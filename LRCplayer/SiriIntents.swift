import Intents
import AppIntents
import Combine
import CoreSpotlight
import Foundation
import SwiftUI

// What Siri, Shortcuts and Spotlight can reach in the app: the library as
// entities (indexed in Spotlight, where Siri looks first), and the actions
// the assistant already knows, as intents. The intents run the same code as
// the in-app assistant, so both stay in step.

// MARK: - Entities

struct SongEntity: AppEntity, IndexedEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Song", numericFormat: "\(placeholder: .int) songs")
    static let defaultQuery = SongEntityQuery()

    let id: UUID
    @Property(title: "Title") var title: String
    @Property(title: "Artist") var artist: String
    @Property(title: "Album") var album: String

    init(id: UUID, title: String, artist: String, album: String) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
    }

    init(_ song: Song) {
        self.init(id: song.id, title: song.title, artist: song.artist, album: song.album)
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(artist) · \(album)", image: .init(systemName: "music.note"))
    }
}

struct SongEntityQuery: EntityStringQuery {
    func entities(for identifiers: [UUID]) async throws -> [SongEntity] {
        await MainActor.run {
            let library = AppModel.shared.libraryService
            return identifiers.compactMap { library.song(withID: $0).map(SongEntity.init) }
        }
    }

    func entities(matching string: String) async throws -> [SongEntity] {
        await MainActor.run { SiriLibrary.songs(matching: string).prefix(30).map(SongEntity.init) }
    }

    func suggestedEntities() async throws -> [SongEntity] {
        await MainActor.run {
            AppModel.shared.libraryService.songs
                .sorted { $0.playCount > $1.playCount }
                .prefix(30)
                .map(SongEntity.init)
        }
    }
}

struct PlaylistEntity: AppEntity, IndexedEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Playlist", numericFormat: "\(placeholder: .int) playlists")
    static let defaultQuery = PlaylistEntityQuery()

    let id: UUID
    @Property(title: "Name") var name: String
    @Property(title: "Song Count") var songCount: Int

    init(id: UUID, name: String, songCount: Int) {
        self.id = id
        self.name = name
        self.songCount = songCount
    }

    init(_ playlist: Playlist) {
        self.init(id: playlist.id, name: playlist.name, songCount: playlist.songs.count)
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(songCount) songs", image: .init(systemName: "music.note.list"))
    }
}

struct PlaylistEntityQuery: EntityStringQuery {
    func entities(for identifiers: [UUID]) async throws -> [PlaylistEntity] {
        await MainActor.run {
            let playlists = AppModel.shared.libraryService.playlists
            return identifiers.compactMap { id in playlists.first { $0.id == id }.map(PlaylistEntity.init) }
        }
    }

    func entities(matching string: String) async throws -> [PlaylistEntity] {
        await MainActor.run {
            let key = AssistantText.normalize(string)
            return AppModel.shared.libraryService.playlists
                .filter { AssistantText.normalize($0.name).contains(key) }
                .map(PlaylistEntity.init)
        }
    }

    func suggestedEntities() async throws -> [PlaylistEntity] {
        await MainActor.run { AppModel.shared.libraryService.playlists.map(PlaylistEntity.init) }
    }
}

struct ArtistEntity: AppEntity, IndexedEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Artist", numericFormat: "\(placeholder: .int) artists")
    static let defaultQuery = ArtistEntityQuery()

    /// The artist's name, as the library groups it.
    let id: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(id)", image: .init(systemName: "music.mic"))
    }
}

struct ArtistEntityQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [ArtistEntity] {
        await MainActor.run {
            let names = Set(SiriLibrary.artists())
            return identifiers.filter(names.contains).map(ArtistEntity.init)
        }
    }

    func entities(matching string: String) async throws -> [ArtistEntity] {
        await MainActor.run {
            let key = AssistantText.normalize(string)
            return SiriLibrary.artists().filter { AssistantText.normalize($0).contains(key) }.prefix(30).map(ArtistEntity.init)
        }
    }

    func suggestedEntities() async throws -> [ArtistEntity] {
        await MainActor.run { SiriLibrary.topArtists(30).map(ArtistEntity.init) }
    }
}

struct AlbumEntity: AppEntity, IndexedEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Album", numericFormat: "\(placeholder: .int) albums")
    static let defaultQuery = AlbumEntityQuery()

    let id: String
    @Property(title: "Title") var title: String
    @Property(title: "Artist") var artist: String

    init(title: String, artist: String) {
        id = "\(title)\u{1F}\(artist)"
        self.title = title
        self.artist = artist
    }

    init?(id: String) {
        let parts = id.components(separatedBy: "\u{1F}")
        guard parts.count == 2 else { return nil }
        self.init(title: parts[0], artist: parts[1])
    }

    var albumID: AlbumID { AlbumID(name: title, artist: artist) }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(artist)", image: .init(systemName: "square.stack"))
    }
}

struct AlbumEntityQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [AlbumEntity] {
        identifiers.compactMap(AlbumEntity.init(id:))
    }

    func entities(matching string: String) async throws -> [AlbumEntity] {
        await MainActor.run {
            let key = AssistantText.normalize(string)
            return SiriLibrary.albums().filter { AssistantText.normalize($0.title).contains(key) }.prefix(30).map { $0 }
        }
    }

    func suggestedEntities() async throws -> [AlbumEntity] {
        await MainActor.run { Array(SiriLibrary.albums().prefix(30)) }
    }
}

// MARK: - Library helpers

@MainActor
enum SiriLibrary {
    static var library: LibraryService { AppModel.shared.libraryService }
    static var player: MusicPlayerService { MusicPlayerService.shared }

    static func songs(matching text: String) -> [Song] {
        let key = AssistantText.normalize(text)
        guard !key.isEmpty else { return [] }
        let songs = library.songs
        let titled = songs.filter { AssistantText.normalize($0.title).contains(key) }
        if !titled.isEmpty { return titled.sorted { $0.playCount > $1.playCount } }
        return songs.filter { AssistantText.normalize("\($0.title) \($0.artist)").contains(key) }
    }

    static func artists() -> [String] {
        Array(Set(library.songs.map(LibraryIndex.artistName(for:)))).sorted()
    }

    static func topArtists(_ count: Int) -> [String] {
        Dictionary(grouping: library.songs, by: LibraryIndex.artistName(for:))
            .map { ($0.key, $0.value.reduce(0) { $0 + $1.playCount }) }
            .sorted { $0.1 > $1.1 }
            .prefix(count)
            .map(\.0)
    }

