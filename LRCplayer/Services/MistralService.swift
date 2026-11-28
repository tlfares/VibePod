import SwiftUI
import Foundation
import Security

/// Who runs the AI features, with the user's own key: Groq (free plan) or
/// Mistral (for those with an API plan).
enum AIProvider: String, CaseIterable, Identifiable, Sendable {
    case groq
    case mistral

    static let defaultsKey = "aiProvider"
    var id: String { rawValue }

    static var current: AIProvider {
        get { UserDefaults.standard.string(forKey: defaultsKey).flatMap(AIProvider.init(rawValue:)) ?? .groq }
        set {
            guard newValue != current else { return }
            UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
            MistralModelMemory.reset()
            NotificationCenter.default.post(name: AIFeatures.didChangeNotification, object: nil)
        }
    }

    var name: String {
        switch self {
        case .groq: "Groq"
        case .mistral: "Mistral"
        }
    }

    var baseURL: URL {
        switch self {
        case .groq: URL(string: "https://api.groq.com/openai/v1/")!
        case .mistral: URL(string: "https://api.mistral.ai/v1/")!
        }
    }

    var keysPage: URL {
        switch self {
        case .groq: URL(string: "https://console.groq.com/keys")!
        case .mistral: URL(string: "https://console.mistral.ai/api-keys")!
        }
    }

    var consoleHost: String {
        switch self {
        case .groq: "console.groq.com"
        case .mistral: "console.mistral.ai"
        }
    }

    fileprivate var keychainAccount: String {
        switch self {
        case .groq: "groq-api-key"
        case .mistral: "mistral-api-key"
        }
    }

    /// Lyrics: the most accurate on singing, with a time for every word.
    var transcriptionModel: String {
        switch self {
        case .groq: "whisper-large-v3"
        case .mistral: "voxtral-mini-latest"
        }
    }

    /// The assistant's voice: quick.
    var voiceModel: String {
        switch self {
        case .groq: "whisper-large-v3-turbo"
        case .mistral: "voxtral-mini-latest"
        }
    }

    /// Small jobs (lyrics lines, summaries, matching), best first. Free
    /// keys can't call some models at all, so each is tried in turn.
    var lightModels: [String] {
        switch self {
        case .groq: ["openai/gpt-oss-20b", "openai/gpt-oss-120b"]
        case .mistral: ["mistral-small-latest", "ministral-14b-latest", "ministral-8b-latest"]
        }
    }

    /// Summaries and matching: the small ones, then a stronger one.
    var summaryModels: [String] {
        switch self {
        case .groq: lightModels
        case .mistral: lightModels + ["mistral-medium-latest"]
        }
    }

    /// The assistant and programs, best first.
    var strongModels: [String] {
        switch self {
        case .groq: ["openai/gpt-oss-120b", "openai/gpt-oss-20b"]
        case .mistral: ["mistral-medium-latest", "mistral-small-latest", "ministral-14b-latest", "ministral-8b-latest"]
        }
    }

    /// What the assistant may send at once: Groq's free plan takes about
    /// 8,000 tokens a minute per model, answer included.
    var assistantBudget: AssistantLibrary.Budget {
        switch self {
        case .groq: .compact
        case .mistral: .full
        }
    }

    var assistantMaxTokens: Int {
        switch self {
        case .groq: 1800
        case .mistral: 4000
        }
    }

    /// Past exchanges the assistant is reminded of.
    var assistantHistory: Int {
        switch self {
        case .groq: 3
        case .mistral: 20
        }
    }

    /// Time between two requests: Groq's free plan allows 30 a minute.
    var spacing: TimeInterval {
        switch self {
        case .groq: 2.05
        case .mistral: 1.15
        }
    }

    /// What a chat request adds for this model: reasoning models think
    /// briefly, and keep their thoughts to themselves.
    static func extras(for model: String) -> [String: Any] {
        guard model.hasPrefix("openai/gpt-oss") else { return [:] }
        return ["reasoning_effort": "low", "include_reasoning": false]
    }
}

