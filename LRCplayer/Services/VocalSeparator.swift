import Accelerate
import AVFoundation
#if targetEnvironment(macCatalyst)
import CoreAudio
#endif
import AppleArchive
import Combine
import CoreML
import Synchronization
import System

// MARK: - Model

/// The on-device vocal separation model (HTDemucs, vocals only), downloaded
/// on request from Settings and deleted from there.
@MainActor
final class SingAlongModel: ObservableObject {
    static let shared = SingAlongModel()

    enum State: Equatable {
        case notInstalled
        case downloading(Double)
        case installing
        case installed
        case failed(String)
    }

    @Published private(set) var state: State = .notInstalled

    /// The compiled model, as an Apple Archive, on Hugging Face.
    static let remoteURL = URL(string: "https://huggingface.co/tlfares/htdemucs-vocals-coreml/resolve/main/SingAlongModel.aar")!
    static let downloadSize = Int64(33_000_000).formatted(.byteCount(style: .file))
    /// HTDemucs needs room: 6 GB phones and up (iPhone 14 Pro, 15 and later).
    static let isSupported = ProcessInfo.processInfo.physicalMemory >= 5_500_000_000

    nonisolated private static let directory = URL.applicationSupportDirectory.appending(path: "SingAlong", directoryHint: .isDirectory)
    nonisolated static let modelURL = directory.appending(path: "Vocals.mlmodelc", directoryHint: .isDirectory)

    private var task: Task<Void, Never>?

    private init() {
        if FileManager.default.fileExists(atPath: Self.modelURL.path) { state = .installed }
        // Before it was hosted, the model came from a copy left here.
        try? FileManager.default.removeItem(at: URL.documentsDirectory.appending(path: "SingAlongModel.aar"))
    }

    var isInstalled: Bool { state == .installed }

    func download() {
        guard task == nil, !isInstalled else { return }
        state = .downloading(0)
        task = Task {
            defer { task = nil }
            do {
                let archive = try await fetchArchive()
                state = .installing
                try await Task.detached { try Self.install(archive) }.value
                state = .installed
            } catch is CancellationError {
                state = .notInstalled
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        task?.cancel()
    }

    func delete() {
        task?.cancel()
        SingAlong.shared.turnOff()
        SingAlong.shared.modelDeleted()
        // The songs already separated stay, for when it comes back.
        try? FileManager.default.removeItem(at: Self.directory)
        state = .notInstalled
    }

    private func fetchArchive() async throws -> URL {
        let progress = DownloadProgress { [weak self] fraction in
            Task { @MainActor in
                guard let self, case .downloading = self.state else { return }
                self.state = .downloading(fraction)
            }
        }
        let (file, response) = try await URLSession.shared.download(from: Self.remoteURL, delegate: progress)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let kept = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".aar")
        try FileManager.default.moveItem(at: file, to: kept)
        return kept
    }

    /// Unpacks the Apple Archive (a compiled `Vocals.mlmodelc`).
    nonisolated private static func install(_ archive: URL) throws {
        let fileManager = FileManager.default
        let staging = fileManager.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }
        guard let read = ArchiveByteStream.fileStream(path: FilePath(archive.path), mode: .readOnly, options: [], permissions: FilePermissions(rawValue: 0o644)),
              let decompress = ArchiveByteStream.decompressionStream(readingFrom: read),
              let decode = ArchiveStream.decodeStream(readingFrom: decompress),
              let extract = ArchiveStream.extractStream(extractingTo: FilePath(staging.path), flags: [.ignoreOperationNotPermitted]) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        defer {
            try? extract.close()
            try? decode.close()
            try? decompress.close()
            try? read.close()
        }
        _ = try ArchiveStream.process(readingFrom: decode, writingTo: extract)
        let unpacked = staging.appending(path: "Vocals.mlmodelc", directoryHint: .isDirectory)
        guard fileManager.fileExists(atPath: unpacked.path) else { throw CocoaError(.fileReadCorruptFile) }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try? fileManager.removeItem(at: modelURL)
        try fileManager.moveItem(at: unpacked, to: modelURL)
        try? fileManager.removeItem(at: archive)
    }
}

private final class DownloadProgress: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let update: @Sendable (Double) -> Void
    private var observation: NSKeyValueObservation?

    init(update: @escaping @Sendable (Double) -> Void) {
        self.update = update
    }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        let update = update
        observation = task.progress.observe(\.fractionCompleted) { @Sendable progress, _ in
            update(progress.fractionCompleted)
        }
    }
}