    static func albums() -> [AlbumEntity] {
        var seen = Set<String>()
        var albums: [(AlbumEntity, Int)] = []
        var plays: [String: Int] = [:]
        for song in library.songs {
            let album = AlbumEntity(title: song.album, artist: LibraryIndex.artistName(for: song))
            plays[album.id, default: 0] += song.playCount
            if seen.insert(album.id).inserted { albums.append((album, 0)) }
        }
        return albums.map(\.0).sorted { plays[$0.id, default: 0] > plays[$1.id, default: 0] }
    }

    static func songs(of album: AlbumEntity) -> [Song] {
        library.songs
            .filter { $0.album == album.title && LibraryIndex.artistName(for: $0) == album.artist }
            .sorted { ($0.discNumber, $0.trackNumber) < ($1.discNumber, $1.trackNumber) }
    }

    static func songs(of artist: ArtistEntity) -> [Song] {
        library.songs.filter { LibraryIndex.artistName(for: $0) == artist.id }
    }

    static func playlist(_ entity: PlaylistEntity) throws -> Playlist {
        guard let playlist = library.playlists.first(where: { $0.id == entity.id }) else { throw SiriError.notFound(entity.name) }
        return playlist
    }

    nonisolated static var french: Bool { AssistantService.prefersFrench }

    nonisolated static func say(_ french: String, _ english: String) -> String {
        Self.french ? french : english
    }

    /// The receipts of actions run by the assistant's own code, as one line.
    static func run(_ actions: [AssistantAction]) throws -> String {
        let receipts = AssistantService.shared.perform(actions)
        if let failure = receipts.first(where: \.isFailure) { throw SiriError.message(failure.detail) }
        return receipts.map { [$0.title, $0.detail].filter { !$0.isEmpty }.joined(separator: " · ") }.joined(separator: "\n")
    }
}

enum SiriError: Error, CustomLocalizedStringResourceConvertible {
    case notFound(String)
    case nothingPlaying
    case noLyrics
    case message(String)

    var localizedStringResource: LocalizedStringResource {
        let french = AssistantService.prefersFrench
        switch self {
        case let .notFound(name): return french ? "« \(name) » est introuvable dans ta bibliothèque." : "“\(name)” isn't in your library."
        case .nothingPlaying: return french ? "Rien n'est en lecture." : "Nothing is playing."
        case .noLyrics: return french ? "Ce titre n'a pas de paroles synchronisées." : "This song has no synced lyrics."
        case let .message(text): return "\(text)"
        }
    }
}

// MARK: - Spotlight

/// Keeps the library's entities in Spotlight, where Siri finds them first.
@MainActor
final class SiriIndex {
    static let shared = SiriIndex()
    private var cancellables: Set<AnyCancellable> = []
    private var lastSignature = ""

    func start() {
        guard cancellables.isEmpty else { return }
        let library = AppModel.shared.libraryService
        library.$songs.map { _ in () }
            .merge(with: library.$playlists.map { _ in () })
            .debounce(for: .seconds(8), scheduler: RunLoop.main)
            .sink { [weak self] in self?.refresh() }
            .store(in: &cancellables)
    }

    private func refresh() {
        let library = AppModel.shared.libraryService
        guard !library.songs.isEmpty else { return }
        let signature = "\(library.songs.count)|\(library.playlists.map { "\($0.id)\($0.name)\($0.songs.count)" }.joined())"
        guard signature != lastSignature else { return }
        lastSignature = signature
        let songs = library.songs.map(SongEntity.init)
        let playlists = library.playlists.map(PlaylistEntity.init)
        let artists = SiriLibrary.artists().map(ArtistEntity.init)
        let albums = SiriLibrary.albums()
        Task.detached(priority: .background) {
            let index = CSSearchableIndex.default()
            try? await index.deleteAppEntities(ofType: SongEntity.self)
            try? await index.deleteAppEntities(ofType: PlaylistEntity.self)
            try? await index.deleteAppEntities(ofType: ArtistEntity.self)
            try? await index.deleteAppEntities(ofType: AlbumEntity.self)
            try? await index.indexAppEntities(playlists)
            try? await index.indexAppEntities(artists)
            try? await index.indexAppEntities(albums)
            try? await index.indexAppEntities(songs)
        }
    }
}

/// Pages Siri asks the app to show; ContentView opens them.
@MainActor
final class SiriRouting: ObservableObject {
    static let shared = SiriRouting()
    @Published var route: LibraryRoute?
    @Published var openAssistant: AssistantMode?
}

// MARK: - Playback

enum QueuePosition: String, AppEnum {
    case now
    case next
    case later

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "When"
    static let caseDisplayRepresentations: [QueuePosition: DisplayRepresentation] = [
        .now: "Now",
        .next: "Next",
        .later: "Later",
    ]
}

@MainActor
private func play(_ songs: [Song], shuffled: Bool, position: QueuePosition) {
    let player = SiriLibrary.player
    switch position {
    case .now:
        player.play(songs, shuffled: shuffled)
    case .next:
        let ordered = shuffled ? songs.shuffled() : songs
        for song in ordered.prefix(100).reversed() { player.addNextToQueue(song: song) }
    case .later:
        if player.queue.isEmpty {
            player.play(songs, shuffled: shuffled)
        } else {
            for song in (shuffled ? songs.shuffled() : songs).prefix(300) { player.addToQueue(song: song) }
        }
    }
}

private func playedDialog(_ what: String, _ position: QueuePosition) -> IntentDialog {
    switch position {
    case .now: IntentDialog(stringLiteral: SiriLibrary.say("Lecture de \(what).", "Playing \(what)."))
    case .next: IntentDialog(stringLiteral: SiriLibrary.say("\(what) passe ensuite.", "\(what) plays next."))
    case .later: IntentDialog(stringLiteral: SiriLibrary.say("\(what) ajouté à la file.", "\(what) added to the queue."))
    }
}

struct PlaySongIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Song"
    static let description = IntentDescription("Plays a song from the LRCplayer library now, next, or at the end of the queue.")

    @Parameter(title: "Song", description: "The song to play.")
    var song: SongEntity

    @Parameter(title: "When", description: "Now replaces the queue; Next plays it after the current song; Later adds it to the end.", default: .now)
    var position: QueuePosition

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$song) \(\.$position)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let found = SiriLibrary.library.song(withID: song.id) else { throw SiriError.notFound(song.title) }
        if position == .now {
            // The rest of the album follows, as when tapping it in the app.
            let album = SiriLibrary.songs(of: AlbumEntity(title: found.album, artist: LibraryIndex.artistName(for: found)))
            SiriLibrary.player.play(song: found, from: album.isEmpty ? [found] : album)
        } else {
            play([found], shuffled: false, position: position)
        }
        return .result(dialog: playedDialog("« \(found.title) »", position))
    }
}

