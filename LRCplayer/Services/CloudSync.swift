@preconcurrency import CloudKit
import Combine
import CryptoKit
import UIKit

// MARK: - Documents

/// One part of a synced document (a song's lyrics, a setting), with who
/// changed it last and when: two devices changing different parts of the
/// same thing never step on each other.
struct SyncSection: Codable, Equatable, Sendable {
    var data: Data
    var modified: Date
    var author: String
}

/// What goes up to iCloud for one thing (a song, a playlist, a month of
/// listening…): one CloudKit record.
struct SyncDoc: Codable, Equatable, Sendable {
    var sections: [String: SyncSection] = [:]
}

/// What a domain reads from the app for one document.
struct DocSnapshot {
    var sections: [String: Data] = [:]
    /// Parts that can't be read right now (a lyrics file out of reach):
    /// neither sent nor taken as deleted.
    var skipped: Set<String> = []
}

enum SyncValue {
    /// A part deleted on a device.
    static let null = Data("null".utf8)

    static func encode<T: Encodable>(_ value: T) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(value)) ?? null
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        try? JSONDecoder().decode(type, from: data)
    }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}

/// One kind of synced data. Documents are named `prefix.something`.
@MainActor
protocol SyncDomain: AnyObject {
    var prefix: String { get }
    /// Deleting a document on one device deletes it everywhere.
    var propagatesDeletion: Bool { get }
    /// The documents this device has.
    func localDocuments() -> [String]
    /// What this device has for the document, nil when it has none.
    func snapshot(_ name: String) -> DocSnapshot?
    /// Writes these parts into the app. False when the document can't be
    /// held here (a song this device doesn't have).
    func apply(_ name: String, sections: [String: Data]) -> Bool
    /// The document was deleted on another device.
    func remove(_ name: String)
    /// Both sides changed the part: their merge, or nil when the latest
    /// change wins.
    func merge(section: String, local: Data, remote: Data) -> Data?
    func beginApplying()
    func endApplying()
}

extension SyncDomain {
    var propagatesDeletion: Bool { true }
    func remove(_ name: String) {}
    func merge(section: String, local: Data, remote: Data) -> Data? { nil }
    func beginApplying() {}
    func endApplying() {}
}

// MARK: - Song identity

/// Songs get a random ID on each device, so synced data names them by a
/// key every device works out the same way from the song itself (its file
/// name and size, its server ID…). In synced data, song IDs are swapped for
/// `@@song:<hash of the key>` going up and back to local IDs coming down.
@MainActor
final class SyncSongKeys {
    private struct Stored: Codable {
        var keys: [UUID: String] = [:]
        /// Hashes of songs another device has and this one doesn't (yet).
        var placeholders: Set<String> = []
    }

    private var stored = Stored()
    private var idByHash: [String: UUID] = [:]
    private var hashByID: [UUID: String] = [:]
    private let url: URL

    static let tokenPrefix = "@@song:"

    init(directory: URL) {
        url = directory.appendingPathComponent("keys.json")
        if let data = try? Data(contentsOf: url), let decoded = try? JSONDecoder().decode(Stored.self, from: data) {
            stored = decoded
        }
        rebuild()
    }

    func key(for id: UUID) -> String? { stored.keys[id] }
    func hash(for id: UUID) -> String? { hashByID[id] }
    func id(forHash hash: String) -> UUID? { idByHash[hash] }

    /// Gives new songs their key; forgets deleted ones. Returns the hashes
    /// that were placeholders and now are songs here.
    @discardableResult
    func refresh(songs: [Song]) -> [String: UUID] {
        let present = Set(songs.map(\.id))
        var changed = false
        for id in stored.keys.keys where !present.contains(id) {
            stored.keys[id] = nil
            changed = true
        }
        var used = Set(stored.keys.values)
        for song in songs.sorted(by: { $0.addedAt < $1.addedAt }) where stored.keys[song.id] == nil {
            let base = Self.key(for: song)
            var key = base
            var copy = 2
            while used.contains(key) {
                key = "\(base)#\(copy)"
                copy += 1
            }
            used.insert(key)
            stored.keys[song.id] = key
            changed = true
        }
        guard changed else { return [:] }
        rebuild()
        var resolved: [String: UUID] = [:]
        for hash in stored.placeholders {
            if let id = idByHash[hash] { resolved[hash] = id }
        }
        stored.placeholders.subtract(resolved.keys)
        save()
        return resolved
    }

    /// Another device knows this song by another key: take it.
    func rekey(_ id: UUID, to key: String) {
        if let holder = stored.keys.first(where: { $0.value == key })?.key, holder != id {
            stored.keys[holder] = key + "#\(id.uuidString.prefix(4))"
        }
        stored.keys[id] = key
        rebuild()
        save()
    }

