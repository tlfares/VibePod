import Foundation
import FoundationModels
import NaturalLanguage

/// Which model answers. Apple's run on the device (or on Apple's Private
/// Cloud Compute) for free; Mistral needs the user's key and is the fallback
/// on devices without Apple Intelligence.
enum AssistantEngineChoice: String, CaseIterable, Identifiable {
    case automatic
    case apple
    case mistral

    static let storageKey = "assistantEngine"

    var id: Self { self }

    var title: String {
        switch self {
        case .automatic: String(localized: "Automatic")
        case .apple: "Apple Intelligence"
        case .mistral: "Mistral"
        }
    }

    /// The model picker's label.
    var shortTitle: String {
        switch self {
        case .automatic: "Auto"
        case .apple: "Apple AI"
        case .mistral: "Mistral"
        }
    }

    static var current: AssistantEngineChoice {
        UserDefaults.standard.string(forKey: storageKey).flatMap(Self.init(rawValue:)) ?? .automatic
    }
}

enum AssistantEngineKind: String, Sendable {
    case onDevice
    case mistral

    var title: String {
        switch self {
        case .onDevice: "Apple Intelligence · On Device"
        case .mistral: "Mistral"
        }
    }
}

/// One exchange of the conversation, as the model is reminded of it.
struct AssistantTurn: Sendable {
    var user: String
    var assistant: String
}

struct AssistantPrompt: Sendable {
    var context: String
    var history: [AssistantTurn]
    var message: String
    var lookupResults: String?
    var isVoice: Bool
    /// The request read without a model (the on-device engine relies on it).
    var parse: AssistantParse?
    /// Stats and albums of the artists named, for chat answers that can't
    /// ask for lookups.
    var facts: String?
}

protocol AssistantEngine: Sendable {
    var kind: AssistantEngineKind { get }
    /// How much of the library the context can describe.
    var budget: AssistantLibrary.Budget { get }
    func plan(for prompt: AssistantPrompt) async throws -> AssistantPlan
}

enum AssistantEngines {
    /// The engines to try, best first, for the user's choice.
    static func available(for choice: AssistantEngineChoice = .current) -> [any AssistantEngine] {
        var engines: [any AssistantEngine] = []
        if choice != .mistral {
            if OnDeviceEngine.isAvailable {
                engines.append(OnDeviceEngine())
            }
        }
        if choice != .apple, AIFeatures.isAvailable, let key = AIFeatures.apiKey {
            engines.append(MistralEngine(key: key))
        }
        return engines
    }

    /// Why Apple Intelligence can't answer here, if it can't.
    static var appleUnavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return SystemLanguageModel.default.supportsLocale() ? nil : "Apple Intelligence doesn't speak this device's language yet."
        case .unavailable(.deviceNotEligible):
            return "This device doesn't support Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Apple Intelligence is off in Settings."
        case .unavailable(.modelNotReady):
            return "Apple Intelligence is still downloading."
        case .unavailable:
            return "Apple Intelligence isn't available."
        }
    }

    /// Loads the on-device model ahead of the first question.
    static func prewarm() {
        guard OnDeviceEngine.isAvailable else { return }
        LanguageModelSession().prewarm()
    }
}

// MARK: - Instructions

