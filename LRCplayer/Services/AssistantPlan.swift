import Foundation
import FoundationModels

// What the assistant's model answers with: a reply, and actions the app runs
// itself. The model never names a song the app then trusts: it describes
// songs with a `SongQuery`, matched against the library on the device. One
// type serves both engines: Apple's models fill it through guided generation,
// Mistral through its JSON schema (`AssistantPlan.jsonSchema`).

@Generable
struct AssistantPlan: Codable, Sendable {
    // Generated in this order: small models think of the action first and
    // only rarely need a lookup.
    @Guide(description: "What the app should do, in order, only when the user asks for it. Empty for questions, recaps, opinions and chat.")
    var actions: [AssistantAction]?

    @Guide(description: "Your answer to the user, in their language.")
    var reply: String

    @Guide(description: "True when the reply asks the user something (a confirmation, a choice).")
    var expectsAnswer: Bool?

    @Guide(description: "Rarely needed: library data to fetch before answering, only when CONTEXT lacks it. Never together with actions.")
    var lookups: [AssistantLookup]?

    init(actions: [AssistantAction]? = nil, reply: String, expectsAnswer: Bool? = nil, lookups: [AssistantLookup]? = nil) {
        self.lookups = lookups
        self.actions = actions
        self.reply = reply
        self.expectsAnswer = expectsAnswer
    }
}

@Generable
enum AssistantActionType: String, Codable, Sendable {
    /// Replaces the queue and plays.
    case playNow
    /// Right after the current song.
    case playNext
    /// At the end of the queue.
    case playLater
    case createPlaylist
    case addToPlaylist
    case removeFromPlaylist
    case renamePlaylist
    case deletePlaylist
    /// Removes the matching songs from what's coming up.
    case removeFromQueue
    /// Empties what's coming up; the current song keeps playing.
    case clearQueue
    case pause
    case resume
    case skip
    case previous
    case restart
    case shuffleOn
    case shuffleOff
    case repeatOff
    case repeatAll
    case repeatOne
    case sleepTimer
    case cancelSleepTimer
    /// Shows an artist, album or playlist page.
    case open
    /// Keeps something the user asked to remember (note).
    case remember
    /// Drops something remembered (note).
    case forget
    /// Runs the action waiting for the user's yes.
    case confirm
    case cancel
}

@Generable
struct AssistantAction: Codable, Sendable {
    var type: AssistantActionType

    @Guide(description: "The songs to play, add, remove or open, described by artist, genre, years, sort… Required by every action on songs. Several queries add up.")
    var songs: [SongQuery]?

    @Guide(description: "Name of an existing playlist this acts on. For createPlaylist: the playlist from this conversation it redoes.")
    var playlist: String?

    @Guide(description: "Name for a new or renamed playlist.")
    var name: String?

    @Guide(description: "playNow: shuffle the songs.")
    var shuffle: Bool?

    @Guide(description: "createPlaylist: true for a playlist that keeps itself up to date (most played, recently added…).")
    var autoUpdate: Bool?

    @Guide(description: "sleepTimer: minutes before pausing; 0 pauses at the end of the current song.")
    var minutes: Int?

    @Guide(description: "remember: what to keep, short and self-contained, in the user's language. forget: the remembered thing to drop.")
    var note: String?
}

@Generable
enum SongSort: String, Codable, Sendable {
    /// Album, playlist or artist order.
    case libraryOrder
    case mostPlayed
    case leastPlayed
    case recentlyPlayed
    case recentlyAdded
    case neverPlayed
    /// Loved once, not played for a month.
    case forgotten
    case random
    /// By release year.
    case newest
    case oldest
    /// Alphabetical by title, the versions of one song oldest first.
    case title
    /// By the energy measured from the audio (needs the library analyzed).
    case mostEnergetic
    case calmest
}

/// How a song feels, measured from its audio (tempo, loudness, brightness).
@Generable
enum SongMood: String, Codable, Sendable {
    case energetic
    case balanced
    case calm
}

@Generable
enum StatsPeriod: String, Codable, Sendable {
    case allTime
    case week
    case month
    case year
}

