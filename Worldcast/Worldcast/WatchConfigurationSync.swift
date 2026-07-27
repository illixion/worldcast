import Foundation
import WatchConnectivity

/// Transfers the configured server URL to a paired watch after the user opts
/// in (the URL contains the path-based bearer token, so this never syncs by
/// default), and doubles as the phone-side half of the watch's "On My
/// iPhone" remote control: it publishes now-playing snapshots via
/// application context (so the watch has a last-known state even when not
/// reachable) and handles transport commands the watch sends live.
final class WatchConfigurationSync: NSObject, WCSessionDelegate {
    static let shared = WatchConfigurationSync()

    static let enabledKey = "worldcast.syncServerToWatch"
    static let serverURLContextKey = "worldcast.serverBaseURL"
    static let nowPlayingContextKey = "worldcast.nowPlaying"

    /// Set once from WorldcastApp's init. Weak: the session outlives them.
    weak var player: PlayerModel?
    weak var library: LibraryStore?

    private override init() {}

    func start() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func syncIfEnabled() {
        guard UserDefaults.standard.bool(forKey: Self.enabledKey) else { return }
        sendServerURL(BackendAPI.configuredBaseString)
    }

    func sendServerURL(_ serverURL: String?) {
        updateContext { $0[Self.serverURLContextKey] = serverURL ?? "" }
    }

    // MARK: - Now Playing snapshot (phone → watch)

    /// Called by PlayerModel every time it (re-)publishes its own Now Playing
    /// info, so the watch's remote view stays in lockstep with the lock
    /// screen without any polling.
    func refreshNowPlaying(episodeId: String, title: String, feedTitle: String,
                            chapterTitle: String?, artworkURL: URL?,
                            position: Double, duration: Double, rate: Double) {
        var info: [String: Any] = [
            "episodeId": episodeId,
            "title": title,
            "feedTitle": feedTitle,
            "position": position,
            "duration": duration,
            "rate": rate,
            "publishedAt": Date().timeIntervalSince1970,
        ]
        if let chapterTitle { info["chapterTitle"] = chapterTitle }
        if let artworkURL { info["artworkURL"] = artworkURL.absoluteString }
        updateContext { $0[Self.nowPlayingContextKey] = info }
    }

    func clearNowPlaying() {
        updateContext { $0.removeValue(forKey: Self.nowPlayingContextKey) }
    }

    private func updateContext(_ mutate: (inout [String: Any]) -> Void) {
        guard WCSession.isSupported() else { return }
        var context = WCSession.default.applicationContext
        mutate(&context)
        do {
            try WCSession.default.updateApplicationContext(context)
        } catch {
            NSLog("Could not update Apple Watch application context: %@", error.localizedDescription)
        }
    }

    // MARK: - Transport commands (watch → phone)

    func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                 replyHandler: @escaping ([String: Any]) -> Void) {
        Task { @MainActor [weak self] in
            replyHandler(self?.handle(message: message) ?? ["ok": false])
        }
    }

    @MainActor
    @discardableResult
    private func handle(message: [String: Any]) -> [String: Any] {
        guard let player, let cmd = message["cmd"] as? String else { return ["ok": false] }
        switch cmd {
        case "play": player.play()
        case "pause": player.pause()
        case "toggle": player.toggle()
        case "seek":
            if let to = message["to"] as? Double { player.seek(to: to) }
        case "seekBy":
            if let delta = message["delta"] as? Double { player.seekBy(delta) }
        case "chapter":
            if let dir = message["dir"] as? Int { player.jumpChapter(dir) }
        case "requestState":
            player.republishNowPlaying()
        case "playEpisode":
            guard let serverId = message["episodeId"] as? Int,
                  let ep = library?.episode(serverId: serverId) else { return ["ok": false] }
            Task { await player.load(episodeId: ep.id) }
        case "shuffle":
            guard let ep = library?.randomNeverPlayed() else { return ["ok": false] }
            Task { await player.load(episodeId: ep.id) }
        default:
            return ["ok": false]
        }
        return ["ok": true]
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {
        if activationState == .activated { syncIfEnabled() }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
}
