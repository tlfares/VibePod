import Accelerate
import MediaToolbox
import os
import Foundation
import AVFoundation
import CoreMedia
import MediaPlayer
import Combine
import UIKit
import WidgetKit

enum RepeatMode: String, Codable {
    case off, one, all
}

enum ShuffleMode: String, Codable {
    case off, on
}

@MainActor
final class MusicPlayerService: NSObject, ObservableObject {
    static let shared = MusicPlayerService()

    @Published private(set) var currentSong: Song?
    @Published private(set) var isPlaying = false
    /// Published at 4 Hz for the scrubber. Use `preciseCurrentTime` when the
    /// exact position matters (lyrics sync).
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var repeatMode: RepeatMode = .off
    @Published private(set) var shuffleMode: ShuffleMode = .off
    @Published private(set) var queue: [Song] = []
    @Published private(set) var currentIndex: Int = 0
    @Published var lastError: String?

    /// Play-next block: consecutive "Play Next" songs keep their order right
    /// after the song that was current when the first one was added.
    private var playNextAnchor: Int?
    private var pendingNextCount = 0
    private var lastPlayNextOriginalIndex: Int?

    private var audioPlayer: AVAudioPlayer?
    private var mediaPlayer: AVPlayer?
    private var mediaTimeObserver: Any?
    private var mediaEndObserver: NSObjectProtocol?
    private var mediaStatusObservation: NSKeyValueObservation?
    private var originalQueue: [Song] = []
    private var progressTimer: Timer?
    private var stateSaveTimer: Timer?
    private var remoteSeekTimer: Timer?
    private(set) var isSeeking = false
    private var seekCount = 0
    private var restoreSavedTime: TimeInterval?
    private var wasPlayingBeforeInterruption = false
    private var nowPlayingInfo: [String: Any] = [:]
    private var lastWidgetSongID: UUID?
    private var lastWidgetIsPlaying: Bool?
    private let widgetQueue = DispatchQueue(label: "com.fares.lrc.player.widget", qos: .utility)

    /// Exact playback position, read straight from the player.
    var preciseCurrentTime: TimeInterval {
        if let audioPlayer { return audioPlayer.currentTime }
        if let mediaPlayer {
            // Until a seek lands the player still reports the old position.
            if isSeeking { return currentTime }
            let seconds = mediaPlayer.currentTime().seconds
            return seconds.isFinite ? seconds : currentTime
        }
        return currentTime
    }

    override init() {
        super.init()
        configureAudioSession()
        setupRemoteCommandCenter()
        setupNotifications()
    }

    // MARK: - State Persistence

    private enum Keys {
        static let queueIDs = "playerQueueIDs"
        static let playingQueueIDs = "playerPlayingQueueIDs"
        static let currentIndex = "playerCurrentIndex"
        static let currentSongID = "playerCurrentSongID"
        static let currentTime = "playerCurrentTime"
        static let repeatMode = "playerRepeatMode"
        static let shuffleMode = "playerShuffleMode"
    }

    /// The queue keeps copies of songs: after a Music library re-sync, swap
    /// in the relinked ones (or the originals duplicates were merged into),
    /// so the queue plays again and points at songs that still exist.
    private func replaceSongs(_ replacements: [UUID: Song]) {
        guard !replacements.isEmpty else { return }
        let swap = { (songs: [Song]) in songs.map { replacements[$0.id] ?? $0 } }
        queue = swap(queue)
        originalQueue = swap(originalQueue)
        if let current = currentSong, let replacement = replacements[current.id] {
            currentSong = replacement
        }
        saveState()
    }

    func saveState() {
        let defaults = UserDefaults.standard
        defaults.set(originalQueue.map(\.id.uuidString), forKey: Keys.queueIDs)
        defaults.set(queue.map(\.id.uuidString), forKey: Keys.playingQueueIDs)
        defaults.set(currentIndex, forKey: Keys.currentIndex)
        defaults.set(currentSong?.id.uuidString, forKey: Keys.currentSongID)
        defaults.set(preciseCurrentTime, forKey: Keys.currentTime)
        defaults.set(repeatMode.rawValue, forKey: Keys.repeatMode)
        defaults.set(shuffleMode.rawValue, forKey: Keys.shuffleMode)
    }

    private var didRestoreState = false

    /// Restores the last session once per launch (never over live playback).
    private func savePlaybackPosition() {
        let defaults = UserDefaults.standard
        defaults.set(currentIndex, forKey: Keys.currentIndex)
        defaults.set(currentSong?.id.uuidString, forKey: Keys.currentSongID)
        defaults.set(preciseCurrentTime, forKey: Keys.currentTime)
    }

