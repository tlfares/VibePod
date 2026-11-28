import CryptoKit
import Foundation
import SwiftUI

// MARK: - Candidates

/// Lyrics found for a song by one source, in a common shape: lines with
/// their time, and when the source has them, a time per word and who sings.
struct LyricsCandidate: Identifiable, Sendable {
    struct Line: Sendable {
        var time: TimeInterval
        var text: String
        /// One per word of `text` (as `LyricWords` splits it), or nil.
        var words: [WordTiming]?
        /// The singer's id in the source (TTML's `ttm:agent`), when known.
        var agent: String?
        /// When the line ends, if the source says.
        var end: TimeInterval?
    }

    let id = UUID()
    let source: String
    let title: String
    let artist: String
    var album: String?
    var duration: TimeInterval?
    var lines: [Line] = []
    var plainText: String?
    /// Agents sung as a group, which stay on the leading side.
    var groupAgents: Set<String> = []
    var score: Double = 0

    var isSynced: Bool { !lines.isEmpty }
    var isWordSynced: Bool { lines.contains { $0.words != nil } }
    /// Lines on the trailing side: those of every singer but the first.
    var trailingLineIndices: Set<Int> {
        var first: String?
        var trailing: Set<Int> = []
        for (index, line) in lines.enumerated() {
            guard let agent = line.agent, !groupAgents.contains(agent) else { continue }
            if first == nil { first = agent }
            if agent != first { trailing.insert(index) }
        }
        return trailing
    }
    var isDuet: Bool { !trailingLineIndices.isEmpty }

    var hasLyrics: Bool { isSynced || plainText?.isEmpty == false }

    /// Feature labels for the results list, best first.
    var featureText: String {
        let stars = isWordSynced ? (isDuet ? 3 : 2) : (isSynced ? 1 : 0)
        let label = featureLabel
        return stars == 0 ? label : String(repeating: "⭐️", count: stars) + " " + label
    }

    private var featureLabel: String {
        var parts: [String] = []
        if isWordSynced { parts.append(String(localized: "Word by Word")) } else if isSynced { parts.append(String(localized: "Synced")) } else { parts.append(String(localized: "Not synced")) }
        if isDuet { parts.append(String(localized: "Duet")) }
        return parts.joined(separator: " · ")
    }

    /// What goes into the LRC file: line times and text only. Word times and
    /// singers are kept beside it (see `LyricsImport`).
    var fileLines: [Line] {
        var result: [Line] = []
        for (index, line) in lines.enumerated() {
            result.append(line)
            // A long silence after a line is an instrumental break, so the
            // line doesn't stay lit through it.
            let next = index + 1 < lines.count ? lines[index + 1].time : nil
            if let end = line.end, let next, next - end > 6 {
                result.append(Line(time: end, text: ""))
            }
        }
        return result
    }

    var lrcText: String {
        guard isSynced else { return plainText ?? "" }
        var text = "[ti:\(title)]\n[ar:\(artist)]\n"
        if let album, !album.isEmpty { text += "[al:\(album)]\n" }
        text += "[re:\(source)]\n"
        for line in fileLines {
            text += "[\(Self.timeTag(line.time))]\(line.text)\n"
        }
        return text
    }

    private static func timeTag(_ time: TimeInterval) -> String {
        let time = max(time, 0)
        let minutes = Int(time) / 60
        let seconds = time - Double(minutes * 60)
        return String(format: "%02d:%05.2f", minutes, seconds)
    }
}

/// A run of text sung at one time: a syllable or a word, maybe with its
/// trailing space.
struct LyricsSyllable: Sendable {
    var text: String
    var start: TimeInterval
    var end: TimeInterval?
}

enum LyricsLineBuilder {
    /// Joins syllables into a line whose text is tidy (single spaces, no
    /// spaces at the ends), with one timing per word of that text.
    static func line(from syllables: [LyricsSyllable], lineStart: TimeInterval? = nil, lineEnd: TimeInterval? = nil, agent: String? = nil) -> LyricsCandidate.Line? {
        var characters: [Character] = []
        var owners: [Int] = []
        for (index, syllable) in syllables.enumerated() {
            for character in syllable.text {
                if character.isWhitespace {
                    if let last = characters.last, !last.isWhitespace { characters.append(" "); owners.append(index) }
                } else {
                    characters.append(character)
                    owners.append(index)
                }
            }
        }
        while characters.last?.isWhitespace == true { characters.removeLast(); owners.removeLast() }
        guard !characters.isEmpty, !syllables.isEmpty else { return nil }
        let text = String(characters)

        func end(of index: Int) -> TimeInterval {
            if let end = syllables[index].end, end > syllables[index].start { return end }
            if index + 1 < syllables.count { return syllables[index + 1].start }
            return max(lineEnd ?? syllables[index].start + 0.3, syllables[index].start + 0.05)
        }

        var words: [WordTiming] = []
        var wordOwners: [Int] = []
        for character in characters.indices {
            if characters[character].isWhitespace {
                if !wordOwners.isEmpty { words.append(timing(wordOwners)); wordOwners = [] }
            } else {
                wordOwners.append(owners[character])
            }
        }
        if !wordOwners.isEmpty { words.append(timing(wordOwners)) }

        func timing(_ owners: [Int]) -> WordTiming {
            let first = owners.min() ?? 0
            let last = owners.max() ?? 0
            return WordTiming(start: syllables[first].start, end: end(of: last))
        }

        let start = lineStart ?? syllables[0].start
        guard words.count == LyricWords.ranges(in: text).count else {
            return LyricsCandidate.Line(time: start, text: text, words: nil, agent: agent, end: lineEnd)
        }
        return LyricsCandidate.Line(time: start, text: text, words: words, agent: agent, end: lineEnd ?? words.last?.end)
    }

