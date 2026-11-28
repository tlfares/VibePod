import Foundation
import UIKit

struct SpotifyTrack: Identifiable, Equatable {
    let id: String
    let uri: String
    let name: String
    let artist: String
    let album: String
    let durationMS: Int
    let year: Int?
    let coverURL: URL?

    var duration: TimeInterval {
        TimeInterval(durationMS) / 1000
    }
}

struct SpotifyPlaylist: Equatable {
    let id: String
    let name: String
    let description: String
    let tracks: [SpotifyTrack]
    let coverURL: URL?
}

struct SpotifyTrackMeta {
    let year: Int?
    let coverURL: URL?
}

enum SpotifyError: LocalizedError {
    case invalidURL
    case notFound
    case network

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return String(localized: "Invalid Spotify link. Paste a playlist link such as https://open.spotify.com/playlist/...")
        case .notFound:
            return String(localized: "Playlist not found or private. Only public playlists are supported.")
        case .network:
            return String(localized: "Network error. Check your connection.")
        }
    }
}

struct SpotifyService {
    static func playlistID(from link: String) -> String? {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "spotify:playlist:"
        if trimmed.hasPrefix(prefix) {
            let id = String(trimmed.dropFirst(prefix.count))
            return id.isEmpty || id.contains(":") ? nil : id
        }
        guard let url = URL(string: trimmed),
              let host = url.host, host.contains("spotify.com") else { return nil }
        let components = url.pathComponents
        guard let index = components.firstIndex(of: "playlist"),
              index + 1 < components.count else { return nil }
        let id = components[index + 1]
        return id.isEmpty ? nil : id
    }

    /// The embed page gives the playlist's name, cover and first 100 songs,
    /// plus an anonymous web-player token. With that token the web player's
    /// own API pages through every song, no account needed. If Spotify changes
    /// that API, the import still gets the first 100.
    static func fetchPlaylist(
        from link: String,
        progress: (@MainActor @Sendable (String) -> Void)? = nil
    ) async throws -> SpotifyPlaylist {
        guard let playlistID = playlistID(from: link) else { throw SpotifyError.invalidURL }

        let embedURL = URL(string: "https://open.spotify.com/embed/playlist/\(playlistID)")!
        var request = URLRequest(url: embedURL)
        request.timeoutInterval = 30

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw SpotifyError.network
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw SpotifyError.notFound
        }

        let payload = try Self.decodeEmbedPayload(from: data)
        guard let entity = payload.props?.pageProps?.state?.data?.entity else {
            throw SpotifyError.notFound
        }

        let coverURL = entity.coverArt?.sources?.first?.url.flatMap(URL.init(string:))

        let embedTracks = (entity.trackList ?? []).compactMap { item -> SpotifyTrack? in
            guard let uri = item.uri, uri.hasPrefix("spotify:track:"),
                  let title = item.title, !title.isEmpty else { return nil }
            return SpotifyTrack(
                id: String(uri.dropFirst("spotify:track:".count)),
                uri: uri,
                name: title,
                artist: item.subtitle ?? "",
                album: "",
                durationMS: item.duration ?? 0,
                year: nil,
                coverURL: nil
            )
        }

        var tracks = embedTracks
        if let token = payload.props?.pageProps?.state?.settings?.session?.accessToken,
           let all = await Self.allTracks(ofPlaylist: playlistID, token: token, progress: progress),
           all.count >= embedTracks.count {
            tracks = all
        }

        let enriched = await Self.enrichTracks(tracks, progress: progress)

