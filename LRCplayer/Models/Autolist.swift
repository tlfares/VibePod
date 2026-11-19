import Foundation

/// The rules of an Autolist: a playlist the app fills and keeps up to date by
/// itself. Stored on its `Playlist`; the playlist's songs are the latest result.
struct AutolistRules: Codable, Hashable, Sendable {
    enum Selection: String, Codable, CaseIterable, Identifiable, Sendable {
        case mostPlayed
        case leastPlayed
        case recentlyPlayed
        case recentlyAdded
        case forgotten
        case neverPlayed
        case random
        /// Measured from the audio: only once the library is analyzed.
        case energetic
        case calm
        /// Fast songs (120 BPM+). Stored as "workout" from before it had a name of its own.
        case upTempo = "workout"
        /// The songs played most during workouts (Apple Health).
        case workoutFavorites

        var id: Self { self }

        /// Picks by the sound analysis (Stats), offered once it has run.
        var needsSoundAnalysis: Bool { self == .energetic || self == .calm || self == .upTempo }
        /// Picks by the workouts read from Health, offered once that's on.
        var needsWorkouts: Bool { self == .workoutFavorites }

        var title: String {
            switch self {
            case .mostPlayed: String(localized: "Most Played")
            case .leastPlayed: String(localized: "Least Played")
            case .recentlyPlayed: String(localized: "Recently Played")
            case .recentlyAdded: String(localized: "Recently Added")
            case .forgotten: String(localized: "Forgotten Favorites")
            case .neverPlayed: String(localized: "Never Played")
            case .random: String(localized: "Random Mix")
            case .energetic: String(localized: "Energy Boost")
            case .calm: String(localized: "Calm")
            case .upTempo: String(localized: "Up-Tempo")
            case .workoutFavorites: String(localized: "Workout")
            }
        }

        var symbol: String {
            switch self {
            case .mostPlayed: "flame.fill"
            case .leastPlayed: "moon.zzz.fill"
            case .recentlyPlayed: "clock.arrow.circlepath"
            case .recentlyAdded: "tray.and.arrow.down.fill"
            case .forgotten: "heart.fill"
            case .neverPlayed: "circle.dashed"
            case .random: "dice.fill"
            case .energetic: "bolt.fill"
            case .calm: "leaf.fill"
            case .upTempo: "metronome.fill"
            case .workoutFavorites: "figure.run"
            }
        }

        var summary: String {
            switch self {
            case .mostPlayed: String(localized: "Your most played songs, ranked by play count.")
            case .leastPlayed: String(localized: "The songs you play the least, unplayed ones first.")
            case .recentlyPlayed: String(localized: "The songs you played last, newest first.")
            case .recentlyAdded: String(localized: "The newest songs in your library.")
            case .forgotten: String(localized: "Songs you played at least \(AutolistRules.favoritePlays) times but not in the last 30 days.")
            case .neverPlayed: String(localized: "Songs you haven’t played yet, newest first.")
            case .random: String(localized: "A random pick of your songs, new at every update.")
            case .energetic: String(localized: "Your most intense songs, whatever their tempo, measured from their sound.")
            case .calm: String(localized: "Your calmest songs, measured from their sound.")
            case .upTempo: String(localized: "Fast, punchy songs, 120 BPM and up, to keep a pace.")
            case .workoutFavorites: String(localized: "The songs you play most during your workouts, from Apple Health.")
            }
        }

        /// The period only changes how plays are counted.
        var usesPeriod: Bool { self == .mostPlayed || self == .workoutFavorites }
        /// A random pick has no ranking to keep.
        var hasRanking: Bool { self != .random }

        var defaultPalette: CoverPalette {
            switch self {
            case .mostPlayed: .ember
            case .leastPlayed: .midnight
            case .recentlyPlayed: .lagoon
            case .recentlyAdded: .lime
            case .forgotten: .orchid
            case .neverPlayed: .indigo
            case .random: .sunrise
            case .energetic: .cherry
            case .calm: .mint
            case .upTempo: .peach
            case .workoutFavorites: .lime
            }
        }
    }

