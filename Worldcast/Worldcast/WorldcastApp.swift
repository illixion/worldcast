import SwiftUI
import UIKit

@main
struct WorldcastApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var library: LibraryStore
    @State private var player: PlayerModel
    @State private var downloads: DownloadManager

    init() {
        let library = LibraryStore()
        let player = PlayerModel()
        let downloads = DownloadManager()
        player.library = library
        downloads.library = library
        _library = State(initialValue: library)
        _player = State(initialValue: player)
        _downloads = State(initialValue: downloads)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(library)
                .environment(player)
                .environment(downloads)
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
