import AVFoundation
import SwiftUI
import UIKit

/// Shares an imported song as a file carrying the edits made in the app:
/// title, artist, album, genre, year, numbers, cover and lyrics are written
/// into a copy (ID3 for MP3, iTunes atoms for M4A). The library's own file
/// isn't touched. Other formats go out as they are, with the LRC beside.
@MainActor
enum SongExporter {
    struct Tags: Sendable {
        var title: String
        var artist: String
        var album: String
        var albumArtist: String?
        var genre: String
        var year: Int
        var track: Int
        var disc: Int
        var cover: Data?
        var lyrics: String?
    }

    static func share(_ song: Song) {
        let library = AppModel.shared.libraryService
        let source = song.playableFileURL
        let lyricsURL = library.resolvedLyricsURL(for: song)
        let tags = Tags(
            title: song.title,
            artist: song.artist,
            album: song.album,
            albumArtist: song.albumArtist,
            genre: song.genre,
            year: song.year,
            track: song.trackNumber,
            disc: song.discNumber,
            cover: song.artworkData.flatMap { UIImage(data: $0)?.jpegData(compressionQuality: 0.9) },
            lyrics: lyricsURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        )
        library.activityMessage = String(localized: "Preparing…")
        Task {
            let items = await Task.detached(priority: .userInitiated) {
                await export(source: source, tags: tags, lyricsURL: lyricsURL)
            }.value
            library.activityMessage = nil
            guard !items.isEmpty else {
                AppModel.shared.importService.lastError = String(localized: "This song's file couldn't be exported.")
                return
            }
            present(items)
        }
    }

