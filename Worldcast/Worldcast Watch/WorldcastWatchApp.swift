import AVFoundation
import MediaPlayer
import Observation
import SwiftUI
import WatchKit

@main
struct WorldcastWatchApp: App {
    @State private var model = WatchLibrary()
    @State private var remote = PhoneRemote()

    var body: some Scene {
        WindowGroup {
            WatchContentView()
                .environment(model)
                .environment(remote)
        }
    }
}

struct WatchFeed: Codable, Identifiable {
    let id: Int
    let title: String?
    let unplayed_count: Int?
}

struct WatchEpisode: Codable, Identifiable {
    let id: Int
    let title: String?
    let audio_url: String?
    let duration_seconds: Double?
    let position_seconds: Double?
    let played: Int?
    let audio_available: Int?
    let artwork_url: String?
    let feed_artwork_url: String?
    let feed_title: String?
    let chapter_count: Int?
}

struct WatchChapter: Codable, Identifiable {
    let id: Int
    let title: String?
    let start_ms: Double
    let end_ms: Double?
    let artwork_url: String?

    var startSeconds: Double { start_ms / 1000 }
}

private struct WatchFeedsResponse: Codable {
    let feeds: [WatchFeed]
}

private struct WatchEpisodesResponse: Codable {
    let episodes: [WatchEpisode]
}

private struct WatchEpisodeResponse: Codable {
    let episode: WatchEpisode?
    let chapters: [WatchChapter]?
}

enum WatchBackendError: LocalizedError {
    case notConfigured
    case invalidURL
    case server(Int)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Add your Worldcast server URL first."
        case .invalidURL: return "The server URL is invalid."
        case .server(let code): return "Server error \(code)."
        }
    }
}

@Observable
@MainActor
final class WatchLibrary {
    static let serverURLKey = "worldcast.watch.serverBaseURL"

    var serverURL: String {
        didSet { UserDefaults.standard.set(serverURL, forKey: Self.serverURLKey) }
    }
    var feeds: [WatchFeed] = []
    var episodes: [WatchEpisode] = []
    var selectedFeed: WatchFeed?
    var isLoading = false
    var errorMessage: String?
    var nowPlaying: WatchEpisode?
    var chapters: [WatchChapter] = []
    var currentChapterIndex = -1
    var isPlaying = false
    var currentTime = 0.0
    private(set) var playGeneration = 0

    private let decoder = JSONDecoder()
    private let player = AVPlayer()
    private var timeObserver: Any?
    private var itemObserver: NSKeyValueObservation?
    private var artworkGeneration = 0
    private var nowPlayingArtwork: MPMediaItemArtwork?