struct PlayPlaylistIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Playlist"
    static let description = IntentDescription("Plays one of the user's LRCplayer playlists, in order or shuffled.")

    @Parameter(title: "Playlist", description: "The playlist to play.")
    var playlist: PlaylistEntity

    @Parameter(title: "Shuffle", description: "Plays the songs in random order.", default: false)
    var shuffle: Bool

    @Parameter(title: "When", default: .now)
    var position: QueuePosition

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$playlist) \(\.$position)") { \.$shuffle }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let found = try SiriLibrary.playlist(playlist)
        let songs = SiriLibrary.library.songsForPlaylist(found)
        guard !songs.isEmpty else { throw SiriError.message(SiriLibrary.say("Cette playlist est vide.", "This playlist is empty.")) }
        play(songs, shuffled: shuffle, position: position)
        return .result(dialog: playedDialog(found.name, position))
    }
}

struct PlayArtistIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Artist"
    static let description = IntentDescription("Plays an artist's songs from the LRCplayer library, shuffled by default.")

    @Parameter(title: "Artist")
    var artist: ArtistEntity

    @Parameter(title: "Shuffle", default: true)
    var shuffle: Bool

    @Parameter(title: "When", default: .now)
    var position: QueuePosition

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$artist) \(\.$position)") { \.$shuffle }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let songs = SiriLibrary.songs(of: artist)
        guard !songs.isEmpty else { throw SiriError.notFound(artist.id) }
        play(songs, shuffled: shuffle, position: position)
        return .result(dialog: playedDialog(artist.id, position))
    }
}

struct PlayAlbumIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Album"
    static let description = IntentDescription("Plays an album from the LRCplayer library in track order.")

    @Parameter(title: "Album")
    var album: AlbumEntity

    @Parameter(title: "Shuffle", default: false)
    var shuffle: Bool

    @Parameter(title: "When", default: .now)
    var position: QueuePosition

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$album) \(\.$position)") { \.$shuffle }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let songs = SiriLibrary.songs(of: album)
        guard !songs.isEmpty else { throw SiriError.notFound(album.title) }
        play(songs, shuffled: shuffle, position: position)
        return .result(dialog: playedDialog(album.title, position))
    }
}

struct ShuffleLibraryIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Shuffle Library"
    static let description = IntentDescription("Plays the whole LRCplayer library in random order.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        SiriLibrary.player.play(SiriLibrary.library.songs, shuffled: true)
        return .result(dialog: IntentDialog(stringLiteral: SiriLibrary.say("Toute ta bibliothèque, en aléatoire.", "Your whole library, shuffled.")))
    }
}

enum RepeatSetting: String, AppEnum {
    case off, all, one

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Repeat"
    static let caseDisplayRepresentations: [RepeatSetting: DisplayRepresentation] = [
        .off: "Off", .all: "All", .one: "One Song",
    ]
}

struct SetPlaybackModeIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Set Shuffle and Repeat"
    static let description = IntentDescription("Turns LRCplayer's shuffle on or off and sets repeat (off, all, or the current song).")

    @Parameter(title: "Shuffle", description: "Leave empty to keep it as is.")
    var shuffle: Bool?

    @Parameter(title: "Repeat", description: "Leave empty to keep it as is.")
    var repeatMode: RepeatSetting?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        var actions: [AssistantAction] = []
        if let shuffle { actions.append(AssistantAction(type: shuffle ? .shuffleOn : .shuffleOff)) }
        switch repeatMode {
        case .off: actions.append(AssistantAction(type: .repeatOff))
        case .all: actions.append(AssistantAction(type: .repeatAll))
        case .one: actions.append(AssistantAction(type: .repeatOne))
        case nil: break
        }
        guard !actions.isEmpty else { return .result(dialog: IntentDialog(stringLiteral: SiriLibrary.say("Rien à changer.", "Nothing to change."))) }
        return .result(dialog: IntentDialog(stringLiteral: try SiriLibrary.run(actions)))
    }
}

struct SleepTimerIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Sleep Timer"
    static let description = IntentDescription("Pauses LRCplayer after some minutes, or at the end of the current song with 0. Turning it off cancels the timer.")

    @Parameter(title: "Minutes", description: "0 pauses at the end of the current song.", default: 30, inclusiveRange: (0, 600))
    var minutes: Int

    @Parameter(title: "Turn Off", description: "Cancels the running timer instead.", default: false)
    var cancel: Bool

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        var action = AssistantAction(type: cancel ? .cancelSleepTimer : .sleepTimer)
        action.minutes = minutes
        return .result(dialog: IntentDialog(stringLiteral: try SiriLibrary.run([action])))
    }
}

// MARK: - Library

struct AddToPlaylistIntent: AppIntent {
    static let title: LocalizedStringResource = "Add to Playlist"
    static let description = IntentDescription("Adds songs to one of the user's LRCplayer playlists. Without songs, adds the song playing now.")

    @Parameter(title: "Playlist")
    var playlist: PlaylistEntity

    @Parameter(title: "Songs", description: "Leave empty for the song playing now.")
    var songs: [SongEntity]?

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$songs) to \(\.$playlist)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let found = try SiriLibrary.playlist(playlist)
        guard !found.isAutolist else {
            throw SiriError.message(SiriLibrary.say("« \(found.name) » est une autolist : elle se remplit seule.", "“\(found.name)” is an autolist: it fills itself."))
        }
        let ids: [UUID]
        if let songs, !songs.isEmpty {
            ids = songs.map(\.id)
        } else if let current = SiriLibrary.player.currentSong {
            ids = [current.id]
        } else {
            throw SiriError.nothingPlaying
        }
        let new = ids.filter { !found.songs.contains($0) }
        for id in new { SiriLibrary.library.addSongToPlaylist(songId: id, playlistId: found.id) }
        let titles = ids.compactMap { SiriLibrary.library.song(withID: $0)?.title }
        let what = titles.count == 1 ? "« \(titles[0]) »" : SiriLibrary.say("\(titles.count) titres", "\(titles.count) songs")
        if new.isEmpty {
            return .result(dialog: IntentDialog(stringLiteral: SiriLibrary.say("\(what) est déjà dans \(found.name).", "\(what) is already in \(found.name).")))
        }
        return .result(dialog: IntentDialog(stringLiteral: SiriLibrary.say("\(what) ajouté à \(found.name).", "Added \(what) to \(found.name).")))
    }
}