    /// A line without word times: text tidied the same way.
    static func plainLine(time: TimeInterval, text: String, end: TimeInterval? = nil, agent: String? = nil) -> LyricsCandidate.Line {
        let tidy = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return LyricsCandidate.Line(time: time, text: tidy, words: nil, agent: agent, end: end)
    }
}

// MARK: - Search

/// Searches every source at once; a source that fails or is slow is
/// skipped. Results are ranked by how well they match the song, then by
/// what they offer (word by word, duet, synced).
enum LyricsSearch {
    struct Query: Sendable {
        var title: String
        var artist: String
        var album: String?
        var duration: TimeInterval?
    }

    static let timeout: TimeInterval = 6
    /// Once a source has a strong match, the slower ones get this long.
    static let grace: TimeInterval = 1.2

    static func search(_ query: Query) async -> [LyricsCandidate] {
        let providers: [@Sendable (Query) async throws -> [LyricsCandidate]] = [
            { try await LRCLIBSource.search($0) },
            KuGouSource.search,
            MusixmatchSource.search,
            LyricsPlusSource.search,
            UnisonSource.search,
        ]
        // nil: the grace period after a strong match ran out.
        let found = await withTaskGroup(of: [LyricsCandidate]?.self) { group in
            for provider in providers {
                group.addTask {
                    await withTaskGroup(of: [LyricsCandidate]?.self) { race in
                        race.addTask { try? await provider(query) }
                        race.addTask {
                            try? await Task.sleep(for: .seconds(timeout))
                            return nil
                        }
                        let first = await race.next() ?? nil
                        race.cancelAll()
                        return first ?? []
                    }
                }
            }
            var all: [LyricsCandidate] = []
            var pending = providers.count
            var isWaitingOnGrace = false
            for await results in group {
                guard let results else { break }
                all += results
                pending -= 1
                if pending == 0 { break }
                if !isWaitingOnGrace, results.contains(where: { $0.isSynced && score($0, for: query) >= 0.9 }) {
                    isWaitingOnGrace = true
                    group.addTask {
                        try? await Task.sleep(for: .seconds(grace))
                        return nil
                    }
                }
            }
            group.cancelAll()
            return all
        }
        return rank(found, for: query)
    }

    static func rank(_ candidates: [LyricsCandidate], for query: Query) -> [LyricsCandidate] {
        var seen: Set<String> = []
        return candidates
            .filter(\.hasLyrics)
            .map { candidate in
                var candidate = candidate
                candidate.score = score(candidate, for: query)
                return candidate
            }
            .filter { $0.score > 0.35 }
            .sorted { $0.score > $1.score }
            // The same lyrics from two sources: the better ranked one stays.
            .filter { seen.insert("\($0.source)|\($0.lrcText.hashValue)").inserted }
    }

    /// 0…1 for the match (title, artist, length), plus a bonus for what the
    /// lyrics can do. A poor match never wins on features.
    static func score(_ candidate: LyricsCandidate, for query: Query) -> Double {
        let title = TextMatch.similarity(TextMatch.core(candidate.title), TextMatch.core(query.title))
        let artist = TextMatch.artistSimilarity(candidate.artist, query.artist)
        var match = title * 0.5 + artist * 0.3
        if let wanted = query.duration, wanted > 0, let duration = candidate.duration, duration > 0 {
            let difference = abs(duration - wanted)
            match += 0.2 * max(0, 1 - max(difference - 2, 0) / 15)
        } else {
            match += 0.1
        }
        guard match > 0.45 else { return match }
        var bonus = 0.0
        if candidate.isWordSynced { bonus += 0.12 } else if candidate.isSynced { bonus += 0.08 }
        if candidate.isDuet { bonus += 0.04 }
        return match + bonus
    }
}

enum TextMatch {
    static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .init(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "&", with: " and ")
            .unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : " " }.joined()
            .split(separator: " ").joined(separator: " ")
    }

    /// A title without "(feat. …)", "- Remastered" and the like.
    static func core(_ title: String) -> String {
        var title = title
        for pattern in [#"\s*[\(\[][^\)\]]*[\)\]]"#, #"\s+-\s+.*$"#] {
            title = title.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return title.isEmpty ? title : title
    }

    /// Dice coefficient over character bigrams, 1 when equal.
    static func similarity(_ a: String, _ b: String) -> Double {
        let a = normalized(a), b = normalized(b)
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        if a == b { return 1 }
        if a.contains(b) || b.contains(a) { return 0.85 }
        func bigrams(_ s: String) -> [String] {
            let c = Array(s.replacingOccurrences(of: " ", with: ""))
            return c.count < 2 ? [String(c)] : (0..<c.count - 1).map { String(c[$0...$0 + 1]) }
        }
        var other = bigrams(b)
        let first = bigrams(a)
        var shared = 0
        for gram in first {
            if let index = other.firstIndex(of: gram) { shared += 1; other.remove(at: index) }
        }
        return 2 * Double(shared) / Double(first.count + bigrams(b).count)
    }

    /// Artists match when any credited name matches ("A, B & C").
    static func artistSimilarity(_ a: String, _ b: String) -> Double {
        let split: (String) -> [String] = {
            $0.components(separatedBy: CharacterSet(charactersIn: ",&;/")).flatMap { $0.components(separatedBy: " feat") }
                .flatMap { $0.components(separatedBy: " x ") }
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        var best = similarity(a, b)
        for x in split(a) { for y in split(b) { best = max(best, similarity(x, y)) } }
        return best
    }
}

// MARK: - HTTP

enum LyricsHTTP {
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = LyricsSearch.timeout
        configuration.httpCookieStorage = HTTPCookieStorage.shared
        return URLSession(configuration: configuration)
    }()

    static let browserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"

    static func url(_ base: String, _ items: [String: String?]) -> URL? {
        var components = URLComponents(string: base)
        components?.queryItems = items.compactMap { key, value in value.map { URLQueryItem(name: key, value: $0) } }
        return components?.url
    }

    static func data(_ url: URL, headers: [String: String] = [:]) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("VibePod-iOS/1.0", forHTTPHeaderField: "User-Agent")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    static func json(_ url: URL, headers: [String: String] = [:]) async throws -> Any {
        try JSONSerialization.jsonObject(with: try await data(url, headers: headers))
    }
}

