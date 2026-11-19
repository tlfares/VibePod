import Foundation
import AVFoundation
import os

/// What AutoMix needs to know about a song, measured from its audio once and
/// remembered: where the music really starts and ends, where the outro
/// begins, and the beat grid.
struct AutoMixProfile: Codable, Sendable {
    /// Seconds of leading silence to skip.
    var start: TimeInterval
    /// Last audible moment (trailing silence cut).
    var end: TimeInterval
    /// Where the loud part of the song is over (fade-out, quiet outro).
    var outroStart: TimeInterval
    /// When the song reaches its full loudness: the intro's length.
    var attack: TimeInterval
    /// 0 when no steady beat was found.
    var bpm: Double
    /// Time of one beat; the others are every 60 / bpm seconds from it.
    var beatOffset: TimeInterval

    var beatPeriod: TimeInterval? { bpm > 0 ? 60 / bpm : nil }

    /// The nearest beat at or after `time` (or `time` itself without a beat).
    func beat(atOrAfter time: TimeInterval) -> TimeInterval {
        guard let period = beatPeriod else { return time }
        let k = ((time - beatOffset) / period).rounded(.up)
        return beatOffset + k * period
    }

    func beat(atOrBefore time: TimeInterval) -> TimeInterval {
        guard let period = beatPeriod else { return time }
        let k = ((time - beatOffset) / period).rounded(.down)
        return beatOffset + k * period
    }
}

/// How one song hands over to the next. Times are positions in the
/// outgoing song unless named otherwise.
struct AutoMixPlan: Sendable {
    let fromID: UUID
    let toID: UUID
    /// The outgoing song starts getting quieter here…
    let fadeStart: TimeInterval
    /// …the incoming one starts here…
    let switchAt: TimeInterval
    /// …and the outgoing one is silent here.
    let end: TimeInterval
    /// Position the incoming song starts from.
    let inStart: TimeInterval
    /// The outgoing song has its own fade: keep it at full volume longer.
    let naturalFade: Bool

    var overlap: TimeInterval { end - switchAt }
}

/// The user's AutoMix settings.
struct AutoMixOptions: Sendable {
    /// Apple Music's two transition styles.
    enum Style: String, CaseIterable, Sendable {
        case autoMix, crossfade
        var title: String {
            switch self {
            case .autoMix: String(localized: "AutoMix")
            case .crossfade: String(localized: "Crossfade")
            }
        }
        var symbol: String {
            switch self {
            case .autoMix: "circlebadge.2.fill"
            case .crossfade: "point.topleft.down.to.point.bottomright.curvepath"
            }
        }
    }

    static let styleKey = "autoMixStyle"
    static let crossfadeKey = "autoMixCrossfade"
    static let vocalsKey = "autoMixVocals"
    static let crossfadeRange: ClosedRange<Double> = 1...12

    var style: Style
    var crossfade: Double
    var protectVocals: Bool

    static var current: AutoMixOptions {
        let defaults = UserDefaults.standard
        return AutoMixOptions(
            style: Style(rawValue: defaults.string(forKey: styleKey) ?? "") ?? .autoMix,
            crossfade: defaults.object(forKey: crossfadeKey) as? Double ?? 4,
            protectVocals: defaults.object(forKey: vocalsKey) as? Bool ?? true
        )
    }
}

/// Where the singing is, from the song's synced lyrics.
struct AutoMixVocals: Sendable {
    /// When the last sung line is over.
    var lastEnd: TimeInterval?
    /// When the first line is sung.
    var firstStart: TimeInterval?

