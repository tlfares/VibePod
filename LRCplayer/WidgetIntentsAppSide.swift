import Foundation

extension TogglePlaybackIntent {
    func runToggle() async {
        await MainActor.run { MusicPlayerService.shared.togglePlayPause() }
    }
}

extension NextTrackIntent {
    func runNext() async {
        await MainActor.run { MusicPlayerService.shared.next() }
    }
}

extension PreviousTrackIntent {
    func runPrevious() async {
        await MainActor.run { MusicPlayerService.shared.skipToPreviousTrack() }
    }
}
