import AVFoundation
import Combine
import Foundation

/// Writes synced lyrics for a song that has none anywhere, from its own
/// audio: Voxtral transcribes the vocals with a time for every word, then a
/// Mistral chat model groups the words into lines. Beta: songs with loud
/// mixes or several singers come out rough, so the result is easy to delete.
@MainActor
final class LyricsGenerator: ObservableObject {
    static let shared = LyricsGenerator()

    enum Stage: Equatable {
        case preparing
        case transcribing(part: Int, of: Int)
        case syncing

        var title: String {
            switch self {
            case .preparing: String(localized: "Preparing the audio…")
            case let .transcribing(part, count) where count > 1 && part > 0: String(localized: "Transcribing the vocals… \(part)/\(count)")
            case .transcribing: String(localized: "Transcribing the vocals…")
            case .syncing: String(localized: "Syncing the lines…")
            }
        }
    }

    enum GenerationError: LocalizedError {
        case unavailable
        case unreadableAudio
        case noVocals

        var errorDescription: String? {
            switch self {
            case .unavailable: String(localized: "Turn on AI Features and add a \(AIProvider.current.name) API key in Settings › Tools.")
            case .unreadableAudio: String(localized: "This song's audio couldn't be read.")
            case .noVocals: String(localized: "No vocals were heard in this song.")
            }
        }
    }

    /// Songs being worked on, by song ID.
    @Published private(set) var stages: [UUID: Stage] = [:]
    /// The last failure per song, until it's shown.
    @Published private(set) var failures: [UUID: String] = [:]

    /// Generated lyrics live apart from the user's own files, which is how
    /// they're told apart (and deleted for good when removed).
    static let folderName = "Generated"

    /// Times every word from the same transcription, so no second upload
    /// is needed to sync word by word.
    static let wordByWordKey = "generateLyricsWordByWord"

    static var wordByWord: Bool {
        UserDefaults.standard.object(forKey: wordByWordKey) as? Bool ?? true
    }

    /// Unsynced lyrics an AI sync replaced, by song ID.
    private static let originalsKey = "aiSyncedOriginalLyrics"

    static func setOriginal(_ path: String?, for songID: UUID) {
        var originals = UserDefaults.standard.dictionary(forKey: originalsKey) as? [String: String] ?? [:]
        originals[songID.uuidString] = path
        UserDefaults.standard.set(originals, forKey: originalsKey)
    }

    static func original(for songID: UUID) -> String? {
        (UserDefaults.standard.dictionary(forKey: originalsKey) as? [String: String])?[songID.uuidString]
    }

    /// Where imported lyrics came from (LRCLIB, …), by stored path: an AI
    /// sync of them names it under the lyrics.
    private static let sourcesKey = "lyricsSourcesByPath"

    static func setSource(_ name: String?, forStoredPath path: String) {
        var sources = UserDefaults.standard.dictionary(forKey: sourcesKey) as? [String: String] ?? [:]
        sources[path] = name
        UserDefaults.standard.set(sources, forKey: sourcesKey)
    }

    static func source(forStoredPath path: String?) -> String? {
        guard let path else { return nil }
        return (UserDefaults.standard.dictionary(forKey: sourcesKey) as? [String: String])?[path]
    }

    /// The source of the lyrics an AI sync starts from: the file itself,
    /// or for lyrics already synced, the ones they replaced.
    static func textSource(for song: Song) -> String? {
        if isGenerated(storedPath: song.lrcFilePath) { return source(forStoredPath: original(for: song.id)) }
        return source(forStoredPath: song.lrcFilePath)
    }

    static func isGenerated(storedPath: String?) -> Bool {
        guard let storedPath else { return false }
        return storedPath.contains("Lyrics/\(folderName)/")
    }

    func clearFailure(for songID: UUID) {
        failures[songID] = nil
    }