// MARK: - Line-synced LRC (also enhanced LRC with word tags)

enum LRCReader {
    private static let lineRegex = try! NSRegularExpression(pattern: #"^\[(\d{1,3}):(\d{1,2}(?:[.:]\d{1,3})?)\](.*)$"#)
    private static let wordRegex = try! NSRegularExpression(pattern: #"<(\d{1,3}):(\d{1,2}(?:[.:]\d{1,3})?)>([^<]*)"#)

    static func seconds(_ minutes: String, _ seconds: String) -> TimeInterval {
        (Double(minutes) ?? 0) * 60 + (Double(seconds.replacingOccurrences(of: ":", with: ".")) ?? 0)
    }

    static func lines(_ content: String) -> [LyricsCandidate.Line] {
        var lines: [LyricsCandidate.Line] = []
        for raw in content.components(separatedBy: .newlines) {
            let raw = raw.trimmingCharacters(in: .whitespaces)
            let range = NSRange(raw.startIndex..., in: raw)
            guard let match = lineRegex.firstMatch(in: raw, range: range),
                  let m = Range(match.range(at: 1), in: raw), let s = Range(match.range(at: 2), in: raw),
                  let rest = Range(match.range(at: 3), in: raw) else { continue }
            let time = seconds(String(raw[m]), String(raw[s]))
            var body = String(raw[rest])
            // "v1:" / "v2:" singer prefixes some enhanced LRC files carry.
            var agent: String?
            if let prefix = body.range(of: #"^\s*(v\d+):\s*"#, options: .regularExpression) {
                agent = body[prefix].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ":", with: "")
                body.removeSubrange(prefix)
            }
            let bodyRange = NSRange(body.startIndex..., in: body)
            let tags = wordRegex.matches(in: body, range: bodyRange)
            if tags.isEmpty {
                lines.append(LyricsLineBuilder.plainLine(time: time, text: body, agent: agent))
                continue
            }
            let syllables: [LyricsSyllable] = tags.compactMap { tag in
                guard let m = Range(tag.range(at: 1), in: body), let s = Range(tag.range(at: 2), in: body),
                      let t = Range(tag.range(at: 3), in: body) else { return nil }
                return LyricsSyllable(text: String(body[t]), start: seconds(String(body[m]), String(body[s])))
            }
            // A closing tag with no text marks the last word's end.
            var cleaned: [LyricsSyllable] = []
            for syllable in syllables {
                if syllable.text.isEmpty, var last = cleaned.popLast() {
                    last.end = syllable.start
                    cleaned.append(last)
                } else {
                    cleaned.append(syllable)
                }
            }
            let leading = body[..<(Range(tags[0].range, in: body)?.lowerBound ?? body.startIndex)]
            if !leading.trimmingCharacters(in: .whitespaces).isEmpty {
                cleaned.insert(LyricsSyllable(text: String(leading), start: time), at: 0)
            }
            if let line = LyricsLineBuilder.line(from: cleaned, lineStart: time, agent: agent) {
                lines.append(line)
            } else {
                lines.append(LyricsLineBuilder.plainLine(time: time, text: "", agent: agent))
            }
        }
        return lines.sorted { $0.time < $1.time }
    }
}

// MARK: - TTML (Apple-style: per-syllable spans, singers as agents)

final class TTMLReader: NSObject, XMLParserDelegate {
    private var lines: [LyricsCandidate.Line] = []
    private var groupAgents: Set<String> = []
    private var inBody = false
    private var paragraph: (begin: TimeInterval?, end: TimeInterval?, agent: String?)?
    private var syllables: [LyricsSyllable] = []
    private var looseText = ""
    /// Open spans: whether each is timed, and skipped (background vocals,
    /// translations).
    private var spans: [(timed: Bool, skipped: Bool)] = []
    private var current: LyricsSyllable?
    private var text = ""

    static func parse(_ ttml: String) -> (lines: [LyricsCandidate.Line], groups: Set<String>) {
        let reader = TTMLReader()
        let parser = XMLParser(data: Data(ttml.utf8))
        parser.shouldProcessNamespaces = false
        parser.delegate = reader
        parser.parse()
        return (reader.lines.sorted { $0.time < $1.time }, reader.groupAgents)
    }

