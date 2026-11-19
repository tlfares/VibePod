import Foundation
import SwiftUI
import AVFoundation
import UniformTypeIdentifiers
import UIKit

enum SongSource: String, Codable {
    case appFile
    case mediaLibrary
}

struct Song: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var artist: String
    var album: String
    var genre: String
    var duration: TimeInterval
    var fileURL: URL
    var addedAt: Date
    var lastPlayedAt: Date?
    var playCount: Int
    var trackNumber: Int
    var discNumber: Int
    var year: Int
    var lrcFilePath: String?
    var fileSize: Int64
    var format: String
    var source: SongSource?
    var mediaLibraryPersistentID: UInt64?
    var albumArtist: String?

    init(
        id: UUID = UUID(),
        title: String = "Unknown Title",
        artist: String = "Unknown Artist",
        album: String = "Unknown Album",
        albumArtist: String? = nil,
        genre: String = "",
        duration: TimeInterval = 0,
        fileURL: URL,
        artworkData: Data? = nil,
        addedAt: Date = Date(),
        lastPlayedAt: Date? = nil,
        playCount: Int = 0,
        trackNumber: Int = 0,
        discNumber: Int = 0,
        year: Int = 0,
        lrcFilePath: String? = nil,
        fileSize: Int64 = 0,
        format: String = "",
        source: SongSource? = nil,
        mediaLibraryPersistentID: UInt64? = nil
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.genre = genre
        self.duration = duration
        self.fileURL = fileURL
        ArtworkStore.store(artworkData, for: id)
        self.addedAt = addedAt
        self.lastPlayedAt = lastPlayedAt
        self.playCount = playCount
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.year = year
        self.lrcFilePath = lrcFilePath
        self.fileSize = fileSize
        self.format = format
        self.source = source
        self.mediaLibraryPersistentID = mediaLibraryPersistentID
        self.albumArtist = albumArtist
    }

    /// `fileURL`, rebased on the current Documents folder when the stored
    /// absolute path points into an old app container (reinstall, restore).
    var playableFileURL: URL {
        guard fileURL.isFileURL, !FileManager.default.fileExists(atPath: fileURL.path) else { return fileURL }
        let components = fileURL.pathComponents
        guard let index = components.lastIndex(of: "Documents"), index + 1 < components.count else { return fileURL }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let candidate = components[(index + 1)...].reduce(documents) { $0.appendingPathComponent($1) }
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : fileURL
    }

    var sourceKind: SongSource {
        if let source { return source }
        return mediaLibraryPersistentID == nil ? .appFile : .mediaLibrary
    }

    var isMediaLibraryItem: Bool {
        sourceKind == .mediaLibrary
    }

    /// Artwork bytes for this song. Not persisted in songs.json anymore: it is
    /// served lazily from disk (one file per song) with an in-memory cache, so
    /// launch no longer base64-decodes the whole library.
    var artworkData: Data? {
        ArtworkStore.data(for: id)
    }

    var artworkSource: ArtworkSource { .song(id) }

    /// Decodes arbitrary artwork bytes at a display-friendly size. Prefer
    /// `artworkSource` + `ArtworkImage`/`ArtworkImageLoader`, which cache by ID.
    static func artworkImage(from data: Data?) -> UIImage? {
        guard let data, !data.isEmpty else { return nil }
        return ArtworkImageCache.downsample(data, maxPixelSize: 900)
    }

    var artwork: Image? {
        guard let image = ArtworkImageCache.shared.imageSync(for: artworkSource, points: 300) else { return nil }
        return Image(uiImage: image)
    }

    var playerArtworkColors: [Color] {
        Self.playerArtworkUIColors(for: artworkSource).map { Color($0) }
    }

    /// The flat tint used as the album / artist / playlist detail page backdrop,
    /// derived from the artwork's dominant color.
    var albumBackgroundUIColor: UIColor {
        Self.albumBackgroundUIColor(for: artworkSource)
    }

    static func albumBackgroundUIColor(for source: ArtworkSource?) -> UIColor {
        guard let source else { return .black }
        let key = "bg-\(source.cacheKey)" as NSString
        if let cached = ArtworkPaletteCache.colors.object(forKey: key)?.firstObject as? UIColor {
            return cached
        }
        guard let image = paletteSampleImage(for: source) else { return .black }
        let color = pageUIColor(for: image)
        ArtworkPaletteCache.colors.setObject([color] as NSArray, forKey: key)
        return color
    }

    /// The page backdrop for any image: its dominant color, dark and rich.
    static func pageUIColor(for image: UIImage) -> UIColor {
        let base = UIColor(image.musicPalette.first ?? fallbackArtworkColors[0])
        var hue = CGFloat(0)
        var saturation = CGFloat(0)
        var brightness = CGFloat(0)
        var alpha = CGFloat(0)
        base.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)

        let color: UIColor
        if saturation < 0.12 {
            color = UIColor(
                white: brightness > 0.65 ? 0.22 : max(min(brightness * 0.48, 0.24), 0.13),
                alpha: 1
            )
        } else {
            color = UIColor(
                hue: hue,
                saturation: min(max(saturation * 1.10, 0.38), 0.86),
                brightness: max(min(brightness * 0.34, 0.27), 0.12),
                alpha: 1
            )
        }
        return color
    }

    /// A tiny decode is all the palette code samples (it draws into 24x24).
    fileprivate static func paletteSampleImage(for source: ArtworkSource) -> UIImage? {
        ArtworkImageCache.shared.imageSync(for: source, points: 32)
    }

    var formattedDuration: String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    var formattedFileSize: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: fileSize)
    }

    static func == (lhs: Song, rhs: Song) -> Bool {
        lhs.id == rhs.id
    }

    enum CodingKeys: String, CodingKey {
        case id, title, artist, album, genre, duration
        case fileURL, artworkData, addedAt, lastPlayedAt
        case playCount, trackNumber, discNumber, year, lrcFilePath
        case fileSize, format, source, mediaLibraryPersistentID, albumArtist
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        artist = try c.decode(String.self, forKey: .artist)
        album = try c.decode(String.self, forKey: .album)
        genre = try c.decode(String.self, forKey: .genre)
        duration = try c.decode(TimeInterval.self, forKey: .duration)
        fileURL = try c.decode(URL.self, forKey: .fileURL)
        addedAt = try c.decode(Date.self, forKey: .addedAt)
        lastPlayedAt = try c.decodeIfPresent(Date.self, forKey: .lastPlayedAt)
        playCount = try c.decode(Int.self, forKey: .playCount)
        trackNumber = try c.decode(Int.self, forKey: .trackNumber)
        discNumber = try c.decodeIfPresent(Int.self, forKey: .discNumber) ?? 0
        year = try c.decode(Int.self, forKey: .year)
        lrcFilePath = try c.decodeIfPresent(String.self, forKey: .lrcFilePath)
        fileSize = try c.decode(Int64.self, forKey: .fileSize)
        format = try c.decode(String.self, forKey: .format)
        source = try c.decodeIfPresent(SongSource.self, forKey: .source)
        mediaLibraryPersistentID = try c.decodeIfPresent(UInt64.self, forKey: .mediaLibraryPersistentID)
        albumArtist = try c.decodeIfPresent(String.self, forKey: .albumArtist)
        if let legacyArtwork = try c.decodeIfPresent(Data.self, forKey: .artworkData) {
            ArtworkStore.spillLegacy(legacyArtwork, for: id)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(artist, forKey: .artist)
        try c.encode(album, forKey: .album)
        try c.encode(genre, forKey: .genre)
        try c.encode(duration, forKey: .duration)
        try c.encode(fileURL, forKey: .fileURL)
        try c.encode(addedAt, forKey: .addedAt)
        try c.encodeIfPresent(lastPlayedAt, forKey: .lastPlayedAt)
        try c.encode(playCount, forKey: .playCount)
        try c.encode(trackNumber, forKey: .trackNumber)
        try c.encode(discNumber, forKey: .discNumber)
        try c.encode(year, forKey: .year)
        try c.encodeIfPresent(lrcFilePath, forKey: .lrcFilePath)
        try c.encode(fileSize, forKey: .fileSize)
        try c.encode(format, forKey: .format)
        try c.encodeIfPresent(source, forKey: .source)
        try c.encodeIfPresent(mediaLibraryPersistentID, forKey: .mediaLibraryPersistentID)
        try c.encodeIfPresent(albumArtist, forKey: .albumArtist)
    }
}