    init(lyrics: LRCLyrics?, duration: TimeInterval) {
        guard let lyrics, lyrics.hasTimedLyrics else { return }
        let lines = lyrics.lines
        let sung = lines.indices.filter { !lines[$0].isInstrumentalGap }
        guard let first = sung.first, let last = sung.last else { return }
        firstStart = max(0, lines[first].time - lyrics.offset)
        // A line ends at the next timestamp (an empty one marks the break);
        // the very last one, a few seconds later.
        let lastTime = lines[last].time - lyrics.offset
        let next = lines.indices.contains(last + 1) ? lines[last + 1].time - lyrics.offset : nil
        lastEnd = min(next ?? lastTime + 5, lastTime + 8, duration)
    }
}

/// Measures songs with plain signal processing (no AI): a loudness envelope
/// for silences and outros, onset autocorrelation for the tempo.
actor AutoMixAnalyzer {
    static let shared = AutoMixAnalyzer()

    private static let version = 3
    private static let sampleRate = 11_025.0
    private static let hop = 128
    private var profiles: [UUID: AutoMixProfile] = [:]
    private var running: [UUID: Task<AutoMixProfile?, Never>] = [:]
    private var loaded = false

    private var storeURL: URL {
        URL.applicationSupportDirectory.appending(path: "AutoMix-v\(Self.version).json")
    }

    func profile(for song: Song) async -> AutoMixProfile? {
        loadIfNeeded()
        if let profile = profiles[song.id] { return profile }
        if let task = running[song.id] { return await task.value }
        let url = song.isMediaLibraryItem ? song.fileURL : song.playableFileURL
        guard url.scheme != "media-library" else { return nil }
        let task = Task.detached(priority: .utility) { await Self.analyze(url) }
        running[song.id] = task
        let profile = await task.value
        running[song.id] = nil
        if let profile {
            profiles[song.id] = profile
            save()
        }
        return profile
    }

    /// The transition from `from` into `to`, or nil when the two should just
    /// follow each other (no audio to read).
    /// Two voices never overlap: the next song only comes in once the last
    /// line is sung, and the overlap is over before its first line.
    func plan(
        from: Song, to: Song, outDuration: TimeInterval,
        outVocals: AutoMixVocals, inVocals: AutoMixVocals, options: AutoMixOptions
    ) async -> AutoMixPlan? {
        if options.style == .crossfade {
            // A plain crossfade of the set length, no audio to read.
            let end = outDuration
            let fade = min(options.crossfade, end / 2)
            guard end > 10 else { return nil }
            return AutoMixPlan(
                fromID: from.id, toID: to.id,
                fadeStart: end - fade, switchAt: end - fade, end: end,
                inStart: 0, naturalFade: false
            )
        }
        guard let out = await profile(for: from), let into = await profile(for: to) else { return nil }
        let end = min(out.end, outDuration)
        guard end > 20 else { return nil }

        // Beat alignment only when the tempos are close (or close at half /
        // double time). No time-stretching: changing the playback rate makes
        // iOS players drop out.
        let onBeat = out.bpm > 0 && into.bpm > 0
            && [1.0, 2.0, 0.5].contains { abs(out.bpm / (into.bpm * $0) - 1) <= 0.04 }

        // Fade-out: the outro if it has one, else 8 beats.
        let naturalFade = end - out.outroStart >= 4
        var fade = naturalFade ? end - out.outroStart : (onBeat ? out.beatPeriod! * 8 : 6)
        fade = min(max(fade, 2), 12)
        var fadeStart = end - fade
        if onBeat { fadeStart = out.beat(atOrBefore: fadeStart) }
        fadeStart = max(fadeStart, end / 2)

        // Incoming: first audible beat, so both downbeats land together.
        var inStart = into.start
        if onBeat {
            let snapped = into.beat(atOrAfter: inStart - 0.05)
            if snapped - inStart < 0.5 { inStart = max(0, snapped) }
        }

        // The incoming song comes in early in the fade-out, so the two
        // really play together. Only voices must not meet: the incoming
        // song's first line has to come after the outgoing song's last one.
        // Its instrumental intro may play under that last line.
        var switchAt = fadeStart + (end - fadeStart) * 0.1
        let firstIn = options.protectVocals ? inVocals.firstStart : nil
        let lastOut = options.protectVocals ? outVocals.lastEnd.map { min($0, end) } : nil
        if let firstIn {
            let lead = max(0, firstIn - inStart)
            if let lastOut { switchAt = max(switchAt, lastOut + 0.3 - lead) }
            // Its first line is sung over a nearly silent outgoing song.
            switchAt = max(switchAt, end - 0.5 - lead)
            switchAt = min(switchAt, end)
        } else if into.attack - inStart < 1 {
            // No lyrics to go by and no intro: a shorter overlap.
            switchAt = max(switchAt, end - 4)
            if let lastOut { switchAt = max(switchAt, lastOut) }
        } else if let lastOut {
            switchAt = max(switchAt, lastOut + 0.3 - (into.attack - inStart))
        }
        switchAt = max(switchAt, fadeStart)
        if onBeat, switchAt < end {
            let snapped = out.beat(atOrAfter: switchAt)
            switchAt = snapped <= end ? snapped : switchAt
        }
        return AutoMixPlan(
            fromID: from.id, toID: to.id,
            fadeStart: fadeStart, switchAt: min(switchAt, end), end: end,
            inStart: inStart,
            naturalFade: naturalFade
        )
    }

    // MARK: - Storage

    /// The measures already taken, without analyzing.
    func storedProfile(for id: UUID) -> AutoMixProfile? {
        loadIfNeeded()
        return profiles[id]
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        if let data = try? Data(contentsOf: storeURL),
           let stored = try? JSONDecoder().decode([UUID: AutoMixProfile].self, from: data) {
            profiles = stored
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        try? FileManager.default.createDirectory(at: URL.applicationSupportDirectory, withIntermediateDirectories: true)
        try? data.write(to: storeURL, options: .atomic)
    }

    // MARK: - Analysis

    private static func analyze(_ url: URL) async -> AutoMixProfile? {
        guard let samples = await decode(url), samples.count > Int(sampleRate * 10) else { return nil }
        let frameRate = sampleRate / Double(hop)

        // Per-hop energy, full band and low band (kick drum / bass).
        let frames = samples.count / hop
        var energy = [Float](repeating: 0, count: frames)
        var low = [Float](repeating: 0, count: frames)
        var lp: Float = 0
        let alpha: Float = 0.06 // one-pole low-pass ≈ 110 Hz at 11 kHz
        for f in 0..<frames {
            var e: Float = 0, l: Float = 0
            for i in (f * hop)..<((f + 1) * hop) {
                let s = samples[i]
                lp += alpha * (s - lp)
                e += s * s
                l += lp * lp
            }
            energy[f] = e / Float(hop)
            low[f] = l / Float(hop)
        }

        // Loudness over ~0.4 s and ~1.5 s windows, in dB.
        let db = { (x: Float) in 10 * log10(max(x, 1e-10)) }
        let short = smooth(energy, radius: Int(frameRate * 0.2)).map(db)
        let long = smooth(energy, radius: Int(frameRate * 0.75)).map(db)
        let reference = percentile(long, 0.7)

        // Silence only: a soft intro or fade-in is music and is kept.
        let floor = max(reference - 55, -75)
        let firstAudible = short.firstIndex { $0 > floor } ?? 0
        let lastAudible = short.lastIndex { $0 > floor } ?? (frames - 1)
        let loudEnd = long.lastIndex { $0 > reference - 6 } ?? lastAudible
        let loudStart = short.firstIndex { $0 > reference - 8 } ?? firstAudible
        let toTime = { (f: Int) in Double(f) / frameRate }

        let (bpm, offset) = tempo(energy: energy, low: low, frameRate: frameRate)
        return AutoMixProfile(
            start: toTime(firstAudible),
            end: toTime(lastAudible + 1),
            outroStart: min(toTime(loudEnd), toTime(lastAudible + 1)),
            attack: toTime(max(loudStart, firstAudible)),
            bpm: bpm,
            beatOffset: offset
        )
    }

    /// Mono float samples at 11 kHz.
    private static func decode(_ url: URL) async -> [Float]? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first, let reader = try? AVAssetReader(asset: asset) else { return nil }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }
        var samples: [Float] = []
        samples.reserveCapacity(Int(sampleRate * 300))
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var chunk = [Float](repeating: 0, count: length / 4)
            chunk.withUnsafeMutableBytes { raw in
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
            }
            samples += chunk
        }
        return reader.status == .completed ? samples : nil
    }

    /// Tempo from the autocorrelation of the onset curve (rises in loudness,
    /// low band weighted up), then the beat phase that fits it best.
    static func tempo(energy: [Float], low: [Float], frameRate: Double) -> (Double, TimeInterval) {
        let n = energy.count
        guard n > 200 else { return (0, 0) }
        var onset = [Float](repeating: 0, count: n)
        let log1 = { (x: Float) in log(1 + 1000 * x) }
        for i in 1..<n {
            let full = max(0, log1(energy[i]) - log1(energy[i - 1]))
            let bass = max(0, log1(low[i]) - log1(low[i - 1]))
            onset[i] = full + 1.5 * bass
        }
        // Remove the slow trend so loud sections don't dominate.
        let trend = smooth(onset, radius: Int(frameRate))
        for i in 0..<n { onset[i] = max(0, onset[i] - trend[i]) }

        let minLag = Int(frameRate * 60 / 180), maxLag = Int(frameRate * 60 / 70)
        guard maxLag < n / 4 else { return (0, 0) }
        var scores = [Float](repeating: 0, count: maxLag + 2)
        for lag in max(1, minLag - 1)...(maxLag + 1) {
            var s: Float = 0
            for i in lag..<n { s += onset[i] * onset[i - lag] }
            scores[lag] = s / Float(n - lag)
        }
        // Mild preference for 90–140 BPM, where most songs sit.
        var best = minLag
        var bestScore: Float = -1
        for lag in minLag...maxLag {
            let bpm = 60 * frameRate / Double(lag)
            let weight = Float(exp(-pow(log2(bpm / 115), 2) / 0.5))
            let score = scores[lag] * (0.6 + 0.4 * weight)
            if score > bestScore { bestScore = score; best = lag }
        }
        // Too flat: no steady beat (ambient, speech, rubato).
        let mean = scores[minLag...maxLag].reduce(0, +) / Float(maxLag - minLag + 1)
        guard mean > 0, scores[best] / mean > 1.25 else { return (0, 0) }

        // Sub-frame lag by parabola through the peak.
        let a = scores[best - 1], b = scores[best], c = scores[best + 1]
        let shift = (a - c) / (2 * (a - 2 * b + c))
        let lag = Double(best) + (shift.isFinite ? Double(max(-0.5, min(0.5, shift))) : 0)
        let bpm = 60 * frameRate / lag

        // Phase: the offset whose comb collects the most onset.
        var bestPhase = 0.0, bestSum: Float = -1
        let steps = 48
        for step in 0..<steps {
            let phase = lag * Double(step) / Double(steps)
            var sum: Float = 0
            var t = phase
            while Int(t) < n {
                sum += onset[Int(t)]
                t += lag
            }
            if sum > bestSum { bestSum = sum; bestPhase = phase }
        }
        return (bpm, bestPhase / frameRate)
    }

    static func smooth(_ x: [Float], radius: Int) -> [Float] {
        guard radius > 0, !x.isEmpty else { return x }
        var prefix = [Float](repeating: 0, count: x.count + 1)
        for i in 0..<x.count { prefix[i + 1] = prefix[i] + x[i] }
        return (0..<x.count).map { i in
            let lo = max(0, i - radius), hi = min(x.count, i + radius + 1)
            return (prefix[hi] - prefix[lo]) / Float(hi - lo)
        }
    }

    private static func percentile(_ x: [Float], _ p: Double) -> Float {
        let sorted = x.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))]
    }
}

