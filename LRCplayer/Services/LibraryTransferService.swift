import AVFoundation
import Combine
import Compression
import zlib
import MultipeerConnectivity
import UIKit
import UniformTypeIdentifiers

/// Sends songs to another device running VibePod over the local network
/// (Wi-Fi, or peer-to-peer Wi-Fi like AirDrop): the audio, its tags, artwork,
/// play history and lyrics. The receiver first says which songs it already
/// holds, so sending again only sends what's new there, or was deleted since.
@MainActor
final class LibraryTransferService: NSObject, ObservableObject {
    static let shared = LibraryTransferService()

    enum State: Equatable {
        case idle
        /// Sender: looking for devices with the Receive page open.
        case browsing
        /// Receiver: visible to the sender.
        case advertising
        /// Waiting for the other device to accept, then for its list.
        case connecting(peer: String)
        case transferring(peer: String)
        case finished(Summary)
        case failed(String)
        /// Writing or reading a zip file.
        case archiving(isExport: Bool)

        var isActive: Bool {
            switch self {
            case .connecting, .transferring, .archiving: true
            default: false
            }
        }
    }

    struct Summary: Equatable {
        enum Mode { case nearby, export, `import` }
        var peer: String
        var isSender: Bool
        var mode: Mode = .nearby
        var content: TransferContent = .all
        /// Songs that went with their audio.
        var transferred: Int
        /// Songs already there that got lyrics or stats.
        var updated = 0
        /// Selected, but already on the receiver.
        var alreadyThere: Int
        /// Lyrics or stats for songs the receiver doesn't have.
        var notThere = 0
        var failed: Int
    }

    struct Peer: Identifiable, Equatable {
        let id: MCPeerID
        var name: String { id.displayName }
        /// "iPhone", "iPad", from the other device's advertisement.
        let model: String
    }

    struct Invitation: Identifiable {
        let id = UUID()
        let peer: String
        let songCount: Int
        let content: TransferContent
        fileprivate let respond: (Bool) -> Void
    }

    struct Progress: Equatable {
        var completed = 0
        var total = 0
        var current: Song?
        /// Of the file on its way.
        var fileFraction = 0.0

        var fraction: Double {
            total > 0 ? min((Double(completed) + fileFraction) / Double(total), 1) : 0
        }
    }

    @Published private(set) var state: State = .idle {
        didSet { holdDeviceAwake(state.isActive) }
    }
    @Published private(set) var peers: [Peer] = []
    @Published var invitation: Invitation?
    @Published private(set) var progress = Progress()
    /// The zip the last export wrote, until it's saved or shared.
    @Published private(set) var exportedArchive: URL?

    nonisolated static let serviceType = "lrcplayer-xfer"

    private let peerID = MCPeerID(displayName: UIDevice.current.name)
    private var session: MCSession?
    private var browser: MCNearbyServiceBrowser?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var connectedPeer: MCPeerID?
    private var fileProgress: NSKeyValueObservation?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    // Sending
    private var selection: [Song] = []
    private var content: TransferContent = .all
    private var sendTask: Task<Void, Never>?
    private var sendSummary: Summary?

    // Receiving
    private var incoming: [UUID: TransferredSong] = [:]
    private var incomingFiles: [UUID: URL] = [:]
    /// The songs the sender says it sent, once it's done.
    private var expectedIDs: Set<UUID>?
    private var resolvedIDs = Set<UUID>()
    private var receivedCount = 0
    private var updatedCount = 0
    private var failedCount = 0
    private var incomingContent: TransferContent = .all
    /// Plays and replayed lines that came in, written at the end in one go.
    private var pendingHistory: [ListeningStatsEntry] = []
    private var pendingReplays: [String: Int] = [:]
    private var matchIndex: [String: [Song]]?

    private var library: LibraryService { AppModel.shared.libraryService }

    /// This device sends (rather than receives) the current transfer.
    var isSending: Bool { !selection.isEmpty }

    // MARK: - Sending

    /// Starts looking for receivers; `songs` go to the one picked.
    func startSending(_ songs: [Song], content: TransferContent) {
        reset()
        selection = songs
        self.content = content
        let browser = MCNearbyServiceBrowser(peer: peerID, serviceType: Self.serviceType)
        browser.delegate = self
        browser.startBrowsingForPeers()
        self.browser = browser
        state = .browsing
    }

    func send(to peer: Peer) {
        guard case .browsing = state, let browser else { return }
        let session = makeSession()
        let context = try? JSONEncoder().encode(InvitationContext(songCount: selection.count, content: content))
        browser.invitePeer(peer.id, to: session, withContext: context, timeout: 60)
        state = .connecting(peer: peer.name)
    }

    private func didReceiveManifest(_ manifest: TransferManifest, from peer: MCPeerID) {
        guard sendTask == nil else { return }
        let missing = manifest.missing(from: selection)
        let missingIDs = Set(missing.map(\.id))
        let present = selection.filter { !missingIDs.contains($0.id) }
        let songs = content.contains(.audio) ? missing : []
        let updates = content.subtracting(.audio).isEmpty ? [] : present
        var summary = Summary(peer: peer.displayName, isSender: true, content: content, transferred: 0, alreadyThere: 0, failed: 0)
        if content.contains(.audio) {
            summary.alreadyThere = updates.isEmpty ? present.count : 0
        } else {
            summary.notThere = missing.count
        }
        state = .transferring(peer: peer.displayName)
        progress = Progress(total: songs.count + updates.count)
        sendTask = Task { await send(songs, updates: updates, to: peer, summary: summary) }
    }