    enum Period: String, Codable, CaseIterable, Identifiable, Sendable {
        case allTime
        case week
        case month
        case year

        var id: Self { self }

        var title: String {
            switch self {
            case .allTime: String(localized: "All Time")
            case .week: String(localized: "Last 7 Days")
            case .month: String(localized: "Last 30 Days")
            case .year: String(localized: "Last 12 Months")
            }
        }

        /// Plays inside a window come from the listening history.
        var historyRange: ListeningStatsTimeRange? {
            switch self {
            case .allTime: nil
            case .week: .week
            case .month: .month
            case .year: .year
            }
        }
    }

    enum Order: String, Codable, CaseIterable, Identifiable, Sendable {
        case ranked
        case shuffled

        var id: Self { self }

        var title: String {
            switch self {
            case .ranked: String(localized: "Ranked")
            case .shuffled: String(localized: "Shuffled")
            }
        }
    }

    /// How often the songs are picked again.
    enum Refresh: String, Codable, CaseIterable, Identifiable, Sendable {
        case instant
        case daily
        case everyTwoDays
        case weekly
        case monthly
        case manual

        var id: Self { self }

        var title: String {
            switch self {
            case .instant: String(localized: "As You Listen")
            case .daily: String(localized: "Every Day")
            case .everyTwoDays: String(localized: "Every 2 Days")
            case .weekly: String(localized: "Every Week")
            case .monthly: String(localized: "Every Month")
            case .manual: String(localized: "Manually")
            }
        }

        /// When an Autolist last updated at `date` is due again; `nil` for
        /// the ones that don't wait (instant) or never update alone (manual).
        func nextUpdate(after date: Date, calendar: Calendar = .current) -> Date? {
            switch self {
            case .instant, .manual: nil
            case .daily: calendar.date(byAdding: .day, value: 1, to: date)
            case .everyTwoDays: calendar.date(byAdding: .day, value: 2, to: date)
            case .weekly: calendar.date(byAdding: .day, value: 7, to: date)
            case .monthly: calendar.date(byAdding: .month, value: 1, to: date)
            }
        }
    }

    static let limitChoices: [Int?] = [10, 25, 50, 100, 250, nil]
    static let favoritePlays = 3

    var selection: Selection = .mostPlayed
    var period: Period = .allTime
    /// `nil`: every matching song.
    var limit: Int? = 50
    var order: Order = .ranked
    var refresh: Refresh = .everyTwoDays
    /// Empty: any artist.
    var artists: [String] = []
    /// Empty: any genre.
    var genres: [String] = []
    /// First year of the decade (1990 for the 1990s).
    var decade: Int?
    var requiresLyrics = false
    /// Empty: the name follows the rules.
    var customName = ""
    /// `nil`: the selection's own colors.
    var palette: CoverPalette?
    var style: CoverStyle = .classic
    /// The covers of the first four albums instead of a drawn cover.
    var usesMix = false
    /// Drives the shuffled order and the random pick; "Shuffle Again" renews it.
    var seed: UInt64 = .random(in: .min ... .max)

    init() {}

    // MARK: Text

    var automaticName: String {
        let base = limit.map { String(localized: "\($0) \(selection.title)", comment: "Autolist name: song count, then the selection (“25 Most Played”)") } ?? selection.title
        let filters = [Self.artistsSummary(artists), Self.genresSummary(genres), decade.map(Self.decadeTitle)].compactMap(\.self)
        return filters.isEmpty ? base : "\(base) · \(filters.joined(separator: ", "))"
    }

    var name: String {
        let trimmed = customName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? automaticName : trimmed
    }

