import AVFoundation
import CoreMotion
import SwiftUI

// MARK: - Availability

/// The year in music, told as a story: from December 1st through New
/// Year's Day, or any time with the hidden setting.
@MainActor
enum YearInMusic {
    static let earlyKey = "yearInMusicEarly"

    /// The year to tell, or nil out of season. In season it's December's
    /// year (still last year's on January 1st); early, the year so far
    /// (last year's in January, when this one has barely started).
    static func year(now: Date = Date(), early: Bool) -> Int? {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: now)
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return nil }
        if month == 12 { return year }
        if month == 1, day == 1 { return year - 1 }
        guard early else { return nil }
        return month == 1 ? year - 1 : year
    }

    static func entries(in year: Int) -> [ListeningStatsEntry] {
        let calendar = Calendar.current
        return ListeningStatsService.shared.allEntries().filter { calendar.component(.year, from: $0.timestamp) == year }
    }
}

// MARK: - Data

@MainActor
struct YearInMusicData: Identifiable {
    struct SongItem: Identifiable {
        let id: UUID
        let song: Song?
        let title: String
        let artist: String
        let plays: Int
        let seconds: TimeInterval
    }

    struct ArtistItem: Identifiable {
        var id: String { name }
        let name: String
        let songs: [Song]
        let plays: Int
        let seconds: TimeInterval
    }

    struct AlbumItem: Identifiable {
        let id: String
        let title: String
        let artist: String
        let artwork: ArtworkSource?
        let plays: Int
        let seconds: TimeInterval
    }

    enum Page: Hashable {
        case intro, minutes, topSong, topSongs, topArtist, topArtists, topAlbum, genres, habits, summary

        /// How long the page stays before the next one: time to read it
        /// once everything has come in.
        var duration: TimeInterval {
            switch self {
            case .intro: 6
            case .minutes: 12
            case .topSongs, .topArtists: 14
            case .habits: 13
            case .genres: 11
            default: 10
            }
        }
    }

    nonisolated var id: Int { year }
    let year: Int
    let seconds: TimeInterval
    let plays: Int
    let songCount: Int
    let artistCount: Int
    let addedSongs: Int
    let songs: [SongItem]
    let artists: [ArtistItem]
    let albums: [AlbumItem]
    let genres: [(name: String, plays: Int)]
    let peakHour: Int?
    let peakWeekday: Int?
    let peakMonth: (month: Int, seconds: TimeInterval)?
    /// Played songs still in the library, most played first: the excerpts.
    let ranked: [Song]
    private let songArtist: [UUID: String]
    private let songAlbum: [UUID: String]
    private let songGenre: [UUID: String]

    init(year: Int) {
        self.year = year
        let calendar = Calendar.current
        let entries = YearInMusic.entries(in: year)
        let library = AppModel.shared.libraryService
        let stats = ListeningStatsService.shared

        var songTotals: [UUID: (plays: Int, seconds: TimeInterval, entry: ListeningStatsEntry)] = [:]
        var artistTotals: [String: (plays: Int, seconds: TimeInterval)] = [:]
        var albumTotals: [String: (plays: Int, seconds: TimeInterval, title: String, artist: String, artwork: ArtworkSource?)] = [:]
        var genreTotals: [String: Int] = [:]
        var hours: [Int: Int] = [:]
        var weekdays: [Int: Int] = [:]
        var months: [Int: TimeInterval] = [:]
        var songArtist: [UUID: String] = [:]
        var songAlbum: [UUID: String] = [:]
        var songGenre: [UUID: String] = [:]

        for entry in entries {
            let song = library.song(withID: entry.songID)
            let artist = stats.artist(for: entry)
            songArtist[entry.songID] = artist
            songTotals[entry.songID, default: (0, 0, entry)].plays += 1
            songTotals[entry.songID]?.seconds += entry.durationPlayed
            artistTotals[artist, default: (0, 0)].plays += 1
            artistTotals[artist]?.seconds += entry.durationPlayed

            let album = song?.album ?? entry.album
            if !LibraryIndex.unknownAlbumNames.contains(album.trimmingCharacters(in: .whitespaces).lowercased()) {
                let key = "\(artist)|\(album)"
                songAlbum[entry.songID] = key
                albumTotals[key, default: (0, 0, album, artist, song?.artworkSource)].plays += 1
                albumTotals[key]?.seconds += entry.durationPlayed
                if albumTotals[key]?.artwork == nil, let song { albumTotals[key]?.artwork = song.artworkSource }
            }
            if let genre = song?.genre.trimmingCharacters(in: .whitespaces), !genre.isEmpty {
                genreTotals[genre, default: 0] += 1
                songGenre[entry.songID] = genre
            }
            hours[calendar.component(.hour, from: entry.timestamp), default: 0] += 1
            weekdays[calendar.component(.weekday, from: entry.timestamp), default: 0] += 1
            months[calendar.component(.month, from: entry.timestamp), default: 0] += entry.durationPlayed
        }

        self.songArtist = songArtist
        self.songAlbum = songAlbum
        self.songGenre = songGenre
        ranked = songTotals
            .sorted { $0.value.plays == $1.value.plays ? $0.value.seconds > $1.value.seconds : $0.value.plays > $1.value.plays }
            .compactMap { library.song(withID: $0.key) }
            .filter { !StatsHidden.contains(.song($0.id)) }
            .prefix(40)
            .map { $0 }
        seconds = entries.reduce(0) { $0 + $1.durationPlayed }
        plays = entries.count
        songCount = songTotals.count
        artistCount = artistTotals.count
        addedSongs = library.songs.filter { calendar.component(.year, from: $0.addedAt) == year }.count

        songs = songTotals
            .filter { !StatsHidden.contains(.song($0.key)) }
            .sorted { $0.value.plays == $1.value.plays ? $0.value.seconds > $1.value.seconds : $0.value.plays > $1.value.plays }
            .prefix(5)
            .map { id, total in
                let song = library.song(withID: id)
                return SongItem(id: id, song: song, title: song?.title ?? total.entry.title, artist: song?.artist ?? total.entry.artist, plays: total.plays, seconds: total.seconds)
            }

        let artistSongs = Dictionary(AppModel.shared.libraryVM.artists.map { ($0.name, $0.songs) }, uniquingKeysWith: { first, _ in first })
        artists = artistTotals
            .filter { !StatsHidden.contains(.artist($0.key)) }
            .sorted { $0.value.plays == $1.value.plays ? $0.value.seconds > $1.value.seconds : $0.value.plays > $1.value.plays }
            .prefix(5)
            .map { ArtistItem(name: $0.key, songs: artistSongs[$0.key] ?? [], plays: $0.value.plays, seconds: $0.value.seconds) }

        albums = albumTotals
            .filter { !StatsHidden.contains(.album($0.value.title, artist: $0.value.artist)) }
            .sorted { $0.value.plays > $1.value.plays }
            .prefix(5)
            .map { AlbumItem(id: $0.key, title: $0.value.title, artist: $0.value.artist, artwork: $0.value.artwork, plays: $0.value.plays, seconds: $0.value.seconds) }

        // Genres only when most plays have one: otherwise it would mislead.
        let genrePlays = genreTotals.values.reduce(0, +)
        genres = genrePlays * 2 >= plays
            ? genreTotals.sorted { $0.value > $1.value }.prefix(5).map { (name: $0.key, plays: $0.value) }
            : []
        peakHour = plays >= 10 ? hours.max { $0.value < $1.value }?.key : nil
        peakWeekday = plays >= 10 ? weekdays.max { $0.value < $1.value }?.key : nil
        peakMonth = plays >= 10 ? months.max { $0.value < $1.value }.map { (month: $0.key, seconds: $0.value) } : nil
    }

