import Foundation
import ImageIO
import SwiftUI
import UIKit

/// Per-song artwork bytes stored as one file per song instead of embedded in
/// songs.json. Launching the app used to base64-decode every artwork in the
/// library on the main thread; now songs.json holds no artwork at all and each
/// image is read lazily from disk on first access (then cached).
///
/// `nil` behaves exactly like a song whose `artworkData` was `nil`, so nothing
/// else in the app needs to know where the bytes live.
enum ArtworkStore {
    private static let lock = NSLock()
    private nonisolated(unsafe) static let cache: NSCache<NSUUID, NSData> = {
        let cache = NSCache<NSUUID, NSData>()
        cache.totalCostLimit = 48 * 1024 * 1024
        return cache
    }()
    /// IDs known to have no artwork on disk, so rows without a cover don't hit
    /// the file system on every configure.
    private nonisolated(unsafe) static var missingIDs = Set<UUID>()

    private static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("Artwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// How many times each song's cover was replaced since launch: part of
    /// its cache key, so every surface draws the new cover instead of the
    /// image it decoded before.
    private nonisolated(unsafe) static var revisions: [UUID: Int] = [:]

    /// Posted on the main thread with the `Set<UUID>` of songs whose cover
    /// changed.
    static let didChange = Notification.Name("ArtworkStoreDidChange")

    static func revision(for id: UUID) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return revisions[id] ?? 0
    }

    /// True once a legacy song with an embedded base64 artwork has been moved to
    /// disk. Used to trigger the one-time lightweight re-save of songs.json.
    private nonisolated(unsafe) static var didSpillLegacyData = false

    static var spilledLegacyData: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didSpillLegacyData
    }

    private static func fileURL(for id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString).appendingPathExtension("jpg")
    }

    /// Cache + persist bytes for a song. No-ops on nil so callers can keep
    /// passing the optional artwork through the `Song` initializer.
    static func store(_ data: Data?, for id: UUID) {
        guard let data, !data.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        missingIDs.remove(id)
        cache.setObject(data as NSData, forKey: id as NSUUID, cost: data.count)
        let url = fileURL(for: id)
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Legacy-JSON migration: remember that an embedded artwork was seen, cache
    /// it, and write the file on first encounter (idempotent across relaunches).
    static func spillLegacy(_ data: Data?, for id: UUID) {
        guard data?.isEmpty == false else { return }
        lock.lock()
        didSpillLegacyData = true
        lock.unlock()
        store(data, for: id)
    }

    static func data(for id: UUID) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache.object(forKey: id as NSUUID) {
            return cached as Data
        }
        guard !missingIDs.contains(id) else { return nil }
        guard let data = try? Data(contentsOf: fileURL(for: id), options: .mappedIfSafe), !data.isEmpty else {
            missingIDs.insert(id)
            return nil
        }
        cache.setObject(data as NSData, forKey: id as NSUUID, cost: data.count)
        return data
    }

    /// A cover the user picked: replaces whatever was stored.
    static func replace(_ data: Data, for id: UUID) {
        replace(data, for: [id])
    }

    /// One cover for several songs (an album), announced once.
    static func replace(_ data: Data, for ids: [UUID]) {
        for id in ids {
            discard(id)
            store(data, for: id)
        }
        announce(ids)
    }

    static func remove(for id: UUID) {
        discard(id)
        announce([id])
    }

    private static func discard(_ id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        cache.removeObject(forKey: id as NSUUID)
        missingIDs.insert(id)
        revisions[id, default: 0] += 1
        try? FileManager.default.removeItem(at: fileURL(for: id))
        ArtworkImageCache.shared.removeImages(forKeyPrefix: id.uuidString)
    }

    private static func announce(_ ids: [UUID]) {
        let changed = Set(ids)
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: didChange, object: changed)
        }
    }
}

// MARK: - Artwork source

