import SwiftUI

struct ContentView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerModel.self) private var player
    @Environment(AppNavigation.self) private var navigation
    @Environment(\.scenePhase) private var scenePhase
    @State private var wasBackgrounded = false

    var body: some View {
        @Bindable var navigation = navigation

        LibraryView()
            .sheet(item: $navigation.presentedSheet, onDismiss: navigation.sheetDidDismiss) { sheet in
                switch sheet {
                case .player:
                    PlayerView()
                        .presentationDetents([.large])
                        .presentationDragIndicator(.hidden)
                case .settings:
                    SettingsView()
                }
            }
            .onChange(of: player.loadGeneration) {
                navigation.showPlayer()
            }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .active:
                    if wasBackgrounded, player.hasEpisode {
                        navigation.showPlayer()
                    }
                    wasBackgrounded = false
                case .background:
                    wasBackgrounded = true
                case .inactive:
                    break
                @unknown default:
                    break
                }
            }
            .task { await library.refreshAll() }
    }
}