    private func rebuild() {
        hashByID = stored.keys.mapValues(Self.hash)
        idByHash = Dictionary(hashByID.map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func save() {
        let snapshot = stored
        let url = url
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: url, options: .atomic) }
        }
    }

    // MARK: Keys

    nonisolated static func key(for song: Song) -> String {
        if song.source == .subsonic, let remoteID = song.remoteID {
            return "s:\(remoteID)"
        }
        if song.isMediaLibraryItem || song.fileSize <= 0 {
            let match = MediaLibraryReconciler.matchKey(title: song.title, artist: song.artist, album: song.album)
            return "m:\(match):\(Int(song.duration.rounded()))"
        }
        // Copied with the Finder: same name, same bytes on every device.
        let name = song.fileURL.lastPathComponent.precomposedStringWithCanonicalMapping.lowercased()
        return "f:\(song.fileSize):\(name)"
    }

    nonisolated static func hash(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// The ID a song another device has goes by here, until this device
    /// has the song too.
    nonisolated static func placeholderID(_ hash: String) -> UUID {
        let hex = Array(hash)
        let string = "\(String(hex[0..<8]))-\(String(hex[8..<12]))-\(String(hex[12..<16]))-\(String(hex[16..<20]))-\(String(hex[20..<32]))"
        return UUID(uuidString: string) ?? UUID()
    }

    // MARK: Tokens

    private static let uuidPattern = try! NSRegularExpression(pattern: "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}")
    private static let tokenPattern = try! NSRegularExpression(pattern: "@@song:([0-9a-f]{32})")

    /// Local song IDs → tokens.
    func tokenize(_ data: Data) -> Data {
        guard let text = String(data: data, encoding: .utf8) else { return data }
        return Data(tokenize(text).utf8)
    }

    func tokenize(_ text: String) -> String {
        replace(Self.uuidPattern, in: text) { match in
            let id = match.uppercased()
            if let uuid = UUID(uuidString: id) {
                if let hash = hashByID[uuid] { return Self.tokenPrefix + hash }
                let compact = id.replacingOccurrences(of: "-", with: "").lowercased()
                if stored.placeholders.contains(compact) { return Self.tokenPrefix + compact }
            }
            return nil
        }
    }

    /// Tokens → local song IDs (or placeholders).
    func detokenize(_ data: Data) -> Data {
        guard let text = String(data: data, encoding: .utf8), text.contains(Self.tokenPrefix) else { return data }
        return Data(detokenize(text).utf8)
    }

    func detokenize(_ text: String) -> String {
        guard text.contains(Self.tokenPrefix) else { return text }
        var added = false
        let result = replace(Self.tokenPattern, in: text, group: 1) { hash in
            if let id = idByHash[hash] { return id.uuidString }
            if !stored.placeholders.contains(hash) {
                stored.placeholders.insert(hash)
                added = true
            }
            return Self.placeholderID(hash).uuidString
        }
        if added { save() }
        return result
    }

    private func replace(_ pattern: NSRegularExpression, in text: String, group: Int = 0, with transform: (String) -> String?) -> String {
        let ns = text as NSString
        let matches = pattern.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        var result = ""
        result.reserveCapacity(text.utf16.count)
        var cursor = 0
        for match in matches {
            let captured = ns.substring(with: match.range(at: group))
            guard let replacement = transform(captured) else { continue }
            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            result += replacement
            cursor = match.range.location + match.range.length
        }
        result += ns.substring(from: cursor)
        return result
    }
}

// MARK: - Devices

struct SyncDevice: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var name: String
    var kind: Kind
    var isLinked: Bool
    var lastSeen: Date

    enum Kind: String, Codable, Sendable {
        case iPhone, iPad, mac

        var systemImage: String {
            switch self {
            case .iPhone: "iphone"
            case .iPad: "ipad"
            case .mac: "macbook"
            }
        }
    }

    static var currentKind: Kind {
        if MacApp.isActive { return .mac }
        return UIDevice.current.userInterfaceIdiom == .pad ? .iPad : .iPhone
    }

    static var currentName: String {
        switch currentKind {
        case .iPhone: "iPhone"
        case .iPad: "iPad"
        case .mac: "Mac"
        }
    }
}

/// Playback left on another device, offered here.
struct SyncResumeOffer: Identifiable, Equatable {
    let id: Date
    let deviceName: String
    let songs: [Song]
    let index: Int
    let time: TimeInterval

    var song: Song { songs[index] }
}

// MARK: - Engine

/// iCloud Sync: everything but the audio files, kept the same on every
/// linked device through the user's private CloudKit database. One device
/// is the main one: when a device is linked, the main device's version of
/// anything both had comes first; after that, the latest change wins.
@MainActor
final class CloudSync: ObservableObject {
    static let shared = CloudSync()

    enum Status: Equatable {
        case off
        case starting
        case upToDate(Date?)
        case syncing
        case failed(String)
    }

    @Published private(set) var status: Status = .off
    @Published private(set) var devices: [SyncDevice] = []
    @Published private(set) var primaryID: String?
    @Published var resumeOffer: SyncResumeOffer?

    static let containerID = "iCloud.com.fares.lrc.player"
    private static let enabledKey = "cloudSyncEnabled"
    private static let deviceIDKey = "cloudSyncDeviceID"
    private static let lastSyncKey = "cloudSyncLastSync"
    private static let registryName = "registry"
    /// Inline in the record below this; a CloudKit asset above.
    private static let inlineLimit = 600_000
    /// What a part this device had before it was linked is dated: anything
    /// the main device had for it comes first.
    private static let linkDate = Date(timeIntervalSince1970: 1)