/// The AI features switch and the user's API keys. A key never leaves
/// this device except to authenticate with its provider (and, with Device
/// Sync, to the user's other devices through their encrypted iCloud).
enum AIFeatures {
    static let enabledKey = "aiFeaturesEnabled"
    static let didChangeNotification = Notification.Name("AIFeaturesDidChange")

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: enabledKey)
            NotificationCenter.default.post(name: didChangeNotification, object: nil)
        }
    }

    /// On, with a key to use.
    static var isAvailable: Bool { isEnabled && apiKey != nil }

    /// The current provider's key.
    static var apiKey: String? {
        get { key(for: .current) }
        set { setKey(newValue, for: .current) }
    }

    static func key(for provider: AIProvider) -> String? {
        Keychain.read(account: provider.keychainAccount)
    }

    /// Optional, for hearing the songs (see `Speechmatics`).
    static var speechmaticsKey: String? {
        get { Keychain.read(account: "speechmatics-api-key") }
        set {
            guard newValue != speechmaticsKey else { return }
            if let newValue, !newValue.isEmpty {
                Keychain.write(newValue, account: "speechmatics-api-key")
            } else {
                Keychain.delete(account: "speechmatics-api-key")
            }
            NotificationCenter.default.post(name: didChangeNotification, object: nil)
        }
    }

    static func setKey(_ key: String?, for provider: AIProvider) {
        guard key != self.key(for: provider) else { return }
        if let key, !key.isEmpty {
            Keychain.write(key, account: provider.keychainAccount)
        } else {
            Keychain.delete(account: provider.keychainAccount)
        }
        if provider == .current { MistralModelMemory.reset() }
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    private enum Keychain {
        private static let service = "com.fares.lrc.player.ai"

        private static func query(account: String) -> [String: Any] {
            [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account
            ]
        }

        static func read(account: String) -> String? {
            var request = query(account: account)
            request[kSecReturnData as String] = true
            request[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
                  let data = result as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        }

        static func write(_ value: String, account: String) {
            delete(account: account)
            var item = query(account: account)
            item[kSecValueData as String] = Data(value.utf8)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(item as CFDictionary, nil)
        }

        static func delete(account: String) {
            SecItemDelete(query(account: account) as CFDictionary)
        }
    }
}

enum MistralError: LocalizedError {
    case invalidKey
    case rateLimited
    /// The key's plan can't use this model at all (no quota, or forbidden).
    case modelUnavailable
    case fileTooLarge
    /// The account has no API plan (Mistral's console, Billing).
    case noSubscription
    /// More than the plan takes in one go (Groq's tokens a minute).
    case requestTooLarge
    /// Groq refused an answer that broke the JSON schema; it's still here
    /// to read what it can of it.
    case unvalidatedAnswer(String)
    case server(String)
    case network(String)

    private var provider: AIProvider { .current }

    var errorDescription: String? {
        switch self {
        case .invalidKey: String(localized: "\(provider.name) didn't accept the API key. Check it in Settings › Tools › AI Features.")
        case .rateLimited: String(localized: "\(provider.name) is limiting requests on this key for now. Try again in a minute.")
        case .modelUnavailable: String(localized: "This \(provider.name) key can't use the model it needs.")
        case .fileTooLarge: String(localized: "This song's file is too large to send to \(provider.name).")
        case .noSubscription: String(localized: "Your \(provider.name) account has no active API plan. Choose one in its console (\(provider.consoleHost)), or use another provider in Settings › Tools › AI Features.")
        case .requestTooLarge: String(localized: "This request is too large for \(provider.name)'s free limits. Try a shorter question, or start a new conversation.")
        case .server(let message): String(localized: "\(provider.name) couldn't process the request: \(message)")
        case .unvalidatedAnswer: String(localized: "\(provider.name)'s answer couldn't be read. Try again.")
        case .network(let message): message
        }
    }
}

/// A sung word and when it starts and ends, in seconds.
struct TimedWord: Sendable, Equatable {
    var text: String
    var start: TimeInterval
    var end: TimeInterval
}

/// The few endpoints VibePod uses, the same at Groq and Mistral
/// (https://console.groq.com/docs, https://docs.mistral.ai).
enum MistralClient {
    private static var base: URL { AIProvider.current.baseURL }
    static var chatURL: URL { base.appendingPathComponent("chat/completions") }
    static var transcriptionURL: URL { base.appendingPathComponent("audio/transcriptions") }

    static var layoutModels: [String] { AIProvider.current.lightModels }

    /// Checks the key with the cheapest authenticated call.
    static func validate(key: String, provider: AIProvider = .current) async throws {
        var request = URLRequest(url: provider.baseURL.appendingPathComponent("models"))
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        _ = try await send(request)
    }

    static func transcribe(audio: URL, key: String) async throws -> [TimedWord] {
        let boundary = "LRCplayer-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        let provider = AIProvider.current
        field("model", provider.transcriptionModel)
        switch provider {
        case .groq:
            field("response_format", "verbose_json")
            field("timestamp_granularities[]", "word")
        case .mistral:
            field("timestamp_granularities", "word")
        }
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(audio.lastPathComponent)\"\r\nContent-Type: application/octet-stream\r\n\r\n")
        body.append(try Data(contentsOf: audio, options: .mappedIfSafe))
        body.append("\r\n--\(boundary)--\r\n")

        var request = URLRequest(url: transcriptionURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (data, _) = try await send(request, retryingOnce: true)
        struct Response: Decodable {
            struct Segment: Decodable { let text: String; let start: Double; let end: Double }
            struct Word: Decodable { let word: String; let start: Double; let end: Double }
            let segments: [Segment]?
            /// Whisper (Groq): the words apart; Voxtral: one word a segment.
            let words: [Word]?
        }
        let response = try JSONDecoder().decode(Response.self, from: data)
        let segments = response.words.map { $0.map { Response.Segment(text: $0.word, start: $0.start, end: $0.end) } }
            ?? response.segments ?? []
        let words: [TimedWord] = segments.compactMap { segment in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : TimedWord(text: text, start: segment.start, end: max(segment.end, segment.start))
        }
        return response.words == nil ? words : unstretched(words)
    }

    /// Whisper hands a held note, or the silence before a phrase, to the
    /// word that follows it: "Hey" gets 0.05 s and "Don't" the next 3 s.
    /// Such a word is moved to the end of its span, where it's really sung.
    nonisolated static func unstretched(_ words: [TimedWord]) -> [TimedWord] {
        var words = words
        for index in words.indices.dropFirst() {
            let word = words[index]
            let letters = word.text.filter(\.isLetter).count
            let spoken = min(0.6, 0.15 + 0.07 * Double(letters))
            let previous = words[index - 1]
            let next = index + 1 < words.count ? words[index + 1] : nil
            // A repeated word ("Okay Okay") is likely held for real.
            guard next?.text.lowercased() != word.text.lowercased() else { continue }
            // The word before barely lasts: it's the one being held.
            // (Or it's short and this one is drawn out by seconds.)
            let held = previous.end - previous.start
            let length = word.end - word.start
            if (held < 0.15 && length > spoken + 0.3) || (held < 0.3 && length > spoken + 1.5) {
                let start = word.end - spoken
                words[index].start = start
                words[index - 1].end = start
                continue
            }
            // A phrase's first word (Whisper capitalizes them) set down at
            // the start of the pause before it, drawn out or not: it's sung
            // just before the word that follows. Singers hold a phrase's
            // end, not its start.
            // The next word carries the same sentence on (not "Okay. No…").
            guard let next, word.text.first?.isUppercase == true, word.text != "I",
                  next.text.first?.isLowercase == true,
                  next.start - word.start > spoken + 0.8 else { continue }
            let start = max(word.start, next.start - spoken)
            words[index].start = start
            words[index].end = max(min(word.end, next.start), start + 0.1)
        }
        return words
    }

    /// Indices of the words that open each lyric line, as a lyrics site
    /// would lay them out. Only the grouping comes from the model, so no
    /// word or time can be made up.
    static func lineStarts(of words: [TimedWord], title: String, artist: String, key: String) async throws -> [Int] {
        // The silence before each word is what tells a line break; small
        // models read it far better than two times to subtract.
        let listing = words.enumerated()
            .map { index, word in
                let gap = index == 0 ? 0 : max(0, word.start - words[index - 1].end)
                return "\(index)|\(String(format: "%.1f", gap))|\(word.text)"
            }
            .joined(separator: "\n")
        let system = """
        You lay out song lyrics into lines, like a lyrics website. You get the song's words as transcribed by speech recognition, \
        one per line as index|silence before the word in seconds|word.
        Each lyric line is one short sung phrase (a verse line): usually 4 to 8 words, never more than 10. \
        Start a new line after a silence of 0.5 s or more, after a sentence or clause ends (. ! ? , ;), \
        and where a rhyme closes a phrase. A line must read as a coherent phrase on its own: never end it on an article, \
        a preposition or a conjunction (the, a, to, of, and, but… or their equivalents in the song's language), and don't leave a single word alone on a line. \
        Repeated phrases (a chorus) get the same breaks each time. Never reorder, merge or drop words.
        Reply with JSON only: {"line_starts": [the index of the first word of each line, ascending, starting with 0]}.
        """
        let payload: [String: Any] = [
            "temperature": 0,
            "response_format": ["type": "json_object"],
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": "Song: \(title) by \(artist)\n\n\(listing)"]
            ]
        ]

        var lastError: Error = MistralError.rateLimited
        for model in layoutModels {
            var body = payload.merging(AIProvider.extras(for: model)) { $1 }
            body["model"] = model
            await MistralPacer.shared.waitTurn()
            var request = URLRequest(url: chatURL)
            request.httpMethod = "POST"
            request.timeoutInterval = 120
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            do {
                let (data, _) = try await send(request, retryingOnce: true)
                struct Response: Decodable {
                    struct Choice: Decodable { struct Message: Decodable { let content: String }; let message: Message }
                    let choices: [Choice]
                }
                struct Layout: Decodable { let line_starts: [Int] }
                guard let content = try JSONDecoder().decode(Response.self, from: data).choices.first?.message.content,
                      let layout = try? JSONDecoder().decode(Layout.self, from: Data(content.utf8)) else {
                    throw MistralError.server("unreadable layout")
                }
                return layout.line_starts
            } catch MistralError.invalidKey {
                throw MistralError.invalidKey
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    // MARK: Transport

    /// Sends a request and maps Mistral's errors. A rate limit that will
    /// lift (a nonzero limit) is waited out once.
    static func send(_ request: URLRequest, retryingOnce: Bool = false) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw MistralError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw MistralError.network(String(localized: "No response from \(AIProvider.current.name).")) }
        switch http.statusCode {
        case 200..<300:
            return (data, http)
        case 401:
            throw MistralError.invalidKey
        case 403:
            noteRefusal(http, data)
            throw MistralError.modelUnavailable
        case 413:
            // Groq: a request over the tokens a minute; otherwise an upload.
            if String(decoding: data.prefix(1000), as: UTF8.self).localizedCaseInsensitiveContains("token") {
                throw MistralError.requestTooLarge
            }
            throw MistralError.fileTooLarge
        case 429:
            let limit = http.value(forHTTPHeaderField: "x-ratelimit-limit-req-minute")
            if limit == "0" {
                noteRefusal(http, data)
                throw MistralError.modelUnavailable
            }
            if retryingOnce {
                let wait = http.value(forHTTPHeaderField: "retry-after").flatMap(Double.init).map { min(max($0, 1), 8) } ?? 3
                try await Task.sleep(for: .seconds(wait))
                return try await send(request)
            }
            throw MistralError.rateLimited
        default:
            // Mistral: {"message"}; Groq (OpenAI's shape): {"error": {"message"}}.
            struct Failure: Decodable {
                struct Inner: Decodable {
                    let message: String?
                    let code: String?
                    let failed_generation: String?
                }
                let message: String?
                let error: Inner?
            }
            let failure = try? JSONDecoder().decode(Failure.self, from: data)
            let message = failure?.message ?? failure?.error?.message
            if failure?.error?.code == "json_validate_failed", let answer = failure?.error?.failed_generation, !answer.isEmpty {
                throw MistralError.unvalidatedAnswer(answer)
            }
            if http.statusCode == 402 || message?.localizedCaseInsensitiveContains("subscription") == true {
                throw MistralError.noSubscription
            }
            throw MistralError.server(message ?? String(localized: "error \(http.statusCode)"))
        }
    }
}

extension MistralClient {
    /// Why a model was set aside, kept to look at later (pulled from the
    /// device): the status, the rate-limit headers and Mistral's message.
    fileprivate static func noteRefusal(_ http: HTTPURLResponse, _ data: Data) {
        let headers = http.allHeaderFields
            .compactMap { key, value -> String? in
                let name = "\(key)".lowercased()
                return name.contains("ratelimit") || name.contains("retry") ? "\(name): \(value)" : nil
            }
            .sorted()
            .joined(separator: "\n")
        let note = "\(Date()) \(http.url?.path ?? "")\nstatus \(http.statusCode)\n\(headers)\n\n\(String(decoding: data.prefix(2000), as: UTF8.self))\n"
        let folder = URL.applicationSupportDirectory.appending(path: "Assistant")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? note.write(to: folder.appending(path: "last-refusal.txt"), atomically: true, encoding: .utf8)
    }
}

private extension Data {
    mutating func append(_ string: String) {
        append(Data(string.utf8))
    }
}

// MARK: - Lyrics summaries

/// One sentence per song saying what its lyrics are about, written by
/// Mistral from the lyrics. The assistant reads them to find a song by its
/// subject ("the one about a road trip") and to build themed mixes. Shown
/// and editable only in the song's Info.
@MainActor
final class LyricsSummaries: ObservableObject {
    static let shared = LyricsSummaries()

    struct Entry: Codable, Equatable {
        var text: String
        /// Written or fixed by hand: never replaced.
        var isEdited = false
    }

    @Published private(set) var entries: [UUID: Entry]
    @Published private(set) var isRunning = false
    @Published private(set) var done = 0
    @Published private(set) var total = 0
    @Published private(set) var lastError: String?
    /// Mistral asked to slow down: the run waits, then goes on by itself.
    @Published private(set) var isWaiting = false
    private var task: Task<Void, Never>?

    static let batchSize = 10
    private static let lyricsLimit = 1200
    /// Cut short by leaving the app: picked up again on return.
    private var interrupted: [Song]?
    private var extraQueue: [Song] = []
    private var extraTask: Task<Void, Never>?

    private static var fileURL: URL {
        URL.applicationSupportDirectory.appending(path: "Assistant/lyrics-summaries.json")
    }

    private init() {
        entries = (try? Data(contentsOf: Self.fileURL)).flatMap { try? JSONDecoder().decode([UUID: Entry].self, from: $0) } ?? [:]
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                let summaries = LyricsSummaries.shared
                if let songs = summaries.interrupted {
                    summaries.interrupted = nil
                    summaries.run(songs: songs)
                }
            }
        }
    }

    /// One song whose lyrics just came from Mistral (transcribed or
    /// synced): summed up right away, quietly, while the key is warm.
    func summarizeSoon(_ song: Song) {
        guard AIFeatures.isAvailable, entries[song.id]?.isEdited != true else { return }
        extraQueue.removeAll { $0.id == song.id }
        extraQueue.append(song)
        guard extraTask == nil else { return }
        extraTask = Task {
            while !extraQueue.isEmpty {
                let batch = Array(extraQueue.prefix(Self.batchSize))
                extraQueue.removeFirst(batch.count)
                guard let key = AIFeatures.apiKey else { break }
                for wait in [0, 20, 60] {
                    if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                    do {
                        let results = try await Self.summarize(batch, key: key)
                        for (id, text) in results where entries[id]?.isEdited != true {
                            entries[id] = Entry(text: text)
                        }
                        save()
                        break
                    } catch MistralError.rateLimited {
                        continue
                    } catch {
                        break
                    }
                }
            }
            extraTask = nil
        }
    }

    /// Mistral's Markdown (**bold**, *italic*) shown as styled text.
    static func styled(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }

    /// Without Markdown marks, for the assistant to read.
    static func plain(_ text: String) -> String {
        String(styled(text).characters)
    }

    func summary(for id: UUID) -> String? {
        entries[id]?.text.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyString
    }

    func setSummary(_ text: String, for id: UUID) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            entries[id] = nil
        } else {
            entries[id] = Entry(text: trimmed, isEdited: true)
        }
        save()
    }

    /// iCloud Sync: another device's summary for this song, or none.
    func replaceEntry(_ entry: Entry?, for id: UUID) {
        guard entries[id] != entry else { return }
        entries[id] = entry
        save()
    }

    /// Songs with lyrics and no summary yet.
    func pending(in songs: [Song]) -> [Song] {
        songs.filter { entries[$0.id] == nil && !LyricsAutoMatcher.lacksLyrics($0) }
    }

    func summarizedCount(in songs: [Song]) -> Int {
        songs.reduce(0) { $0 + (entries[$1.id] != nil ? 1 : 0) }
    }

    func cancel() {
        task?.cancel()
    }

    func run(songs: [Song]) {
        guard !isRunning, let key = AIFeatures.apiKey else { return }
        let queue = pending(in: songs)
        guard !queue.isEmpty else { return }
        isRunning = true
        lastError = nil
        done = 0
        total = queue.count
        // A few more seconds to finish the request in flight when the app
        // is left; what's left resumes on return.
        var background = UIBackgroundTaskIdentifier.invalid
        background = UIApplication.shared.beginBackgroundTask(withName: "Lyrics summaries") { [weak self] in
            self?.interrupted = songs
            self?.task?.cancel()
            UIApplication.shared.endBackgroundTask(background)
            background = .invalid
        }
        task = Task {
            defer {
                if background != .invalid { UIApplication.shared.endBackgroundTask(background) }
            }
            for start in stride(from: 0, to: queue.count, by: Self.batchSize) {
                if Task.isCancelled { break }
                let batch = Array(queue[start..<min(start + Self.batchSize, queue.count)])
                var failed = false
                // A rate limit is waited out (longer each time) rather than
                // ending the run; free keys hit it every few requests.
                for wait in [0, 20, 40, 60, 60, 60] {
                    if wait > 0 {
                        withAnimation(.smooth) { isWaiting = true }
                        try? await Task.sleep(for: .seconds(wait))
                        withAnimation(.smooth) { isWaiting = false }
                    }
                    if Task.isCancelled { failed = true; break }
                    do {
                        let results = try await Self.summarize(batch, key: key)
                        for (id, text) in results where entries[id]?.isEdited != true {
                            entries[id] = Entry(text: text)
                        }
                        save()
                        failed = false
                        break
                    } catch is CancellationError {
                        failed = true
                        break
                    } catch MistralError.rateLimited {
                        failed = true
                        lastError = MistralError.rateLimited.errorDescription
                        continue
                    } catch MistralError.network where UIApplication.shared.applicationState != .active {
                        // Left the app: not an error, it goes on on return.
                        failed = true
                        interrupted = songs
                        break
                    } catch {
                        failed = true
                        lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                        break
                    }
                }
                if failed { break }
                lastError = nil
                withAnimation(.smooth) { done = min(start + batch.count, queue.count) }
            }
            withAnimation(.smooth) { isRunning = false; isWaiting = false }
            task = nil
        }
    }

    private func save() {
        try? FileManager.default.createDirectory(at: Self.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(entries).write(to: Self.fileURL, options: .atomic)
    }

    private static func summarize(_ songs: [Song], key: String) async throws -> [UUID: String] {
        var blocks: [String] = []
        var ids: [String: UUID] = [:]
        for (index, song) in songs.enumerated() {
            guard let lyrics = MusicPlayerService.lyrics(for: song) else { continue }
            var text = lyrics.hasTimedLyrics ? lyrics.lines.map(\.text).joined(separator: "\n") : lyrics.plainText
            text = text.replacingOccurrences(of: #"\n{2,}"#, with: "\n", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if text.count > lyricsLimit { text = String(text.prefix(lyricsLimit)) + "\n[…]" }
            let id = String(index + 1)
            ids[id] = song.id
            blocks.append("SONG \(id): “\(song.title)” — \(song.artist)\n\(text)")
        }
        guard !blocks.isEmpty else { return [:] }
        let language = AssistantService.prefersFrench ? "French" : "English"
        let system = """
        For each song, write ONE short sentence (max 25 words) in \(language) saying what its lyrics are about: the subject, the story, the feeling, the themes. No "This song…" opener, no title or artist, no quotes, plain text with no Markdown (no ** or _). Answer with JSON only: {"summaries":[{"id":"1","summary":"…"}]}.
        """
        var body: [String: Any] = [
            "temperature": 0.3,
            "max_tokens": 1500,
            "response_format": ["type": "json_object"],
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": blocks.joined(separator: "\n\n")]
            ]
        ]
        // Free keys can't call some models at all, so each is tried in
        // turn and a refused one is set aside for a while.
        var data: Data?
        var lastError: Error = MistralError.modelUnavailable
        for model in MistralModelMemory.usable(AIProvider.current.summaryModels) {
            body["model"] = model
            for (name, value) in AIProvider.extras(for: model) { body[name] = value }
            var request = URLRequest(url: MistralClient.chatURL)
            request.httpMethod = "POST"
            request.timeoutInterval = 60
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            await MistralPacer.shared.waitTurn()
            try Task.checkCancellation()
            do {
                data = try await MistralClient.send(request, retryingOnce: true).0
                break
            } catch MistralError.modelUnavailable {
                MistralModelMemory.skip(model)
                lastError = MistralError.modelUnavailable
            }
        }
        guard let data else { throw lastError }
        struct Response: Decodable {
            struct Choice: Decodable { struct Message: Decodable { let content: String? }; let message: Message }
            let choices: [Choice]
        }
        struct Summaries: Decodable {
            struct Item: Decodable { let id: String; let summary: String }
            let summaries: [Item]
        }
        guard var content = try JSONDecoder().decode(Response.self, from: data).choices.first?.message.content else { return [:] }
        if let start = content.firstIndex(of: "{"), let end = content.lastIndex(of: "}") {
            content = String(content[start...end])
        }
        let items = (try? JSONDecoder().decode(Summaries.self, from: Data(content.utf8)).summaries) ?? []
        var result: [UUID: String] = [:]
        for item in items {
            let text = item.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            if let id = ids[item.id.trimmingCharacters(in: .whitespaces)], !text.isEmpty { result[id] = text }
        }
        return result
    }
}

private extension String {
    var nonEmptyString: String? { isEmpty ? nil : self }
}
