import Foundation

/// What the user's own words say, read without a model: the songs they
/// describe and, when a phrase leaves no doubt, what to do with them.
/// Apple's on-device model is good at telling what someone wants but makes
/// up details when it fills a long form; the details come from here instead.
struct AssistantParse: Sendable {
    /// The songs described, nil when the words describe none.
    var query: SongQuery?
    /// An action a phrase spells out ("vide la file", "après ce son").
    var intent: AssistantActionType?
    /// A verb asking to hear something ("joue", "mets", "play").
    var asksToPlay = false
    /// An existing playlist named in the request.
    var playlist: String?
    /// After "rename … to" / "appelée": a name for a playlist.
    var newName: String?
    var minutes: Int?
    var autoUpdate = false
    var shuffle: Bool?
    /// The library's artists named, for chat answers' facts.
    var artists: [String] = []
    /// What's left of a request to play that names nothing in the library
    /// ("joue moi Wejdene"), to say it wasn't found.
    var unknown: String?
}

extension AssistantLibrary {
    func parse(_ request: String) -> AssistantParse {
        var parse = AssistantParse()
        var text = AssistantText.normalize(request)
        var query = SongQuery()
        var described = false

        func has(_ phrases: [String]) -> Bool {
            phrases.contains { AssistantText.containsWords(text, $0) }
        }
        func remove(_ phrase: String) {
            text = " \(text) ".replacingOccurrences(of: " \(phrase) ", with: " ").trimmingCharacters(in: .whitespaces)
        }
        /// Whether a phrase is there, taking it out so "après ce son" isn't
        /// also read as "this song".
        func take(_ phrases: [String]) -> Bool {
            let found = phrases.filter { AssistantText.containsWords(text, $0) }
            found.sorted { $0.count > $1.count }.forEach(remove)
            return !found.isEmpty
        }

        // What to do, when it's said plainly.
        let stopping = has(["arrete", "arreter", "stop", "stoppe", "coupe", "couper", "pause", "eteins", "sleep", "minuteur", "timer", "endors"])
        if stopping, let minutes = Self.firstNumber(in: text, before: ["min", "mins", "minute", "minutes", "mn"]) {
            parse.intent = .sleepTimer
            parse.minutes = minutes
        } else if stopping, let hours = Self.firstNumber(in: text, before: ["h", "heure", "heures", "hour", "hours"]) {
            parse.intent = .sleepTimer
            parse.minutes = hours * 60
        } else if stopping, take(["a la fin de ce son", "a la fin de la chanson", "a la fin du son", "a la fin de ce titre", "at the end of this song", "at the end of the song", "after this song", "apres ce son", "apres cette chanson"]) {
            parse.intent = .sleepTimer
            parse.minutes = 0
        } else if take(["vide la file", "vider la file", "efface la file", "clear the queue", "clear queue", "empty the queue", "vide la file d attente", "supprime la file"]) {
            parse.intent = .clearQueue
        } else if take(["apres ce son", "apres cette chanson", "apres ce titre", "apres ce morceau", "apres celle ci", "apres celui ci", "juste apres", "ensuite", "play next", "after this", "after this one", "after this song", "next up", "a la fin de ce son", "quand ce son", "en suivant", "a la suite"]) {
            parse.intent = .playNext
        } else if take(["a la fin de la file", "en fin de file", "ajoute a la file", "ajoute la a la file", "dans la file", "add to the queue", "add to queue", "to the queue", "at the end of the queue", "queue up"]) {
            parse.intent = .playLater
        } else if let first = text.split(separator: " ").first, ["montre", "montre moi", "ouvre", "affiche", "show", "open", "va"].contains(String(first)) {
            parse.intent = .open
        } else if has(["playlist", "autolist"]), has(["cree", "creer", "creee", "genere", "generer", "fais", "faire", "fait", "make", "create", "build", "nouvelle", "new", "compose", "prepare"]) {
            parse.intent = .createPlaylist
        }

        parse.asksToPlay = has(["joue", "jouer", "mets", "met", "mettre", "lance", "lancer", "passe", "envoie", "ecouter", "play", "put on", "je veux", "j ai envie", "fais moi ecouter"])
        parse.autoUpdate = has(["se met a jour", "mise a jour", "se mette a jour", "auto", "automatique", "dynamique", "evolue", "se renouvelle", "update", "updates", "updating", "refresh", "autolist", "smart"])

        // The playlist named, longest name first ("Road trip 2" before "Road trip").
        for playlist in playlists.sorted(by: { $0.name.count > $1.name.count }) {
            let key = AssistantText.normalize(playlist.name)
            guard key.count >= 2, AssistantText.containsWords(text, key) else { continue }
            parse.playlist = playlist.name
            remove(key)
            break
        }
        let renaming = has(["renomme", "renommer", "rename", "change le nom"])
        let namePattern = renaming ? #"\b(en|to|appelee|appele|nommee|called|named|intitulee)\s+(.+)$"# : #"\b(appelee|appele|nommee|called|named|intitulee|nom)\s+(.+)$"#
        if renaming || parse.intent == .createPlaylist, let range = text.range(of: namePattern, options: .regularExpression) {
            if renaming { parse.intent = .renamePlaylist }
            // The name ends where the songs start ("appelée Soirée avec du Queen").
            var words = Array(text[range].split(separator: " ").dropFirst())
            let rest = words.firstIndex { ["avec", "with", "qui", "that", "contenant", "containing", "pleine", "full"].contains($0) }.map { Array(words[$0...]) } ?? []
            words.removeLast(rest.count)
            let originalWords = request.split(separator: " ")
            if let start = originalWords.indices.last(where: { AssistantText.normalize(String(originalWords[$0])) == words.first.map(String.init) }) {
                let original = originalWords[start...].prefix(words.count).joined(separator: " ")
                parse.newName = original.trimmingCharacters(in: CharacterSet(charactersIn: "\"'«»“”.!?,").union(.whitespaces)).nonEmptyName
            }
            text = (String(text[..<range.lowerBound]) + " " + rest.joined(separator: " ")).trimmingCharacters(in: .whitespaces)
        }

        // "This song", "something like this".
        if has(["meme style", "meme genre", "meme vibe", "dans le meme style", "du meme genre", "similar", "like this", "like that", "comme ca", "dans le genre", "same vibe", "same style", "pareil", "similaire", "similaires"]) {
            query.likeNowPlaying = true
            described = true
        } else if has(["ce son", "cette chanson", "ce titre", "ce morceau", "this song", "this track", "current song", "celle ci", "celui ci", "cette musique"]) {
            query.nowPlaying = true
            described = true
        }

        // Artists, longest names first, as whole words.
        var artistNames: [String] = []
        let candidates = Set(songs.flatMap { [LibraryIndex.artistName(for: $0), $0.artist] }).sorted { $0.count > $1.count }
        for name in candidates {
            let key = AssistantText.normalize(name)
            guard key.count >= 2, !Self.fillerWords.contains(key) else { continue }
            if AssistantText.containsWords(text, key) || (key.contains(" ") && AssistantText.containsWords(text, AssistantText.compact(key))) {
                if let display = artistNamesMatching(key: key), !artistNames.contains(display) { artistNames.append(display) }
                remove(key)
            }
        }
        // "Kanye" for Kanye West: a distinctive word of one artist's name.
        let remainingWords = Set(text.split(separator: " ").map(String.init)).subtracting(Self.fillerWords)
        for word in remainingWords where word.count >= 4 && Int(word) == nil {
            let owners = candidates.filter { AssistantText.normalize($0).split(separator: " ").count > 1 && AssistantText.normalize($0).split(separator: " ").contains(Substring(word)) }
            let displays = Set(owners.compactMap { artistNamesMatching(key: AssistantText.normalize($0)) })
            if displays.count == 1, let display = displays.first, !artistNames.contains(display) {
                artistNames.append(display)
                remove(word)
            }
        }
        if !artistNames.isEmpty {
            query.artists = artistNames
            parse.artists = artistNames
            described = true
        }

        // Genres.
        var genres: [String] = []
        let genreWords = Set(genreKeys.values).union(AssistantText.genreSynonyms.keys).sorted { $0.count > $1.count }
        for key in genreWords where key.count >= 2 && AssistantText.containsWords(text, key) {
            for name in genreNames(matching: key) where !genres.contains(name) { genres.append(name) }
            remove(key)
        }
        if !genres.isEmpty {
            query.genres = genres
            described = true
        }

        // Albums, only when asked for by that word.
        if has(["album", "albums", "l album", "the album"]) {
            let albums = Set(songs.map(\.album)).sorted { $0.count > $1.count }
            for album in albums {
                let key = AssistantText.normalize(album)
                guard key.count >= 3, AssistantText.containsWords(text, key) else { continue }
                query.albums = (query.albums ?? []) + [album]
                remove(key)
                described = true
                if (query.albums?.count ?? 0) >= 3 { break }
            }
        }

        // Years.
        if let (from, to) = Self.years(in: text) {
            query.yearFrom = from
            query.yearTo = to
            described = true
        }

        // Order and amount.
        if has(["plus joues", "plus jouees", "plus ecoutes", "plus ecoutees", "most played", "top", "favoris", "favorites", "preferes", "preferees", "les plus", "classiques", "hits"]) {
            query.sort = .mostPlayed
        } else if has(["moins joues", "moins ecoutes", "least played"]) {
            query.sort = .leastPlayed
        } else if has(["jamais ecoute", "jamais ecoutes", "jamais joue", "jamais joues", "never played", "pas encore ecoute", "unplayed"]) {
            query.sort = .neverPlayed
        } else if has(["oublies", "oubliees", "oublie", "forgotten", "delaisses"]) {
            query.sort = .forgotten
        } else if has(["recemment ajoutes", "derniers ajouts", "derniers ajoutes", "recently added", "nouveautes", "new additions", "derniers sons ajoutes", "ajoutes recemment"]) {
            query.sort = .recentlyAdded
        } else if has(["recemment joues", "recemment ecoutes", "recently played", "derniers ecoutes", "ecoute recemment"]) {
            query.sort = .recentlyPlayed
        } else if has(["aleatoire", "random", "au hasard", "melange", "mix", "shuffle", "selection"]) {
            query.sort = .random
            parse.shuffle = true
        } else if has(["plus recents", "newest", "latest", "derniers sortis"]) {
            query.sort = .newest
        } else if has(["plus anciens", "oldest", "plus vieux"]) {
            query.sort = .oldest
        } else if has(["alphabetique", "alphabetical", "par titre", "by title", "de a a z", "a to z"]) {
            query.sort = .title
        }
        if has(["toutes les versions", "plusieurs versions", "plusieurs fois", "les redux", "reprises", "every version", "all versions", "all the versions", "several versions", "several times"]) {
            query.versions = true
        }
        if let sort = query.sort, sort != .random {
            if has(["semaine", "week", "7 jours", "7 days"]) {
                query.period = .week
            } else if has(["mois", "month", "30 jours", "30 days"]) {
                query.period = .month
            } else if has(["cette annee", "this year", "l annee", "the year", "12 mois", "12 months"]) {
                query.period = .year
            }
            described = described || [.mostPlayed, .leastPlayed, .neverPlayed, .forgotten, .recentlyAdded, .recentlyPlayed].contains(sort)
        }
        if query.sort == .random, !described {
            // "A random selection" of the whole library.
            described = parse.asksToPlay || parse.intent == .createPlaylist
        }
        if let limit = Self.firstNumber(in: text, before: ["titres", "titre", "sons", "son", "chansons", "chanson", "morceaux", "morceau", "songs", "song", "tracks", "track"])
            ?? Self.number(after: "top", in: text) {
            query.limit = min(limit, 500)
        }
        if has(["avec paroles", "avec les paroles", "with lyrics", "lyrics"]) {
            query.withLyrics = true
        }

        // A playlist's songs, when it's what to play.
        if let playlist = parse.playlist, !described, ![.addToPlaylist, .removeFromPlaylist, .renamePlaylist, .deletePlaylist, .createPlaylist].contains(parse.intent),
           parse.asksToPlay || [.playNext, .playLater].contains(parse.intent) {
            query.playlists = [playlist]
            described = true
        }

        // Song titles: what's left that names one.
        if !described || (query.artists != nil && query.sort == nil && query.yearFrom == nil && query.genres == nil) {
            let leftover = text.split(separator: " ").map(String.init).filter { !Self.fillerWords.contains($0) }.joined(separator: " ")
            var titles: [String] = []
            var pool = songs
            if let artists = query.artists { pool = pool.filter { artists.contains(LibraryIndex.artistName(for: $0)) || artists.contains($0.artist) } }
            for song in pool.sorted(by: { $0.title.count > $1.title.count }) {
                let key = AssistantText.normalize(song.title)
                guard key.count >= 3, Int(key) == nil, !titles.contains(song.title) else { continue }
                // One-word titles only when they're all that's left.
                let matches = key.contains(" ") ? AssistantText.containsWords(leftover, key) : leftover == key
                if matches {
                    titles.append(song.title)
                    if titles.count >= 5 { break }
                }
            }
            if !titles.isEmpty {
                query.titles = titles
                described = true
            }
        }

        // Nothing named exactly: a misheard or misspelled artist or title.
        let leftover = text.split(separator: " ").map(String.init).filter { !Self.fillerWords.contains($0) }.joined(separator: " ")
        if !described, !leftover.isEmpty, parse.asksToPlay || [.playNext, .playLater, .open].contains(parse.intent) {
            let artistKeys = Array(Set(candidates.map(AssistantText.normalize)))
            if let key = AssistantText.match(leftover, in: artistKeys).first, let display = artistNamesMatching(key: key) {
                query.artists = [display]
                parse.artists = [display]
                described = true
            } else {
                let titleKeys = Array(Set(songs.map { AssistantText.normalize($0.title) }))
                let titles = AssistantText.match(leftover, in: titleKeys).prefix(3)
                if !titles.isEmpty, titles.allSatisfy({ $0.count >= 3 }) {
                    query.titles = Array(titles)
                    described = true
                } else {
                    parse.unknown = leftover
                }
            }
        }

        parse.query = described ? query : nil
        return parse
    }

