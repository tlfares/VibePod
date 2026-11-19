import Foundation
import SwiftUI
import Translation
import NaturalLanguage
import CryptoKit

/// Translates the current song's lyrics, line by line, with Apple's
/// on-device Translation (Settings › Exclusive Features). Off by default;
/// on, songs are translated from the Now Playing menu, or all of them with
/// Translate Automatically.
///
/// Driven by the player, not the lyrics on screen. Translations are keyed
/// by the original line's text: a chorus is translated once, and new line
/// IDs from a reload still find theirs.
@MainActor
final class LyricsTranslator: ObservableObject {
    static let shared = LyricsTranslator()
    static let enabledKey = "lyricsTranslationEnabled"
    static let automaticKey = "lyricsTranslationAutomatic"
    static let targetKey = "lyricsTranslationTarget"

    /// Original line → its translation, for the lyrics on screen.
    @Published private(set) var translations: [String: String] = [:]
    /// Drives the lyrics' `.translationTask`, only when the languages still
    /// need downloading (it offers the download).
    @Published var configuration: TranslationSession.Configuration?
    /// A translation is under way: the lyrics show a small loading pill.
    @Published private(set) var isTranslating = false
    /// The current song is asked for translated, from the menu or automatically.
    @Published private(set) var isRequested = false

    /// The song after the current one, for translating it ahead.
    var upcoming: () -> Song? = { nil }

    private var songID: Song.ID?
    private var lyrics: LRCLyrics?
    /// The menu's choice for the current song, over the automatic setting.
    private var choice: Bool?
    private var lines: [String] = []
    private var cacheKey: String?
    private var running: String?
    private var work: Task<Void, Never>?
    /// Kept from song to song: no setup for each.
    private var session: (pair: String, session: TranslationSession)?
    private var settings = LyricsTranslator.settingsSignature

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
    static var isAutomatic: Bool { UserDefaults.standard.bool(forKey: automaticKey) }

    /// The language picked in Settings, the phone's own by default.
    static var target: Locale.Language {
        if let stored = UserDefaults.standard.string(forKey: targetKey), !stored.isEmpty {
            return Locale.Language(identifier: stored)
        }
        return Locale.current.language
    }

    private static var settingsSignature: String {
        "\(isEnabled) \(isAutomatic) \(target.maximalIdentifier)"
    }