    /// The small line on the cover and the page: period and filters.
    var caption: String {
        var parts: [String] = []
        if selection.usesPeriod { parts.append(period.title) }
        if let artists = Self.artistsSummary(artists) { parts.append(artists) }
        if let genres = Self.genresSummary(genres) { parts.append(genres) }
        if let decade { parts.append(Self.decadeTitle(decade)) }
        if requiresLyrics { parts.append(String(localized: "With Lyrics")) }
        if selection == .random, parts.isEmpty, let caption = refreshCaption { parts.append(caption) }
        return parts.joined(separator: " · ")
    }

    /// What a random pick's cover says about its renewal.
    private var refreshCaption: String? {
        switch refresh {
        // The random pick changes with the day at most.
        case .instant, .daily: String(localized: "New Every Day")
        case .everyTwoDays: String(localized: "New Every 2 Days")
        case .weekly: String(localized: "New Every Week")
        case .monthly: String(localized: "New Every Month")
        case .manual: nil
        }
    }

    var resolvedPalette: CoverPalette { palette ?? selection.defaultPalette }

    var cover: GeneratedCover {
        GeneratedCover(
            number: limit.map(String.init),
            title: selection.title,
            caption: caption,
            symbol: selection.symbol,
            palette: resolvedPalette,
            style: style
        )
    }

    var effectiveOrder: Order { selection.hasRanking ? order : .shuffled }

    static func decadeTitle(_ decade: Int) -> String { String(localized: "\(decade)s", comment: "A decade, from its first year (“1990s”)") }

    /// "Nova Lane", "3 Artists", or nil for none.
    static func artistsSummary(_ names: [String]) -> String? {
        summary(of: names) { String(localized: "\($0) Artists") }
    }

    /// "Pop", "3 Genres", or nil for none.
    static func genresSummary(_ names: [String]) -> String? {
        summary(of: names) { String(localized: "\($0) Genres") }
    }

    private static func summary(of names: [String], counted: (Int) -> String) -> String? {
        switch names.count {
        case 0: nil
        case 1: names[0]
        default: counted(names.count)
        }
    }

    // MARK: Coding

    private enum CodingKeys: String, CodingKey {
        case selection, period, limit, order, refresh, artists, genres, decade, requiresLyrics, customName, palette, style, usesMix, seed
    }

    /// Single-value filters saved by the first version.
    private enum LegacyKeys: String, CodingKey {
        case artist, genre
    }

    /// Every field is optional so rules saved by any version keep decoding.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        selection = (try? c.decode(Selection.self, forKey: .selection)) ?? .mostPlayed
        period = (try? c.decode(Period.self, forKey: .period)) ?? .allTime
        limit = try c.decodeIfPresent(Int.self, forKey: .limit)
        order = (try? c.decode(Order.self, forKey: .order)) ?? .ranked
        refresh = (try? c.decode(Refresh.self, forKey: .refresh)) ?? .everyTwoDays
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        artists = try c.decodeIfPresent([String].self, forKey: .artists)
            ?? (try legacy.decodeIfPresent(String.self, forKey: .artist)).map { [$0] } ?? []
        genres = try c.decodeIfPresent([String].self, forKey: .genres)
            ?? (try legacy.decodeIfPresent(String.self, forKey: .genre)).map { [$0] } ?? []
        decade = try c.decodeIfPresent(Int.self, forKey: .decade)
        requiresLyrics = try c.decodeIfPresent(Bool.self, forKey: .requiresLyrics) ?? false
        customName = try c.decodeIfPresent(String.self, forKey: .customName) ?? ""
        palette = try? c.decodeIfPresent(CoverPalette.self, forKey: .palette)
        style = (try? c.decode(CoverStyle.self, forKey: .style)) ?? .classic
        usesMix = try c.decodeIfPresent(Bool.self, forKey: .usesMix) ?? false
        seed = try c.decodeIfPresent(UInt64.self, forKey: .seed) ?? .random(in: .min ... .max)
    }
}

// MARK: - Engine

