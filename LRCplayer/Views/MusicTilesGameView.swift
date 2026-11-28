import Accelerate
import AVFoundation
#if targetEnvironment(macCatalyst)
import CoreAudio
#endif
import Synchronization
import SwiftUI
import UIKit

// MARK: - Chart

enum MusicTilesDifficulty: String, CaseIterable, Identifiable {
    case easy, normal, hard, precise

    static let storageKey = "musicTilesDifficulty"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .easy: String(localized: "Easy")
        case .normal: String(localized: "Normal")
        case .hard: String(localized: "Hard")
        case .precise: String(localized: "Precise")
        }
    }

    var symbol: String {
        switch self {
        case .easy: "gauge.with.dots.needle.0percent"
        case .normal: "gauge.with.dots.needle.50percent"
        case .hard: "gauge.with.dots.needle.100percent"
        case .precise: "metronome.fill"
        }
    }

    static var saved: MusicTilesDifficulty {
        UserDefaults.standard.string(forKey: storageKey).flatMap(Self.init) ?? .normal
    }

    /// Onset score a hit must clear (1 is the detector's line).
    fileprivate var threshold: Float {
        switch self {
        case .easy: 1.7
        case .normal: 1.25
        case .hard, .precise: 0.95
        }
    }

    /// Shortest time between two tiles.
    fileprivate var minGap: TimeInterval {
        switch self {
        case .easy: 0.34
        case .normal: 0.23
        case .hard: 0.15
        case .precise: 0.075
        }
    }

    /// Time a tile takes to fall from the top to the line.
    var fallDuration: TimeInterval {
        switch self {
        case .easy: 1.7
        case .normal: 1.35
        case .hard: 1.05
        case .precise: 1.0
        }
    }
}

struct MusicTile {
    /// What in the song the tile sits on.
    enum Kind { case low, high, word }

    let lane: Int
    let time: TimeInterval
    /// 0 for a tap tile.
    let duration: TimeInterval
    let kind: Kind

    var isHold: Bool { duration > 0 }
    var end: TimeInterval { time + duration }
}

/// Tiles placed on the song's own hits: kicks, snares and, with word-synced
/// lyrics, held words. The same song and difficulty always give the same chart.
enum MusicTilesChart {
    static let lanes = 4

    static func make(analysis: HapticAnalysis, vocals: VocalTimeline?, difficulty: MusicTilesDifficulty, seed: UUID) -> [MusicTile] {
        let frame = HapticAnalysis.frameDuration

        var hits = analysis.low.filter { $0.score > difficulty.threshold }.map {
            Hit(time: Double($0.frame) * frame, strength: 0.4 + 0.6 * $0.strength, hold: $0.sustain, kind: .low)
        }
        hits += analysis.high.filter { $0.score > difficulty.threshold * 1.1 && $0.strength > 0.3 }.map {
            Hit(time: Double($0.frame) * frame, strength: 0.3 + 0.5 * $0.strength, hold: 0, kind: .high)
        }
        // Long sung words become long tiles.
        for word in vocals?.words ?? [] where word.end - word.start >= 0.6 {
            hits.append(Hit(time: word.start, strength: 0.7, hold: word.end - word.start, kind: .word))
        }
        hits.sort { $0.time < $1.time }

        // Too close to the previous kept hit: keep the stronger.
        var kept: [Hit] = []
        for hit in hits where hit.time > 1 {
            if let last = kept.last, hit.time - last.time < difficulty.minGap {
                if hit.strength > last.strength + 0.15 || (hit.hold > 0 && last.hold == 0) { kept[kept.count - 1] = hit }
                continue
            }
            kept.append(hit)
        }

        // A strong hit followed by a breath is held until just before the next one.
        for index in kept.indices where kept[index].hold == 0 && kept[index].strength > 0.6 {
            let next = index + 1 < kept.count ? kept[index + 1].time : kept[index].time + 2
            let room = next - kept[index].time
            if room > 0.9 { kept[index].hold = min(2.5, room - 0.35) }
        }
        let minimumHold = max(0.45, difficulty.minGap * 2)

        return place(kept, difficulty: difficulty, seed: seed, minimumHold: minimumHold)
    }

    struct Hit {
        let time: TimeInterval
        let strength: Float
        var hold: TimeInterval
        let kind: MusicTile.Kind
        /// Two hands: two tiles at once.
        var chord = false
    }

    /// Lanes for the hits: quick runs climb like stairs, strong accents
    /// can take two hands.
    static func place(_ kept: [Hit], difficulty: MusicTilesDifficulty, seed: UUID, minimumHold: TimeInterval) -> [MusicTile] {
        var random = SplitMix(seed: seed)
        var tiles: [MusicTile] = []
        var busyUntil = [TimeInterval](repeating: -.infinity, count: lanes)
        var previousLane = -1
        var previousTime = -TimeInterval.infinity
        var step = 1
        for hit in kept {
            let free = (0..<lanes).filter { busyUntil[$0] < hit.time - 0.1 }
            guard !free.isEmpty else { continue }
            let close = hit.time - previousTime < 0.4
            var choices = free.filter { $0 != previousLane || !close }
            if choices.isEmpty { choices = free }
            var lane: Int
            if close, previousLane >= 0, random.next() % 3 != 0 {
                // Quick runs climb up or down the lanes, like stairs.
                var target = previousLane + step
                if !(0..<lanes).contains(target) { step = -step; target = previousLane + step }
                lane = choices.contains(target) ? target : choices[Int(random.next() % UInt64(choices.count))]
            } else {
                lane = choices[Int(random.next() % UInt64(choices.count))]
                if random.next() % 4 == 0 { step = -step }
            }
            let duration = hit.hold >= minimumHold ? hit.hold : 0
            tiles.append(MusicTile(lane: lane, time: hit.time, duration: duration, kind: hit.kind))
            busyUntil[lane] = hit.time + duration
            // The strongest hits on Hard take two hands.
            if (difficulty == .hard && duration == 0 && hit.strength > 0.9) || hit.chord,
               let other = free.filter({ $0 != lane && abs($0 - lane) >= 2 }).first {
                tiles.append(MusicTile(lane: other, time: hit.time, duration: 0, kind: hit.kind))
            }
            previousLane = lane
            previousTime = hit.time
        }
        return tiles
    }

    private struct SplitMix {
        var state: UInt64

        init(seed: UUID) {
            let bytes = withUnsafeBytes(of: seed.uuid) { Array($0) }
            state = bytes.reduce(0) { $0 &* 31 &+ UInt64($1) }
        }

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }
}

// MARK: - Game

enum MusicTilesJudgement {
    case perfect, great, good, miss

    var title: String {
        switch self {
        case .perfect: String(localized: "Perfect")
        case .great: String(localized: "Great")
        case .good: String(localized: "Good")
        case .miss: String(localized: "Miss")
        }
    }

    var points: Int {
        switch self {
        case .perfect: 3
        case .great: 2
        case .good: 1
        case .miss: 0
        }
    }
}

struct MusicTilesSession: Identifiable {
    let id = UUID()
    let song: Song
    let difficulty: MusicTilesDifficulty
}

/// What the playfield's HUD shows, apart from the game so a hit only
/// redraws the HUD.
@MainActor
final class MusicTilesHUD: ObservableObject {
    @Published var score = 0
    @Published var combo = 0
    @Published var livesLeft = MusicTilesGame.lives
    @Published var lastJudgement: (judgement: MusicTilesJudgement, id: Int)?
    @Published var progress: Double = 0
}

@MainActor
final class MusicTilesGame: ObservableObject {
    enum Phase: Equatable { case loading, ready, playing, paused, finished, failed }

    static let lives = 3
    /// How late a tile can still be caught.
    static let window: TimeInterval = 0.2
    static let countdownLength = 3

    @Published private(set) var phase: Phase = .loading
    // Not published here: each hit would redraw the whole screen. Only the
    // HUD follows them.
    private(set) var score = 0 { didSet { if hud.score != score { hud.score = score } } }
    private(set) var combo = 0 { didSet { if hud.combo != combo { hud.combo = combo } } }
    private(set) var bestCombo = 0
    private(set) var livesLeft = MusicTilesGame.lives { didSet { if hud.livesLeft != livesLeft { hud.livesLeft = livesLeft } } }
    private(set) var lastJudgement: (judgement: MusicTilesJudgement, id: Int)? { didSet { hud.lastJudgement = lastJudgement } }
    private(set) var progress: Double = 0 { didSet { hud.progress = progress } }
    let hud = MusicTilesHUD()
    /// 3, 2, 1 before the music starts.
    @Published private(set) var countdown: Int?
    @Published private(set) var isNewBest = false
    /// The song decoded but nothing in it is a hit (a drone, silence).
    @Published private(set) var hasNoBeats = false

    let song: Song
    let difficulty: MusicTilesDifficulty
    private(set) var tiles: [MusicTile] = []
    /// Per tile: judged, and for a long tile how far it was held.
    private(set) var judged: [MusicTilesJudgement?] = []
    private(set) var heldUntil: [TimeInterval?] = []
    private(set) var holding: [Int?] = Array(repeating: nil, count: MusicTilesChart.lanes)
    private(set) var counts: [MusicTilesJudgement: Int] = [:]

    /// Sound options, picked before playing (off each time).
    @Published private(set) var withoutVocals = false
    @Published private(set) var tilesPlayBeats = false
    /// While the song is decoded and, without vocals, separated.
    @Published private(set) var soundProgress: Double?
    @Published private(set) var soundFailed = false