enum AssistantInstructions {
    static func text(isVoice: Bool) -> String {
        """
        You are the assistant of VibePod, the user's music player app. You know their music library and listening habits (CONTEXT) and you act on the app by returning actions, which the app runs right after your answer.

        HOW TO ANSWER
        - Always reply in the user's language, like a friend who loves music. When you act, one short sentence is enough ("Here's some 2000s Daft Punk!").
        - Questions about their music, recaps, opinions: use the real facts and numbers in CONTEXT and give a real take. Asked to roast or judge their taste: don't hold back, be savage, funny and specific (obsessions, guilty pleasures, songs played on repeat, 3am listening), but about the music, never insulting the person.
        \(isVoice
            ? "- Voice mode: your reply shows on a small card, so no lists, no markdown, no emoji, and keep it brief."
            : "- Text mode: markdown (headings, bold, italics, lists) is fine. Stay under about 300 words: pick the best, don't list everything.")
        - Never write a straight double quote (") inside your reply: it ends the reply early. To quote, use « » in French and “ ” in other languages.

        CHOOSING SONGS
        - Never invent songs and never claim something played: describe songs with queries; the app finds them in the library and shows what it found.
        - Use the names written in CONTEXT when they match what the user means (their genre names, artist spellings). Artists missing from CONTEXT may still exist: query them anyway.
        - In one query, different fields must all match; several values in one field mean any of them. Separate wishes are separate queries ("Daft Punk from 2001 and Justice from 2007" = 2 queries).
        - Years: "the 90s" = yearFrom 1990, yearTo 1999. "From 2005" = yearFrom 2005, yearTo 2005. "Since 2010" = yearFrom 2010 only.
        - "My most played" = sort mostPlayed, with period week, month or year when they say so, limit 25 unless they give a number. "A random selection", "a mix" = sort random, limit 30 unless they give a number. A whole artist or genre: no limit.
        - Several versions of a song (redux, remix, live, reprises, the same title re-recorded in different years): versions true keeps every version. "All the songs X made several times" = artists [X], versions true, no titles. Alphabetical order = sort title (the versions of one song come oldest first).
        - "Something like this", "more of this style" = likeNowPlaying. "This song" = nowPlaying.
        - When CONTEXT has a Sound line, fit the songs to the moment: mood energetic for sport, running, a party, getting hyped, waking up; mood calm for sleep, studying, focus, reading, rain, winding down; bpmFrom/bpmTo for a tempo or a running pace; sort mostEnergetic or calmest to rank by energy. Mix it with their other wishes (artists, genres, years). Roasts can use it too (all ballads, never above 90 BPM…). Without a Sound line, don't use mood or bpm.

        ACTIONS
        - Act only when the user asks for something to happen. Questions, recaps, opinions and roasts get a reply and no actions.
        - Every action on songs carries its songs (the query), right in the action.
        - Read the verb, it decides the action. "Make / create / prepare me a playlist" (fais-moi, crée, prépare) = createPlaylist ONLY: nothing plays, no playNow. "Play / start / put on" (lance, joue, mets, passe-moi) = playNow. "Play … after this one / next" (après celui-ci, ensuite) = playNext. "Add to the queue / at the end / after the queue" (à la suite de la file, à la fin) = playLater. Both make and play only when both are asked ("fais une playlist et lance-la"), then with the very same songs query.
        - playNow replaces the queue and plays at once. playNext plays after the current song ("next", "after this one", "when this song ends"). playLater adds to the end of the queue.
        - shuffle true for artists, genres and mixes; false for an album or a playlist in order.
        - createPlaylist needs name and songs. With playlist set to one of the playlists you made in this conversation, it redoes that one (its songs are replaced, name optional) instead of making another: use it for every correction or adjustment. autoUpdate true when it describes something that changes over time (most played, recently added, never played, a random mix…) so it refreshes itself. Play it only if asked to play it too.
        - addToPlaylist and removeFromPlaylist: playlist and songs. renamePlaylist: playlist and name.
        - deletePlaylist always waits for a yes: send it, ask the user to confirm, set expectsAnswer. If CONTEXT shows a pending confirmation, a yes is confirm and a no is cancel.
        - open shows a page: songs with an artist, album or playlist.
        - sleepTimer with minutes (0 = at the end of the current song).
        - remember with note, only when the user explicitly asks you to remember, note or keep something in mind ("retiens que…", "souviens-toi…", "remember that…"): write the note short and self-contained, in their language ("Préfère les versions live"). forget with note drops a remembered thing. Use what CONTEXT says you remember in every answer, without bringing it up for no reason.
        - Anything you can't do: say so, don't pretend.
        - Your reply is written before the app acts: never give a number of songs (the app shows it), and name only artists whose songs you really put in the actions.

        LOOKUPS
        CONTEXT has the main facts. When you need more (an album's songs, an artist's stats over a period, lyrics containing some words, the whole queue, the last plays), send lookups with no actions; the results come back to you and you answer then.
        - Songs about a subject (a place, a person, a cause, an event, a thing: Palestine, Paris, the moon…): look up subject with songs.about = the subject and its whole lexical field (related places, people, events, symbols and words, in the languages of the lyrics: for Palestine e.g. Palestine, Palestinian, Gaza, West Bank, Cisjordanie, intifada, keffiyeh, Free Palestine, occupation). Then judge each candidate from its line and summary: keep only the songs truly about the subject, drop homonyms and passing mentions (Palestine, Ohio), and act with their titles and artists. Never a song query without any filter for it: that would be the whole library.
        - Songs about a story or a feeling (love, a breakup, leaving home…), a song the user describes without its title, or a mix around a vague theme: look up themes (each song's one-line lyrics summary), then pick the songs by their titles.
        - To read, explain or analyse a song's words (its meaning, themes, references, wordplay, how it's written), look up songLyrics with the song ("this song", "ce son" = nowPlaying). Then analyse it for real: what it's about, the key lines quoted briefly, the images and wordplay, how it fits the artist. Quote a few lines, never the whole lyrics. If the library has no lyrics for it, say so; don't make them up.

        EXAMPLES
        "joue moi du Daft Punk et du Justice de 2007" → {"actions":[{"type":"playNow","shuffle":true,"songs":[{"artists":["Daft Punk","Justice"],"yearFrom":2007,"yearTo":2007}]}],"reply":"C'est parti pour la French Touch de 2007 !"}
        "after this song, my 20 most played this month" → {"actions":[{"type":"playNext","songs":[{"sort":"mostPlayed","period":"month","limit":20}]}],"reply":"Your 20 favorites of the month are up next."}
        "fais moi une playlist de rap des années 90 qui se met à jour" → {"actions":[{"type":"createPlaylist","name":"Rap 90s","autoUpdate":true,"songs":[{"genres":["Hip-Hop/Rap"],"yearFrom":1990,"yearTo":1999,"sort":"random","limit":50}]}],"reply":"Ta playlist Rap 90s est prête, elle se renouvellera toute seule."}
        "fais moi une playlist calme pour dormir, surtout du Mann" → {"actions":[{"type":"createPlaylist","name":"Dodo","songs":[{"artists":["Jonathan Mann"],"mood":"calm","sort":"random","limit":30},{"mood":"calm","sort":"random","limit":8}]}],"reply":"Ta playlist Dodo est prête, que du calme."}
        "fais une playlist des sons qui parlent de la Palestine" → {"lookups":[{"type":"subject","songs":{"about":["Palestine","Palestinian","Gaza","West Bank","Cisjordanie","intifada","keffiyeh","occupation"]}}],"reply":""}
        "lance moi un mix pour courir" → {"actions":[{"type":"playNow","shuffle":true,"songs":[{"mood":"energetic","bpmFrom":150,"bpmTo":180,"sort":"random","limit":30}]}],"reply":"C'est parti, ça va courir !"}
        "add this song to Workout" → {"actions":[{"type":"addToPlaylist","playlist":"Workout","songs":[{"nowPlaying":true}]}],"reply":"Added to Workout."}
        "supprime la playlist Été" → {"actions":[{"type":"deletePlaylist","playlist":"Été"}],"reply":"Je supprime la playlist Été ? Elle a 32 titres.","expectsAnswer":true}
        "roast my taste" → {"actions":[],"reply":"(a savage, specific roast built from their top artists, songs on repeat and listening hours in CONTEXT)"}
        "analyse les paroles de ce son" → {"lookups":[{"type":"songLyrics","songs":{"nowPlaying":true}}],"reply":""}
        """
    }

