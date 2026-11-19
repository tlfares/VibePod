import Foundation
import WidgetKit

extension TogglePlaybackIntent {
    func runToggle() async {
        let currentlyPlaying = WidgetStateStore.read()?.isPlaying ?? false
        WidgetStateStore.updatePlayback(isPlaying: !currentlyPlaying)
        WidgetCenter.shared.reloadAllTimelines()
    }
}

extension NextTrackIntent {
    func runNext() async {}
}

extension PreviousTrackIntent {
    func runPrevious() async {}
}