    private var player: AVPlayer?
    private var stage: MusicTilesStage?
    private var stageTrack: StageTrack?
    private var hasVocals = false
    private var soundJob: Task<Void, Never>?
    private var separation: Task<Bool, Never>?
    private var endObserver: NSObjectProtocol?
    private var nextPending = 0
    private var judgementID = 0
    /// Before the music starts the clock runs on its own, so the first tiles
    /// get their full fall.
    private var leadInStart: CFTimeInterval?
    /// From the start to the song's first frame: the countdown, and more if
    /// the first tile needs it to fall all the way.
    private var leadIn: TimeInterval {
        max(Double(Self.countdownLength), Double(Self.countdownLength) + 0.4 - (tiles.first?.time ?? 0))
    }
    private var isPrerolled = false
    private var isPrerolling = false
    /// The player was told to start on the exact frame the lead-in ends.
    private var isScheduled = false
    private var lastPlayerTime: TimeInterval = 0
    private var lastPlayerSample: CFTimeInterval = 0
    /// The player reports its old position until a seek lands.
    private var isSeeking = false
    private let haptics = UIImpactFeedbackGenerator(style: .light)
    private let missFeedback = UINotificationFeedbackGenerator()

    init(session: MusicTilesSession) {
        song = session.song
        difficulty = session.difficulty
    }

    var bestScore: Int { UserDefaults.standard.integer(forKey: bestKey) }

    static let recentKey = "musicTilesRecent"

    /// Songs played in this game, latest first.
    static var recentIDs: [UUID] {
        recentIDs(from: UserDefaults.standard.string(forKey: recentKey) ?? "")
    }

    /// Stored as one string, so the picker's `@AppStorage` follows it.
    static func recentIDs(from raw: String) -> [UUID] {
        raw.split(separator: "\n").compactMap { UUID(uuidString: String($0)) }
    }

    private static func recordRecent(_ id: UUID) {
        let ids = [id] + recentIDs.filter { $0 != id }
        UserDefaults.standard.set(ids.prefix(6).map(\.uuidString).joined(separator: "\n"), forKey: recentKey)
    }
    private var bestKey: String { "musicTilesBest.\(song.id.uuidString).\(difficulty.rawValue)" }

    var accuracy: Double {
        let total = judged.compactMap { $0 }.count
        guard total > 0 else { return 0 }
        let points = judged.compactMap { $0?.points }.reduce(0, +)
        return Double(points) / Double(total * 3)
    }

    var stars: Int {
        guard phase == .finished else { return 0 }
        return accuracy >= 0.92 ? 3 : accuracy >= 0.78 ? 2 : accuracy >= 0.5 ? 1 : 0
    }

    func load() {
        guard phase == .loading, tiles.isEmpty else { return }
        let song = song
        let difficulty = difficulty
        let url = song.isMediaLibraryItem ? song.fileURL : song.playableFileURL
        let lyricsURL = AppModel.shared.libraryService.resolvedLyricsURL(for: song)
        Task {
            let tiles = await Task.detached(priority: .userInitiated) { () -> [MusicTile]? in
                let vocals = lyricsURL.flatMap { VocalTimeline(songID: song.id, lyricsURL: $0) }
                if difficulty == .precise {
                    guard let precise = PreciseTileAnalyzer.cached(for: song.id) ?? PreciseTileAnalyzer.analyze(url: url, songID: song.id) else { return nil }
                    return MusicTilesChart.makePrecise(precise, vocals: vocals, seed: song.id)
                }
                guard let analysis = HapticAnalyzer.cachedAnalysis(for: song.id) ?? HapticAnalyzer.analyze(url: url, songID: song.id) else { return nil }
                return MusicTilesChart.make(analysis: analysis, vocals: vocals, difficulty: difficulty, seed: song.id)
            }.value
            self.tiles = tiles ?? []
            self.hasNoBeats = tiles?.isEmpty == true
            self.reset()
            self.phase = .ready
        }
    }

    private func reset() {
        judged = Array(repeating: nil, count: tiles.count)
        heldUntil = Array(repeating: nil, count: tiles.count)
        holding = Array(repeating: nil, count: MusicTilesChart.lanes)
        counts = [:]
        score = 0
        combo = 0
        bestCombo = 0
        livesLeft = Self.lives
        progress = 0
        nextPending = 0
        lastJudgement = nil
        isNewBest = false
    }

    private var usesStage: Bool { withoutVocals || tilesPlayBeats }

    /// The song is ready to be played with the options picked.
    var isSoundReady: Bool {
        !usesStage || (stageTrack != nil && hasVocals)
    }

    func setWithoutVocals(_ on: Bool) {
        withoutVocals = on
        prepareSound()
    }

    func setTilesPlayBeats(_ on: Bool) {
        tilesPlayBeats = on
        prepareSound()
    }

    /// Decodes the song for the stage, and separates its vocals if they're
    /// to go (at once if it was already done for Sing Along).
    private func prepareSound() {
        guard soundJob == nil, !isSoundReady else {
            if isSoundReady { soundProgress = nil }
            return
        }
        soundFailed = false
        soundProgress = 0
        let url = song.isMediaLibraryItem ? song.fileURL : song.playableFileURL
        let id = song.id
        let needsVocals = !hasVocals
        let loaded = stageTrack
        soundJob = Task {
            let track: StageTrack?
            if let loaded {
                track = loaded
            } else {
                track = await Task.detached(priority: .userInitiated) { await StageTrack.load(url) }.value
            }
            guard let track, !Task.isCancelled else {
                soundJob = nil
                soundProgress = nil
                soundFailed = !Task.isCancelled
                return
            }
            stageTrack = track
            if needsVocals {
                let separation = Task.detached(priority: .userInitiated) {
                    await VocalSeparator.separateAll(track, id: id) { fraction in
                        Task { @MainActor [weak self] in
                            if self?.soundProgress != nil { self?.soundProgress = fraction }
                        }
                    }
                }
                self.separation = separation
                let separated = await separation.value
                self.separation = nil
                guard !Task.isCancelled else { return }
                hasVocals = separated
                if !separated {
                    withoutVocals = false
                    tilesPlayBeats = false
                    soundFailed = true
                }
            }
            soundJob = nil
            soundProgress = nil
            // The options may have changed meanwhile.
            prepareSound()
        }
    }

    /// Leaving the game.
    func cancelSound() {
        soundJob?.cancel()
        soundJob = nil
        separation?.cancel()
        separation = nil
    }