// MARK: - Feature

/// Turns the vocals down under the synced lyrics: the song is separated on
/// device, a few seconds at a time from where it's playing, and played back
/// by `VocalStage` in place of the player (which keeps running, muted, as
/// the clock).
@MainActor
final class SingAlong: ObservableObject {
    static let shared = SingAlong()

    @Published private(set) var isOn = false
    /// How loud the vocals stay: 0 is gone, 1 is the original.
    @Published var level: Float = 0.1 {
        didSet { stage.setLevel(level) }
    }
    /// Part of the current song separated so far.
    @Published private(set) var progress: Double = 0
    /// The stage is playing the current song (separated or not yet).
    @Published private(set) var isAudible = false

    private var stage = VocalStage()
    private var job: Task<Void, Never>?
    private var songID: UUID?
    /// Ready before the player got to its song (AutoMix prepares the next
    /// one during the fade).
    private var pending: StageTrack?
    /// The song AutoMix is fading out, still without its vocals.
    private var fading: VocalStage?
    /// Where the player was told to play from and hasn't left yet.
    private var waitingFrom: TimeInterval?
    private var waitStart = Date.now
    private var waitTimer: Timer?
    private var wasPlaying = false
    private let models = SeparationModels.shared

    private init() {
        stage.setLevel(level)
    }

    func toggle() {
        isOn ? turnOff() : turnOn()
    }

    func turnOn() {
        guard SingAlongModel.shared.isInstalled, !isOn else { return }
        isOn = true
        prepareCurrentSong()
    }

    func turnOff() {
        guard isOn else { return }
        isOn = false
        stopSong()
        fading?.stop()
        fading = nil
    }

    /// The player changed song, position, volume or state.
    func playerDidChange() {
        guard isOn else { return }
        let player = MusicPlayerService.shared
        if player.currentSong?.id != songID {
            // Until the switch, the song mixing out is still the current one.
            guard player.mix == nil else { return }
            prepareCurrentSong()
            return
        }
        if let track = pending {
            pending = nil
            engage(track, for: songID!)
            return
        }
        follow()
    }

    /// Keeps the stage with the player. After a seek or a start, the player
    /// takes a moment to really move: the stage waits on the spot until it
    /// does, rather than play ahead and jump back (a stutter).
    private func follow() {
        let player = MusicPlayerService.shared
        let time = player.preciseCurrentTime
        let playing = player.isPlaying
        defer { wasPlaying = playing }
        if playing, player.isSeeking || !wasPlaying || stage.isAway(from: time) {
            if waitingFrom != time {
                waitingFrom = time
                waitStart = .now
            }
        } else if let from = waitingFrom, !playing || time > from + 0.002 || waitStart.distance(to: .now) > 1.5 {
            waitingFrom = nil
        }
        stage.sync(time: time, playing: playing, volume: player.outputVolume, held: waitingFrom != nil)
        // Checked often while waiting, so the stage starts with the player.
        if waitingFrom == nil {
            waitTimer?.invalidate()
            waitTimer = nil
        } else if waitTimer == nil {
            let timer = Timer(timeInterval: 0.004, repeats: true) { _ in
                MainActor.assumeIsolated { SingAlong.shared.followIfActive() }
            }
            RunLoop.main.add(timer, forMode: .common)
            waitTimer = timer
        }
    }

    private func followIfActive() {
        guard isOn, isAudible, MusicPlayerService.shared.currentSong?.id == songID else {
            waitingFrom = nil
            waitTimer?.invalidate()
            waitTimer = nil
            return
        }
        follow()
    }

    /// AutoMix starts fading out the current song: it stays on the stage,
    /// and the next song is prepared from where it will come in. While it
    /// `playsFade`, `mixDidStep` drives it.
    func mixWillStart(to next: Song, at time: TimeInterval) {
        guard isOn else { return }
        if isAudible {
            fading = stage
            stage = VocalStage()
            stage.setLevel(level)
            isAudible = false
        }
        prepare(next, from: time)
    }

    /// The stage, not the player, is heard fading out.
    var playsFade: Bool { fading != nil }

