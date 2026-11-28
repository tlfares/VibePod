import Combine
import Foundation
import UIKit

// What iCloud Sync carries, one domain per kind of data. Each one reads
// what the app holds into documents and writes documents back.

private extension String {
    /// "playlist.<uuid>" → the UUID.
    var syncUUID: UUID? {
        split(separator: ".", maxSplits: 1).last.flatMap { UUID(uuidString: String($0)) }
    }
}

// MARK: - Songs

/// Everything about a song but its file: tags edited here, play counts,
/// lyrics, word by word sync, duet singers, lyrics marks, summary, music
/// video choice.
@MainActor
final class SongsSyncDomain: SyncDomain {
    struct Ident: Codable {
        var key: String
        /// Normalized title, artist and album, to recognize the song when
        /// the key differs.
        var mk: String
        var d: Int
    }

    struct Tags: Codable {
        var title: String
        var artist: String
        var album: String
        var albumArtist: String?
        var genre: String
        var year: Int
        var track: Int
        var disc: Int
    }

    /// Plays counted by each device: the total adds them up, and merging
    /// keeps each device's highest, so plays on two devices both count.
    struct Counts: Codable {
        var by: [String: Int]
        var last: Date?
    }

    struct Lyrics: Codable {
        var text: String
        var generated: Bool
    }

    let prefix = "song"
    var propagatesDeletion: Bool { false }

    private weak var library: LibraryService?
    /// Songs changed while applying a batch, written to the library at once.
    private var modified: [UUID: Song] = [:]
    private var flushScheduled = false

    init(library: LibraryService) {
        self.library = library
    }

    private var keys: SyncSongKeys { CloudSync.shared.keys }

    private func song(_ name: String) -> Song? {
        guard let id = keys.id(forHash: String(name.dropFirst(prefix.count + 1))) else { return nil }
        return modified[id] ?? library?.song(withID: id)
    }

    func localDocuments() -> [String] {
        (library?.songs ?? []).compactMap { song in keys.hash(for: song.id).map { "song.\($0)" } }
    }

    func localSong(matching ident: Ident) -> Song? {
        let candidates = (library?.songs ?? []).filter { song in
            abs(Int(song.duration.rounded()) - ident.d) <= 2
                && MediaLibraryReconciler.matchKey(title: song.title, artist: song.artist, album: song.album) == ident.mk
        }
        return candidates.count == 1 ? candidates[0] : nil
    }

    func snapshot(_ name: String) -> DocSnapshot? {
        guard var song = song(name), let library, let key = keys.key(for: song.id) else { return nil }
        var snapshot = DocSnapshot()
        let id = song.id
        snapshot.sections["ident"] = SyncValue.encode(Ident(
            key: key,
            mk: MediaLibraryReconciler.matchKey(title: song.title, artist: song.artist, album: song.album),
            d: Int(song.duration.rounded())
        ))
        snapshot.sections["tags"] = SyncValue.encode(Tags(
            title: song.title, artist: song.artist, album: song.album, albumArtist: song.albumArtist,
            genre: song.genre, year: song.year, track: song.trackNumber, disc: song.discNumber
        ))

        let me = CloudSync.shared.deviceID
        let agreed = CloudSync.shared.agreedSection(name, "counts").flatMap { SyncValue.decode(Counts.self, from: $0) }
        if song.playCount > 0 || song.lastPlayedAt != nil || agreed != nil {
            var by = (agreed?.by ?? [:]).filter { $0.key != me }
            let others = by.values.reduce(0, +)
            // Fewer plays here than the other devices had (or an older last
            // play): this song never caught up. Brought level now, since
            // what's below would otherwise look the same as the synced data.
            let agreedLast = agreed?.last
            if song.playCount < others || (agreedLast ?? .distantPast) > (song.lastPlayedAt ?? .distantPast) {
                song.playCount = max(song.playCount, others + (agreed?.by[me] ?? 0))
                song.lastPlayedAt = [song.lastPlayedAt, agreedLast].compactMap { $0 }.max()
                modified[id] = song
                scheduleFlush()
            }
            by[me] = max(0, song.playCount - others)
            snapshot.sections["counts"] = SyncValue.encode(Counts(by: by, last: song.lastPlayedAt))
        }

        if song.lrcFilePath == nil, LyricsRemovals.contains(id) {
            // Deleted by hand: said so, unlike lyrics that are just missing.
            snapshot.sections["lyrics"] = SyncValue.encode(LyricsRemovals.Marker())
        }
        if song.lrcFilePath != nil {
            // Lyrics again: an older deletion no longer stands.
            LyricsRemovals.remove(id)
            if let url = library.resolvedLyricsURL(for: song), let text = readText(url) {
                let generated = LyricsGenerator.isGenerated(storedPath: song.lrcFilePath)
                snapshot.sections["lyrics"] = SyncValue.encode(Lyrics(text: text, generated: generated))
            } else {
                snapshot.skipped.insert("lyrics")
            }
            if let data = WordSyncStore.rawData(for: id) {
                snapshot.sections["wordSync"] = data
            } else if WordSyncStore.isRemoved(for: id) {
                // Deleted by hand: said so, unlike timings that are just missing.
                snapshot.sections["wordSync"] = SyncValue.encode(WordSyncStore.RemovalMarker())
            }
            if let data = LyricsSingerStore.rawData(for: id) { snapshot.sections["singers"] = data }
        } else {
            // Without lyrics, what hangs on them isn't looked at.
            snapshot.skipped.formUnion(["wordSync", "singers"])
        }
        if let data = LyricsMarks.rawData(for: id) { snapshot.sections["marks"] = data }
        if WordSyncStore.isHidden(for: id) { snapshot.sections["wordSyncHidden"] = SyncValue.encode(true) }
        if let entry = LyricsSummaries.shared.entries[id] { snapshot.sections["summary"] = SyncValue.encode(entry) }
        if var choice = MusicVideoStore.storedChoice(for: id), choice.isOn || choice.videoID != nil {
            // Search results stay on each device.
            choice.candidates = nil
            snapshot.sections["video"] = SyncValue.encode(choice)
        }
        // Something missing here never deletes it elsewhere: it may only
        // have failed to arrive (a file that couldn't be written, a song
        // reloaded). Lyrics are removed on each device by hand.
        snapshot.skipped.formUnion(Self.sections.subtracting(snapshot.sections.keys))
        return snapshot
    }

