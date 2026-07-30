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
//
// Transport intervals and the meaning of the remote previous/next-track
// commands live in PlaybackSettings, not here — see `applyRemoteCommandConfig`.

@Observable
final class PlayerModel {
    static let speedSteps: [Double] = [1, 1.25, 1.5, 1.75, 2, 0.75]
    private static let speedKey = "worldcast.playbackRate"
    /// How stale the lock screen's extrapolated elapsed time is allowed to get
    /// before we re-publish it. Not a position *sync* — purely local metadata.
    private static let nowPlayingDriftTolerance: Double = 1.5

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
    let settings: PlaybackSettings
    weak var library: LibraryStore?

    private var timeObserverToken: Any?
    private var itemObservations: [NSKeyValueObservation] = []
    private var playerObservations: [NSKeyValueObservation] = []
    private var itemNotificationTokens: [NSObjectProtocol] = []
    private var notificationTokens: [NSObjectProtocol] = []
    private var intendPlaying = false
    private var artworkFetchGeneration = 0

    // Now Playing state. We keep our own copy of everything we publish and
    // always write the dictionary whole: MPNowPlayingInfoCenter's getter is
    // not a reliable read-back (it can return nil or a stale dictionary from a
    // previous item), so the old read-modify-write pattern intermittently
    // dropped the duration and elapsed-time keys — which is why the lock
    // screen sometimes showed no scrubber at all.
    private var nowPlayingArtwork: MPMediaItemArtwork?
    private var nowPlayingArtworkURL: URL?
    private var publishedElapsed: Double = -1
    private var publishedRate: Double = -1
    private var publishedAt = Date.distantPast
    private var lastTimeControlStatus: AVPlayer.TimeControlStatus = .paused

    // Position-push de-duplication: pause() and the timeControlStatus observer
    // can both fire for one user action.
    private var lastPushedEpisode: UUID?
    private var lastPushedPosition: Double = -1

    init(settings: PlaybackSettings = .shared) {
        self.settings = settings
        let saved = UserDefaults.standard.double(forKey: Self.speedKey)
        playbackRate = Self.speedSteps.contains(saved) ? saved : 1
#if !os(visionOS)
        player.allowsExternalPlayback = true
#endif
        // Set the category up front (without activating) so the Now Playing
        // info we publish before the first play() isn't discarded.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        configureRemoteCommands()
        applyRemoteCommandConfig()
        observePlayer()
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

    /// Best available playback position: the player's own clock when it has
    /// one, else our last observed value. Used for both the lock screen and
    /// position sync so the two can never disagree.
    var playbackPosition: Double {
        if let t = player.currentItem?.currentTime().seconds, t.isFinite, t >= 0 {
            return t
        }
        return currentTime
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

        // The outgoing episode's position must land before we swap items away
        // from it, otherwise auto-advance silently loses it.
        if let previous = episode, previous.id != ep.id { pushPosition() }

        episode = ep
        feedTitle = library.feed(id: ep.feedId)?.displayTitle ?? ""
        chapters = ep.chapters.sorted { $0.startSeconds < $1.startSeconds }
        currentChapterIndex = -2 // force first applyChapter even for -1
        duration = ep.durationSeconds ?? 0
        loadGeneration += 1
        // Drop the previous item's artwork so the lock screen can't show it
        // against the new episode while the new art loads.
        nowPlayingArtwork = nil
        nowPlayingArtworkURL = nil
        lastPushedEpisode = nil
        lastPushedPosition = -1

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
        publishNowPlaying()
        updateNowPlayingArtwork()
    }

    // MARK: - Transport

    func play() {
        configureAudioSession()
        intendPlaying = true
        player.play()
        player.rate = Float(playbackRate)
        isPlaying = true
        publishNowPlaying()
    }

    func pause() {
        intendPlaying = false
        player.pause()
        isPlaying = false
        publishNowPlaying()
        pushPosition()
    }

    func toggle() { isPlaying ? pause() : play() }

    /// Tear down playback entirely (e.g. the library was erased).
    func stop() {
        intendPlaying = false
        player.pause()
        player.replaceCurrentItem(with: nil)
        episode = nil
        chapters = []
        currentChapterIndex = -1
        isPlaying = false
        currentTime = 0
        duration = 0
        statusMessage = nil
        nowPlayingArtwork = nil
        nowPlayingArtworkURL = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        WatchConfigurationSync.shared.clearNowPlaying()
    }

    func seek(to seconds: Double) {
        let dur = effectiveDuration
        let target = max(0, dur > 0 ? min(seconds, dur) : seconds)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 1000),
                    toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = target
        applyChapter(chapterIndex(at: target))
        publishNowPlaying()
        pushPosition(at: target)
    }