    func mixDidStep(time: TimeInterval, playing: Bool, volume: Float) {
        fading?.sync(time: time, playing: playing, volume: volume)
    }

    func mixDidEnd() {
        fading?.stop()
        fading = nil
        playerDidChange()
    }

    private func prepareCurrentSong() {
        stopSong()
        let player = MusicPlayerService.shared
        guard let song = player.currentSong, player.mix == nil else { return }
        prepare(song, from: player.preciseCurrentTime)
    }

    private func prepare(_ song: Song, from start: TimeInterval) {
        stopSong()
        songID = song.id
        progress = 0
        let url = song.isMediaLibraryItem ? song.fileURL : song.playableFileURL
        let id = song.id
        let models = models
        let streamed = song.isRemote && !song.isDownloaded ? song : nil
        job = Task.detached(priority: .userInitiated) { [weak self] in
            // A streamed song is downloaded first: separating reads the file.
            if let streamed {
                guard await SubsonicDownloads.shared.ensureLocal(streamed), !Task.isCancelled else { return }
            }
            guard let track = await StageTrack.load(url), !Task.isCancelled else { return }
            // A song already separated doesn't wait for the model to load.
            if VocalsCache.load(id, into: track) { track.markAllReady() }
            await self?.engage(track, for: id)
            guard !track.isComplete else {
                await self?.setProgress(1)
                return
            }
            guard let model = await models.load() else {
                await self?.turnOff()
                return
            }
            guard !Task.isCancelled else { return }
            VocalSeparator(model: model.model).run(track, from: start) { fraction in
                Task { @MainActor in self?.setProgress(fraction) }
            }
            if track.isComplete, !Task.isCancelled { VocalsCache.save(track, for: id) }
        }
    }

    private func engage(_ track: StageTrack, for id: UUID) {
        guard isOn, songID == id else { return }
        let player = MusicPlayerService.shared
        guard player.currentSong?.id == id else {
            pending = track
            return
        }
        guard stage.start(track, time: player.preciseCurrentTime, playing: player.isPlaying, volume: player.outputVolume) else { return }
        wasPlaying = player.isPlaying
        isAudible = true
        player.setStageAudible(true)
    }

    private func setProgress(_ fraction: Double) {
        progress = fraction
    }

    private func stopSong() {
        job?.cancel()
        job = nil
        songID = nil
        pending = nil
        progress = 0
        if isAudible {
            isAudible = false
            MusicPlayerService.shared.setStageAudible(false)
        }
        stage.stop()
    }

    func modelDeleted() {
        Task { await models.unload() }
    }
}

/// Loads the model once, off the main thread (it takes a moment).
private actor SeparationModels {
    static let shared = SeparationModels()

    final class Loaded: @unchecked Sendable {
        let model: MLModel
        init(_ model: MLModel) { self.model = model }
    }

    private var loaded: Loaded?

    func load() -> Loaded? {
        if let loaded { return loaded }
        guard FileManager.default.fileExists(atPath: SingAlongModel.modelURL.path) else { return nil }
        let configuration = MLModelConfiguration()
        // The Neural Engine overflows in half precision here; the GPU doesn't.
        configuration.computeUnits = .cpuAndGPU
        loaded = (try? MLModel(contentsOf: SingAlongModel.modelURL, configuration: configuration)).map(Loaded.init)
        return loaded
    }

    func unload() {
        loaded = nil
    }
}

// MARK: - Separation

/// HTDemucs' `apply_model`: 7.8 s windows overlapping by a quarter, blended
/// with triangular weights. Windows are run from where the song is playing,
/// then on to the end, then the beginning.
final class VocalSeparator: @unchecked Sendable {
    private let model: MLModel
    private let spectrogram = DemucsSpectrogram()

    /// Loaded only if the GPU is refused.
    private lazy var cpuModel: MLModel? = {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuOnly
        return try? MLModel(contentsOf: SingAlongModel.modelURL, configuration: configuration)
    }()

    init(model: MLModel) {
        self.model = model
    }

    static let segment = DemucsSpectrogram.segment
    static let stride = segment * 3 / 4

    /// Triangular weights, peak 1.
    private static let weights: [Float] = {
        let half = segment / 2
        var weights = (0..<half).map { Float($0 + 1) } + (0..<(segment - half)).map { Float(segment - half - $0) }
        let peak = weights.max() ?? 1
        weights = weights.map { $0 / peak }
        return weights
    }()