// MARK: - Library Sound

/// What Stats learns from listening to a song: plain signal measures, no AI.
struct SoundProfile: Codable, Sendable {
    /// 0 when there's no steady beat.
    var bpm: Double
    /// Average loudness, in dBFS.
    var loudness: Double
    /// Gap between the song's loud and quiet passages, in dB.
    var dynamics: Double
    /// Zero-crossing rate: higher for bright, noisy sounds (cymbals,
    /// distortion), lower for warm and acoustic ones.
    var brightness: Double

    enum Mood: String, Sendable {
        case energetic, balanced, calm
    }

    /// Stats' three groups.
    var mood: Mood { energy >= 0.65 ? .energetic : energy < 0.4 ? .calm : .balanced }

    /// 0 calm … 1 energetic, from tempo, loudness and brightness.
    var energy: Double {
        let clamp = { (x: Double) in min(1, max(0, x)) }
        let tempo = bpm > 0 ? clamp((bpm - 70) / 90) : 0.25
        return 0.4 * tempo + 0.4 * clamp((loudness + 26) / 16) + 0.2 * clamp((brightness - 0.03) / 0.1)
    }
}

/// Listens to the whole library once, a minute of each song at a time and
/// several songs at once, and keeps what it measured.
@MainActor
final class LibrarySoundAnalysis: ObservableObject {
    static let shared = LibrarySoundAnalysis()

