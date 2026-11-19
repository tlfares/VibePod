import Foundation
import AVFoundation
import Accelerate
import Combine
import CoreHaptics
import UIKit

/// Music Haptics, like Music: taps and textures that follow the song.
/// Apple only ships haptic tracks for its catalog, so they are made here
/// from the audio itself: the song is decoded once, its kicks and snares
/// found with a spectral-flux onset detector, and the result cached.
@MainActor
final class MusicHapticsService {
    static let shared = MusicHapticsService()
    static let storageKey = "musicHapticsEnabled"
    /// Apple's haptic tracks, played by iOS itself; exclusive with ours.
    static let appleStorageKey = "musicHapticsApple"

    static var isSupported: Bool { CHHapticEngine.capabilitiesForHardware().supportsHaptics }

    private let player = MusicPlayerService.shared
    private var engine: CHHapticEngine?
    private var analysis: HapticAnalysis?
    private var vocals: VocalTimeline?
    private var events: [HapticBeat] = []
    private var appliedSettings = MusicHapticsSettings.current
    private var eventsSongID: UUID?
    private var analysisTask: Task<Void, Never>?
    private var timer: Timer?
    private var nextIndex = 0
    private var lastTime: TimeInterval = 0
    private var cancellables: Set<AnyCancellable> = []

    private var isEnabled: Bool { UserDefaults.standard.bool(forKey: Self.storageKey) }