    var pages: [Page] {
        var pages: [Page] = [.intro, .minutes]
        if !songs.isEmpty { pages.append(.topSong) }
        if songs.count >= 3 { pages.append(.topSongs) }
        if !artists.isEmpty { pages.append(.topArtist) }
        if artists.count >= 3 { pages.append(.topArtists) }
        if !albums.isEmpty { pages.append(.topAlbum) }
        if !genres.isEmpty { pages.append(.genres) }
        if peakHour != nil { pages.append(.habits) }
        pages.append(.summary)
        return pages
    }

    /// The artwork the page's background is made from.
    func backdrop(for page: Page) -> ArtworkSource? {
        let topSong = songs.first?.song?.artworkSource
        let topArtist = artists.first.flatMap(photo(of:))
        let source: ArtworkSource? = switch page {
        case .intro, .topSong: topSong
        case .summary: topArtist
        case .minutes: albums.first?.artwork
        case .topSongs: songs.dropFirst().first?.song?.artworkSource
        case .topArtist, .topArtists: topArtist
        case .topAlbum: albums.first?.artwork
        case .genres: songs.dropFirst(2).first?.song?.artworkSource
        case .habits: albums.dropFirst().first?.artwork
        }
        return source ?? topSong ?? topArtist
    }

    /// The artist's photo, or the cover standing in for it.
    func photo(of artist: ArtistItem) -> ArtworkSource? {
        ArtistImageService.shared.photo(for: artist.name, albums: artist.songs.map(\.album))
            ?? ArtistAvatar.coverSong(in: artist.songs, artist: artist.name)?.artworkSource
    }

    /// The songs a page's excerpt is taken from, closest to what the page
    /// shows first: the played ones, then the rest of the library's.
    func snippetSongs(for page: Page) -> [Song] {
        let top = songs.compactMap(\.song)
        switch page {
        case .intro: return Array(top.dropFirst()) + ranked.dropFirst(5).prefix(10)
        case .minutes, .habits: return Array(ranked.prefix(15))
        case .topSong: return Array(top.prefix(1))
        case .summary: return top + ranked.prefix(15)
        case .topSongs: return Array(top.dropFirst())
        case .topArtist:
            guard let artist = artists.first else { return [] }
            return ranked.filter { songArtist[$0.id] == artist.name } + artist.songs
        case .topArtists:
            return artists.dropFirst().flatMap { artist in
                ranked.filter { songArtist[$0.id] == artist.name }.prefix(2) + artist.songs.prefix(2)
            }
        case .topAlbum:
            guard let album = albums.first else { return [] }
            let tracks = AppModel.shared.libraryService.songs.filter {
                $0.album == album.title && LibraryIndex.artistName(for: $0) == album.artist
            }
            return ranked.filter { songAlbum[$0.id] == album.id } + tracks
        case .genres:
            guard let genre = genres.first else { return [] }
            return ranked.filter { songGenre[$0.id] == genre.name }
        }
    }
}

// MARK: - Excerpts

/// Excerpts under the story: each page plays a song from what it shows,
/// fading over from the last. No song plays twice in one story, and the
/// next opening picks other songs or passages. What was playing stops
/// meanwhile.
@MainActor
final class StorySnippets {
    private var current: AVPlayer?
    private var currentPage: String?
    private var plan: [String: Pick] = [:]
    private var fades: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var resumesMain = false
    private var isHeld = false
    private var isActive = false
    private static let lastPicksKey = "yearInMusicLastExcerpts"
    /// Page → "songID@start" of its last excerpt, across openings.
    private var lastPicks = UserDefaults.standard.dictionary(forKey: StorySnippets.lastPicksKey) as? [String: String] ?? [:]
    private var startsCache: [UUID: [TimeInterval]] = [:]

    func begin() {
        guard !isActive else { return }
        isActive = true
        let player = AppModel.shared.playerVM
        resumesMain = player.isPlaying
        if resumesMain { player.togglePlayPause() }
    }