struct CreatePlaylistIntent: AppIntent {
    static let title: LocalizedStringResource = "Create Playlist"
    static let description = IntentDescription("Creates an LRCplayer playlist with a name and, optionally, some songs.")

    @Parameter(title: "Name")
    var name: String

    @Parameter(title: "Songs")
    var songs: [SongEntity]?

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<PlaylistEntity> & ProvidesDialog {
        let playlist = SiriLibrary.library.createPlaylist(name: name, cover: .generated(CoverPalette.allCases.randomElement() ?? .allCases[0]))
        let ids = (songs ?? []).map(\.id)
        if !ids.isEmpty { SiriLibrary.library.setPlaylistSongOrder(playlistId: playlist.id, songIds: ids) }
        let saved = SiriLibrary.library.playlists.first { $0.id == playlist.id } ?? playlist
        return .result(value: PlaylistEntity(saved), dialog: IntentDialog(stringLiteral: SiriLibrary.say("Playlist « \(name) » créée.", "Created “\(name)”.")))
    }
}

// MARK: - Questions

struct NowPlayingIntent: AppIntent {
    static let title: LocalizedStringResource = "What's Playing"
    static let description = IntentDescription("Tells which song LRCplayer is playing, with the lyric line being sung when there is one.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<SongEntity> & ProvidesDialog & ShowsSnippetView {
        guard let song = SiriLibrary.player.currentSong else { throw SiriError.nothingPlaying }
        let line = AppModel.shared.playerVM.currentLyricLine?.text.trimmingCharacters(in: .whitespaces) ?? ""
        let text = SiriLibrary.say("« \(song.title) » de \(song.artist).", "“\(song.title)” by \(song.artist).")
        return .result(value: SongEntity(song), dialog: IntentDialog(stringLiteral: text), view: NowPlayingSnippet(song: song, line: line))
    }
}

struct CurrentLyricsIntent: AppIntent {
    static let title: LocalizedStringResource = "Current Lyrics"
    static let description = IntentDescription("Returns the lyrics being sung right now in LRCplayer: the current line and the next ones. Useful to explain or translate what the user is hearing.")

    @Parameter(title: "Lines", description: "How many lines to return from the current one.", default: 4, inclusiveRange: (1, 40))
    var count: Int

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        guard let song = SiriLibrary.player.currentSong else { throw SiriError.nothingPlaying }
        let vm = AppModel.shared.playerVM
        guard let lyrics = vm.currentLyrics, lyrics.hasTimedLyrics else {
            if let plain = vm.currentLyrics?.plainText, !plain.isEmpty { return .result(value: plain, dialog: IntentDialog(stringLiteral: plain)) }
            throw SiriError.noLyrics
        }
        let lines = lyrics.lines.filter { !$0.isInstrumentalGap }
        let start = vm.currentLyricLine.flatMap { current in lines.firstIndex { $0.id == current.id } } ?? 0
        let text = lines[start...].prefix(count).map(\.text).joined(separator: "\n")
        return .result(value: "\(song.title) — \(song.artist)\n\(text)", dialog: IntentDialog(stringLiteral: text))
    }
}

struct FindSongByLyricsIntent: AppIntent {
    static let title: LocalizedStringResource = "Find Song by Lyrics"
    static let description = IntentDescription("Finds the songs in the LRCplayer library whose lyrics contain some words, like “the song that says …”.")

    @Parameter(title: "Words", description: "Words the user remembers from the lyrics.")
    var words: String

    @Parameter(title: "Play It", description: "Plays the first match.", default: false)
    var playFirst: Bool

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[SongEntity]> & ProvidesDialog {
        let library = SiriLibrary.library
        let keys = AssistantText.normalize(words).split(separator: " ").map(String.init)
        guard !keys.isEmpty else { throw SiriError.message(SiriLibrary.say("Quels mots ?", "Which words?")) }
        let files: [(UUID, URL)] = library.songs.compactMap { song in library.resolvedLyricsURL(for: song).map { (song.id, $0) } }
        let hits = await Task.detached(priority: .userInitiated) { () -> [(UUID, String)] in
            var hits: [(UUID, String)] = []
            for (id, url) in files {
                guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
                for raw in content.split(whereSeparator: \.isNewline) {
                    let line = raw.replacingOccurrences(of: #"\[[^\]]*\]|<[^>]*>"#, with: "", options: .regularExpression)
                    let key = " \(AssistantText.normalize(line)) "
                    if keys.allSatisfy({ key.contains(" \($0)") }) {
                        hits.append((id, line.trimmingCharacters(in: .whitespaces)))
                        break
                    }
                }
                if hits.count >= 10 { break }
            }
            return hits
        }.value
        let songs = hits.compactMap { library.song(withID: $0.0) }
        guard let first = songs.first else {
            throw SiriError.message(SiriLibrary.say("Aucune parole ne contient « \(words) ».", "No lyrics contain “\(words)”."))
        }
        if playFirst { SiriLibrary.player.play(song: first, from: [first]) }
        let line = hits[0].1
        let text = songs.count == 1
            ? SiriLibrary.say("C'est « \(first.title) » de \(first.artist) : « \(line) ».", "It's “\(first.title)” by \(first.artist): “\(line)”.")
            : SiriLibrary.say("Sûrement « \(first.title) » de \(first.artist), parmi \(songs.count) titres.", "Probably “\(first.title)” by \(first.artist), among \(songs.count) songs.")
        return .result(value: songs.map(SongEntity.init), dialog: IntentDialog(stringLiteral: text))
    }
}

enum StatsPeriodSetting: String, AppEnum {
    case week, month, year, allTime

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Period"
    static let caseDisplayRepresentations: [StatsPeriodSetting: DisplayRepresentation] = [
        .week: "This Week", .month: "This Month", .year: "This Year", .allTime: "All Time",
    ]

    var period: StatsPeriod {
        switch self {
        case .week: .week
        case .month: .month
        case .year: .year
        case .allTime: .allTime
        }
    }
}

struct ListeningStatsIntent: AppIntent {
    static let title: LocalizedStringResource = "Listening Stats"
    static let description = IntentDescription("Returns the user's LRCplayer listening stats over a period: listening time, top songs, artists and albums. Can focus on some artists.")

    @Parameter(title: "Period", default: .month)
    var period: StatsPeriodSetting