    private static let sections: Set<String> = ["tags", "counts", "lyrics", "wordSync", "singers", "marks", "wordSyncHidden", "summary", "video"]

    /// Lyrics read at the last scan, until their file changes: a scan
    /// looks at every song.
    private var lyricsCache: [String: (date: Date, text: String)] = [:]

    private func readText(_ url: URL) -> String? {
        let path = url.path
        let date = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        if let date, let cached = lyricsCache[path], cached.date == date { return cached.text }
        guard let text = Self.readText(url) else { return nil }
        if let date { lyricsCache[path] = (date, text) }
        return text
    }

    private static func readText(_ url: URL) -> String? {
        if let text = try? String(contentsOf: url, encoding: .utf8) { return text }
        var encoding = String.Encoding.utf8
        return try? String(contentsOf: url, usedEncoding: &encoding)
    }

    func apply(_ name: String, sections: [String: Data]) -> Bool {
        guard var song = song(name), let library else { return false }
        let id = song.id
        let null = SyncValue.null
        let before = song
        var complete = true
        for (section, data) in sections {
            // What another device lost is never deleted here.
            if data == null, ["lyrics", "wordSync", "singers", "marks", "summary"].contains(section) { continue }
            switch section {
            case "tags":
                guard let tags = SyncValue.decode(Tags.self, from: data) else { continue }
                song.title = tags.title
                song.artist = tags.artist
                song.album = tags.album
                song.albumArtist = tags.albumArtist
                song.genre = tags.genre
                song.year = tags.year
                song.trackNumber = tags.track
                song.discNumber = tags.disc
            case "counts":
                guard let counts = SyncValue.decode(Counts.self, from: data) else { continue }
                song.playCount = counts.by.values.reduce(0, +)
                song.lastPlayedAt = counts.last
            case "lyrics":
                if !applyLyrics(data, to: &song, library: library) { complete = false }
            case "wordSync":
                if SyncValue.decode(WordSyncStore.RemovalMarker.self, from: data)?.removed == true {
                    // Deleted by hand on another device: the same as Delete here.
                    WordSyncStore.removeRawData(for: id)
                } else {
                    WordSyncStore.setRawData(data, for: id)
                }
            case "singers":
                LyricsSingerStore.setRawData(data, for: id)
            case "marks":
                LyricsMarks.setRawData(data, for: id)
            case "wordSyncHidden":
                WordSyncStore.setHidden(SyncValue.decode(Bool.self, from: data) == true, for: id)
            case "summary":
                LyricsSummaries.shared.replaceEntry(SyncValue.decode(LyricsSummaries.Entry.self, from: data), for: id)
            case "video":
                var choice = SyncValue.decode(MusicVideoChoice.self, from: data) ?? MusicVideoChoice()
                choice.candidates = MusicVideoStore.storedChoice(for: id)?.candidates
                MusicVideoStore.setChoice(choice, for: id)
            default:
                break
            }
        }
        if !song.hasSameContent(as: before) {
            modified[id] = song
            scheduleFlush()
        }
        // Not written: tried again later, and never taken for a deletion.
        return complete
    }