    @Published private(set) var profiles: [UUID: SoundProfile] = [:] {
        didSet { Self.stored.withLock { [profiles] in $0 = profiles } }
    }
    /// Read from disk on first use: the Assistant and Autolists need the
    /// measures without Stats having been opened since launch.
    private nonisolated static let stored = OSAllocatedUnfairLock<[UUID: SoundProfile]>(initialState: readStore())

    private nonisolated static func readStore() -> [UUID: SoundProfile] {
        guard let data = try? Data(contentsOf: storeURL) else { return [:] }
        return (try? JSONDecoder().decode([UUID: SoundProfile].self, from: data)) ?? [:]
    }

    /// The measures, from any thread (Autolists are built off the main one).
    nonisolated static func storedProfiles() -> [UUID: SoundProfile] {
        stored.withLock { $0 }
    }

    /// Enough songs measured for moods to mean something.
    nonisolated static var isUnlocked: Bool { storedProfiles().count >= 5 }
    @Published private(set) var isRunning = false
    @Published private(set) var progress = 0.0

    private var task: Task<Void, Never>?
    private nonisolated static let sampleRate = 11_025.0
    private nonisolated static let hop = 128
    private nonisolated static var storeURL: URL { URL.applicationSupportDirectory.appending(path: "SoundProfiles-v1.json") }

