@MainActor
final class AppServices {
    static let shared = AppServices()

    let library: LibraryStore
    let player: PlayerModel
    let downloads: DownloadManager

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
