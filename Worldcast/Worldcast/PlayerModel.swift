import AVFoundation
import MediaPlayer
import Observation
import UIKit

// Playback engine. Ports the web Player class (public/app.js) to AVPlayer:
//  - chapter boundary crossings rewrite the Now Playing metadata (title +
//    artwork) so the lock screen swaps art at each chapter, matching the
//    MediaSession pattern in docs/example.html;
//  - position sync is quiet: pause / seek / background edges only, never
//    periodic (CLAUDE.md rule 7) — via LibraryStore.recordPosition(push:);
//  - auto-advance to the chronologically-next unplayed episode on end/error;
//  - playback speed cycling with persistence.

@Observable
final class PlayerModel {
    static let speedSteps: [Double] = [1, 1.25, 1.5, 1.75, 2, 0.75]
    private static let speedKey = "worldcast.playbackRate"

    private(set) var episode: StoredEpisode?
    private(set) var feedTitle: String = ""
    private(set) var chapters: [StoredChapter] = []
    private(set) var currentChapterIndex: Int = -1
    private(set) var isPlaying = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var playbackRate: Double
    var statusMessage: String?
    var isScrubbing = false
    var scrubTime: Double = 0
    /// Bumped when a new episode loads so the UI can present the player.
    private(set) var loadGeneration = 0

    let player = AVPlayer()
    weak var library: LibraryStore?

    private var timeObserverToken: Any?
    private var itemObservations: [NSKeyValueObservation] = []
    private var notificationTokens: [NSObjectProtocol] = []
    private var intendPlaying = false
    private var artworkFetchGeneration = 0

    init() {
        let saved = UserDefaults.standard.double(forKey: Self.speedKey)
        playbackRate = Self.speedSteps.contains(saved) ? saved : 1
        player.allowsExternalPlayback = true
        configureRemoteCommands()
        installTimeObserver()
        installLifecycleObservers()
    }

    var hasEpisode: Bool { episode != nil }

    var currentChapter: StoredChapter? {
        guard currentChapterIndex >= 0, currentChapterIndex < chapters.count else { return nil }
        return chapters[currentChapterIndex]
    }

    var effectiveDuration: Double {
        if duration > 0 { return duration }
        return episode?.durationSeconds ?? 0
    }

    // MARK: - Loading

    func load(episodeId: UUID, autoplay: Bool = true) async {
        guard let library else { return }
        statusMessage = nil
        // Chapters (backend ID3 or JSON) come with the detail fetch.
        guard let ep = await library.ensureChapters(for: episodeId) ?? library.episode(id: episodeId) else { return }
        guard let url = library.playbackURL(for: ep), ep.audioAvailable else {
            statusMessage = "“\(ep.displayTitle)” — audio unavailable"
            return
        }

        episode = ep
        feedTitle = library.feed(id: ep.feedId)?.displayTitle ?? ""
        chapters = ep.chapters.sorted { $0.startSeconds < $1.startSeconds }
        currentChapterIndex = -2 // force first applyChapter even for -1
        duration = ep.durationSeconds ?? 0
        loadGeneration += 1

        let item = AVPlayerItem(url: url)
        observe(item)
        player.replaceCurrentItem(with: item)
        player.defaultRate = Float(playbackRate)

        let startAt = ep.positionSeconds
        if startAt > 1 {
            await player.seek(to: CMTime(seconds: startAt, preferredTimescale: 1000),
                              toleranceBefore: .zero, toleranceAfter: .positiveInfinity)
        }
        currentTime = startAt
        applyChapter(chapterIndex(at: startAt))
        preloadChapterArtwork()
        if autoplay { play() }
        else { refreshNowPlayingInfo() }
    }

    // MARK: - Transport

    func play() {
        configureAudioSession()
        intendPlaying = true
        player.play()
        player.rate = Float(playbackRate)
        isPlaying = true
        refreshNowPlayingInfo()
    }

    func pause() {
        intendPlaying = false
        player.pause()
        isPlaying = false
        pushPosition()
        refreshNowPlayingInfo()
    }