    /// The user's turn: the recent conversation, the request and any lookup
    /// results.
    static func userText(for prompt: AssistantPrompt, includeHistory: Bool) -> String {
        var parts: [String] = []
        if includeHistory, !prompt.history.isEmpty {
            parts.append("RECENT CONVERSATION\n" + prompt.history.map { "User: \($0.user)\nYou: \($0.assistant)" }.joined(separator: "\n"))
        }
        parts.append("USER (\(prompt.isVoice ? "voice" : "text")): \(prompt.message)")
        if let results = prompt.lookupResults {
            parts.append("LOOKUP RESULTS (fetched for you; give your final answer now, no more lookups)\n\(results)")
        }
        return parts.joined(separator: "\n\n")
    }
}

enum AssistantEngineError: LocalizedError {
    case unreadableAnswer

    var errorDescription: String? {
        switch self {
        case .unreadableAnswer: "The assistant's answer couldn't be read."
        }
    }
}

// MARK: - Apple

/// The on-device model reliably tells what someone wants from a short form
/// but invents details when it fills a long one: it picks the intent, the
/// details come from `AssistantParse`, and conversation is a second,
/// free-text answer.
struct OnDeviceEngine: AssistantEngine {
    var kind: AssistantEngineKind { .onDevice }
    var budget: AssistantLibrary.Budget {
        // 4k-token models get the short version.
        SystemLanguageModel.default.contextSize >= 8000 ? .medium : .compact
    }