    func end() {
        guard isActive else { return }
        isActive = false
        if let last = current {
            fade(last, to: 0, over: 0.5) { last.pause() }
        }
        current = nil
        currentPage = nil
        UserDefaults.standard.set(lastPicks, forKey: Self.lastPicksKey)
        guard resumesMain else { return }
        resumesMain = false
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.5))
            let player = AppModel.shared.playerVM
            if !player.isPlaying { player.togglePlayPause() }
        }
    }

    func hold(_ held: Bool) {
        guard held != isHeld else { return }
        isHeld = held
        if held { current?.pause() } else { current?.play() }
    }

    /// Gives every page its song before the story starts, each song once:
    /// the pages with the fewest candidates choose first (the song of the
    /// year's page only has that one), and each page avoids the song it
    /// played last time.
    func prepare(_ pages: [(page: String, songs: [Song])], fallback: [Song]) {
        plan = [:]
        var used = Set<UUID>()
        let backup = fallback.filter(Self.isPlayable)
        let order = pages.indices.sorted {
            let a = pages[$0].songs.count, b = pages[$1].songs.count
            return a == b ? $0 < $1 : a < b
        }
        for index in order {
            let page = pages[index].page
            let pool = pages[index].songs.filter(Self.isPlayable)
            let lastSong = lastPicks[page]?.split(separator: "@").first.map(String.init)
            let tiers = [
                pool.filter { !used.contains($0.id) && $0.id.uuidString != lastSong },
                pool.filter { !used.contains($0.id) },
                backup.filter { !used.contains($0.id) && $0.id.uuidString != lastSong },
                backup.filter { !used.contains($0.id) }
            ]
            // Among the few closest to the page, so it stays about it.
            guard let song = tiers.first(where: { !$0.isEmpty })?.prefix(4).randomElement() else { continue }
            used.insert(song.id)
            plan[page] = Pick(song: song)
        }
    }

    /// Plays the page's song. Back on a page, its song picks up where it
    /// was left.
    func play(page: String) {
        guard isActive, let pick = plan[page] else { return }
        isHeld = false
        if let current, let currentPage, currentPage != page {
            plan[currentPage]?.resumeAt = current.currentTime().seconds
        }
        let start: TimeInterval
        if let resumeAt = pick.resumeAt, resumeAt.isFinite, resumeAt < pick.song.duration - 12 {
            start = resumeAt
        } else if let first = pick.start {
            start = first
        } else {
            let starts = starts(for: pick.song)
            let key = { (start: TimeInterval) in "\(pick.song.id.uuidString)@\(Int(start))" }
            start = starts.filter { key($0) != lastPicks[page] }.randomElement() ?? starts.first ?? 0
            plan[page]?.start = start
            lastPicks[page] = key(start)
        }
        currentPage = page
        self.start(pick.song, at: start)
    }

    private struct Pick {
        let song: Song
        var start: TimeInterval?
        var resumeAt: TimeInterval?
    }

    private static func isPlayable(_ song: Song) -> Bool {
        song.duration > 25 && !(song.isMediaLibraryItem && song.fileURL.scheme == "media-library")
    }

    /// Where an excerpt can start: the chorus (the line sung most often)
    /// when the lyrics are synced, else about a third and half way in.
    private func starts(for song: Song) -> [TimeInterval] {
        if let cached = startsCache[song.id] { return cached }
        var starts: [TimeInterval] = []
        if let url = AppModel.shared.libraryService.resolvedLyricsURL(for: song),
           let content = try? String(contentsOf: url, encoding: .utf8) {
            let lyrics = LRCParser.parse(content: content)
            let lines = lyrics.lines.filter { !$0.isInstrumentalGap }
            let groups = Dictionary(grouping: lines) { $0.text.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces)) }
            if let chorus = groups.filter({ $0.value.count >= 2 && $0.key.count >= 8 }).max(by: { $0.value.count < $1.value.count }) {
                starts = chorus.value.prefix(3).map { max(0, $0.time - lyrics.offset - 1.5) }
            }
        }
        starts = starts.filter { $0 < song.duration - 20 }
        if starts.isEmpty { starts = [0.33, 0.5].map { (song.duration * $0).rounded() } }
        startsCache[song.id] = starts
        return starts
    }

    private func start(_ song: Song, at time: TimeInterval) {
        let player = AVPlayer(url: song.excerptURL)
        player.volume = 0
        if let old = current {
            fade(old, to: 0, over: 0.8) { old.pause() }
        }
        current = player
        player.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak player] finished in
            Task { @MainActor in
                guard let self, let player, finished, self.current === player else { return }
                if !self.isHeld { player.play() }
                self.fade(player, to: 1, over: 1.2)
            }
        }
    }

    private func fade(_ player: AVPlayer, to target: Float, over duration: TimeInterval, then done: (() -> Void)? = nil) {
        let id = ObjectIdentifier(player)
        fades[id]?.cancel()
        let from = player.volume
        fades[id] = Task { @MainActor [weak self] in
            let steps = 30
            for step in 1...steps {
                try? await Task.sleep(for: .seconds(duration / Double(steps)))
                guard !Task.isCancelled else { return }
                let t = Float(step) / Float(steps)
                player.volume = from + (target - from) * (t * t * (3 - 2 * t))
            }
            done?()
            self?.fades[id] = nil
        }
    }
}

// MARK: - Home banner

/// The colored band under the home suggestions that opens the story.
struct YearInMusicBanner: View {
    let year: Int
    let action: () -> Void

    private static let cornerRadius: CGFloat = 22

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: "sparkles")
                    .font(.system(size: 24, weight: .bold))
                    .symbolEffect(.pulse, options: .repeat(2))
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Your \(String(year)) in Music")
                        .font(.headline.bold())
                    Text("Your top songs, artists and more.")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "play.fill")
                    .font(.system(size: 15, weight: .bold))
                    .frame(width: 38, height: 38)
                    .glassEffect(.regular.interactive(), in: .circle)
            }
            .foregroundStyle(.white)
            .padding(.leading, 18)
            .padding(.trailing, 12)
            .padding(.vertical, 14)
            .background {
                MeshGradient(width: 3, height: 2, points: [
                    [0, 0], [0.5, 0], [1, 0],
                    [0, 1], [0.55, 1], [1, 1]
                ], colors: [
                    Color(red: 0.98, green: 0.24, blue: 0.42), Color(red: 0.96, green: 0.42, blue: 0.22), Color(red: 0.99, green: 0.66, blue: 0.24),
                    Color(red: 0.55, green: 0.2, blue: 0.86), Color(red: 0.86, green: 0.2, blue: 0.56), Color(red: 0.98, green: 0.36, blue: 0.3)
                ])
            }
            .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
            .overlay { GlassRim(cornerRadius: Self.cornerRadius, intensity: 1.5) }
            .shadow(color: Color(red: 0.9, green: 0.25, blue: 0.4).opacity(0.3), radius: 14, y: 6)
            .contentShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        }
        .buttonStyle(PressScaleStyle())
    }
}

