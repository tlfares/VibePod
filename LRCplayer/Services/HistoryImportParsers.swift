import Foundation

/// One play read from another service's data export.
struct HistoryRawPlay: Sendable {
    var title: String
    var artist: String
    var album: String
    var end: Date
    /// How long it played, when the export says.
    var seconds: Double?
    /// The track's length, when the export says (or the play ran to the end).
    var trackDuration: Double?
}

/// What a data export held.
struct HistoryExport: Sendable {
    var service: ImportedHistoryPackage.Service
    var plays: [HistoryRawPlay] = []
    /// Too short to count (under 30 seconds), podcasts, private sessions.
    var skipped = 0
    /// A less detailed copy of another file of the same export: Apple's
    /// daily totals (beside its Play Activity), Spotify's account data
    /// (beside its extended history).
    var isSummary = false
}

enum HistoryImportError: LocalizedError {
    case nothingFound
    case unreadable

    var errorDescription: String? {
        switch self {
        case .nothingFound: String(localized: "No listening history was found in this file. Choose the export from Spotify, Apple Music, Deezer, YouTube Music, Last.fm or ListenBrainz, as you received it.")
        case .unreadable: String(localized: "This file couldn't be read.")
        }
    }
}

/// Reads the data exports of the other services: the zip as received, or
/// the files inside it.
///
/// - Spotify: StreamingHistory*.json (account data) or
///   Streaming_History_Audio_*.json / endsong_*.json (extended history).
/// - Apple Music: Apple Music Play Activity.csv, or Play History Daily
///   Tracks.csv, in the zips privacy.apple.com sends.
/// - Deezer: the .xlsx of the personal data export.
/// - YouTube Music: Google Takeout's watch history (.json).
/// - Last.fm: a scrobbles CSV (artist, album, title, date).
/// - ListenBrainz: the listens export (.json or .jsonl).
enum HistoryImportParser {
    /// Plays under this long don't count, as Spotify counts streams.
    static let minimumSeconds = 30.0

    static func read(_ urls: [URL]) throws -> HistoryExport {
        var exports: [HistoryExport] = []
        for url in urls {
            try collect(url, into: &exports)
        }
        // A summary repeats the detailed file: one or the other.
        let detailed = Set(exports.filter { !$0.isSummary && !$0.plays.isEmpty }.map(\.service))
        exports.removeAll { $0.isSummary && detailed.contains($0.service) }
        let found = exports.filter { !$0.plays.isEmpty }
        guard !found.isEmpty else { throw HistoryImportError.nothingFound }
        // The service most plays come from names the package.
        let services = Dictionary(grouping: found, by: \.service).mapValues { $0.reduce(0) { $0 + $1.plays.count } }
        var result = HistoryExport(service: services.max { $0.value < $1.value }?.key ?? .other)
        for export in exports {
            result.plays += export.plays
            result.skipped += export.skipped
        }
        result.plays.sort { $0.end < $1.end }
        return result
    }