    func restoreState(with songs: [Song]) {
        guard !didRestoreState, currentSong == nil else { return }
        didRestoreState = true
        let defaults = UserDefaults.standard
        let songMap = Dictionary(songs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func resolve(_ key: String) -> [Song] {
            (defaults.stringArray(forKey: key) ?? []).compactMap(UUID.init).compactMap { songMap[$0] }
        }

        let original = resolve(Keys.queueIDs)
        guard !original.isEmpty else { return }
        let playing = resolve(Keys.playingQueueIDs)
        let resolvedQueue = playing.count == original.count ? playing : original

        var index = min(max(defaults.integer(forKey: Keys.currentIndex), 0), resolvedQueue.count - 1)
        if let idString = defaults.string(forKey: Keys.currentSongID),
           let songID = UUID(uuidString: idString),
           resolvedQueue.indices.contains(index) == false || resolvedQueue[index].id != songID,
           let found = resolvedQueue.firstIndex(where: { $0.id == songID }) {
            index = found
        }

        originalQueue = original
        queue = resolvedQueue
        currentIndex = index
        repeatMode = RepeatMode(rawValue: defaults.string(forKey: Keys.repeatMode) ?? "") ?? .off
        shuffleMode = ShuffleMode(rawValue: defaults.string(forKey: Keys.shuffleMode) ?? "") ?? .off

        let song = resolvedQueue[index]
        let savedTime = defaults.double(forKey: Keys.currentTime)
        let clampedTime = song.duration > 0 ? max(0, min(savedTime, song.duration - 0.5)) : max(0, savedTime)
        restoreSavedTime = clampedTime
        currentTime = clampedTime
        duration = song.duration
        currentSong = song
        updateWidgetState()
    }

    private func startStateSaveTimer() {
        stopStateSaveTimer()
        // Only the position changes while a song plays; the queue is saved
        // whenever it is edited.
        let timer = Timer(timeInterval: 5, repeats: true) { _ in
            MainActor.assumeIsolated { MusicPlayerService.shared.savePlaybackPosition() }
        }
        RunLoop.main.add(timer, forMode: .common)
        stateSaveTimer = timer
    }

    private func stopStateSaveTimer() {
        stateSaveTimer?.invalidate()
        stateSaveTimer = nil
    }

    // MARK: - Widget

    func updateWidgetState() {
        let song = currentSong
        let playing = song != nil && isPlaying
        let songChanged = song?.id != lastWidgetSongID
        guard songChanged || playing != lastWidgetIsPlaying else { return }
        lastWidgetSongID = song?.id
        lastWidgetIsPlaying = playing

        let title = song?.title ?? "VibePod"
        let artist = song?.artist ?? String(localized: "Nothing playing")
        let artworkData = songChanged ? song?.artworkData : nil

        // Artwork downsampling and file writes stay off the main thread.
        widgetQueue.async {
            let artwork: Data?
            if song == nil {
                artwork = nil
            } else if songChanged {
                artwork = artworkData.flatMap { ArtworkImageCache.downsample($0, maxPixelSize: 240) }?
                    .jpegData(compressionQuality: 0.7)
            } else {
                artwork = WidgetStateStore.read()?.artworkData
            }
            let snapshot = WidgetNowPlayingSnapshot(
                hasTrack: song != nil,
                title: title,
                artist: artist,
                isPlaying: playing,
                artworkData: artwork,
                updatedAt: Date().timeIntervalSince1970
            )
            WidgetStateStore.write(snapshot)
            if let defaults = WidgetAppGroup.defaults, let data = try? JSONEncoder().encode(snapshot) {
                defaults.set(data, forKey: WidgetStateKey.snapshot)
            }
            DispatchQueue.main.async {
                WidgetCenter.shared.reloadTimelines(ofKind: WidgetKind.nowPlaying)
            }
        }
    }

    private func clearWidgetState() {
        lastWidgetSongID = nil
        lastWidgetIsPlaying = nil
        let snapshot = WidgetNowPlayingSnapshot(
            hasTrack: false,
            title: "VibePod",
            artist: String(localized: "Nothing playing"),
            isPlaying: false,
            artworkData: nil,
            updatedAt: Date().timeIntervalSince1970
        )
        WidgetStateStore.write(snapshot)
        if let defaults = WidgetAppGroup.defaults, let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: WidgetStateKey.snapshot)
        }
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetKind.nowPlaying)
    }

    // MARK: - Audio Session

    /// Only the category is set at launch: activating the session here would
    /// stop whatever the user was listening to in another app just by opening
    /// this one. The session is activated when playback actually starts.
    private func configureAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, policy: .longFormAudio)
            try? AVAudioSession.sharedInstance().setSupportsMultichannelContent(true)
        } catch {
            lastError = String(localized: "Audio session setup failed: \(error.localizedDescription)")
        }
    }

    private func activateAudioSession() {
        // Something else (the assistant, a Discord voice engine) may have left
        // the session in another category, which plays quieter.
        let session = AVAudioSession.sharedInstance()
        if session.category != .playback || session.mode != .default { configureAudioSession() }
        try? session.setActive(true)
    }

    private static let duckedVolume: Float = 0.15
    private var isDucked = false
    var baseVolume: Float { duckVolume * VolumeLeveling.gain(for: currentSong) }
    var duckVolume: Float { isDucked ? Self.duckedVolume : 1 }

    /// The current song's level is known (or the setting moved): heard now.
    func refreshVolumeLeveling() {
        guard mix == nil, !isMixingIn else { return }
        applyOutputVolume(baseVolume, fade: 0.8)
    }

    // AutoMix state (see the AutoMix extension).
    var autoMixPlan: AutoMixPlan?
    var planTask: Task<Void, Never>?
    var plannedPair: (from: UUID, to: UUID, options: String)?
    var mix: ActiveMix? {
        didSet {
            // The end only glows once the next song is about to be heard
            // (see stepMix): the fade-out starts long before it's audible.
            let glow: MixGlow = mix == nil ? .none : (mix?.switchedAt == nil ? mixGlow : .incoming)
            if glow != mixGlow { mixGlow = glow }
        }
    }
    /// Which end of the progress bar glows while songs mix.
    @Published var mixGlow = MixGlow.none
    var mixTimer: Timer?
    var isMixingIn = false

    /// Lowers the music under the assistant's voice (other apps duck through
    /// the audio session; this app's own players have to do it themselves).
    func setDucked(_ ducked: Bool) {
        if ducked { assistantHoldsAudio = true }
        guard ducked != isDucked else { return }
        isDucked = ducked
        guard mix == nil else { return } // the mix ramp picks it up
        applyOutputVolume(baseVolume, fade: 0.3)
        SingAlong.shared.playerDidChange()
    }

    /// Sing Along plays the song itself: the player keeps going, silent, as
    /// the clock.
    private var stageIsAudible = false
    /// The current song's volume, whoever plays it.
    private(set) var outputVolume: Float = 1

    func setStageAudible(_ audible: Bool) {
        stageIsAudible = audible
        applyOutputVolume(outputVolume)
    }

    /// A music video's own sound plays instead: the file goes on, silent,
    /// as the clock.
    private var videoIsAudible = false

    func setVideoAudible(_ audible: Bool) {
        guard audible != videoIsAudible else { return }
        videoIsAudible = audible
        applyOutputVolume(outputVolume, fade: 0.3)
    }

    /// The song ends here (its outro hidden by a lyrics mark): the next one
    /// plays, as if the file ended. On the audio's clock.
    struct OutroCutoff: Equatable {
        var songID: UUID
        var time: TimeInterval
    }

    var outroCutoff: OutroCutoff? {
        didSet {
            guard oldValue != outroCutoff else { return }
            if autoMixEnabled { prepareAutoMix() }
        }
    }

    /// Past the cutoff: on to the next song (AutoMix, when on, already
    /// handed over before it).
    private func checkOutroCutoff() {
        guard let cutoff = outroCutoff, cutoff.songID == currentSong?.id, isPlaying, mix == nil, !isSeeking,
              preciseCurrentTime >= cutoff.time, preciseCurrentTime < cutoff.time + 2 else { return }
        outroCutoff = nil
        handlePlaybackFinished()
    }

    /// The music video went on past the file and has now ended.
    func videoDidEnd() {
        handlePlaybackFinished()
    }

    private func applyOutputVolume(_ volume: Float, fade: TimeInterval = 0) {
        outputVolume = volume
        let heard = stageIsAudible || videoIsAudible ? 0 : volume
        if fade > 0 {
            audioPlayer?.setVolume(heard, fadeDuration: fade)
        } else {
            audioPlayer?.volume = heard
        }
        mediaPlayer?.volume = heard
    }

    /// Back to music playback after the assistant used the microphone.
    func restoreAudioSession() {
        configureAudioSession()
        if isPlaying { activateAudioSession() }
        // Leaving the microphone moves the route back too.
        routeChangeGraceEnd = Date().addingTimeInterval(2)
        assistantHoldsAudio = false
    }

    /// While the assistant uses the microphone, Bluetooth headphones and car
    /// systems switch profile: that route change isn't an unplug.
    private var assistantHoldsAudio = false
    private var routeChangeGraceEnd: Date?

    private var ignoresRouteChanges: Bool {
        assistantHoldsAudio || routeChangeGraceEnd.map { Date() < $0 } ?? false
    }

    // MARK: - Notifications

    private func setupNotifications() {
        let center = NotificationCenter.default
        center.addObserver(forName: LibraryService.songsRelinked, object: nil, queue: .main) { notification in
            let songs = notification.userInfo?["songs"] as? [UUID: Song] ?? [:]
            MainActor.assumeIsolated {
                MusicPlayerService.shared.replaceSongs(songs)
            }
        }
        // AVAudioSession posts on a background thread; hop to the main actor.
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { notification in
            let type = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                .flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            let options = (notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
                .map(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []
            MainActor.assumeIsolated {
                MusicPlayerService.shared.handleInterruption(type: type, options: options)
            }
        }
        center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { notification in
            let reason = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
                .flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
            MainActor.assumeIsolated {
                // Headphones unplugged: pause, like every audio app.
                if reason == .oldDeviceUnavailable, MusicPlayerService.shared.isPlaying, !MusicPlayerService.shared.ignoresRouteChanges {
                    MusicPlayerService.shared.pause()
                }
            }
        }
        // The media server crashed (often after a long time in background):
        // every player dies silently. Rebuild them instead of skipping songs.
        center.addObserver(forName: AVAudioSession.mediaServicesWereLostNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { MusicPlayerService.shared.mediaServicesLost = true }
        }
        center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { MusicPlayerService.shared.recoverMediaServices() }
        }
        center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { MusicPlayerService.shared.refreshCurrentTime() }
        }
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { MusicPlayerService.shared.saveState() }
        }
        center.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                MusicPlayerService.shared.saveState()
                MusicPlayerService.shared.clearWidgetState()
            }
        }
        center.addObserver(forName: HiddenSettings.didChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { MusicPlayerService.shared.updateNowPlayingInfo() }
        }
    }

    private func handleInterruption(type: AVAudioSession.InterruptionType?, options: AVAudioSession.InterruptionOptions) {
        switch type {
        case .began:
            wasPlayingBeforeInterruption = isPlaying
            if isPlaying { pause() }
        case .ended:
            // Only resume if we were the ones playing (a call shouldn't start
            // music the user had paused).
            if wasPlayingBeforeInterruption, options.contains(.shouldResume) { play() }
            wasPlayingBeforeInterruption = false
        default:
            break
        }
    }

    private func refreshCurrentTime() {
        let time = preciseCurrentTime
        guard time.isFinite else { return }
        currentTime = time
    }

    // MARK: - Playback Control

    /// Plays `song` within `queue`, keeping the current shuffle setting.
    func play(song: Song, from queue: [Song]) {
        let index = queue.firstIndex(of: song) ?? 0
        play(at: index, from: queue)
    }

    func play(at index: Int, from queue: [Song]) {
        guard queue.indices.contains(index) else { return }
        finishMix()
        restoreSavedTime = nil
        resetPlayNextBlock()
        originalQueue = queue
        self.queue = queue
        currentIndex = index
        if shuffleMode == .on { shuffleQueueKeepingCurrent() }
        playCurrent()
        saveState()
    }

    /// Album/playlist "Play" and "Shuffle" buttons: Play always plays in order
    /// from the top, Shuffle always shuffles (like Apple Music).
    func play(_ songs: [Song], shuffled: Bool) {
        guard !songs.isEmpty else { return }
        shuffleMode = shuffled ? .on : .off
        let start = shuffled ? Int.random(in: songs.indices) : 0
        play(at: start, from: songs)
    }

    /// Plays the song at `currentIndex`, moving forward (iteratively, never
    /// recursively) past files that can't be opened.
    private func playCurrent() {
        guard queue.indices.contains(currentIndex) else {
            stop()
            return
        }
        var savedTime = restoreSavedTime ?? 0
        restoreSavedTime = nil
        var failedTitle: String?

        for _ in 0..<queue.count {
            let song = queue[currentIndex]
            tearDownPlayers()
            let started = song.isMediaLibraryItem
                ? playMediaLibrarySong(song, from: savedTime)
                : playFile(song, from: savedTime)
            if started {
                if let failedTitle { reportError(String(localized: "Couldn't play “\(failedTitle)”")) }
                return
            }
            failedTitle = failedTitle ?? song.title
            savedTime = 0
            let nextIndex = currentIndex + 1
            if queue.indices.contains(nextIndex) {
                currentIndex = nextIndex
            } else if repeatMode == .all {
                currentIndex = 0
            } else {
                break
            }
        }
        showUnplayable(queue[currentIndex], title: failedTitle)
    }

    /// Nothing playable: show the song we stopped on, paused, with an error.
    private func showUnplayable(_ song: Song, title: String?) {
        tearDownPlayers()
        currentSong = song
        duration = song.duration
        currentTime = 0
        isPlaying = false
        stopStateSaveTimer()
        updateNowPlayingInfo()
        updateWidgetState()
        reportError(String(localized: "Couldn't play “\(title ?? song.title)”"))
    }

    /// Re-publishes even when the message repeats, so the toast shows again.
    private func reportError(_ message: String) {
        lastError = nil
        lastError = message
    }

    private func playFile(_ song: Song, from savedTime: TimeInterval) -> Bool {
        let url = song.playableFileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        // Always AVPlayer: AVAudioPlayer can't be spatialized (AirPods'
        // Spatial Audio, fixed or head-tracked) and plays the file plainer
        // than Music does.
        if Self.playsThroughAVPlayer { return playMediaLibrarySong(song, from: savedTime, url: url) }
        guard let player = try? AVAudioPlayer(contentsOf: url) else {
            // Some m4a/mp4 files AVAudioPlayer rejects play fine through AVPlayer.
            return playMediaLibrarySong(song, from: savedTime, url: url)
        }
        activateAudioSession()
        player.delegate = self
        player.prepareToPlay()
        if savedTime > 0 { player.currentTime = savedTime }
        audioPlayer = player
        applyOutputVolume(isMixingIn ? 0 : baseVolume)
        VolumeLeveling.measureIfNeeded(song)
        player.play()

        duration = player.duration
        currentTime = savedTime
        currentSong = song
        isPlaying = true
        startProgressTimer()
        didStartPlaying()
        return true
    }

    private static let playsThroughAVPlayer = true

    private func playMediaLibrarySong(_ song: Song, from savedTime: TimeInterval, url: URL? = nil) -> Bool {
        // No asset URL: protected (DRM) or cloud-only item.
        let url = url ?? song.fileURL
        guard url.scheme != "media-library" else { return false }
        activateAudioSession()
        let item = AVPlayerItem(url: url)
        // Stereo spatialized like in Music (Spatial Audio on AirPods).
        item.allowedAudioSpatializationFormats = .monoStereoAndMultichannel
        // A tap takes the audio off the system's own path: only when the
        // equalizer actually shapes it.
        if Equalizer.isOn { Equalizer.attach(to: item) }
        let player = AVPlayer(playerItem: item)
        mediaPlayer = player
        applyOutputVolume(isMixingIn ? 0 : baseVolume)
        VolumeLeveling.measureIfNeeded(song)

        mediaEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { MusicPlayerService.shared.handlePlaybackFinished() }
        }
        let itemID = ObjectIdentifier(item)
        mediaStatusObservation = item.observe(\.status, options: [.new]) { @Sendable item, _ in
            guard item.status == .failed else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let service = MusicPlayerService.shared
                    guard service.mediaPlayer?.currentItem.map(ObjectIdentifier.init) == itemID else { return }
                    service.handleAsyncFailure()
                }
            }
        }
        mediaTimeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { time in
            MainActor.assumeIsolated {
                let service = MusicPlayerService.shared
                guard !service.isSeeking, time.seconds.isFinite else { return }
                service.currentTime = time.seconds
                service.checkOutroCutoff()
                service.checkAutoMix()
                SingAlong.shared.playerDidChange()
            }
        }

        let startTime = min(savedTime, max(0, song.duration - 0.5))
        if startTime > 0 {
            player.seek(to: CMTime(seconds: startTime, preferredTimescale: 600))
        }
        player.play()

        duration = song.duration
        currentTime = startTime
        currentSong = song
        isPlaying = true
        didStartPlaying()
        return true
    }

    private func didStartPlaying() {
        SingAlong.shared.playerDidChange()
        prepareAutoMix()
        startStateSaveTimer()
        updateNowPlayingInfo()
        updateWidgetState()
    }

    /// A file that opened but failed while playing (decode error, failed
    /// asset): move on, at most once per queue item in a row.
    private var consecutiveAsyncFailures = 0
    fileprivate var mediaServicesLost = false

    /// Recreates the session and the player where the song was.
    fileprivate func recoverMediaServices() {
        mediaServicesLost = false
        consecutiveAsyncFailures = 0
        guard queue.indices.contains(currentIndex) else { return }
        let wasPlaying = isPlaying
        configureAudioSession()
        restoreSavedTime = currentTime
        playCurrent()
        if !wasPlaying { pause() }
    }

    /// Turning the equalizer on: a song playing through AVAudioPlayer moves
    /// to AVPlayer where it is, unless a mix is running.
    func reloadForEqualizer() {
        // Already on AVPlayer: the tap goes on the playing item.
        if let item = mediaPlayer?.currentItem, item.audioMix == nil {
            Equalizer.attach(to: item)
            return
        }
        guard audioPlayer != nil, mix == nil, !isMixingIn, queue.indices.contains(currentIndex) else { return }
        let wasPlaying = isPlaying
        restoreSavedTime = preciseCurrentTime
        playCurrent()
        if !wasPlaying { pause() }
    }

    private func handleAsyncFailure() {
        // Dead media server: every item fails. Wait for the reset, don't skip.
        if mediaServicesLost { return }
        let title = currentSong?.title ?? String(localized: "song")
        consecutiveAsyncFailures += 1
        guard consecutiveAsyncFailures < max(queue.count, 1) else {
            consecutiveAsyncFailures = 0
            if let song = queue[safe: currentIndex] ?? currentSong {
                showUnplayable(song, title: title)
            } else {
                pause()
            }
            return
        }
        reportError(String(localized: "Couldn't play “\(title)”"))
        let nextIndex = currentIndex + 1
        if queue.indices.contains(nextIndex) {
            currentIndex = nextIndex
        } else if repeatMode == .all, !queue.isEmpty {
            currentIndex = 0
        } else {
            consecutiveAsyncFailures = 0
            pause()
            return
        }
        playCurrent()
    }

    private func tearDownPlayers() {
        stopProgressTimer()
        remoteSeekTimer?.invalidate()
        remoteSeekTimer = nil
        audioPlayer?.delegate = nil
        audioPlayer?.stop()
        audioPlayer = nil
        if let mediaEndObserver {
            NotificationCenter.default.removeObserver(mediaEndObserver)
            self.mediaEndObserver = nil
        }
        mediaStatusObservation?.invalidate()
        mediaStatusObservation = nil
        if let mediaTimeObserver, let mediaPlayer {
            mediaPlayer.removeTimeObserver(mediaTimeObserver)
        }
        mediaTimeObserver = nil
        mediaPlayer?.pause()
        mediaPlayer = nil
    }

    func play() {
        if let mediaPlayer {
            activateAudioSession()
            mediaPlayer.play()
        } else if let audioPlayer {
            activateAudioSession()
            audioPlayer.play()
            startProgressTimer()
        } else {
            // Restored state: nothing is loaded yet.
            playCurrent()
            return
        }
        isPlaying = true
        startStateSaveTimer()
        updateNowPlayingPlaybackInfo()
        updateWidgetState()
        SingAlong.shared.playerDidChange()
    }

    func pause() {
        finishMix()
        remoteSeekTimer?.invalidate()
        remoteSeekTimer = nil
        audioPlayer?.pause()
        mediaPlayer?.pause()
        stopProgressTimer()
        stopStateSaveTimer()
        refreshCurrentTime()
        isPlaying = false
        saveState()
        updateNowPlayingPlaybackInfo()
        updateWidgetState()
        SingAlong.shared.playerDidChange()
    }

    func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    func stop() {
        finishMix()
        tearDownPlayers()
        stopStateSaveTimer()
        isPlaying = false
        currentSong = nil
        currentTime = 0
        duration = 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        publishPlaybackState()
        saveState()
        updateWidgetState()
        SingAlong.shared.playerDidChange()
    }

    func next() {
        finishMix()
        consecutiveAsyncFailures = 0
        // A restored, never-loaded song's position belongs to that song only.
        restoreSavedTime = nil
        let nextIndex = currentIndex + 1
        if queue.indices.contains(nextIndex) {
            currentIndex = nextIndex
            playCurrent()
        } else if repeatMode == .all, !queue.isEmpty {
            currentIndex = 0
            playCurrent()
        } else {
            // End of the queue: stop on the last track, ready to replay it.
            pause()
            seek(to: 0)
        }
        saveState()
    }

    /// Apple Music behavior: restart the song after 3 seconds, otherwise go back.
    func previous() {
        if preciseCurrentTime > 3 {
            seek(to: 0)
            return
        }
        skipToPreviousTrack()
    }

    func skipToPreviousTrack() {
        finishMix()
        consecutiveAsyncFailures = 0
        restoreSavedTime = nil
        let previousIndex = currentIndex - 1
        if queue.indices.contains(previousIndex) {
            currentIndex = previousIndex
            playCurrent()
        } else if repeatMode == .all, !queue.isEmpty {
            currentIndex = queue.count - 1
            playCurrent()
        } else {
            seek(to: 0)
        }
        saveState()
    }

    func seek(to time: TimeInterval) {
        finishMix()
        let clamped = max(0, min(time, duration > 0 ? duration : time))
        if let mediaPlayer {
            isSeeking = true
            seekCount &+= 1
            let seek = seekCount
            mediaPlayer.seek(to: CMTime(seconds: clamped, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        // A later seek replaced this one: it clears the flag itself.
                        guard MusicPlayerService.shared.seekCount == seek else { return }
                        MusicPlayerService.shared.isSeeking = false
                        SingAlong.shared.playerDidChange()
                    }
                }
            }
        } else if let audioPlayer {
            audioPlayer.currentTime = clamped
        } else {
            // Restored but not loaded yet: start from here on play.
            restoreSavedTime = clamped
        }
        currentTime = clamped
        updateNowPlayingPlaybackInfo()
        SingAlong.shared.playerDidChange()
        MusicVideoPlayer.shared.playerDidSeek()
    }

    func toggleRepeat() {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
        saveState()
    }

    func toggleShuffle() {
        if shuffleMode == .off {
            shuffleMode = .on
            shuffleQueueKeepingCurrent()
        } else {
            shuffleMode = .off
            restoreOriginalOrder()
        }
        saveState()
    }

    // MARK: - Queue

    func addToQueue(song: Song) {
        queue.append(song)
        originalQueue.append(song)
        saveState()
    }

    func addNextToQueue(song: Song) {
        guard !queue.isEmpty else {
            play(at: 0, from: [song])
            return
        }
        // The block only extends while the user is still before/inside it.
        if let anchor = playNextAnchor, currentIndex < anchor || currentIndex > anchor + pendingNextCount {
            resetPlayNextBlock()
        }
        let anchor = playNextAnchor ?? currentIndex
        let insertIndex = min(max(anchor + 1 + pendingNextCount, currentIndex + 1), queue.count)
        queue.insert(song, at: insertIndex)

        if shuffleMode == .off {
            // Unshuffled, the playing order *is* the original order.
            originalQueue = queue
        } else {
            // Keep the block's order in the unshuffled list too: insert after the
            // previous Play Next song (or after the current one).
            let base = lastPlayNextOriginalIndex
                ?? currentSong.flatMap { current in originalQueue.firstIndex { $0.id == current.id } }
                ?? (originalQueue.count - 1)
            let originalInsert = min(base + 1, originalQueue.count)
            originalQueue.insert(song, at: originalInsert)
            lastPlayNextOriginalIndex = originalInsert
        }
        playNextAnchor = anchor
        pendingNextCount += 1
        saveState()
    }

    func playQueueItem(at index: Int) {
        guard queue.indices.contains(index) else { return }
        finishMix()
        resetPlayNextBlock()
        restoreSavedTime = nil
        currentIndex = index
        playCurrent()
        saveState()
    }

    func removeFromQueue(at index: Int) {
        guard queue.indices.contains(index), index != currentIndex else { return }
        resetPlayNextBlock()
        let removed = queue.remove(at: index)
        // The visible queue may be shuffled: remove the matching song from the
        // unshuffled order instead of the same index.
        if shuffleMode == .off, originalQueue.indices.contains(index), originalQueue[index].id == removed.id {
            originalQueue.remove(at: index)
        } else if let originalIndex = originalQueue.firstIndex(where: { $0.id == removed.id }) {
            originalQueue.remove(at: originalIndex)
        }
        if index < currentIndex { currentIndex -= 1 }
        saveState()
    }

    func moveQueueItem(from source: Int, to destination: Int) {
        guard queue.indices.contains(source), source != currentIndex,
              destination > currentIndex, destination <= queue.count else { return }
        resetPlayNextBlock()
        let song = queue.remove(at: source)
        let target = destination > source ? destination - 1 : destination
        queue.insert(song, at: target)
        if shuffleMode == .off { originalQueue = queue }
        saveState()
    }

    func clearQueue() {
        stop()
        resetPlayNextBlock()
        queue = []
        originalQueue = []
        currentIndex = 0
        saveState()
    }

    private func resetPlayNextBlock() {
        lastPlayNextOriginalIndex = nil
        playNextAnchor = nil
        pendingNextCount = 0
    }

    private func shuffleQueueKeepingCurrent() {
        resetPlayNextBlock()
        guard queue.indices.contains(currentIndex) else {
            queue.shuffle()
            return
        }
        var shuffled = queue
        let current = shuffled.remove(at: currentIndex)
        shuffled.shuffle()
        shuffled.insert(current, at: 0)
        queue = shuffled
        currentIndex = 0
    }

    private func restoreOriginalOrder() {
        resetPlayNextBlock()
        queue = originalQueue
        if let current = currentSong, let index = queue.firstIndex(of: current) {
            currentIndex = index
        } else {
            currentIndex = min(currentIndex, max(queue.count - 1, 0))
        }
    }

    // MARK: - Progress

    private func startProgressTimer() {
        stopProgressTimer()
        guard audioPlayer != nil else { return }
        let timer = Timer(timeInterval: 0.25, repeats: true) { _ in
            MainActor.assumeIsolated {
                let service = MusicPlayerService.shared
                guard let player = service.audioPlayer, player.currentTime.isFinite else { return }
                service.currentTime = player.currentTime
                service.checkOutroCutoff()
                service.checkAutoMix()
                SingAlong.shared.playerDidChange()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        progressTimer = timer
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    private func handlePlaybackFinished() {
        consecutiveAsyncFailures = 0
        // The music video is longer and its sound is the one heard.
        if MusicVideoPlayer.shared.holdsSongEnd() { return }
        if repeatMode == .one {
            seek(to: 0)
            if let audioPlayer {
                audioPlayer.play()
            } else {
                mediaPlayer?.play()
            }
            updateNowPlayingPlaybackInfo()
            return
        }
        next()
    }

    // MARK: - Now Playing

    private func updateNowPlayingInfo() {
        guard let song = currentSong else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: song.title,
            MPMediaItemPropertyArtist: song.artist,
            MPMediaItemPropertyAlbumTitle: song.album,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: preciseCurrentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue
        ]
        if !HiddenSettings.hideNowPlayingArtwork,
           let image = ArtworkImageCache.shared.imageSync(for: song.artworkSource, points: 300) {
            // MediaPlayer calls this from a background queue: it must not be
            // main-actor isolated.
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { @Sendable _ in image }
        }
        // With Apple's Music Haptics chosen, the ISRC lets iOS find and play
        // the song's haptic track, even in the background.
        if UserDefaults.standard.bool(forKey: MusicHapticsService.appleStorageKey) {
            if let code = ISRCResolver.cached(for: song) {
                info[MPNowPlayingInfoPropertyInternationalStandardRecordingCode] = code
            } else {
                Task { [weak self] in
                    guard let code = await ISRCResolver.resolve(song), let self, self.currentSong?.id == song.id,
                          UserDefaults.standard.bool(forKey: MusicHapticsService.appleStorageKey) else { return }
                    self.nowPlayingInfo[MPNowPlayingInfoPropertyInternationalStandardRecordingCode] = code
                    MPNowPlayingInfoCenter.default().nowPlayingInfo = self.nowPlayingInfo
                }
            }
        }
        nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        publishPlaybackState()
    }

    /// Said outright as well as through the rate: inferred alone, the
    /// system player sometimes stayed on its pause button after a pause.
    private func publishPlaybackState() {
        MPNowPlayingInfoCenter.default().playbackState = currentSong == nil ? .stopped : (isPlaying ? .playing : .paused)
    }

    /// iOS's own video player (a music video full screen) takes the system
    /// player while it shows, and leaves it greyed out: ours again, every
    /// control on.
    func reclaimNowPlaying() {
        try? AVAudioSession.sharedInstance().setActive(true)
        let center = MPRemoteCommandCenter.shared()
        // It drops every handler as it leaves (ours too) and leaves its
        // ±10 s buttons in place of previous and next.
        let ours = [center.playCommand, center.pauseCommand, center.togglePlayPauseCommand,
                    center.nextTrackCommand, center.previousTrackCommand, center.changePlaybackPositionCommand,
                    center.seekForwardCommand, center.seekBackwardCommand]
        for command in ours {
            command.removeTarget(nil)
            command.isEnabled = true
        }
        for command in [center.skipForwardCommand, center.skipBackwardCommand] {
            command.removeTarget(nil)
            command.isEnabled = false
        }
        setupRemoteCommandCenter()
        updateNowPlayingInfo()
    }

    /// Republishes the Now Playing info, with or without the ISRC.
    func refreshNowPlayingInfo() {
        updateNowPlayingInfo()
    }

    private func updateNowPlayingPlaybackInfo() {
        guard currentSong != nil else { return }
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = preciseCurrentTime
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
        publishPlaybackState()
    }

    // MARK: - Remote Commands

    /// Remote command handlers are delivered on the main thread.
    private nonisolated static func onMain(_ body: @escaping @MainActor () -> Void) -> MPRemoteCommandHandlerStatus {
        if Thread.isMainThread {
            MainActor.assumeIsolated(body)
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated(body) }
        }
        return .success
    }

    private func setupRemoteCommandCenter() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { @Sendable _ in Self.onMain { MusicPlayerService.shared.play() } }
        center.pauseCommand.addTarget { @Sendable _ in Self.onMain { MusicPlayerService.shared.pause() } }
        center.togglePlayPauseCommand.addTarget { @Sendable _ in Self.onMain { MusicPlayerService.shared.togglePlayPause() } }
        center.nextTrackCommand.addTarget { @Sendable _ in Self.onMain { MusicPlayerService.shared.next() } }
        center.previousTrackCommand.addTarget { @Sendable _ in Self.onMain { MusicPlayerService.shared.previous() } }
        center.changePlaybackPositionCommand.addTarget { @Sendable event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = event.positionTime
            return Self.onMain { MusicPlayerService.shared.seek(to: position) }
        }
        center.seekForwardCommand.addTarget { @Sendable event in
            guard let event = event as? MPSeekCommandEvent else { return .commandFailed }
            let begins = event.type == .beginSeeking
            return Self.onMain { MusicPlayerService.shared.remoteSeek(begin: begins, step: 10) }
        }
        center.seekBackwardCommand.addTarget { @Sendable event in
            guard let event = event as? MPSeekCommandEvent else { return .commandFailed }
            let begins = event.type == .beginSeeking
            return Self.onMain { MusicPlayerService.shared.remoteSeek(begin: begins, step: -10) }
        }
    }

    private func remoteSeek(begin: Bool, step: TimeInterval) {
        remoteSeekTimer?.invalidate()
        remoteSeekTimer = nil
        guard begin else { return }
        let timer = Timer(timeInterval: 0.25, repeats: true) { _ in
            MainActor.assumeIsolated {
                let service = MusicPlayerService.shared
                service.seek(to: service.preciseCurrentTime + step / 2)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        remoteSeekTimer = timer
    }
}

// MARK: - AutoMix

extension MusicPlayerService {
    static let autoMixKey = "autoMix"

    private var autoMixEnabled: Bool { UserDefaults.standard.bool(forKey: Self.autoMixKey) }

    /// The song after the current one, as the queue would play it.
    private var upcomingIndex: Int? {
        if repeatMode == .one { return nil }
        if queue.indices.contains(currentIndex + 1) { return currentIndex + 1 }
        return repeatMode == .all && queue.count > 1 ? 0 : nil
    }

    /// Measures the current and next songs in the background and plans the
    /// handover. Rechecked when the queue or the settings change.
    func prepareAutoMix() {
        autoMixPlan = nil
        planTask?.cancel()
        plannedPair = nil
        guard autoMixEnabled, let from = currentSong, let index = upcomingIndex else { return }
        let to = queue[index]
        let options = AutoMixOptions.current
        plannedPair = (from.id, to.id, options.signature)
        let outDuration = outroCutoff.flatMap { $0.songID == from.id ? min(duration, $0.time) : nil } ?? duration
        let outVocals = AutoMixVocals(lyrics: Self.lyrics(for: from), duration: outDuration)
        let inVocals = AutoMixVocals(lyrics: Self.lyrics(for: to), duration: to.duration)
        planTask = Task { [weak self] in
            let plan = await AutoMixAnalyzer.shared.plan(
                from: from, to: to, outDuration: outDuration,
                outVocals: outVocals, inVocals: inVocals, options: options
            )
            guard !Task.isCancelled, let self, self.currentSong?.id == from.id else { return }
            self.autoMixPlan = plan
        }
    }

    static func lyrics(for song: Song) -> LRCLyrics? {
        let documents = URL.documentsDirectory
        let url = song.lrcFilePath.flatMap { LibraryService.resolveLyricsURL(stored: $0, documents: documents) }
            ?? LRCParser.findLRC(for: song.fileURL)
        return url.flatMap(LRCParser.parse(url:))
    }

    /// Called from the progress updates (4 Hz): starts the fade-out when the
    /// outgoing song reaches it.
    func checkAutoMix() {
        guard isPlaying, mix == nil, let song = currentSong else { return }
        guard autoMixEnabled, let index = upcomingIndex else {
            if plannedPair != nil { prepareAutoMix() }
            return
        }
        let pair = (song.id, queue[index].id, AutoMixOptions.current.signature)
        if plannedPair.map({ $0.from != pair.0 || $0.to != pair.1 || $0.options != pair.2 }) ?? true { prepareAutoMix() }
        guard let plan = autoMixPlan, plan.fromID == song.id, plan.toID == queue[index].id else { return }
        let now = preciseCurrentTime
        guard now >= plan.fadeStart - 0.3, now < plan.switchAt else { return }
        SingAlong.shared.mixWillStart(to: queue[index], at: plan.inStart)
        // The stage keeps the song fading out; the next one comes to the player.
        stageIsAudible = false
        let outgoing = MixingPlayer(audio: audioPlayer, media: mediaPlayer)
        mix = ActiveMix(plan: plan, outgoing: outgoing, outgoingGain: VolumeLeveling.gain(for: song))
        if let next = queue.indices.contains(index) ? queue[index] : nil { VolumeLeveling.measureIfNeeded(next) }
        let timer = Timer(timeInterval: 1 / 60, repeats: true) { _ in
            MainActor.assumeIsolated { MusicPlayerService.shared.stepMix() }
        }
        RunLoop.main.add(timer, forMode: .common)
        mixTimer = timer
    }

    private func stepMix() {
        guard var mix else { return }
        let plan = mix.plan
        let position = mix.outgoing.currentTime
        // Equal-power fade-out. A song with its own fade is already getting
        // quieter, so it stays up longer.
        let fadeProgress = min(1, max(0, (position - plan.fadeStart) / max(plan.end - plan.fadeStart, 0.01)))
        let outShape = plan.naturalFade ? pow(fadeProgress, 2) : fadeProgress
        let outVolume = Float(Double(duckVolume * mix.outgoingGain) * cos(outShape * .pi / 2))
        mix.outgoing.volume = SingAlong.shared.playsFade ? 0 : outVolume
        SingAlong.shared.mixDidStep(time: position, playing: mix.outgoing.isPlaying, volume: outVolume)

        if mix.switchedAt == nil {
            let remaining = plan.switchAt - position
            if remaining <= 1.5, mixGlow == .none { mixGlow = .outgoing }
            if remaining <= 1 / 60 || !mix.outgoing.isPlaying {
                mix.switchedAt = CACurrentMediaTime()
                self.mix = mix
                switchToIncoming(plan)
                return
            }
        } else if let switchedAt = mix.switchedAt {
            let inProgress = min(1, (CACurrentMediaTime() - switchedAt) / max(plan.overlap, 0.12))
            applyOutputVolume(Float(Double(baseVolume) * sin(inProgress * .pi / 2)))
            SingAlong.shared.playerDidChange()
            if inProgress >= 1, fadeProgress >= 1 || !mix.outgoing.isPlaying {
                mix.outgoing.stop()
                self.mix = nil
                mixTimer?.invalidate()
                mixTimer = nil
                SingAlong.shared.mixDidEnd()
                return
            }
        }
        self.mix = mix
    }

    /// The incoming song starts; the outgoing one keeps playing on its own,
    /// out of the way, until its fade is over.
    private func switchToIncoming(_ plan: AutoMixPlan) {
        guard let index = upcomingIndex, queue[index].id == plan.toID else {
            finishMix()
            return
        }
        audioPlayer?.delegate = nil
        audioPlayer = nil
        if let mediaEndObserver {
            NotificationCenter.default.removeObserver(mediaEndObserver)
            self.mediaEndObserver = nil
        }
        mediaStatusObservation?.invalidate()
        mediaStatusObservation = nil
        if let mediaTimeObserver, let mediaPlayer { mediaPlayer.removeTimeObserver(mediaTimeObserver) }
        mediaTimeObserver = nil
        mediaPlayer = nil

        consecutiveAsyncFailures = 0
        currentIndex = index
        restoreSavedTime = plan.inStart
        isMixingIn = true
        playCurrent()
        isMixingIn = false
        saveState()
        if currentSong?.id != plan.toID {
            finishMix()
        }
    }

    /// Ends a mix at once (skip, pause, seek). Before the switch the fading
    /// song is still the current one and just gets its volume back; after
    /// it, the incoming song takes over.
    func finishMix() {
        guard let mix else { return }
        if mix.switchedAt != nil { mix.outgoing.stop() }
        self.mix = nil
        mixTimer?.invalidate()
        mixTimer = nil
        applyOutputVolume(baseVolume)
        SingAlong.shared.mixDidEnd()
    }
}

extension AutoMixOptions {
    /// Changes when any setting does, so the plan is redone.
    var signature: String { "\(style.rawValue)\(crossfade)\(protectVocals)" }
}

/// The song being mixed out, whichever player it uses.
@MainActor
final class MixingPlayer {
    private var audio: AVAudioPlayer?
    private var media: AVPlayer?

    init(audio: AVAudioPlayer?, media: AVPlayer?) {
        self.audio = audio
        self.media = media
    }

    var currentTime: TimeInterval {
        if let audio { return audio.currentTime }
        let seconds = media?.currentTime().seconds ?? 0
        return seconds.isFinite ? seconds : 0
    }

    var isPlaying: Bool { audio?.isPlaying ?? (media.map { $0.rate != 0 } ?? false) }

    var volume: Float {
        get { audio?.volume ?? media?.volume ?? 0 }
        set {
            audio?.volume = newValue
            media?.volume = newValue
        }
    }

    func stop() {
        audio?.stop()
        media?.pause()
        audio = nil
        media = nil
    }
}

enum MixGlow {
    case none
    /// The song is fading out: the bar's end glows.
    case outgoing
    /// The next song has come in over it: the bar's start glows.
    case incoming
}

struct ActiveMix {
    let plan: AutoMixPlan
    let outgoing: MixingPlayer
    /// The outgoing song keeps its own leveling while it fades.
    var outgoingGain: Float = 1
    var switchedAt: CFTimeInterval?
}

// MARK: - AVAudioPlayerDelegate

extension MusicPlayerService: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let id = ObjectIdentifier(player)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let service = MusicPlayerService.shared
                guard let current = service.audioPlayer, ObjectIdentifier(current) == id else { return }
                service.handlePlaybackFinished()
            }
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                MusicPlayerService.shared.handleAsyncFailure()
            }
        }
    }
}