    static var isAvailable: Bool {
        SystemLanguageModel.default.availability == .available && SystemLanguageModel.default.supportsLocale()
    }

    func plan(for prompt: AssistantPrompt) async throws -> AssistantPlan {
        let parse = prompt.parse ?? AssistantParse()
        // "Retiens que…" needs no model, and the small one would only
        // paraphrase it.
        if let request = AssistantMemory.request(in: prompt.message) {
            let french = Self.isFrench(prompt.message)
            var action = AssistantAction(type: request.forgets ? .forget : .remember)
            action.note = request.text
            let reply = request.forgets ? (french ? "C'est oublié." : "Forgotten.") : (french ? "C'est noté, je m'en souviendrai." : "Noted, I'll remember that.")
            return AssistantPlan(actions: [action], reply: reply)
        }
        let command = try await classify(prompt)
        guard let action = Self.action(for: command, parse: parse) else {
            return AssistantPlan(reply: try await chat(prompt))
        }
        return AssistantPlan(actions: [action], reply: "")
    }

    private func classify(_ prompt: AssistantPrompt) async throws -> AssistantCommand {
        let playlists = prompt.context.split(separator: "\n").first { $0.hasPrefix("Playlists") }.map(String.init) ?? ""
        let session = LanguageModelSession(model: .default, instructions: Self.classifyInstructions + "\n" + playlists)
        var request = prompt.message
        if let last = prompt.history.last {
            request = "(Previous answer: \(last.assistant.prefix(200)))\n" + request
        }
        return try await session.respond(to: request, generating: AssistantCommand.self, options: GenerationOptions(temperature: 0)).content
    }

    private func chat(_ prompt: AssistantPrompt) async throws -> String {
        // The small model answers in the language of its instructions, not
        // the user's: they're written in the user's.
        let french = Self.isFrench(prompt.message)
        let roast = Self.isRoast(prompt.message)
        var instructions = Self.chatInstructions(french: french, roast: roast, isVoice: prompt.isVoice)
        instructions += (french ? "\n\nCONTEXTE\n" : "\n\nCONTEXT\n") + prompt.context
        if let facts = prompt.facts { instructions += "\n\n" + facts }
        var request = ""
        for turn in prompt.history.suffix(2) {
            request += (french ? "Utilisateur : \(turn.user)\nToi : \(turn.assistant)\n" : "User: \(turn.user)\nYou: \(turn.assistant)\n")
        }
        request += request.isEmpty ? prompt.message : (french ? "Utilisateur : " : "User: ") + prompt.message
        let session = LanguageModelSession(model: .default, instructions: instructions)
        return try await session.respond(to: request, options: GenerationOptions(temperature: roast ? 0.9 : 0.7)).content
    }

    /// The message's language, the device's when it's too short to tell.
    static func isFrench(_ text: String) -> Bool {
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = [.french, .english]
        recognizer.processString(text)
        if let best = recognizer.languageHypotheses(withMaximum: 1).first, best.value > 0.7 {
            return best.key == .french
        }
        return Locale.current.language.languageCode?.identifier == "fr"
    }

    static func isRoast(_ text: String) -> Bool {
        let words = AssistantText.normalize(text)
        return ["roast", "roaste", "clash", "clashe", "juge", "juger", "sans pitie", "lache toi", "defonce", "detruis", "allume moi", "critique", "no mercy", "destroy", "judge", "brutal", "honnetement"].contains {
            AssistantText.containsWords(words, $0)
        }
    }