    private func send(_ songs: [Song], updates: [Song], to peer: MCPeerID, summary: Summary) async {
        var summary = summary
        var sent: [UUID] = []
        var failed = 0
        let outbox = Self.workDirectory("Outbox")
        defer { try? FileManager.default.removeItem(at: outbox) }
        let stats = content.contains(.stats) ? StatsIndex() : nil

        try? message(.begin(count: songs.count + updates.count), to: peer)
        // Lyrics and stats for songs it has: small, they go first.
        for song in updates {
            guard !Task.isCancelled, session != nil else { return }
            progress.current = song
            do {
                try message(.update(transferred(song, fileExtension: nil, stats: stats)), to: peer)
                sent.append(song.id)
                summary.updated += 1
            } catch {
                guard session != nil, !Task.isCancelled else { return }
                failed += 1
            }
            progress.completed += 1
            await Task.yield()
        }
        for song in songs {
            guard !Task.isCancelled, session != nil else { return }
            progress.current = song
            progress.fileFraction = 0
            do {
                let file = try await Self.audioFile(for: song, in: outbox)
                defer { if file.isCopy { try? FileManager.default.removeItem(at: file.url) } }
                try message(.song(transferred(song, fileExtension: file.url.pathExtension, stats: stats)), to: peer)
                try await sendResource(at: file.url, named: song.id.uuidString, to: peer)
                sent.append(song.id)
                summary.transferred += 1
            } catch {
                guard session != nil, !Task.isCancelled else { return }
                failed += 1
            }
            progress.completed += 1
            progress.fileFraction = 0
        }
        summary.failed = failed
        sendSummary = summary
        // The receiver answers once everything is in its library, then hangs up.
        try? message(.end(sent: sent), to: peer)
    }

    /// What travels ahead of the song's audio, or alone (no file extension)
    /// for a song the other side has.
    private func transferred(_ song: Song, fileExtension: String?, stats: StatsIndex?) -> TransferredSong {
        let lyricsURL = content.contains(.lyrics) ? library.resolvedLyricsURL(for: song) : nil
        let hasStats = content.contains(.stats)
        return TransferredSong(
            originID: song.id,
            title: song.title,
            artist: song.artist,
            album: song.album,
            albumArtist: song.albumArtist,
            genre: song.genre,
            duration: song.duration,
            trackNumber: song.trackNumber,
            discNumber: song.discNumber,
            year: song.year,
            addedAt: song.addedAt,
            lastPlayedAt: hasStats ? song.lastPlayedAt : nil,
            playCount: hasStats ? song.playCount : 0,
            fileExtension: fileExtension ?? "",
            artwork: fileExtension == nil ? nil : song.artworkData,
            lyrics: lyricsURL.flatMap { try? Data(contentsOf: $0) },
            lyricsExtension: lyricsURL?.pathExtension,
            lyricsGenerated: LyricsGenerator.isGenerated(storedPath: song.lrcFilePath),
            wordSync: lyricsURL == nil ? nil : WordSyncStore.rawData(for: song.id),
            hasStats: hasStats,
            history: hasStats ? stats?.history[song.id] : nil,
            replayed: hasStats ? stats?.replayed(for: song.id) : nil
        )
    }

