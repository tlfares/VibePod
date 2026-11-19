import Foundation

struct LRCLIBResult: Identifiable {
    let id = UUID()
    let trackName: String
    let artistName: String
    let albumName: String?
    let duration: Double
    let syncedLyrics: String?
    let plainLyrics: String?
    let instrumental: Bool
    let source: String?

    var hasSynced: Bool { (syncedLyrics?.isEmpty == false) }
    var hasPlain: Bool { (plainLyrics?.isEmpty == false) }

    var lrcContent: String? {
        if let synced = syncedLyrics, !synced.isEmpty { return synced }
        if let plain = plainLyrics, !plain.isEmpty { return plain }
        return nil
    }

    var durationFormatted: String {
        guard duration > 0 else { return "" }
        let mins = Int(duration) / 60
        let secs = Int(duration) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}

enum LRCLIBError: LocalizedError {
    case networkError(Error)
    case serverError(Int)
    case noResults

    var errorDescription: String? {
        switch self {
        case .networkError(let e): return String(localized: "Network error: \(e.localizedDescription)")
        case .serverError(let code) where code == 429 || code >= 500:
            return String(localized: "LRCLIB is busy right now. Try again in a moment.")
        case .serverError(let code): return String(localized: "LRCLIB returned an error (\(code)).")
        case .noResults: return String(localized: "No results found")
        }
    }
}

final class LRCLIBService: @unchecked Sendable {
    static let shared = LRCLIBService()
    private init() {}

    func search(
        trackName: String,
        artistName: String,
        albumName: String? = nil,
        duration: Double? = nil,
        attempts: Int = LRCLIBService.maxAttempts,
        completion: @escaping @Sendable (Result<[LRCLIBResult], LRCLIBError>) -> Void
    ) {
        var components = URLComponents(string: "https://lrclib.net/api/search")!
        var queryItems = [
            URLQueryItem(name: "track_name", value: trackName),
            URLQueryItem(name: "artist_name", value: artistName),
        ]
        if let albumName, !albumName.isEmpty {
            queryItems.append(URLQueryItem(name: "album_name", value: albumName))
        }
        if let duration, duration > 0 {
            queryItems.append(URLQueryItem(name: "duration", value: String(Int(duration))))
        }
        components.queryItems = queryItems

        guard let url = components.url else {
            DispatchQueue.main.async { completion(.success([])) }
            return
        }

        var request = URLRequest(url: url)
        request.setValue("VibePod-iOS/1.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        perform(request, attempt: 0, attempts: attempts, completion: completion)
    }

    /// LRCLIB often answers 503 for a moment when it's busy: such answers
    /// (and dropped connections) are retried a few times, a little later
    /// each time, before an error is shown.
    static let maxAttempts = 5

    private static func isTransient(status: Int) -> Bool {
        status == 429 || status == 500 || status == 502 || status == 503 || status == 504
    }

    private static func isTransient(_ error: Error) -> Bool {
        guard let error = error as? URLError else { return false }
        return [.timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed].contains(error.code)
    }

    private func perform(
        _ request: URLRequest,
        attempt: Int,
        attempts: Int,
        completion: @escaping @Sendable (Result<[LRCLIBResult], LRCLIBError>) -> Void
    ) {
        let retry: @Sendable () -> Bool = { [self] in
            guard attempt + 1 < attempts else { return false }
            // 0.6 s, 1.2 s, 2.4 s, 4.8 s, with a little jitter.
            let delay = 0.6 * pow(2, Double(attempt)) + Double.random(in: 0...0.3)
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                self.perform(request, attempt: attempt + 1, attempts: attempts, completion: completion)
            }
            return true
        }

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                if Self.isTransient(error), retry() { return }
                DispatchQueue.main.async { completion(.failure(.networkError(error))) }
                return
            }
            guard let http = response as? HTTPURLResponse else {
                DispatchQueue.main.async { completion(.failure(.networkError(
                    NSError(domain: "LRCLIB", code: -1, userInfo: [NSLocalizedDescriptionKey: "No HTTP response"])
                ))) }
                return
            }
            guard (200...299).contains(http.statusCode) else {
                if Self.isTransient(status: http.statusCode), retry() { return }
                DispatchQueue.main.async { completion(.failure(.serverError(http.statusCode))) }
                return
            }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                DispatchQueue.main.async { completion(.success([])) }
                return
            }

            let results: [LRCLIBResult] = json.compactMap { dict in
                guard let track = dict["trackName"] as? String else { return nil }
                let artist = dict["artistName"] as? String ?? ""
                let album = dict["albumName"] as? String
                let dur = dict["duration"] as? Double ?? 0
                let synced = dict["syncedLyrics"] as? String
                let plain = dict["plainLyrics"] as? String
                let inst = dict["instrumental"] as? Bool ?? false
                let src = dict["source"] as? String
                return LRCLIBResult(
                    trackName: track,
                    artistName: artist,
                    albumName: album,
                    duration: dur,
                    syncedLyrics: synced,
                    plainLyrics: plain,
                    instrumental: inst,
                    source: src
                )
            }

            DispatchQueue.main.async { completion(.success(results)) }
        }.resume()
    }
}