    private init() {
        profiles = Self.storedProfiles()
    }

    /// Songs that can be measured and haven't been.
    func pending(in songs: [Song]) -> [Song] {
        songs.filter { profiles[$0.id] == nil && $0.isExcerptPlayable }
    }

    func start(songs: [Song]) {
        guard !isRunning else { return }
        let queue = pending(in: songs).map { ($0.id, $0.isMediaLibraryItem ? $0.fileURL : $0.playableFileURL, $0.duration) }
        guard !queue.isEmpty else { return }
        isRunning = true
        progress = 0
        task = Task {
            let width = max(2, ProcessInfo.processInfo.activeProcessorCount)
            var done = 0
            await withTaskGroup(of: (UUID, SoundProfile?).self) { group in
                var next = 0
                func add() {
                    guard next < queue.count else { return }
                    let (id, url, duration) = queue[next]
                    next += 1
                    group.addTask(priority: .userInitiated) { (id, await Self.analyze(url, duration: duration)) }
                }
                for _ in 0..<width { add() }
                for await (id, profile) in group {
                    if Task.isCancelled { group.cancelAll(); break }
                    if let profile { profiles[id] = profile }
                    done += 1
                    progress = Double(done) / Double(queue.count)
                    // Saved along the way: a cancel keeps what's done.
                    if done % 25 == 0 { save() }
                    add()
                }
            }
            save()
            isRunning = false
            task = nil
        }
    }