    private func sendResource(at url: URL, named name: String, to peer: MCPeerID) async throws {
        guard let session else { throw CancellationError() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let progress = session.sendResource(at: url, withName: name, toPeer: peer) { @Sendable error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
            observeFileProgress(progress)
        }
    }

    /// Songs from the Music library are read out of it (as they were synced,
    /// re-encoded only when their format can't be copied as is); the app's
    /// own files go as they are.
    nonisolated private static func audioFile(for song: Song, in directory: URL) async throws -> (url: URL, isCopy: Bool) {
        guard song.isMediaLibraryItem else {
            let url = song.playableFileURL
            guard FileManager.default.fileExists(atPath: url.path) else { throw TransferError.unreadable }
            return (url, false)
        }
        let asset = AVURLAsset(url: song.fileURL)
        // ipod-library://item/item.mp3?id=… names the synced file's format.
        let original = song.fileURL.pathExtension.lowercased()
        for preset in [AVAssetExportPresetPassthrough, AVAssetExportPresetAppleM4A] {
            guard let export = AVAssetExportSession(asset: asset, presetName: preset) else { continue }
            let supported = export.supportedFileTypes
            let preferred: [AVFileType] = [.m4a, .mp3, .aiff, .wav, .caf]
            let ordered = preferred.filter { UTType($0.rawValue)?.preferredFilenameExtension == original } + preferred
            guard let fileType = ordered.first(where: supported.contains),
                  let fileExtension = UTType(fileType.rawValue)?.preferredFilenameExtension else { continue }
            let destination = directory.appendingPathComponent(song.id.uuidString).appendingPathExtension(fileExtension)
            try? FileManager.default.removeItem(at: destination)
            do {
                try await export.export(to: destination, as: fileType)
                return (destination, true)
            } catch {
                continue
            }
        }
        throw TransferError.unreadable
    }

    // MARK: - Receiving

    /// Makes this device visible to senders.
    func startReceiving() {
        reset()
        let advertiser = MCNearbyServiceAdvertiser(peer: peerID, discoveryInfo: ["model": UIDevice.current.model], serviceType: Self.serviceType)
        advertiser.delegate = self
        advertiser.startAdvertisingPeer()
        self.advertiser = advertiser
        state = .advertising
    }

    private func didReceiveInvitation(from peer: MCPeerID, context: Data?, handler: @escaping (Bool, MCSession?) -> Void) {
        guard case .advertising = state, invitation == nil else {
            handler(false, nil)
            return
        }
        let decoded = context.flatMap { try? JSONDecoder().decode(InvitationContext.self, from: $0) }
        let count = decoded?.songCount ?? 0
        let content = decoded?.content ?? .all
        invitation = Invitation(peer: peer.displayName, songCount: count, content: content) { [weak self] accepted in
            guard let self else { return }
            self.invitation = nil
            guard accepted, case .advertising = self.state else {
                handler(false, nil)
                return
            }
            handler(true, self.makeSession())
            self.incomingContent = content
            self.state = .connecting(peer: peer.displayName)
        }
    }

    /// Everything the sender doesn't need to send.
    private func manifest() -> TransferManifest {
        var origins = Self.loadOrigins()
        let ids = Set(library.songs.map(\.id))
        // Songs deleted here since are sent again.
        origins = origins.filter { ids.contains($0.value) }
        Self.saveOrigins(origins)
        return TransferManifest(
            origins: Set(origins.keys),
            songs: library.songs.map {
                TransferManifest.Entry(key: MediaLibraryReconciler.matchKey(title: $0.title, artist: $0.artist, album: $0.album), duration: $0.duration)
            }
        )
    }

    private func didReceiveFile(named name: String, at url: URL?) {
        guard let id = UUID(uuidString: name), !resolvedIDs.contains(id) else { return }
        guard let url else {
            incoming[id] = nil
            resolve(id, song: nil)
            return
        }
        incomingFiles[id] = url
        importIfComplete(id)
    }

    private func importIfComplete(_ id: UUID) {
        guard let song = incoming[id], let file = incomingFiles[id] else { return }
        incoming[id] = nil
        incomingFiles[id] = nil
        let imported = try? importSong(song, from: file)
        if imported == nil { try? FileManager.default.removeItem(at: file) }
        resolve(id, song: imported)
    }

    private func resolve(_ id: UUID, song: Song?, updated: Bool = false) {
        resolvedIDs.insert(id)
        if let song {
            if updated { updatedCount += 1 } else { receivedCount += 1 }
            progress.current = song
        } else {
            failedCount += 1
        }
        progress.completed = resolvedIDs.count
        progress.fileFraction = 0
        finishReceivingIfDone()
    }

    /// Adds a received song to the library, in Documents/Music/Received
    /// (left out of the scan for files copied in with Finder).
    private func importSong(_ transferred: TransferredSong, from file: URL) throws -> Song {
        let fileManager = FileManager.default
        let folder = library.musicDirectory.appendingPathComponent("Received", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = Self.fileName("\(transferred.artist) - \(transferred.title)")
        let fileExtension = transferred.fileExtension.isEmpty ? "m4a" : transferred.fileExtension
        var destination = folder.appendingPathComponent(name).appendingPathExtension(fileExtension)
        var counter = 2
        while fileManager.fileExists(atPath: destination.path) {
            destination = folder.appendingPathComponent("\(name) \(counter)").appendingPathExtension(fileExtension)
            counter += 1
        }
        try fileManager.moveItem(at: file, to: destination)

        let fileSize = (try? destination.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        var song = Song(
            title: transferred.title,
            artist: transferred.artist,
            album: transferred.album,
            albumArtist: transferred.albumArtist,
            genre: transferred.genre,
            duration: transferred.duration,
            fileURL: destination,
            artworkData: transferred.artwork,
            addedAt: transferred.addedAt,
            lastPlayedAt: transferred.lastPlayedAt,
            playCount: transferred.playCount,
            trackNumber: transferred.trackNumber,
            discNumber: transferred.discNumber,
            year: transferred.year,
            fileSize: Int64(fileSize),
            format: fileExtension.lowercased(),
            source: .appFile
        )
        storeLyrics(transferred, for: &song)
        if transferred.hasStats { queueStats(transferred, as: song.id) }
        library.addSong(song)
        matchIndex = nil

        var origins = Self.loadOrigins()
        origins[transferred.originID] = song.id
        Self.saveOrigins(origins)
        return song
    }

    private func finishReceivingIfDone() {
        guard let expectedIDs, expectedIDs.isSubset(of: resolvedIDs),
              let connectedPeer, case .transferring = state else { return }
        flushStats()
        try? message(.received, to: connectedPeer)
        state = .finished(Summary(peer: connectedPeer.displayName, isSender: false, content: incomingContent, transferred: receivedCount, updated: updatedCount, alreadyThere: 0, failed: failedCount))
    }

    // MARK: - Lyrics and stats

    /// Writes the lyrics that came with a song (and their word sync), unless
    /// it already has exactly these.
    private func storeLyrics(_ transferred: TransferredSong, for song: inout Song) {
        guard let lyrics = transferred.lyrics else { return }
        let current = library.resolvedLyricsURL(for: song).flatMap { try? Data(contentsOf: $0) }
        if current != lyrics {
            let fileManager = FileManager.default
            var folder = library.lyricsDirectory
            if transferred.lyricsGenerated {
                folder.appendPathComponent(LyricsGenerator.folderName, isDirectory: true)
            }
            try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = library.ownLyricsURL(for: song, in: folder)
                .deletingPathExtension()
                .appendingPathExtension(transferred.lyricsExtension ?? "lrc")
            guard (try? lyrics.write(to: url, options: .atomic)) != nil else { return }
            let stored = LibraryService.storedLyricsPath(url.path)
            LyricsKindCache.invalidate(storedPath: stored)
            song.lrcFilePath = stored
        }
        if let wordSync = transferred.wordSync {
            WordSyncStore.setRawData(wordSync, for: song.id)
        }
    }

    private func queueStats(_ transferred: TransferredSong, as songID: UUID) {
        for entry in transferred.history ?? [] {
            pendingHistory.append(ListeningStatsEntry(
                id: entry.id, songID: songID, title: entry.title, artist: entry.artist,
                album: entry.album, timestamp: entry.timestamp, durationPlayed: entry.durationPlayed
            ))
        }
        for (text, count) in transferred.replayed ?? [:] {
            let key = "\(songID.uuidString)|\(text)"
            pendingReplays[key] = max(pendingReplays[key] ?? 0, count)
        }
    }

    private func flushStats() {
        if !pendingHistory.isEmpty { ListeningStatsService.shared.merge(pendingHistory) }
        if !pendingReplays.isEmpty { ReplayedLines.merge(pendingReplays) }
        pendingHistory = []
        pendingReplays = [:]
    }

    /// The song here a transferred one is: the one it became last time, or
    /// the same tags and length.
    private func localSong(for transferred: TransferredSong) -> Song? {
        if let id = Self.loadOrigins()[transferred.originID], let song = library.song(withID: id) {
            return song
        }
        if matchIndex == nil {
            matchIndex = Dictionary(grouping: library.songs) {
                MediaLibraryReconciler.matchKey(title: $0.title, artist: $0.artist, album: $0.album)
            }
        }
        let key = MediaLibraryReconciler.matchKey(title: transferred.title, artist: transferred.artist, album: transferred.album)
        return matchIndex?[key]?.first { song in
            song.duration <= 0 || transferred.duration <= 0
                || abs(song.duration - transferred.duration) <= MediaLibraryReconciler.durationTolerance
        }
    }

    /// Lyrics and stats for a song this library already has. Play counts
    /// keep the higher one, so sending twice never counts plays twice.
    private func applyUpdate(_ transferred: TransferredSong) -> Song? {
        guard var song = localSong(for: transferred) else { return nil }
        storeLyrics(transferred, for: &song)
        if transferred.hasStats {
            song.playCount = max(song.playCount, transferred.playCount)
            song.lastPlayedAt = [song.lastPlayedAt, transferred.lastPlayedAt].compactMap { $0 }.max()
            queueStats(transferred, as: song.id)
        }
        library.updateSong(song)
        var origins = Self.loadOrigins()
        if origins[transferred.originID] != song.id {
            origins[transferred.originID] = song.id
            Self.saveOrigins(origins)
        }
        return song
    }

    // MARK: - Zip

    /// Writes the songs (audio, lyrics, stats, as chosen) into a zip file.
    func startExport(_ songs: [Song], content: TransferContent) {
        reset()
        self.content = content
        state = .archiving(isExport: true)
        progress = Progress(total: songs.count)
        sendTask = Task { await export(songs) }
    }

    private func export(_ songs: [Song]) async {
        let folder = Self.workDirectory("Export")
        let outbox = Self.workDirectory("Outbox")
        defer { try? FileManager.default.removeItem(at: outbox) }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        let url = folder.appendingPathComponent("VibePod \(formatter.string(from: Date())).zip")
        var summary = Summary(peer: "", isSender: true, mode: .export, content: content, transferred: 0, alreadyThere: 0, failed: 0)
        do {
            let writer = try ZipWriter(url: url)
            let stats = content.contains(.stats) ? StatsIndex() : nil
            try writer.add(JSONEncoder().encode(ArchiveHeader(version: 1, content: content, count: songs.count)), name: ArchiveHeader.fileName)
            for song in songs {
                guard !Task.isCancelled else {
                    try? FileManager.default.removeItem(at: url)
                    return
                }
                progress.current = song
                var fileExtension: String?
                if content.contains(.audio) {
                    do {
                        let file = try await Self.audioFile(for: song, in: outbox)
                        defer { if file.isCopy { try? FileManager.default.removeItem(at: file.url) } }
                        let name = "Audio/\(song.id.uuidString).\(file.url.pathExtension)"
                        let source = file.url
                        try await Task.detached { try writer.addFile(at: source, name: name) }.value
                        fileExtension = file.url.pathExtension
                    } catch {
                        summary.failed += 1
                        progress.completed += 1
                        continue
                    }
                }
                try writer.add(JSONEncoder().encode(transferred(song, fileExtension: fileExtension, stats: stats)), name: "Songs/\(song.id.uuidString).json")
                summary.transferred += 1
                progress.completed += 1
            }
            try writer.finish()
            exportedArchive = url
            state = .finished(summary)
        } catch {
            try? FileManager.default.removeItem(at: url)
            state = .failed(String(localized: "The zip file couldn't be written. Check there's enough free space."))
        }
    }

    /// Adds what a VibePod zip holds: new songs with their audio, lyrics and
    /// stats for the ones already here.
    func startImport(from url: URL) {
        reset()
        state = .archiving(isExport: false)
        sendTask = Task { await importArchive(url) }
    }

    private func importArchive(_ url: URL) async {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            let reader = try ZipReader(url: url)
            guard let headerEntry = reader.entries.first(where: { $0.name == ArchiveHeader.fileName }),
                  let header = try? JSONDecoder().decode(ArchiveHeader.self, from: reader.data(for: headerEntry)) else {
                state = .failed(String(localized: "This zip wasn't exported from VibePod."))
                return
            }
            let songEntries = reader.entries.filter { $0.name.hasPrefix("Songs/") && $0.name.hasSuffix(".json") }
            var audio: [String: ZipReader.Entry] = [:]
            for entry in reader.entries where entry.name.hasPrefix("Audio/") {
                let file = (entry.name as NSString).lastPathComponent
                audio[(file as NSString).deletingPathExtension] = entry
            }
            var summary = Summary(peer: "", isSender: false, mode: .import, content: header.content, transferred: 0, alreadyThere: 0, failed: 0)
            progress = Progress(total: songEntries.count)
            let inbox = Self.workDirectory("Inbox")
            for entry in songEntries {
                guard !Task.isCancelled else { break }
                defer { progress.completed += 1 }
                guard let data = try? reader.data(for: entry),
                      let song = try? JSONDecoder().decode(TransferredSong.self, from: data) else {
                    summary.failed += 1
                    continue
                }
                if localSong(for: song) != nil {
                    if song.lyrics != nil || song.hasStats, let updated = applyUpdate(song) {
                        summary.updated += 1
                        progress.current = updated
                    } else {
                        summary.alreadyThere += 1
                    }
                } else if let audioEntry = audio[song.originID.uuidString] {
                    let file = inbox.appendingPathComponent(UUID().uuidString)
                    do {
                        try await Task.detached { try reader.extract(audioEntry, to: file) }.value
                        progress.current = try importSong(song, from: file)
                        summary.transferred += 1
                    } catch {
                        try? FileManager.default.removeItem(at: file)
                        summary.failed += 1
                    }
                } else {
                    summary.notThere += 1
                }
                await Task.yield()
            }
            flushStats()
            guard !Task.isCancelled else { return }
            state = .finished(summary)
        } catch {
            flushStats()
            state = .failed(String(localized: "The zip file couldn't be read."))
        }
    }

    // MARK: - Messages

    private func didReceive(_ message: TransferMessage, from peer: MCPeerID) {
        switch message {
        case let .manifest(manifest):
            didReceiveManifest(manifest, from: peer)
        case let .begin(count):
            state = .transferring(peer: peer.displayName)
            progress = Progress(total: count)
        case let .song(song):
            incoming[song.originID] = song
            importIfComplete(song.originID)
        case let .update(song):
            guard !resolvedIDs.contains(song.originID) else { return }
            let updated = applyUpdate(song)
            resolve(song.originID, song: updated, updated: true)
        case let .end(sent):
            expectedIDs = Set(sent)
            // Announced, then never sent: the sender counts it as failed.
            incoming = incoming.filter { sent.contains($0.key) }
            finishReceivingIfDone()
        case .received:
            finishSending()
        }
    }

    private func message(_ message: TransferMessage, to peer: MCPeerID) throws {
        guard let session else { throw CancellationError() }
        try session.send(JSONEncoder().encode(message), toPeers: [peer], with: .reliable)
    }

    private func finishSending() {
        guard let sendSummary else { return }
        state = .finished(sendSummary)
        tearDown()
    }

    // MARK: - Connection

    private func makeSession() -> MCSession {
        session?.disconnect()
        let session = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self
        self.session = session
        return session
    }

    private func peer(_ peer: MCPeerID, didChange connection: MCSessionState) {
        switch connection {
        case .connected:
            connectedPeer = peer
            browser?.stopBrowsingForPeers()
            advertiser?.stopAdvertisingPeer()
            if advertiser != nil {
                try? message(.manifest(manifest()), to: peer)
            }
        case .notConnected:
            switch state {
            case .connecting:
                state = .failed(String(localized: "\(peer.displayName) didn't accept the transfer."))
                tearDown()
            case .transferring:
                if sendSummary != nil {
                    // Hung up once it had everything.
                    finishSending()
                } else {
                    let done = progress.completed
                    state = .failed(String(localized: "Lost the connection with \(peer.displayName) after \(done) of \(progress.total) songs. Send again to finish: songs already received won't be sent twice."))
                    tearDown()
                }
            case .finished:
                tearDown()
            default:
                break
            }
        case .connecting:
            break
        @unknown default:
            break
        }
    }

    private func didFindPeer(_ peer: MCPeerID, info: [String: String]?) {
        guard !peers.contains(where: { $0.id == peer }) else { return }
        // A device that relaunched advertises a new peer under the same name.
        peers.removeAll { $0.name == peer.displayName }
        peers.append(Peer(id: peer, model: info?["model"] ?? "iPhone"))
    }

    private func didLosePeer(_ peer: MCPeerID) {
        peers.removeAll { $0.id == peer }
    }

    private func observeFileProgress(_ progress: Foundation.Progress?) {
        fileProgress = progress?.observe(\.fractionCompleted) { @Sendable [weak self] progress, _ in
            let fraction = progress.fractionCompleted
            Task { @MainActor in self?.progress.fileFraction = fraction }
        }
    }

    /// Stops everything and goes back to the start.
    func cancel() {
        reset()
    }

    private func reset() {
        flushStats()
        tearDown()
        state = .idle
        peers = []
        invitation = nil
        progress = Progress()
        selection = []
        sendSummary = nil
        incoming = [:]
        incomingFiles = [:]
        expectedIDs = nil
        resolvedIDs = []
        receivedCount = 0
        updatedCount = 0
        failedCount = 0
        incomingContent = .all
        content = .all
        matchIndex = nil
        exportedArchive = nil
        try? FileManager.default.removeItem(at: Self.workDirectory("Inbox"))
        try? FileManager.default.removeItem(at: Self.workDirectory("Export"))
    }

    private func tearDown() {
        sendTask?.cancel()
        sendTask = nil
        fileProgress = nil
        browser?.stopBrowsingForPeers()
        browser = nil
        advertiser?.stopAdvertisingPeer()
        advertiser = nil
        session?.delegate = nil
        session?.disconnect()
        session = nil
        connectedPeer = nil
        holdDeviceAwake(false)
    }

    /// The connection doesn't survive the screen locking or the app leaving
    /// the screen for long.
    private func holdDeviceAwake(_ awake: Bool) {
        UIApplication.shared.isIdleTimerDisabled = awake
        if awake, backgroundTask == .invalid {
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Library Transfer") { [weak self] in
                MainActor.assumeIsolated { self?.holdDeviceAwake(false) }
            }
        } else if !awake, backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }

    // MARK: - Storage

    /// Sender's song ID → the song it became here.
    nonisolated private static var originsURL: URL {
        LibraryService.dataDirectory.appendingPathComponent("transfers.json")
    }

    private static func loadOrigins() -> [UUID: UUID] {
        guard let data = try? Data(contentsOf: originsURL),
              let stored = try? JSONDecoder().decode([String: UUID].self, from: data) else { return [:] }
        return Dictionary(uniqueKeysWithValues: stored.compactMap { key, value in UUID(uuidString: key).map { ($0, value) } })
    }

    private static func saveOrigins(_ origins: [UUID: UUID]) {
        let stored = Dictionary(uniqueKeysWithValues: origins.map { ($0.key.uuidString, $0.value) })
        try? JSONEncoder().encode(stored).write(to: originsURL, options: .atomic)
    }

    nonisolated private static func workDirectory(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryTransfer", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func fileName(_ text: String) -> String {
        let name = text.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined(separator: "-")
        return String(name.prefix(120))
    }
}

// MARK: - Delegates

/// Multipeer hands its peers and handlers over on its own queues.
private struct Unchecked<Value>: @unchecked Sendable {
    let value: Value
}

extension LibraryTransferService: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        let source = ObjectIdentifier(session)
        let peer = Unchecked(value: peerID)
        Task { @MainActor in
            guard source == self.session.map(ObjectIdentifier.init) else { return }
            self.peer(peer.value, didChange: state)
        }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        let source = ObjectIdentifier(session)
        guard let message = try? JSONDecoder().decode(TransferMessage.self, from: data) else { return }
        let peer = Unchecked(value: peerID)
        Task { @MainActor in
            guard source == self.session.map(ObjectIdentifier.init) else { return }
            self.didReceive(message, from: peer.value)
        }
    }

    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Foundation.Progress) {
        let source = ObjectIdentifier(session)
        let progress = Unchecked(value: progress)
        Task { @MainActor in
            guard source == self.session.map(ObjectIdentifier.init) else { return }
            self.observeFileProgress(progress.value)
        }
    }

    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {
        let source = ObjectIdentifier(session)
        // The file is deleted once this returns.
        var kept: URL?
        if error == nil, let localURL {
            let destination = Self.workDirectory("Inbox").appendingPathComponent(UUID().uuidString)
            if (try? FileManager.default.moveItem(at: localURL, to: destination)) != nil {
                kept = destination
            }
        }
        Task { @MainActor [kept] in
            guard source == self.session.map(ObjectIdentifier.init) else {
                if let kept { try? FileManager.default.removeItem(at: kept) }
                return
            }
            self.didReceiveFile(named: resourceName, at: kept)
        }
    }

    nonisolated func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
}

