import CryptoKit
import Foundation

/// When one word of a lyric line is sung, in lyrics time (the LRC's own
/// clock, `[offset:]` included).
struct WordTiming: Codable, Sendable, Equatable {
    var start: TimeInterval
    var end: TimeInterval
}

/// A lyric line split into words exactly as written: the ranges point into
/// the line's own text, which is never changed.
enum LyricWords {
    static func ranges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var start: String.Index?
        for index in text.indices {
            if text[index].isWhitespace {
                if let wordStart = start { ranges.append(wordStart..<index) }
                start = nil
            } else if start == nil {
                start = index
            }
        }
        if let start { ranges.append(start..<text.endIndex) }
        return ranges
    }
}

/// Word-by-word timings for a song's synced lyrics, kept apart from the LRC
/// file (which stays exactly as it is). They're tied to the lyrics they were
/// made for: once the lyrics change, they're ignored.
enum WordSyncStore {
    static let didChangeNotification = Notification.Name("WordSyncDidChange")

    private struct File: Codable {
        var fingerprint: String
        /// One entry per lyric line, one timing per word.
        var lines: [[WordTiming]]
        /// The lyrics source the timings came with; nil when Mistral made them.
        var source: String?
    }

    private static var folder: URL {
        LibraryService.dataDirectory.appendingPathComponent("WordSync", isDirectory: true)
    }

    private static func url(for songID: UUID) -> URL {
        folder.appendingPathComponent("\(songID.uuidString).json")
    }

    static func fingerprint(of lines: [LyricsLine]) -> String {
        let joined = lines.map { "\(String(format: "%.2f", $0.time))|\($0.text)" }.joined(separator: "\n")
        return SHA256.hash(data: Data(joined.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The timings per line ID, if these lyrics have them.
    static func load(for songID: UUID, lyrics: LRCLyrics) -> [LyricsLine.ID: [WordTiming]] {
        guard let data = try? Data(contentsOf: url(for: songID)),
              let file = try? JSONDecoder().decode(File.self, from: data),
              file.fingerprint == fingerprint(of: lyrics.lines),
              file.lines.count == lyrics.lines.count else { return [:] }
        var timings: [LyricsLine.ID: [WordTiming]] = [:]
        for (line, words) in zip(lyrics.lines, file.lines) where !words.isEmpty {
            guard words.count == LyricWords.ranges(in: line.text).count else { return [:] }
            timings[line.id] = words
        }
        return timings
    }

    /// Where the timings came from, nil when Mistral made them.
    static func source(for songID: UUID) -> String? {
        guard let data = try? Data(contentsOf: url(for: songID)) else { return nil }
        return (try? JSONDecoder().decode(File.self, from: data))?.source
    }

    static func save(_ lines: [[WordTiming]], for songID: UUID, lyrics: LRCLyrics, source: String? = nil) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = File(fingerprint: fingerprint(of: lyrics.lines), lines: lines, source: source)
        try JSONEncoder().encode(file).write(to: url(for: songID), options: .atomic)
        NotificationCenter.default.post(name: didChangeNotification, object: songID)
    }

    /// The stored file as is, to carry to another device.
    static func rawData(for songID: UUID) -> Data? {
        try? Data(contentsOf: url(for: songID))
    }

    static func setRawData(_ data: Data, for songID: UUID) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard (try? data.write(to: url(for: songID), options: .atomic)) != nil else { return }
        NotificationCenter.default.post(name: didChangeNotification, object: songID)
    }

    static func delete(for songID: UUID) {
        try? FileManager.default.removeItem(at: url(for: songID))
        setHidden(false, for: songID)
    }

    // MARK: Hidden

    private static let hiddenKey = "hiddenWordSyncSongs"

    /// Songs shown with their line by line sync only, word timings kept for
    /// when they're shown again.
    static func isHidden(for songID: UUID) -> Bool {
        UserDefaults.standard.stringArray(forKey: hiddenKey)?.contains(songID.uuidString) == true
    }

    static func setHidden(_ hidden: Bool, for songID: UUID) {
        var songs = Set(UserDefaults.standard.stringArray(forKey: hiddenKey) ?? [])
        if hidden { songs.insert(songID.uuidString) } else { songs.remove(songID.uuidString) }
        UserDefaults.standard.set(songs.sorted(), forKey: hiddenKey)
        NotificationCenter.default.post(name: didChangeNotification, object: songID)
    }
}

/// Times every word of lyrics a song already has, like Apple Music's word
/// by word lyrics: Voxtral transcribes the vocals with a time per word, then
/// the transcription is matched to the lyrics' own words. Only times come
/// out of it: the text and its line breaks are left untouched, and so is
/// the LRC file.
@MainActor
final class WordSyncGenerator: ObservableObject {
    static let shared = WordSyncGenerator()