    func start() {
        guard phase == .ready || phase == .paused || phase == .finished || phase == .failed, !tiles.isEmpty else { return }
        guard isSoundReady else { return }
        reset()
        stopAudio()
        isPrerolled = false
        isScheduled = false
        if usesStage, let stageTrack {
            stage = MusicTilesStage(track: stageTrack, withoutVocals: withoutVocals, tiles: tiles, cutsBeats: tilesPlayBeats)
        } else {
            let player = AVPlayer(url: song.isMediaLibraryItem ? song.fileURL : song.playableFileURL)
            player.automaticallyWaitsToMinimizeStalling = false
            self.player = player
            endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: player.currentItem, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.finish(failed: false) }
            }
        }
        try? AVAudioSession.sharedInstance().setActive(true)
        haptics.prepare()
        leadInStart = CACurrentMediaTime()
        countdown = Self.countdownLength
        Self.recordRecent(song.id)
        phase = .playing
    }

    func pause() {
        guard phase == .playing else { return }
        player?.pause()
        stage?.pause()
        isScheduled = false
        isPrerolled = false
        countdown = nil
        phase = .paused
    }

    func resume() {
        guard phase == .paused else { return }
        // Picks up a second early, so the tiles on screen can be caught.
        let time = max(0, currentTime - 1)
        if leadInStart != nil {
            leadInStart = CACurrentMediaTime() - (time + leadIn)
        } else if let stage {
            stage.play(from: time, atHost: nil)
            lastPlayerTime = time
            lastPlayerSample = CACurrentMediaTime()
        } else {
            isSeeking = true
            player?.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { @Sendable _ in
                Task { @MainActor [weak self] in self?.isSeeking = false }
            }
            lastPlayerTime = time
            lastPlayerSample = CACurrentMediaTime()
            player?.play()
        }
        for lane in holding.indices { holding[lane] = nil }
        phase = .playing
    }

    func stop() {
        stopAudio()
        countdown = nil
        if phase == .playing { phase = .paused }
    }

    private func stopAudio() {
        player?.pause()
        player = nil
        stage?.stop()
        stage = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
    }

    /// Song time, smoothed between the player's own reports and moved back
    /// by the output latency, so tiles reach the line when you hear them.
    var currentTime: TimeInterval {
        if let leadInStart {
            return CACurrentMediaTime() - leadInStart - leadIn
        }
        return lastPlayerTime + (phase == .playing ? CACurrentMediaTime() - lastPlayerSample : 0)
            - AVAudioSession.sharedInstance().outputLatency
    }

    /// Called every frame by the board.
    func tick() {
        guard phase == .playing else { return }
        let now = CACurrentMediaTime()
        if let leadInStart {
            let elapsed = now - leadInStart
            let remaining = Self.countdownLength - Int(elapsed)
            let shown = remaining > 0 ? remaining : nil
            if countdown != shown { countdown = shown }
            prepareStart(at: leadInStart + leadIn, now: now)
            if elapsed >= leadIn {
                self.leadInStart = nil
                lastPlayerTime = elapsed - leadIn
                lastPlayerSample = now
                // Ready too late to be scheduled: starts now, where the
                // clock already is.
                if !isScheduled, let player {
                    player.seek(to: CMTime(seconds: lastPlayerTime, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                    player.play()
                } else if !isScheduled, let stage {
                    stage.play(from: lastPlayerTime, atHost: nil)
                }
            }
        } else if let stage {
            if stage.hasEnded {
                finish(failed: false)
                return
            }
            if let reported = stage.time(at: now) {
                let predicted = lastPlayerTime + (now - lastPlayerSample)
                lastPlayerTime = abs(reported - predicted) > 0.12 ? reported : predicted + (reported - predicted) * 0.05
                lastPlayerSample = now
            }
        } else if !isSeeking, let player, player.timeControlStatus == .playing {
            let reported = player.currentTime().seconds
            if reported.isFinite {
                let predicted = lastPlayerTime + (now - lastPlayerSample)
                // Follows the player, without the jitter of its reports.
                let corrected = abs(reported - predicted) > 0.12 ? reported : predicted + (reported - predicted) * 0.05
                lastPlayerTime = corrected
                lastPlayerSample = now
            }
        }

        let time = currentTime
        // Tiles that went past the line untouched.
        while nextPending < tiles.count, judged[nextPending] != nil { nextPending += 1 }
        var index = nextPending
        while index < tiles.count, tiles[index].time < time - Self.window {
            if judged[index] == nil {
                judge(index, .miss)
                if phase != .playing { return }
            }
            index += 1
        }
        // Long tiles held to their end.
        for lane in holding.indices {
            guard let held = holding[lane] else { continue }
            heldUntil[held] = min(time, tiles[held].end)
            if time >= tiles[held].end {
                holding[lane] = nil
                score += 2
            }
        }
        // Published sparingly: every change redraws the whole HUD.
        if let last = tiles.last {
            let value = min(1, max(0, time / max(1, last.end)))
            if abs(value - progress) > 0.002 { progress = value }
        }
    }

    /// Prerolls the player during the lead-in, then has it start on the
    /// exact host time the clock reaches the song's first frame, so the
    /// tiles never jump when the music kicks in.
    private func prepareStart(at hostTime: CFTimeInterval, now: CFTimeInterval) {
        if let stage {
            guard !isScheduled, hostTime - now > 0.05 else { return }
            stage.play(from: 0, atHost: hostTime)
            isScheduled = true
            return
        }
        guard let player, !isScheduled, player.currentItem?.status == .readyToPlay else { return }
        guard isPrerolled else {
            if player.rate == 0, !isPrerolling {
                isPrerolling = true
                player.preroll(atRate: 1) { @Sendable _ in
                    Task { @MainActor [weak self] in
                        self?.isPrerolling = false
                        self?.isPrerolled = true
                    }
                }
            }
            return
        }
        guard hostTime - now > 0.05 else { return }
        player.setRate(1, time: .zero, atHostTime: CMTime(seconds: hostTime, preferredTimescale: 1_000_000_000))
        isScheduled = true
    }

    /// `reach`: how early a tile counts, more when the finger lands on the
    /// tile itself above the line.
    func press(lane: Int, reach: TimeInterval) {
        guard phase == .playing, leadInStart == nil || currentTime > -1 else { return }
        let time = currentTime
        let candidate = tiles.indices[nextPending...].first {
            tiles[$0].lane == lane && judged[$0] == nil && tiles[$0].time > time - Self.window
        }
        guard let candidate, tiles[candidate].time - time < max(Self.window * 1.4, reach) else { return }
        let offset = abs(tiles[candidate].time - time)
        let judgement: MusicTilesJudgement = offset < 0.06 ? .perfect : offset < 0.12 ? .great : .good
        judge(candidate, judgement)
        if let beat = stage?.tileBeats[candidate] { stage?.trigger(beat) }
        if tiles[candidate].isHold {
            holding[lane] = candidate
            heldUntil[candidate] = time
        }
    }

    func release(lane: Int) {
        guard let held = holding[lane] else { return }
        holding[lane] = nil
        // Let go well before the end: the tile breaks the combo.
        if currentTime < tiles[held].end - 0.2 {
            combo = 0
        } else {
            score += 2
        }
    }

    private func judge(_ index: Int, _ judgement: MusicTilesJudgement) {
        judged[index] = judgement
        counts[judgement, default: 0] += 1
        judgementID += 1
        lastJudgement = (judgement, judgementID)
        if judgement == .miss {
            combo = 0
            livesLeft -= 1
            missFeedback.notificationOccurred(.error)
            if livesLeft <= 0 { finish(failed: true) }
            return
        }
        combo += 1
        bestCombo = max(bestCombo, combo)
        score += judgement.points * (1 + min(combo, 50) / 10)
        haptics.impactOccurred(intensity: judgement == .perfect ? 0.9 : 0.6)
    }

    private func finish(failed: Bool) {
        guard phase == .playing || phase == .paused else { return }
        stopAudio()
        for lane in holding.indices { holding[lane] = nil }
        phase = failed ? .failed : .finished
        if !failed, score > bestScore {
            isNewBest = bestScore > 0 || score > 0
            UserDefaults.standard.set(score, forKey: bestKey)
        }
    }
}

// MARK: - Stage

/// The game's own mix, played from memory: without the vocals, and without
/// the tiles' beats, each one coming back when its tile is tapped, at the
/// moment it's tapped. Its clock then replaces the player's.
final class MusicTilesStage: @unchecked Sendable {
    /// A beat cut out of the song: where it was, and its sound in the pool.
    private struct Beat {
        let start: Int
        let length: Int
        let offset: Int
    }

    private static let sampleRate = StageTrack.sampleRate
    private static let ringSize = 64
    private static let voiceCount = 8

    private let engine = AVAudioEngine()
    private var node: AVAudioSourceNode?
    private var configurationObserver: NSObjectProtocol?
    private let track: StageTrack
    /// Of the vocals, what's taken out: 1 without them, 0 with.
    private let vocalsCut: Float
    private let beatCount: Int
    private let beatList: UnsafeMutablePointer<Beat>
    private let poolLeft: UnsafeMutablePointer<Float>
    private let poolRight: UnsafeMutablePointer<Float>
    /// Per tile, the beat it plays (none for sung words).
    let tileBeats: [Int?]
    private let secondsPerTick: Double

    // Set from the main thread, read on the audio thread.
    private let playing = Atomic<Bool>(false)
    private let seekTarget = Atomic<Int>(-1)
    private let startHostBits = Atomic<UInt64>(0)
    private let ring = UnsafeMutablePointer<Int>.allocate(capacity: ringSize)
    private let ringHead = Atomic<Int>(0)
    // Written on the audio thread, read on the main thread.
    private let clockSample = Atomic<Int>(.min)
    private let clockHostBits = Atomic<UInt64>(0)
    private let ended = Atomic<Bool>(false)
    // Audio thread only.
    private var cursor = 0
    private var ringTail = 0
    private var nextBeat = 0
    private let voiceBeat = UnsafeMutablePointer<Int>.allocate(capacity: voiceCount)
    private let voicePosition = UnsafeMutablePointer<Int>.allocate(capacity: voiceCount)

    init(track: StageTrack, withoutVocals: Bool, tiles: [MusicTile], cutsBeats: Bool) {
        self.track = track
        vocalsCut = withoutVocals ? 1 : 0
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        secondsPerTick = Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
        voiceBeat.initialize(repeating: -1, count: Self.voiceCount)
        voicePosition.initialize(repeating: 0, count: Self.voiceCount)
        ring.initialize(repeating: 0, count: Self.ringSize)

        // One beat per hit (two tiles on the same hit share it), cut short
        // before the next one of its kind.
        let rate = Self.sampleRate
        var planned: [(start: Int, kind: MusicTile.Kind)] = []
        var tileBeats = [Int?](repeating: nil, count: tiles.count)
        if cutsBeats {
            var index: [String: Int] = [:]
            for (tile, item) in tiles.enumerated() where item.kind != .word {
                let start = max(0, Int((item.time - (item.kind == .low ? 0.03 : 0.02)) * rate))
                let key = "\(start / 64)-\(item.kind)"
                if let existing = index[key] {
                    tileBeats[tile] = existing
                } else {
                    index[key] = planned.count
                    tileBeats[tile] = planned.count
                    planned.append((start, item.kind))
                }
            }
        }
        var beats: [Beat] = []
        var offset = 0
        for (index, beat) in planned.enumerated() {
            let longest = Int((beat.kind == .low ? 0.24 : 0.14) * rate)
            let next = planned[(index + 1)...].first { $0.kind == beat.kind }?.start ?? .max
            let length = max(0, min(longest, next - beat.start, track.count - beat.start))
            beats.append(Beat(start: beat.start, length: length, offset: offset))
            offset += length
        }
        poolLeft = .allocate(capacity: max(1, offset))
        poolRight = .allocate(capacity: max(1, offset))
        for (beat, plan) in zip(beats, planned) {
            Self.extract(beat, kind: plan.kind, from: track, into: (poolLeft + beat.offset, poolRight + beat.offset))
        }
        // Played in time order.
        let order = beats.indices.sorted { beats[$0].start < beats[$1].start }
        var position = [Int](repeating: 0, count: beats.count)
        for (sorted, original) in order.enumerated() { position[original] = sorted }
        self.tileBeats = tileBeats.map { $0.map { position[$0] } }
        beatCount = beats.count
        beatList = .allocate(capacity: max(1, beats.count))
        beatList.initialize(from: order.map { beats[$0] }, count: beats.count)
    }

    deinit {
        stop()
        for buffer in [poolLeft, poolRight] { buffer.deallocate() }
        beatList.deallocate()
        ring.deallocate()
        voiceBeat.deallocate()
        voicePosition.deallocate()
    }

    /// The kick's lows, or the snare's highs, faded at both ends. What's
    /// left in the song plus this is exactly the song again.
    private static func extract(_ beat: Beat, kind: MusicTile.Kind, from track: StageTrack, into pool: (UnsafeMutablePointer<Float>, UnsafeMutablePointer<Float>)) {
        guard beat.length > 0 else { return }
        let cutoff = kind == .low ? 150.0 : 1_500.0
        let w0 = 2 * Double.pi * cutoff / sampleRate
        let alpha = sin(w0) / (2 * 0.7071)
        let a0 = 1 + alpha
        let b0 = Float((1 - cos(w0)) / 2 / a0), b1 = Float((1 - cos(w0)) / a0)
        let a1 = Float(-2 * cos(w0) / a0), a2 = Float((1 - alpha) / a0)
        let warmup = Int(0.05 * sampleRate)
        let first = max(0, beat.start - warmup)
        let fadeIn = Float(0.003 * sampleRate)
        let half = beat.length / 2
        for (channel, vocals, out) in [(track.left, track.vocalsLeft, pool.0), (track.right, track.vocalsRight, pool.1)] {
            // Two low-pass stages in a row.
            var state = [Float](repeating: 0, count: 8)
            for i in first..<(beat.start + beat.length) {
                // From the music alone: no bits of voice come and go with the taps.
                let x = channel[i] - vocals[i]
                var y = b0 * x + b1 * state[0] + b0 * state[1] - a1 * state[2] - a2 * state[3]
                state[1] = state[0]; state[0] = x; state[3] = state[2]; state[2] = y
                let z = b0 * y + b1 * state[4] + b0 * state[5] - a1 * state[6] - a2 * state[7]
                state[5] = state[4]; state[4] = y; state[7] = state[6]; state[6] = z
                y = z
                guard i >= beat.start else { continue }
                let j = i - beat.start
                var gain = min(1, Float(j) / fadeIn)
                if j > half { gain *= 0.5 * (1 + cos(Float.pi * Float(j - half) / Float(max(1, beat.length - half)))) }
                out[j] = (kind == .low ? y : x - y) * gain
            }
        }
    }

    /// Plays from `time`, on the dot of `host` if given (else at once).
    func play(from time: TimeInterval, atHost host: CFTimeInterval?) {
        ended.store(false, ordering: .relaxed)
        clockSample.store(.min, ordering: .relaxed)
        startHostBits.store(host?.bitPattern ?? 0, ordering: .relaxed)
        seekTarget.store(max(0, Int(time * Self.sampleRate)), ordering: .relaxed)
        playing.store(true, ordering: .relaxed)
        if node == nil { attach() }
        if !engine.isRunning { try? engine.start() }
    }

    func pause() {
        playing.store(false, ordering: .relaxed)
        clockSample.store(.min, ordering: .relaxed)
        if engine.isRunning { engine.pause() }
    }

    func stop() {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        playing.store(false, ordering: .relaxed)
        engine.stop()
        if let node { engine.detach(node) }
        node = nil
    }

    /// The beat comes back, from now.
    func trigger(_ beat: Int) {
        let head = ringHead.load(ordering: .relaxed)
        ring[head % Self.ringSize] = beat
        ringHead.store(head + 1, ordering: .releasing)
    }

    var hasEnded: Bool { ended.load(ordering: .relaxed) }

    /// Song time being played at `now`, once it has started.
    func time(at now: CFTimeInterval) -> TimeInterval? {
        let host = Double(bitPattern: clockHostBits.load(ordering: .relaxed))
        let sample = clockSample.load(ordering: .relaxed)
        guard sample != .min else { return nil }
        return Double(sample) / Self.sampleRate + (host > 0 ? now - host : 0)
    }

    private func attach() {
        let format = AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 2)!
        let node = AVAudioSourceNode(format: format) { [unowned self] _, timestamp, frameCount, buffers in
            let list = UnsafeMutableAudioBufferListPointer(buffers)
            guard list.count >= 2,
                  let left = list[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = list[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            self.render(Int(frameCount), timestamp: timestamp.pointee, left: left, right: right)
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        self.node = node
        configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            guard let self, self.node != nil, self.playing.load(ordering: .relaxed) else { return }
            try? self.engine.start()
        }
        engine.prepare()
    }

    private func render(_ count: Int, timestamp: AudioTimeStamp, left outL: UnsafeMutablePointer<Float>, right outR: UnsafeMutablePointer<Float>) {
        outL.update(repeating: 0, count: count)
        outR.update(repeating: 0, count: count)
        let seek = seekTarget.exchange(-1, ordering: .relaxed)
        if seek >= 0 {
            cursor = seek
            nextBeat = 0
            voiceBeat.update(repeating: -1, count: Self.voiceCount)
        }
        let head = ringHead.load(ordering: .acquiring)
        while ringTail < head {
            let beat = ring[ringTail % Self.ringSize]
            ringTail += 1
            guard beat >= 0, beat < beatCount else { continue }
            // A free voice, or else the one furthest along.
            var chosen = 0
            for voice in 0..<Self.voiceCount {
                if voiceBeat[voice] < 0 { chosen = voice; break }
                if voicePosition[voice] > voicePosition[chosen] { chosen = voice }
            }
            voiceBeat[chosen] = beat
            voicePosition[chosen] = 0
        }
        guard playing.load(ordering: .relaxed) else { return }

        let hostValid = timestamp.mFlags.contains(.hostTimeValid)
        let host = hostValid ? Double(timestamp.mHostTime) * secondsPerTick : 0
        var first = 0
        let startBits = startHostBits.load(ordering: .relaxed)
        if startBits != 0 {
            let wait = hostValid ? Int(((Double(bitPattern: startBits) - host) * Self.sampleRate).rounded()) : 0
            if wait >= count { return }
            first = max(0, wait)
            _ = startHostBits.compareExchange(expected: startBits, desired: 0, ordering: .relaxed)
        }
        clockHostBits.store(host.bitPattern, ordering: .relaxed)
        clockSample.store(cursor - first, ordering: .relaxed)

        let frames = count - first
        let start = cursor
        let end = cursor + frames
        let length = track.count
        let cut = vocalsCut
        for i in 0..<frames where start + i < length {
            let c = start + i
            outL[first + i] = track.left[c] - cut * track.vocalsLeft[c]
            outR[first + i] = track.right[c] - cut * track.vocalsRight[c]
        }
        // The tiles' beats are out of the song...
        while nextBeat < beatCount, beatList[nextBeat].start + beatList[nextBeat].length <= start { nextBeat += 1 }
        var index = nextBeat
        while index < beatCount, beatList[index].start < end {
            let beat = beatList[index]
            let from = max(start, beat.start)
            let to = min(end, beat.start + beat.length)
            if from < to {
                for c in from..<to {
                    outL[first + c - start] -= poolLeft[beat.offset + c - beat.start]
                    outR[first + c - start] -= poolRight[beat.offset + c - beat.start]
                }
            }
            index += 1
        }
        // ...and back when they're tapped.
        var sounding = false
        for voice in 0..<Self.voiceCount where voiceBeat[voice] >= 0 {
            let beat = beatList[voiceBeat[voice]]
            let position = voicePosition[voice]
            let n = min(frames, beat.length - position)
            for i in 0..<max(0, n) {
                outL[first + i] += poolLeft[beat.offset + position + i]
                outR[first + i] += poolRight[beat.offset + position + i]
            }
            voicePosition[voice] = position + max(0, n)
            if voicePosition[voice] >= beat.length { voiceBeat[voice] = -1 } else { sounding = true }
        }
        cursor = end
        if cursor >= length, !sounding { ended.store(true, ordering: .relaxed) }
    }
}

// MARK: - Board

/// Four lanes, tiles as layers moved every frame, every finger tracked.
private final class MusicTilesBoardView: UIView {
    var game: MusicTilesGame? {
        didSet { setNeedsLayout() }
    }

    private var link: CADisplayLink?
    private var laneLines: [CALayer] = []
    private let hitLine = CALayer()
    private var laneFlashes: [CALayer] = []
    private var tileLayers: [Int: TileLayer] = [:]
    private var spare: [TileLayer] = []
    private var touchLanes: [ObjectIdentifier: Int] = [:]
    private var renderStart = 0
    /// Tiles appear softly under the score instead of cutting in.
    private let fade = CAGradientLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        clipsToBounds = true
        for _ in 1..<MusicTilesChart.lanes {
            let line = CALayer()
            line.backgroundColor = UIColor.white.withAlphaComponent(0.1).cgColor
            layer.addSublayer(line)
            laneLines.append(line)
        }
        for _ in 0..<MusicTilesChart.lanes {
            let flash = CAGradientLayer()
            flash.colors = [UIColor.white.withAlphaComponent(0).cgColor, UIColor.white.withAlphaComponent(0.22).cgColor]
            flash.opacity = 0
            layer.addSublayer(flash)
            laneFlashes.append(flash)
        }
        hitLine.backgroundColor = UIColor.white.withAlphaComponent(0.55).cgColor
        hitLine.shadowColor = UIColor.white.cgColor
        hitLine.shadowOpacity = 0.8
        hitLine.shadowRadius = 6
        hitLine.shadowOffset = .zero
        layer.addSublayer(hitLine)
        // Made up front: the first tiles cost nothing when they appear.
        spare = (0..<16).map { _ in TileLayer() }
        fade.colors = [UIColor.clear.cgColor, UIColor.black.cgColor]
        fade.locations = [0.04, 0.2]
        layer.mask = fade
    }

    required init?(coder: NSCoder) { fatalError("init(coder:)") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        link?.invalidate()
        link = nil
        guard window != nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(step))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    private var laneWidth: CGFloat { bounds.width / CGFloat(MusicTilesChart.lanes) }
    private var lineY: CGFloat { bounds.height * 0.82 }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, line) in laneLines.enumerated() {
            line.frame = CGRect(x: laneWidth * CGFloat(index + 1) - 0.5, y: 0, width: 1, height: bounds.height)
        }
        for (index, flash) in laneFlashes.enumerated() {
            flash.frame = CGRect(x: laneWidth * CGFloat(index), y: 0, width: laneWidth, height: lineY)
        }
        hitLine.frame = CGRect(x: 0, y: lineY - 1, width: bounds.width, height: 2)
        fade.frame = bounds
        CATransaction.commit()
        render()
    }

    @objc private func step() {
        game?.tick()
        render()
    }

    private func render() {
        guard let game, bounds.height > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let speed = lineY / game.difficulty.fallDuration
        let tapHeight = min(bounds.height * 0.17, laneWidth * 1.5)
        let time = game.currentTime
        let visibleUntil = time + game.difficulty.fallDuration + 0.2
        let visibleFrom = time - (bounds.height - lineY + tapHeight) / speed

        var shown = Set<Int>()
        // Tiles long gone are never looked at again.
        // A restart rewinds the clock.
        if renderStart > game.tiles.count || (renderStart > 0 && game.tiles[renderStart - 1].end >= visibleFrom - 2) { renderStart = 0 }
        while renderStart < game.tiles.count, game.tiles[renderStart].end < visibleFrom - 2 { renderStart += 1 }
        // Tiles are in time order: stop at the first one above the screen.
        for index in renderStart..<game.tiles.count {
            let tile = game.tiles[index]
            if tile.time > visibleUntil { break }
            guard tile.end >= visibleFrom || game.holding[tile.lane] == index else { continue }
            let judgement = game.judged[index]
            // A hit tap tile fades out at once; a missed one keeps falling, red.
            if !tile.isHold, let judgement, judgement != .miss { continue }
            shown.insert(index)
            let tileLayer = tileLayers[index] ?? dequeue(for: index)
            var bottom = lineY + CGFloat(time - tile.time) * speed
            var height = tile.isHold ? max(tapHeight, CGFloat(tile.duration) * speed) : tapHeight
            // A held tile is eaten at the line, where the fill shows, not
            // under the finger.
            if tile.isHold, game.heldUntil[index] != nil, bottom > lineY {
                height = max(0, height - (bottom - lineY))
                bottom = lineY
            }
            tileLayer.frame = CGRect(x: laneWidth * CGFloat(tile.lane) + 3, y: bottom - height, width: laneWidth - 6, height: height)
            let heldFraction = game.heldUntil[index].map { CGFloat(($0 - tile.time) / max(tile.duration, 0.01)) } ?? 0
            tileLayer.update(isHold: tile.isHold, missed: judgement == .miss,
                             holding: game.holding[tile.lane] == index,
                             heldFraction: min(1, max(0, heldFraction)),
                             tapHeight: tapHeight)
        }
        for (index, tileLayer) in tileLayers where !shown.contains(index) {
            tileLayer.removeFromSuperlayer()
            tileLayers[index] = nil
            spare.append(tileLayer)
        }
    }

    private func dequeue(for index: Int) -> TileLayer {
        let tileLayer = spare.popLast() ?? TileLayer()
        layer.insertSublayer(tileLayer, below: hitLine)
        tileLayers[index] = tileLayer
        return tileLayer
    }

    // MARK: Touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let lane = min(MusicTilesChart.lanes - 1, max(0, Int(touch.location(in: self).x / laneWidth)))
            touchLanes[ObjectIdentifier(touch)] = lane
            flash(lane)
            guard let game else { continue }
            // A finger on the tile catches it, even a little above the line.
            let speed = lineY / game.difficulty.fallDuration
            let reach = min(0.6, (lineY - touch.location(in: self).y + 30) / speed)
            game.press(lane: lane, reach: reach)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            guard let lane = touchLanes.removeValue(forKey: ObjectIdentifier(touch)) else { continue }
            if !touchLanes.values.contains(lane) { game?.release(lane: lane) }
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchesEnded(touches, with: event)
    }

    private func flash(_ lane: Int) {
        let flash = laneFlashes[lane]
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 1
        animation.toValue = 0
        animation.duration = 0.25
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        flash.add(animation, forKey: "flash")
    }
}

