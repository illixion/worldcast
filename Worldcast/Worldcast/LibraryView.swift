import SwiftUI

// "Home" tab: recently played (collapsed 3 / expanded 20, like the web UI),
// feed list with unplayed badges, swipe-to-unsubscribe. Pull-to-refresh
// triggers a server sync; adding feeds lives in the "Add" tab.

struct LibraryView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerModel.self) private var player
    @Environment(\.scenePhase) private var scenePhase

    @State private var recentExpanded = false
    @State private var feedPendingDelete: StoredFeed?

    private let recentCollapsed = 3
    private let recentExpandedCount = 20

    var body: some View {
        NavigationStack {
            List {
                if let msg = player.statusMessage ?? library.lastError {
                    Section {
                        Text(msg).font(.footnote).foregroundStyle(.secondary)
                    }
                }

                let recent = library.recentEpisodes(
                    limit: recentExpanded ? recentExpandedCount : recentCollapsed + 1)
                if !recent.isEmpty {
                    Section {
                        ForEach(recent.prefix(recentExpanded ? recentExpandedCount : recentCollapsed)) { ep in
                            NavigationLink(value: ep.id) {
                                EpisodeRow(episode: ep, showArtwork: true, showFeedTitle: true)
                            }
                        }
                        if recent.count > recentCollapsed || recentExpanded {
                            Button(recentExpanded ? "Show less" : "Show all") {
                                withAnimation { recentExpanded.toggle() }
                            }
                            .font(.footnote)
                        }
                    } header: {
                        Text("Recently played")
                    }
                }

                Section {
                    if library.sortedFeeds.isEmpty {
                        Text("No feeds yet. Add one from the Add tab.")
                            .foregroundStyle(.secondary)
                            .font(.subheadline)
                    }
                    ForEach(library.sortedFeeds) { feed in
                        NavigationLink(value: feed.id) {
                            FeedRow(feed: feed)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                feedPendingDelete = feed
                            } label: {
                                Label("Unsubscribe", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("Feeds")
                        Spacer()
                        if library.isRefreshing {
                            ProgressView().controlSize(.mini)
                        } else if !library.syncStatusText.isEmpty {
                            Text(library.syncStatusText).textCase(nil)
                        }
                    }
                }
            }
            .navigationTitle("Worldcast")
            .navigationDestination(for: UUID.self) { id in
                if library.feed(id: id) != nil {
                    EpisodesView(feedId: id)
                } else if library.episode(id: id) != nil {
                    EpisodeDetailView(episodeId: id)
                }
            }
            .refreshable { await library.refreshAll(triggerServerSync: true) }
            // Lives here (not the app-wide bottom accessory) so it has a
            // constant height of its own and never fights the mini player
            // accessory's enable/disable-only sizing — see ContentView.
            .safeAreaInset(edge: .bottom) {
                ShuffleButton()
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }
        }
        .task { await pollLoop() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await library.refreshAll() }
            }
        }
        .confirmationDialog(
            "Unsubscribe from \(feedPendingDelete?.displayTitle ?? "")?",
            isPresented: .init(get: { feedPendingDelete != nil },
                               set: { if !$0 { feedPendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Unsubscribe", role: .destructive) {
                if let f = feedPendingDelete { library.removeFeed(f) }
                feedPendingDelete = nil
            }
        } message: {
            Text("Removes the feed, its episodes and any downloads.")
        }
    }

    /// Foreground poll: sync status + library refresh, mirroring the web
    /// app's 15s visible-tab poll (server state changes hourly server-side;
    /// standalone mode just refreshes status text).
    private func pollLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(15))
            guard scenePhase == .active else { continue }
            await library.updateBackendStatusText()
        }
    }
}

/// Big always-visible shuffle affordance pinned above the Home list.
struct ShuffleButton: View {
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

struct FeedRow: View {
    @Environment(LibraryStore.self) private var library
    let feed: StoredFeed

    var body: some View {
        let counts = library.episodeCounts(feedId: feed.id)
        HStack(spacing: 12) {
            ArtworkView(url: library.resolveURL(feed.artworkURL), cornerRadius: 10)
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 3) {
                Text(feed.displayTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Text(counts.unplayed > 0
                     ? "\(counts.total) episodes · \(counts.unplayed) new"
                     : "\(counts.total) episodes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if counts.unplayed > 0 {
                Text("\(counts.unplayed)")
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.accentColor, in: Capsule())
                    .foregroundStyle(.white)
            }
        }
    }
}