    /// Writes lyrics from another device into this one's lyrics folder.
    /// Never deletes any.
    @discardableResult
    private func applyLyrics(_ data: Data, to song: inout Song, library: LibraryService) -> Bool {
        let current = library.resolvedLyricsURL(for: song)
        if SyncValue.decode(LyricsRemovals.Marker.self, from: data)?.removed == true {
            // Deleted by hand on another device: the same as Delete here.
            if song.lrcFilePath != nil {
                song.lrcFilePath = library.unlinkLyrics(of: song)
            }
            if song.lrcFilePath == nil { LyricsRemovals.insert(song.id) }
            return true
        }
        guard data != SyncValue.null, let lyrics = SyncValue.decode(Lyrics.self, from: data) else { return true }
        let folder = lyrics.generated
            ? library.lyricsDirectory.appendingPathComponent(LyricsGenerator.folderName, isDirectory: true)
            : library.lyricsDirectory
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let documents = library.documentsDirectory.standardizedFileURL.path
        let url: URL
        if let current, current.standardizedFileURL.path.hasPrefix(documents),
           LyricsGenerator.isGenerated(storedPath: song.lrcFilePath) == lyrics.generated {
            url = current
        } else {
            url = library.ownLyricsURL(for: song, in: folder)
        }
        guard (try? lyrics.text.write(to: url, atomically: true, encoding: .utf8)) != nil else { return false }
        let stored = LibraryService.storedLyricsPath(url.path)
        LyricsKindCache.invalidate(storedPath: stored)
        song.lrcFilePath = stored
        return true
    }

    /// One time recovery: lyrics (by song key hash) put back where they
    /// were lost, from `restore-lyrics.json` next to the sync data. Songs
    /// whose lyrics file exists are left alone.
    func restoreLyrics(from url: URL) {
        guard let data = try? Data(contentsOf: url), let library,
              let lost = try? JSONDecoder().decode([String: Lyrics].self, from: data) else { return }
        var songs = library.songs
        var restored = 0
        for (offset, song) in songs.enumerated() {
            guard let hash = keys.hash(for: song.id), let lyrics = lost[hash] else { continue }
            // Still there (a file the song points to and that exists).
            if let current = library.resolvedLyricsURL(for: song), FileManager.default.fileExists(atPath: current.path) { continue }
            var updated = song
            if applyLyrics(SyncValue.encode(lyrics), to: &updated, library: library) {
                songs[offset] = updated
                restored += 1
            }
        }
        if restored > 0 {
            library.songs = songs
            library.saveLibrary()
        }
        let done = url.deletingLastPathComponent().appending(path: "restored-lyrics.json")
        try? FileManager.default.removeItem(at: done)
        try? FileManager.default.moveItem(at: url, to: done)
    }

    func merge(section: String, local: Data, remote: Data) -> Data? {
        guard section == "counts",
              let ours = SyncValue.decode(Counts.self, from: local),
              let theirs = SyncValue.decode(Counts.self, from: remote) else { return nil }
        let by = ours.by.merging(theirs.by, uniquingKeysWith: max)
        let last = [ours.last, theirs.last].compactMap { $0 }.max()
        return SyncValue.encode(Counts(by: by, last: last))
    }

    /// Songs changed by sync go into the library together, as soon as the
    /// current work lets the main thread breathe (and never wait for more).
    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.flush() }
        }
    }

    func endApplying() {
        flush()
    }

    private func flush() {
        flushScheduled = false
        guard !modified.isEmpty, let library else { return }
        var songs = library.songs
        var index: [UUID: Int] = [:]
        for (offset, song) in songs.enumerated() where index[song.id] == nil { index[song.id] = offset }
        for (id, song) in modified {
            if let offset = index[id] { songs[offset] = song }
        }
        modified = [:]
        library.songs = songs
        library.saveLibrary()
    }
}