    func start() {
        guard Self.isSupported, cancellables.isEmpty else { return }
        player.$currentSong.removeDuplicates { $0?.id == $1?.id }
            .sink { [weak self] _ in DispatchQueue.main.async { self?.refresh() } }
            .store(in: &cancellables)
        player.$isPlaying.removeDuplicates()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.refresh() } }
            .store(in: &cancellables)
        // Posted from whichever thread wrote the defaults (the widget queue).
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .map { _ in (UserDefaults.standard.bool(forKey: Self.storageKey), MusicHapticsSettings.current) }
            .removeDuplicates { $0 == $1 }
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
    }

    private func refresh() {
        guard isEnabled, let song = player.currentSong else {
            stopTicking()
            if !isEnabled { stopTicking(); engine?.stop(); engine = nil }
            return
        }
        let settings = MusicHapticsSettings.current
        if settings.threshold != appliedSettings.threshold || settings.focus != appliedSettings.focus {
            rebuildEvents()
        } else {
            // Intensity is only read at each tick (`gain`): the beats stay.
            appliedSettings = settings
        }
        if eventsSongID != song.id {
            analysis = nil
            vocals = nil
            events = []
            eventsSongID = song.id
            load(song)
        }
        if player.isPlaying {
            startTicking()
        } else {
            stopTicking()
            // Running on the playback session, the engine kept the app
            // counted as playing: the system player stayed on its pause
            // button. It starts again with the music.
            engine?.stop(completionHandler: nil)
        }
    }

    // MARK: - Analysis

    private func load(_ song: Song) {
        analysisTask?.cancel()
        let id = song.id
        let url = song.isMediaLibraryItem ? song.fileURL : song.playableFileURL
        guard url.scheme != "media-library" else { return }
        let lyricsURL = AppModel.shared.libraryService.resolvedLyricsURL(for: song)
        analysisTask = Task { [weak self] in
            let (analysis, vocals) = await Task.detached(priority: .utility) {
                let analysis = HapticAnalyzer.cachedAnalysis(for: id) ?? HapticAnalyzer.analyze(url: url, songID: id)
                return (analysis, lyricsURL.flatMap { VocalTimeline(songID: id, lyricsURL: $0) })
            }.value
            guard let self, !Task.isCancelled, self.eventsSongID == id else { return }
            self.analysis = analysis
            self.vocals = vocals
            self.rebuildEvents()
        }
    }

    /// The analysis keeps every candidate; what plays depends on the settings.
    private func rebuildEvents() {
        let settings = MusicHapticsSettings.current
        appliedSettings = settings
        events = analysis?.beats(threshold: settings.threshold, focus: settings.focus, vocals: vocals) ?? []
        resync(to: player.preciseCurrentTime)
    }

    // MARK: - Playback

    private func startTicking() {
        // Restarts the engine if iOS stopped it while in the background.
        prepareEngine()
        guard timer == nil else { return }
        resync(to: player.preciseCurrentTime)
        let timer = Timer(timeInterval: 0.05, repeats: true) { _ in
            MainActor.assumeIsolated { MusicHapticsService.shared.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTicking() {
        timer?.invalidate()
        timer = nil
    }

    private func prepareEngine() {
        if engine == nil {
            // Tied to the playback session, which stays alive in the
            // background, instead of a session of its own.
            engine = try? CHHapticEngine(audioSession: .sharedInstance())
            engine?.playsHapticsOnly = true
            engine?.isAutoShutdownEnabled = true
            engine?.resetHandler = { [weak self] in
                DispatchQueue.main.async {
                    guard let self, self.timer != nil else { return }
                    try? self.engine?.start()
                }
            }
        }
        try? engine?.start()
    }

    private func resync(to time: TimeInterval) {
        nextIndex = events.firstIndex { $0.time >= time } ?? events.count
        lastTime = time
    }

    /// Schedules what falls in the next 120 ms, at its exact offset.
    private func tick() {
        guard let engine, !events.isEmpty else { return }
        let now = player.preciseCurrentTime
        // A seek, or a pause the timer didn't see: start again from here.
        if now < lastTime - 0.05 || now > lastTime + 0.5 { resync(to: now) }
        lastTime = now
        let horizon = now + 0.12
        let gain = Float(appliedSettings.intensity)
        var hapticEvents: [CHHapticEvent] = []
        while nextIndex < events.count, events[nextIndex].time < horizon {
            let beat = events[nextIndex]
            nextIndex += 1
            let offset = beat.time - now
            guard offset > -0.03 else { continue }
            hapticEvents.append(beat.event(at: max(0, offset), gain: gain))
        }
        guard !hapticEvents.isEmpty,
              let pattern = try? CHHapticPattern(events: hapticEvents, parameters: []),
              let patternPlayer = try? engine.makePlayer(with: pattern) else { return }
        do {
            try patternPlayer.start(atTime: CHHapticTimeImmediate)
        } catch {
            try? engine.start()
        }
    }
}

enum MusicHapticsFocus: String, CaseIterable, Identifiable, Codable {
    case instruments, both, vocals

    static let storageKey = "musicHapticsFocus"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .instruments: String(localized: "Instruments")
        case .both: String(localized: "Both")
        case .vocals: String(localized: "Vocals")
        }
    }

    var symbol: String {
        switch self {
        case .instruments: "pianokeys"
        case .both: "music.note"
        case .vocals: "music.microphone"
        }
    }
}

struct MusicHapticsSettings: Equatable {
    static let intensityKey = "musicHapticsIntensity"
    static let intensityRange: ClosedRange<Double> = 0.25...1.5
    static let thresholdRange: ClosedRange<Double> = 0.5...2

    var intensity: Double = 1
    var threshold: Double = 1
    var focus: MusicHapticsFocus = .instruments

    static var current: MusicHapticsSettings {
        let defaults = UserDefaults.standard
        return MusicHapticsSettings(
            intensity: defaults.object(forKey: intensityKey) as? Double ?? 1,
            focus: defaults.string(forKey: MusicHapticsFocus.storageKey).flatMap(MusicHapticsFocus.init) ?? .instruments
        )
    }
}

struct HapticBeat {
    let time: TimeInterval
    let intensity: Float
    let sharpness: Float
    /// A held bass note gets a short texture after its tap.
    let sustain: TimeInterval

