import AVFoundation
import CoreMotion
import MediaPlayer
import SwiftUI
import UIKit

/// A head movement the AirPods' motion sensors can tell apart from the
/// rest: nodding, shaking, tilting.
enum HeadGesture: String, CaseIterable, Identifiable {
    case nod, shake, tiltLeft, tiltRight

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .nod: "Nod"
        case .shake: "Shake"
        case .tiltLeft: "Tilt Left"
        case .tiltRight: "Tilt Right"
        }
    }

    var systemImage: String {
        switch self {
        case .nod: "arrow.up.and.down"
        case .shake: "arrow.left.and.right"
        case .tiltLeft: "rotate.left"
        case .tiltRight: "rotate.right"
        }
    }

    var storageKey: String { "headGesture.\(rawValue)" }
}

/// What a head gesture does. Nothing, until chosen.
enum HeadGestureAction: String, CaseIterable, Identifiable {
    case none, playPause, next, previous, volumeUp, volumeDown, shuffleAll, shuffleArtist, announce

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .none: "No Action"
        case .playPause: "Play/Pause"
        case .next: "Next Song"
        case .previous: "Previous Song"
        case .volumeUp: "Volume Up"
        case .volumeDown: "Volume Down"
        case .shuffleAll: "Shuffle All"
        case .shuffleArtist: "Shuffle This Artist"
        case .announce: "Say What's Playing"
        }
    }

    var systemImage: String {
        switch self {
        case .none: "nosign"
        case .playPause: "playpause.fill"
        case .next: "forward.fill"
        case .previous: "backward.fill"
        case .volumeUp: "speaker.wave.3.fill"
        case .volumeDown: "speaker.wave.1.fill"
        case .shuffleAll: "shuffle"
        case .shuffleArtist: "music.microphone"
        case .announce: "waveform"
        }
    }
}

/// Head gestures through the AirPods (Pro, Max, 3rd generation and later)
/// and the Beats that track the head: Core Motion only gives the head's
/// rotation, the gestures are read from it here.
///
/// A gesture is a burst of fast turns on one axis, then stillness: one nod
/// is down-up, a shake is left-right-left. Nodding along to a song never
/// stops long enough to count, and walking never turns the head fast enough.
@MainActor
final class HeadGestures: NSObject, ObservableObject {
    static let shared = HeadGestures()
    static let enabledKey = "headGesturesEnabled"
    /// 0 (firm gestures only) to 1 (the lightest ones); 0.5 by default.
    static let sensitivityKey = "headGesturesSensitivity"

    static var isSupported: Bool { CMHeadphoneMotionManager().isDeviceMotionAvailable }

    /// Compatible headphones are in and sending their motion.
    @Published private(set) var isConnected = false
    /// The last gesture read, for the settings to light its row.
    @Published private(set) var lastGesture: (gesture: HeadGesture, at: Date)?
    @Published private(set) var isDenied = false

    private let manager = CMHeadphoneMotionManager()
    private var isRunning = false

    private override init() {
        super.init()
        manager.delegate = self
    }