// MARK: - Volume leveling

/// Every song brought to about the same loudness. Players can't go past
/// full volume, so a song is turned down by however much the quietest may
/// be raised (the maximum boost): one that needs the whole boost plays at
/// full volume, a loud one lower. The loudness is a gated RMS measured once
/// per song.
enum VolumeLeveling {
    static let enabledKey = "volumeLeveling"
    static let maxBoostKey = "volumeLevelingMaxBoost"
    static let boostRange: ClosedRange<Double> = 0...12
    private static let levelsKey = "songLoudness"
    /// Where songs are brought to, in dB (gated RMS).
    private static let target: Float = -14
    /// Assumed until measured: a typical modern master.
    private static let assumed: Float = -11

    static var isOn: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
    static var maxBoost: Float {
        Float(UserDefaults.standard.object(forKey: maxBoostKey) as? Double ?? 6)
    }

    @MainActor private static var levels: [String: Float] = (UserDefaults.standard.dictionary(forKey: levelsKey) as? [String: Float]) ?? [:]
    @MainActor private static var measuring: Set<UUID> = []

    @MainActor static func gain(for song: Song?) -> Float {
        guard isOn, let song else { return 1 }
        let loudness = levels[song.id.uuidString] ?? assumed
        let boost = maxBoost
        let decibels = min(max(target - loudness, -24), boost) - boost
        return min(1, pow(10, decibels / 20))
    }