    func seekBy(_ delta: Double) { seek(to: playbackPosition + delta) }

    func skipBackward() { seekBy(-settings.skipBackInterval) }
    func skipForward() { seekBy(settings.skipForwardInterval) }

    /// Previous/next chapter; falls back to a configured time skip when the
    /// episode has no chapters — same shape as the web player, but the
    /// interval is now the user's, not a hardcoded 30s.
    func jumpChapter(_ dir: Int) {
        guard !chapters.isEmpty else {
            dir < 0 ? skipBackward() : skipForward()
            return
        }
        let cur = chapterIndex(at: playbackPosition)
        let next = max(0, min(chapters.count - 1, (cur < 0 ? 0 : cur) + dir))
        seek(to: chapters[next].startSeconds)
    }

    /// What a remote previous/next-track command does. AirPods
    /// press-twice/thrice, CarPlay and the lock screen track buttons all land
    /// here, so the single setting covers all of them.
    func performTrackCommand(_ dir: Int) {
        switch settings.trackCommandAction {
        case .chapter:
            jumpChapter(dir)
        case .skip:
            dir < 0 ? skipBackward() : skipForward()
        }
    }

    func setSpeed(_ rate: Double) {
        playbackRate = rate
        UserDefaults.standard.set(rate, forKey: Self.speedKey)
        player.defaultRate = Float(rate)
        if isPlaying { player.rate = Float(rate) }
        publishNowPlaying()
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
        publishNowPlaying()
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

    /// Write the whole Now Playing dictionary. Always call this rather than
    /// mutating `MPNowPlayingInfoCenter.default().nowPlayingInfo` in place.
    private func publishNowPlaying() {
        guard let ep = episode else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            publishedElapsed = -1
            publishedRate = -1
            return
        }
        let elapsed = playbackPosition
        // Report the *actual* rate: while buffering (waitingToPlayAtSpecified-
        // Rate) the lock screen must not run its clock ahead of the audio.
        let rate = player.timeControlStatus == .playing ? playbackRate : 0

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: currentChapter?.title ?? ep.displayTitle,
            MPMediaItemPropertyArtist: feedTitle,
            MPMediaItemPropertyAlbumTitle: ep.displayTitle,
            MPNowPlayingInfoPropertyExternalContentIdentifier: ep.id.uuidString,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: rate,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: playbackRate,
            MPNowPlayingInfoPropertyIsLiveStream: false,
            MPNowPlayingInfoPropertyMediaType: ep.isVideo
                ? MPNowPlayingInfoMediaType.video.rawValue
                : MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        // Publishing a 0 duration makes iOS hide the scrubber entirely, so
        // omit the key until we actually know the length.
        let dur = effectiveDuration
        if dur > 0 { info[MPMediaItemPropertyPlaybackDuration] = dur }
        if currentChapterIndex >= 0 {
            info[MPNowPlayingInfoPropertyChapterNumber] = currentChapterIndex + 1
            info[MPNowPlayingInfoPropertyChapterCount] = chapters.count
        }
        if let art = nowPlayingArtwork { info[MPMediaItemPropertyArtwork] = art }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        publishedElapsed = elapsed
        publishedRate = rate
        publishedAt = Date()

        WatchConfigurationSync.shared.refreshNowPlaying(
            episodeId: ep.id.uuidString,
            title: ep.displayTitle,
            feedTitle: feedTitle,
            chapterTitle: currentChapter?.title,
            artworkURL: currentArtworkURL,
            position: elapsed,
            duration: dur,
            rate: rate,
            chapters: chapters)
    }

