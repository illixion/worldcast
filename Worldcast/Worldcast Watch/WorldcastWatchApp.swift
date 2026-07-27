import AVFoundation
import Observation
import SwiftUI

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
}

private struct WatchFeedsResponse: Codable {
    let feeds: [WatchFeed]
}

private struct WatchEpisodesResponse: Codable {
    let episodes: [WatchEpisode]
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
    var isPlaying = false
    var currentTime = 0.0

    private let decoder = JSONDecoder()
    private let player = AVPlayer()
    private var timeObserver: Any?

    init() {
        serverURL = UserDefaults.standard.string(forKey: Self.serverURLKey) ?? ""
        WatchConfigurationReceiver.shared.onServerURL = { [weak self] serverURL in
            self?.serverURL = serverURL
            self?.selectedFeed = nil
            self?.episodes = []
        }
        WatchConfigurationReceiver.shared.start()
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1, preferredTimescale: 1),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                self?.currentTime = time.seconds.isFinite ? time.seconds : 0
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

    func play(_ episode: WatchEpisode) {
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
        currentTime = episode.position_seconds ?? 0
        player.replaceCurrentItem(with: AVPlayerItem(url: audioURL))
        if currentTime > 1 {
            player.seek(to: CMTime(seconds: currentTime, preferredTimescale: 1))
        }
        player.play()
        isPlaying = true
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
    }

    func seek(by seconds: Double) {
        let target = max(0, currentTime + seconds)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 1))
        currentTime = target
        pushPosition()
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

struct WatchContentView: View {
    @Environment(WatchLibrary.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingSettings = false

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
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Settings", systemImage: "gearshape") { showingSettings = true }
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
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { model.pushPosition() }
            }
        }
    }

    private var rootList: some View {
        List {
            Section {
                NavigationLink {
                    PhoneRemoteView()
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
        }
        .overlay { if model.isLoading { ProgressView() } }
    }

    private func episodeList(_ feed: WatchFeed) -> some View {
        List(model.episodes) { episode in
            Button {
                model.play(episode)
            } label: {
                VStack(alignment: .leading) {
                    Text(episode.title ?? "Untitled episode").lineLimit(2)
                    Text(WatchFormatters.time(episode.duration_seconds ?? 0))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Back", systemImage: "chevron.left") {
                    model.selectedFeed = nil
                    model.episodes = []
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let episode = model.nowPlaying {
                WatchPlayerControls(episode: episode)
            }
        }
        .overlay { if model.isLoading { ProgressView() } }
    }
}

struct WatchPlayerControls: View {
    @Environment(WatchLibrary.self) private var model
    let episode: WatchEpisode

    var body: some View {
        VStack(spacing: 4) {
            Text(episode.title ?? "Now Playing").lineLimit(1)
            Text(WatchFormatters.time(model.currentTime)).foregroundStyle(.secondary)
            HStack {
                Button("-15", systemImage: "gobackward.15") { model.seek(by: -15) }
                Button(model.isPlaying ? "Pause" : "Play",
                       systemImage: model.isPlaying ? "pause.fill" : "play.fill") {
                    model.togglePlayback()
                }
                Button("+30", systemImage: "goforward.30") { model.seek(by: 30) }
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal)
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