    func event(at offset: TimeInterval, gain: Float) -> CHHapticEvent {
        let parameters = [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: min(1, intensity * gain)),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
        ]
        if sustain > 0 {
            return CHHapticEvent(eventType: .hapticContinuous, parameters: parameters, relativeTime: offset, duration: sustain)
        }
        return CHHapticEvent(eventType: .hapticTransient, parameters: parameters, relativeTime: offset)
    }
}

/// One local peak of an onset curve. `score` is how far it clears the
/// adaptive threshold: 1 is the line, the threshold setting moves it.
struct HapticCandidate: Codable {
    let frame: Int
    let score: Float
    let strength: Float
    var sustain: TimeInterval = 0
}

struct HapticAnalysis: Codable {
    static let frameDuration = 256.0 / 22_050

    let low: [HapticCandidate]
    let high: [HapticCandidate]
    let voice: [HapticCandidate]

    func beats(threshold: Double, focus: MusicHapticsFocus, vocals: VocalTimeline? = nil) -> [HapticBeat] {
        let threshold = Float(threshold)
        let frame = Self.frameDuration
        let lowPeaks = Self.pick(low, threshold: threshold, minGap: Int(0.12 / frame))
        let highPeaks = Self.pick(high, threshold: threshold, minGap: Int(0.1 / frame))
        let drumFrames = Set(lowPeaks.map { $0.frame / 4 } + highPeaks.map { $0.frame / 4 })
        var beats: [HapticBeat] = []

        if focus != .vocals {
            beats += lowPeaks.map {
                HapticBeat(time: Double($0.frame) * frame, intensity: 0.55 + 0.45 * $0.strength, sharpness: 0.15, sustain: $0.sustain)
            }
            let lowFrames = Set(lowPeaks.map { $0.frame / 4 })
            beats += highPeaks.filter { $0.strength > 0.35 && !lowFrames.contains($0.frame / 4) }.map {
                HapticBeat(time: Double($0.frame) * frame, intensity: 0.3 + 0.4 * $0.strength, sharpness: 0.8, sustain: 0)
            }
        }
        if focus == .vocals, let words = vocals?.words {
            // Word-synced lyrics: one tap per syllable, as strong as the voice
            // there. The first lands on the word; the others are spread over
            // it, each pulled to the closest voice onset.
            let onsets = voice.map { (time: Double($0.frame) * frame, strength: $0.strength) }
            func strongest(near time: TimeInterval, within radius: TimeInterval) -> (time: TimeInterval, strength: Float)? {
                var low = 0, high = onsets.count
                while low < high {
                    let mid = (low + high) / 2
                    if onsets[mid].time <= time - radius { low = mid + 1 } else { high = mid }
                }
                return onsets[low...].prefix { $0.time < time + radius }.max { $0.strength < $1.strength }
            }
            for word in words {
                let duration = max(0, word.end - word.start)
                // Keep syllables at least 120 ms apart, so a fast word doesn't buzz.
                let count = max(1, min(word.syllables, Int(duration / 0.12)))
                let step = duration / Double(count)
                for index in 0..<count {
                    var time = word.start + step * Double(index)
                    let onset = strongest(near: time, within: index == 0 ? 0.08 : step / 2)
                    if index > 0, let onset { time = onset.time }
                    beats.append(HapticBeat(time: time, intensity: 0.35 + 0.45 * (onset?.strength ?? 0.4),
                                            sharpness: index == 0 ? 0.45 : 0.35, sustain: 0))
                }
            }
        } else if focus != .instruments {
            // Syllables: mid-band onsets that don't land on a drum hit; with
            // line-synced lyrics, only while a line is being sung.
            let lines = focus == .vocals ? vocals?.lines : nil
            let voicePeaks = Self.pick(voice, threshold: threshold, minGap: Int(0.15 / frame))
            beats += voicePeaks.filter { peak in
                guard peak.strength > 0.25, !drumFrames.contains(peak.frame / 4) else { return false }
                let time = Double(peak.frame) * frame
                return lines.map { $0.contains { $0.contains(time) } } ?? true
            }.map {
                HapticBeat(time: Double($0.frame) * frame, intensity: 0.35 + 0.45 * $0.strength, sharpness: 0.45, sustain: 0)
            }
            // Each new line lands with a firmer tap.
            beats += (lines ?? []).map { HapticBeat(time: $0.lowerBound, intensity: 0.75, sharpness: 0.5, sustain: 0) }
        }
        return beats.sorted { $0.time < $1.time }
    }

