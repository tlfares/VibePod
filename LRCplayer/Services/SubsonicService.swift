import Foundation
import CryptoKit
import Security
import Combine

/// A self-hosted music server speaking the (Open)Subsonic API: Navidrome,
/// Gonic, Airsonic, Ampache… Its songs join the library as `.subsonic`
/// songs; they stream until the user downloads them.
@MainActor
final class SubsonicService: ObservableObject {
    static let shared = SubsonicService()

    enum State: Equatable {
        case signedOut
        case connecting
        case connected
        case failed(String)
    }

    @Published private(set) var state: State = .signedOut
    @Published private(set) var isSyncing = false
    @Published private(set) var syncStatus: String?
    @Published private(set) var lastSync: Date?
    @Published private(set) var serverDescription: String?

    weak var library: LibraryService?

    private static let serverKey = "subsonicServer"
    private static let userKey = "subsonicUser"
    private static let lastSyncKey = "subsonicLastSync"
    private static let serverDescriptionKey = "subsonicServerDescription"
    private static let apiVersion = "1.16.1"
    private static let clientName = "VibePod"
    /// The library refreshes on launch at most this often.
    private static let autoSyncInterval: TimeInterval = 6 * 3600
    static let playlistService = "subsonic"

    private(set) var serverURL: URL?
    private(set) var username: String?
    private var password: String?
    private var nowPlayingTask: Task<Void, Never>?
    private var lyricsChecked: Set<String> = []

    var isConfigured: Bool { serverURL != nil && username != nil && password != nil }

    /// The sign-in, for iCloud Sync.
    var syncCredentials: (server: String, user: String, password: String)? {
        guard let serverURL, let username, let password else { return nil }
        return (serverURL.absoluteString, username, password)
    }

    private init() {
        let defaults = UserDefaults.standard
        serverURL = defaults.string(forKey: Self.serverKey).flatMap(URL.init(string:))
        username = defaults.string(forKey: Self.userKey)
        password = Keychain.read()
        lastSync = defaults.object(forKey: Self.lastSyncKey) as? Date
        serverDescription = defaults.string(forKey: Self.serverDescriptionKey)
        if isConfigured { state = .connected }
    }

    /// At launch: a quiet refresh when the last one is old.
    func start(with library: LibraryService) {
        self.library = library
        guard isConfigured else { return }
        if let lastSync, Date().timeIntervalSince(lastSync) < Self.autoSyncInterval { return }
        Task { await sync() }
    }

    // MARK: - Account

