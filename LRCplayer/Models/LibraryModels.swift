import Foundation
import os

/// Stable identity of an album. Songs without an album tag become one
/// "single" each (like Apple Music) instead of one giant "Unknown Album".
struct AlbumID: Hashable, Codable, Sendable {
    let name: String
    let artist: String
    var singleSongID: UUID?

    /// Key used by the pinned-albums store ("artist|||name").
    var pinKey: String { "\(artist)|||\(name)" }
}

struct Album: Identifiable, Hashable {
    let id: AlbumID
    /// Display title (the song title for singles).
    let title: String
    let artist: String
    /// Sorted by disc, track, then title.
    let songs: [Song]
    let year: Int
    let genre: String
    let dateAdded: Date
    let duration: TimeInterval

    var isSingle: Bool { id.singleSongID != nil }

    /// A single or an EP rather than an album: so titled, or short (Apple's
    /// rule: up to six tracks and under 30 minutes) without a track number
    /// past six that would make it part of a longer album.
    var isSingleOrEP: Bool {
        if isSingle { return true }
        let lower = title.lowercased()
        if lower.hasSuffix(" - single") || lower.hasSuffix(" - ep") || lower.hasSuffix(" ep") || lower.contains("(ep)") || lower.contains("[ep]") { return true }
        return songs.count <= 6 && duration < 30 * 60 && songs.allSatisfy { $0.trackNumber <= 6 }
    }
    var artworkSource: ArtworkSource? { songs.first?.artworkSource }

    var formattedDuration: String {
        let minutes = Int(duration) / 60
        if minutes >= 60 {
            return String(localized: "\(minutes / 60) hr \(minutes % 60) min")
        }
        return String(localized: "\(minutes) min")
    }

    static func == (lhs: Album, rhs: Album) -> Bool {
        lhs.id == rhs.id && lhs.songs.map(\.id) == rhs.songs.map(\.id)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func sortedTracks(_ songs: [Song]) -> [Song] {
        songs.sorted { lhs, rhs in
            if lhs.discNumber != rhs.discNumber { return lhs.discNumber < rhs.discNumber }
            if lhs.trackNumber != rhs.trackNumber {
                // Untagged tracks (0) go after numbered ones.
                if lhs.trackNumber == 0 { return false }
                if rhs.trackNumber == 0 { return true }
                return lhs.trackNumber < rhs.trackNumber
            }
            return lhs.title.libraryCompare(rhs.title) == .orderedAscending
        }
    }
}

struct Artist: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let songs: [Song]
    let albumCount: Int
    var artworkSource: ArtworkSource? { songs.first?.artworkSource }

    static func == (lhs: Artist, rhs: Artist) -> Bool {
        lhs.name == rhs.name && lhs.songs.count == rhs.songs.count
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(name)
    }
}

struct Genre: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let songs: [Song]
    var artworkSource: ArtworkSource? { songs.first?.artworkSource }

    static func == (lhs: Genre, rhs: Genre) -> Bool {
        lhs.name == rhs.name && lhs.songs.count == rhs.songs.count
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(name)
    }
}

/// Everything the library screens derive from the song list, computed once per
/// change instead of on every view render.
struct LibraryIndex {
    var albums: [Album] = []
    var artists: [Artist] = []
    var genres: [Genre] = []
    var albumsByID: [AlbumID: Album] = [:]
    var albumIDBySongID: [UUID: AlbumID] = [:]
    var artistsByName: [String: Artist] = [:]
    var genresByName: [String: Genre] = [:]

    static let unknownAlbumNames: Set<String> = ["", "unknown album"]

    /// The artist a song counts for: its profile, or the main one it was
    /// merged into (the song itself still shows its own artist).
    static func artistName(for song: Song) -> String {
        ArtistMerges.main(for: taggedArtistName(for: song))
    }

    /// The artist as the file has it (album artist first).
    static func taggedArtistName(for song: Song) -> String {
        if let albumArtist = song.albumArtist?.trimmingCharacters(in: .whitespacesAndNewlines), !albumArtist.isEmpty {
            return albumArtist
        }
        let artist = song.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        return artist.isEmpty ? "Unknown Artist" : artist
    }

    init() {}

    init(songs: [Song]) {
        var singles: [Album] = []
        var byName: [String: [Song]] = [:]
        for song in songs {
            let name = song.album.trimmingCharacters(in: .whitespacesAndNewlines)
            if Self.unknownAlbumNames.contains(name.lowercased()) {
                let artist = Self.artistName(for: song)
                singles.append(Album(
                    id: AlbumID(name: song.title, artist: artist, singleSongID: song.id),
                    title: song.title,
                    artist: artist,
                    songs: [song],
                    year: song.year,
                    genre: song.genre,
                    dateAdded: song.addedAt,
                    duration: song.duration
                ))
            } else {
                byName[name, default: []].append(song)
            }
        }

        var albums = singles
        for (name, group) in byName {
            for (artist, albumSongs) in Self.splitByAlbumArtist(group) {
                let tracks = Album.sortedTracks(albumSongs)
                albums.append(Album(
                    id: AlbumID(name: name, artist: artist),
                    title: name,
                    artist: artist,
                    songs: tracks,
                    year: tracks.map(\.year).max() ?? 0,
                    genre: tracks.first(where: { !$0.genre.isEmpty })?.genre ?? "",
                    dateAdded: tracks.map(\.addedAt).max() ?? .distantPast,
                    duration: tracks.reduce(0) { $0 + max(0, $1.duration) }
                ))
            }
        }
        albums.sort {
            let order = $0.title.libraryCompare($1.title)
            if order != .orderedSame { return order == .orderedAscending }
            return $0.artist.libraryCompare($1.artist) == .orderedAscending
        }
        self.albums = albums

        for album in albums {
            albumsByID[album.id] = album
            for song in album.songs { albumIDBySongID[song.id] = album.id }
        }

        let albumCountByArtist = Dictionary(grouping: albums) { ArtistMerges.main(for: $0.artist) }.mapValues(\.count)
        artists = Dictionary(grouping: songs, by: Self.artistName(for:))
            .map { name, songs in
                Artist(
                    name: name,
                    songs: songs.sorted { $0.title.libraryCompare($1.title) == .orderedAscending },
                    albumCount: albumCountByArtist[name] ?? 0
                )
            }
            .sorted { $0.name.libraryCompare($1.name) == .orderedAscending }
        artistsByName = Dictionary(artists.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })

        genres = Dictionary(grouping: songs) { song -> String in
            let genre = song.genre.trimmingCharacters(in: .whitespacesAndNewlines)
            return genre.isEmpty ? "Unknown" : genre
        }
        .map { Genre(name: $0.key, songs: $0.value.sorted { $0.title.libraryCompare($1.title) == .orderedAscending }) }
        .sorted { $0.name.libraryCompare($1.name) == .orderedAscending }
        genresByName = Dictionary(genres.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Same-named albums by different album artists ("Greatest Hits") stay
    /// separate; untagged tracks join the biggest group, and compilations
    /// without an album artist tag stay together.
    private static func splitByAlbumArtist(_ songs: [Song]) -> [(String, [Song])] {
        var tagged: [String: [Song]] = [:]
        var untagged: [Song] = []
        for song in songs {
            if let albumArtist = song.albumArtist?.trimmingCharacters(in: .whitespacesAndNewlines), !albumArtist.isEmpty {
                tagged[albumArtist, default: []].append(song)
            } else {
                untagged.append(song)
            }
        }

        if tagged.isEmpty {
            let counts = Dictionary(grouping: untagged, by: { $0.artist }).mapValues(\.count)
            let artist = counts.max { lhs, rhs in
                lhs.value == rhs.value ? lhs.key > rhs.key : lhs.value < rhs.value
            }?.key ?? "Unknown Artist"
            // More than half the tracks by different artists: a compilation.
            let isCompilation = counts.count > 1 && (counts[artist] ?? 0) * 2 < untagged.count
            return [(isCompilation ? "Various Artists" : artist, untagged)]
        }

        var groups = tagged
        if !untagged.isEmpty, let biggest = groups.max(by: { $0.value.count < $1.value.count })?.key {
            groups[biggest, default: []].append(contentsOf: untagged)
        }
        return groups.map { ($0.key, $0.value) }
    }
}

extension String {
    /// Library ordering, like Apple Music: titles starting with a digit,
    /// punctuation or a symbol ("♪ Intro") first, then Latin letters, then
    /// other scripts (Arabic, Hebrew…). Inside a group: case/diacritic-
    /// insensitive with numeric runs ("Track 2" before "Track 10").
    /// Non-localized, so sorting thousands of songs stays fast.
    func libraryCompare(_ other: String) -> ComparisonResult {
        let group = librarySortGroup, otherGroup = other.librarySortGroup
        if group != otherGroup { return group < otherGroup ? .orderedAscending : .orderedDescending }
        return compare(other, options: [.caseInsensitive, .diacriticInsensitive, .numeric])
    }

    /// 0: starts with anything but a letter (the "#" section), 1: a Latin
    /// letter, 2: a letter from another script.
    var librarySortGroup: Int {
        guard let scalar = unicodeScalars.first(where: { !$0.properties.isWhitespace }),
              scalar.properties.isAlphabetic else { return 0 }
        switch scalar.value {
        case 0x41...0x5A, 0x61...0x7A, 0xC0...0x24F, 0x1E00...0x1EFF: return 1
        default: return 2
        }
    }
}

/// Artists merged into another: side projects under other names that count
/// as the main artist (its page, the stats, the assistant), while songs
/// keep showing the name their files carry.
enum ArtistMerges {
    static let didChange = Notification.Name("ArtistMergesDidChange")
    private static let key = "artistMerges"
    /// Read from the index, built off the main thread.
    private static let store = OSAllocatedUnfairLock(initialState: UserDefaults.standard.dictionary(forKey: "artistMerges") as? [String: String] ?? [:])

    /// Merged name → main name.
    static var all: [String: String] { store.withLock { $0 } }

    static func main(for name: String) -> String {
        store.withLock { $0[name] } ?? name
    }

    /// The names merged into this artist.
    static func merged(into main: String) -> [String] {
        all.filter { $0.value == main }.map(\.key).sorted { $0.libraryCompare($1) == .orderedAscending }
    }

    /// The merged artist and those merged into it go to the main one.
    static func merge(_ name: String, into main: String) {
        let target = Self.main(for: main)
        guard target != name else { return }
        update { merges in
            for (other, current) in merges where current == name { merges[other] = target }
            merges[name] = target
        }
    }

    static func unmerge(_ name: String) {
        update { $0[name] = nil }
    }

    private static func update(_ change: (inout [String: String]) -> Void) {
        var merges = all
        change(&merges)
        store.withLock { [merges] in $0 = merges }
        UserDefaults.standard.set(merges, forKey: key)
        NotificationCenter.default.post(name: didChange, object: nil)
    }
}
