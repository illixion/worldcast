import Foundation
import Observation
import SwiftUI
import WatchKit

struct RemoteChapter: Identifiable {
    let id: String
    let title: String?
    let start: Double
}

/// Snapshot of the iPhone's now-playing state, as pushed through
/// WatchConnectivity application context by WatchConfigurationSync on the
/// phone. `publishedAt` + `rate` let the watch extrapolate elapsed time
/// between snapshots instead of polling.
struct RemoteNowPlaying {
    let episodeId: String
    let title: String
    let feedTitle: String
    let chapterTitle: String?
    let artworkURL: URL?
    let position: Double
    let duration: Double
    let rate: Double
    let publishedAt: Date
    let chapters: [RemoteChapter]

    init?(_ dict: [String: Any]) {
        guard let title = dict["title"] as? String,
              let position = dict["position"] as? Double,
              let duration = dict["duration"] as? Double,
              let rate = dict["rate"] as? Double,
              let publishedAtRaw = dict["publishedAt"] as? Double else { return nil }
        episodeId = dict["episodeId"] as? String ?? ""
        self.title = title
        feedTitle = dict["feedTitle"] as? String ?? ""
        chapterTitle = dict["chapterTitle"] as? String
        artworkURL = (dict["artworkURL"] as? String).flatMap(URL.init(string:))
        self.position = position
        self.duration = duration
        self.rate = rate
        publishedAt = Date(timeIntervalSince1970: publishedAtRaw)
        chapters = (dict["chapters"] as? [[String: Any]] ?? []).compactMap { chapter in
            guard let id = chapter["id"] as? String,
                  let start = chapter["start"] as? Double else { return nil }
            let rawTitle = chapter["title"] as? String
            return RemoteChapter(
                id: id,
                title: rawTitle.flatMap { $0.isEmpty ? nil : $0 },
                start: start
            )
        }
    }

    /// Elapsed time extrapolated to `now`, matching how the phone's own lock
    /// screen extrapolates MPNowPlayingInfo between publishes.
    func extrapolatedPosition(at now: Date = Date()) -> Double {
        guard duration > 0 else { return max(0, position + rate * now.timeIntervalSince(publishedAt)) }
        return min(duration, max(0, position + rate * now.timeIntervalSince(publishedAt)))
    }
}

/// The watch-side half of "On My iPhone": mirrors the phone's playback state
/// and forwards transport commands to it live over WatchConnectivity. This
/// is deliberately separate from WatchLibrary, which drives the watch's own
/// standalone playback straight against the backend — the two never share a
/// player.
@Observable
@MainActor
final class PhoneRemote {
    private(set) var nowPlaying: RemoteNowPlaying?
    private(set) var isReachable = false
    /// Distinguishes "no snapshot received yet" from "phone confirmed nothing
    /// is playing" so the UI doesn't flash a wrong state on first appearance.
    private(set) var hasReceivedSnapshot = false

    init() {
        let receiver = WatchConfigurationReceiver.shared
        isReachable = receiver.isReachable
        receiver.onNowPlaying = { [weak self] dict in
            self?.hasReceivedSnapshot = true
            self?.nowPlaying = dict.flatMap(RemoteNowPlaying.init)
        }
        receiver.onReachabilityChanged = { [weak self] reachable in
            self?.isReachable = reachable
        }
        receiver.start()
    }

    func requestStateRefresh() {
        WatchConfigurationReceiver.shared.sendCommand("requestState")
    }

    func play() { WatchConfigurationReceiver.shared.sendCommand("play") }
    func pause() { WatchConfigurationReceiver.shared.sendCommand("pause") }
    func toggle() { WatchConfigurationReceiver.shared.sendCommand("toggle") }

    func seek(to seconds: Double) {
        WatchConfigurationReceiver.shared.sendCommand("seek", ["to": seconds])
    }

    func seekBy(_ delta: Double) {
        WatchConfigurationReceiver.shared.sendCommand("seekBy", ["delta": delta])
    }

    func jumpChapter(_ dir: Int) {
        WatchConfigurationReceiver.shared.sendCommand("chapter", ["dir": dir])
    }

    /// Tell the phone to start streaming a specific episode from its library.
    func playEpisode(_ episode: WatchEpisode) {
        WatchConfigurationReceiver.shared.sendCommand("playEpisode", ["episodeId": episode.id])
    }

    /// Tell the phone to play a random never-played episode, mirroring the
    /// main app's library shuffle button.
    func shuffle() {
        WatchConfigurationReceiver.shared.sendCommand("shuffle")
    }
}

/// "On My iPhone" keeps the system Now Playing controls and the phone library
/// on separate swipeable pages, matching the native watchOS media-player
/// pattern. Picking an episode starts it on the iPhone, never on this watch.
struct PhoneRemoteView: View {
    @Environment(WatchLibrary.self) private var model
    @Environment(PhoneRemote.self) private var remote
    @State private var browsingFeed: WatchFeed?
    @State private var browsedEpisodes: [WatchEpisode] = []
    @State private var isLoadingEpisodes = false
    @State private var page = 0

    var body: some View {
        TabView(selection: $page) {
            NowPlayingView()
                .tag(0)

            if let chapters = remote.nowPlaying?.chapters, !chapters.isEmpty {
                remoteChapterList(chapters)
                    .tag(1)
            }

            libraryPage
                .tag(2)
        }
        .tabViewStyle(.page(indexDisplayMode: .always))
        .navigationTitle(navigationTitle)
        .toolbar {
            if page == 2, browsingFeed != nil {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Back", systemImage: "chevron.left") {
                        browsingFeed = nil
                        browsedEpisodes = []
                    }
                }
            }
            if page == 2 {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Shuffle", systemImage: "shuffle") { remote.shuffle() }
                }
            }
        }
        .task { remote.requestStateRefresh() }
    }

    private var navigationTitle: String {
        if page == 0 { return "Now Playing" }
        if page == 1 { return "Chapters" }
        return browsingFeed?.title ?? "On My iPhone"
    }

    @ViewBuilder
    private var libraryPage: some View {
        if let feed = browsingFeed {
            episodeList(feed)
        } else {
            root
        }
    }

    private var root: some View {
        List {
            Section("Library") {
                if !model.isConfigured {
                    Text("Add the server URL, including its secret token path, in Settings.")
                        .foregroundStyle(.secondary)
                } else if model.feeds.isEmpty {
                    Text("No feeds yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(model.feeds) { feed in
                        Button {
                            browsingFeed = feed
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
        }
        .overlay { if model.isLoading { ProgressView() } }
    }

    private func episodeList(_ feed: WatchFeed) -> some View {
        List(browsedEpisodes) { episode in
            Button {
                remote.playEpisode(episode)
                page = 0
            } label: {
                VStack(alignment: .leading) {
                    Text(episode.title ?? "Untitled episode").lineLimit(2)
                    Text(WatchFormatters.time(episode.duration_seconds ?? 0))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .overlay { if isLoadingEpisodes { ProgressView() } }
    }

    private func remoteChapterList(_ chapters: [RemoteChapter]) -> some View {
        List {
            ForEach(Array(chapters.enumerated()), id: \.element.id) { index, chapter in
                Button {
                    remote.seek(to: chapter.start)
                    page = 0
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(chapter.title ?? "Chapter \(index + 1)")
                            .lineLimit(2)
                        Text(WatchFormatters.time(chapter.start))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if !remote.isReachable {
                Text("iPhone not reachable")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }
}
