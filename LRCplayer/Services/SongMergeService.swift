import AVFoundation
import Foundation
import UIKit

/// Two songs played as one (a part 1 and its part 2): rendered into one
/// lossless file that takes their place in the library, so shuffle never
/// plays one without the other. Undone at any time: the originals come back
/// as they were (their files are never touched).
struct SongMerge: Codable, Identifiable, Sendable {
    enum Transition: String, Codable, CaseIterable, Sendable {
        /// One straight after the other.
        case cut
        /// One fades out while the other fades in.
        case crossfade
        /// A mix on the beat, like AutoMix.
        case autoMix

        var title: String {
            switch self {
            case .cut: String(localized: "Cut")
            case .crossfade: String(localized: "Crossfade")
            case .autoMix: String(localized: "AutoMix")
            }
        }

        var symbol: String {
            switch self {
            case .cut: "scissors"
            case .crossfade: "arrow.left.and.right"
            case .autoMix: "wand.and.stars"
            }
        }
    }

    struct Part: Codable, Sendable {
        /// The song as it was in the library, given back on unmerging.
        var song: Song
        var start: TimeInterval
        var end: TimeInterval
        var length: TimeInterval { max(0, end - start) }
    }

    /// The merged song's ID.
    let id: UUID
    var parts: [Part]
    var transition: Transition
    /// The crossfade's length.
    var fade: TimeInterval
    /// Playlist → which parts it held, to put them back.
    var playlistParts: [UUID: [UUID]] = [:]
    var createdAt = Date()
    /// Where the second part came in, as rendered (AutoMix's depends on
    /// the beat): the music video switches there too.
    var secondAt: TimeInterval?
    var overlap: TimeInterval?

    /// As rendered (merges made before it was kept: worked out again).
    var layout: SongMergeLayout {
        var layout = SongMergeService.layout(for: self)
        if let secondAt, let overlap {
            layout.secondAt = secondAt
            layout.overlap = overlap
            layout.duration = secondAt + parts[1].length
        }
        return layout
    }
}

/// Where the second part comes in and how the two meet.
struct SongMergeLayout: Sendable {
    /// When the second part starts, on the merged song's clock.
    var secondAt: TimeInterval
    /// How long both play together.
    var overlap: TimeInterval
    /// The second part's fade in (AutoMix brings it in faster).
    var fadeIn: TimeInterval
    var duration: TimeInterval
}

@MainActor
final class SongMergeService: ObservableObject {
    static let shared = SongMergeService()

    @Published private(set) var merges: [SongMerge] = []

    private var storeURL: URL {
        LibraryService.dataDirectory.appendingPathComponent("SongMerges.json")
    }

    private init() {
        if let data = try? Data(contentsOf: storeURL),
           let stored = try? JSONDecoder().decode([SongMerge].self, from: data) {
            merges = stored
        }
    }

    private func save() {
        try? JSONEncoder().encode(merges).write(to: storeURL, options: .atomic)
    }

    func merge(for songID: UUID) -> SongMerge? {
        merges.first { $0.id == songID }
    }

    /// The originals now inside a merge: kept out of the library's imports.
    var mergedPartPaths: Set<String> {
        Set(merges.flatMap(\.parts).filter { !$0.song.isMediaLibraryItem }.map { $0.song.fileURL.standardizedFileURL.path })
    }

    var mergedPartPersistentIDs: Set<UInt64> {
        Set(merges.flatMap(\.parts).compactMap(\.song.mediaLibraryPersistentID))
    }

    // MARK: Layout