    /// In place, like `(x - x.mean()) / (1e-5 + x.std())`. Returns what
    /// undoes it.
    private static func normalize(_ x: UnsafeMutablePointer<Float>, count: Int) -> (mean: Float, std: Float) {
        var mean: Float = 0
        vDSP_meanv(x, 1, &mean, vDSP_Length(count))
        var negative = -mean
        vDSP_vsadd(x, 1, &negative, x, 1, vDSP_Length(count))
        var squares: Float = 0
        vDSP_svesq(x, 1, &squares, vDSP_Length(count))
        let std = (squares / Float(count - 1)).squareRoot() + 1e-5
        var inverse = 1 / std
        vDSP_vsmul(x, 1, &inverse, x, 1, vDSP_Length(count))
        return (mean, std)
    }

    /// The model's output as contiguous floats, whatever it came back as.
    private static func copy(_ array: MLMultiArray, into buffer: UnsafeMutablePointer<Float>, count: Int) {
        let shape = array.shape.map(\.intValue)
        var expected = 1
        var contiguous = array.count == count
        for (size, stride) in zip(shape, array.strides.map(\.intValue)).reversed() {
            if size > 1, stride != expected { contiguous = false }
            expected *= size
        }
        if contiguous, array.dataType == .float32 {
            buffer.update(from: array.dataPointer.assumingMemoryBound(to: Float.self), count: count)
        } else {
            let scalars = MLShapedArray<Float>(converting: array).scalars
            scalars.withUnsafeBufferPointer { buffer.update(from: $0.baseAddress!, count: count) }
        }
    }

