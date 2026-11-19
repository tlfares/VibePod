import Foundation
import AVFoundation
import Combine
import SwiftUI

@MainActor
final class PlayerViewModel: ObservableObject {
    let playerService: MusicPlayerService
    let libraryService: LibraryService

    @Published var showPlayer = false
    @Published var showLyrics = false
    @Published private(set) var currentLyrics: LRCLyrics?
    /// The lyrics as in the file, before the start and outro marks.
    private(set) var rawLyrics: LRCLyrics?
    /// The current song's start and outro marks.
    @Published private(set) var currentMarks = LyricsMarks()
    /// Shown line → the file's line (they differ around the marks).
    private var rawLineIDs: [LyricsLine.ID: LyricsLine.ID] = [:]
    /// The outro's lines, as shown.
    @Published private(set) var currentOutroLines: Set<LyricsLine.ID> = []

    /// The file's line a shown line comes from.
    func rawLine(for line: LyricsLine) -> LyricsLine? {
        let id = rawLineIDs[line.id] ?? line.id
        return rawLyrics?.lines.first { $0.id == id }
    }
    @Published private(set) var currentLyricLine: LyricsLine?
    @Published private(set) var currentSongHasLRC = false
    /// The current lyrics' AI word by word timings, by line (empty without).
    @Published private(set) var currentWordTimings: [LyricsLine.ID: [WordTiming]] = [:]
    /// Lines a second singer sings, shown on the trailing side.
    @Published private(set) var currentTrailingLines: Set<LyricsLine.ID> = []
    /// The source of the current word timings, nil when Mistral made them.
    @Published private(set) var currentWordSyncSource: String?
    /// The current lyrics have word timings, shown or hidden.
    @Published private(set) var currentSongHasWordSync = false
    @Published private(set) var currentWordSyncHidden = false
    /// Last playback failure, cleared after a few seconds (shown as a toast).
    @Published private(set) var playbackError: String?
    private var errorClearTask: Task<Void, Never>?

    // Snapshots of the service state, minus the 4 Hz `currentTime`: views that
    // observe this model don't re-render on every playback tick.
    @Published private(set) var currentSong: Song?
    @Published private(set) var isPlaying = false
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var repeatMode: RepeatMode = .off
    @Published private(set) var shuffleMode: ShuffleMode = .off
    @Published private(set) var queue: [Song] = []
    @Published private(set) var currentIndex = 0

    private var cancellables = Set<AnyCancellable>()
    private var lyricsClock: Timer?

    // Listening stats: time actually listened, across pauses.
    private var trackedSong: Song?
    private var listenedSeconds: TimeInterval = 0
    private var segmentStart: Date?

    var currentTime: TimeInterval { playerService.currentTime }

    var nextSongPreview: Song? {
        guard !queue.isEmpty else { return nil }
        let nextIndex = currentIndex + 1
        if queue.indices.contains(nextIndex) { return queue[nextIndex] }
        return repeatMode == .all ? queue.first : nil
    }

    var previousSongPreview: Song? {
        guard !queue.isEmpty else { return nil }
        let previousIndex = currentIndex - 1
        if queue.indices.contains(previousIndex) { return queue[previousIndex] }
        return repeatMode == .all ? queue.last : nil
    }

    /// Songs after the current one (the "Up Next" list).
    var upNext: ArraySlice<Song> {
        guard queue.indices.contains(currentIndex) else { return [] }
        return queue[(currentIndex + 1)...]
    }