    static func time(_ value: String?) -> TimeInterval? {
        guard var value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if value.hasSuffix("ms") { return Double(value.dropLast(2)).map { $0 / 1000 } }
        if value.hasSuffix("s") { value.removeLast() }
        let parts = value.split(separator: ":").map { Double($0) ?? 0 }
        return parts.reduce(0) { $0 * 60 + $1 }
    }

    private var skipping: Bool { spans.contains { $0.skipped } }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        let local = name.split(separator: ":").last.map(String.init) ?? name
        switch local {
        case "agent":
            if attributes["type"] == "group", let id = attributes["xml:id"] { groupAgents.insert(id) }
        case "body":
            inBody = true
        case "p" where inBody:
            paragraph = (Self.time(attributes["begin"]), Self.time(attributes["end"]), attributes["ttm:agent"])
            syllables = []
            looseText = ""
            text = ""
        case "span" where paragraph != nil:
            flushLoose()
            let role = attributes["ttm:role"] ?? ""
            let skipped = role == "x-bg" || role.hasPrefix("x-translation") || role.hasPrefix("x-roman")
            let begin = Self.time(attributes["begin"])
            spans.append((begin != nil, skipped))
            if let begin, !skipping {
                current = LyricsSyllable(text: "", start: begin, end: Self.time(attributes["end"]))
                text = ""
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard paragraph != nil, !skipping else { return }
        if current != nil { text += string } else { looseText += string }
    }

    /// Text between spans: a space between words, or a line without spans.
    private func flushLoose() {
        guard !looseText.isEmpty else { return }
        if looseText.allSatisfy(\.isWhitespace), let last = syllables.popLast() {
            var last = last
            last.text += " "
            syllables.append(last)
        } else if let last = syllables.last {
            syllables.append(LyricsSyllable(text: looseText, start: last.end ?? last.start, end: last.end))
        }
        looseText = ""
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let local = name.split(separator: ":").last.map(String.init) ?? name
        switch local {
        case "span" where paragraph != nil:
            let span = spans.popLast()
            if span?.timed == true, !(span?.skipped ?? false), !skipping, var syllable = current {
                syllable.text = text
                syllables.append(syllable)
                current = nil
                text = ""
            }
        case "p":
            guard let paragraph else { return }
            let lineText = looseText
            if syllables.isEmpty {
                if let begin = paragraph.begin {
                    lines.append(LyricsLineBuilder.plainLine(time: begin, text: lineText, end: paragraph.end, agent: paragraph.agent))
                }
            } else {
                flushLoose()
                if let line = LyricsLineBuilder.line(from: syllables, lineStart: paragraph.begin, lineEnd: paragraph.end, agent: paragraph.agent) {
                    lines.append(line)
                }
            }
            self.paragraph = nil
        case "body":
            inBody = false
        default:
            break
        }
    }
}

// MARK: - LRCLIB

enum LRCLIBSource {
    static func search(_ query: LyricsSearch.Query, attempts: Int = 2) async throws -> [LyricsCandidate] {
        let results = try await withCheckedThrowingContinuation { continuation in
            // One retry only: when LRCLIB is down, its backoff kept the
            // whole search waiting while the other sources had answered.
            LRCLIBService.shared.search(trackName: query.title, artistName: query.artist, albumName: query.album, duration: query.duration, attempts: attempts) { result in
                switch result {
                case let .success(results): continuation.resume(returning: results)
                case let .failure(error): continuation.resume(throwing: error)
                }
            }
        }
        return results.map { result in
            var candidate = LyricsCandidate(source: "LRCLIB", title: result.trackName, artist: result.artistName, album: result.albumName, duration: result.duration > 0 ? result.duration : nil)
            if let synced = result.syncedLyrics, !synced.isEmpty {
                candidate.lines = LRCReader.lines(synced)
            }
            candidate.plainText = result.plainLyrics
            return candidate
        }
    }
}

// MARK: - KuGou (KRC: word by word)

enum KuGouSource {
    private static let key: [UInt8] = [64, 71, 97, 119, 94, 50, 116, 71, 81, 54, 49, 45, 206, 210, 110, 105]

    static func search(_ query: LyricsSearch.Query) async throws -> [LyricsCandidate] {
        var items: [String: String?] = ["ver": "1", "man": "yes", "client": "pc", "keyword": "\(query.artist) - \(query.title)"]
        if let duration = query.duration { items["duration"] = String(Int(duration * 1000)) }
        guard let url = LyricsHTTP.url("https://lyrics.kugou.com/search", items),
              let json = try await LyricsHTTP.json(url) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]] else { return [] }

        // The candidates' lyrics download side by side.
        let picks = candidates.prefix(3).compactMap { item -> Pick? in
            guard let id = item["id"].map({ "\($0)" }), let accessKey = item["accesskey"] as? String else { return nil }
            return Pick(id: id, accessKey: accessKey, song: item["song"] as? String, singer: item["singer"] as? String,
                        duration: (item["duration"] as? Double).map { $0 / 1000 })
        }
        let downloaded = await withTaskGroup(of: (Int, LyricsCandidate?).self) { group in
            for (index, pick) in picks.enumerated() {
                group.addTask { (index, await candidate(pick, query: query)) }
            }
            var found: [(Int, LyricsCandidate)] = []
            for await (index, candidate) in group {
                if let candidate { found.append((index, candidate)) }
            }
            return found
        }
        return downloaded.sorted { $0.0 < $1.0 }.map(\.1)
    }

