import Foundation
import HealthKit

struct ListeningStatsEntry: Codable, Hashable {
    let id: UUID
    let songID: UUID
    let title: String
    let artist: String
    let album: String
    let timestamp: Date
    let durationPlayed: TimeInterval

    init(id: UUID = UUID(), songID: UUID, title: String, artist: String, album: String, timestamp: Date = Date(), durationPlayed: TimeInterval) {
        self.id = id
        self.songID = songID
        self.title = title
        self.artist = artist
        self.album = album
        self.timestamp = timestamp
        self.durationPlayed = durationPlayed
    }
}

struct ListeningStatsData: Codable {
    var entries: [ListeningStatsEntry]
    let version: Int

    init() {
        self.entries = []
        self.version = 1
    }
}

struct ListeningStatsAggregated {
    let totalListeningTime: TimeInterval
    let totalSongsPlayed: Int
    let uniqueArtists: Int
    let uniqueAlbums: Int
    let uniqueSongs: Int
    let topArtists: [(name: String, count: Int, totalTime: TimeInterval)]
    let topAlbums: [(name: String, artist: String, count: Int, totalTime: TimeInterval)]
    let topSongs: [(songID: UUID, title: String, artist: String, album: String, count: Int, totalTime: TimeInterval)]
    let hourlyDistribution: [Int: Int]
    let dailyDistribution: [Int: Int]

    static let empty = ListeningStatsAggregated(
        totalListeningTime: 0, totalSongsPlayed: 0, uniqueArtists: 0,
        uniqueAlbums: 0, uniqueSongs: 0, topArtists: [], topAlbums: [],
        topSongs: [], hourlyDistribution: [:], dailyDistribution: [:]
    )
}

enum ListeningStatsTimeRange: Int, CaseIterable {
    case week = 0
    case month = 1
    case year = 2
    /// Offered once listening goes back more than a year.
    case allTime = 3

    var label: String {
        switch self {
        case .week: return String(localized: "7 Days")
        case .month: return String(localized: "30 Days")
        case .year: return String(localized: "1 Year")
        case .allTime: return String(localized: "All Time")
        }
    }

    var interval: TimeInterval {
        switch self {
        case .week: return 7 * 24 * 3600
        case .month: return 30 * 24 * 3600
        case .year: return 365 * 24 * 3600
        case .allTime: return 200 * 365 * 24 * 3600
        }
    }
}

@MainActor
final class ListeningStatsService {
    static let shared = ListeningStatsService()
    /// Posted when plays are recorded or the history is erased.
    static let historyDidChange = Notification.Name("ListeningStatsHistoryDidChange")

    private let fileName = "listening_stats.json"
    private let settingsKey = "listeningStatsEnabled"
    private var cachedData: ListeningStatsData?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// On unless the user turned it off.
    var isEnabled: Bool {
        UserDefaults.standard.object(forKey: settingsKey) as? Bool ?? true
    }

