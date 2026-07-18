import SwiftUI

// Episode list for one feed, newest first — the web app's episodes view.

struct EpisodesView: View {
    @Environment(LibraryStore.self) private var library
    let feedId: UUID

    var body: some View {
        List {
            if let feed = library.feed(id: feedId) {
                Section {
                    HStack(alignment: .top, spacing: 14) {
                        ArtworkView(url: library.resolveURL(feed.artworkURL), cornerRadius: 12)
                            .frame(width: 84, height: 84)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(feed.displayTitle)
                                .font(.headline)
                            let counts = library.episodeCounts(feedId: feed.id)
                            Text([feed.author, "\(counts.total) episodes"]
                                .compactMap { $0 }.joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .listRowSeparator(.hidden)
                }
            }

            Section {
                ForEach(library.episodes(inFeed: feedId)) { ep in
                    if ep.isUnavailable {
                        EpisodeRow(episode: ep)
                    } else {
                        NavigationLink(value: ep.id) {
                            EpisodeRow(episode: ep)
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(library.feed(id: feedId)?.displayTitle ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await library.refreshAll() }
    }
}