    private static func collect(_ url: URL, into exports: inout [HistoryExport]) throws {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
            for file in files.sorted(by: { $0.path < $1.path }) where !file.hasDirectoryPath {
                if let export = try? parse(name: file.lastPathComponent, data: { try Data(contentsOf: file, options: .alwaysMapped) }, url: file) {
                    exports.append(contentsOf: export)
                }
            }
            return
        }
        let name = url.lastPathComponent
        if name.lowercased().hasSuffix(".zip") {
            try readZip(url, into: &exports, depth: 0)
        } else {
            exports += try parse(name: name, data: { try Data(contentsOf: url, options: .alwaysMapped) }, url: url)
        }
    }

    private static func readZip(_ url: URL, into exports: inout [HistoryExport], depth: Int) throws {
        let reader = try ZipReader(url: url)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("HistoryImport-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        for entry in reader.entries {
            let name = (entry.name as NSString).lastPathComponent
            guard !name.hasPrefix("."), !entry.name.contains("__MACOSX") else { continue }
            let lower = name.lowercased()
            // Apple sends zips inside its zip.
            if lower.hasSuffix(".zip") {
                guard depth < 3, isWorthOpening(name) else { continue }
                let nested = temporary.appendingPathComponent(UUID().uuidString + ".zip")
                try reader.extract(entry, to: nested)
                try? readZip(nested, into: &exports, depth: depth + 1)
                try? FileManager.default.removeItem(at: nested)
                continue
            }
            guard isCandidate(name) else { continue }
            let load: () throws -> Data = {
                if entry.size < 48 << 20 { return try reader.data(for: entry) }
                let file = temporary.appendingPathComponent(UUID().uuidString)
                try reader.extract(entry, to: file)
                return try Data(contentsOf: file, options: .alwaysMapped)
            }
            if let found = try? parse(name: name, data: load, url: nil) {
                exports += found
            }
        }
    }

    /// Nested zips with music history in them (Apple's), not photos.
    private static func isWorthOpening(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.contains("media") || lower.contains("music") || lower.contains("apple") || lower.contains("listen") || lower.contains("takeout") || lower.contains("spotify") || lower.contains("deezer")
    }

    private static func isCandidate(_ name: String) -> Bool {
        let lower = name.lowercased()
        guard lower.hasSuffix(".json") || lower.hasSuffix(".jsonl") || lower.hasSuffix(".csv") || lower.hasSuffix(".xlsx") else { return false }
        // Spotify's podcasts and videos, Apple's library and other lists.
        let excluded = ["podcast", "video", "playlist", "library", "follow", "search", "inferences", "userdata", "identity", "payments", "wrapped", "marquee", "favorite", "subscriptions", "containers", "artist", "account"]
        if lower.contains("streaming_history_audio") || lower.contains("streaminghistory") || lower.hasPrefix("endsong") { return !lower.contains("podcast") && !lower.contains("video") }
        return !excluded.contains { lower.contains($0) } || lower.contains("play activity") || lower.contains("play history")
    }

    private static func parse(name: String, data load: () throws -> Data, url: URL?) throws -> [HistoryExport] {
        let lower = name.lowercased()
        if lower.hasSuffix(".xlsx") {
            guard let url else {
                // Inside a zip: written out first, an xlsx is a zip itself.
                let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".xlsx")
                try load().write(to: file)
                defer { try? FileManager.default.removeItem(at: file) }
                return try XLSXSheets.read(file).compactMap { rows in table(rows, name: name, service: .deezer) }
            }
            return try XLSXSheets.read(url).compactMap { rows in table(rows, name: name, service: .deezer) }
        }
        let data = try load()
        if lower.hasSuffix(".csv") {
            var rows: [[String]] = []
            CSVRows.read(data) { rows.append($0) }
            let service: ImportedHistoryPackage.Service = lower.contains("apple") || lower.contains("play activity") || lower.contains("play history") ? .appleMusic : .other
            return table(rows, name: name, service: service).map { [$0] } ?? []
        }
        if lower.hasSuffix(".jsonl") {
            let objects = data.split(separator: UInt8(ascii: "\n")).compactMap { try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any] }
            return json(objects).map { [$0] } ?? []
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            // ListenBrainz writes one listen per line under a .json name too.
            let objects = data.split(separator: UInt8(ascii: "\n")).compactMap { try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any] }
            return json(objects).map { [$0] } ?? []
        }
        if let array = object as? [[String: Any]] { return json(array).map { [$0] } ?? [] }
        if let dictionary = object as? [String: Any], let listens = dictionary["listens"] as? [[String: Any]] ?? dictionary["payload"].flatMap({ ($0 as? [String: Any])?["listens"] as? [[String: Any]] }) {
            return json(listens).map { [$0] } ?? []
        }
        return []
    }

    // MARK: JSON

    private static func json(_ objects: [[String: Any]]) -> HistoryExport? {
        guard let first = objects.first(where: { !$0.isEmpty }) else { return nil }
        if first["ms_played"] != nil, first["ts"] != nil { return spotifyExtended(objects) }
        if first["msPlayed"] != nil, first["endTime"] != nil { return spotifyAccount(objects) }
        if first["listened_at"] != nil || first["track_metadata"] != nil { return listenBrainz(objects) }
        if first["header"] != nil, first["time"] != nil { return youTube(objects) }
        return nil
    }

    private static func spotifyExtended(_ objects: [[String: Any]]) -> HistoryExport {
        var export = HistoryExport(service: .spotify)
        export.plays.reserveCapacity(objects.count)
        for object in objects {
            guard let title = object["master_metadata_track_name"] as? String, !title.isEmpty,
                  let artist = object["master_metadata_album_artist_name"] as? String,
                  let ts = object["ts"] as? String, let end = HistoryDates.parse(ts, assumeUTC: true) else {
                export.skipped += 1
                continue
            }
            let seconds = ((object["ms_played"] as? NSNumber)?.doubleValue ?? 0) / 1000
            if (object["incognito_mode"] as? Bool) == true || seconds < minimumSeconds {
                export.skipped += 1
                continue
            }
            let finished = (object["reason_end"] as? String) == "trackdone"
            export.plays.append(HistoryRawPlay(
                title: title,
                artist: artist,
                album: object["master_metadata_album_album_name"] as? String ?? "",
                end: end,
                seconds: seconds,
                trackDuration: finished ? seconds : nil
            ))
        }
        return export
    }

    private static func spotifyAccount(_ objects: [[String: Any]]) -> HistoryExport {
        var export = HistoryExport(service: .spotify, isSummary: true)
        export.plays.reserveCapacity(objects.count)
        for object in objects {
            guard let title = object["trackName"] as? String, !title.isEmpty,
                  let artist = object["artistName"] as? String,
                  let time = object["endTime"] as? String, let end = HistoryDates.parse(time, assumeUTC: true) else {
                export.skipped += 1
                continue
            }
            let seconds = ((object["msPlayed"] as? NSNumber)?.doubleValue ?? 0) / 1000
            guard seconds >= minimumSeconds, title != "Unknown Track" else {
                export.skipped += 1
                continue
            }
            export.plays.append(HistoryRawPlay(title: title, artist: artist, album: "", end: end, seconds: seconds))
        }
        return export
    }

    private static func listenBrainz(_ objects: [[String: Any]]) -> HistoryExport {
        var export = HistoryExport(service: .listenBrainz)
        for object in objects {
            guard let metadata = object["track_metadata"] as? [String: Any],
                  let title = metadata["track_name"] as? String, !title.isEmpty,
                  let artist = metadata["artist_name"] as? String else {
                export.skipped += 1
                continue
            }
            let end: Date?
            if let stamp = (object["listened_at"] as? NSNumber)?.doubleValue {
                end = Date(timeIntervalSince1970: stamp)
            } else if let text = object["listened_at"] as? String {
                end = HistoryDates.parse(text, assumeUTC: true)
            } else {
                end = nil
            }
            guard let end else { export.skipped += 1; continue }
            let info = metadata["additional_info"] as? [String: Any]
            let duration = ((info?["duration_ms"] as? NSNumber)?.doubleValue).map { $0 / 1000 } ?? (info?["duration"] as? NSNumber)?.doubleValue
            export.plays.append(HistoryRawPlay(title: title, artist: artist, album: metadata["release_name"] as? String ?? "", end: end, trackDuration: duration))
        }
        return export
    }

    /// Google Takeout: only what was played in YouTube Music.
    private static func youTube(_ objects: [[String: Any]]) -> HistoryExport? {
        var export = HistoryExport(service: .youtubeMusic)
        for object in objects {
            guard (object["header"] as? String) == "YouTube Music" else { continue }
            guard var title = object["title"] as? String,
                  let time = object["time"] as? String, let end = HistoryDates.parse(time, assumeUTC: true),
                  let channel = (object["subtitles"] as? [[String: Any]])?.first?["name"] as? String else {
                export.skipped += 1
                continue
            }
            // "Watched …", in the account's language.
            for prefix in ["Watched ", "Vous avez regardé ", "Vous avez regardé ", "Has visto ", "Hai guardato ", "Assistiu a ", "Angesehen: ", "Je hebt ", "Bekeken: "] where title.hasPrefix(prefix) {
                title.removeFirst(prefix.count)
                break
            }
            if title.hasSuffix(" angesehen") { title.removeLast(" angesehen".count) }
            if title.hasSuffix(" bekeken") { title.removeLast(" bekeken".count) }
            let artist = channel.hasSuffix(" - Topic") ? String(channel.dropLast(" - Topic".count)) : channel
            export.plays.append(HistoryRawPlay(title: title, artist: artist, album: "", end: end))
        }
        return export.plays.isEmpty ? nil : export
    }

    // MARK: Tables (CSV, XLSX)

    /// A table with a header row naming its columns, or Last.fm's four
    /// columns without one.
    private static func table(_ rows: [[String]], name: String, service: ImportedHistoryPackage.Service) -> HistoryExport? {
        guard let header = rows.first else { return nil }
        let columns = TableColumns(header: header)
        if columns.isUsable {
            return tableExport(rows.dropFirst(), columns: columns, service: service == .other ? columns.guessedService : service)
        }
        // Last.fm exports: artist, album, title, date.
        if header.count == 4, HistoryDates.parse(header[3], assumeUTC: true) != nil {
            var export = HistoryExport(service: .lastfm)
            for row in rows where row.count >= 4 {
                guard !row[2].isEmpty, let end = HistoryDates.parse(row[3], assumeUTC: true) else { export.skipped += 1; continue }
                export.plays.append(HistoryRawPlay(title: row[2], artist: row[0], album: row[1], end: end))
            }
            return export
        }
        return nil
    }

    private static func tableExport(_ rows: ArraySlice<[String]>, columns: TableColumns, service: ImportedHistoryPackage.Service) -> HistoryExport {
        var export = HistoryExport(service: service)
        export.isSummary = columns.isDailyTotals
        export.plays.reserveCapacity(rows.count)
        for row in rows {
            func value(_ index: Int?) -> String {
                guard let index, index < row.count else { return "" }
                return row[index].trimmingCharacters(in: .whitespaces)
            }
            var title = value(columns.title)
            var artist = value(columns.artist)
            // Apple's daily tracks: "Artist - Title".
            if title.isEmpty || artist.isEmpty, let description = columns.description.map({ value($0) }), let dash = description.range(of: " - ") {
                artist = String(description[..<dash.lowerBound])
                title = String(description[dash.upperBound...])
            }
            guard !title.isEmpty, !artist.isEmpty else { export.skipped += 1; continue }
            if columns.isDailyTotals {
                guard let day = HistoryDates.parse(value(columns.date), assumeUTC: false) else { export.skipped += 1; continue }
                let hour = value(columns.hours).split(whereSeparator: { !$0.isNumber }).first.flatMap { Int($0) } ?? 12
                let count = max(1, Int(value(columns.count)) ?? 1)
                let total = Double(value(columns.duration)).map { $0 / 1000 }
                let seconds = total.map { $0 / Double(count) }
                if let seconds, seconds < minimumSeconds { export.skipped += count; continue }
                for index in 0..<count {
                    let end = day.addingTimeInterval(Double(hour) * 3600 + Double(index) * (seconds ?? 200))
                    export.plays.append(HistoryRawPlay(title: title, artist: artist, album: value(columns.album), end: end, seconds: seconds))
                }
                continue
            }
            guard var end = HistoryDates.parse(value(columns.date), assumeUTC: columns.dateIsUTC) else { export.skipped += 1; continue }
            var seconds = Double(value(columns.duration)).map { $0 * columns.durationScale }
            if let s = seconds, s <= 0 { seconds = nil }
            if let seconds, seconds < minimumSeconds { export.skipped += 1; continue }
            if columns.dateIsStart, let seconds { end.addTimeInterval(seconds) }
            let length = Double(value(columns.trackLength)).map { $0 / 1000 }
            let finished = columns.endReason.map { value($0).uppercased().contains("NATURAL_END") } ?? false
            export.plays.append(HistoryRawPlay(
                title: title,
                artist: artist,
                album: value(columns.album),
                end: end,
                seconds: seconds,
                trackDuration: length ?? (finished ? seconds : nil)
            ))
        }
        return export
    }

    /// Which column holds what, from the header's names.
    private struct TableColumns {
        var title: Int?
        var artist: Int?
        var album: Int?
        var date: Int?
        var duration: Int?
        var durationScale = 1.0
        var trackLength: Int?
        var endReason: Int?
        var description: Int?
        var hours: Int?
        var count: Int?
        var dateIsStart = false
        var dateIsUTC = false
        var isDailyTotals = false
        var guessedService = ImportedHistoryPackage.Service.other

        init(header: [String]) {
            let names = header.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            func find(_ candidates: [String]) -> Int? {
                for candidate in candidates {
                    if let index = names.firstIndex(of: candidate) { return index }
                }
                return nil
            }
            title = find(["song name", "song title", "track name", "track", "title", "titre", "titre du morceau", "content name", "master_metadata_track_name", "track_name", "name"])
            artist = find(["artist name", "artist", "artiste", "container artist name", "master_metadata_album_artist_name", "artist_name", "artists"])
            album = find(["album name", "album title", "album", "titre de l'album", "container album name", "master_metadata_album_album_name", "release_name"])
            if let index = find(["event start timestamp"]) {
                date = index
                dateIsStart = true
                dateIsUTC = true
            } else {
                date = find(["date", "ts", "timestamp", "played at", "played_at", "listened at", "listened_at", "event end timestamp", "date played", "time", "datetime", "end time", "endtime", "date d'écoute"])
                dateIsUTC = names.contains("ts") || names.contains("event end timestamp")
            }
            if let index = find(["play duration milliseconds", "ms_played", "msplayed", "duration_ms", "play duration (ms)"]) {
                duration = index
                durationScale = 0.001
            } else {
                duration = find(["listening time", "durée d'écoute", "duration", "seconds", "play duration", "durée"])
            }
            trackLength = find(["media duration in milliseconds"])
            endReason = find(["end reason type"])
            description = find(["track description"])
            hours = find(["hours"])
            count = find(["play count"])
            if names.contains("date played"), description != nil, count != nil {
                isDailyTotals = true
            }
            if names.contains("platform name") || names.contains("isrc") { guessedService = .deezer }
            if names.contains("event start timestamp") || names.contains("track description") { guessedService = .appleMusic }
        }

        var isUsable: Bool {
            (title != nil && artist != nil || description != nil) && date != nil
        }
    }
}

