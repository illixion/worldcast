import AVKit
import SwiftUI
import UIKit

// Full "Now Playing" screen: ambient artwork glow, chapter-aware title,
// scrub bar with chapter tick marks, transport controls, chapter list.
// Video episodes swap the artwork for the AVPlayer video surface.

struct PlayerView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerModel.self) private var player

    @State private var showDetails = false
    @State private var glowImage: UIImage?

    var body: some View {
        if let ep = player.episode {
            content(ep)
        } else {
            ContentUnavailableView("Nothing playing",
                                   systemImage: "play.circle",
                                   description: Text("Pick an episode from the library."))
        }
    }

    @ViewBuilder
    private func content(_ ep: StoredEpisode) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 18) {
                    artworkArea(ep)
                        .padding(.top, 12)

                    VStack(spacing: 5) {
                        Button {
                            showDetails = true
                        } label: {
                            Text(player.currentChapter?.title ?? ep.displayTitle)
                                .font(.title3.weight(.semibold))
                                .multilineTextAlignment(.center)
                                .foregroundStyle(.primary)
                        }
                        .buttonStyle(.plain)
                        Text(chapterMeta(ep))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal)

                    if !player.chapters.isEmpty {
                        chapterList
                    }
                }
                .padding(.bottom, 12)
            }

            dock
        }
        // Ambient color wash from the current artwork. Lives in .background
        // so its .fill overflow can't inflate the layout width (a ZStack
        // sibling would stretch the whole view past the screen edge).
        .background {
            if !ep.isVideo, let glowImage {
                Image(uiImage: glowImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .blur(radius: 80)
                    .opacity(0.45)
                    .ignoresSafeArea()
            }
        }
        .task(id: player.currentArtworkURL) {
            guard let url = player.currentArtworkURL else { glowImage = nil; return }
            glowImage = await ImageCache.shared.image(for: url)
        }
        .sheet(isPresented: $showDetails) {
            NavigationStack {
                EpisodeDetailView(episodeId: ep.id)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { showDetails = false }
                        }
                    }
            }
        }
    }

    @ViewBuilder
    private func artworkArea(_ ep: StoredEpisode) -> some View {
        Group {
            if ep.isVideo {
                VideoPlayer(player: player.player)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else {
                ArtworkView(url: player.currentArtworkURL, cornerRadius: 20)
                    .aspectRatio(1, contentMode: .fit)
                    .shadow(color: .black.opacity(0.35), radius: 22, y: 10)
                    .animation(.easeInOut(duration: 0.3), value: player.currentChapterIndex)
            }
        }
        .frame(maxWidth: 340)
        .padding(.horizontal, 24)
    }

    private func chapterMeta(_ ep: StoredEpisode) -> String {
        if player.currentChapterIndex >= 0 && !player.chapters.isEmpty {
            return "ch \(player.currentChapterIndex + 1)/\(player.chapters.count) · \(player.feedTitle)"
        }
        return player.feedTitle
    }

    private var chapterList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Chapters")
                .font(.headline)
                .padding(.horizontal)
            VStack(spacing: 0) {
                ForEach(Array(player.chapters.enumerated()), id: \.element.id) { i, ch in
                    Button {
                        player.seek(to: ch.startSeconds)
                    } label: {
                        HStack(spacing: 10) {
                            ArtworkView(url: library.resolveURL(ch.artworkURL)
                                        ?? player.episodeArtworkURL,
                                        cornerRadius: 6)
                                .frame(width: 40, height: 40)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(ch.title ?? "Chapter \(i + 1)")
                                    .font(.subheadline)
                                    .lineLimit(2)
                                    .foregroundStyle(.primary)
                                Text(Formatters.time(ch.startSeconds))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if i == player.currentChapterIndex {
                                Image(systemName: "waveform")
                                    .foregroundStyle(Color.accentColor)
                                    .symbolEffect(.variableColor.iterative,
                                                  isActive: player.isPlaying)
                            }
                        }
                        .padding(.vertical, 7)
                        .padding(.horizontal)
                        .background(i == player.currentChapterIndex
                                    ? Color.accentColor.opacity(0.12) : .clear)
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal)
        }
    }

    // MARK: transport dock

    private var dock: some View {
        VStack(spacing: 10) {
            ScrubBar()
            // Times at the edges; the speed menu is overlaid so it stays
            // geometrically centered regardless of the labels' widths.
            HStack {
                Text(Formatters.time(player.isScrubbing ? player.scrubTime : player.currentTime))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Text(Formatters.time(player.effectiveDuration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .overlay { SpeedMenu() }

            HStack(spacing: 26) {
                Button { player.jumpChapter(-1) } label: {
                    Image(systemName: "backward.end.fill").font(.title3)
                }
                Button { player.seekBy(-15) } label: {
                    Image(systemName: "15.arrow.trianglehead.counterclockwise").font(.title2)
                }
                Button { player.toggle() } label: {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 62))
                        .symbolRenderingMode(.hierarchical)
                }
                Button { player.seekBy(30) } label: {
                    Image(systemName: "30.arrow.trianglehead.clockwise").font(.title2)
                }
                Button { player.jumpChapter(+1) } label: {
                    Image(systemName: "forward.end.fill").font(.title3)
                }
            }
            .foregroundStyle(.primary)
            .padding(.bottom, 4)
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(.ultraThinMaterial)
    }
}

/// Playback-speed dropdown. Its own view on purpose: the dock re-renders on
/// every 0.5s playback tick, and an open Menu that gets rebuilt each tick
/// visibly flickers. This body only reads `playbackRate`, so @Observable
/// tracking leaves the menu alone while time advances.
struct SpeedMenu: View {
    @Environment(PlayerModel.self) private var player

    var body: some View {
        Menu {
            Picker("Playback speed", selection: Binding(
                get: { player.playbackRate },
                set: { player.setSpeed($0) }
            )) {
                ForEach(PlayerModel.speedSteps.sorted(), id: \.self) { rate in
                    Text(Formatters.speed(rate)).tag(rate)
                }
            }
        } label: {
            Text(Formatters.speed(player.playbackRate))
                .font(.caption.weight(.bold).monospacedDigit())
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(.quaternary, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Tap/drag-to-seek scrub bar with chapter boundary tick marks — the native
/// port of the web player's #scrubBar.
struct ScrubBar: View {
    @Environment(PlayerModel.self) private var player

    var body: some View {
        GeometryReader { geo in
            let dur = player.effectiveDuration
            let time = player.isScrubbing ? player.scrubTime : player.currentTime
            let frac = dur > 0 ? min(1, max(0, time / dur)) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(.secondary.opacity(0.3))
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: max(6, geo.size.width * frac))
                if dur > 0 && player.chapters.count > 1 {
                    ForEach(player.chapters.dropFirst()) { ch in
                        let x = geo.size.width * (ch.startSeconds / dur)
                        if x > 0 && x < geo.size.width {
                            Rectangle()
                                .fill(.primary.opacity(0.5))
                                .frame(width: 1.5, height: 8)
                                .offset(x: x)
                        }
                    }
                }
            }
            .frame(height: 8)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        guard dur > 0 else { return }
                        player.isScrubbing = true
                        player.scrubTime = dur * min(1, max(0, g.location.x / geo.size.width))
                    }
                    .onEnded { _ in
                        let t = player.scrubTime
                        player.isScrubbing = false
                        player.seek(to: t)
                    }
            )
        }
        .frame(height: 26)
    }
}