// MARK: - Playlists

@MainActor
final class PlaylistsSyncDomain: SyncDomain {
    let prefix = "playlist"
    private weak var library: LibraryService?
    private var autolistsChanged = false

    init(library: LibraryService) {
        self.library = library
    }

    private var keys: SyncSongKeys { CloudSync.shared.keys }

    /// A music server's playlists come from the server on each device.
    private func isSynced(_ playlist: Playlist) -> Bool {
        playlist.importSource?.service != SubsonicService.playlistService
    }

    func localDocuments() -> [String] {
        (library?.playlists ?? []).filter(isSynced).map { "playlist.\($0.id.uuidString)" }
    }

    func snapshot(_ name: String) -> DocSnapshot? {
        guard let id = name.syncUUID, var playlist = library?.playlists.first(where: { $0.id == id }), isSynced(playlist) else { return nil }
        if playlist.autolist != nil {
            // Each device picks an Autolist's songs from its own library.
            playlist.songs = []
            playlist.manualSongOrder = nil
            playlist.autolistUpdatedAt = nil
        }
        return DocSnapshot(sections: ["content": keys.tokenize(SyncValue.encode(playlist))])
    }

    func apply(_ name: String, sections: [String: Data]) -> Bool {
        guard let library, let id = name.syncUUID, let content = sections["content"] else { return true }
        if content == SyncValue.null {
            remove(name)
            return true
        }
        guard var playlist = SyncValue.decode(Playlist.self, from: keys.detokenize(content)), playlist.id == id else { return false }
        var playlists = library.playlists
        if let index = playlists.firstIndex(where: { $0.id == id }) {
            if playlist.autolist != nil {
                playlist.songs = playlists[index].songs
                playlist.autolistUpdatedAt = playlists[index].autolistUpdatedAt
            }
            guard playlists[index] != playlist else { return true }
            playlists[index] = playlist
        } else {
            // The same playlist made on both devices before they were
            // linked: the main device's stays.
            if !CloudSync.shared.isPrimary {
                playlists.removeAll { local in
                    local.name.caseInsensitiveCompare(playlist.name) == .orderedSame
                        && (local.autolist == nil) == (playlist.autolist == nil)
                        && local.importSource?.playlistID == playlist.importSource?.playlistID
                        && !CloudSync.shared.isKnown("playlist.\(local.id.uuidString)")
                }
            }
            playlists.append(playlist)
        }
        if playlist.autolist != nil { autolistsChanged = true }
        library.playlists = playlists
        library.saveLibrary()
        return true
    }

    func remove(_ name: String) {
        guard let library, let id = name.syncUUID, library.playlists.contains(where: { $0.id == id }) else { return }
        library.playlists.removeAll { $0.id == id }
        library.saveLibrary()
    }

    func endApplying() {
        guard autolistsChanged else { return }
        autolistsChanged = false
        library?.refreshAutolists()
    }
}

// MARK: - Programs

@MainActor
final class ProgramsSyncDomain: SyncDomain {
    let prefix = "program"
    private var keys: SyncSongKeys { CloudSync.shared.keys }

    func localDocuments() -> [String] {
        ProgramStore.shared.programs.map { "program.\($0.id.uuidString)" }
    }

    func snapshot(_ name: String) -> DocSnapshot? {
        guard let id = name.syncUUID, let program = ProgramStore.shared.program(withID: id) else { return nil }
        return DocSnapshot(sections: ["content": keys.tokenize(SyncValue.encode(program))])
    }

    func apply(_ name: String, sections: [String: Data]) -> Bool {
        guard let id = name.syncUUID, let content = sections["content"] else { return true }
        if content == SyncValue.null {
            remove(name)
            return true
        }
        guard let program = SyncValue.decode(PlaybackProgram.self, from: keys.detokenize(content)), program.id == id else { return false }
        ProgramStore.shared.applySynced(program)
        return true
    }

    func remove(_ name: String) {
        guard let id = name.syncUUID else { return }
        ProgramStore.shared.removeSynced(id: id)
    }
}

// MARK: - Listening history

/// VibePod's plays, one document per month: a new play only changes the
/// current month. Plays from every device add up.
@MainActor
final class HistorySyncDomain: SyncDomain {
    let prefix = "history"
    var propagatesDeletion: Bool { false }
    private var months: [String: [ListeningStatsEntry]]?
    private var observer: NSObjectProtocol?
    private var keys: SyncSongKeys { CloudSync.shared.keys }