enum ArtworkPaletteCache {
    nonisolated(unsafe) static let colors: NSCache<NSString, NSArray> = {
        let cache = NSCache<NSString, NSArray>()
        cache.countLimit = 400
        return cache
    }()
}

extension Song {
    static let fallbackArtworkColors: [Color] = [
        Color(red: 0.34, green: 0.34, blue: 0.36),
        Color(red: 0.22, green: 0.22, blue: 0.24),
        Color(red: 0.18, green: 0.18, blue: 0.20),
        Color(red: 0.09, green: 0.09, blue: 0.11)
    ]

    static let fallbackArtworkUIColors: [UIColor] = [
        UIColor(red: 0.34, green: 0.34, blue: 0.36, alpha: 1),
        UIColor(red: 0.22, green: 0.22, blue: 0.24, alpha: 1),
        UIColor(red: 0.18, green: 0.18, blue: 0.20, alpha: 1),
        UIColor(red: 0.09, green: 0.09, blue: 0.11, alpha: 1)
    ]

    static func playerArtworkUIColors(for source: ArtworkSource?) -> [UIColor] {
        guard let source else { return fallbackArtworkUIColors }
        let key = "player-\(source.cacheKey)" as NSString
        if let cached = ArtworkPaletteCache.colors.object(forKey: key) as? [UIColor] {
            return cached
        }
        guard let image = paletteSampleImage(for: source) else {
            return fallbackArtworkUIColors
        }
        let colors = image.playerMusicPalette.map { color -> UIColor in
            let ui = UIColor(color)
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            ui.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
            return UIColor(hue: h, saturation: s * 0.88, brightness: b, alpha: a)
        }
        let result = colors.isEmpty ? fallbackArtworkUIColors : colors
        ArtworkPaletteCache.colors.setObject(result as NSArray, forKey: key)
        return result
    }