    func run(_ track: StageTrack, from time: TimeInterval, progress: @escaping (Double) -> Void) {
        let length = track.count
        let chunkCount = (length + Self.stride - 1) / Self.stride
        guard chunkCount > 0,
              let mix = try? MLMultiArray(shape: [1, 2, NSNumber(value: Self.segment)], dataType: .float32),
              let spec = try? MLMultiArray(shape: [1, 4, NSNumber(value: DemucsSpectrogram.bins), NSNumber(value: DemucsSpectrogram.frames)], dataType: .float32) else { return }

        let (mean, std) = track.statistics()
        let first = min(chunkCount - 1, max(0, Int(time * StageTrack.sampleRate) / Self.stride))
        var order = Array(max(0, first - 1)..<chunkCount)
        order += Array(0..<max(0, first - 1))
        var done = [Bool](repeating: false, count: chunkCount)
        let segment = Self.segment
        let left = UnsafeMutablePointer<Float>.allocate(capacity: segment)
        let right = UnsafeMutablePointer<Float>.allocate(capacity: segment)
        let freqBuffer = UnsafeMutablePointer<Float>.allocate(capacity: DemucsSpectrogram.spectrumCount)
        let timeBuffer = UnsafeMutablePointer<Float>.allocate(capacity: 2 * segment)
        defer {
            for buffer in [left, right, freqBuffer, timeBuffer] { buffer.deallocate() }
        }

        for (step, chunk) in order.enumerated() {
            if Task.isCancelled { return }
            let offset = chunk * Self.stride
            let chunkLength = min(segment, length - offset)
            // The last window is padded on both sides with what's around it.
            let lead = (segment - chunkLength) / 2
            let start = offset - lead
            let mixL = mix.dataPointer.assumingMemoryBound(to: Float.self)
            let mixR = mixL + segment
            // The song's own normalization (zeros where the window overhangs).
            mixL.update(repeating: 0, count: 2 * segment)
            let from = max(0, start)
            let to = min(length, start + segment)
            var centering = -mean
            var scaling = 1 / std
            vDSP_vsadd(track.left + from, 1, &centering, mixL + (from - start), 1, vDSP_Length(to - from))
            vDSP_vsadd(track.right + from, 1, &centering, mixR + (from - start), 1, vDSP_Length(to - from))
            vDSP_vsmul(mixL + (from - start), 1, &scaling, mixL + (from - start), 1, vDSP_Length(to - from))
            vDSP_vsmul(mixR + (from - start), 1, &scaling, mixR + (from - start), 1, vDSP_Length(to - from))
            // The model's own normalization, done here: its statistics
            // overflow in half precision.
            let specData = spec.dataPointer.assumingMemoryBound(to: Float.self)
            spectrogram.spectrogram(left: mixL, right: mixR, into: specData)
            let (specMean, specStd) = Self.normalize(specData, count: DemucsSpectrogram.spectrumCount)
            let (timeMean, timeStd) = Self.normalize(mixL, count: 2 * segment)
            let input = try? MLDictionaryFeatureProvider(dictionary: ["mix": mix, "spec": spec])
            // In the background iOS refuses the GPU: the CPU takes over.
            var prediction = input.flatMap { try? model.prediction(from: $0) }
            if prediction == nil, let input { prediction = try? cpuModel?.prediction(from: input) }
            guard let output = prediction,
                  let freq = output.featureValue(for: "freq")?.multiArrayValue,
                  let time = output.featureValue(for: "time")?.multiArrayValue else { return }
            Self.copy(freq, into: freqBuffer, count: DemucsSpectrogram.spectrumCount)
            Self.copy(time, into: timeBuffer, count: 2 * segment)
            var scale = specStd
            var shift = specMean
            vDSP_vsmsa(freqBuffer, 1, &scale, &shift, freqBuffer, 1, vDSP_Length(DemucsSpectrogram.spectrumCount))
            spectrogram.waveform(from: freqBuffer, left: left, right: right)
            // Vocals = frequency branch + time branch, back to the song's
            // scale, weighted into the running sums.
            scale = timeStd
            shift = timeMean
            vDSP_vsmsa(timeBuffer, 1, &scale, &shift, timeBuffer, 1, vDSP_Length(2 * segment))
            vDSP_vadd(left + lead, 1, timeBuffer + lead, 1, left + lead, 1, vDSP_Length(chunkLength))
            vDSP_vadd(right + lead, 1, timeBuffer + segment + lead, 1, right + lead, 1, vDSP_Length(chunkLength))
            Self.weights.withUnsafeBufferPointer { weights in
                vDSP_vmul(left + lead, 1, weights.baseAddress!, 1, left + lead, 1, vDSP_Length(chunkLength))
                vDSP_vmul(right + lead, 1, weights.baseAddress!, 1, right + lead, 1, vDSP_Length(chunkLength))
            }
            var trackStd = std
            vDSP_vsma(left + lead, 1, &trackStd, track.vocalsLeft + offset, 1, track.vocalsLeft + offset, 1, vDSP_Length(chunkLength))
            vDSP_vsma(right + lead, 1, &trackStd, track.vocalsRight + offset, 1, track.vocalsRight + offset, 1, vDSP_Length(chunkLength))
            done[chunk] = true
            // A block (one stride) is final once its window and the one
            // before it are in.
            for block in [chunk, chunk + 1] where block < chunkCount && done[block] && (block == 0 || done[block - 1]) {
                track.finish(block: block, mean: mean)
            }
            progress(Double(step + 1) / Double(order.count))
        }
    }
}

extension VocalSeparator {
    /// The whole song's vocals, from the cache or separated now (for the
    /// games). False without the model, or if cancelled.
    static func separateAll(_ track: StageTrack, id: UUID, progress: @escaping (Double) -> Void) async -> Bool {
        if VocalsCache.load(id, into: track) {
            track.markAllReady()
            return true
        }
        guard let model = await SeparationModels.shared.load(), !Task.isCancelled else { return false }
        VocalSeparator(model: model.model).run(track, from: 0, progress: progress)
        guard track.isComplete, !Task.isCancelled else { return false }
        VocalsCache.save(track, for: id)
        return true
    }

    /// A short excerpt's vocals, separated now and not kept.
    static func separateExcerpt(_ track: StageTrack) async -> Bool {
        guard let model = await SeparationModels.shared.load(), !Task.isCancelled else { return false }
        VocalSeparator(model: model.model).run(track, from: 0) { _ in }
        return track.isComplete
    }
}

// MARK: - Track

/// A song decoded for the stage: the original and, block by block, its
/// vocals. Blocks are `VocalSeparator.stride` samples long.
final class StageTrack: @unchecked Sendable {
    static let sampleRate = 44_100.0
    static let maxBlocks = 256

    let count: Int
    let left: UnsafeMutablePointer<Float>
    let right: UnsafeMutablePointer<Float>
    /// Weighted sums while separating; the vocals once a block is ready.
    let vocalsLeft: UnsafeMutablePointer<Float>
    let vocalsRight: UnsafeMutablePointer<Float>
    let blockCount: Int
    private let ready = UnsafeMutablePointer<UInt8>.allocate(capacity: maxBlocks)
    private let readyCount = Atomic<Int>(0)

