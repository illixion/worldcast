import Foundation
import Observation

// User-tunable playback behaviour, persisted in UserDefaults.
//
// Split out of PlayerModel so both the transport UI and the
// MPRemoteCommandCenter wiring read the same source of truth, and so a change
// made in Settings takes effect on an already-loaded episode without a reload.
// PlayerModel listens for `didChangeNotification` to re-publish
// `preferredIntervals` to the remote command center (the lock screen / CarPlay
// draw their skip glyphs from that, so it has to be pushed, not polled).

@Observable
final class PlaybackSettings {
    static let shared = PlaybackSettings()

    /// Posted after any property changes. PlayerModel observes it rather than
    /// using `withObservationTracking`, which only fires once per read.
    nonisolated static let didChangeNotification =
        Notification.Name("worldcast.playbackSettingsDidChange")

    /// What the remote *previous/next track* commands do — AirPods
    /// press-twice / press-thrice, CarPlay's ⏮/⏭, the lock screen track
    /// buttons and the Watch's crown menu all route through these.
    enum TrackCommandAction: String, CaseIterable, Identifiable {
        /// Jump to the previous/next chapter (falls back to a time skip on
        /// episodes with no chapters).
        case chapter
        /// Skip back/forward by the configured intervals.
        case skip

        var id: String { rawValue }

        var label: String {
            switch self {
            case .chapter: return "Chapter"
            case .skip: return "Time skip"
            }
        }
    }

    /// Offered in Settings. Restricted to values that have a matching
    /// `<n>.arrow.trianglehead.*` SF Symbol so the transport buttons can show
    /// the number instead of a bare arrow.
    nonisolated static let intervalChoices: [Double] = [5, 10, 15, 30, 45, 60, 75, 90]

    private enum Key {
        static let skipBack = "worldcast.skipBackInterval"
        static let skipForward = "worldcast.skipForwardInterval"
        static let trackAction = "worldcast.trackCommandAction"
        static let spatialAudio = "worldcast.spatialAudioEnabled"
    }

    private static let defaultSkipBack: Double = 15
    private static let defaultSkipForward: Double = 30

    var skipBackInterval: Double {
        didSet { commit(skipBackInterval, Key.skipBack, oldValue) }
    }

    var skipForwardInterval: Double {
        didSet { commit(skipForwardInterval, Key.skipForward, oldValue) }
    }

    var trackCommandAction: TrackCommandAction {
        didSet {
            guard trackCommandAction != oldValue else { return }
            defaults.set(trackCommandAction.rawValue, forKey: Key.trackAction)
            announce()
        }
    }

    /// Whether playback uses head-tracked spatial rendering or flat stereo
    /// passthrough. Off by default: episodes arrive as an already-mixed
    /// stereo track, so on visionOS the system's automatic spatial
    /// experience just anchors that mix to a point in the room rather than
    /// adding anything — spatializing it is a user choice, not automatic.
    /// Persisted; PlayerModel applies it live to the running session, no
    /// restart needed.
    var spatialAudioEnabled: Bool {
        didSet {
            guard spatialAudioEnabled != oldValue else { return }
            defaults.set(spatialAudioEnabled, forKey: Key.spatialAudio)
            announce()
        }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let back = defaults.double(forKey: Key.skipBack)
        let forward = defaults.double(forKey: Key.skipForward)
        skipBackInterval = Self.sanitize(back, fallback: Self.defaultSkipBack)
        skipForwardInterval = Self.sanitize(forward, fallback: Self.defaultSkipForward)
        trackCommandAction = defaults.string(forKey: Key.trackAction)
            .flatMap(TrackCommandAction.init(rawValue:)) ?? .chapter
        spatialAudioEnabled = defaults.bool(forKey: Key.spatialAudio)
    }

    private func commit(_ value: Double, _ key: String, _ oldValue: Double) {
        guard value != oldValue else { return }
        defaults.set(value, forKey: key)
        announce()
    }

    private func announce() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    /// Reject 0 (the UserDefaults miss value) and anything absurd, so a
    /// corrupt/legacy value can't silently disable skipping.
    private static func sanitize(_ value: Double, fallback: Double) -> Double {
        guard value.isFinite, value >= 1, value <= 300 else { return fallback }
        return value
    }
}

extension Double {
    /// SF Symbol for a skip button at this interval, e.g.
    /// `30.arrow.trianglehead.clockwise`. Falls back to the plain arrow for
    /// intervals outside `PlaybackSettings.intervalChoices`.
    func skipSymbolName(forward: Bool) -> String {
        let whole = Int(rounded())
        guard Double(whole) == rounded(), PlaybackSettings.intervalChoices.contains(Double(whole)) else {
            return forward ? "goforward" : "gobackward"
        }
        return forward
            ? "\(whole).arrow.trianglehead.clockwise"
            : "\(whole).arrow.trianglehead.counterclockwise"
    }
}
