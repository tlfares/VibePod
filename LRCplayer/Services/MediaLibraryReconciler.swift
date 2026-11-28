import Foundation

/// Finds the songs a Music library re-sync orphaned, and the tracks they
/// became.
///
/// Syncing an iPhone from another Mac erases its library and copies the same
/// files back: every track comes back under a new persistent ID, so the app's
/// songs point at tracks that no longer exist (they don't play, and neither
/// do the playlists holding them), and importing the library again adds every
/// song a second time. Each orphan is matched to the track it became by its
/// tags, never by title alone: an artist's redux or live take shares the
/// title, but not the album and duration.
enum MediaLibraryReconciler {
    /// A track in the iOS Music library.
    struct Track: Sendable {
        var persistentID: UInt64
        var assetURL: URL
        var title: String
        var artist: String
        var album: String
        var duration: TimeInterval
        var trackNumber: Int
        var discNumber: Int
        var genre: String = ""
        var year: Int = 0
    }

    /// One of the app's songs from the Music library.
    struct Song: Sendable {
        var id: UUID
        var persistentID: UInt64?
        var title: String
        var artist: String
        var album: String
        var duration: TimeInterval
        var trackNumber: Int
        var discNumber: Int
        var addedAt: Date
    }

    struct Plan: Equatable, Sendable {
        /// Orphaned song → the persistent ID of the track it became.
        var relinks: [UUID: UInt64] = [:]
        /// Song to delete → the song it duplicates, which takes over.
        var merges: [UUID: UUID] = [:]

        var isEmpty: Bool { relinks.isEmpty && merges.isEmpty }
    }

    /// Longest a track's duration may drift between two syncs of one file.
    static let durationTolerance: TimeInterval = 2

    static func plan(songs: [Song], tracks: [Track]) -> Plan {
        var plan = Plan()
        let livePIDs = Set(tracks.map(\.persistentID))

        // Songs still linked to a live track, oldest first: the oldest one
        // holds the history, later ones with the same track are duplicates.
        var holder: [UInt64: Song] = [:]
        for song in songs.sorted(by: { $0.addedAt < $1.addedAt }) {
            guard let pid = song.persistentID, livePIDs.contains(pid) else { continue }
            if let first = holder[pid] {
                plan.merges[song.id] = first.id
            } else {
                holder[pid] = song
            }
        }

        // The same file synced twice (a Finder sync that copies the whole
        // library again): two live tracks with the same tags. The oldest
        // song keeps the history, the copy folds into it.
        var keptByKey: [String: [Song]] = [:]
        for song in holder.values.sorted(by: { $0.addedAt < $1.addedAt }) {
            let key = matchKey(title: song.title, artist: song.artist, album: song.album)
            if let kept = keptByKey[key]?.first(where: { isSameRecording($0, song) }) {
                plan.merges[song.id] = kept.id
                for (other, target) in plan.merges where target == song.id {
                    plan.merges[other] = kept.id
                }
            } else {
                keptByKey[key, default: []].append(song)
            }
        }

        let orphans = songs.filter { song in
            song.persistentID.map { !livePIDs.contains($0) } ?? true
        }
        guard !orphans.isEmpty else { return plan }

        // Every plausible orphan → track pair, closest first; each side is
        // used once, so two identical copies pair up one to one.
        let tracksByKey = Dictionary(grouping: tracks, by: matchKey(_:))
        var pairs: [(orphan: Song, track: Track, cost: Double)] = []
        for orphan in orphans {
            for track in tracksByKey[matchKey(title: orphan.title, artist: orphan.artist, album: orphan.album)] ?? [] {
                if let cost = cost(of: orphan, as: track) {
                    pairs.append((orphan, track, cost))
                }
            }
        }
        pairs.sort { $0.cost < $1.cost }

        var matchedOrphans = Set<UUID>()
        var claimedTracks = Set<UInt64>()
        for pair in pairs where !matchedOrphans.contains(pair.orphan.id) && !claimedTracks.contains(pair.track.persistentID) {
            matchedOrphans.insert(pair.orphan.id)
            claimedTracks.insert(pair.track.persistentID)
            plan.relinks[pair.orphan.id] = pair.track.persistentID
            // Re-imported since: the orphan, with the history, takes over.
            if let duplicate = holder[pair.track.persistentID] {
                plan.merges[duplicate.id] = pair.orphan.id
                for (song, kept) in plan.merges where kept == duplicate.id {
                    plan.merges[song] = pair.orphan.id
                }
            }
        }
        return plan
    }

    /// How far `track` is from `song`, or `nil` when it can't be the same
    /// recording.
    private static func cost(of song: Song, as track: Track) -> Double? {
        var cost = 0.0
        if song.duration > 0, track.duration > 0 {
            let drift = abs(song.duration - track.duration)
            guard drift <= durationTolerance else { return nil }
            cost += drift
        }
        if song.trackNumber > 0, track.trackNumber > 0 {
            guard song.trackNumber == track.trackNumber else { return nil }
        } else {
            cost += 0.5
        }
        // Disc 0 is "untagged", read as disc 1.
        guard max(song.discNumber, 1) == max(track.discNumber, 1) else { return nil }
        return cost
    }

    /// Two songs from one file synced twice: same tags, a known duration
    /// within the drift, same track and disc. A redux or live take differs
    /// in album or duration.
    static func isSameRecording(_ a: Song, _ b: Song) -> Bool {
        guard matchKey(title: a.title, artist: a.artist, album: a.album)
                == matchKey(title: b.title, artist: b.artist, album: b.album),
              a.duration > 0, b.duration > 0,
              abs(a.duration - b.duration) <= durationTolerance,
              max(a.discNumber, 1) == max(b.discNumber, 1) else { return false }
        if a.trackNumber > 0, b.trackNumber > 0 { return a.trackNumber == b.trackNumber }
        return true
    }

    /// `candidates` without the ones already in `existing` (or twice among
    /// themselves): the copies a whole-library re-sync made.
    static func withoutCopies(_ candidates: [Song], of existing: [Song]) -> Set<UUID> {
        var byKey = Dictionary(grouping: existing) { matchKey(title: $0.title, artist: $0.artist, album: $0.album) }
        var copies = Set<UUID>()
        for song in candidates {
            let key = matchKey(title: song.title, artist: song.artist, album: song.album)
            if byKey[key]?.contains(where: { isSameRecording($0, song) }) == true {
                copies.insert(song.id)
            } else {
                byKey[key, default: []].append(song)
            }
        }
        return copies
    }

    static func matchKey(title: String, artist: String, album: String) -> String {
        [title, artist, album].map(normalized).joined(separator: "\u{1F}")
    }

    static func matchKey(_ track: Track) -> String {
        matchKey(title: track.title, artist: track.artist, album: track.album)
    }

    /// Case, accents, width and runs of spaces don't make another song.
    static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}