    private init(count: Int) {
        self.count = count
        left = .allocate(capacity: count)
        right = .allocate(capacity: count)
        vocalsLeft = .allocate(capacity: count)
        vocalsRight = .allocate(capacity: count)
        vocalsLeft.initialize(repeating: 0, count: count)
        vocalsRight.initialize(repeating: 0, count: count)
        blockCount = min(Self.maxBlocks, (count + VocalSeparator.stride - 1) / VocalSeparator.stride)
        ready.initialize(repeating: 0, count: Self.maxBlocks)
    }

    deinit {
        for buffer in [left, right, vocalsLeft, vocalsRight] { buffer.deallocate() }
        ready.deallocate()
    }

    var isComplete: Bool { readyCount.load(ordering: .acquiring) >= blockCount }

    /// Read on the audio thread.
    @inline(__always) func isReady(sample: Int) -> Bool {
        let block = sample / VocalSeparator.stride
        guard block < blockCount else { return false }
        _ = readyCount.load(ordering: .acquiring)
        return ready[block] != 0
    }

    /// Divides the weighted sums by the weights that went into them.
    func finish(block: Int, mean: Float) {
        guard block < blockCount else { return }
        let stride = VocalSeparator.stride
        let start = block * stride
        let end = min(count, start + stride)
        let segment = VocalSeparator.segment
        let windows = (count + stride - 1) / stride
        for i in start..<end {
            var total: Float = 0
            // At most two windows cover a sample.
            for chunk in max(0, i / stride - 1)...min(windows - 1, i / stride) {
                let offset = chunk * stride
                let index = i - offset
                if index < min(segment, count - offset) { total += Self.weight(index) }
            }
            let scale = total > 0 ? 1 / total : 0
            vocalsLeft[i] = vocalsLeft[i] * scale + mean
            vocalsRight[i] = vocalsRight[i] * scale + mean
        }
        ready[block] = 1
        readyCount.add(1, ordering: .releasing)
    }

    func markAllReady() {
        for block in 0..<blockCount { ready[block] = 1 }
        readyCount.store(blockCount, ordering: .releasing)
    }

    private static func weight(_ index: Int) -> Float {
        let segment = VocalSeparator.segment
        let half = segment / 2
        let peak = Float(max(half, segment - half))
        return index < half ? Float(index + 1) / peak : Float(segment - index) / peak
    }

    /// Mean and standard deviation of the mono mix, as Demucs normalizes.
    func statistics() -> (Float, Float) {
        var sum = 0.0
        var squares = 0.0
        for i in 0..<count {
            let mono = Double(left[i] + right[i]) / 2
            sum += mono
            squares += mono * mono
        }
        let n = Double(max(count, 2))
        let mean = sum / n
        let variance = max(0, (squares - n * mean * mean) / (n - 1))
        return (Float(mean), Float(max(sqrt(variance), 1e-5)))
    }

    /// Decodes the whole song (or just `range` of it), stereo at 44.1 kHz.
    static func load(_ url: URL, range: ClosedRange<TimeInterval>? = nil) async -> StageTrack? {
        let asset = AVURLAsset(url: url)
        guard let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first,
              let reader = try? AVAssetReader(asset: asset) else { return nil }
        let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        if let range {
            reader.timeRange = CMTimeRange(start: CMTime(seconds: range.lowerBound, preferredTimescale: 44_100),
                                           end: CMTime(seconds: range.upperBound, preferredTimescale: 44_100))
        }
        guard reader.startReading() else { return nil }
        var interleaved: [Float] = []
        if let range {
            interleaved.reserveCapacity(Int((range.upperBound - range.lowerBound) * sampleRate * 2) + 4096)
        } else if let duration = try? await asset.load(.duration), duration.seconds.isFinite {
            interleaved.reserveCapacity(Int(duration.seconds * sampleRate * 2) + 4096)
        }
        while let buffer = output.copyNextSampleBuffer() {
            if Task.isCancelled { return nil }
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            let previous = interleaved.count
            interleaved.append(contentsOf: repeatElement(0, count: length / 4))
            interleaved.withUnsafeMutableBytes { raw in
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress! + previous * 4)
            }
        }
        guard reader.status == .completed, interleaved.count >= 4 else { return nil }
        let track = StageTrack(count: interleaved.count / 2)
        for i in 0..<track.count {
            track.left[i] = interleaved[2 * i]
            track.right[i] = interleaved[2 * i + 1]
        }
        return track
    }
}

