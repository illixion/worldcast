import SwiftUI

// Small shared UI pieces.

// Artwork loads through ImageCache (memory → disk → network) so everything
// seen once keeps rendering offline. The image is drawn in an .overlay of a
// Color, which can't inflate the layout — a .fill image as a direct child
// would (see the PlayerView glow bug).
struct ArtworkView: View {
    let url: URL?
    var cornerRadius: CGFloat = 8

    @State private var image: UIImage?

    var body: some View {
        Color(.quaternarySystemFill)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "waveform")
                        .foregroundStyle(.secondary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .task(id: url) {
                guard let url else { image = nil; return }
                image = await ImageCache.shared.image(for: url)
            }
    }
}

struct TagLabel: View {
    let text: String
    var color: Color = .secondary

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 5).padding(.vertical, 1.5)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}

/// Episode row used by the feed list, recent list and search-ish contexts.
struct EpisodeRow: View {
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerModel.self) private var player
    @Environment(DownloadManager.self) private var downloads

    let episode: StoredEpisode
    var showArtwork = false
    var showFeedTitle = false

    var body: some View {
        HStack(spacing: 12) {
            if showArtwork {
                ArtworkView(url: library.resolveURL(
                    episode.artworkURL ?? library.feed(id: episode.feedId)?.artworkURL))
                    .frame(width: 52, height: 52)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(episode.displayTitle)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(2)
                        .foregroundStyle(episode.isUnavailable ? .secondary : .primary)
                    if episode.isUnavailable { TagLabel(text: "missing", color: .orange) }
                    if episode.isVideo { TagLabel(text: "video", color: .purple) }
                    if episode.knownChapterCount > 0 {
                        TagLabel(text: "\(episode.knownChapterCount) ch", color: .teal)
                    }
                    if episode.isDownloaded {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.caption2).foregroundStyle(.green)
                    }
                }
                Text(metaText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let frac = episode.progressFraction {
                    ProgressView(value: frac)
                        .progressViewStyle(.linear)
                        .tint(.accentColor)
                        .scaleEffect(y: 0.6)
                }
                if case .downloading(let p) = downloads.state(for: episode.id) {
                    ProgressView(value: p)
                        .progressViewStyle(.linear)
                        .tint(.green)
                        .scaleEffect(y: 0.6)
                }
            }
            Spacer(minLength: 4)
            if !episode.isUnavailable {
                Button {
                    Task { await player.load(episodeId: episode.id) }
                } label: {
                    Image(systemName: "play.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.borderless)
            }
            if episode.played {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
        }
        .opacity(episode.played ? 0.55 : 1)
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                library.markPlayed(episode, played: !episode.played)
            } label: {
                Label(episode.played ? "Mark Unplayed" : "Mark Played",
                      systemImage: episode.played ? "circle" : "checkmark.circle")
            }
            .tint(episode.played ? .gray : .green)
        }
        .swipeActions(edge: .trailing) {
            downloadSwipeButton
        }
    }

    @ViewBuilder
    private var downloadSwipeButton: some View {
        if episode.isDownloaded {
            Button(role: .destructive) {
                downloads.removeDownload(for: episode)
            } label: {
                Label("Remove Download", systemImage: "trash")
            }
        } else if case .downloading = downloads.state(for: episode.id) {
            Button {
                downloads.cancelDownload(for: episode.id)
            } label: {
                Label("Cancel", systemImage: "xmark.circle")
            }
        } else if let url = library.resolveURL(episode.audioURL), !episode.isUnavailable {
            Button {
                downloads.startDownload(for: episode, url: url)
            } label: {
                Label("Download", systemImage: "arrow.down.circle")
            }
            .tint(.blue)
        }
    }

    private var metaText: String {
        var parts: [String] = []
        if showFeedTitle, let f = library.feed(id: episode.feedId)?.displayTitle, !f.isEmpty {
            parts.append(f)
        }
        let d = Formatters.date(ms: episode.pubDateMs)
        if !d.isEmpty { parts.append(d) }
        if let dur = episode.durationSeconds, dur > 0 { parts.append(Formatters.time(dur)) }
        return parts.joined(separator: " · ")
    }
}