    private struct Pick: Sendable {
        let id: String
        let accessKey: String
        let song: String?
        let singer: String?
        let duration: TimeInterval?
    }

    private static func candidate(_ pick: Pick, query: LyricsSearch.Query) async -> LyricsCandidate? {
        guard let download = LyricsHTTP.url("https://lyrics.kugou.com/download", [
                  "ver": "1", "client": "pc", "id": pick.id, "accesskey": pick.accessKey, "fmt": "krc", "charset": "utf8",
              ]),
              let body = try? await LyricsHTTP.json(download) as? [String: Any],
              let content = body["content"] as? String,
              let krc = decode(content) else { return nil }
        let lines = dropCredits(parse(krc), title: pick.song ?? query.title)
        guard !lines.isEmpty else { return nil }
        return LyricsCandidate(
            source: "KuGou",
            title: pick.song ?? query.title,
            artist: pick.singer ?? query.artist,
            duration: pick.duration,
            lines: lines
        )
    }

    /// KuGou opens with "Title - Artist" and credit lines ("Lyrics by:
    /// …", "作词：…") before the first sung line: they go.
    static func dropCredits(_ lines: [LyricsCandidate.Line], title: String) -> [LyricsCandidate.Line] {
        let creditWords = ["lyrics", "lyricist", "composed", "composer", "written", "writer", "produced", "producer",
                           "arranged", "arranger", "mixed", "mastered", "music", "words", "作词", "作曲", "编曲", "制作", "词", "曲"]
        let core = TextMatch.normalized(TextMatch.core(title))
        var index = 0
        while index < lines.count, index < 12 {
            let text = lines[index].text
            let lower = text.lowercased()
            let isCredit: Bool = {
                if let colon = lower.firstIndex(where: { $0 == ":" || $0 == "：" }) {
                    let label = lower[..<colon]
                    return label.count <= 24 && creditWords.contains { label.contains($0) }
                }
                // "Title - Artist"
                if text.contains(" - "), !core.isEmpty,
                   TextMatch.normalized(text.components(separatedBy: " - ")[0]) == core { return true }
                return false
            }()
            guard isCredit else { break }
            index += 1
        }
        return Array(lines[index...])
    }

    static func decode(_ base64: String) -> String? {
        guard let data = Data(base64Encoded: base64), data.count > 4 else { return nil }
        var bytes = [UInt8](data.dropFirst(4))
        for index in bytes.indices { bytes[index] ^= key[index % key.count] }
        // zlib: a 2-byte header, raw deflate, a 4-byte checksum.
        guard bytes.count > 6, let inflated = try? (Data(bytes[2..<(bytes.count - 4)]) as NSData).decompressed(using: .zlib) else { return nil }
        return String(data: inflated as Data, encoding: .utf8)
    }

