import Foundation
import Observation
import SwiftUI
import WatchKit

enum PlaybackSource: String, CaseIterable, Identifiable {
    case watch
    case phone

    var id: String { rawValue }
    var title: String { self == .watch ? "Apple Watch" : "iPhone" }
    var symbol: String { self == .watch ? "applewatch" : "iphone" }
}

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
    let serverId: Int?
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
        serverId = (dict["serverId"] as? NSNumber)?.intValue
            ?? dict["serverId"] as? Int
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

    func chapterIndex(at date: Date = Date()) -> Int {
        let position = extrapolatedPosition(at: date)
        var result = -1
        for (index, chapter) in chapters.enumerated() {
            if position >= chapter.start {
                result = index
            } else {
                break
            }
        }
        return result
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
    func playEpisode(_ episode: WatchEpisode, position: Double? = nil) {
        playEpisode(serverId: episode.id, position: position)
    }

    func playEpisode(serverId: Int, position: Double? = nil) {
        var payload: [String: Any] = ["episodeId": serverId]
        if let position { payload["position"] = position }
        WatchConfigurationReceiver.shared.sendCommand("playEpisode", payload)
    }

    func pauseAwaitingReply() async -> Bool {
        await WatchConfigurationReceiver.shared.sendCommandAwaitingReply("pause")
    }

    func playAwaitingReply() async -> Bool {
        await WatchConfigurationReceiver.shared.sendCommandAwaitingReply("play")
    }

    func playEpisodeAwaitingReply(serverId: Int, position: Double? = nil) async -> Bool {
        var payload: [String: Any] = ["episodeId": serverId]
        if let position { payload["position"] = position }
        return await WatchConfigurationReceiver.shared.sendCommandAwaitingReply(
            "playEpisode",
            payload
        )
    }

    /// Tell the phone to play a random never-played episode, mirroring the
    /// main app's library shuffle button.
    func shuffle() {
        WatchConfigurationReceiver.shared.sendCommand("shuffle")
    }
}

struct PhoneRemoteView: View {
    var initialPage = 0

    var body: some View {
        WatchPlaybackPager(initialSource: .phone, initialPage: initialPage)
    }
}
