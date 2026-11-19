import Foundation
import CryptoKit
import UIKit

/// Artist photos, like Music shows them. The iTunes Search API doesn't return
/// any image for an artist, but the artist's Apple Music page carries its photo
/// in `og:image`; Deezer's public API is the fallback. Photos are kept in
/// Caches, and an artist with none is retried after a week.
@MainActor
final class ArtistImageService: ObservableObject {
    static let shared = ArtistImageService()

    /// Bumped whenever a photo arrives, so views showing it redraw.
    @Published private(set) var revision = 0

    private var photos: [String: ArtworkSource] = [:]
    private var lookedUp = Set<String>()
    private var queue: [(name: String, albums: [String], source: ArtistPhotoSource)] = []
    private var running = 0
    private static let maxConcurrent = 3
    private static let retryInterval: TimeInterval = 7 * 24 * 3600
    private static let sourcesKey = "artistPhotoSources"
    private static let coversKey = "artistCoverAlbums"

    nonisolated private static let directory: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("ArtistImages-v3", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Where this artist's photo comes from: Apple Music unless chosen
    /// otherwise from the artist page's menu.
    func source(for name: String) -> ArtistPhotoSource {
        let stored = UserDefaults.standard.dictionary(forKey: Self.sourcesKey) as? [String: String]
        return stored?[Self.key(for: name)].flatMap(ArtistPhotoSource.init(rawValue:)) ?? .appleMusic
    }

    func setSource(_ source: ArtistPhotoSource, for name: String) {
        var stored = UserDefaults.standard.dictionary(forKey: Self.sourcesKey) as? [String: String] ?? [:]
        stored[Self.key(for: name)] = source == .appleMusic ? nil : source.rawValue
        UserDefaults.standard.set(stored, forKey: Self.sourcesKey)
        revision += 1
    }

    /// The album whose cover stands for this artist when `.albumArtwork` is
    /// chosen; nil leaves it to the most represented album.
    func coverAlbum(for name: String) -> String? {
        guard source(for: name) == .albumArtwork else { return nil }
        return (UserDefaults.standard.dictionary(forKey: Self.coversKey) as? [String: String])?[Self.key(for: name)]
    }

    func setCoverAlbum(_ title: String, for name: String) {
        var stored = UserDefaults.standard.dictionary(forKey: Self.coversKey) as? [String: String] ?? [:]
        stored[Self.key(for: name)] = title
        UserDefaults.standard.set(stored, forKey: Self.coversKey)
        setSource(.albumArtwork, for: name)
    }

    /// The artist's photo if it is known; otherwise starts looking for it and
    /// returns nil (the caller shows an album cover meanwhile). `albums`, the
    /// artist's album titles in the library, tell namesakes apart.
    func photo(for name: String, albums: [String]) -> ArtworkSource? {
        let source = source(for: name)
        guard source != .albumArtwork else { return nil }
        let key = Self.key(for: name, source: source)
        if let photo = photos[key] { return photo }
        guard !Self.placeholderNames.contains(Self.key(for: name)), lookedUp.insert(key).inserted else { return nil }
        let url = Self.fileURL(for: key)
        if let data = try? Data(contentsOf: url), !data.isEmpty {
            let photo = ArtworkSource.artist(key, data: data)
            photos[key] = photo
            return photo
        }
        // An empty file marks an artist without a photo.
        if let date = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
           Date().timeIntervalSince(date) < Self.retryInterval {
            return nil
        }
        queue.append((name, albums, source))
        pump()
        return nil
    }

    private func pump() {
        while running < Self.maxConcurrent, !queue.isEmpty {
            let (name, albums, source) = queue.removeFirst()
            let titles = Set(albums.map(Self.normalizedTitle).filter { !$0.isEmpty && $0 != "unknown album" })
            running += 1
            Task {
                let network = NetworkTrace()
                let data = await Self.fetchPhoto(for: name, albums: titles, source: source, network: network)
                let key = Self.key(for: name, source: source)
                if let data {
                    try? data.write(to: Self.fileURL(for: key), options: .atomic)
                } else if !network.failed {
                    try? Data().write(to: Self.fileURL(for: key), options: .atomic)
                } else {
                    // Offline: look again next launch.
                    lookedUp.remove(key)
                }
                if let data {
                    photos[key] = ArtworkSource.artist(key, data: data)
                    revision += 1
                }
                running -= 1
                pump()
            }
        }
    }

    /// Tags standing for no artist: whatever a search returns for them is
    /// someone else.
    private static let placeholderNames: Set<String> = ["", "unknown artist", "unknown", "various artists", "artiste inconnu", "<unknown>"]

    nonisolated private static func key(for name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Apple Music keeps the plain key, so photos already cached stay valid.
    nonisolated private static func key(for name: String, source: ArtistPhotoSource) -> String {
        source == .appleMusic ? key(for: name) : key(for: name) + "|" + source.rawValue
    }

    nonisolated private static func fileURL(for key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(String(digest.prefix(32))).appendingPathExtension("jpg")
    }

    // MARK: Lookup

    nonisolated private static func fetchPhoto(for name: String, albums: Set<String>, source: ArtistPhotoSource, network: NetworkTrace) async -> Data? {
        // "A & B", "A feat. B": the first artist is the one with a page.
        var names = [name]
        if let main = name.components(separatedBy: [",", "&", "/"]).first?
            .components(separatedBy: " feat").first?
            .components(separatedBy: " ft.").first?
            .trimmingCharacters(in: .whitespaces),
           !main.isEmpty, main.caseInsensitiveCompare(name) != .orderedSame {
            names.append(main)
        }
        for candidate in names {
            // Apple Music falls back on Deezer; a source picked by hand doesn't.
            if source == .appleMusic, let url = await appleMusicPhotoURL(for: candidate, albums: albums, network: network), let data = await download(url, network: network) { return data }
            if source != .audioDB, let url = await deezerPhotoURL(for: candidate, albums: albums, network: network), let data = await download(url, network: network) { return data }
            if source == .audioDB, let url = await audioDBPhotoURL(for: candidate, network: network), let data = await download(url, network: network) { return data }
        }
        return nil
    }

    nonisolated private static func appleMusicPhotoURL(for name: String, albums: Set<String>, network: NetworkTrace) async -> URL? {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: name),
            URLQueryItem(name: "entity", value: "musicArtist"),
            URLQueryItem(name: "limit", value: "10")
        ]
        struct Response: Decodable {
            struct Artist: Decodable {
                let artistId: Int
                let artistName: String
                let artistLinkUrl: String?
            }
            let results: [Artist]
        }
        guard let url = components.url,
              let data = await get(url, network: network),
              let response = try? JSONDecoder().decode(Response.self, from: data)
        else { return nil }
        // Namesakes share a name: when there are several, only one with an
        // album of the library is the right one. Its page must have a real
        // photo (an artist photo or a press shot, not an album cover).
        let namesakes = response.results.filter { matches($0.artistName, name) }
        for artist in namesakes {
            if namesakes.count > 1 {
                let lookup = URL(string: "https://itunes.apple.com/lookup?id=\(artist.artistId)&entity=album&limit=200")!
                struct Albums: Decodable {
                    struct Album: Decodable { let collectionName: String? }
                    let results: [Album]
                }
                guard let data = await get(lookup, network: network),
                      let found = try? JSONDecoder().decode(Albums.self, from: data),
                      sharesAlbum(found.results.compactMap(\.collectionName), with: albums)
                else { continue }
            }
            guard let link = artist.artistLinkUrl.flatMap(URL.init(string:)),
                  let page = await get(link, network: network).flatMap({ String(data: $0, encoding: .utf8) }),
                  let image = ogImage(in: page),
                  image.contains("AMCArtistImages") || image.contains("pr_source")
            else { continue }
            // "…/1200x630cw.png" is a banner crop; ask for the square photo.
            return URL(string: image)?.deletingLastPathComponent().appendingPathComponent("1200x1200cc.jpg")
        }
        return nil
    }

