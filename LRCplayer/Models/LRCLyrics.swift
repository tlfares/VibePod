import Foundation

struct LyricsLine: Identifiable, Equatable, Sendable {
    let id = UUID()
    let time: TimeInterval
    let text: String

    /// Empty timed lines mark instrumental breaks: they end the previous line
    /// instead of leaving it highlighted through a solo.
    var isInstrumentalGap: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var formattedTime: String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        let centiseconds = Int((time - floor(time)) * 100)
        return String(format: "%02d:%02d.%02d", minutes, seconds, centiseconds)
    }

    static func == (lhs: LyricsLine, rhs: LyricsLine) -> Bool {
        lhs.id == rhs.id
    }
}

struct LRCLyrics: Sendable {
    var lines: [LyricsLine]
    var metadata: [String: String]
    var plainText: String
    var hasTimedLyrics: Bool { lines.contains { !$0.isInstrumentalGap } }
    var hasPlainText: Bool { !plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    /// `[offset:]` in seconds. Positive values make lyrics appear earlier.
    var offset: TimeInterval = 0

    init(lines: [LyricsLine] = [], metadata: [String: String] = [:], plainText: String = "") {
        self.lines = lines
        self.metadata = metadata
        self.plainText = plainText

        if let offsetString = metadata["offset"],
           let milliseconds = Double(offsetString.trimmingCharacters(in: .whitespaces)) {
            offset = milliseconds / 1000.0
        }
    }

    func line(at time: TimeInterval) -> LyricsLine? {
        currentIndex(at: time).map { lines[$0] }
    }

    /// Index of the last line whose timestamp is <= `time` (binary search; this
    /// runs on every playback tick).
    func currentIndex(at time: TimeInterval) -> Int? {
        let adjustedTime = time + offset
        var low = 0
        var high = lines.count
        while low < high {
            let mid = (low + high) / 2
            if lines[mid].time <= adjustedTime {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low == 0 ? nil : low - 1
    }
}

extension LRCLyrics {
    /// Written by `LyricsGenerator`, which signs its files.
    var isGenerated: Bool {
        metadata["by"]?.hasPrefix("LRCplayer AI") == true
    }
}