    /// Re-publish for a watch that just asked for a fresh snapshot (e.g. its
    /// remote view just appeared) — same data, no state change.
    func republishNowPlaying() { publishNowPlaying() }

    /// Re-publish only when the lock screen's own extrapolation would have
    /// drifted from reality (a stall, a seek we didn't route through seek(), a
    /// rate change), so we stay well clear of hammering
    /// MPNowPlayingInfoCenter on every 0.5s tick.
    private func refreshNowPlayingIfDrifted() {
        guard episode != nil else { return }
        let rate = player.timeControlStatus == .playing ? playbackRate : 0
        guard rate == publishedRate else { publishNowPlaying(); return }
        // iOS extrapolates from what we last published: elapsed + rate × age.
        let expected = publishedElapsed + rate * Date().timeIntervalSince(publishedAt)
        if abs(playbackPosition - expected) > Self.nowPlayingDriftTolerance {
            publishNowPlaying()
        }
    }

    private func updateNowPlayingArtwork() {
        guard let url = currentArtworkURL else {
            if nowPlayingArtwork != nil {
                nowPlayingArtwork = nil
                nowPlayingArtworkURL = nil
                publishNowPlaying()
            }
            return
        }
        guard url != nowPlayingArtworkURL else { return }
        artworkFetchGeneration += 1
        let generation = artworkFetchGeneration
        Task { [weak self] in
            guard let image = await ImageCache.shared.image(for: url),
                  let self, generation == self.artworkFetchGeneration else { return }
            self.nowPlayingArtwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            self.nowPlayingArtworkURL = url
            self.publishNowPlaying()
        }
    }

    // MARK: - Position sync (quiet contract)

    /// Record + push the current position. Pushes are de-duplicated because a
    /// single lock-screen pause can reach us twice (the remote command target
    /// and the timeControlStatus observer).
    private func pushPosition(at position: Double? = nil) {
        guard let ep = episode else { return }
        let pos = position ?? playbackPosition
        guard pos.isFinite else { return }
        if lastPushedEpisode == ep.id, abs(pos - lastPushedPosition) < 0.5 { return }
        lastPushedEpisode = ep.id
        lastPushedPosition = pos
        library?.recordPosition(episodeId: ep.id, position: pos, push: true)
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
            publishNowPlaying()
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
        adoptItemDuration()
        let idx = chapterIndex(at: seconds)
        if idx != currentChapterIndex { applyChapter(idx) }
        refreshNowPlayingIfDrifted()
        // Keep the store's in-memory position current (no network — the push
        // flag stays false so the quiet contract holds).
        if let ep = episode, isPlaying, Int(seconds) % 10 == 0, seconds > 0 {
            library?.recordPosition(episodeId: ep.id, position: seconds, push: false)
        }
    }

