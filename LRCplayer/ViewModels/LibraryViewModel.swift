import Foundation
import Combine
import SwiftUI

@MainActor
final class LibraryViewModel: ObservableObject {
    @Published private(set) var songs: [Song] = []
    @Published private(set) var playlists: [Playlist] = []
    @Published private(set) var index = LibraryIndex()

    /// The playlist editor sheet (new, or editing an existing one).
    @Published var playlistEditor: PlaylistEditorRequest?
    /// "Edit Info…" on an imported song.
    @Published var songEditor: Song?
    @Published var songPendingLRCAssociation: Song?
    /// The Autolist editor sheet (new, or editing an existing one).
    @Published var autolistEditor: AutolistEditorRequest?
    @Published var pinnedAlbums: [String: Date] = [:]
    @Published var pinnedPlaylists: [String: Date] = [:]
    @Published var coversSnakeSession: CoversSnakeSession?
    @Published var guessLyricsSession: GuessLyricsSession?
    @Published var whatSongSession: WhatSongSession?
    @Published var whoSingsSession: WhoSingsSession?

    let libraryService: LibraryService
    private var cancellables = Set<AnyCancellable>()
    private var indexTask: Task<Void, Never>?

    var albums: [Album] { index.albums }
    var artists: [Artist] { index.artists }
    var genres: [Genre] { index.genres }
    var hasSongs: Bool { !songs.isEmpty }

    init(libraryService: LibraryService) {
        self.libraryService = libraryService
        songs = libraryService.songs
        playlists = libraryService.playlists
        index = LibraryIndex(songs: songs)

        pinnedAlbums = (UserDefaults.standard.object(forKey: "pinnedAlbums") as? [String: Date]) ?? [:]
        pinnedPlaylists = (UserDefaults.standard.object(forKey: "pinnedPlaylists") as? [String: Date]) ?? [:]

        libraryService.$songs
            .dropFirst()
            .sink { [weak self] songs in
                self?.songs = songs
                self?.scheduleIndexRebuild(for: songs)
            }
            .store(in: &cancellables)

        // An artist merged or unmerged: the pages and lists regroup.
        NotificationCenter.default.publisher(for: ArtistMerges.didChange)
            .sink { [weak self] _ in
                guard let self else { return }
                self.scheduleIndexRebuild(for: self.songs)
            }
            .store(in: &cancellables)

        libraryService.$playlists
            .dropFirst()
            .sink { [weak self] playlists in self?.playlists = playlists }
            .store(in: &cancellables)
    }

    /// Grouping and sorting thousands of songs runs off the main thread; edits
    /// arrive in bursts, so only the latest snapshot is indexed.
    private func scheduleIndexRebuild(for songs: [Song]) {
        indexTask?.cancel()
        indexTask = Task { [weak self] in
            let index = await Task.detached(priority: .userInitiated) { LibraryIndex(songs: songs) }.value
            guard !Task.isCancelled else { return }
            self?.index = index
        }
    }

    // MARK: - Lookup

    func album(withID id: AlbumID) -> Album? {
        index.albumsByID[id]
    }

    func album(containing song: Song) -> Album? {
        index.albumIDBySongID[song.id].flatMap { index.albumsByID[$0] }
    }

    func artist(named name: String) -> Artist? {
        index.artistsByName[name] ?? index.artistsByName[ArtistMerges.main(for: name)]
    }

    func artist(for song: Song) -> Artist? {
        index.artistsByName[LibraryIndex.artistName(for: song)] ?? index.artistsByName[song.artist]
    }

    func genre(named name: String) -> Genre? {
        index.genresByName[name]
    }

    func playlist(withID id: UUID) -> Playlist? {
        playlists.first { $0.id == id }
    }

    /// Playlists songs can be added to by hand (Autolists fill themselves).
    var editablePlaylists: [Playlist] {
        playlists.filter { !$0.isAutolist }
    }

    func songs(in playlist: Playlist) -> [Song] {
        libraryService.songsForPlaylist(playlist)
    }

