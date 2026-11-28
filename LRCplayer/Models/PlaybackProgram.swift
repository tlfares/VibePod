import Combine
import Foundation
import SwiftUI

// MARK: - Model

/// A Program: a moment of listening built from steps, like a shortcut.
/// Not a fixed list of songs: each run picks them again from the steps
/// ("4 times this song, then 3 random songs from that album, then…").
struct PlaybackProgram: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var symbol: String
    var palette: CoverPalette
    var steps: [ProgramStep]
    /// Minutes after which playback stops (a sleep timer); `nil`: plays on
    /// to the end of the steps.
    var stopAfter: Int?
    /// The last minute of a stop fades out instead of cutting.
    var fadesOut = true
    var createdAt = Date()
    var modifiedAt = Date()

    static func blank() -> PlaybackProgram {
        PlaybackProgram(name: "", symbol: "sparkles", palette: .lagoon, steps: [])
    }
}

struct ProgramStep: Identifiable, Codable, Hashable, Sendable {
    enum Kind: String, Codable, CaseIterable, Identifiable, Sendable {
        case song, album, artist, genre, playlist, decade, selection, library

        var id: Self { self }

        var title: String {
            switch self {
            case .song: String(localized: "Play a Song")
            case .album: String(localized: "Play an Album")
            case .artist: String(localized: "Play an Artist")
            case .genre: String(localized: "Play a Genre")
            case .playlist: String(localized: "Play a Playlist")
            case .decade: String(localized: "Play a Decade")
            case .selection: String(localized: "Smart Pick")
            case .library: String(localized: "Play the Library")
            }
        }

        var summary: String {
            switch self {
            case .song: String(localized: "One song, as many times as you like.")
            case .album: String(localized: "All of it, or a few of its songs.")
            case .artist: String(localized: "Songs by one artist.")
            case .genre: String(localized: "Songs of one genre.")
            case .playlist: String(localized: "Songs from a playlist or an Autolist.")
            case .decade: String(localized: "Songs released in one decade.")
            case .selection: String(localized: "Picked from how you listen.")
            case .library: String(localized: "Everything else, to keep going.")
            }
        }

        var symbol: String {
            switch self {
            case .song: "music.note"
            case .album: "square.stack.fill"
            case .artist: "music.microphone"
            case .genre: "guitars.fill"
            case .playlist: "music.note.list"
            case .decade: "calendar"
            case .selection: "wand.and.stars"
            case .library: "books.vertical.fill"
            }
        }

        var color: Color {
            switch self {
            case .song: .pink
            case .album: .red
            case .artist: .purple
            case .genre: .orange
            case .playlist: .blue
            case .decade: .brown
            case .selection: .teal
            case .library: .indigo
            }
        }

        /// A song, an album… must be picked before the step can play.
        var needsSource: Bool { self != .library && self != .selection }
    }

    enum Amount: Codable, Hashable, Sendable {
        case all
        case songs(Int)
        case minutes(Int)
    }

    enum Order: String, Codable, Hashable, Sendable {
        case inOrder, shuffled
    }

    var id = UUID()
    var kind: Kind
    var songID: UUID?
    var album: AlbumID?
    /// The artist's or the genre's name.
    var name: String?
    var playlistID: UUID?
    var decade: Int?
    var selection: AutolistRules.Selection?
    var amount: Amount = .all
    var order: Order = .shuffled
    /// How many times a song plays in a row.
    var repeats = 1
    /// Leaves out the songs the program plays before this step.
    var skipsEarlier = true

    init(kind: Kind) {
        self.kind = kind
        switch kind {
        case .song: order = .inOrder
        case .album, .playlist: order = .inOrder
        case .selection: selection = .mostPlayed; amount = .songs(20)
        default: break
        }
    }

    /// Smart picks offered: the sound and workout ones once they can work.
    static var offeredSelections: [AutolistRules.Selection] {
        AutolistRules.Selection.allCases.filter {
            $0.needsSoundAnalysis ? LibrarySoundAnalysis.isUnlocked : $0.needsWorkouts ? WorkoutListening.isEnabled : true
        }
    }
}

