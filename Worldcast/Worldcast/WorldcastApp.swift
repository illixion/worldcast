import SwiftUI
import UIKit

@main
struct WorldcastApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let services = AppServices.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(services.library)
                .environment(services.player)
                .environment(services.downloads)
                .environment(services.navigation)
                .environment(PlaybackSettings.shared)
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    // iOS relaunches the app when background downloads finish; hold the
    // completion handler until the URLSession delegate drains its events.
    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        if identifier == DownloadManager.sessionIdentifier {
            DownloadManager.backgroundCompletionHandler = completionHandler
        } else {
            completionHandler()
        }
    }
}