    init(playerService: MusicPlayerService, libraryService: LibraryService) {
        self.playerService = playerService
        self.libraryService = libraryService

        currentSong = playerService.currentSong
        isPlaying = playerService.isPlaying
        duration = playerService.duration
        repeatMode = playerService.repeatMode
        shuffleMode = playerService.shuffleMode
        queue = playerService.queue
        currentIndex = playerService.currentIndex
        LyricsTranslator.shared.upcoming = { [weak self] in self?.nextSongPreview }
        loadLyrics(for: currentSong)

        playerService.$currentSong
            .dropFirst()
            .removeDuplicates { $0?.id == $1?.id }
            .sink { [weak self] song in self?.currentSongDidChange(song) }
            .store(in: &cancellables)

        playerService.$isPlaying
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] playing in
                guard let self else { return }
                self.isPlaying = playing
                self.trackPlayback(isPlaying: playing)
                self.updateLyricsClock()
            }
            .store(in: &cancellables)

        playerService.$lastError
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] message in
                guard let self else { return }
                self.errorClearTask?.cancel()
                self.playbackError = message
                guard message != nil else { return }
                self.errorClearTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(3))
                    guard !Task.isCancelled else { return }
                    self?.playbackError = nil
                }
            }
            .store(in: &cancellables)

        playerService.$duration.dropFirst().removeDuplicates().assign(to: &$duration)
        playerService.$repeatMode.dropFirst().removeDuplicates().assign(to: &$repeatMode)
        playerService.$shuffleMode.dropFirst().removeDuplicates().assign(to: &$shuffleMode)
        playerService.$queue.dropFirst().assign(to: &$queue)
        playerService.$currentIndex.dropFirst().removeDuplicates().assign(to: &$currentIndex)

        // Seeks and coarse ticks re-sync the lyric immediately; the clock below
        // handles the precise line changes in between.
        playerService.$currentTime
            .sink { [weak self] _ in
                guard let self, self.showPlayer else { return }
                self.updateCurrentLyric()
            }
            .store(in: &cancellables)

        $showPlayer
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor in self?.updateLyricsClock() }
            }
            .store(in: &cancellables)

        // The current song's lyrics path can change (association, LRCLIB).
        libraryService.$songs
            .sink { [weak self] songs in
                guard let self, let current = self.currentSong,
                      let updated = songs.first(where: { $0.id == current.id }) else { return }
                let lyricsChanged = updated.lrcFilePath != current.lrcFilePath
                self.currentSong = updated
                if lyricsChanged {
                    self.loadLyrics(for: updated)
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: LyricsMarks.didChangeNotification)
            .sink { [weak self] notification in
                guard let self, let songID = notification.object as? UUID, songID == self.currentSong?.id else { return }
                self.loadWordTimings()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: WordSyncStore.didChangeNotification)
            .sink { [weak self] notification in
                guard let self, let songID = notification.object as? UUID, songID == self.currentSong?.id else { return }
                self.loadWordTimings()
            }
            .store(in: &cancellables)

        if isPlaying { trackPlayback(isPlaying: true) }
    }

    private func currentSongDidChange(_ song: Song?) {
        finishTrackedPlay()
        currentSong = song.flatMap { libraryService.song(withID: $0.id) } ?? song
        loadLyrics(for: currentSong)
        trackedSong = currentSong
        if isPlaying, currentSong != nil { segmentStart = Date() }
        recordRecentlyPlayedCollection()
    }

    // MARK: - Listening stats

    private func trackPlayback(isPlaying: Bool) {
        if isPlaying {
            if trackedSong == nil { trackedSong = currentSong }
            segmentStart = Date()
        } else if let start = segmentStart {
            listenedSeconds += Date().timeIntervalSince(start)
            segmentStart = nil
        }
    }

    private func finishTrackedPlay() {
        if let start = segmentStart {
            listenedSeconds += Date().timeIntervalSince(start)
        }
        if let song = trackedSong, listenedSeconds >= 10, !PrivateListening.isOn {
            ListeningStatsService.shared.recordPlay(song: song, durationPlayed: listenedSeconds)
            libraryService.recordPlay(songID: song.id)
        }
        trackedSong = nil
        listenedSeconds = 0
        segmentStart = nil
    }

    /// Feeds the home "Recently Played" shelf with the album or playlist the
    /// current queue was started from.
    private func recordRecentlyPlayedCollection() {
        guard let song = currentSong else { return }
        let queueIDs = queue.map(\.id)
        guard !queueIDs.isEmpty else { return }
        let albumName = song.album
        if !albumName.isEmpty, queue.allSatisfy({ $0.album == albumName }) {
            RecentPlayedStore.shared.record(albumArtist: LibraryIndex.artistName(for: song), albumName: albumName)
            return
        }
        let queueSet = Set(queueIDs)
        if let playlist = libraryService.playlists.first(where: { !$0.songs.isEmpty && Set($0.songs) == queueSet }) {
            RecentPlayedStore.shared.record(playlistID: playlist.id)
        }
    }

    // MARK: - Playback

    func play(song: Song, from queue: [Song]) {
        playerService.play(song: song, from: queue)
    }

    /// Album/playlist header buttons.
    func play(_ songs: [Song], shuffled: Bool) {
        playerService.play(songs, shuffled: shuffled)
    }

    func playPlaylist(_ playlist: Playlist, shuffled: Bool = false) {
        let songs = libraryService.songsForPlaylist(playlist)
        guard !songs.isEmpty else { return }
        playerService.play(songs, shuffled: shuffled)
        RecentPlayedStore.shared.record(playlistID: playlist.id)
    }

    func togglePlayPause() { playerService.togglePlayPause() }
    func next() { playerService.next() }
    func previous() { playerService.previous() }
    func previousTrack() { playerService.skipToPreviousTrack() }
    func seek(to time: TimeInterval) {
        recordReplay(to: time)
        playerService.seek(to: time)
        updateCurrentLyric()
    }
    func toggleRepeat() { playerService.toggleRepeat() }
    func toggleShuffle() { playerService.toggleShuffle() }

    func addToQueue(song: Song) { playerService.addToQueue(song: song) }
    func addNextToQueue(song: Song) { playerService.addNextToQueue(song: song) }
    func playQueueItem(at index: Int) { playerService.playQueueItem(at: index) }
    func removeFromQueue(at index: Int) { playerService.removeFromQueue(at: index) }
    func moveQueueItem(from source: Int, to destination: Int) { playerService.moveQueueItem(from: source, to: destination) }

    func dismissPlayer() {
        showPlayer = false
    }

    // MARK: - Lyrics

    /// Rewrites one line of the current song's LRC file (an AI transcript's
    /// mistake), keeping its timestamps; word timings of that line go.
    func correctLyricLine(_ line: LyricsLine, to text: String) {
        guard let song = currentSong, let url = libraryService.resolvedLyricsURL(for: song),
              let content = try? String(contentsOf: url, encoding: .utf8) else { return }
        // A line cut by a mark: the file's whole line, rewritten as a whole.
        let line = rawLine(for: line) ?? line
        let oldLyrics = rawLyrics
        let oldTimings = oldLyrics.map { WordSyncStore.load(for: song.id, lyrics: $0) } ?? [:]
        let oldSource = WordSyncStore.source(for: song.id)
        var rows = content.components(separatedBy: "\n")
        let stamps = try! NSRegularExpression(pattern: #"^((?:\[\d+:\d+(?:[.:]\d+)?\])+)(.*)$"#)
        var best: (index: Int, distance: TimeInterval, prefix: String)?
        for (index, row) in rows.enumerated() {
            let ns = row as NSString
            guard let match = stamps.firstMatch(in: row, range: NSRange(location: 0, length: ns.length)) else { continue }
            let prefix = ns.substring(with: match.range(at: 1))
            let body = ns.substring(with: match.range(at: 2))
                .replacingOccurrences(of: #"<[^>]*>"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard body == line.text.trimmingCharacters(in: .whitespacesAndNewlines) else { continue }
            let times = prefix.split(separator: "]").compactMap { tag -> TimeInterval? in
                let parts = tag.dropFirst().split(separator: ":")
                guard parts.count >= 2, let minutes = Double(parts[0]), let seconds = Double(parts[1...].joined(separator: ".")) else { return nil }
                return minutes * 60 + seconds
            }
            let distance = times.map { min(abs($0 - line.time), abs($0 - (line.time + (rawLyrics?.offset ?? 0)))) }.min() ?? .infinity
            if best == nil || distance < best!.distance { best = (index, distance, prefix) }
        }
        guard let best else { return }
        rows[best.index] = best.prefix + text
        let updated = rows.joined(separator: "\n")
        guard (try? updated.write(to: url, atomically: true, encoding: .utf8)) != nil else { return }
        if !LyricsGenerator.isGenerated(storedPath: song.lrcFilePath) {
            libraryService.writeSourceLyrics(updated, fileName: url.lastPathComponent)
        }
        if let oldLyrics, !oldTimings.isEmpty {
            carryWordSync(from: oldLyrics, timings: oldTimings, source: oldSource, editing: line, song: song, url: url)
        }
        loadLyrics(for: song)
    }

    fileprivate func loadLyrics(for song: Song?) {
        currentLyricLine = nil
        defer { LyricsTranslator.shared.lyricsDidLoad(currentLyrics, for: song?.id) }
        guard let song else {
            currentLyrics = nil
            rawLyrics = nil
            rawLineIDs = [:]
            currentMarks = LyricsMarks()
            currentOutroLines = []
            playerService.outroCutoff = nil
            currentWordTimings = [:]
            currentTrailingLines = []
            currentWordSyncSource = nil
            currentSongHasWordSync = false
            currentWordSyncHidden = false
            currentSongHasLRC = false
            return
        }

        var lrcURL = libraryService.resolvedLyricsURL(for: song)
        if lrcURL == nil, let found = LRCParser.findLRC(for: song.fileURL) {
            lrcURL = found
            libraryService.setLyricsPath(libraryService.storedLyricsPath(for: found.path), for: song.id)
        }
        currentSongHasLRC = lrcURL != nil
        rawLyrics = lrcURL.flatMap(LRCParser.parse(url:))
        currentLyrics = rawLyrics
        loadWordTimings()
        updateCurrentLyric()
        updateLyricsClock()
    }

    private func loadWordTimings() {
        guard let song = currentSong, let lyrics = rawLyrics, lyrics.hasTimedLyrics else {
            if currentLyrics?.lines.first?.id != rawLyrics?.lines.first?.id || currentLyrics?.lines.count != rawLyrics?.lines.count { currentLyrics = rawLyrics }
            if !currentMarks.isEmpty { currentMarks = LyricsMarks() }
            rawLineIDs = [:]
            if !currentOutroLines.isEmpty { currentOutroLines = [] }
            playerService.outroCutoff = nil
            if !currentWordTimings.isEmpty { currentWordTimings = [:] }
            if !currentTrailingLines.isEmpty { currentTrailingLines = [] }
            currentWordSyncSource = nil
            currentSongHasWordSync = false
            currentWordSyncHidden = false
            return
        }
        let rawTimings = WordSyncStore.load(for: song.id, lyrics: lyrics)
        let hidden = WordSyncStore.isHidden(for: song.id)
        let marks = LyricsMarks.load(for: song.id)
        let applied = marks.apply(to: lyrics, timings: rawTimings)
        let wasMarked = !currentMarks.isEmpty
        if marks != currentMarks { currentMarks = marks }
        rawLineIDs = applied.rawLines
        if !marks.isEmpty || wasMarked { currentLyrics = applied.lyrics }
        if applied.outroLines != currentOutroLines { currentOutroLines = applied.outroLines }
        playerService.outroCutoff = applied.skipsOutro ? applied.outroTime.map { .init(songID: song.id, time: $0 - lyrics.offset) } : nil
        let timings = applied.timings
        currentSongHasWordSync = !rawTimings.isEmpty
        currentWordSyncHidden = hidden
        currentWordTimings = hidden ? [:] : timings
        currentWordSyncSource = timings.isEmpty ? nil : WordSyncStore.source(for: song.id)
        let rawTrailing = LyricsSingerStore.load(for: song.id, lyrics: lyrics)
        let trailing = Set(applied.lyrics.lines.map(\.id).filter { rawTrailing.contains(applied.rawLines[$0] ?? $0) })
        if trailing != currentTrailingLines { currentTrailingLines = trailing }
        updateCurrentLyric()
    }

    private func updateCurrentLyric() {
        guard let lyrics = currentLyrics, !lyrics.lines.isEmpty else {
            // @Published emits even when nil is reassigned; avoid churn.
            if currentLyricLine != nil { currentLyricLine = nil }
            return
        }
        let line = lyrics.line(at: playerService.preciseCurrentTime)
        if line?.id != currentLyricLine?.id {
            currentLyricLine = line
        }
    }

    /// 20 Hz while the player is open and playing synced lyrics, so lines
    /// change on the beat rather than up to 250 ms late.
    private func updateLyricsClock() {
        let shouldRun = showPlayer && isPlaying && currentLyrics?.lines.isEmpty == false
        guard shouldRun != (lyricsClock != nil) else { return }
        lyricsClock?.invalidate()
        lyricsClock = nil
        guard shouldRun else { return }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateCurrentLyric() }
        }
        RunLoop.main.add(timer, forMode: .common)
        lyricsClock = timer
    }

    func importLRCLIBResult(_ result: LRCLIBResult, for song: Song) {
        guard let content = result.lrcContent, !content.isEmpty else { return }

        let destination = libraryService.ownLyricsURL(for: song, in: libraryService.lyricsDirectory)
        do {
            try content.write(to: destination, atomically: true, encoding: .utf8)
        } catch {
            return
        }
        let stored = libraryService.storedLyricsPath(for: destination.path)
        LyricsKindCache.invalidate(storedPath: stored)
        libraryService.setLyricsPath(stored, for: song.id)
        // The results sheet can outlive the song: never show its lyrics over
        // whatever is playing now.
        guard song.id == currentSong?.id else { return }
        loadLyrics(for: libraryService.song(withID: song.id) ?? song)
    }

    /// Imports lyrics found by `LyricsSearch`: the LRC file, and beside it
    /// the word timings and singers the source had.
    func importCandidate(_ candidate: LyricsCandidate, for song: Song) {
        let content = candidate.lrcText
        guard !content.isEmpty else { return }
        let destination = libraryService.ownLyricsURL(for: song, in: libraryService.lyricsDirectory)
        do {
            try content.write(to: destination, atomically: true, encoding: .utf8)
        } catch {
            return
        }
        WordSyncStore.delete(for: song.id)
        LyricsSingerStore.delete(for: song.id)
        if candidate.isSynced, let lyrics = LRCParser.parse(url: destination), lyrics.hasTimedLyrics {
            // The parsed lines matched back to the source's by time and text.
            let source = candidate.fileLines
            let trailingSource = Set(candidate.trailingLineIndices.map { index in
                source.firstIndex { $0.time == candidate.lines[index].time && $0.text == candidate.lines[index].text } ?? -1
            })
            var lookup: [String: Int] = [:]
            for (index, line) in source.enumerated() {
                lookup["\(String(format: "%.2f", line.time))|\(line.text)", default: index] = index
            }
            var words: [[WordTiming]] = []
            var trailing: Set<Int> = []
            for (index, line) in lyrics.lines.enumerated() {
                let match = lookup["\(String(format: "%.2f", line.time))|\(line.text)"]
                    ?? source.firstIndex { abs($0.time - line.time) < 0.02 && $0.text == line.text }
                let found = match.map { source[$0] }
                if let found, let timings = found.words, timings.count == LyricWords.ranges(in: line.text).count {
                    words.append(timings)
                } else {
                    words.append([])
                }
                if let match, trailingSource.contains(match) { trailing.insert(index) }
            }
            if words.contains(where: { !$0.isEmpty }) {
                try? WordSyncStore.save(words, for: song.id, lyrics: lyrics, source: candidate.source)
            }
            try? LyricsSingerStore.save(trailing: trailing, for: song.id, lyrics: lyrics)
        }
        let stored = libraryService.storedLyricsPath(for: destination.path)
        LyricsKindCache.invalidate(storedPath: stored)
        libraryService.setLyricsPath(stored, for: song.id)
        guard song.id == currentSong?.id else { return }
        loadLyrics(for: libraryService.song(withID: song.id) ?? song)
    }
}