// MARK: - Cache

/// Separated vocals, kept so a song is ready at once the next time.
enum VocalsCache {
    private static let directory = URL.cachesDirectory.appending(path: "SingAlong", directoryHint: .isDirectory)
    private static let limit = 30

    private static func url(for id: UUID) -> URL {
        directory.appending(path: id.uuidString + ".caf")
    }

    static func load(_ id: UUID, into track: StageTrack) -> Bool {
        guard let file = try? AVAudioFile(forReading: url(for: id), commonFormat: .pcmFormatFloat32, interleaved: false),
              Int(file.length) == track.count,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil,
              let channels = buffer.floatChannelData, buffer.format.channelCount == 2 else { return false }
        track.vocalsLeft.update(from: channels[0], count: track.count)
        track.vocalsRight.update(from: channels[1], count: track.count)
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url(for: id).path)
        return true
    }

    /// Part of a song's kept vocals, from `start`, as long as `track`.
    static func excerpt(_ id: UUID, from start: Int, into track: StageTrack) -> Bool {
        guard start >= 0,
              let file = try? AVAudioFile(forReading: url(for: id), commonFormat: .pcmFormatFloat32, interleaved: false),
              Int64(start + track.count) <= file.length,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(track.count)) else { return false }
        file.framePosition = AVAudioFramePosition(start)
        guard (try? file.read(into: buffer, frameCount: AVAudioFrameCount(track.count))) != nil,
              let channels = buffer.floatChannelData, buffer.format.channelCount == 2,
              Int(buffer.frameLength) == track.count else { return false }
        track.vocalsLeft.update(from: channels[0], count: track.count)
        track.vocalsRight.update(from: channels[1], count: track.count)
        track.markAllReady()
        return true
    }

    static func save(_ track: StageTrack, for id: UUID) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatAppleLossless,
            AVSampleRateKey: StageTrack.sampleRate,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitDepthHintKey: 16
        ]
        guard let file = try? AVAudioFile(forWriting: url(for: id), settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(track.count)),
              let channels = buffer.floatChannelData else { return }
        buffer.frameLength = AVAudioFrameCount(track.count)
        channels[0].update(from: track.vocalsLeft, count: track.count)
        channels[1].update(from: track.vocalsRight, count: track.count)
        try? file.write(from: buffer)
        trim()
    }

    static func clear() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// The songs kept, and the space they take.
    static func usage() -> (songs: Int, bytes: Int64) {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        let bytes = files.reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        return (files.count, bytes)
    }

    /// Keeps the most recently used songs.
    private static func trim() {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys),
              files.count > limit else { return }
        let sorted = files.sorted {
            let a = (try? $0.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
            return a > b
        }
        for file in sorted.dropFirst(limit) { try? FileManager.default.removeItem(at: file) }
    }
}

// MARK: - Playback