    @Parameter(title: "Artists", description: "Only these artists. Leave empty for everything.")
    var artists: [ArtistEntity]?

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        var lookup = AssistantLookup(type: .stats)
        lookup.period = period.period
        if let artists, !artists.isEmpty { lookup.songs = SongQuery(artists: artists.map(\.id)) }
        let library = AssistantLibrary(libraryService: SiriLibrary.library, player: SiriLibrary.player)
        return .result(value: await library.run(lookup))
    }
}

struct UpNextIntent: AppIntent {
    static let title: LocalizedStringResource = "Up Next"
    static let description = IntentDescription("Lists the songs coming up in LRCplayer's queue.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[SongEntity]> & ProvidesDialog {
        let player = SiriLibrary.player
        let upcoming = Array(player.queue.dropFirst(player.currentIndex + 1).prefix(20))
        guard let next = upcoming.first else {
            return .result(value: [], dialog: IntentDialog(stringLiteral: SiriLibrary.say("Rien d'autre dans la file.", "Nothing else in the queue.")))
        }
        let text = SiriLibrary.say("Ensuite : « \(next.title) » de \(next.artist).", "Next: “\(next.title)” by \(next.artist).")
        return .result(value: upcoming.map(SongEntity.init), dialog: IntentDialog(stringLiteral: text))
    }
}

// MARK: - Assistant

struct AskAssistantIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask LRCplayer Assistant"
    static let description = IntentDescription("""
        Hands a music request to LRCplayer's own assistant, which knows the whole library, the audio of each song (energy, tempo, mood), play counts and history. \
        Use it for mixes and smart playlists described in words (“calm songs from the 2000s I haven't played in a while”, “a playlist like what's playing”), \
        for editing playlists, and for questions about the user's listening.
        """)

    @Parameter(title: "Request", description: "The user's request, in their words.")
    var request: String

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        guard let answer = await AssistantService.shared.send(request) else {
            throw SiriError.message(SiriLibrary.say("L'assistant est occupé.", "The assistant is busy."))
        }
        let done = answer.receipts.map { [$0.title, $0.detail].filter { !$0.isEmpty }.joined(separator: " · ") }
        let text = answer.text.isEmpty ? done.joined(separator: "\n") : answer.text
        return .result(value: ([text] + done).joined(separator: "\n"), dialog: IntentDialog(stringLiteral: text))
    }
}

struct OpenAssistantIntent: AppIntent {
    static let title: LocalizedStringResource = "Talk to LRCplayer Assistant"
    static let description = IntentDescription("Opens LRCplayer's assistant in voice mode.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        SiriRouting.shared.openAssistant = .voice
        return .result()
    }
}

// MARK: - Open

struct OpenPlaylistIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Playlist"
    static let description = IntentDescription("Shows a playlist in LRCplayer.")

    @Parameter(title: "Playlist")
    var target: PlaylistEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        SiriRouting.shared.route = .playlist(target.id)
        return .result()
    }
}

struct OpenArtistIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Artist"
    static let description = IntentDescription("Shows an artist's page in LRCplayer.")

    @Parameter(title: "Artist")
    var target: ArtistEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        SiriRouting.shared.route = .artist(target.id)
        return .result()
    }
}

struct OpenAlbumIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Album"
    static let description = IntentDescription("Shows an album in LRCplayer.")

    @Parameter(title: "Album")
    var target: AlbumEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        SiriRouting.shared.route = .album(target.albumID)
        return .result()
    }
}

// MARK: - Snippet

private struct NowPlayingSnippet: View {
    let song: Song
    let line: String

    var body: some View {
        HStack(spacing: 12) {
            artwork
                .frame(width: 56, height: 56)
                .clipShape(.rect(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title).font(.headline).lineLimit(1)
                Text(song.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                if !line.isEmpty {
                    Text(line).font(.footnote.weight(.semibold)).lineLimit(2).padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding()
    }

    @ViewBuilder
    private var artwork: some View {
        if let data = ArtworkStore.data(for: song.id), let image = UIImage(data: data) {
            Image(uiImage: image).resizable().scaledToFill()
        } else {
            Rectangle().fill(.quaternary).overlay(Image(systemName: "music.note").foregroundStyle(.secondary))
        }
    }
}

// MARK: - More intents

struct GenreEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Genre", numericFormat: "\(placeholder: .int) genres")
    static let defaultQuery = GenreEntityQuery()
    let id: String
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(id)", image: .init(systemName: "guitars"))
    }
}

struct GenreEntityQuery: EntityStringQuery {
    @MainActor static func genres() -> [String] {
        Dictionary(grouping: SiriLibrary.library.songs.filter { !$0.genre.trimmingCharacters(in: .whitespaces).isEmpty }, by: \.genre)
            .sorted { $0.value.count > $1.value.count }.map(\.key)
    }
    func entities(for identifiers: [String]) async throws -> [GenreEntity] {
        await MainActor.run { let all = Set(Self.genres()); return identifiers.filter(all.contains).map(GenreEntity.init) }
    }
    func entities(matching string: String) async throws -> [GenreEntity] {
        await MainActor.run {
            let key = AssistantText.normalize(string)
            return Self.genres().filter { AssistantText.normalize($0).contains(key) }.map(GenreEntity.init)
        }
    }
    func suggestedEntities() async throws -> [GenreEntity] {
        await MainActor.run { Self.genres().prefix(30).map(GenreEntity.init) }
    }
}

enum PlaybackCommand: String, AppEnum {
    case pause, resume, toggle, next, previous, restart

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Command"
    static let caseDisplayRepresentations: [PlaybackCommand: DisplayRepresentation] = [
        .pause: "Pause", .resume: "Resume", .toggle: "Play/Pause",
        .next: "Next Song", .previous: "Previous Song", .restart: "Restart Song",
    ]
}

struct PlaybackControlIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Control Playback"
    static let description = IntentDescription("Pauses, resumes, skips, goes back or restarts the current LRCplayer song.")

    @Parameter(title: "Command", default: .toggle)
    var command: PlaybackCommand

    static var parameterSummary: some ParameterSummary { Summary("\(\.$command)") }

    @MainActor
    func perform() async throws -> some IntentResult {
        let player = SiriLibrary.player
        guard player.currentSong != nil else { throw SiriError.nothingPlaying }
        switch command {
        case .pause: player.pause()
        case .resume: player.play()
        case .toggle: player.togglePlayPause()
        case .next: player.next()
        case .previous: player.skipToPreviousTrack()
        case .restart: player.seek(to: 0)
        }
        return .result()
    }
}

struct SeekIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Skip Seconds"
    static let description = IntentDescription("Jumps forward or back in the current LRCplayer song. Negative values go back.")