    enum Stage: Equatable {
        case preparing
        case transcribing(part: Int, of: Int)
        case matching

        var title: String {
            switch self {
            case .preparing: String(localized: "Preparing the audio…")
            case let .transcribing(part, count) where count > 1 && part > 0: String(localized: "Listening to the vocals… \(part)/\(count)")
            case .transcribing: String(localized: "Listening to the vocals…")
            case .matching: String(localized: "Syncing every word…")
            }
        }
    }

    enum SyncError: LocalizedError {
        case unavailable
        case noTimedLyrics
        case poorMatch

        var errorDescription: String? {
            switch self {
            case .unavailable: String(localized: "Turn on AI Features and add a Mistral API key in Settings › Tools.")
            case .noTimedLyrics: String(localized: "Word by word sync needs lyrics already synced line by line.")
            case .poorMatch: String(localized: "The vocals heard in this song don't match its lyrics closely enough to sync them word by word.")
            }
        }
    }

    /// Songs being worked on, by song ID.
    @Published private(set) var stages: [UUID: Stage] = [:]
    /// The last failure per song, until it's shown.
    @Published private(set) var failures: [UUID: String] = [:]

    func clearFailure(for songID: UUID) {
        failures[songID] = nil
    }

    func sync(_ song: Song, lyrics: LRCLyrics) {
        guard stages[song.id] == nil else { return }
        failures[song.id] = nil
        guard AIFeatures.isAvailable, let key = AIFeatures.apiKey else {
            failures[song.id] = SyncError.unavailable.localizedDescription
            return
        }
        guard lyrics.hasTimedLyrics else {
            failures[song.id] = SyncError.noTimedLyrics.localizedDescription
            return
        }
        stages[song.id] = .preparing
        Task {
            do {
                let chunks = try await LyricsGenerator.audioChunks(at: song.playableFileURL, duration: song.duration)
                defer { chunks.filter(\.isTemporary).forEach { try? FileManager.default.removeItem(at: $0.url) } }

                stages[song.id] = .transcribing(part: 0, of: chunks.count)
                let transcribed = try await LyricsGenerator.transcribe(chunks, key: key) { done in
                    self.stages[song.id] = .transcribing(part: done, of: chunks.count)
                }

                stages[song.id] = .matching
                let heard = LyricsGenerator.sungWords(in: transcribed).map {
                    // Playback time to the lyrics' clock.
                    TimedWord(text: $0.text, start: $0.start + lyrics.offset, end: $0.end + lyrics.offset)
                }
                let timings = try await Task.detached(priority: .userInitiated) {
                    try Self.timings(for: lyrics.lines, heard: heard)
                }.value
                try WordSyncStore.save(timings, for: song.id, lyrics: lyrics)
                if LyricsSummaries.shared.summary(for: song.id) == nil { LyricsSummaries.shared.summarizeSoon(song) }
            } catch {
                failures[song.id] = error.localizedDescription
            }
            stages[song.id] = nil
        }
    }

