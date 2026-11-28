import Foundation
import FoundationModels

/// A message of the assistant's single conversation.
struct AssistantMessage: Identifiable, Codable, Equatable {
    enum Role: String, Codable { case user, assistant }

    var id = UUID()
    var role: Role
    var text: String
    var date = Date()
    /// What the assistant did, shown as cards under its answer.
    var receipts: [AssistantReceipt] = []
    var isError = false
    var viaVoice = false
    /// The answer asked something back: voice mode listens again.
    var expectsAnswer = false
}

/// A card for something the assistant did (or waits to do).
struct AssistantReceipt: Identifiable, Codable, Equatable {
    enum Destination: Codable, Equatable {
        case playlist(UUID)
        case artist(String)
        case album(name: String, artist: String)

        var route: LibraryRoute {
            switch self {
            case let .playlist(id): .playlist(id)
            case let .artist(name): .artist(name)
            case let .album(name, artist): .album(AlbumID(name: name, artist: artist))
            }
        }
    }

    var id = UUID()
    var symbol: String
    var title: String
    var detail: String
    /// Artwork comes from the first of these.
    var songIDs: [UUID] = []
    var destination: Destination?
    /// A delete waiting for the user's yes.
    var awaitsConfirmation = false
    var isFailure = false
}

enum AssistantMode: String, Identifiable {
    case text
    case voice
    var id: Self { self }
}

/// Runs the conversation: asks the model for a plan, fetches what it looks
/// up, runs its actions on the library and the player, and keeps the one
/// conversation on disk.
@MainActor
final class AssistantService: ObservableObject {
    static let shared = AssistantService()

    @Published private(set) var messages: [AssistantMessage] = []
    @Published private(set) var isWorking = false
    /// What the assistant is busy with ("Checking your stats…").
    @Published private(set) var activity: String?
    /// A page an `open` action asked for; the sheet closes and shows it.
    @Published var requestedRoute: LibraryRoute?
    @Published private(set) var sleepTimerEnd: Date?
    @Published private(set) var stopsAtEndOfSong = false
    /// Which model answered last, for the sheet's subtitle.
    @Published private(set) var lastEngine: AssistantEngineKind?

    private var pending: AssistantAction?
    private var pendingReceiptID: UUID?
    private var sleepTask: Task<Void, Never>?
    private var currentTask: Task<AssistantMessage?, Never>?

    private var libraryService: LibraryService { AppModel.shared.libraryService }
    private var player: MusicPlayerService { MusicPlayerService.shared }

    private static let fileURL: URL = {
        let folder = URL.applicationSupportDirectory.appending(path: "Assistant", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appending(path: "conversation.json")
    }()

    private init() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let saved = try? JSONDecoder().decode([AssistantMessage].self, from: data) {
            messages = saved
        }
    }

    /// Whether any model can answer right now.
    var canAnswer: Bool { !AssistantEngines.available().isEmpty }

    /// The app's language (the phone's, or the one picked in the app's iOS Settings).
    nonisolated static var prefersFrench: Bool {
        Bundle.main.preferredLocalizations.first?.hasPrefix("fr") == true
    }

    // MARK: Conversation

    /// Sends the user's words; returns the assistant's answer.
    @discardableResult
    func send(_ text: String, viaVoice: Bool = false) async -> AssistantMessage? {
        await ask(text, viaVoice: viaVoice, at: nil)
    }

    /// Puts new words in place of a question the user sent: its answer goes,
    /// and a new one comes in its place. Later turns stay where they are.
    @discardableResult
    func edit(_ id: UUID, to text: String) async -> AssistantMessage? {
        guard !isWorking, let index = messages.firstIndex(where: { $0.id == id && $0.role == .user }) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        messages.removeSubrange(index..<turnEnd(after: index))
        save()
        return await ask(trimmed, viaVoice: false, at: index)
    }