/// Identifies one artwork image independently of its bytes. Image caches are
/// keyed by this string instead of by the image data itself: hashing `Data`
/// only looks at its first bytes, so every JPEG with the same header collided
/// and each lookup ended up comparing whole images byte by byte.
struct ArtworkSource: Hashable, @unchecked Sendable {
    fileprivate enum Kind {
        case song(UUID)
        case data(Data)
        /// 2x2 cover mosaic (playlists without their own artwork).
        case mosaic([UUID])
        /// Generated Autolist cover.
        case generated(GeneratedCover)
    }

    let cacheKey: String
    fileprivate let kind: Kind

    static func song(_ id: UUID) -> ArtworkSource {
        let revision = ArtworkStore.revision(for: id)
        return ArtworkSource(cacheKey: revision == 0 ? id.uuidString : "\(id.uuidString)~\(revision)", kind: .song(id))
    }

    /// Artwork that only exists in memory (playlist covers). The data length is
    /// part of the key so a refreshed cover never shows the stale image.
    static func data(_ data: Data, id: UUID) -> ArtworkSource {
        ArtworkSource(cacheKey: "\(id.uuidString)-\(data.count)", kind: .data(data))
    }

    /// An artist photo downloaded by `ArtistImageService`.
    static func artist(_ name: String, data: Data) -> ArtworkSource {
        ArtworkSource(cacheKey: "artist-\(name.lowercased())-\(data.count)", kind: .data(data))
    }

    static func mosaic(_ songIDs: [UUID]) -> ArtworkSource {
        ArtworkSource(cacheKey: "mosaic-" + songIDs.prefix(4).map { song($0).cacheKey }.joined(separator: "-"), kind: .mosaic(songIDs))
    }

    /// This artwork as stored now: a cover replaced since gets its new key.
    var current: ArtworkSource {
        switch kind {
        case let .song(id): .song(id)
        case let .mosaic(ids): .mosaic(ids)
        case .data, .generated: self
        }
    }

    /// Whether it draws the cover of one of these songs.
    func shows(any ids: Set<UUID>) -> Bool {
        switch kind {
        case let .song(id): ids.contains(id)
        case let .mosaic(songIDs): songIDs.prefix(4).contains(where: ids.contains)
        case .data, .generated: false
        }
    }

    /// Drawn at the displayed size, so it is never blurry; the key changes
    /// with anything drawn on it.
    static func generated(_ cover: GeneratedCover) -> ArtworkSource {
        ArtworkSource(cacheKey: cover.cacheKey, kind: .generated(cover))
    }

    func loadData() -> Data? {
        switch kind {
        case let .song(id): ArtworkStore.data(for: id)
        case let .data(data): data
        case .mosaic, .generated: nil
        }
    }

    static func == (lhs: ArtworkSource, rhs: ArtworkSource) -> Bool {
        lhs.cacheKey == rhs.cacheKey
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(cacheKey)
    }
}

// MARK: - Decoded image cache

/// Downsampled, display-ready artwork images. Decoding a 1500px cover to show
/// it at 42pt in a row is what made scrolling hitch; every surface now asks for
/// the pixel size it actually draws.
final class ArtworkImageCache: @unchecked Sendable {
    static let shared = ArtworkImageCache()

