import AppIntents

private enum PlaybackIntentSupport {
    @MainActor
    static func requirePlayer() -> PlayerModel? {
        let player = AppServices.shared.player
        return player.hasEpisode ? player : nil
    }
}

struct NextChapterIntent: AppIntent {
    static let title: LocalizedStringResource = "Next Chapter"
    static let description = IntentDescription("Skips to the next chapter in Worldcast.")
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let player = PlaybackIntentSupport.requirePlayer() else {
            return .result(dialog: "Nothing is playing in Worldcast.")
        }
        player.jumpChapter(1)
        return .result(dialog: "Skipped to the next chapter.")
    }
}

struct PreviousChapterIntent: AppIntent {
    static let title: LocalizedStringResource = "Previous Chapter"
    static let description = IntentDescription("Skips to the previous chapter in Worldcast.")
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let player = PlaybackIntentSupport.requirePlayer() else {
            return .result(dialog: "Nothing is playing in Worldcast.")
        }
        player.jumpChapter(-1)
        return .result(dialog: "Skipped to the previous chapter.")
    }
}

struct SkipForwardIntent: AppIntent {
    static let title: LocalizedStringResource = "Skip Forward"
    static let description = IntentDescription("Skips forward by the interval configured in Worldcast.")
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let player = PlaybackIntentSupport.requirePlayer() else {
            return .result(dialog: "Nothing is playing in Worldcast.")
        }
        player.skipForward()
        return .result(dialog: "Skipped forward.")
    }
}

struct SkipBackwardIntent: AppIntent {
    static let title: LocalizedStringResource = "Skip Backward"
    static let description = IntentDescription("Skips backward by the interval configured in Worldcast.")
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let player = PlaybackIntentSupport.requirePlayer() else {
            return .result(dialog: "Nothing is playing in Worldcast.")
        }
        player.skipBackward()
        return .result(dialog: "Skipped backward.")
    }
}

struct PlayRandomEpisodeIntent: AppIntent {
    static let title: LocalizedStringResource = "Play Random Episode"
    static let description = IntentDescription("Plays a random never-played episode from Worldcast.")
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let services = AppServices.shared
        guard let episode = services.library.randomNeverPlayed() else {
            return .result(dialog: "There are no never-played episodes available.")
        }
        await services.player.load(episodeId: episode.id)
        return .result(dialog: "Playing a random episode.")
    }
}

struct TogglePlaybackIntent: AppIntent {
    static let title: LocalizedStringResource = "Play or Pause"
    static let description = IntentDescription("Toggles Worldcast playback.")
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let player = PlaybackIntentSupport.requirePlayer() else {
            return .result(dialog: "Nothing is playing in Worldcast.")
        }
        player.toggle()
        return .result(dialog: "Playback toggled.")
    }
}

struct WorldcastShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: NextChapterIntent(),
            phrases: [
                "Next chapter in \(.applicationName)",
                "Skip to the next chapter in \(.applicationName)",
            ],
            shortTitle: "Next Chapter",
            systemImageName: "forward.end.fill"
        )
        AppShortcut(
            intent: PreviousChapterIntent(),
            phrases: [
                "Previous chapter in \(.applicationName)",
                "Go back a chapter in \(.applicationName)",
            ],
            shortTitle: "Previous Chapter",
            systemImageName: "backward.end.fill"
        )
        AppShortcut(
            intent: SkipForwardIntent(),
            phrases: ["Skip forward in \(.applicationName)"],
            shortTitle: "Skip Forward",
            systemImageName: "goforward"
        )
        AppShortcut(
            intent: SkipBackwardIntent(),
            phrases: ["Skip backward in \(.applicationName)"],
            shortTitle: "Skip Backward",
            systemImageName: "gobackward"
        )
        AppShortcut(
            intent: PlayRandomEpisodeIntent(),
            phrases: [
                "Play a random episode in \(.applicationName)",
                "Shuffle \(.applicationName)",
            ],
            shortTitle: "Random Episode",
            systemImageName: "shuffle"
        )
        AppShortcut(
            intent: TogglePlaybackIntent(),
            phrases: ["Play or pause \(.applicationName)"],
            shortTitle: "Play or Pause",
            systemImageName: "playpause.fill"
        )
    }

    static let shortcutTileColor: ShortcutTileColor = .orange
}