    func generate(for song: Song, in library: LibraryService) {
        guard stages[song.id] == nil else { return }
        failures[song.id] = nil
        guard AIFeatures.isAvailable, let key = AIFeatures.apiKey else {
            failures[song.id] = GenerationError.unavailable.localizedDescription
            return
        }
        stages[song.id] = .preparing
        Task {
            do {
                guard await SubsonicDownloads.shared.ensureLocal(song) else {
                    failures[song.id] = String(localized: "Couldn't download “\(song.title)”")
                    stages[song.id] = nil
                    return
                }
                let chunks = try await Self.audioChunks(for: song)
                defer { chunks.filter(\.isTemporary).forEach { try? FileManager.default.removeItem(at: $0.url) } }

                stages[song.id] = .transcribing(part: 0, of: chunks.count)
                let transcribed = try await Self.transcribe(chunks, key: key) { done in
                    self.stages[song.id] = .transcribing(part: done, of: chunks.count)
                }
                let words = Self.sungWords(in: transcribed)
                guard words.count >= 3 else { throw GenerationError.noVocals }

                stages[song.id] = .syncing
                let starts: [Int]
                do {
                    starts = try await MistralClient.lineStarts(of: words, title: song.title, artist: song.artist, key: key)
                } catch MistralError.invalidKey {
                    throw MistralError.invalidKey
                } catch {
                    // Only a hint: punctuation and breaths make the lines.
                    starts = []
                }

                let lines = Self.lines(from: words, starts: starts)
                let content = Self.lrc(lines: lines, for: song)
                try save(content, for: song, in: library)
                LyricsSummaries.shared.summarizeSoon(library.song(withID: song.id) ?? song)
                if Self.wordByWord {
                    let lyrics = LRCParser.parse(content: content)
                    let heard = words.map { TimedWord(text: $0.text, start: $0.start + lyrics.offset, end: $0.end + lyrics.offset) }
                    if let timings = try? await Task.detached(priority: .userInitiated, operation: {
                        try WordSyncGenerator.timings(for: lyrics.lines, heard: heard)
                    }).value {
                        try? WordSyncStore.save(timings, for: song.id, lyrics: lyrics)
                    }
                }
            } catch {
                failures[song.id] = error.localizedDescription
            }
            stages[song.id] = nil
        }
    }