// MARK: - Word sync through a correction

extension PlayerViewModel {
    /// Keeps word timings through a corrected line: a respelled or similar
    /// word takes its old timing, a few new words fit around the kept ones,
    /// and a line rewritten too much is synced again from its own audio.
    fileprivate func carryWordSync(from oldLyrics: LRCLyrics, timings: [LyricsLine.ID: [WordTiming]], source: String?, editing line: LyricsLine, song: Song, url: URL) {
        guard let newLyrics = LRCParser.parse(url: url), newLyrics.lines.count == oldLyrics.lines.count,
              let index = oldLyrics.lines.firstIndex(where: { $0.id == line.id }) else { return }
        var lines = oldLyrics.lines.map { timings[$0.id] ?? [] }
        var resync: (start: TimeInterval, end: TimeInterval)?
        if let old = timings[line.id], let first = old.first, let last = old.last {
            let newText = newLyrics.lines[index].text
            if let carried = Self.carriedTimings(oldText: line.text, old: old, newText: newText) {
                lines[index] = carried
            } else {
                lines[index] = []
                resync = (first.start, last.end)
            }
        }
        try? WordSyncStore.save(lines, for: song.id, lyrics: newLyrics, source: source)
        if let resync { resyncLine(index, of: song, lyrics: newLyrics, span: resync) }
    }

