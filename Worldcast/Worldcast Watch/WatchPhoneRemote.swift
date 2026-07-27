import Foundation
import Observation
import SwiftUI

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

/// "On My iPhone": mirrors the Podcasts app's remote-control screen. Shows
/// live transport controls for whatever the phone is already playing, plus
/// the same feed/episode library the phone's own LibraryView shows — so an
/// episode can be picked here and streaming starts on the iPhone, not the
/// watch. This never touches WatchLibrary's `selectedFeed`/`episodes`
/// (those drive the watch's own standalone playback below); it keeps its
/// own local browsing state instead.
struct PhoneRemoteView: View {
    @Environment(WatchLibrary.self) private var model
    @Environment(PhoneRemote.self) private var remote
    @State private var browsingFeed: WatchFeed?
    @State private var browsedEpisodes: [WatchEpisode] = []
    @State private var isLoadingEpisodes = false

    var body: some View {
        Group {
            if let feed = browsingFeed {
                episodeList(feed)
            } else {
                root
            }
        }
        .navigationTitle(browsingFeed?.title ?? "On My iPhone")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if let feed = browsingFeed {
                    Button("Back", systemImage: "chevron.left") {
                        browsingFeed = nil
                        browsedEpisodes = []
                    }
                } else {
                    Button("Shuffle", systemImage: "shuffle") { remote.shuffle() }
                }
            }
        }
        .task { remote.requestStateRefresh() }
    }

    private var root: some View {
        List {
            if let np = remote.nowPlaying {
                Section { nowPlayingBody(np) }
            } else if !remote.hasReceivedSnapshot {
                Section { ProgressView() }
            }
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

    private func nowPlayingBody(_ np: RemoteNowPlaying) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(spacing: 6) {
                if let url = np.artworkURL {
                    AsyncImage(url: url) { image in
                        image.resizable().aspectRatio(contentMode: .fit)
                    } placeholder: {
                        Color.clear
                    }
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                Text(np.chapterTitle ?? np.title).font(.headline).lineLimit(2)
                Text(np.feedTitle).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                Text(WatchFormatters.time(np.extrapolatedPosition(at: context.date))
                     + " / " + WatchFormatters.time(np.duration))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Back 15", systemImage: "gobackward.15") { remote.seekBy(-15) }
                    Button(np.rate > 0 ? "Pause" : "Play",
                           systemImage: np.rate > 0 ? "pause.fill" : "play.fill") {
                        remote.toggle()
                    }
                    Button("Forward 30", systemImage: "goforward.30") { remote.seekBy(30) }
                }
                .buttonStyle(.bordered)
                .labelStyle(.iconOnly)

                if !remote.isReachable {
                    Text("iPhone not reachable").font(.caption2).foregroundStyle(.orange)
                }
            }
            .padding(.horizontal)
        }
    }
}
