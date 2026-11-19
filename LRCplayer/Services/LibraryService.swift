import Foundation
import Combine
import AVFoundation
import AudioToolbox
import MediaPlayer
import UIKit

@MainActor
final class LibraryService: ObservableObject {
    @Published var songs: [Song] = [] {
        didSet {
            rebuildSongIndex()
            scheduleAutolistRefresh()
        }
    }
    @Published var playlists: [Playlist] = []
    /// Non-nil while a long library task runs (shown as a HUD).
    @Published var activityMessage: String?
    @Published var lastError: String?

    private let songsFileName = "songs.json"
    private let playlistsFileName = "playlists.json"
    private let lyricsFolderBookmarkKey = "lyricsFolderBookmark"
    private let metadataVersionKey = "libraryMetadataVersion"
    private static let currentMetadataVersion = 2
    private let fileManager = FileManager.default
    private var songIndexByID: [UUID: Int] = [:]
    private var pendingSave: DispatchWorkItem?
    private let saveQueue = DispatchQueue(label: "com.fares.lrc.player.library-save", qos: .utility)
    private var cancellables = Set<AnyCancellable>()

    init() {
        // Kept synchronous: the player state, the mini player and every screen
        // expect the library to be ready on the first frame. songs.json holds no
        // artwork anymore, so decoding it is cheap.
        Self.migrateLegacyDataFiles()
        songs = Self.loadItems(Song.self, from: songsFileName)
        playlists = Self.loadItems(Playlist.self, from: playlistsFileName)
        rebuildSongIndex()
        ListeningStatsService.shared.applyOnByDefault()
        seedPlayCountsFromHistory()
        refreshAutolists()

        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in self?.flushPendingSave() }
            .store(in: &cancellables)
        // Files copied in with Finder / the Files app show up on return.
        NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
            .sink { [weak self] _ in
                self?.scanDocumentsDirectory()
                // Time windows and the daily random pick move on their own.
                self?.scheduleAutolistRefresh()
                // The phone may have been synced from a Mac in the meantime.
                Task { await self?.reconcileMediaLibrary() }
            }
            .store(in: &cancellables)
        // History changes feed instant Autolists; midnight makes daily ones due.
        NotificationCenter.default.publisher(for: ListeningStatsService.historyDidChange)
            .merge(with: NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification))
            .sink { [weak self] _ in self?.scheduleAutolistRefresh() }
            .store(in: &cancellables)

        Task { [weak self] in
            guard let self else { return }
            // One-time migration: the library was decoded from the legacy
            // songs.json that embedded every artwork in base64; the files are on
            // disk now, so rewrite songs.json without them.
            if ArtworkStore.spilledLegacyData { saveLibrary() }
            await performLaunchMaintenance()
            await reconcileMediaLibrary()
            await importExistingFiles()
            await refreshMetadataIfNeeded()
        }
    }

    var documentsDirectory: URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
    }

    var musicDirectory: URL {
        let dir = documentsDirectory.appendingPathComponent("Music", isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    var lyricsDirectory: URL {
        let dir = documentsDirectory.appendingPathComponent("Lyrics", isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    // MARK: - Lookup

    private func rebuildSongIndex() {
        var index: [UUID: Int] = [:]
        index.reserveCapacity(songs.count)
        for (offset, song) in songs.enumerated() where index[song.id] == nil {
            index[song.id] = offset
        }
        songIndexByID = index
    }

    func song(withID id: UUID) -> Song? {
        guard let index = songIndexByID[id], songs.indices.contains(index) else { return nil }
        return songs[index]
    }

    func songsForPlaylist(_ playlist: Playlist) -> [Song] {
        playlist.songs.compactMap(song(withID:))
    }

    // MARK: - Persistence

    /// Coalesces bursts of edits (imports, migrations, reorders) into a single
    /// write, performed in order on a serial queue.
    func saveLibrary() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.writeLibraryNow() }
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// Entering the background: write now and wait, inside a background task,
    /// so a suspended app can't lose the last edits.
    private func flushPendingSave() {
        guard let pendingSave, !pendingSave.isCancelled else { return }
        pendingSave.cancel()
        self.pendingSave = nil
        let task = UIApplication.shared.beginBackgroundTask(withName: "Save Library")
        writeLibraryNow()
        saveQueue.sync {}
        UIApplication.shared.endBackgroundTask(task)
    }

    private func writeLibraryNow() {
        pendingSave = nil
        let songsSnapshot = songs
        let playlistsSnapshot = playlists
        let songsURL = Self.dataDirectory.appendingPathComponent(songsFileName)
        let playlistsURL = Self.dataDirectory.appendingPathComponent(playlistsFileName)
        saveQueue.async {
            let encoder = JSONEncoder()
            if let data = try? encoder.encode(songsSnapshot) {
                try? data.write(to: songsURL, options: .atomic)
            }
            if let data = try? encoder.encode(playlistsSnapshot) {
                try? data.write(to: playlistsURL, options: .atomic)
            }
        }
    }

    /// The library database lives in Application Support: Documents is shown
    /// in the Files app (file sharing is on, for importing music).
    nonisolated static let dataDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = base.appendingPathComponent("Library", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()

    /// Decodes record by record: one damaged entry is dropped instead of the
    /// whole library. An unreadable file is kept aside (never overwritten).
    nonisolated private static func loadItems<T: Decodable>(_ type: T.Type, from fileName: String) -> [T] {
        let url = dataDirectory.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url) else { return [] }
        if let items = try? JSONDecoder().decode([LossyDecodable<T>].self, from: data) {
            return items.compactMap(\.value)
        }
        let backup = url.deletingPathExtension()
            .appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970)).json")
        try? FileManager.default.copyItem(at: url, to: backup)
        return []
    }

    /// Moves files earlier builds kept in Documents.
    nonisolated private static func migrateLegacyDataFiles() {
        let fileManager = FileManager.default
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        for name in ["songs.json", "playlists.json"] {
            let legacy = documents.appendingPathComponent(name)
            let destination = dataDirectory.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: legacy.path) else { continue }
            if fileManager.fileExists(atPath: destination.path) {
                try? fileManager.removeItem(at: legacy)
            } else {
                try? fileManager.moveItem(at: legacy, to: destination)
            }
        }
        // Debug timing log written by older builds.
        try? fileManager.removeItem(at: documents.appendingPathComponent("measure.log"))
    }

    // MARK: - Songs

    func addSong(_ song: Song) {
        let isDuplicate = songs.contains { existing in
            if let lhs = existing.mediaLibraryPersistentID, let rhs = song.mediaLibraryPersistentID {
                return lhs == rhs
            }
            return existing.fileURL.path == song.fileURL.path
        }
        guard !isDuplicate else { return }
        songs.append(song)
        saveLibrary()
    }

    func removeSong(_ song: Song) {
        songs.removeAll { $0.id == song.id }
        playlists = playlists.map { playlist in
            var updated = playlist
            updated.songs.removeAll { $0 == song.id }
            updated.manualSongOrder?.removeAll { $0 == song.id }
            return updated
        }
        saveLibrary()
    }

    func deleteSong(_ song: Song) {
        removeSong(song)
        ArtworkStore.remove(for: song.id)
        if !song.isMediaLibraryItem {
            try? fileManager.removeItem(at: song.fileURL)
        }
    }

    func updateSong(_ song: Song) {
        guard let index = songIndexByID[song.id] else { return }
        songs[index] = song
        saveLibrary()
    }

    // MARK: - Playlists

    func createPlaylist(name: String, description: String = "", cover: PlaylistCover? = nil) -> Playlist {
        let playlist = Playlist(name: name, description: description, cover: cover)
        playlists.append(playlist)
        saveLibrary()
        return playlist
    }

    @discardableResult
    func createImportedPlaylist(session: SpotifyMatchSession, artworkDataOverride: Data? = nil) -> Playlist {
        let songIDs = session.orderedLocalSongIDs
        let playlist = Playlist(
            name: session.playlist.name,
            description: session.playlist.description,
            songs: songIDs,
            artworkData: artworkDataOverride, // nil → 2x2 mosaic generated on demand
            isSmartPlaylist: false,
            sortOrder: .manual,
            manualSongOrder: songIDs,
            importSource: session.importSource
        )
        playlists.append(playlist)
        saveLibrary()
        return playlist
    }

    func applyImportedPlaylist(session: SpotifyMatchSession, artworkDataOverride: Data? = nil) {
        if let existing = playlists.first(where: {
            $0.importSource?.url == session.sourceURL
                || ($0.importSource?.service == "spotify" && $0.importSource?.playlistID == session.playlist.id)
        }) {
            updateImportedPlaylist(id: existing.id, session: session, artworkDataOverride: artworkDataOverride)
        } else {
            createImportedPlaylist(session: session, artworkDataOverride: artworkDataOverride)
        }
    }

    func updateImportedPlaylist(id: UUID, session: SpotifyMatchSession, artworkDataOverride: Data? = nil) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        var updated = playlists[index]
        updated.name = session.playlist.name
        updated.description = session.playlist.description
        updated.songs = session.orderedLocalSongIDs
        updated.manualSongOrder = updated.songs
        updated.sortOrder = .manual
        updated.modifiedAt = Date()
        updated.importSource = session.importSource
        updated.artworkData = artworkDataOverride
        playlists[index] = updated
        saveLibrary()
    }

    func deletePlaylist(_ playlist: Playlist) {
        playlists.removeAll { $0.id == playlist.id }
        saveLibrary()
    }

    func renamePlaylist(_ playlist: Playlist, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = playlists.firstIndex(where: { $0.id == playlist.id }), !trimmed.isEmpty else { return }
        playlists[index].name = trimmed
        playlists[index].modifiedAt = Date()
        saveLibrary()
    }

    /// The playlist editor's Done: name and cover.
    func updatePlaylist(id: UUID, name: String, cover: PlaylistCover?) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = playlists.firstIndex(where: { $0.id == id }), !trimmed.isEmpty else { return }
        guard playlists[index].name != trimmed || playlists[index].cover != cover else { return }
        playlists[index].name = trimmed
        playlists[index].cover = cover
        playlists[index].modifiedAt = Date()
        saveLibrary()
    }

    /// A photo the user picked as the cover; shown as the playlist's own artwork.
    func setPlaylistArtwork(id: UUID, data: Data) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[index].artworkData = data
        playlists[index].cover = nil
        playlists[index].modifiedAt = Date()
        saveLibrary()
    }

    func addSongToPlaylist(songId: UUID, playlistId: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistId }),
              !playlists[index].songs.contains(songId) else { return }
        playlists[index].songs.append(songId)
        if playlists[index].manualSongOrder != nil {
            playlists[index].manualSongOrder?.append(songId)
        }
        playlists[index].modifiedAt = Date()
        saveLibrary()
    }

    func removeSongFromPlaylist(songId: UUID, playlistId: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistId }) else { return }
        playlists[index].songs.removeAll { $0 == songId }
        playlists[index].manualSongOrder?.removeAll { $0 == songId }
        playlists[index].modifiedAt = Date()
        saveLibrary()
    }

    func moveSongInPlaylist(playlistId: UUID, from: Int, to: Int) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistId }) else { return }
        var playlist = playlists[index]
        guard playlist.songs.indices.contains(from), to >= 0, to <= playlist.songs.count else { return }
        let songID = playlist.songs.remove(at: from)
        playlist.songs.insert(songID, at: to > from ? to - 1 : to)
        playlist.manualSongOrder = playlist.songs
        playlist.sortOrder = .manual
        playlist.modifiedAt = Date()
        playlists[index] = playlist
        saveLibrary()
    }

    func setPlaylistSongOrder(playlistId: UUID, songIds: [UUID]) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistId }) else { return }
        playlists[index].songs = songIds
        playlists[index].manualSongOrder = songIds
        playlists[index].sortOrder = .manual
        playlists[index].modifiedAt = Date()
        saveLibrary()
    }

    func setPlaylistSortOrder(_ playlist: Playlist, order: PlaylistSortOrder) {
        guard let index = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        var updated = playlists[index]

        if order == .manual {
            if updated.sortOrder != .manual, let manualOrder = updated.manualSongOrder {
                // Keep songs added while sorted, after the remembered order.
                let remembered = manualOrder.filter(updated.songs.contains)
                let added = updated.songs.filter { !remembered.contains($0) }
                updated.songs = remembered + added
            }
            updated.manualSongOrder = nil
        } else {
            if updated.sortOrder == .manual {
                updated.manualSongOrder = updated.songs
            }
            let songObjects = updated.songs.compactMap(song(withID:))
            let sorted: [Song]
            switch order {
            case .title:
                sorted = songObjects.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            case .artist:
                sorted = songObjects.sorted {
                    let artist = $0.artist.localizedStandardCompare($1.artist)
                    if artist != .orderedSame { return artist == .orderedAscending }
                    return $0.title.localizedStandardCompare($1.title) == .orderedAscending
                }
            case .dateAdded:
                sorted = songObjects.sorted { $0.addedAt > $1.addedAt }
            case .manual:
                sorted = songObjects
            }
            updated.songs = sorted.map(\.id)
        }

        updated.sortOrder = order
        updated.modifiedAt = Date()
        playlists[index] = updated
        saveLibrary()
    }

    // MARK: - Plays

    /// Counts a play (same rule as the listening history: 10 seconds), whether
    /// or not the history is recorded.
    func recordPlay(songID: UUID, at date: Date = Date()) {
        guard let index = songIndexByID[songID] else { return }
        songs[index].playCount += 1
        songs[index].lastPlayedAt = date
        saveLibrary()
    }

    /// Play counts weren't kept before Autolists: start them from the
    /// listening history, once.
    private func seedPlayCountsFromHistory() {
        let key = "playCountsSeededFromHistory"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        let entries = ListeningStatsService.shared.allEntries()
        guard !entries.isEmpty else { return }
        var counts: [UUID: Int] = [:]
        var lastPlayed: [UUID: Date] = [:]
        for entry in entries {
            counts[entry.songID, default: 0] += 1
            lastPlayed[entry.songID] = max(lastPlayed[entry.songID] ?? .distantPast, entry.timestamp)
        }
        var updated = songs
        var changed = false
        for index in updated.indices {
            let id = updated[index].id
            if let count = counts[id], count > updated[index].playCount {
                updated[index].playCount = count
                changed = true
            }
            if let date = lastPlayed[id], date > (updated[index].lastPlayedAt ?? .distantPast) {
                updated[index].lastPlayedAt = date
                changed = true
            }
        }
        guard changed else { return }
        songs = updated
        saveLibrary()
    }

    // MARK: - Autolists

    private var pendingAutolistRefresh: DispatchWorkItem?

    @discardableResult
    func createAutolist(_ rules: AutolistRules) -> Playlist {
        var playlist = Playlist(name: rules.name, autolist: rules)
        playlist.songs = AutolistEngine.songIDs(for: rules, in: songs, history: AutolistEngine.HistoryCounts())
        playlist.autolistUpdatedAt = Date()
        playlists.append(playlist)
        saveLibrary()
        return playlist
    }

    func updateAutolist(id: UUID, rules: AutolistRules) {
        guard let index = playlists.firstIndex(where: { $0.id == id }), playlists[index].isAutolist else { return }
        var updated = playlists[index]
        updated.autolist = rules
        updated.name = rules.name
        updated.songs = AutolistEngine.songIDs(for: rules, in: songs, history: AutolistEngine.HistoryCounts())
        updated.modifiedAt = Date()
        updated.autolistUpdatedAt = Date()
        playlists[index] = updated
        saveLibrary()
    }

    /// A new shuffled order (or a new random pick).
    func reshuffleAutolist(id: UUID) {
        guard let rules = playlists.first(where: { $0.id == id })?.autolist else { return }
        var reshuffled = rules
        reshuffled.seed = .random(in: .min ... .max)
        updateAutolist(id: id, rules: reshuffled)
    }

    /// Plays, imports and edits arrive in bursts: refresh once they settle.
    private func scheduleAutolistRefresh() {
        guard playlists.contains(where: \.isAutolist) else { return }
        pendingAutolistRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.refreshAutolists() }
        }
        pendingAutolistRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Picks the songs of one Autolist again now, whatever its frequency
    /// ("Refresh" in its menu).
    func refreshAutolist(id: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == id }),
              let rules = playlists[index].autolist else { return }
        var updated = playlists[index]
        let ids = AutolistEngine.songIDs(for: rules, in: songs, history: AutolistEngine.HistoryCounts())
        if ids != updated.songs {
            updated.songs = ids
            updated.modifiedAt = Date()
        }
        updated.autolistUpdatedAt = Date()
        playlists[index] = updated
        saveLibrary()
    }

    /// Recomputes the Autolists that are due: instant ones always, the others
    /// once their interval has passed. Playlists whose songs didn't change are
    /// left untouched (no republish, no save).
    func refreshAutolists() {
        pendingAutolistRefresh?.cancel()
        pendingAutolistRefresh = nil
        guard playlists.contains(where: \.isAutolist) else { return }
        let now = Date()
        var history: AutolistEngine.HistoryCounts?
        var updated = playlists
        var changed = false
        for index in updated.indices {
            guard let rules = updated[index].autolist else { continue }
            // Automatic names follow renamed selections (Workout → Up-Tempo).
            if rules.customName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, updated[index].name != rules.name {
                updated[index].name = rules.name
                changed = true
            }
            let lastUpdate = updated[index].autolistUpdatedAt
            let isDue = switch rules.refresh {
            case .instant: true
            case .manual: lastUpdate == nil
            default: lastUpdate.flatMap { rules.refresh.nextUpdate(after: $0) }.map { $0 <= now } ?? true
            }
            guard isDue else {
                // Waiting for its next update, but deleted songs still leave.
                let kept = updated[index].songs.filter { songIndexByID[$0] != nil }
                if kept.count != updated[index].songs.count {
                    updated[index].songs = kept
                    changed = true
                }
                continue
            }
            if history == nil { history = AutolistEngine.HistoryCounts() }
            let ids = AutolistEngine.songIDs(for: rules, in: songs, history: history!, now: now)
            if rules.refresh != .instant {
                updated[index].autolistUpdatedAt = now
                changed = true
            }
            guard ids != updated[index].songs else { continue }
            updated[index].songs = ids
            updated[index].modifiedAt = now
            changed = true
        }
        guard changed else { return }
        playlists = updated
        saveLibrary()
    }

    // MARK: - Importing files

    private var isScanningFiles = false

    /// Picks up audio files placed in Documents (or Documents/Music) outside
    /// the app: Finder file sharing, the Files app.
    func importExistingFiles() async {
        guard !isScanningFiles else { return }
        isScanningFiles = true
        defer { isScanningFiles = false }

        // Songs inside a merge stay out.
        let knownPaths = Set(songs.map(\.fileURL.standardizedFileURL.path)).union(SongMergeService.shared.mergedPartPaths)
        let newFiles = [documentsDirectory, musicDirectory]
            .flatMap { (try? fileManager.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? [] }
            .filter {
                Song.supportedAudioExtensions.contains($0.pathExtension.lowercased())
                    && !knownPaths.contains($0.standardizedFileURL.path)
            }
        guard !newFiles.isEmpty else { return }
        var imported: [Song] = []
        for url in newFiles {
            if let song = await Self.makeSong(fromFileAt: url) {
                imported.append(song)
            }
        }
        // Re-check: an import may have added the same file meanwhile.
        let currentPaths = Set(songs.map(\.fileURL.standardizedFileURL.path))
        let fresh = imported.filter { !currentPaths.contains($0.fileURL.standardizedFileURL.path) }
        guard !fresh.isEmpty else { return }
        songs.append(contentsOf: fresh)
        saveLibrary()
    }

    func scanDocumentsDirectory() {
        Task { await importExistingFiles() }
    }

    func createSongFromFile(url: URL) async -> Song? {
        await Self.makeSong(fromFileAt: url)
    }

    /// Reads a local file's tags off the main thread with the async AVFoundation
    /// API, falling back to AudioToolbox's info dictionary (FLAC, some MP3s).
    nonisolated static func makeSong(fromFileAt url: URL) async -> Song? {
        let metadata = await readMetadata(from: url)
        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        return Song(
            title: metadata.title ?? url.deletingPathExtension().lastPathComponent,
            artist: metadata.artist ?? "Unknown Artist",
            album: metadata.album ?? "Unknown Album",
            albumArtist: metadata.albumArtist,
            genre: metadata.genre ?? "",
            duration: metadata.duration,
            fileURL: url,
            artworkData: metadata.artwork,
            trackNumber: metadata.trackNumber,
            discNumber: metadata.discNumber,
            year: metadata.year,
            lrcFilePath: LRCParser.findLRC(for: url).map { storedLyricsPath($0.path) },
            fileSize: Int64(fileSize),
            format: url.pathExtension.lowercased()
        )
    }

    struct FileMetadata: Sendable {
        var title: String?
        var artist: String?
        var album: String?
        var albumArtist: String?
        var genre: String?
        var year = 0
        var trackNumber = 0
        var discNumber = 0
        var duration: TimeInterval = 0
        var artwork: Data?
    }

    nonisolated static func readMetadata(from url: URL, includeArtwork: Bool = true) async -> FileMetadata {
        var result = FileMetadata()
        let info = audioFileInfo(for: url)
        func infoString(_ key: String) -> String? {
            (info[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }

        let asset = AVURLAsset(url: url)
        if let duration = try? await asset.load(.duration) {
            let seconds = CMTimeGetSeconds(duration)
            result.duration = seconds.isFinite ? seconds : 0
        }

        var items = (try? await asset.load(.commonMetadata)) ?? []
        for format in (try? await asset.load(.availableMetadataFormats)) ?? [] {
            items += (try? await asset.loadMetadata(for: format)) ?? []
        }

        func string(_ identifiers: [AVMetadataIdentifier]) async -> String? {
            for identifier in identifiers {
                for item in AVMetadataItem.metadataItems(from: items, filteredByIdentifier: identifier) {
                    if let value = try? await item.load(.stringValue)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                        return value
                    }
                }
            }
            return nil
        }

        result.title = await string([.commonIdentifierTitle, .id3MetadataTitleDescription, .iTunesMetadataSongName]) ?? infoString("title")
        result.artist = await string([.commonIdentifierArtist, .id3MetadataLeadPerformer, .iTunesMetadataArtist]) ?? infoString("artist")
        result.album = await string([.commonIdentifierAlbumName, .id3MetadataAlbumTitle, .iTunesMetadataAlbum]) ?? infoString("album")
        result.albumArtist = await string([.iTunesMetadataAlbumArtist, .id3MetadataBand]) ?? infoString("album artist")
        result.genre = await string([.iTunesMetadataUserGenre, .id3MetadataContentType, .quickTimeMetadataGenre]).map(normalizedGenre) ?? infoString("genre").map(normalizedGenre)

        // Track & disc numbers: iTunes atoms are binary (index, total) pairs,
        // ID3 frames are "3/12" strings.
        func pair(_ identifier: AVMetadataIdentifier) async -> Int? {
            for item in AVMetadataItem.metadataItems(from: items, filteredByIdentifier: identifier) {
                if let data = try? await item.load(.dataValue), data.count >= 4 {
                    let value = Int(data[data.startIndex + 2]) << 8 | Int(data[data.startIndex + 3])
                    if value > 0 { return value }
                }
                if let number = try? await item.load(.numberValue)?.intValue, number > 0 { return number }
                if let text = try? await item.load(.stringValue), let value = leadingInteger(text), value > 0 { return value }
            }
            return nil
        }
        if let track = await pair(.iTunesMetadataTrackNumber) {
            result.trackNumber = track
        } else if let track = await pair(.id3MetadataTrackNumber) {
            result.trackNumber = track
        } else {
            result.trackNumber = infoString("track number").flatMap(leadingInteger) ?? 0
        }
        if let disc = await pair(.iTunesMetadataDiscNumber) {
            result.discNumber = disc
        } else {
            result.discNumber = await pair(.id3MetadataPartOfASet) ?? 0
        }

        result.year = audioFileYear(from: info)
        if result.year == 0 {
            for item in items {
                let key = (item.key.map { String(describing: $0) } ?? "").lowercased()
                let identifier = item.identifier?.rawValue.lowercased() ?? ""
                guard ["year", "tyer", "tdrc", "©day", "date"].contains(where: { key.contains($0) || identifier.contains($0) }) else { continue }
                if let date = try? await item.load(.dateValue) {
                    result.year = parsedYear(from: date)
                } else if let value = try? await item.load(.stringValue) {
                    result.year = parsedYear(from: value)
                } else if let number = try? await item.load(.numberValue) {
                    result.year = parsedYear(from: number)
                }
                if result.year > 0 { break }
            }
        }

        if includeArtwork {
            for item in AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .commonIdentifierArtwork) {
                if let data = try? await item.load(.dataValue), !data.isEmpty {
                    result.artwork = data
                    break
                }
            }
        }
        return result
    }

    /// ID3v1 numeric genres come through as "(17)"; keep the name when present.
    nonisolated private static func normalizedGenre(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("("), let close = trimmed.firstIndex(of: ")") {
            let rest = trimmed[trimmed.index(after: close)...].trimmingCharacters(in: .whitespaces)
            return rest.isEmpty ? trimmed : rest
        }
        return trimmed
    }

    nonisolated private static func leadingInteger(_ text: String) -> Int? {
        let digits = text.trimmingCharacters(in: .whitespaces).prefix { $0.isNumber }
        return Int(digits)
    }

    nonisolated private static func audioFileInfo(for url: URL) -> [String: Any] {
        guard url.isFileURL else { return [:] }
        var audioFile: AudioFileID?
        guard AudioFileOpenURL(url as CFURL, .readPermission, 0, &audioFile) == noErr, let audioFile else { return [:] }
        defer { AudioFileClose(audioFile) }

        var dictionary: Unmanaged<CFDictionary>?
        var size = UInt32(MemoryLayout<Unmanaged<CFDictionary>?>.size)
        guard AudioFileGetProperty(audioFile, kAudioFilePropertyInfoDictionary, &size, &dictionary) == noErr,
              let values = dictionary?.takeRetainedValue() as? [String: Any] else { return [:] }
        return Dictionary(values.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
    }

    nonisolated private static func audioFileYear(from info: [String: Any]) -> Int {
        for (key, value) in info where key.contains("year") || key.contains("date") {
            let year = parsedYear(from: value)
            if year > 0 { return year }
        }
        return 0
    }

    nonisolated private static func parsedYear(from value: Any?) -> Int {
        if let date = value as? Date {
            let year = Calendar(identifier: .gregorian).component(.year, from: date)
            return (1901...2099).contains(year) ? year : 0
        }
        if let number = value as? NSNumber, (1901...2099).contains(number.intValue) {
            return number.intValue
        }
        let string: String
        if let value = value as? String {
            string = value
        } else if let data = value as? Data, let value = String(data: data, encoding: .utf8) {
            string = value
        } else {
            return 0
        }
        guard let match = string.range(of: #"(?:19|20)\d{2}"#, options: .regularExpression),
              let year = Int(string[match]),
              (1901...2099).contains(year) else { return 0 }
        return year
    }

    nonisolated private static func mediaItemYear(from item: MPMediaItem) -> Int {
        // MPMediaItemPropertyYear exists at runtime but isn't in the Swift header.
        let tagged = parsedYear(from: item.value(forProperty: "year"))
        return tagged > 0 ? tagged : parsedYear(from: item.releaseDate)
    }

    // MARK: - Launch maintenance

    /// File checks for every song used to run on the main thread at launch.
    private func performLaunchMaintenance() async {
        let snapshot = songs
        let documents = documentsDirectory
        let repairs: [(UUID, URL?, String?)] = await Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            var result: [(UUID, URL?, String?)] = []
            for song in snapshot {
                var newURL: URL?
                if !song.isMediaLibraryItem, !fileManager.fileExists(atPath: song.fileURL.path),
                   let tail = Self.documentsRelativePath(from: song.fileURL.path) {
                    let candidate = documents.appendingPathComponent(tail)
                    if fileManager.fileExists(atPath: candidate.path) { newURL = candidate }
                }
                var newLyricsPath: String?
                if let stored = song.lrcFilePath, stored.hasPrefix("/") {
                    if let resolved = Self.resolveLyricsURL(stored: stored, documents: documents) {
                        let normalized = Self.storedLyricsPath(resolved.path)
                        if normalized != stored { newLyricsPath = normalized }
                    }
                }
                if newURL != nil || newLyricsPath != nil {
                    result.append((song.id, newURL, newLyricsPath))
                }
            }
            return result
        }.value

        defer { unlinkSharedGeneratedLyrics() }
        guard !repairs.isEmpty else { return }
        // Edit a copy and publish once (each element write would copy the
        // array, rebuild the index and notify every observer).
        var updated = songs
        for (id, url, lyricsPath) in repairs {
            guard let index = songIndexByID[id] else { continue }
            if let url { updated[index].fileURL = url }
            if let lyricsPath { updated[index].lrcFilePath = lyricsPath }
        }
        songs = updated
        saveLibrary()
    }

    nonisolated private static func documentsRelativePath(from absolutePath: String) -> String? {
        let components = absolutePath.split(separator: "/").map(String.init)
        guard let index = components.lastIndex(of: "Documents"), index + 1 < components.count else { return nil }
        return components[(index + 1)...].joined(separator: "/")
    }

    /// One-time metadata refresh. Earlier builds never read genre, track and
    /// disc numbers from local files (albums played in random order) and
    /// re-scanned every file without a year on every launch.
    private func refreshMetadataIfNeeded() async {
        let defaults = UserDefaults.standard
        guard defaults.integer(forKey: metadataVersionKey) < Self.currentMetadataVersion else { return }

        let snapshot = songs
        let isAuthorized = MPMediaLibrary.authorizationStatus() == .authorized
        let updates: [UUID: FileMetadata] = await Task.detached(priority: .utility) {
            var result: [UUID: FileMetadata] = [:]
            var mediaItems: [UInt64: MPMediaItem] = [:]
            if isAuthorized, snapshot.contains(where: \.isMediaLibraryItem) {
                for item in MPMediaQuery.songs().items ?? [] { mediaItems[item.persistentID] = item }
            }
            for song in snapshot {
                if song.isMediaLibraryItem {
                    guard let pid = song.mediaLibraryPersistentID, let item = mediaItems[pid] else { continue }
                    var metadata = FileMetadata()
                    metadata.genre = item.genre
                    metadata.trackNumber = item.albumTrackNumber
                    metadata.discNumber = item.discNumber
                    metadata.year = Self.mediaItemYear(from: item)
                    metadata.albumArtist = item.albumArtist
                    result[song.id] = metadata
                } else if FileManager.default.fileExists(atPath: song.fileURL.path) {
                    result[song.id] = await Self.readMetadata(from: song.fileURL, includeArtwork: false)
                }
            }
            return result
        }.value

        var didChange = false
        var updated = songs
        for (id, metadata) in updates {
            guard let index = songIndexByID[id] else { continue }
            var song = updated[index]
            var changed = false
            if song.genre.isEmpty, let genre = metadata.genre, !genre.isEmpty { song.genre = genre; changed = true }
            if song.trackNumber == 0, metadata.trackNumber > 0 { song.trackNumber = metadata.trackNumber; changed = true }
            if song.discNumber == 0, metadata.discNumber > 0 { song.discNumber = metadata.discNumber; changed = true }
            if song.year == 0, metadata.year > 0 { song.year = metadata.year; changed = true }
            if song.albumArtist == nil, let albumArtist = metadata.albumArtist, !albumArtist.isEmpty {
                song.albumArtist = albumArtist
                changed = true
            }
            if changed {
                updated[index] = song
                didChange = true
            }
        }
        if didChange {
            songs = updated
            saveLibrary()
        }
        defaults.set(Self.currentMetadataVersion, forKey: metadataVersionKey)
    }

    // MARK: - iOS media library

    func importPhoneMusicLibrary() async {
        let status = await requestMediaLibraryAccess()
        guard status == .authorized else {
            lastError = String(localized: "Music library access denied")
            return
        }
        activityMessage = String(localized: "Importing Library…")
        defer { activityMessage = nil }

        // Songs a re-sync orphaned get their tracks back first, instead of
        // being imported a second time.
        await reconcileMediaLibrary(force: true)

        let lyricsFolders = [resolvedLyricsFolderURL(), lyricsDirectory].compactMap { $0 }
        let knownPersistentIDs = Set(songs.compactMap(\.mediaLibraryPersistentID)).union(SongMergeService.shared.mergedPartPersistentIDs)
        let newSongs = await Task.detached(priority: .userInitiated) {
            let entries = Self.lyricsEntries(in: lyricsFolders)
            return (MPMediaQuery.songs().items ?? []).compactMap { item -> Song? in
                guard !knownPersistentIDs.contains(item.persistentID) else { return nil }
                return Self.createSongFromMediaItem(item, lrcEntries: entries)
            }
        }.value

        guard !newSongs.isEmpty else { return }
        songs.append(contentsOf: newSongs)
        saveLibrary()
    }

    func importPhoneMusicPlaylists() async {
        let status = await requestMediaLibraryAccess()
        guard status == .authorized else {
            lastError = String(localized: "Music library access denied")
            return
        }

        let localByPersistentID = Dictionary(
            songs.compactMap { song in song.mediaLibraryPersistentID.map { ($0, song.id) } },
            uniquingKeysWith: { first, _ in first }
        )
        let existingNames = Set(playlists.map(\.name))
        var imported = 0

        for collection in MPMediaQuery.playlists().collections ?? [] {
            guard let mediaPlaylist = collection as? MPMediaPlaylist,
                  let name = mediaPlaylist.name, !name.isEmpty,
                  !existingNames.contains(name) else { continue }
            let songIDs = mediaPlaylist.items.compactMap { localByPersistentID[$0.persistentID] }
            guard !songIDs.isEmpty else { continue }
            playlists.append(Playlist(
                name: name,
                songs: songIDs,
                artworkData: nil // the 2x2 mosaic is generated on demand
            ))
            imported += 1
        }

        if imported > 0 { saveLibrary() }
    }

    // MARK: Music library re-syncs

    private let mediaLibraryReconciledKey = "mediaLibraryReconciledAt"

    /// Reconnects the songs a Music library re-sync orphaned (see
    /// `MediaLibraryReconciler`) and folds the duplicates a re-import made
    /// into them: the originals keep their lyrics, play counts, listening
    /// history, playlists and pins. Runs when the Music library changed
    /// since the last check, or always with `force`.
    func reconcileMediaLibrary(force: Bool = false) async {
        guard MPMediaLibrary.authorizationStatus() == .authorized,
              songs.contains(where: \.isMediaLibraryItem) else { return }
        let modified = MPMediaLibrary.default().lastModifiedDate
        let defaults = UserDefaults.standard
        // v2 also takes titles, artists and albums: once more over a sync
        // already checked.
        let version = 2
        let isUpToDate = defaults.integer(forKey: "mediaLibraryReconcileVersion") >= version
        if !force, isUpToDate, let checked = defaults.object(forKey: mediaLibraryReconciledKey) as? Date, checked >= modified {
            return
        }

        let snapshot = songs.filter(\.isMediaLibraryItem).map { song in
            MediaLibraryReconciler.Song(
                id: song.id,
                persistentID: song.mediaLibraryPersistentID,
                title: song.title,
                artist: song.artist,
                album: song.album,
                duration: song.duration,
                trackNumber: song.trackNumber,
                discNumber: song.discNumber,
                addedAt: song.addedAt
            )
        }
        let (tracks, plan) = await Task.detached(priority: .utility) {
            let tracks = (MPMediaQuery.songs().items ?? []).compactMap { item -> MediaLibraryReconciler.Track? in
                guard item.persistentID != 0, let url = item.assetURL else { return nil }
                return MediaLibraryReconciler.Track(
                    persistentID: item.persistentID,
                    assetURL: url,
                    title: item.title ?? "Unknown Title",
                    artist: item.artist ?? "Unknown Artist",
                    album: item.albumTitle ?? "Unknown Album",
                    duration: item.playbackDuration,
                    trackNumber: item.albumTrackNumber,
                    discNumber: item.discNumber,
                    genre: item.genre ?? "",
                    year: Self.mediaItemYear(from: item)
                )
            }
            return (tracks, MediaLibraryReconciler.plan(songs: snapshot, tracks: tracks))
        }.value

        defaults.set(modified, forKey: mediaLibraryReconciledKey)
        defaults.set(version, forKey: "mediaLibraryReconcileVersion")
        let byPID = Dictionary(tracks.map { ($0.persistentID, $0) }, uniquingKeysWith: { first, _ in first })
        if !plan.isEmpty { apply(plan, tracks: byPID) }
        refreshTags(from: byPID)
    }

    /// Tags edited on the Mac (title, artist, album, numbers, genre, year)
    /// and a replaced file come over with the next sync, on the same
    /// tracks: the songs keep their history, only the tags change.
    private func refreshTags(from tracks: [UInt64: MediaLibraryReconciler.Track]) {
        var updated = songs
        var didChange = false
        var changed: [UUID: Song] = [:]
        for index in updated.indices {
            guard let pid = updated[index].mediaLibraryPersistentID, let track = tracks[pid] else { continue }
            var song = updated[index]
            var moved = false
            func set<T: Equatable>(_ path: WritableKeyPath<Song, T>, _ value: T, when valid: Bool = true) {
                guard valid, song[keyPath: path] != value else { return }
                song[keyPath: path] = value
                moved = true
            }
            // "Unknown …" is what an untagged track reads as: never over a name.
            set(\.title, track.title, when: track.title != "Unknown Title")
            set(\.artist, track.artist, when: track.artist != "Unknown Artist")
            set(\.album, track.album, when: track.album != "Unknown Album")
            set(\.trackNumber, track.trackNumber, when: track.trackNumber > 0)
            set(\.discNumber, track.discNumber, when: track.discNumber > 0)
            set(\.duration, track.duration, when: track.duration > 0 && abs(track.duration - song.duration) > 0.5)
            set(\.fileURL, track.assetURL)
            updated[index] = song
            if moved {
                didChange = true
                changed[updated[index].id] = updated[index]
            }
            let genre = Self.normalizedGenre(track.genre)
            if !genre.isEmpty, genre != updated[index].genre { updated[index].genre = genre; didChange = true }
            if track.year > 0, track.year != updated[index].year { updated[index].year = track.year; didChange = true }
        }
        guard didChange else { return }
        songs = updated
        saveLibrary()
        // The queue holds copies: it takes the new titles (and files).
        if !changed.isEmpty {
            NotificationCenter.default.post(name: Self.songsRelinked, object: self, userInfo: ["songs": changed])
        }
    }

    private func apply(_ plan: MediaLibraryReconciler.Plan, tracks: [UInt64: MediaLibraryReconciler.Track]) {
        var updated = songs
        let indexByID = Dictionary(updated.indices.map { (updated[$0].id, $0) }, uniquingKeysWith: { first, _ in first })

        for (id, persistentID) in plan.relinks {
            guard let index = indexByID[id], let track = tracks[persistentID] else { continue }
            updated[index].mediaLibraryPersistentID = persistentID
            updated[index].fileURL = track.assetURL
            updated[index].source = .mediaLibrary
            if track.duration > 0 { updated[index].duration = track.duration }
        }

        // Duplicate → the song that takes over (its history added in).
        var replacements: [UUID: UUID] = [:]
        for (duplicateID, keptID) in plan.merges {
            guard let duplicateIndex = indexByID[duplicateID], let keptIndex = indexByID[keptID] else { continue }
            let duplicate = updated[duplicateIndex]
            var kept = updated[keptIndex]
            if kept.lrcFilePath == nil { kept.lrcFilePath = duplicate.lrcFilePath }
            kept.playCount = max(kept.playCount, duplicate.playCount)
            kept.lastPlayedAt = [kept.lastPlayedAt, duplicate.lastPlayedAt].compactMap { $0 }.max()
            kept.addedAt = min(kept.addedAt, duplicate.addedAt)
            if kept.genre.isEmpty { kept.genre = duplicate.genre }
            if kept.year == 0 { kept.year = duplicate.year }
            if kept.trackNumber == 0 { kept.trackNumber = duplicate.trackNumber }
            if kept.discNumber == 0 { kept.discNumber = duplicate.discNumber }
            if kept.albumArtist == nil { kept.albumArtist = duplicate.albumArtist }
            if ArtworkStore.data(for: kept.id) == nil, let artwork = ArtworkStore.data(for: duplicate.id) {
                ArtworkStore.store(artwork, for: kept.id)
            }
            updated[keptIndex] = kept
            replacements[duplicateID] = keptID
        }

        updated.removeAll { replacements[$0.id] != nil }
        // Lyrics generated for a duplicate that the original didn't take.
        let keptLyrics = Set(updated.compactMap(\.lrcFilePath))
        for id in replacements.keys {
            ArtworkStore.remove(for: id)
            if let duplicate = indexByID[id].map({ songs[$0] }),
               LyricsGenerator.isGenerated(storedPath: duplicate.lrcFilePath),
               let path = duplicate.lrcFilePath, !keptLyrics.contains(path),
               let url = resolvedLyricsURL(for: duplicate) {
                try? fileManager.removeItem(at: url)
            }
        }

        if !replacements.isEmpty {
            playlists = playlists.map { playlist in
                var playlist = playlist
                playlist.songs = Self.replacing(replacements, in: playlist.songs)
                playlist.manualSongOrder = playlist.manualSongOrder.map { Self.replacing(replacements, in: $0) }
                if var source = playlist.importSource {
                    for index in source.matches.indices {
                        if let id = source.matches[index].localSongID, let kept = replacements[id] {
                            source.matches[index].localSongID = kept
                        }
                    }
                    playlist.importSource = source
                }
                return playlist
            }
            ListeningStatsService.shared.replaceSongIDs(replacements)
        }

        songs = updated
        saveLibrary()

        // The queue holds copies of the songs: hand it the relinked ones.
        var changed: [UUID: Song] = [:]
        for id in plan.relinks.keys { changed[id] = song(withID: id) }
        for (id, kept) in replacements { changed[id] = song(withID: kept) }
        NotificationCenter.default.post(name: Self.songsRelinked, object: self, userInfo: ["songs": changed])
    }

    /// Posted with `["songs": [UUID: Song]]`: songs to use in place of the
    /// ones with those IDs (relinked to a new track, or merged into another).
    static let songsRelinked = Notification.Name("LibraryService.songsRelinked")

    /// `ids` with each duplicate swapped for its original, dropped when the
    /// original is already there (a song added on purpose twice stays twice).
    private static func replacing(_ replacements: [UUID: UUID], in ids: [UUID]) -> [UUID] {
        let present = Set(ids)
        var swappedIn = Set<UUID>()
        return ids.compactMap { id in
            guard let kept = replacements[id] else { return id }
            guard !present.contains(kept), swappedIn.insert(kept).inserted else { return nil }
            return kept
        }
    }

    private func requestMediaLibraryAccess() async -> MPMediaLibraryAuthorizationStatus {
        let current = MPMediaLibrary.authorizationStatus()
        guard current == .notDetermined else { return current }
        return await withCheckedContinuation { continuation in
            MPMediaLibrary.requestAuthorization { @Sendable status in
                continuation.resume(returning: status)
            }
        }
    }

    nonisolated private static func createSongFromMediaItem(_ item: MPMediaItem, lrcEntries: [LyricsEntry]) -> Song? {
        let persistentID = item.persistentID
        // No asset URL: DRM-protected or cloud-only, which can't be played here.
        guard persistentID != 0, item.assetURL != nil else { return nil }

        var song = Song(
            title: item.title ?? "Unknown Title",
            artist: item.artist ?? "Unknown Artist",
            album: item.albumTitle ?? "Unknown Album",
            albumArtist: item.albumArtist,
            genre: item.genre ?? "",
            duration: item.playbackDuration,
            fileURL: item.assetURL ?? URL(string: "media-library://\(persistentID)")!,
            artworkData: item.artwork?.image(at: CGSize(width: 600, height: 600))?.jpegData(compressionQuality: 0.85),
            addedAt: item.dateAdded,
            // Plays from the Music app seed the Autolists.
            lastPlayedAt: item.lastPlayedDate,
            playCount: item.playCount,
            trackNumber: item.albumTrackNumber,
            discNumber: item.discNumber,
            year: mediaItemYear(from: item),
            format: "media",
            source: .mediaLibrary,
            mediaLibraryPersistentID: persistentID
        )
        song.lrcFilePath = bestLyricsMatch(for: song, in: lrcEntries).map { storedLyricsPath($0.path) }
        return song
    }

    // MARK: - Lyrics

    func setLyricsFolder(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(bookmark, forKey: lyricsFolderBookmarkKey)
        } catch {
            lastError = String(localized: "Couldn't save the lyrics folder: \(error.localizedDescription)")
            return
        }
        Task { await matchLyricsFromConfiguredFolder() }
    }

    func associateLyrics(url: URL, with song: Song) {
        guard let index = songIndexByID[song.id] else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        do {
            let destination = try FileImportService.placeFile(url, in: lyricsDirectory)
            songs[index].lrcFilePath = Self.storedLyricsPath(destination.path)
        } catch {
            lastError = String(localized: "Couldn't import the lyrics file: \(error.localizedDescription)")
            return
        }
        LyricsKindCache.invalidate(storedPath: songs[index].lrcFilePath)
        saveLibrary()
    }

    func setLyricsPath(_ storedPath: String?, for songID: UUID) {
        guard let index = songIndexByID[songID] else { return }
        LyricsKindCache.invalidate(storedPath: storedPath)
        songs[index].lrcFilePath = storedPath
        saveLibrary()
    }

    /// Unlinks the song's lyrics. Generated ones only exist for this song, so
    /// their file goes too (unless an older version shared it with another).
    func removeLRCLyrics(for song: Song) {
        if let current = self.song(withID: song.id),
           LyricsGenerator.isGenerated(storedPath: current.lrcFilePath),
           !songs.contains(where: { $0.id != song.id && $0.lrcFilePath == current.lrcFilePath }),
           let url = resolvedLyricsURL(for: current) {
            try? fileManager.removeItem(at: url)
        }
        WordSyncStore.delete(for: song.id)
        LyricsSingerStore.delete(for: song.id)
        // An AI sync of unsynced lyrics: back to those.
        let original = LyricsGenerator.isGenerated(storedPath: self.song(withID: song.id)?.lrcFilePath) ? LyricsGenerator.original(for: song.id) : nil
        LyricsGenerator.setOriginal(nil, for: song.id)
        setLyricsPath(original, for: song.id)
    }

    /// Where lyrics fetched or generated for `song` are written. The song's ID
    /// is part of the name: an artist's redux, a live take or a remaster often
    /// shares the title (even the album), and must never write over the
    /// original's lyrics.
    func ownLyricsURL(for song: Song, in folder: URL) -> URL {
        let name = "\(song.title) - \(song.artist)"
            .components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>"))
            .joined(separator: "-")
        return folder.appendingPathComponent("\(name) [\(song.id.uuidString)].lrc")
    }

    /// Older versions named generated lyrics after the title and artist only,
    /// so generating a namesake's lyrics overwrote the first song's file and
    /// both ended up linked to it. The file names its album: songs from
    /// another album are unlinked (they show No Lyrics, ready to generate
    /// again); when the album can't tell them apart, the links stay.
    private func unlinkSharedGeneratedLyrics() {
        let shared = Dictionary(grouping: songs.filter { LyricsGenerator.isGenerated(storedPath: $0.lrcFilePath) }) { $0.lrcFilePath! }
            .filter { $0.value.count > 1 }
        guard !shared.isEmpty else { return }
        var updated = songs
        var unlinked = false
        for (_, group) in shared {
            guard let url = resolvedLyricsURL(for: group[0]),
                  let album = LRCParser.parse(url: url)?.metadata["al"] else { continue }
            let owners = group.filter { $0.album.caseInsensitiveCompare(album) == .orderedSame }
            guard !owners.isEmpty, owners.count < group.count else { continue }
            for song in group where !owners.contains(where: { $0.id == song.id }) {
                guard let index = songIndexByID[song.id] else { continue }
                updated[index].lrcFilePath = nil
                unlinked = true
            }
        }
        guard unlinked else { return }
        songs = updated
        saveLibrary()
    }

    nonisolated static func storedLyricsPath(_ absolutePath: String) -> String {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!.path + "/"
        return absolutePath.hasPrefix(documents) ? String(absolutePath.dropFirst(documents.count)) : absolutePath
    }

    func storedLyricsPath(for path: String) -> String {
        Self.storedLyricsPath(path)
    }

    func resolvedLyricsURL(for song: Song) -> URL? {
        guard let stored = song.lrcFilePath, !stored.isEmpty else { return nil }
        return Self.resolveLyricsURL(stored: stored, documents: documentsDirectory)
    }

    nonisolated static func resolveLyricsURL(stored: String, documents: URL) -> URL? {
        let fileManager = FileManager.default
        if stored.hasPrefix("/") {
            if fileManager.fileExists(atPath: stored) { return URL(fileURLWithPath: stored) }
            // Absolute paths break when the app container moves (reinstall).
            let name = URL(fileURLWithPath: stored).lastPathComponent
            for directory in ["Lyrics", "Music", ""] {
                let candidate = documents.appendingPathComponent(directory).appendingPathComponent(name)
                if fileManager.fileExists(atPath: candidate.path) { return candidate }
            }
            return nil
        }
        let absolute = documents.appendingPathComponent(stored)
        return fileManager.fileExists(atPath: absolute.path) ? absolute : nil
    }

    /// Copies the configured folder's lyrics into the app and matches them to
    /// songs without lyrics. Everything but the final assignment runs off the
    /// main thread (it used to freeze the UI behind the loading overlay).
    func matchLyricsFromConfiguredFolder() async {
        guard let folder = resolvedLyricsFolderURL() else { return }
        activityMessage = String(localized: "Matching Lyrics…")
        defer { activityMessage = nil }

        let snapshot = songs
        let lyricsDirectory = lyricsDirectory
        let matches: [UUID: String] = await Task.detached(priority: .userInitiated) {
            let scoped = folder.startAccessingSecurityScopedResource()
            defer { if scoped { folder.stopAccessingSecurityScopedResource() } }

            let fileManager = FileManager.default
            let entries = Self.lyricsEntries(in: [folder, lyricsDirectory])
            for entry in entries where entry.url.deletingLastPathComponent().standardizedFileURL != lyricsDirectory.standardizedFileURL {
                let destination = lyricsDirectory.appendingPathComponent(entry.url.lastPathComponent)
                if !fileManager.fileExists(atPath: destination.path) {
                    try? fileManager.copyItem(at: entry.url, to: destination)
                }
            }

            var result: [UUID: String] = [:]
            for song in snapshot where song.resolvedLyricsFileURL() == nil {
                guard let match = Self.bestLyricsMatch(for: song, in: entries) else { continue }
                let destination = lyricsDirectory.appendingPathComponent(match.lastPathComponent)
                result[song.id] = Self.storedLyricsPath(destination.path)
            }
            return result
        }.value

        guard !matches.isEmpty else { return }
        var updated = songs
        for (id, path) in matches {
            guard let index = songIndexByID[id] else { continue }
            LyricsKindCache.invalidate(storedPath: path)
            updated[index].lrcFilePath = path
        }
        songs = updated
        saveLibrary()
    }

    /// A local lyrics file corrected in the app is corrected at its source
    /// too (the lyrics folder), so a later import doesn't bring the old back.
    func writeSourceLyrics(_ content: String, fileName: String) {
        guard let folder = resolvedLyricsFolderURL() else { return }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        for entry in Self.lyricsEntries(in: [folder]) where entry.url.lastPathComponent == fileName {
            try? content.write(to: entry.url, atomically: false, encoding: .utf8)
        }
    }

    private func resolvedLyricsFolderURL() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: lyricsFolderBookmarkKey) else { return nil }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale) else { return nil }
        if isStale {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let refreshed = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
                UserDefaults.standard.set(refreshed, forKey: lyricsFolderBookmarkKey)
            }
        }
        return url
    }

    // MARK: - Lyrics matching

    struct LyricsEntry: Sendable {
        let url: URL
        let keys: Set<String>
    }

    nonisolated private static func lyricsEntries(in folders: [URL]) -> [LyricsEntry] {
        var seen = Set<String>()
        var entries: [LyricsEntry] = []
        for folder in folders {
            guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { continue }
            for file in files where ["lrc", "txt"].contains(file.pathExtension.lowercased()) {
                if seen.insert(file.standardizedFileURL.path).inserted {
                    entries.append(LyricsEntry(url: file, keys: candidateLyricsKeys(for: file)))
                }
            }
        }
        return entries
    }

    nonisolated private static func bestLyricsMatch(for song: Song, in entries: [LyricsEntry]) -> URL? {
        let audioName = song.fileURL.deletingPathExtension().lastPathComponent
            .trimmingCharacters(in: .whitespaces).lowercased()
        let titleKey = normalizedLyricsKey(song.title)
        let artistKey = normalizedLyricsKey(song.artist)
        let albumKey = normalizedLyricsKey(song.album)
        let songKeys = lyricsMatchKeys(for: song)

        if let match = entries.first(where: {
            lyricsFilenameAgrees($0.url, audioName: audioName, songTitleKey: titleKey, songArtistKey: artistKey, songAlbumKey: albumKey)
        }) {
            return match.url
        }
        return entries.first(where: { entry in
            lyricsMetadataAgrees(entry.url, songArtistKey: artistKey, songAlbumKey: albumKey)
                && !entry.keys.isDisjoint(with: songKeys)
        })?.url
    }

    nonisolated private static func lyricsFilenameAgrees(_ url: URL, audioName: String, songTitleKey: String, songArtistKey: String, songAlbumKey: String) -> Bool {
        let rawName = url.deletingPathExtension().lastPathComponent
            .trimmingCharacters(in: .whitespaces).lowercased()
        let parts = parsedLyricsParts(url)

        if rawName == audioName || normalizedLyricsKey(rawName) == songTitleKey {
            return lyricsMetadataAgrees(url, songArtistKey: songArtistKey, songAlbumKey: songAlbumKey)
        }
        guard parts.count >= 2 else { return false }

        let firstKey = normalizedLyricsKey(parts[0])
        let lastKey = normalizedLyricsKey(parts[parts.count - 1])
        if firstKey == songArtistKey || firstKey == songAlbumKey {
            if parts.count >= 3 {
                guard !songAlbumKey.isEmpty, normalizedLyricsKey(parts[1]) == songAlbumKey else { return false }
            }
            return lastKey == songTitleKey
        }
        if lastKey == songArtistKey {
            return firstKey == songTitleKey
        }
        return false
    }

    nonisolated private static func lyricsMetadataAgrees(_ url: URL, songArtistKey: String, songAlbumKey: String) -> Bool {
        let parts = parsedLyricsParts(url)
        if parts.count >= 3 {
            guard !songAlbumKey.isEmpty, normalizedLyricsKey(parts[1]) == songAlbumKey else { return false }
        }
        if songArtistKey.isEmpty && songAlbumKey.isEmpty { return true }
        guard parts.count >= 2 else { return true }
        let firstKey = normalizedLyricsKey(parts[0])
        let lastKey = normalizedLyricsKey(parts[parts.count - 1])
        return firstKey == songArtistKey || firstKey == songAlbumKey || lastKey == songArtistKey
    }

    nonisolated private static func parsedLyricsParts(_ url: URL) -> [String] {
        let stripped = url.deletingPathExtension().lastPathComponent
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: #"^\s*\d{1,3}\s*[-–—‐._]+\s*"#, with: "", options: .regularExpression)
        return stripped.components(separatedBy: " - ")
            .flatMap { $0.components(separatedBy: " – ") }
            .flatMap { $0.components(separatedBy: " — ") }
            .flatMap { $0.components(separatedBy: " ‐ ") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    nonisolated private static func lyricsMatchKeys(for song: Song) -> Set<String> {
        let audioFileName = song.fileURL.deletingPathExtension().lastPathComponent
        let audioWithoutTrack = audioFileName
            .replacingOccurrences(of: #"^\s*\d{1,3}\s*[-–—‐._]+\s*"#, with: "", options: .regularExpression)
        return Set([
            song.title,
            "\(song.artist) \(song.title)",
            "\(song.title) \(song.artist)",
            "\(song.album) \(song.title)",
            audioFileName,
            audioWithoutTrack
        ].map(normalizedLyricsKey).filter { !$0.isEmpty })
    }

    nonisolated private static func candidateLyricsKeys(for url: URL) -> Set<String> {
        let rawName = url.deletingPathExtension().lastPathComponent
        let withoutTrackPrefix = rawName.replacingOccurrences(of: #"^\s*\d{1,3}\s*[-–—‐._]+\s*"#, with: "", options: .regularExpression)
        let separatorsAsSpaces = withoutTrackPrefix.replacingOccurrences(of: #"[-–—‐_.]+"#, with: " ", options: .regularExpression)
        let withoutArtistPrefix = withoutTrackPrefix
            .replacingOccurrences(of: #"^(.+?)\s*[-–—‐]\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[-–—‐_.]+"#, with: " ", options: .regularExpression)
        let lastPartRaw = withoutTrackPrefix.replacingOccurrences(of: #"^.*\s*[-–—‐]\s*"#, with: "", options: .regularExpression)
        let lastPart = lastPartRaw.replacingOccurrences(of: #"[-–—‐_.]+"#, with: " ", options: .regularExpression)

        return Set([rawName, withoutTrackPrefix, separatorsAsSpaces, withoutArtistPrefix, lastPart, lastPartRaw]
            .map(normalizedLyricsKey)
            .filter { !$0.isEmpty })
    }

    nonisolated private static func normalizedLyricsKey(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"[–—‐]"#, with: "-", options: .regularExpression)
            .replacingOccurrences(of: "/", with: ":")
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Queries

    func search(query: String) -> [Song] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return songs }
        return songs.filter {
            $0.title.localizedStandardContains(trimmed)
                || $0.artist.localizedStandardContains(trimmed)
                || ($0.albumArtist?.localizedStandardContains(trimmed) ?? false)
                || $0.album.localizedStandardContains(trimmed)
        }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// Decodes an element if possible, `nil` otherwise (for lenient arrays).
struct LossyDecodable<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}