    @Parameter(title: "Seconds", default: 15, inclusiveRange: (-600, 600))
    var seconds: Int

    static var parameterSummary: some ParameterSummary { Summary("Skip \(\.$seconds) seconds") }

    @MainActor
    func perform() async throws -> some IntentResult {
        let player = SiriLibrary.player
        guard player.currentSong != nil else { throw SiriError.nothingPlaying }
        player.seek(to: min(max(0, player.currentTime + TimeInterval(seconds)), max(0, player.duration - 1)))
        return .result()
    }
}

struct PlayGenreIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Genre"
    static let description = IntentDescription("Plays the songs of a genre from the LRCplayer library, shuffled.")

    @Parameter(title: "Genre")
    var genre: GenreEntity

    @Parameter(title: "When", default: .now)
    var position: QueuePosition

    static var parameterSummary: some ParameterSummary { Summary("Play \(\.$genre) \(\.$position)") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let songs = SiriLibrary.library.songs.filter { $0.genre == genre.id }
        guard !songs.isEmpty else { throw SiriError.notFound(genre.id) }
        play(songs, shuffled: true, position: position)
        return .result(dialog: playedDialog(genre.id, position))
    }
}

enum SmartMix: String, AppEnum {
    case mostPlayed, recentlyAdded, recentlyPlayed, neverPlayed, forgotten, random

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Mix"
    static let caseDisplayRepresentations: [SmartMix: DisplayRepresentation] = [
        .mostPlayed: "Most Played", .recentlyAdded: "Recently Added", .recentlyPlayed: "Recently Played",
        .neverPlayed: "Never Played", .forgotten: "Forgotten Favorites", .random: "Random Mix",
    ]

    var label: String {
        switch self {
        case .mostPlayed: SiriLibrary.say("tes titres les plus écoutés", "your most played songs")
        case .recentlyAdded: SiriLibrary.say("tes derniers ajouts", "your recently added songs")
        case .recentlyPlayed: SiriLibrary.say("tes écoutes récentes", "your recently played songs")
        case .neverPlayed: SiriLibrary.say("des titres jamais écoutés", "songs you've never played")
        case .forgotten: SiriLibrary.say("des favoris oubliés", "forgotten favorites")
        case .random: SiriLibrary.say("un mix aléatoire", "a random mix")
        }
    }
}

struct PlaySmartMixIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Mix"
    static let description = IntentDescription("Plays a mix built from the LRCplayer library: most played, recently added, never played, forgotten favorites…")

    @Parameter(title: "Mix", default: .mostPlayed)
    var mix: SmartMix

    @Parameter(title: "Songs", default: 50, inclusiveRange: (5, 500))
    var count: Int

    @Parameter(title: "When", default: .now)
    var position: QueuePosition

    static var parameterSummary: some ParameterSummary { Summary("Play \(\.$mix) \(\.$position)") { \.$count } }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let all = SiriLibrary.library.songs
        let monthAgo = Date().addingTimeInterval(-30 * 86_400)
        var shuffled = false
        let picked: [Song]
        switch mix {
        case .mostPlayed: picked = all.filter { $0.playCount > 0 }.sorted { $0.playCount > $1.playCount }; shuffled = true
        case .recentlyAdded: picked = all.sorted { $0.addedAt > $1.addedAt }
        case .recentlyPlayed: picked = all.filter { $0.lastPlayedAt != nil }.sorted { $0.lastPlayedAt! > $1.lastPlayedAt! }
        case .neverPlayed: picked = all.filter { $0.playCount == 0 }.shuffled()
        case .forgotten: picked = all.filter { $0.playCount >= 5 && ($0.lastPlayedAt ?? .distantPast) < monthAgo }.shuffled()
        case .random: picked = all.shuffled()
        }
        let songs = Array(picked.prefix(count))
        guard !songs.isEmpty else { throw SiriError.message(SiriLibrary.say("Aucun titre pour ce mix.", "No songs for this mix.")) }
        play(songs, shuffled: shuffled, position: position)
        return .result(dialog: playedDialog(mix.label, position))
    }
}

struct PlayMoreFromArtistIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "More from This Artist"
    static let description = IntentDescription("Plays more songs by the artist of the song playing now, or the rest of its album.")

    @Parameter(title: "Album Only", default: false)
    var albumOnly: Bool

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let current = SiriLibrary.player.currentSong else { throw SiriError.nothingPlaying }
        let artist = LibraryIndex.artistName(for: current)
        if albumOnly {
            let songs = SiriLibrary.songs(of: AlbumEntity(title: current.album, artist: artist))
            SiriLibrary.player.play(song: current, from: songs.isEmpty ? [current] : songs)
            return .result(dialog: IntentDialog(stringLiteral: SiriLibrary.say("Suite de « \(current.album) ».", "The rest of “\(current.album)”.")))
        }
        let songs = SiriLibrary.songs(of: ArtistEntity(id: artist)).filter { $0.id != current.id }
        guard !songs.isEmpty else { throw SiriError.message(SiriLibrary.say("Pas d'autre titre de \(artist).", "No other songs by \(artist).")) }
        play(songs, shuffled: true, position: .next)
        return .result(dialog: IntentDialog(stringLiteral: SiriLibrary.say("Plus de \(artist) ensuite.", "More \(artist) coming up.")))
    }
}

struct ClearQueueIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Clear Queue"
    static let description = IntentDescription("Stops LRCplayer and empties its queue.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        SiriLibrary.player.clearQueue()
        return .result(dialog: IntentDialog(stringLiteral: SiriLibrary.say("File d'attente vidée.", "Queue cleared.")))
    }
}

struct RemoveFromPlaylistIntent: AppIntent {
    static let title: LocalizedStringResource = "Remove from Playlist"
    static let description = IntentDescription("Removes songs from an LRCplayer playlist. Without songs, removes the song playing now.")

    @Parameter(title: "Playlist")
    var playlist: PlaylistEntity

    @Parameter(title: "Songs", description: "Leave empty for the song playing now.")
    var songs: [SongEntity]?