    /// AutoMix: eight beats of the first part (6 s without a tempo), both
    /// landing on the beat; the second part comes in over the first third.
    nonisolated static func layout(for merge: SongMerge, profiles: (AutoMixProfile?, AutoMixProfile?) = (nil, nil)) -> SongMergeLayout {
        let first = merge.parts[0]
        let second = merge.parts[1]
        var overlap: TimeInterval
        var fadeIn: TimeInterval
        switch merge.transition {
        case .cut:
            overlap = 0
            fadeIn = 0.012
        case .crossfade:
            overlap = merge.fade
            fadeIn = merge.fade
        case .autoMix:
            if let period = profiles.0?.beatPeriod, period > 0.25 {
                overlap = period * 8
            } else {
                overlap = 6
            }
            overlap = min(max(overlap, 3), 10)
            fadeIn = overlap * 0.35
        }
        overlap = min(overlap, first.length / 2, second.length / 2)
        fadeIn = min(fadeIn, max(overlap, 0.012))
        var secondAt = first.length - overlap
        // On the beat: the first part's beat nearest the switch.
        if merge.transition == .autoMix, let out = profiles.0, out.bpm > 0 {
            let beat = out.beat(atOrBefore: first.start + secondAt) - first.start
            if abs(beat - secondAt) < 0.6, beat > first.length / 2 { secondAt = beat }
        }
        return SongMergeLayout(secondAt: secondAt, overlap: first.length - secondAt, fadeIn: fadeIn, duration: secondAt + second.length)
    }

    /// The two parts as one asset, faded as the transition says: what's
    /// previewed is exactly what's rendered.
    nonisolated static func composition(for merge: SongMerge, layout: SongMergeLayout) async throws -> (AVMutableComposition, AVMutableAudioMix) {
        let composition = AVMutableComposition()
        var parameters: [AVMutableAudioMixInputParameters] = []
        for (index, part) in merge.parts.enumerated() {
            let url = part.song.isMediaLibraryItem ? part.song.fileURL : part.song.playableFileURL
            let asset = AVURLAsset(url: url)
            guard let source = try await asset.loadTracks(withMediaType: .audio).first,
                  let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw MergeError.unreadable(part.song.title)
            }
            let at = index == 0 ? 0 : layout.secondAt
            let range = CMTimeRange(start: CMTime(seconds: part.start, preferredTimescale: 44_100), duration: CMTime(seconds: part.length, preferredTimescale: 44_100))
            try track.insertTimeRange(range, of: source, at: CMTime(seconds: at, preferredTimescale: 44_100))

            let input = AVMutableAudioMixInputParameters(track: track)
            func ramp(_ from: Float, _ to: Float, _ start: TimeInterval, _ length: TimeInterval) {
                input.setVolumeRamp(fromStartVolume: from, toEndVolume: to, timeRange: CMTimeRange(
                    start: CMTime(seconds: start, preferredTimescale: 44_100),
                    duration: CMTime(seconds: max(length, 0.005), preferredTimescale: 44_100)))
            }
            // Trimmed edges get a few milliseconds of fade, never a click.
            if index == 0 {
                if part.start > 0.05 { ramp(0, 1, 0, 0.012) }
                let out = max(layout.overlap, 0.012)
                ramp(1, 0, part.length - out, out)
            } else {
                ramp(0, 1, at, layout.fadeIn)
                if part.end < part.song.duration - 0.05 { ramp(1, 0, at + part.length - 0.012, 0.012) }
            }
            parameters.append(input)
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = parameters
        return (composition, mix)
    }

    enum MergeError: LocalizedError {
        case unreadable(String)
        case render

        var errorDescription: String? {
            switch self {
            case .unreadable(let title): String(localized: "“\(title)” can't be read (protected or in the cloud).")
            case .render: String(localized: "The merged song couldn't be made.")
            }
        }
    }

    // MARK: Merging