    nonisolated private static func deezerPhotoURL(for name: String, albums: Set<String>, network: NetworkTrace) async -> URL? {
        var components = URLComponents(string: "https://api.deezer.com/search/artist")!
        components.queryItems = [URLQueryItem(name: "q", value: name), URLQueryItem(name: "limit", value: "5")]
        struct Response: Decodable {
            struct Artist: Decodable {
                let id: Int
                let name: String
                let picture_xl: String?
            }
            let data: [Artist]
        }
        struct Albums: Decodable {
            struct Album: Decodable { let title: String }
            let data: [Album]
        }
        guard let url = components.url,
              let data = await get(url, network: network),
              let response = try? JSONDecoder().decode(Response.self, from: data)
        else { return nil }
        let namesakes = response.data.filter { matches($0.name, name) }
        var chosen: Response.Artist?
        if namesakes.count == 1 {
            chosen = namesakes[0]
        } else {
            for artist in namesakes {
                guard let albumsURL = URL(string: "https://api.deezer.com/artist/\(artist.id)/albums?limit=100"),
                      let data = await get(albumsURL, network: network),
                      let found = try? JSONDecoder().decode(Albums.self, from: data),
                      sharesAlbum(found.data.map(\.title), with: albums)
                else { continue }
                chosen = artist
                break
            }
        }
        guard let artist = chosen,
              let picture = artist.picture_xl,
              // Artists without a photo get a generic silhouette at "/artist//".
              !picture.contains("/artist//")
        else { return nil }
        return URL(string: picture)
    }