    /// Unsynced lyrics: the vocals heard give each line its time, then
    /// (with Word by Word on in AI Features) each word.
    func syncPlain(_ song: Song, lyrics: LRCLyrics, in library: LibraryService) {
        guard stages[song.id] == nil else { return }
        failures[song.id] = nil
        guard AIFeatures.isAvailable, let key = AIFeatures.apiKey else {
            failures[song.id] = SyncError.unavailable.localizedDescription
            return
        }
        let texts = lyrics.plainText.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !texts.isEmpty else { return }
        stages[song.id] = .preparing
        Task {
            do {
                let chunks = try await LyricsGenerator.audioChunks(at: song.playableFileURL, duration: song.duration)
                defer { chunks.filter(\.isTemporary).forEach { try? FileManager.default.removeItem(at: $0.url) } }
                stages[song.id] = .transcribing(part: 0, of: chunks.count)
                let transcribed = try await LyricsGenerator.transcribe(chunks, key: key) { done in
                    self.stages[song.id] = .transcribing(part: done, of: chunks.count)
                }
                stages[song.id] = .matching
                let heard = LyricsGenerator.sungWords(in: transcribed)
                guard let first = heard.first, let last = heard.last else { throw SyncError.poorMatch }
                let content = try await Task.detached(priority: .userInitiated) {
                    let starts = Self.plainLineStarts(texts, heard: heard)
                    var lines: [LyricsGenerator.Line] = []
                    for (index, text) in texts.enumerated() {
                        let next = index + 1 < starts.count ? starts[index + 1] : last.end
                        lines.append(.init(text: text, start: starts[index], end: max(starts[index], min(next - 0.1, starts[index] + 8))))
                    }
                    return LyricsGenerator.lrc(lines: lines, for: song)
                }.value
                // Delete AI Lyrics brings these back.
                if let original = library.song(withID: song.id)?.lrcFilePath {
                    LyricsGenerator.setOriginal(original, for: song.id)
                }
                try LyricsGenerator.shared.save(content, for: song, in: library)
                LyricsSummaries.shared.summarizeSoon(library.song(withID: song.id) ?? song)
                if LyricsGenerator.wordByWord {
                    let parsed = LRCParser.parse(content: content)
                    if let timings = try? await Task.detached(priority: .userInitiated, operation: {
                        try Self.timings(for: parsed.lines, heard: heard)
                    }).value {
                        try? WordSyncStore.save(timings, for: song.id, lyrics: parsed)
                    }
                }
            } catch {
                failures[song.id] = error.localizedDescription
            }
            stages[song.id] = nil
        }
    }

    /// Each line's start: spread by length over the vocals, then matched to
    /// the words heard in narrowing windows. Lines nothing anchored sit
    /// between their neighbours.
    nonisolated static func plainLineStarts(_ texts: [String], heard: [TimedWord]) -> [TimeInterval] {
        guard let first = heard.first, let last = heard.last else { return texts.map { _ in 0 } }
        let weights = texts.map { Double(max(1, $0.count)) }
        let total = weights.reduce(0, +)
        var cumulative = [0.0]
        for weight in weights { cumulative.append(cumulative.last! + weight) }
        var starts = texts.indices.map { first.start + (last.end - first.start) * cumulative[$0] / total }
        for slack in [40.0, 15, 6, 3] {
            let lines = zip(texts, starts).map { LyricsLine(time: $1, text: $0) }
            var anchored: [Int: TimeInterval] = [:]
            _ = try? timings(for: lines, heard: heard, slack: slack) { anchored = $0 }
            guard !anchored.isEmpty else { continue }
            // Anchors out of order are dropped, the rest interpolated by length.
            var kept: [(index: Int, time: TimeInterval)] = []
            for index in texts.indices {
                guard let time = anchored[index] else { continue }
                if let previous = kept.last, time <= previous.time { continue }
                kept.append((index, time))
            }
            for index in texts.indices {
                let before = kept.last { $0.index <= index }
                let after = kept.first { $0.index >= index }
                switch (before, after) {
                case let (b?, a?) where a.index != b.index:
                    let share = (cumulative[index] - cumulative[b.index]) / max(1, cumulative[a.index] - cumulative[b.index])
                    starts[index] = b.time + (a.time - b.time) * share
                case let (b?, _?):
                    starts[index] = b.time
                case let (b?, nil):
                    starts[index] = min(last.end, b.time + (cumulative[index] - cumulative[b.index]) / total * (last.end - first.start))
                case let (nil, a?):
                    starts[index] = max(0, a.time - (cumulative[a.index] - cumulative[index]) / total * (last.end - first.start))
                case (nil, nil):
                    break
                }
            }
        }
        return starts
    }

    // MARK: Matching