    /// The player's colors from any picture (a music video's frame), the
    /// same way as from a cover.
    nonisolated static func playerUIColors(from image: UIImage) -> [UIColor] {
        image.playerMusicPalette.map { color -> UIColor in
            let ui = UIColor(color)
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            ui.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
            return UIColor(hue: h, saturation: s * 0.88, brightness: b, alpha: a)
        }
    }

    static var supportedAudioExtensions: [String] {
        ["mp3", "m4a", "m4b", "aac", "wav", "aiff", "aif", "caf",
         "alac", "flac", "wma", "ogg", "opus", "ac3"]
    }

    static var supportedAudioUTTypes: [UTType] {
        [.mp3, .wav, .aiff,
         UTType(filenameExtension: "aif")!,
         UTType(filenameExtension: "caf")!,
         UTType(filenameExtension: "m4a")!,
         UTType(filenameExtension: "m4b")!,
         UTType(filenameExtension: "aac")!,
         UTType(filenameExtension: "flac")!,
         UTType(filenameExtension: "alac")!,
         UTType(filenameExtension: "ogg")!,
         UTType(filenameExtension: "opus")!,
         UTType(filenameExtension: "wma")!,
         UTType(filenameExtension: "ac3")!]
    }
}

private extension UIImage {
    var musicPalette: [Color] {
        guard let cgImage else { return Song.fallbackArtworkColors }

        let width = 18
        let height = 18
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: width * height * bytesPerPixel)
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return Song.fallbackArtworkColors
        }

        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var samples: [(red: Double, green: Double, blue: Double, vibrance: Double)] = []
        samples.reserveCapacity(width * height)

        stride(from: 0, to: pixels.count, by: bytesPerPixel).forEach { index in
            let red = Double(pixels[index]) / 255
            let green = Double(pixels[index + 1]) / 255
            let blue = Double(pixels[index + 2]) / 255
            let maxChannel = max(red, green, blue)
            let minChannel = min(red, green, blue)
            let saturation = maxChannel == 0 ? 0 : (maxChannel - minChannel) / maxChannel
            let brightness = (red + green + blue) / 3
            let vibrance = saturation * 0.72 + min(1, brightness) * 0.28

            guard brightness > 0.12, brightness < 0.92, saturation > 0.12 else { return }
            samples.append((red, green, blue, vibrance))
        }

        let selected = samples
            .sorted { $0.vibrance > $1.vibrance }
            .prefix(12)
            .reduce(into: [(red: Double, green: Double, blue: Double)]()) { colors, sample in
                let isDistinct = colors.allSatisfy { existing in
                    abs(existing.red - sample.red) + abs(existing.green - sample.green) + abs(existing.blue - sample.blue) > 0.42
                }
                if isDistinct {
                    colors.append((sample.red, sample.green, sample.blue))
                }
            }

        let colors = selected.prefix(3).map {
            Color(red: min($0.red * 1.08, 1), green: min($0.green * 1.08, 1), blue: min($0.blue * 1.08, 1))
        }

        guard !colors.isEmpty else { return Song.fallbackArtworkColors }
        return Array((colors + Song.fallbackArtworkColors).prefix(3))
    }

    var playerMusicPalette: [Color] {
        guard let cgImage else { return Song.fallbackArtworkColors }

        let width = 24
        let height = 24
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: width * height * bytesPerPixel)
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return Song.fallbackArtworkColors
        }

        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        struct ColorBucket {
            var count = 0
            var red = 0.0
            var green = 0.0
            var blue = 0.0
            var saturation = 0.0
        }
        var buckets: [Int: ColorBucket] = [:]

        stride(from: 0, to: pixels.count, by: bytesPerPixel).forEach { index in
            let red = Double(pixels[index]) / 255
            let green = Double(pixels[index + 1]) / 255
            let blue = Double(pixels[index + 2]) / 255
            let maxChannel = max(red, green, blue)
            let minChannel = min(red, green, blue)
            let saturation = maxChannel == 0 ? 0 : (maxChannel - minChannel) / maxChannel
            let brightness = maxChannel

            guard brightness > 0.055, brightness < 0.97 else { return }
            let redBin = min(Int(red * 4), 3)
            let greenBin = min(Int(green * 4), 3)
            let blueBin = min(Int(blue * 4), 3)
            let key = (redBin << 4) | (greenBin << 2) | blueBin
            var bucket = buckets[key, default: ColorBucket()]
            bucket.count += 1
            bucket.red += red
            bucket.green += green
            bucket.blue += blue
            bucket.saturation += saturation
            buckets[key] = bucket
        }

        let candidates = buckets.values.map { bucket in
            let divisor = Double(bucket.count)
            return (
                red: bucket.red / divisor,
                green: bucket.green / divisor,
                blue: bucket.blue / divisor,
                count: bucket.count,
                saturation: bucket.saturation / divisor
            )
        }
        .sorted { $0.count > $1.count }

        guard let dominant = candidates.first else { return Song.fallbackArtworkColors }
        var selected = [(red: dominant.red, green: dominant.green, blue: dominant.blue)]
        var remaining = Array(candidates.dropFirst()).filter {
            $0.count >= max(2, dominant.count / 12)
        }

        while selected.count < 4, !remaining.isEmpty {
            let bestIndex = remaining.indices.max { lhs, rhs in
                func score(_ sample: (red: Double, green: Double, blue: Double, count: Int, saturation: Double)) -> Double {
                    let nearestDistance = selected.map { color in
                        abs(color.red - sample.red)
                            + abs(color.green - sample.green)
                            + abs(color.blue - sample.blue)
                    }.min() ?? 0
                    return Double(sample.count)
                        * (0.82 + sample.saturation * 0.18)
                        * (0.58 + nearestDistance * 1.35)
                }
                return score(remaining[lhs]) < score(remaining[rhs])
            }
            guard let bestIndex else { break }
            let sample = remaining.remove(at: bestIndex)
            let distance = selected.map { color in
                abs(color.red - sample.red)
                    + abs(color.green - sample.green)
                    + abs(color.blue - sample.blue)
            }.min() ?? 0
            guard distance > 0.20 else { continue }
            selected.append((sample.red, sample.green, sample.blue))
        }

        let first = selected[0]
        var palette = selected
        while palette.count < 4 {
            let factor: Double
            switch palette.count {
            case 1: factor = 0.76
            case 2: factor = 1.14
            default: factor = 0.88
            }
            palette.append((
                red: min(first.red * factor, 1),
                green: min(first.green * factor, 1),
                blue: min(first.blue * factor, 1)
            ))
        }
        return palette.prefix(4).map { sample in
            let source = UIColor(red: sample.red, green: sample.green, blue: sample.blue, alpha: 1)
            var hue = CGFloat(0)
            var saturation = CGFloat(0)
            var brightness = CGFloat(0)
            var alpha = CGFloat(0)
            source.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
            let enhancedSaturation = saturation > 0.06
                ? max(min(saturation * 1.62, 1), 0.30)
                : saturation
            return Color(
                hue: Double(hue),
                saturation: Double(enhancedSaturation),
                brightness: Double(min(brightness * 1.06, 1)),
                opacity: Double(alpha)
            )
        }
    }
}