    var isEnabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }

    /// Follows the setting: on at launch and when switched on.
    func refresh() {
        updateSensitivity()
        isEnabled ? start() : stop()
    }

    /// Half as firm again at the least sensitive; a bit softer (×0.81) at the most.
    func updateSensitivity() {
        let stored = UserDefaults.standard.object(forKey: Self.sensitivityKey) as? Double ?? 0.5
        let s = min(max(stored, 0), 1)
        let firmness = s <= 0.5 ? pow(2, 0.5 - s) : pow(2, -(s - 0.5) * 0.6)
        threshold = Self.baseThreshold * firmness
        tiltAngle = Self.baseTiltAngle * firmness
    }

    private func start() {
        guard !isRunning, manager.isDeviceMotionAvailable else { return }
        isDenied = CMHeadphoneMotionManager.authorizationStatus() == .denied
        guard !isDenied else { return }
        isRunning = true
        reset()
        manager.startConnectionStatusUpdates()
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, error in
            guard let motion else {
                if error != nil {
                    MainActor.assumeIsolated {
                        self?.isDenied = CMHeadphoneMotionManager.authorizationStatus() == .denied
                    }
                }
                return
            }
            let rate = motion.rotationRate
            let attitude = motion.attitude
            let roll = attitude.roll, pitch = attitude.pitch
            let time = motion.timestamp
            MainActor.assumeIsolated {
                guard let self else { return }
                if !self.isConnected { self.isConnected = true }
                self.read(pitch: rate.x, roll: rate.y, yaw: rate.z, at: time)
                self.readTilt(roll: roll, pitch: pitch, at: time)
            }
        }
    }

    private func stop() {
        guard isRunning else { return }
        isRunning = false
        manager.stopDeviceMotionUpdates()
        manager.stopConnectionStatusUpdates()
        isConnected = false
    }

    // MARK: - Reading

    private enum Axis { case pitch, roll, yaw }

    /// One fast turn of the head, from when it passed the threshold to when
    /// it slowed down again.
    private struct Swing {
        var axis: Axis
        var sign: Double
        var peak: Double
        var end: TimeInterval
    }

    /// Turns faster than this (rad/s) are deliberate; under `rest`, the
    /// turn is over.
    private static let baseThreshold = 1.7
    private var threshold = baseThreshold
    private var rest: Double { threshold * 0.35 }
    /// The burst ends after this much stillness.
    private static let quiet: TimeInterval = 0.35

    private var swing: Swing?
    private var burst: [Swing] = []
    private var burstStart: TimeInterval = 0
    private var cooldownUntil: TimeInterval = 0

    private func reset() {
        swing = nil
        burst = []
        rollBase = nil
        tilt = nil
    }

    // MARK: Tilts

    /// A tilt is slow, unlike a nod: read from the head's angle, not its
    /// speed. Over by this much from where the head was resting, then
    /// back up.
    private static let baseTiltAngle = 19 * Double.pi / 180
    private var tiltAngle = baseTiltAngle
    /// Where the head rests, following slowly the way it's held.
    private var rollBase: Double?
    private var pitchBase: Double = 0
    private var lastTiltTime: TimeInterval = 0
    private var tilt: (sign: Double, since: TimeInterval)?

    private func readTilt(roll: Double, pitch: Double, at time: TimeInterval) {
        defer { lastTiltTime = time }
        guard let base = rollBase else {
            rollBase = roll
            pitchBase = pitch
            return
        }
        let delta = roll - base
        let lean = pitch - pitchBase
        if let current = tilt {
            if abs(delta) < tiltAngle * 0.45 {
                // Back up: a tilt, if it was quick enough to be one.
                tilt = nil
                if time - current.since < 2.5, time >= cooldownUntil {
                    cooldownUntil = time + 0.8
                    perform(current.sign > 0 ? .tiltRight : .tiltLeft)
                }
            } else if time - current.since > 2.5 {
                // Held there: a new way of resting the head.
                tilt = nil
                rollBase = roll
                pitchBase = pitch
            }
            return
        }
        if abs(delta) > tiltAngle, abs(lean) < abs(delta) * 0.8, time >= cooldownUntil {
            tilt = (delta > 0 ? 1 : -1, time)
            return
        }
        let step = min(max(time - lastTiltTime, 0) / 1.5, 1)
        rollBase = base + (roll - base) * step
        pitchBase += (pitch - pitchBase) * step
    }

    private func read(pitch: Double, roll: Double, yaw: Double, at time: TimeInterval) {
        guard time >= cooldownUntil else { return }
        let rates: [(Axis, Double)] = [(.pitch, pitch), (.roll, roll), (.yaw, yaw)]
        let (axis, rate) = rates.max { abs($0.1) < abs($1.1) }!

        if var current = swing {
            let along = current.axis == .pitch ? pitch : current.axis == .roll ? roll : yaw
            if abs(along) < rest || along.sign != (current.sign < 0 ? .minus : .plus) {
                current.end = time
                close(current)
                swing = nil
            } else {
                current.peak = max(current.peak, abs(along))
                swing = current
                return
            }
        }

        if abs(rate) >= threshold {
            if burst.isEmpty { burstStart = time }
            swing = Swing(axis: axis, sign: rate < 0 ? -1 : 1, peak: abs(rate), end: time)
        } else if let last = burst.last, swing == nil, time - last.end >= Self.quiet {
            finish(at: time)
        }
    }

    private func close(_ swing: Swing) {
        // A turn back the same way it went (a jolt, not a gesture) or on
        // another axis than the burst's: the burst is something else.
        if let first = burst.first, first.axis != swing.axis {
            burst = []
            return
        }
        if let last = burst.last, last.sign == swing.sign {
            burst.append(swing)
            burst = Array(burst.suffix(12))
            return
        }
        burst.append(swing)
    }

    private func finish(at time: TimeInterval) {
        defer { burst = [] }
        guard let first = burst.first else { return }
        let count = burst.count
        let length = time - burstStart
        let alternates = zip(burst, burst.dropFirst()).allSatisfy { $0.sign != $1.sign }
        guard alternates else { return }

        let gesture: HeadGesture?
        switch first.axis {
        case .pitch:
            // One or two nods; more is dancing.
            gesture = (2...4).contains(count) && length < 1.6 ? .nod : nil
        case .yaw:
            // Left-right-left at least; once to the side and back is a glance.
            gesture = (3...6).contains(count) && length < 2 ? .shake : nil
        case .roll:
            // Tilts are read from the angle (`readTilt`).
            gesture = nil
        }
        guard let gesture else { return }
        cooldownUntil = time + 0.8
        perform(gesture)
    }

    // MARK: - Acting

    private func perform(_ gesture: HeadGesture) {
        lastGesture = (gesture, .now)
        let raw = UserDefaults.standard.string(forKey: gesture.storageKey) ?? ""
        let action = HeadGestureAction(rawValue: raw) ?? .none
        // Games own the playback: only the volume stays available.
        if LibraryGamesViewController.isGameOnScreen, action != .volumeUp, action != .volumeDown { return }
        let player = MusicPlayerService.shared
        switch action {
        case .none:
            return
        case .playPause:
            player.togglePlayPause()
        case .next:
            player.next()
        case .previous:
            player.previous()
        case .volumeUp:
            SystemVolume.step(by: 2)
        case .volumeDown:
            SystemVolume.step(by: -2)
        case .shuffleAll:
            let songs = AppModel.shared.libraryService.songs
            guard !songs.isEmpty else { return }
            player.play(songs, shuffled: true)
        case .shuffleArtist:
            guard let song = player.currentSong else { return }
            let artist = LibraryIndex.artistName(for: song)
            let songs = AppModel.shared.libraryService.songs.filter { LibraryIndex.artistName(for: $0) == artist }
            guard !songs.isEmpty else { return }
            player.play(songs, shuffled: true)
        case .announce:
            guard let song = player.currentSong else { return }
            Announcer.say(String(localized: "\(song.title), by \(song.artist)"))
        }
    }
}