    /// Below this share of the lyrics' words found in the vocals, the times
    /// would mostly be guesses.
    nonisolated static let minimumMatchedShare = 0.35

    /// One timing per word of every line (none for instrumental breaks).
    nonisolated static func timings(for lines: [LyricsLine], heard: [TimedWord], slack: TimeInterval = 2, anchors: ((_ starts: [Int: TimeInterval]) -> Void)? = nil) throws -> [[WordTiming]] {
        struct Token {
            var line: Int
            var key: String
        }
        let wordRanges = lines.map { LyricWords.ranges(in: $0.text) }
        var tokens: [Token] = []
        for (lineIndex, ranges) in wordRanges.enumerated() where !lines[lineIndex].isInstrumentalGap {
            for range in ranges {
                tokens.append(Token(line: lineIndex, key: comparable(String(lines[lineIndex].text[range]))))
            }
        }
        guard !tokens.isEmpty else { throw SyncError.noTimedLyrics }
        let heardKeys = heard.map { comparable($0.text) }

        // When each line may be sung: from a little before its timestamp to
        // a little after the next line's.
        let windows: [ClosedRange<TimeInterval>] = lines.indices.map { index in
            let start = lines[index].time - slack
            let next = lines[(index + 1)...].first { $0.time > lines[index].time }?.time ?? lines[index].time + 15
            return start...(next + slack)
        }

        // Heaviest common subsequence of the lyrics' words and the words
        // heard, a word only pairing with one heard while its line is sung.
        let n = tokens.count
        let m = heard.count
        var score = [[Double]](repeating: [Double](repeating: 0, count: m + 1), count: n + 1)
        func pairScore(_ i: Int, _ j: Int) -> Double {
            guard windows[tokens[i].line].contains(heard[j].start) else { return 0 }
            return similarity(tokens[i].key, heardKeys[j])
        }
        for i in 1...n {
            for j in stride(from: 1, through: m, by: 1) {
                let pair = pairScore(i - 1, j - 1)
                score[i][j] = max(score[i - 1][j], score[i][j - 1], pair > 0 ? score[i - 1][j - 1] + pair : 0)
            }
        }
        var matched = [Int?](repeating: nil, count: n)
        var i = n
        var j = m
        while i > 0, j > 0 {
            let pair = pairScore(i - 1, j - 1)
            if pair > 0, score[i][j] == score[i - 1][j - 1] + pair {
                matched[i - 1] = j - 1
                i -= 1
                j -= 1
            } else if score[i - 1][j] >= score[i][j - 1] {
                i -= 1
            } else {
                j -= 1
            }
        }
        guard Double(matched.compactMap { $0 }.count) >= Double(n) * minimumMatchedShare else { throw SyncError.poorMatch }
        if let anchors {
            // Per line, where its first matched word was heard, moved back
            // for the words before it.
            var starts: [Int: TimeInterval] = [:]
            var position: [Int: Int] = [:]
            for (index, token) in tokens.enumerated() {
                let offset = position[token.line, default: 0]
                position[token.line] = offset + 1
                if starts[token.line] == nil, let heardIndex = matched[index], offset <= 2 {
                    starts[token.line] = heard[heardIndex].start - Double(offset) * 0.3
                }
            }
            anchors(starts)
        }

        // Per line: matched words keep the times heard, the others share out
        // the time around them by length.
        var result = wordRanges.map { _ in [WordTiming]() }
        var tokenIndex = 0
        for (lineIndex, ranges) in wordRanges.enumerated() where !lines[lineIndex].isInstrumentalGap {
            let line = lines[lineIndex]
            let lineTokens = tokenIndex..<(tokenIndex + ranges.count)
            tokenIndex += ranges.count
            let next = lines[(lineIndex + 1)...].first { $0.time > line.time }?.time ?? line.time + 10
            let words = ranges.map { line.text[$0] }
            let anchors: [WordTiming?] = lineTokens.map { index in
                matched[index].map { WordTiming(start: heard[$0].start, end: heard[$0].end) }
            }
            result[lineIndex] = lineTimings(words: words.map { $0.count }, anchors: anchors, lineStart: line.time, lineEnd: next)
        }
        return result
    }