    /// Renders the merge, then swaps the two songs for it in the library.
    /// `replacing`: the merge being edited, undone once the new one is made.
    func apply(_ merge: SongMerge, title: String, metadataFrom metadataIndex: Int, replacing old: SongMerge? = nil, library: LibraryService, progress: @escaping @Sendable (Double) -> Void) async throws {
        var merge = merge
        let profiles = merge.transition == .autoMix
            ? (await AutoMixAnalyzer.shared.profile(for: merge.parts[0].song), await AutoMixAnalyzer.shared.profile(for: merge.parts[1].song))
            : (nil, nil)
        let layout = Self.layout(for: merge, profiles: profiles)

        let folder = library.musicDirectory.appendingPathComponent("Merged", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fileURL = folder.appendingPathComponent("\(merge.id.uuidString).m4a")
        let frozen = merge
        try await Task.detached(priority: .userInitiated) {
            try await Self.render(frozen, layout: layout, to: fileURL, progress: progress)
        }.value
        if let old { unmerge(old, library: library) }

        // The merged song: the chosen title, the chosen part's album and
        // artwork, both parts' history.
        let parts = merge.parts.map(\.song)
        let info = parts[metadataIndex]
        let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64) ?? 0
        var song = Song(
            id: merge.id,
            title: title,
            artist: info.artist,
            album: info.album,
            albumArtist: info.albumArtist,
            genre: info.genre,
            duration: layout.duration,
            fileURL: fileURL,
            artworkData: ArtworkStore.data(for: info.id),
            addedAt: parts.map(\.addedAt).min() ?? Date(),
            lastPlayedAt: parts.compactMap(\.lastPlayedAt).max(),
            playCount: parts.map(\.playCount).max() ?? 0,
            trackNumber: info.trackNumber,
            discNumber: info.discNumber,
            year: info.year,
            fileSize: size,
            format: "ALAC",
            source: .appFile
        )
        song.lrcFilePath = writeLyrics(for: merge, layout: layout, song: song, library: library)

        // In the library and the playlists, the two become one.
        let ids = Set(parts.map(\.id))
        var playlistParts: [UUID: [UUID]] = [:]
        for playlist in library.playlists where playlist.songs.contains(where: ids.contains) {
            playlistParts[playlist.id] = parts.map(\.id).filter(playlist.songs.contains)
        }
        merge.playlistParts = playlistParts
        merge.secondAt = layout.secondAt
        merge.overlap = layout.overlap
        merge.parts = merge.parts.map { part in
            var part = part
            part.song = library.song(withID: part.song.id) ?? part.song
            return part
        }

        var songs = library.songs
        let position = songs.firstIndex { ids.contains($0.id) } ?? songs.endIndex
        songs.removeAll { ids.contains($0.id) }
        songs.insert(song, at: min(position, songs.endIndex))
        library.playlists = library.playlists.map { playlist in
            var playlist = playlist
            playlist.songs = Self.collapse(playlist.songs, parts: ids, into: song.id)
            playlist.manualSongOrder = playlist.manualSongOrder.map { Self.collapse($0, parts: ids, into: song.id) }
            return playlist
        }
        library.songs = songs
        library.saveLibrary()

        merges.removeAll { $0.id == merge.id }
        merges.insert(merge, at: 0)
        save()
        // The queue may hold the parts: give it the merged song.
        NotificationCenter.default.post(name: LibraryService.songsRelinked, object: library, userInfo: ["songs": [parts[0].id: song]])
    }