// MARK: - Story

struct YearInMusicStory: View {
    let data: YearInMusicData
    @Environment(\.dismiss) private var dismiss
    @State private var index = 0
    /// Time the page has run before the current stretch.
    @State private var elapsedBefore: TimeInterval = 0
    /// When the current stretch started; nil while held.
    @State private var runStart: Date? = Date()
    @State private var touchStart: Date?
    @GestureState private var touching = false
    @State private var holdTask: Task<Void, Never>?
    @State private var dragY: CGFloat = 0
    @State private var snippets = StorySnippets()

    private struct TimerKey: Hashable {
        let index: Int
        let running: Bool
    }

    private var pages: [YearInMusicData.Page] { data.pages }
    private var page: YearInMusicData.Page { pages[index] }

    var body: some View {
        ZStack {
            PlayerBackgroundRepresentable(artwork: data.backdrop(for: page), showsMotion: false)
                .ignoresSafeArea()
            if page == .summary {
                SummaryGradient(palette: SummaryPalette(data: data))
                    .overlay(Color.black.opacity(0.5))
                    .ignoresSafeArea()
                    .transition(.opacity)
            }

            // Taps go back or forward, holding pauses, a pull down closes.
            Color.clear
                .contentShape(.rect)
                .gesture(touches)

            pageView
                .id(index)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .scale(scale: 1.04)),
                    removal: .opacity.combined(with: .scale(scale: 0.97))
                ))
                .padding(.horizontal, 28)
                .frame(maxWidth: 560)
                .padding(.top, 70)
                .padding(.bottom, 40)
                .allowsHitTesting(page == .summary)

            VStack {
                chrome
                Spacer()
            }
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .offset(y: max(0, dragY))
        .scaleEffect(1 - min(max(0, dragY), 400) / 2400)
        .statusBarHidden()
        .task(id: TimerKey(index: index, running: runStart != nil)) { await advanceWhenDone() }
        .sensoryFeedback(.impact(weight: .light), trigger: index)
        .onChange(of: touching) { _, isDown in touchChanged(isDown) }
        .onAppear {
            StoryMotion.shared.start()
            snippets.begin()
            snippets.prepare(pages.map { ("\($0)", data.snippetSongs(for: $0)) }, fallback: data.ranked)
            playSnippet()
        }
        .onDisappear {
            snippets.end()
            StoryMotion.shared.stop()
        }
    }

    private func playSnippet() {
        snippets.play(page: "\(page)")
    }

    // MARK: Chrome

    private var chrome: some View {
        VStack(spacing: 12) {
            TimelineView(.animation(paused: runStart == nil || page == .summary)) { context in
                HStack(spacing: 4) {
                    ForEach(pages.indices, id: \.self) { position in
                        Capsule()
                            .fill(.white.opacity(0.28))
                            .overlay(alignment: .leading) {
                                GeometryReader { geometry in
                                    Capsule()
                                        .fill(.white)
                                        .frame(width: geometry.size.width * fill(of: position, at: context.date))
                                }
                            }
                            .frame(height: 3)
                    }
                }
            }
            HStack {
                Text(verbatim: String(data.year))
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white.opacity(0.85))
                Spacer()
                // Below the progress, out of the Mac's title bar (which
                // takes the clicks in its band).
                closeButton
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var closeButton: some View {
        Button {
            snippets.end()
            dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 15, weight: .bold))
                .frame(width: 36, height: 36)
                .contentShape(.circle)
        }
        // Plain: the Mac's default style drew a square behind the glass.
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .keyboardShortcut(.cancelAction)
        .accessibilityLabel("Close")
    }

    private func fill(of position: Int, at now: Date) -> CGFloat {
        if position < index { return 1 }
        if position > index { return 0 }
        if page == .summary { return 1 }
        return CGFloat(min(1, elapsed(at: now) / page.duration))
    }

    // MARK: Timing

    private func elapsed(at now: Date) -> TimeInterval {
        elapsedBefore + (runStart.map { now.timeIntervalSince($0) } ?? 0)
    }

    private func advanceWhenDone() async {
        guard runStart != nil, page != .summary else { return }
        let remaining = page.duration - elapsed(at: Date())
        try? await Task.sleep(for: .seconds(max(0, remaining)))
        guard !Task.isCancelled else { return }
        go(to: index + 1)
    }

    private func pause() {
        guard let start = runStart else { return }
        elapsedBefore += Date().timeIntervalSince(start)
        runStart = nil
        // The music stops only for a real hold: a tap to change page
        // must not cut the excerpt.
        holdTask = Task {
            try? await Task.sleep(for: .seconds(0.3))
            guard !Task.isCancelled else { return }
            snippets.hold(true)
        }
    }

    private func resume() {
        holdTask?.cancel()
        holdTask = nil
        if runStart == nil { runStart = Date() }
        snippets.hold(false)
    }

    private func go(to newIndex: Int) {
        guard pages.indices.contains(newIndex) else { return }
        withAnimation(.smooth(duration: 0.5)) { index = newIndex }
        elapsedBefore = 0
        runStart = Date()
        playSnippet()
    }

    /// A finger is down. Resets by itself when the system cancels the
    /// touch (no `onEnded` then), so the story never stays paused.
    private func touchChanged(_ isDown: Bool) {
        if isDown {
            pause()
        } else {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { dragY = 0 }
            resume()
            // A cancelled touch never reaches onEnded: forget it.
            Task { @MainActor in touchStart = nil }
        }
    }

    private var touches: some Gesture {
        // Global space: the story follows the finger down, which would
        // shrink a local translation.
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .updating($touching) { _, isDown, _ in isDown = true }
            .onChanged { value in
                // From the touch's own clock: the view may update late
                // (a page just came in), a tap must still count as one.
                if touchStart == nil { touchStart = value.time }
                if value.translation.height > 0, abs(value.translation.height) > abs(value.translation.width) {
                    dragY = value.translation.height
                }
            }
            .onEnded { value in
                let held = touchStart.map { value.time.timeIntervalSince($0) } ?? 0
                touchStart = nil
                if value.translation.height > 130 || value.predictedEndTranslation.height > 400 {
                    dismiss()
                    return
                }
                let moved = hypot(value.translation.width, value.translation.height)
                guard moved < 20, held < 0.5 else { return }
                if value.location.x < UIScreen.main.bounds.width * 0.3 {
                    go(to: max(0, index - 1))
                } else if index + 1 < pages.count {
                    go(to: index + 1)
                }
            }
    }

    // MARK: Pages

    @ViewBuilder
    private var pageView: some View {
        switch page {
        case .intro: IntroPage(year: data.year)
        case .minutes: MinutesPage(data: data)
        case .topSong: if let song = data.songs.first { TopSongPage(item: song) }
        case .topSongs: TopSongsPage(songs: data.songs)
        case .topArtist: if let artist = data.artists.first { TopArtistPage(item: artist) }
        case .topArtists: TopArtistsPage(artists: data.artists)
        case .topAlbum: if let album = data.albums.first { TopAlbumPage(item: album) }
        case .genres: GenresPage(genres: data.genres)
        case .habits: HabitsPage(data: data)
        case .summary: SummaryPage(data: data) { dismiss() }
        }
    }
}