extension LibraryTransferService: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        let source = ObjectIdentifier(browser)
        let peer = Unchecked(value: peerID)
        Task { @MainActor in
            guard source == self.browser.map(ObjectIdentifier.init) else { return }
            self.didFindPeer(peer.value, info: info)
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        let source = ObjectIdentifier(browser)
        let peer = Unchecked(value: peerID)
        Task { @MainActor in
            guard source == self.browser.map(ObjectIdentifier.init) else { return }
            self.didLosePeer(peer.value)
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        let source = ObjectIdentifier(browser)
        Task { @MainActor in
            guard source == self.browser.map(ObjectIdentifier.init) else { return }
            self.state = .failed(TransferError.localNetwork.localizedDescription)
            self.tearDown()
        }
    }
}

extension LibraryTransferService: MCNearbyServiceAdvertiserDelegate {
    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        let source = ObjectIdentifier(advertiser)
        let peer = Unchecked(value: peerID)
        let handler = Unchecked(value: invitationHandler)
        Task { @MainActor in
            guard source == self.advertiser.map(ObjectIdentifier.init) else {
                handler.value(false, nil)
                return
            }
            self.didReceiveInvitation(from: peer.value, context: context, handler: handler.value)
        }
    }

    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        let source = ObjectIdentifier(advertiser)
        Task { @MainActor in
            guard source == self.advertiser.map(ObjectIdentifier.init) else { return }
            self.state = .failed(TransferError.localNetwork.localizedDescription)
            self.tearDown()
        }
    }
}