    @MainActor static func measureIfNeeded(_ song: Song) {
        guard isOn, levels[song.id.uuidString] == nil, !measuring.contains(song.id) else { return }
        measuring.insert(song.id)
        let url = song.isMediaLibraryItem ? song.fileURL : song.playableFileURL
        let id = song.id
        Task {
            let loudness = await Task.detached(priority: .utility) { Self.loudness(of: url) }.value
            measuring.remove(id)
            guard let loudness else { return }
            levels[id.uuidString] = loudness
            UserDefaults.standard.set(levels, forKey: levelsKey)
            if MusicPlayerService.shared.currentSong?.id == id { MusicPlayerService.shared.refreshVolumeLeveling() }
        }
    }

    /// Mean power of the 400 ms blocks, quiet ones (silence, fades) left out.
    nonisolated static func loudness(of url: URL) -> Float? {
        guard let samples = HapticAnalyzer.decode(url: url), samples.count > 22_050 else { return nil }
        let block = 8_820
        var powers: [Float] = []
        var start = 0
        while start + block <= samples.count {
            var meanSquare: Float = 0
            samples.withUnsafeBufferPointer { vDSP_measqv($0.baseAddress! + start, 1, &meanSquare, vDSP_Length(block)) }
            powers.append(meanSquare)
            start += block
        }
        let audible = powers.filter { $0 > 1e-7 }
        guard !audible.isEmpty else { return nil }
        let gate = audible.reduce(0, +) / Float(audible.count) * 0.1
        let kept = audible.filter { $0 >= gate }
        return 10 * log10(kept.reduce(0, +) / Float(max(1, kept.count)))
    }
}

