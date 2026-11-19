import Foundation

enum SpotifyMatchStatus {
    case matched
    case ambiguous
    case unmatched
    case removed
}

struct SpotifyMatchResult {
    let track: SpotifyTrack
    var localSong: Song?
    var status: SpotifyMatchStatus
    var candidates: [Song]
}

@MainActor
final class SpotifyMatchSession {
    let sourceURL: String
    let playlist: SpotifyPlaylist
    var results: [SpotifyMatchResult]

    init(sourceURL: String, playlist: SpotifyPlaylist, results: [SpotifyMatchResult]) {
        self.sourceURL = sourceURL
        self.playlist = playlist
        self.results = results
    }

    var matchedCount: Int { results.filter { $0.status == .matched }.count }
    var ambiguousCount: Int { results.filter { $0.status == .ambiguous }.count }
    var unmatchedCount: Int { results.filter { $0.status == .unmatched }.count }
    var removedCount: Int { results.filter { $0.status == .removed }.count }

    var orderedLocalSongIDs: [UUID] {
        results.filter { $0.status == .matched }.compactMap { $0.localSong?.id }
    }

    var importSource: ImportSource {
        ImportSource(
            service: "spotify",
            playlistID: playlist.id,
            url: sourceURL,
            matches: results.map { result in
                ImportedPlaylistMatch(
                    remoteID: result.track.id,
                    localSongID: result.localSong?.id,
                    isRemoved: result.status == .removed
                )
            }
        )
    }

    func choose(trackID: String, song: Song) {
        guard let index = results.firstIndex(where: { $0.track.id == trackID }) else { return }
        choose(at: index, song: song)
    }

    func remove(trackID: String) {
        guard let index = results.firstIndex(where: { $0.track.id == trackID }) else { return }
        remove(at: index)
    }

    /// Index-based variants: a playlist can contain the same track several
    /// times, so a track ID does not identify a row.
    func choose(at index: Int, song: Song) {
        guard results.indices.contains(index) else { return }
        results[index].localSong = song
        results[index].status = .matched
        results[index].candidates = []
    }

    func remove(at index: Int) {
        guard results.indices.contains(index) else { return }
        results[index].localSong = nil
        results[index].status = .removed
        results[index].candidates = []
    }
}