    private static let lineRegex = try! NSRegularExpression(pattern: #"^\[(\d+),(\d+)\](.*)$"#)
    private static let wordRegex = try! NSRegularExpression(pattern: #"<(\d+),(\d+),\d+>([^<]*)"#)

    static func parse(_ krc: String) -> [LyricsCandidate.Line] {
        var lines: [LyricsCandidate.Line] = []
        for raw in krc.components(separatedBy: .newlines) {
            let raw = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            guard let match = lineRegex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
                  let s = Range(match.range(at: 1), in: raw), let d = Range(match.range(at: 2), in: raw),
                  let b = Range(match.range(at: 3), in: raw) else { continue }
            let start = (Double(raw[s]) ?? 0) / 1000
            let end = start + (Double(raw[d]) ?? 0) / 1000
            let body = String(raw[b])
            let syllables: [LyricsSyllable] = wordRegex.matches(in: body, range: NSRange(body.startIndex..., in: body)).compactMap { word in
                guard let o = Range(word.range(at: 1), in: body), let l = Range(word.range(at: 2), in: body),
                      let t = Range(word.range(at: 3), in: body) else { return nil }
                let offset = start + (Double(body[o]) ?? 0) / 1000
                return LyricsSyllable(text: String(body[t]), start: offset, end: offset + (Double(body[l]) ?? 0) / 1000)
            }
            if let line = LyricsLineBuilder.line(from: syllables, lineStart: start, lineEnd: end) {
                lines.append(line)
            }
        }
        return lines
    }
}

// MARK: - Musixmatch (desktop app API: richsync is word by word)

actor MusixmatchToken {
    static let shared = MusixmatchToken()
    private var token: String?
    private var refusedUntil: Date?

    func get() async throws -> String {
        if let token { return token }
        if let refusedUntil, refusedUntil > .now { throw URLError(.userAuthenticationRequired) }
        guard let url = LyricsHTTP.url(MusixmatchSource.base + "token.get", ["app_id": MusixmatchSource.appID]),
              let json = try await LyricsHTTP.json(url, headers: MusixmatchSource.headers) as? [String: Any],
              let token = ((json["message"] as? [String: Any])?["body"] as? [String: Any])?["user_token"] as? String,
              token.contains(where: { $0 != "0" && $0 != "-" }) else {
            // Anonymous tokens are often refused for a while.
            refusedUntil = .now.addingTimeInterval(60)
            throw URLError(.userAuthenticationRequired)
        }
        self.token = token
        return token
    }

    func invalidate() { token = nil }
}

enum MusixmatchSource {
    static let base = "https://apic-desktop.musixmatch.com/ws/1.1/"
    static let appID = "web-desktop-app-v1.0"
    static let headers = [
        "User-Agent": LyricsHTTP.browserAgent,
        "Origin": "https://musixmatch.com",
        "Cookie": "AWSELB=unknown; AWSELBCORS=unknown",
    ]

    private static func body(_ method: String, _ items: [String: String?]) async throws -> [String: Any]? {
        var items = items
        items["app_id"] = appID
        items["usertoken"] = try await MusixmatchToken.shared.get()
        guard let url = LyricsHTTP.url(base + method, items),
              let json = try await LyricsHTTP.json(url, headers: headers) as? [String: Any],
              let message = json["message"] as? [String: Any] else { return nil }
        if (message["header"] as? [String: Any])?["status_code"] as? Int == 401 {
            await MusixmatchToken.shared.invalidate()
            return nil
        }
        return message["body"] as? [String: Any]
    }

    static func search(_ query: LyricsSearch.Query) async throws -> [LyricsCandidate] {
        var items: [String: String?] = ["q_track": query.title, "q_artist": query.artist, "q_album": query.album]
        if let duration = query.duration { items["q_duration"] = String(Int(duration)) }
        guard let track = try await body("matcher.track.get", items)?["track"] as? [String: Any],
              let trackID = track["track_id"].map({ "\($0)" }) else { return [] }
        var candidate = LyricsCandidate(
            source: "Musixmatch",
            title: track["track_name"] as? String ?? query.title,
            artist: track["artist_name"] as? String ?? query.artist,
            album: track["album_name"] as? String,
            duration: (track["track_length"] as? Double).flatMap { $0 > 0 ? $0 : nil }
        )
        if (track["has_richsync"] as? Int) == 1,
           let richsync = try? await body("track.richsync.get", ["track_id": trackID])?["richsync"] as? [String: Any],
           let text = richsync["richsync_body"] as? String,
           let lines = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]] {
            candidate.lines = lines.compactMap { line in
                guard let start = line["ts"] as? Double else { return nil }
                let end = line["te"] as? Double
                let parts = line["l"] as? [[String: Any]] ?? []
                let syllables = parts.compactMap { part -> LyricsSyllable? in
                    guard let c = part["c"] as? String, let o = part["o"] as? Double else { return nil }
                    return LyricsSyllable(text: c, start: start + o)
                }
                return LyricsLineBuilder.line(from: syllables, lineStart: start, lineEnd: end)
                    ?? (line["x"] as? String).map { LyricsLineBuilder.plainLine(time: start, text: $0, end: end) }
            }
        }
        if candidate.lines.isEmpty, (track["has_subtitles"] as? Int) == 1,
           let subtitle = try? await body("track.subtitle.get", ["track_id": trackID, "subtitle_format": "lrc"])?["subtitle"] as? [String: Any],
           let lrc = subtitle["subtitle_body"] as? String {
            candidate.lines = LRCReader.lines(lrc)
        }
        return candidate.isSynced ? [candidate] : []
    }
}

// MARK: - LyricsPlus (word by word, singers)

enum LyricsPlusSource {
    static let hosts = ["https://lyricsplus.binimum.org"]

    static func search(_ query: LyricsSearch.Query) async throws -> [LyricsCandidate] {
        var items: [String: String?] = ["title": query.title, "artist": query.artist, "album": query.album]
        if let duration = query.duration { items["duration"] = String(Int(duration)) }
        for host in hosts {
            guard let url = LyricsHTTP.url(host + "/v2/lyrics/get", items),
                  let json = try? await LyricsHTTP.json(url) as? [String: Any],
                  let lyrics = json["lyrics"] as? [[String: Any]], !lyrics.isEmpty else { continue }
            let metadata = json["metadata"] as? [String: Any] ?? [:]
            let agents = metadata["agents"] as? [String: [String: Any]] ?? [:]
            var candidate = LyricsCandidate(
                source: "LyricsPlus" + ((metadata["source"] as? String).map { " (\($0))" } ?? ""),
                title: metadata["title"] as? String ?? query.title,
                artist: metadata["artist"] as? String ?? query.artist,
                duration: query.duration
            )
            candidate.groupAgents = Set(agents.filter { ($0.value["type"] as? String) == "group" }.keys)
            candidate.lines = lyrics.compactMap { item in
                guard let time = item["time"] as? Double else { return nil }
                let start = time / 1000
                let end = (item["duration"] as? Double).map { start + $0 / 1000 }
                let agent = (item["element"] as? [String: Any])?["singer"] as? String
                let syllables = (item["syllabus"] as? [[String: Any]] ?? []).compactMap { syllable -> LyricsSyllable? in
                    guard syllable["isBackground"] as? Bool != true,
                          let text = syllable["text"] as? String, let time = syllable["time"] as? Double else { return nil }
                    let start = time / 1000
                    return LyricsSyllable(text: text, start: start, end: (syllable["duration"] as? Double).map { start + $0 / 1000 })
                }
                if !syllables.isEmpty, let line = LyricsLineBuilder.line(from: syllables, lineStart: start, lineEnd: end, agent: agent) {
                    return line
                }
                return LyricsLineBuilder.plainLine(time: start, text: item["text"] as? String ?? "", end: end, agent: agent)
            }
            .filter { !$0.text.isEmpty }
            if candidate.isSynced { return [candidate] }
        }
        return []
    }
}

// MARK: - Unison (better-lyrics' community lyrics)