    init() {
        serverURL = UserDefaults.standard.string(forKey: Self.serverURLKey) ?? ""
        WatchConfigurationReceiver.shared.onServerURL = { [weak self] serverURL in
            self?.serverURL = serverURL
            self?.selectedFeed = nil
            self?.episodes = []
        }
        WatchConfigurationReceiver.shared.start()
        configureRemoteCommands()
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 2),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                self?.tick(time.seconds)
            }
        }
    }

    var isConfigured: Bool { baseURL != nil }

    var baseURL: URL? {
        let trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(string: trimmed.hasSuffix("/") ? trimmed : trimmed + "/")
    }

    func refreshFeeds() async {
        await load {
            let response: WatchFeedsResponse = try await self.request("api/feeds")
            self.feeds = response.feeds
        }
    }

    func select(_ feed: WatchFeed) async {
        selectedFeed = feed
        await load {
            let response: WatchEpisodesResponse = try await self.request("api/episodes?feed=\(feed.id)&limit=100")
            self.episodes = response.episodes
        }
    }

    /// Same request `select(_:)` makes, but returns instead of mutating
    /// `selectedFeed`/`episodes` — for browsing that shouldn't disturb this
    /// screen's own local-playback navigation state, e.g. the "On My
    /// iPhone" remote library browser.
    func fetchEpisodes(for feed: WatchFeed) async -> [WatchEpisode] {
        do {
            let response: WatchEpisodesResponse = try await request("api/episodes?feed=\(feed.id)&limit=100")
            return response.episodes
        } catch {
            errorMessage = error.localizedDescription
            return []
        }
    }

    func play(_ episode: WatchEpisode) async {
        await load {
            let response: WatchEpisodeResponse = try await self.request("api/episodes/\(episode.id)")
            guard let detailedEpisode = response.episode else {
                throw WatchBackendError.server(404)
            }
            self.startPlayback(detailedEpisode, chapters: response.chapters ?? [])
        }
    }

    func playRandom() async {
        await load {
            let response: WatchEpisodeResponse = try await self.request("api/episodes/random-unplayed")
            guard let episode = response.episode else {
                self.errorMessage = "No never-played episodes available."
                return
            }
            let detail: WatchEpisodeResponse = try await self.request("api/episodes/\(episode.id)")
            guard let detailedEpisode = detail.episode else {
                throw WatchBackendError.server(404)
            }
            self.startPlayback(detailedEpisode, chapters: detail.chapters ?? [])
        }
    }

    private func startPlayback(_ episode: WatchEpisode, chapters: [WatchChapter]) {
        guard let audioURL = resolve(episode.audio_url) else {
            errorMessage = "This episode has no playable audio."
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        nowPlaying = episode
        self.chapters = chapters.sorted { $0.start_ms < $1.start_ms }
        currentChapterIndex = -1
        currentTime = episode.position_seconds ?? 0
        let item = AVPlayerItem(url: audioURL)
        itemObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            Task { @MainActor [weak self] in
                self?.errorMessage = item.error?.localizedDescription ?? "Playback failed."
            }
        }
        player.replaceCurrentItem(with: item)
        if currentTime > 1 {
            player.seek(to: CMTime(seconds: currentTime, preferredTimescale: 1))
        }
        player.play()
        isPlaying = true
        playGeneration += 1
        updateChapter(at: currentTime)
        publishNowPlaying()
        updateArtwork()
    }

    func togglePlayback() {
        if isPlaying {
            player.pause()
            isPlaying = false
            pushPosition()
        } else {
            player.play()
            isPlaying = true
        }
        publishNowPlaying()
    }

    func seek(by seconds: Double) {
        seek(to: currentTime + seconds)
    }

    func seek(to seconds: Double) {
        let duration = nowPlaying?.duration_seconds ?? 0
        let target = max(0, duration > 0 ? min(seconds, duration) : seconds)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 1))
        currentTime = target
        updateChapter(at: target)
        publishNowPlaying()
        pushPosition()
    }

    func jumpChapter(_ direction: Int) {
        guard !chapters.isEmpty else {
            seek(by: direction < 0 ? -15 : 30)
            return
        }
        let current = chapterIndex(at: currentTime)
        let target = max(0, min(chapters.count - 1, (current < 0 ? 0 : current) + direction))
        seek(to: chapters[target].startSeconds)
    }

    func pushPosition() {
        guard let nowPlaying else { return }
        let position = currentTime
        Task {
            struct Response: Codable { let ok: Bool? }
            let _: Response? = try? await request(
                "api/episodes/\(nowPlaying.id)/position",
                method: "POST",
                body: ["position": position, "client_ts": Date().timeIntervalSince1970 * 1000]
            )
        }
    }

    private func load(_ operation: @escaping () async throws -> Void) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            try await operation()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func tick(_ seconds: Double) {
        guard nowPlaying != nil, seconds.isFinite else { return }
        currentTime = seconds
        updateChapter(at: seconds)
    }

    private func chapterIndex(at seconds: Double) -> Int {
        var result = -1
        for (index, chapter) in chapters.enumerated() {
            if seconds >= chapter.startSeconds {
                result = index
            } else {
                break
            }
        }
        return result
    }

    private func updateChapter(at seconds: Double) {
        let index = chapterIndex(at: seconds)
        guard index != currentChapterIndex else { return }
        currentChapterIndex = index
        publishNowPlaying()
        updateArtwork()
    }

    private var currentChapter: WatchChapter? {
        guard chapters.indices.contains(currentChapterIndex) else { return nil }
        return chapters[currentChapterIndex]
    }

    private func publishNowPlaying() {
        guard let episode = nowPlaying else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: currentChapter?.title ?? episode.title ?? "Untitled episode",
            MPMediaItemPropertyArtist: episode.feed_title ?? "Worldcast",
            MPMediaItemPropertyAlbumTitle: episode.title ?? "Untitled episode",
            MPNowPlayingInfoPropertyExternalContentIdentifier: "worldcast-watch:\(episode.id)",
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1 : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let duration = episode.duration_seconds, duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        if currentChapterIndex >= 0 {
            info[MPNowPlayingInfoPropertyChapterNumber] = currentChapterIndex + 1
            info[MPNowPlayingInfoPropertyChapterCount] = chapters.count
        }
        if let artwork = nowPlayingArtwork {
            info[MPMediaItemPropertyArtwork] = artwork
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func updateArtwork() {
        let rawURL = currentChapter?.artwork_url
            ?? nowPlaying?.artwork_url
            ?? nowPlaying?.feed_artwork_url
        guard let url = resolve(rawURL) else {
            nowPlayingArtwork = nil
            publishNowPlaying()
            return
        }
        artworkGeneration += 1
        let generation = artworkGeneration
        Task { [weak self] in
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard let image = UIImage(data: data), let self,
                      generation == self.artworkGeneration else { return }
                self.nowPlayingArtwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                self.publishNowPlaying()
            } catch {
                guard let self, generation == self.artworkGeneration else { return }
                self.nowPlayingArtwork = nil
                self.publishNowPlaying()
            }
        }
    }

    private func configureRemoteCommands() {
        let commands = MPRemoteCommandCenter.shared()
        commands.playCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.player.play()
                self.isPlaying = true
                self.publishNowPlaying()
            }
            return .success
        }
        commands.pauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.player.pause()
                self.isPlaying = false
                self.publishNowPlaying()
                self.pushPosition()
            }
            return .success
        }
        commands.togglePlayPauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.togglePlayback() }
            return .success
        }
        commands.skipBackwardCommand.preferredIntervals = [NSNumber(value: 15)]
        commands.skipForwardCommand.preferredIntervals = [NSNumber(value: 30)]
        commands.skipBackwardCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.seek(by: -15) }
            return .success
        }
        commands.skipForwardCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.seek(by: 30) }
            return .success
        }
        commands.previousTrackCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.jumpChapter(-1) }
            return .success
        }
        commands.nextTrackCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.jumpChapter(1) }
            return .success
        }
        commands.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            MainActor.assumeIsolated { self?.seek(to: event.positionTime) }
            return .success
        }
    }

    private func resolve(_ path: String?) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        if path.lowercased().hasPrefix("http://") || path.lowercased().hasPrefix("https://") {
            return URL(string: path)
        }
        guard let baseURL else { return nil }
        return URL(string: path, relativeTo: baseURL)?.absoluteURL
    }

    private func request<T: Decodable>(_ path: String, method: String = "GET",
                                       body: [String: Any]? = nil) async throws -> T {
        guard let url = resolve(path) else {
            throw isConfigured ? WatchBackendError.invalidURL : WatchBackendError.notConfigured
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw WatchBackendError.server(status) }
        return try decoder.decode(T.self, from: data)
    }
}