enum SpotifyMatcher {
    @MainActor
    static func makeSession(
        from link: String,
        playlist: SpotifyPlaylist,
        localSongs: [Song],
        existingMatches: [ImportedPlaylistMatch]?
    ) -> SpotifyMatchSession {
        // A playlist may contain the same track more than once, so previous
        // matches are grouped per remote ID and consumed in order.
        // (`Dictionary(uniqueKeysWithValues:)` used to trap on such playlists.)
        var previousByRemoteID = Dictionary(grouping: existingMatches ?? [], by: \.remoteID)
        let songsByID = Dictionary(localSongs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let index = localSongs.map(NormalizedSong.init)

        var results: [SpotifyMatchResult] = []
        results.reserveCapacity(playlist.tracks.count)
        for track in playlist.tracks {
            if var queue = previousByRemoteID[track.id], !queue.isEmpty {
                let previous = queue.removeFirst()
                previousByRemoteID[track.id] = queue
                if previous.isRemoved {
                    results.append(SpotifyMatchResult(track: track, localSong: nil, status: .removed, candidates: []))
                    continue
                }
                if let songID = previous.localSongID, let song = songsByID[songID] {
                    results.append(SpotifyMatchResult(track: track, localSong: song, status: .matched, candidates: []))
                    continue
                }
            }
            results.append(match(track, in: index))
        }
        return SpotifyMatchSession(sourceURL: link, playlist: playlist, results: results)
    }

    /// A local song with its matching keys normalized once. Normalizing runs
    /// several regexes; doing it per (track × song) pair froze the main thread
    /// for seconds on large libraries.
    private struct NormalizedSong {
        let song: Song
        let title: String
        let artist: String
        let albumArtist: String?
        let album: String

        init(_ song: Song) {
            self.song = song
            title = SpotifyMatcher.normalized(song.title)
            artist = SpotifyMatcher.normalized(song.artist)
            albumArtist = song.albumArtist.map(SpotifyMatcher.normalized)
            album = SpotifyMatcher.normalized(song.album)
        }

        func artistMatches(_ trackArtist: String) -> Bool {
            artist == trackArtist || albumArtist == trackArtist
        }
    }

    static func match(_ track: SpotifyTrack, localSongs: [Song]) -> SpotifyMatchResult {
        match(track, in: localSongs.map(NormalizedSong.init))
    }

    private static func match(_ track: SpotifyTrack, in localSongs: [NormalizedSong]) -> SpotifyMatchResult {
        let trackTitle = normalized(track.name)
        let trackArtist = normalized(track.artist)

        let exactCandidates = localSongs
            .filter { $0.title == trackTitle && $0.artistMatches(trackArtist) }
            .map(\.song)

        if exactCandidates.count == 1 {
            return SpotifyMatchResult(track: track, localSong: exactCandidates[0], status: .matched, candidates: [])
        }
        if exactCandidates.count > 1 {
            if let trackYear = track.year,
               let yearMatch = yearDisambiguation(exactCandidates, trackYear: trackYear) {
                return SpotifyMatchResult(track: track, localSong: yearMatch, status: .matched, candidates: [])
            }
            return SpotifyMatchResult(track: track, localSong: nil, status: .ambiguous, candidates: exactCandidates)
        }

        let trackAlbum = normalized(track.album)
        let scored = localSongs.map { song in
            (song.song, score(song, track: track, trackTitle: trackTitle, trackArtist: trackArtist, trackAlbum: trackAlbum))
        }
        .filter { $0.1 > 0 }
        .sorted { $0.1 > $1.1 }

        guard let best = scored.first, best.1 >= 4 else {
            return SpotifyMatchResult(track: track, localSong: nil, status: .unmatched, candidates: [])
        }

        let near = scored.filter { best.1 - $0.1 <= 1 }
        if near.count == 1 {
            return SpotifyMatchResult(track: track, localSong: best.0, status: .matched, candidates: [])
        }
        if let trackYear = track.year,
           let yearMatch = yearDisambiguation(near.map(\.0), trackYear: trackYear) {
            return SpotifyMatchResult(track: track, localSong: yearMatch, status: .matched, candidates: [])
        }
        return SpotifyMatchResult(track: track, localSong: nil, status: .ambiguous, candidates: near.map(\.0))
    }

    /// Returns the single candidate whose release year matches the track's year.
    /// Prefers an exact match, then falls back to ±1 year. Returns nil when none
    /// or several candidates match, so the match stays ambiguous.
    private static func yearDisambiguation(_ candidates: [Song], trackYear: Int) -> Song? {
        guard trackYear > 0 else { return nil }
        let withYear = candidates.filter { $0.year > 0 }
        let exact = withYear.filter { $0.year == trackYear }
        if exact.count == 1 { return exact[0] }
        let near = withYear.filter { abs($0.year - trackYear) <= 1 }
        return near.count == 1 ? near[0] : nil
    }

    private static func score(
        _ song: NormalizedSong,
        track: SpotifyTrack,
        trackTitle: String,
        trackArtist: String,
        trackAlbum: String
    ) -> Int {
        var score = 0
        let songTitle = song.title
        if songTitle == trackTitle {
            score += 3
        } else if !songTitle.isEmpty, !trackTitle.isEmpty,
                  songTitle.contains(trackTitle) || trackTitle.contains(songTitle) {
            // ("" is contained in every string: an empty title must not score.)
            score += 2
        }

        if song.artistMatches(trackArtist) {
            score += 2
        } else if !song.artist.isEmpty, !trackArtist.isEmpty,
                  trackArtist.contains(song.artist) || song.artist.contains(trackArtist) {
            score += 1
        }

        if abs(song.song.duration - track.duration) < 4 {
            score += 1
        }

        if !trackAlbum.isEmpty, song.album == trackAlbum {
            score += 1
        }

        if let trackYear = track.year, trackYear > 0, song.song.year > 0, abs(song.song.year - trackYear) <= 1 {
            score += 1
        }
        return score
    }

    private static let posixLocale = Locale(identifier: "en_US_POSIX")

    static func normalized(_ value: String) -> String {
        let folded = value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: posixLocale)
        let stripped = folded
            .replacingOccurrences(of: #"\([^)]*\)"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\[[^\]]*\]"#, with: " ", options: .regularExpression)
        let cleaned = stripped.map { character -> String in
            character.isLetter || character.isNumber || character == " " ? String(character) : " "
        }.joined()
        return cleaned.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Returns local songs likely to match the given track, most probable first.
    /// Never matches automatically: these are suggestions for manual selection only.
    static func recommendations(for track: SpotifyTrack, in songs: [Song], limit: Int = 8) -> [Song] {
        let trackTitle = normalized(track.name)
        let trackArtist = normalized(track.artist)
        let trackTokens = Set(trackTitle.split(separator: " ").map(String.init))
        let trackBigrams = bigrams(of: trackTitle)

        let normalizedTitles = songs.map { normalized($0.title) }
        var tokenCounts: [String: Int] = [:]
        for title in normalizedTitles {
            for token in Set(title.split(separator: " ").map(String.init)) {
                tokenCounts[token, default: 0] += 1
            }
        }

        func weight(_ token: String) -> Double {
            1.0 / (1.0 + log2(Double(tokenCounts[token] ?? 1) + 1.0))
        }

        var scored: [(song: Song, score: Double)] = []
        for (song, songTitle) in zip(songs, normalizedTitles) {
            let songTokens = Set(songTitle.split(separator: " ").map(String.init))
            let union = trackTokens.union(songTokens)
            guard !union.isEmpty else { continue }

            let commonTokens = trackTokens.intersection(songTokens)
            let commonWeight = commonTokens.map(weight).reduce(0, +)
            let unionWeight = union.map(weight).reduce(0, +)
            let tokenScore = unionWeight > 0 ? commonWeight / unionWeight : 0

            let bigramScore = dice(trackBigrams, bigrams(of: songTitle))
            let titleScore = max(tokenScore, bigramScore)

            let artistScore = artistSimilarity(song, trackArtist)
            let durationDiff = abs(song.duration - track.duration)
            let durationScore = durationDiff < 4 ? 1.0 : (durationDiff < 15 ? 0.5 : 0)

            let score = 0.7 * titleScore + 0.2 * artistScore + 0.1 * durationScore
            if titleScore >= 0.55 || (titleScore >= 0.4 && artistScore >= 1.0) {
                scored.append((song, score))
            }
        }
        return scored
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map(\.song)
    }

    private static func bigrams(of value: String) -> Set<String> {
        let chars = Array(value)
        guard chars.count > 1 else { return Set(chars.map(String.init)) }
        return Set((0..<(chars.count - 1)).map { "\(chars[$0])\(chars[$0 + 1])" })
    }

    private static func dice(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        let intersection = a.intersection(b).count
        return 2.0 * Double(intersection) / Double(a.count + b.count)
    }

    private static func artistSimilarity(_ song: Song, _ trackArtist: String) -> Double {
        guard !trackArtist.isEmpty else { return 0 }
        let variants = [song.artist, song.albumArtist].compactMap { value -> String? in
            guard let value else { return nil }
            let normalizedValue = normalized(value)
            return normalizedValue.isEmpty ? nil : normalizedValue
        }
        if variants.contains(trackArtist) { return 1.0 }
        if variants.contains(where: { $0.contains(trackArtist) || trackArtist.contains($0) }) { return 0.5 }
        return 0
    }
}