        return SpotifyPlaylist(
            id: entity.id ?? playlistID,
            name: entity.name ?? String(localized: "Spotify Playlist"),
            description: entity.subtitle ?? "",
            tracks: enriched,
            coverURL: coverURL
        )
    }

    // MARK: Web player API

    /// The web player's persisted "fetchPlaylist" query.
    private static let fetchPlaylistHash = "bb67e0af06e8d6f52b531f97468ee4acd44cd0f82b988e15c2ea47b1148efc77"
    private static let pageSize = 100

    /// Every song of the playlist, page by page. `nil` when the API refuses
    /// the first page; a later failure keeps the pages already read.
    nonisolated private static func allTracks(
        ofPlaylist playlistID: String,
        token: String,
        progress: (@MainActor @Sendable (String) -> Void)?
    ) async -> [SpotifyTrack]? {
        var tracks: [SpotifyTrack] = []
        var offset = 0
        var total: Int?
        repeat {
            guard let page = await playlistPage(playlistID, offset: offset, token: token) else {
                return total == nil ? nil : tracks
            }
            total = page.totalCount ?? 0
            let items = page.items ?? []
            tracks += items.compactMap(\.track)
            offset += items.count
            if let total, total > pageSize {
                await progress?(String(localized: "Fetching songs\u{2026} \(min(offset, total)) of \(total)"))
            }
            if items.isEmpty { break }
        } while offset < (total ?? 0)
        return tracks
    }

    nonisolated private static func playlistPage(_ playlistID: String, offset: Int, token: String) async -> PathfinderPlaylist.Content? {
        var request = URLRequest(url: URL(string: "https://api-partner.spotify.com/pathfinder/v2/query")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json;charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue("WebPlayer", forHTTPHeaderField: "App-Platform")
        let body: [String: Any] = [
            "operationName": "fetchPlaylist",
            "variables": [
                "uri": "spotify:playlist:\(playlistID)",
                "offset": offset,
                "limit": pageSize,
                "enableWatchFeedEntrypoint": false,
            ],
            "extensions": ["persistedQuery": ["version": 1, "sha256Hash": fetchPlaylistHash]],
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        // A busy API answers 429 for a moment: retry the page once.
        for attempt in 0..<2 {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode
                if status == 429, attempt == 0 {
                    try await Task.sleep(for: .seconds(2))
                    continue
                }
                guard status == 200 else { return nil }
                return try JSONDecoder().decode(PathfinderPlaylist.self, from: data).data?.playlistV2?.content
            } catch {
                return nil
            }
        }
        return nil
    }

    static func coverArtworkData(from playlist: SpotifyPlaylist) async -> Data? {
        guard let url = playlist.coverURL else { return nil }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let image = UIImage(data: data) else { return nil }
            let size = CGSize(width: 300, height: 300)
            let format = UIGraphicsImageRendererFormat.preferred()
            format.scale = 2
            // Aspect-fill instead of stretching non-square covers.
            let scale = max(size.width / max(image.size.width, 1), size.height / max(image.size.height, 1))
            let drawSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            let origin = CGPoint(x: (size.width - drawSize.width) / 2, y: (size.height - drawSize.height) / 2)
            let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                image.draw(in: CGRect(origin: origin, size: drawSize))
            }
            return resized.jpegData(compressionQuality: 0.9)
        } catch {
            return nil
        }
    }

    @MainActor
    private static func enrichTracks(_ tracks: [SpotifyTrack], progress: (@MainActor @Sendable (String) -> Void)?) async -> [SpotifyTrack] {
        guard !tracks.isEmpty else { return tracks }
        let store = SpotifyTrackMetaStore.shared
        var metas: [Int: SpotifyTrackMeta?] = [:]
        await withTaskGroup(of: (Int, SpotifyTrackMeta?).self) { group in
            var iterator = tracks.enumerated().makeIterator()
            let maxConcurrent = 8
            func addNext() {
                if let (index, track) = iterator.next() {
                    group.addTask { (index, await store.meta(for: track.id)) }
                }
            }
            for _ in 0..<maxConcurrent { addNext() }
            for await entry in group {
                metas[entry.0] = entry.1
                // Only long playlists take long enough to need a count.
                if tracks.count > 100, metas.count % 25 == 0 || metas.count == tracks.count {
                    progress?(String(localized: "Reading song details\u{2026} \(metas.count) of \(tracks.count)"))
                }
                addNext()
            }
        }
        return tracks.enumerated().map { index, track in
            guard let meta = metas[index] ?? nil else { return track }
            return SpotifyTrack(
                id: track.id,
                uri: track.uri,
                name: track.name,
                artist: track.artist,
                album: track.album,
                durationMS: track.durationMS,
                year: meta.year,
                coverURL: meta.coverURL ?? track.coverURL
            )
        }
    }

    fileprivate static func decodeEmbedPayload(from data: Data) throws -> EmbedPayload {
        guard let html = String(data: data, encoding: .utf8) else { throw SpotifyError.notFound }
        let pattern = #"<script id="__NEXT_DATA__"[^>]*>(.*?)</script>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html) else {
            throw SpotifyError.notFound
        }
        let jsonString = String(html[range])
        guard let data = jsonString.data(using: .utf8) else { throw SpotifyError.notFound }
        do {
            return try JSONDecoder().decode(EmbedPayload.self, from: data)
        } catch {
            throw SpotifyError.notFound
        }
    }
}