private final class TileLayer: CALayer {
    private let fill = CAGradientLayer()
    private let head = CALayer()

    override init() {
        super.init()
        cornerRadius = 10
        cornerCurve = .continuous
        masksToBounds = true
        fill.colors = [UIColor.white.withAlphaComponent(0.25).cgColor, UIColor.white.cgColor]
        addSublayer(fill)
        head.cornerRadius = 8
        head.cornerCurve = .continuous
        addSublayer(head)
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("init(coder:)") }

    func update(isHold: Bool, missed: Bool, holding: Bool, heldFraction: CGFloat, tapHeight: CGFloat) {
        if missed {
            backgroundColor = UIColor.systemRed.withAlphaComponent(0.75).cgColor
            fill.isHidden = true
            head.isHidden = true
            return
        }
        if !isHold {
            backgroundColor = UIColor.white.withAlphaComponent(0.92).cgColor
            fill.isHidden = true
            head.isHidden = true
            return
        }
        // A long tile: a pale body, filled from the bottom as it is held,
        // with a solid head where the finger lands.
        backgroundColor = UIColor.white.withAlphaComponent(0.22).cgColor
        borderColor = UIColor.white.withAlphaComponent(0.5).cgColor
        borderWidth = 1
        // Held, the tile is eaten at the line: what is left of it lights up
        // from the line upward, brighter the further along it is.
        fill.isHidden = heldFraction <= 0
        let lit = min(bounds.height, max(tapHeight, bounds.height * (0.35 + heldFraction)))
        fill.frame = CGRect(x: 0, y: bounds.height - lit, width: bounds.width, height: lit)
        fill.opacity = holding ? 1 : 0.5
        head.isHidden = false
        head.backgroundColor = UIColor.white.withAlphaComponent(holding ? 1 : 0.92).cgColor
        head.frame = CGRect(x: 4, y: bounds.height - min(tapHeight * 0.5, bounds.height) + 4, width: bounds.width - 8, height: min(tapHeight * 0.5, bounds.height) - 8)
        head.isHidden = heldFraction > 0
    }
}