extension ProgramStep.Amount {
    static let songChoices = [1, 2, 3, 4, 5, 8, 10, 15, 20, 30, 50]
    static let minuteChoices = [5, 10, 15, 20, 30, 45, 60, 90, 120]

    var title: String {
        switch self {
        case .all: String(localized: "all the songs")
        case let .songs(count): count == 1 ? String(localized: "1 song") : String(localized: "\(count) songs")
        case let .minutes(minutes): ProgramFormat.minutes(minutes)
        }
    }
}

enum ProgramFormat {
    static func minutes(_ minutes: Int) -> String {
        guard minutes >= 60 else { return String(localized: "\(minutes) min") }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? String(localized: "\(hours) h") : String(localized: "\(hours) h \(rest)")
    }

    static func duration(_ seconds: TimeInterval) -> String {
        minutes(max(1, Int((seconds / 60).rounded())))
    }
}

// MARK: - Store

struct ProgramEditorRequest: Identifiable {
    let id = UUID()
    var program: PlaybackProgram
    var isNew: Bool
}

/// The Programs, saved apart from the library in their own file.
@MainActor
final class ProgramStore: ObservableObject {
    static let shared = ProgramStore()

    @Published private(set) var programs: [PlaybackProgram] = []
    /// The editor sheet (new, or editing one).
    @Published var editor: ProgramEditorRequest?

    nonisolated private static let fileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("programs.json")
    }()

    private init() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let saved = try? JSONDecoder().decode([PlaybackProgram].self, from: data) {
            programs = saved
        }
    }

    func program(withID id: UUID) -> PlaybackProgram? {
        programs.first { $0.id == id }
    }

    func newProgram() {
        editor = ProgramEditorRequest(program: .blank(), isNew: true)
    }

    func edit(_ program: PlaybackProgram) {
        editor = ProgramEditorRequest(program: program, isNew: false)
    }

    func save(_ program: PlaybackProgram) {
        var program = program
        program.modifiedAt = Date()
        if let index = programs.firstIndex(where: { $0.id == program.id }) {
            programs[index] = program
        } else {
            programs.append(program)
        }
        persist()
    }

    func duplicate(_ program: PlaybackProgram) {
        var copy = program
        copy.id = UUID()
        copy.name = String(localized: "\(program.name) Copy")
        copy.createdAt = Date()
        copy.steps = program.steps.map { var step = $0; step.id = UUID(); return step }
        if let index = programs.firstIndex(where: { $0.id == program.id }) {
            programs.insert(copy, at: index + 1)
        } else {
            programs.append(copy)
        }
        persist()
    }

    func delete(_ program: PlaybackProgram) {
        programs.removeAll { $0.id == program.id }
        if ProgramRunner.shared.activeID == program.id { ProgramRunner.shared.end() }
        persist()
    }

    func move(from source: IndexSet, to destination: Int) {
        programs.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    /// iCloud Sync: a Program as another device saved it (its dates kept).
    func applySynced(_ program: PlaybackProgram) {
        if let index = programs.firstIndex(where: { $0.id == program.id }) {
            guard programs[index] != program else { return }
            programs[index] = program
        } else {
            programs.append(program)
        }
        persist()
    }

    /// iCloud Sync: a Program deleted on another device.
    func removeSynced(id: UUID) {
        guard programs.contains(where: { $0.id == id }) else { return }
        programs.removeAll { $0.id == id }
        if ProgramRunner.shared.activeID == id { ProgramRunner.shared.end() }
        persist()
    }

    private func persist() {
        let snapshot = programs
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: Self.fileURL, options: .atomic)
            }
        }
    }
}

// MARK: - Resolving