    private static func present(_ items: [URL]) {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first,
            var top = window.rootViewController else { return }
        while let presented = top.presentedViewController { top = presented }
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        if let popover = controller.popoverPresentationController {
            popover.sourceView = window
            popover.sourceRect = CGRect(x: window.bounds.midX, y: window.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        top.present(controller, animated: true)
    }

    // MARK: Export

    nonisolated private static func export(source: URL, tags: Tags, lyricsURL: URL?) async -> [URL] {
        guard FileManager.default.fileExists(atPath: source.path) else { return [] }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Share", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = fileName("\(tags.artist) - \(tags.title)")
        let ext = source.pathExtension.lowercased()

        switch ext {
        case "mp3":
            let output = folder.appendingPathComponent("\(base).mp3")
            guard let data = try? Data(contentsOf: source) else { return [] }
            guard (try? (ID3Writer.tag(tags) + ID3Writer.strippingTags(data)).write(to: output)) != nil else { return [] }
            return [output]
        case "m4a", "aac", "mp4", "alac":
            let output = folder.appendingPathComponent("\(base).m4a")
            if await exportM4A(source: source, to: output, tags: tags) { return [output] }
            fallthrough
        default:
            let output = folder.appendingPathComponent("\(base).\(ext.isEmpty ? "audio" : ext)")
            guard (try? FileManager.default.copyItem(at: source, to: output)) != nil else { return [] }
            var items = [output]
            if let lyricsURL {
                let lrc = folder.appendingPathComponent("\(base).lrc")
                if (try? FileManager.default.copyItem(at: lyricsURL, to: lrc)) != nil { items.append(lrc) }
            }
            return items
        }
    }

    nonisolated private static func fileName(_ text: String) -> String {
        let cleaned = text.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined(separator: " ")
        return String(cleaned.trimmingCharacters(in: .whitespaces).prefix(120))
    }

    nonisolated private static func exportM4A(source: URL, to output: URL, tags: Tags) async -> Bool {
        let asset = AVURLAsset(url: source)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else { return false }
        var items: [AVMetadataItem] = []
        func add(_ identifier: AVMetadataIdentifier, _ value: (NSCopying & NSObjectProtocol)?, dataType: String? = nil) {
            guard let value else { return }
            let item = AVMutableMetadataItem()
            item.identifier = identifier
            item.value = value
            if let dataType { item.dataType = dataType }
            items.append(item)
        }
        add(.iTunesMetadataSongName, tags.title as NSString)
        add(.iTunesMetadataArtist, tags.artist as NSString)
        add(.iTunesMetadataAlbum, tags.album as NSString)
        add(.iTunesMetadataAlbumArtist, tags.albumArtist.map { $0 as NSString })
        if !tags.genre.isEmpty { add(.iTunesMetadataUserGenre, tags.genre as NSString) }
        if tags.year > 0 { add(.iTunesMetadataReleaseDate, String(tags.year) as NSString) }
        if tags.track > 0 { add(.iTunesMetadataTrackNumber, numberPair(tags.track) as NSData) }
        if tags.disc > 0 { add(.iTunesMetadataDiscNumber, numberPair(tags.disc) as NSData) }
        add(.iTunesMetadataCoverArt, tags.cover.map { $0 as NSData }, dataType: kCMMetadataBaseDataType_JPEG as String)
        add(.iTunesMetadataLyrics, tags.lyrics.map { $0 as NSString })
        session.metadata = items
        do {
            try await session.export(to: output, as: .m4a)
            return true
        } catch {
            try? FileManager.default.removeItem(at: output)
            return false
        }
    }

    /// iTunes' track and disc atom: number, then total (unknown here).
    nonisolated private static func numberPair(_ number: Int) -> Data {
        let value = UInt16(clamping: number)
        return Data([0, 0, UInt8(value >> 8), UInt8(value & 0xFF), 0, 0, 0, 0])
    }
}

/// A minimal ID3v2.3 writer: text frames, cover and lyrics.
enum ID3Writer {
    static func tag(_ tags: SongExporter.Tags) -> Data {
        var frames = Data()
        func text(_ id: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            frames += frame(id, Data([0x01]) + utf16(value))
        }
        text("TIT2", tags.title)
        text("TPE1", tags.artist)
        text("TALB", tags.album)
        text("TPE2", tags.albumArtist)
        text("TCON", tags.genre)
        if tags.year > 0 { text("TYER", String(tags.year)) }
        if tags.track > 0 { text("TRCK", String(tags.track)) }
        if tags.disc > 0 { text("TPOS", String(tags.disc)) }
        if let cover = tags.cover {
            frames += frame("APIC", Data([0x00]) + Data("image/jpeg".utf8) + Data([0x00, 0x03, 0x00]) + cover)
        }
        if let lyrics = tags.lyrics, !lyrics.isEmpty {
            frames += frame("USLT", Data([0x01]) + Data("eng".utf8) + utf16("") + utf16(lyrics, terminated: false))
        }
        return Data("ID3".utf8) + Data([0x03, 0x00, 0x00]) + syncSafe(frames.count) + frames
    }

    /// The audio without its old ID3v2 header and ID3v1 trailer.
    static func strippingTags(_ data: Data) -> Data {
        var audio = data
        if audio.count > 10, audio.prefix(3) == Data("ID3".utf8) {
            let bytes = [UInt8](audio[audio.startIndex + 6 ..< audio.startIndex + 10])
            var size = bytes.reduce(0) { ($0 << 7) | Int($1 & 0x7F) } + 10
            if audio[audio.startIndex + 5] & 0x10 != 0 { size += 10 }
            audio = size < audio.count ? audio.dropFirst(size) : audio
        }
        if audio.count > 128, audio.suffix(128).prefix(3) == Data("TAG".utf8) {
            audio = audio.dropLast(128)
        }
        return Data(audio)
    }

    private static func frame(_ id: String, _ body: Data) -> Data {
        let size = UInt32(body.count)
        return Data(id.utf8) + Data([UInt8(size >> 24), UInt8((size >> 16) & 0xFF), UInt8((size >> 8) & 0xFF), UInt8(size & 0xFF), 0, 0]) + body
    }

    /// UTF-16 with its byte order mark, ended by two zero bytes.
    private static func utf16(_ text: String, terminated: Bool = true) -> Data {
        var data = Data([0xFF, 0xFE])
        for unit in text.utf16 { data += Data([UInt8(unit & 0xFF), UInt8(unit >> 8)]) }
        if terminated { data += Data([0, 0]) }
        return data
    }

    private static func syncSafe(_ value: Int) -> Data {
        Data([UInt8((value >> 21) & 0x7F), UInt8((value >> 14) & 0x7F), UInt8((value >> 7) & 0x7F), UInt8(value & 0x7F)])
    }
}

/// The system photo picker with its square crop step.
struct CroppingPhotoPicker: UIViewControllerRepresentable {
    let onPick: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .photoLibrary
        picker.allowsEditing = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CroppingPhotoPicker
        init(_ parent: CroppingPhotoPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = (info[.editedImage] ?? info[.originalImage]) as? UIImage { parent.onPick(image) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