private struct EmbedPayload: Decodable {
    let props: Props?

    struct Props: Decodable {
        let pageProps: PageProps?

        struct PageProps: Decodable {
            let state: State?

            struct State: Decodable {
                let data: Data?
                let settings: Settings?

                struct Settings: Decodable {
                    let session: Session?

                    struct Session: Decodable {
                        let accessToken: String?
                    }
                }

                struct Data: Decodable {
                    let entity: Entity?

                    struct Entity: Decodable {
                        let id: String?
                        let name: String?
                        let subtitle: String?
                        let trackList: [TrackItem]?
                        let coverArt: CoverArt?
                        let releaseDate: ReleaseDate?
                        let visualIdentity: VisualIdentity?

                        struct TrackItem: Decodable {
                            let uri: String?
                            let title: String?
                            let subtitle: String?
                            let duration: Int?
                        }

                        struct CoverArt: Decodable {
                            let sources: [CoverSource]?

                            struct CoverSource: Decodable {
                                let url: String?
                            }
                        }

                        struct ReleaseDate: Decodable {
                            let isoString: String?
                        }

                        struct VisualIdentity: Decodable {
                            let image: [ImageSource]?

                            struct ImageSource: Decodable {
                                let url: String?
                            }
                        }
                    }
                }
            }
        }
    }
}

/// The web player API's answer to "fetchPlaylist", reduced to the songs.
private struct PathfinderPlaylist: Decodable {
    let data: DataField?

    struct DataField: Decodable {
        let playlistV2: Playlist?
    }

    struct Playlist: Decodable {
        let content: Content?
    }

    struct Content: Decodable {
        let totalCount: Int?
        let items: [Item]?
    }

    struct Item: Decodable {
        let itemV2: Wrapper?

        /// Podcast episodes and local files have no Spotify track to match.
        var track: SpotifyTrack? {
            guard let data = itemV2?.data, data.__typename == "Track",
                  let uri = data.uri, uri.hasPrefix("spotify:track:"),
                  let name = data.name, !name.isEmpty else { return nil }
            let artists = data.artists?.items?.compactMap(\.profile?.name) ?? []
            // The 300 px cover, like the embed's.
            let covers = data.albumOfTrack?.coverArt?.sources ?? []
            let cover = covers.first { $0.width == 300 } ?? covers.first
            return SpotifyTrack(
                id: String(uri.dropFirst("spotify:track:".count)),
                uri: uri,
                name: name,
                artist: artists.joined(separator: ", "),
                album: data.albumOfTrack?.name ?? "",
                durationMS: data.trackDuration?.totalMilliseconds ?? 0,
                year: nil,
                coverURL: cover?.url.flatMap(URL.init(string:))
            )
        }
    }

    struct Wrapper: Decodable {
        let data: Track?
    }

    struct Track: Decodable {
        let __typename: String?
        let uri: String?
        let name: String?
        let artists: Artists?
        let albumOfTrack: Album?
        let trackDuration: Duration?
    }

    struct Artists: Decodable {
        let items: [Artist]?
    }

    struct Artist: Decodable {
        let profile: Profile?

        struct Profile: Decodable {
            let name: String?
        }
    }

    struct Album: Decodable {
        let name: String?
        let coverArt: CoverArt?
    }

    struct CoverArt: Decodable {
        let sources: [Source]?

        struct Source: Decodable {
            let url: String?
            let width: Int?
        }
    }

    struct Duration: Decodable {
        let totalMilliseconds: Int?
    }
}

@MainActor
final class SpotifyTrackMetaStore {
    static let shared = SpotifyTrackMetaStore()