    /// Takes back a question and its answer; if it's still being answered,
    /// stops there.
    func delete(_ id: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == id && $0.role == .user }) else { return }
        if isWorking, index == messages.lastIndex(where: { $0.role == .user }) { cancel() }
        messages.removeSubrange(index..<turnEnd(after: index))
        save()
    }

    /// The question still waiting for its answer.
    var waitingID: UUID? {
        guard isWorking, let last = messages.last, last.role == .user else { return nil }
        return last.id
    }

    /// Where the turn begun at `index` ends: at the next question.
    private func turnEnd(after index: Int) -> Int {
        messages[(index + 1)...].firstIndex { $0.role == .user } ?? messages.endIndex
    }

    /// Asks, appending the turn, or inserting it at `index` (an edit).
    private func ask(_ text: String, viaVoice: Bool, at index: Int?) async -> AssistantMessage? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isWorking else { return nil }
        let history = recentTurns(in: index.map { Array(messages[..<$0]) } ?? messages)
        let question = AssistantMessage(role: .user, text: trimmed, viaVoice: viaVoice)
        if let index {
            messages.insert(question, at: min(index, messages.count))
            save()
        } else {
            append(question)
        }
        isWorking = true
        defer {
            isWorking = false
            activity = nil
        }

        var answer = localAnswer(to: trimmed)
        if answer == nil {
            let task = Task { await self.answer(trimmed, history: history, viaVoice: viaVoice) }
            currentTask = task
            answer = await task.value
            currentTask = nil
        }
        // Taken back meanwhile: nothing to answer.
        guard let answer, let at = messages.firstIndex(where: { $0.id == question.id }) else { return nil }
        if index == nil {
            append(answer)
        } else {
            messages.insert(answer, at: at + 1)
            save()
        }
        return answer
    }

    /// Stops waiting for the model (the sheet closed, or the user tapped stop).
    func cancel() {
        currentTask?.cancel()
    }

    /// Deletes the conversation.
    func clear() {
        cancel()
        messages = []
        pending = nil
        pendingReceiptID = nil
        try? FileManager.default.removeItem(at: Self.fileURL)
    }

    private func append(_ message: AssistantMessage) {
        messages.append(message)
        // Very long conversations only cost disk space: keep the last 200.
        if messages.count > 200 { messages.removeFirst(messages.count - 200) }
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(messages) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }

    /// iCloud Sync: the conversation as another device left it.
    func replaceMessages(_ synced: [AssistantMessage]) {
        guard !isWorking, synced != messages else { return }
        messages = synced
        save()
    }

    /// The last exchanges, shortened: enough to follow up on, cheap to send.
    private func recentTurns(in messages: [AssistantMessage], limit: Int = 5) -> [AssistantTurn] {
        var turns: [AssistantTurn] = []
        var assistantText: String?
        for message in messages.reversed() where !message.isError {
            switch message.role {
            case .assistant:
                var text = message.text
                if !message.receipts.isEmpty {
                    text += " [did: " + message.receipts.map { "\($0.title) \($0.detail)" }.joined(separator: "; ") + "]"
                }
                assistantText = text
            case .user:
                if let reply = assistantText {
                    turns.append(AssistantTurn(user: String(message.text.prefix(300)), assistant: String(reply.prefix(400))))
                    assistantText = nil
                }
            }
            if turns.count == limit { break }
        }
        return turns.reversed()
    }

    // MARK: Model rounds

    private func answer(_ text: String, history: [AssistantTurn], viaVoice: Bool) async -> AssistantMessage? {
        let engines = AssistantEngines.available()
        guard !engines.isEmpty else {
            return AssistantMessage(role: .assistant, text: Self.setupHint, isError: true)
        }
        activity = Self.prefersFrench ? "Réflexion…" : "Thinking…"

        var lookupResults: String?
        var engineIndex = 0
        let parse = AssistantLibrary(libraryService: libraryService, player: player).parse(text)
        let facts = engines.contains { $0.kind == .onDevice } ? await facts(for: text, parse: parse) : nil
        var plan: AssistantPlan?
        var lastError: Error?
        // Actions sent along with lookups: run with the final answer.
        var earlyActions: [AssistantAction] = []

        // A first answer, then at most two rounds of lookups, then one last
        // answer that can't ask for more (never a bare preamble).
        let lastRound = 3
        for round in 0...lastRound {
            var answered = false
            while engineIndex < engines.count {
                let engine = engines[engineIndex]
                let library = AssistantLibrary(libraryService: libraryService, player: player)
                let prompt = AssistantPrompt(
                    context: library.context(budget: engine.budget) + extraContext(),
                    history: engine.kind == .onDevice ? Array(history.suffix(3)) : Array(history.suffix(AIProvider.current.assistantHistory)),
                    message: text,
                    lookupResults: lookupResults,
                    isVoice: viaVoice,
                    parse: parse,
                    facts: facts
                )
                do {
                    plan = try await engine.plan(for: prompt).repaired()
                    lastEngine = engine.kind
                    answered = true
                    break
                } catch is CancellationError {
                    return nil
                } catch {
                    if Task.isCancelled { return nil }
                    // The next engine may do better (a refusal, a full context,
                    // a quota): fall through to it.
                    lastError = error
                    engineIndex += 1
                }
            }
            guard answered, let current = plan else {
                // It was still looking things up: its first answer is only a
                // preamble, whose actions guessed ahead of the results.
                if plan?.lookups?.nonEmpty != nil { plan = nil }
                break
            }
            guard round < lastRound, let lookups = current.lookups?.nonEmpty else { break }
            // Actions on songs wait for the results (the final answer picks
            // the songs); the others (pause, skip…) can run with it.
            earlyActions += (current.actions ?? []).filter { $0.songs?.nonEmpty == nil }

            var results: [String] = []
            if round < lastRound - 1 {
                activity = Self.activity(for: lookups)
                let library = AssistantLibrary(libraryService: libraryService, player: player)
                await loadLyricsIndex(if: lookups.contains { $0.type == .subject || $0.songs?.about?.isEmpty == false })
                for lookup in lookups.prefix(4) {
                    results.append(await library.run(lookup))
                }
            }
            if round >= lastRound - 2 {
                results.append("NO MORE LOOKUPS: write your complete final answer now with what you have.")
            }
            lookupResults = [lookupResults, results.joined(separator: "\n\n")].compactMap { $0 }.joined(separator: "\n\n")
            if Task.isCancelled { return nil }
        }

        guard var plan else {
            return AssistantMessage(role: .assistant, text: Self.describe(lastError), isError: true)
        }
        // The final answer usually repeats them; otherwise the early ones run.
        if plan.actions?.isEmpty ?? true, !earlyActions.isEmpty {
            plan.actions = earlyActions
        }
        await loadLyricsIndex(if: (plan.actions ?? []).contains { $0.songs?.contains { $0.about?.isEmpty == false } == true })
        let receipts = execute(plan.actions ?? [])
        var reply = plan.reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if reply.isEmpty {
            reply = receipts.isEmpty ? (Self.prefersFrench ? "Je n'ai pas compris." : "I didn't get that.") : Self.reply(for: receipts)
        }
        // The reply is written before the app acts: a count or an artist it
        // names that the songs don't bear out gives way to the facts.
        if let facts = Self.factualReply(reply, receipts: receipts, songs: actedSongs, library: libraryService.songs) {
            reply = facts
        }
        // The model said it played something the library doesn't have.
        if !receipts.isEmpty, receipts.allSatisfy(\.isFailure) {
            reply = receipts.map(\.detail).joined(separator: " ")
        }
        let asks = plan.expectsAnswer == true || receipts.contains(where: \.awaitsConfirmation)
        return AssistantMessage(role: .assistant, text: reply, receipts: receipts, viaVoice: viaVoice, expectsAnswer: asks)
    }

    /// What the on-device model can't look up by itself: the named artists'
    /// stats and albums, and the period a recap is about.
    private func facts(for text: String, parse: AssistantParse) async -> String? {
        let library = AssistantLibrary(libraryService: libraryService, player: player)
        let words = AssistantText.normalize(text)
        let period: StatsPeriod? = ["semaine", "week"].contains { AssistantText.containsWords(words, $0) } ? .week
            : ["mois", "month"].contains { AssistantText.containsWords(words, $0) } ? .month
            : ["annee", "year"].contains { AssistantText.containsWords(words, $0) } ? .year : nil
        var parts: [String] = []
        // "Analyse les paroles de ce son": the small model gets the words
        // themselves, shorter, its context being small.
        if Self.asksAboutLyrics(words) {
            let query = parse.query.flatMap { $0.titles == nil ? nil : $0 } ?? SongQuery(nowPlaying: true)
            parts.append(library.songLyrics(query, limit: 1500))
            return parts.joined(separator: "\n\n")
        }
        if !parse.artists.isEmpty {
            let artists = SongQuery(artists: parse.artists)
            parts.append(await library.run(AssistantLookup(type: .stats, songs: artists, period: period)))
            parts.append(await library.run(AssistantLookup(type: .albums, songs: artists)))
        } else if let period {
            parts.append(await library.run(AssistantLookup(type: .stats, period: period)))
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    /// Asks what a song's words say (paroles, lyrics, texte, "ça parle de quoi").
    static func asksAboutLyrics(_ words: String) -> Bool {
        ["paroles", "lyrics", "le texte", "ca parle de quoi", "parle de quoi", "what is it about", "what s it about", "what does it mean", "ca veut dire quoi"]
            .contains { AssistantText.containsWords(words, $0) }
    }

    /// An answer for actions the model didn't word: what the receipts say.
    private static func reply(for receipts: [AssistantReceipt]) -> String {
        let french = prefersFrench
        if let waiting = receipts.first(where: \.awaitsConfirmation) {
            return waiting.title + (french ? " Dis oui pour confirmer." : " Say yes to confirm.")
        }
        let lines = receipts.map { $0.detail.isEmpty ? $0.title : "\($0.title) : \($0.detail)" }
        return lines.joined(separator: "\n").replacingOccurrences(of: " : ", with: french ? " : " : ": ")
    }

    /// The state the library context doesn't know about.
    private func extraContext() -> String {
        var lines: [String] = []
        let memories = AssistantMemory.shared.items
        if !memories.isEmpty {
            lines.append("You remember, because the user asked you to (their words): " + memories.suffix(30).map { "“\($0.text)”" }.joined(separator: "; ") + ".")
        }
        if let pending {
            lines.append("Pending confirmation: \(pending.type.rawValue) \(pending.playlist ?? pending.name ?? ""). A yes is confirm, a no is cancel.")
        }
        let made = conversationPlaylists()
        if !made.isEmpty {
            lines.append("Playlists you made in this conversation: " + made.prefix(5).map { "“\($0.name)” (\($0.songs.count) songs)" }.joined(separator: ", ")
                + ". To adjust or redo one, send createPlaylist with playlist set to its name: its songs are replaced, no new playlist. Small changes can be addToPlaylist or removeFromPlaylist.")
        }
        if let sleepTimerEnd {
            lines.append("Sleep timer: pauses at \(sleepTimerEnd.formatted(date: .omitted, time: .shortened)).")
        } else if stopsAtEndOfSong {
            lines.append("Sleep timer: pauses at the end of this song.")
        }
        return lines.isEmpty ? "" : "\n" + lines.joined(separator: "\n")
    }

    private static func activity(for lookups: [AssistantLookup]) -> String {
        let french = prefersFrench
        switch lookups.first?.type {
        case .stats, .history: return french ? "Je regarde tes stats…" : "Checking your stats…"
        case .lyrics: return french ? "Je fouille les paroles…" : "Searching the lyrics…"
        case .songLyrics: return french ? "Je lis les paroles…" : "Reading the lyrics…"
        case .queue: return french ? "Je regarde la file d'attente…" : "Looking at the queue…"
        case .themes: return french ? "Je parcours les thèmes des paroles…" : "Going through the lyrics' themes…"
        case .subject: return french ? "Je cherche dans les paroles…" : "Searching the lyrics…"
        default: return french ? "Je fouille ta bibliothèque…" : "Searching your library…"
        }
    }

    private static var setupHint: String {
        prefersFrench
            ? "Pour me parler, active Apple Intelligence dans Réglages, ou ajoute une clé \(AIProvider.current.name) dans Réglages › Outils › Fonctions IA."
            : "To talk to me, turn on Apple Intelligence in Settings, or add a \(AIProvider.current.name) key in Settings › Tools › AI Features."
    }

    private static func describe(_ error: Error?) -> String {
        let french = prefersFrench
        if let error = error as? LanguageModelSession.GenerationError {
            switch error {
            case .guardrailViolation, .refusal:
                return french ? "Apple Intelligence a refusé de répondre à ça. Ajoute une clé \(AIProvider.current.name) pour aller plus loin." : "Apple Intelligence wouldn't answer that one. A \(AIProvider.current.name) key lets me go further."
            case .exceededContextWindowSize:
                return french ? "Ta bibliothèque est trop grande pour le modèle sur l'appareil. Une clé \(AIProvider.current.name) m'aiderait." : "Your library is too big for the on-device model. A \(AIProvider.current.name) key would help."
            case .rateLimited:
                return french ? "Apple Intelligence est occupé, réessaie dans un instant." : "Apple Intelligence is busy, try again in a moment."
            default: break
            }
        }
        if let error = error as? MistralError, case .rateLimited = error {
            return french ? "\(AIProvider.current.name) limite les requêtes pour l'instant. Réessaie dans une minute." : MistralError.rateLimited.localizedDescription
        }
        return error?.localizedDescription ?? (french ? "Je n'ai pas pu répondre." : "I couldn't answer.")
    }

    // MARK: Without the model

    /// Plain commands and yes/no to a pending question: no need to ask a
    /// model (nor spend a Mistral request).
    private func localAnswer(to text: String) -> AssistantMessage? {
        let words = AssistantText.normalize(text)
            .split(separator: " ")
            .filter { !["please", "stp", "svp", "s il te plait", "the", "la", "le", "music", "musique", "song", "chanson", "son", "hey", "mets", "met"].contains($0) }
            .joined(separator: " ")
        let french = Self.prefersFrench

        if pending != nil {
            if ["yes", "yeah", "yep", "ok", "okay", "sure", "do it", "confirm", "oui", "ouais", "vas y", "confirme", "d accord", "carrement", "go"].contains(words) {
                let receipts = execute([AssistantAction(type: .confirm)])
                return AssistantMessage(role: .assistant, text: french ? "C'est fait." : "Done.", receipts: receipts)
            }
            if ["no", "nope", "cancel", "never mind", "non", "annule", "laisse tomber", "nan"].contains(words) {
                _ = execute([AssistantAction(type: .cancel)])
                return AssistantMessage(role: .assistant, text: french ? "OK, je ne touche à rien." : "OK, I'll leave it.")
            }
        }

        let commands: [(Set<String>, AssistantActionType, String, String)] = [
            (["pause", "stop", "arrete", "stoppe", "coupe", "pause la"], .pause, "En pause.", "Paused."),
            (["play", "resume", "continue", "reprends", "lecture", "relance", "joue"], .resume, "C'est reparti.", "Playing."),
            (["next", "skip", "suivant", "suivante", "passe", "next track", "skip it", "passe la", "zappe"], .skip, "Au suivant.", "Skipped."),
            (["previous", "back", "go back", "precedent", "precedente", "reviens"], .previous, "Retour en arrière.", "Going back."),
        ]
        for (phrases, type, frenchReply, englishReply) in commands where phrases.contains(words) {
            let receipts = execute([AssistantAction(type: type)])
            return AssistantMessage(role: .assistant, text: french ? frenchReply : englishReply, receipts: receipts)
        }
        return nil
    }

    // MARK: Actions

    func confirmPending() {
        let receipts = execute([AssistantAction(type: .confirm)])
        append(AssistantMessage(role: .assistant, text: Self.prefersFrench ? "C'est fait." : "Done.", receipts: receipts))
    }

    func cancelPending() {
        _ = execute([AssistantAction(type: .cancel)])
        append(AssistantMessage(role: .assistant, text: Self.prefersFrench ? "OK, je ne touche à rien." : "OK, I'll leave it."))
    }

    /// Whether this receipt still waits for the user's yes.
    func isAwaiting(_ receipt: AssistantReceipt) -> Bool {
        receipt.awaitsConfirmation && receipt.id == pendingReceiptID && pending != nil
    }

    /// Runs actions outside a conversation (Siri, Shortcuts), with the same
    /// code as the assistant's own.
    func perform(_ actions: [AssistantAction]) -> [AssistantReceipt] { execute(actions) }

    /// Songs asked by subject are found in their lyrics too: the lyrics
    /// Search reads, read first (off the main thread, once per file).
    private func loadLyricsIndex(if needed: Bool) async {
        guard needed else { return }
        let service = libraryService
        let files = service.songs.compactMap { song in
            LyricsTextIndex.shared.needsLoading(song) ? service.resolvedLyricsURL(for: song).map { (song, $0) } : nil
        }
        guard !files.isEmpty else { return }
        await Task.detached(priority: .userInitiated) { LyricsTextIndex.shared.load(files) }.value
    }

    /// The songs the last actions played or put in a playlist.
    private var actedSongs: [Song] = []

    private func execute(_ actions: [AssistantAction]) -> [AssistantReceipt] {
        let library = AssistantLibrary(libraryService: libraryService, player: player)
        actedSongs = []
        var receipts: [AssistantReceipt] = []
        let french = Self.prefersFrench

        func failure(_ resolution: AssistantLibrary.Resolution, _ queries: [SongQuery]) -> AssistantReceipt {
            let what = resolution.missing.nonEmpty?.joined(separator: ", ") ?? queries.map(\.summary).joined(separator: ", ")
            return AssistantReceipt(
                symbol: "questionmark.circle",
                title: french ? "Introuvable" : "Not found",
                detail: french ? "Rien trouvé pour \(what) dans ta bibliothèque." : "Nothing for \(what) in your library.",
                isFailure: true
            )
        }

        for action in actions.prefix(8) {
            let queries = action.songs ?? []
            switch action.type {
            case .playNow, .playNext, .playLater:
                let resolution = library.resolve(queries)
                actedSongs += resolution.songs
                guard !resolution.songs.isEmpty else {
                    receipts.append(failure(resolution, queries))
                    continue
                }
                // A mix is the assistant's own order, played as is: the app's
                // shuffle stays off and the preview shows what plays first.
                let ordered = queries.contains { [.mostPlayed, .leastPlayed, .recentlyPlayed, .recentlyAdded, .newest, .oldest, .title, .libraryOrder, .mostEnergetic, .calmest].contains($0.sort) || $0.versions == true || $0.albums != nil || $0.playlists != nil }
                let mixes = action.shuffle ?? !ordered
                // Random queries already come mixed, spread across albums.
                let alreadyMixed = queries.allSatisfy { ($0.sort == nil || $0.sort == .random) && $0.titles == nil && $0.albums == nil && $0.playlists == nil }
                var songs = Array(resolution.songs.prefix(500))
                if mixes, !alreadyMixed { songs.shuffle() }
                let symbol: String
                let title: String
                switch action.type {
                case .playNow:
                    player.play(songs, shuffled: false)
                    symbol = mixes ? "shuffle" : "play.fill"
                    title = french ? "Lecture" : "Playing"
                case .playNext:
                    for song in songs.prefix(100) { player.addNextToQueue(song: song) }
                    symbol = "text.line.first.and.arrowtriangle.forward"
                    title = french ? "Ensuite" : "Playing Next"
                default:
                    if player.queue.isEmpty {
                        player.play(songs, shuffled: false)
                    } else {
                        for song in songs.prefix(300) { player.addToQueue(song: song) }
                    }
                    symbol = "text.line.last.and.arrowtriangle.forward"
                    title = french ? "Ajouté à la file" : "Added to Queue"
                }
                receipts.append(AssistantReceipt(symbol: symbol, title: title, detail: Self.songsDetail(songs, queries, missing: resolution.missing), songIDs: songs.prefix(4).map(\.id)))

            case .createPlaylist:
                let name = action.name?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyString
                    ?? queries.first?.summary.nonEmptyString
                    ?? (french ? "Ma playlist" : "My Playlist")
                let rules = action.autoUpdate == true && queries.count == 1 ? library.autolistRules(for: queries[0], name: name) : nil
                // An adjustment to a playlist made earlier in this conversation
                // reworks that one instead of adding a near copy.
                if let target = revisedPlaylist(named: action.playlist, newName: name, library: library) {
                    if target.isAutolist, let rules {
                        libraryService.updateAutolist(id: target.id, rules: rules)
                        let updated = libraryService.playlists.first { $0.id == target.id } ?? target
                        receipts.append(AssistantReceipt(
                            symbol: "wand.and.stars",
                            title: french ? "Autolist modifiée" : "Autolist Updated",
                            detail: "\(updated.name) · \(Self.count(updated.songs.count))",
                            songIDs: Array(updated.songs.prefix(4)),
                            destination: .playlist(target.id)
                        ))
                        continue
                    }
                    if !target.isAutolist {
                        guard !queries.contains(where: \.isUnfiltered) else {
                            receipts.append(Self.unchosenSongs())
                            continue
                        }
                        let resolution = library.resolve(queries)
                        actedSongs += resolution.songs
                        guard !resolution.songs.isEmpty else {
                            receipts.append(failure(resolution, queries))
                            continue
                        }
                        if let newName = action.name?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyString, newName != target.name {
                            libraryService.renamePlaylist(target, name: newName)
                        }
                        let ids = Array(resolution.songs.prefix(500).map(\.id))
                        libraryService.setPlaylistSongOrder(playlistId: target.id, songIds: ids)
                        let updatedName = libraryService.playlists.first { $0.id == target.id }?.name ?? target.name
                        receipts.append(AssistantReceipt(
                            symbol: "music.note.list",
                            title: french ? "Playlist modifiée" : "Playlist Updated",
                            detail: "\(updatedName) · \(Self.count(ids.count))",
                            songIDs: Array(ids.prefix(4)),
                            destination: .playlist(target.id)
                        ))
                        continue
                    }
                }
                if let rules {
                    let playlist = libraryService.createAutolist(rules)
                    receipts.append(AssistantReceipt(
                        symbol: "wand.and.stars",
                        title: french ? "Autolist créée" : "Autolist Created",
                        detail: "\(playlist.name) · \(Self.count(playlist.songs.count))",
                        songIDs: Array(playlist.songs.prefix(4)),
                        destination: .playlist(playlist.id)
                    ))
                    continue
                }
                let resolution = library.resolve(queries)
                actedSongs += resolution.songs
                guard !resolution.songs.isEmpty || queries.isEmpty else {
                    receipts.append(failure(resolution, queries))
                    continue
                }
                // Nothing chose the songs: not the whole library as a playlist.
                guard !queries.contains(where: \.isUnfiltered) else {
                    receipts.append(Self.unchosenSongs())
                    continue
                }
                let palette = CoverPalette.allCases.randomElement() ?? .allCases[0]
                let playlist = libraryService.createPlaylist(name: name, cover: .generated(palette))
                let ids = Array(resolution.songs.prefix(500).map(\.id))
                if !ids.isEmpty { libraryService.setPlaylistSongOrder(playlistId: playlist.id, songIds: ids) }
                receipts.append(AssistantReceipt(
                    symbol: "music.note.list",
                    title: french ? "Playlist créée" : "Playlist Created",
                    detail: "\(playlist.name) · \(Self.count(ids.count))",
                    songIDs: Array(ids.prefix(4)),
                    destination: .playlist(playlist.id)
                ))

            case .addToPlaylist, .removeFromPlaylist:
                guard let playlist = action.playlist.flatMap(library.playlist(named:)) else {
                    receipts.append(Self.missingPlaylist(action.playlist))
                    continue
                }
                guard !playlist.isAutolist else {
                    receipts.append(AssistantReceipt(
                        symbol: "wand.and.stars",
                        title: playlist.name,
                        detail: french ? "Une Autolist choisit ses titres seule : modifie plutôt ses règles." : "An Autolist picks its own songs: edit its rules instead.",
                        destination: .playlist(playlist.id),
                        isFailure: true
                    ))
                    continue
                }
                let resolution = library.resolve(queries)
                actedSongs += resolution.songs
                guard !resolution.songs.isEmpty else {
                    receipts.append(failure(resolution, queries))
                    continue
                }
                let adding = action.type == .addToPlaylist
                let songs = resolution.songs.filter { playlist.songs.contains($0.id) != adding }
                for song in songs.prefix(500) {
                    if adding {
                        libraryService.addSongToPlaylist(songId: song.id, playlistId: playlist.id)
                    } else {
                        libraryService.removeSongFromPlaylist(songId: song.id, playlistId: playlist.id)
                    }
                }
                receipts.append(AssistantReceipt(
                    symbol: adding ? "text.badge.plus" : "text.badge.minus",
                    title: adding ? (french ? "Ajouté à \(playlist.name)" : "Added to \(playlist.name)") : (french ? "Retiré de \(playlist.name)" : "Removed from \(playlist.name)"),
                    detail: songs.isEmpty ? (french ? "Rien à changer." : "Nothing to change.") : Self.songsDetail(songs, queries, missing: resolution.missing),
                    songIDs: songs.prefix(4).map(\.id),
                    destination: .playlist(playlist.id)
                ))

            case .renamePlaylist:
                guard let playlist = action.playlist.flatMap(library.playlist(named:)),
                      let name = action.name?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyString else {
                    receipts.append(Self.missingPlaylist(action.playlist))
                    continue
                }
                if var rules = playlist.autolist {
                    rules.customName = name
                    libraryService.updateAutolist(id: playlist.id, rules: rules)
                } else {
                    libraryService.renamePlaylist(playlist, name: name)
                }
                receipts.append(AssistantReceipt(symbol: "pencil", title: french ? "Renommée" : "Renamed", detail: "\(playlist.name) → \(name)", destination: .playlist(playlist.id)))

            case .deletePlaylist:
                guard let playlist = action.playlist.flatMap(library.playlist(named:)) else {
                    receipts.append(Self.missingPlaylist(action.playlist))
                    continue
                }
                var waiting = action
                waiting.playlist = playlist.name
                pending = waiting
                let receipt = AssistantReceipt(
                    symbol: "trash",
                    title: french ? "Supprimer \(playlist.name) ?" : "Delete \(playlist.name)?",
                    detail: Self.count(playlist.songs.count),
                    songIDs: Array(playlist.songs.prefix(4)),
                    awaitsConfirmation: true
                )
                pendingReceiptID = receipt.id
                receipts.append(receipt)

            case .confirm:
                guard let waiting = pending else { continue }
                pending = nil
                pendingReceiptID = nil
                if waiting.type == .deletePlaylist, let playlist = waiting.playlist.flatMap(library.playlist(named:)) {
                    libraryService.deletePlaylist(playlist)
                    receipts.append(AssistantReceipt(symbol: "trash", title: french ? "Supprimée" : "Deleted", detail: playlist.name))
                }

            case .cancel:
                pending = nil
                pendingReceiptID = nil

            case .remember:
                guard let note = action.note?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyString else { continue }
                AssistantMemory.shared.add(note)
                receipts.append(AssistantReceipt(symbol: "bookmark.fill", title: french ? "Retenu" : "Remembered", detail: note))

            case .forget:
                guard let item = action.note.flatMap(AssistantMemory.shared.item(matching:)) else {
                    receipts.append(AssistantReceipt(
                        symbol: "bookmark.slash",
                        title: french ? "Rien à oublier" : "Nothing to forget",
                        detail: french ? "Je n'avais rien retenu de tel." : "I hadn't remembered anything like that.",
                        isFailure: true
                    ))
                    continue
                }
                AssistantMemory.shared.remove(item)
                receipts.append(AssistantReceipt(symbol: "bookmark.slash", title: french ? "Oublié" : "Forgotten", detail: item.text))

            case .removeFromQueue:
                let ids = Set(library.resolve(queries).songs.map(\.id))
                var removed = 0
                for index in player.queue.indices.reversed() where index > player.currentIndex && ids.contains(player.queue[index].id) {
                    player.removeFromQueue(at: index)
                    removed += 1
                }
                receipts.append(AssistantReceipt(symbol: "minus.circle", title: french ? "Retiré de la file" : "Removed from Queue", detail: Self.count(removed)))

            case .clearQueue:
                let upcoming = player.queue.count - player.currentIndex - 1
                for index in player.queue.indices.reversed() where index > player.currentIndex {
                    player.removeFromQueue(at: index)
                }
                receipts.append(AssistantReceipt(symbol: "xmark.circle", title: french ? "File vidée" : "Queue Cleared", detail: Self.count(max(0, upcoming))))

            case .pause:
                player.pause()
                receipts.append(Self.control("pause.fill", french ? "Pause" : "Paused"))
            case .resume:
                guard player.currentSong != nil || !player.queue.isEmpty else {
                    // Nothing to resume: play the whole library, shuffled.
                    player.play(libraryService.songs, shuffled: true)
                    receipts.append(Self.control("shuffle", french ? "Toute ta bibliothèque, en aléatoire" : "Your whole library, shuffled"))
                    continue
                }
                player.play()
                receipts.append(Self.control("play.fill", french ? "Lecture" : "Playing"))
            case .skip:
                player.next()
                receipts.append(Self.control("forward.fill", french ? "Suivant" : "Skipped"))
            case .previous:
                player.skipToPreviousTrack()
                receipts.append(Self.control("backward.fill", french ? "Précédent" : "Previous"))
            case .restart:
                player.seek(to: 0)
                receipts.append(Self.control("backward.end.fill", french ? "Depuis le début" : "From the Top"))
            case .shuffleOn, .shuffleOff:
                let on = action.type == .shuffleOn
                if (player.shuffleMode == .on) != on { player.toggleShuffle() }
                receipts.append(Self.control("shuffle", on ? (french ? "Aléatoire activé" : "Shuffle On") : (french ? "Aléatoire désactivé" : "Shuffle Off")))
            case .repeatOff, .repeatAll, .repeatOne:
                let wanted: RepeatMode = action.type == .repeatOff ? .off : action.type == .repeatAll ? .all : .one
                for _ in 0..<3 where player.repeatMode != wanted { player.toggleRepeat() }
                let symbol = wanted == .one ? "repeat.1" : "repeat"
                let title = switch wanted {
                case .off: french ? "Répétition désactivée" : "Repeat Off"
                case .all: french ? "Répéter tout" : "Repeat All"
                case .one: french ? "Répéter ce titre" : "Repeat One"
                }
                receipts.append(Self.control(symbol, title))

            case .sleepTimer:
                let minutes = max(0, action.minutes ?? 0)
                startSleepTimer(minutes: minutes)
                receipts.append(Self.control("moon.zzz.fill", minutes == 0
                    ? (french ? "Pause à la fin de ce titre" : "Pausing at the end of this song")
                    : (french ? "Pause dans \(minutes) min" : "Pausing in \(minutes) min")))
            case .cancelSleepTimer:
                stopSleepTimer()
                receipts.append(Self.control("moon.zzz", french ? "Minuteur annulé" : "Sleep Timer Off"))

            case .open:
                guard let destination = destination(for: queries.first, playlist: action.playlist, library: library) else {
                    receipts.append(failure(library.resolve(queries), queries))
                    continue
                }
                requestedRoute = destination.route
                receipts.append(AssistantReceipt(symbol: "arrow.up.forward.square", title: french ? "Ouvert" : "Opened", detail: Self.title(of: destination), destination: destination))
            }
        }
        return receipts
    }

    /// Playlists the assistant made or reworked in this conversation and
    /// that still exist, the latest first.
    private func conversationPlaylists() -> [Playlist] {
        let titles: Set<String> = [
            "Playlist créée", "Playlist Created", "Autolist créée", "Autolist Created",
            "Playlist modifiée", "Playlist Updated", "Autolist modifiée", "Autolist Updated",
        ]
        var ids: [UUID] = []
        for message in messages.reversed() {
            for receipt in message.receipts.reversed() where titles.contains(receipt.title) {
                if case let .playlist(id)? = receipt.destination, !ids.contains(id) { ids.append(id) }
            }
        }
        return ids.compactMap { id in libraryService.playlists.first { $0.id == id } }
    }

    /// The conversation's playlist a createPlaylist really revises: the one it
    /// names, else one whose name it repeats ("Mix" → "Mix (complet)").
    private func revisedPlaylist(named wanted: String?, newName: String, library: AssistantLibrary) -> Playlist? {
        let made = conversationPlaylists()
        guard !made.isEmpty else { return nil }
        if let wanted, let named = library.playlist(named: wanted), let match = made.first(where: { $0.id == named.id }) {
            return match
        }
        let key = AssistantText.normalize(newName)
        return made.first { playlist in
            let other = AssistantText.normalize(playlist.name)
            return other == key || AssistantText.containsWords(key, other) || AssistantText.containsWords(other, key)
        }
    }

    private func destination(for query: SongQuery?, playlist: String?, library: AssistantLibrary) -> AssistantReceipt.Destination? {
        if let name = playlist ?? query?.playlists?.first, let match = library.playlist(named: name) {
            return .playlist(match.id)
        }
        guard let query else { return nil }
        if query.albums != nil || query.titles != nil || query.nowPlaying == true {
            if let song = library.resolve(query).songs.first {
                return .album(name: song.album, artist: LibraryIndex.artistName(for: song))
            }
        }
        if let artist = query.artists?.first, let name = library.artistNames(matching: artist).first {
            return .artist(name)
        }
        return nil
    }

    private static func title(of destination: AssistantReceipt.Destination) -> String {
        switch destination {
        case let .playlist(id): AppModel.shared.libraryService.playlists.first { $0.id == id }?.name ?? ""
        case let .artist(name): name
        case let .album(name, artist): "\(name) · \(artist)"
        }
    }

    private static func control(_ symbol: String, _ title: String) -> AssistantReceipt {
        AssistantReceipt(symbol: symbol, title: title, detail: "")
    }

    /// Nil when the reply agrees with what was done; otherwise what was done.
    private static func factualReply(_ reply: String, receipts: [AssistantReceipt], songs: [Song], library: [Song]) -> String? {
        let done = receipts.filter { !$0.isFailure && !$0.awaitsConfirmation }
        guard !songs.isEmpty, let main = done.first(where: { !$0.songIDs.isEmpty }) else { return nil }
        let text = AssistantText.normalize(reply)
        var counts: [String: Int] = [:]
        for song in songs { counts[song.artist, default: 0] += 1 }
        let acted = Set(songs.flatMap { [AssistantText.normalize($0.artist), AssistantText.normalize($0.albumArtist ?? "")] })
        // Artists of the library the reply names, none of whose songs are in.
        let named = Set(library.map { AssistantText.normalize($0.artist) }).filter { $0.count >= 4 && AssistantText.containsWords(text, $0) }
        let strays = named.filter { name in !acted.contains { $0 == name || AssistantText.containsWords($0, name) } }
        // A number of songs that isn't the one done (one action on songs).
        var wrongCount = false
        if done.filter({ !$0.songIDs.isEmpty }).count == 1,
           let regex = try? NSRegularExpression(pattern: #"\b(\d+)\s+(titres?|sons?|morceaux|chansons?|songs?|tracks?)\b"#) {
            let range = NSRange(text.startIndex..., in: text)
            wrongCount = regex.matches(in: text, range: range).contains { match in
                Range(match.range(at: 1), in: text).flatMap { Int(text[$0]) }.map { $0 != songs.count } ?? false
            }
        }
        guard !strays.isEmpty || wrongCount else { return nil }
        let french = prefersFrench
        let artists = counts.sorted { $0.value > $1.value }.map(\.key)
        let and = french ? " et " : " and "
        var who = artists.prefix(3).joined(separator: ", ")
        if artists.count == 2 { who = artists.joined(separator: and) }
        if artists.count == 3 { who = artists[0] + ", " + artists[1] + and + artists[2] }
        if artists.count > 3 { who += french ? " et d'autres" : " and more" }
        let subject = songs.count == 1 ? "\(songs[0].title) — \(songs[0].artist)" : "\(count(songs.count))" + (french ? " de " : " by ") + who
        guard main.destination != nil, let name = main.detail.components(separatedBy: " · ").first, !name.isEmpty else {
            return "\(main.title)\(french ? " : " : ": ")\(subject)."
        }
        return french ? "\(main.title) : « \(name) », \(subject)." : "\(main.title): “\(name)”, \(subject)."
    }

    private static func unchosenSongs() -> AssistantReceipt {
        AssistantReceipt(
            symbol: "questionmark.circle",
            title: prefersFrench ? "Aucun titre choisi" : "No Songs Chosen",
            detail: prefersFrench ? "Je n'ai pas su quels titres y mettre : rien n'a été créé." : "I couldn't tell which songs to put in it: nothing was created.",
            isFailure: true
        )
    }

    private static func missingPlaylist(_ name: String?) -> AssistantReceipt {
        AssistantReceipt(
            symbol: "questionmark.circle",
            title: prefersFrench ? "Playlist introuvable" : "Playlist not found",
            detail: name.map { prefersFrench ? "Aucune playlist « \($0) »." : "No playlist called “\($0)”." } ?? "",
            isFailure: true
        )
    }

    private static func count(_ songs: Int) -> String {
        prefersFrench ? "\(songs) titre\(songs == 1 ? "" : "s")" : "\(songs) song\(songs == 1 ? "" : "s")"
    }

    /// "“One More Time” — Daft Punk" for one song, else "24 songs · Daft Punk, Justice".
    private static func songsDetail(_ songs: [Song], _ queries: [SongQuery], missing: [String]) -> String {
        var detail: String
        if songs.count == 1, let song = songs.first {
            detail = "\(song.title) — \(song.artist)"
        } else {
            detail = count(songs.count)
            let summary = queries.map(\.summary).filter { !$0.isEmpty }.joined(separator: " + ")
            if !summary.isEmpty { detail += " · " + summary }
        }
        if !missing.isEmpty {
            detail += prefersFrench ? " (introuvable : \(missing.joined(separator: ", ")))" : " (not found: \(missing.joined(separator: ", ")))"
        }
        return detail
    }

    // MARK: Sleep timer

    private func startSleepTimer(minutes: Int) {
        stopSleepTimer()
        if minutes > 0 {
            let end = Date().addingTimeInterval(TimeInterval(minutes * 60))
            sleepTimerEnd = end
            sleepTask = Task { [weak self] in
                try? await Task.sleep(until: .now + .seconds(minutes * 60))
                guard !Task.isCancelled, let self else { return }
                self.player.pause()
                self.sleepTimerEnd = nil
            }
        } else {
            stopsAtEndOfSong = true
            let songID = player.currentSong?.id
            sleepTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(500))
                    guard let self else { return }
                    if self.player.currentSong?.id != songID || !self.player.isPlaying && self.player.currentTime == 0 {
                        self.player.pause()
                        self.player.seek(to: 0)
                        self.stopsAtEndOfSong = false
                        return
                    }
                }
            }
        }
    }

    private func stopSleepTimer() {
        sleepTask?.cancel()
        sleepTask = nil
        sleepTimerEnd = nil
        stopsAtEndOfSong = false
    }
}