    init() {
        observer = NotificationCenter.default.addObserver(forName: ListeningStatsService.historyDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.months = nil }
        }
    }

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM"
        return formatter
    }()

    private func grouped() -> [String: [ListeningStatsEntry]] {
        if let months { return months }
        let groups = Dictionary(grouping: ListeningStatsService.shared.ownEntries()) { Self.monthFormatter.string(from: $0.timestamp) }
            .mapValues(Self.sorted)
        months = groups
        return groups
    }

    private static func sorted(_ entries: [ListeningStatsEntry]) -> [ListeningStatsEntry] {
        entries.sorted { $0.timestamp != $1.timestamp ? $0.timestamp < $1.timestamp : $0.id.uuidString < $1.id.uuidString }
    }

    func localDocuments() -> [String] {
        grouped().keys.map { "history.\($0)" }
    }

    func snapshot(_ name: String) -> DocSnapshot? {
        guard let entries = grouped()[String(name.dropFirst(prefix.count + 1))] else { return nil }
        return DocSnapshot(sections: ["plays": keys.tokenize(SyncValue.encode(entries))])
    }

    func apply(_ name: String, sections: [String: Data]) -> Bool {
        guard let data = sections["plays"], data != SyncValue.null,
              let entries = SyncValue.decode([ListeningStatsEntry].self, from: keys.detokenize(data)) else { return true }
        ListeningStatsService.shared.merge(entries)
        return true
    }

    func merge(section: String, local: Data, remote: Data) -> Data? {
        guard section == "plays",
              let ours = SyncValue.decode([ListeningStatsEntry].self, from: keys.detokenize(local)),
              let theirs = SyncValue.decode([ListeningStatsEntry].self, from: keys.detokenize(remote)) else { return nil }
        var byID: [UUID: ListeningStatsEntry] = [:]
        for entry in ours + theirs {
            if let held = byID[entry.id], held.songID.uuidString >= entry.songID.uuidString { continue }
            byID[entry.id] = entry
        }
        return keys.tokenize(SyncValue.encode(Self.sorted(Array(byID.values))))
    }
}

// MARK: - Imported histories

@MainActor
final class ImportsSyncDomain: SyncDomain {
    let prefix = "import"
    private var keys: SyncSongKeys { CloudSync.shared.keys }

    func localDocuments() -> [String] {
        ImportedHistory.shared.packages.map { "import.\($0.id.uuidString)" }
    }

    func snapshot(_ name: String) -> DocSnapshot? {
        guard let id = name.syncUUID, let package = ImportedHistory.shared.package(id) else { return nil }
        return DocSnapshot(sections: ["package": keys.tokenize(SyncValue.encode(package))])
    }

    func apply(_ name: String, sections: [String: Data]) -> Bool {
        guard let id = name.syncUUID, let data = sections["package"] else { return true }
        if data == SyncValue.null {
            remove(name)
            return true
        }
        guard let package = SyncValue.decode(ImportedHistoryPackage.self, from: keys.detokenize(data)), package.id == id else { return false }
        if ImportedHistory.shared.package(id) != nil {
            ImportedHistory.shared.update(package)
        } else {
            ImportedHistory.shared.add(package)
        }
        return true
    }

    func remove(_ name: String) {
        guard let id = name.syncUUID, ImportedHistory.shared.package(id) != nil else { return }
        ImportedHistory.shared.remove(id)
    }
}

// MARK: - Assistant

@MainActor
final class AssistantSyncDomain: SyncDomain {
    let prefix = "assistant"
    var propagatesDeletion: Bool { false }
    private var keys: SyncSongKeys { CloudSync.shared.keys }

    func localDocuments() -> [String] {
        ["assistant.conversation", "assistant.memories"]
    }

    func snapshot(_ name: String) -> DocSnapshot? {
        switch name {
        case "assistant.conversation":
            DocSnapshot(sections: ["messages": keys.tokenize(SyncValue.encode(AssistantService.shared.messages))])
        case "assistant.memories":
            DocSnapshot(sections: ["items": SyncValue.encode(AssistantMemory.shared.items)])
        default:
            nil
        }
    }

    func apply(_ name: String, sections: [String: Data]) -> Bool {
        if let data = sections["messages"], let messages = SyncValue.decode([AssistantMessage].self, from: keys.detokenize(data)) {
            AssistantService.shared.replaceMessages(messages)
        }
        if let data = sections["items"], let items = SyncValue.decode([AssistantMemory.Item].self, from: data) {
            AssistantMemory.shared.replaceItems(items)
        }
        return true
    }
}

