import Foundation
import AVFoundation
import Speech
import NaturalLanguage

/// The assistant's ears: listens until the user stops talking, in French
/// and English at once, and keeps whichever understood better.
@MainActor
final class AssistantVoice: NSObject, ObservableObject {
    enum Phase: Equatable {
        case idle
        case listening
        case thinking
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var transcript = ""
    /// Microphone level, 0…1, for the orb.
    @Published private(set) var level: Float = 0

    /// Made for each listen, once the session records: an engine whose
    /// input was touched under the playback category keeps a 0 Hz input.
    private var engine: AVAudioEngine?
    /// One per language, fed the same microphone.
    private var requests: [SFSpeechAudioBufferRecognitionRequest] = []
    private var recognitions: [SFSpeechRecognitionTask] = []
    private var heard: [Heard] = []
    private var silenceTask: Task<Void, Never>?
    private var listenContinuation: CheckedContinuation<String, Never>?
    private var sessionActive = false
    /// Which listen a recognition callback belongs to: a cancelled one still
    /// reports (an error, a final result) and mustn't end the next.
    private var generation = 0
    private var configurationObserver: NSObjectProtocol?
    /// The listen's audio, for Mistral's transcription (Voxtral), which
    /// knows any language and mixes of them far better than Apple's
    /// one-language recognizers.
    private var recording: AVAudioFile?

    /// How long a pause ends the request.
    private static let silence: Duration = .milliseconds(1400)
    /// Gives up when nothing is said at all.
    private static let noSpeechTimeout: Duration = .seconds(8)

    // MARK: Permissions

    /// Asks for the microphone and speech recognition; nil when both are
    /// granted, else what's missing.
    func authorize() async -> String? {
        let french = AssistantService.prefersFrench
        let speech = await Self.speechAuthorization()
        guard speech == .authorized else {
            return french ? "Autorise la reconnaissance vocale dans Réglages pour parler à l'assistant." : "Allow Speech Recognition in Settings to talk to the assistant."
        }
        guard await AVAudioApplication.requestRecordPermission() else {
            return french ? "Autorise le micro dans Réglages pour parler à l'assistant." : "Allow the microphone in Settings to talk to the assistant."
        }
        return nil
    }