// MARK: - Page pieces

/// Rises into place, sharpening, `delay` seconds after the page shows.
private struct Reveal: ViewModifier {
    let delay: Double
    var scale: CGFloat = 1
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 26)
            .scaleEffect(shown ? 1 : scale)
            .blur(radius: shown ? 0 : 10)
            .onAppear {
                withAnimation(.spring(response: 0.75, dampingFraction: 0.82).delay(delay)) { shown = true }
            }
    }
}

private extension View {
    func reveal(_ delay: Double, scale: CGFloat = 1) -> some View {
        modifier(Reveal(delay: delay, scale: scale))
    }
}

/// A number counting up to its value.
private struct CountUp: View, @MainActor Animatable {
    var value: Double
    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        Text(Int(value.rounded()).formatted())
    }
}

private struct CountingNumber: View {
    let target: Double
    let delay: Double
    @State private var value = 0.0

    var body: some View {
        CountUp(value: value)
            .monospacedDigit()
            .onAppear {
                withAnimation(.easeOut(duration: 1.8).delay(delay)) { value = target }
            }
    }
}

private enum StoryFormat {
    static func duration(_ seconds: TimeInterval) -> String {
        let whole = Int(max(60, seconds))
        let units: Set<Duration.UnitsFormatStyle.Unit> = whole >= 86_400 ? [.days, .hours] : [.hours, .minutes]
        return Duration.seconds(whole).formatted(.units(allowed: units, width: .abbreviated, maximumUnitCount: 2))
    }

    static func plays(_ value: Int) -> String {
        String(localized: "\(value) plays")
    }
}

private struct StoryTitle: View {
    let text: LocalizedStringKey

    init(_ text: LocalizedStringKey) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 30, weight: .bold))
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: Motion

/// How the phone moves, for the covers that lean with it.
@MainActor @Observable
final class StoryMotion {
    static let shared = StoryMotion()
    /// -1…1 each way: x leans right, y leans toward you.
    private(set) var tilt = CGPoint.zero
    @ObservationIgnored private let manager = CMMotionManager()
    @ObservationIgnored private var rest: CGPoint?

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        rest = nil
        manager.deviceMotionUpdateInterval = 1.0 / 60
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let gravity = motion?.gravity else { return }
            MainActor.assumeIsolated { self?.update(CGPoint(x: gravity.x, y: gravity.y)) }
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
        tilt = .zero
    }

    private func update(_ gravity: CGPoint) {
        // The rest position slowly follows how the phone is held: only a
        // movement leans the cover, which then settles back.
        var rest = self.rest ?? gravity
        rest.x += (gravity.x - rest.x) * 0.01
        rest.y += (gravity.y - rest.y) * 0.01
        self.rest = rest
        let target = CGPoint(
            x: max(-1, min(1, (gravity.x - rest.x) * 2.6)),
            y: max(-1, min(1, (gravity.y - rest.y) * 2.6))
        )
        tilt.x += (target.x - tilt.x) * 0.22
        tilt.y += (target.y - tilt.y) * 0.22
    }
}

/// Leans in 3D as the phone moves.
private struct LeansWithPhone: ViewModifier {
    var degrees = 11.0
    private var motion: StoryMotion { .shared }

    func body(content: Content) -> some View {
        let tilt = motion.tilt
        content
            .rotation3DEffect(.degrees(tilt.x * degrees), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
            .rotation3DEffect(.degrees(-tilt.y * degrees), axis: (x: 1, y: 0, z: 0), perspective: 0.5)
    }
}

private extension View {
    func leansWithPhone(degrees: Double = 11) -> some View {
        modifier(LeansWithPhone(degrees: degrees))
    }
}

// MARK: Intro

private struct IntroPage: View {
    let year: Int

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            HStack(spacing: 0) {
                ForEach(Array(String(year).enumerated()), id: \.offset) { position, digit in
                    Text(String(digit))
                        .reveal(0.15 + Double(position) * 0.12, scale: 0.6)
                }
            }
            .font(.system(size: 112, weight: .bold))
            .minimumScaleFactor(0.5)
            .lineLimit(1)
            Text("Your Year in Music")
                .font(.system(size: 30, weight: .bold))
                .reveal(0.75)
            Spacer()
            Text("Tap to continue")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.65))
                .reveal(1.6)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }
}

// MARK: Minutes

private struct MinutesPage: View {
    let data: YearInMusicData

