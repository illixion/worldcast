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
            // ornament) — float the bar in a glass panel instead.
            .safeAreaInset(edge: .bottom) {
                bottomBar
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .glassBackgroundEffect(in: .rect(cornerRadius: 24))
                    .padding(.bottom, 12)
            }
#else
            .tabViewBottomAccessory(isEnabled: true) {
                bottomBar
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

    /// Always-visible shuffle affordance plus the mini "Now Playing" strip
    /// (only once something's loaded), stacked in one bottom accessory slot
    /// so they read as a single bar instead of two competing safe-area insets.
    private var bottomBar: some View {
        VStack(spacing: 10) {
            ShuffleButton()
            if player.hasEpisode {
                MiniPlayerView()
                    .contentShape(Rectangle())
                    .onTapGesture { isPlayerPresented = true }
            }
        }
    }
}

private struct ShuffleButton: View {
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerModel.self) private var player

    var body: some View {
        Button(action: playRandom) {
            Label("Shuffle", systemImage: "shuffle")
                .font(.headline)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }

    private func playRandom() {
        if let ep = library.randomNeverPlayed() {
            Task { await player.load(episodeId: ep.id) }
        } else {
            player.statusMessage = "No never-played episodes available."
        }
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
    }
}