enum UnisonSource {
    /// Each install identifies itself with a key of its own.
    private static var keyID: String {
        let storageKey = "unisonKeyID"
        if let key = UserDefaults.standard.string(forKey: storageKey) { return key }
        let key = UUID().uuidString.lowercased()
        UserDefaults.standard.set(key, forKey: storageKey)
        return key
    }

    static func search(_ query: LyricsSearch.Query) async throws -> [LyricsCandidate] {
        var items: [String: String?] = ["song": query.title, "artist": query.artist, "album": query.album]
        if let duration = query.duration { items["duration"] = String(Int(duration.rounded())) }
        guard let url = LyricsHTTP.url("https://unison.betterlyrics.org/lyrics", items),
              let json = try await LyricsHTTP.json(url, headers: ["x-key-id": keyID]) as? [String: Any],
              let data = json["data"] as? [String: Any],
              let lyrics = data["lyrics"] as? String, !lyrics.isEmpty else { return [] }
        var candidate = LyricsCandidate(source: "Unison", title: query.title, artist: query.artist, album: query.album, duration: query.duration)
        switch data["format"] as? String {
        case "ttml":
            let parsed = TTMLReader.parse(lyrics)
            candidate.lines = parsed.lines.filter { !$0.text.isEmpty }
            candidate.groupAgents = parsed.groups
        case "lrc":
            candidate.lines = LRCReader.lines(lyrics)
        default:
            candidate.plainText = lyrics
        }
        return [candidate]
    }
}

// MARK: - Singers (duets)

/// Which lines a second singer sings, shown on the trailing side like
/// Music's duets. Kept beside the LRC file, tied to the lyrics it was
/// saved for.
enum LyricsSingerStore {
    private struct File: Codable {
        var fingerprint: String
        var trailing: [Int]
    }

    private static var folder: URL {
        LibraryService.dataDirectory.appendingPathComponent("Singers", isDirectory: true)
    }

    private static func url(for songID: UUID) -> URL {
        folder.appendingPathComponent("\(songID.uuidString).json")
    }

    static func load(for songID: UUID, lyrics: LRCLyrics) -> Set<LyricsLine.ID> {
        guard let data = try? Data(contentsOf: url(for: songID)),
              let file = try? JSONDecoder().decode(File.self, from: data),
              file.fingerprint == WordSyncStore.fingerprint(of: lyrics.lines) else { return [] }
        return Set(file.trailing.compactMap { lyrics.lines.indices.contains($0) ? lyrics.lines[$0].id : nil })
    }

    static func save(trailing: Set<Int>, for songID: UUID, lyrics: LRCLyrics) throws {
        guard !trailing.isEmpty else { return delete(for: songID) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = File(fingerprint: WordSyncStore.fingerprint(of: lyrics.lines), trailing: trailing.sorted())
        try JSONEncoder().encode(file).write(to: url(for: songID), options: .atomic)
    }

    static func delete(for songID: UUID) {
        try? FileManager.default.removeItem(at: url(for: songID))
    }

    /// The stored file as is, for iCloud Sync.
    static func rawData(for songID: UUID) -> Data? {
        try? Data(contentsOf: url(for: songID))
    }

    /// Another device's file, or none.
    static func setRawData(_ data: Data?, for songID: UUID) {
        guard let data else { return delete(for: songID) }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: url(for: songID), options: .atomic)
    }
}

// MARK: - Auto match

/// Gives every song without lyrics the best search result, when it's a
/// close enough match.
@MainActor
final class LyricsAutoMatcher: ObservableObject {
    static let shared = LyricsAutoMatcher()

    @Published private(set) var isRunning = false
    @Published private(set) var done = 0
    @Published private(set) var total = 0
    @Published private(set) var matched = 0
    /// Songs being searched right now.
    @Published private(set) var searching: [String] = []
    /// Every song of the last run, newest first.
    @Published private(set) var results: [Result] = []

    struct Result: Identifiable {
        let id = UUID()
        let title: String
        let artist: String
        /// The source used, nil when nothing matched closely enough.
        let source: String?
    }

    var progress: Double { total == 0 ? 0 : Double(done) / Double(total) }

    /// Empty: every artist.
    @Published var artists: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "autoMatchArtists") ?? []) {
        didSet { UserDefaults.standard.set(artists.sorted(), forKey: "autoMatchArtists") }
    }

    static func lacksLyrics(_ song: Song) -> Bool {
        song.lrcFilePath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
    }

    nonisolated private static let minimumScore = 0.65

    func run(_ songs: [Song], player: PlayerViewModel) {
        guard !isRunning else { return }
        let missing = songs.filter(Self.lacksLyrics)
        guard !missing.isEmpty else { return }
        isRunning = true
        done = 0
        matched = 0
        results = []
        searching = []
        total = missing.count
        Task {
            await withTaskGroup(of: (Song, LyricsCandidate?).self) { group in
                var next = 0
                @MainActor func add() {
                    guard next < missing.count else { return }
                    let song = missing[next]
                    next += 1
                    searching.append(song.title)
                    group.addTask {
                        let query = LyricsSearch.Query(title: song.title, artist: song.artist, album: song.album, duration: song.duration > 0 ? song.duration : nil)
                        let best = await LyricsSearch.search(query).first { $0.score >= Self.minimumScore }
                        return (song, best)
                    }
                }
                // Two at a time: more and the sources start refusing.
                for _ in 0..<2 { add() }
                for await (song, best) in group {
                    if let index = searching.firstIndex(of: song.title) { searching.remove(at: index) }
                    results.insert(Result(title: song.title, artist: song.artist, source: best?.source), at: 0)
                    if let best {
                        player.importCandidate(best, for: song)
                        matched += 1
                    }
                    done += 1
                    add()
                }
            }
            isRunning = false
        }
    }
}