@Generable
struct SongQuery: Codable, Sendable {
    @Guide(description: "Song titles.")
    var titles: [String]?
    @Guide(description: "A subject the songs talk about: the subject and its lexical field (related places, people, events, words, in the languages of the lyrics), found in titles, lyrics or lyrics summaries.")
    var about: [String]?
    var artists: [String]?
    var albums: [String]?
    @Guide(description: "Genre names, as listed in CONTEXT.")
    var genres: [String]?
    @Guide(description: "Songs of these playlists.")
    var playlists: [String]?
    var excludeArtists: [String]?
    @Guide(description: "First release year, inclusive.")
    var yearFrom: Int?
    @Guide(description: "Last release year, inclusive.")
    var yearTo: Int?
    var sort: SongSort?
    @Guide(description: "How the songs feel, measured from their audio. Only when CONTEXT has a Sound line.")
    var mood: SongMood?
    @Guide(description: "Lowest tempo, in BPM. Only when CONTEXT has a Sound line.")
    var bpmFrom: Int?
    @Guide(description: "Highest tempo, in BPM.")
    var bpmTo: Int?
    @Guide(description: "mostPlayed: the period plays are counted over.")
    var period: StatsPeriod?
    @Guide(description: "How many songs at most.")
    var limit: Int?
    @Guide(description: "Only songs with synced lyrics.")
    var withLyrics: Bool?
    @Guide(description: "Songs in the style of the song playing now (same genre and era).")
    var likeNowPlaying: Bool?
    @Guide(description: "The song playing now.")
    var nowPlaying: Bool?
    @Guide(description: "Every version of each song (redux, remix, live, re-recordings), not just one. Without titles: only the songs that exist in several versions.")
    var versions: Bool?
}

@Generable
enum AssistantLookupType: String, Codable, Sendable {
    /// Songs matching a query, with play counts.
    case songs
    /// Listening stats over a period, for some artists if given.
    case stats
    /// The last songs played, with dates.
    case history
    /// Songs whose lyrics contain some words.
    case lyrics
    /// The whole lyrics of a song or two, to read, explain or analyse.
    case songLyrics
    /// Albums matching a query.
    case albums
    /// Everything coming up in the queue.
    case queue
    /// Songs mentioning a subject or its lexical field (songs.about), with
    /// the line and the summary, to judge which are truly about it.
    case subject
    /// Every song's one-line summary of what its lyrics are about.
    case themes
}

@Generable
struct AssistantLookup: Codable, Sendable {
    var type: AssistantLookupType
    var songs: SongQuery?
    var period: StatsPeriod?
    @Guide(description: "lyrics: the words to find.")
    var text: String?
}

// MARK: - Lenient decoding

// Mistral's small models now and then put a string where a list goes or
// write an enum case we don't have: one odd field shouldn't lose the plan.

extension AssistantPlan {
    private enum CodingKeys: String, CodingKey { case actions, reply, expectsAnswer, lookups }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lookups = c.lossyArray(AssistantLookup.self, forKey: .lookups)
        actions = c.lossyArray(AssistantAction.self, forKey: .actions)
        reply = (try? c.decode(String.self, forKey: .reply)) ?? ""
        expectsAnswer = try? c.decodeIfPresent(Bool.self, forKey: .expectsAnswer)
    }
}

extension AssistantAction {
    private enum CodingKeys: String, CodingKey { case type, songs, playlist, name, shuffle, autoUpdate, minutes, note }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(AssistantActionType.self, forKey: .type)
        songs = c.lossyArray(SongQuery.self, forKey: .songs)
        playlist = try? c.decodeIfPresent(String.self, forKey: .playlist)
        name = try? c.decodeIfPresent(String.self, forKey: .name)
        shuffle = try? c.decodeIfPresent(Bool.self, forKey: .shuffle)
        autoUpdate = try? c.decodeIfPresent(Bool.self, forKey: .autoUpdate)
        minutes = c.lossyInt(forKey: .minutes)
        note = try? c.decodeIfPresent(String.self, forKey: .note)
    }
}

extension SongQuery {
    private enum CodingKeys: String, CodingKey {
        case titles, about, artists, albums, genres, playlists, excludeArtists, yearFrom, yearTo, sort, mood, bpmFrom, bpmTo, period, limit, withLyrics, likeNowPlaying, nowPlaying, versions
    }