// MARK: - Dates

enum HistoryDates {
    /// ISO 8601 and the like ("2023-01-05T14:03:22Z", "2023-01-05 14:03"),
    /// "20230105", Unix time, or Last.fm's "05 Jan 2023 14:03". Read by
    /// hand: a formatter per row was the slow part on large histories.
    static func parse(_ text: String, assumeUTC: Bool) -> Date? {
        let bytes = Array(text.utf8)
        guard !bytes.isEmpty else { return nil }
        var index = 0
        func number(_ count: Int) -> Int? {
            guard index + count <= bytes.count else { return nil }
            var value = 0
            for offset in 0..<count {
                let byte = bytes[index + offset]
                guard byte >= 48, byte <= 57 else { return nil }
                value = value * 10 + Int(byte - 48)
            }
            index += count
            return value
        }
        func skip(_ characters: String) -> Bool {
            guard index < bytes.count, characters.utf8.contains(bytes[index]) else { return false }
            index += 1
            return true
        }

        // Unix time, in seconds or milliseconds.
        if bytes.allSatisfy({ $0 >= 48 && $0 <= 57 }) {
            if bytes.count == 8, let year = number(4), let month = number(2), let day = number(2) {
                return date(year, month, day, 0, 0, 0, offset: assumeUTC ? 0 : nil)
            }
            if let value = Double(text) {
                return Date(timeIntervalSince1970: bytes.count >= 13 ? value / 1000 : value)
            }
        }
        guard let year = number(4) else { return lastFM(text) }
        guard skip("-/."), let month = number(2), skip("-/."), let day = number(2) else { return nil }
        var hour = 0, minute = 0
        var second = 0.0
        if skip("T "), let h = number(2), skip(":"), let m = number(2) {
            hour = h
            minute = m
            if skip(":"), let s = number(2) {
                second = Double(s)
                if skip(".,") {
                    var scale = 0.1
                    while index < bytes.count, bytes[index] >= 48, bytes[index] <= 57 {
                        second += Double(bytes[index] - 48) * scale
                        scale /= 10
                        index += 1
                    }
                }
            }
        }
        while index < bytes.count, bytes[index] == 32 { index += 1 }
        var offset: Int? = assumeUTC ? 0 : nil
        if skip("Z") {
            offset = 0
        } else if index < bytes.count, bytes[index] == 43 || bytes[index] == 45 {
            let sign = bytes[index] == 45 ? -1 : 1
            index += 1
            if let h = number(2) {
                _ = skip(":")
                let m = number(2) ?? 0
                offset = sign * (h * 3600 + m * 60)
            }
        } else if text.hasSuffix("UTC") || text.hasSuffix("GMT") {
            offset = 0
        }
        return date(year, month, day, hour, minute, second, offset: offset)
    }