    private var comparison: String {
        let hours = data.seconds / 3600
        if hours >= 48 {
            return String(localized: "That's \(Int((hours / 24).rounded())) days of music, end to end.")
        }
        return String(localized: "That's \(max(1, Int(hours.rounded()))) hours of music.")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Spacer()
            Text("This year, you listened for")
                .font(.title2.weight(.bold))
                .reveal(0.1)
            CountingNumber(target: (data.seconds / 60).rounded(), delay: 0.35)
                .font(.system(size: 92, weight: .bold))
                .minimumScaleFactor(0.4)
                .lineLimit(1)
                .reveal(0.3)
            Text("minutes")
                .font(.system(size: 34, weight: .bold))
                .reveal(0.45)
            Text(comparison)
                .font(.title3)
                .foregroundStyle(.white.opacity(0.8))
                .padding(.top, 6)
                .reveal(1.5)
            Spacer()
            HStack(alignment: .top, spacing: 0) {
                figure(data.plays, "Plays")
                figure(data.songCount, "Songs")
                figure(data.artistCount, "Artists")
            }
            .reveal(2.1)
            if data.addedSongs > 0 {
                Text("And \(data.addedSongs) songs added to your library.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.top, 14)
                    .reveal(2.5)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func figure(_ value: Int, _ label: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value.formatted())
                .font(.system(size: 30, weight: .bold))
                .monospacedDigit()
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.7))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: Songs

private struct TopSongPage: View {
    let item: YearInMusicData.SongItem

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            StoryTitle("Your Song of the Year")
                .reveal(0.1)
            ArtworkImage(source: item.song?.artworkSource, cornerRadius: 16, points: 300)
                .frame(width: 280, height: 280)
                .leansWithPhone()
                .shadow(color: .black.opacity(0.4), radius: 30, y: 16)
                .reveal(0.35, scale: 0.85)
            VStack(spacing: 4) {
                Text(item.title)
                    .font(.system(size: 28, weight: .bold))
                    .lineLimit(2)
                Text(item.artist)
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)
            }
            .reveal(0.8)
            Text("\(StoryFormat.plays(item.plays)) · \(StoryFormat.duration(item.seconds))")
                .font(.headline.bold())
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .glassEffect(.regular, in: .capsule)
                .reveal(1.3)
            Spacer()
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }
}

private struct TopSongsPage: View {
    let songs: [YearInMusicData.SongItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Spacer()
            StoryTitle("Your Top Songs")
                .reveal(0.1)
                .padding(.bottom, 6)
            ForEach(Array(songs.enumerated()), id: \.element.id) { position, item in
                HStack(spacing: 14) {
                    Text("\(position + 1)")
                        .font(.system(size: 26, weight: .bold))
                        .monospacedDigit()
                        .frame(width: 28)
                    ArtworkImage(source: item.song?.artworkSource, cornerRadius: 8, points: 64)
                        .frame(width: 60, height: 60)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(.headline.bold())
                            .lineLimit(1)
                        Text(item.artist)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Text(item.plays.formatted())
                        .font(.subheadline.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.75))
                }
                .reveal(0.4 + Double(position) * 0.18)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: Artists

private struct TopArtistPage: View {
    let item: YearInMusicData.ArtistItem

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            StoryTitle("Your Artist of the Year")
                .reveal(0.1)
            ArtistAvatarView(artistName: item.name, songs: item.songs, size: 250)
                .leansWithPhone()
                .shadow(color: .black.opacity(0.4), radius: 30, y: 16)
                .reveal(0.35, scale: 0.85)
            Text(item.name)
                .font(.system(size: 34, weight: .bold))
                .lineLimit(2)
                .minimumScaleFactor(0.6)
                .reveal(0.8)
            Text("\(StoryFormat.plays(item.plays)) · \(StoryFormat.duration(item.seconds))")
                .font(.headline.bold())
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .glassEffect(.regular, in: .capsule)
                .reveal(1.3)
            Spacer()
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }
}

private struct TopArtistsPage: View {
    let artists: [YearInMusicData.ArtistItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Spacer()
            StoryTitle("Your Top Artists")
                .reveal(0.1)
                .padding(.bottom, 6)
            ForEach(Array(artists.enumerated()), id: \.element.id) { position, item in
                HStack(spacing: 14) {
                    Text("\(position + 1)")
                        .font(.system(size: 26, weight: .bold))
                        .monospacedDigit()
                        .frame(width: 28)
                    ArtistAvatarView(artistName: item.name, songs: item.songs, size: 60)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name)
                            .font(.headline.bold())
                            .lineLimit(1)
                        Text(StoryFormat.duration(item.seconds))
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    Spacer(minLength: 8)
                    Text(item.plays.formatted())
                        .font(.subheadline.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.75))
                }
                .reveal(0.4 + Double(position) * 0.18)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: Album

private struct TopAlbumPage: View {
    let item: YearInMusicData.AlbumItem

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            StoryTitle("Your Album of the Year")
                .reveal(0.1)
            ArtworkImage(source: item.artwork, cornerRadius: 12, points: 300, placeholderSymbol: "square.stack")
                .frame(width: 270, height: 270)
                .leansWithPhone()
                .shadow(color: .black.opacity(0.4), radius: 30, y: 16)
                .reveal(0.35, scale: 0.85)
            VStack(spacing: 4) {
                Text(item.title)
                    .font(.system(size: 28, weight: .bold))
                    .lineLimit(2)
                Text(item.artist)
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)
            }
            .reveal(0.8)
            Text("\(StoryFormat.plays(item.plays)) · \(StoryFormat.duration(item.seconds))")
                .font(.headline.bold())
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .glassEffect(.regular, in: .capsule)
                .reveal(1.3)
            Spacer()
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }
}

// MARK: Genres

