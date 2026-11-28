import Foundation

/// Speechmatics (Enhanced), optional: with its key, lyrics generation and
/// word by word sync hear the songs through it, for word times far closer
/// to the singing than Whisper's. Everything else stays on the AI provider.
enum Speechmatics {
    static let name = "Speechmatics"
    static let keysPage = URL(string: "https://portal.speechmatics.com/settings/api-keys")!
    static let consoleHost = "portal.speechmatics.com"
    /// Jobs live in the region they were sent to.
    private static let base = URL(string: "https://eu1.asr.api.speechmatics.com/v2/")!

    static var isOn: Bool { AIFeatures.speechmaticsKey != nil }

    /// Standard is faster, Enhanced more accurate. Picked by holding the
    /// Generate button, kept until changed.
    enum OperatingPoint: String, CaseIterable, Identifiable {
        case standard, enhanced
        var id: Self { self }
        var title: String {
            switch self {
            case .standard: String(localized: "Standard")
            case .enhanced: String(localized: "Enhanced")
            }
        }
    }

    static let operatingPointKey = "speechmaticsOperatingPoint"
    static var operatingPoint: OperatingPoint {
        get { UserDefaults.standard.string(forKey: operatingPointKey).flatMap(OperatingPoint.init) ?? .standard }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: operatingPointKey) }
    }

    enum Failure: LocalizedError {
        case invalidKey
        case noCredit
        case rejected(String)
        case timedOut
        case server(String)

        var errorDescription: String? {
            switch self {
            case .invalidKey: String(localized: "Speechmatics didn't accept the API key. Check it in Settings › Tools › AI Features.")
            case .noCredit: String(localized: "Speechmatics turned the song down: your account may have no credit left (\(Speechmatics.consoleHost)).")
            case .rejected(let message): String(localized: "Speechmatics couldn't transcribe this song: \(message)")
            case .timedOut: String(localized: "Speechmatics is taking too long. Try again later.")
            case .server(let message): String(localized: "Speechmatics couldn't process the request: \(message)")
            }
        }
    }

    private static func request(_ path: String, key: String, method: String = "GET") -> URLRequest {
        var request = URLRequest(url: URL(string: path, relativeTo: base)!)
        request.httpMethod = method
        request.timeoutInterval = 60
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        return request
    }

    private static func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200..<300:
            return data
        case 401:
            throw Failure.invalidKey
        case 402, 403:
            throw Failure.noCredit
        default:
            struct Body: Decodable { let error: String?; let detail: String? }
            let body = try? JSONDecoder().decode(Body.self, from: data)
            throw Failure.server(body?.detail ?? body?.error ?? String(localized: "error \(status)"))
        }
    }

    static func validate(key: String) async throws {
        _ = try await send(request("jobs?limit=1", key: key))
    }

    /// The song's words with their times. The job (audio and transcript)
    /// is deleted from Speechmatics once read.
    static func transcribe(audio: URL, key: String) async throws -> [TimedWord] {
        let boundary = "VibePod-\(UUID().uuidString)"
        var body = Data()
        // One language detected for the whole song: Melia 1's "multi"
        // switched languages mid-song and misplaced the first line.
        let config = #"{"type":"transcription","transcription_config":{"language":"auto","operating_point":""# + operatingPoint.rawValue + #""}}"#
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"config\"\r\n\r\n\(config)\r\n")
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"data_file\"; filename=\"\(audio.lastPathComponent)\"\r\nContent-Type: application/octet-stream\r\n\r\n")
        body.append(try Data(contentsOf: audio, options: .mappedIfSafe))
        body.append("\r\n--\(boundary)--\r\n")

        var submit = request("jobs", key: key, method: "POST")
        submit.timeoutInterval = 300
        submit.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        submit.httpBody = body
        struct Created: Decodable { let id: String }
        let id = try JSONDecoder().decode(Created.self, from: try await send(submit)).id
        defer {
            let delete = request("jobs/\(id)?force=true", key: key, method: "DELETE")
            Task.detached { _ = try? await URLSession.shared.data(for: delete) }
        }

        struct Details: Decodable {
            struct Job: Decodable {
                struct Problem: Decodable { let message: String? }
                let status: String
                let errors: [Problem]?
            }
            let job: Job
        }
        // A few seconds a minute of audio; given up after a quarter hour.
        let deadline = Date().addingTimeInterval(15 * 60)
        while true {
            try await Task.sleep(for: .seconds(2))
            let job = try JSONDecoder().decode(Details.self, from: try await send(request("jobs/\(id)", key: key))).job
            switch job.status {
            case "done":
                let data = try await send(request("jobs/\(id)/transcript?format=json-v2", key: key))
                return try words(in: data)
            case "running":
                guard Date() < deadline else { throw Failure.timedOut }
            default:
                throw Failure.rejected(job.errors?.compactMap(\.message).first ?? job.status)
            }
        }
    }

    /// Words with their punctuation attached, as Whisper writes them (the
    /// lines are cut after sentence ends).
    private static func words(in data: Data) throws -> [TimedWord] {
        struct Transcript: Decodable {
            struct Result: Decodable {
                struct Alternative: Decodable { let content: String }
                let type: String
                let start_time: Double
                let end_time: Double
                let alternatives: [Alternative]?
                let attaches_to: String?
            }
            let results: [Result]
        }
        var words: [TimedWord] = []
        var pendingPrefix = ""
        for result in try JSONDecoder().decode(Transcript.self, from: data).results {
            guard let content = result.alternatives?.first?.content, !content.isEmpty else { continue }
            switch result.type {
            case "word":
                words.append(TimedWord(text: pendingPrefix + content, start: result.start_time, end: max(result.end_time, result.start_time)))
                pendingPrefix = ""
            case "punctuation":
                if result.attaches_to == "next" {
                    pendingPrefix += content
                } else if !words.isEmpty {
                    words[words.count - 1].text += content
                }
            default:
                continue
            }
        }
        return words
    }
}

private extension Data {
    mutating func append(_ string: String) {
        append(Data(string.utf8))
    }
}