    func cancel() {
        task?.cancel()
    }

    /// Forgets what Stats measured so it can be measured again. AutoMix's
    /// and Music Haptics' own data stay.
    func reset() {
        guard !isRunning else { return }
        profiles = [:]
        progress = 0
        try? FileManager.default.removeItem(at: Self.storeURL)
    }

    private func save() {
        let profiles = profiles
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(profiles) else { return }
            try? FileManager.default.createDirectory(at: URL.applicationSupportDirectory, withIntermediateDirectories: true)
            try? data.write(to: Self.storeURL, options: .atomic)
        }
    }

    // MARK: Measuring

    private nonisolated static func analyze(_ url: URL, duration: TimeInterval) async -> SoundProfile? {
        guard url.scheme != "media-library", !Task.isCancelled,
              let samples = await decodeExcerpt(url, duration: duration),
              samples.count > Int(sampleRate * 8) else { return nil }
        let frameRate = sampleRate / Double(hop)
        let frames = samples.count / hop
        var energy = [Float](repeating: 0, count: frames)
        var low = [Float](repeating: 0, count: frames)
        var lp: Float = 0
        var crossings = 0
        var previous: Float = 0
        for f in 0..<frames {
            var e: Float = 0, l: Float = 0
            for i in (f * hop)..<((f + 1) * hop) {
                let s = samples[i]
                lp += 0.06 * (s - lp)
                e += s * s
                l += lp * lp
                if (s >= 0) != (previous >= 0) { crossings += 1 }
                previous = s
            }
            energy[f] = e / Float(hop)
            low[f] = l / Float(hop)
        }
        let db = { (x: Float) in 10 * log10(max(x, 1e-10)) }
        let loudness = AutoMixAnalyzer.smooth(energy, radius: Int(frameRate * 0.2)).map(db).sorted()
        let audible = loudness.filter { $0 > -60 }
        guard !audible.isEmpty else { return nil }
        let mean = energy.reduce(0, +) / Float(frames)
        let (bpm, _) = AutoMixAnalyzer.tempo(energy: energy, low: low, frameRate: frameRate)
        return SoundProfile(
            bpm: bpm,
            loudness: Double(db(mean)),
            dynamics: Double(audible[Int(Double(audible.count) * 0.95)] - audible[Int(Double(audible.count) * 0.1)]),
            brightness: Double(crossings) / Double(samples.count)
        )
    }

    /// A minute of mono audio from the middle of the song, where it's in full
    /// swing; decoding only that keeps the whole library quick.
    private nonisolated static func decodeExcerpt(_ url: URL, duration: TimeInterval) async -> [Float]? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let reader = try? AVAssetReader(asset: asset) else { return nil }
        let length = min(60, duration > 0 ? duration : 60)
        let start = max(0, duration / 2 - length / 2)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), duration: CMTime(seconds: length, preferredTimescale: 600))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }
        var samples: [Float] = []
        samples.reserveCapacity(Int(sampleRate * length))
        while let buffer = output.copyNextSampleBuffer() {
            if Task.isCancelled { reader.cancelReading(); return nil }
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let bytes = CMBlockBufferGetDataLength(block)
            var chunk = [Float](repeating: 0, count: bytes / 4)
            chunk.withUnsafeMutableBytes { raw in
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes, destination: raw.baseAddress!)
            }
            samples += chunk
        }
        return reader.status == .completed ? samples : nil
    }
}