/// Turns a Program's steps into songs, picked again at every run.
@MainActor
enum ProgramResolver {
    struct Plan {
        var songs: [Song] = []
        /// Where each step starts in `songs` (its count when it added none).
        var stepStarts: [Int] = []
        /// Steps whose source is unset or gone from the library.
        var missing = Set<UUID>()
        var duration: TimeInterval { songs.reduce(0) { $0 + $1.duration } }
    }

    static func resolve(_ program: PlaybackProgram, library: LibraryViewModel) -> Plan {
        var plan = Plan()
        var used = Set<UUID>()
        var context = Context(library: library)
        for (index, step) in program.steps.enumerated() {
            plan.stepStarts.append(plan.songs.count)
            guard var pool = context.pool(for: step) else {
                plan.missing.insert(step.id)
                continue
            }
            if step.kind == .song {
                plan.songs += Array(repeating: pool, count: max(1, step.repeats)).flatMap { $0 }
                pool.forEach { used.insert($0.id) }
                continue
            }
            if step.skipsEarlier, index > 0 { pool.removeAll { used.contains($0.id) } }
            if step.order == .shuffled { pool.shuffle() }
            let picked = take(pool, step.amount)
            plan.songs += picked
            picked.forEach { used.insert($0.id) }
        }
        return plan
    }

    private static func take(_ songs: [Song], _ amount: ProgramStep.Amount) -> [Song] {
        switch amount {
        case .all:
            return songs
        case let .songs(count):
            return Array(songs.prefix(max(0, count)))
        case let .minutes(minutes):
            let target = TimeInterval(minutes * 60)
            var total: TimeInterval = 0
            var picked: [Song] = []
            for song in songs where total < target {
                picked.append(song)
                total += song.duration
            }
            return picked
        }
    }

    @MainActor
    private struct Context {
        let library: LibraryViewModel
        private var byID: [UUID: Song]?
        private var history: AutolistEngine.HistoryCounts?

        init(library: LibraryViewModel) {
            self.library = library
        }

        mutating func song(_ id: UUID) -> Song? {
            if byID == nil {
                byID = Dictionary(library.songs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            }
            return byID?[id]
        }

        mutating func pool(for step: ProgramStep) -> [Song]? {
            switch step.kind {
            case .song:
                return step.songID.flatMap { song($0) }.map { [$0] }
            case .album:
                return step.album.flatMap { library.album(withID: $0) }?.songs
            case .artist:
                return step.name.flatMap { library.artist(named: $0) }?.songs
            case .genre:
                guard let name = step.name else { return nil }
                return library.genres.first { $0.name == name }?.songs
            case .playlist:
                guard let id = step.playlistID, let playlist = library.playlists.first(where: { $0.id == id }) else { return nil }
                return library.songs(in: playlist)
            case .decade:
                guard let decade = step.decade else { return nil }
                return library.songs.filter { $0.year >= decade && $0.year < decade + 10 }
            case .selection:
                guard let selection = step.selection else { return nil }
                var rules = AutolistRules()
                rules.selection = selection
                rules.limit = nil
                rules.order = .ranked
                if history == nil { history = AutolistEngine.HistoryCounts() }
                let ids = AutolistEngine.songIDs(for: rules, in: library.songs, history: history!)
                return ids.compactMap { song($0) }
            case .library:
                return library.songs
            }
        }
    }
}

// MARK: - Running

/// The Program playing now, and its sleep timer.
@MainActor
final class ProgramRunner: ObservableObject {
    static let shared = ProgramRunner()

    @Published private(set) var activeID: UUID?
    /// The step the song playing belongs to.
    @Published private(set) var currentStep: Int?
    @Published private(set) var stepCount = 0
    /// When the sleep timer stops playback.
    @Published private(set) var stopsAt: Date?

    private var plannedIDs: [UUID] = []
    private var plannedSet = Set<UUID>()
    private var stepStarts: [Int] = []
    private var sleepTask: Task<Void, Never>?
    private var watch: AnyCancellable?

