import Foundation

/// Where a song's singing really starts and where its outro begins, set
/// by holding a line: a transcript that wrote "Music" over a long intro
/// starts at the first sung word, and an artist talking after the song is
/// kept out of the games (or hidden, the song ending there).
///
/// The LRC file is never changed: the marks are applied to the lyrics as
/// they load, so removing one gives the lyrics back as they were.
struct LyricsMarks: Codable, Equatable, Sendable {
    struct Mark: Codable, Equatable, Sendable {
        /// The line's time and text in the file, to find it again.
        var lineTime: TimeInterval
        var lineText: String
        /// The marked word's index in the line.
        var word: Int
    }

    var start: Mark?
    var outro: Mark?
    /// The outro hidden, and the next song played when it's reached.
    var skipsOutro = false

    var isEmpty: Bool { start == nil && outro == nil }

    // MARK: Store

    static let didChangeNotification = Notification.Name("LyricsMarksDidChange")

    private static var folder: URL {
        LibraryService.dataDirectory.appendingPathComponent("LyricsMarks", isDirectory: true)
    }

    private static func url(for songID: UUID) -> URL {
        folder.appendingPathComponent("\(songID.uuidString).json")
    }

    static func load(for songID: UUID) -> LyricsMarks {
        guard let data = try? Data(contentsOf: url(for: songID)),
              let marks = try? JSONDecoder().decode(LyricsMarks.self, from: data) else { return LyricsMarks() }
        return marks
    }

    static func save(_ marks: LyricsMarks, for songID: UUID) {
        if marks.isEmpty {
            try? FileManager.default.removeItem(at: url(for: songID))
        } else {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? JSONEncoder().encode(marks).write(to: url(for: songID), options: .atomic)
        }
        NotificationCenter.default.post(name: didChangeNotification, object: songID)
    }

    /// The stored file as is, for iCloud Sync.
    static func rawData(for songID: UUID) -> Data? {
        try? Data(contentsOf: url(for: songID))
    }

    /// Another device's file, or none.
    static func setRawData(_ data: Data?, for songID: UUID) {
        if let data {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? data.write(to: url(for: songID), options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: url(for: songID))
        }
        NotificationCenter.default.post(name: didChangeNotification, object: songID)
    }

    // MARK: Applying

    /// The lyrics as shown and played: before the start and (when skipped)
    /// the outro left out, the marked lines split at their word.
    struct Applied: Sendable {
        var lyrics: LRCLyrics
        var timings: [LyricsLine.ID: [WordTiming]]
        /// Shown line → the file's line it comes from.
        var rawLines: [LyricsLine.ID: LyricsLine.ID]
        /// The outro's lines (kept out of the games).
        var outroLines: Set<LyricsLine.ID>
        /// When the outro starts, on the lyrics' clock.
        var outroTime: TimeInterval?
        var skipsOutro: Bool
    }

    /// The index of the file's line a mark points to.
    func lineIndex(of mark: Mark, in lyrics: LRCLyrics) -> Int? {
        let lines = lyrics.lines
        if let exact = lines.firstIndex(where: { abs($0.time - mark.lineTime) < 0.02 && $0.text == mark.lineText }) {
            return exact
        }
        // The line corrected or moved a little: the same text nearest, or
        // the line at the same time.
        let sameText = lines.indices.filter { lines[$0].text == mark.lineText }
        if let nearest = sameText.min(by: { abs(lines[$0].time - mark.lineTime) < abs(lines[$1].time - mark.lineTime) }) {
            return nearest
        }
        return lines.firstIndex { abs($0.time - mark.lineTime) < 0.02 && !$0.isInstrumentalGap }
    }