    nonisolated static func carriedTimings(oldText: String, old: [WordTiming], newText: String) -> [WordTiming]? {
        let oldWords = LyricWords.ranges(in: oldText).map { String(oldText[$0]) }
        let newWords = LyricWords.ranges(in: newText).map { String(newText[$0]) }
        guard oldWords.count == old.count, !newWords.isEmpty, let first = old.first, let last = old.last else { return nil }
        let a = oldWords.map(WordSyncGenerator.comparable), b = newWords.map(WordSyncGenerator.comparable)
        var anchors = [WordTiming?](repeating: nil, count: b.count)
        if a.count == b.count {
            // Same shape: word for word, when close in spelling or length.
            for i in b.indices {
                let ratio = Double(max(a[i].count, 1)) / Double(max(b[i].count, 1))
                if a[i] == b[i] || WordSyncGenerator.similarity(a[i], b[i]) >= 0.5 || (0.6...1.7).contains(ratio) {
                    anchors[i] = old[i]
                }
            }
            if anchors.allSatisfy({ $0 != nil }) { return old }
        } else {
            // Words added or dropped: the longest run of matching words.
            var table = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
            func same(_ i: Int, _ j: Int) -> Bool { a[i] == b[j] || WordSyncGenerator.similarity(a[i], b[j]) >= 0.75 }
            for i in stride(from: a.count - 1, through: 0, by: -1) {
                for j in stride(from: b.count - 1, through: 0, by: -1) {
                    table[i][j] = same(i, j) ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
                }
            }
            var i = 0, j = 0
            while i < a.count, j < b.count {
                if same(i, j) { anchors[j] = old[i]; i += 1; j += 1 }
                else if table[i + 1][j] >= table[i][j + 1] { i += 1 } else { j += 1 }
            }
        }
        // Too little left to hold on to: that's a new line.
        let kept = anchors.compactMap { $0 }.count
        guard Double(kept) / Double(b.count) >= 0.6, Double(kept) / Double(a.count) >= 0.5 else { return nil }
        return WordSyncGenerator.lineTimings(words: newWords.map(\.count), anchors: anchors, lineStart: first.start, lineEnd: last.end)
    }