    /// Resolved metadata per track, including "nothing found" results, so a
    /// track without a cover is not re-fetched every time its cell reappears.
    private var metas: [String: SpotifyTrackMeta] = [:]
    private let images = NSCache<NSString, UIImage>()
    private var tracksWithoutImage: Set<String> = []
    private var inFlightMeta: [String: Task<SpotifyTrackMeta, Never>] = [:]
    private var inFlightImages: [String: Task<UIImage?, Never>] = [:]

    private init() {
        images.countLimit = 300
    }

    func meta(for trackID: String) async -> SpotifyTrackMeta? {
        if let cached = metas[trackID] {
            return cached.isEmpty ? nil : cached
        }
        let task: Task<SpotifyTrackMeta, Never>
        if let existing = inFlightMeta[trackID] {
            task = existing
        } else {
            // Network + HTML/JSON decoding run off the main actor.
            task = Task.detached(priority: .utility) {
                await Self.fetchMeta(for: trackID)
            }
            inFlightMeta[trackID] = task
        }
        let meta = await task.value
        inFlightMeta[trackID] = nil
        metas[trackID] = meta
        return meta.isEmpty ? nil : meta
    }

    /// The track's cover. `coverURL` comes with the playlist (web player
    /// API) and needs no lookup; without it the cover is looked up per track.
    func image(for track: SpotifyTrack) async -> UIImage? {
        let trackID = track.id
        if let cached = images.object(forKey: trackID as NSString) {
            return cached
        }
        guard !tracksWithoutImage.contains(trackID) else { return nil }
        let task: Task<UIImage?, Never>
        if let existing = inFlightImages[trackID] {
            task = existing
        } else {
            let knownURL = track.coverURL
            task = Task { [weak self] in
                guard let self else { return nil }
                let url: URL? = if let knownURL { knownURL } else { await self.meta(for: trackID)?.coverURL }
                guard let url else { return nil }
                return await Task.detached(priority: .utility) {
                    await Self.downloadImage(from: url)
                }.value
            }
            inFlightImages[trackID] = task
        }
        let image = await task.value
        inFlightImages[trackID] = nil
        if let image {
            images.setObject(image, forKey: trackID as NSString)
        } else if track.coverURL == nil, let meta = metas[trackID], meta.coverURL == nil {
            // Looked up and no cover exists: don't retry on every scroll. A
            // failed download (network, throttling) is retried next time.
            tracksWithoutImage.insert(trackID)
        }
        return image
    }

    // MARK: - Off-main fetching

    nonisolated private static func fetchMeta(for trackID: String) async -> SpotifyTrackMeta {
        let embed = await embedMeta(for: trackID)
        if let coverURL = embed?.coverURL {
            return SpotifyTrackMeta(year: embed?.year, coverURL: coverURL)
        }
        let oembed = await oembedMeta(for: trackID)
        return SpotifyTrackMeta(year: embed?.year, coverURL: oembed?.coverURL)
    }

    nonisolated private static func embedMeta(for trackID: String) async -> SpotifyTrackMeta? {
        guard let url = URL(string: "https://open.spotify.com/embed/track/\(trackID)") else { return nil }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let payload = try? SpotifyService.decodeEmbedPayload(from: data),
                  let entity = payload.props?.pageProps?.state?.data?.entity else { return nil }
            let year = entity.releaseDate?.isoString.flatMap { Int($0.prefix(4)) }
            let coverURL = entity.visualIdentity?.image?.first?.url.flatMap(URL.init(string:))
            return SpotifyTrackMeta(year: year, coverURL: coverURL)
        } catch {
            return nil
        }
    }

    nonisolated private static func oembedMeta(for trackID: String) async -> SpotifyTrackMeta? {
        guard let url = URL(string: "https://open.spotify.com/oembed?url=spotify:track:\(trackID)") else { return nil }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let thumb = json["thumbnail_url"] as? String,
                  let imageURL = URL(string: thumb) else { return nil }
            return SpotifyTrackMeta(year: nil, coverURL: imageURL)
        } catch {
            return nil
        }
    }

    nonisolated private static func downloadImage(from url: URL) async -> UIImage? {
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let decoded = UIImage(data: data) else { return nil }
            // Small thumbnails are all the UI shows; decode at that size off the main thread.
            return await decoded.byPreparingThumbnail(ofSize: CGSize(width: 132, height: 132))
                ?? decoded.preparingForDisplay()
        } catch {
            return nil
        }
    }
}

