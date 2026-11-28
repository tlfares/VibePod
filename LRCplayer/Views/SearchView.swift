import GameController
import SwiftUI
import CoreImage

/// The Search tab: browse genres when idle, library-wide results while typing.
struct SearchView: View {
    @EnvironmentObject private var libraryVM: LibraryViewModel
    /// Only to play: observed, the page (and its sorted shelves) redrew
    /// at every lyric line and slowed the pages opened from it.
    private var playerVM: PlayerViewModel { AppModel.shared.playerVM }
    @State private var orderCache = BrowseOrderCache()
    @State private var query = ""
    @State private var results = SearchResults()
    @State private var showHiddenSettingsUnlocked = false
    @State private var infoSong: Song?
    /// The artist being merged into another (touch and hold).
    @State private var mergingArtist: String?
    /// Jiggle mode: the cards wobble and can be dragged into a new order.
    @State private var isRearranging = false
    @State private var genreOrder: [Genre] = []
    @State private var artistOrder: [Artist] = []
    @State private var isDragging = false
    @State private var pageScroll = ScrollPosition()
    @State private var pageMetrics = ScrollMetrics()
    /// The page's metrics as it scrolls, unobserved: only rearranging (the
    /// drag's autoscroll) needs them live, so plain scrolling doesn't
    /// recompute the page every frame.
    @State private var latestPageMetrics = ScrollMetricsBox()
    @AppStorage("searchGenreOrder") private var savedGenreOrder = ""
    @AppStorage("searchArtistOrder") private var savedArtistOrder = ""