    /// Nothing narrows it down: the whole library.
    var isUnfiltered: Bool {
        titles?.isEmpty ?? true && about?.isEmpty ?? true && artists?.isEmpty ?? true && albums?.isEmpty ?? true
            && genres?.isEmpty ?? true && playlists?.isEmpty ?? true
            && yearFrom == nil && yearTo == nil && mood == nil && bpmFrom == nil && bpmTo == nil
            && withLyrics != true && likeNowPlaying != true && nowPlaying != true && versions != true
            && (limit ?? 0) <= 0
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        titles = c.lossyStrings(forKey: .titles)
        about = c.lossyStrings(forKey: .about)
        artists = c.lossyStrings(forKey: .artists)
        albums = c.lossyStrings(forKey: .albums)
        genres = c.lossyStrings(forKey: .genres)
        playlists = c.lossyStrings(forKey: .playlists)
        excludeArtists = c.lossyStrings(forKey: .excludeArtists)
        yearFrom = c.lossyInt(forKey: .yearFrom)
        yearTo = c.lossyInt(forKey: .yearTo)
        sort = try? c.decodeIfPresent(SongSort.self, forKey: .sort)
        mood = try? c.decodeIfPresent(SongMood.self, forKey: .mood)
        bpmFrom = c.lossyInt(forKey: .bpmFrom)
        bpmTo = c.lossyInt(forKey: .bpmTo)
        period = try? c.decodeIfPresent(StatsPeriod.self, forKey: .period)
        limit = c.lossyInt(forKey: .limit)
        withLyrics = try? c.decodeIfPresent(Bool.self, forKey: .withLyrics)
        likeNowPlaying = try? c.decodeIfPresent(Bool.self, forKey: .likeNowPlaying)
        nowPlaying = try? c.decodeIfPresent(Bool.self, forKey: .nowPlaying)
        versions = try? c.decodeIfPresent(Bool.self, forKey: .versions)
    }
}

extension AssistantLookup {
    private enum CodingKeys: String, CodingKey { case type, songs, period, text }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(AssistantLookupType.self, forKey: .type)
        songs = try? c.decodeIfPresent(SongQuery.self, forKey: .songs)
        period = try? c.decodeIfPresent(StatsPeriod.self, forKey: .period)
        text = try? c.decodeIfPresent(String.self, forKey: .text)
    }
}

// MARK: - Repairs

extension AssistantPlan {
    /// Fixes what small models get wrong: the songs written in a lookup
    /// instead of the action using them, "this song" left implicit.
    func repaired() -> AssistantPlan {
        var plan = self
        var lookups = plan.lookups ?? []
        guard var actions = plan.actions?.nonEmpty else { return plan }
        for index in actions.indices where actions[index].type.needsSongs && (actions[index].songs?.isEmpty ?? true) {
            if let lookupIndex = lookups.firstIndex(where: { [.songs, .albums].contains($0.type) && $0.songs != nil }),
               let query = lookups[lookupIndex].songs {
                actions[index].songs = [query]
                lookups.remove(at: lookupIndex)
            } else if [.addToPlaylist, .removeFromPlaylist, .removeFromQueue].contains(actions[index].type) {
                var current = SongQuery()
                current.nowPlaying = true
                actions[index].songs = [current]
            }
        }
        plan.actions = actions.filter { !$0.type.needsSongs || !($0.songs?.isEmpty ?? true) }
        // The remaining lookups still run: the reply is often only a preamble
        // ("here's what makes it work:") waiting for their results.
        plan.lookups = lookups.nonEmpty
        return plan
    }
}

extension AssistantActionType {
    var needsSongs: Bool {
        switch self {
        case .playNow, .playNext, .playLater, .addToPlaylist, .removeFromPlaylist, .removeFromQueue: true
        default: false
        }
    }
}

private extension KeyedDecodingContainer {
    /// The elements that decode; a lone object counts as a list of one.
    func lossyArray<T: Decodable>(_ type: T.Type, forKey key: Key) -> [T]? {
        if let items = try? decodeIfPresent([LossyDecodable<T>].self, forKey: key) {
            return items.compactMap(\.value)
        }
        return (try? decodeIfPresent(T.self, forKey: key)).flatMap { $0.map { [$0] } }
    }

    func lossyStrings(forKey key: Key) -> [String]? {
        if let list = try? decodeIfPresent([String].self, forKey: key) { return list.isEmpty ? nil : list }
        if let single = try? decodeIfPresent(String.self, forKey: key), !single.isEmpty { return [single] }
        return nil
    }

    func lossyInt(forKey key: Key) -> Int? {
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Double.self, forKey: key) { return Int(value) }
        if let text = try? decodeIfPresent(String.self, forKey: key) { return Int(text.trimmingCharacters(in: .whitespaces)) }
        return nil
    }
}

// MARK: - JSON schema

extension AssistantPlan {
    /// The guided-generation schema as plain JSON Schema for Mistral, minus
    /// the keys it has no use for.
    nonisolated(unsafe) static let jsonSchema: [String: Any] = {
        guard let data = try? JSONEncoder().encode(AssistantPlan.generationSchema),
              let object = try? JSONSerialization.jsonObject(with: data) else { return [:] }
        func strip(_ value: Any) -> Any {
            if let dictionary = value as? [String: Any] {
                var cleaned: [String: Any] = [:]
                for (key, item) in dictionary where key != "x-order" && key != "title" {
                    cleaned[key] = strip(item)
                }
                return cleaned
            }
            if let array = value as? [Any] { return array.map(strip) }
            return value
        }
        return strip(object) as? [String: Any] ?? [:]
    }()
}