    private let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 96 * 1024 * 1024
        return cache
    }()
    private let keysLock = NSLock()
    private var keys = Set<String>()
    private let decodeQueue = DispatchQueue(label: "com.fares.lrc.player.artwork", qos: .userInitiated, attributes: .concurrent)

    /// Pixel buckets: a handful of sizes keeps the cache hit rate high while
    /// never decoding much more than what is drawn.
    static func pixelSize(forPoints points: CGFloat) -> Int {
        let pixels = points * 3
        for bucket in [96, 192, 384, 600, 900] where CGFloat(bucket) >= pixels {
            return bucket
        }
        return 1400
    }

    private func key(for source: ArtworkSource, pixels: Int) -> NSString {
        "\(source.cacheKey)@\(pixels)" as NSString
    }

    func cachedImage(for source: ArtworkSource, points: CGFloat) -> UIImage? {
        let pixels = Self.pixelSize(forPoints: points)
        if let image = cache.object(forKey: key(for: source, pixels: pixels)) {
            return image
        }
        // A bigger decode already in memory is a perfectly good stand-in.
        for bucket in [192, 384, 600, 900, 1400] where bucket > pixels {
            if let image = cache.object(forKey: key(for: source, pixels: bucket)) {
                return image
            }
        }
        return nil
    }

    /// Synchronous decode. Prefer `image(for:points:)` (async) in scrolling
    /// surfaces; this is for places that must have the image right away.
    func imageSync(for source: ArtworkSource, points: CGFloat) -> UIImage? {
        if let cached = cachedImage(for: source, points: points) { return cached }
        return decode(source, pixels: Self.pixelSize(forPoints: points))
    }

    func image(for source: ArtworkSource, points: CGFloat) async -> UIImage? {
        if let cached = cachedImage(for: source, points: points) { return cached }
        let pixels = Self.pixelSize(forPoints: points)
        return await withCheckedContinuation { continuation in
            decodeQueue.async { [self] in
                continuation.resume(returning: decode(source, pixels: pixels))
            }
        }
    }

    private func decode(_ source: ArtworkSource, pixels: Int) -> UIImage? {
        let decoded: UIImage?
        if case let .mosaic(songIDs) = source.kind {
            decoded = composeMosaic(songIDs, pixels: pixels)
        } else if case let .generated(cover) = source.kind {
            decoded = GeneratedCoverRenderer.image(for: cover, pixels: pixels)
        } else if let data = source.loadData(), !data.isEmpty {
            decoded = Self.downsample(data, maxPixelSize: pixels)
        } else {
            decoded = nil
        }
        guard let image = decoded else { return nil }
        let key = key(for: source, pixels: pixels)
        let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
        cache.setObject(image, forKey: key, cost: cost)
        keysLock.lock()
        keys.insert(key as String)
        keysLock.unlock()
        return image
    }

    private func composeMosaic(_ songIDs: [UUID], pixels: Int) -> UIImage? {
        let tiles = songIDs.prefix(4).compactMap { id -> UIImage? in
            guard let data = ArtworkStore.data(for: id) else { return nil }
            return Self.downsample(data, maxPixelSize: max(48, pixels / 2))
        }
        guard tiles.count == 4 else { return tiles.first }
        let side = CGFloat(pixels)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
            let half = side / 2
            for (index, tile) in tiles.enumerated() {
                let rect = CGRect(x: CGFloat(index % 2) * half, y: CGFloat(index / 2) * half, width: half, height: half)
                tile.draw(in: rect)
            }
        }
    }

    func removeImages(forKeyPrefix prefix: String) {
        keysLock.lock()
        let matching = keys.filter { $0.hasPrefix(prefix) }
        keys.subtract(matching)
        keysLock.unlock()
        matching.forEach { cache.removeObject(forKey: $0 as NSString) }
    }

    static func downsample(_ data: Data, maxPixelSize: Int) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

// MARK: - SwiftUI artwork view

/// Square artwork that decodes off the main thread at the size it is drawn.
/// The placeholder matches Apple Music's gray tile with a music note.
struct ArtworkImage: View {
    let source: ArtworkSource?
    var cornerRadius: CGFloat = 8
    var placeholderSymbol = "music.note"
    /// Expected rendered side length; drives the decode size.
    var points: CGFloat = 160

    @State private var image: UIImage?
    @State private var loadedKey: String?
    /// Bumped when the cover drawn here is replaced.
    @State private var coverChanges = 0