    func toggle() { isPlaying ? pause() : play() }

    func seek(to seconds: Double) {
        let dur = effectiveDuration
        let target = max(0, dur > 0 ? min(seconds, dur) : seconds)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 1000),
                    toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = target
        applyChapter(chapterIndex(at: target))
        pushPosition(at: target)
        refreshNowPlayingInfo()
    }

    func seekBy(_ delta: Double) { seek(to: currentTime + delta) }

    /// Previous/next chapter; falls back to ±30s when the episode has no
    /// chapters — same as the web player.
    func jumpChapter(_ dir: Int) {
        guard !chapters.isEmpty else { seekBy(Double(dir) * 30); return }
        let cur = chapterIndex(at: currentTime)
        let next = max(0, min(chapters.count - 1, (cur < 0 ? 0 : cur) + dir))
        seek(to: chapters[next].startSeconds)
    }

    func setSpeed(_ rate: Double) {
        playbackRate = rate
        UserDefaults.standard.set(rate, forKey: Self.speedKey)
        player.defaultRate = Float(rate)
        if isPlaying { player.rate = Float(rate) }
        refreshNowPlayingInfo()
    }

    // MARK: - Chapters

    func chapterIndex(at seconds: Double) -> Int {
        var idx = -1
        for (i, ch) in chapters.enumerated() {
            if seconds >= ch.startSeconds { idx = i } else { break }
        }
        return idx
    }

    private func applyChapter(_ idx: Int) {
        guard idx != currentChapterIndex else { return }
        currentChapterIndex = idx
        refreshNowPlayingInfo()
        updateNowPlayingArtwork()
    }

    /// Artwork priority: current chapter's APIC/JSON image → episode → feed.
    var currentArtworkURL: URL? {
        library?.resolveURL(
            currentChapter?.artworkURL
            ?? episode?.artworkURL
            ?? episode.flatMap { library?.feed(id: $0.feedId)?.artworkURL })
    }

    var episodeArtworkURL: URL? {
        library?.resolveURL(
            episode?.artworkURL
            ?? episode.flatMap { library?.feed(id: $0.feedId)?.artworkURL })
    }

    private func preloadChapterArtwork() {
        let urls = chapters.compactMap { library?.resolveURL($0.artworkURL) }
        ImageCache.shared.prefetch(urls)
    }

    // MARK: - Now Playing (lock screen)

    private func refreshNowPlayingInfo() {
        guard let ep = episode else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPMediaItemPropertyTitle] = currentChapter?.title ?? ep.displayTitle
        info[MPMediaItemPropertyArtist] = feedTitle
        info[MPMediaItemPropertyAlbumTitle] = ep.displayTitle
        info[MPMediaItemPropertyPlaybackDuration] = effectiveDuration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? playbackRate : 0
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = playbackRate
        info[MPNowPlayingInfoPropertyMediaType] = ep.isVideo
            ? MPNowPlayingInfoMediaType.video.rawValue
            : MPNowPlayingInfoMediaType.audio.rawValue
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func updateNowPlayingArtwork() {
        guard let url = currentArtworkURL else { return }
        artworkFetchGeneration += 1
        let generation = artworkFetchGeneration
        Task { [weak self] in
            guard let image = await ImageCache.shared.image(for: url),
                  let self, generation == self.artworkFetchGeneration else { return }
            var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
            info[MPMediaItemPropertyArtwork] =
                MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }
    }

    // MARK: - Position sync (quiet contract)

    private func pushPosition(at position: Double? = nil) {
        guard let ep = episode else { return }
        library?.recordPosition(episodeId: ep.id,
                                position: position ?? currentTime,
                                push: true)
    }

    // MARK: - End / error / auto-advance

    private func onEnded() {
        guard let ep = episode else { return }
        library?.markPlayed(ep, played: true)
        advance(from: ep)
    }

    private func onItemFailed(_ message: String?) {
        guard let ep = episode else { return }
        statusMessage = message ?? "Playback failed"
        advance(from: ep)
    }

    private func advance(from ep: StoredEpisode) {
        if let next = library?.nextEpisode(after: ep) {
            Task { await self.load(episodeId: next.id) }
        } else {
            intendPlaying = false
            player.pause()
            isPlaying = false
            statusMessage = "No newer unplayed episode in this feed."
            refreshNowPlayingInfo()
        }
    }

    // MARK: - Observation plumbing

    private func installTimeObserver() {
        let interval = CMTime(seconds: 0.5, preferredTimescale: 10)
        timeObserverToken = player.addPeriodicTimeObserver(
            forInterval: interval, queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time.seconds) }
        }
    }

    private func tick(_ seconds: Double) {
        guard episode != nil, seconds.isFinite else { return }
        if !isScrubbing { currentTime = seconds }
        if let d = player.currentItem?.duration.seconds, d.isFinite, d > 0 { duration = d }
        let idx = chapterIndex(at: seconds)
        if idx != currentChapterIndex { applyChapter(idx) }
        // Keep the store's in-memory position current (no network — the push
        // flag stays false so the quiet contract holds).
        if let ep = episode, isPlaying, Int(seconds) % 10 == 0, seconds > 0 {
            library?.recordPosition(episodeId: ep.id, position: seconds, push: false)
        }
    }

    private func observe(_ item: AVPlayerItem) {
        itemObservations = []
        for token in notificationTokens { NotificationCenter.default.removeObserver(token) }
        notificationTokens = []

        itemObservations.append(item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let failed = item.status == .failed
            let msg = item.error?.localizedDescription
            Task { @MainActor [weak self] in
                if failed { self?.onItemFailed(msg) }
            }
        })

        let center = NotificationCenter.default
        notificationTokens.append(center.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onEnded() }
        })
        notificationTokens.append(center.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification,
            object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onItemFailed("Playback error") }
        })
    }

    private func installLifecycleObservers() {
        let center = NotificationCenter.default
        // Background edge: push the current position (mirrors the web app's
        // visibilitychange→hidden / pagehide beacons).
        notificationTokens.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.hasEpisode else { return }
                self.pushPosition()
            }
        })
        // Audio interruptions (phone call, other app): reflect reality in the
        // UI, resume if the system says we should.
        notificationTokens.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(), queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self,
                      let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
                switch type {
                case .began:
                    self.isPlaying = false
                    self.pushPosition()
                    self.refreshNowPlayingInfo()
                case .ended:
                    let opts = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
                        .map(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []
                    if self.intendPlaying && opts.contains(.shouldResume) { self.play() }
                @unknown default:
                    break
                }
            }
        })
    }

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio)
        try? session.setActive(true)
    }

    private func configureRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.play() }
            return .success
        }
        c.pauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.pause() }
            return .success
        }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.toggle() }
            return .success
        }
        c.skipBackwardCommand.preferredIntervals = [15]
        c.skipBackwardCommand.addTarget { [weak self] event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 15
            MainActor.assumeIsolated { self?.seekBy(-interval) }
            return .success
        }
        c.skipForwardCommand.preferredIntervals = [30]
        c.skipForwardCommand.addTarget { [weak self] event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 30
            MainActor.assumeIsolated { self?.seekBy(interval) }
            return .success
        }
        // Track skip = chapter jump, matching the web MediaSession handlers.
        c.previousTrackCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.jumpChapter(-1) }
            return .success
        }
        c.nextTrackCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.jumpChapter(+1) }
            return .success
        }
        c.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let pos = e.positionTime
            MainActor.assumeIsolated { self?.seek(to: pos) }
            return .success
        }
        c.changePlaybackRateCommand.supportedPlaybackRates =
            Self.speedSteps.map { NSNumber(value: $0) }
        c.changePlaybackRateCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackRateCommandEvent else { return .commandFailed }
            let rate = Double(e.playbackRate)
            MainActor.assumeIsolated { self?.setSpeed(rate) }
            return .success
        }
    }
}