    /// nil offset: the device's time zone.
    private static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Double, offset: Int?) -> Date? {
        guard (1970...2100).contains(year), (1...12).contains(month), (1...31).contains(day), hour < 24, minute < 60 else { return nil }
        // Days from the civil date (Howard Hinnant's algorithm).
        let y = month <= 2 ? year - 1 : year
        let era = y / 400
        let yearOfEra = y - era * 400
        let dayOfYear = (153 * ((month + 9) % 12) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        let days = era * 146_097 + dayOfEra - 719_468
        let utc = Double(days) * 86_400 + Double(hour * 3600 + minute * 60) + second
        if let offset { return Date(timeIntervalSince1970: utc - Double(offset)) }
        let guess = Date(timeIntervalSince1970: utc)
        return Date(timeIntervalSince1970: utc - Double(TimeZone.current.secondsFromGMT(for: guess)))
    }

    private static let lastFMFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "dd MMM yyyy HH:mm"
        return formatter
    }()

    private static func lastFM(_ text: String) -> Date? {
        lastFMFormatter.date(from: text.trimmingCharacters(in: .whitespaces))
    }
}

// MARK: - CSV

enum CSVRows {
    /// Rows of a CSV file (quoted fields, commas or semicolons or tabs,
    /// CRLF), one at a time.
    static func read(_ data: Data, row handle: ([String]) -> Void) {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard var bytes = raw.bindMemory(to: UInt8.self).baseAddress.map({ UnsafeBufferPointer(start: $0, count: raw.count) }) else { return }
            // Byte order mark.
            if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF {
                bytes = UnsafeBufferPointer(rebasing: bytes[3...])
            }
            let separator = detectSeparator(bytes)
            var fields: [String] = []
            var field: [UInt8] = []
            var quoted = false
            var index = 0
            let count = bytes.count
            while index < count {
                let byte = bytes[index]
                if quoted {
                    if byte == 34 {
                        if index + 1 < count, bytes[index + 1] == 34 {
                            field.append(34)
                            index += 1
                        } else {
                            quoted = false
                        }
                    } else {
                        field.append(byte)
                    }
                } else if byte == 34, field.isEmpty {
                    quoted = true
                } else if byte == separator {
                    fields.append(String(decoding: field, as: UTF8.self))
                    field.removeAll(keepingCapacity: true)
                } else if byte == 10 || byte == 13 {
                    if byte == 13, index + 1 < count, bytes[index + 1] == 10 { index += 1 }
                    fields.append(String(decoding: field, as: UTF8.self))
                    field.removeAll(keepingCapacity: true)
                    if !(fields.count == 1 && fields[0].isEmpty) { handle(fields) }
                    fields.removeAll(keepingCapacity: true)
                } else {
                    field.append(byte)
                }
                index += 1
            }
            if !field.isEmpty || !fields.isEmpty {
                fields.append(String(decoding: field, as: UTF8.self))
                handle(fields)
            }
        }
    }

    private static func detectSeparator(_ bytes: UnsafeBufferPointer<UInt8>) -> UInt8 {
        var counts: [UInt8: Int] = [44: 0, 59: 0, 9: 0]
        var quoted = false
        for byte in bytes.prefix(4096) {
            if byte == 34 { quoted.toggle() }
            if quoted { continue }
            if byte == 10 { break }
            if counts[byte] != nil { counts[byte, default: 0] += 1 }
        }
        return counts.max { $0.value < $1.value }?.value ?? 0 > 0 ? counts.max { $0.value < $1.value }!.key : 44
    }
}