    /// The model's intent, corrected by what the words say plainly; nil to chat.
    static func action(for command: AssistantCommand, parse: AssistantParse) -> AssistantAction? {
        var type = AssistantActionType(rawValue: command.intent.rawValue)
        let query = parse.query

        // Phrases that leave no doubt win over the model.
        if let hinted = parse.intent {
            switch hinted {
            case .playNext, .playLater:
                if query != nil || parse.playlist != nil { type = hinted }
            case .open:
                if query?.artists != nil || query?.albums != nil || parse.playlist != nil { type = .open }
            default:
                type = hinted
            }
        }
        // "Play X" read as a question, "mets la playlist X" as making one.
        if type == nil || (type == .createPlaylist && parse.intent != .createPlaylist), query != nil || parse.unknown != nil, parse.asksToPlay {
            type = .playNow
        }
        guard let type else { return nil }

        var action = AssistantAction(type: type)
        // The model also names playlists nobody asked about: only the
        // words count.
        action.playlist = parse.playlist
        switch type {
        case .playNow, .playNext, .playLater:
            if let query {
                action.songs = [query]
            } else if let playlist = action.playlist {
                action.songs = [SongQuery(playlists: [playlist])]
            } else if let unknown = parse.unknown {
                // Resolving finds nothing and says so.
                action.songs = [SongQuery(titles: [unknown])]
            } else {
                // "Mets un truc": anything.
                action.songs = [SongQuery(sort: .random, limit: 100)]
            }
            action.playlist = nil
            action.shuffle = parse.shuffle
        case .addToPlaylist, .removeFromPlaylist, .removeFromQueue:
            action.songs = [query ?? SongQuery(nowPlaying: true)]
            if type != .removeFromQueue, action.playlist == nil { return nil }
        case .createPlaylist:
            action.songs = query.map { [$0] }
            action.name = parse.newName ?? command.newName.nonEmpty
            action.autoUpdate = parse.autoUpdate
            action.playlist = nil
        case .renamePlaylist:
            action.name = parse.newName ?? command.newName.nonEmpty
            if action.playlist == nil || action.name == nil { return nil }
        case .deletePlaylist:
            if action.playlist == nil { return nil }
        case .sleepTimer:
            action.minutes = parse.minutes ?? command.minutes
        case .open:
            action.songs = query.map { [$0] } ?? parse.unknown.map { [SongQuery(titles: [$0])] }
            if action.songs == nil, action.playlist == nil { return nil }
        default:
            break
        }
        return action
    }

    static let classifyInstructions = """
    You turn a music player user's request into a command. Rules:
    - playNow: play something now ("joue", "mets", "lance", "play", "une sélection de…", "un mix de…").
    - playNext: right after the current song ("après ce son", "ensuite", "play next"). playLater: at the end of the queue ("ajoute à la file", "à la fin").
    - createPlaylist: make a playlist ("crée", "génère une playlist", "make a playlist").
    - addToPlaylist / removeFromPlaylist: put songs in or take them out of an existing playlist.
    - removeFromQueue: take some songs out of the queue. clearQueue: empty the whole queue ("vide la file").
    - pause, resume, skip, previous, restart, shuffleOn, shuffleOff, repeat…, sleepTimer ("arrête dans 20 minutes", "stop at the end of this song").
    - open: show an artist, album or playlist page ("montre moi", "ouvre", "show me").
    - chat: everything else, including questions about their music, stats, recaps, opinions and roasts.
    """