extension LibraryTransferService.Invitation {
    func accept() { respond(true) }
    func decline() { respond(false) }
}

// MARK: - Wire format

enum TransferError: LocalizedError {
    case unreadable
    case localNetwork

    var errorDescription: String? {
        switch self {
        case .unreadable: String(localized: "The song's file couldn't be read.")
        case .localNetwork: String(localized: "VibePod can't use the local network. Allow it in Settings › Privacy & Security › Local Network.")
        }
    }
}

private struct InvitationContext: Codable {
    var songCount: Int
    var content: TransferContent?
}

private enum TransferMessage: Codable {
    /// Receiver → sender, once connected.
    case manifest(TransferManifest)
    /// Sender → receiver: how many songs are coming.
    case begin(count: Int)
    /// Sender → receiver, ahead of the song's audio.
    case song(TransferredSong)
    /// Sender → receiver: lyrics or stats for a song it already has.
    case update(TransferredSong)
    /// Sender → receiver: the songs that actually went.
    case end(sent: [UUID])
    /// Receiver → sender: everything is in the library.
    case received
}

/// What the receiver already holds.
private struct TransferManifest: Codable {
    /// The sender's song IDs this library got from it and still holds.
    var origins: Set<UUID>
    /// Every song here, by tags: one it got some other way isn't sent twice.
    var songs: [Entry]