    /// False when the steps found no song.
    @discardableResult
    func run(_ program: PlaybackProgram, library: LibraryViewModel, player: PlayerViewModel) -> Bool {
        let plan = ProgramResolver.resolve(program, library: library)
        guard !plan.songs.isEmpty else { return false }
        end()
        plannedIDs = plan.songs.map(\.id)
        plannedSet = Set(plannedIDs)
        stepStarts = plan.stepStarts
        stepCount = program.steps.count
        player.play(plan.songs, shuffled: false)
        activeID = program.id
        updateStep()

        if let minutes = program.stopAfter, minutes > 0 {
            let fade: TimeInterval = program.fadesOut ? min(60, Double(minutes * 60) / 4) : 0
            let end = Date().addingTimeInterval(TimeInterval(minutes * 60))
            stopsAt = end
            sleepTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(max(0, end.timeIntervalSinceNow - fade)))
                guard !Task.isCancelled else { return }
                let service = MusicPlayerService.shared
                if fade > 0 {
                    await service.fadeOutAndPause(over: fade)
                } else {
                    service.pause()
                }
                guard !Task.isCancelled else { return }
                self?.end()
            }
        }

        // Another album or playlist started: the Program is over.
        let service = MusicPlayerService.shared
        watch = service.$currentIndex.combineLatest(service.$queue.map { $0.map(\.id) })
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.followPlayback() }
        return true
    }

    func end() {
        sleepTask?.cancel()
        sleepTask = nil
        watch = nil
        activeID = nil
        currentStep = nil
        stopsAt = nil
        plannedIDs = []
        plannedSet = []
    }

    private func followPlayback() {
        let service = MusicPlayerService.shared
        guard let song = service.currentSong, plannedSet.contains(song.id) else {
            if service.currentSong != nil { end() }
            return
        }
        updateStep()
    }

    private func updateStep() {
        let service = MusicPlayerService.shared
        let index: Int?
        if service.queue.map(\.id) == plannedIDs {
            index = service.currentIndex
        } else {
            index = service.currentSong.flatMap { song in plannedIDs.firstIndex(of: song.id) }
        }
        guard let index else { return }
        let step = stepStarts.lastIndex { $0 <= index }
        if step != currentStep { currentStep = step }
    }
}

// MARK: - Mistral

/// Builds a Program from a description, streamed: each step shows up as
/// soon as Mistral has written it.
enum ProgramGenerator {
    struct Header {
        var name: String?
        var symbol: String?
        var palette: CoverPalette?
        var stopAfter: Int??
        var fadesOut: Bool?
    }

    enum Event {
        case header(Header)
        case step(ProgramStep)
    }

    enum GeneratorError: LocalizedError {
        case unavailable, nothing

        var errorDescription: String? {
            switch self {
            case .unavailable: String(localized: "Turn on AI Features and add a \(AIProvider.current.name) API key in Settings › Tools.")
            case .nothing: String(localized: "\(AIProvider.current.name) couldn't build a program from that. Try describing it differently.")
            }
        }
    }

    static let symbols = [
        "figure.run", "figure.strengthtraining.traditional", "dumbbell.fill", "figure.outdoor.cycle", "figure.yoga", "figure.walk",
        "figure.dance", "moon.zzz.fill", "bed.double.fill", "sunrise.fill", "sun.max.fill", "cloud.rain.fill",
        "car.fill", "tram.fill", "airplane", "house.fill", "briefcase.fill", "book.fill",
        "brain.head.profile", "laptopcomputer", "cup.and.saucer.fill", "fork.knife", "party.popper.fill", "gift.fill",
        "heart.fill", "flame.fill", "bolt.fill", "leaf.fill", "drop.fill", "snowflake",
        "sparkles", "star.fill", "music.note", "headphones", "guitars.fill", "music.mic",
        "gamecontroller.fill", "shower.fill", "beach.umbrella.fill", "mountain.2.fill", "pawprint.fill", "balloon.2.fill"
    ]

