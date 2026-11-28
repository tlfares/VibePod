import Foundation
import CryptoKit

// MARK: - Package

/// A listening history imported from another service's data export: its
/// songs, linked to the library when they're in it, and every play.
struct ImportedHistoryPackage: Codable, Identifiable, Sendable {
    enum Service: String, Codable, CaseIterable, Sendable {
        case spotify, appleMusic, deezer, youtubeMusic, lastfm, listenBrainz, other

        var name: String {
            switch self {
            case .spotify: "Spotify"
            case .appleMusic: "Apple Music"
            case .deezer: "Deezer"
            case .youtubeMusic: "YouTube Music"
            case .lastfm: "Last.fm"
            case .listenBrainz: "ListenBrainz"
            case .other: String(localized: "Other Service")
            }
        }
    }

    /// How a song of the export relates to the library.
    enum Link: String, Codable, Sendable {
        /// Same title, same artist: counted as the library song.
        case matched
        /// Likely the same song (another version, a title written
        /// differently): counted under its own name until checked.
        case review
        /// Checked: counted as the library song.
        case confirmed
        /// Not in the library: counted under its own name.
        case missing
        /// Marked as not in the library.
        case unlinked
        /// Left out of the stats.
        case excluded

        /// Decided by hand: matching again keeps it.
        var isSettled: Bool { self == .confirmed || self == .unlinked || self == .excluded }
    }

    struct Track: Codable, Sendable, Hashable {
        var title: String
        var artist: String
        var album: String
        var plays: Int
        /// Its length, when the export tells.
        var duration: Double?
        var songID: UUID?
        var link: Link

        /// Counted as the library song.
        var isLinked: Bool { songID != nil && (link == .matched || link == .confirmed) }
    }

    /// One play, packed in 16 bytes: an export holds hundreds of thousands.
    struct Play: Sendable {
        var track: Int32
        /// Seconds played; -1 when the export doesn't say.
        var seconds: Float32
        /// When it was logged, since the reference date.
        var time: Double
    }

    let id: UUID
    var name: String
    var service: Service
    let importedAt: Date
    var tracks: [Track]
    /// Export artist → library artist, confirmed.
    var aliases: [String: String]
    /// Entries of the export that don't count (under 30 seconds, podcasts,
    /// private sessions).
    var skipped: Int
    let firstPlay: Date
    let lastPlay: Date
    var plays: [Play]

    init(name: String, service: Service, tracks: [Track], aliases: [String: String], skipped: Int, plays: [Play]) {
        id = UUID()
        self.name = name
        self.service = service
        importedAt = Date()
        self.tracks = tracks
        self.aliases = aliases
        self.skipped = skipped
        self.plays = plays
        firstPlay = Date(timeIntervalSinceReferenceDate: plays.first?.time ?? 0)
        lastPlay = Date(timeIntervalSinceReferenceDate: plays.last?.time ?? 0)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, service, importedAt, tracks, aliases, skipped, firstPlay, lastPlay, plays
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        service = (try? container.decode(Service.self, forKey: .service)) ?? .other
        importedAt = try container.decode(Date.self, forKey: .importedAt)
        tracks = try container.decode([Track].self, forKey: .tracks)
        aliases = try container.decodeIfPresent([String: String].self, forKey: .aliases) ?? [:]
        skipped = try container.decodeIfPresent(Int.self, forKey: .skipped) ?? 0
        firstPlay = try container.decode(Date.self, forKey: .firstPlay)
        lastPlay = try container.decode(Date.self, forKey: .lastPlay)
        plays = Self.unpack(try container.decode(Data.self, forKey: .plays), trackCount: tracks.count)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(service, forKey: .service)
        try container.encode(importedAt, forKey: .importedAt)
        try container.encode(tracks, forKey: .tracks)
        try container.encode(aliases, forKey: .aliases)
        try container.encode(skipped, forKey: .skipped)
        try container.encode(firstPlay, forKey: .firstPlay)
        try container.encode(lastPlay, forKey: .lastPlay)
        try container.encode(plays.withUnsafeBufferPointer { Data(buffer: $0) }, forKey: .plays)
    }