    struct Entry: Codable {
        var key: String
        var duration: TimeInterval
    }

    /// The songs of `selection` the receiver doesn't hold.
    func missing(from selection: [Song]) -> [Song] {
        let durations = Dictionary(grouping: songs, by: \.key).mapValues { $0.map(\.duration) }
        return selection.filter { song in
            if origins.contains(song.id) { return false }
            let key = MediaLibraryReconciler.matchKey(title: song.title, artist: song.artist, album: song.album)
            let held = durations[key]?.contains { duration in
                duration <= 0 || song.duration <= 0
                    || abs(duration - song.duration) <= MediaLibraryReconciler.durationTolerance
            }
            return held != true
        }
    }
}

private struct TransferredSong: Codable {
    var originID: UUID
    var title: String
    var artist: String
    var album: String
    var albumArtist: String?
    var genre: String
    var duration: TimeInterval
    var trackNumber: Int
    var discNumber: Int
    var year: Int
    var addedAt: Date
    var lastPlayedAt: Date?
    var playCount: Int
    var fileExtension: String
    var artwork: Data?
    var lyrics: Data?
    var lyricsExtension: String?
    var lyricsGenerated: Bool
    /// The WordSync file, as stored.
    var wordSync: Data?
    var hasStats = true
    var history: [ListeningStatsEntry]?
    /// Replayed line text → count.
    var replayed: [String: Int]?
}

// MARK: - Content

/// What a transfer or an export carries.
struct TransferContent: OptionSet, Codable, Hashable, Sendable {
    let rawValue: Int
    static let audio = TransferContent(rawValue: 1)
    static let lyrics = TransferContent(rawValue: 2)
    static let stats = TransferContent(rawValue: 4)
    static let all: TransferContent = [.audio, .lyrics, .stats]
    static let storageKey = "libraryTransferContent"
}

/// The sender's history, looked up per song.
@MainActor
private struct StatsIndex {
    let history: [UUID: [ListeningStatsEntry]]
    private let replays: [String: Int]

    init() {
        history = Dictionary(grouping: ListeningStatsService.shared.allEntries(), by: \.songID)
        replays = ReplayedLines.all()
    }

    func replayed(for songID: UUID) -> [String: Int]? {
        let prefix = songID.uuidString + "|"
        var lines: [String: Int] = [:]
        for (key, count) in replays where key.hasPrefix(prefix) {
            lines[String(key.dropFirst(prefix.count))] = count
        }
        return lines.isEmpty ? nil : lines
    }
}

/// VibePod.json, at the root of an exported zip.
private struct ArchiveHeader: Codable {
    static let fileName = "VibePod.json"
    var version: Int
    var content: TransferContent
    var count: Int
}

// MARK: - Zip

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}

private extension Array where Element == UInt8 {
    func le<T: FixedWidthInteger>(_ offset: Int, as: T.Type = T.self) -> T {
        var value: T = 0
        for i in 0..<MemoryLayout<T>.size { value |= T(self[offset + i]) << (8 * i) }
        return value
    }
}

enum ZipError: Error { case malformed, unsupported }

/// Writes a zip with stored (uncompressed) entries, Zip64 when it needs to:
/// audio doesn't compress, and any unzip tool reads it.
final class ZipWriter: @unchecked Sendable {
    private struct Entry {
        var name: Data
        var crc: UInt32
        var size: UInt64
        var offset: UInt64
    }

    private let handle: FileHandle
    private var entries: [Entry] = []
    private let time: UInt16
    private let date: UInt16