// MARK: - Equalizer

/// A 10-band graphic equalizer, run in an audio processing tap on AVPlayer
/// items (AVAudioPlayer can't be tapped, so files go through AVPlayer while
/// it's on).
enum Equalizer {
    static let frequencies: [Double] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    static let range: ClosedRange<Double> = -12...12
    static let enabledKey = "equalizerEnabled"
    static let gainsKey = "equalizerGains"
    static let didChange = Notification.Name("Equalizer.didChange")
    private static let q = 1.41

    static var isOn: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    static var gains: [Double] {
        let stored = UserDefaults.standard.array(forKey: gainsKey) as? [Double] ?? []
        return stored.count == frequencies.count ? stored : Array(repeating: 0, count: frequencies.count)
    }

    struct Snapshot: Sendable {
        var version: Int
        var active: Bool
        var gains: [Double]
        var preGain: Float
        var limits: Bool
    }

    /// What the taps read on the audio thread.
    static let state = OSAllocatedUnfairLock(initialState: makeSnapshot(version: 1))

    private static func makeSnapshot(version: Int) -> Snapshot {
        let gains = gains
        let active = isOn && gains.contains { abs($0) > 0.05 }
        // Boosts are heard at full level (taking the curve's peak off the
        // whole signal made the music quieter than other apps); peaks that
        // would clip are rounded off by a soft limiter instead.
        let peak = response(gains: gains, at: stride(from: 0.0, through: 1.0, by: 1.0 / 160).map(frequency(atPosition:))).max() ?? 0
        return Snapshot(version: version, active: active, gains: gains, preGain: 1, limits: peak > 0.05)
    }