    /// Greedy, in time order, like a live detector: a peak too close to the
    /// last kept one is dropped.
    private static func pick(_ candidates: [HapticCandidate], threshold: Float, minGap: Int) -> [HapticCandidate] {
        var result: [HapticCandidate] = []
        var lastFrame = Int.min / 2
        for candidate in candidates where candidate.score > threshold && candidate.frame - lastFrame >= minGap {
            result.append(candidate)
            lastFrame = candidate.frame
        }
        return result
    }
}

struct SungWord: Sendable {
    let start: TimeInterval
    let end: TimeInterval
    let syllables: Int
}

/// When the singer sings, from the song's synced lyrics, in playback time.
struct VocalTimeline: Sendable {
    /// Sung lines, from their timestamp to the next one (at most 10 s).
    let lines: [ClosedRange<TimeInterval>]
    /// Sung words, when the lyrics are synced word by word.
    let words: [SungWord]?

    init?(songID: UUID, lyricsURL: URL) {
        guard let lyrics = LRCParser.parse(url: lyricsURL), lyrics.hasTimedLyrics else { return nil }
        let offset = lyrics.offset
        var lines: [ClosedRange<TimeInterval>] = []
        for (index, line) in lyrics.lines.enumerated() where !line.isInstrumentalGap {
            let next = lyrics.lines.indices.contains(index + 1) ? lyrics.lines[index + 1].time : line.time + 10
            lines.append((line.time - offset)...(min(next, line.time + 10) - offset))
        }
        self.lines = lines
        let timings = WordSyncStore.load(for: songID, lyrics: lyrics)
        var words: [SungWord] = []
        for line in lyrics.lines {
            guard let lineTimings = timings[line.id] else { continue }
            for (range, timing) in zip(LyricWords.ranges(in: line.text), lineTimings) {
                words.append(SungWord(start: timing.start - offset, end: timing.end - offset,
                                      syllables: Self.syllableCount(line.text[range])))
            }
        }
        words.sort { $0.start < $1.start }
        self.words = words.isEmpty ? nil : words
    }

    /// Vowel groups, a good enough syllable count for French and English
    /// (a final silent "e" doesn't count).
    static func syllableCount(_ word: Substring) -> Int {
        let letters = word.lowercased().folding(options: .diacriticInsensitive, locale: nil).filter(\.isLetter)
        let vowels: Set<Character> = ["a", "e", "i", "o", "u", "y"]
        var count = 0, previousWasVowel = false
        for letter in letters {
            let isVowel = vowels.contains(letter)
            if isVowel && !previousWasVowel { count += 1 }
            previousWasVowel = isVowel
        }
        if count > 1, letters.hasSuffix("e"), let beforeLast = letters.dropLast().last, !vowels.contains(beforeLast) { count -= 1 }
        return max(1, count)
    }
}

enum HapticAnalyzer {
    private static let sampleRate: Double = 22_050
    private static let frameSize = 1024
    private static let hop = 256
    private static let version = 2

    private static var cacheDirectory: URL {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MusicHaptics", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func cacheURL(for id: UUID) -> URL {
        cacheDirectory.appendingPathComponent("\(id.uuidString)-v\(version).json")
    }

    static func cachedAnalysis(for id: UUID) -> HapticAnalysis? {
        guard let data = try? Data(contentsOf: cacheURL(for: id)) else { return nil }
        return try? JSONDecoder().decode(HapticAnalysis.self, from: data)
    }