    init(url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw ZipError.malformed }
        handle = try FileHandle(forWritingTo: url)
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date())
        time = UInt16((c.hour ?? 0) << 11 | (c.minute ?? 0) << 5 | (c.second ?? 0) / 2)
        date = UInt16(max((c.year ?? 1980) - 1980, 0) << 9 | (c.month ?? 1) << 5 | (c.day ?? 1))
    }

    deinit { try? handle.close() }

    func add(_ data: Data, name: String) throws {
        let crc = data.withUnsafeBytes { UInt32(crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count))) }
        let offset = try handle.offset()
        let nameData = Data(name.utf8)
        try handle.write(contentsOf: localHeader(name: nameData, crc: crc, size: UInt64(data.count)))
        try handle.write(contentsOf: data)
        entries.append(Entry(name: nameData, crc: crc, size: UInt64(data.count), offset: offset))
    }

    /// Streams the file in, then fills in its checksum.
    func addFile(at url: URL, name: String) throws {
        let size = UInt64((try url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0)
        let offset = try handle.offset()
        let nameData = Data(name.utf8)
        try handle.write(contentsOf: localHeader(name: nameData, crc: 0, size: size))
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var crc: uLong = 0
        var written: UInt64 = 0
        while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
            crc = chunk.withUnsafeBytes { crc32(crc, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count)) }
            try handle.write(contentsOf: chunk)
            written += UInt64(chunk.count)
        }
        guard written == size else { throw ZipError.malformed }
        let end = try handle.offset()
        try handle.seek(toOffset: offset + 14)
        var crcData = Data()
        crcData.appendLE(UInt32(crc))
        try handle.write(contentsOf: crcData)
        try handle.seek(toOffset: end)
        entries.append(Entry(name: nameData, crc: UInt32(crc), size: size, offset: offset))
    }

    private func localHeader(name: Data, crc: UInt32, size: UInt64) -> Data {
        let big = size >= 0xFFFF_FFFF
        var data = Data()
        data.appendLE(UInt32(0x0403_4B50))
        data.appendLE(UInt16(big ? 45 : 20))
        data.appendLE(UInt16(0x0800)) // UTF-8 names
        data.appendLE(UInt16(0)) // stored
        data.appendLE(time)
        data.appendLE(date)
        data.appendLE(crc)
        data.appendLE(UInt32(big ? 0xFFFF_FFFF : UInt32(size)))
        data.appendLE(UInt32(big ? 0xFFFF_FFFF : UInt32(size)))
        data.appendLE(UInt16(name.count))
        data.appendLE(UInt16(big ? 20 : 0))
        data.append(name)
        if big {
            data.appendLE(UInt16(0x0001))
            data.appendLE(UInt16(16))
            data.appendLE(size)
            data.appendLE(size)
        }
        return data
    }

    func finish() throws {
        let directoryStart = try handle.offset()
        for entry in entries {
            let bigSize = entry.size >= 0xFFFF_FFFF
            let bigOffset = entry.offset >= 0xFFFF_FFFF
            var extra = Data()
            if bigSize || bigOffset {
                var fields = Data()
                if bigSize { fields.appendLE(entry.size); fields.appendLE(entry.size) }
                if bigOffset { fields.appendLE(entry.offset) }
                extra.appendLE(UInt16(0x0001))
                extra.appendLE(UInt16(fields.count))
                extra.append(fields)
            }
            var data = Data()
            data.appendLE(UInt32(0x0201_4B50))
            data.appendLE(UInt16(0x0300 | 45)) // made by: Unix
            data.appendLE(UInt16(extra.isEmpty ? 20 : 45))
            data.appendLE(UInt16(0x0800))
            data.appendLE(UInt16(0))
            data.appendLE(time)
            data.appendLE(date)
            data.appendLE(entry.crc)
            data.appendLE(UInt32(bigSize ? 0xFFFF_FFFF : UInt32(entry.size)))
            data.appendLE(UInt32(bigSize ? 0xFFFF_FFFF : UInt32(entry.size)))
            data.appendLE(UInt16(entry.name.count))
            data.appendLE(UInt16(extra.count))
            data.appendLE(UInt16(0)) // comment
            data.appendLE(UInt16(0)) // disk
            data.appendLE(UInt16(0)) // internal attributes
            data.appendLE(UInt32(0o100644) << 16)
            data.appendLE(UInt32(bigOffset ? 0xFFFF_FFFF : UInt32(entry.offset)))
            data.append(entry.name)
            data.append(extra)
            try handle.write(contentsOf: data)
        }
        let directoryEnd = try handle.offset()
        let directorySize = directoryEnd - directoryStart
        let count = UInt64(entries.count)
        var end = Data()
        if count >= 0xFFFF || directoryStart >= 0xFFFF_FFFF || directorySize >= 0xFFFF_FFFF {
            end.appendLE(UInt32(0x0606_4B50))
            end.appendLE(UInt64(44))
            end.appendLE(UInt16(45))
            end.appendLE(UInt16(45))
            end.appendLE(UInt32(0))
            end.appendLE(UInt32(0))
            end.appendLE(count)
            end.appendLE(count)
            end.appendLE(directorySize)
            end.appendLE(directoryStart)
            end.appendLE(UInt32(0x0706_4B50))
            end.appendLE(UInt32(0))
            end.appendLE(directoryEnd)
            end.appendLE(UInt32(1))
        }
        end.appendLE(UInt32(0x0605_4B50))
        end.appendLE(UInt16(0))
        end.appendLE(UInt16(0))
        end.appendLE(UInt16(min(count, 0xFFFF)))
        end.appendLE(UInt16(min(count, 0xFFFF)))
        end.appendLE(UInt32(min(directorySize, 0xFFFF_FFFF)))
        end.appendLE(UInt32(min(directoryStart, 0xFFFF_FFFF)))
        end.appendLE(UInt16(0))
        try handle.write(contentsOf: end)
        try handle.close()
    }
}

/// Reads zips: stored or deflated entries, Zip64 included (so one re-zipped
/// in Files or Finder still opens).
final class ZipReader: @unchecked Sendable {
    struct Entry: Sendable {
        let name: String
        let method: UInt16
        let compressedSize: UInt64
        let size: UInt64
        let localOffset: UInt64
    }

    let entries: [Entry]
    private let handle: FileHandle
    private let lock = NSLock()