    private init() {
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                let translator = LyricsTranslator.shared
                let signature = Self.settingsSignature
                guard signature != translator.settings else { return }
                translator.settings = signature
                translator.refresh()
            }
        }
    }

    /// From the player, whenever the current song or its lyrics change.
    func lyricsDidLoad(_ lyrics: LRCLyrics?, for songID: Song.ID?) {
        if songID != self.songID { choice = nil }
        self.songID = songID
        self.lyrics = lyrics
        refresh()
    }

    /// The Now Playing menu: translated or original, for this song.
    func setTranslated(_ translated: Bool) {
        choice = translated
        refresh()
    }

    private func refresh() {
        let requested = Self.isEnabled && (choice ?? Self.isAutomatic)
        if requested != isRequested { isRequested = requested }
        let texts = requested ? Self.uniqueLines(of: lyrics) : []
        let target = Self.target
        let key = texts.isEmpty ? nil : Self.key(for: texts, target: target)
        guard key != cacheKey else { return }
        cacheKey = key
        lines = texts
        let previous = work
        previous?.cancel()
        work = nil
        translations = [:]
        isTranslating = false
        guard let key else { return }

        if let cached = Self.loadCache(key) {
            withAnimation(.smooth) { translations = cached }
            work = Task { await previous?.value; await prefetchUpcoming() }
            return
        }
        guard let source = Self.sourceLanguage(of: texts, target: target) else { return }
        work = Task {
            // One translation at a time on the session.
            await previous?.value
            let status = await Self.status(from: source, to: target)
            // Unsupported pairs say nothing: the lyrics just stay as they are.
            guard !Task.isCancelled, cacheKey == key else { return }
            switch status {
            case .installed:
                isTranslating = true
                nonisolated(unsafe) let session = session(from: source, to: target)
                let pairs = await Self.stream(texts, with: session) { [weak self] pairs in
                    self?.show(pairs, of: texts, key: key) ?? false
                }
                finish(key: key, texts: texts, pairs: pairs)
                guard !Task.isCancelled else { return }
                await prefetchUpcoming()
            case .supported:
                isTranslating = true
                requestDownload(from: source, to: target)
            default:
                return
            }
        }
    }

    /// The lyrics' `.translationTask` asks for the download, then translates.
    private func requestDownload(from source: Locale.Language, to target: Locale.Language) {
        // An equal configuration wouldn't run the task again: invalidate it.
        if var current = configuration, current.source == source, current.target == target {
            current.invalidate()
            configuration = current
        } else {
            configuration = TranslationSession.Configuration(source: source, target: target)
        }
    }

    /// Runs inside `.translationTask`, once the languages are there.
    nonisolated func translate(with session: TranslationSession) async {
        guard let (key, texts) = await begin() else { return }
        let pairs = await Self.stream(texts, with: session) { [weak self] pairs in
            self?.show(pairs, of: texts, key: key) ?? false
        }
        await finish(key: key, texts: texts, pairs: pairs)
    }

    private func session(from source: Locale.Language, to target: Locale.Language) -> TranslationSession {
        let pair = source.maximalIdentifier + ">" + target.maximalIdentifier
        if let session, session.pair == pair { return session.session }
        session?.session.cancel()
        let created = TranslationSession(installedSource: source, target: target)
        session = (pair, created)
        return created
    }

    /// Translates the next song in the background, when every song is
    /// translated and its languages are already there.
    private func prefetchUpcoming() async {
        guard Self.isEnabled, Self.isAutomatic, let song = upcoming(), song.id != songID,
              let lyrics = MusicPlayerService.lyrics(for: song) else { return }
        let texts = Self.uniqueLines(of: lyrics)
        let target = Self.target
        guard !texts.isEmpty else { return }
        let key = Self.key(for: texts, target: target)
        guard Self.loadCache(key) == nil, let source = Self.sourceLanguage(of: texts, target: target),
              await Self.status(from: source, to: target) == .installed, !Task.isCancelled else { return }
        nonisolated(unsafe) let session = session(from: source, to: target)
        guard let pairs = await Self.stream(texts, with: session, update: { _ in true }), !Task.isCancelled else { return }
        Self.saveCache(Self.translations(of: pairs, texts: texts), key: key)
    }

    /// Streams the lines' translations, handing them over a few at a time.
    /// Nil when it fails or `update` says the lyrics moved on.
    nonisolated private static func stream(
        _ texts: [String],
        with session: TranslationSession,
        update: @escaping @MainActor ([(Int, String)]) -> Bool
    ) async -> [(Int, String)]? {
        let requests = texts.enumerated().map { TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset)) }
        let probeCount = min(3, texts.count)
        var pairs: [(Int, String)] = []
        var shown = 0
        do {
            for try await response in session.translate(batch: requests) {
                guard let index = response.clientIdentifier.flatMap(Int.init), texts.indices.contains(index) else { continue }
                pairs.append((index, response.targetText))
                // The first lines come back as they are: the lyrics are
                // already in that language.
                if pairs.count == probeCount, pairs.allSatisfy({ folded($0.1) == folded(texts[$0.0]) }) {
                    return []
                }
                if pairs.count - shown >= (shown == 0 ? probeCount : 8) {
                    shown = pairs.count
                    let snapshot = pairs
                    guard await update(snapshot) else { return nil }
                }
            }
        } catch {
            return nil
        }
        return pairs
    }

    private func begin() -> (String, [String])? {
        guard let key = cacheKey, running != key else { return nil }
        running = key
        return (key, lines)
    }

    /// The lines translated so far, while the rest comes.
    private func show(_ pairs: [(Int, String)], of texts: [String], key: String) -> Bool {
        guard cacheKey == key else { return false }
        let result = Self.translations(of: pairs, texts: texts)
        if result != translations { withAnimation(.smooth) { translations = result } }
        return true
    }

    private func finish(key: String, texts: [String], pairs: [(Int, String)]?) {
        if running == key { running = nil }
        guard cacheKey == key else { return }
        isTranslating = false
        guard let pairs else { return }
        let result = Self.translations(of: pairs, texts: texts)
        if result != translations { withAnimation(.smooth) { translations = result } }
        Self.saveCache(result, key: key)
    }

    // MARK: Helpers

    nonisolated private static func translations(of pairs: [(Int, String)], texts: [String]) -> [String: String] {
        var result: [String: String] = [:]
        for (index, text) in pairs {
            guard let original = texts[safe: index] else { continue }
            let translated = text.trimmingCharacters(in: .whitespacesAndNewlines)
            // A line already in the target language comes back as itself.
            guard !translated.isEmpty, folded(translated) != folded(original) else { continue }
            result[original] = translated
        }
        return result
    }

    /// The lyrics' language, when they're worth translating to `target`.
    private static func sourceLanguage(of texts: [String], target: Locale.Language) -> Locale.Language? {
        guard let detected = dominantLanguage(of: texts),
              detected.languageCode != target.languageCode,
              !isLikely(target, in: texts) else { return nil }
        return detected
    }

    private static func uniqueLines(of lyrics: LRCLyrics?) -> [String] {
        guard let lyrics, lyrics.hasTimedLyrics else { return [] }
        var seen = Set<String>()
        return lyrics.lines.compactMap { line in
            guard !line.isInstrumentalGap, seen.insert(line.text).inserted else { return nil }
            return line.text
        }
    }

    private static func dominantLanguage(of texts: [String]) -> Locale.Language? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(texts.joined(separator: "\n"))
        guard let language = recognizer.dominantLanguage, language != .undetermined else { return nil }
        return Locale.Language(identifier: language.rawValue)
    }

    /// Mixed or slangy lyrics can fool the dominant guess: a fair chance
    /// of the target language is enough to leave them alone.
    private static func isLikely(_ target: Locale.Language, in texts: [String]) -> Bool {
        guard let code = target.languageCode?.identifier else { return false }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(texts.prefix(8).joined(separator: "\n"))
        let hypotheses = recognizer.languageHypotheses(withMaximum: 3)
        return hypotheses.contains { $0.key.rawValue.hasPrefix(code) && $0.value > 0.3 }
    }

    nonisolated private static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).filter { $0.isLetter || $0.isNumber }
    }

    private static func key(for texts: [String], target: Locale.Language) -> String {
        let digest = SHA256.hash(data: Data((texts.joined(separator: "\n") + "|" + target.maximalIdentifier).utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private static let cacheDirectory: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let directory = caches.appendingPathComponent("LyricsTranslations", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()

    private static func loadCache(_ key: String) -> [String: String]? {
        guard let data = try? Data(contentsOf: cacheDirectory.appendingPathComponent(key + ".json")) else { return nil }
        return try? JSONDecoder().decode([String: String].self, from: data)
    }

    private static func saveCache(_ translations: [String: String], key: String) {
        guard let data = try? JSONEncoder().encode(translations) else { return }
        try? data.write(to: cacheDirectory.appendingPathComponent(key + ".json"), options: .atomic)
    }

    nonisolated private static func status(from source: Locale.Language, to target: Locale.Language) async -> LanguageAvailability.Status {
        await LanguageAvailability().status(from: source, to: target)
    }

    /// The languages Translation offers, named in the phone's language.
    nonisolated static func supportedTargets() async -> [Locale.Language] {
        let languages = await LanguageAvailability().supportedLanguages
        var seen = Set<String>()
        return languages
            .filter { seen.insert($0.minimalIdentifier).inserted }
            .sorted { displayName(of: $0).localizedCompare(displayName(of: $1)) == .orderedAscending }
    }

    nonisolated static func displayName(of language: Locale.Language) -> String {
        Locale.current.localizedString(forIdentifier: language.minimalIdentifier)?.capitalized(with: .current) ?? language.minimalIdentifier
    }
}