    private func artistNamesMatching(key: String) -> String? {
        songs.first { AssistantText.normalize(LibraryIndex.artistName(for: $0)) == key }.map(LibraryIndex.artistName(for:))
            ?? songs.first { AssistantText.normalize($0.artist) == key }.map(LibraryIndex.artistName(for:))
    }

    /// Words that never name a song or an artist by themselves.
    static let fillerWords: Set<String> = [
        "joue", "jouer", "moi", "mets", "met", "lance", "passe", "du", "de", "des", "la", "le", "les", "un", "une", "et", "a", "au", "aux", "en",
        "play", "me", "some", "the", "a", "an", "and", "of", "by", "from", "please", "stp", "svp", "s", "il", "te", "plait", "musique", "music",
        "son", "sons", "song", "songs", "titre", "titres", "chanson", "chansons", "morceau", "morceaux", "track", "tracks", "je", "veux", "j", "ai",
        "envie", "ecouter", "maintenant", "now", "truc", "trucs", "quelque", "chose", "something", "peu", "bit", "little", "ma", "mon", "mes",
        "my", "ta", "ton", "tes", "your", "sur", "on", "dans", "in", "with", "avec", "pour", "for", "this", "that", "ce", "cette", "ca", "it",
        "band", "group", "groupe", "artiste", "artist", "dj", "mc",
        "ajoute", "ajouter", "rajoute", "add", "put", "retire", "retirer", "enleve", "enlever", "supprime", "remove", "take", "out",
        "playlist", "la playlist", "file", "queue", "to", "at", "ensuite", "apres", "next", "later", "fin", "end"
    ]