// MARK: - Settings

/// The app's preferences and small lists (pins, artist merges, hidden
/// stats, best scores…), one part per setting. What belongs to one device
/// (its layout, volume, permissions, window) stays there.
@MainActor
final class SettingsSyncDomain: SyncDomain {
    let prefix = "settings"
    var propagatesDeletion: Bool { false }
    private var keys: SyncSongKeys { CloudSync.shared.keys }

    private static let names: Set<String> = [
        // Look and library pages
        "appTintColor", "appAppearance", "enabledOptionalTabs",
        "albumsLayout", "albumsGridColumns", "albumsSortMode",
        "playlistsLayout", "playlistsGridColumns", "playlistsSortMode",
        "homeLibrarySortMode", "playlistsAlwaysOnTop", "showRecentlyPlayedSection",
        "homeSuggestionRows", "homeSuggestsPlaylists", "homeSuggestsAlbums", "homeSuggestsArtists", "homeSuggestionsHidden",
        "homeLeadingShortcut", "homeLeadingShortcut2", "homeLeadingShortcut3", "homeTrailingShortcut",
        "searchGenreOrder", "searchArtistOrder", "artistCoverFlow", "artistSongSort2", "detailSongsFollowAlbum",
        "allSongsSort", "genreSongSort", "lyricsSongSort", "songSwipeLeftAction", "lyricsCardBackground",
        // Player and sound
        "nowPlayingFullScreenArtwork", "showPlayerLyricPreview", "singAlongProgressStyle",
        "autoMix", "autoMixStyle", "autoMixCrossfade", "autoMixVocals",
        "volumeLeveling", "volumeLevelingMaxBoost", "equalizerEnabled", "equalizerGains",
        "musicHapticsEnabled", "musicHapticsApple", "musicHapticsIntensity", "musicHapticsFocus",
        "motionArtworkEnabled", "motionArtworkKeepsPlaying", "motionArtworkClassicUnderLyrics",
        "musicVideoEnabled", "musicVideoAutoMode",
        "lyricsTranslationEnabled", "lyricsTranslationAutomatic", "lyricsTranslationTarget",
        // Features
        "aiFeaturesEnabled", "aiProvider", "generateLyricsWordByWord",
        "assistantEngine", "assistantSwapPress", "assistantAutoListen", "assistantShowButton",
        "headGesturesEnabled", "headGesturesSensitivity",
        "listeningStatsEnabled", "importedHistoryShownSeparately", "libraryTransferContent",
        "hiddenSettingsUnlocked", "hideNowPlayingArtwork", "alphaFeatures", "yearInMusicEarly",
        // Library data
        "artistMerges", "pinnedAlbums", "pinnedPlaylists", "recentlyPlayedEntries", "playlistFilterModes",
        "artistsWithSeparateSingles", "statsHiddenItems", "replayedLines",
        "artistPhotoSources", "artistCoverAlbums", "motionArtworkHiddenAlbums",
        "autoMatchArtists", "aiSyncedOriginalLyrics",
        // Games
        "whatSongBestScore", "coversSnakeBestScore", "guessLyricsBestScore",
        "whatSongDuration", "whatSongDifficulty", "whoSingsDifficulty", "musicTilesDifficulty",
        "songVoiceAllSongs", "musicTilesRecent", "aCappellaRecent",
    ]

    private static let prefixes = ["headGesture.", "widgetTapAction.", "whoSingsBestScore.", "musicTilesBest."]

    private static func isSynced(_ key: String) -> Bool {
        names.contains(key) || prefixes.contains { key.hasPrefix($0) }
    }

    private static func isScore(_ key: String) -> Bool {
        key.contains("BestScore") || key.hasPrefix("musicTilesBest.")
    }

    func localDocuments() -> [String] { ["settings"] }

    func snapshot(_ name: String) -> DocSnapshot? {
        guard name == "settings" else { return nil }
        var snapshot = DocSnapshot()
        for (key, value) in UserDefaults.standard.dictionaryRepresentation() where Self.isSynced(key) {
            guard let data = Self.json(value) else { continue }
            snapshot.sections[keys.tokenize(key)] = keys.tokenize(data)
        }
        return snapshot
    }