private extension SpotifyTrackMeta {
    var isEmpty: Bool { year == nil && coverURL == nil }
}

// MARK: - Catalog (artists and their releases)

/// An artist found on Spotify.
struct SpotifyArtist: Identifiable, Hashable, Sendable {
    var id: String { uri }
    let uri: String
    let name: String
    let imageURL: URL?
    let isVerified: Bool
}

/// An album, EP or single of an artist, with its cover.
struct SpotifyRelease: Identifiable, Hashable, Sendable {
    var id: String { uri }
    let uri: String
    let name: String
    let year: Int?
    let kind: String
    let coverURL: URL?
    /// About 300 px, for a grid.
    let thumbnailURL: URL?

    /// The same cover at full size (1500 px or so) where Spotify has it:
    /// the 640 px link with another size code.
    var largeCoverURL: URL? {
        guard let coverURL else { return nil }
        let link = coverURL.absoluteString
        guard link.contains("ab67616d0000b273") else { return coverURL }
        return URL(string: link.replacingOccurrences(of: "ab67616d0000b273", with: "ab67616d000082c1"))
    }
}

/// Artists and their discographies, through the web player's own API with
/// the anonymous token of an embed page (the same route as the playlist
/// import): no account needed.
enum SpotifyCatalog {
    private static let searchArtistsHash = "7bf95d754fdbe32c8b161fbbe54d1ae50974900df4dce4c8f1afcbcad153224d"
    private static let discographyHash = "5e07d323febb57b4a56a42abbf781490e58764aa45feb6e3dc0591564fc56599"

    static func searchArtists(_ term: String) async throws -> [SpotifyArtist] {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let data = try await query("searchArtists", hash: searchArtistsHash, variables: [
            "searchTerm": trimmed,
            "offset": 0,
            "limit": 20,
            "numberOfTopResults": 5,
            "includeAudiobooks": false,
            "includePreReleases": false,
            "includeLocalConcertsField": false,
            "includeArtistHasConcertsField": false,
        ])
        let response = try JSONDecoder().decode(ArtistSearchResponse.self, from: data)
        return (response.data?.searchV2?.artists?.items ?? []).compactMap { item in
            guard let artist = item.data, let uri = artist.uri, let name = artist.profile?.name else { return nil }
            let image = artist.visuals?.avatarImage?.sources?
                .min { abs(($0.width ?? 0) - 320) < abs(($1.width ?? 0) - 320) }?
                .url.flatMap(URL.init(string:))
            return SpotifyArtist(uri: uri, name: name, imageURL: image, isVerified: artist.onPlatformReputationTrait?.verification?.isVerified ?? false)
        }
    }

    /// Every release of the artist, newest first.
    static func releases(of artist: SpotifyArtist) async throws -> [SpotifyRelease] {
        var releases: [SpotifyRelease] = []
        var offset = 0
        var total = Int.max
        while offset < min(total, 400) {
            let data = try await query("queryArtistDiscographyAll", hash: discographyHash, variables: [
                "uri": artist.uri,
                "offset": offset,
                "limit": 50,
                "order": "DATE_DESC",
            ])
            let page = try JSONDecoder().decode(DiscographyResponse.self, from: data).data?.artistUnion?.discography?.all
            let items = page?.items ?? []
            total = page?.totalCount ?? 0
            releases += items.flatMap { $0.releases?.items ?? [] }.compactMap { release in
                guard let uri = release.uri, let name = release.name else { return nil }
                let sources = release.coverArt?.sources ?? []
                let cover = sources.max { ($0.width ?? 0) < ($1.width ?? 0) }?.url.flatMap(URL.init(string:))
                let thumbnail = sources.min { abs(($0.width ?? 0) - 300) < abs(($1.width ?? 0) - 300) }?.url.flatMap(URL.init(string:))
                return SpotifyRelease(uri: uri, name: name, year: release.date?.year, kind: release.type ?? "", coverURL: cover, thumbnailURL: thumbnail ?? cover)
            }
            if items.isEmpty { break }
            offset += items.count
        }
        return releases
    }