    init(source: ArtworkSource?, cornerRadius: CGFloat = 8, points: CGFloat = 160, placeholderSymbol: String = "music.note") {
        self.source = source
        self.cornerRadius = cornerRadius
        self.points = points
        self.placeholderSymbol = placeholderSymbol
        // Seed from the memory cache so already-decoded covers draw on the very
        // first frame (no placeholder flash while scrolling back).
        if let source, let cached = ArtworkImageCache.shared.cachedImage(for: source, points: points) {
            _image = State(initialValue: cached)
            _loadedKey = State(initialValue: source.cacheKey)
        }
    }

    var body: some View {
        let _ = coverChanges
        // A cover replaced since the parent built this view draws anew.
        let source = self.source?.current
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        // When the source changes on a live view (mini player, pager), use any
        // decode already in memory instead of flashing the placeholder.
        let displayed = loadedKey == source?.cacheKey
            ? image
            : source.flatMap { ArtworkImageCache.shared.cachedImage(for: $0, points: points) }
        ZStack {
            if let displayed {
                Image(uiImage: displayed)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                shape.fill(Color(uiColor: .tertiarySystemFill))
                Image(systemName: placeholderSymbol)
                    .font(.system(size: max(12, points * 0.3), weight: .medium))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .clipShape(shape)
        .contentShape(shape)
        .task(id: source?.cacheKey) {
            guard let source else {
                image = nil
                loadedKey = nil
                return
            }
            guard loadedKey != source.cacheKey || image == nil else { return }
            let decoded = await ArtworkImageCache.shared.image(for: source, points: points)
            guard !Task.isCancelled else { return }
            image = decoded
            loadedKey = source.cacheKey
        }
        .onReceive(NotificationCenter.default.publisher(for: ArtworkStore.didChange)) { note in
            guard let ids = note.object as? Set<UUID>, self.source?.shows(any: ids) == true else { return }
            coverChanges += 1
        }
    }
}

// MARK: - UIKit helper

@MainActor
final class ArtworkImageLoader {
    private var token: String?
    /// What `load` was last asked, to draw again when that cover is replaced.
    private var request: (source: ArtworkSource, points: CGFloat, placeholder: UIImage?)?
    private weak var imageView: UIImageView?
    nonisolated(unsafe) private var observer: NSObjectProtocol?

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    private func observeCoverChanges() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: ArtworkStore.didChange, object: nil, queue: .main) { [weak self] note in
            guard let ids = note.object as? Set<UUID> else { return }
            MainActor.assumeIsolated {
                guard let self, let request = self.request, request.source.shows(any: ids), let imageView = self.imageView else { return }
                self.load(request.source.current, into: imageView, points: request.points, placeholder: request.placeholder)
            }
        }
    }

    /// Sets the image view's artwork, decoding off the main thread when the
    /// image isn't cached yet. Safe against cell reuse.
    func load(_ source: ArtworkSource?, into imageView: UIImageView, points: CGFloat, placeholder: UIImage? = nil) {
        token = source?.cacheKey
        self.imageView = imageView
        request = source.map { ($0, points, placeholder) }
        if source != nil { observeCoverChanges() }
        func show(_ image: UIImage?) {
            // Symbols keep their natural size centered; covers fill the frame.
            if let image {
                imageView.contentMode = .scaleAspectFill
                imageView.image = image
            } else {
                imageView.contentMode = .center
                imageView.image = placeholder
            }
        }
        guard let source else {
            show(nil)
            return
        }
        if let cached = ArtworkImageCache.shared.cachedImage(for: source, points: points) {
            show(cached)
            return
        }
        show(nil)
        let expected = source.cacheKey
        Task { [weak self, weak imageView] in
            let image = await ArtworkImageCache.shared.image(for: source, points: points)
            guard let self, let imageView, self.token == expected else { return }
            if let image {
                imageView.contentMode = .scaleAspectFill
                imageView.image = image
            }
        }
    }

    func cancel() {
        token = nil
        request = nil
    }
}