    func apply(_ name: String, sections: [String: Data]) -> Bool {
        let defaults = UserDefaults.standard
        for (section, data) in sections {
            let key = keys.detokenize(section)
            guard Self.isSynced(key) else { continue }
            if data == SyncValue.null {
                defaults.removeObject(forKey: key)
            } else if let value = Self.value(from: keys.detokenize(data)) {
                defaults.set(value, forKey: key)
            }
        }
        return true
    }

    func merge(section: String, local: Data, remote: Data) -> Data? {
        let key = keys.detokenize(section)
        if Self.isScore(key) {
            let ours = (Self.value(from: local) as? NSNumber)?.doubleValue ?? 0
            let theirs = (Self.value(from: remote) as? NSNumber)?.doubleValue ?? 0
            return ours >= theirs ? local : remote
        }
        if key == "replayedLines",
           let ours = Self.value(from: keys.detokenize(local)) as? [String: Int],
           let theirs = Self.value(from: keys.detokenize(remote)) as? [String: Int] {
            return Self.json(ours.merging(theirs, uniquingKeysWith: max)).map(keys.tokenize)
        }
        return nil
    }

    // MARK: Values

    static func json(_ value: Any) -> Data? {
        guard let converted = toJSON(value) else { return nil }
        return try? JSONSerialization.data(withJSONObject: [converted], options: [.sortedKeys, .fragmentsAllowed])
    }

    static func value(from data: Data) -> Any? {
        guard let array = (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) as? [Any], let first = array.first else { return nil }
        return fromJSON(first)
    }

    private static func toJSON(_ value: Any) -> Any? {
        switch value {
        case let data as Data: ["$data": data.base64EncodedString()]
        case let date as Date: ["$date": date.timeIntervalSince1970]
        case let string as String: string
        case let number as NSNumber: number
        case let array as [Any]: array.compactMap(toJSON)
        case let dictionary as [String: Any]: dictionary.compactMapValues(toJSON)
        default: nil
        }
    }

    private static func fromJSON(_ value: Any) -> Any? {
        switch value {
        case let dictionary as [String: Any]:
            if dictionary.count == 1, let base64 = dictionary["$data"] as? String { return Data(base64Encoded: base64) }
            if dictionary.count == 1, let interval = dictionary["$date"] as? Double { return Date(timeIntervalSince1970: interval) }
            return dictionary.compactMapValues(fromJSON)
        case let array as [Any]:
            return array.compactMap(fromJSON)
        case is NSNull:
            return nil
        default:
            return value
        }
    }
}

// MARK: - Keys

/// The user's own API keys and the music server's sign-in, encrypted in
/// their private iCloud database.
@MainActor
final class SecretsSyncDomain: SyncDomain {
    let prefix = "secrets"
    var propagatesDeletion: Bool { false }

    private struct Server: Codable, Equatable {
        var server: String
        var user: String
        var password: String
    }

    func localDocuments() -> [String] { ["secrets"] }

    func snapshot(_ name: String) -> DocSnapshot? {
        guard name == "secrets" else { return nil }
        var snapshot = DocSnapshot()
        if let key = AIFeatures.key(for: .mistral) { snapshot.sections["mistral"] = SyncValue.encode(key) }
        if let key = AIFeatures.key(for: .groq) { snapshot.sections["groq"] = SyncValue.encode(key) }
        if let key = AIFeatures.speechmaticsKey { snapshot.sections["speechmatics"] = SyncValue.encode(key) }
        if let key = MusicVideoFeature.apiKey { snapshot.sections["youtube"] = SyncValue.encode(key) }
        if let key = MusicVideoFeature.backupAPIKey { snapshot.sections["youtube2"] = SyncValue.encode(key) }
        if let login = SubsonicService.shared.syncCredentials {
            snapshot.sections["subsonic"] = SyncValue.encode(Server(server: login.server, user: login.user, password: login.password))
        } else {
            // Signing in takes a moment: never taken as signed out.
            snapshot.skipped.insert("subsonic")
        }
        return snapshot
    }

    func apply(_ name: String, sections: [String: Data]) -> Bool {
        for (section, data) in sections {
            let value = data == SyncValue.null ? nil : SyncValue.decode(String.self, from: data)
            switch section {
            case "mistral":
                // A key is never removed by another device: only added or replaced.
                if let value { AIFeatures.setKey(value, for: .mistral) }
            case "groq":
                if let value { AIFeatures.setKey(value, for: .groq) }
            case "speechmatics":
                if let value { AIFeatures.speechmaticsKey = value }
            case "youtube":
                if MusicVideoFeature.apiKey != value { MusicVideoFeature.apiKey = value }
            case "youtube2":
                if MusicVideoFeature.backupAPIKey != value { MusicVideoFeature.backupAPIKey = value }
            case "subsonic":
                guard let login = SyncValue.decode(Server.self, from: data) else { continue }
                let current = SubsonicService.shared.syncCredentials
                guard current?.server != login.server || current?.user != login.user || current?.password != login.password else { continue }
                Task { await SubsonicService.shared.connect(server: login.server, username: login.user, password: login.password) }
            default:
                break
            }
        }
        return true
    }
}