    static var parameterSummary: some ParameterSummary { Summary("Remove \(\.$songs) from \(\.$playlist)") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let found = try SiriLibrary.playlist(playlist)
        guard !found.isAutolist else {
            throw SiriError.message(SiriLibrary.say("« \(found.name) » est une autolist.", "“\(found.name)” is an autolist."))
        }
        let ids: [UUID]
        if let songs, !songs.isEmpty { ids = songs.map(\.id) }
        else if let current = SiriLibrary.player.currentSong { ids = [current.id] }
        else { throw SiriError.nothingPlaying }
        let present = ids.filter(found.songs.contains)
        guard !present.isEmpty else {
            return .result(dialog: IntentDialog(stringLiteral: SiriLibrary.say("Rien à retirer de \(found.name).", "Nothing to remove from \(found.name).")))
        }
        for id in present { SiriLibrary.library.removeSongFromPlaylist(songId: id, playlistId: found.id) }
        return .result(dialog: IntentDialog(stringLiteral: SiriLibrary.say("\(present.count) titre(s) retiré(s) de \(found.name).", "Removed \(present.count) song(s) from \(found.name).")))
    }
}

struct RenamePlaylistIntent: AppIntent {
    static let title: LocalizedStringResource = "Rename Playlist"
    static let description = IntentDescription("Renames an LRCplayer playlist.")

    @Parameter(title: "Playlist")
    var playlist: PlaylistEntity

    @Parameter(title: "New Name")
    var name: String

    static var parameterSummary: some ParameterSummary { Summary("Rename \(\.$playlist) to \(\.$name)") }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<PlaylistEntity> & ProvidesDialog {
        let found = try SiriLibrary.playlist(playlist)
        SiriLibrary.library.renamePlaylist(found, name: name)
        let saved = SiriLibrary.library.playlists.first { $0.id == found.id } ?? found
        return .result(value: PlaylistEntity(saved), dialog: IntentDialog(stringLiteral: SiriLibrary.say("Renommée en « \(saved.name) ».", "Renamed to “\(saved.name)”.")))
    }
}

struct GetPlaylistSongsIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Playlist Songs"
    static let description = IntentDescription("Returns the songs of an LRCplayer playlist, for use in Shortcuts.")

    @Parameter(title: "Playlist")
    var playlist: PlaylistEntity

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[SongEntity]> {
        let found = try SiriLibrary.playlist(playlist)
        let songs = found.songs.compactMap { SiriLibrary.library.song(withID: $0) }
        return .result(value: songs.map(SongEntity.init))
    }
}

struct LibraryInfoIntent: AppIntent {
    static let title: LocalizedStringResource = "Library Summary"
    static let description = IntentDescription("Tells how many songs, artists, albums and playlists are in the LRCplayer library.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let songs = SiriLibrary.library.songs
        let hours = Int(songs.reduce(0) { $0 + $1.duration } / 3600)
        let text = SiriLibrary.say(
            "\(songs.count) titres, \(SiriLibrary.artists().count) artistes, \(SiriLibrary.albums().count) albums et \(SiriLibrary.library.playlists.count) playlists, soit environ \(hours) h de musique.",
            "\(songs.count) songs, \(SiriLibrary.artists().count) artists, \(SiriLibrary.albums().count) albums and \(SiriLibrary.library.playlists.count) playlists — about \(hours) hours of music.")
        return .result(value: text, dialog: IntentDialog(stringLiteral: text))
    }
}

// MARK: - Phrases

struct LRCplayerShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PlayPlaylistIntent(),
            phrases: ["Play \(\.$playlist) in \(.applicationName)", "Shuffle \(\.$playlist) in \(.applicationName)"],
            shortTitle: "Play Playlist",
            systemImageName: "music.note.list"
        )
        AppShortcut(
            intent: AskAssistantIntent(),
            phrases: ["Ask \(.applicationName)", "Ask the \(.applicationName) assistant"],
            shortTitle: "Ask Assistant",
            systemImageName: "sparkles"
        )
        AppShortcut(
            intent: FindSongByLyricsIntent(),
            phrases: ["Find a song by lyrics in \(.applicationName)", "What's that song in \(.applicationName)"],
            shortTitle: "Find by Lyrics",
            systemImageName: "text.magnifyingglass"
        )
        AppShortcut(
            intent: CurrentLyricsIntent(),
            phrases: ["What are they singing in \(.applicationName)", "Show the lyrics in \(.applicationName)"],
            shortTitle: "Current Lyrics",
            systemImageName: "quote.bubble"
        )
        AppShortcut(
            intent: ShuffleLibraryIntent(),
            phrases: ["Shuffle my library in \(.applicationName)", "Shuffle \(.applicationName)"],
            shortTitle: "Shuffle Library",
            systemImageName: "shuffle"
        )
        AppShortcut(
            intent: ListeningStatsIntent(),
            phrases: ["My stats in \(.applicationName)", "What did I listen to in \(.applicationName)"],
            shortTitle: "Listening Stats",
            systemImageName: "chart.bar"
        )
        AppShortcut(
            intent: PlaySmartMixIntent(),
            phrases: ["Play \(\.$mix) in \(.applicationName)", "Play my \(\.$mix) in \(.applicationName)"],
            shortTitle: "Play Mix",
            systemImageName: "sparkles.rectangle.stack"
        )
        AppShortcut(
            intent: PlayGenreIntent(),
            phrases: ["Play \(\.$genre) in \(.applicationName)", "Put on some \(\.$genre) in \(.applicationName)"],
            shortTitle: "Play Genre",
            systemImageName: "guitars"
        )
        AppShortcut(
            intent: PlayMoreFromArtistIntent(),
            phrases: ["More from this artist in \(.applicationName)", "Play more like this in \(.applicationName)"],
            shortTitle: "More from Artist",
            systemImageName: "music.mic"
        )
        AppShortcut(
            intent: OpenAssistantIntent(),
            phrases: ["Talk to \(.applicationName)"],
            shortTitle: "Talk to Assistant",
            systemImageName: "waveform"
        )
    }
}

// MARK: - SiriKit media ("Play X in VibePod")

/// Siri's own "play …" requests go through SiriKit's media intent, not App
/// Intents: without it the app isn't offered as a player at all.
final class SiriMediaHandler: NSObject, INPlayMediaIntentHandling, @unchecked Sendable {
    static let shared = SiriMediaHandler()

    private static func key(_ text: String) -> String {
        AssistantText.normalize(text.replacingOccurrences(of: "&", with: " and "))
            .split(separator: " ").filter { !["and", "et", "the", "le", "la", "les"].contains($0) }.joined(separator: " ")
    }

