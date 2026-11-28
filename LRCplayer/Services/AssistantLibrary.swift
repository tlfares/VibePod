import Foundation

/// Names as people say them: no case, accents or punctuation, "&" as "and".
enum AssistantText {
    static func normalize(_ text: String) -> String {
        let folded = text
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .replacingOccurrences(of: "&", with: " and ")
        var result = ""
        var lastWasSpace = true
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                result.unicodeScalars.append(scalar)
                lastWasSpace = false
            } else if !lastWasSpace, scalar != "'", scalar != "’", scalar != "." {
                result.append(" ")
                lastWasSpace = true
            }
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// Without spaces: "AC/DC", "ACDC" and "AC DC" meet.
    static func compact(_ normalized: String) -> String {
        normalized.replacingOccurrences(of: " ", with: "")
    }

    /// The title without its version marks: "By Degrees (2013)", "By Degrees
    /// redux" and "By Degrees - Live" all give "by degrees".
    static func baseTitle(_ title: String) -> String {
        var text = title.replacingOccurrences(of: "\\([^)]*\\)|\\[[^\\]]*\\]", with: " ", options: .regularExpression)
        if let dash = text.range(of: " - ") { text = String(text[..<dash.lowerBound]) }
        var words = normalize(text).split(separator: " ").map(String.init)
        while words.count > 1, let last = words.last, versionWords.contains(last) || (last.count == 4 && Int(last) != nil) {
            words.removeLast()
        }
        return words.isEmpty ? normalize(title) : words.joined(separator: " ")
    }

    private static let versionWords: Set<String> = [
        "redux", "remix", "remixed", "mix", "live", "version", "acoustic", "acoustique", "demo", "edit", "remaster",
        "remastered", "reprise", "rerecorded", "recorded", "re", "radio", "extended", "alt", "alternate", "take",
        "mono", "stereo", "instrumental", "unplugged", "session", "sessions", "rework", "reworked", "redo", "new",
    ]

    /// `needle` appears in `haystack` as whole words.
    static func containsWords(_ haystack: String, _ needle: String) -> Bool {
        guard !needle.isEmpty else { return false }
        return " \(haystack) ".contains(" \(needle) ")
    }

    /// 1 for the same text, 0 for nothing in common (edit distance, on the
    /// compact forms so a speech recognizer's split words still meet).
    static func similarity(_ lhs: String, _ rhs: String) -> Double {
        let a = Array(compact(lhs)), b = Array(compact(rhs))
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        if a == b { return 1 }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return 1 - Double(previous[b.count]) / Double(max(a.count, b.count))
    }

    /// The candidates `wanted` names: exact first, then whole words inside
    /// (with `widen`, both), then close spellings.
    static func match(_ wanted: String, in candidates: [String], widen: Bool = false) -> [String] {
        let key = normalize(wanted)
        guard !key.isEmpty else { return [] }
        let compactKey = compact(key)
        let exact = candidates.filter { $0 == key || compact($0) == compactKey }
        let inside = candidates.filter { candidate in
            containsWords(candidate, key) || (candidate.count >= 4 && containsWords(key, candidate) && key.split(separator: " ").count <= 4)
        }
        if !exact.isEmpty { return widen ? Array(Set(exact + inside)) : exact }
        if !inside.isEmpty { return inside }
        let scored = candidates.map { ($0, similarity($0, key)) }.filter { $0.1 >= 0.78 }
        if let best = scored.map(\.1).max() { return scored.filter { $0.1 >= best - 0.02 }.map(\.0) }
        // Then names that sound the same however they were spelled: speech
        // in one language writes names from another its own way ("beau
        // beurre" for Bo Burnham). Only the closest one, never a family.
        let sound = skeleton(key)
        guard sound.count >= 3 else { return [] }
        let heard = candidates.compactMap { candidate -> (String, Double)? in
            let other = skeleton(candidate)
            guard other.first == sound.first else { return nil }
            let score = similarity(other, sound)
            return score >= 0.6 ? (candidate, score + similarity(candidate, key) / 10) : nil
        }
        guard let best = heard.max(by: { $0.1 < $1.1 }) else { return [] }
        return heard.filter { $0.1 >= best.1 - 0.01 }.map(\.0)
    }

    /// The consonants as heard, whatever the spelling: "beau beurre" and
    /// "bo burnham" give "bbr" and "bbrnm".
    static func skeleton(_ normalized: String) -> String {
        normalized.split(separator: " ").map { word -> String in
            var word = String(word)
            for (from, to) in [("ph", "f"), ("ch", "x"), ("sh", "x"), ("ck", "k"), ("qu", "k"), ("c", "k"), ("q", "k"), ("z", "s"), ("y", "i"), ("w", "v")] {
                word = word.replacingOccurrences(of: from, with: to)
            }
            var sound = ""
            for letter in word where !"aeiouh".contains(letter) && sound.last != letter { sound.append(letter) }
            return sound
        }.joined()
    }

    /// What a spoken genre may be called in the library.
    static let genreSynonyms: [String: [String]] = [
        "rap": ["hip hop", "hip hop rap", "rap francais", "french rap", "trap"],
        "hip hop": ["rap", "hip hop rap"],
        "rap francais": ["rap", "french rap", "hip hop rap"],
        "electro": ["electronic", "electronica", "dance", "house", "techno", "edm"],
        "electronique": ["electronic", "electronica", "dance", "house", "techno"],
        "rnb": ["r and b", "rhythm and blues", "soul", "r and b soul"],
        "variete": ["variete francaise", "french pop", "chanson", "chanson francaise", "pop"],
        "classique": ["classical"],
        "metal": ["heavy metal", "hard rock"],
        "reggaeton": ["latin", "latin urban", "reggaeton"],
        "k pop": ["kpop", "k pop"],
        "film": ["soundtrack", "original score", "bande originale"],
        "bo": ["soundtrack", "original score"]
    ]
}

/// The library as the assistant sees it for one request: matching, digests
/// and lookups. Built fresh for each turn (cheap), read on the main actor.
@MainActor
final class AssistantLibrary {
    let songs: [Song]
    let playlists: [Playlist]
    let nowPlaying: Song?
    private let libraryService: LibraryService
    private let player: MusicPlayerService
    private let history = AutolistEngine.HistoryCounts()
    /// What the library analysis measured, if it ran.
    private let sound = LibrarySoundAnalysis.storedProfiles()