    static func setGains(_ gains: [Double]) {
        UserDefaults.standard.set(gains, forKey: gainsKey)
        publish()
    }

    @MainActor static func setOn(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: enabledKey)
        publish()
        if on { MusicPlayerService.shared.reloadForEqualizer() }
    }

    static func publish() {
        state.withLock { $0 = makeSnapshot(version: $0.version + 1) }
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    // MARK: Filters

    /// RBJ peaking filter, normalized: b0, b1, b2, a1, a2.
    static func coefficients(frequency: Double, gain: Double, sampleRate: Double) -> [Double] {
        guard frequency < sampleRate * 0.47, abs(gain) > 0.01 else { return [1, 0, 0, 0, 0] }
        let a = pow(10, gain / 40)
        let w0 = 2 * Double.pi * frequency / sampleRate
        let alpha = sin(w0) / (2 * q)
        let cosW = cos(w0)
        let a0 = 1 + alpha / a
        return [(1 + alpha * a) / a0, -2 * cosW / a0, (1 - alpha * a) / a0, -2 * cosW / a0, (1 - alpha / a) / a0]
    }

    /// The whole cascade's gain in dB at each frequency.
    static func response(gains: [Double], at freqs: [Double], sampleRate: Double = 44100) -> [Double] {
        let sections = zip(frequencies, gains).map { coefficients(frequency: $0, gain: $1, sampleRate: sampleRate) }
        return freqs.map { f in
            let w = 2 * Double.pi * f / sampleRate
            var db = 0.0
            for c in sections {
                // |B(e^jw)| / |A(e^jw)|
                let br = c[0] + c[1] * cos(w) + c[2] * cos(2 * w)
                let bi = -(c[1] * sin(w) + c[2] * sin(2 * w))
                let ar = 1 + c[3] * cos(w) + c[4] * cos(2 * w)
                let ai = -(c[3] * sin(w) + c[4] * sin(2 * w))
                db += 10 * log10((br * br + bi * bi) / max(ar * ar + ai * ai, 1e-12))
            }
            return db
        }
    }

    /// 20 Hz – 20 kHz on a log scale, position 0…1.
    static func frequency(atPosition x: Double) -> Double { 20 * pow(1000, x) }
    static func position(ofFrequency f: Double) -> Double { log(f / 20) / log(1000) }

    // MARK: Tap

    /// Puts a tap on the item's audio track; it passes audio through
    /// untouched while the equalizer is off or flat.
    @MainActor static func attach(to item: AVPlayerItem) {
        let asset = item.asset
        Task { @MainActor in
            guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
                  let tap = makeTap() else { return }
            let params = AVMutableAudioMixInputParameters(track: track)
            params.audioTapProcessor = tap
            let mix = AVMutableAudioMix()
            mix.inputParameters = [params]
            item.audioMix = mix
        }
    }

    private static func makeTap() -> MTAudioProcessingTap? {
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: Unmanaged.passRetained(EqualizerTapContext()).toOpaque(),
            init: { _, clientInfo, storage in storage.pointee = clientInfo },
            finalize: { tap in
                Unmanaged<EqualizerTapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
            },
            prepare: { tap, _, format in
                let context = Unmanaged<EqualizerTapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                context.prepare(format.pointee)
            },
            unprepare: nil,
            process: { tap, frames, _, buffers, framesOut, flagsOut in
                guard MTAudioProcessingTapGetSourceAudio(tap, frames, buffers, flagsOut, nil, framesOut) == noErr else { return }
                let context = Unmanaged<EqualizerTapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                context.process(UnsafeMutableAudioBufferListPointer(buffers), frames: Int(framesOut.pointee))
            }
        )
        var tap: MTAudioProcessingTap?
        guard MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PreEffects, &tap) == noErr else { return nil }
        return tap
    }
}