private struct MusicTilesBoard: UIViewRepresentable {
    let game: MusicTilesGame

    func makeUIView(context: Context) -> MusicTilesBoardView {
        let view = MusicTilesBoardView()
        view.game = game
        return view
    }

    func updateUIView(_ view: MusicTilesBoardView, context: Context) {
        view.game = game
    }
}

// MARK: - Screen

struct MusicTilesGameView: View {
    let onDismiss: () -> Void

    @StateObject private var game: MusicTilesGame
    @ObservedObject var playerVM: PlayerViewModel
    @State private var resumePlaybackOnExit = false

    init(session: MusicTilesSession, playerVM: PlayerViewModel, onDismiss: @escaping () -> Void) {
        self.playerVM = playerVM
        self.onDismiss = onDismiss
        _game = StateObject(wrappedValue: MusicTilesGame(session: session))
    }

    var body: some View {
        ZStack {
            background
            switch game.phase {
            case .loading:
                intro(isLoading: true)
            case .ready:
                intro(isLoading: false)
            case .playing, .paused:
                playfield
            case .finished, .failed:
                results
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .animation(.smooth(duration: 0.35), value: game.phase)
        .animation(.spring(duration: 0.4, bounce: 0.3), value: game.countdown)
        .onAppear {
            resumePlaybackOnExit = playerVM.isPlaying
            if resumePlaybackOnExit { playerVM.togglePlayPause() }
            game.load()
        }
        .onDisappear {
            game.stop()
            game.cancelSound()
            if resumePlaybackOnExit { playerVM.togglePlayPause() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            game.pause()
        }
    }

    private var background: some View {
        let colors = game.song.playerArtworkColors
        return ZStack {
            LinearGradient(colors: colors.isEmpty ? Song.fallbackArtworkColors : colors, startPoint: .topLeading, endPoint: .bottomTrailing)
            Rectangle().fill(.ultraThinMaterial)
            Color.black.opacity(game.phase == .playing || game.phase == .paused ? 0.55 : 0.3)
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.5), value: game.phase)
    }

    /// The cover's own color, for the main buttons.
    private var coverTint: Color {
        Color(uiColor: Song.albumBackgroundUIColor(for: game.song.artworkSource))
    }

    private var closeButton: some View {
        Button { finish() } label: {
            Image(systemName: "xmark")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 44, height: 44)
                .glassEffect(.regular.interactive(true), in: Circle())
        }
    }

    // MARK: Intro

    private func intro(isLoading: Bool) -> some View {
        VStack(spacing: 0) {
            HStack {
                closeButton
                Spacer()
                Text(game.difficulty.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .glassEffect(.regular, in: Capsule())
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)

            Spacer()

            ArtworkImage(source: game.song.artworkSource, points: 240)
                .frame(width: 240, height: 240)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: .black.opacity(0.35), radius: 24, y: 10)

            VStack(spacing: 4) {
                Text(game.song.title)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
                Text(game.song.artist)
                    .font(.system(size: 17))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .lineLimit(1)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 32)
            .padding(.top, 24)

            Group {
                if isLoading {
                    HStack(spacing: 8) {
                        ProgressView().tint(.white)
                        Text("Listening to the song…")
                    }
                } else if game.hasNoBeats {
                    Text("No beats to play in this song.")
                } else if game.tiles.isEmpty {
                    Text("This song couldn't be read.")
                } else if game.bestScore > 0 {
                    Text("Best: \(game.bestScore.formatted())")
                } else {
                    Text("Tap the tiles as they reach the line. Hold the long ones.")
                }
            }
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.white.opacity(0.55))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 40)
            .padding(.top, 16)

            Spacer()

            if !isLoading, !game.tiles.isEmpty {
                soundOptions
                    .padding(.horizontal, 24)
                    .padding(.bottom, 14)
            }

            Button { game.start() } label: {
                Label("Play", systemImage: "play.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
            }
            .buttonStyle(.glassProminent)
            .tint(coverTint)
            .disabled(isLoading || game.tiles.isEmpty || !game.isSoundReady)
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
        }
    }