enum LyricsKind: Sendable { case none, unsynced, synced }

/// Remembers whether each LRC file is synced. Song rows used to read the
/// lyrics file from disk on every cell configure just to pick an icon.
enum LyricsKindCache {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var kinds: [String: LyricsKind] = [:]

    static func kind(forStoredPath path: String, resolve: () -> URL?) -> LyricsKind {
        lock.lock()
        if let cached = kinds[path] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let kind: LyricsKind
        if let url = resolve(),
           let data = try? Data(contentsOf: url, options: .uncached),
           let content = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) {
            let hasTime = content.range(of: #"\[\d{1,3}:\d{2}([.:]\d{1,3})?\]"#, options: .regularExpression) != nil
            kind = hasTime ? .synced : .unsynced
        } else {
            kind = .none
        }
        lock.lock()
        kinds[path] = kind
        lock.unlock()
        return kind
    }

    static func invalidate(storedPath path: String?) {
        guard let path else { return }
        lock.lock()
        kinds[path] = nil
        lock.unlock()
    }
}

extension Song {
    var lyricsKind: LyricsKind {
        guard let path = lrcFilePath, !path.isEmpty else { return .none }
        return LyricsKindCache.kind(forStoredPath: path) { resolvedLyricsFileURL() }
    }

    func resolvedLyricsFileURL() -> URL? {
        guard let path = lrcFilePath, !path.isEmpty else { return nil }
        let fm = FileManager.default
        if path.hasPrefix("/") {
            return fm.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
        }
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        let url = docs.appendingPathComponent(path)
        return fm.fileExists(atPath: url.path) ? url : nil
    }
}