    private static func unpack(_ data: Data, trackCount: Int) -> [Play] {
        let count = data.count / MemoryLayout<Play>.stride
        var plays = [Play](repeating: Play(track: 0, seconds: 0, time: 0), count: count)
        _ = plays.withUnsafeMutableBufferPointer { data.copyBytes(to: $0) }
        // A damaged file can't point past the songs.
        return plays.filter { $0.track >= 0 && Int($0.track) < trackCount }
    }

    // MARK: Figures

    /// Plays that count (not left out).
    var countedPlays: Int { tracks.reduce(0) { $0 + ($1.link == .excluded ? 0 : $1.plays) } }

    /// Plays counted as songs of the library.
    var linkedPlays: Int { tracks.reduce(0) { $0 + ($1.isLinked ? $1.plays : 0) } }

    var reviewCount: Int { tracks.reduce(0) { $0 + ($1.link == .review ? 1 : 0) } }

    /// Share of the counted plays that are songs of the library.
    var linkedShare: Double {
        let counted = countedPlays
        return counted > 0 ? Double(linkedPlays) / Double(counted) : 0
    }
}

// MARK: - Store

/// The imported histories, one file each in Application Support.
@MainActor @Observable
final class ImportedHistory {
    static let shared = ImportedHistory()
    static let didChange = Notification.Name("ImportedHistoryDidChange")
    /// Off by default: imported plays join the VibePod stats.
    static let separateKey = "importedHistoryShownSeparately"

    static var showsSeparately: Bool { UserDefaults.standard.bool(forKey: separateKey) }

    /// Oldest import first.
    private(set) var packages: [ImportedHistoryPackage] = []
    /// Plays of each import already counted by VibePod or an earlier import,
    /// as of the last time the stats were put together.
    @ObservationIgnored private(set) var duplicates: [UUID: Int] = [:]

    @ObservationIgnored private let saveQueue = DispatchQueue(label: "com.fares.lrc.player.history-import", qos: .utility)

    nonisolated private static var directory: URL {
        URL.applicationSupportDirectory.appending(path: "ListeningStats/Imports", directoryHint: .isDirectory)
    }

    private init() {
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.directory, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        packages = files
            .filter { $0.pathExtension == "json" }
            .compactMap { (try? Data(contentsOf: $0)).flatMap { try? decoder.decode(ImportedHistoryPackage.self, from: $0) } }
            .sorted { $0.importedAt < $1.importedAt }
    }

    func package(_ id: UUID) -> ImportedHistoryPackage? {
        packages.first { $0.id == id }
    }

    /// The artists linked so far, offered to the next import.
    var knownAliases: [String: String] {
        packages.reduce(into: [:]) { result, package in result.merge(package.aliases) { $1 } }
    }

    func add(_ package: ImportedHistoryPackage) {
        packages.append(package)
        save(package)
        changed()
    }

    func update(_ package: ImportedHistoryPackage) {
        guard let index = packages.firstIndex(where: { $0.id == package.id }) else { return }
        packages[index] = package
        save(package)
        changed()
    }

    func remove(_ id: UUID) {
        packages.removeAll { $0.id == id }
        let url = Self.file(for: id)
        saveQueue.async { try? FileManager.default.removeItem(at: url) }
        changed()
    }

    /// Merged duplicates: links follow the songs they became.
    func replaceSongIDs(_ replacements: [UUID: UUID]) {
        for var package in packages where package.tracks.contains(where: { $0.songID.map { replacements[$0] != nil } ?? false }) {
            for index in package.tracks.indices {
                if let id = package.tracks[index].songID, let kept = replacements[id] {
                    package.tracks[index].songID = kept
                }
            }
            update(package)
        }
    }

    /// Matches the songs again (the library changed), keeping what was
    /// decided by hand.
    func matchAgain(_ id: UUID) async {
        guard let package = package(id) else { return }
        let library = HistoryLibrarySong.snapshot()
        let tracks = package.tracks
        let aliases = package.aliases
        let matched = await Task.detached(priority: .userInitiated) {
            HistoryMatcher(songs: library).match(tracks, aliases: aliases)
        }.value
        guard var current = self.package(id) else { return }
        current.tracks = matched
        update(current)
    }

    // MARK: Corrections

