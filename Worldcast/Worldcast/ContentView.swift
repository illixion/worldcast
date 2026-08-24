import SwiftUI

enum AppTab: Hashable {
    case home
    case addFeed
    case settings
}

struct ContentView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerModel.self) private var player
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab: AppTab = .home
    @State private var isPlayerPresented = false
    @State private var wasBackgrounded = false

    var body: some View {
        tabs
#if os(visionOS)
            // No tabViewBottomAccessory on visionOS (tabs live in the side
            // ornament) — float the mini player in a glass capsule instead.
            .safeAreaInset(edge: .bottom) {
                if player.hasEpisode {
                    MiniPlayerView()
                        .padding(.horizontal, 6)
                        .glassBackgroundEffect(in: .capsule)
                        .onTapGesture { isPlayerPresented = true }
                        .padding(.bottom, 12)
                }
            }
#else
            // isEnabled (rather than conditional content) is required here:
            // this accessory's content height must stay constant while
            // enabled, or the tab content's safe-area inset gets stale and
            // list rows scroll up underneath the (now taller) glass bar.
            // Toggling isEnabled is the transition the system actually
            // re-measures for. The Shuffle button lives in LibraryView's own
            // safeAreaInset instead of sharing this slot for that reason.
            .tabViewBottomAccessory(isEnabled: player.hasEpisode) {
                MiniPlayerView()
                    .onTapGesture { isPlayerPresented = true }
            }
#endif
            .onChange(of: player.loadGeneration) {
                // A new episode started (tap on play anywhere) — surface the
                // full player, like the web app's navigate('playerView') on load.
                isPlayerPresented = true
            }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .active:
                    if wasBackgrounded, player.hasEpisode {
                        isPlayerPresented = true
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
            .sheet(isPresented: $isPlayerPresented) {
                PlayerView()
                    .presentationDetents([.large])
                    .presentationDragIndicator(.hidden)
            }
            .task { await library.refreshAll() }
    }

    private var tabs: some View {
        TabView(selection: $selectedTab) {
            Tab("Home", systemImage: "house.fill", value: .home) {
                LibraryView()
            }
            Tab("Add", systemImage: "plus.circle.fill", value: .addFeed) {
                AddFeedView { selectedTab = .home }
            }
            Tab("Settings", systemImage: "gearshape.fill", value: .settings) {
                SettingsView()
            }
        }
#if !os(visionOS)
        .tabBarMinimizeBehavior(.onScrollDown)
#endif
    }
}

struct MiniPlayerView: View {
    @Environment(PlayerModel.self) private var player

    var body: some View {
        HStack(spacing: 10) {
            ArtworkView(url: player.currentArtworkURL, cornerRadius: 6)
                .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(player.currentChapter?.title
                     ?? player.episode?.displayTitle ?? "—")
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
                Text(player.feedTitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                player.toggle()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 4)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}