    /// "les années 90", "the 2000s", "de 2015 à 2018", "depuis 2010", "avant 2000", "de 2001".
    static func years(in text: String) -> (Int?, Int?)? {
        func capture(_ pattern: String) -> [Int]? {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
            return (1..<match.numberOfRanges).compactMap { Range(match.range(at: $0), in: text).flatMap { Int(text[$0]) } }
        }
        func decade(_ value: Int) -> Int {
            value < 100 ? (value >= 30 ? 1900 + value : 2000 + value) : value
        }
        if let values = capture(#"\b(19\d\d|20\d\d)\s+(?:a|au|to|et|and|jusqu a|until|through)\s+(19\d\d|20\d\d)\b"#) ?? capture(#"\b(?:entre|between|de|from)\s+(19\d\d|20\d\d)\s+(19\d\d|20\d\d)\b"#),
           values.count == 2 {
            return (min(values[0], values[1]), max(values[0], values[1]))
        }
        if let values = capture(#"\b(?:annees|annee|decennie)\s+(\d0|19\d0|20\d0)\b"#) ?? capture(#"\b(\d0|19\d0|20\d0)\s*s\b"#)
            ?? capture(#"\b(?:the|des)\s+(\d0|19\d0|20\d0)\b"#), let value = values.first {
            let start = decade(value)
            return (start, start + 9)
        }
        let decadeWords = ["seventies": 1970, "eighties": 1980, "nineties": 1990, "sixties": 1960]
        for (word, start) in decadeWords where AssistantText.containsWords(text, word) { return (start, start + 9) }
        if let values = capture(#"\b(?:depuis|since|after|apres|a partir de)\s+(19\d\d|20\d\d)\b"#), let value = values.first {
            return (value, nil)
        }
        if let values = capture(#"\b(?:avant|before)\s+(19\d\d|20\d\d)\b"#), let value = values.first {
            return (nil, value - 1)
        }
        if let values = capture(#"\b(19\d\d|20\d\d)\b"#), let value = values.first {
            return (value, value)
        }
        return nil
    }

    static func firstNumber(in text: String, before units: [String]) -> Int? {
        let words = text.split(separator: " ").map(String.init)
        for index in words.indices.dropLast() where units.contains(words[index + 1]) {
            if let value = Int(words[index]) ?? Self.numberWords[words[index]] { return value }
        }
        // "20min", "2h"
        for word in words {
            for unit in units where word.hasSuffix(unit) && word.count > unit.count {
                if let value = Int(word.dropLast(unit.count)) { return value }
            }
        }
        return nil
    }

    static func number(after word: String, in text: String) -> Int? {
        let words = text.split(separator: " ").map(String.init)
        guard let index = words.firstIndex(of: word), index + 1 < words.count else { return nil }
        return Int(words[index + 1]) ?? numberWords[words[index + 1]]
    }

    static let numberWords: [String: Int] = [
        "un": 1, "une": 1, "deux": 2, "trois": 3, "quatre": 4, "cinq": 5, "six": 6, "sept": 7, "huit": 8, "neuf": 9, "dix": 10,
        "quinze": 15, "vingt": 20, "trente": 30, "quarante": 40, "cinquante": 50, "cent": 100,
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "ten": 10, "fifteen": 15, "twenty": 20, "thirty": 30, "fifty": 50, "hundred": 100
    ]
}

private extension String {
    var nonEmptyName: String? { isEmpty ? nil : self }
}