// MARK: - XLSX

/// The sheets of an .xlsx file, as rows of text (Deezer's export).
enum XLSXSheets {
    static func read(_ url: URL) throws -> [[[String]]] {
        let zip = try ZipReader(url: url)
        var shared: [String] = []
        if let entry = zip.entries.first(where: { $0.name == "xl/sharedStrings.xml" }) {
            let parser = SharedStringsParser()
            let xml = XMLParser(data: try zip.data(for: entry))
            xml.delegate = parser
            xml.parse()
            shared = parser.strings
        }
        let sheets = zip.entries
            .filter { $0.name.hasPrefix("xl/worksheets/sheet") && $0.name.hasSuffix(".xml") }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return try sheets.map { entry in
            let parser = SheetParser(shared: shared)
            let xml = XMLParser(data: try zip.data(for: entry))
            xml.delegate = parser
            xml.parse()
            return parser.rows
        }
    }

    private final class SharedStringsParser: NSObject, XMLParserDelegate {
        var strings: [String] = []
        private var current = ""
        private var inText = false

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            if name == "si" { current = "" }
            if name == "t" { inText = true }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inText { current += string }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if name == "t" { inText = false }
            if name == "si" { strings.append(current) }
        }
    }

    private final class SheetParser: NSObject, XMLParserDelegate {
        let shared: [String]
        var rows: [[String]] = []
        private var row: [String] = []
        private var column = 0
        private var type = ""
        private var value = ""
        private var inValue = false

        init(shared: [String]) { self.shared = shared }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            switch name {
            case "row": row = []
            case "c":
                type = attributes["t"] ?? ""
                value = ""
                column = attributes["r"].map(Self.column(of:)) ?? row.count
            case "v", "t": inValue = true
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inValue { value += string }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            switch name {
            case "v", "t": inValue = false
            case "c":
                var text = value
                if type == "s", let index = Int(value), shared.indices.contains(index) { text = shared[index] }
                while row.count < column { row.append("") }
                if row.count == column { row.append(text) } else if column < row.count { row[column] = text }
            case "row": rows.append(row)
            default: break
            }
        }

        /// "AB12" → 27.
        private static func column(of reference: String) -> Int {
            var value = 0
            for scalar in reference.unicodeScalars {
                guard scalar.value >= 65, scalar.value <= 90 else { break }
                value = value * 26 + Int(scalar.value - 64)
            }
            return max(0, value - 1)
        }
    }
}