    static func analyze(url: URL, songID: UUID) -> HapticAnalysis? {
        guard let samples = decode(url: url), samples.count > frameSize else { return nil }
        let analysis = detectCandidates(in: samples)
        if let data = try? JSONEncoder().encode(analysis) {
            try? data.write(to: cacheURL(for: songID), options: .atomic)
        }
        return analysis
    }

    /// Mono floats at 22.05 kHz, enough for drums.
    static func decode(url: URL) -> [Float]? {
        let asset = AVURLAsset(url: url)
        guard let reader = try? AVAssetReader(asset: asset),
              let track = loadTrack(asset) else { return nil }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }
        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buffer) {
            let length = CMBlockBufferGetDataLength(block)
            var chunk = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            chunk.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            samples.append(contentsOf: chunk)
        }
        return reader.status == .completed ? samples : nil
    }

    private static func loadTrack(_ asset: AVURLAsset) -> AVAssetTrack? {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var track: AVAssetTrack?
        asset.loadTracks(withMediaType: .audio) { tracks, _ in
            track = tracks?.first
            semaphore.signal()
        }
        semaphore.wait()
        return track
    }

    /// Spectral flux in a low band (kick, bass), a high band (snare, hats)
    /// and the voice band, each with its local peaks scored against a moving
    /// average of itself.
    private static func detectCandidates(in samples: [Float]) -> HapticAnalysis? {
        let log2n = vDSP_Length(log2(Double(frameSize)))
        guard let fft = vDSP.FFT(log2n: log2n, radix: .radix2, ofType: DSPSplitComplex.self) else { return nil }
        let half = frameSize / 2
        let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: frameSize, isHalfWindow: false)
        let binHz = Float(sampleRate) / Float(frameSize)
        let lowEnd = Int(180 / binHz), highStart = Int(2_000 / binHz)
        let voiceStart = Int(300 / binHz), voiceEnd = Int(3_400 / binHz)

        var lowFlux: [Float] = [], highFlux: [Float] = [], voiceFlux: [Float] = [], lowEnergy: [Float] = []
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
            vDSP.add(1, magnitudes, result: &magnitudes)
            magnitudes = vForce.log(magnitudes)
            var low: Float = 0, high: Float = 0, voice: Float = 0, energy: Float = 0
            for bin in 1..<half {
                let rise = max(0, magnitudes[bin] - previous[bin])
                if bin <= lowEnd { low += rise; energy += magnitudes[bin] } else if bin >= highStart { high += rise }
                if bin >= voiceStart && bin <= voiceEnd { voice += rise }
            }
            lowFlux.append(low)
            highFlux.append(high / Float(half - highStart))
            voiceFlux.append(voice / Float(voiceEnd - voiceStart + 1))
            lowEnergy.append(energy / Float(lowEnd))
            previous = magnitudes
            start += hop
        }

        let frameDuration = HapticAnalysis.frameDuration
        let energyTop = percentile(lowEnergy, 0.95)
        let low = candidates(in: lowFlux).map { peak in
            // Bass that stays up after the hit becomes a short rumble.
            var held = 0
            while peak.frame + held + 1 < lowEnergy.count,
                  lowEnergy[peak.frame + held + 1] > energyTop * 0.85, held < Int(0.4 / frameDuration) { held += 1 }
            var peak = peak
            peak.sustain = held > Int(0.15 / frameDuration) ? Double(held) * frameDuration : 0
            return peak
        }
        return HapticAnalysis(low: low, high: candidates(in: highFlux), voice: candidates(in: voiceFlux))
    }

    /// Every local maximum that could pass the lowest threshold setting.
    private static func candidates(in flux: [Float]) -> [HapticCandidate] {
        guard flux.count > 16 else { return [] }
        let top = max(percentile(flux, 0.98), .ulpOfOne)
        let radius = 16
        let floor = Float(MusicHapticsSettings.thresholdRange.lowerBound)
        var result: [HapticCandidate] = []
        for index in 1..<(flux.count - 1) {
            let value = flux[index]
            guard value > flux[index - 1], value >= flux[index + 1] else { continue }
            let lower = max(0, index - radius), upper = min(flux.count, index + radius)
            let line = vDSP.mean(flux[lower..<upper]) * 1.5 + top * 0.12
            let score = value / max(line, .ulpOfOne)
            guard score > floor else { continue }
            result.append(HapticCandidate(frame: index, score: score, strength: min(1, value / top)))
        }
        return result
    }

    private static func percentile(_ values: [Float], _ p: Double) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))]
    }
}