    /// "demo.navidrome.org" → https://demo.navidrome.org
    static func normalizedServer(_ text: String) -> URL? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if !value.contains("://") { value = "https://" + value }
        while value.hasSuffix("/") { value.removeLast() }
        if value.lowercased().hasSuffix("/rest") { value.removeLast(5) }
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host != nil else { return nil }
        return url
    }

    func connect(server: String, username: String, password: String) async {
        guard let url = Self.normalizedServer(server) else {
            state = .failed(String(localized: "Check the server address."))
            return
        }
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        state = .connecting
        do {
            let response = try await Self.request("ping", server: url, username: user, password: password)
            serverURL = url
            self.username = user
            self.password = password
            let defaults = UserDefaults.standard
            defaults.set(url.absoluteString, forKey: Self.serverKey)
            defaults.set(user, forKey: Self.userKey)
            Keychain.write(password)
            serverDescription = Self.describe(response)
            defaults.set(serverDescription, forKey: Self.serverDescriptionKey)
            state = .connected
            await sync()
        } catch {
            state = .failed(Self.message(for: error))
        }
    }

    /// Forgets the server. Its songs, playlists and downloads leave the library.
    func disconnect() {
        SubsonicDownloads.shared.cancelAll()
        library?.removeSubsonicContent()
        SubsonicDownloads.shared.removeAllFiles()
        serverURL = nil
        username = nil
        password = nil
        lastSync = nil
        serverDescription = nil
        lyricsChecked = []
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: Self.serverKey)
        defaults.removeObject(forKey: Self.userKey)
        defaults.removeObject(forKey: Self.lastSyncKey)
        defaults.removeObject(forKey: Self.serverDescriptionKey)
        Keychain.write(nil)
        state = .signedOut
    }

    // MARK: - Sync

    func sync() async {
        guard isConfigured, !isSyncing, let library else { return }
        isSyncing = true
        syncStatus = String(localized: "Fetching songs…")
        defer {
            isSyncing = false
            syncStatus = nil
        }
        do {
            let entries = try await fetchAllSongs()
            let existing = Dictionary(
                library.songs.filter(\.isRemote).compactMap { song in song.remoteID.map { ($0, song) } },
                uniquingKeysWith: { first, _ in first }
            )
            var songs: [Song] = []
            var newSongs: [Song] = []
            for entry in entries {
                if var song = existing[entry.id] {
                    entry.apply(to: &song)
                    songs.append(song)
                } else {
                    var song = Song(fileURL: SubsonicDownloads.localURL(remoteID: entry.id, format: entry.suffix), source: .subsonic)
                    entry.apply(to: &song)
                    song.addedAt = entry.created ?? Date()
                    songs.append(song)
                    newSongs.append(song)
                }
            }
            // Covers once fetched at 900 px looked soft full screen: they
            // come again, once, at the size the app draws its largest.
            let defaults = UserDefaults.standard
            if defaults.integer(forKey: Self.coverSizeKey) < Self.coverSize {
                await fetchCovers(for: songs, replacing: true)
                defaults.set(Self.coverSize, forKey: Self.coverSizeKey)
            } else if !newSongs.isEmpty {
                await fetchCovers(for: newSongs, replacing: false)
            }
            syncStatus = String(localized: "Fetching playlists…")
            let playlists = (try? await fetchPlaylists()) ?? nil
            library.applySubsonicSync(songs: songs, playlists: playlists)
            lastSync = Date()
            UserDefaults.standard.set(lastSync, forKey: Self.lastSyncKey)
            state = .connected
        } catch {
            state = .failed(Self.message(for: error))
        }
    }

    private func fetchAllSongs() async throws -> [Entry] {
        // OpenSubsonic servers list every song for an empty search.
        var entries: [Entry] = []
        let page = 500
        while true {
            let response = try await call("search3", [
                "query": "", "songCount": "\(page)", "songOffset": "\(entries.count)",
                "albumCount": "0", "artistCount": "0"
            ])
            let batch = ((response["searchResult3"] as? [String: Any])?["song"] as? [[String: Any]] ?? []).compactMap(Entry.init)
            entries += batch
            syncStatus = String(localized: "Fetching songs… \(entries.count)")
            if batch.count < page { break }
        }
        if !entries.isEmpty { return entries }
        // Older servers: walk the albums.
        var albumIDs: [String] = []
        while true {
            let response = try await call("getAlbumList2", [
                "type": "alphabeticalByName", "size": "500", "offset": "\(albumIDs.count)"
            ])
            let batch = ((response["albumList2"] as? [String: Any])?["album"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
            albumIDs += batch
            if batch.count < 500 { break }
        }
        for (index, id) in albumIDs.enumerated() {
            syncStatus = String(localized: "Fetching albums… \(index + 1)/\(albumIDs.count)")
            let response = try await call("getAlbum", ["id": id])
            entries += ((response["album"] as? [String: Any])?["song"] as? [[String: Any]] ?? []).compactMap(Entry.init)
        }
        return entries
    }

    /// Pixel size covers are asked at: the largest the app decodes
    /// (`ArtworkImageCache`), so a full-screen cover stays sharp.
    private static let coverSize = 1500
    private static let coverSizeKey = "subsonicCoverSize"

    /// One cover per album, shared by its songs, before they show up.
    private func fetchCovers(for songs: [Song], replacing: Bool) async {
        var groups: [String: [Song]] = [:]
        for song in songs where song.remoteCoverID != nil {
            groups["\(song.albumArtist ?? song.artist)\u{1F}\(song.album)", default: []].append(song)
        }
        let jobs = groups.values.compactMap { group -> (String, [UUID])? in
            guard let cover = group.first?.remoteCoverID else { return nil }
            return (cover, group.map(\.id))
        }
        guard !jobs.isEmpty else { return }
        var done = 0
        syncStatus = String(localized: "Fetching covers… \(done)/\(jobs.count)")
        let urls = jobs.map { coverURL(for: $0.0, size: Self.coverSize) }
        await withTaskGroup(of: (Int, Data?).self) { group in
            var next = 0
            func add() {
                guard next < jobs.count else { return }
                let index = next
                let url = urls[index]
                next += 1
                group.addTask {
                    guard let url, let (data, response) = try? await URLSession.shared.data(from: url),
                          (response as? HTTPURLResponse)?.statusCode == 200,
                          (response.mimeType ?? "").hasPrefix("image") else { return (index, nil) }
                    return (index, data)
                }
            }
            for _ in 0..<6 { add() }
            for await (index, data) in group {
                if let data {
                    for id in jobs[index].1 {
                        if replacing { ArtworkStore.replace(data, for: id) } else { ArtworkStore.store(data, for: id) }
                    }
                }
                done += 1
                syncStatus = String(localized: "Fetching covers… \(done)/\(jobs.count)")
                add()
            }
        }
    }

    private func fetchPlaylists() async throws -> [RemotePlaylist] {
        let response = try await call("getPlaylists", [:])
        let list = (response["playlists"] as? [String: Any])?["playlist"] as? [[String: Any]] ?? []
        var result: [RemotePlaylist] = []
        for item in list {
            guard let id = item["id"] as? String else { continue }
            let detail = try await call("getPlaylist", ["id": id])
            let playlist = detail["playlist"] as? [String: Any] ?? item
            let songIDs = (playlist["entry"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
            result.append(RemotePlaylist(
                id: id,
                name: playlist["name"] as? String ?? item["name"] as? String ?? "",
                comment: playlist["comment"] as? String ?? "",
                songIDs: songIDs
            ))
        }
        return result
    }

    // MARK: - Playback

    func streamURL(for song: Song) -> URL? {
        guard let remoteID = song.remoteID else { return nil }
        return url("stream", ["id": remoteID, "estimateContentLength": "true"])
    }

    func downloadURL(for remoteID: String) -> URL? {
        url("download", ["id": remoteID])
    }

    func coverURL(for coverID: String, size: Int) -> URL? {
        url("getCoverArt", ["id": coverID, "size": "\(size)"])
    }

    /// A song started: the server shows it as now playing.
    func songDidStart(_ song: Song) {
        guard song.isRemote, isConfigured, let remoteID = song.remoteID else { return }
        nowPlayingTask?.cancel()
        nowPlayingTask = Task { _ = try? await call("scrobble", ["id": remoteID, "submission": "false"]) }
        fetchLyricsIfNeeded(for: song)
    }

    /// A song counted as played (same rule as the stats).
    func songWasPlayed(_ song: Song, at date: Date = Date()) {
        guard song.isRemote, isConfigured, let remoteID = song.remoteID else { return }
        let time = String(Int64(date.timeIntervalSince1970 * 1000))
        Task { _ = try? await call("scrobble", ["id": remoteID, "submission": "true", "time": time]) }
    }

    /// The server's synced lyrics, when the song has none yet.
    private func fetchLyricsIfNeeded(for song: Song) {
        guard song.lrcFilePath == nil, let remoteID = song.remoteID, !lyricsChecked.contains(remoteID) else { return }
        lyricsChecked.insert(remoteID)
        Task {
            guard let response = try? await call("getLyricsBySongId", ["id": remoteID]),
                  let lyrics = Self.lrc(from: response),
                  let library, let current = library.song(withID: song.id), current.lrcFilePath == nil else { return }
            let url = library.lyricsDirectory.appendingPathComponent("server-\(Self.safeFileName(remoteID))").appendingPathExtension("lrc")
            guard (try? lyrics.write(to: url, atomically: true, encoding: .utf8)) != nil else { return }
            library.setLyricsPath(library.storedLyricsPath(for: url.path), for: song.id)
        }
    }

    /// OpenSubsonic `structuredLyrics`: the first synced set, as LRC.
    private static func lrc(from response: [String: Any]) -> String? {
        let sets = (response["lyricsList"] as? [String: Any])?["structuredLyrics"] as? [[String: Any]] ?? []
        guard let synced = sets.first(where: { ($0["synced"] as? Bool) == true }),
              let lines = synced["line"] as? [[String: Any]], !lines.isEmpty else { return nil }
        let offset = (synced["offset"] as? Double) ?? 0
        let body = lines.compactMap { line -> String? in
            guard let start = (line["start"] as? Double) ?? (line["start"] as? Int).map(Double.init) else { return nil }
            let ms = max(0, start + offset)
            let minutes = Int(ms) / 60_000
            let seconds = (ms - Double(minutes * 60_000)) / 1000
            return String(format: "[%02d:%05.2f]", minutes, seconds) + ((line["value"] as? String) ?? "")
        }
        return body.isEmpty ? nil : body.joined(separator: "\n")
    }

    private static func safeFileName(_ value: String) -> String {
        String(value.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" })
    }

    // MARK: - Requests

    private func url(_ endpoint: String, _ parameters: [String: String]) -> URL? {
        guard let serverURL, let username, let password else { return nil }
        return Self.url(endpoint, server: serverURL, username: username, password: password, parameters: parameters)
    }

    private func call(_ endpoint: String, _ parameters: [String: String]) async throws -> [String: Any] {
        guard let serverURL, let username, let password else { throw SubsonicError.notConfigured }
        return try await Self.request(endpoint, server: serverURL, username: username, password: password, parameters: parameters)
    }

    /// Token auth: md5(password + salt), a new salt each time. The password
    /// never travels.
    private static func url(_ endpoint: String, server: URL, username: String, password: String, parameters: [String: String]) -> URL? {
        let salt = String((0..<12).map { _ in "abcdefghijklmnopqrstuvwxyz0123456789".randomElement()! })
        let token = Insecure.MD5.hash(data: Data((password + salt).utf8)).map { String(format: "%02x", $0) }.joined()
        var components = URLComponents(url: server.appendingPathComponent("rest").appendingPathComponent("\(endpoint).view"), resolvingAgainstBaseURL: false)
        var items = [
            URLQueryItem(name: "u", value: username),
            URLQueryItem(name: "t", value: token),
            URLQueryItem(name: "s", value: salt),
            URLQueryItem(name: "v", value: apiVersion),
            URLQueryItem(name: "c", value: clientName),
            URLQueryItem(name: "f", value: "json")
        ]
        items += parameters.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        components?.queryItems = items
        return components?.url
    }

    private static func request(_ endpoint: String, server: URL, username: String, password: String, parameters: [String: String] = [:]) async throws -> [String: Any] {
        guard let url = url(endpoint, server: server, username: username, password: password, parameters: parameters) else {
            throw SubsonicError.badAddress
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw SubsonicError.unreachable
        }
        guard let http = response as? HTTPURLResponse else { throw SubsonicError.unreachable }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let body = object["subsonic-response"] as? [String: Any] else {
            throw http.statusCode == 200 ? SubsonicError.notSubsonic : SubsonicError.http(http.statusCode)
        }
        if body["status"] as? String != "ok" {
            let error = body["error"] as? [String: Any]
            let code = error?["code"] as? Int ?? 0
            throw SubsonicError.server(code: code, message: error?["message"] as? String ?? "")
        }
        return body
    }

    private static func describe(_ response: [String: Any]) -> String? {
        let type = (response["type"] as? String).map { $0.prefix(1).uppercased() + $0.dropFirst() }
        let version = response["serverVersion"] as? String
        switch (type, version) {
        case let (type?, version?): return "\(type) \(version.split(separator: " ").first ?? "")"
        case let (type?, nil): return type
        default: return nil
        }
    }

    private static func message(for error: Error) -> String {
        switch error as? SubsonicError {
        case .badAddress?: String(localized: "Check the server address.")
        case .unreachable?: String(localized: "Couldn't reach the server.")
        case .notSubsonic?: String(localized: "This address doesn't answer like a Subsonic server.")
        case let .http(code)?: String(localized: "The server answered with error \(code).")
        case let .server(code, message)?:
            code == 40 || code == 41 ? String(localized: "Wrong username or password.")
                : (message.isEmpty ? String(localized: "The server refused the request.") : message)
        case .notConfigured?, nil: String(localized: "Couldn't reach the server.")
        }
    }

    // MARK: - Models

    private enum SubsonicError: Error {
        case badAddress, unreachable, notSubsonic, notConfigured
        case http(Int)
        case server(code: Int, message: String)
    }

    struct RemotePlaylist {
        let id: String
        let name: String
        let comment: String
        let songIDs: [String]
    }

    private struct Entry {
        let id: String
        let title: String
        let artist: String
        let album: String
        let albumArtist: String?
        let genre: String
        let duration: TimeInterval
        let track: Int
        let disc: Int
        let year: Int
        let size: Int64
        let suffix: String
        let coverArt: String?
        let created: Date?

        init?(_ json: [String: Any]) {
            guard let id = json["id"] as? String, (json["isDir"] as? Bool) != true else { return nil }
            if let type = json["type"] as? String, type != "music" { return nil }
            self.id = id
            title = json["title"] as? String ?? "Unknown Title"
            artist = (json["displayArtist"] as? String) ?? (json["artist"] as? String) ?? "Unknown Artist"
            album = json["album"] as? String ?? "Unknown Album"
            let albumArtist = (json["displayAlbumArtist"] as? String) ?? ((json["albumArtists"] as? [[String: Any]])?.first?["name"] as? String)
            self.albumArtist = albumArtist?.isEmpty == false ? albumArtist : nil
            genre = (json["genre"] as? String) ?? ((json["genres"] as? [[String: Any]])?.first?["name"] as? String) ?? ""
            duration = (json["duration"] as? Double) ?? 0
            track = json["track"] as? Int ?? 0
            disc = json["discNumber"] as? Int ?? 0
            year = json["year"] as? Int ?? 0
            size = (json["size"] as? NSNumber)?.int64Value ?? 0
            suffix = (json["suffix"] as? String)?.lowercased() ?? "mp3"
            coverArt = json["coverArt"] as? String
            created = (json["created"] as? String).flatMap(Self.parseDate)
        }

        private static func parseDate(_ text: String) -> Date? {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: text) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: text)
        }

        func apply(to song: inout Song) {
            song.remoteID = id
            song.remoteCoverID = coverArt
            song.title = title
            song.artist = artist
            song.album = album
            song.albumArtist = albumArtist
            song.genre = genre
            song.duration = duration
            song.trackNumber = track
            song.discNumber = disc
            song.year = year
            song.fileSize = size
            song.format = suffix
            song.source = .subsonic
            song.fileURL = SubsonicDownloads.localURL(remoteID: id, format: suffix)
        }
    }

    private enum Keychain {
        private static var query: [String: Any] { [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "VibePod.Subsonic",
            kSecAttrAccount as String: "password"
        ] }

        static func read() -> String? {
            var request = query
            request[kSecReturnData as String] = true
            request[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
                  let data = result as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        }

        static func write(_ value: String?) {
            SecItemDelete(query as CFDictionary)
            guard let value else { return }
            var item = query
            item[kSecValueData as String] = Data(value.utf8)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(item as CFDictionary, nil)
        }
    }
}

// MARK: - Downloads

/// Songs the user chose to keep on the device. Nothing downloads on its own.
@MainActor
final class SubsonicDownloads: ObservableObject {
    static let shared = SubsonicDownloads()

    /// Queued (0) or downloading songs, by song ID.
    @Published private(set) var progress: [UUID: Double] = [:]
    /// Bumps when a download lands or goes, so views re-read the disk.
    @Published private(set) var revision = 0

    private var waiting: [Song] = []
    private var running: [UUID: Task<Void, Never>] = [:]
    private var tasks: [UUID: URLSessionTask] = [:]
    private var progressTimer: Timer?
    private let maxConcurrent = 3

    nonisolated static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var dir = base.appendingPathComponent("Server Downloads", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            // They can be downloaded again: keep them out of backups.
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? dir.setResourceValues(values)
        }
        return dir
    }()

    nonisolated static func localURL(remoteID: String, format: String) -> URL {
        let name = String(remoteID.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" })
        return directory.appendingPathComponent(name).appendingPathExtension(format.isEmpty ? "mp3" : format)
    }

    func isPending(_ song: Song) -> Bool { progress[song.id] != nil }

    /// For a feature that reads the whole file (AI lyrics, Sing Along, a
    /// lyrics video): a streamed song is downloaded first, or its download
    /// already under way is waited for. True once the file is on disk.
    func ensureLocal(_ song: Song) async -> Bool {
        if song.hasLocalAudio { return true }
        guard song.isRemote else { return false }
        download([song])
        for await pending in $progress.values where pending[song.id] == nil { break }
        return song.isDownloaded
    }

    func download(_ songs: [Song]) {
        let fresh = songs.filter { $0.isRemote && !$0.isDownloaded && progress[$0.id] == nil }
        guard !fresh.isEmpty else { return }
        for song in fresh { progress[song.id] = 0 }
        waiting += fresh
        pump()
    }

    func cancel(_ songs: [Song]) {
        let ids = Set(songs.map(\.id))
        waiting.removeAll { ids.contains($0.id) }
        for id in ids {
            running[id]?.cancel()
            tasks[id]?.cancel()
            running[id] = nil
            tasks[id] = nil
            progress[id] = nil
        }
        pump()
    }

    func cancelAll() {
        for (id, task) in running { task.cancel(); tasks[id]?.cancel() }
        running = [:]
        tasks = [:]
        progress = [:]
        waiting = []
    }

    func removeDownloads(_ songs: [Song]) {
        cancel(songs)
        for song in songs where song.isRemote {
            try? FileManager.default.removeItem(at: song.playableFileURL)
        }
        revision += 1
    }

    func removeAllFiles() {
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.directory, includingPropertiesForKeys: nil)) ?? []
        files.forEach { try? FileManager.default.removeItem(at: $0) }
        revision += 1
    }

    /// Space the downloads take.
    var totalBytes: Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
    }

    var downloadedCount: Int {
        ((try? FileManager.default.contentsOfDirectory(atPath: Self.directory.path)) ?? []).filter { !$0.hasPrefix(".") }.count
    }

    private func pump() {
        while running.count < maxConcurrent, !waiting.isEmpty {
            let song = waiting.removeFirst()
            start(song)
        }
        if running.isEmpty {
            progressTimer?.invalidate()
            progressTimer = nil
        } else if progressTimer == nil {
            progressTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { _ in
                MainActor.assumeIsolated { SubsonicDownloads.shared.updateProgress() }
            }
        }
    }

    private func updateProgress() {
        for (id, task) in tasks {
            let expected = task.countOfBytesExpectedToReceive
            guard expected > 0 else { continue }
            let value = min(0.99, Double(task.countOfBytesReceived) / Double(expected))
            if abs((progress[id] ?? 0) - value) > 0.005 { progress[id] = value }
        }
    }

    private func start(_ song: Song) {
        guard let remoteID = song.remoteID, let url = SubsonicService.shared.downloadURL(for: remoteID) else {
            progress[song.id] = nil
            return
        }
        let id = song.id
        let destination = song.playableFileURL
        let grabber = TaskGrabber { task in
            Task { @MainActor in
                guard SubsonicDownloads.shared.running[id] != nil else { task.cancel(); return }
                SubsonicDownloads.shared.tasks[id] = task
            }
        }
        running[id] = Task {
            var succeeded = false
            do {
                let (temporary, response) = try await URLSession.shared.download(from: url, delegate: grabber)
                let mime = response.mimeType ?? ""
                if (response as? HTTPURLResponse)?.statusCode == 200, !mime.contains("json"), !mime.contains("xml") {
                    try? FileManager.default.removeItem(at: destination)
                    try FileManager.default.moveItem(at: temporary, to: destination)
                    succeeded = true
                } else {
                    try? FileManager.default.removeItem(at: temporary)
                }
            } catch {}
            self.finish(id, succeeded: succeeded, title: song.title)
        }
    }

    private func finish(_ id: UUID, succeeded: Bool, title: String) {
        let wasCancelled = running[id] == nil
        running[id] = nil
        tasks[id] = nil
        progress[id] = nil
        if succeeded { revision += 1 }
        if !succeeded, !wasCancelled {
            SubsonicService.shared.library?.lastError = String(localized: "Couldn't download “\(title)”")
        }
        pump()
    }

    private final class TaskGrabber: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        let onCreate: @Sendable (URLSessionTask) -> Void
        init(onCreate: @escaping @Sendable (URLSessionTask) -> Void) { self.onCreate = onCreate }
        func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) { onCreate(task) }
    }
}