/// Picks an Autolist's songs. Pure: everything it reads is passed in.
@MainActor
enum AutolistEngine {
    /// Play counts inside history windows, computed once per refresh.
    @MainActor
    final class HistoryCounts {
        private var counts: [ListeningStatsTimeRange: [UUID: Int]] = [:]

        func plays(in range: ListeningStatsTimeRange) -> [UUID: Int] {
            if let cached = counts[range] { return cached }
            var result: [UUID: Int] = [:]
            for entry in ListeningStatsService.shared.entries(in: range) {
                result[entry.songID, default: 0] += 1
            }
            counts[range] = result
            return result
        }

        private var workoutCounts: [ListeningStatsTimeRange: [UUID: Int]] = [:]

        /// Plays that happened during a workout.
        func workoutPlays(in range: ListeningStatsTimeRange) -> [UUID: Int] {
            if let cached = workoutCounts[range] { return cached }
            var result: [UUID: Int] = [:]
            let entries = ListeningStatsService.shared.entries(in: range)
            for play in WorkoutListening.plays(in: entries, sessions: WorkoutListening.storedSessions()) {
                result[play.entry.songID, default: 0] += 1
            }
            workoutCounts[range] = result
            return result
        }
    }

    static func songIDs(for rules: AutolistRules, in songs: [Song], history: HistoryCounts, now: Date = Date()) -> [UUID] {
        let filters = Filters(rules)
        let candidates = songs.filter(filters.matches)
        var picked: [Song]

        switch rules.selection {
        case .mostPlayed:
            if let range = rules.period.historyRange {
                let plays = history.plays(in: range)
                picked = candidates
                    .filter { (plays[$0.id] ?? 0) > 0 }
                    .sorted { lhs, rhs in
                        let l = plays[lhs.id] ?? 0, r = plays[rhs.id] ?? 0
                        return l != r ? l > r : recency(lhs, rhs)
                    }
            } else {
                picked = candidates
                    .filter { $0.playCount > 0 }
                    .sorted { $0.playCount != $1.playCount ? $0.playCount > $1.playCount : recency($0, $1) }
            }
        case .leastPlayed:
            picked = candidates.sorted { lhs, rhs in
                if lhs.playCount != rhs.playCount { return lhs.playCount < rhs.playCount }
                switch (lhs.lastPlayedAt, rhs.lastPlayedAt) {
                case let (l?, r?) where l != r: return l < r
                case (nil, .some): return true
                case (.some, nil): return false
                default: return stable(lhs, rhs)
                }
            }
        case .recentlyPlayed:
            picked = candidates
                .filter { $0.lastPlayedAt != nil }
                .sorted(by: recency)
        case .recentlyAdded:
            picked = candidates.sorted { $0.addedAt != $1.addedAt ? $0.addedAt > $1.addedAt : stable($0, $1) }
        case .forgotten:
            let cutoff = now.addingTimeInterval(-30 * 24 * 3600)
            picked = candidates
                .filter { $0.playCount >= AutolistRules.favoritePlays && ($0.lastPlayedAt ?? .distantPast) < cutoff }
                .sorted { $0.playCount != $1.playCount ? $0.playCount > $1.playCount : recency($0, $1) }
        case .neverPlayed:
            picked = candidates
                .filter { $0.playCount == 0 }
                .sorted { $0.addedAt != $1.addedAt ? $0.addedAt > $1.addedAt : stable($0, $1) }
        case .workoutFavorites:
            let plays = history.workoutPlays(in: rules.period.historyRange ?? .allTime)
            picked = candidates
                .filter { (plays[$0.id] ?? 0) > 0 }
                .sorted { lhs, rhs in
                    let l = plays[lhs.id] ?? 0, r = plays[rhs.id] ?? 0
                    return l != r ? l > r : recency(lhs, rhs)
                }
        case .energetic, .calm, .upTempo:
            let sound = LibrarySoundAnalysis.storedProfiles()
            let measured = candidates.filter { sound[$0.id] != nil }
            let energy = { (song: Song) in sound[song.id]!.energy }
            switch rules.selection {
            case .energetic:
                picked = measured.filter { sound[$0.id]!.mood == .energetic }.sorted { energy($0) != energy($1) ? energy($0) > energy($1) : stable($0, $1) }
            case .calm:
                picked = measured.filter { sound[$0.id]!.mood == .calm }.sorted { energy($0) != energy($1) ? energy($0) < energy($1) : stable($0, $1) }
            default:
                picked = measured.filter { sound[$0.id]!.bpm >= 120 && energy($0) >= 0.55 }.sorted { energy($0) != energy($1) ? energy($0) > energy($1) : stable($0, $1) }
            }
        case .random:
            // Same pick all day, a new one tomorrow.
            let day = UInt64(max(0, Calendar.current.ordinality(of: .day, in: .era, for: now) ?? 0))
            let seed = rules.seed ^ (day &* 0x9E37_79B9_7F4A_7C15)
            picked = candidates.sorted { shuffleKey($0.id, seed) < shuffleKey($1.id, seed) }
        }

        if let limit = rules.limit { picked = Array(picked.prefix(limit)) }
        if rules.effectiveOrder == .shuffled, rules.selection != .random {
            // Stable while the songs stay the same; new songs land at random.
            picked.sort { shuffleKey($0.id, rules.seed) < shuffleKey($1.id, rules.seed) }
        }
        return picked.map(\.id)
    }

