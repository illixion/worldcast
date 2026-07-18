import SwiftUI

enum AppTab: Hashable {
    case library
    case nowPlaying
}

struct ContentView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerModel.self) private var player
    @State private var selectedTab: AppTab = .library

    var body: some View {
        // isEnabled (rather than conditional content) — an accessory with
        // empty content still renders a blank pill. Hidden on the Now Playing
        // tab: the full player has its own transport.
        tabs
            .tabViewBottomAccessory(isEnabled: player.hasEpisode && selectedTab != .nowPlaying) {
                MiniPlayerView()
                    .onTapGesture { selectedTab = .nowPlaying }
            }
            .onChange(of: player.loadGeneration) {
                // A new episode started (tap on play anywhere) — surface the
                // player, like the web app's navigate('playerView') on load.
                selectedTab = .nowPlaying
            }
            .task {
                await library.refreshAll()
            }
    }

    private var tabs: some View {
        TabView(selection: $selectedTab) {
            Tab("Library", systemImage: "square.stack.fill", value: .library) {
                LibraryView()
            }
            Tab("Now Playing", systemImage: "play.circle.fill", value: .nowPlaying) {
                PlayerView()
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
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
