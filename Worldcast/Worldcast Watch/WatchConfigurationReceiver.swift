import Foundation
import WatchConnectivity

final class WatchConfigurationReceiver: NSObject, WCSessionDelegate, @unchecked Sendable {
    static let shared = WatchConfigurationReceiver()

    static let serverURLContextKey = "worldcast.serverBaseURL"
    static let nowPlayingContextKey = "worldcast.nowPlaying"

    var onServerURL: (@MainActor @Sendable (String) -> Void)?
    /// Fired on every application-context push, even when the phone has
    /// nothing playing (nil), so the remote view can distinguish "nothing
    /// playing" from "haven't heard from the phone yet".
    var onNowPlaying: (@MainActor @Sendable ([String: Any]?) -> Void)?
    var onReachabilityChanged: (@MainActor @Sendable (Bool) -> Void)?
    private var hasStarted = false

    private override init() {}

    func start() {
        guard WCSession.isSupported() else { return }
        if !hasStarted {
            hasStarted = true
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
        receive(WCSession.default.receivedApplicationContext)
    }

    var isReachable: Bool {
        WCSession.isSupported() && WCSession.default.isReachable
    }

    /// Send a live transport command to the phone (play/pause/seek/…). Silently
    /// drops if unreachable — callers should gate on `isReachable` for UI, but
    /// this stays best-effort so a race never crashes.
    func sendCommand(_ cmd: String, _ extra: [String: Any] = [:]) {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated,
              WCSession.default.isReachable else { return }
        var message = extra
        message["cmd"] = cmd
        WCSession.default.sendMessage(message, replyHandler: nil) { error in
            NSLog("Worldcast watch command '%@' failed: %@", cmd, error.localizedDescription)
        }
    }

    func sendCommandAwaitingReply(_ cmd: String, _ extra: [String: Any] = [:]) async -> Bool {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated,
              WCSession.default.isReachable else { return false }
        var message = extra
        message["cmd"] = cmd
        return await withCheckedContinuation { continuation in
            WCSession.default.sendMessage(message) { reply in
                continuation.resume(returning: reply["ok"] as? Bool == true)
            } errorHandler: { error in
                NSLog("Worldcast watch command '%@' failed: %@", cmd, error.localizedDescription)
                continuation.resume(returning: false)
            }
        }
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {
        guard activationState == .activated else { return }
        receive(session.receivedApplicationContext)
        let reachable = session.isReachable
        Task { @MainActor [weak self] in
            self?.onReachabilityChanged?(reachable)
            if reachable { self?.sendCommand("requestState") }
        }
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        receive(applicationContext)
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor [weak self] in
            self?.onReachabilityChanged?(reachable)
            if reachable { self?.sendCommand("requestState") }
        }
    }

    private func receive(_ context: [String: Any]) {
        if let serverURL = context[Self.serverURLContextKey] as? String {
            Task { @MainActor [weak self] in self?.onServerURL?(serverURL) }
        }
        let nowPlaying = context[Self.nowPlayingContextKey] as? [String: Any]
        Task { @MainActor [weak self] in self?.onNowPlaying?(nowPlaying) }
    }
}