    /// Gives the two songs back, as they were, and removes the merged one.
    func unmerge(_ merge: SongMerge, library: LibraryService) {
        let merged = library.song(withID: merge.id)
        var restored = merge.parts.map(\.song)
        // What was played merged counts for both.
        if let merged {
            for index in restored.indices {
                restored[index].playCount = max(restored[index].playCount, merged.playCount)
                restored[index].lastPlayedAt = [restored[index].lastPlayedAt, merged.lastPlayedAt].compactMap { $0 }.max()
            }
        }
        var songs = library.songs
        let position = songs.firstIndex { $0.id == merge.id } ?? songs.endIndex
        songs.removeAll { $0.id == merge.id }
        let present = Set(songs.map(\.id))
        songs.insert(contentsOf: restored.filter { !present.contains($0.id) }, at: min(position, songs.endIndex))
        library.playlists = library.playlists.map { playlist in
            var playlist = playlist
            let parts = merge.playlistParts[playlist.id] ?? restored.map(\.id)
            playlist.songs = Self.expand(playlist.songs, merged: merge.id, into: parts)
            playlist.manualSongOrder = playlist.manualSongOrder.map { Self.expand($0, merged: merge.id, into: parts) }
            return playlist
        }
        library.songs = songs
        library.saveLibrary()

        // The merged song's own files.
        if let merged {
            try? FileManager.default.removeItem(at: merged.playableFileURL)
            if let lyrics = library.resolvedLyricsURL(for: merged) { try? FileManager.default.removeItem(at: lyrics) }
        }
        WordSyncStore.delete(for: merge.id)
        ArtworkStore.remove(for: merge.id)

        merges.removeAll { $0.id == merge.id }
        save()
        NotificationCenter.default.post(name: LibraryService.songsRelinked, object: library, userInfo: ["songs": [merge.id: restored[0]]])
        // An iPhone track may have moved since: relink it.
        Task { await library.reconcileMediaLibrary(force: true) }
    }

    private static func collapse(_ ids: [UUID], parts: Set<UUID>, into merged: UUID) -> [UUID] {
        var placed = ids.contains(merged)
        return ids.compactMap { id in
            guard parts.contains(id) else { return id }
            if placed { return nil }
            placed = true
            return merged
        }
    }

    private static func expand(_ ids: [UUID], merged: UUID, into parts: [UUID]) -> [UUID] {
        ids.flatMap { $0 == merged ? parts.filter { !ids.contains($0) } : [$0] }
    }

    // MARK: Lyrics

    /// Both parts' synced lyrics on the merged clock (word sync too), when
    /// at least one has them.
    private func writeLyrics(for merge: SongMerge, layout: SongMergeLayout, song: Song, library: LibraryService) -> String? {
        var lines: [(time: TimeInterval, text: String, words: [WordTiming]?)] = []
        for (index, part) in merge.parts.enumerated() {
            guard let url = library.resolvedLyricsURL(for: part.song), let lyrics = LRCParser.parse(url: url), lyrics.hasTimedLyrics else { continue }
            let timings = WordSyncStore.load(for: part.song.id, lyrics: lyrics)
            // Lyrics time = audio time + offset; on the merged clock, the
            // part starts at `at` from its `start`.
            let at = index == 0 ? 0 : layout.secondAt
            let shift = at - part.start - lyrics.offset
            let window = (part.start + lyrics.offset - 0.05)...(part.end + lyrics.offset)
            if index == 1, let last = lines.last, !last.text.isEmpty {
                // The first part's last line ends where the second comes in.
                lines.append((max(last.time + 0.1, at), "", nil))
            }
            for line in lyrics.lines where window.contains(line.time) {
                let words = timings[line.id]?.map { WordTiming(start: $0.start + shift, end: $0.end + shift) }
                lines.append((max(0, line.time + shift), line.text, words))
            }
        }
        guard lines.contains(where: { !$0.text.isEmpty }) else { return nil }

        func stamp(_ time: TimeInterval) -> String {
            let centiseconds = Int((time * 100).rounded())
            return String(format: "[%02d:%02d.%02d]", centiseconds / 6000, (centiseconds / 100) % 60, centiseconds % 100)
        }
        var content = "[ti:\(song.title)]\n[ar:\(song.artist)]\n[al:\(song.album)]\n"
        content += lines.map { stamp($0.time) + $0.text }.joined(separator: "\n")
        let folder = library.lyricsDirectory.appendingPathComponent("Merged", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = library.ownLyricsURL(for: song, in: folder)
        guard (try? content.write(to: url, atomically: true, encoding: .utf8)) != nil else { return nil }

        // Word sync carried over (on the file as it parses back).
        if lines.contains(where: { $0.words != nil }), let parsed = LRCParser.parse(url: url) {
            var byStamp: [String: [WordTiming]] = [:]
            for line in lines { if let words = line.words { byStamp[stamp(line.time) + line.text] = words } }
            let words = parsed.lines.map { byStamp[stamp($0.time) + $0.text] ?? [] }
            try? WordSyncStore.save(words, for: song.id, lyrics: parsed)
        }
        return library.storedLyricsPath(for: url.path)
    }

    // MARK: Rendering

    /// The composition decoded and written losslessly (ALAC), so the
    /// merged song sounds exactly like its parts.
    nonisolated private static func render(_ merge: SongMerge, layout: SongMergeLayout, to url: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        try? FileManager.default.removeItem(at: url)
        let (composition, mix) = try await composition(for: merge, layout: layout)
        let tracks = try await composition.loadTracks(withMediaType: .audio)

        // The first part's sample rate (48 kHz files stay 48 kHz).
        var sampleRate = 44_100.0
        let sourceURL = merge.parts[0].song.isMediaLibraryItem ? merge.parts[0].song.fileURL : merge.parts[0].song.playableFileURL
        if let source = try? await AVURLAsset(url: sourceURL).loadTracks(withMediaType: .audio).first,
           let description = try? await source.load(.formatDescriptions).first,
           let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
           basic.mSampleRate >= 22_050 {
            sampleRate = basic.mSampleRate
        }

        let reader = try AVAssetReader(asset: composition)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])
        output.audioMix = mix
        guard reader.canAdd(output) else { throw MergeError.render }
        reader.add(output)