    static func chatInstructions(french: Bool, roast: Bool, isVoice: Bool) -> String {
        if french {
            let persona = """
            Tu es l'assistant de VibePod, l'app de musique de l'utilisateur, et son pote qui s'y connaît en musique. Tu connais sa bibliothèque et ses habitudes d'écoute grâce au CONTEXTE (écrit en anglais). \
            Tu réponds toujours en français, en le tutoyant, sur un ton naturel et familier, avec les vrais noms et chiffres du CONTEXTE. N'invente aucun chiffre, aucun son, rien sur sa vie ; si le CONTEXTE ne le dit pas, dis-le.
            """
            let task = roast ? """
            Il te demande un roast : un vrai, sans retenue. Écris-le comme un pote qui le démonte à l'oral, pas comme une liste de vannes : \
            choisis un angle (ce que ses écoutes disent de lui comme auditeur) et déroule-le d'un bout à l'autre, chaque phrase s'appuyant sur la précédente, avec les vrais chiffres comme preuves : \
            l'artiste qu'il saigne, le son qu'il use, ses classiques qu'il ne lâche pas, les sons qu'il n'écoute jamais, ses heures d'écoute. \
            Ironie sèche et observations justes plutôt que comparaisons forcées ou formules qui sonnent comme des punchlines. Laisse de côté le son en cours et sa position de lecture. Aucun compliment, aucune excuse, aucune morale, pas de conclusion qui adoucit. Tu vises sa musique, jamais sa personne.
            """ : "Récaps : les temps forts avec les chiffres. Avis : un vrai point de vue, franc, pas tiède."
            let length = isVoice
                ? "Ta réponse est lue à voix haute : phrases courtes à l'oral, pas de listes, pas d'emoji\(roast ? ", un seul paragraphe de cinq ou six phrases." : ", deux ou trois phrases.")"
                : roast ? "Un ou deux paragraphes, sans listes ni sauts de ligne entre chaque phrase." : "Quelques phrases, des listes courtes si besoin."
            return persona + "\n" + task + "\n" + length
        }
        let persona = """
        You are the assistant inside VibePod, the user's music app, and their friend who knows music. You know their library and listening habits from CONTEXT. \
        Answer in English, casually, with the real names and numbers from CONTEXT. Never invent a number, a song or anything about their life; say so when CONTEXT doesn't tell.
        """
        let task = roast ? """
        They're asking for a roast: a real one, no holding back. Write it like a friend taking them apart out loud, not a list of jokes: \
        pick one angle (what their listening says about them as a listener) and carry it from start to finish, each sentence building on the last, with the real numbers as evidence: \
        the artist they wore out, the song they overplay, the classics they can't let go of, the songs they never play, their listening hours. \
        Dry irony and sharp observations rather than forced comparisons or lines that sound like punchlines. Leave the current song and its playback position out. No compliments, no apologies, no moral, no softening ending. Aim at their music, never at them.
        """ : "Recaps: the highlights with numbers. Opinions: a real, honest take, not lukewarm."
        let length = isVoice
            ? "Your answer shows on a small card: short sentences, no lists, no emoji\(roast ? ", one paragraph of five or six sentences." : ", two or three sentences.")"
            : roast ? "One or two paragraphs, no lists, no line break after every sentence." : "A few sentences; short lists are fine."
        return persona + "\n" + task + "\n" + length
    }
}

@Generable
enum AssistantIntent: String, Codable, Sendable {
    case chat, playNow, playNext, playLater, createPlaylist, addToPlaylist, removeFromPlaylist, renamePlaylist, deletePlaylist
    case removeFromQueue, clearQueue, pause, resume, skip, previous, restart
    case shuffleOn, shuffleOff, repeatOff, repeatAll, repeatOne, sleepTimer, cancelSleepTimer, open
}

@Generable
struct AssistantCommand: Codable, Sendable {
    @Guide(description: "What the user asks for. chat when nothing should happen in the app: questions, recaps, opinions, roasts, small talk.")
    var intent: AssistantIntent
    @Guide(description: "The existing playlist named by the user, exactly as listed. Empty if none.")
    var playlist: String
    @Guide(description: "createPlaylist or renamePlaylist: the new name, short. Empty otherwise.")
    var newName: String
    @Guide(description: "sleepTimer: minutes, 0 for the end of the song. 0 otherwise.")
    var minutes: Int
}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Mistral

/// Mistral's free keys allow about a request a second and no request at all
/// on some models: each question costs one call (two or three with
/// lookups), spaced out, and models a key can't use are skipped for a while
/// instead of being tried every time.
struct MistralEngine: AssistantEngine {
    let key: String
    var kind: AssistantEngineKind { .mistral }
    var budget: AssistantLibrary.Budget { .full }

    /// Best first.
    static let models = ["mistral-medium-latest", "mistral-small-latest", "ministral-14b-latest", "ministral-8b-latest"]