    /// Times for one line's words, `weights` being their lengths.
    nonisolated static func lineTimings(words weights: [Int], anchors rawAnchors: [WordTiming?], lineStart: TimeInterval, lineEnd: TimeInterval) -> [WordTiming] {
        let count = weights.count
        guard count > 0 else { return [] }
        let lineEnd = max(lineEnd, lineStart + 0.3)
        // About how long a word of this many letters is sung for, when
        // nothing else tells.
        func spoken(_ range: Range<Int>) -> TimeInterval {
            range.reduce(0) { $0 + 0.12 + Double(weights[$1]) * 0.055 }
        }

        // Anchors in order and inside the line.
        var anchors = rawAnchors
        var latest = lineStart - 0.5
        for index in anchors.indices {
            guard var anchor = anchors[index] else { continue }
            if anchor.start < latest || anchor.start >= lineEnd {
                anchors[index] = nil
                continue
            }
            anchor.start = max(anchor.start, lineStart - 0.5)
            anchor.end = min(max(anchor.end, anchor.start + 0.08), lineEnd)
            anchors[index] = anchor
            latest = anchor.start
        }

        var timings = [WordTiming](repeating: WordTiming(start: 0, end: 0), count: count)
        // Spreads the words in `range` over `span`, by length.
        func share(_ range: Range<Int>, over span: ClosedRange<TimeInterval>) {
            guard !range.isEmpty else { return }
            let total = Double(range.reduce(0) { $0 + weights[$1] + 1 })
            var cursor = span.lowerBound
            for index in range {
                let length = (span.upperBound - span.lowerBound) * Double(weights[index] + 1) / total
                timings[index] = WordTiming(start: cursor, end: cursor + length)
                cursor += length
            }
        }

        var index = 0
        var previousEnd = lineStart
        while index < count {
            if let anchor = anchors[index] {
                timings[index] = anchor
                previousEnd = anchor.end
                index += 1
                continue
            }
            var runEnd = index
            while runEnd < count, anchors[runEnd] == nil { runEnd += 1 }
            let run = index..<runEnd
            if runEnd < count, let nextAnchor = anchors[runEnd] {
                // Between two heard words (or the line's start and one).
                var start = previousEnd
                if start > nextAnchor.start - 0.1 * Double(run.count) {
                    start = max(lineStart - 0.5, nextAnchor.start - spoken(run))
                }
                share(run, over: start...max(start + 0.05, nextAnchor.start))
            } else {
                let end = min(lineEnd - 0.05, previousEnd + spoken(run))
                share(run, over: previousEnd...max(previousEnd + 0.05 * Double(run.count), end))
            }
            index = runEnd
        }

        // Words sung back to back light up in one sweep, without a pause
        // between them; times only ever go forward.
        for index in timings.indices {
            if index > 0, timings[index].start < timings[index - 1].start {
                timings[index].start = timings[index - 1].start
            }
            timings[index].end = max(timings[index].end, timings[index].start + 0.05)
            if index + 1 < count {
                let nextStart = timings[index + 1].start
                if nextStart - timings[index].end < 0.25 || timings[index].end > nextStart {
                    timings[index].end = max(timings[index].start + 0.05, nextStart)
                }
            }
        }
        return timings
    }

    /// Lowercased, without accents or punctuation: "Don't," and "dont" match.
    nonisolated static func comparable(_ word: String) -> String {
        word.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }

    /// 0 for different words, up to 3 for the same; close spellings ("gonna",
    /// "gon") count a little.
    nonisolated static func similarity(_ a: String, _ b: String) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        if a == b { return 3 }
        let longest = max(a.count, b.count)
        guard longest >= 3, abs(a.count - b.count) <= longest / 2 else { return 0 }
        let ratio = 1 - Double(editDistance(Array(a), Array(b))) / Double(longest)
        if ratio >= 0.75 { return 2 }
        if ratio >= 0.6 { return 1 }
        return 0
    }

    nonisolated private static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        var previous = Array(0...b.count)
        for (i, ca) in a.enumerated() {
            var current = [i + 1] + [Int](repeating: 0, count: b.count)
            for (j, cb) in b.enumerated() {
                current[j + 1] = min(previous[j + 1] + 1, current[j] + 1, previous[j] + (ca == cb ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }
}
