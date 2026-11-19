import Foundation
import SwiftUI
import UIKit

enum WidgetAppGroup {
    static let id = "group.com.fares.lrc.player"
    static var defaults: UserDefaults? { UserDefaults(suiteName: id) }
}

enum WidgetKind {
    static let nowPlaying = "NowPlayingWidget.v2"
}

enum WidgetStateKey {
    static let snapshot = "widgetNowPlayingSnapshot"
    static let hasTrack = "widgetHasTrack"
    static let title = "widgetTitle"
    static let artist = "widgetArtist"
    static let isPlaying = "widgetIsPlaying"
    static let artworkData = "widgetArtworkData"
    static let lastWriteAt = "widgetLastWriteAt"
}

struct WidgetNowPlayingSnapshot: Codable {
    let hasTrack: Bool
    let title: String
    let artist: String
    let isPlaying: Bool
    let artworkData: Data?
    let updatedAt: TimeInterval
}

enum WidgetStateStore {
    private static let directoryName = "LRCplayerWidget"
    private static let fileName = "now-playing.json"

    private static var directoryURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: WidgetAppGroup.id)?
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    private static var fileURL: URL? {
        directoryURL?.appendingPathComponent(fileName, isDirectory: false)
    }

    static func read() -> WidgetNowPlayingSnapshot? {
        guard let fileURL,
              let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else {
            return nil
        }
        return try? JSONDecoder().decode(WidgetNowPlayingSnapshot.self, from: data)
    }

    @discardableResult
    static func write(_ snapshot: WidgetNowPlayingSnapshot) -> Bool {
        guard let directoryURL,
              let fileURL,
              let data = try? JSONEncoder().encode(snapshot) else {
            return false
        }
        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUnlessOpen])
            return true
        } catch {
            return false
        }
    }

    static func updatePlayback(isPlaying: Bool) {
        guard let snapshot = read(), snapshot.hasTrack else { return }
        let updated = WidgetNowPlayingSnapshot(
            hasTrack: snapshot.hasTrack,
            title: snapshot.title,
            artist: snapshot.artist,
            isPlaying: isPlaying,
            artworkData: snapshot.artworkData,
            updatedAt: Date().timeIntervalSince1970
        )
        write(updated)
        if let defaults = WidgetAppGroup.defaults,
           let data = try? JSONEncoder().encode(updated) {
            defaults.set(data, forKey: WidgetStateKey.snapshot)
            defaults.set(isPlaying, forKey: WidgetStateKey.isPlaying)
            defaults.set(updated.updatedAt, forKey: WidgetStateKey.lastWriteAt)
            defaults.synchronize()
        }
    }
}

struct WidgetNowPlayingState {
    var hasTrack = false
    var title = "VibePod"
    var artist = String(localized: "Nothing playing")
    var isPlaying = false
    var artwork: UIImage?
    var palette: [Color] = WidgetPalette.fallback

    static func read() -> WidgetNowPlayingState {
        var state = WidgetNowPlayingState()
        let ud = WidgetAppGroup.defaults

        let snapshotFromDefaults: WidgetNowPlayingSnapshot? = {
            guard let data = ud?.data(forKey: WidgetStateKey.snapshot) else { return nil }
            return try? JSONDecoder().decode(WidgetNowPlayingSnapshot.self, from: data)
        }()

        if let snapshot = WidgetStateStore.read() ?? snapshotFromDefaults {
            state.hasTrack = snapshot.hasTrack
            state.title = snapshot.title
            state.artist = snapshot.artist
            state.isPlaying = snapshot.isPlaying
            if let data = snapshot.artworkData, let image = UIImage(data: data) {
                state.artwork = image
                state.palette = WidgetPalette.palette(from: image)
            }
        } else {
            // Keep reading the original keys so existing installs migrate cleanly.
            state.hasTrack = ud?.bool(forKey: WidgetStateKey.hasTrack) ?? false
            state.title = ud?.string(forKey: WidgetStateKey.title) ?? "VibePod"
            state.artist = ud?.string(forKey: WidgetStateKey.artist) ?? ""
            state.isPlaying = ud?.bool(forKey: WidgetStateKey.isPlaying) ?? false
        }
        // The app stores an English placeholder when idle: show it in the widget's language.
        if !state.hasTrack { state.artist = String(localized: "Nothing playing") }

        if state.artwork == nil,
           let data = ud?.data(forKey: WidgetStateKey.artworkData),
           let image = UIImage(data: data) {
            state.artwork = image
            state.palette = WidgetPalette.palette(from: image)
        }
        return state
    }
}