    /// Outside the main actor: Speech answers on a background queue, and a
    /// main-actor callback traps there.
    private nonisolated static func speechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { @Sendable status in continuation.resume(returning: status) }
        }
    }

    // MARK: Session

    private func beginAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        // No Bluetooth hands-free profile: AirPods and cars would switch to
        // call quality and the route change stops the engine mid-sentence.
        // The music stays on A2DP and the iPhone's microphone listens.
        try session.setCategory(.playAndRecord, mode: .default, options: [.duckOthers, .defaultToSpeaker, .allowBluetoothA2DP])
        try session.setActive(true)
        MusicPlayerService.shared.setDucked(true)
        sessionActive = true
    }

    /// Hands the audio back to the music.
    func endSession() {
        stopListening()
        if sessionActive {
            sessionActive = false
            MusicPlayerService.shared.setDucked(false)
            MusicPlayerService.shared.restoreAudioSession()
        }
        phase = .idle
        level = 0
    }

    // MARK: Listening

    /// Listens until the user pauses; returns what they said ("" for nothing).
    func listen() async -> String {
        stopListening()
        guard !Task.isCancelled else { return "" }
        transcript = ""
        recognitionError = nil
        let french = AssistantService.prefersFrench
        let recognizers = Self.recognizers()
        guard !recognizers.isEmpty else {
            phase = .failed(french ? "La reconnaissance vocale n'est pas disponible." : "Speech recognition isn't available.")
            return ""
        }
        do {
            try beginAudioSession()
        } catch {
            phase = .failed(error.localizedDescription)
            return ""
        }

        // Artist and playlist names are what recognizers get wrong most.
        let vocabulary = Self.vocabulary()
        var onDevice = false
        requests = recognizers.map { recognizer in
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.addsPunctuation = true
            // Only the device's own language on device: the other language's
            // on-device model is often missing, and two on-device
            // recognizers at once let one fail silently (French was lost).
            if recognizer.supportsOnDeviceRecognition, !onDeviceFailed, recognizers.count == 1 {
                request.requiresOnDeviceRecognition = true
                onDevice = true
            }
            request.contextualStrings = vocabulary
            return request
        }
        heard = recognizers.map { Heard(language: $0.locale.language.languageCode?.identifier ?? "") }

        var engine = AVAudioEngine()
        if engine.inputNode.outputFormat(forBus: 0).sampleRate == 0 {
            // The route is still settling after the category change.
            try? await Task.sleep(for: .milliseconds(300))
            engine = AVAudioEngine()
        }
        self.engine = engine
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            phase = .failed(french ? "Aucun micro disponible." : "No microphone available.")
            return ""
        }
        recording = Self.cloudKey == nil ? nil : try? AVAudioFile(
            forWriting: Self.recordingURL,
            settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: format.sampleRate, AVNumberOfChannelsKey: format.channelCount],
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.tapBlock(requests: requests, recording: recording) { [weak self] level in
            Task { @MainActor in self?.level = level }
        })
        engine.prepare()
        do {
            try engine.start()
        } catch {
            phase = .failed(error.localizedDescription)
            return ""
        }
        // The route can still change (a call, a car connecting): restart
        // the microphone on the new format instead of going deaf.
        configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restartInput() }
        }
        phase = .listening
        generation += 1
        let current = generation

        let heard = await withCheckedContinuation { continuation in
            listenContinuation = continuation
            recognitions = zip(recognizers, requests).enumerated().map { index, pair in
                pair.0.recognitionTask(with: pair.1, resultHandler: Self.resultHandler { [weak self] text, confidence, isFinal, error in
                    Task { @MainActor in self?.handle(text: text, confidence: confidence, isFinal: isFinal, error: error, channel: index, generation: current) }
                })
            }
            armSilenceTimer(after: Self.noSpeechTimeout)
        }
        // On-device recognition can fail outright (language assets missing):
        // once, try Apple's servers instead.
        if heard.isEmpty, let error = recognitionError, !Self.isNoSpeech(error), !onDeviceFailed, onDevice, !Task.isCancelled {
            onDeviceFailed = true
            return await listen()
        }
        // Something was said: Voxtral's reading of it, Apple's as a fallback.
        if !heard.isEmpty, recording != nil, let key = Self.cloudKey, !Task.isCancelled {
            recording = nil
            phase = .thinking
            if let text = await Self.transcribe(key: key), !text.isEmpty {
                transcript = text
                return text
            }
        }
        recording = nil
        if heard.isEmpty, let error = recognitionError, !Self.isNoSpeech(error) {
            phase = .failed((french ? "La reconnaissance vocale a échoué : " : "Speech recognition failed: ") + error)
        }
        return heard
    }

    // MARK: Mistral transcription

    private static let recordingURL = URL.temporaryDirectory.appending(path: "assistant-voice.m4a")

    /// Mistral's key when the user lets the assistant use Mistral.
    private static var cloudKey: String? {
        AssistantEngineChoice.current != .apple && AIFeatures.isAvailable ? AIFeatures.apiKey : nil
    }

    /// The recording as Voxtral heard it; nil when it couldn't. The
    /// library's names bias it, so artists come out spelled right.
    private static func transcribe(key: String) async -> String? {
        guard let audio = try? Data(contentsOf: recordingURL), audio.count > 2_000 else { return nil }
        func request(withNames: Bool) -> URLRequest {
            let boundary = "lrc-\(UUID().uuidString)"
            var body = Data()
            func field(_ name: String, _ value: String) {
                body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
            }
            field("model", "voxtral-mini-latest")
            if withNames {
                for name in vocabulary() { field("context_bias", name) }
            }
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"voice.m4a\"\r\nContent-Type: audio/mp4\r\n\r\n".utf8))
            body.append(audio)
            body.append(Data("\r\n--\(boundary)--\r\n".utf8))
            var request = URLRequest(url: URL(string: "https://api.mistral.ai/v1/audio/transcriptions")!)
            request.httpMethod = "POST"
            request.timeoutInterval = 20
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
            return request
        }
        struct Reply: Decodable { let text: String }
        // Names refused (a model without biasing): the plain transcription.
        for withNames in [true, false] {
            guard let (data, response) = try? await URLSession.shared.data(for: request(withNames: withNames)) else { return nil }
            if (response as? HTTPURLResponse)?.statusCode == 200 {
                return (try? JSONDecoder().decode(Reply.self, from: data))?.text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    /// Ends listening now with what was heard so far.
    func finishListening() {
        finish(with: transcript)
    }

    private var recognitionError: String?
    private var onDeviceFailed = false

    /// What one language's recognizer understood.
    private struct Heard {
        let language: String
        var text = ""
        var confidence: Float = 0
        var isDone = false
    }

    private func handle(text: String?, confidence: Float, isFinal: Bool, error: String?, channel: Int, generation: Int) {
        guard generation == self.generation, listenContinuation != nil, heard.indices.contains(channel) else { return }
        if let text, !text.isEmpty, text != heard[channel].text {
            heard[channel].text = text
            if confidence > 0 { heard[channel].confidence = confidence }
            let best = bestTranscript()
            if best != transcript {
                transcript = best
                armSilenceTimer(after: Self.silence)
            }
        } else if let text, isFinal, confidence > 0, text == heard[channel].text {
            heard[channel].confidence = confidence
        }
        if let error, transcript.isEmpty { recognitionError = error }
        if isFinal || error != nil {
            heard[channel].isDone = true
            if heard.allSatisfy(\.isDone) { finish(with: bestTranscript()) }
        }
    }

    /// The language that made the most sense of it: the recognizers' own
    /// confidence once they have one, and how French or English each
    /// transcript reads.
    private func bestTranscript() -> String {
        let candidates = heard.filter { !$0.text.isEmpty }
        // French often never reports a confidence while English reports 1.0
        // on a mishearing ("Joue du Orelsan" heard as "You"): only compare
        // confidences when every language has one.
        let useConfidence = candidates.allSatisfy { $0.confidence > 0 }
        let scored = candidates.map { heard -> (String, Float) in
            let detector = NLLanguageRecognizer()
            detector.languageConstraints = [.french, .english]
            detector.processString(heard.text)
            let reads = Float(detector.languageHypotheses(withMaximum: 2)[NLLanguage(heard.language)] ?? 0)
            // A recognizer hearing the wrong language makes out fewer words.
            let words = Float(heard.text.split(whereSeparator: \.isWhitespace).count)
            var score = reads * log(1 + words)
            if useConfidence { score *= 0.5 + heard.confidence }
            return (heard.text, score)
        }
        guard let best = scored.max(by: { $0.1 < $1.1 })?.0 else { return "" }
        return withNames(best, others: candidates.map(\.text).filter { $0 != best })
    }

    /// The library's names in `text`: French hears "The Weeknd" as
    /// "de wiquende" while English hears it right. A name another language
    /// caught, or one spelled close enough, replaces the words it sounds like.
    private func withNames(_ text: String, others: [String]) -> String {
        var words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return text }
        let normalizedOthers = others.map(AssistantText.normalize)
        for name in Self.names {
            let key = AssistantText.normalize(name)
            let nameWords = key.split(separator: " ").count
            guard nameWords > 0, !AssistantText.containsWords(AssistantText.normalize(words.joined(separator: " ")), key) else { continue }
            let caughtElsewhere = normalizedOthers.contains { AssistantText.containsWords($0, key) }
            // The run of words sounding most like the name (a word more or
            // less: recognizers split and merge names).
            var best: (range: Range<Int>, score: Double)?
            for length in max(1, nameWords - 1)...(nameWords + 1) where length <= words.count {
                for start in 0...(words.count - length) {
                    let score = AssistantText.similarity(words[start..<(start + length)].joined(separator: " "), name)
                    if score > (best?.score ?? 0) { best = (start..<(start + length), score) }
                }
            }
            // Without the other language's word for it, only long names
            // spelled almost the same: "joue" must never become "Joe".
            guard let best, caughtElsewhere ? best.score >= 0.45 : (key.count >= 6 && best.score >= 0.85) else { continue }
            words.replaceSubrange(best.range, with: [name])
        }
        return words.joined(separator: " ")
    }

    /// Artists and playlists, longest first so "Daft Punk" wins over "Punk".
    private static var names: [String] {
        let library = AppModel.shared.libraryService
        let names = Set(library.songs.map(LibraryIndex.artistName(for:)) + library.playlists.map(\.name))
        return names.filter { $0.count >= 3 }.sorted { $0.count > $1.count }
    }

    /// French and English, plus the device's language when it's another.
    private static func recognizers() -> [SFSpeechRecognizer] {
        var identifiers = ["fr-FR", "en-US"]
        if let code = Locale.current.language.languageCode?.identifier, code != "fr", code != "en" {
            identifiers.insert(Locale.current.identifier, at: 0)
        } else if let code = Locale.current.language.languageCode?.identifier, let region = Locale.current.region?.identifier {
            // The device's own accent for its language (fr-BE, en-GB…).
            identifiers[code == "fr" ? 0 : 1] = "\(code)-\(region)"
        }
        let available = identifiers.compactMap { SFSpeechRecognizer(locale: Locale(identifier: $0)) }.filter(\.isAvailable)
        if !available.isEmpty { return available }
        return [SFSpeechRecognizer()].compactMap { $0 }.filter(\.isAvailable)
    }

    /// "No speech detected" (1110) and a cancelled request (301) aren't
    /// failures worth showing.
    private static func isNoSpeech(_ error: String) -> Bool {
        error.hasSuffix(" 1110)") || error.hasSuffix(" 301)")
    }

    private func restartInput() {
        guard listenContinuation != nil, !requests.isEmpty, let engine else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { return }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.tapBlock(requests: requests, recording: recording) { [weak self] level in
            Task { @MainActor in self?.level = level }
        })
        engine.prepare()
        try? engine.start()
    }

    private func armSilenceTimer(after delay: Duration) {
        silenceTask?.cancel()
        silenceTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.finish(with: self.transcript)
        }
    }

    private func finish(with text: String) {
        guard let continuation = listenContinuation else { return }
        listenContinuation = nil
        stopListening()
        continuation.resume(returning: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func stopListening() {
        generation += 1
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        silenceTask?.cancel()
        silenceTask = nil
        if let engine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
            self.engine = nil
        }
        requests.forEach { $0.endAudio() }
        requests = []
        recognitions.forEach { $0.cancel() }
        recognitions = []
        level = 0
        if let continuation = listenContinuation {
            listenContinuation = nil
            continuation.resume(returning: transcript)
        }
    }

    /// A note in the caption instead of a transcript.
    func show(_ message: String) {
        phase = .failed(message)
    }

    func setThinking() {
        phase = .thinking
    }

    /// Built outside the main actor: the audio thread calls it.
    private nonisolated static func tapBlock(requests: [SFSpeechAudioBufferRecognitionRequest], recording: AVAudioFile?, level: @escaping @Sendable (Float) -> Void) -> AVAudioNodeTapBlock {
        // The requests take buffers from any thread; the file only from this one.
        nonisolated(unsafe) let requests = requests
        nonisolated(unsafe) let recording = recording
        return { @Sendable buffer, _ in
            for request in requests { request.append(buffer) }
            if let recording, buffer.format == recording.processingFormat { try? recording.write(from: buffer) }
            guard let samples = buffer.floatChannelData?[0] else { return }
            let count = Int(buffer.frameLength)
            guard count > 0 else { return }
            var sum: Float = 0
            for index in 0..<count { sum += samples[index] * samples[index] }
            let rms = (sum / Float(count)).squareRoot()
            // About -50 dB (silence) to -10 dB (close speech) → 0…1.
            let decibels = 20 * log10(max(rms, 0.000_01))
            level(min(1, max(0, (decibels + 50) / 40)))
        }
    }

    private nonisolated static func resultHandler(_ handle: @escaping @Sendable (String?, Float, Bool, String?) -> Void) -> @Sendable (SFSpeechRecognitionResult?, Error?) -> Void {
        { result, error in
            let described = error.map { error -> String in
                let error = error as NSError
                return "\(error.localizedDescription) (\(error.domain) \(error.code))"
            }
            let segments = result?.bestTranscription.segments ?? []
            let confidence = segments.isEmpty ? 0 : segments.map(\.confidence).reduce(0, +) / Float(segments.count)
            handle(result?.bestTranscription.formattedString, confidence, result?.isFinal ?? false, described)
        }
    }

    private static func vocabulary() -> [String] {
        let library = AppModel.shared.libraryService
        let artists = Dictionary(grouping: library.songs, by: LibraryIndex.artistName(for:))
            .sorted { $0.value.count > $1.value.count }
            .prefix(80)
            .map(\.key)
        return Array((artists + library.playlists.prefix(20).map(\.name)).prefix(100))
    }
}