private extension String {
    var nonEmptyString: String? { isEmpty ? nil : self }
}

// MARK: - Memory

/// What the user asked the assistant to remember, kept on the device and
/// sent with every question.
@MainActor
final class AssistantMemory: ObservableObject {
    static let shared = AssistantMemory()

    struct Item: Identifiable, Codable, Equatable {
        var id = UUID()
        var text: String
        var date = Date()
    }

    @Published private(set) var items: [Item] = []

    private static let fileURL: URL = {
        let folder = URL.applicationSupportDirectory.appending(path: "Assistant", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appending(path: "memories.json")
    }()

    private init() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let saved = try? JSONDecoder().decode([Item].self, from: data) {
            items = saved
        }
    }

    func add(_ text: String) {
        // Saying it again moves it up rather than keeping it twice.
        let key = AssistantText.normalize(text)
        items.removeAll { AssistantText.normalize($0.text) == key }
        items.append(Item(text: text))
        save()
    }

    func remove(_ item: Item) {
        items.removeAll { $0.id == item.id }
        save()
    }

    func remove(atOffsets offsets: IndexSet) {
        items.remove(atOffsets: offsets)
        save()
    }

    func removeAll() {
        items = []
        save()
    }

    /// The remembered thing `wanted` names, by its words or a close spelling.
    func item(matching wanted: String) -> Item? {
        let key = AssistantText.normalize(wanted)
        guard !key.isEmpty else { return nil }
        if let exact = items.last(where: { AssistantText.normalize($0.text) == key }) { return exact }
        let keys = Set(AssistantText.match(wanted, in: items.map { AssistantText.normalize($0.text) }))
        if let found = items.last(where: { keys.contains(AssistantText.normalize($0.text)) }) { return found }
        // Most words in common.
        let words = Set(key.split(separator: " ").filter { $0.count > 2 })
        let scored = items.map { item in (item, Set(AssistantText.normalize(item.text).split(separator: " ")).intersection(words).count) }
        guard let best = scored.max(by: { $0.1 < $1.1 }), best.1 >= max(1, words.count / 2) else { return nil }
        return best.0
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: Self.fileURL, options: .atomic)
        }
    }

    /// iCloud Sync: the memories as another device left them.
    func replaceItems(_ synced: [Item]) {
        guard synced != items else { return }
        items = synced
        save()
    }

    /// "Retiens que je préfère les lives" → remember "je préfère les lives";
    /// "oublie que…" → forget. Nil when the message asks for neither.
    nonisolated static func request(in message: String) -> (text: String, forgets: Bool)? {
        let polite = #"(?:(?:est[- ]ce que )?(?:tu peux|peux[- ]tu|can you|could you|please|stp|s'il te pla[iî]t)[ ,]*)?"#
        let bare = #"\b(?:retiens(?: bien)?|souviens[- ]toi(?: bien)?|rappelle[- ]toi|m[ée]morise|remember)"#
        let remember = #"\b(?:ret(?:iens|enir)(?: bien)?|(?:te )?souvenir|souviens[- ]toi(?: bien)?(?: de)?|rappelle[- ]toi|n['’]oublie pas|garde (?:[çc]a |bien )?en (?:m[ée]moire|t[eê]te)|m[ée]morise|note(?: bien)?|remember|keep in mind|don['’]t forget)"#
        let forget = #"\b(?:oublie|forget)"#
        let tail = #"(?:\s+que|\s+qu['’]|\s+that|\s*:)\s*(.+)$"#
        let options: NSRegularExpression.Options = [.caseInsensitive, .dotMatchesLineSeparators]
        let range = NSRange(message.startIndex..., in: message)
        for (pattern, forgets) in [(polite + forget + tail, true), (polite + remember + tail, false), (#"^\s*"# + polite + bare + #"\s+(.+)$"#, false)] {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: options),
                  let match = regex.firstMatch(in: message, range: range),
                  let found = Range(match.range(at: 1), in: message) else { continue }
            var text = message[found].trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            guard text.count >= 3 else { continue }
            text = text.prefix(1).uppercased() + text.dropFirst()
            return (text, forgets)
        }
        return nil
    }
}