private enum WatchDestination: String, Identifiable {
    case localPlayer
    case phoneRemote

    var id: String { rawValue }
}

struct WatchContentView: View {
    @Environment(WatchLibrary.self) private var model
    @Environment(PhoneRemote.self) private var remote
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingSettings = false
    @State private var destination: WatchDestination?
    @State private var wasBackgrounded = false

    var body: some View {
        NavigationStack {
            Group {
                if let feed = model.selectedFeed {
                    episodeList(feed)
                } else {
                    rootList
                }
            }
            .navigationTitle(model.selectedFeed?.title ?? "Worldcast")
            .toolbar {
                if model.selectedFeed != nil {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Back", systemImage: "chevron.left") {
                            model.selectedFeed = nil
                            model.episodes = []
                        }
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if model.nowPlaying != nil {
                        Button("Now Playing", systemImage: "waveform") {
                            showLocalPlayer()
                        }
                    }
                    Button("Shuffle", systemImage: "shuffle") {
                        Task { await model.playRandom() }
                    }
                }
            }
            .navigationDestination(item: $destination) { destination in
                switch destination {
                case .localPlayer:
                    WatchPlaybackPager()
                case .phoneRemote:
                    PhoneRemoteView()
                }
            }
            .sheet(isPresented: $showingSettings) {
                WatchSettingsView()
            }
            .alert("Worldcast", isPresented: .init(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.errorMessage ?? "")
            }
            .task(id: model.serverURL) {
                if model.isConfigured { await model.refreshFeeds() }
                if model.nowPlaying == nil, remote.nowPlaying != nil {
                    showPhoneRemote()
                }
            }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .active:
                    if wasBackgrounded {
                        if model.nowPlaying != nil {
                            showLocalPlayer()
                        } else if remote.nowPlaying != nil {
                            showPhoneRemote()
                        }
                    }
                    wasBackgrounded = false
                case .background:
                    wasBackgrounded = true
                    model.pushPosition()
                case .inactive:
                    model.pushPosition()
                @unknown default:
                    break
                }
            }
            .onChange(of: model.playGeneration) { showLocalPlayer() }
            .onChange(of: remote.nowPlaying?.episodeId) {
                if remote.nowPlaying != nil, model.nowPlaying == nil {
                    showPhoneRemote()
                }
            }
        }
    }

    private var rootList: some View {
        List {
            Section {
                Button {
                    showPhoneRemote()
                } label: {
                    Label("On My iPhone", systemImage: "iphone")
                }
            }
            Section("Library") {
                if !model.isConfigured {
                    Text("Add the server URL, including its secret token path, in Settings.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.feeds) { feed in
                        Button {
                            Task { await model.select(feed) }
                        } label: {
                            VStack(alignment: .leading) {
                                Text(feed.title ?? "Untitled feed")
                                if let count = feed.unplayed_count, count > 0 {
                                    Text("\(count) unplayed").foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            Section {
                Button("Settings", systemImage: "gearshape") { showingSettings = true }
            }
        }
        .overlay { if model.isLoading { ProgressView() } }
    }

    private func episodeList(_ feed: WatchFeed) -> some View {
        List(model.episodes) { episode in
            Button {
                Task { await model.play(episode) }
            } label: {
                VStack(alignment: .leading) {
                    Text(episode.title ?? "Untitled episode").lineLimit(2)
                    Text(WatchFormatters.time(episode.duration_seconds ?? 0))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .overlay { if model.isLoading { ProgressView() } }
    }

    private func showLocalPlayer() {
        destination = .localPlayer
    }

    private func showPhoneRemote() {
        destination = .phoneRemote
    }
}

struct WatchPlaybackPager: View {
    @Environment(WatchLibrary.self) private var model
    @State private var page = 0

    var body: some View {
        TabView(selection: $page) {
            NowPlayingView()
                .tag(0)

            if !model.chapters.isEmpty {
                List {
                    ForEach(Array(model.chapters.enumerated()), id: \.element.id) { index, chapter in
                        Button {
                            model.seek(to: chapter.startSeconds)
                            page = 0
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(chapter.title ?? "Chapter \(index + 1)")
                                    .lineLimit(2)
                                Text(WatchFormatters.time(chapter.startSeconds))
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .listRowBackground(
                            index == model.currentChapterIndex
                                ? Color.accentColor.opacity(0.18)
                                : Color.clear
                        )
                    }
                }
                .navigationTitle("Chapters")
                .tag(1)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: model.chapters.isEmpty ? .never : .always))
        .navigationTitle(page == 0 ? "Now Playing" : "Chapters")
    }
}

struct WatchSettingsView: View {
    @Environment(WatchLibrary.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var serverURL = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Server URL", text: $serverURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Text("Enter the full URL, including the Worldcast token path. The watch connects directly over Wi-Fi or cellular.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .navigationTitle("Server")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        model.serverURL = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
                        model.selectedFeed = nil
                        dismiss()
                    }
                }
            }
            .onAppear { serverURL = model.serverURL }
        }
    }
}

enum WatchFormatters {
    static func time(_ seconds: Double) -> String {
        let value = max(0, Int(seconds))
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}