    private var soundOptions: some View {
        VStack(alignment: .leading, spacing: 12) {
            let installed = SingAlongModel.shared.isInstalled
            soundToggle("Without Vocals", detail: installed ? String(localized: "Just the music, the vocals taken out on device.") : HiddenSettings.needsModelNote,
                        isOn: Binding(get: { game.withoutVocals }, set: { game.setWithoutVocals($0) }))
                .disabled(!installed)
                .opacity(installed ? 1 : 0.5)
            if installed, HiddenSettings.alphaFeatures {
                Divider().overlay(.white.opacity(0.12))
                soundToggle("Tiles Play the Beats", detail: String(localized: "Their beats leave the song and sound when you tap them."),
                            isOn: Binding(get: { game.tilesPlayBeats }, set: { game.setTilesPlayBeats($0) }))
            }
            if let progress = game.soundProgress {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).tint(.white)
                    Text(progress > 0 ? "Separating the song… \(Int(progress * 100))%" : "Preparing the song…")
                        .monospacedDigit()
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
            } else if game.soundFailed {
                Text("The song couldn't be prepared.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .padding(16)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .animation(.smooth(duration: 0.3), value: game.soundProgress == nil)
    }

    private func soundToggle(_ title: LocalizedStringKey, detail: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .tint(coverTint)
    }

    // MARK: Playfield

    private var playfield: some View {
        ZStack(alignment: .top) {
            MusicTilesBoard(game: game)
                .ignoresSafeArea()

            MusicTilesHUDView(hud: game.hud, onPause: { game.pause() })

            if let count = game.countdown, game.phase == .playing {
                Text("\(count)")
                    .font(.system(size: 120, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.3), radius: 20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .id(count)
                    .transition(.asymmetric(insertion: .scale(scale: 1.6).combined(with: .opacity), removal: .scale(scale: 0.6).combined(with: .opacity)))
                    .allowsHitTesting(false)
            }

            if game.phase == .paused {
                pauseOverlay
            }
        }
    }

    private var pauseOverlay: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
            VStack(spacing: 14) {
                Text("Paused")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.bottom, 12)
                Button { game.resume() } label: {
                    Label("Resume", systemImage: "play.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                }
                .buttonStyle(.glassProminent)
                .tint(coverTint)
                Button { game.start() } label: {
                    Label("Restart", systemImage: "arrow.counterclockwise")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                }
                .buttonStyle(.glass)
                Button { finish() } label: {
                    Text("Quit")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                }
                .buttonStyle(.glass)
            }
            .padding(.horizontal, 40)
        }
        .transition(.opacity)
    }

    // MARK: Results

    private var results: some View {
        VStack(spacing: 0) {
            HStack {
                closeButton
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)

            Spacer()

            ArtworkImage(source: game.song.artworkSource, points: 140)
                .frame(width: 140, height: 140)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(color: .black.opacity(0.35), radius: 18, y: 8)

            if game.phase == .finished {
                HStack(spacing: 10) {
                    ForEach(0..<3, id: \.self) { index in
                        Image(systemName: index < game.stars ? "star.fill" : "star")
                            .font(.system(size: 30, weight: .semibold))
                            .foregroundStyle(index < game.stars ? .yellow : .white.opacity(0.3))
                    }
                }
                .padding(.top, 24)
            } else {
                Text("Game Over")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.top, 24)
                Text("\(Int(game.progress * 100))% of the song")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.top, 4)
            }

            VStack(spacing: 2) {
                Text(game.score.formatted())
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                Text(game.isNewBest ? "New Best!" : "Best: \(game.bestScore.formatted())")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(game.isNewBest ? .yellow : .white.opacity(0.55))
            }
            .padding(.top, 16)

            HStack(spacing: 0) {
                stat("Perfect", game.counts[.perfect] ?? 0)
                stat("Great", game.counts[.great] ?? 0)
                stat("Good", game.counts[.good] ?? 0)
                stat("Miss", game.counts[.miss] ?? 0)
                stat("Combo", game.bestCombo)
            }
            .padding(.vertical, 14)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(.horizontal, 20)
            .padding(.top, 28)

            Spacer()

            VStack(spacing: 10) {
                Button { game.start() } label: {
                    Label("Play Again", systemImage: "arrow.counterclockwise")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                }
                .buttonStyle(.glassProminent)
                .tint(coverTint)
                Button { finish() } label: {
                    Text("Done")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                }
                .buttonStyle(.glass)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
        }
    }

    private func stat(_ title: LocalizedStringKey, _ value: Int) -> some View {
        VStack(spacing: 3) {
            Text("\(value)")
                .font(.system(size: 19, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
        }
        .frame(maxWidth: .infinity)
    }

    private func finish() {
        game.stop()
        onDismiss()
    }
}

private struct MusicTilesHUDView: View {
    @ObservedObject var hud: MusicTilesHUD
    let onPause: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                Button { onPause() } label: {
                    Image(systemName: "pause.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                        .frame(width: 44, height: 44)
                        .glassEffect(.regular.interactive(true), in: Circle())
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    Text(hud.score.formatted())
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(hud.score)))
                        .foregroundStyle(.white)
                    HStack(spacing: 4) {
                        ForEach(0..<MusicTilesGame.lives, id: \.self) { index in
                            Image(systemName: index < hud.livesLeft ? "heart.fill" : "heart")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(index < hud.livesLeft ? .white : .white.opacity(0.35))
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)

            ProgressView(value: hud.progress)
                .tint(.white)
                .padding(.horizontal, 20)
                .padding(.top, 10)

            Spacer()
            judgementLabel
            Spacer()
            Spacer()
        }
        .allowsHitTesting(true)
    }

    @ViewBuilder
    private var judgementLabel: some View {
        if let last = hud.lastJudgement {
            VStack(spacing: 2) {
                Text(last.judgement.title)
                    .font(.system(size: 24, weight: .heavy, design: .rounded))
                    .foregroundStyle(last.judgement == .miss ? Color.red : .white)
                if hud.combo > 1 {
                    Text("\(hud.combo) combo")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.7))
                        .monospacedDigit()
                }
            }
            .id(last.id)
            .transition(.asymmetric(insertion: .scale(scale: 1.25).combined(with: .opacity), removal: .opacity))
            .animation(.spring(duration: 0.25), value: last.id)
            .allowsHitTesting(false)
        }
    }
}

// MARK: - Song Picker

/// Pick the difficulty, then a song: by artist, or searched by name.
struct MusicTilesPickerView: View {
    let songs: [Song]
    var title = String(localized: "Music Tiles")
    /// A Cappella shares this picker, without the difficulty.
    var showsDifficulty = true
    let onCancel: () -> Void
    let onStart: (Song, MusicTilesDifficulty) -> Void

    @AppStorage(MusicTilesDifficulty.storageKey) private var difficultyRawValue = MusicTilesDifficulty.normal.rawValue
    @AppStorage private var recentRaw: String

    init(songs: [Song], title: String = String(localized: "Music Tiles"), showsDifficulty: Bool = true, recentKey: String = MusicTilesGame.recentKey,
         onCancel: @escaping () -> Void, onStart: @escaping (Song, MusicTilesDifficulty) -> Void) {
        self.songs = songs
        self.title = title
        self.showsDifficulty = showsDifficulty
        self.onCancel = onCancel
        self.onStart = onStart
        _recentRaw = AppStorage(wrappedValue: "", recentKey)
    }
    @State private var query = ""
    @State private var path = NavigationPath()
    @EnvironmentObject private var libraryVM: LibraryViewModel

    private var difficulty: MusicTilesDifficulty { MusicTilesDifficulty(rawValue: difficultyRawValue) ?? .normal }

    /// Playlists with at least one playable song.
    private var playlists: [Playlist] {
        let playable = Set(songs.map(\.id))
        return libraryVM.playlists.filter { $0.songs.contains(where: playable.contains) }
    }

    /// The artists with the most playable songs first.
    private var artists: [Artist] {
        // Grouped like the library, so names and chosen photos match Search.
        Dictionary(grouping: songs, by: LibraryIndex.artistName(for:))
            .map { Artist(name: $0.key, songs: $0.value, albumCount: Set($0.value.map(\.album)).count) }
            .sorted {
                $0.songs.count != $1.songs.count
                    ? $0.songs.count > $1.songs.count
                    : $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }

    /// Played here lately, alternating with the library's most played;
    /// recently played songs fill what's left.
    private var suggestedSongs: [Song] {
        let byID = Dictionary(songs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let recent = MusicTilesGame.recentIDs(from: recentRaw).compactMap { byID[$0] }
        let mostPlayed = songs.filter { $0.playCount > 0 }.sorted { $0.playCount > $1.playCount }.prefix(12)
        let lastPlayed = songs.filter { $0.lastPlayedAt != nil }.sorted { $0.lastPlayedAt! > $1.lastPlayedAt! }.prefix(12)
        var picked: [Song] = []
        var seen = Set<UUID>()
        func add(_ song: Song) {
            guard picked.count < 6, seen.insert(song.id).inserted else { return }
            picked.append(song)
        }
        for index in 0..<max(recent.count, mostPlayed.count) {
            if let song = recent[safe: index] { add(song) }
            if let song = Array(mostPlayed)[safe: index] { add(song) }
        }
        lastPlayed.forEach(add)
        return picked
    }

    private var results: [Song] {
        let query = query.trimmingCharacters(in: .whitespaces)
        return songs
            .filter { $0.title.localizedCaseInsensitiveContains(query) || $0.artist.localizedCaseInsensitiveContains(query) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            if showsDifficulty { difficultyPicker }
                            let recent = suggestedSongs
                            if !recent.isEmpty {
                                Text("Suggestions")
                                    .font(.title2.bold())
                                    .padding(.top, showsDifficulty ? 28 : 8)
                                    .padding(.bottom, 12)
                                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                                    ForEach(recent) { song in
                                        MusicTilesRecentCard(song: song, difficulty: difficulty) { onStart(song, difficulty) }
                                    }
                                }
                            }
                            let playlists = playlists
                            if !playlists.isEmpty {
                                Text("Playlists")
                                    .font(.title2.bold())
                                    .padding(.top, 28)
                                    .padding(.bottom, 12)
                                GeometryReader { proxy in
                                    PlaylistCoverFlow(playlists: playlists, width: proxy.size.width + 40) { path.append($0.id) }
                                        .padding(.horizontal, -20)
                                }
                                .frame(height: min(max((UIScreen.main.bounds.width) * 0.36, 130), 180) + 20 + 40)
                            }
                            Text("Artists")
                                .font(.title2.bold())
                                .padding(.top, 28)
                                .padding(.bottom, 12)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 14)], spacing: 14) {
                                ForEach(artists) { artist in
                                    NavigationLink(value: artist) {
                                        ArtistCard(artist: artist)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 24)
                    }
                    .scrollDismissesKeyboard(.immediately)
                } else {
                    List(results) { song in
                        MusicTilesSongRow(song: song, difficulty: difficulty) { onStart(song, difficulty) }
                    }
                    .listStyle(.plain)
                    .scrollDismissesKeyboard(.immediately)
                    .overlay {
                        if results.isEmpty { ContentUnavailableView.search(text: query) }
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Songs and Artists")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { onCancel() }
                }
            }
            .navigationDestination(for: Artist.self) { artist in
                MusicTilesArtistPage(artist: artist, difficulty: difficulty, onStart: onStart)
            }
            .navigationDestination(for: UUID.self) { id in
                if let playlist = libraryVM.playlist(withID: id) {
                    let byID = Dictionary(songs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                    List(playlist.songs.compactMap { byID[$0] }) { song in
                        MusicTilesSongRow(song: song, difficulty: difficulty) { onStart(song, difficulty) }
                    }
                    .listStyle(.plain)
                    .navigationTitle(playlist.name)
                }
            }
        }
        .tint(AppTint.current.color)
    }

    private var difficultyPicker: some View {
        GlassSegmentedPicker(
            String(localized: "Difficulty"),
            options: MusicTilesDifficulty.allCases,
            selection: Binding(get: { difficulty }, set: { difficultyRawValue = $0.rawValue }),
            title: \.title,
            commitsWhenSettled: true
        )
        .padding(.top, 8)
    }
}