        let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatAppleLossless,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitDepthHintKey: 16
        ])
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw MergeError.render }
        writer.add(input)

        guard reader.startReading(), writer.startWriting() else { throw MergeError.render }
        writer.startSession(atSourceTime: .zero)
        let total = max(layout.duration, 1)
        while let buffer = output.copyNextSampleBuffer() {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            guard input.append(buffer) else { break }
            let time = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
            progress(min(0.99, time / total))
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard reader.status == .completed, writer.status == .completed else {
            try? FileManager.default.removeItem(at: url)
            throw MergeError.render
        }
        progress(1)
    }

    // MARK: Waveform

    private var waveforms: [UUID: [Float]] = [:]

    /// The song's loudness in `count` bars (0…1), for trimming by eye.
    func waveform(for song: Song, count: Int = 160) async -> [Float] {
        if let cached = waveforms[song.id], cached.count == count { return cached }
        let url = song.isMediaLibraryItem ? song.fileURL : song.playableFileURL
        let bars = await Task.detached(priority: .userInitiated) { await Self.readWaveform(url, count: count) }.value
        if !bars.isEmpty { waveforms[song.id] = bars }
        return bars
    }

    nonisolated private static func readWaveform(_ url: URL, count: Int) async -> [Float] {
        let asset = AVURLAsset(url: url)
        let track = try? await asset.loadTracks(withMediaType: .audio).first
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        guard let track, duration > 0, let reader = try? AVAssetReader(asset: asset) else { return [] }
        // A rate the converter takes (AutoMix reads at it too).
        let rate = 11_025.0
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])
        guard reader.canAdd(output) else { return [] }
        reader.add(output)
        guard reader.startReading() else { return [] }
        let perBar = max(1, Int(duration * rate) / count)
        var bars = [Float](repeating: 0, count: count)
        var sample = 0
        var samples: [Int16] = []
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            // Copied out: a block buffer isn't always in one piece.
            let length = CMBlockBufferGetDataLength(block)
            samples = [Int16](repeating: 0, count: length / 2)
            let status = samples.withUnsafeMutableBytes { raw in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: (length / 2) * 2, destination: raw.baseAddress!)
            }
            guard status == kCMBlockBufferNoErr else { continue }
            for value in samples {
                let bar = min(count - 1, sample / perBar)
                let level = Float(abs(Int32(value))) / 32_768
                if level > bars[bar] { bars[bar] = level }
                sample += 1
            }
        }
        let peak = max(bars.max() ?? 1, 0.01)
        return bars.map { pow($0 / peak, 0.8) }
    }
}
