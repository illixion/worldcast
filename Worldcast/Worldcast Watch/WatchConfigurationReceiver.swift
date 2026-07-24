import Foundation
import WatchConnectivity

final class WatchConfigurationReceiver: NSObject, WCSessionDelegate, @unchecked Sendable {
    static let shared = WatchConfigurationReceiver()

    static let serverURLContextKey = "worldcast.serverBaseURL"

    var onServerURL: (@MainActor @Sendable (String) -> Void)?

    private override init() {}

    func start() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
        receive(WCSession.default.receivedApplicationContext)
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {
        guard activationState == .activated else { return }
        receive(session.receivedApplicationContext)
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        receive(applicationContext)
    }

    private func receive(_ context: [String: Any]) {
        guard let serverURL = context[Self.serverURLContextKey] as? String else { return }
        Task { @MainActor [weak self] in
            self?.onServerURL?(serverURL)
        }
    }
}