    func apply(to lyrics: LRCLyrics, timings: [LyricsLine.ID: [WordTiming]], forGames: Bool = false) -> Applied {
        var applied = Applied(lyrics: lyrics, timings: timings, rawLines: [:], outroLines: [], outroTime: nil, skipsOutro: skipsOutro)
        for line in lyrics.lines { applied.rawLines[line.id] = line.id }
        guard !isEmpty, lyrics.hasTimedLyrics else { return applied }

        struct Row {
            var line: LyricsLine
            var timings: [WordTiming]?
            var raw: LyricsLine.ID
            var isOutro = false
        }
        var rows = lyrics.lines.map { Row(line: $0, timings: timings[$0.id], raw: $0.id) }
        let startIndex = start.flatMap { lineIndex(of: $0, in: lyrics) }
        var outroIndex = outro.flatMap { lineIndex(of: $0, in: lyrics) }
        if let startIndex, let index = outroIndex, index < startIndex { outroIndex = nil }

        // The outro first (it may split a line the start also cuts).
        if let index = outroIndex, let mark = outro {
            let row = rows[index]
            let ranges = LyricWords.ranges(in: row.line.text)
            let word = min(max(mark.word, 0), max(ranges.count - 1, 0))
            if word > 0, word < ranges.count {
                let head = String(row.line.text[..<ranges[word].lowerBound]).trimmingCharacters(in: .whitespaces)
                let tail = String(row.line.text[ranges[word].lowerBound...])
                let next = index + 1 < rows.count ? rows[index + 1].line.time : row.line.time + 4
                let splitTime = row.timings.flatMap { $0.indices.contains(word) ? $0[word].start : nil }
                    ?? row.line.time + (next - row.line.time) * Double(word) / Double(ranges.count)
                let first = Row(line: LyricsLine(time: row.line.time, text: head), timings: row.timings.map { Array($0.prefix(word)) }, raw: row.raw)
                let second = Row(line: LyricsLine(time: splitTime, text: tail), timings: row.timings.map { Array($0.dropFirst(word)) }, raw: row.raw, isOutro: true)
                rows.replaceSubrange(index...index, with: [first, second])
                outroIndex = index + 1
            }
            if let index = outroIndex {
                for i in index..<rows.count { rows[i].isOutro = true }
                applied.outroTime = rows[index].line.time
            }
        }

        if let index = startIndex, let mark = start {
            let row = rows[index]
            let ranges = LyricWords.ranges(in: row.line.text)
            let word = min(max(mark.word, 0), max(ranges.count - 1, 0))
            var line = row.line
            var lineTimings = row.timings
            if word > 0, word < ranges.count {
                let text = String(row.line.text[ranges[word].lowerBound...])
                let time = row.timings.flatMap { $0.indices.contains(word) ? $0[word].start : nil } ?? row.line.time
                line = LyricsLine(time: time, text: text)
                lineTimings = row.timings.map { Array($0.dropFirst(word)) }
            }
            rows.replaceSubrange(0...index, with: [Row(line: line, timings: lineTimings, raw: row.raw, isOutro: row.isOutro)])
        }

        // Hidden outro: an empty line ends the last sung one there.
        if skipsOutro || forGames, let first = rows.firstIndex(where: \.isOutro) {
            let time = rows[first].line.time
            rows.removeSubrange(first...)
            if !forGames { rows.append(Row(line: LyricsLine(time: time, text: ""), timings: nil, raw: rows.last?.raw ?? UUID())) }
        }

        var result = lyrics
        result.lines = rows.map(\.line)
        applied.lyrics = result
        applied.timings = [:]
        applied.rawLines = [:]
        applied.outroLines = []
        for row in rows {
            if let timings = row.timings, !timings.isEmpty { applied.timings[row.line.id] = timings }
            applied.rawLines[row.line.id] = row.raw
            if row.isOutro { applied.outroLines.insert(row.line.id) }
        }
        return applied
    }

    /// The lyrics a game asks about: from the real start, the outro left out.
    static func forGames(_ lyrics: LRCLyrics, songID: UUID) -> (lyrics: LRCLyrics, timings: [LyricsLine.ID: [WordTiming]]) {
        let timings = WordSyncStore.load(for: songID, lyrics: lyrics)
        let marks = load(for: songID)
        guard !marks.isEmpty else { return (lyrics, timings) }
        let applied = marks.apply(to: lyrics, timings: timings, forGames: true)
        return (applied.lyrics, applied.timings)
    }
}