    /// Recording is on by default. Builds before this default stored `false`
    /// for everyone who never touched the switch, so it is turned on once on
    /// update; any choice made after that sticks. Called at launch.
    func applyOnByDefault() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.defaultOnMigrationKey) else { return }
        defaults.set(true, forKey: Self.defaultOnMigrationKey)
        defaults.set(true, forKey: settingsKey)
    }

    private static let defaultOnMigrationKey = "listeningStatsOnByDefaultApplied"

    /// Application Support (not Documents, which is visible in Files). The
    /// first access moves the file earlier builds wrote to Documents.
    private lazy var fileURL: URL = {
        let fileManager = FileManager.default
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = base.appendingPathComponent("ListeningStats", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(fileName)

        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        let legacyDirectory = documents.appendingPathComponent("ListeningStats", isDirectory: true)
        let legacy = legacyDirectory.appendingPathComponent(fileName)
        if fileManager.fileExists(atPath: legacy.path) {
            if !fileManager.fileExists(atPath: url.path) {
                try? fileManager.moveItem(at: legacy, to: url)
            }
            try? fileManager.removeItem(at: legacyDirectory)
        }
        return url
    }()

    init() {
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    func setEnabled(_ enabled: Bool) {
        // An explicit choice is never overridden by the one-time switch-on.
        UserDefaults.standard.set(true, forKey: Self.defaultOnMigrationKey)
        UserDefaults.standard.set(enabled, forKey: settingsKey)
    }

    func recordPlay(song: Song, durationPlayed: TimeInterval) {
        guard isEnabled else { return }
        guard durationPlayed >= 10 else { return }

        let entry = ListeningStatsEntry(
            songID: song.id,
            title: song.title,
            artist: song.artist,
            album: song.album,
            durationPlayed: min(durationPlayed, song.duration)
        )

        var data = loadOrCreate()
        data.entries.append(entry)
        save(data)
        cachedData = data
        NotificationCenter.default.post(name: Self.historyDidChange, object: nil)
    }

    /// Moves the history of merged duplicates onto the songs they became.
    func replaceSongIDs(_ replacements: [UUID: UUID]) {
        var data = loadOrCreate()
        guard data.entries.contains(where: { replacements[$0.songID] != nil }) else { return }
        data.entries = data.entries.map { entry in
            guard let songID = replacements[entry.songID] else { return entry }
            return ListeningStatsEntry(
                id: entry.id,
                songID: songID,
                title: entry.title,
                artist: entry.artist,
                album: entry.album,
                timestamp: entry.timestamp,
                durationPlayed: entry.durationPlayed
            )
        }
        save(data)
        cachedData = data
        NotificationCenter.default.post(name: Self.historyDidChange, object: nil)
    }

    /// Plays from another device; ones already here (same ID) are skipped.
    func merge(_ entries: [ListeningStatsEntry]) {
        var data = loadOrCreate()
        let known = Set(data.entries.map(\.id))
        let new = entries.filter { !known.contains($0.id) }
        guard !new.isEmpty else { return }
        data.entries.append(contentsOf: new)
        data.entries.sort { $0.timestamp < $1.timestamp }
        save(data)
        cachedData = data
        NotificationCenter.default.post(name: Self.historyDidChange, object: nil)
    }

    func allEntries() -> [ListeningStatsEntry] {
        loadOrCreate().entries
    }

    func entries(in range: ListeningStatsTimeRange) -> [ListeningStatsEntry] {
        let data = loadOrCreate()
        let cutoff = Date().addingTimeInterval(-range.interval)
        return data.entries.filter { $0.timestamp >= cutoff }
    }

    func aggregate(for range: ListeningStatsTimeRange) -> ListeningStatsAggregated {
        let entries = self.entries(in: range)
        guard !entries.isEmpty else { return .empty }

        let totalListeningTime = entries.reduce(0) { $0 + $1.durationPlayed }
        let totalSongsPlayed = entries.count

        var artistCounts: [String: Int] = [:]
        var artistTime: [String: TimeInterval] = [:]
        var albumCounts: [String: Int] = [:]
        var albumTime: [String: TimeInterval] = [:]
        var albumArtist: [String: String] = [:]
        var songCounts: [String: Int] = [:]
        var songTime: [String: TimeInterval] = [:]
        var songArtist: [String: String] = [:]
        var hourly: [Int: Int] = [:]
        var daily: [Int: Int] = [:]

        let calendar = Calendar.current

        for entry in entries {
            // Merged profiles count for their main artist.
            let artist = ArtistMerges.main(for: entry.artist)
            artistCounts[artist, default: 0] += 1
            artistTime[artist, default: 0] += entry.durationPlayed

            let albumKey = "\(entry.artist)|\(entry.album)"
            albumCounts[albumKey, default: 0] += 1
            albumTime[albumKey, default: 0] += entry.durationPlayed
            albumArtist[albumKey] = entry.artist

            let songKey = "\(entry.songID.uuidString)"
            songCounts[songKey, default: 0] += 1
            songTime[songKey, default: 0] += entry.durationPlayed
            songArtist[songKey] = entry.artist

            let hour = calendar.component(.hour, from: entry.timestamp)
            hourly[hour, default: 0] += 1

            let weekday = calendar.component(.weekday, from: entry.timestamp)
            daily[weekday, default: 0] += 1
        }

        let topArtists = artistCounts
            .filter { !StatsHidden.contains(.artist($0.key)) }
            .sorted { $0.value > $1.value }
            .prefix(10)
            .map { (name: $0.key, count: $0.value, totalTime: artistTime[$0.key] ?? 0) }

        let topAlbums = albumCounts
            .filter { !StatsHidden.contains(.album(key: $0.key)) }
            .sorted { $0.value > $1.value }
            .prefix(10)
            .map { key in
                let parts = key.key.split(separator: "|", maxSplits: 1).map(String.init)
                return (
                    name: parts.count > 1 ? parts[1] : key.key,
                    artist: albumArtist[key.key] ?? "",
                    count: key.value,
                    totalTime: albumTime[key.key] ?? 0
                )
            }

        let topSongs = songCounts
            .filter { !StatsHidden.contains(.song(key: $0.key)) }
            .sorted { $0.value > $1.value }
            .prefix(10)
            .compactMap { key -> (songID: UUID, title: String, artist: String, album: String, count: Int, totalTime: TimeInterval)? in
                guard let first = entries.first(where: { $0.songID.uuidString == key.key }) else { return nil }
                return (songID: first.songID, title: first.title, artist: first.artist, album: first.album, count: key.value, totalTime: songTime[key.key] ?? 0)
            }

        return ListeningStatsAggregated(
            totalListeningTime: totalListeningTime,
            totalSongsPlayed: totalSongsPlayed,
            uniqueArtists: artistCounts.count,
            uniqueAlbums: albumCounts.count,
            uniqueSongs: songCounts.count,
            topArtists: topArtists,
            topAlbums: topAlbums,
            topSongs: topSongs,
            hourlyDistribution: hourly,
            dailyDistribution: daily
        )
    }

    func eraseAllData() {
        let url = fileURL
        saveQueue.async { try? FileManager.default.removeItem(at: url) }
        cachedData = ListeningStatsData()
        NotificationCenter.default.post(name: Self.historyDidChange, object: nil)
    }

    /// Whether the history goes back more than a year (All Time is offered).
    var firstRecordDate: Date? {
        allEntries().map(\.timestamp).min()
    }

    var hasMoreThanAYear: Bool {
        guard let first = allEntries().map(\.timestamp).min() else { return false }
        return first < Date().addingTimeInterval(-ListeningStatsTimeRange.year.interval)
    }

    func totalEntriesCount() -> Int {
        loadOrCreate().entries.count
    }

    private func loadOrCreate() -> ListeningStatsData {
        if let cached = cachedData { return cached }
        if FileManager.default.fileExists(atPath: fileURL.path),
           let data = try? Data(contentsOf: fileURL),
           let decoded = try? decoder.decode(ListeningStatsData.self, from: data) {
            cachedData = decoded
            return decoded
        }
        let fresh = ListeningStatsData()
        cachedData = fresh
        return fresh
    }

    private let saveQueue = DispatchQueue(label: "com.fares.lrc.player.stats-save", qos: .utility)

    /// The history only grows: encode and write it off the main thread.
    private func save(_ data: ListeningStatsData) {
        let url = fileURL
        saveQueue.async {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let encoded = try? encoder.encode(data) else { return }
            try? encoded.write(to: url, options: .atomic)
        }
    }
}


/// Songs, albums, artists and lines held out of the Stats rankings (the
/// totals still count them).
enum StatsHidden {
    enum Item: Hashable {
        case song(key: String)
        case album(key: String)
        case artist(String)
        case line(key: String)

        static func song(_ id: UUID) -> Item { .song(key: id.uuidString) }
        /// Albums are keyed "artist|album", as the history groups them.
        static func album(_ name: String, artist: String) -> Item { .album(key: "\(artist)|\(name)") }

        var storageKey: String {
            switch self {
            case let .song(key): "song:" + key
            case let .album(key): "album:" + key
            case let .artist(name): "artist:" + name
            case let .line(key): "line:" + key
            }
        }

        init?(storageKey: String) {
            guard let colon = storageKey.firstIndex(of: ":") else { return nil }
            let value = String(storageKey[storageKey.index(after: colon)...])
            switch storageKey[..<colon] {
            case "song": self = .song(key: value)
            case "album": self = .album(key: value)
            case "artist": self = .artist(value)
            case "line": self = .line(key: value)
            default: return nil
            }
        }
    }

    static let didChange = Notification.Name("StatsHidden.didChange")
    private static let key = "statsHiddenItems"

    /// Storage key → what the menu shows.
    private static var stored: [String: String] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
    }

    static func contains(_ item: Item) -> Bool { stored[item.storageKey] != nil }

    static var isEmpty: Bool { stored.isEmpty }

    /// Hidden items with their label, by kind then name.
    static var all: [(item: Item, label: String)] {
        stored.compactMap { key, label in Item(storageKey: key).map { ($0, label) } }
            .sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }

    static func hide(_ item: Item, label: String) {
        var all = stored
        all[item.storageKey] = label
        UserDefaults.standard.set(all, forKey: key)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    static func show(_ item: Item) {
        var all = stored
        all[item.storageKey] = nil
        UserDefaults.standard.set(all, forKey: key)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    static func showAll() {
        UserDefaults.standard.removeObject(forKey: key)
        NotificationCenter.default.post(name: didChange, object: nil)
    }
}

// MARK: - Workouts (Apple Health)

/// A workout read from Health: only its time span and kind are kept.
struct WorkoutSession: Codable, Hashable, Sendable {
    let start: Date
    let end: Date
    /// `HKWorkoutActivityType` raw value.
    let activity: UInt

    var activityName: String { WorkoutListening.name(of: activity) }
}

/// Matches the listening history against the workouts in Health: a song
/// played during a workout counts as a workout play. Read only, on device.
enum WorkoutListening {
    static let enabledKey = "workoutSyncEnabled"
    static let didChange = Notification.Name("workoutListeningDidChange")
    private static let lastSyncKey = "workoutLastSync"

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
    static var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    nonisolated(unsafe) private static let store = HKHealthStore()
    nonisolated(unsafe) private static var cache: [WorkoutSession]?

    private static var fileURL: URL {
        URL.applicationSupportDirectory.appending(path: "workouts.json")
    }

    static func storedSessions() -> [WorkoutSession] {
        if let cache { return cache }
        let sessions = (try? Data(contentsOf: fileURL)).flatMap { try? JSONDecoder().decode([WorkoutSession].self, from: $0) } ?? []
        cache = sessions
        return sessions
    }

    /// Asks Health for the workouts (read only), then syncs.
    @MainActor
    static func enable() async -> Bool {
        guard isAvailable else { return false }
        do {
            try await store.requestAuthorization(toShare: [], read: [HKObjectType.workoutType()])
        } catch {
            return false
        }
        UserDefaults.standard.set(true, forKey: enabledKey)
        await sync(force: true)
        return true
    }

    @MainActor
    static func disable() {
        UserDefaults.standard.set(false, forKey: enabledKey)
        UserDefaults.standard.removeObject(forKey: lastSyncKey)
        try? FileManager.default.removeItem(at: fileURL)
        cache = []
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    /// Reads the workouts since the first listening record. At most every
    /// ten minutes unless forced.
    @MainActor
    static func sync(force: Bool = false) async {
        guard isEnabled, isAvailable else { return }
        let last = UserDefaults.standard.object(forKey: lastSyncKey) as? Date
        if !force, let last, Date().timeIntervalSince(last) < 600 { return }
        let since = ListeningStatsService.shared.entries(in: .allTime).map(\.timestamp).min() ?? Date().addingTimeInterval(-30 * 24 * 3600)
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.workout(HKQuery.predicateForSamples(withStart: since.addingTimeInterval(-24 * 3600), end: nil))],
            sortDescriptors: [SortDescriptor(\.startDate)]
        )
        guard let workouts = try? await descriptor.result(for: store) else { return }
        let sessions = workouts.map { WorkoutSession(start: $0.startDate, end: $0.endDate, activity: $0.workoutActivityType.rawValue) }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(sessions).write(to: fileURL, options: .atomic)
        let changed = sessions != storedSessions()
        cache = sessions
        UserDefaults.standard.set(Date(), forKey: lastSyncKey)
        if changed { NotificationCenter.default.post(name: didChange, object: nil) }
    }

    /// The plays that happened during a workout: at least half the time
    /// listened (or 30 s) falls inside it.
    static func plays(in entries: [ListeningStatsEntry], sessions: [WorkoutSession]) -> [(entry: ListeningStatsEntry, session: WorkoutSession)] {
        guard !sessions.isEmpty else { return [] }
        let sorted = sessions.sorted { $0.start < $1.start }
        var result: [(ListeningStatsEntry, WorkoutSession)] = []
        for entry in entries {
            // Entries are written when the song ends.
            let end = entry.timestamp
            let start = end.addingTimeInterval(-entry.durationPlayed)
            let needed = min(30, entry.durationPlayed / 2)
            // The last workout starting before the play ends.
            var low = 0, high = sorted.count
            while low < high {
                let mid = (low + high) / 2
                if sorted[mid].start < end { low = mid + 1 } else { high = mid }
            }
            var index = low - 1
            while index >= 0, index >= low - 3 {
                let session = sorted[index]
                let overlap = min(end, session.end).timeIntervalSince(max(start, session.start))
                if overlap >= needed {
                    result.append((entry, session))
                    break
                }
                index -= 1
            }
        }
        return result
    }

    static func name(of activity: UInt) -> String {
        switch HKWorkoutActivityType(rawValue: activity) {
        case .running: String(localized: "Running")
        case .walking: String(localized: "Walking")
        case .hiking: String(localized: "Hiking")
        case .cycling: String(localized: "Cycling")
        case .traditionalStrengthTraining, .functionalStrengthTraining: String(localized: "Strength Training")
        case .highIntensityIntervalTraining: String(localized: "HIIT")
        case .coreTraining: String(localized: "Core Training")
        case .crossTraining: String(localized: "Cross Training")
        case .swimming: String(localized: "Swimming")
        case .yoga: String(localized: "Yoga")
        case .elliptical: String(localized: "Elliptical")
        case .rowing: String(localized: "Rowing")
        case .stairClimbing, .stairs: String(localized: "Stairs")
        case .socialDance, .cardioDance: String(localized: "Dancing")
        case .boxing, .kickboxing: String(localized: "Boxing")
        case .soccer: String(localized: "Soccer")
        case .basketball: String(localized: "Basketball")
        case .tennis: String(localized: "Tennis")
        case .pilates: String(localized: "Pilates")
        default: String(localized: "Other Workouts")
        }
    }
}
