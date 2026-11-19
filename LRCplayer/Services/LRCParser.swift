import Foundation

enum LRCParser {
    // Compiled once: parsing happens on every track change.
    private static let metadataRegex = try! NSRegularExpression(
        pattern: #"^\[([A-Za-z]+):(.*)\]$"#
    )
    /// `[mm:ss]`, `[mm:ss.xx]`, `[mm:ss.xxx]` and the `[mm:ss:xx]` variant.
    private static let timeTagRegex = try! NSRegularExpression(
        pattern: #"\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]"#
    )
    /// Enhanced-LRC word timings (`<mm:ss.xx>`), stripped from the display text.
    private static let wordTimingRegex = try! NSRegularExpression(
        pattern: #"<\d{1,3}:\d{1,2}(?:[.:]\d{1,3})?>"#
    )

    static func parse(url: URL) -> LRCLyrics? {
        guard let data = try? Data(contentsOf: url), let content = decode(data) else { return nil }
        return parse(content: content)
    }

    /// LRC files in the wild are UTF-8, UTF-16 (with BOM) or Windows-1252.
    static func decode(_ data: Data) -> String? {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16)
        }
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        return String(data: data, encoding: .windowsCP1252) ?? String(data: data, encoding: .isoLatin1)
    }

    static func parse(content: String) -> LRCLyrics {
        var lyricsLines: [LyricsLine] = []
        var metadata: [String: String] = [:]
        var plainLines: [String] = []

        let normalized = content.hasPrefix("\u{FEFF}") ? String(content.dropFirst()) : content

        for rawLine in normalized.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let fullRange = NSRange(line.startIndex..., in: line)

            let tags = timeTagRegex.matches(in: line, range: fullRange)
            guard !tags.isEmpty else {
                if let meta = metadataRegex.firstMatch(in: line, range: fullRange),
                   let keyRange = Range(meta.range(at: 1), in: line),
                   let valueRange = Range(meta.range(at: 2), in: line) {
                    metadata[line[keyRange].lowercased()] = line[valueRange].trimmingCharacters(in: .whitespaces)
                } else {
                    plainLines.append(line)
                }
                continue
            }

            // Text follows the last leading time tag; a line may carry several
            // tags (repeated choruses) that all share the same text.
            guard let lastTagRange = Range(tags[tags.count - 1].range, in: line) else { continue }
            var text = String(line[lastTagRange.upperBound...])
            text = wordTimingRegex.stringByReplacingMatches(
                in: text,
                range: NSRange(text.startIndex..., in: text),
                withTemplate: ""
            )
            text = text.trimmingCharacters(in: .whitespaces)

            for tag in tags {
                guard let minutesRange = Range(tag.range(at: 1), in: line),
                      let secondsRange = Range(tag.range(at: 2), in: line),
                      let minutes = Int(line[minutesRange]),
                      let seconds = Int(line[secondsRange]) else { continue }
                var time = TimeInterval(minutes * 60 + seconds)
                if let fractionRange = Range(tag.range(at: 3), in: line) {
                    let fraction = line[fractionRange]
                    if let value = Double(fraction) {
                        time += value / pow(10, Double(fraction.count))
                    }
                }
                lyricsLines.append(LyricsLine(time: time, text: text))
            }
        }

        lyricsLines.sort { $0.time < $1.time }
        // Collapse runs of instrumental markers and drop a leading one: they only
        // matter as the end of a sung line.
        var cleaned: [LyricsLine] = []
        cleaned.reserveCapacity(lyricsLines.count)
        for line in lyricsLines {
            if line.isInstrumentalGap {
                guard let last = cleaned.last, !last.isInstrumentalGap else { continue }
            }
            cleaned.append(line)
        }
        if cleaned.last?.isInstrumentalGap == true {
            cleaned.removeLast()
        }

        return LRCLyrics(lines: cleaned, metadata: metadata, plainText: plainLines.joined(separator: "\n"))
    }

    static func findLRC(for songURL: URL) -> URL? {
        guard songURL.isFileURL else { return nil }
        let fileName = songURL.deletingPathExtension().lastPathComponent
        let fileManager = FileManager.default
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        let directories = [
            songURL.deletingLastPathComponent(),
            documents.appendingPathComponent("Lyrics", isDirectory: true)
        ]

        for directory in directories {
            for ext in ["lrc", "LRC", "txt"] {
                let candidate = directory.appendingPathComponent(fileName).appendingPathExtension(ext)
                if fileManager.fileExists(atPath: candidate.path) {
                    return candidate
                }
            }
        }
        return nil
    }
}