    /// The cover picked in the editor, else the playlist's imported artwork,
    /// else Apple Music's 2x2 mosaic of its first
    /// four albums, else its first song's cover.
    func playlistArtwork(_ playlist: Playlist) -> ArtworkSource? {
        if let rules = playlist.autolist {
            return rules.usesMix ? mosaicArtwork(playlist) : .generated(rules.cover)
        }
        switch playlist.cover {
        case let .generated(palette):
            return .generated(playlist.generatedCover(palette))
        case let .styled(palette, style):
            return .generated(playlist.generatedCover(palette, style: style))
        case .mosaic:
            return mosaicArtwork(playlist)
        case nil:
            if let data = playlist.artworkData, !data.isEmpty {
                return .data(data, id: playlist.id)
            }
            return mosaicArtwork(playlist)
        }
    }

    func mosaicArtwork(_ playlist: Playlist) -> ArtworkSource? {
        var seenAlbums = Set<AlbumID>()
        var mosaicSongs: [UUID] = []
        for songID in playlist.songs {
            guard let albumID = index.albumIDBySongID[songID], seenAlbums.insert(albumID).inserted else { continue }
            mosaicSongs.append(songID)
            if mosaicSongs.count == 4 { return .mosaic(mosaicSongs) }
        }
        return playlist.songs.first.map(ArtworkSource.song)
    }

    /// The album or playlist the queue was started from (widget deep link,
    /// "Go to Album" from the player).
    func collectionRoute(for song: Song, queue: [Song]) -> LibraryRoute? {
        let queueIDs = queue.map(\.id)
        if let album = album(containing: song) {
            let albumIDs = Set(album.songs.map(\.id))
            if !queueIDs.isEmpty, queueIDs.allSatisfy(albumIDs.contains) {
                return .album(album.id)
            }
        }
        let queueSet = Set(queueIDs)
        if !queueSet.isEmpty, let playlist = playlists.first(where: { Set($0.songs) == queueSet }) {
            return .playlist(playlist.id)
        }
        return album(containing: song).map { .album($0.id) }
    }

    // MARK: - Actions

    func importPhoneMusicLibrary() {
        Task { await libraryService.importPhoneMusicLibrary() }
    }

    func importPhoneMusicPlaylists() {
        Task { await libraryService.importPhoneMusicPlaylists() }
    }

    func selectLyricsFolder(_ url: URL) {
        libraryService.setLyricsFolder(url)
    }

    func beginLyricsAssociation(for song: Song) {
        songPendingLRCAssociation = song
    }

    func associateSelectedLyrics(_ url: URL) {
        guard let song = songPendingLRCAssociation else { return }
        libraryService.associateLyrics(url: url, with: song)
        songPendingLRCAssociation = nil
    }

    func presentCoversSnake(title: String, songs: [Song]) {
        guard !songs.isEmpty else { return }
        coversSnakeSession = CoversSnakeSession(title: title, songs: songs)
    }

    func presentGuessLyrics(songs: [Song]) {
        let playable = songs.filter { $0.lyricsKind == .synced }
        guard !playable.isEmpty else { return }
        guessLyricsSession = GuessLyricsSession(songs: playable)
    }

    func presentWhatSong(songs: [Song], snippetDuration: TimeInterval, difficulty: WhatSongDifficulty) {
        let playable = songs.filter { $0.isExcerptPlayable }
        guard playable.count >= 2 else { return }
        whatSongSession = WhatSongSession(songs: playable, snippetDuration: snippetDuration, difficulty: difficulty)
    }

    func presentWhoSings(songs: [Song], difficulty: WhatSongDifficulty) {
        guard WhoSingsSettings.artistCount(songs) >= WhoSingsSettings.minimumArtists else { return }
        whoSingsSession = WhoSingsSession(songs: songs, difficulty: difficulty)
    }

    func deleteSong(_ song: Song) {
        libraryService.deleteSong(song)
    }

    /// "New Playlist…"; `song` is added to it ("Add to Playlist → New…").
    func requestNewPlaylist(adding song: Song? = nil) {
        playlistEditor = PlaylistEditorRequest(playlistID: nil, song: song)
    }

    /// "Add to Playlist → New…" from an album or a playlist.
    func requestNewPlaylist(adding songs: [Song]) {
        playlistEditor = PlaylistEditorRequest(playlistID: nil, songs: songs)
    }