/// Like an artist page: the albums in a cover flow, the centered one's
/// songs below. Searching looks through all of the artist's songs.
private struct MusicTilesArtistPage: View {
    let artist: Artist
    let difficulty: MusicTilesDifficulty
    let onStart: (Song, MusicTilesDifficulty) -> Void

    @State private var query = ""
    @State private var centered = 0

    private var albums: [Album] {
        let playable = Set(artist.songs.map(\.id))
        return AppModel.shared.libraryVM.albums
            .filter { ArtistMerges.main(for: $0.artist) == artist.name && $0.songs.contains { playable.contains($0.id) } }
            .sorted { ($0.year == 0 ? Int.max : -$0.year, $0.title) < ($1.year == 0 ? Int.max : -$1.year, $1.title) }
    }

    var body: some View {
        let albums = albums
        let playable = Set(artist.songs.map(\.id))
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let songs: [Song] = if !trimmed.isEmpty {
            artist.songs
                .filter { $0.title.localizedCaseInsensitiveContains(trimmed) || $0.album.localizedCaseInsensitiveContains(trimmed) }
                .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        } else if let album = albums[safe: centered] {
            album.songs.filter { playable.contains($0.id) }
        } else {
            artist.songs
        }
        GeometryReader { proxy in
            List {
                if trimmed.isEmpty, !albums.isEmpty {
                    AlbumCoverFlow(albums: albums, width: proxy.size.width) { centered = $0 }
                        .listRowInsets(EdgeInsets(top: 12, leading: 0, bottom: 12, trailing: 0))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
                ForEach(songs) { song in
                    MusicTilesSongRow(song: song, difficulty: difficulty) { onStart(song, difficulty) }
                }
            }
            .listStyle(.plain)
            .scrollDismissesKeyboard(.immediately)
            .animation(.smooth(duration: 0.25), value: centered)
        }
        .navigationTitle(artist.name)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Songs by \(artist.name)")
    }
}

/// Like the suggestions at the top of Home, with the best score.
private struct MusicTilesRecentCard: View {
    let song: Song
    let difficulty: MusicTilesDifficulty
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ArtworkImage(source: song.artworkSource, points: 56)
                    .frame(width: 56, height: 56)
                    .clipped()
                Text(song.title)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                let best = UserDefaults.standard.integer(forKey: "musicTilesBest.\(song.id.uuidString).\(difficulty.rawValue)")
                if best > 0 {
                    Text(best.formatted())
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.trailing, 8)
            .frame(height: 56)
            .background(Color.primary.opacity(colorScheme == .dark ? 0.1 : 0.06))
            .clipShape(.rect(cornerRadius: 8, style: .continuous))
            .contentShape(.rect(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct MusicTilesSongRow: View {
    let song: Song
    let difficulty: MusicTilesDifficulty
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ArtworkImage(source: song.artworkSource, points: 48)
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(song.title).foregroundStyle(.primary)
                    Text(song.artist).font(.subheadline).foregroundStyle(.secondary)
                }
                .lineLimit(1)
                Spacer(minLength: 8)
                let best = UserDefaults.standard.integer(forKey: "musicTilesBest.\(song.id.uuidString).\(difficulty.rawValue)")
                if best > 0 {
                    Text(best.formatted())
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Precise charts

extension MusicTilesChart {
    /// Every real hit, on the song's own beat grid (which follows its tempo
    /// changes), and long tiles wherever a note or a chord is held.
    static func makePrecise(_ analysis: PreciseTileAnalysis, vocals: VocalTimeline?, seed: UUID) -> [MusicTile] {
        var hits = analysis.hits.map {
            Hit(time: $0.time, strength: $0.strength, hold: $0.hold, kind: $0.band == 0 ? .low : .high, chord: $0.chord)
        }
        // Long sung words: held like notes, if nothing's held there yet.
        for word in vocals?.words ?? [] where word.end - word.start >= 0.6 {
            if let index = hits.firstIndex(where: { abs($0.time - word.start) < 0.09 }) {
                if hits[index].hold < word.end - word.start { hits[index].hold = word.end - word.start }
            } else {
                hits.append(Hit(time: word.start, strength: 0.7, hold: word.end - word.start, kind: .word))
            }
        }
        hits.sort { $0.time < $1.time }
        var kept: [Hit] = []
        for hit in hits where hit.time > 0.8 {
            if let last = kept.last, hit.time - last.time < MusicTilesDifficulty.precise.minGap {
                if hit.strength > last.strength || (hit.hold > 0 && last.hold == 0) { kept[kept.count - 1] = hit }
                continue
            }
            kept.append(hit)
        }
        return place(kept, difficulty: .precise, seed: seed, minimumHold: 0.4)
    }
}

struct PreciseTileAnalysis: Codable {
    struct Hit: Codable {
        let time: TimeInterval
        let strength: Float
        var hold: TimeInterval
        /// 0 low, 1 mid, 2 high: where most of the hit is.
        let band: Int
        var chord: Bool
    }
    let beats: [TimeInterval]
    let hits: [Hit]
}

/// The audio, heard closely: onsets in three bands, the beat followed
/// through tempo changes (tempo per window, then beat tracking with that
/// local period), hits snapped to the grid, and held notes found where the
/// spectrum changes on a hit then stays put.
enum PreciseTileAnalyzer {
    private static let version = 1
    private static let sampleRate = 22_050.0
    private static let frameSize = 1024
    private static let hop = 256
    private static var dt: Double { Double(hop) / sampleRate }

    private static func cacheURL(for id: UUID) -> URL {
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("MusicTilesPrecise", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("\(id.uuidString)-v\(version).json")
    }

    static func cached(for id: UUID) -> PreciseTileAnalysis? {
        (try? Data(contentsOf: cacheURL(for: id))).flatMap { try? JSONDecoder().decode(PreciseTileAnalysis.self, from: $0) }
    }

    static func analyze(url: URL, songID: UUID) -> PreciseTileAnalysis? {
        guard let samples = HapticAnalyzer.decode(url: url), samples.count > frameSize * 8,
              let analysis = analyze(samples) else { return nil }
        if let data = try? JSONEncoder().encode(analysis) { try? data.write(to: cacheURL(for: songID), options: .atomic) }
        return analysis
    }

    private static let toneBands = 36

    private static func analyze(_ samples: [Float]) -> PreciseTileAnalysis? {
        let half = frameSize / 2
        guard let fft = vDSP.FFT(log2n: vDSP_Length(log2(Double(frameSize))), radix: .radix2, ofType: DSPSplitComplex.self) else { return nil }
        let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: frameSize, isHalfWindow: false)
        let binHz = sampleRate / Double(frameSize)
        let lowEnd = Int(150 / binHz), highStart = Int(2_500 / binHz)
        // Log-spaced bands from 100 Hz to 4 kHz: what notes and chords are.
        let edges = (0...toneBands).map { Int((100 * pow(40, Double($0) / Double(toneBands))) / binHz) }

        var fluxLow: [Float] = [], fluxMid: [Float] = [], fluxHigh: [Float] = []
        var tone: [Float] = []   // frames × toneBands, log energies
        var level: [Float] = []
        var previous = [Float](repeating: 0, count: half)
        var real = [Float](repeating: 0, count: half), imag = [Float](repeating: 0, count: half)
        var magnitudes = [Float](repeating: 0, count: half)
        var frame = [Float](repeating: 0, count: frameSize)
        var start = 0
        while start + frameSize <= samples.count {
            vDSP.multiply(samples[start..<(start + frameSize)], window, result: &frame)
            real.withUnsafeMutableBufferPointer { r in
                imag.withUnsafeMutableBufferPointer { i in
                    var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                    frame.withUnsafeBytes { vDSP_ctoz($0.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(half)) }
                    fft.forward(input: split, output: &split)
                    vDSP.absolute(split, result: &magnitudes)
                }
            }
            var energy: Float = 0
            for band in 0..<toneBands {
                var sum: Float = 0
                for bin in edges[band]..<max(edges[band] + 1, edges[band + 1]) where bin < half { sum += magnitudes[bin] }
                energy += sum
                tone.append(log(1 + sum))
            }
            level.append(log(1 + energy))
            vDSP.add(1, magnitudes, result: &magnitudes)
            magnitudes = vForce.log(magnitudes)
            var low: Float = 0, mid: Float = 0, high: Float = 0
            for bin in 1..<half {
                let rise = max(0, magnitudes[bin] - previous[bin])
                if bin <= lowEnd { low += rise } else if bin < highStart { mid += rise } else { high += rise }
            }
            fluxLow.append(low); fluxMid.append(mid); fluxHigh.append(high)
            previous = magnitudes
            start += hop
        }
        let count = fluxLow.count
        guard count > 200 else { return nil }

        // Onset strength: each band against its own loud end.
        let lowTop = max(percentile(fluxLow, 0.97), .ulpOfOne), midTop = max(percentile(fluxMid, 0.97), .ulpOfOne), highTop = max(percentile(fluxHigh, 0.97), .ulpOfOne)
        var onset = [Float](repeating: 0, count: count)
        for i in 0..<count { onset[i] = fluxLow[i] / lowTop + 0.8 * fluxMid[i] / midTop + 0.6 * fluxHigh[i] / highTop }
        let top = max(percentile(onset, 0.985), .ulpOfOne)
        let localMean = movingAverage(onset, radius: Int(0.35 / dt))

        // Peaks above the local level.
        struct Peak { let frame: Int; let strength: Float; let band: Int }
        var peaks: [Peak] = []
        let reach = 3
        for i in reach..<(count - reach) {
            let value = onset[i]
            guard value > localMean[i] * 1.3 + top * 0.08 else { continue }
            guard (i - reach...i + reach).allSatisfy({ $0 == i || onset[$0] < value || ($0 > i && onset[$0] <= value) }) else { continue }
            let parts = [fluxLow[i] / lowTop, 0.8 * fluxMid[i] / midTop, 0.6 * fluxHigh[i] / highTop]
            peaks.append(Peak(frame: i, strength: min(1, value / top), band: parts.indices.max { parts[$0] < parts[$1] } ?? 1))
        }

        // Tempo per window, kept steady unless the song really changes.
        let novelty = zip(onset, movingAverage(onset, radius: Int(0.5 / dt))).map { max(0, $0 - $1) }
        let minLag = Int((60 / 200) / dt), maxLag = Int((60 / 55) / dt)
        let windowLength = Int(6 / dt), windowHop = Int(1 / dt)
        var centers: [Int] = [], salience: [[Float]] = []
        var w = 0
        while w + windowLength <= count || centers.isEmpty {
            let slice = Array(novelty[w..<min(count, w + windowLength)])
            var ac = [Float](repeating: 0, count: 2 * maxLag + 2)
            for lag in minLag...min(2 * maxLag + 1, slice.count - 1) {
                var sum: Float = 0
                for t in 0..<(slice.count - lag) { sum += slice[t] * slice[t + lag] }
                ac[lag] = sum / Float(slice.count - lag)
            }
            var row = [Float](repeating: 0, count: maxLag + 1)
            for lag in minLag...maxLag {
                let bpm = 60 / (Double(lag) * dt)
                let prior = Float(exp(-0.5 * pow(log2(bpm / 120) / 0.9, 2)))
                row[lag] = (ac[lag] + 0.5 * ac[min(2 * lag, ac.count - 1)]) * prior
            }
            let peak = max(row.max() ?? 0, .ulpOfOne)
            salience.append(row.map { $0 / peak })
            centers.append(min(count - 1, w + windowLength / 2))
            if w + windowLength >= count { break }
            w += windowHop
        }
        // Viterbi over lags.
        var score = salience[0], back: [[Int]] = []
        for index in 1..<salience.count {
            var next = [Float](repeating: -.infinity, count: maxLag + 1), links = [Int](repeating: minLag, count: maxLag + 1)
            for lag in minLag...maxLag {
                var best: Float = -.infinity, arg = lag
                for prior in minLag...maxLag {
                    let change = log(Float(lag) / Float(prior))
                    let value = score[prior] - 20 * change * change
                    if value > best { best = value; arg = prior }
                }
                next[lag] = best + salience[index][lag]
                links[lag] = arg
            }
            score = next; back.append(links)
        }
        var lags = [Int](repeating: minLag, count: salience.count)
        lags[lags.count - 1] = (minLag...maxLag).max { score[$0] < score[$1] } ?? minLag
        for index in stride(from: salience.count - 1, to: 0, by: -1) { lags[index - 1] = back[index - 1][lags[index]] }
        var period = [Double](repeating: Double(lags[0]), count: count)
        for index in 0..<(centers.count - 1) {
            let a = centers[index], b = centers[index + 1]
            for t in a..<b { period[t] = Double(lags[index]) + Double(lags[index + 1] - lags[index]) * Double(t - a) / Double(max(1, b - a)) }
        }
        if let lastCenter = centers.last { for t in lastCenter..<count { period[t] = Double(lags.last!) } }

        // Beats: the best path through the onsets with that local period.
        let mean = novelty.reduce(0, +) / Float(count)
        let deviation = max(sqrt(novelty.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(count)), .ulpOfOne)
        let normalized = novelty.map { Double($0 / deviation) }
        var total = normalized, link = [Int](repeating: -1, count: count)
        for t in 0..<count {
            let p = period[t]
            let from = t - Int(2 * p), to = t - Int(p / 2)
            guard to > 0 else { continue }
            var best = -Double.infinity, arg = -1
            for prior in max(0, from)...to {
                let ratio = log(Double(t - prior) / p)
                let value = total[prior] - 100 * ratio * ratio
                if value > best { best = value; arg = prior }
            }
            if arg >= 0, best > 0 { total[t] += best; link[t] = arg }
        }
        let tailStart = max(0, count - Int(period[count - 1]) - 1)
        var beat = (tailStart..<count).max { total[$0] < total[$1] } ?? count - 1
        var beatFrames: [Int] = []
        while beat >= 0 { beatFrames.append(beat); beat = link[beat] }
        beatFrames.reverse()
        let beats = beatFrames.map { Double($0) * dt }

        // Held notes: the spectrum changes on the hit, then stays put.
        let bands = toneBands
        var bandMean = [Float](repeating: 0, count: bands)
        for t in 0..<count { for b in 0..<bands { bandMean[b] += tone[t * bands + b] } }
        bandMean = bandMean.map { $0 / Float(count) }
        func correlation(_ a: Int, _ b: Int) -> Float {
            guard a >= 0, b >= 0, a < count, b < count else { return 0 }
            var dot: Float = 0, na: Float = 0, nb: Float = 0
            for k in 0..<bands {
                let x = tone[a * bands + k] - bandMean[k], y = tone[b * bands + k] - bandMean[k]
                dot += x * y; na += x * x; nb += y * y
            }
            return dot / max(sqrt(na * nb), .ulpOfOne)
        }
        let quiet = percentile(level, 0.3)
        var held = [Bool](repeating: false, count: count)
        for t in 4..<count { held[t] = level[t] > quiet && correlation(t, t - 4) > 0.82 }
        let maxGap = Int(0.1 / dt), lead = Int(0.06 / dt)
        func holdLength(from frame: Int) -> TimeInterval {
            guard correlation(frame + lead, frame - 3) < 0.55 else { return 0 }
            var t = frame + lead, last = t, gap = 0
            let reference = frame + lead
            while t < count, t - reference < Int(4 / dt) {
                if held[t] && correlation(t, reference) > 0.6 { last = t; gap = 0 } else { gap += 1; if gap > maxGap { break } }
                t += 1
            }
            let length = Double(last - frame) * dt
            return length >= 0.55 ? length : 0
        }

        // Onto the grid: sixteenths first, then triplets, when close.
        func snap(_ time: TimeInterval) -> TimeInterval {
            guard beats.count > 1 else { return time }
            var low = 0, high = beats.count - 1
            while low < high - 1 { let mid = (low + high) / 2; if beats[mid] <= time { low = mid } else { high = mid } }
            let a = beats[low], b = beats[high]
            guard time >= a - 0.1, time <= b + 0.1, b > a else { return time }
            let span = b - a, tolerance = min(0.035, span / 10)
            let sixteenth = ((time - a) / span * 4).rounded() / 4 * span + a
            if abs(sixteenth - time) <= tolerance { return sixteenth }
            let triplet = ((time - a) / span * 3).rounded() / 3 * span + a
            if abs(triplet - time) <= tolerance { return triplet }
            return time
        }

        var hits: [PreciseTileAnalysis.Hit] = []
        for peak in peaks {
            let time = snap(Double(peak.frame) * dt)
            var hold = holdLength(from: peak.frame)
            if hold > 0 { hold = max(0.4, snap(time + hold) - time) }
            let hit = PreciseTileAnalysis.Hit(time: time, strength: peak.strength, hold: hold, band: peak.band, chord: false)
            if let last = hits.last, time - last.time < 0.03 {
                // Two hits as one: a kick and a crash together take two hands.
                var merged = peak.strength > last.strength ? hit : last
                merged.hold = max(hit.hold, last.hold)
                merged.chord = last.band != peak.band && min(last.strength, peak.strength) > 0.7
                hits[hits.count - 1] = merged
            } else {
                hits.append(hit)
            }
        }
        return PreciseTileAnalysis(beats: beats, hits: hits)
    }

    private static func movingAverage(_ values: [Float], radius: Int) -> [Float] {
        var prefix = [Float](repeating: 0, count: values.count + 1)
        for (i, v) in values.enumerated() { prefix[i + 1] = prefix[i] + v }
        return values.indices.map { i in
            let a = max(0, i - radius), b = min(values.count, i + radius + 1)
            return (prefix[b] - prefix[a]) / Float(b - a)
        }
    }

    private static func percentile(_ values: [Float], _ p: Double) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))]
    }
}
