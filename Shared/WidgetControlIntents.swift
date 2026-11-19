import AppIntents
import Foundation

struct TogglePlaybackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play/Pause"
    static let description = IntentDescription("Plays or pauses the current track.")

    init() {}

    func perform() async throws -> some IntentResult {
        await runToggle()
        return .result()
    }
}

struct NextTrackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Next Track"
    static let description = IntentDescription("Skips to the next track.")

    init() {}

    func perform() async throws -> some IntentResult {
        await runNext()
        return .result()
    }
}

struct PreviousTrackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Previous Track"
    static let description = IntentDescription("Skips to the previous track.")

    init() {}

    func perform() async throws -> some IntentResult {
        await runPrevious()
        return .result()
    }
}