    /// TheAudioDB, with its public test key.
    nonisolated private static func audioDBPhotoURL(for name: String, network: NetworkTrace) async -> URL? {
        var components = URLComponents(string: "https://www.theaudiodb.com/api/v1/json/123/search.php")!
        components.queryItems = [URLQueryItem(name: "s", value: name)]
        struct Response: Decodable {
            struct Artist: Decodable {
                let strArtist: String
                let strArtistThumb: String?
            }
            let artists: [Artist]?
        }
        guard let url = components.url,
              let data = await get(url, network: network),
              let response = try? JSONDecoder().decode(Response.self, from: data),
              let artist = response.artists?.first(where: { matches($0.strArtist, name) }),
              let thumb = artist.strArtistThumb, !thumb.isEmpty
        else { return nil }
        return URL(string: thumb)
    }

    nonisolated private static func sharesAlbum(_ found: [String], with library: Set<String>) -> Bool {
        let titles = found.map(normalizedTitle)
        return library.contains { mine in titles.contains { $0 == mine || $0.hasPrefix(mine) || mine.hasPrefix($0) } }
    }

    /// "Album (Deluxe Edition) - Single" → "album".
    nonisolated private static func normalizedTitle(_ title: String) -> String {
        var title = title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        for marker in [" (", " [", " - "] {
            if let range = title.range(of: marker) { title = String(title[..<range.lowerBound]) }
        }
        return title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func matches(_ found: String, _ wanted: String) -> Bool {
        found.compare(wanted, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }

    nonisolated private static func ogImage(in page: String) -> String? {
        guard let range = page.range(of: "<meta property=\"og:image\" content=\"") else { return nil }
        let rest = page[range.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }

    nonisolated private static func download(_ url: URL, network: NetworkTrace) async -> Data? {
        guard let data = await get(url, network: network), UIImage(data: data) != nil else { return nil }
        return data
    }

    nonisolated private static func get(_ url: URL, network: NetworkTrace) async -> Data? {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request) else {
            network.failed = true
            return nil
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }
}

enum ArtistPhotoSource: String, CaseIterable, Identifiable {
    case appleMusic, deezer, audioDB, albumArtwork

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appleMusic: "Apple Music"
        case .deezer: "Deezer"
        case .audioDB: "TheAudioDB"
        case .albumArtwork: String(localized: "Album Artwork")
        }
    }

    var systemImage: String {
        switch self {
        case .appleMusic: "applelogo"
        case .deezer: "waveform"
        case .audioDB: "books.vertical"
        case .albumArtwork: "square.stack"
        }
    }
}

/// Whether a lookup hit a network error, so "no photo" isn't remembered for
/// an artist that was only looked up offline.
private final class NetworkTrace: @unchecked Sendable {
    var failed = false
}