    func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var package = package(id), !trimmed.isEmpty, trimmed != package.name else { return }
        package.name = trimmed
        update(package)
    }

    /// Links a song of the export to a library song, or not.
    func setLink(_ id: UUID, track: Int, songID: UUID?, link: ImportedHistoryPackage.Link) {
        guard var package = package(id), package.tracks.indices.contains(track) else { return }
        package.tracks[track].songID = songID
        package.tracks[track].link = link
        update(package)
    }

    /// Every song to check is the song proposed.
    func confirmAll(_ id: UUID) {
        guard var package = package(id) else { return }
        for index in package.tracks.indices where package.tracks[index].link == .review {
            package.tracks[index].link = .confirmed
        }
        update(package)
    }

    /// An artist of the export is this artist of the library (or no longer
    /// is): its songs are matched again.
    func setAlias(_ id: UUID, exportArtist: String, libraryArtist: String?) async {
        guard var package = package(id) else { return }
        package.aliases[exportArtist] = libraryArtist
        if libraryArtist == nil {
            // What the link brought is matched again from scratch.
            for index in package.tracks.indices where package.tracks[index].artist == exportArtist && package.tracks[index].link != .excluded {
                package.tracks[index].link = .missing
            }
        }
        update(package)
        await matchAgain(id)
    }

    private func changed() {
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    nonisolated private static func file(for id: UUID) -> URL {
        directory.appending(path: id.uuidString + ".json")
    }

    private func save(_ package: ImportedHistoryPackage) {
        let url = Self.file(for: package.id)
        saveQueue.async {
            try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            guard let data = try? JSONEncoder().encode(package) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: Stats

    /// The imported plays as stats entries, oldest first. A play already
    /// counted (by VibePod, or by an earlier import: Last.fm scrobbles of
    /// Spotify plays) is left out.
    func entries(own: [ListeningStatsEntry]) -> [ListeningStatsEntry] {
        let built = Self.build(packages, own: own)
        duplicates = built.duplicates
        return built.entries
    }

    static func build(_ packages: [ImportedHistoryPackage], own: [ListeningStatsEntry]) -> (entries: [ListeningStatsEntry], duplicates: [UUID: Int]) {
        guard !packages.isEmpty else { return ([], [:]) }
        let library = AppModel.shared.libraryService

        // Song → times of its plays so far, sorted.
        var seen: [UUID: [Double]] = [:]
        for entry in own {
            seen[entry.songID, default: []].append(entry.timestamp.timeIntervalSinceReferenceDate)
        }
        for key in seen.keys { seen[key]?.sort() }

        struct Resolved {
            let id: UUID
            let title: String
            let artist: String
            let album: String
            let duration: Double
        }

        var entries: [ListeningStatsEntry] = []
        entries.reserveCapacity(packages.reduce(0) { $0 + $1.plays.count })
        var duplicates: [UUID: Int] = [:]
        for package in packages.sorted(by: { $0.importedAt < $1.importedAt }) {
            let resolved = package.tracks.map { track -> Resolved? in
                guard track.link != .excluded else { return nil }
                if track.isLinked, let id = track.songID, let song = library.song(withID: id) {
                    return Resolved(id: id, title: song.title, artist: song.artist, album: song.album, duration: song.duration > 0 ? song.duration : track.duration ?? HistoryText.typicalLength)
                }
                let artist = package.aliases[track.artist] ?? track.artist
                return Resolved(
                    id: HistoryText.stableID(title: track.title, artist: artist),
                    title: track.title,
                    artist: artist,
                    album: track.album,
                    duration: track.duration ?? HistoryText.typicalLength
                )
            }
            var added: [UUID: [Double]] = [:]
            var skipped = 0
            for play in package.plays {
                guard let track = resolved[Int(play.track)] else { continue }
                let seconds = play.seconds >= 0 ? Double(play.seconds) : track.duration
                // Services log the start or the end: a track's length apart.
                let window = min(900, max(seconds, track.duration) + 120)
                if let times = seen[track.id], contains(times, near: play.time, within: window) {
                    skipped += 1
                    continue
                }
                added[track.id, default: []].append(play.time)
                entries.append(ListeningStatsEntry(
                    songID: track.id,
                    title: track.title,
                    artist: track.artist,
                    album: track.album,
                    timestamp: Date(timeIntervalSinceReferenceDate: play.time),
                    durationPlayed: min(seconds, 1800)
                ))
            }
            for (id, times) in added {
                seen[id, default: []].append(contentsOf: times)
                seen[id]?.sort()
            }
            duplicates[package.id] = skipped
        }
        entries.sort { $0.timestamp < $1.timestamp }
        return (entries, duplicates)
    }

    private static func contains(_ times: [Double], near time: Double, within window: Double) -> Bool {
        var low = 0, high = times.count
        while low < high {
            let mid = (low + high) / 2
            if times[mid] < time - window { low = mid + 1 } else { high = mid }
        }
        return low < times.count && times[low] <= time + window
    }
}

// MARK: - Text

/// Keys that compare titles and artists as people write them.
enum HistoryText {
    /// A song's length when nothing tells it.
    static let typicalLength: Double = 210

    private static let locale = Locale(identifier: "en_US_POSIX")

    /// Lowercased, without accents, punctuation or apostrophes; "&" is "and".
    static func key(_ value: String) -> String {
        let folded = value.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: locale)
        var scalars = String.UnicodeScalarView()
        var space = false
        func word(_ text: String) {
            if space, !scalars.isEmpty { scalars.append(" ") }
            space = false
            scalars.append(contentsOf: text.unicodeScalars)
        }
        for scalar in folded.unicodeScalars {
            switch scalar {
            case "'", "’", "`", "´": continue
            case "&", "+":
                space = true
                word("and")
                space = true
            default:
                if CharacterSet.alphanumerics.contains(scalar) {
                    if space, !scalars.isEmpty { scalars.append(" ") }
                    space = false
                    scalars.append(scalar)
                } else {
                    space = true
                }
            }
        }
        return String(scalars)
    }

    /// The title without what tells the version: brackets, " - Remastered
    /// 2011", "feat. …".
    static func looseTitle(_ title: String) -> String {
        key(split(title).base)
    }

    /// Another recording (live, acoustic, remix…), not just a remaster.
    static func isVariant(_ title: String) -> Bool {
        let extra = Set(key(split(title).extra).split(separator: " ").map(String.init))
        return !extra.isDisjoint(with: variantWords)
    }

    private static let variantWords: Set<String> = [
        "live", "acoustic", "remix", "demo", "instrumental", "unplugged", "session", "sessions",
        "cover", "karaoke", "sped", "slowed", "reprise", "acapella", "cappella", "orchestral",
        "rehearsal", "alternate", "alt", "take", "rework", "bootleg", "nightcore", "reverb"
    ]

    private static let versionWords: Set<String> = [
        "remaster", "remastered", "remasterise", "remasterisé", "version", "edit", "mix", "remix", "live",
        "demo", "acoustic", "instrumental", "mono", "stereo", "session", "sessions", "recorded", "take",
        "single", "radio", "bonus", "explicit", "clean", "original", "unplugged", "deluxe",
        "anniversary", "extended", "sped", "slowed", "acapella", "cover", "rerecorded", "re", "from"
    ]

    /// Splits a title into what names the song and what names the version.
    private static func split(_ title: String) -> (base: String, extra: String) {
        var base = ""
        var extra = ""
        var depth = 0
        for character in title {
            switch character {
            case "(", "[", "{":
                depth += 1
                extra.append(" ")
            case ")", "]", "}":
                depth = max(0, depth - 1)
                extra.append(" ")
            default:
                if depth > 0 { extra.append(character) } else { base.append(character) }
            }
        }
        // " - Remastered 2011", " – Live at …": only when it names a version.
        for dash in [" - ", " – ", " — "] {
            if let range = base.range(of: dash) {
                let suffix = String(base[range.upperBound...])
                let words = Set(key(suffix).split(separator: " ").map(String.init))
                let isYear = words.contains { $0.count == 4 && Int($0).map { (1900...2100).contains($0) } == true }
                if !words.isDisjoint(with: versionWords) || isYear {
                    extra += " " + suffix
                    base = String(base[..<range.lowerBound])
                }
                break
            }
        }
        let lower = base.lowercased()
        for marker in [" feat. ", " feat ", " ft. ", " ft ", " featuring "] {
            if let range = lower.range(of: marker) {
                let offset = lower.distance(from: lower.startIndex, to: range.lowerBound)
                let cut = base.index(base.startIndex, offsetBy: offset)
                extra += " " + String(base[cut...])
                base = String(base[..<cut])
                break
            }
        }
        return (base, extra)
    }

    /// The artist's keys: the whole credit, its first name ("A feat. B",
    /// "A, B", "A & B"), without a leading "the".
    static func artistKeys(_ artist: String) -> Set<String> {
        var keys: Set<String> = []
        func add(_ value: String) {
            let key = key(value)
            guard !key.isEmpty else { return }
            keys.insert(key)
            if key.hasPrefix("the "), key.count > 6 { keys.insert(String(key.dropFirst(4))) }
        }
        add(artist)
        let lower = artist.lowercased()
        var cut = lower.endIndex
        for separator in [",", ";", " & ", " feat", " ft.", " ft ", " x ", " with ", " vs", " / ", " featuring "] {
            if let range = lower.range(of: separator), range.lowerBound < cut { cut = range.lowerBound }
        }
        if cut != lower.endIndex {
            let offset = lower.distance(from: lower.startIndex, to: cut)
            add(String(artist.prefix(offset)))
        }
        return keys
    }

    /// The same ID for the same song not in the library, import after
    /// import (the rankings and the hidden items key songs by ID).
    static func stableID(title: String, artist: String) -> UUID {
        let digest = SHA256.hash(data: Data(("vibepod-history|" + key(title) + "|" + key(artist)).utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

// MARK: - Grouping

/// An export's plays gathered per song.
struct HistoryGrouped: Sendable {
    var service: ImportedHistoryPackage.Service
    var tracks: [ImportedHistoryPackage.Track]
    var plays: [ImportedHistoryPackage.Play]
    var skipped: Int

    init(_ export: HistoryExport) {
        service = export.service
        skipped = export.skipped
        var index: [String: Int] = [:]
        var tracks: [ImportedHistoryPackage.Track] = []
        var albums: [[String: Int]] = []
        var plays: [ImportedHistoryPackage.Play] = []
        plays.reserveCapacity(export.plays.count)
        for play in export.plays {
            let title = play.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let artist = play.artist.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            let key = title + "\u{1F}" + artist
            let position: Int
            if let found = index[key] {
                position = found
            } else {
                position = tracks.count
                index[key] = position
                tracks.append(.init(title: title, artist: artist, album: "", plays: 0, songID: nil, link: .missing))
                albums.append([:])
            }
            tracks[position].plays += 1
            if let length = play.trackDuration, length > 0 {
                tracks[position].duration = max(tracks[position].duration ?? 0, length)
            }
            let album = play.album.trimmingCharacters(in: .whitespacesAndNewlines)
            if !album.isEmpty { albums[position][album, default: 0] += 1 }
            plays.append(.init(track: Int32(position), seconds: play.seconds.map { Float32($0) } ?? -1, time: play.end.timeIntervalSinceReferenceDate))
        }
        for position in tracks.indices {
            tracks[position].album = albums[position].max { $0.value < $1.value }?.key ?? ""
        }
        self.tracks = tracks
        self.plays = plays
    }
}

// MARK: - Matching

/// A library song's keys, read once on the main actor.
struct HistoryLibrarySong: Sendable {
    let id: UUID
    let title: String
    let loose: String
    let isVariant: Bool
    let artists: Set<String>
    /// The artist it counts for in the stats.
    let artistName: String
    let album: String
    let duration: Double

    /// A merged song also answers to the songs it's made of: services only
    /// know those.
    @MainActor
    static func snapshot() -> [HistoryLibrarySong] {
        AppModel.shared.libraryService.songs.flatMap { song in
            let artistName = LibraryIndex.artistName(for: song)
            let parts = SongMergeService.shared.merge(for: song.id)?.parts.map(\.song) ?? []
            return ([song] + parts).map { source in
                var artists = HistoryText.artistKeys(source.artist)
                if let albumArtist = source.albumArtist { artists.formUnion(HistoryText.artistKeys(albumArtist)) }
                artists.formUnion(HistoryText.artistKeys(artistName))
                return HistoryLibrarySong(
                    id: song.id,
                    title: HistoryText.key(source.title),
                    loose: HistoryText.looseTitle(source.title),
                    isVariant: HistoryText.isVariant(source.title),
                    artists: artists,
                    artistName: artistName,
                    album: HistoryText.key(source.album),
                    duration: source.duration
                )
            }
        }
    }
}

/// Links an export's songs to the library's.
///
/// - Same title (punctuation and case aside) and same artist: linked.
/// - Same title once the version is set aside (" - Remastered 2011",
///   "(feat. …)"): linked, unless one is another recording (live, remix…),
///   then to check.
/// - A title written differently by an artist of the library: to check.
/// - Albums don't decide: a song is the same on an album, a single or a
///   compilation, whatever the service grouped it in.
/// - An artist the library knows under another name (a project, a former
///   name) is linked by hand, never guessed.
struct HistoryMatcher: Sendable {
    let songs: [HistoryLibrarySong]
    private let byTitle: [String: [Int]]
    private let byLoose: [String: [Int]]
    private let byArtist: [String: [Int]]
    /// Library artist keys → name.
    let artistNames: [String: String]

    init(songs: [HistoryLibrarySong]) {
        self.songs = songs
        var byTitle: [String: [Int]] = [:]
        var byLoose: [String: [Int]] = [:]
        var byArtist: [String: [Int]] = [:]
        var artistNames: [String: String] = [:]
        for (index, song) in songs.enumerated() {
            byTitle[song.title, default: []].append(index)
            if !song.loose.isEmpty { byLoose[song.loose, default: []].append(index) }
            for artist in song.artists { byArtist[artist, default: []].append(index) }
            artistNames[HistoryText.key(song.artistName)] = song.artistName
        }
        self.byTitle = byTitle
        self.byLoose = byLoose
        self.byArtist = byArtist
        self.artistNames = artistNames
    }

    func match(_ tracks: [ImportedHistoryPackage.Track], aliases: [String: String]) -> [ImportedHistoryPackage.Track] {
        var aliasKeys: [String: String] = [:]
        for (export, library) in aliases { aliasKeys[HistoryText.key(export)] = HistoryText.key(library) }

        var result = tracks
        for position in result.indices where !result[position].link.isSettled {
            let track = result[position]
            let title = HistoryText.key(track.title)
            let loose = HistoryText.looseTitle(track.title)
            var artists = HistoryText.artistKeys(track.artist)
            if let alias = aliasKeys[HistoryText.key(track.artist)] { artists.insert(alias) }
            let album = HistoryText.key(track.album)
            func fits(_ song: Int) -> Bool { !songs[song].artists.isDisjoint(with: artists) }

            if let exact = byTitle[title]?.filter(fits), !exact.isEmpty {
                result[position].songID = songs[pick(exact, album: album, duration: track.duration)].id
                result[position].link = .matched
                continue
            }
            if !loose.isEmpty, let near = byLoose[loose]?.filter(fits), !near.isEmpty {
                let song = pick(near, album: album, duration: track.duration)
                let variant = HistoryText.isVariant(track.title)
                result[position].songID = songs[song].id
                result[position].link = variant || songs[song].isVariant ? .review : .matched
                continue
            }
            // The same song with its title written differently.
            if loose.count >= 5, let song = closest(to: loose, among: artists.flatMap { byArtist[$0] ?? [] }) {
                result[position].songID = songs[song].id
                result[position].link = .review
                continue
            }
            result[position].songID = nil
            result[position].link = .missing
        }

        return result
    }

    private func pick(_ candidates: [Int], album: String, duration: Double?) -> Int {
        if candidates.count == 1 { return candidates[0] }
        if !album.isEmpty, let same = candidates.first(where: { songs[$0].album == album }) { return same }
        if let duration {
            return candidates.min { abs(songs[$0].duration - duration) < abs(songs[$1].duration - duration) } ?? candidates[0]
        }
        return candidates[0]
    }

    /// The artist's song whose title holds this one, or is held by it.
    private func closest(to loose: String, among candidates: [Int]) -> Int? {
        var best: (song: Int, gap: Int)?
        for song in Set(candidates) {
            let other = songs[song].loose
            guard other.count >= 5 else { continue }
            let (short, long) = other.count < loose.count ? (other, loose) : (loose, other)
            guard long.contains(short), short.count * 5 >= long.count * 2 else { continue }
            let gap = long.count - short.count
            if best.map({ gap < $0.gap }) ?? true { best = (song, gap) }
        }
        return best?.song
    }
}

// MARK: - Import session

/// One import, from the files to the package added.
@MainActor @Observable
final class HistoryImportSession {
    enum Phase: Equatable {
        case reading
        case matching
        case ready
        case failed(String)
    }

    private(set) var phase: Phase = .reading
    var name = ""
    private(set) var grouped: HistoryGrouped?
    private(set) var tracks: [ImportedHistoryPackage.Track] = []
    private(set) var aliases: [String: String] = [:]
    private(set) var duplicates = 0

    @ObservationIgnored private var matcher: HistoryMatcher?
    @ObservationIgnored private var task: Task<Void, Never>?

    init(urls: [URL]) {
        let library = HistoryLibrarySong.snapshot()
        let known = ImportedHistory.shared.knownAliases
        task = Task { [weak self] in
            do {
                let grouped = try await Task.detached(priority: .userInitiated) {
                    let scoped = urls.filter { $0.startAccessingSecurityScopedResource() }
                    defer { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }
                    return HistoryGrouped(try HistoryImportParser.read(urls))
                }.value
                guard let self, !Task.isCancelled else { return }
                self.grouped = grouped
                self.name = grouped.service.name
                self.phase = .matching
                // Only the links that concern this export's artists.
                let artists = Set(grouped.tracks.map(\.artist))
                let aliases = known.filter { artists.contains($0.key) }
                let tracks = grouped.tracks
                let (matcher, outcome) = await Task.detached(priority: .userInitiated) {
                    let matcher = HistoryMatcher(songs: library)
                    return (matcher, matcher.match(tracks, aliases: aliases))
                }.value
                guard !Task.isCancelled else { return }
                self.matcher = matcher
                self.aliases = aliases
                self.tracks = outcome
                self.finish()
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.phase = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        task?.cancel()
    }

    /// An artist of the export is this artist of the library: its songs
    /// are matched again.
    func link(_ exportArtist: String, to libraryArtist: String) {
        guard let matcher else { return }
        aliases[exportArtist] = libraryArtist
        phase = .matching
        let tracks = tracks
        let aliases = aliases
        task = Task { [weak self] in
            let matched = await Task.detached(priority: .userInitiated) {
                matcher.match(tracks, aliases: aliases)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.tracks = matched
            self.finish()
        }
    }

    private func finish() {
        guard let grouped else { return }
        let draft = makePackage(from: grouped)
        let existing = ImportedHistory.shared.packages
        duplicates = ImportedHistory.build(existing + [draft], own: ListeningStatsService.shared.ownEntries()).duplicates[draft.id] ?? 0
        phase = .ready
    }

    private func makePackage(from grouped: HistoryGrouped) -> ImportedHistoryPackage {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return ImportedHistoryPackage(
            name: trimmed.isEmpty ? grouped.service.name : trimmed,
            service: grouped.service,
            tracks: tracks,
            aliases: aliases,
            skipped: grouped.skipped,
            plays: grouped.plays
        )
    }

    /// Adds the plays to the stats.
    func commit() {
        guard phase == .ready, let grouped else { return }
        ImportedHistory.shared.add(makePackage(from: grouped))
    }

    // MARK: Figures

    var service: ImportedHistoryPackage.Service { grouped?.service ?? .other }
    var playCount: Int { grouped?.plays.count ?? 0 }
    var firstPlay: Date? { grouped?.plays.first.map { Date(timeIntervalSinceReferenceDate: $0.time) } }
    var lastPlay: Date? { grouped?.plays.last.map { Date(timeIntervalSinceReferenceDate: $0.time) } }
    var linkedPlays: Int { tracks.reduce(0) { $0 + ($1.isLinked ? $1.plays : 0) } }
    var reviewCount: Int { tracks.reduce(0) { $0 + ($1.link == .review ? 1 : 0) } }
    var missingCount: Int { tracks.reduce(0) { $0 + ($1.link == .missing ? 1 : 0) } }
}