    /// The cover's bytes, at full size when Spotify has it.
    static func coverData(for release: SpotifyRelease) async throws -> Data {
        for url in [release.largeCoverURL, release.coverURL].compactMap(\.self) {
            if let (data, response) = try? await URLSession.shared.data(from: url),
               (response as? HTTPURLResponse)?.statusCode == 200, UIImage(data: data) != nil {
                return data
            }
        }
        throw SpotifyError.network
    }

    // MARK: Requests

    private static func query(_ operation: String, hash: String, variables: [String: Any]) async throws -> Data {
        let body = try JSONSerialization.data(withJSONObject: [
            "operationName": operation,
            "variables": variables,
            "extensions": ["persistedQuery": ["version": 1, "sha256Hash": hash]],
        ])
        // A stale token answers 401: a new one, once.
        for attempt in 0..<2 {
            let token = try await SpotifyWebToken.shared.token(renewing: attempt > 0)
            var request = URLRequest(url: URL(string: "https://api-partner.spotify.com/pathfinder/v2/query")!)
            request.httpMethod = "POST"
            request.timeoutInterval = 20
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json;charset=UTF-8", forHTTPHeaderField: "Content-Type")
            request.setValue("WebPlayer", forHTTPHeaderField: "App-Platform")
            request.httpBody = body
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await URLSession.shared.data(for: request)
            } catch {
                throw SpotifyError.network
            }
            switch (response as? HTTPURLResponse)?.statusCode {
            case 200: return data
            case 401 where attempt == 0: continue
            case 429 where attempt == 0: try await Task.sleep(for: .seconds(2))
            default: throw SpotifyError.network
            }
        }
        throw SpotifyError.network
    }

    private struct ArtistSearchResponse: Decodable {
        let data: DataField?
        struct DataField: Decodable { let searchV2: Search? }
        struct Search: Decodable { let artists: Artists? }
        struct Artists: Decodable { let items: [Item]? }
        struct Item: Decodable { let data: Artist? }
        struct Artist: Decodable {
            let uri: String?
            let profile: Profile?
            let visuals: Visuals?
            let onPlatformReputationTrait: Reputation?
        }
        struct Profile: Decodable { let name: String? }
        struct Visuals: Decodable { let avatarImage: Avatar? }
        struct Avatar: Decodable { let sources: [Source]? }
        struct Reputation: Decodable { let verification: Verification? }
        struct Verification: Decodable { let isVerified: Bool? }
    }

    private struct DiscographyResponse: Decodable {
        let data: DataField?
        struct DataField: Decodable { let artistUnion: Artist? }
        struct Artist: Decodable { let discography: Discography? }
        struct Discography: Decodable { let all: Page? }
        struct Page: Decodable {
            let items: [Group]?
            let totalCount: Int?
        }
        struct Group: Decodable { let releases: Releases? }
        struct Releases: Decodable { let items: [Release]? }
        struct Release: Decodable {
            let uri: String?
            let name: String?
            let type: String?
            let date: ReleaseDate?
            let coverArt: Cover?
        }
        struct ReleaseDate: Decodable { let year: Int? }
        struct Cover: Decodable { let sources: [Source]? }
    }

    fileprivate struct Source: Decodable {
        let url: String?
        let width: Int?
    }
}

/// The web player's anonymous token, from an embed page, kept while it works.
private actor SpotifyWebToken {
    static let shared = SpotifyWebToken()
    private var token: String?

    func token(renewing: Bool) async throws -> String {
        if let token, !renewing { return token }
        // Any public embed carries one; this is Spotify's own top hits playlist.
        var request = URLRequest(url: URL(string: "https://open.spotify.com/embed/playlist/37i9dQZF1DXcBWIGoYBM5M")!)
        request.timeoutInterval = 20
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let fresh = try? SpotifyService.decodeEmbedPayload(from: data).props?.pageProps?.state?.settings?.session?.accessToken else {
            throw SpotifyError.network
        }
        token = fresh
        return fresh
    }
}