    init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
        let fileSize = try handle.seekToEnd()
        let tailLength = min(fileSize, 65_557 + 20)
        try handle.seek(toOffset: fileSize - tailLength)
        let tail = [UInt8](try handle.readToEnd() ?? Data())
        guard tail.count >= 22,
              let eocd = stride(from: tail.count - 22, through: 0, by: -1).first(where: { tail.le($0, as: UInt32.self) == 0x0605_4B50 }) else {
            throw ZipError.malformed
        }
        var count = UInt64(tail.le(eocd + 10, as: UInt16.self))
        var directorySize = UInt64(tail.le(eocd + 12, as: UInt32.self))
        var directoryOffset = UInt64(tail.le(eocd + 16, as: UInt32.self))
        if count == 0xFFFF || directorySize == 0xFFFF_FFFF || directoryOffset == 0xFFFF_FFFF,
           eocd >= 20, tail.le(eocd - 20, as: UInt32.self) == 0x0706_4B50 {
            try handle.seek(toOffset: tail.le(eocd - 12, as: UInt64.self))
            let record = [UInt8](try handle.read(upToCount: 56) ?? Data())
            guard record.count == 56, record.le(0, as: UInt32.self) == 0x0606_4B50 else { throw ZipError.malformed }
            count = record.le(32)
            directorySize = record.le(40)
            directoryOffset = record.le(48)
        }
        try handle.seek(toOffset: directoryOffset)
        let directory = [UInt8](try handle.read(upToCount: Int(directorySize)) ?? Data())
        var entries: [Entry] = []
        var p = 0
        while entries.count < count, p + 46 <= directory.count, directory.le(p, as: UInt32.self) == 0x0201_4B50 {
            let method: UInt16 = directory.le(p + 10)
            var compressed = UInt64(directory.le(p + 20, as: UInt32.self))
            var size = UInt64(directory.le(p + 24, as: UInt32.self))
            let nameLength = Int(directory.le(p + 28, as: UInt16.self))
            let extraLength = Int(directory.le(p + 30, as: UInt16.self))
            let commentLength = Int(directory.le(p + 32, as: UInt16.self))
            var offset = UInt64(directory.le(p + 42, as: UInt32.self))
            guard p + 46 + nameLength + extraLength <= directory.count else { throw ZipError.malformed }
            let name = String(decoding: directory[(p + 46)..<(p + 46 + nameLength)], as: UTF8.self)
            var e = p + 46 + nameLength
            let extraEnd = e + extraLength
            while e + 4 <= extraEnd {
                let id: UInt16 = directory.le(e)
                let length = Int(directory.le(e + 2, as: UInt16.self))
                if id == 0x0001 {
                    var f = e + 4
                    if size == 0xFFFF_FFFF, f + 8 <= extraEnd { size = directory.le(f); f += 8 }
                    if compressed == 0xFFFF_FFFF, f + 8 <= extraEnd { compressed = directory.le(f); f += 8 }
                    if offset == 0xFFFF_FFFF, f + 8 <= extraEnd { offset = directory.le(f) }
                }
                e += 4 + length
            }
            if !name.hasSuffix("/") {
                entries.append(Entry(name: name, method: method, compressedSize: compressed, size: size, localOffset: offset))
            }
            p = extraEnd + commentLength
        }
        self.entries = entries
    }

    deinit { try? handle.close() }

    func data(for entry: Entry) throws -> Data {
        guard entry.size < 64 << 20 else { throw ZipError.unsupported }
        var data = Data()
        try read(entry) { data.append(contentsOf: $0) }
        return data
    }

    func extract(_ entry: Entry, to url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw ZipError.malformed }
        let output = try FileHandle(forWritingTo: url)
        defer { try? output.close() }
        try read(entry) { try output.write(contentsOf: Data($0)) }
    }

    private func read(_ entry: Entry, into sink: (UnsafeRawBufferPointer) throws -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        try handle.seek(toOffset: entry.localOffset)
        let header = [UInt8](try handle.read(upToCount: 30) ?? Data())
        guard header.count == 30, header.le(0, as: UInt32.self) == 0x0403_4B50 else { throw ZipError.malformed }
        let start = entry.localOffset + 30 + UInt64(header.le(26, as: UInt16.self)) + UInt64(header.le(28, as: UInt16.self))
        try handle.seek(toOffset: start)
        switch entry.method {
        case 0:
            var remaining = entry.size
            while remaining > 0 {
                guard let chunk = try handle.read(upToCount: Int(min(remaining, 1 << 20))), !chunk.isEmpty else { throw ZipError.malformed }
                try chunk.withUnsafeBytes { try sink($0) }
                remaining -= UInt64(chunk.count)
            }
        case 8:
            try inflate(compressedSize: entry.compressedSize, into: sink)
        default:
            throw ZipError.unsupported
        }
    }

    /// Raw deflate, which Compression's ZLIB is.
    private func inflate(compressedSize: UInt64, into sink: (UnsafeRawBufferPointer) throws -> Void) throws {
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw ZipError.unsupported
        }
        defer { compression_stream_destroy(stream) }
        let sourceCapacity = 1 << 20
        let destinationCapacity = 1 << 18
        let source = UnsafeMutablePointer<UInt8>.allocate(capacity: sourceCapacity)
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: destinationCapacity)
        defer { source.deallocate(); destination.deallocate() }
        var remaining = compressedSize
        stream.pointee.src_size = 0
        while true {
            if stream.pointee.src_size == 0, remaining > 0 {
                guard let chunk = try handle.read(upToCount: Int(min(remaining, UInt64(sourceCapacity)))), !chunk.isEmpty else {
                    throw ZipError.malformed
                }
                chunk.copyBytes(to: source, count: chunk.count)
                stream.pointee.src_ptr = UnsafePointer(source)
                stream.pointee.src_size = chunk.count
                remaining -= UInt64(chunk.count)
            }
            stream.pointee.dst_ptr = destination
            stream.pointee.dst_size = destinationCapacity
            let flags = remaining == 0 ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
            let status = compression_stream_process(stream, flags)
            let produced = destinationCapacity - stream.pointee.dst_size
            if produced > 0 { try sink(UnsafeRawBufferPointer(start: destination, count: produced)) }
            switch status {
            case COMPRESSION_STATUS_END:
                return
            case COMPRESSION_STATUS_OK:
                if remaining == 0, stream.pointee.src_size == 0, produced == 0 { return }
            default:
                throw ZipError.malformed
            }
        }
    }
}
