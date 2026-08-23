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
    private static let lastEpisodeKey = "worldcast.watch.lastEpisodeId"
    private static let lastPositionKey = "worldcast.watch.lastPosition"

    var serverURL: String {
        didSet { UserDefaults.standard.set(serverURL, forKey: Self.serverURLKey) }
    }
    var feeds: [WatchFeed] = []
    var recentEpisodes: [WatchEpisode] = []
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
    let downloads = WatchDownloadManager()

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
        downloads.fetchDetail = { [weak self] episodeId in
            guard let self else { throw WatchBackendError.notConfigured }
            let response: WatchEpisodeResponse = try await self.request("api/episodes/\(episodeId)")
            guard let episode = response.episode else { throw WatchBackendError.server(404) }
            return (episode, response.chapters ?? [])
        }
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

    func refreshLibrary() async {
        await load {
            let feedsResponse: WatchFeedsResponse = try await self.request("api/feeds")
            let recentResponse: WatchEpisodesResponse =
                try await self.request("api/episodes/recent?limit=10")
            self.feeds = feedsResponse.feeds
            self.recentEpisodes = recentResponse.episodes
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

    @discardableResult
    func play(_ episode: WatchEpisode, startAt position: Double? = nil) async -> Bool {
        if let local = downloads.localAudioURL(for: episode.id) {
            let detailedEpisode = downloads.downloaded[episode.id]?.episode ?? episode
            startPlayback(
                detailedEpisode,
                chapters: downloads.chapters(for: episode.id) ?? [],
                position: position,
                autoplay: true,
                localFileURL: local
            )
            return true
        }
        var started = false
        await load {
            let response: WatchEpisodeResponse = try await self.request("api/episodes/\(episode.id)")
            guard let detailedEpisode = response.episode else {
                throw WatchBackendError.server(404)
            }
            self.startPlayback(
                detailedEpisode,
                chapters: response.chapters ?? [],
                position: position,
                autoplay: true
            )
            started = true
        }
        return started
    }

    /// Kicks off an offline download for `episode`: refetches its detail
    /// (for chapter data) and hands the audio URL to `WatchDownloadManager`.
    func startDownload(_ episode: WatchEpisode) {
        Task {
            do {
                let response: WatchEpisodeResponse = try await request("api/episodes/\(episode.id)")
                guard let detailedEpisode = response.episode,
                      let audioURL = resolve(detailedEpisode.audio_url) else {
                    errorMessage = "This episode has no playable audio."
                    return
                }
                downloads.startDownload(
                    episode: detailedEpisode,
                    chapters: response.chapters ?? [],
                    audioURL: audioURL
                )
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    @discardableResult
    func play(serverId: Int, startAt position: Double) async -> Bool {
        if let local = downloads.localAudioURL(for: serverId) {
            let episode = downloads.downloaded[serverId]?.episode
            if let episode {
                startPlayback(
                    episode,
                    chapters: downloads.chapters(for: serverId) ?? [],
                    position: position,
                    autoplay: true,
                    localFileURL: local
                )
                return true
            }
        }
        var started = false
        await load {
            let response: WatchEpisodeResponse = try await self.request("api/episodes/\(serverId)")
            guard let episode = response.episode else {
                throw WatchBackendError.server(404)
            }
            self.startPlayback(
                episode,
                chapters: response.chapters ?? [],
                position: position,
                autoplay: true
            )
            started = true
        }
        return started
    }

    func restoreLastEpisode() async {
        let defaults = UserDefaults.standard
        guard nowPlaying == nil,
              defaults.object(forKey: Self.lastEpisodeKey) != nil else { return }
        let episodeId = defaults.integer(forKey: Self.lastEpisodeKey)
        let position = defaults.double(forKey: Self.lastPositionKey)
        if let local = downloads.localAudioURL(for: episodeId),
           let episode = downloads.downloaded[episodeId]?.episode {
            startPlayback(
                episode,
                chapters: downloads.chapters(for: episodeId) ?? [],
                position: position,
                autoplay: false,
                announce: false,
                localFileURL: local
            )
            return
        }
        guard isConfigured else { return }
        await load {
            let response: WatchEpisodeResponse = try await self.request("api/episodes/\(episodeId)")
            guard let episode = response.episode else {
                throw WatchBackendError.server(404)
            }
            self.startPlayback(
                episode,
                chapters: response.chapters ?? [],
                position: position,
                autoplay: false,
                announce: false
            )
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
            self.startPlayback(
                detailedEpisode,
                chapters: detail.chapters ?? [],
                position: nil,
                autoplay: true
            )
        }
    }

    private func startPlayback(
        _ episode: WatchEpisode,
        chapters: [WatchChapter],
        position: Double?,
        autoplay: Bool,
        announce: Bool = true,
        localFileURL: URL? = nil
    ) {
        guard let audioURL = localFileURL ?? resolve(episode.audio_url) else {
            errorMessage = "This episode has no playable audio."
            return
        }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        nowPlaying = episode
        noteRecentlyPlayed(episode)
        UserDefaults.standard.set(episode.id, forKey: Self.lastEpisodeKey)
        self.chapters = chapters.sorted { $0.start_ms < $1.start_ms }
        currentTime = max(0, position ?? episode.position_seconds ?? 0)
        currentChapterIndex = chapterIndex(at: currentTime)
        saveLocalPosition()
        nowPlayingArtwork = nil
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
        if autoplay {
            resumePlayback()
            updateArtwork()
        } else {
            player.pause()
            isPlaying = false
        }
        if announce { playGeneration += 1 }
    }

    func togglePlayback() {
        if isPlaying {
            pausePlayback()
        } else {
            resumePlayback()
        }
    }

    func resumePlayback() {
        guard nowPlaying != nil else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        player.play()
        isPlaying = true
        publishNowPlaying()
    }

    func pausePlayback() {
        player.pause()
        isPlaying = false
        publishNowPlaying()
        pushPosition()
    }

    func relinquishPlayback() {
        if isPlaying {
            pausePlayback()
        } else {
            player.pause()
        }
        player.replaceCurrentItem(with: nil)
        itemObserver = nil
        nowPlaying = nil
        chapters = []
        currentChapterIndex = -1
        currentTime = 0
        isPlaying = false
        UserDefaults.standard.removeObject(forKey: Self.lastEpisodeKey)
        UserDefaults.standard.removeObject(forKey: Self.lastPositionKey)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
    }

    func seek(by seconds: Double) {
        seek(to: currentTime + seconds)
    }

    func seek(to seconds: Double) {
        let duration = nowPlaying?.duration_seconds ?? 0
        let target = max(0, duration > 0 ? min(seconds, duration) : seconds)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 1))
        currentTime = target
        saveLocalPosition()
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
        saveLocalPosition()
        Task {
            struct Response: Codable { let ok: Bool? }
            let _: Response? = try? await request(
                "api/episodes/\(nowPlaying.id)/position",
                method: "POST",
                body: ["position": position, "client_ts": Date().timeIntervalSince1970 * 1000]
            )
        }
    }

    func noteRecentlyPlayed(_ episode: WatchEpisode) {
        recentEpisodes.removeAll { $0.id == episode.id }
        recentEpisodes.insert(episode, at: 0)
        if recentEpisodes.count > 10 {
            recentEpisodes.removeLast(recentEpisodes.count - 10)
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
        if Int(seconds) % 10 == 0 { saveLocalPosition() }
        updateChapter(at: seconds)
    }

    private func saveLocalPosition() {
        UserDefaults.standard.set(currentTime, forKey: Self.lastPositionKey)
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
                self?.resumePlayback()
            }
            return .success
        }
        commands.pauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pausePlayback()
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
    @State private var phoneInitialPage = 0

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
                            model.resumePlayback()
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
                    WatchPlaybackPager(initialSource: .watch)
                case .phoneRemote:
                    PhoneRemoteView(initialPage: phoneInitialPage)
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
                remote.requestStateRefresh()
                if model.isConfigured {
                    await model.refreshLibrary()
                    await model.restoreLastEpisode()
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { model.pushPosition() }
            }
            .onChange(of: model.playGeneration) { showLocalPlayer() }
        }
    }

    private var rootList: some View {
        List {
            if model.nowPlaying != nil || remote.nowPlaying != nil {
                Section("Resume") {
                    if let episode = model.nowPlaying {
                        Button {
                            model.resumePlayback()
                            showLocalPlayer()
                        } label: {
                            Label(
                                episode.title ?? "On Apple Watch",
                                systemImage: "applewatch"
                            )
                        }
                    }
                    if let nowPlaying = remote.nowPlaying {
                        Button {
                            Task {
                                if await remote.playAwaitingReply() {
                                    showPhoneRemote()
                                } else {
                                    model.errorMessage = "Could not resume playback on the iPhone."
                                }
                            }
                        } label: {
                            Label(nowPlaying.title, systemImage: "iphone")
                        }
                    }
                }
            }
            Section {
                Button {
                    remote.requestStateRefresh()
                    showPhoneRemote(initialPage: 2)
                } label: {
                    Label("On My iPhone", systemImage: "iphone")
                }
            }
            if !model.recentEpisodes.isEmpty {
                Section("Recently Played") {
                    ForEach(model.recentEpisodes) { episode in
                        WatchDownloadableEpisodeRow(episode: episode, showFeedTitle: true) {
                            Task { await model.play(episode) }
                        }
                    }
                }
            }
            if !model.downloads.downloadedEpisodes.isEmpty {
                Section("Downloaded") {
                    ForEach(model.downloads.downloadedEpisodes) { episode in
                        WatchDownloadableEpisodeRow(episode: episode, showFeedTitle: true) {
                            Task { await model.play(episode) }
                        }
                    }
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
        .refreshable { await model.refreshLibrary() }
    }

    private func episodeList(_ feed: WatchFeed) -> some View {
        List(model.episodes) { episode in
            WatchDownloadableEpisodeRow(episode: episode) {
                Task { await model.play(episode) }
            }
        }
        .overlay { if model.isLoading { ProgressView() } }
    }

    private func showLocalPlayer() {
        destination = .localPlayer
    }

    private func showPhoneRemote(initialPage: Int = 0) {
        phoneInitialPage = initialPage
        destination = .phoneRemote
    }
}

struct WatchPlaybackPager: View {
    @Environment(WatchLibrary.self) private var model
    @Environment(PhoneRemote.self) private var remote
    @State private var source: PlaybackSource
    @State private var page: Int

    init(initialSource: PlaybackSource, initialPage: Int = 0) {
        _source = State(initialValue: initialSource)
        _page = State(initialValue: initialPage)
    }

    var body: some View {
        TabView(selection: $page) {
            NowPlayingView()
                .tag(0)

            Group {
                switch source {
                case .watch:
                    LocalChapterList(page: $page)
                case .phone:
                    RemoteChapterList(page: $page)
                }
            }
            .tag(1)

            PlaybackLibraryPage(source: $source, page: $page)
                .tag(2)
        }
        .tabViewStyle(.page(indexDisplayMode: .always))
        .navigationTitle(pageTitle)
        .toolbar {
            if page == 2 {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Shuffle", systemImage: "shuffle") {
                        switch source {
                        case .watch:
                            Task { await model.playRandom() }
                        case .phone:
                            remote.shuffle()
                        }
                    }
                    .disabled(source == .phone && !remote.isReachable)
                }
            }
        }
        .task { remote.requestStateRefresh() }
    }

    private var pageTitle: String {
        switch page {
        case 1: "Chapters"
        case 2: source.title
        default: "Now Playing"
        }
    }
}

private struct LocalChapterList: View {
    @Environment(WatchLibrary.self) private var model
    @Binding var page: Int

    var body: some View {
        if model.chapters.isEmpty {
            ContentUnavailableView("No Chapters", systemImage: "list.bullet")
        } else {
            ScrollViewReader { proxy in
                List {
                    ForEach(Array(model.chapters.enumerated()), id: \.element.id) { index, chapter in
                        Button {
                            model.seek(to: chapter.startSeconds)
                            page = 0
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(chapter.title ?? "Chapter \(index + 1)")
                                        .lineLimit(2)
                                    Text(WatchFormatters.time(chapter.startSeconds))
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if index == model.currentChapterIndex {
                                    Image(systemName: "waveform")
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                        }
                        .id(chapter.id)
                        .listRowBackground(
                            index == model.currentChapterIndex
                                ? Color.accentColor.opacity(0.18)
                                : Color.clear
                        )
                    }
                }
                .task(id: model.currentChapterIndex) {
                    guard model.chapters.indices.contains(model.currentChapterIndex) else { return }
                    await Task.yield()
                    withAnimation {
                        proxy.scrollTo(
                            model.chapters[model.currentChapterIndex].id,
                            anchor: .center
                        )
                    }
                }
            }
        }
    }
}

private struct RemoteChapterList: View {
    @Environment(PhoneRemote.self) private var remote
    @Binding var page: Int

    var body: some View {
        if let nowPlaying = remote.nowPlaying, !nowPlaying.chapters.isEmpty {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let currentIndex = nowPlaying.chapterIndex(at: context.date)
                ScrollViewReader { proxy in
                    List {
                        ForEach(Array(nowPlaying.chapters.enumerated()), id: \.element.id) { index, chapter in
                            Button {
                                remote.seek(to: chapter.start)
                                page = 0
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(chapter.title ?? "Chapter \(index + 1)")
                                            .lineLimit(2)
                                        Text(WatchFormatters.time(chapter.start))
                                            .font(.footnote)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if index == currentIndex {
                                        Image(systemName: "waveform")
                                            .foregroundStyle(Color.accentColor)
                                    }
                                }
                            }
                            .id(chapter.id)
                            .listRowBackground(
                                index == currentIndex
                                    ? Color.accentColor.opacity(0.18)
                                    : Color.clear
                            )
                        }
                    }
                    .task(id: currentIndex) {
                        guard nowPlaying.chapters.indices.contains(currentIndex) else { return }
                        await Task.yield()
                        withAnimation {
                            proxy.scrollTo(nowPlaying.chapters[currentIndex].id, anchor: .center)
                        }
                    }
                }
            }
        } else {
            ContentUnavailableView("No Chapters", systemImage: "list.bullet")
        }
    }
}