    private static func distance(_ a: Substring, _ b: Substring) -> Int {
        let a = Array(a), b = Array(b)
        var row = Array(0...b.count)
        for i in 1...max(a.count, 1) where !a.isEmpty {
            var prev = row[0]; row[0] = i
            for j in stride(from: 1, through: b.count, by: 1) {
                let tmp = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, prev + (a[i - 1] == b[j - 1] ? 0 : 1))
                prev = tmp
            }
        }
        return a.isEmpty ? b.count : row[b.count]
    }

    /// Strict: same words. Loose: every spoken word is in the name, allowing
    /// one typo in words of 5+ letters (Siri's transcription slips).
    private static func matches(_ candidate: String, _ query: String, strict: Bool = false) -> Bool {
        let c = key(candidate), q = key(query)
        guard !c.isEmpty, !q.isEmpty else { return false }
        if c == q { return true }
        if strict { return false }
        if c.hasPrefix(q + " ") || c.contains(" " + q + " ") || c.hasSuffix(" " + q) { return true }
        let cw = c.split(separator: " "), qw = q.split(separator: " ")
        return qw.allSatisfy { w in cw.contains { $0 == w || (w.count >= 5 && $0.count >= 5 && distance($0, w) <= 1) } }
    }

    @MainActor
    private static func resolve(_ search: INMediaSearch?) -> (id: String, title: String, type: INMediaItemType)? {
        let library = SiriLibrary.library
        let name = search?.mediaName ?? ""
        let artist = search?.artistName ?? ""
        let album = search?.albumName ?? ""
        let genre = search?.genreNames?.first ?? ""
        let type = search?.mediaType ?? .unknown

        var strict = true
        func playlist() -> (String, String, INMediaItemType)? {
            library.playlists.first { matches($0.name, name, strict: strict) }.map { ("playlist:\($0.id)", $0.name, .playlist) }
        }
        func albumMatch(_ q: String) -> (String, String, INMediaItemType)? {
            SiriLibrary.albums().first { matches($0.title, q, strict: strict) && (artist.isEmpty || matches($0.artist, artist)) }
                .map { ("album:\($0.title)\u{1F}\($0.artist)", $0.title, .album) }
        }
        func artistMatch(_ q: String) -> (String, String, INMediaItemType)? {
            SiriLibrary.artists().first { matches($0, q, strict: strict) }.map { ("artist:\($0)", $0, .artist) }
        }
        func genreMatch(_ q: String) -> (String, String, INMediaItemType)? {
            GenreEntityQuery.genres().first { matches($0, q, strict: strict) }.map { ("genre:\($0)", $0, .genre) }
        }
        func song() -> (String, String, INMediaItemType)? {
            let pool = library.songs.filter { artist.isEmpty || matches(LibraryIndex.artistName(for: $0), artist) }
            let exact = pool.filter { key($0.title) == key(name) }
            let found = (exact.isEmpty ? pool.filter { matches($0.title, name, strict: strict) } : exact).max { $0.playCount < $1.playCount }
            return found.map { ("song:\($0.id)", $0.title, .song) }
        }

        if name.isEmpty {
            if !album.isEmpty, let r = albumMatch(album) { return r }
            if !artist.isEmpty, let r = artistMatch(artist) { return r }
            if !genre.isEmpty, let r = genreMatch(genre) { return r }
            return ("shuffle", SiriLibrary.say("Ta bibliothèque", "Your library"), .music)
        }
        func pick() -> (String, String, INMediaItemType)? {
            switch type {
            case .playlist: return playlist()
            case .album: return albumMatch(name)
            case .artist: return artistMatch(name)
            case .genre: return genreMatch(name)
            case .song: return song()
            default: return song() ?? artistMatch(name) ?? playlist() ?? albumMatch(name) ?? genreMatch(name)
            }
        }
        // An exact name anywhere beats a near one: "Ridan" is the artist, not "Riding…".
        if let exact = pick() { return exact }
        strict = false
        return pick()
    }

    @MainActor
    private static func play(_ id: String, shuffle: Bool) -> Bool {
        let library = SiriLibrary.library, player = SiriLibrary.player
        let parts = id.split(separator: ":", maxSplits: 1).map(String.init)
        let value = parts.count > 1 ? parts[1] : ""
        switch parts[0] {
        case "song":
            guard let uuid = UUID(uuidString: value), let song = library.song(withID: uuid) else { return false }
            let album = SiriLibrary.songs(of: AlbumEntity(title: song.album, artist: LibraryIndex.artistName(for: song)))
            player.play(song: song, from: album.isEmpty ? [song] : album)
        case "playlist":
            guard let p = library.playlists.first(where: { $0.id.uuidString == value }) else { return false }
            let songs = p.songs.compactMap { library.song(withID: $0) }
            guard !songs.isEmpty else { return false }
            player.play(songs, shuffled: shuffle)
        case "album":
            let bits = value.split(separator: "\u{1F}", omittingEmptySubsequences: false).map(String.init)
            guard bits.count == 2 else { return false }
            let songs = SiriLibrary.songs(of: AlbumEntity(title: bits[0], artist: bits[1]))
            guard !songs.isEmpty else { return false }
            player.play(songs, shuffled: shuffle)
        case "artist":
            let songs = SiriLibrary.songs(of: ArtistEntity(id: value))
            guard !songs.isEmpty else { return false }
            player.play(songs, shuffled: true)
        case "genre":
            let songs = library.songs.filter { $0.genre == value }
            guard !songs.isEmpty else { return false }
            player.play(songs, shuffled: true)
        default:
            guard !library.songs.isEmpty else { return false }
            player.play(library.songs, shuffled: true)
        }
        return true
    }

    func resolveMediaItems(for intent: INPlayMediaIntent, with completion: @escaping ([INPlayMediaMediaItemResolutionResult]) -> Void) {
        nonisolated(unsafe) let search = intent.mediaSearch
        nonisolated(unsafe) let completion = completion
        Task { @MainActor in
            guard let found = Self.resolve(search) else {
                completion([INPlayMediaMediaItemResolutionResult(mediaItemResolutionResult: .unsupported())])
                return
            }
            let item = INMediaItem(identifier: found.id, title: found.title, type: found.type, artwork: nil)
            completion(INPlayMediaMediaItemResolutionResult.successes(with: [item]))
        }
    }

    func handle(intent: INPlayMediaIntent, completion: @escaping (INPlayMediaIntentResponse) -> Void) {
        let id = intent.mediaItems?.first?.identifier
        let shuffle = intent.playShuffled ?? false
        nonisolated(unsafe) let search = intent.mediaSearch
        nonisolated(unsafe) let completion = completion
        Task { @MainActor in
            let target = id ?? Self.resolve(search)?.id
            let ok = target.map { Self.play($0, shuffle: shuffle) } ?? false
            completion(INPlayMediaIntentResponse(code: ok ? .success : .failureUnknownMediaType, userActivity: nil))
        }
    }
}