    var body: some View {
        Group {
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                browse
            } else if results.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                resultsList
            }
        }
        .pageTitle("Search")
        .sheet(item: $infoSong) { song in SongInfoView(song: song) }
        .sheet(isPresented: Binding(get: { mergingArtist != nil }, set: { if !$0 { mergingArtist = nil } })) {
            if let mergingArtist { MergeArtistSheet(name: mergingArtist) }
        }
        .pageSearch(text: $query, prompt: "Artists, Albums, Songs and More", alwaysVisible: true)
        .task(id: SearchKey(query: query, songCount: libraryVM.songs.count, playlistCount: libraryVM.playlists.count, artistCount: libraryVM.artists.count)) {
            // Debounce typing, then search off the main thread.
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let index = libraryVM.index
            let songs = libraryVM.songs
            let playlists = libraryVM.playlists
            let term = query
            let service = libraryVM.libraryService
            let lyricsFiles = songs.compactMap { song in
                LyricsTextIndex.shared.needsLoading(song) ? service.resolvedLyricsURL(for: song).map { (song, $0) } : nil
            }
            let found = await Task.detached(priority: .userInitiated) {
                LyricsTextIndex.shared.load(lyricsFiles)
                return SearchResults(query: term, songs: songs, index: index, playlists: playlists)
            }.value
            guard !Task.isCancelled else { return }
            results = found
        }
        .hiddenSettingsUnlock(searchText: $query, isPresented: $showHiddenSettingsUnlocked)
        .pageLeadingItem(isShown: isRearranging) {
            Button { resetOrder() } label: {
                BarIcon("Reset", systemImage: "arrow.counterclockwise")
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
                .disabled(savedGenreOrder.isEmpty && savedArtistOrder.isEmpty
                    && genreOrder.map(\.id) == defaultGenres.map(\.id) && artistOrder.map(\.id) == defaultArtists.map(\.id))
        }
        .pageTrailingItem(isShown: isRearranging || libraryVM.hasSongs) {
            if isRearranging {
                Button { finishRearranging() } label: {
                    BarIcon("Done", systemImage: "checkmark")
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            } else {
                RouteLink(.allSongs) {
                    BarText("All Songs")
                        .foregroundStyle(.tint)
                }
                .buttonStyle(.plain)
            }
        }
        .animation(.smooth(duration: 0.3), value: isRearranging)
        .sensoryFeedback(.impact(weight: .medium), trigger: isRearranging) { _, new in new }
        .onChange(of: query) { _, new in if !new.isEmpty, isRearranging { finishRearranging() } }
        .onDisappear { if isRearranging { finishRearranging() } }
    }

    // MARK: Rearranging

    private func startRearranging() {
        genreOrder = browseGenres
        artistOrder = browseArtists
        pageMetrics = latestPageMetrics.value
        isRearranging = true
    }

    private func finishRearranging() {
        let genres = genreOrder.map(\.name), artists = artistOrder.map(\.name)
        savedGenreOrder = genres == defaultGenres.map(\.name) ? "" : genres.joined(separator: "\n")
        savedArtistOrder = artists == defaultArtists.map(\.name) ? "" : artists.joined(separator: "\n")
        isRearranging = false
    }

    private func resetOrder() {
        withAnimation(.spring(duration: 0.4, bounce: 0.15)) {
            genreOrder = defaultGenres
            artistOrder = defaultArtists
        }
    }

    /// A side project's profile: counted as another artist from now on.
    private func mergeButton(for name: String) -> some View {
        Section {
            Button("Merge Into Another Artist…", systemImage: "arrow.triangle.merge") { mergingArtist = name }
        }
    }

    private func rearrangeMenu() -> some View {
        Section {
            Button("Rearrange", systemImage: "square.grid.3x1.below.line.grid.1x2") { startRearranging() }
        }
    }

    /// The saved order, then anything new in its default place at the end.
    private static func ordered<Item>(_ items: [Item], saved: String, name: (Item) -> String) -> [Item] {
        guard !saved.isEmpty else { return items }
        let rank = Dictionary(saved.components(separatedBy: "\n").enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return items.enumerated()
            .sorted { (rank[name($0.element)] ?? Int.max, $0.offset) < (rank[name($1.element)] ?? Int.max, $1.offset) }
            .map(\.element)
    }

    // MARK: Browse

    private var browse: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !libraryVM.genres.isEmpty {
                    Text("Browse Genres")
                        .font(.title2.bold())
                        // Two rows, the rest a swipe away, like Music's shelves.
                        if isRearranging {
                            genreShelfRearranging
                        } else {
                            ScrollView(.horizontal) {
                                LazyHGrid(rows: Array(repeating: GridItem(.fixed(108), spacing: 14), count: genreRows), spacing: 14) {
                                    ForEach(browseGenres) { genreLink($0).frame(width: genreCardWidth) }
                                }
                                .scrollTargetLayout()
                            }
                            .scrollIndicators(.hidden)
                            .scrollTargetBehavior(.viewAligned)
                            // Edge to edge, so cards scrolled past the margin
                            // stay drawn instead of being unloaded.
                            .contentMargins(.horizontal, 20, for: .scrollContent)
                            .padding(.horizontal, -20)
                        }
                }
                if !libraryVM.artists.isEmpty {
                    Text("Browse Artists")
                        .font(.title2.bold())
                        .padding(.top, libraryVM.genres.isEmpty ? 0 : 16)
                    if isRearranging {
                        RearrangeableCards(
                            items: $artistOrder,
                            layout: FlowGridLayout(minimum: 160, spacing: 14),
                            axis: .vertical,
                            scroll: $pageScroll,
                            metrics: pageMetrics,
                            isDragging: $isDragging
                        ) { ArtistCard(artist: $0) }
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 14)], spacing: 14) {
                            ForEach(browseArtists) { artist in
                                RouteLink(.artist(artist.name)) {
                                    ArtistCard(artist: artist)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    mergeButton(for: artist.name)
                                    rearrangeMenu()
                                }
                            }
                        }
                    }
                }
                if libraryVM.genres.isEmpty, libraryVM.artists.isEmpty {
                    ContentUnavailableView("Search Your Library", systemImage: "magnifyingglass", description: Text("Find artists, albums, songs and playlists."))
                        .frame(maxWidth: .infinity)
                        .padding(.top, 80)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
        }
        .scrollPosition($pageScroll)
        .scrollDisabled(isDragging)
        .onScrollGeometryChange(for: ScrollMetrics.self) { ScrollMetrics($0, axis: .vertical) } action: { _, new in
            latestPageMetrics.value = new
            if isRearranging { pageMetrics = new }
        }
        .dismissesKeyboardOnScroll()
    }

    private var genreRows: Int { libraryVM.genres.count > 2 ? 2 : 1 }

    @State private var genreScroll = ScrollPosition()
    @State private var genreMetrics = ScrollMetrics()

    private var genreShelfRearranging: some View {
        ScrollView(.horizontal) {
            RearrangeableCards(
                items: $genreOrder,
                layout: ColumnsLayout(rows: genreRows, spacing: 14, rowSpacing: 14),
                axis: .horizontal,
                scroll: $genreScroll,
                metrics: genreMetrics,
                isDragging: $isDragging
            ) { GenreCard(genre: $0).frame(width: genreCardWidth, height: 108) }
            .padding(.vertical, 6)
        }
        .scrollIndicators(.hidden)
        .scrollPosition($genreScroll)
        .scrollDisabled(isDragging)
        .contentMargins(.horizontal, 20, for: .scrollContent)
        .onScrollGeometryChange(for: ScrollMetrics.self) { ScrollMetrics($0, axis: .horizontal) } action: { _, new in genreMetrics = new }
        .padding(.horizontal, -20)
    }

    private var browseGenres: [Genre] {
        isRearranging ? genreOrder : Self.ordered(defaultGenres, saved: savedGenreOrder, name: \.name)
    }

    private var browseArtists: [Artist] {
        isRearranging ? artistOrder : Self.ordered(defaultArtists, saved: savedArtistOrder, name: \.name)
    }

    /// The genres with the most songs first.
    private var defaultGenres: [Genre] {
        orderCache.genres(libraryVM.genres) { Self.sortedGenres($0) }
    }

    private static func sortedGenres(_ genres: [Genre]) -> [Genre] {
        genres.sorted {
            // "Unknown" goes last.
            Self.isUnknown($0.name) != Self.isUnknown($1.name)
                ? Self.isUnknown($1.name)
                : $0.songs.count != $1.songs.count
                ? $0.songs.count > $1.songs.count
                : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// A little under two cards across: the next column peeks in from the
    /// edge, so the shelf reads as scrollable.
    private var genreCardWidth: CGFloat {
        let width = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen.bounds.width ?? 390
        guard width > 700 else { return (width - 20 - 14 * 2) / 2.2 }
        // Wide screens: the artist grid's column width, so both shelves line up.
        let columns = max(1, floor((width - 40 + 14) / (160 + 14)))
        return (width - 40 - 14 * (columns - 1)) / columns
    }

    private func genreLink(_ genre: Genre) -> some View {
        RouteLink(.genre(genre.name)) {
            GenreCard(genre: genre)
        }
        .buttonStyle(.plain)
        .contextMenu { rearrangeMenu() }
    }

    private static func isUnknown(_ name: String) -> Bool {
        name.lowercased().hasPrefix("unknown")
    }

    /// Most-played-in-library first: the artists with the most songs.
    private var defaultArtists: [Artist] {
        orderCache.artists(libraryVM.artists) { Self.sortedArtists($0) }
    }

    private static func sortedArtists(_ artists: [Artist]) -> [Artist] {
        artists.sorted {
            // "Unknown" goes last.
            Self.isUnknown($0.name) != Self.isUnknown($1.name)
                ? Self.isUnknown($1.name)
                : $0.songs.count != $1.songs.count
                ? $0.songs.count > $1.songs.count
                : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    // MARK: Results

    private var resultsList: some View {
        List {
            if !results.artists.isEmpty {
                Section("Artists") {
                    ForEach(results.artists.prefix(6)) { artist in
                        RouteLink(.artist(artist.name), showsChevron: true) {
                            HStack(spacing: 14) {
                                ArtistAvatarView(artistName: artist.name, songs: artist.songs, size: 48)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(artist.name).lineLimit(1)
                                    Text("Artist").font(.subheadline).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .contextMenu { mergeButton(for: artist.name) }
                    }
                }
            }
            if !results.albums.isEmpty {
                Section("Albums") {
                    ForEach(results.albums.prefix(8)) { album in
                        RouteLink(.album(album.id), showsChevron: true) {
                            HStack(spacing: 14) {
                                ArtworkImage(source: album.artworkSource, cornerRadius: 6, points: 48)
                                    .frame(width: 48, height: 48)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(album.title).lineLimit(1)
                                    Text(album.isSingle ? "Single · \(album.artist)" : "Album · \(album.artist)")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                        .contextMenu { HomeItemMenu(item: .album(album)) }
                    }
                }
            }
            if !results.playlists.isEmpty {
                Section("Playlists") {
                    ForEach(results.playlists) { playlist in
                        RouteLink(.playlist(playlist.id), showsChevron: true) {
                            HStack(spacing: 14) {
                                ArtworkImage(source: libraryVM.playlistArtwork(playlist), cornerRadius: 6, points: 48, placeholderSymbol: "music.note.list")
                                    .frame(width: 48, height: 48)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(playlist.name).lineLimit(1)
                                    Text("Playlist").font(.subheadline).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .contextMenu { HomeItemMenu(item: .playlist(playlist)) }
                    }
                }
            }
            if !results.songs.isEmpty {
                Section("Songs") {
                    ForEach(results.songs) { song in
                        SongRow(song: song, subtitle: "\(song.artist) · \(song.album)")
                            .onTapGesture { playerVM.play(song: song, from: results.songs) }
                            .contextMenu { SongContextMenu(song: song, onInfo: { infoSong = song }) }
                            .swipeActions(edge: .leading) { QueueSwipeButtons(song: song) }
                            .swipeActions(edge: .trailing) { SwipeLeftButtons(song: song) }
                    }
                }
            }
            if !results.lyricMatches.isEmpty {
                Section("Lyrics") {
                    ForEach(results.lyricMatches, id: \.song.id) { match in
                        VStack(alignment: .leading, spacing: 4) {
                            SongRow(song: match.song, subtitle: "\(match.song.artist) · \(match.song.album)")
                            highlighted(match.quote, terms: results.terms)
                                .font(.footnote)
                                .italic()
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .padding(.leading, 56)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { playerVM.play(song: match.song, from: results.lyricMatches.map(\.song)) }
                        .contextMenu { SongContextMenu(song: match.song, onInfo: { infoSong = match.song }) }
                        .swipeActions(edge: .leading) { QueueSwipeButtons(song: match.song) }
                        .swipeActions(edge: .trailing) { SwipeLeftButtons(song: match.song) }
                    }
                }
            }
        }
        .listStyle(.plain)
        .dismissesKeyboardOnScroll()
    }
}

/// The quote in quotation marks, the searched words standing out from
/// its gray in the primary color.
private func highlighted(_ quote: String, terms: [String]) -> Text {
    var bold: [Range<String.Index>] = []
    for term in terms {
        var searchStart = quote.startIndex
        while let range = quote.range(of: term, options: [.caseInsensitive, .diacriticInsensitive], range: searchStart..<quote.endIndex) {
            bold.append(range)
            searchStart = range.upperBound
        }
    }
    var text = Text("“")
    var position = quote.startIndex
    for range in bold.sorted(by: { $0.lowerBound < $1.lowerBound }) where range.lowerBound >= position {
        text = text + Text(quote[position..<range.lowerBound]) + Text(quote[range]).foregroundStyle(.primary)
        position = range.upperBound
    }
    return text + Text(quote[position...]) + Text("”")
}

private struct SearchKey: Hashable {
    let query: String
    let songCount: Int
    let playlistCount: Int
    /// Fewer once an artist is merged into another.
    let artistCount: Int
}

struct SearchResults: Sendable {
    var artists: [Artist] = []
    var albums: [Album] = []
    var songs: [Song] = []
    var playlists: [Playlist] = []
    /// Songs found by their words, with the lines they were found in.
    var lyricMatches: [(song: Song, quote: String)] = []
    /// The query's words, folded, to bold them in the quotes.
    var terms: [String] = []

    var isEmpty: Bool { artists.isEmpty && albums.isEmpty && songs.isEmpty && playlists.isEmpty && lyricMatches.isEmpty }

    init() {}

    init(query: String, songs: [Song], index: LibraryIndex, playlists: [Playlist]) {
        let terms = query
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard !terms.isEmpty else { return }
        self.terms = terms

        func matches(_ fields: String...) -> Bool {
            let haystack = fields.joined(separator: " ").folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            return terms.allSatisfy(haystack.contains)
        }
        /// Prefix matches first, like Apple Music's ranking.
        func rank(_ name: String) -> Int {
            let folded = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            return folded.hasPrefix(terms[0]) ? 0 : 1
        }

        // A merged profile's own name finds its main artist.
        let aliases = Dictionary(grouping: ArtistMerges.all, by: \.value).mapValues { $0.map(\.key) }
        artists = index.artists.filter { artist in
            matches(artist.name) || (aliases[artist.name] ?? []).contains { matches($0) }
        }
        .sorted { rank($0.name) < rank($1.name) }
        albums = index.albums.filter { !$0.isSingle && matches($0.title, $0.artist) }.sorted { rank($0.title) < rank($1.title) }
        self.songs = songs
            .filter { matches($0.title, $0.artist, $0.album) }
            .sorted {
                let lhs = rank($0.title), rhs = rank($1.title)
                return lhs != rhs ? lhs < rhs : $0.title.libraryCompare($1.title) == .orderedAscending
            }
        self.playlists = playlists.filter { matches($0.name) }

        // A few letters match every song's lyrics somewhere.
        guard terms.joined().count >= 3 else { return }
        let found = Set(self.songs.map(\.id))
        lyricMatches = songs.compactMap { song in
            guard !found.contains(song.id), let quote = LyricsTextIndex.shared.quote(for: song, terms: terms) else { return nil }
            return (song, quote)
        }
    }
}

/// The library's lyrics as plain lines, read once per file, for searching
/// songs by their words.
final class LyricsTextIndex: @unchecked Sendable {
    static let shared = LyricsTextIndex()

    private struct Entry {
        var path: String
        var lines: [String]
        var folded: [String]
    }

    private let lock = NSLock()
    private var entries: [UUID: Entry] = [:]

    func needsLoading(_ song: Song) -> Bool {
        guard let path = song.lrcFilePath, !path.isEmpty else { return false }
        lock.lock()
        defer { lock.unlock() }
        return entries[song.id]?.path != path
    }

    func load(_ files: [(Song, URL)]) {
        for (song, url) in files {
            guard let path = song.lrcFilePath, let lyrics = LRCParser.parse(url: url) else { continue }
            var lines = lyrics.lines.map(\.text)
            if lines.isEmpty { lines = lyrics.plainText.components(separatedBy: .newlines) }
            lines = lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            // The same chorus over and over: one copy is enough to search.
            var seen = Set<String>()
            lines = lines.filter { seen.insert($0).inserted }
            let folded = lines.map { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
            lock.lock()
            entries[song.id] = Entry(path: path, lines: lines, folded: folded)
            lock.unlock()
        }
    }

    /// The line holding every term, or two lines in a row that do together.
    func quote(for song: Song, terms: [String]) -> String? {
        lock.lock()
        let entry = song.lrcFilePath == nil ? nil : entries[song.id]
        lock.unlock()
        guard let entry, entry.path == song.lrcFilePath else { return nil }
        for index in entry.folded.indices where terms.allSatisfy(entry.folded[index].contains) {
            return entry.lines[index]
        }
        for index in entry.folded.indices.dropLast() {
            let pair = entry.folded[index] + " " + entry.folded[index + 1]
            if terms.allSatisfy(pair.contains) {
                return entry.lines[index] + " / " + entry.lines[index + 1]
            }
        }
        return nil
    }
}

/// Apple Music-style browse card: artwork-tinted tile with the genre name.
/// Search's browse card, Apple Music style: a vivid gradient from the
/// artwork's color, the name, and up to three covers fanned in the corner.
struct BrowseCard: View {
    let title: String
    let covers: [ArtworkSource?]
    var placeholderSymbol = "music.note"

    var body: some View {
        let base = Self.vivid(Song.albumBackgroundUIColor(for: covers.first ?? nil))
        ZStack(alignment: .topLeading) {
            LinearGradient(
                colors: [Color(uiColor: base.lighter), Color(uiColor: base)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            coverStack
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            // Top-left, like Music's browse cards: the covers keep the
            // bottom-right corner, so a long name never runs over them.
            Text(title)
                .font(.headline)
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
                .lineLimit(2)
                .padding(12)
        }
        .frame(height: 108)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay { GlassRim(cornerRadius: 12) }
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// Back to front: each cover behind sits a little higher, further left
    /// and less tilted, like a fanned stack.
    private var coverStack: some View {
        let shown = Array(covers.prefix(3))
        let side: CGFloat = 60
        return ZStack(alignment: .bottomTrailing) {
            ForEach(Array(shown.enumerated().reversed()), id: \.offset) { index, cover in
                ArtworkImage(source: cover, cornerRadius: 6, points: side, placeholderSymbol: placeholderSymbol)
                    .frame(width: side, height: side)
                    .shadow(color: .black.opacity(0.32), radius: 6, y: 3)
                    .rotationEffect(.degrees(16 - Double(index) * 8))
                    .offset(x: 12 - CGFloat(index) * 22, y: 4 - CGFloat(index) * 3)
            }
        }
    }

    /// Pushes the artwork color's saturation and brightness up: Music's browse
    /// cards are bright, not the dim tints used behind album pages.
    static func vivid(_ color: UIColor) -> UIColor {
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        // Greys stay grey (an "Unknown" card shouldn't turn red).
        guard saturation > 0.08 else { return UIColor(white: 0.32, alpha: 1) }
        return UIColor(hue: hue, saturation: min(1, max(0.62, saturation * 1.35)), brightness: min(0.9, max(0.62, brightness * 1.6)), alpha: 1)
    }
}

/// The specular edge of Liquid Glass: light catching the top-left and
/// bottom-right corners, almost nothing along the sides.
struct GlassRim: View {
    let cornerRadius: CGFloat
    /// Stronger on the bands that stand out (the programs, the Wrapped):
    /// a brighter edge, and a soft glow where the light catches it.
    var intensity: CGFloat = 1

    private var gradient: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: .white.opacity(min(1, 0.28 * intensity)), location: 0),
                .init(color: .white.opacity(min(1, 0.06 * intensity)), location: 0.3),
                .init(color: .white.opacity(min(1, 0.02 * intensity)), location: 0.6),
                .init(color: .white.opacity(min(1, 0.14 * intensity)), location: 1)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            if intensity > 1 {
                shape
                    .strokeBorder(gradient, lineWidth: 2)
                    .blur(radius: 1.5)
                    .opacity(0.35)
                    .clipShape(shape)
            }
            shape.strokeBorder(gradient, lineWidth: intensity > 1 ? 0.9 : 0.75)
        }
        .blendMode(.plusLighter)
        .allowsHitTesting(false)
    }
}

private extension UIColor {
    var lighter: UIColor {
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return UIColor(hue: fmod(hue + 0.03, 1), saturation: saturation * 0.85, brightness: min(1, brightness * 1.18), alpha: alpha)
    }
}

/// The artist's photo on a wide card: blown up and blurred to fill the
/// width, with the photo itself, at the card's height, on the right edge
/// melting into it. The name sits on the left, over the blur.
struct ArtistPhotoCard: View {
    let title: String
    let photo: ArtworkSource

    var body: some View {
        PhotoCard(title: title, source: .artwork(photo))
    }
}

/// What a photo card shows: an artwork, or a bundled picture.
enum PhotoCardSource: Hashable {
    case artwork(ArtworkSource)
    case bundled(String)

    var key: String {
        switch self {
        case let .artwork(source): "a-\(source.cacheKey)"
        case let .bundled(name): "b-\(name)"
        }
    }
}

/// A photo card's two pictures, made once off the main thread: the photo at
/// the size it's drawn, and its blurred backdrop as a tiny bitmap. (A live
/// blur on every card was redrawn each frame and made the shelves stutter.)
final class PhotoCardImages: @unchecked Sendable {
    static let shared = PhotoCardImages()

    struct Pair {
        let photo: UIImage
        let backdrop: UIImage
    }

    private final class Box {
        let pair: Pair
        init(_ pair: Pair) { self.pair = pair }
    }

    private let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 160
        return cache
    }()
    private let queue = DispatchQueue(label: "com.fares.lrc.player.photocards", qos: .userInitiated, attributes: .concurrent)
    private static let context = CIContext(options: [.cacheIntermediates: false])

    func cached(_ source: PhotoCardSource) -> Pair? {
        cache.object(forKey: source.key as NSString)?.pair
    }

    func load(_ source: PhotoCardSource) async -> Pair? {
        if let pair = cached(source) { return pair }
        let photo: UIImage?
        switch source {
        case let .artwork(artwork):
            photo = await ArtworkImageCache.shared.image(for: artwork, points: 130)
        case let .bundled(name):
            photo = UIImage(named: name)
        }
        guard let photo else { return nil }
        return await withCheckedContinuation { continuation in
            queue.async { [self] in
                let pair = Self.make(from: photo)
                if let pair { cache.setObject(Box(pair), forKey: source.key as NSString) }
                continuation.resume(returning: pair)
            }
        }
    }

    private static func make(from image: UIImage) -> Pair? {
        // The sharp photo, about the card's height on a 3x screen.
        let photo = scaled(image, maxPixels: 400) ?? image
        guard let small = scaled(image, maxPixels: 48), let cgSmall = small.cgImage else { return nil }
        let input = CIImage(cgImage: cgSmall)
        let blurred = input.clampedToExtent()
            .applyingGaussianBlur(sigma: 3.5)
            .cropped(to: input.extent)
        guard let output = context.createCGImage(blurred, from: input.extent) else { return nil }
        return Pair(photo: photo, backdrop: UIImage(cgImage: output))
    }

    private static func scaled(_ image: UIImage, maxPixels: CGFloat) -> UIImage? {
        let pixelSize = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let longest = max(pixelSize.width, pixelSize.height)
        guard longest > 0 else { return nil }
        let factor = min(1, maxPixels / longest)
        let size = CGSize(width: max(1, (pixelSize.width * factor).rounded()), height: max(1, (pixelSize.height * factor).rounded()))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

/// A photo on a wide card: blown up and blurred to fill the width, with the
/// photo itself, at the card's height, on the right edge melting into it.
/// The name sits on the left, over the blur.
struct PhotoCard: View {
    let title: String
    let source: PhotoCardSource

    @State private var pair: PhotoCardImages.Pair?

    init(title: String, source: PhotoCardSource) {
        self.title = title
        self.source = source
        // Already made: drawn on the first frame, no fade while scrolling back.
        _pair = State(initialValue: PhotoCardImages.shared.cached(source))
    }

    var body: some View {
        let height: CGFloat = 108
        ZStack(alignment: .topLeading) {
            Color(white: 0.16)
            if let pair {
                // In an overlay, so a fill-scaled photo can't widen the card
                // and push the name out of it.
                Color.clear.overlay {
                    Image(uiImage: pair.backdrop)
                        .resizable()
                        .interpolation(.medium)
                        .scaledToFill()
                }
                .scaleEffect(1.4)
                .overlay(Color.black.opacity(0.18))
                .transition(.opacity)
                Image(uiImage: pair.photo)
                    .resizable()
                    .scaledToFill()
                    .frame(width: height * 1.2, height: height * 1.2)
                    .offset(y: height * 0.1)
                    .frame(width: height * 1.2, height: height)
                    .clipped()
                    .mask {
                        LinearGradient(
                            stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.5)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    .transition(.opacity)
            }
            LinearGradient(colors: [.black.opacity(0.35), .clear], startPoint: .leading, endPoint: .center)
            Text(title)
                .font(.headline)
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
                .lineLimit(2)
                .padding(12)
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay { GlassRim(cornerRadius: 12) }
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .task(id: source) {
            guard pair == nil || PhotoCardImages.shared.cached(source) == nil else { return }
            let loaded = await PhotoCardImages.shared.load(source)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { pair = loaded }
        }
    }
}

/// The shelves' default orders, sorted again only when the library's
/// genres or artists change, not on every pass of the page.
@MainActor private final class BrowseOrderCache {
    private var genreSource: [Genre]?
    private var genreOrder: [Int] = []
    private var artistSource: [Artist]?
    private var artistOrder: [Int] = []

    // The order is kept as positions in the source: an edited song (same
    // genre, same count) still shows through the current items.
    func genres(_ source: [Genre], sort: ([Genre]) -> [Genre]) -> [Genre] {
        if genreSource != source { genreOrder = Self.positions(of: sort(source), in: source); genreSource = source }
        return genreOrder.map { source[$0] }
    }

    func artists(_ source: [Artist], sort: ([Artist]) -> [Artist]) -> [Artist] {
        if artistSource != source { artistOrder = Self.positions(of: sort(source), in: source); artistSource = source }
        return artistOrder.map { source[$0] }
    }

    private static func positions<Item: Identifiable>(of sorted: [Item], in source: [Item]) -> [Int] {
        let index = Dictionary(source.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        return sorted.compactMap { index[$0.id] }
    }
}

private struct GenreCard: View {
    let genre: Genre

    var body: some View {
        let style = GenreStyle(genre.name)
        if let image = style.imageName {
            // Public-domain (CC0) photos of instruments and gear, from
            // Wikimedia Commons, bundled: no people.
            PhotoCard(title: genre.name, source: .bundled(image))
        } else {
            GenreIllustrationCard(title: genre.name, style: style)
        }
    }
}

/// A genre's own color and emblem, guessed from its name.
struct GenreStyle {
    let symbol: String
    let hue: Double
    /// The bundled photo's asset name, for the genres that have one.
    let imageName: String?

    init(_ name: String) {
        let name = name.lowercased()
        let table: [([String], String, Double, String?)] = [
            (["unknown"], "questionmark", -1, "unknown"),
            (["folk", "americana", "acoustic"], "guitars.fill", 0.09, "folk"),
            (["metal"], "flame.fill", 0.0, "metal"),
            (["punk", "rock"], "bolt.fill", 0.98, "rock"),
            (["electro", "techno", "house", "ambient", "edm", "trance"], "waveform", 0.72, "electronic"),
            (["dance", "disco"], "figure.dance", 0.85, "dance"),
            (["hip-hop", "hip hop", "rap", "trap"], "music.mic", 0.04, "hiphop"),
            (["r&b", "soul", "funk"], "heart.fill", 0.93, "rnb"),
            (["jazz", "blues"], "music.quarternote.3", 0.6, "jazz"),
            (["classical", "orchestral", "opera"], "music.note.house.fill", 0.12, "classical"),
            (["soundtrack", "score", "film"], "film.fill", 0.55, "soundtrack"),
            (["comedy", "humour", "humor"], "theatermasks.fill", 0.14, "comedy"),
            (["country"], "sun.horizon.fill", 0.07, "country"),
            (["singer", "songwriter", "chanson"], "pencil.and.scribble", 0.5, "songwriter"),
            (["french", "variété"], "music.note", 0.62, "frenchpop"),
            (["rai", "raï", "arab", "maghreb", "world", "latin", "reggae", "afro"], "globe.europe.africa.fill", 0.42, "world"),
            (["alternative", "indie"], "headphones", 0.33, "alternative"),
            (["pop"], "sparkles", 0.9, "pop"),
            (["kids", "children", "enfants"], "balloon.2.fill", 0.17, "kids"),
            (["podcast", "spoken", "audiobook"], "waveform.and.mic", 0.66, nil),
        ]
        let match = table.first { $0.0.contains(where: name.contains) }
        symbol = match?.1 ?? "music.note.list"
        imageName = match?.3.map { "Genre-\($0)" }
        // Unmatched genres still get a steady color of their own.
        hue = match?.2 ?? Double(abs(name.unicodeScalars.reduce(0) { ($0 &* 31) &+ Int($1.value) }) % 360) / 360
    }

    var color: UIColor {
        hue < 0 ? UIColor(white: 0.32, alpha: 1) : UIColor(hue: hue, saturation: 0.72, brightness: 0.78, alpha: 1)
    }
}

/// Music-style genre tile: a vivid gradient with the genre's emblem large
/// and tilted in the corner.
struct GenreIllustrationCard: View {
    let title: String
    let style: GenreStyle

    var body: some View {
        let base = style.color
        ZStack(alignment: .topLeading) {
            LinearGradient(
                colors: [Color(uiColor: base.lighter), Color(uiColor: base)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: style.symbol)
                .font(.system(size: 64, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
                .rotationEffect(.degrees(14))
                .offset(x: 10, y: 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(.trailing, 6)
            Text(title)
                .font(.headline)
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
                .lineLimit(2)
                .padding(12)
        }
        .frame(height: 108)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay { GlassRim(cornerRadius: 12) }
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct ArtistCard: View {
    let artist: Artist
    @ObservedObject private var photos = ArtistImageService.shared

    var body: some View {
        if let photo = photos.photo(for: artist.name, albums: artist.songs.map(\.album))
            ?? ArtistAvatar.coverSong(in: artist.songs, artist: artist.name)?.artworkSource {
            ArtistPhotoCard(title: artist.name, photo: photo)
        } else {
            BrowseCard(title: artist.name, covers: Self.covers(of: artist), placeholderSymbol: "music.microphone")
        }
    }

    /// One cover per album, the albums with the most songs first.
    static func covers(of artist: Artist) -> [ArtworkSource?] {
        let byAlbum = Dictionary(grouping: artist.songs, by: \.album)
        let albums = byAlbum.sorted {
            $0.value.count != $1.value.count ? $0.value.count > $1.value.count : $0.key < $1.key
        }
        let covers = albums.prefix(3).map { $0.value.first?.artworkSource }
        return covers.isEmpty ? [nil] : covers
    }
}

private extension View {
    /// Like Apple Music: a drag hides the keyboard and keeps the search. The
    /// search field lives in the UIKit navigation bar, out of reach of
    /// SwiftUI's focus, so the first responder is resigned directly.
    /// Not with a real keyboard (the Mac, an iPad's): there's no keyboard
    /// to hide, and scrolling the results shouldn't take the field's focus.
    func dismissesKeyboardOnScroll() -> some View {
        scrollDismissesKeyboard(MacApp.isActive ? .never : .immediately)
            .onScrollPhaseChange { _, phase in
                guard phase == .interacting, !MacApp.isActive, GCKeyboard.coalesced == nil else { return }
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            }
    }
}

// MARK: - Rearranging

/// What auto-scrolling needs to know about a scroll view, along one axis.
@MainActor final class ScrollMetricsBox {
    var value = ScrollMetrics()
}

struct ScrollMetrics: Equatable {
    var offset: CGFloat = 0
    var maxOffset: CGFloat = 0
    var viewport: CGFloat = 0

    init() {}

    init(_ geometry: ScrollGeometry, axis: Axis) {
        if axis == .horizontal {
            offset = geometry.contentOffset.x + geometry.contentInsets.leading
            maxOffset = max(geometry.contentSize.width - geometry.containerSize.width + geometry.contentInsets.leading + geometry.contentInsets.trailing, 0)
            viewport = geometry.containerSize.width
        } else {
            offset = geometry.contentOffset.y + geometry.contentInsets.top
            maxOffset = max(geometry.contentSize.height - geometry.containerSize.height + geometry.contentInsets.top + geometry.contentInsets.bottom, 0)
            viewport = geometry.containerSize.height
        }
    }
}

/// The Pinned shelf's jiggle mode for any cards: hold one to pick it up and
/// drag it; its slot stays empty while it floats, and the scroll view runs on
/// its own near the edges.
private struct RearrangeableCards<Item: Identifiable, Card: View, L: Layout>: View where Item.ID: Hashable {
    @Binding var items: [Item]
    let layout: L
    let axis: Axis
    @Binding var scroll: ScrollPosition
    let metrics: ScrollMetrics
    @Binding var isDragging: Bool
    @ViewBuilder let card: (Item) -> Card

    @State private var dragged: Item?
    @State private var frames: [Item.ID: CGRect] = [:]
    @State private var floatOrigin: CGPoint = .zero
    @State private var floatSize: CGSize = .zero
    @State private var grabOffset: CGSize = .zero
    @State private var isLifted = false
    /// The finger in the scroll view's visible frame: it stays put while the
    /// content scrolls under it.
    @State private var fingerInViewport: CGPoint = .zero
    /// Where this layout's origin sits in the scroll view's visible frame.
    @State private var origin: CGPoint = .zero
    @State private var autoScroll: Task<Void, Never>?
    @State private var swapCount = 0

    private static var space: String { "rearrangeableCards" }

    var body: some View {
        layout {
            ForEach(items) { item in
                card(item)
                    .allowsHitTesting(false)
                    .modifier(Jiggle(isOn: true, seed: item.id.hashValue))
                    .contentShape(Rectangle())
                    .opacity(dragged?.id == item.id ? 0 : 1)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { frames[item.id] = $0 }
                    .gesture(PickUpGesture(space: Self.space) { finger in
                        pickUp(item, at: finger)
                    } onMove: { finger in
                        move(to: finger)
                    } onEnd: {
                        drop()
                    })
            }
        }
        .overlay(alignment: .topLeading) {
            if let dragged {
                card(dragged)
                    .frame(width: floatSize.width, height: floatSize.height)
                    .scaleEffect(isLifted ? 1.06 : 1)
                    .shadow(color: .black.opacity(isLifted ? 0.35 : 0), radius: 18, y: 10)
                    .offset(x: floatOrigin.x, y: floatOrigin.y)
                    .allowsHitTesting(false)
            }
        }
        .coordinateSpace(name: Self.space)
        .onGeometryChange(for: CGPoint.self) { $0.frame(in: .scrollView).origin } action: { new in
            origin = new
            if dragged != nil { followFinger() }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: isLifted) { _, new in new }
        .sensoryFeedback(.selection, trigger: swapCount)
        .onDisappear { stopAutoScroll() }
    }

    /// The finger in this layout's coordinates.
    private var finger: CGPoint {
        CGPoint(x: fingerInViewport.x - origin.x, y: fingerInViewport.y - origin.y)
    }

    private func pickUp(_ item: Item, at finger: CGPoint) {
        guard dragged == nil, let slot = frames[item.id] else { return }
        fingerInViewport = CGPoint(x: finger.x + origin.x, y: finger.y + origin.y)
        grabOffset = CGSize(width: finger.x - slot.minX, height: finger.y - slot.minY)
        floatSize = slot.size
        floatOrigin = slot.origin
        dragged = item
        isDragging = true
        withAnimation(.spring(duration: 0.25, bounce: 0.3)) { isLifted = true }
    }

    private func move(to finger: CGPoint) {
        guard dragged != nil else { return }
        fingerInViewport = CGPoint(x: finger.x + origin.x, y: finger.y + origin.y)
        followFinger()
        updateAutoScroll()
    }

    private func followFinger() {
        let finger = finger
        floatOrigin = CGPoint(x: finger.x - grabOffset.width, y: finger.y - grabOffset.height)
        reorder(at: finger)
    }

    private func drop() {
        stopAutoScroll()
        isDragging = false
        guard let item = dragged else { return }
        withAnimation(.spring(duration: 0.35, bounce: 0.2)) {
            if let slot = frames[item.id] { floatOrigin = slot.origin }
            isLifted = false
        } completion: {
            if dragged?.id == item.id { dragged = nil }
        }
    }

    private func reorder(at finger: CGPoint) {
        guard let id = dragged?.id,
              let target = items.first(where: { $0.id != id && (frames[$0.id]?.contains(finger) ?? false) }),
              let from = items.firstIndex(where: { $0.id == id }),
              let to = items.firstIndex(where: { $0.id == target.id }) else { return }
        withAnimation(.spring(duration: 0.35, bounce: 0.15)) {
            items.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        }
        swapCount += 1
    }

    private func updateAutoScroll() {
        let position = axis == .horizontal ? fingerInViewport.x : fingerInViewport.y
        let edge: CGFloat = axis == .horizontal ? 50 : 90
        let direction: CGFloat = position < edge ? -1 : position > metrics.viewport - edge ? 1 : 0
        guard direction != 0 else {
            stopAutoScroll()
            return
        }
        guard autoScroll == nil else { return }
        autoScroll = Task { @MainActor in
            var offset = metrics.offset
            while !Task.isCancelled, dragged != nil {
                let next = min(max(offset + direction * 6, 0), metrics.maxOffset)
                guard next != offset else { break }
                if axis == .horizontal { scroll.scrollTo(x: next) } else { scroll.scrollTo(y: next) }
                offset = next
                try? await Task.sleep(for: .milliseconds(16))
            }
            autoScroll = nil
        }
    }

    private func stopAutoScroll() {
        autoScroll?.cancel()
        autoScroll = nil
    }
}

/// Rows of equal columns, as many as fit at `minimum` wide, like an adaptive
/// grid, but not lazy, so every card has a frame while rearranging.
private struct FlowGridLayout: Layout {
    let minimum: CGFloat
    let spacing: CGFloat

    private func columns(for width: CGFloat) -> (count: Int, width: CGFloat) {
        let count = max(1, Int((width + spacing) / (minimum + spacing)))
        return (count, (width - spacing * CGFloat(count - 1)) / CGFloat(count))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 390
        let (count, column) = columns(for: width)
        var height: CGFloat = 0
        for start in stride(from: 0, to: subviews.count, by: count) {
            let row = subviews[start..<min(start + count, subviews.count)]
            height += row.map { $0.sizeThatFits(ProposedViewSize(width: column, height: nil)).height }.max() ?? 0
        }
        let rows = (subviews.count + count - 1) / count
        return CGSize(width: width, height: height + spacing * CGFloat(max(rows - 1, 0)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (count, column) = columns(for: bounds.width)
        var y = bounds.minY
        for start in stride(from: 0, to: subviews.count, by: count) {
            let row = Array(subviews[start..<min(start + count, subviews.count)])
            let height = row.map { $0.sizeThatFits(ProposedViewSize(width: column, height: nil)).height }.max() ?? 0
            for (index, subview) in row.enumerated() {
                subview.place(at: CGPoint(x: bounds.minX + CGFloat(index) * (column + spacing), y: y), proposal: ProposedViewSize(width: column, height: height))
            }
            y += height + spacing
        }
    }
}

/// Picks the artist a side profile counts as.
struct MergeArtistSheet: View {
    let name: String
    @EnvironmentObject private var libraryVM: LibraryViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var candidates: [Artist] {
        libraryVM.artists.filter { $0.name != name && (query.isEmpty || $0.name.localizedStandardContains(query)) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(candidates) { artist in
                        Button {
                            ArtistMerges.merge(name, into: artist.name)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                ArtistAvatarView(artistName: artist.name, songs: artist.songs, size: 40)
                                Text(artist.name)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                            }
                        }
                    }
                } footer: {
                    Text("\(name)'s songs join the artist you pick: on its page, in Stats and for the assistant, they count as one artist. Songs still show the name their files carry.")
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always))
            .navigationTitle("Merge Into…")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
            }
        }
    }
}

/// The profiles merged into an artist, each one can be split off again.
struct MergedArtistsSheet: View {
    let main: String
    @Environment(\.dismiss) private var dismiss
    @State private var names: [String] = []

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(names, id: \.self) { name in
                        HStack {
                            Text(name).lineLimit(1)
                            Spacer()
                            Button("Unmerge") { unmerge(name) }
                                .buttonStyle(.bordered)
                        }
                    }
                } footer: {
                    Text("Counted as \(main) on its page, in Stats and for the assistant. Unmerged, an artist gets its own page again.")
                }
            }
            .navigationTitle("Merged Artists")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
            }
        }
        .onAppear { names = ArtistMerges.merged(into: main) }
    }

    private func unmerge(_ name: String) {
        withAnimation(.smooth) {
            ArtistMerges.unmerge(name)
            names.removeAll { $0 == name }
        }
        if names.isEmpty { dismiss() }
    }
}