    /// Player-level observation, installed once — survives item swaps.
    private func observePlayer() {
        playerObservations.append(
            player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
                let status = player.timeControlStatus
                Task { @MainActor [weak self] in
                    self?.onTimeControlStatusChanged(status)
                }
            })
    }

    /// Reconcile our state with the player's. This is what catches pauses we
    /// didn't initiate — a route change (AirPods pulled out), an interruption,
    /// or the system stopping us — so both the UI and the lock screen stay
    /// truthful and the position still gets pushed.
    private func onTimeControlStatusChanged(_ status: AVPlayer.TimeControlStatus) {
        let previous = lastTimeControlStatus
        lastTimeControlStatus = status
        guard episode != nil else { return }
        let nowPlaying = status != .paused
        if nowPlaying != isPlaying { isPlaying = nowPlaying }
        publishNowPlaying()
        // Only a genuine playing → paused transition is worth a push. An item
        // swap also reports .paused, and pushing there would write the *new*
        // episode's zero position over its stored one.
        if status == .paused, previous != .paused { pushPosition() }
    }

    private func observe(_ item: AVPlayerItem) {
        itemObservations = []
        for token in itemNotificationTokens { NotificationCenter.default.removeObserver(token) }
        itemNotificationTokens = []

        itemObservations.append(item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let failed = item.status == .failed
            let msg = item.error?.localizedDescription
            Task { @MainActor [weak self] in
                if failed { self?.onItemFailed(msg) }
                else { self?.adoptItemDuration() }
            }
        })
        // Duration resolves asynchronously for streamed audio. Without this
        // the lock screen keeps whatever we knew at load time — often nothing,
        // which is why the scrubber was sometimes missing or stuck at 0:00.
        itemObservations.append(item.observe(\.duration, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.adoptItemDuration() }
        })

        let center = NotificationCenter.default
        itemNotificationTokens.append(center.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onEnded() }
        })
        itemNotificationTokens.append(center.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification,
            object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onItemFailed("Playback error") }
        })
        // A seek performed outside our own seek() path (or a live-stream
        // window shift) invalidates the elapsed time we published.
        itemNotificationTokens.append(center.addObserver(
            forName: AVPlayerItem.timeJumpedNotification,
            object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.publishNowPlaying() }
        })
        itemNotificationTokens.append(center.addObserver(
            forName: AVPlayerItem.playbackStalledNotification,
            object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.publishNowPlaying() }
        })
    }

    private func adoptItemDuration() {
        guard let d = player.currentItem?.duration.seconds, d.isFinite, d > 0 else { return }
        guard abs(d - duration) > 0.5 else { return }
        duration = d
        publishNowPlaying()
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
        notificationTokens.append(center.addObserver(
            forName: UIApplication.willTerminateNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.hasEpisode else { return }
                self.pushPosition()
            }
        })
        // Coming back to the foreground is our chance to retry anything a
        // suspension cut short while we were backgrounded.
        notificationTokens.append(center.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.library?.flushDirtyPositions()
                self?.publishNowPlaying()
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
                    self.publishNowPlaying()
                    self.pushPosition()
                case .ended:
                    let opts = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
                        .map(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []
                    if self.intendPlaying && opts.contains(.shouldResume) { self.play() }
                @unknown default:
                    break
                }
            }
        })
        // AirPods pulled out / Bluetooth device gone: iOS pauses us. Get the
        // position out while we still have runtime.
        notificationTokens.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(), queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, self.hasEpisode,
                      let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                      AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable
                else { return }
                self.pushPosition()
            }
        })
        // Settings changed → the remote command center needs the new
        // intervals pushed to it (the lock screen renders its skip glyphs from
        // preferredIntervals, so polling isn't enough).
        notificationTokens.append(center.addObserver(
            forName: PlaybackSettings.didChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyRemoteCommandConfig() }
        })
    }

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio)
        try? session.setActive(true)
    }

    // MARK: - Remote commands

    /// Registered once. Handlers read PlaybackSettings at invocation time, so
    /// only the *presentation* (preferredIntervals) needs re-applying when
    /// settings change.
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
        c.skipBackwardCommand.addTarget { [weak self] event in
            // Trust the event's interval (it's the one we advertised), but
            // fall back to the setting if the system omits it.
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval
            MainActor.assumeIsolated {
                guard let self else { return }
                self.seekBy(-(interval ?? self.settings.skipBackInterval))
            }
            return .success
        }
        c.skipForwardCommand.addTarget { [weak self] event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval
            MainActor.assumeIsolated {
                guard let self else { return }
                self.seekBy(interval ?? self.settings.skipForwardInterval)
            }
            return .success
        }
        // Track skip: chapter jump or time skip, per PlaybackSettings.
        c.previousTrackCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.performTrackCommand(-1) }
            return .success
        }
        c.nextTrackCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.performTrackCommand(+1) }
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

    /// Push the current PlaybackSettings to MPRemoteCommandCenter.
    private func applyRemoteCommandConfig() {
        let c = MPRemoteCommandCenter.shared()
        c.skipBackwardCommand.preferredIntervals = [NSNumber(value: settings.skipBackInterval)]
        c.skipForwardCommand.preferredIntervals = [NSNumber(value: settings.skipForwardInterval)]
    }
}