// MARK: - Playback session

/// What's playing, so another device can offer to pick it up.
@MainActor
final class SessionSyncDomain: SyncDomain {
    static let shared = SessionSyncDomain()

    private struct State: Codable {
        var device: String
        var deviceName: String
        var queue: [UUID]
        var index: Int
        var time: Double
        var updated: Date
    }

    let prefix = "session"
    var propagatesDeletion: Bool { false }
    /// The latest session, from this device or another (tokenized).
    private var current: Data?
    private var lastLocalUpdate: Date?
    private var cancellables = Set<AnyCancellable>()
    private var keys: SyncSongKeys { CloudSync.shared.keys }

    func observePlayer(_ changed: @escaping @MainActor () -> Void) {
        let player = MusicPlayerService.shared
        player.$currentSong.map { $0?.id }.removeDuplicates().dropFirst()
            .merge(with: player.$isPlaying.removeDuplicates().dropFirst().map { _ in player.currentSong?.id })
            .sink { [weak self] _ in
                // Published before the change lands.
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.captureLocal()
                        changed()
                    }
                }
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in self?.captureLocal() }
            .store(in: &cancellables)
    }

    private func captureLocal() {
        let player = MusicPlayerService.shared
        guard player.currentSong != nil, !player.queue.isEmpty, !PrivateListening.isOn else { return }
        let start = max(0, player.currentIndex - 100)
        let queue = Array(player.queue[start..<min(player.queue.count, start + 400)])
        let state = State(
            device: CloudSync.shared.deviceID,
            deviceName: SyncDevice.currentName,
            queue: queue.map(\.id),
            index: min(max(0, player.currentIndex - start), queue.count - 1),
            time: player.currentTime,
            updated: Date()
        )
        current = keys.tokenize(SyncValue.encode(state))
        lastLocalUpdate = state.updated
    }

    func localDocuments() -> [String] {
        current == nil ? [] : ["session"]
    }

    func snapshot(_ name: String) -> DocSnapshot? {
        guard name == "session", let current else { return nil }
        return DocSnapshot(sections: ["state": current])
    }

    func apply(_ name: String, sections: [String: Data]) -> Bool {
        guard let data = sections["state"], data != SyncValue.null else { return true }
        current = data
        guard let state = SyncValue.decode(State.self, from: keys.detokenize(data)),
              state.device != CloudSync.shared.deviceID,
              state.updated > (lastLocalUpdate ?? .distantPast),
              Date().timeIntervalSince(state.updated) < 12 * 3600,
              !MusicPlayerService.shared.isPlaying else { return true }
        let library = AppModel.shared.libraryService
        // Songs this device doesn't have are left out of the queue.
        var songs: [Song] = []
        var index: Int?
        for (offset, id) in state.queue.enumerated() {
            guard let song = library.song(withID: id) else { continue }
            if offset == state.index { index = songs.count }
            songs.append(song)
        }
        guard let index else { return true }
        CloudSync.shared.offerResume(SyncResumeOffer(id: state.updated, deviceName: state.deviceName, songs: songs, index: index, time: state.time))
        return true
    }
}

/// Songs whose lyrics were deleted by hand (Delete AI Lyrics, Remove LRC).
/// Only this tells a deletion from lyrics that failed to arrive, so only
/// it is ever passed on; it's dropped as soon as the song has lyrics again.
enum LyricsRemovals {
    struct Marker: Codable {
        var removed = true
    }

    private static let key = "lyricsRemovedByHand"

    private static var ids: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: key) ?? []) }
        set { UserDefaults.standard.set(newValue.sorted(), forKey: key) }
    }

    static func contains(_ id: UUID) -> Bool { ids.contains(id.uuidString) }

    static func insert(_ id: UUID) { ids.insert(id.uuidString) }

    static func remove(_ id: UUID) {
        guard contains(id) else { return }
        ids.remove(id.uuidString)
    }
}