    func save(_ content: String, for song: Song, in library: LibraryService) throws {
        let folder = library.lyricsDirectory.appendingPathComponent(Self.folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = library.ownLyricsURL(for: song, in: folder)
        try content.write(to: destination, atomically: true, encoding: .utf8)
        library.setLyricsPath(library.storedLyricsPath(for: destination.path), for: song.id)
    }

    // MARK: Audio

    /// A stretch of the song sent on its own. Neighbouring stretches overlap;
    /// each keeps the words that start in its own half of the overlaps.
    struct AudioChunk {
        var url: URL
        var isTemporary: Bool
        /// Where the stretch starts in the song: its word times add to it.
        var offset: TimeInterval
        var keepFrom: TimeInterval
        var keepUntil: TimeInterval

        /// The words this stretch adds after `kept`. Both stretches hear the
        /// words around the cut, with slightly different times: a word is
        /// taken a little before `keepFrom` if the previous stretch missed
        /// it, and dropped if the previous stretch already has it.
        func keptWords(from words: [TimedWord], after kept: [TimedWord]) -> [TimedWord] {
            let tolerance: TimeInterval = 0.8
            // The previous stretch's last words, each matched at most once
            // ("in the distance" keeps its second "the").
            var unmatched = Array(kept.suffix(4))
            var added: [TimedWord] = []
            for word in words {
                let shifted = TimedWord(text: word.text, start: word.start + offset, end: word.end + offset)
                guard shifted.start >= keepFrom - tolerance, shifted.start < keepUntil else { continue }
                if shifted.start < keepFrom + tolerance {
                    let bare = LyricsGenerator.bareWord(shifted)
                    if let match = unmatched.firstIndex(where: { LyricsGenerator.bareWord($0) == bare && abs($0.start - shifted.start) < tolerance }) {
                        unmatched.removeSubrange(...match)
                        continue
                    }
                }
                if shifted.start < keepFrom, let last = kept.last, shifted.start <= last.start { continue }
                added.append(shifted)
            }
            return added
        }
    }

    /// Every stretch is transcribed at once, a beat apart so a free key's
    /// rate limit isn't hit; the words are put back together in order.
    /// `progress` gets how many stretches are done.
    static func transcribe(_ chunks: [AudioChunk], key: String, progress: @escaping @MainActor (Int) -> Void) async throws -> [TimedWord] {
        let results = try await withThrowingTaskGroup(of: (Int, [TimedWord]).self) { group in
            for (index, chunk) in chunks.enumerated() {
                let url = chunk.url
                let speechmatics = AIFeatures.speechmaticsKey
                group.addTask {
                    if let speechmatics {
                        return (index, try await Speechmatics.transcribe(audio: url, key: speechmatics))
                    }
                    try await Task.sleep(for: .seconds(Double(index) * AIProvider.current.spacing))
                    return (index, try await MistralClient.transcribe(audio: url, key: key))
                }
            }
            var heard: [[TimedWord]] = Array(repeating: [], count: chunks.count)
            var done = 0
            for try await (index, words) in group {
                heard[index] = words
                done += 1
                progress(done)
            }
            return heard
        }
        var transcribed: [TimedWord] = []
        for (chunk, words) in zip(chunks, results) {
            transcribed += chunk.keptWords(from: words, after: transcribed)
        }
        return transcribed
    }

    /// The audio to transcribe. With Groq and the Sing Along model, only the
    /// vocals are sent: Whisper places words far better without the band
    /// (a held note over the music is what it hands to the next word).
    /// Speechmatics gets the song itself: separating the vocals on the phone
    /// first made the wait far too long.
    static func audioChunks(for song: Song) async throws -> [AudioChunk] {
        let url = song.playableFileURL
        if AIProvider.current == .groq, !Speechmatics.isOn, SingAlongModel.isSupported,
           FileManager.default.fileExists(atPath: SingAlongModel.modelURL.path) {
            let id = song.id
            let vocals = await Task.detached(priority: .userInitiated) {
                await Self.vocalsFile(from: url, id: id)
            }.value
            if let vocals {
                var chunks = try await audioChunks(at: vocals, duration: song.duration)
                if chunks.contains(where: { $0.url == vocals }) {
                    for index in chunks.indices where chunks[index].url == vocals { chunks[index].isTemporary = true }
                } else {
                    try? FileManager.default.removeItem(at: vocals)
                }
                return chunks
            }
        }
        return try await audioChunks(at: url, duration: song.duration)
    }

    /// The song's vocals alone (separated now, or kept from Sing Along), as
    /// a mono AAC file; nil if they can't be had.
    nonisolated private static func vocalsFile(from url: URL, id: UUID) async -> URL? {
        guard let track = await StageTrack.load(url),
              await VocalSeparator.separateAll(track, id: id, progress: { _ in }),
              let format = AVAudioFormat(standardFormatWithSampleRate: StageTrack.sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(track.count)),
              let mono = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = AVAudioFrameCount(track.count)
        for i in 0..<track.count { mono[i] = (track.vocalsLeft[i] + track.vocalsRight[i]) / 2 }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: StageTrack.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 96_000
        ]
        do {
            // Written and closed before it's read.
            try autoreleasepool {
                let file = try AVAudioFile(forWriting: output, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
                try file.write(from: buffer)
            }
            return output
        } catch {
            try? FileManager.default.removeItem(at: output)
            return nil
        }
    }

    /// Voxtral sometimes stops transcribing well before the end of a whole
    /// song, so songs are sent a minute at a time. Whisper (Groq) takes a
    /// whole song: one request, and no words lost at the cuts. Ten minutes
    /// of AAC stays under Groq's 25 MB.
    nonisolated private static var chunkLength: TimeInterval {
        if Speechmatics.isOn { return 3600 }
        return AIProvider.current == .groq ? 600 : 60
    }
    nonisolated private static let chunkOverlap: TimeInterval = 4

    /// A short compressed file goes as it is; anything else is cut into
    /// AAC stretches (which also covers FLAC, WAV and music library items).
    nonisolated static func audioChunks(at url: URL, duration knownDuration: TimeInterval) async throws -> [AudioChunk] {
        // Exact timing: without it a VBR MP3's stretches start a little off
        // where they were asked to, and so would every line after the first.
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        var duration = knownDuration
        if duration <= 0 {
            duration = (try? await asset.load(.duration).seconds) ?? 0
        }
        guard duration > 0 else { throw GenerationError.unreadableAudio }

        if duration <= chunkLength + chunkOverlap,
           url.isFileURL,
           ["m4a", "mp3", "aac", "mp4"].contains(url.pathExtension.lowercased()),
           let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 20_000_000 {
            return [AudioChunk(url: url, isTemporary: false, offset: 0, keepFrom: 0, keepUntil: .infinity)]
        }

        var chunks: [AudioChunk] = []
        var start: TimeInterval = 0
        repeat {
            let end = min(start + chunkLength + chunkOverlap, duration)
            let isLast = end >= duration - 1
            let output = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).m4a")
            do {
                guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
                    throw GenerationError.unreadableAudio
                }
                session.timeRange = CMTimeRange(
                    start: CMTime(seconds: start, preferredTimescale: 600),
                    end: CMTime(seconds: end, preferredTimescale: 600)
                )
                try await session.export(to: output, as: .m4a)
            } catch {
                chunks.forEach { try? FileManager.default.removeItem(at: $0.url) }
                throw GenerationError.unreadableAudio
            }
            chunks.append(AudioChunk(
                url: output,
                isTemporary: true,
                offset: start,
                keepFrom: start == 0 ? 0 : start + chunkOverlap / 2,
                keepUntil: isLast ? .infinity : end - chunkOverlap / 2
            ))
            if isLast { break }
            start += chunkLength
        } while true
        return chunks
    }

    // MARK: Lines

    /// Drops what speech recognition writes for music: "[Music]", "♪", "(instrumental)".
    nonisolated static func sungWords(in words: [TimedWord]) -> [TimedWord] {
        words.filter { word in
            let text = word.text
            if text.hasPrefix("[") || text.hasPrefix("(") && text.hasSuffix(")") { return false }
            return text.unicodeScalars.contains { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) }
        }
    }

    struct Line: Equatable {
        var text: String
        var start: TimeInterval
        var end: TimeInterval
    }

    /// The song's words as verses: a line ends where a sentence ends or the
    /// singer breathes, lines too long are cut at their best point, and
    /// scraps are joined to a neighbour. `hints` (a model's proposed line
    /// starts, as word indices) only tip the choice of a cut.
    nonisolated static func lines(from words: [TimedWord], starts hints: [Int]) -> [Line] {
        let hinted = Set(hints.filter { words.indices.contains($0) }.map { words[$0].start })
        var groups = splitAtBreaks(words)
        groups = groups.flatMap { splitLongLine($0, hinted: hinted) }
        groups = carryLeadingWordsForward(groups)
        groups = mergeFragments(groups, hinted: hinted)
        groups = groups.flatMap { splitLongLine($0, hinted: hinted) }
        groups = groups.flatMap(splitAtComma)

        return groups.compactMap { group in
            guard let first = group.first, let last = group.last else { return nil }
            var text = group.map(\.text).joined(separator: " ")
            // Lyrics sites don't end lines with commas or periods.
            while let character = text.last, ",.;:".contains(character) { text.removeLast() }
            if let initial = text.first, initial.isLowercase { text = initial.uppercased() + text.dropFirst() }
            return Line(text: text, start: first.start, end: last.end)
        }
    }

    /// A lyric line no longer than this reads at a glance.
    nonisolated static let maxLineWords = 8
    nonisolated static let maxLineLength = 42
    /// Shorter than this, a line is a scrap of the one next to it.
    nonisolated static let minLineWords = 3
    /// Words sung closer together than this belong to the same breath.
    nonisolated static let tightGap: TimeInterval = 0.35

    /// Words that don't end a line: the phrase goes on after them.
    nonisolated private static let continuingWords: Set<String> = [
        "the", "a", "an", "to", "of", "and", "but", "or", "nor", "at", "for", "with", "from", "by", "into", "onto",
        "my", "your", "his", "her", "our", "their", "its", "this", "these", "those", "every", "each",
        "i", "i'm", "i'll", "we", "they", "he", "she", "you're", "we're", "if", "when", "than", "because", "that", "which", "who", "where",
        "till", "until", "while",
        "le", "la", "les", "l'", "un", "une", "des", "de", "du", "d'", "et", "ou", "mais", "donc", "car", "à", "au", "aux",
        "en", "dans", "sur", "sous", "pour", "par", "avec", "sans", "je", "j'", "tu", "il", "elle", "on", "nous", "vous", "ils", "elles",
        "mon", "ma", "mes", "ton", "ta", "tes", "son", "sa", "ses", "notre", "votre", "leur", "leurs", "ce", "cet", "cette", "ces",
        "que", "qu'", "qui", "quand", "si", "comme", "est"
    ]

    /// Rather not cut after these either, though a line may end on them.
    nonisolated private static let weakEndings: Set<String> = [
        "is", "are", "was", "were", "be", "all", "behind", "above", "below", "under", "over", "through", "across",
        "about", "without", "like", "est", "sont", "tout", "devant", "derrière", "contre", "vers", "chez"
    ]
    /// Words that hang off the one before rather than open a line.
    nonisolated private static let poorStarts: Set<String> = ["me", "him", "us", "them", "moi", "toi", "lui", "eux"]

    nonisolated static func bareWord(_ word: TimedWord) -> String {
        word.text.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
    }

    nonisolated private static func endsSentence(_ word: TimedWord) -> Bool {
        word.text.last.map { ".!?".contains($0) } ?? false
    }

    nonisolated private static func fits(_ group: [TimedWord]) -> Bool {
        group.count <= maxLineWords && group.map(\.text).joined(separator: " ").count <= maxLineLength
    }

    /// Silence this long always ends a line, even mid-sentence.
    nonisolated static let breathGap: TimeInterval = 1.0

    /// Lines end where a sentence ends or the singer stops for a breath.
    nonisolated static func splitAtBreaks(_ words: [TimedWord]) -> [[TimedWord]] {
        var result: [[TimedWord]] = [[]]
        for (index, word) in words.enumerated() {
            result[result.count - 1].append(word)
            guard index < words.count - 1 else { break }
            if endsSentence(word) || words[index + 1].start - word.end >= breathGap { result.append([]) }
        }
        return result.filter { !$0.isEmpty }
    }

    /// "Hold on, hold on, we will carry on": a longish line with a comma
    /// near its middle reads as two.
    nonisolated static func splitAtComma(_ group: [TimedWord]) -> [[TimedWord]] {
        guard group.count >= 7 else { return [group] }
        let cuts = (3...(group.count - 3)).filter { group[$0 - 1].text.hasSuffix(",") }
        guard let cut = cuts.min(by: { abs(Double($0) - Double(group.count) / 2) < abs(Double($1) - Double(group.count) / 2) }) else { return [group] }
        return [Array(group[..<cut]), Array(group[cut...])]
    }

    /// "I counted every / footstep": a line never ends on a word that leads
    /// into the next one when they're sung in one breath; it moves down.
    nonisolated static func carryLeadingWordsForward(_ groups: [[TimedWord]]) -> [[TimedWord]] {
        var groups = groups
        for index in groups.indices.dropLast() {
            while groups[index].count > 1,
                  let last = groups[index].last, let next = groups[index + 1].first,
                  last.text.last.map({ $0.isLetter || $0 == "'" }) ?? false,
                  continuingWords.contains(bareWord(last)),
                  next.start - last.end < tightGap {
                groups[index + 1].insert(groups[index].removeLast(), at: 0)
            }
        }
        return groups.filter { !$0.isEmpty }
    }

    /// Joins lines of one or two words to a neighbour: a sentence's last
    /// words to the line before, anything else to whichever neighbour it's
    /// sung closest to, as long as the result still reads at a glance.
    nonisolated static func mergeFragments(_ groups: [[TimedWord]], hinted: Set<TimeInterval> = []) -> [[TimedWord]] {
        var groups = groups
        var index = 0
        while index < groups.count {
            let group = groups[index]
            guard group.count < minLineWords, groups.count > 1, let first = group.first, let last = group.last else {
                index += 1
                continue
            }
            let previous = index > 0 ? groups[index - 1] : nil
            let next = index + 1 < groups.count ? groups[index + 1] : nil
            let gapBefore = previous.map { first.start - ($0.last?.end ?? 0) } ?? .infinity
            let gapAfter = next.map { ($0.first?.start ?? .infinity) - last.end } ?? .infinity
            let previousEndsSentence = previous?.last.map(endsSentence) ?? false
            // A sentence's last words stay with it; a new sentence's first
            // words go with the rest of it; otherwise the closer neighbour.
            var sides: [Bool] // true: the line before
            if endsSentence(last) {
                sides = previousEndsSentence ? [] : [true]
            } else if previousEndsSentence {
                sides = [false]
            } else {
                sides = gapAfter <= gapBefore ? [false, true] : [true, false]
            }
            // The first line has nothing before it, the last nothing after.
            sides.removeAll { $0 ? previous == nil : next == nil }
            if let joinsPrevious = sides.first(where: { $0 ? previous.map { fits($0 + group) } ?? false : next.map { fits(group + $0) } ?? false }) {
                if joinsPrevious {
                    groups[index - 1] += group
                } else {
                    groups[index + 1] = group + groups[index + 1]
                }
                groups.remove(at: index)
            } else if let joinsPrevious = sides.first {
                // Too long together: shared out again, so neither keeps a
                // scrap ("…would carry me / away").
                let neighbour = joinsPrevious ? index - 1 : index + 1
                let combined = joinsPrevious ? groups[neighbour] + group : group + groups[neighbour]
                let pieces = splitLongLine(combined, hinted: hinted)
                groups.replaceSubrange(min(index, neighbour)...max(index, neighbour), with: pieces)
                index = min(index, neighbour) + pieces.count
            } else {
                index += 1
            }
        }
        return groups
    }

    /// Cuts an overlong line where a singer would breathe: the longest
    /// silence or a clause's end, near the middle, never on a word that
    /// leads into the next, and never leaving a scrap on either side.
    nonisolated static func splitLongLine(_ group: [TimedWord], hinted: Set<TimeInterval> = []) -> [[TimedWord]] {
        let length = group.map(\.text).joined(separator: " ").count
        guard group.count > maxLineWords || length > maxLineLength, group.count >= 4 else { return [group] }
        let minimumSide = group.count >= 6 ? 3 : 2
        func score(_ index: Int) -> Double {
            let previous = group[index - 1]
            // Short gaps are just articulation; real breaths count.
            let silence = min(max(group[index].start - previous.end - 0.15, 0), 1.5)
            let endsClause = previous.text.last.map { ",.;:!?".contains($0) } ?? false
            let leadsOn = previous.text.last?.isLetter == true
                && (continuingWords.contains(bareWord(previous)) || weakEndings.contains(bareWord(previous)))
            // "…keeps on running / and the city…": a line may well start
            // on the word that opens a phrase.
            let opensPhrase = continuingWords.contains(bareWord(group[index]))
            let offCenter = abs(Double(index) - Double(group.count) / 2) / Double(group.count)
            let isHinted = hinted.contains(group[index].start)
            let hangsBack = poorStarts.contains(bareWord(group[index]))
            return silence * 2 + (endsClause ? 1.2 : 0) + (opensPhrase ? 0.6 : 0) + (isHinted ? 0.7 : 0)
                - (leadsOn ? 1.5 : 0) - (hangsBack ? 1.0 : 0) - offCenter * 2.5
        }
        guard let cut = (minimumSide...(group.count - minimumSide)).max(by: { score($0) < score($1) }) else { return [group] }
        return splitLongLine(Array(group[..<cut]), hinted: hinted) + splitLongLine(Array(group[cut...]), hinted: hinted)
    }

    /// The model the words are heard by, signed in the file and shown
    /// under the lyrics.
    nonisolated static var transcriptionModelName: String {
        if Speechmatics.isOn {
            return "Speechmatics " + (Speechmatics.operatingPoint == .standard ? "Standard" : "Enhanced")
        }
        return AIProvider.current == .groq ? "Whisper" : "Voxtral"
    }

    /// Where a file's words come from: heard in the song, or lyrics that
    /// already existed (from `source` when known) only given their times.
    enum TextOrigin: Sendable {
        case transcribed
        case existing(source: String?)
    }

    /// The signature's parentheses: the model, then for a sync of
    /// existing lyrics, where those came from.
    nonisolated static func signature(_ origin: TextOrigin) -> String {
        switch origin {
        case .transcribed: transcriptionModelName
        case .existing(let source?): transcriptionModelName + "; lyrics from " + source
        case .existing(nil): transcriptionModelName + "; synced only"
        }
    }

    /// LRC text, each line shown a beat before it's sung; long breaks end
    /// the previous line so it isn't left lit through a solo.
    nonisolated static func lrc(lines: [Line], for song: Song, origin: TextOrigin = .transcribed) -> String {
        func stamp(_ time: TimeInterval) -> String {
            let hundredths = Int((max(0, time) * 100).rounded())
            return String(format: "[%02d:%02d.%02d]", hundredths / 6000, hundredths / 100 % 60, hundredths % 100)
        }
        var output = [
            "[ti:\(song.title)]",
            "[ar:\(song.artist)]",
            "[al:\(song.album)]",
            "[by:LRCplayer AI Beta (\(signature(origin)))]"
        ]
        for (index, line) in lines.enumerated() {
            output.append(stamp(line.start - 0.15) + line.text)
            let next = index + 1 < lines.count ? lines[index + 1].start : nil
            if let next, next - line.end >= 5 {
                output.append(stamp(line.end + 1))
            }
        }
        if let last = lines.last {
            output.append(stamp(last.end + 2))
        }
        return output.joined(separator: "\n") + "\n"
    }
}
