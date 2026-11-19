import UIKit
import Foundation
import Combine

/// An album's animated cover from Apple Music: a looping video, tall when
/// the album has one.
struct MotionArtworkVideo: Codable, Hashable, Sendable {
    let url: URL
    /// Width over height.
    let aspect: Double
}

/// Finds Apple Music's motion artwork for local songs. No developer account:
/// the catalog is read with the public token Apple's web player ships with,
/// like the Spotify import reads the embed page's.
///
/// Spotify's Canvas would be the other source, but it's only served to a
/// signed-in Spotify account: the anonymous token gets `canvas: null`.
enum MotionArtworkService {
    static let storageKey = "motionArtworkEnabled"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: storageKey) as? Bool ?? true
    }

    /// The video keeps looping while the music is paused. On by default.
    static let keepsPlayingKey = "motionArtworkKeepsPlaying"

    /// Under the lyrics, the classic background instead of the video.
    /// Off by default.
    static let classicUnderLyricsKey = "motionArtworkClassicUnderLyrics"

    static var classicUnderLyrics: Bool {
        UserDefaults.standard.bool(forKey: classicUnderLyricsKey)
    }

    static var keepsPlaying: Bool {
        UserDefaults.standard.object(forKey: keepsPlayingKey) as? Bool ?? true
    }

    private struct CacheEntry: Codable {
        let video: MotionArtworkVideo?
        let checkedAt: Date
    }

    private static let cacheURL: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("MotionArtwork.json")
    }()

    @MainActor private static var cache: [String: CacheEntry] = {
        guard let data = try? Data(contentsOf: cacheURL),
              let decoded = try? JSONDecoder().decode([String: CacheEntry].self, from: data) else { return [:] }
        return decoded
    }()

    @MainActor private static var inFlight: [String: Task<Outcome, Never>] = [:]

    /// One album, one video: every song of it shares the lookup.
    static func key(for song: Song) -> String {
        let album = normalized(song.album)
        let artist = normalized(primaryArtist(song.albumArtist ?? song.artist))
        return album.isEmpty || album == "unknown album" ? "t|\(normalized(song.title))|\(artist)" : "a|\(album)|\(artist)"
    }

    /// What's already known, without asking the network: `.some(nil)` when
    /// the album has no motion artwork.
    @MainActor static func cachedVideo(for song: Song) -> MotionArtworkVideo?? {
        guard let entry = cache[key(for: song)], isFresh(entry) else { return nil }
        return .some(entry.video)
    }

    @MainActor static func video(for song: Song) async -> MotionArtworkVideo? {
        let key = key(for: song)
        if let entry = cache[key], isFresh(entry) { return entry.video }
        if let task = inFlight[key] {
            if case .found(let video) = await task.value { return video }
            return nil
        }
        let query = Query(title: song.title, artist: song.albumArtist ?? song.artist, songArtist: song.artist, album: song.album)
        let task = Task.detached(priority: .utility) { await lookUp(query) }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        // A network failure isn't remembered: it's asked again next time.
        if case .found(let video) = result {
            store(video, for: key)
            return video
        }
        if case .none = result { store(nil, for: key) }
        return nil
    }

    @MainActor private static func isFresh(_ entry: CacheEntry) -> Bool {
        let age = Date().timeIntervalSince(entry.checkedAt)
        // Albums gain motion artwork now and then: missing ones are asked again.
        return age < (entry.video == nil ? 14 : 60) * 86_400
    }

    @MainActor private static func store(_ video: MotionArtworkVideo?, for key: String) {
        cache[key] = CacheEntry(video: video, checkedAt: Date())
        let snapshot = cache
        Task.detached(priority: .background) {
            if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: cacheURL, options: .atomic) }
        }
    }

    // MARK: Lookup

    private struct Query: Sendable {
        let title, artist, songArtist, album: String
    }

    private enum Outcome: Sendable {
        case found(MotionArtworkVideo)
        case none
        case failed
    }

    private static func lookUp(_ query: Query) async -> Outcome {
        guard let token = await WebToken.shared.token() else { return .failed }
        let region = Locale.current.region?.identifier.lowercased() ?? "us"
        var storefronts = [region]
        if region != "us" { storefronts.append("us") }
        var failed = false
        for storefront in storefronts {
            switch await albumID(for: query, storefront: storefront, token: token) {
            case .some(.some(let id)):
                switch await editorialVideo(album: id, storefront: storefront, token: token) {
                case .found(let video): return .found(video)
                case .failed: failed = true
                // Found, without motion artwork: another storefront has the same.
                case .none: return .none
                }
            case .some(.none): continue
            case .none: failed = true
            }
        }
        return failed ? .failed : .none
    }

    /// `nil` on a network failure, `.some(nil)` when nothing matches.
    private static func albumID(for query: Query, storefront: String, token: String) async -> String?? {
        let album = normalized(query.album)
        let artist = normalized(primaryArtist(query.artist))
        let songArtist = normalized(primaryArtist(query.songArtist))
        func artistMatches(_ name: String) -> Bool {
            let other = normalized(name)
            return [artist, songArtist].contains { !$0.isEmpty && (other.contains($0) || $0.contains(other)) }
        }

        if !album.isEmpty, album != "unknown album" {
            guard let results = await search(term: "\(query.album) \(primaryArtist(query.artist))", type: "albums", storefront: storefront, token: token) else { return nil }
            let match = results.first { item in
                let name = normalized(item.name)
                return artistMatches(item.artist) && (name == album || name.hasPrefix(album) || album.hasPrefix(name))
            }
            if let match { return .some(match.id) }
        }

        // No album name, or none found: the song's own album.
        guard let songs = await search(term: "\(query.title) \(primaryArtist(query.songArtist))", type: "songs", storefront: storefront, token: token) else { return nil }
        let title = normalized(query.title)
        let match = songs.first { item in
            let name = normalized(item.name)
            return artistMatches(item.artist) && (name == title || name.hasPrefix(title) || title.hasPrefix(name))
        }
        return .some(match?.albumID)
    }

    private struct SearchItem {
        let id: String
        let name: String
        let artist: String
        let albumID: String?
    }

    private static func search(term: String, type: String, storefront: String, token: String) async -> [SearchItem]? {
        var components = URLComponents(string: "https://amp-api.music.apple.com/v1/catalog/\(storefront)/search")!
        components.queryItems = [
            URLQueryItem(name: "types", value: type),
            URLQueryItem(name: "limit", value: "10"),
            URLQueryItem(name: "term", value: term)
        ]
        guard let url = components.url, let json = await request(url, token: token) else { return nil }
        let data = ((json["results"] as? [String: Any])?[type] as? [String: Any])?["data"] as? [[String: Any]] ?? []
        return data.compactMap { item in
            guard let id = item["id"] as? String, let attributes = item["attributes"] as? [String: Any] else { return nil }
            // A song's link is its album's, with the song as `?i=`.
            let albumID = (attributes["url"] as? String).flatMap(URL.init(string:))?.lastPathComponent
            return SearchItem(
                id: id,
                name: attributes["name"] as? String ?? "",
                artist: attributes["artistName"] as? String ?? "",
                albumID: albumID
            )
        }
    }

    private static func editorialVideo(album id: String, storefront: String, token: String) async -> Outcome {
        guard let url = URL(string: "https://amp-api.music.apple.com/v1/catalog/\(storefront)/albums/\(id)?extend=editorialVideo"),
              let json = await request(url, token: token) else { return .failed }
        let attributes = ((json["data"] as? [[String: Any]])?.first?["attributes"] as? [String: Any]) ?? [:]
        let videos = attributes["editorialVideo"] as? [String: Any] ?? [:]
        // Tall first: it fills the player; the square one is Music's fallback too.
        for name in ["motionDetailTall", "motionTallVideo3x4", "motionDetailSquare", "motionSquareVideo1x1"] {
            guard let entry = videos[name] as? [String: Any],
                  let link = entry["video"] as? String, let url = URL(string: link) else { continue }
            let frame = entry["previewFrame"] as? [String: Any]
            let width = frame?["width"] as? Double ?? 1
            let height = frame?["height"] as? Double ?? 1
            return .found(MotionArtworkVideo(url: url, aspect: height > 0 ? width / height : 1))
        }
        return .none
    }

    private static func request(_ url: URL, token: String, retried: Bool = false) async -> [String: Any]? {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("https://music.apple.com", forHTTPHeaderField: "Origin")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode else { return nil }
        if status == 401, !retried, let fresh = await WebToken.shared.token(refresh: true) {
            return await self.request(url, token: fresh, retried: true)
        }
        guard status == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    // MARK: Matching

    private static let posixLocale = Locale(identifier: "en_US_POSIX")

    /// Folded, without "(Deluxe)", "[Remastered]", " - Single" or punctuation.
    static func normalized(_ value: String) -> String {
        let folded = value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: posixLocale)
        let stripped = folded
            .replacingOccurrences(of: #"\([^)]*\)"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\[[^\]]*\]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+-\s+(single|ep)$"#, with: " ", options: .regularExpression)
        let cleaned = stripped.map { $0.isLetter || $0.isNumber || $0 == " " ? String($0) : " " }.joined()
        return cleaned.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// "Artist feat. Other", "Artist & Other", "Artist, Other" → "Artist".
    static func primaryArtist(_ value: String) -> String {
        let separators = [" feat. ", " feat ", " ft. ", " featuring ", " & ", ", ", " x ", " et ", ";", "/"]
        var result = value
        for separator in separators {
            if let range = result.range(of: separator, options: .caseInsensitive) {
                result = String(result[..<range.lowerBound])
            }
        }
        return result.trimmingCharacters(in: .whitespaces)
    }
}

/// The token Apple's web player uses, read from its script and kept until
/// it expires.
private actor WebToken {
    static let shared = WebToken()
    private static let defaultsKey = "appleMusicWebToken"
    private var refreshing: Task<String?, Never>?

    func token(refresh: Bool = false) async -> String? {
        if !refresh, let stored = UserDefaults.standard.string(forKey: Self.defaultsKey),
           let expiry = Self.expiry(of: stored), expiry.timeIntervalSinceNow > 86_400 {
            return stored
        }
        if let refreshing { return await refreshing.value }
        let task = Task { await Self.fetch() }
        refreshing = task
        let token = await task.value
        refreshing = nil
        if let token { UserDefaults.standard.set(token, forKey: Self.defaultsKey) }
        return token
    }

    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    private static func fetch() async -> String? {
        // Any page carries the script; an album page is small and stable.
        guard let page = await text(at: URL(string: "https://music.apple.com/us/album/1440857781")!),
              let range = page.range(of: #"/assets/index[^"']*\.js"#, options: .regularExpression),
              let script = await text(at: URL(string: "https://music.apple.com" + page[range])!),
              let token = script.range(of: #"eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}"#, options: .regularExpression)
        else { return nil }
        return String(script[token])
    }

    private static func text(at url: URL) async -> String? {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// The JWT's `exp`.
    private static func expiry(of token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var payload = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = json["exp"] as? Double else { return nil }
        return Date(timeIntervalSince1970: exp)
    }
}

/// The current song's motion artwork, shared by the player's background
/// (which plays it) and the player (which hides its cover while it shows).
@MainActor
final class MotionArtworkState: ObservableObject {
    static let shared = MotionArtworkState()

    /// The video for the current song, once found.
    @Published private(set) var video: MotionArtworkVideo?
    /// A video stands in for the cover: playing, or about to (known from
    /// the cache, given a moment to load).
    @Published private(set) var hidesCover = false
    @Published var isPlaying = false
    /// The current album's video was turned off from Now Playing.
    @Published private(set) var isHiddenForAlbum = false
    /// The player is wider than tall: the video doesn't fit it, the
    /// classic background and cover stay.
    @Published var isLandscape = false {
        didSet { updateHidesCover() }
    }
    /// The video would stand in for the cover, upright. The player reads
    /// it with its own size, which turns as the rotation starts.
    @Published private(set) var videoHidesCover = false {
        didSet { updateHidesCover() }
    }
    /// The lyrics are open: the video dims under them.
    @Published var isDimmed = false
    /// Full-Screen Artwork without a video: the cover, shown and dimmed
    /// like one.
    @Published var still: UIImage?

    private var songKey: String?
    private var song: Song?
    private var wasEnabled = MotionArtworkService.isEnabled
    private var settingObserver: NSObjectProtocol?
    private var lookup: Task<Void, Never>?
    private var graceTimer: Task<Void, Never>?
    private var isReady = false

    /// The switch in Settings takes effect at once, player open or not.
    private init() {
        settingObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, MotionArtworkService.isEnabled != self.wasEnabled else { return }
                self.refresh(for: self.song)
            }
        }
    }

    func setSong(_ song: Song?) {
        self.song = song
        wasEnabled = MotionArtworkService.isEnabled
        let enabled = MotionArtworkService.isEnabled
        let key = enabled ? song.map(MotionArtworkService.key(for:)) : nil
        guard key != songKey else { return }
        songKey = key
        lookup?.cancel()
        graceTimer?.cancel()
        isReady = false
        isHiddenForAlbum = key.map(Self.hiddenAlbums.contains) ?? false
        // The song's music video stands in for the cover instead.
        guard let song, enabled, !isHiddenForAlbum, !MusicVideoPlayer.shared.isWanted(for: song) else {
            video = nil
            videoHidesCover = false
            return
        }
        if case .some(let cached) = MotionArtworkService.cachedVideo(for: song) {
            video = cached
            videoHidesCover = cached != nil
            if cached != nil { startGrace() }
            return
        }
        video = nil
        videoHidesCover = false
        lookup = Task { [weak self] in
            let found = await MotionArtworkService.video(for: song)
            guard let self, !Task.isCancelled, self.songKey == key else { return }
            self.video = found
        }
    }

    private static let hiddenAlbumsKey = "motionArtworkHiddenAlbums"

    private static var hiddenAlbums: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: hiddenAlbumsKey) ?? [])
    }

    /// Now Playing's "Hide Video for This Album", and back.
    func setHidden(_ hidden: Bool, forAlbumOf song: Song) {
        var albums = Self.hiddenAlbums
        let key = MotionArtworkService.key(for: song)
        if hidden { albums.insert(key) } else { albums.remove(key) }
        UserDefaults.standard.set(Array(albums).sorted(), forKey: Self.hiddenAlbumsKey)
        refresh(for: song)
    }

    /// Re-reads the setting.
    func refresh(for song: Song?) {
        // Not nil: turned off, the key is nil too and nothing would change.
        songKey = ""
        setSong(song)
    }

    /// The video's first frame is on screen.
    func noteReady(_ ready: Bool, for url: URL?) {
        guard url == video?.url else { return }
        isReady = ready
        if ready {
            graceTimer?.cancel()
            videoHidesCover = true
        }
    }

    /// The cover comes back if the video doesn't show soon.
    private func startGrace() {
        graceTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard let self, !Task.isCancelled, !self.isReady else { return }
            self.videoHidesCover = false
        }
    }

    private func updateHidesCover() {
        let hides = videoHidesCover && !isLandscape
        if hides != hidesCover { hidesCover = hides }
    }
}