/// One tap's filter state, touched only on its audio thread.
final class EqualizerTapContext: @unchecked Sendable {
    private static let maxChannels = 8
    private static let bands = Equalizer.frequencies.count
    private static let delayStride = 2 * bands + 2

    private var setup: vDSP_biquad_Setup?
    private let delays = UnsafeMutablePointer<Float>.allocate(capacity: maxChannels * delayStride)
    private var sampleRate = 44100.0
    private var supported = true
    private var version = -1
    private var active = false
    private var preGain: Float = 1
    private var limits = false

    init() { delays.initialize(repeating: 0, count: Self.maxChannels * Self.delayStride) }

    deinit {
        if let setup { vDSP_biquad_DestroySetup(setup) }
        delays.deallocate()
    }

    func prepare(_ format: AudioStreamBasicDescription) {
        sampleRate = format.mSampleRate > 0 ? format.mSampleRate : 44100
        supported = format.mFormatFlags & kAudioFormatFlagIsFloat != 0 && format.mBitsPerChannel == 32
        version = -1
        active = false
    }

    func process(_ buffers: UnsafeMutableAudioBufferListPointer, frames: Int) {
        guard supported, frames > 0 else { return }
        if let pending = Equalizer.state.withLockIfAvailable({ $0.version == version ? nil : $0 }), let snapshot = pending {
            apply(snapshot)
        }
        guard active, let setup else { return }
        var channel = 0
        var gain = preGain
        for buffer in buffers {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let count = Int(buffer.mNumberChannels)
            for c in 0..<count where channel < Self.maxChannels {
                vDSP_biquad(setup, delays + channel * Self.delayStride, data + c, vDSP_Stride(count),
                            data + c, vDSP_Stride(count), vDSP_Length(frames))
                channel += 1
            }
            if gain != 1 { vDSP_vsmul(data, 1, &gain, data, 1, vDSP_Length(frames * count)) }
            if limits { Self.softLimit(data, count: frames * count) }
        }
    }

    /// Transparent below the knee; above it, peaks bend smoothly towards
    /// full scale instead of clipping.
    private static func softLimit(_ data: UnsafeMutablePointer<Float>, count: Int) {
        let knee: Float = 0.85, room: Float = 1 - knee
        for i in 0..<count {
            let x = data[i], m = abs(x)
            guard m > knee else { continue }
            let bent = knee + room * tanhf((m - knee) / room)
            data[i] = x < 0 ? -bent : bent
        }
    }

    private func apply(_ snapshot: Equalizer.Snapshot) {
        version = snapshot.version
        let wasActive = active
        active = snapshot.active
        guard active else { return }
        if !wasActive { delays.update(repeating: 0, count: Self.maxChannels * Self.delayStride) }
        let coefficients = zip(Equalizer.frequencies, snapshot.gains).flatMap {
            Equalizer.coefficients(frequency: $0, gain: $1, sampleRate: sampleRate)
        }
        if let setup { vDSP_biquad_DestroySetup(setup) }
        setup = vDSP_biquad_CreateSetup(coefficients, vDSP_Length(Self.bands))
        preGain = snapshot.preGain
        limits = snapshot.limits
    }
}