enum WidgetPalette {
    static let fallback: [Color] = [
        Color(red: 0.34, green: 0.34, blue: 0.36),
        Color(red: 0.22, green: 0.22, blue: 0.24),
        Color(red: 0.09, green: 0.09, blue: 0.11)
    ]

    static func palette(from image: UIImage, sampleSize: Int = 12) -> [Color] {
        guard let cgImage = image.cgImage else { return fallback }
        let bytesPerPixel = 4
        let bytesPerRow = sampleSize * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: sampleSize * sampleSize * bytesPerPixel)
        guard let context = CGContext(
            data: &pixels,
            width: sampleSize,
            height: sampleSize,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return fallback }
        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: sampleSize, height: sampleSize))

        var buckets: [Int: (count: Int, red: Double, green: Double, blue: Double, sat: Double)] = [:]
        stride(from: 0, to: pixels.count, by: bytesPerPixel).forEach { index in
            let red = Double(pixels[index]) / 255
            let green = Double(pixels[index + 1]) / 255
            let blue = Double(pixels[index + 2]) / 255
            let maxChannel = max(red, green, blue)
            let minChannel = min(red, green, blue)
            let saturation = maxChannel == 0 ? 0 : (maxChannel - minChannel) / maxChannel
            guard maxChannel > 0.08, maxChannel < 0.96, saturation > 0.08 else { return }
            let key = (min(Int(red * 4), 3) << 4) | (min(Int(green * 4), 3) << 2) | min(Int(blue * 4), 3)
            var bucket = buckets[key] ?? (0, 0, 0, 0, 0)
            bucket.count += 1
            bucket.red += red
            bucket.green += green
            bucket.blue += blue
            bucket.sat += saturation
            buckets[key] = bucket
        }

        let candidates = buckets.values.map { bucket in
            (count: bucket.count, red: bucket.red / Double(bucket.count), green: bucket.green / Double(bucket.count), blue: bucket.blue / Double(bucket.count), sat: bucket.sat / Double(bucket.count))
        }
        .sorted { $0.count > $1.count }

        guard let dominant = candidates.first else { return fallback }
        var selected: [(red: Double, green: Double, blue: Double)] = [(dominant.red, dominant.green, dominant.blue)]
        for candidate in candidates.dropFirst() where selected.count < 3 {
            let distance = selected.map {
                abs($0.red - candidate.red) + abs($0.green - candidate.green) + abs($0.blue - candidate.blue)
            }.min() ?? 0
            guard distance > 0.18 else { continue }
            selected.append((candidate.red, candidate.green, candidate.blue))
        }

        var result: [Color] = []
        for color in selected {
            let source = UIColor(red: color.red, green: color.green, blue: color.blue, alpha: 1)
            var hue: CGFloat = 0
            var saturation: CGFloat = 0
            var brightness: CGFloat = 0
            var alpha: CGFloat = 0
            source.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
            let boosted = saturation > 0.06 ? min(saturation * 1.35, 1) : saturation
            result.append(Color(hue: Double(hue), saturation: Double(boosted), brightness: Double(min(brightness * 1.05, 1))))
        }
        while result.count < 3 {
            result.append(fallback[result.count])
        }
        return Array(result.prefix(3))
    }
}

// MARK: - Tap actions

/// What a tap on the Now Playing widget opens.
enum NowPlayingTapAction: String, CaseIterable, Identifiable {
    case lyrics
    case player
    case collection
    case album
    case app

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lyrics: String(localized: "Lyrics")
        case .player: String(localized: "Player")
        case .collection: String(localized: "Playlist or Album")
        case .album: String(localized: "Album")
        case .app: String(localized: "App Only")
        }
    }
}

/// The widget's tappable parts, each opening its chosen action.
enum WidgetTapZone: String, CaseIterable, Identifiable {
    case artwork
    case title
    case background

    var id: String { rawValue }

    var title: String {
        switch self {
        case .artwork: String(localized: "Artwork")
        case .title: String(localized: "Title & Artist")
        case .background: String(localized: "Rest of the Widget")
        }
    }

    var storageKey: String { "widgetTapAction.\(rawValue)" }

    var defaultAction: NowPlayingTapAction {
        switch self {
        case .artwork: .lyrics
        case .title: .collection
        case .background: .app
        }
    }

    /// Read when the tap arrives: the widget only says where it was tapped,
    /// so changing the setting needs no widget reload.
    var action: NowPlayingTapAction {
        UserDefaults.standard.string(forKey: storageKey).flatMap(NowPlayingTapAction.init(rawValue:)) ?? defaultAction
    }

    var url: URL { URL(string: "lrcplayer://widget?zone=\(rawValue)")! }
}