// MARK: - ISRC

/// The song's recording code, which is how iOS finds Apple's haptic track
/// for it: from the file's tags, else from Deezer's catalog (no account
/// needed). Remembered per song, misses included.
@MainActor
enum ISRCResolver {
    private static let storageKey = "songISRCs"
    private static var codes: [String: String] = UserDefaults.standard.dictionary(forKey: storageKey) as? [String: String] ?? [:]
    private static var pending: Set<UUID> = []

    static func cached(for song: Song?) -> String? {
        guard let song, let code = codes[song.id.uuidString], !code.isEmpty else { return nil }
        return code
    }

    static func resolve(_ song: Song) async -> String? {
        if let code = codes[song.id.uuidString] { return code.isEmpty ? nil : code }
        guard !pending.contains(song.id) else { return nil }
        pending.insert(song.id)
        defer { pending.remove(song.id) }
        let url = song.isMediaLibraryItem ? song.fileURL : song.playableFileURL
        var code = await fromTags(url)
        if code == nil { code = await fromDeezer(title: song.title, artist: song.artist, duration: song.duration) }
        codes[song.id.uuidString] = code ?? ""
        UserDefaults.standard.set(codes, forKey: storageKey)
        return code
    }

    private static func fromTags(_ url: URL) async -> String? {
        guard url.scheme != "media-library",
              let items = try? await AVURLAsset(url: url).load(.metadata) else { return nil }
        for item in items {
            let key = [item.identifier?.rawValue, (item.key as? String)].compactMap { $0 }.joined(separator: " ").uppercased()
            guard key.contains("TSRC") || key.contains("ISRC"),
                  let value = try? await item.load(.stringValue) else { continue }
            if let code = normalized(value) { return code }
        }
        return nil
    }

    private static func fromDeezer(title: String, artist: String, duration: TimeInterval) async -> String? {
        var search = URLComponents(string: "https://api.deezer.com/search")!
        search.queryItems = [URLQueryItem(name: "q", value: "\(artist) \(title)"), URLQueryItem(name: "limit", value: "10")]
        guard let url = search.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let results = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["data"] as? [[String: Any]]
        else { return nil }
        let match = results.first { result in
            let resultArtist = (result["artist"] as? [String: Any])?["name"] as? String ?? ""
            let length = result["duration"] as? Double ?? 0
            return same(result["title"] as? String ?? "", title) && same(resultArtist, artist)
                && (duration <= 0 || abs(length - duration) < 6)
        }
        guard let id = match?["id"] as? Int,
              let trackURL = URL(string: "https://api.deezer.com/track/\(id)"),
              let (trackData, _) = try? await URLSession.shared.data(from: trackURL),
              let track = try? JSONSerialization.jsonObject(with: trackData) as? [String: Any]
        else { return nil }
        return (track["isrc"] as? String).flatMap(normalized)
    }

    private static func same(_ a: String, _ b: String) -> Bool {
        let fold = { (s: String) in
            s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).filter { $0.isLetter || $0.isNumber }
        }
        let x = fold(a), y = fold(b)
        return !x.isEmpty && (x == y || x.hasPrefix(y) || y.hasPrefix(x))
    }

    private static func normalized(_ value: String) -> String? {
        let code = value.uppercased().filter { $0.isLetter || $0.isNumber }
        return code.count == 12 ? code : nil
    }
}