    func addToPlaylist(songs: [Song], playlistId: UUID) {
        songs.forEach { libraryService.addSongToPlaylist(songId: $0.id, playlistId: playlistId) }
    }

    func requestEdit(ofPlaylist playlist: Playlist) {
        playlistEditor = PlaylistEditorRequest(playlistID: playlist.id, song: nil)
    }

    @discardableResult
    func createPlaylist(name: String, cover: PlaylistCover?, adding songs: [Song] = []) -> Playlist? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let playlist = libraryService.createPlaylist(name: trimmed, cover: cover)
        songs.forEach { libraryService.addSongToPlaylist(songId: $0.id, playlistId: playlist.id) }
        return playlist
    }

    func updatePlaylist(id: UUID, name: String, cover: PlaylistCover?) {
        libraryService.updatePlaylist(id: id, name: name, cover: cover)
    }

    func setPlaylistArtwork(id: UUID, data: Data) {
        libraryService.setPlaylistArtwork(id: id, data: data)
    }

    func addToPlaylist(songId: UUID, playlistId: UUID) {
        libraryService.addSongToPlaylist(songId: songId, playlistId: playlistId)
    }

    func removeFromPlaylist(songId: UUID, playlistId: UUID) {
        libraryService.removeSongFromPlaylist(songId: songId, playlistId: playlistId)
    }

    func moveSongInPlaylist(playlistId: UUID, from: Int, to: Int) {
        libraryService.moveSongInPlaylist(playlistId: playlistId, from: from, to: to)
    }

    func setPlaylistSortOrder(_ playlist: Playlist, order: PlaylistSortOrder) {
        libraryService.setPlaylistSortOrder(playlist, order: order)
    }

    func setPlaylistSongOrder(playlistId: UUID, songIds: [UUID]) {
        libraryService.setPlaylistSongOrder(playlistId: playlistId, songIds: songIds)
    }

    // MARK: - Autolists

    func requestNewAutolist() {
        var rules = AutolistRules()
        rules.style = .waves
        autolistEditor = AutolistEditorRequest(playlistID: nil, rules: rules)
    }

    func requestEdit(of playlist: Playlist) {
        guard let rules = playlist.autolist else { return }
        autolistEditor = AutolistEditorRequest(playlistID: playlist.id, rules: rules)
    }

    @discardableResult
    func createAutolist(_ rules: AutolistRules) -> Playlist {
        libraryService.createAutolist(rules)
    }

    func updateAutolist(id: UUID, rules: AutolistRules) {
        libraryService.updateAutolist(id: id, rules: rules)
    }

    func reshuffleAutolist(id: UUID) {
        libraryService.reshuffleAutolist(id: id)
    }

    func refreshAutolist(id: UUID) {
        libraryService.refreshAutolist(id: id)
    }

    /// What the rules would pick right now (the editor's live count).
    func previewAutolist(_ rules: AutolistRules, history: AutolistEngine.HistoryCounts) -> [UUID] {
        AutolistEngine.songIDs(for: rules, in: songs, history: history)
    }

    func deletePlaylist(_ playlist: Playlist) {
        libraryService.deletePlaylist(playlist)
        if pinnedPlaylists.removeValue(forKey: playlist.id.uuidString) != nil {
            UserDefaults.standard.set(pinnedPlaylists, forKey: "pinnedPlaylists")
        }
    }

    // MARK: - Pins

    func isAlbumPinned(_ id: AlbumID) -> Bool {
        pinnedAlbums[id.pinKey] != nil
    }

    func toggleAlbumPin(_ id: AlbumID) {
        if pinnedAlbums.removeValue(forKey: id.pinKey) == nil {
            pinnedAlbums[id.pinKey] = Date()
        }
        UserDefaults.standard.set(pinnedAlbums, forKey: "pinnedAlbums")
    }

    func isPlaylistPinned(id: UUID) -> Bool {
        pinnedPlaylists[id.uuidString] != nil
    }

    func togglePlaylistPin(id: UUID) {
        if pinnedPlaylists.removeValue(forKey: id.uuidString) == nil {
            pinnedPlaylists[id.uuidString] = Date()
        }
        UserDefaults.standard.set(pinnedPlaylists, forKey: "pinnedPlaylists")
    }

    /// A pin, under the key it's stored with.
    private enum PinRef: Equatable {
        case album(String)
        case playlist(String)
    }

    /// Every pin, first pinned first: the order of the Pinned shelf and of the
    /// pinned playlists atop Playlists.
    private var pinOrder: [PinRef] {
        let albums = pinnedAlbums.map { (PinRef.album($0.key), $0.value) }
        let playlists = pinnedPlaylists.map { (PinRef.playlist($0.key), $0.value) }
        return (albums + playlists).sorted { $0.1 < $1.1 }.map(\.0)
    }

    /// Stores `order` as pin dates a second apart, all in the past: anything
    /// pinned afterwards still lands at the end.
    private func savePinOrder(_ order: [PinRef]) {
        let start = Date().addingTimeInterval(-TimeInterval(order.count + 1))
        for (index, ref) in order.enumerated() {
            let date = start.addingTimeInterval(TimeInterval(index))
            switch ref {
            case let .album(key): pinnedAlbums[key] = date
            case let .playlist(key): pinnedPlaylists[key] = date
            }
        }
        UserDefaults.standard.set(pinnedAlbums, forKey: "pinnedAlbums")
        UserDefaults.standard.set(pinnedPlaylists, forKey: "pinnedPlaylists")
    }

    /// Saves a new order for the Pinned shelf.
    func setPinnedOrder(_ items: [HomeItem]) {
        savePinOrder(items.map { item in
            switch item {
            case let .album(album): .album(pinKey(of: album))
            case let .playlist(playlist): .playlist(playlist.id.uuidString)
            }
        })
    }

    /// Pinned playlists, first pinned first.
    var orderedPinnedPlaylists: [Playlist] {
        pinOrder.compactMap { ref in
            guard case let .playlist(key) = ref, let id = UUID(uuidString: key) else { return nil }
            return playlist(withID: id)
        }
    }

    /// Reorders the pinned playlists (offsets into `orderedPinnedPlaylists`);
    /// pinned albums keep their places on the shelf.
    func movePinnedPlaylists(fromOffsets source: IndexSet, toOffset destination: Int) {
        var order = pinOrder
        let slots = order.indices.filter { index in
            guard case let .playlist(key) = order[index], let id = UUID(uuidString: key) else { return false }
            return playlist(withID: id) != nil
        }
        var moved = slots.map { order[$0] }
        moved.move(fromOffsets: source, toOffset: destination)
        for (slot, ref) in zip(slots, moved) { order[slot] = ref }
        savePinOrder(order)
    }

    func unpin(_ item: HomeItem) {
        switch item {
        case let .album(album):
            pinnedAlbums.removeValue(forKey: pinKey(of: album))
            UserDefaults.standard.set(pinnedAlbums, forKey: "pinnedAlbums")
        case let .playlist(playlist):
            pinnedPlaylists.removeValue(forKey: playlist.id.uuidString)
            UserDefaults.standard.set(pinnedPlaylists, forKey: "pinnedPlaylists")
        }
    }

    /// The key the album was pinned under, which older versions wrote
    /// differently.
    private func pinKey(of album: Album) -> String {
        pinnedAlbums.keys.first { self.album(forPinKey: $0)?.id == album.id } ?? album.id.pinKey
    }

    /// Resolves an "artist|||name" key written by any version of the app.
    func album(forPinKey key: String) -> Album? {
        let parts = key.components(separatedBy: "|||")
        guard parts.count == 2 else { return nil }
        let artist = parts[0]
        let name = parts[1]
        if let album = index.albumsByID[AlbumID(name: name, artist: artist)] {
            return album
        }
        return albums.first { $0.title == name && $0.artist == artist }
            ?? albums.first { $0.title == name }
    }
}

struct AutolistEditorRequest: Identifiable {
    let id = UUID()
    /// `nil`: a new Autolist.
    let playlistID: UUID?
    let rules: AutolistRules
}

struct PlaylistEditorRequest: Identifiable {
    let id = UUID()
    /// `nil`: a new playlist.
    let playlistID: UUID?
    /// Added to the new playlist.
    let songs: [Song]

    init(playlistID: UUID?, song: Song? = nil, songs: [Song] = []) {
        self.playlistID = playlistID
        self.songs = song.map { [$0] } ?? songs
    }
}