    func plan(for prompt: AssistantPrompt) async throws -> AssistantPlan {
        var messages: [[String: String]] = [
            ["role": "system", "content": AssistantInstructions.text(isVoice: prompt.isVoice) + "\n\nCONTEXT\n" + prompt.context]
        ]
        for turn in prompt.history {
            messages.append(["role": "user", "content": turn.user])
            messages.append(["role": "assistant", "content": turn.assistant])
        }
        messages.append(["role": "user", "content": AssistantInstructions.userText(for: prompt, includeHistory: false)])

        var lastError: Error = MistralError.modelUnavailable
        for model in MistralModelMemory.usable(Self.models) {
            do {
                return try await request(model: model, messages: messages)
            } catch MistralError.invalidKey {
                throw MistralError.invalidKey
            } catch MistralError.modelUnavailable {
                MistralModelMemory.skip(model)
                lastError = MistralError.modelUnavailable
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    /// `retriesBrokenAnswer`: an answer whose JSON falls apart midway is
    /// asked for again once before what's readable of it is kept.
    private func request(model: String, messages: [[String: String]], retriesBrokenAnswer: Bool = true) async throws -> AssistantPlan {
        var body: [String: Any] = [
            "model": model,
            "temperature": 0.5,
            "max_tokens": 4000,
            "messages": messages
        ]
        if MistralModelMemory.schemaUnsupported {
            body["response_format"] = ["type": "json_object"]
            var withSchema = messages
            if let data = try? JSONSerialization.data(withJSONObject: AssistantPlan.jsonSchema),
               let schema = String(data: data, encoding: .utf8) {
                withSchema[0]["content", default: ""] += "\n\nAnswer with JSON only, following this JSON schema:\n\(schema)"
            }
            body["messages"] = withSchema
        } else {
            body["response_format"] = [
                "type": "json_schema",
                "json_schema": ["name": "assistant_plan", "schema": AssistantPlan.jsonSchema, "strict": false]
            ]
        }

        var request = URLRequest(url: URL(string: "https://api.mistral.ai/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        await MistralPacer.shared.waitTurn()
        let data: Data
        do {
            (data, _) = try await MistralClient.send(request, retryingOnce: true)
        } catch let MistralError.server(message) where !MistralModelMemory.schemaUnsupported
            && (message.localizedCaseInsensitiveContains("schema") || message.localizedCaseInsensitiveContains("response_format")) {
            // A model without structured outputs: JSON mode, schema in the prompt.
            MistralModelMemory.schemaUnsupported = true
            return try await self.request(model: model, messages: messages, retriesBrokenAnswer: retriesBrokenAnswer)
        }

        struct Response: Decodable {
            struct Choice: Decodable { struct Message: Decodable { let content: String? }; let message: Message }
            let choices: [Choice]
        }
        guard let raw = try JSONDecoder().decode(Response.self, from: data).choices.first?.message.content else {
            throw AssistantEngineError.unreadableAnswer
        }
        // The last answer as sent, to see what the model really asked for.
        let folder = URL.applicationSupportDirectory.appending(path: "Assistant")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? raw.write(to: folder.appending(path: "last-answer.txt"), atomically: true, encoding: .utf8)
        var content = raw
        // Some models wrap JSON in a code fence anyway.
        if let start = content.firstIndex(of: "{"), let end = content.lastIndex(of: "}") {
            content = String(content[start...end])
        }
        if var plan = try? JSONDecoder().decode(AssistantPlan.self, from: Data(content.utf8)) {
            // Ended right after opening emphasis (` *`): an unescaped quote
            // closed the reply early. Shown as cut, not as finished.
            let trimmed = plan.reply.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasSuffix(" *") || trimmed.hasSuffix(" _") || trimmed.hasSuffix(" **") {
                plan.reply = Self.trimmingDanglingMarkup(trimmed) + "…"
            }
            return plan
        }
        // Kept to see what went wrong (pulled from the device).
        let dump = URL.applicationSupportDirectory.appending(path: "Assistant/unreadable-answer.txt")
        try? raw.write(to: dump, atomically: true, encoding: .utf8)
        if retriesBrokenAnswer {
            return try await self.request(model: model, messages: messages, retriesBrokenAnswer: false)
        }
        // Cut off, or quotes left unescaped: keep what it wrote of the reply.
        guard let reply = Self.partialReply(in: raw) else { throw AssistantEngineError.unreadableAnswer }
        return AssistantPlan(reply: reply.isComplete ? reply.text : Self.trimmingDanglingMarkup(reply.text) + "…")
    }

    /// The "reply" string of a JSON answer that stops midway or has quotes
    /// left unescaped, and whether it got to its end.
    static func partialReply(in json: String) -> (text: String, isComplete: Bool)? {
        guard let key = json.range(of: #""reply"\s*:\s*""#, options: .regularExpression) else { return nil }
        let characters = Array(json[key.upperBound...])
        var text = ""
        var index = 0
        var isComplete = false
        while index < characters.count {
            let character = characters[index]
            index += 1
            if character == "\\", index < characters.count {
                let escaped = characters[index]
                index += 1
                switch escaped {
                case "n": text.append("\n")
                case "t": text.append("\t")
                case "u" where index + 4 <= characters.count:
                    let hex = String(characters[index..<index + 4])
                    index += 4
                    if let value = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(value) { text.unicodeScalars.append(scalar) }
                default: text.append(escaped)
                }
            } else if character == "\"" {
                // The closing quote comes before the next key or the end;
                // any other one is a quote the model forgot to escape.
                let after = String(characters[index...].prefix(40)).drop { $0.isWhitespace }
                // The next key has to look like one ("name":), or a stray
                // quote in a broken answer would pass for the end.
                if after.isEmpty || after.hasPrefix("}") || after.range(of: #"^,\s*"[A-Za-z_]+"\s*:"#, options: .regularExpression) != nil {
                    isComplete = true
                    break
                }
                text.append(character)
            } else {
                text.append(character)
            }
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : (trimmed, isComplete)
    }

    /// A reply cut short can end on a lone `*` or `_` that opened emphasis
    /// it never closed: dropped, so no stray mark shows before the "…".
    static func trimmingDanglingMarkup(_ text: String) -> String {
        var text = text
        while let last = text.last, last == "*" || last == "_" || last.isWhitespace {
            text.removeLast()
        }
        return text
    }
}

/// Spaces Mistral calls at least a little over a second apart (the free
/// tier's pace), so a lookup round right after a first answer isn't refused.
actor MistralPacer {
    static let shared = MistralPacer()
    private var last = Date.distantPast

    func waitTurn() async {
        let wait = 1.15 - Date().timeIntervalSince(last)
        if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
        last = Date()
    }
}

/// What this key taught us: models it can't call (retried after a while,
/// the plan may change) and whether structured outputs are refused.
enum MistralModelMemory {
    private static let skipKey = "assistantMistralSkippedModels"
    private static let schemaKey = "assistantMistralJSONModeOnly"
    private static let skipDuration: TimeInterval = 30 * 60

    static func usable(_ models: [String]) -> [String] {
        let skipped = UserDefaults.standard.dictionary(forKey: skipKey) as? [String: Date] ?? [:]
        // Dates set further out than a skip lasts now (an older, longer
        // skip) count as over.
        let now = Date()
        let usable = models.filter {
            let until = skipped[$0] ?? .distantPast
            return until < now || until > now.addingTimeInterval(skipDuration)
        }
        // Never nothing: if every model was skipped, try them all again.
        return usable.isEmpty ? models : usable
    }

    static func skip(_ model: String) {
        var skipped = UserDefaults.standard.dictionary(forKey: skipKey) as? [String: Date] ?? [:]
        skipped[model] = Date().addingTimeInterval(skipDuration)
        UserDefaults.standard.set(skipped, forKey: skipKey)
    }

    /// Forgets everything (a new key).
    static func reset() {
        UserDefaults.standard.removeObject(forKey: skipKey)
        UserDefaults.standard.removeObject(forKey: schemaKey)
    }

    static var schemaUnsupported: Bool {
        get { UserDefaults.standard.bool(forKey: schemaKey) }
        set { UserDefaults.standard.set(newValue, forKey: schemaKey) }
    }
}