    /// Mistral hears just this line again; without AI, or if it hears
    /// something else, its words are spread over the line's old span.
    private func resyncLine(_ index: Int, of song: Song, lyrics: LRCLyrics, span: (start: TimeInterval, end: TimeInterval)) {
        let line = lyrics.lines[index]
        let weights = LyricWords.ranges(in: line.text).map { line.text.distance(from: $0.lowerBound, to: $0.upperBound) }
        let fallback = WordSyncGenerator.lineTimings(words: weights, anchors: weights.map { _ in nil }, lineStart: span.start, lineEnd: span.end)
        func store(_ timings: [WordTiming]) {
            var lines = lyrics.lines.map { _ in [WordTiming]() }
            let current = WordSyncStore.load(for: song.id, lyrics: lyrics)
            guard !current.isEmpty || lyrics.lines.count == 1 else { return } // lyrics changed meanwhile
            for (i, l) in lyrics.lines.enumerated() { lines[i] = current[l.id] ?? [] }
            lines[index] = timings
            try? WordSyncStore.save(lines, for: song.id, lyrics: lyrics, source: WordSyncStore.source(for: song.id))
            if currentSong?.id == song.id { loadLyrics(for: song) }
        }
        guard AIFeatures.isAvailable, let key = AIFeatures.apiKey else { return store(fallback) }
        store(fallback) // shown right away, refined when Mistral answers
        let offset = lyrics.offset
        let from = max(0, span.start - offset - 1), to = span.end - offset + 1
        let audio = song.playableFileURL
        Task {
            let output = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).m4a")
            defer { try? FileManager.default.removeItem(at: output) }
            do {
                let asset = AVURLAsset(url: audio, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
                guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else { return }
                session.timeRange = CMTimeRange(start: CMTime(seconds: from, preferredTimescale: 600), end: CMTime(seconds: to, preferredTimescale: 600))
                try await session.export(to: output, as: .m4a)
                let heard = LyricsGenerator.sungWords(in: try await MistralClient.transcribe(audio: output, key: key)).map {
                    TimedWord(text: $0.text, start: $0.start + from + offset, end: $0.end + from + offset)
                }
                let probe = LyricsLine(time: line.time, text: line.text)
                guard let timings = try? WordSyncGenerator.timings(for: [probe], heard: heard).first, timings.count == weights.count else { return }
                store(timings)
            } catch {}
        }
    }
}

