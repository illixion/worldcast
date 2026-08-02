import Observation

@MainActor
final class AppServices {
    static let shared = AppServices()

    let library: LibraryStore
    let player: PlayerModel
    let downloads: DownloadManager
    let navigation = AppNavigation()

    private init() {
        let library = LibraryStore()
        let player = PlayerModel()
        let downloads = DownloadManager()

        player.library = library
        downloads.library = library
        WatchConfigurationSync.shared.player = player
        WatchConfigurationSync.shared.library = library
        WatchConfigurationSync.shared.start()
        WatchConfigurationSync.shared.syncIfEnabled()

        self.library = library
        self.player = player
        self.downloads = downloads

        Task { await player.restoreLastEpisode() }
    }
}

@Observable
@MainActor
final class AppNavigation {
    enum Sheet: String, Identifiable {
        case player
        case settings

        var id: String { rawValue }
    }

    var presentedSheet: Sheet?
    private var presentPlayerAfterDismissal = false

    func showPlayer() {
        if presentedSheet == .settings {
            presentPlayerAfterDismissal = true
        } else {
            presentedSheet = .player
        }
    }

    func showSettings() {
        presentedSheet = .settings
    }

    func sheetDidDismiss() {
        guard presentPlayerAfterDismissal else { return }
        presentPlayerAfterDismissal = false
        presentedSheet = .player
    }
}