    @MainActor
    static func stream(_ description: String, library: LibraryViewModel) throws -> AsyncThrowingStream<Event, Error> {
        guard AIFeatures.isAvailable, let key = AIFeatures.apiKey else { throw GeneratorError.unavailable }
        let system = systemPrompt(library: library)
        let catalog = Catalog(library: library)
        return AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                do {
                    var sent = 0
                    try await chat(system: system, user: description, key: key) { object in
                        for event in catalog.events(from: object) {
                            if case .step = event { sent += 1 }
                            continuation.yield(event)
                        }
                    }
                    if sent == 0 { throw GeneratorError.nothing }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Prompt

    @MainActor
    private static func systemPrompt(library: LibraryViewModel) -> String {
        let artists = library.artists.sorted { $0.songs.count > $1.songs.count }.prefix(250)
            .map { "\($0.name) (\($0.songs.count))" }.joined(separator: "; ")
        let genres = library.genres.sorted { $0.songs.count > $1.songs.count }.prefix(60)
            .map { "\($0.name) (\($0.songs.count))" }.joined(separator: "; ")
        let albums = library.albums.filter { !$0.isSingle }.sorted { $0.songs.count > $1.songs.count }.prefix(250)
            .map { "\($0.title) — \($0.artist)" }.joined(separator: "; ")
        let playlists = library.playlists.prefix(80).map(\.name).joined(separator: "; ")
        let decades = Set(library.songs.map { $0.year / 10 * 10 }.filter { $0 > 1900 }).sorted().map(String.init).joined(separator: ", ")
        let selections = ProgramStep.offeredSelections.map { "\($0.rawValue) (\($0.title))" }.joined(separator: ", ")
        let palettes = CoverPalette.allCases.map(\.rawValue).joined(separator: ", ")
        let language = AssistantService.prefersFrench ? "French" : "English"
        return """
        You build "programs" for a music player: a sequence of playback steps for a moment (a workout, falling asleep, a commute…), \
        from the user's own library. Only use what exists in the library below.

        Reply with JSON Lines only: one compact JSON object per line, no array around them, no Markdown, no prose.
        Line 1, the program: {"name": short name in \(language), "symbol": one of [\(symbols.joined(separator: ", "))], \
        "palette": one of [\(palettes)], "stop_after_minutes": minutes before playback stops (for sleep) or null, "fade_out": true|false}
        Then one line per step, in playing order:
        {"kind": "song"|"album"|"artist"|"genre"|"playlist"|"decade"|"selection"|"library", \
        "title": song or album title (song, album), "artist": its artist (song, album), "name": artist, genre or playlist name, \
        "decade": first year of the decade (decade), "selection": one of the smart picks (selection), \
        "amount": "all" | {"songs": n} | {"minutes": n}, "order": "in_order"|"shuffled", \
        "repeats": times a song plays in a row (song only), "skip_earlier": leave out songs already played earlier in the program}
        "library" plays from the whole library: use it last to keep music going. A step is usually 2 to 8 lines total.
        Smart picks: \(selections).

        LIBRARY
        Artists (songs): \(artists)
        Genres (songs): \(genres)
        Albums: \(albums)
        Playlists: \(playlists.isEmpty ? "none" : playlists)
        Decades: \(decades)
        """
    }

    // MARK: Transport

    /// Streams the reply, handing each JSON object over as soon as it closes
    /// (one per line, pretty-printed, in an array or a code block alike).
    @MainActor
    private static func chat(system: String, user: String, key: String, onObject: @MainActor ([String: Any]) -> Void) async throws {
        var lastError: Error = MistralError.modelUnavailable
        for model in MistralModelMemory.usable(AIProvider.current.strongModels) {
            var body: [String: Any] = [
                "model": model,
                "temperature": 0.4,
                "stream": true,
                "messages": [
                    ["role": "system", "content": system],
                    ["role": "user", "content": user]
                ]
            ]
            body.merge(AIProvider.extras(for: model)) { $1 }
            var request = URLRequest(url: MistralClient.chatURL)
            request.httpMethod = "POST"
            request.timeoutInterval = 90
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            await MistralPacer.shared.waitTurn()
            try Task.checkCancellation()
            let bytes: URLSession.AsyncBytes
            let response: URLResponse
            do {
                (bytes, response) = try await URLSession.shared.bytes(for: request)
            } catch {
                throw MistralError.network(error.localizedDescription)
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200..<300: break
            case 401: throw MistralError.invalidKey
            case 402: throw MistralError.noSubscription
            case 403:
                MistralModelMemory.skip(model)
                lastError = MistralError.modelUnavailable
                continue
            case 429:
                lastError = MistralError.rateLimited
                continue
            default:
                lastError = MistralError.server(String(localized: "error \(status)"))
                continue
            }

            var scanner = JSONObjectScanner()
            for try await event in bytes.lines {
                guard event.hasPrefix("data:") else { continue }
                let payload = event.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if payload == "[DONE]" { break }
                guard let data = payload.data(using: .utf8),
                      let chunk = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let choice = (chunk["choices"] as? [[String: Any]])?.first,
                      let delta = choice["delta"] as? [String: Any],
                      let content = delta["content"] as? String else { continue }
                for text in scanner.feed(content) {
                    if let data = text.data(using: .utf8),
                       let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        onObject(object)
                    }
                }
            }
            return
        }
        throw lastError
    }

    /// Picks the top-level JSON objects out of streamed text, whatever is
    /// around them.
    private struct JSONObjectScanner {
        private var current = ""
        private var depth = 0
        private var inString = false
        private var escaped = false

        mutating func feed(_ text: String) -> [String] {
            var objects: [String] = []
            for character in text {
                if depth == 0 {
                    if character == "{" {
                        depth = 1
                        current = "{"
                        inString = false
                        escaped = false
                    }
                    continue
                }
                current.append(character)
                if inString {
                    if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == "\"" { inString = false }
                    continue
                }
                switch character {
                case "\"": inString = true
                case "{", "[": depth += 1
                case "}", "]":
                    depth -= 1
                    if depth == 0 {
                        objects.append(current)
                        current = ""
                    }
                default: break
                }
            }
            return objects
        }
    }

    // MARK: Matching

    /// The library, to match Mistral's names against (accents and case aside).
    @MainActor
    private struct Catalog {
        let library: LibraryViewModel

        /// One object, or a whole program in one (`"steps": [...]`).
        func events(from object: [String: Any]) -> [Event] {
            guard let steps = (object["steps"] ?? object["actions"]) as? [[String: Any]] else {
                return event(from: object).map { [$0] } ?? []
            }
            var events: [Event] = []
            if let header = event(from: object.filter { $0.key != "steps" && $0.key != "actions" }) { events.append(header) }
            for step in steps {
                if let event = event(from: step), case .step = event { events.append(event) }
            }
            return events
        }

        private static let kindAliases: [String: ProgramStep.Kind] = [
            "track": .song, "title": .song, "smart": .selection, "smart_pick": .selection, "autolist": .playlist,
            "rest": .library, "all": .library, "shuffle_library": .library, "year": .decade, "era": .decade
        ]

        func event(from object: [String: Any]) -> Event? {
            if let kindName = (object["kind"] ?? object["type"]) as? String {
                let key = kindName.lowercased()
                guard let kind = ProgramStep.Kind(rawValue: key) ?? Self.kindAliases[key] else { return nil }
                return step(kind, object).map(Event.step)
            }
            guard object["name"] != nil || object["symbol"] != nil else { return nil }
            var header = Header()
            header.name = (object["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            if let symbol = object["symbol"] as? String, symbols.contains(symbol) { header.symbol = symbol }
            header.palette = (object["palette"] as? String).flatMap(CoverPalette.init(rawValue:))
            if object.keys.contains("stop_after_minutes") {
                let minutes = (object["stop_after_minutes"] as? NSNumber)?.intValue
                header.stopAfter = .some(minutes.flatMap { $0 > 0 ? min($0, 600) : nil })
            }
            header.fadesOut = object["fade_out"] as? Bool
            return .header(header)
        }

        private func step(_ kind: ProgramStep.Kind, _ object: [String: Any]) -> ProgramStep? {
            var step = ProgramStep(kind: kind)
            let title = object["title"] as? String
            let artist = object["artist"] as? String
            let name = object["name"] as? String
            switch kind {
            case .song:
                guard let song = matchSong(title: title, artist: artist) else { return nil }
                step.songID = song.id
            case .album:
                guard let album = matchAlbum(title: title ?? name, artist: artist) else { return nil }
                step.album = album.id
            case .artist:
                guard let found = best(library.artists.map(\.name), name ?? artist) else { return nil }
                step.name = found
            case .genre:
                guard let found = best(library.genres.map(\.name), name) else { return nil }
                step.name = found
            case .playlist:
                guard let found = best(library.playlists.map(\.name), name),
                      let playlist = library.playlists.first(where: { $0.name == found }) else { return nil }
                step.playlistID = playlist.id
            case .decade:
                guard let decade = (object["decade"] as? NSNumber)?.intValue else { return nil }
                step.decade = decade / 10 * 10
            case .selection:
                guard let raw = (object["selection"] ?? object["name"] ?? object["title"]) as? String,
                      let selection = AutolistRules.Selection(rawValue: raw)
                        ?? AutolistRules.Selection.allCases.first(where: { "\($0)" == raw || fold($0.title) == fold(raw) }),
                      ProgramStep.offeredSelections.contains(selection) else { return nil }
                step.selection = selection
            case .library:
                break
            }
            if let count = (object["amount"] as? NSNumber)?.intValue, count > 0 {
                step.amount = .songs(min(count, 500))
            } else if let amount = object["amount"] as? String, amount == "all" {
                step.amount = .all
            } else if let amount = object["amount"] as? [String: Any] {
                if let songs = (amount["songs"] as? NSNumber)?.intValue, songs > 0 {
                    step.amount = .songs(min(songs, 500))
                } else if let minutes = (amount["minutes"] as? NSNumber)?.intValue, minutes > 0 {
                    step.amount = .minutes(min(minutes, 600))
                }
            }
            if let order = object["order"] as? String {
                step.order = order == "in_order" ? .inOrder : .shuffled
            }
            if kind == .song, let repeats = (object["repeats"] as? NSNumber)?.intValue {
                step.repeats = min(max(repeats, 1), 20)
            }
            if let skip = object["skip_earlier"] as? Bool { step.skipsEarlier = skip }
            return step
        }

        private func matchSong(title: String?, artist: String?) -> Song? {
            guard let title = title.map(fold), !title.isEmpty else { return nil }
            let artist = artist.map(fold)
            let candidates = library.songs.filter { fold($0.title) == title }
            if let artist, let match = candidates.first(where: { fold($0.artist).contains(artist) || artist.contains(fold($0.artist)) }) {
                return match
            }
            if let match = candidates.first { return match }
            return library.songs.first { song in fold(song.title).hasPrefix(title) && (artist.map { fold(song.artist) == $0 } ?? true) }
        }

        private func matchAlbum(title: String?, artist: String?) -> Album? {
            guard let title = title.map(fold), !title.isEmpty else { return nil }
            let candidates = library.albums.filter { fold($0.title) == title }
            if let artist = artist.map(fold), let match = candidates.first(where: { fold($0.artist) == artist }) {
                return match
            }
            return candidates.first ?? library.albums.first { fold($0.title).hasPrefix(title) }
        }

        private func best(_ names: [String], _ wanted: String?) -> String? {
            guard let wanted = wanted.map(fold), !wanted.isEmpty else { return nil }
            return names.first { fold($0) == wanted } ?? names.first { fold($0).contains(wanted) || wanted.contains(fold($0)) }
        }

        /// Accents and case aside, and without the "(12)" song counts of the
        /// catalog Mistral may copy along.
        private func fold(_ text: String) -> String {
            text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
                .replacingOccurrences(of: #"\s*\(\d+\)\s*$"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