    var isEnabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }

    let deviceID: String = {
        if let id = UserDefaults.standard.string(forKey: CloudSync.deviceIDKey) { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: CloudSync.deviceIDKey)
        return id
    }()

    var isPrimary: Bool { primaryID == deviceID }
    var thisDevice: SyncDevice? { devices.first { $0.id == deviceID } }
    var primaryDevice: SyncDevice? { devices.first { $0.id == primaryID } }
    /// Syncing data, not only the device list.
    var isActive: Bool { isEnabled && (isPrimary || thisDevice?.isLinked == true) }

    private struct Entry: Codable, Equatable {
        var doc = SyncDoc()
        var systemFields: Data?
        /// The document matches what this device holds.
        var applied = false
        /// Hash of the document as iCloud has it.
        var serverHash: String?
    }

    private var entries: [String: Entry] = [:]
    private var dirtyEntries: Set<String> = []
    private var removedEntries: Set<String> = []
    private var engine: CKSyncEngine?
    private var domains: [String: SyncDomain] = [:]
    private(set) var keys: SyncSongKeys
    private weak var library: LibraryService?
    private var cancellables = Set<AnyCancellable>()
    private var scanTask: Task<Void, Never>?
    private var pendingScan: Set<String> = []
    private var pendingSongIDs: Set<UUID> = []
    /// The library as last seen, to tell which songs changed.
    private var seenSongs: [UUID: Song] = [:]
    private var seenSummaries: [UUID: LyricsSummaries.Entry] = [:]
    /// Documents as sent, by name, until iCloud confirms them.
    private var sentDocs: [String: SyncDoc] = [:]
    private var scanTimer: Timer?
    private var persistTask: Task<Void, Never>?
    private var outbox: [String: URL] = [:]
    private var hasFetched = false
    private var wasActive = false
    private var isScanning = false
    private var didFullScan = false
    private let zoneID = CKRecordZone.ID(zoneName: "VibePod", ownerName: CKCurrentUserDefaultName)

    private static let directory: URL = {
        let url = URL.applicationSupportDirectory.appending(path: "CloudSync", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url.appending(path: "Docs"), withIntermediateDirectories: true)
        return url
    }()

    private static var outboxDirectory: URL {
        let url = URL.cachesDirectory.appending(path: "CloudSyncOutbox", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private init() {
        keys = SyncSongKeys(directory: Self.directory)
    }

    // MARK: Starting

    /// At launch, once the library is loaded.
    func start(library: LibraryService) {
        self.library = library
        let list: [SyncDomain] = [
            SongsSyncDomain(library: library),
            PlaylistsSyncDomain(library: library),
            ProgramsSyncDomain(),
            HistorySyncDomain(),
            ImportsSyncDomain(),
            AssistantSyncDomain(),
            SettingsSyncDomain(),
            SecretsSyncDomain(),
            SessionSyncDomain.shared,
        ]
        domains = Dictionary(uniqueKeysWithValues: list.map { ($0.prefix, $0) })
        let restore = Self.directory.appending(path: "restore-lyrics.json")
        if FileManager.default.fileExists(atPath: restore.path) {
            (domains["song"] as? SongsSyncDomain)?.restoreLyrics(from: restore)
        }
        observeApp()
        guard isEnabled else { return }
        Task { await startEngine() }
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        objectWillChange.send()
        if enabled {
            Task { await startEngine() }
        } else {
            if engine != nil { setDeviceSection { $0.isLinked = false } }
            let engine = engine
            Task {
                try? await engine?.sendChanges()
                self.stop()
            }
        }
    }

    private func startEngine() async {
        guard engine == nil else { return }
        status = .starting
        let accountStatus = (try? await CKContainer(identifier: Self.containerID).accountStatus()) ?? .couldNotDetermine
        guard isEnabled else { return }
        guard accountStatus == .available else {
            status = .failed(accountStatus == .noAccount
                ? String(localized: "Sign in to iCloud in the Settings app to sync.")
                : String(localized: "iCloud isn't available right now."))
            return
        }
        await loadEntries()
        guard isEnabled, engine == nil else { return }
        let state = (try? Data(contentsOf: Self.directory.appending(path: "engine.json")))
            .flatMap { try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0) }
        let configuration = CKSyncEngine.Configuration(
            database: CKContainer(identifier: Self.containerID).privateCloudDatabase,
            stateSerialization: state,
            delegate: self
        )
        let engine = CKSyncEngine(configuration)
        self.engine = engine
        if state == nil {
            engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
        }
        refreshRegistry()
        status = .syncing
        Task { await syncNow() }
    }

    /// Fetches, then sends what changed here.
    /// Fetches what the other devices changed, then sends what changed
    /// here. Everything is looked at only once per launch; after that, only
    /// what changed.
    func syncNow() async {
        guard let engine else { return }
        do {
            try await engine.fetchChanges()
            hasFetched = true
            heartbeat()
            activateIfNeeded()
            if isActive {
                if didFullScan {
                    await scanPending()
                } else {
                    didFullScan = true
                    await scan(nil)
                }
            }
            try await engine.sendChanges()
            markSynced()
        } catch {
            status = .failed(Self.message(for: error))
        }
    }

    private func markSynced() {
        let now = Date()
        UserDefaults.standard.set(now, forKey: Self.lastSyncKey)
        status = .upToDate(now)
    }

    var isRunning: Bool { engine != nil }
    var lastSync: Date? { UserDefaults.standard.object(forKey: Self.lastSyncKey) as? Date }

    /// Stops and forgets the sync state here; the app's data stays.
    /// Turned off: what's kept here stays, so turning it back on only
    /// catches up on what changed.
    private func stop() {
        guard !isEnabled else { return }
        scanTask?.cancel()
        scanTask = nil
        pendingScan = []
        pendingSongIDs = []
        sentDocs = [:]
        persistNow()
        engine = nil
        hasFetched = false
        wasActive = false
        didFullScan = false
        status = .off
    }

    /// Another iCloud account: nothing kept applies any more.
    private func reset() {
        scanTask?.cancel()
        scanTask = nil
        pendingScan = []
        pendingSongIDs = []
        sentDocs = [:]
        persistTask?.cancel()
        engine = nil
        entries = [:]
        dirtyEntries = []
        removedEntries = []
        hasFetched = false
        wasActive = false
        devices = []
        primaryID = nil
        status = .off
        try? FileManager.default.removeItem(at: Self.directory.appending(path: "Docs"))
        try? FileManager.default.removeItem(at: Self.directory.appending(path: "engine.json"))
        try? FileManager.default.createDirectory(at: Self.directory.appending(path: "Docs"), withIntermediateDirectories: true)
    }

    private func observeApp() {
        let center = NotificationCenter.default
        center.publisher(for: UIApplication.willEnterForegroundNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.engine != nil else { return }
                Task { await self.syncNow() }
            }
            .store(in: &cancellables)
        center.publisher(for: UIApplication.didEnterBackgroundNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.flushInBackground() }
            .store(in: &cancellables)

        // What changed here, scanned a few seconds later (bursts coalesce).
        let watched: [(Notification.Name, String)] = [
            (ListeningStatsService.historyDidChange, "history"),
            (ImportedHistory.didChange, "import"),
            (UserDefaults.didChangeNotification, "settings"),
            (AIFeatures.didChangeNotification, "secrets"),
            (MusicVideoFeature.didChangeNotification, "secrets"),
        ]
        for (name, prefix) in watched {
            // Some are posted off the main thread (the widget's defaults).
            center.publisher(for: name)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.scheduleScan(prefix) }
                .store(in: &cancellables)
        }
        // A song's marks or word timings: that song only.
        for name in [LyricsMarks.didChangeNotification, WordSyncStore.didChangeNotification] {
            center.publisher(for: name)
                .compactMap { $0.object as? UUID }
                .receive(on: DispatchQueue.main)
                .sink { [weak self] id in self?.scheduleSongScan([id]) }
                .store(in: &cancellables)
        }
        // The songs that changed (a play, an edit, new lyrics), not all.
        seenSongs = Dictionary((library?.songs ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        library?.$songs.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] songs in
            guard let self else { return }
            var changed = Set<UUID>()
            var seen: [UUID: Song] = [:]
            seen.reserveCapacity(songs.count)
            for song in songs where seen[song.id] == nil {
                seen[song.id] = song
                if self.seenSongs[song.id]?.hasSameContent(as: song) != true { changed.insert(song.id) }
            }
            self.seenSongs = seen
            self.scheduleSongScan(changed)
        }.store(in: &cancellables)
        library?.$playlists.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in self?.scheduleScan("playlist") }.store(in: &cancellables)
        ProgramStore.shared.$programs.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in self?.scheduleScan("program") }.store(in: &cancellables)
        AssistantService.shared.$messages.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in self?.scheduleScan("assistant") }.store(in: &cancellables)
        AssistantMemory.shared.$items.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in self?.scheduleScan("assistant") }.store(in: &cancellables)
        seenSummaries = LyricsSummaries.shared.entries
        LyricsSummaries.shared.$entries.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] entries in
            guard let self else { return }
            let changed = Set(entries.keys).union(self.seenSummaries.keys).filter { entries[$0] != self.seenSummaries[$0] }
            self.seenSummaries = entries
            self.scheduleSongScan(changed)
        }.store(in: &cancellables)
        SessionSyncDomain.shared.observePlayer { [weak self] in self?.scheduleScan("session", delay: 2) }

        // What isn't announced (singers, a music video choice, a lyrics file
        // edited in place): everything, now and then, quietly.
        scanTimer = Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleScan(nil, delay: 0) }
        }
    }

    private func flushInBackground() {
        guard let engine, isActive else { return }
        let task = UIApplication.shared.beginBackgroundTask(withName: "iCloud Sync")
        Task {
            await scanPending()
            persistNow()
            try? await engine.sendChanges()
            UIApplication.shared.endBackgroundTask(task)
        }
    }

    // MARK: Devices

    /// Makes this device the one whose data comes first.
    func makePrimary() {
        guard engine != nil else { return }
        setRegistrySection("primary", data: SyncValue.encode(["id": deviceID]))
        setDeviceSection { $0.isLinked = true }
        refreshRegistry()
        activateIfNeeded()
    }

    func setLinked(_ linked: Bool, device id: String) {
        guard engine != nil, var device = devices.first(where: { $0.id == id }) else { return }
        device.isLinked = linked
        setRegistrySection("device.\(id)", data: SyncValue.encode(device))
        refreshRegistry()
        activateIfNeeded()
    }

    private func heartbeat() {
        if let current = thisDevice, Date().timeIntervalSince(current.lastSeen) < 12 * 3600,
           current.name == SyncDevice.currentName { return }
        setDeviceSection { _ in }
    }

    private func setDeviceSection(_ change: (inout SyncDevice) -> Void) {
        var device = thisDevice ?? SyncDevice(id: deviceID, name: SyncDevice.currentName, kind: SyncDevice.currentKind, isLinked: false, lastSeen: Date())
        device.name = SyncDevice.currentName
        device.kind = SyncDevice.currentKind
        device.lastSeen = Date()
        change(&device)
        setRegistrySection("device.\(deviceID)", data: SyncValue.encode(device))
        refreshRegistry()
    }

    private func setRegistrySection(_ section: String, data: Data) {
        var entry = entries[Self.registryName] ?? Entry()
        entry.doc.sections[section] = SyncSection(data: data, modified: Date(), author: deviceID)
        entry.applied = true
        store(Self.registryName, entry)
        enqueueSave(Self.registryName)
    }

    private func refreshRegistry() {
        let sections = entries[Self.registryName]?.doc.sections ?? [:]
        primaryID = sections["primary"].flatMap { SyncValue.decode([String: String].self, from: $0.data) }?["id"]
        devices = sections.filter { $0.key.hasPrefix("device.") }
            .compactMap { SyncValue.decode(SyncDevice.self, from: $0.value.data) }
            .sorted { lhs, rhs in
                if (lhs.id == primaryID) != (rhs.id == primaryID) { return lhs.id == primaryID }
                return lhs.lastSeen > rhs.lastSeen
            }
    }

    /// Linked (or made main) just now: what this device had meets what the
    /// others have, then everything here goes up.
    private func activateIfNeeded() {
        let active = isActive
        defer { wasActive = active }
        guard active, !wasActive, hasFetched else {
            if !active && wasActive {
                // Unlinked: what comes later is taken as new when linked again.
                for name in entries.keys where name != Self.registryName { entries[name]?.applied = false }
            }
            return
        }
        Task {
            await firstContact()
            await scan(nil)
        }
    }

    private func firstContact() async {
        let names = entries.filter { $0.key != Self.registryName && !$0.value.applied }.map(\.key).sorted()
        var touched = Set<String>()
        for (offset, name) in names.enumerated() {
            guard let domain = domain(for: name) else { continue }
            if touched.insert(domain.prefix).inserted { domain.beginApplying() }
            reconcile(name, incoming: nil)
            if offset % 10 == 9 { await Task.yield() }
        }
        for prefix in touched { domains[prefix]?.endApplying() }
    }

    // MARK: Scanning

    /// Looks again at a whole kind of data (all of it with nil) a few
    /// seconds from now.
    func scheduleScan(_ prefix: String?, delay: TimeInterval = 6) {
        guard engine != nil, isActive else { return }
        if let prefix { pendingScan.insert(prefix) } else { pendingScan = Set(domains.keys) }
        startScanTask(delay: delay)
    }

    /// Looks again at these songs only.
    func scheduleSongScan(_ ids: Set<UUID>) {
        guard engine != nil, isActive, !ids.isEmpty else { return }
        pendingSongIDs.formUnion(ids)
        startScanTask(delay: 6)
    }

    private func startScanTask(delay: TimeInterval) {
        // Already on its way: frequent changes mustn't keep pushing it back.
        guard scanTask == nil else { return }
        scanTask = Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await scanPending()
        }
    }

    /// What changed since the last scan, now.
    private func scanPending() async {
        scanTask?.cancel()
        scanTask = nil
        let prefixes = pendingScan
        let ids = pendingSongIDs
        pendingScan = []
        pendingSongIDs = []
        guard !prefixes.isEmpty || !ids.isEmpty else { return }
        await scan(prefixes, songIDs: ids)
    }

    /// Reads what this device holds and sends what changed: everything
    /// (nil), whole kinds of data, or a few songs.
    private func scan(_ prefixes: Set<String>?, songIDs: Set<UUID> = []) async {
        guard engine != nil, isActive, hasFetched else { return }
        guard !isScanning else {
            // Comes back once this one is done.
            if let prefixes { pendingScan.formUnion(prefixes) } else { pendingScan = Set(domains.keys) }
            pendingSongIDs.formUnion(songIDs)
            startScanTask(delay: 2)
            return
        }
        isScanning = true
        defer { isScanning = false }
        if let library {
            let resolved = keys.refresh(songs: library.songs)
            if !resolved.isEmpty { resolvePlaceholders(resolved) }
        }
        if prefixes?.contains("song") != true, !songIDs.isEmpty, let domain = domains["song"] {
            domain.beginApplying()
            for (offset, id) in songIDs.enumerated() {
                guard let hash = keys.hash(for: id) else { continue }
                reconcile("song.\(hash)", incoming: nil)
                if offset % 10 == 9 { await Task.yield() }
            }
            domain.endApplying()
        }
        let order = ["song", "playlist", "program", "history", "import", "assistant", "settings", "secrets", "session"]
        for prefix in order where prefixes?.contains(prefix) ?? true {
            guard let domain = domains[prefix] else { continue }
            let names = domain.localDocuments()
            domain.beginApplying()
            for (offset, name) in names.enumerated() {
                reconcile(name, incoming: nil)
                if offset % 10 == 9 { await Task.yield() }
            }
            // Deleted here.
            if domain.propagatesDeletion {
                let present = Set(names)
                for (name, entry) in entries where entry.applied && self.prefix(of: name) == prefix && !present.contains(name) {
                    deleteEverywhere(name)
                }
            }
            domain.endApplying()
        }
        persistSoon()
    }

    private func domain(for name: String) -> SyncDomain? {
        domains[prefix(of: name)]
    }

    private func prefix(of name: String) -> String {
        name.split(separator: ".", maxSplits: 1).first.map(String.init) ?? name
    }

    private func deleteEverywhere(_ name: String) {
        entries[name] = nil
        removedEntries.insert(name)
        dirtyEntries.remove(name)
        engine?.state.add(pendingRecordZoneChanges: [.deleteRecord(CKRecord.ID(recordName: name, zoneID: zoneID))])
    }

    /// The heart of it: what this device holds for `name`, what the mirror
    /// had, and what came from iCloud become one document, written into the
    /// app where it changed and sent up when iCloud doesn't have it.
    private func reconcile(_ name: String, incoming: SyncDoc?) {
        var entry = entries[name] ?? Entry()
        if name == Self.registryName {
            if let incoming { entry.doc = merge(entry.doc, incoming, domain: nil) }
            entry.applied = true
            store(name, entry)
            refreshRegistry()
            if entry.serverHash != hash(of: entry.doc) { enqueueSave(name) }
            return
        }
        guard let domain = domain(for: name) else { return }

        guard isActive else {
            // Kept for when this device is linked.
            if let incoming { entry.doc = merge(entry.doc, incoming, domain: domain) }
            entry.applied = false
            store(name, entry)
            return
        }

        let snapshot = domain.snapshot(name)
        if snapshot == nil, entry.applied, domain.propagatesDeletion {
            // Deleted here since: that wins.
            deleteEverywhere(name)
            return
        }

        if snapshot == nil, incoming == nil, entry.applied {
            // Not on this device (a song it doesn't have): kept as is.
            entry.applied = false
            store(name, entry)
            return
        }

        let first = !entry.applied
        let base = entry.doc
        var mine = SyncDoc()
        if let snapshot {
            let now = Date()
            for (section, data) in snapshot.sections {
                if let known = base.sections[section], known.data == data {
                    mine.sections[section] = known
                } else {
                    let edited = !first && base.sections[section] != nil
                    mine.sections[section] = SyncSection(data: data, modified: edited || isPrimary ? now : Self.linkDate, author: deviceID)
                }
            }
            if !first {
                for (section, known) in base.sections where snapshot.sections[section] == nil {
                    if snapshot.skipped.contains(section) || known.data == SyncValue.null {
                        mine.sections[section] = known
                    } else {
                        mine.sections[section] = SyncSection(data: SyncValue.null, modified: now, author: deviceID)
                    }
                }
            }
        }

        var theirs = (first || snapshot == nil) ? base : SyncDoc()
        if let incoming { theirs = merge(theirs, incoming, domain: domain) }
        let merged = merge(mine, theirs, domain: domain)

        var toApply: [String: Data] = [:]
        for (section, value) in merged.sections where section != "ident" {
            let local = snapshot?.sections[section]
            if snapshot?.skipped.contains(section) == true, value.data == SyncValue.null { continue }
            if local != value.data, !(local == nil && value.data == SyncValue.null) {
                toApply[section] = value.data
            }
        }
        var applied = true
        if !toApply.isEmpty {
            applied = domain.apply(name, sections: toApply)
        } else if snapshot == nil {
            applied = false
        }
        let previous = entries[name]
        entry.doc = merged
        entry.applied = applied
        if entry != previous { store(name, entry) }
        guard !merged.sections.isEmpty, applied || incoming == nil else { return }
        if entry.serverHash == nil ? entry != previous || previous?.systemFields == nil : entry.serverHash != hash(of: merged) {
            enqueueSave(name)
        }
    }

    private func merge(_ local: SyncDoc, _ remote: SyncDoc, domain: SyncDomain?) -> SyncDoc {
        var result = local
        for (section, theirs) in remote.sections {
            guard let ours = local.sections[section] else {
                result.sections[section] = theirs
                continue
            }
            result.sections[section] = resolve(section, ours, theirs, domain: domain)
        }
        return result
    }

    private func resolve(_ section: String, _ ours: SyncSection, _ theirs: SyncSection, domain: SyncDomain?) -> SyncSection {
        if ours.data == theirs.data {
            return theirs.modified >= ours.modified ? theirs : ours
        }
        if ours.data != SyncValue.null, theirs.data != SyncValue.null,
           let merged = domain?.merge(section: section, local: ours.data, remote: theirs.data) {
            let author = merged == theirs.data ? theirs.author : (merged == ours.data ? ours.author : deviceID)
            return SyncSection(data: merged, modified: max(ours.modified, theirs.modified), author: author)
        }
        if ours.modified != theirs.modified { return ours.modified > theirs.modified ? ours : theirs }
        if ours.author == primaryID { return ours }
        if theirs.author == primaryID { return theirs }
        return ours.author > theirs.author ? ours : theirs
    }

    /// Songs another device had and this one now has too: what pointed to
    /// them here (stats, playlists…) points to the real song.
    private func resolvePlaceholders(_ resolved: [String: UUID]) {
        let replacements = Dictionary(uniqueKeysWithValues: resolved.map { (SyncSongKeys.placeholderID($0.key), $0.value) })
        ListeningStatsService.shared.replaceSongIDs(replacements)
        ImportedHistory.shared.replaceSongIDs(replacements)
        let tokens = resolved.keys.map { SyncSongKeys.tokenPrefix + $0 }
        for (name, entry) in entries where entry.applied {
            let prefix = prefix(of: name)
            guard prefix != "song", prefix != "history", prefix != "import", let domain = domains[prefix] else { continue }
            let sections = entry.doc.sections.filter { section in
                guard let text = String(data: section.value.data, encoding: .utf8) else { return false }
                return tokens.contains { text.contains($0) }
            }
            if !sections.isEmpty { _ = domain.apply(name, sections: sections.mapValues(\.data)) }
        }
        // Songs whose data waited for them.
        for hash in resolved.keys {
            let name = "song.\(hash)"
            if entries[name] != nil { reconcile(name, incoming: nil) }
        }
    }

    /// iCloud or this device already has the document.
    func isKnown(_ name: String) -> Bool {
        entries[name] != nil
    }

    /// Reads a part as this device last agreed on it (for G-counters).
    func agreedSection(_ name: String, _ section: String) -> Data? {
        entries[name]?.doc.sections[section]?.data
    }

    // MARK: Storage

    private func store(_ name: String, _ entry: Entry) {
        entries[name] = entry
        dirtyEntries.insert(name)
        removedEntries.remove(name)
    }

    /// Read off the main thread: there can be thousands, megabytes in all.
    private func loadEntries() async {
        let folder = Self.directory.appending(path: "Docs")
        let loaded = await Task.detached(priority: .userInitiated) { () -> [String: Entry] in
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            let decoder = JSONDecoder()
            var loaded: [String: Entry] = [:]
            for file in files where file.pathExtension == "json" {
                guard let data = try? Data(contentsOf: file), let entry = try? decoder.decode(Entry.self, from: data) else { continue }
                loaded[file.deletingPathExtension().lastPathComponent] = entry
            }
            return loaded
        }.value
        entries.merge(loaded) { current, _ in current }
    }

    private func persistSoon() {
        persistTask?.cancel()
        persistTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            persistNow()
        }
    }

    private func persistNow() {
        let folder = Self.directory.appending(path: "Docs")
        let written = dirtyEntries.compactMap { name in entries[name].map { (name, $0) } }
        let removed = removedEntries
        dirtyEntries = []
        removedEntries = []
        Task.detached(priority: .utility) {
            let encoder = JSONEncoder()
            for (name, entry) in written {
                if let data = try? encoder.encode(entry) {
                    try? data.write(to: folder.appending(path: name + ".json"), options: .atomic)
                }
            }
            for name in removed {
                try? FileManager.default.removeItem(at: folder.appending(path: name + ".json"))
            }
        }
    }

    private func saveEngineState(_ state: CKSyncEngine.State.Serialization) {
        let url = Self.directory.appending(path: "engine.json")
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(state) { try? data.write(to: url, options: .atomic) }
        }
    }

    private func hash(of doc: SyncDoc) -> String {
        SyncValue.hash(SyncValue.encode(doc))
    }

    private func enqueueSave(_ name: String) {
        engine?.state.add(pendingRecordZoneChanges: [.saveRecord(CKRecord.ID(recordName: name, zoneID: zoneID))])
        persistSoon()
    }

    // MARK: Records

    private func record(for id: CKRecord.ID) -> CKRecord? {
        let name = id.recordName
        guard let entry = entries[name] else { return nil }
        let record = entry.systemFields.flatMap(Self.record(fromSystemFields:)) ?? CKRecord(recordType: "Doc", recordID: id)
        let data = SyncValue.encode(entry.doc)
        sentDocs[name] = entry.doc
        if data.count < Self.inlineLimit {
            record.encryptedValues["doc"] = data
            record["asset"] = nil
        } else {
            let url = Self.outboxDirectory.appending(path: "\(name)-\(UUID().uuidString).json")
            guard (try? data.write(to: url)) != nil else { return nil }
            if let old = outbox[name] { try? FileManager.default.removeItem(at: old) }
            outbox[name] = url
            record.encryptedValues["doc"] = nil
            record["asset"] = CKAsset(fileURL: url)
        }
        return record
    }

    private static func doc(from record: CKRecord) -> SyncDoc? {
        if let data = record.encryptedValues["doc"] as? Data {
            return SyncValue.decode(SyncDoc.self, from: data)
        }
        if let asset = record["asset"] as? CKAsset, let url = asset.fileURL, let data = try? Data(contentsOf: url) {
            return SyncValue.decode(SyncDoc.self, from: data)
        }
        return nil
    }

    private static func systemFields(of record: CKRecord) -> Data {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archiver)
        archiver.finishEncoding()
        return archiver.encodedData
    }

    private static func record(fromSystemFields data: Data) -> CKRecord? {
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        unarchiver.requiresSecureCoding = true
        defer { unarchiver.finishDecoding() }
        return CKRecord(coder: unarchiver)
    }

    /// A document from iCloud (fetched, or newer than the one sent).
    private func receive(_ record: CKRecord) {
        let name = record.recordID.recordName
        guard let doc = Self.doc(from: record) else { return }
        var entry = entries[name] ?? Entry()
        entry.systemFields = Self.systemFields(of: record)
        entry.serverHash = hash(of: doc)
        entries[name] = entry
        if prefix(of: name) == "song", entries[name]?.applied != true, isActive, let renamed = adoptSong(name, doc: doc) {
            deleteEverywhere(renamed)
        }
        reconcile(name, incoming: doc)
    }

    /// A song another device knows under another key (renamed file, sent
    /// with Library Transfer): this device takes the other key, unless it's
    /// the main device.
    private func adoptSong(_ name: String, doc: SyncDoc) -> String? {
        guard !isPrimary, let songs = domains["song"] as? SongsSyncDomain else { return nil }
        let hash = String(name.dropFirst("song.".count))
        guard keys.id(forHash: hash) == nil,
              let identData = doc.sections["ident"]?.data,
              let ident = SyncValue.decode(SongsSyncDomain.Ident.self, from: identData),
              let song = songs.localSong(matching: ident),
              let oldHash = keys.hash(for: song.id) else { return nil }
        let oldName = "song.\(oldHash)"
        // Only a song nobody else has data for under its key here.
        if let other = entries[oldName], other.doc.sections.values.contains(where: { $0.author != deviceID }) { return nil }
        keys.rekey(song.id, to: ident.key)
        return entries[oldName] != nil ? oldName : nil
    }

    fileprivate func handle(_ event: CKSyncEngine.Event) async {
        switch event {
        case let .stateUpdate(update):
            saveEngineState(update.stateSerialization)

        case let .accountChange(change):
            switch change.changeType {
            case .signIn:
                break
            case .signOut, .switchAccounts:
                reset()
                if isEnabled { Task { await startEngine() } }
            @unknown default:
                break
            }

        case let .fetchedDatabaseChanges(changes):
            if changes.deletions.contains(where: { $0.zoneID == zoneID }) {
                // The iCloud data was deleted: start over from this device.
                for name in entries.keys {
                    entries[name]?.systemFields = nil
                    entries[name]?.serverHash = nil
                    entries[name]?.applied = false
                }
                engine?.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
                setDeviceSection { _ in }
            }

        case let .fetchedRecordZoneChanges(changes):
            var touched = Set<String>()
            for modification in changes.modifications {
                let prefix = prefix(of: modification.record.recordID.recordName)
                if touched.insert(prefix).inserted { domains[prefix]?.beginApplying() }
                receive(modification.record)
            }
            for deletion in changes.deletions {
                let name = deletion.recordID.recordName
                guard let entry = entries[name] else { continue }
                if entry.applied, isActive, let domain = domain(for: name), domain.propagatesDeletion {
                    if touched.insert(domain.prefix).inserted { domain.beginApplying() }
                    domain.remove(name)
                }
                entries[name] = nil
                removedEntries.insert(name)
            }
            for prefix in touched { domains[prefix]?.endApplying() }
            refreshRegistry()
            activateIfNeeded()
            persistSoon()

        case let .sentRecordZoneChanges(sent):
            for record in sent.savedRecords {
                let name = record.recordID.recordName
                // Read before its file (a large document's) is removed.
                let sentDoc = sentDocs.removeValue(forKey: name) ?? Self.doc(from: record)
                if let url = outbox.removeValue(forKey: name) { try? FileManager.default.removeItem(at: url) }
                guard var entry = entries[name] else { continue }
                entry.systemFields = Self.systemFields(of: record)
                entry.serverHash = sentDoc.map(hash(of:))
                entries[name] = entry
                dirtyEntries.insert(name)
                // Changed again while it was on its way.
                if sentDoc != entry.doc { enqueueSave(name) }
            }
            for failure in sent.failedRecordSaves {
                let name = failure.record.recordID.recordName
                switch failure.error.code {
                case .serverRecordChanged:
                    if let server = failure.error.serverRecord {
                        domain(for: name)?.beginApplying()
                        receive(server)
                        domain(for: name)?.endApplying()
                        enqueueSave(name)
                    }
                case .zoneNotFound:
                    engine?.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
                    enqueueSave(name)
                case .unknownItem:
                    entries[name]?.systemFields = nil
                    enqueueSave(name)
                case .quotaExceeded:
                    status = .failed(String(localized: "Your iCloud storage is full."))
                case .networkFailure, .networkUnavailable, .zoneBusy, .serviceUnavailable, .notAuthenticated, .operationCancelled, .requestRateLimited:
                    break
                default:
                    status = .failed(failure.error.localizedDescription)
                }
            }
            for id in sent.deletedRecordIDs {
                if let url = outbox.removeValue(forKey: id.recordName) { try? FileManager.default.removeItem(at: url) }
            }
            persistSoon()

        case let .sentDatabaseChanges(sent):
            for failure in sent.failedZoneSaves {
                status = .failed(Self.message(for: failure.error))
            }

        case .willFetchChanges, .willSendChanges:
            if case .upToDate = status { status = .syncing }

        case .didFetchChanges:
            hasFetched = true
            activateIfNeeded()
            markSynced()

        case .didSendChanges:
            markSynced()

        case .willFetchRecordZoneChanges, .didFetchRecordZoneChanges:
            break

        @unknown default:
            break
        }
    }

    fileprivate func nextBatch(_ context: CKSyncEngine.SendChangesContext, engine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let scope = context.options.scope
        let pending = engine.state.pendingRecordZoneChanges.filter { scope.contains($0) }
        guard !pending.isEmpty else { return nil }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: Array(pending.prefix(150))) { id in
            await self.record(for: id)
        }
    }

    private static func message(for error: Error) -> String {
        guard let error = error as? CKError else { return error.localizedDescription }
        switch error.code {
        case .notAuthenticated: return String(localized: "Sign in to iCloud in the Settings app to sync.")
        case .quotaExceeded: return String(localized: "Your iCloud storage is full.")
        case .networkFailure, .networkUnavailable: return String(localized: "No connection. Sync resumes on its own.")
        default: return error.localizedDescription
        }
    }

    // MARK: Resuming playback

    /// The "Playing on your …" banner, on by default (this device only).
    static let resumeOffersKey = "syncResumeOffers"

    /// Offers playback left on another device (once per offer).
    func offerResume(_ offer: SyncResumeOffer) {
        guard UserDefaults.standard.object(forKey: Self.resumeOffersKey) as? Bool ?? true,
              resumeOffer?.id != offer.id else { return }
        resumeOffer = offer
    }

    func resume(_ offer: SyncResumeOffer) {
        resumeOffer = nil
        let player = MusicPlayerService.shared
        player.play(at: offer.index, from: offer.songs)
        if offer.time > 5 { player.seek(to: offer.time) }
    }
}

extension CloudSync: CKSyncEngineDelegate {
    nonisolated func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        await handle(event)
    }

    nonisolated func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        await nextBatch(context, engine: syncEngine)
    }
}