private struct GenresPage: View {
    let genres: [(name: String, plays: Int)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Spacer()
            StoryTitle("Your Genres")
                .reveal(0.1)
            if let first = genres.first {
                Text(first.name)
                    .font(.system(size: 64, weight: .bold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.5)
                    .reveal(0.4, scale: 0.8)
                Text(StoryFormat.plays(first.plays))
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white.opacity(0.75))
                    .reveal(0.7)
            }
            ForEach(Array(genres.dropFirst().enumerated()), id: \.offset) { position, genre in
                HStack(alignment: .firstTextBaseline) {
                    Text("\(position + 2)")
                        .font(.title2.weight(.bold))
                        .monospacedDigit()
                        .frame(width: 28, alignment: .leading)
                    Text(genre.name)
                        .font(.title2.weight(.bold))
                        .lineLimit(1)
                    Spacer()
                    Text(genre.plays.formatted())
                        .font(.subheadline.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.75))
                }
                .padding(.top, position == 0 ? 22 : 4)
                .reveal(1.1 + Double(position) * 0.2)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: Habits

private struct HabitsPage: View {
    let data: YearInMusicData

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            Spacer()
            StoryTitle("Your Listening Habits")
                .reveal(0.1)
            if let hour = data.peakHour {
                habit("clock.fill", title: "Your music hour", value: hourText(hour), note: hourNote(hour))
                    .reveal(0.45)
            }
            if let weekday = data.peakWeekday {
                habit("calendar", title: "Your favorite day", value: Calendar.current.weekdaySymbols[(weekday - 1) % 7].capitalized, note: nil)
                    .reveal(0.8)
            }
            if let month = data.peakMonth {
                habit("chart.bar.fill", title: "Your biggest month", value: Calendar.current.monthSymbols[(month.month - 1) % 12].capitalized, note: StoryFormat.duration(month.seconds))
                    .reveal(1.15)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func habit(_ symbol: String, title: LocalizedStringKey, value: String, note: String?) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .bold))
                .frame(width: 48, height: 48)
                .glassEffect(.regular, in: .circle)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.7))
                Text(value)
                    .font(.system(size: 30, weight: .bold))
                if let note {
                    Text(note)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
        }
    }

    private func hourText(_ hour: Int) -> String {
        let date = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date()) ?? Date()
        return date.formatted(.dateTime.hour().minute())
    }

    private func hourNote(_ hour: Int) -> String {
        switch hour {
        case 5..<12: String(localized: "A morning listener.")
        case 12..<18: String(localized: "Music all afternoon.")
        case 18..<22: String(localized: "Evenings are for music.")
        default: String(localized: "A night owl.")
        }
    }
}

// MARK: Summary

private struct SummaryPage: View {
    let data: YearInMusicData
    let onDone: () -> Void
    @State private var shareImage: Image?
    /// The photos the shared image was drawn with.
    @State private var sharedPhotos: [String?] = []
    @ObservedObject private var photos = ArtistImageService.shared