private struct PlaybackLibraryPage: View {
    @Environment(WatchLibrary.self) private var model
    @Environment(PhoneRemote.self) private var remote
    @Binding var source: PlaybackSource
    @Binding var page: Int
    @State private var browsingFeed: WatchFeed?
    @State private var browsedEpisodes: [WatchEpisode] = []
    @State private var isLoadingEpisodes = false

    var body: some View {
        List {
            Section {
                Picker("Play On", selection: $source) {
                    ForEach(PlaybackSource.allCases) { source in
                        Label(source.title, systemImage: source.symbol).tag(source)
                    }
                }
            }

            handoffSection

            if !model.recentEpisodes.isEmpty {
                Section("Recently Played") {
                    ForEach(model.recentEpisodes) { episode in
                        episodeButton(episode)
                    }
                }
            }

            Section("Library") {
                if !model.isConfigured {
                    Text("Add the server URL in Settings.")
                        .foregroundStyle(.secondary)
                } else if browsingFeed != nil {
                    Button("All Feeds", systemImage: "chevron.left") {
                        self.browsingFeed = nil
                        browsedEpisodes = []
                    }
                    ForEach(browsedEpisodes) { episode in
                        episodeButton(episode)
                    }
                } else if model.feeds.isEmpty {
                    Text("No feeds yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(model.feeds) { feed in
                        Button {
                            self.browsingFeed = feed
                            Task {
                                isLoadingEpisodes = true
                                browsedEpisodes = await model.fetchEpisodes(for: feed)
                                isLoadingEpisodes = false
                            }
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

            if source == .phone && !remote.isReachable {
                Text("iPhone not reachable")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .overlay { if isLoadingEpisodes || model.isLoading { ProgressView() } }
        .onChange(of: source) {
            browsingFeed = nil
            browsedEpisodes = []
        }
    }

    @ViewBuilder
    private var handoffSection: some View {
        switch source {
        case .watch:
            if let phone = remote.nowPlaying {
                Section {
                    Button("Continue on Apple Watch", systemImage: "applewatch") {
                        guard let serverId = phone.serverId else {
                            model.errorMessage = "This iPhone episode is not available on the watch."
                            return
                        }
                        Task {
                            let position = phone.extrapolatedPosition()
                            guard await remote.pauseAwaitingReply() else {
                                model.errorMessage = "Could not pause playback on the iPhone."
                                return
                            }
                            if await model.play(serverId: serverId, startAt: position) {
                                page = 0
                            } else {
                                remote.play()
                            }
                        }
                    }
                }
            }
        case .phone:
            if let episode = model.nowPlaying {
                Section {
                    Button("Continue on iPhone", systemImage: "iphone") {
                        Task {
                            let shouldResumeOnFailure = model.isPlaying
                            model.pausePlayback()
                            if await remote.playEpisodeAwaitingReply(
                                serverId: episode.id,
                                position: model.currentTime
                            ) {
                                model.relinquishPlayback()
                                page = 0
                            } else {
                                if shouldResumeOnFailure { model.resumePlayback() }
                                model.errorMessage = "Could not start playback on the iPhone."
                            }
                        }
                    }
                    .disabled(!remote.isReachable)
                }
            }
        }
    }

    @ViewBuilder
    private func episodeButton(_ episode: WatchEpisode) -> some View {
        switch source {
        case .watch:
            WatchDownloadableEpisodeRow(episode: episode) {
                Task {
                    if await model.play(episode) { page = 0 }
                }
            }
        case .phone:
            Button {
                Task {
                    if await remote.playEpisodeAwaitingReply(serverId: episode.id) {
                        model.noteRecentlyPlayed(episode)
                        page = 0
                    } else {
                        model.errorMessage = "Could not start playback on the iPhone."
                    }
                }
            } label: {
                VStack(alignment: .leading) {
                    Text(episode.title ?? "Untitled episode").lineLimit(2)
                    Text(WatchFormatters.time(episode.duration_seconds ?? 0))
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(!remote.isReachable)
        }
    }
}

private struct WatchDownloadableEpisodeRow: View {
    @Environment(WatchLibrary.self) private var model
    let episode: WatchEpisode
    var showFeedTitle = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(episode.title ?? "Untitled episode").lineLimit(2)
                    if showFeedTitle, let feedTitle = episode.feed_title, !feedTitle.isEmpty {
                        Text(feedTitle)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        Text(WatchFormatters.time(episode.duration_seconds ?? 0))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                downloadIndicator
            }
        }
        .swipeActions { downloadSwipeAction }
    }

    @ViewBuilder
    private var downloadIndicator: some View {
        switch model.downloads.state(for: episode.id) {
        case .downloading(let progress):
            ProgressView(value: max(0.02, progress)).frame(width: 24)
        case .failed:
            Image(systemName: "exclamationmark.circle").foregroundStyle(.red)
        case nil:
            if model.downloads.isDownloaded(episode.id) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .imageScale(.small)
            }
        }
    }

    @ViewBuilder
    private var downloadSwipeAction: some View {
        switch model.downloads.state(for: episode.id) {
        case .downloading:
            Button("Cancel", systemImage: "xmark") {
                model.downloads.cancelDownload(for: episode.id)
            }
            .tint(.red)
        default:
            if model.downloads.isDownloaded(episode.id) {
                Button("Remove", systemImage: "trash") {
                    model.downloads.removeDownload(for: episode.id)
                }
                .tint(.red)
            } else {
                Button("Download", systemImage: "arrow.down.circle") {
                    model.startDownload(episode)
                }
                .tint(.blue)
            }
        }
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