// MARK: - Replayed lines

extension PlayerViewModel {
    /// Going back in a song to hear a line again counts for that line.
    fileprivate func recordReplay(to time: TimeInterval) {
        let now = playerService.preciseCurrentTime
        guard ListeningStatsService.shared.isEnabled, !PrivateListening.isOn, let song = currentSong, let lyrics = currentLyrics, lyrics.hasTimedLyrics,
              time < now - 1.5, now - time < 90 else { return }
        let clock = time + lyrics.offset + 0.4
        guard let line = lyrics.lines.last(where: { $0.time <= clock && !$0.isInstrumentalGap }) else { return }
        ReplayedLines.record(line.text, songID: song.id)
    }
}

/// How often each lyric line was gone back to, per song.
/// Private Listening: nothing played counts (stats, play counts, replays).
enum PrivateListening {
    static let key = "privateListening"
    static var isOn: Bool { UserDefaults.standard.bool(forKey: key) }
}

enum ReplayedLines {
    private static let key = "replayedLines"

    struct Entry: Identifiable {
        let songID: UUID
        let text: String
        let count: Int
        var id: String { "\(songID)|\(text)" }
    }

    static func record(_ text: String, songID: UUID) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        var all = UserDefaults.standard.dictionary(forKey: key) as? [String: Int] ?? [:]
        all["\(songID.uuidString)|\(text)", default: 0] += 1
        UserDefaults.standard.set(all, forKey: key)
    }

    static func top(_ limit: Int = 20) -> [Entry] {
        let all = UserDefaults.standard.dictionary(forKey: key) as? [String: Int] ?? [:]
        return all.compactMap { key, count -> Entry? in
            guard let bar = key.firstIndex(of: "|"), let id = UUID(uuidString: String(key[..<bar])) else { return nil }
            return Entry(songID: id, text: String(key[key.index(after: bar)...]), count: count)
        }
        .sorted { $0.count != $1.count ? $0.count > $1.count : $0.text < $1.text }
        .prefix(limit).map { $0 }
    }

    static func reset() { UserDefaults.standard.removeObject(forKey: key) }

    /// "uuid|text" → count.
    static func all() -> [String: Int] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: Int] ?? [:]
    }

    /// Counts from another device: the higher one stays, so merging twice
    /// changes nothing.
    static func merge(_ counts: [String: Int]) {
        var all = all()
        for (line, count) in counts { all[line] = max(all[line] ?? 0, count) }
        UserDefaults.standard.set(all, forKey: key)
    }
}