extension HeadGestures: CMHeadphoneMotionManagerDelegate {
    nonisolated func headphoneMotionManagerDidConnect(_ manager: CMHeadphoneMotionManager) {
        Task { @MainActor in
            self.reset()
            self.isConnected = true
        }
    }

    nonisolated func headphoneMotionManagerDidDisconnect(_ manager: CMHeadphoneMotionManager) {
        Task { @MainActor in
            self.reset()
            self.isConnected = false
        }
    }
}

/// The system volume, the one the buttons change: only an `MPVolumeView`'s
/// slider can set it.
@MainActor
enum SystemVolume {
    private static var view: MPVolumeView?

    /// `steps` of the 16 the volume buttons make.
    static func step(by steps: Int) {
        guard let slider = slider() else { return }
        let current = AVAudioSession.sharedInstance().outputVolume
        let value = min(max(current + Float(steps) / 16, 0), 1)
        slider.setValue(value, animated: false)
        slider.sendActions(for: .valueChanged)
    }

    private static func slider() -> UISlider? {
        if view == nil {
            let volume = MPVolumeView(frame: CGRect(x: -200, y: -200, width: 100, height: 40))
            volume.alpha = 0.01
            volume.isUserInteractionEnabled = false
            let window = UIApplication.shared.connectedScenes
                .compactMap { ($0 as? UIWindowScene)?.keyWindow }
                .first
            window?.addSubview(volume)
            view = volume
        }
        return view?.subviews.compactMap { $0 as? UISlider }.first
    }
}

/// Says a line over the music.
@MainActor
enum Announcer {
    private static let synthesizer = AVSpeechSynthesizer()

    static func say(_ text: String) {
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: Locale.preferredLanguages.first)
        utterance.prefersAssistiveTechnologySettings = true
        synthesizer.speak(utterance)
    }
}

