import SwiftUI

// Episode details: artwork header, play/download actions, HTML show notes.
// Mirrors the web details view including its privacy gate — remote <img>
// tags in descriptions are stripped unless the user opts in (the toggle
// persists, like worldcast.allowRemoteImages in the PWA).

struct EpisodeDetailView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerModel.self) private var player
    @Environment(DownloadManager.self) private var downloads
    @AppStorage("worldcast.allowRemoteImages") private var allowRemoteImages = false

    let episodeId: UUID
    @State private var description: AttributedString?

    var body: some View {
        ScrollView {
            if let ep = library.episode(id: episodeId) {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top, spacing: 14) {
                        ArtworkView(url: library.resolveURL(
                            ep.artworkURL ?? library.feed(id: ep.feedId)?.artworkURL),
                            cornerRadius: 12)
                            .frame(width: 96, height: 96)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(ep.displayTitle).font(.headline)
                            Text(metaText(ep))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            HStack(spacing: 5) {
                                if ep.isVideo { TagLabel(text: "video", color: .purple) }
                                if ep.knownChapterCount > 0 {
                                    TagLabel(text: "\(ep.knownChapterCount) chapters", color: .teal)
                                }
                                if ep.isDownloaded { TagLabel(text: "downloaded", color: .green) }
                            }
                        }
                    }

                    HStack(spacing: 10) {
                        Button {
                            Task { await player.load(episodeId: ep.id) }
                        } label: {
                            Label(ep.isUnavailable ? "Audio unavailable" : "Play",
                                  systemImage: "play.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(ep.isUnavailable)

                        downloadButton(ep)

                        Button {
                            library.markPlayed(ep, played: !ep.played)
                        } label: {
                            Image(systemName: ep.played ? "checkmark.circle.fill" : "checkmark.circle")
                        }
                        .buttonStyle(.bordered)
                    }

                    Toggle(isOn: $allowRemoteImages) {
                        Label("Remote images", systemImage: "photo")
                            .font(.footnote)
                    }
                    .toggleStyle(.switch)
                    .controlSize(.mini)

                    if let description {
                        Text(description)
                            .font(.callout)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text("No description.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: allowRemoteImages) { renderDescription() }
        .task {
            // Fetch chapters/details lazily so counts and show notes fill in.
            _ = await library.ensureChapters(for: episodeId)
            renderDescription()
        }
    }

    @ViewBuilder
    private func downloadButton(_ ep: StoredEpisode) -> some View {
        if case .downloading(let p) = downloads.state(for: ep.id) {
            Button {
                downloads.cancelDownload(for: ep.id)
            } label: {
                ProgressView(value: p)
                    .progressViewStyle(.circular)
                    .controlSize(.small)
            }
            .buttonStyle(.bordered)
        } else if ep.isDownloaded {
            Button(role: .destructive) {
                downloads.removeDownload(for: ep)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.bordered)
        } else if let url = library.resolveURL(ep.audioURL), !ep.isUnavailable {
            Button {
                downloads.startDownload(for: ep, url: url)
            } label: {
                Image(systemName: "arrow.down.circle")
            }
            .buttonStyle(.bordered)
        }
    }

    private func metaText(_ ep: StoredEpisode) -> String {
        var parts: [String] = []
        if let f = library.feed(id: ep.feedId)?.displayTitle { parts.append(f) }
        let d = Formatters.date(ms: ep.pubDateMs)
        if !d.isEmpty { parts.append(d) }
        if let dur = ep.durationSeconds, dur > 0 { parts.append(Formatters.time(dur)) }
        return parts.joined(separator: " · ")
    }

    private func renderDescription() {
        guard let raw = library.episode(id: episodeId)?.episodeDescription,
              !raw.isEmpty else {
            description = nil
            return
        }
        description = HTMLRenderer.attributedString(fromHTML: raw,
                                                    allowRemoteImages: allowRemoteImages)
    }
}

// Renders sanitized show-notes HTML into an AttributedString via the
// WebKit-backed NSAttributedString HTML importer (main-thread only), then
// re-fonts the result to match Dynamic Type while preserving bold/italic and
// link attributes.
enum HTMLRenderer {
    static func attributedString(fromHTML raw: String,
                                 allowRemoteImages: Bool) -> AttributedString? {
        var html = raw
        if !allowRemoteImages {
            // Privacy gate: never let the importer fetch remote <img> URLs.
            html = html.replacing(/<img[^>]*>/.ignoresCase(), with: " [image hidden] ")
        }
        guard let data = html.data(using: .utf8) else { return nil }
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue,
        ]
        guard let ns = try? NSMutableAttributedString(data: data, options: options,
                                                      documentAttributes: nil) else {
            return AttributedString(stripTags(raw))
        }
        let body = UIFont.preferredFont(forTextStyle: .callout)
        ns.enumerateAttribute(.font, in: NSRange(location: 0, length: ns.length)) { value, range, _ in
            guard let font = value as? UIFont else {
                ns.addAttribute(.font, value: body, range: range)
                return
            }
            let traits = font.fontDescriptor.symbolicTraits
            if let desc = body.fontDescriptor.withSymbolicTraits(traits) {
                ns.addAttribute(.font, value: UIFont(descriptor: desc, size: body.pointSize), range: range)
            } else {
                ns.addAttribute(.font, value: body, range: range)
            }
        }
        ns.removeAttribute(.foregroundColor, range: NSRange(location: 0, length: ns.length))
        var result = AttributedString(ns)
        // Trim the trailing newline the importer likes to append.
        while result.characters.last == "\n" {
            result.characters.removeLast()
        }
        return result
    }

    private static func stripTags(_ s: String) -> String {
        s.replacing(/<[^>]+>/, with: " ")
            .replacing("&amp;", with: "&")
            .replacing("&lt;", with: "<")
            .replacing("&gt;", with: ">")
            .replacing("&quot;", with: "\"")
            .replacing("&#39;", with: "'")
    }
}
