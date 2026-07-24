import Foundation
import WatchConnectivity

/// Transfers the configured server URL to a paired watch after the user opts
/// in. The URL contains the path-based bearer token, so this never syncs by
/// default.
final class WatchConfigurationSync: NSObject, WCSessionDelegate {
    static let shared = WatchConfigurationSync()

    static let enabledKey = "worldcast.syncServerToWatch"
    static let serverURLContextKey = "worldcast.serverBaseURL"

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
        guard WCSession.isSupported() else { return }
        do {
            try WCSession.default.updateApplicationContext([
                Self.serverURLContextKey: serverURL ?? ""
            ])
        } catch {
            NSLog("Could not sync Worldcast server URL to Apple Watch: %@", error.localizedDescription)
        }
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