    var body: some View {
        // The full card when it fits, else the top three of each.
        ViewThatFits(in: .vertical) {
            content(rows: 5)
            content(rows: 3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear(perform: renderShareImage)
        .onChange(of: photos.revision) {
            // A photo that came in since: drawn again with it.
            if topPhotos != sharedPhotos { renderShareImage() }
        }
    }

    private var topPhotos: [String?] {
        data.artists.prefix(3).map { data.photo(of: $0)?.cacheKey }
    }

    private func content(rows: Int) -> some View {
        VStack(spacing: 22) {
            SummaryCard(data: data, rows: rows)
                .leansWithPhone(degrees: 7)
                .shadow(color: .black.opacity(0.35), radius: 30, y: 14)
                .reveal(0.15, scale: 0.94)
            HStack(spacing: 12) {
                Button(action: onDone) {
                    Text("Done")
                        .font(.headline.bold())
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                }
                .buttonStyle(.glass)
                if let shareImage {
                    ShareLink(item: shareImage, preview: SharePreview(String(localized: "Your \(String(data.year)) in Music"), image: shareImage)) {
                        Label("Share", systemImage: "square.and.arrow.up")
                            .font(.headline.bold())
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(.white)
                }
            }
            .frame(maxWidth: SummaryCard.width)
            .reveal(0.6)
        }
    }

    /// The card on its own colors, darker, as shared.
    private func renderShareImage() {
        sharedPhotos = topPhotos
        let card = SummaryCard(data: data, rows: 5, animated: false)
            .frame(width: SummaryCard.width)
            .shadow(color: .black.opacity(0.3), radius: 24, y: 12)
            .padding(32)
            .background {
                SummaryGradient(palette: SummaryPalette(data: data), animated: false)
                    .overlay(Color.black.opacity(0.42))
            }
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: card)
        renderer.scale = 3
        if let image = renderer.uiImage { shareImage = Image(uiImage: image) }
    }
}

/// The card's colors, from the artist of the year's photo: its hues, rich
/// and deep enough to carry white text.
private struct SummaryPalette {
    let colors: [Color]

    @MainActor
    init(data: YearInMusicData) {
        let source = data.artists.first.flatMap(data.photo(of:)) ?? data.songs.first?.song?.artworkSource
        var tones = (source.map { Song.playerArtworkUIColors(for: $0) } ?? []).compactMap(Tone.init)
        if tones.isEmpty { tones = Tone.festive }
        // One hue alone: its neighbors on either side, for a real gradient.
        if tones.count == 1 { tones.append(tones[0].turned(0.09)) }
        if tones.count == 2 { tones.append(tones[0].turned(-0.1)) }
        let (a, b, c) = (tones[0], tones[1], tones[2])
        // Lit from the top left, a little deeper toward the bottom right.
        colors = [
            a.lit(1.15), b.lit(1.05), c.lit(0.95),
            b.lit(0.95), a.lit(0.88), c.lit(0.8),
            c.lit(0.72), b.lit(0.66), a.lit(0.56)
        ]
    }

    private struct Tone {
        var hue: Double
        var saturation: Double
        var brightness: Double

        /// The home banner's colors, for a photo without any.
        static let festive = [
            Tone(hue: 0.95, saturation: 0.78, brightness: 0.74),
            Tone(hue: 0.05, saturation: 0.8, brightness: 0.74),
            Tone(hue: 0.78, saturation: 0.7, brightness: 0.6)
        ]

        init(hue: Double, saturation: Double, brightness: Double) {
            self.hue = hue
            self.saturation = saturation
            self.brightness = brightness
        }

        /// A photo's color; nil for a gray, which makes no gradient.
        init?(_ color: UIColor) {
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            guard color.getHue(&h, saturation: &s, brightness: &b, alpha: &a), s > 0.14 else { return nil }
            // Yellows read light: a little deeper, for the white text.
            let ceiling = (0.1...0.2).contains(h) ? 0.6 : 0.7
            self.init(hue: h, saturation: min(max(s * 1.15, 0.5), 0.9), brightness: min(max(b, 0.45), ceiling))
        }

        func turned(_ amount: Double) -> Tone {
            Tone(hue: (hue + amount + 1).truncatingRemainder(dividingBy: 1), saturation: saturation, brightness: brightness * 0.85)
        }

        func lit(_ factor: Double) -> Color {
            Color(hue: hue, saturation: factor > 1 ? saturation * 0.9 : saturation, brightness: min(1, brightness * factor))
        }
    }
}

/// The palette as a mesh, its middle slowly drifting.
private struct SummaryGradient: View {
    let palette: SummaryPalette
    var animated = true

    var body: some View {
        if animated {
            TimelineView(.animation) { context in
                mesh(at: context.date.timeIntervalSinceReferenceDate)
            }
        } else {
            mesh(at: 0)
        }
    }

    private func mesh(at time: Double) -> some View {
        let dx = Float(sin(time * 0.4) * 0.12)
        let dy = Float(cos(time * 0.31) * 0.1)
        return MeshGradient(width: 3, height: 3, points: [
            [0, 0], [0.5 + dx * 0.5, 0], [1, 0],
            [0, 0.5 + dy * 0.6], [0.5 + dx, 0.5 + dy], [1, 0.5 - dy * 0.6],
            [0, 1], [0.5 - dx * 0.5, 1], [1, 1]
        ], colors: palette.colors)
    }
}

/// The year on one card, made to be shared, on the colors of the artist
/// of the year's photo.
private struct SummaryCard: View {
    static let width: CGFloat = 340
    let data: YearInMusicData
    let rows: Int
    var animated = true
    @ObservedObject private var photos = ArtistImageService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            artists.padding(.top, 20)
            songs.padding(.top, 20)
            Rectangle()
                .fill(.white.opacity(0.2))
                .frame(height: 1)
                .padding(.vertical, 18)
            HStack(alignment: .top, spacing: 16) {
                figure("Minutes Listened", Int((data.seconds / 60).rounded()).formatted())
                if let genre = data.genres.first {
                    figure("Top Genre", genre.name)
                } else {
                    figure("Plays", data.plays.formatted())
                }
            }
        }
        .foregroundStyle(.white)
        .padding(24)
        .frame(maxWidth: Self.width, alignment: .leading)
        .background {
            SummaryGradient(palette: SummaryPalette(data: data), animated: animated)
                .overlay {
                    LinearGradient(colors: [.clear, .clear, .black.opacity(0.22)], startPoint: .top, endPoint: .bottom)
                }
        }
        .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
        .overlay { GlassRim(cornerRadius: 32) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Year in Music")
                    .textCase(.uppercase)
                    .tracking(0.8)
                Spacer(minLength: 8)
                Text(verbatim: "VibePod")
            }
            .font(.footnote.bold())
            .foregroundStyle(.white.opacity(0.75))
            Text(verbatim: String(data.year))
                .font(.system(size: 54, weight: .bold))
                .tracking(-1)
                .lineLimit(1)
        }
    }

    /// The top three on a podium, the next ones by name.
    private var artists: some View {
        VStack(alignment: .leading, spacing: 8) {
            label("Top Artists")
            podium
                .padding(.top, 4)
            ForEach(Array(data.artists.prefix(rows).enumerated()).dropFirst(3), id: \.offset) { position, artist in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    rank(position)
                    Text(artist.name)
                        .font(.system(size: 17, weight: .bold))
                        .lineLimit(1)
                }
                .padding(.top, position == 3 ? 6 : 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Second, first, third: the first raised in the middle.
    private var podium: some View {
        let top = Array(data.artists.prefix(3))
        return HStack(alignment: .bottom, spacing: 6) {
            ForEach([1, 0, 2].filter { $0 < top.count }, id: \.self) { position in
                VStack(spacing: 8) {
                    avatar(top[position], size: position == 0 ? 82 : 62)
                    Text(top[position].name)
                        .font(.system(size: position == 0 ? 15 : 13, weight: .bold))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                        .frame(maxWidth: .infinity)
                    Text("\(position + 1)")
                        .font(.system(size: position == 0 ? 20 : 16, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(maxWidth: .infinity)
                        .frame(height: [46, 32, 22][position])
                        .background {
                            UnevenRoundedRectangle(topLeadingRadius: 10, topTrailingRadius: 10, style: .continuous)
                                .fill(LinearGradient(colors: [.white.opacity(0.24), .white.opacity(0.08)], startPoint: .top, endPoint: .bottom))
                        }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var songs: some View {
        VStack(alignment: .leading, spacing: 6) {
            label("Top Songs")
                .padding(.bottom, 2)
            ForEach(Array(data.songs.prefix(rows).enumerated()), id: \.offset) { position, song in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    rank(position)
                    Text(song.title)
                        .font(.system(size: 17, weight: .bold))
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func rank(_ position: Int) -> some View {
        Text("\(position + 1)")
            .font(.system(size: 15, weight: .bold))
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.55))
            .frame(width: 14, alignment: .leading)
    }

    /// Drawn right away (the shared image is rendered, not displayed).
    private func avatar(_ artist: YearInMusicData.ArtistItem, size: CGFloat) -> some View {
        let image = data.photo(of: artist).flatMap { ArtworkImageCache.shared.imageSync(for: $0, points: size) }
        return Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.white.opacity(0.18)
                    .overlay {
                        Text(ArtistAvatar.monogram(for: artist.name))
                            .font(.system(size: size * 0.4, weight: .bold))
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay { Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1) }
        .shadow(color: .black.opacity(0.25), radius: 10, y: 5)
    }

    private func figure(_ title: LocalizedStringKey, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            label(title)
            Text(value)
                .font(.system(size: 30, weight: .bold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func label(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.footnote.bold())
            .foregroundStyle(.white.opacity(0.72))
    }
}