/// The matcher's button, then its progress.
struct AutoMatchLyricsButton: View {
    let songs: [Song]
    @EnvironmentObject private var playerVM: PlayerViewModel
    @EnvironmentObject private var libraryVM: LibraryViewModel
    @ObservedObject private var matcher = LyricsAutoMatcher.shared
    @State private var showsArtists = false

    /// The selected artists' songs, as Search groups them (features included).
    private var targetSongs: [Song] {
        guard !matcher.artists.isEmpty else { return songs }
        let ids = Set(libraryVM.artists.filter { matcher.artists.contains($0.name) }.flatMap(\.songs).map(\.id))
        return songs.filter { ids.contains($0.id) }
    }

    /// Artists left with nothing to find drop out of the selection.
    private func pruneArtists() {
        let listed = Set(libraryVM.artists.filter { $0.songs.contains(where: LyricsAutoMatcher.lacksLyrics) }.map(\.name))
        matcher.artists.formIntersection(listed)
    }

    var body: some View {
        Group {
            if matcher.isRunning {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: matcher.progress)
                    Text("Matching \(matcher.done)/\(matcher.total) · \(matcher.matched) found")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    ForEach(matcher.searching, id: \.self) { title in
                        Label(title, systemImage: "magnifyingglass")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    resultsList
                }
                .transition(.blurReplace)
            } else {
                if !matcher.results.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Done · \(matcher.matched) of \(matcher.total) found", systemImage: "checkmark.circle.fill")
                            .font(.subheadline.weight(.semibold))
                        resultsList
                    }
                    .transition(.blurReplace)
                }
                HStack(spacing: 10) {
                    Button {
                        withAnimation(.smooth) { matcher.run(targetSongs, player: playerVM) }
                    } label: {
                        Label(matcher.artists.isEmpty ? "Find Missing Lyrics" : "Find for \(matcher.artists.count) Artists", systemImage: "wand.and.sparkles")
                            .frame(maxWidth: .infinity)
                            // The tint is pale on dark: white text washes out on it.
                            .foregroundStyle(Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.08, alpha: 1) : .white }))
                    }
                    .buttonStyle(.glassProminent)
                    Button {
                        showsArtists = true
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .buttonStyle(.glass)
                    .accessibilityLabel("Choose Artists")
                }
                .controlSize(.large)
                .transition(.blurReplace)
            }
        }
        .animation(.smooth, value: matcher.isRunning)
        .animation(.smooth, value: matcher.done)
        .sheet(isPresented: $showsArtists) {
            AutoMatchArtistsSheet()
        }
        .onChange(of: matcher.isRunning) { _, running in if !running { pruneArtists() } }
        .sensoryFeedback(.success, trigger: matcher.isRunning) { was, now in was && !now }
    }

    /// Each song's outcome, newest first.
    private var resultsList: some View {
        ForEach(matcher.results.prefix(8)) { result in
            HStack(spacing: 8) {
                Image(systemName: result.source == nil ? "xmark.circle" : "checkmark.circle")
                    .foregroundStyle(.secondary)
                Text(result.title).lineLimit(1)
                Spacer(minLength: 8)
                Text(result.source ?? String(localized: "No match"))
                    .foregroundStyle(.secondary)
            }
            .font(.footnote)
            .transition(.opacity)
        }
    }
}

/// Which artists the matcher looks for: none picked is all of them.
private struct AutoMatchArtistsSheet: View {
    @EnvironmentObject private var libraryVM: LibraryViewModel
    @ObservedObject private var matcher = LyricsAutoMatcher.shared
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var artists: [(name: String, songs: [Song], missing: Int)] {
        // The artists Search shows.
        libraryVM.artists
            .compactMap { artist in
                let missing = artist.songs.filter(LyricsAutoMatcher.lacksLyrics).count
                return missing > 0 ? (name: artist.name, songs: artist.songs, missing: missing) : nil
            }
            .filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        let shown = artists
        let allShownSelected = !shown.isEmpty && shown.allSatisfy { matcher.artists.contains($0.name) }
        NavigationStack {
            List(shown, id: \.name) { artist in
                Button {
                    if matcher.artists.contains(artist.name) {
                        matcher.artists.remove(artist.name)
                    } else {
                        matcher.artists.insert(artist.name)
                    }
                } label: {
                    HStack(spacing: 12) {
                        ArtistAvatarView(artistName: artist.name, songs: artist.songs, size: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(artist.name)
                            Text("\(artist.missing) without lyrics")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: matcher.artists.contains(artist.name) ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(matcher.artists.contains(artist.name) ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                    }
                    .foregroundStyle(.primary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .searchable(text: $query)
            .onAppear {
                // Artists whose songs all have lyrics now aren't listed.
                let listed = Set(artists.map(\.name))
                matcher.artists.formIntersection(listed)
            }
            .navigationTitle(matcher.artists.isEmpty ? "All Artists" : "\(matcher.artists.count) Selected")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(allShownSelected ? "Deselect All" : "Select All") {
                        if allShownSelected {
                            shown.forEach { matcher.artists.remove($0.name) }
                        } else {
                            shown.forEach { matcher.artists.insert($0.name) }
                        }
                    }
                    .disabled(shown.isEmpty)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
    }
}