/// Plays the current song from memory: the original minus part of its
/// vocals where they're separated, the original elsewhere. Follows the
/// player's position, state and volume.
final class VocalStage: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var node: AVAudioSourceNode?
    private var configurationObserver: NSObjectProtocol?

    // Set from the main thread, read on the audio thread.
    private let playing = Atomic<Bool>(false)
    private let levelBits = Atomic<UInt32>(Float(0.1).bitPattern)
    private let volumeBits = Atomic<UInt32>(Float(1).bitPattern)
    private let seekTarget = Atomic<Int>(-1)
    private let position = Atomic<Int>(0)
    private let held = Atomic<Bool>(false)
    // Audio thread only.
    private var track: StageTrack?
    private var cursor = 0
    private var level: Float = 0.1
    private var volume: Float = 1
    private var wet: Float = 0

    func setLevel(_ value: Float) {
        levelBits.store(value.bitPattern, ordering: .relaxed)
    }

    /// Starts on `track` at `time`. False if the engine won't start.
    func start(_ track: StageTrack, time: TimeInterval, playing isPlaying: Bool, volume: Float) -> Bool {
        stop()
        self.track = track
        cursor = Int(time * StageTrack.sampleRate)
        position.store(cursor, ordering: .relaxed)
        seekTarget.store(-1, ordering: .relaxed)
        held.store(false, ordering: .relaxed)
        self.volume = volume
        volumeBits.store(volume.bitPattern, ordering: .relaxed)
        level = Float(bitPattern: levelBits.load(ordering: .relaxed))
        wet = track.isReady(sample: cursor) ? 1 : 0
        playing.store(isPlaying, ordering: .relaxed)

        let format = AVAudioFormat(standardFormatWithSampleRate: StageTrack.sampleRate, channels: 2)!
        let node = AVAudioSourceNode(format: format) { [unowned self] _, _, frameCount, buffers in
            self.render(frameCount: Int(frameCount), buffers: UnsafeMutableAudioBufferListPointer(buffers))
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
        // Paused, the engine waits: a running one tells iOS the app plays.
        guard isPlaying else { return true }
        do {
            try engine.start()
            return true
        } catch {
            stop()
            return false
        }
    }

    func stop() {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        engine.stop()
        if let node {
            engine.detach(node)
        }
        node = nil
        track = nil
        playing.store(false, ordering: .relaxed)
    }

    /// Keeps up with the player; jumps when they drift apart (a seek).
    /// Held, it stays silent on `time` until released.
    func sync(time: TimeInterval, playing isPlaying: Bool, volume: Float, held isHeld: Bool = false) {
        guard node != nil else { return }
        volumeBits.store(volume.bitPattern, ordering: .relaxed)
        let target = Int(time * StageTrack.sampleRate)
        if isHeld || isAway(from: time) {
            seekTarget.store(target, ordering: .relaxed)
            position.store(target, ordering: .relaxed)
        }
        held.store(isHeld, ordering: .relaxed)
        playing.store(isPlaying, ordering: .relaxed)
        // A running engine, even silent, shows the app as playing in iOS.
        if isPlaying {
            if !engine.isRunning { try? engine.start() }
        } else if engine.isRunning {
            engine.pause()
        }
    }

    /// Too far from the player to be the same moment: a seek.
    func isAway(from time: TimeInterval) -> Bool {
        guard node != nil else { return false }
        return abs(Int(time * StageTrack.sampleRate) - position.load(ordering: .relaxed)) > Int(0.06 * StageTrack.sampleRate)
    }

    private func render(frameCount: Int, buffers: UnsafeMutableAudioBufferListPointer) {
        guard buffers.count >= 2,
              let outL = buffers[0].mData?.assumingMemoryBound(to: Float.self),
              let outR = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return }
        let seek = seekTarget.exchange(-1, ordering: .relaxed)
        if seek >= 0 { cursor = seek }
        // Held on a seek, it waits there (and stays where it was told).
        if held.load(ordering: .relaxed) {
            outL.update(repeating: 0, count: frameCount)
            outR.update(repeating: 0, count: frameCount)
            return
        }
        guard let track, playing.load(ordering: .relaxed) else {
            outL.update(repeating: 0, count: frameCount)
            outR.update(repeating: 0, count: frameCount)
            return
        }
        let targetLevel = Float(bitPattern: levelBits.load(ordering: .relaxed))
        let targetVolume = Float(bitPattern: volumeBits.load(ordering: .relaxed))
        // ~30 ms smoothing, so nothing clicks.
        let smoothing: Float = 0.00075
        var ready = track.isReady(sample: cursor)
        var nextBoundary = (cursor / VocalSeparator.stride + 1) * VocalSeparator.stride
        for i in 0..<frameCount {
            let c = cursor
            if c >= nextBoundary {
                ready = track.isReady(sample: c)
                nextBoundary += VocalSeparator.stride
            }
            wet += ((ready ? 1 : 0) - wet) * smoothing
            level += (targetLevel - level) * smoothing
            volume += (targetVolume - volume) * smoothing * 4
            if c < track.count {
                let cut = ready ? wet * (1 - level) : 0
                outL[i] = (track.left[c] - cut * track.vocalsLeft[c]) * volume
                outR[i] = (track.right[c] - cut * track.vocalsRight[c]) * volume
            } else {
                outL[i] = 0
                outR[i] = 0
            }
            cursor += 1
        }
        position.store(cursor, ordering: .relaxed)
    }
}