    /// The rules' filters, with the name lists turned into sets once.
    private struct Filters {
        let artists: Set<String>
        let genres: Set<String>
        let decade: Int?
        let requiresLyrics: Bool

        init(_ rules: AutolistRules) {
            artists = Set(rules.artists)
            genres = Set(rules.genres)
            decade = rules.decade
            requiresLyrics = rules.requiresLyrics
        }

        func matches(_ song: Song) -> Bool {
            if !artists.isEmpty, !artists.contains(LibraryIndex.artistName(for: song)), !artists.contains(song.artist) {
                return false
            }
            if !genres.isEmpty, !genres.contains(AutolistEngine.genreName(of: song)) { return false }
            if let decade, song.year < decade || song.year >= decade + 10 { return false }
            if requiresLyrics, song.lrcFilePath == nil { return false }
            return true
        }
    }

    /// Same grouping as the Genres page.
    nonisolated static func genreName(of song: Song) -> String {
        let genre = song.genre.trimmingCharacters(in: .whitespacesAndNewlines)
        return genre.isEmpty ? "Unknown" : genre
    }

    private static func recency(_ lhs: Song, _ rhs: Song) -> Bool {
        let l = lhs.lastPlayedAt ?? .distantPast, r = rhs.lastPlayedAt ?? .distantPast
        return l != r ? l > r : stable(lhs, rhs)
    }

    private static func stable(_ lhs: Song, _ rhs: Song) -> Bool {
        let order = lhs.title.localizedStandardCompare(rhs.title)
        return order != .orderedSame ? order == .orderedAscending : lhs.id.uuidString < rhs.id.uuidString
    }

    /// SplitMix64 over the song ID: the same seed gives the same order on
    /// every launch (`Hasher` is randomized per process).
    private static func shuffleKey(_ id: UUID, _ seed: UInt64) -> UInt64 {
        let bytes = id.uuid
        let high = withUnsafeBytes(of: (bytes.0, bytes.1, bytes.2, bytes.3, bytes.4, bytes.5, bytes.6, bytes.7)) { $0.load(as: UInt64.self) }
        let low = withUnsafeBytes(of: (bytes.8, bytes.9, bytes.10, bytes.11, bytes.12, bytes.13, bytes.14, bytes.15)) { $0.load(as: UInt64.self) }
        var z = seed ^ high ^ (low &* 0xBF58_476D_1CE4_E5B9)
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