    private lazy var artistKeys: [UUID: (artist: String, albumArtist: String)] = Dictionary(uniqueKeysWithValues: songs.map {
        ($0.id, (AssistantText.normalize($0.artist), AssistantText.normalize(LibraryIndex.artistName(for: $0))))
    })
    private lazy var allArtistKeys: [String] = Array(Set(artistKeys.values.flatMap { [$0.artist, $0.albumArtist] }))
    private lazy var songsByID: [UUID: Song] = Dictionary(songs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

    /// "Title — Artist (Album, 2016)": the album and year tell a redux or a
    /// live version from the original.
    func label(_ title: String, _ artist: String, id: UUID? = nil) -> String {
        guard let song = id.flatMap({ songsByID[$0] }) else { return "\(title) — \(artist)" }
        return "\(title) — \(artist) (\(song.album)\(song.year > 0 ? ", \(song.year)" : ""))"
    }

    func label(_ song: Song) -> String {
        label(song.title, song.artist, id: song.id)
    }

    private func albumLabel(_ song: Song) -> String {
        "\(song.album) — \(LibraryIndex.artistName(for: song))\(song.year > 0 ? " (\(song.year))" : "")"
    }

    /// Songs without a genre tag: the files say nothing, the user's taste does.
    private static let unknownGenre = "Unknown"

    lazy var genreKeys: [UUID: String] = Dictionary(uniqueKeysWithValues: songs.map {
        ($0.id, AssistantText.normalize(AutolistEngine.genreName(of: $0)))
    })

    init(libraryService: LibraryService, player: MusicPlayerService) {
        self.libraryService = libraryService
        self.player = player
        songs = libraryService.songs
        playlists = libraryService.playlists
        nowPlaying = player.currentSong
    }

    // MARK: Matching

    struct Resolution {
        var songs: [Song] = []
        /// What couldn't be found, as the user would read it.
        var missing: [String] = []
    }

    func playlist(named name: String) -> Playlist? {
        let names = playlists.map { AssistantText.normalize($0.name) }
        guard let key = AssistantText.match(name, in: names).first else { return nil }
        return playlists.first { AssistantText.normalize($0.name) == key }
    }

    /// The display names (as the library writes them) `wanted` points at.
    func artistNames(matching wanted: String) -> [String] {
        let keys = Set(AssistantText.match(wanted, in: allArtistKeys, widen: true))
        guard !keys.isEmpty else { return [] }
        var names: [String] = []
        for song in songs {
            let name = LibraryIndex.artistName(for: song)
            // A merged profile's own name finds its main artist too.
            let tagged = LibraryIndex.taggedArtistName(for: song)
            if keys.contains(AssistantText.normalize(name)) || keys.contains(AssistantText.normalize(tagged)), !names.contains(name) { names.append(name) }
        }
        return names
    }

    func genreNames(matching wanted: String) -> [String] {
        let keys = genreKeySet(for: wanted)
        var names: [String] = []
        for song in songs where keys.contains(genreKeys[song.id] ?? "") {
            let name = AutolistEngine.genreName(of: song)
            if !names.contains(name) { names.append(name) }
        }
        return names
    }

    private func genreKeySet(for wanted: String) -> Set<String> {
        let candidates = Array(Set(genreKeys.values))
        var keys = Set(AssistantText.match(wanted, in: candidates, widen: true))
        if keys.isEmpty {
            for synonym in AssistantText.genreSynonyms[AssistantText.normalize(wanted)] ?? [] {
                keys.formUnion(AssistantText.match(synonym, in: candidates, widen: true))
            }
        }
        return keys
    }

    private func artistKeySet(for wanted: String) -> Set<String> {
        Set(AssistantText.match(wanted, in: allArtistKeys, widen: true))
    }

    func resolve(_ query: SongQuery) -> Resolution {
        var result = Resolution()
        if query.nowPlaying == true {
            if let nowPlaying { result.songs = [nowPlaying] } else { result.missing.append("the current song (nothing is playing)") }
            return result
        }

        var pool = songs
        var playlistOrder: [UUID]?

        if let names = query.playlists?.nonEmpty {
            var ids: [UUID] = []
            for name in names {
                if let playlist = playlist(named: name) {
                    ids += playlist.songs.filter { !ids.contains($0) }
                } else {
                    result.missing.append("playlist “\(name)”")
                }
            }
            let set = Set(ids)
            pool = pool.filter { set.contains($0.id) }
            playlistOrder = ids
        }

        if let artists = query.artists?.nonEmpty {
            var keys = Set<String>()
            for artist in artists {
                let found = artistKeySet(for: artist)
                if found.isEmpty { result.missing.append("artist “\(artist)”") }
                keys.formUnion(found)
            }
            pool = pool.filter { song in
                guard let key = artistKeys[song.id] else { return false }
                return keys.contains(key.artist) || keys.contains(key.albumArtist)
                    || keys.contains { AssistantText.containsWords(key.artist, $0) }
            }
        }

        if let excluded = query.excludeArtists?.nonEmpty {
            let keys = Set(excluded.flatMap(artistKeySet(for:)))
            pool = pool.filter { song in
                guard let key = artistKeys[song.id] else { return true }
                return !keys.contains(key.artist) && !keys.contains(key.albumArtist)
            }
        }

        if let albums = query.albums?.nonEmpty {
            let candidates = Array(Set(pool.map { AssistantText.normalize($0.album) }))
            var keys = Set<String>()
            for album in albums {
                let found = AssistantText.match(album, in: candidates)
                if found.isEmpty { result.missing.append("album “\(album)”") }
                keys.formUnion(found)
            }
            pool = pool.filter { keys.contains(AssistantText.normalize($0.album)) }
        }

        if let genres = query.genres?.nonEmpty {
            var keys = Set<String>()
            for genre in genres {
                let found = genreKeySet(for: genre)
                if found.isEmpty { result.missing.append("genre “\(genre)”") }
                keys.formUnion(found)
            }
            pool = pool.filter { keys.contains(genreKeys[$0.id] ?? "") }
        }

        if let subjects = query.about?.nonEmpty {
            pool = pool.filter { !subjectMatches(of: $0, subjects).isEmpty }
            if pool.isEmpty { result.missing.append("songs about “\(subjects.joined(separator: "”, “"))”") }
        }

        if query.yearFrom != nil || query.yearTo != nil {
            let from = query.yearFrom ?? 0, to = query.yearTo ?? 9999
            pool = pool.filter { $0.year > 0 && $0.year >= min(from, to) && $0.year <= max(from, to) }
        }

        if query.withLyrics == true {
            pool = pool.filter { $0.lrcFilePath != nil }
        }

        if let mood = query.mood {
            if sound.isEmpty { result.missing.append("song moods (the library hasn't been analyzed in Stats)") }
            // A leaning, not a wall: an artist with no calm song still gives
            // their calmest third for a sleep mix.
            let measured = pool.filter { sound[$0.id] != nil }
            // Songs not analyzed yet stay in when most of the pool isn't:
            // otherwise the few measured albums would make the whole mix.
            let unmeasured = measured.count * 2 < pool.count ? pool.filter { sound[$0.id] == nil } : []
            let exact = measured.filter { sound[$0.id]?.mood.rawValue == mood.rawValue }
            if exact.count >= min(8, max(1, measured.count / 4)) {
                pool = exact
            } else {
                let byEnergy = measured.sorted { sound[$0.id]!.energy < sound[$1.id]!.energy }
                let third = max(1, Int((Double(byEnergy.count) / 3).rounded(.up)))
                switch mood {
                case .calm: pool = Array(byEnergy.prefix(third))
                case .energetic: pool = Array(byEnergy.suffix(third))
                case .balanced: pool = Array(byEnergy.dropFirst(third / 2).prefix(third * 2))
                }
            }
            // The most fitting first, cut to the mix's length: a calm mix
            // is the calmest songs (shuffled after), not any calm one.
            let wanted = query.limit ?? 40
            if pool.count > wanted, query.sort == nil || query.sort == .random {
                let energy = { (song: Song) in self.sound[song.id]?.energy ?? 0.5 }
                switch mood {
                case .calm: pool = Array(pool.sorted { energy($0) < energy($1) }.prefix(wanted))
                case .energetic: pool = Array(pool.sorted { energy($0) > energy($1) }.prefix(wanted))
                case .balanced: pool = Array(pool.sorted { abs(energy($0) - 0.52) < abs(energy($1) - 0.52) }.prefix(wanted))
                }
            }
            pool += unmeasured.prefix(max(0, wanted - pool.count))
        }
        if query.bpmFrom != nil || query.bpmTo != nil {
            if sound.isEmpty { result.missing.append("tempos (the library hasn't been analyzed in Stats)") }
            let from = Double(query.bpmFrom ?? 0), to = Double(query.bpmTo ?? 999)
            let inRange = pool.filter { song in
                guard let bpm = sound[song.id]?.bpm, bpm > 0 else { return false }
                return bpm >= min(from, to) && bpm <= max(from, to)
            }
            // Nothing in range: the closest tempos rather than nothing.
            if !inRange.isEmpty || sound.isEmpty {
                pool = inRange
            } else {
                let middle = (min(from, to) + min(max(from, to), 220)) / 2
                let distance = { (song: Song) in abs((self.sound[song.id]?.bpm ?? 0) - middle) }
                let measured = pool.filter { (sound[$0.id]?.bpm ?? 0) > 0 }.sorted { distance($0) < distance($1) }
                pool = Array(measured.prefix(max(1, measured.count / 3)))
            }
        }

        if query.versions == true {
            // Every version: songs grouped by artist and title without its version marks.
            let groups = Dictionary(grouping: pool) { versionKey(of: $0) }
            if let titles = query.titles?.nonEmpty {
                let candidates = Array(Set(pool.map { AssistantText.baseTitle($0.title) }))
                var picked: [Song] = []
                for title in titles {
                    let keys = Set(AssistantText.match(AssistantText.baseTitle(title), in: candidates))
                    let found = pool.filter { keys.contains(AssistantText.baseTitle($0.title)) }
                    if found.isEmpty { result.missing.append("song “\(title)”") }
                    for song in found where !picked.contains(song) { picked.append(song) }
                }
                pool = picked
            } else {
                pool = pool.filter { (groups[versionKey(of: $0)]?.count ?? 0) > 1 }
            }
        } else if let titles = query.titles?.nonEmpty {
            var picked: [Song] = []
            for title in titles {
                let candidates = Array(Set(pool.map { AssistantText.normalize($0.title) }))
                let keys = Set(AssistantText.match(title, in: candidates))
                let found = pool.filter { keys.contains(AssistantText.normalize($0.title)) }
                if found.isEmpty { result.missing.append("song “\(title)”") }
                // One version of each song, the most played.
                var seen = Set<String>()
                for song in found.sorted(by: { $0.playCount > $1.playCount }) {
                    let key = AssistantText.normalize(song.title) + "|" + (artistKeys[song.id]?.albumArtist ?? "")
                    if seen.insert(key).inserted, !picked.contains(song) { picked.append(song) }
                }
            }
            pool = picked
        }

        var sort = query.sort ?? (query.versions == true ? .title : nil)
        var limit = query.limit
        if query.likeNowPlaying == true {
            if let seed = nowPlaying {
                let genre = genreKeys[seed.id] ?? ""
                let artist = artistKeys[seed.id]?.albumArtist ?? ""
                pool = pool.filter { song in
                    guard song.id != seed.id else { return false }
                    let sameArtist = artistKeys[song.id]?.albumArtist == artist
                    let sameGenre = !genre.isEmpty && genre != "unknown" && genreKeys[song.id] == genre
                    let closeYears = seed.year == 0 || song.year == 0 || abs(song.year - seed.year) <= 6
                    return (sameGenre && closeYears) || sameArtist
                }
                sort = sort ?? .random
                limit = limit ?? 30
            } else {
                result.missing.append("the current song (nothing is playing)")
            }
        }

        let isRanking = [.mostPlayed, .leastPlayed, .recentlyPlayed, .recentlyAdded, .neverPlayed, .forgotten].contains(sort)
        if limit == nil, sort == .mostEnergetic || sort == .calmest { limit = 30 }
        let hasFilters = query.artists != nil || query.albums != nil || query.genres != nil || query.playlists != nil || query.mood != nil
            || query.titles != nil || query.yearFrom != nil || query.yearTo != nil || query.versions == true
        if limit == nil, isRanking { limit = 25 }
        if limit == nil, sort == .random, !hasFilters { limit = 50 }

        result.songs = sorted(pool, by: sort, period: query.period, playlistOrder: playlistOrder)
        // Several artists asked together: a mix, not one after the other.
        if (query.artists?.count ?? 0) > 1, sort == .random || sort == nil, playlistOrder == nil {
            result.songs = interleaved(Dictionary(grouping: result.songs) { artistKeys[$0.id]?.albumArtist ?? "" }.values.map { Array($0) })
        }
        // A shuffled mix draws from every album, not mostly the biggest one.
        if sort == .random || sort == nil, playlistOrder == nil, query.albums == nil, query.titles == nil, query.versions != true {
            let byArtist = Dictionary(grouping: result.songs) { artistKeys[$0.id]?.albumArtist ?? "" }
            let spread = byArtist.values.map { songs in
                interleaved(Dictionary(grouping: songs) { AssistantText.normalize($0.album) }.values.map { $0.shuffled() })
            }
            result.songs = spread.count > 1 ? interleaved(spread) : spread.first ?? []
        }
        if let limit, limit > 0 { result.songs = Array(result.songs.prefix(limit)) }
        return result
    }

    /// Several queries add up, without repeats.
    func resolve(_ queries: [SongQuery]) -> Resolution {
        var result = Resolution()
        var seen = Set<UUID>()
        var parts: [[Song]] = []
        for query in queries {
            let part = resolve(query)
            result.missing += part.missing
            parts.append(part.songs.filter { seen.insert($0.id).inserted })
        }
        // A query per artist for a mix: spread them, unless asked in order.
        let mixes = queries.count > 1 && queries.allSatisfy { $0.titles == nil && ($0.sort == .random || $0.sort == nil) && $0.playlists == nil }
        result.songs = mixes ? interleaved(parts) : parts.flatMap { $0 }
        // Names the model split into artists or albums are often one title
        // ("Hustle & Grind" read as two artists): try them as a song first.
        if result.songs.isEmpty, !result.missing.isEmpty {
            let names = queries.flatMap { ($0.titles ?? []) + ($0.artists ?? []) + ($0.albums ?? []) }
            for phrase in Set([names.joined(separator: " & "), names.joined(separator: " ")]) where !phrase.isEmpty {
                let retry = resolve(SongQuery(titles: [phrase]))
                if !retry.songs.isEmpty, retry.missing.isEmpty { return retry }
            }
        }
        return result
    }

    /// Spreads each list evenly through the others, keeping its own order:
    /// a big one and a small one alternate without bunching at the end.
    private func interleaved(_ lists: [[Song]]) -> [Song] {
        lists.filter { !$0.isEmpty }
            .enumerated()
            .flatMap { listIndex, list in
                list.enumerated().map { index, song in
                    (song, (Double(index) + 0.5) / Double(list.count), listIndex)
                }
            }
            .sorted { ($0.1, $0.2) < ($1.1, $1.2) }
            .map(\.0)
    }

    private func versionKey(of song: Song) -> String {
        AssistantText.baseTitle(song.title) + "|" + (artistKeys[song.id]?.albumArtist ?? "")
    }

    private func sorted(_ songs: [Song], by sort: SongSort?, period: StatsPeriod?, playlistOrder: [UUID]?) -> [Song] {
        switch sort {
        case .mostPlayed:
            if let range = period?.historyRange {
                let plays = history.plays(in: range)
                return songs.filter { (plays[$0.id] ?? 0) > 0 }
                    .sorted { (plays[$0.id] ?? 0, $0.lastPlayedAt ?? .distantPast) > (plays[$1.id] ?? 0, $1.lastPlayedAt ?? .distantPast) }
            }
            return songs.filter { $0.playCount > 0 }
                .sorted { ($0.playCount, $0.lastPlayedAt ?? .distantPast) > ($1.playCount, $1.lastPlayedAt ?? .distantPast) }
        case .leastPlayed:
            return songs.sorted { ($0.playCount, $0.lastPlayedAt ?? .distantPast) < ($1.playCount, $1.lastPlayedAt ?? .distantPast) }
        case .recentlyPlayed:
            return songs.filter { $0.lastPlayedAt != nil }.sorted { $0.lastPlayedAt! > $1.lastPlayedAt! }
        case .recentlyAdded:
            return songs.sorted { $0.addedAt > $1.addedAt }
        case .neverPlayed:
            return songs.filter { $0.playCount == 0 }.sorted { $0.addedAt > $1.addedAt }
        case .forgotten:
            let cutoff = Date().addingTimeInterval(-30 * 24 * 3600)
            return songs.filter { $0.playCount >= AutolistRules.favoritePlays && ($0.lastPlayedAt ?? .distantPast) < cutoff }
                .sorted { $0.playCount > $1.playCount }
        case .random:
            return songs.shuffled()
        case .mostEnergetic:
            return songs.filter { sound[$0.id] != nil }.sorted { sound[$0.id]!.energy > sound[$1.id]!.energy }
        case .calmest:
            return songs.filter { sound[$0.id] != nil }.sorted { sound[$0.id]!.energy < sound[$1.id]!.energy }
        case .newest:
            return songs.sorted { $0.year != $1.year ? $0.year > $1.year : $0.addedAt > $1.addedAt }
        case .oldest:
            return songs.filter { $0.year > 0 }.sorted { $0.year < $1.year } + songs.filter { $0.year == 0 }
        case .title:
            return songs.sorted { lhs, rhs in
                let l = AssistantText.baseTitle(lhs.title), r = AssistantText.baseTitle(rhs.title)
                if l != r { return l.localizedStandardCompare(r) == .orderedAscending }
                let ly = lhs.year > 0 ? lhs.year : .max, ry = rhs.year > 0 ? rhs.year : .max
                if ly != ry { return ly < ry }
                if lhs.title.count != rhs.title.count { return lhs.title.count < rhs.title.count }
                return lhs.addedAt < rhs.addedAt
            }
        case .libraryOrder, nil:
            if let playlistOrder {
                let position = Dictionary(uniqueKeysWithValues: playlistOrder.enumerated().map { ($1, $0) })
                return songs.sorted { (position[$0.id] ?? .max) < (position[$1.id] ?? .max) }
            }
            return songs.sorted { lhs, rhs in
                let l = artistKeys[lhs.id]?.albumArtist ?? "", r = artistKeys[rhs.id]?.albumArtist ?? ""
                if l != r { return l < r }
                if lhs.year != rhs.year { return lhs.year < rhs.year }
                if lhs.album != rhs.album { return lhs.album < rhs.album }
                if lhs.discNumber != rhs.discNumber { return lhs.discNumber < rhs.discNumber }
                if lhs.trackNumber != rhs.trackNumber { return lhs.trackNumber < rhs.trackNumber }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
        }
    }

    // MARK: Autolists

    /// The Autolist rules doing the same as `query`, when there are some.
    func autolistRules(for query: SongQuery, name: String?) -> AutolistRules? {
        guard query.titles == nil, query.versions != true, query.albums == nil, query.playlists == nil, query.excludeArtists == nil,
              query.likeNowPlaying != true, query.nowPlaying != true else { return nil }
        var rules = AutolistRules()
        // Each new one takes the style after the last one's, for variety.
        let styles = CoverStyle.allCases
        if let last = playlists.last(where: { $0.autolist != nil })?.autolist?.style, let index = styles.firstIndex(of: last) {
            rules.style = styles[(index + 1) % styles.count]
        } else {
            rules.style = .waves
        }
        switch query.sort {
        case .mostPlayed: rules.selection = .mostPlayed
        case .leastPlayed: rules.selection = .leastPlayed
        case .recentlyPlayed: rules.selection = .recentlyPlayed
        case .recentlyAdded: rules.selection = .recentlyAdded
        case .neverPlayed: rules.selection = .neverPlayed
        case .forgotten: rules.selection = .forgotten
        case .random where query.mood == .energetic, .mostEnergetic: rules.selection = .energetic
        case .random where query.mood == .calm, .calmest: rules.selection = .calm
        case .random: rules.selection = .random
        case nil where query.mood == .energetic: rules.selection = .energetic
        case nil where query.mood == .calm: rules.selection = .calm
        default: return nil
        }
        // Autolists have no tempo filter, nor a balanced pick.
        if query.bpmFrom != nil || query.bpmTo != nil || query.mood == .balanced { return nil }
        switch query.period {
        case .week: rules.period = .week
        case .month: rules.period = .month
        case .year: rules.period = .year
        default: rules.period = .allTime
        }
        if query.yearFrom != nil || query.yearTo != nil {
            guard let from = query.yearFrom, from % 10 == 0, query.yearTo == from + 9 else { return nil }
            rules.decade = from
        }
        rules.artists = (query.artists ?? []).flatMap(artistNames(matching:))
        rules.genres = (query.genres ?? []).flatMap(genreNames(matching:))
        if query.artists != nil, rules.artists.isEmpty { return nil }
        if query.genres != nil, rules.genres.isEmpty { return nil }
        rules.requiresLyrics = query.withLyrics == true
        rules.limit = query.limit ?? 50
        rules.refresh = rules.selection == .mostPlayed && rules.period != .allTime ? .daily : .everyTwoDays
        rules.customName = name ?? ""
        return rules
    }

    // MARK: Context

    struct Budget {
        var artists: Int
        var genres: Int
        var playlists: Int
        var top: Int
        var upNext: Int

        static let compact = Budget(artists: 35, genres: 15, playlists: 25, top: 5, upNext: 3)
        static let medium = Budget(artists: 70, genres: 25, playlists: 40, top: 6, upNext: 4)
        static let full = Budget(artists: 220, genres: 60, playlists: 100, top: 10, upNext: 8)
    }

    /// What the model knows without asking: now, the player, the library
    /// and the listening habits, in a few hundred tokens.
    func context(budget: Budget) -> String {
        var lines: [String] = []
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "EEEE d MMMM yyyy, HH:mm"
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        lines.append("Now: \(dateFormatter.string(from: Date())).")

        if let song = nowPlaying {
            var line = "Now playing: \(describe(song)), at \(clock(player.currentTime))/\(clock(song.duration)), \(player.isPlaying ? "playing" : "paused")."
            line += " Shuffle \(player.shuffleMode == .on ? "on" : "off"), repeat \(player.repeatMode.rawValue)."
            lines.append(line)
            let upcoming = player.queue.dropFirst(player.currentIndex + 1)
            if !upcoming.isEmpty {
                let shown = upcoming.prefix(budget.upNext).map(label).joined(separator: "; ")
                let more = upcoming.count > budget.upNext ? " (+\(upcoming.count - budget.upNext) more)" : ""
                lines.append("Up next: \(shown)\(more).")
            } else {
                lines.append("Up next: nothing.")
            }
        } else {
            lines.append("Nothing is playing.")
        }

        let artists = Dictionary(grouping: songs, by: LibraryIndex.artistName(for:))
        let years = songs.map(\.year).filter { $0 > 0 }
        var library = "Library: \(songs.count) songs, \(Set(songs.map { "\($0.album)|\(LibraryIndex.artistName(for: $0))" }).count) albums, \(artists.count) artists"
        if let first = years.min(), let last = years.max() { library += ", released \(first)–\(last)" }
        let merges = Dictionary(grouping: ArtistMerges.all, by: \.value).map { main, names in
            "\(main) (also as \(names.map(\.key).sorted().joined(separator: ", ")))"
        }
        if !merges.isEmpty { library += ". Same artist under other names, counted as one: " + merges.sorted().joined(separator: "; ") }
        library += ", \(songs.filter { $0.lrcFilePath != nil }.count) with synced lyrics, \(songs.filter { $0.playCount == 0 }.count) never played."
        lines.append(library)

        let genres = Dictionary(grouping: songs, by: AutolistEngine.genreName(of:))
            .filter { $0.key != Self.unknownGenre }
            .map { ($0.key, $0.value.count) }
            .sorted { $0.1 > $1.1 }
        var genreLine = "Genres (songs): " + genres.prefix(budget.genres).map { "\($0.0) \($0.1)" }.joined(separator: ", ") + (genres.count > budget.genres ? ", …" : "") + "."
        let untagged = songs.filter { AutolistEngine.genreName(of: $0) == Self.unknownGenre }.count
        if untagged > 0 {
            genreLine += " \(untagged) songs (\(Int((Double(untagged) / Double(max(songs.count, 1)) * 100).rounded()))%) have no genre tag in their files, so these counts miss part of the library: never judge or joke about a genre being absent or small, judge artists instead."
        }
        lines.append(genreLine)

        let decades = Dictionary(grouping: years, by: { $0 / 10 * 10 }).map { ($0.key, $0.value.count) }.sorted { $0.0 < $1.0 }
        if !decades.isEmpty {
            lines.append("Decades (songs): " + decades.map { "\($0.0)s \($0.1)" }.joined(separator: ", ") + ".")
        }

        let rankedArtists = artists
            .map { name, songs in (name, songs.count, songs.reduce(0) { $0 + $1.playCount }) }
            .sorted { ($0.1 + $0.2) > ($1.1 + $1.2) }
        lines.append("Artists (songs/plays), biggest first: " + rankedArtists.prefix(budget.artists).map { "\($0.0) \($0.1)/\($0.2)" }.joined(separator: ", ") + (rankedArtists.count > budget.artists ? ", … (others exist too)" : "") + ".")

        if playlists.isEmpty {
            lines.append("Playlists: none.")
        } else {
            let shown = playlists.prefix(budget.playlists).map { playlist in
                let kind = playlist.autolist.map { " auto: \($0.selection.title)\($0.caption.isEmpty ? "" : " · \($0.caption)")" } ?? ""
                return "\(playlist.name) (\(playlist.songCount)\(kind))"
            }
            lines.append("Playlists: " + shown.joined(separator: ", ") + (playlists.count > budget.playlists ? ", …" : "") + ".")
        }

        if let soundLine = soundLine(top: budget.top) { lines.append(soundLine) }
        lines.append(contentsOf: statsLines(top: budget.top))
        if let workoutLine = workoutLine(top: budget.top) { lines.append(workoutLine) }
        let summarized = LyricsSummaries.shared.summarizedCount(in: songs)
        if summarized > 0 {
            lines.append("Lyrics summaries: \(summarized) songs have a one-line summary of what their lyrics are about (lookup themes).")
        }
        return lines.joined(separator: "\n")
    }

    /// What the user plays while exercising (workouts from Apple Health).
    private func workoutLine(top: Int) -> String? {
        guard WorkoutListening.isEnabled else { return nil }
        let plays = WorkoutListening.plays(in: ListeningStatsService.shared.entries(in: .allTime), sessions: WorkoutListening.storedSessions())
        guard !plays.isEmpty else { return nil }
        let workouts = Set(plays.map(\.session.start)).count
        let byActivity = Dictionary(grouping: plays) { $0.session.activityName }
            .map { ($0.key, $0.value.count) }
            .sorted { $0.1 > $1.1 }
            .map { "\($0.0) \($0.1)" }
        let songs = Dictionary(grouping: plays) { $0.entry.songID }
            .sorted { $0.value.count > $1.value.count }
            .prefix(max(top, 5))
            .map { "\($0.value[0].entry.title) – \($0.value[0].entry.artist) (\($0.value.count))" }
        let artists = Dictionary(grouping: plays) { ListeningStatsService.shared.artist(for: $0.entry) }
            .sorted { $0.value.count > $1.value.count }
            .prefix(5)
            .map { "\($0.key) (\($0.value.count))" }
        return "During workouts (Apple Health, \(workouts) workouts, \(plays.count) plays; by kind: \(byActivity.joined(separator: ", "))). Most played then: \(songs.joined(separator: "; ")). Artists: \(artists.joined(separator: ", ")). The Workout autolist holds these."

    }

    /// What the audio analysis found: for moods, tempos and roasts.
    private func soundLine(top: Int) -> String? {
        let measured = songs.compactMap { song in sound[song.id].map { (song, $0) } }
        guard measured.count >= 5 else { return nil }
        let share = { (mood: SoundProfile.Mood) in Int((Double(measured.filter { $0.1.mood == mood }.count) / Double(measured.count) * 100).rounded()) }
        let beats = measured.map(\.1.bpm).filter { $0 > 0 }.sorted()
        let byEnergy = measured.sorted { $0.1.energy > $1.1.energy }
        var line = "Sound (measured from the audio of \(measured.count) songs; songs can be picked by mood and bpm): \(share(.energetic))% energetic, \(share(.balanced))% balanced, \(share(.calm))% calm"
        if !beats.isEmpty { line += ", typical tempo \(Int(beats[beats.count / 2].rounded())) BPM" }
        line += ". Most energetic: " + byEnergy.prefix(top).map { label($0.0) }.joined(separator: ", ")
        line += ". Calmest: " + byEnergy.suffix(top).reversed().map { label($0.0) }.joined(separator: ", ") + "."
        return line
    }

    private func statsLines(top: Int) -> [String] {
        var lines: [String] = []
        let stats = ListeningStatsService.shared
        if !stats.isEnabled {
            lines.append("Listening history: recording is off.")
        }
        for (range, label) in [(ListeningStatsTimeRange.week, "Last 7 days"), (.month, "Last 30 days")] {
            let aggregate = stats.aggregate(for: range)
            guard aggregate.totalSongsPlayed > 0 else {
                lines.append("\(label): no plays.")
                continue
            }
            var line = "\(label): \(aggregate.totalSongsPlayed) plays, \(duration(aggregate.totalListeningTime)), \(aggregate.uniqueArtists) artists."
            line += " Top artists: " + aggregate.topArtists.prefix(top).map { "\($0.name) \($0.count)" }.joined(separator: ", ") + "."
            line += " Top songs: " + aggregate.topSongs.prefix(top).map { "\(self.label($0.title, $0.artist, id: $0.songID)) \($0.count)" }.joined(separator: ", ") + "."
            lines.append(line)
        }

        let played = songs.filter { $0.playCount > 0 }
        if !played.isEmpty {
            let topSongs = played.sorted { $0.playCount > $1.playCount }.prefix(top)
                .map { "\(label($0)) \($0.playCount)" }
            let artistPlays = Dictionary(grouping: played, by: LibraryIndex.artistName(for:))
                .map { ($0.key, $0.value.reduce(0) { $0 + $1.playCount }) }
                .sorted { $0.1 > $1.1 }
                .prefix(top)
                .map { "\($0.0) \($0.1)" }
            let genrePlays = Dictionary(grouping: played, by: AutolistEngine.genreName(of:))
                .filter { $0.key != Self.unknownGenre }
                .map { ($0.key, $0.value.reduce(0) { $0 + $1.playCount }) }
                .sorted { $0.1 > $1.1 }
                .prefix(top)
                .map { "\($0.0) \($0.1)" }
            lines.append("All time (play counts): top songs: \(topSongs.joined(separator: ", ")). Top artists: \(artistPlays.joined(separator: ", ")). Top genres (tagged songs only): \(genrePlays.joined(separator: ", ")).")
        }

        let year = stats.aggregate(for: .year)
        if year.totalSongsPlayed > 20 {
            let weekdays = Calendar(identifier: .gregorian).weekdaySymbols
            var habits = "Habits (12 months): \(duration(year.totalListeningTime)) listened"
            if let hour = year.hourlyDistribution.max(by: { $0.value < $1.value })?.key { habits += ", peak hour \(hour)h" }
            if let day = year.dailyDistribution.max(by: { $0.value < $1.value })?.key, weekdays.indices.contains(day - 1) {
                habits += ", busiest day \(weekdays[day - 1])"
            }
            let night = (0..<5).reduce(0) { $0 + (year.hourlyDistribution[$1] ?? 0) }
            habits += ", \(Int((Double(night) / Double(year.totalSongsPlayed) * 100).rounded()))% of plays between midnight and 5am."
            lines.append(habits)
        }
        let recent = songs.filter { $0.addedAt > Date().addingTimeInterval(-30 * 24 * 3600) }.count
        lines.append("Added in the last 30 days: \(recent) songs.")
        return lines
    }

    // MARK: Lookups

    func run(_ lookup: AssistantLookup) async -> String {
        switch lookup.type {
        case .songs:
            let resolution = resolve(lookup.songs ?? SongQuery())
            var text = "Songs found: \(resolution.songs.count)."
            if !resolution.missing.isEmpty { text += " Not found: \(resolution.missing.joined(separator: ", "))." }
            let shown = resolution.songs.prefix(40).map { "- \(describe($0)), \($0.playCount) plays" }
            return ([text] + shown + (resolution.songs.count > 40 ? ["- …"] : [])).joined(separator: "\n")
        case .albums:
            let resolution = resolve(lookup.songs ?? SongQuery())
            let albums = Dictionary(grouping: resolution.songs) { "\($0.album)|\(LibraryIndex.artistName(for: $0))" }
                .values
                .map { songs in (songs[0], songs.count, songs.reduce(0) { $0 + $1.playCount }) }
                .sorted { $0.0.year < $1.0.year }
            let shown = albums.prefix(40).map { "- \($0.0.album) — \(LibraryIndex.artistName(for: $0.0)) (\($0.0.year > 0 ? String($0.0.year) : "year unknown")), \($0.1) songs, \($0.2) plays" }
            return (["Albums found: \(albums.count)."] + shown).joined(separator: "\n")
        case .stats:
            return stats(for: lookup)
        case .history:
            let formatter = DateFormatter()
            formatter.dateFormat = "EEE d MMM HH:mm"
            formatter.locale = Locale(identifier: "en_US_POSIX")
            let entries = ListeningStatsService.shared.allEntries().suffix(40).reversed()
            guard !entries.isEmpty else { return "No listening history." }
            return (["Last plays, newest first:"] + entries.map { "- \(formatter.string(from: $0.timestamp)): \(label($0.title, $0.artist, id: $0.songID))" }).joined(separator: "\n")
        case .queue:
            let upcoming = player.queue.dropFirst(player.currentIndex + 1)
            guard !upcoming.isEmpty else { return "The queue is empty after the current song." }
            return (["Up next (\(upcoming.count)):"] + upcoming.prefix(50).enumerated().map { "\($0.offset + 1). \(label($0.element))" }).joined(separator: "\n")
        case .lyrics:
            return await searchLyrics(lookup.text ?? "")
        case .songLyrics:
            return songLyrics(lookup.songs ?? SongQuery(nowPlaying: true))
        case .themes:
            return themes()
        case .subject:
            var words = lookup.songs?.about ?? []
            if words.isEmpty, let text = lookup.text { words = text.components(separatedBy: CharacterSet(charactersIn: ",;")) }
            return subjectCandidates(words.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        }
    }

    /// The words of a subject a song mentions: in its title, its lyrics (as
    /// Search finds them, with the line) or what its lyrics are about.
    func subjectMatches(of song: Song, _ subjects: [String]) -> [(word: String, line: String?)] {
        let title = AssistantText.normalize(song.title)
        let summary = LyricsSummaries.shared.summary(for: song.id).map { AssistantText.normalize(LyricsSummaries.plain($0)) }
        return subjects.compactMap { subject in
            let normalized = AssistantText.normalize(subject)
            guard !normalized.isEmpty else { return nil }
            if let line = LyricsTextIndex.shared.quote(for: song, terms: normalized.split(separator: " ").map(String.init)) {
                return (subject, line)
            }
            if AssistantText.containsWords(title, normalized) || summary.map({ AssistantText.containsWords($0, normalized) }) == true {
                return (subject, nil)
            }
            return nil
        }
    }

    /// Every song that mentions the subject or its lexical field, with the
    /// evidence, for the model to keep only those truly about it.
    func subjectCandidates(_ subjects: [String], limit: Int = 120) -> String {
        guard !subjects.isEmpty else { return "No words given to look for." }
        let found = songs.compactMap { song -> (Song, [(word: String, line: String?)])? in
            let matches = subjectMatches(of: song, subjects)
            return matches.isEmpty ? nil : (song, matches)
        }
        .sorted { $0.1.count > $1.1.count }
        guard !found.isEmpty else { return "No song mentions any of: \(subjects.joined(separator: ", ")) (titles, lyrics and lyrics summaries searched)." }
        var lines = ["Songs mentioning \(subjects.joined(separator: ", ")): \(found.count). Judge each from its line and summary: keep only those truly about the subject (not a homonym or a passing word)."]
        for (song, matches) in found.prefix(limit) {
            var line = "- “\(song.title)” — \(song.artist): mentions \(matches.map(\.word).joined(separator: ", "))"
            if let quote = matches.lazy.compactMap(\.line).first { line += "; line: “\(quote.prefix(110))”" }
            if let about = LyricsSummaries.shared.summary(for: song.id) { line += "; about: \(LyricsSummaries.plain(about).prefix(140))" }
            lines.append(line)
        }
        if found.count > limit { lines.append("- … \(found.count - limit) more, mentioning fewer of the words.") }
        return lines.joined(separator: "\n")
    }

    /// A song's whole lyrics, for the model to read: the lines without
    /// their times, at most `limit` characters per song, two songs at most.
    func songLyrics(_ query: SongQuery, limit: Int = 3500) -> String {
        let resolution = resolve(query)
        guard !resolution.songs.isEmpty else {
            return "No song found" + (resolution.missing.isEmpty ? "." : ": \(resolution.missing.joined(separator: ", ")).")
        }
        return resolution.songs.prefix(2).map { song in
            guard let lyrics = MusicPlayerService.lyrics(for: song) else {
                return "\(describe(song)): no lyrics in the library for this song."
            }
            var text = lyrics.hasTimedLyrics
                ? lyrics.lines.map(\.text).joined(separator: "\n")
                : lyrics.plainText
            // Blank lines between sections, never several in a row.
            text = text.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return "\(describe(song)): no lyrics in the library for this song." }
            if text.count > limit { text = String(text.prefix(limit)) + "\n[…]" }
            return "Lyrics of \(describe(song)):\n\(text)"
        }.joined(separator: "\n\n")
    }

    private func stats(for lookup: AssistantLookup) -> String {
        let period = lookup.period ?? .month
        var keys: Set<String>?
        if let artists = lookup.songs?.artists?.nonEmpty {
            keys = Set(artists.flatMap(artistKeySet(for:)))
        }
        func keep(_ artist: String) -> Bool {
            guard let keys else { return true }
            let key = AssistantText.normalize(artist)
            return keys.contains(key) || keys.contains { AssistantText.containsWords(key, $0) }
        }

        guard let range = period.historyRange else {
            let played = songs.filter { $0.playCount > 0 && keep($0.artist) }
            let total = played.reduce(0) { $0 + $1.playCount }
            let topSongs = played.sorted { $0.playCount > $1.playCount }.prefix(15).map { "- \(label($0)): \($0.playCount)" }
            let albums = Dictionary(grouping: played, by: albumLabel)
                .map { ($0.key, $0.value.reduce(0) { $0 + $1.playCount }) }
                .sorted { $0.1 > $1.1 }
                .prefix(10)
                .map { "- \($0.0): \($0.1)" }
            return (["All-time play counts: \(total) plays of \(played.count) songs.", "Top songs:"] + topSongs + ["Top albums:"] + albums).joined(separator: "\n")
        }

        let entries = ListeningStatsService.shared.entries(in: range).filter { keep($0.artist) }
        guard !entries.isEmpty else { return "No plays in that period." }
        let time = entries.reduce(0) { $0 + $1.durationPlayed }
        func top(_ key: (ListeningStatsEntry) -> String, _ count: Int) -> [String] {
            Dictionary(grouping: entries, by: key).map { ($0.key, $0.value.count) }.sorted { $0.1 > $1.1 }.prefix(count).map { "- \($0.0): \($0.1)" }
        }
        return ([
            "Plays in the period: \(entries.count), \(duration(time)).",
            "Top songs:"
        ] + top({ label($0.title, $0.artist, id: $0.songID) }, 15)
          + ["Top artists:"] + top(ListeningStatsService.shared.artist(for:), 10)
          + ["Top albums:"] + top({ entry in songsByID[entry.songID].map(albumLabel) ?? "\(entry.album) — \(entry.artist)" }, 10)).joined(separator: "\n")
    }

    /// Songs whose lyrics have all of `text`'s words in one line.
    private func searchLyrics(_ text: String) async -> String {
        let words = AssistantText.normalize(text).split(separator: " ").map(String.init)
        guard !words.isEmpty else { return "No words to search." }
        let files: [(UUID, URL)] = songs.compactMap { song in libraryService.resolvedLyricsURL(for: song).map { (song.id, $0) } }
        let hits = await Task.detached(priority: .userInitiated) { () -> [(UUID, String)] in
            var hits: [(UUID, String)] = []
            for (id, url) in files {
                guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
                for rawLine in content.split(whereSeparator: \.isNewline) {
                    let line = rawLine.replacingOccurrences(of: #"\[[^\]]*\]|<[^>]*>"#, with: "", options: .regularExpression)
                    let key = " \(AssistantText.normalize(line)) "
                    if words.allSatisfy({ key.contains(" \($0)") }) {
                        hits.append((id, line.trimmingCharacters(in: .whitespaces)))
                        break
                    }
                }
                if hits.count >= 12 { break }
            }
            return hits
        }.value
        guard !hits.isEmpty else { return "No synced lyrics contain “\(text)” (only songs with lyrics files are searched)." }
        let byID = Dictionary(uniqueKeysWithValues: songs.map { ($0.id, $0) })
        return (["Lyrics matches:"] + hits.compactMap { id, line in byID[id].map { "- \(describe($0)): “\(line)”" } }).joined(separator: "\n")
    }

    // MARK: Formatting

    func describe(_ song: Song) -> String {
        var details = [song.album]
        if song.year > 0 { details.append(String(song.year)) }
        let genre = song.genre.trimmingCharacters(in: .whitespaces)
        if !genre.isEmpty { details.append(genre) }
        if let profile = sound[song.id] {
            details.append(profile.bpm > 0 ? "\(Int(profile.bpm.rounded())) BPM, \(profile.mood.rawValue)" : profile.mood.rawValue)
        }
        var text = "“\(song.title)” — \(song.artist) (\(details.joined(separator: ", ")))"
        if let about = LyricsSummaries.shared.summary(for: song.id) { text += " — about: \(LyricsSummaries.plain(about))" }
        return text
    }

    /// What each song's lyrics are about, for songs asked by subject.
    func themes(limit: Int = 16000) -> String {
        let summaries = LyricsSummaries.shared
        let lines = songs.compactMap { song in
            summaries.summary(for: song.id).map { "- “\(song.title)” — \(song.artist): \(LyricsSummaries.plain($0))" }
        }
        guard !lines.isEmpty else { return "No lyrics summaries yet: the user can create them in the assistant's menu (Improve the Assistant)." }
        var text = "What the lyrics are about (\(lines.count) songs):"
        for line in lines {
            if text.count + line.count > limit { text += "\n- …"; break }
            text += "\n" + line
        }
        return text
    }

    private func clock(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds.isFinite ? seconds : 0))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        return minutes >= 60 ? "\(minutes / 60)h\(String(format: "%02d", minutes % 60))" : "\(minutes) min"
    }
}

extension StatsPeriod {
    var historyRange: ListeningStatsTimeRange? {
        switch self {
        case .allTime: nil
        case .week: .week
        case .month: .month
        case .year: .year
        }
    }
}

extension SongQuery {
    /// A short line for receipts: "Daft Punk, Justice · 2000–2009".
    var summary: String {
        var parts: [String] = []
        if nowPlaying == true { parts.append("Current song") }
        if likeNowPlaying == true { parts.append("Like the current song") }
        for list in [titles, artists, albums, genres, playlists] {
            if let list = list?.nonEmpty { parts.append(list.prefix(3).joined(separator: ", ") + (list.count > 3 ? "…" : "")) }
        }
        switch (yearFrom, yearTo) {
        case let (from?, to?) where from == to: parts.append(String(from))
        case let (from?, to?): parts.append("\(from)–\(to)")
        case let (from?, nil): parts.append("since \(from)")
        case let (nil, to?): parts.append("until \(to)")
        default: break
        }
        switch sort {
        case .mostPlayed: parts.append("Most played" + (period.flatMap { $0 == .allTime ? nil : " · \($0.rawValue)" } ?? ""))
        case .leastPlayed: parts.append("Least played")
        case .recentlyPlayed: parts.append("Recently played")
        case .recentlyAdded: parts.append("Recently added")
        case .neverPlayed: parts.append("Never played")
        case .forgotten: parts.append("Forgotten favorites")
        case .random: parts.append("Random")
        default: break
        }
        return parts.joined(separator: " · ")
    }
}

extension Array {
    var nonEmpty: Self? { isEmpty ? nil : self }
}
