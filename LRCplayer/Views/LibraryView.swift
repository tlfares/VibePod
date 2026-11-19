import SwiftUI

/// An album or playlist shown on the Library home shelves and grid.
enum HomeItem: Identifiable {
    case album(Album)
    case playlist(Playlist)

    var id: String {
        switch self {
        case let .album(album): "album-\(album.id.pinKey)-\(album.id.singleSongID?.uuidString ?? "")"
        case let .playlist(playlist): "playlist-\(playlist.id.uuidString)"
        }
    }

    var title: String {
        switch self {
        case let .album(album): album.title
        case let .playlist(playlist): playlist.name
        }
    }

    var subtitle: String {
        switch self {
        case let .album(album): album.artist
        case let .playlist(playlist): playlist.isAutolist ? String(localized: "Autolist") : String(localized: "Playlist")
        }
    }

    var dateAdded: Date {
        switch self {
        case let .album(album): album.dateAdded
        case let .playlist(playlist): playlist.createdAt
        }
    }

    var year: Int? {
        guard case let .album(album) = self, album.year > 0 else { return nil }
        return album.year
    }

    func route(zoomSource: String?) -> LibraryRoute {
        switch self {
        case let .album(album): .album(album.id, zoomSource: zoomSource)
        case let .playlist(playlist): .playlist(playlist.id, zoomSource: zoomSource)
        }
    }
}

struct LibraryView: View {
    @EnvironmentObject private var libraryVM: LibraryViewModel
    @EnvironmentObject private var router: AppRouter
    @ObservedObject private var recentPlayedStore = RecentPlayedStore.shared
    @AppStorage(HomeShortcut.leadingKey) private var leadingShortcut = HomeShortcut.leadingDefault
    @AppStorage(HomeShortcut.trailingKey) private var trailingShortcut = HomeShortcut.trailingDefault
    @AppStorage(HomeShortcut.leading2Key) private var leadingShortcut2 = HomeShortcut.none
    @AppStorage(HomeShortcut.leading3Key) private var leadingShortcut3 = HomeShortcut.none
    @AppStorage("homeLibrarySortMode") private var homeSortModeRawValue = HomeLibrarySortMode.recentlyAdded.rawValue
    @AppStorage("playlistsAlwaysOnTop") private var playlistsAlwaysOnTop = false
    @AppStorage("showRecentlyPlayedSection") private var showRecentlyPlayedSection = true
    @AppStorage(HomeSuggestions.hiddenKey) private var hiddenSuggestions = ""
    @AppStorage(HomeSuggestions.rowsKey) private var suggestionRows = HomeSuggestions.defaultRows
    @AppStorage(HomeSuggestions.playlistsKey) private var suggestsPlaylists = true
    @AppStorage(HomeSuggestions.albumsKey) private var suggestsAlbums = true
    @AppStorage(HomeSuggestions.artistsKey) private var suggestsArtists = true
    @State private var pageWidth: CGFloat = 390
    @State private var isRearrangingPinned = false
    @AppStorage("hasSeenFirstImportPrompt") private var hasSeenFirstImportPrompt = false
    @State private var showFirstImportPrompt = false

    private var sortMode: HomeLibrarySortMode {
        HomeLibrarySortMode(rawValue: homeSortModeRawValue) ?? .recentlyAdded
    }

    var body: some View {
        Group {
            if libraryVM.hasSongs || !libraryVM.playlists.isEmpty {
                libraryHome
            } else {
                emptyState
            }
        }
        .pageTitle("Library")
        .pageLeadingItem { leadingItems }
        .pageTrailingItem {
            // The chosen shortcut, then Add, sharing one Liquid Glass capsule:
            // shortcuts sit on the inner side of both ends.
            HStack(spacing: 0) {
                HomeShortcutButton(shortcut: trailingShortcut)
                Menu {
                    ImportMenuItems()
                } label: {
                    BarIcon("Add", systemImage: "plus")
                }
            }
        }
        .onChange(of: libraryVM.songs.isEmpty) { wasEmpty, isEmpty in
            if wasEmpty, !isEmpty, !hasSeenFirstImportPrompt {
                hasSeenFirstImportPrompt = true
                showFirstImportPrompt = true
            }
        }
        .sheet(isPresented: $showFirstImportPrompt) {
            FirstImportPromptSheet {
                showFirstImportPrompt = false
                router.importer = .lyricsFolder
            }
        }
    }

    // MARK: Toolbar

    /// Settings, and the chosen shortcut, sharing one Liquid Glass capsule.
    private var leadingItems: some View {
        HStack(spacing: 0) {
            Button {
                router.showSettings = true
            } label: {
                BarIcon("Settings", systemImage: "gearshape")
            }
            HomeShortcutButton(shortcut: leadingShortcut)
            HomeShortcutButton(shortcut: leadingShortcut2)
            HomeShortcutButton(shortcut: leadingShortcut3)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
    }

    // MARK: Home

    private var libraryHome: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                let suggestions = HomeSuggestions.pick(
                    libraryVM: libraryVM,
                    recent: recentlyPlayedItems.map(\.item),
                    options: .init(rows: suggestionRows, playlists: suggestsPlaylists, albums: suggestsAlbums, artists: suggestsArtists, hidden: HomeSuggestions.hiddenIDs(hiddenSuggestions))
                )
                if !suggestions.isEmpty {
                    SuggestionsGrid(suggestions: suggestions)
                        .padding(.horizontal, 16)
                }

                let pinned = pinnedItems
                if !pinned.isEmpty {
                    // Rearranged on the shelf, then back to the Cover Flow.
                    if !isRearrangingPinned {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Pinned")
                                .font(.title2.bold())
                                .frame(minHeight: 34)
                                .padding(.horizontal, 20)
                            PinnedCoverFlow(items: pinned, width: pageWidth) { isRearrangingPinned = true }
                        }
                    } else {
                        PinnedShelf(items: pinned, rows: 1, startsRearranging: true) { isRearrangingPinned = false }
                    }
                }

                if showRecentlyPlayedSection {
                    let recent = recentlyPlayedItems
                    if !recent.isEmpty {
                        HomeShelf(title: "Recently Played", items: recent.map(\.item), zoomPrefix: "recent") { item in
                            if let entry = recent.first(where: { $0.item.id == item.id })?.entry {
                                Button("Remove from Recently Played", destructiveImage: "minus.circle") {
                                    recentPlayedStore.remove(entry: entry)
                                }
                            }
                        }
                    }
                }

                recentlyAddedGrid
                    .padding(.horizontal, 20)
            }
            .padding(.top, 4)
            .padding(.bottom, 24)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { pageWidth = $0 }
        }
    }

    private var recentlyAddedGrid: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(sortMode == .recentlyAdded ? "Recently Added" : "All Albums & Playlists")
                    .font(.title2.bold())
                Spacer()
                Menu {
                    Picker("Sort By", selection: $homeSortModeRawValue) {
                        ForEach(HomeLibrarySortMode.allCases, id: \.rawValue) { mode in
                            Label(mode.title, systemImage: mode.icon).tag(mode.rawValue)
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel("Sort")
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 16)], spacing: 22) {
                ForEach(gridItems) { item in
                    let zoomID = "grid-\(item.id)"
                    RouteLink(item.route(zoomSource: zoomID)) {
                        HomeItemTile(item: item, zoomID: zoomID)
                    }
                    .buttonStyle(.plain)
                    .contextMenu { HomeItemMenu(item: item) }
                }
            }
        }
    }

    // MARK: Data

    private var pinnedItems: [HomeItem] {
        var dated: [(Date, HomeItem)] = []
        for (key, date) in libraryVM.pinnedAlbums {
            if let album = libraryVM.album(forPinKey: key) {
                dated.append((date, .album(album)))
            }
        }
        for (idString, date) in libraryVM.pinnedPlaylists {
            if let id = UUID(uuidString: idString), let playlist = libraryVM.playlist(withID: id) {
                dated.append((date, .playlist(playlist)))
            }
        }
        return dated.sorted { $0.0 < $1.0 }.map(\.1)
    }

    private var recentlyPlayedItems: [(entry: RecentlyPlayedEntry, item: HomeItem)] {
        var seen = Set<String>()
        return recentPlayedStore.entries.compactMap { entry -> (RecentlyPlayedEntry, HomeItem)? in
            let item: HomeItem?
            switch entry.kind {
            case .album:
                item = libraryVM.album(forPinKey: entry.id).map(HomeItem.album)
            case .playlist:
                item = UUID(uuidString: entry.id).flatMap(libraryVM.playlist(withID:)).map(HomeItem.playlist)
            }
            guard let item, seen.insert(item.id).inserted else { return nil }
            return (entry, item)
        }
    }

    private var gridItems: [HomeItem] {
        let albums = libraryVM.albums.map(HomeItem.album)
        let playlists = libraryVM.playlists.map(HomeItem.playlist)

        func byDate(_ items: [HomeItem]) -> [HomeItem] {
            items.sorted { $0.dateAdded > $1.dateAdded }
        }
        func byTitle(_ items: [HomeItem]) -> [HomeItem] {
            items.sorted { $0.title.libraryCompare($1.title) == .orderedAscending }
        }
        func byYear(_ items: [HomeItem], ascending: Bool) -> [HomeItem] {
            items.sorted { lhs, rhs in
                switch (lhs.year, rhs.year) {
                case let (l?, r?) where l != r: return ascending ? l < r : l > r
                case (nil, .some): return false
                case (.some, nil): return true
                default: return lhs.title.libraryCompare(rhs.title) == .orderedAscending
                }
            }
        }

        switch sortMode {
        case .recentlyAdded:
            return playlistsAlwaysOnTop ? byDate(playlists) + byDate(albums) : byDate(albums + playlists)
        case .oldestToNewest:
            return byTitle(playlists) + byYear(albums, ascending: true)
        case .newestToOldest:
            return byTitle(playlists) + byYear(albums, ascending: false)
        case .title:
            return playlistsAlwaysOnTop ? byTitle(playlists) + byTitle(albums) : byTitle(albums + playlists)
        case .artist:
            let sortedAlbums = albums.sorted {
                let order = $0.subtitle.libraryCompare($1.subtitle)
                return order == .orderedSame ? $0.title.libraryCompare($1.title) == .orderedAscending : order == .orderedAscending
            }
            return byTitle(playlists) + sortedAlbums
        }
    }

    // MARK: Empty state

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Your Library Is Empty", systemImage: "music.note.house")
        } description: {
            Text("Import songs from Files or from the music synced to this iPhone. LRC files with the same name are used for synced lyrics.")
        } actions: {
            Button {
                router.importer = .audio
            } label: {
                Label("Import Files", systemImage: "folder.badge.plus")
                    .frame(maxWidth: 260)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)

            Button {
                libraryVM.importPhoneMusicLibrary()
            } label: {
                Label("Import iPhone Library", systemImage: "iphone")
                    .frame(maxWidth: 260)
            }
            .buttonStyle(.glass)
            .controlSize(.large)
        }
    }
}

/// Items of the Library "+" menu (also used by the empty state).
struct ImportMenuItems: View {
    @EnvironmentObject private var libraryVM: LibraryViewModel
    @EnvironmentObject private var router: AppRouter

    var body: some View {
        Button("New Playlist…", systemImage: "music.note.list") {
            libraryVM.requestNewPlaylist()
        }
        Button("New Autolist…", systemImage: "wand.and.stars") {
            libraryVM.requestNewAutolist()
        }
        Section {
            Button("Import Files", systemImage: "folder.badge.plus") {
                router.importer = .audio
            }
            Button("Import iPhone Library", systemImage: "iphone") {
                libraryVM.importPhoneMusicLibrary()
            }
            Button("Import iPhone Playlists", systemImage: "music.note.list") {
                libraryVM.importPhoneMusicPlaylists()
            }
        }
        Section {
            Button("Choose LRC Folder…", systemImage: "text.badge.plus") {
                router.importer = .lyricsFolder
            }
        }
    }
}

// MARK: - Home components

/// Something the Home suggestions grid can open.
enum HomeSuggestion: Identifiable {
    case item(HomeItem)
    case artist(Artist)

    var id: String {
        switch self {
        case let .item(item): item.id
        case let .artist(artist): "artist-\(artist.name)"
        }
    }
}

/// A button the Library toolbar shows next to Settings or Add, picked in
/// Settings › Home.
enum HomeShortcut: String, CaseIterable, Identifiable {
    case none, assistant, games, stats, shuffleAll, autoMix, musicHaptics, animatedCovers, shuffleMode, privateListening

    static let leadingKey = "homeLeadingShortcut"
    static let trailingKey = "homeTrailingShortcut"
    /// Up to two more beside Settings, in the same capsule.
    static let leading2Key = "homeLeadingShortcut2"
    static let leading3Key = "homeLeadingShortcut3"

    /// What the old Games switch showed; else Music Haptics (off until
    /// tapped) on the left, the assistant on the right.
    static var leadingDefault: HomeShortcut {
        UserDefaults.standard.bool(forKey: "showHomeGamesButton") ? .games : .musicHaptics
    }
    static var trailingDefault: HomeShortcut {
        UserDefaults.standard.object(forKey: AssistantSettings.showButtonKey) as? Bool ?? true ? .assistant : .none
    }

    var id: Self { self }

    var title: String {
        switch self {
        case .none: String(localized: "None")
        case .assistant: String(localized: "Assistant")
        case .games: String(localized: "Games")
        case .stats: String(localized: "Stats")
        case .shuffleAll: String(localized: "Shuffle All")
        case .autoMix: String(localized: "AutoMix")
        case .musicHaptics: String(localized: "Music Haptics")
        case .animatedCovers: String(localized: "Animated Covers")
        case .shuffleMode: String(localized: "Shuffle")
        case .privateListening: String(localized: "Private Listening")
        }
    }

    var symbol: String? {
        switch self {
        case .none: nil
        case .assistant: "sparkles"
        case .games: "arcade.stick"
        case .stats: "chart.bar.xaxis"
        case .shuffleAll: "shuffle"
        case .autoMix: "circlebadge.2.fill"
        case .musicHaptics: "iphone.radiowaves.left.and.right"
        case .animatedCovers: "play.rectangle.on.rectangle"
        case .shuffleMode: "shuffle.circle"
        case .privateListening: "eye.slash"
        }
    }
}

/// One toolbar shortcut. AutoMix and Music Haptics switch on and off in
/// place, tinted while on; a long press opens their settings.
struct HomeShortcutButton: View {
    let shortcut: HomeShortcut
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var libraryVM: LibraryViewModel
    @EnvironmentObject private var playerVM: PlayerViewModel
    @AppStorage(MusicPlayerService.autoMixKey) private var autoMix = false
    @AppStorage(MusicHapticsService.storageKey) private var musicHaptics = false
    @AppStorage(MusicHapticsService.appleStorageKey) private var appleHaptics = false
    @AppStorage(MotionArtworkService.storageKey) private var animatedCovers = true
    @AppStorage(PrivateListening.key) private var privateListening = false
    @State private var toggles = 0

    var body: some View {
        switch shortcut {
        case .none:
            EmptyView()
        case .assistant:
            if libraryVM.hasSongs {
                AssistantBarButton()
            }
        case .games:
            button { router.openSettings(at: .games) }
                .disabled(!libraryVM.hasSongs)
        case .stats:
            button { router.openSettings(at: .stats) }
        case .shuffleAll:
            button { playerVM.play(libraryVM.songs, shuffled: true) }
                .disabled(!libraryVM.hasSongs)
        case .autoMix:
            button(isOn: autoMix) { autoMix.toggle() }
                .onLongPressGesture { router.openSettings(at: .exclusive) }
        case .animatedCovers:
            button(isOn: animatedCovers) { animatedCovers.toggle() }
                .onLongPressGesture { router.openSettings(at: .exclusive) }
        case .shuffleMode:
            button(isOn: playerVM.shuffleMode == .on) { playerVM.toggleShuffle() }
        case .privateListening:
            button(isOn: privateListening) { privateListening.toggle() }
        case .musicHaptics:
            if MusicHapticsService.isSupported {
                button(isOn: musicHaptics || appleHaptics) {
                    // Off whichever kind was on; on, VibePod's own.
                    let wasApple = appleHaptics
                    if musicHaptics || appleHaptics {
                        musicHaptics = false
                        appleHaptics = false
                    } else {
                        musicHaptics = true
                    }
                    if wasApple { MusicPlayerService.shared.refreshNowPlayingInfo() }
                }
                .onLongPressGesture { router.openSettings(at: .exclusive) }
            }
        }
    }

    private func button(isOn: Bool? = nil, action: @escaping () -> Void) -> some View {
        Button {
            action()
            if isOn != nil { toggles += 1 }
        } label: {
            BarIcon(shortcut.title, systemImage: shortcut == .privateListening && isOn == false ? "eye" : shortcut.symbol ?? "")
                .overlay {
                    // Struck through while off: the symbol has no slash variant.
                    if shortcut == .musicHaptics, isOn == false {
                        Capsule().frame(width: 2, height: 24).rotationEffect(.degrees(-45))
                    }
                }
        }
        .buttonStyle(.plain)
        .foregroundStyle(isOn == false ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
        .sensoryFeedback(.selection, trigger: toggles)
        .accessibilityValue(isOn.map { $0 ? String(localized: "On") : String(localized: "Off") } ?? "")
    }
}

/// The Spotify-style grid at the top of the home screen: what you play most
/// and last, picked again as you listen.
enum HomeSuggestions {
    static let hiddenKey = "homeSuggestionsHidden"
    static let rowsKey = "homeSuggestionRows"
    static let playlistsKey = "homeSuggestsPlaylists"
    static let albumsKey = "homeSuggestsAlbums"
    static let artistsKey = "homeSuggestsArtists"
    static let defaultRows = 4
    static let rowRange = 2...8

    struct Options {
        var rows = HomeSuggestions.defaultRows
        var playlists = true
        var albums = true
        var artists = true
        var hidden: Set<String> = []
    }

    /// The stored list: one suggestion ID per line.
    static func hiddenIDs(_ stored: String) -> Set<String> {
        Set(stored.split(separator: "\n").map(String.init))
    }

    static var hiddenCount: Int {
        hiddenIDs(UserDefaults.standard.string(forKey: hiddenKey) ?? "").count
    }

    /// Don't Recommend: never suggested again (until reset in Settings).
    static func hide(_ suggestion: HomeSuggestion) {
        var ids = hiddenIDs(UserDefaults.standard.string(forKey: hiddenKey) ?? "")
        ids.insert(suggestion.id)
        UserDefaults.standard.set(ids.sorted().joined(separator: "\n"), forKey: hiddenKey)
    }

    static func showHidden() {
        UserDefaults.standard.removeObject(forKey: hiddenKey)
    }

    @MainActor
    static func pick(libraryVM: LibraryViewModel, recent: [HomeItem], options: Options = Options()) -> [HomeSuggestion] {
        let count = min(max(options.rows, rowRange.lowerBound), rowRange.upperBound) * 2
        func allowed(_ suggestion: HomeSuggestion) -> Bool {
            guard !options.hidden.contains(suggestion.id) else { return false }
            switch suggestion {
            case .artist: return options.artists
            case .item(.album): return options.albums
            case .item(.playlist): return options.playlists
            }
        }
        // Plays per album and per artist, the most recent play breaking ties.
        func ranked<Key: Hashable>(_ groups: [(Key, [Song])]) -> [Key] {
            groups.compactMap { key, songs -> (Key, Int, Date)? in
                let plays = songs.reduce(0) { $0 + $1.playCount }
                guard plays > 0 else { return nil }
                return (key, plays, songs.compactMap(\.lastPlayedAt).max() ?? .distantPast)
            }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.2 > $1.2 }
            .map(\.0)
        }
        let albums = libraryVM.albums
        let topAlbums = ranked(albums.map { ($0.id, $0.songs) }).compactMap(libraryVM.album(withID:)).map { HomeSuggestion.item(.album($0)) }
        // A "top artist" needs more than one song, or it repeats its album.
        let topArtists = ranked(libraryVM.artists.filter { $0.songs.count > 1 }.map { ($0.name, $0.songs) })
            .compactMap(libraryVM.artist(named:)).map(HomeSuggestion.artist)
        let autolists = libraryVM.playlists
            .filter { $0.isAutolist && !$0.songs.isEmpty }
            .sorted { $0.modifiedAt > $1.modifiedAt }
            .map { HomeSuggestion.item(.playlist($0)) }
        let recentItems = recent.map(HomeSuggestion.item)
        let newest = albums.sorted { $0.dateAdded > $1.dateAdded }.map { HomeSuggestion.item(.album($0)) }

        // Mostly what you came back to, mixed with your favorites.
        var queues = [recentItems, topAlbums, topArtists, autolists, newest].map { $0.filter(allowed) }
        let pattern = [0, 0, 1, 2, 0, 3, 1, 2, 0, 1, 2, 3]
        var picked: [HomeSuggestion] = []
        var seen = Set<String>()
        func take(from queue: Int) -> Bool {
            while !queues[queue].isEmpty {
                let next = queues[queue].removeFirst()
                if seen.insert(next.id).inserted {
                    picked.append(next)
                    return true
                }
            }
            return false
        }
        for queue in pattern where picked.count < count {
            _ = take(from: queue)
        }
        // Short history: fill from whatever is left, newest additions last.
        for queue in queues.indices where picked.count < count {
            while picked.count < count, take(from: queue) {}
        }
        // Two columns: keep the grid even.
        if picked.count.isMultiple(of: 2) == false, picked.count > 1 { picked.removeLast() }
        return picked
    }
}

private struct SuggestionsGrid: View {
    let suggestions: [HomeSuggestion]

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
            ForEach(suggestions) { suggestion in
                SuggestionCard(suggestion: suggestion)
            }
        }
    }
}

private struct SuggestionCard: View {
    let suggestion: HomeSuggestion
    @EnvironmentObject private var libraryVM: LibraryViewModel
    @Environment(\.colorScheme) private var colorScheme

    private static let side: CGFloat = 56

    var body: some View {
        switch suggestion {
        case let .item(item):
            let zoomID = "suggestion-\(item.id)"
            RouteLink(item.route(zoomSource: zoomID)) {
                card(title: item.title) {
                    TileArtwork(source: artwork(of: item), zoomID: zoomID, cornerRadius: 0, points: Self.side, placeholderSymbol: placeholder(of: item))
                }
            }
            .buttonStyle(.plain)
            .contextMenu {
                HomeItemMenu(item: item)
                dontRecommend
            }
        case let .artist(artist):
            RouteLink(.artist(artist.name)) {
                card(title: artist.name) {
                    ArtistAvatarView(artistName: artist.name, songs: artist.songs, size: Self.side - 10)
                        .frame(width: Self.side, height: Self.side)
                }
            }
            .buttonStyle(.plain)
            .contextMenu { dontRecommend }
        }
    }

    private var dontRecommend: some View {
        Section {
            Button("Don't Recommend", systemImage: "hand.thumbsdown") {
                withAnimation(.smooth) { HomeSuggestions.hide(suggestion) }
            }
        }
    }

    private func card(title: String, @ViewBuilder artwork: () -> some View) -> some View {
        HStack(spacing: 10) {
            artwork()
                .frame(width: Self.side, height: Self.side)
                .clipped()
            Text(title)
                .font(.footnote.weight(.semibold))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 8)
        }
        .frame(height: Self.side)
        .background(Color.primary.opacity(colorScheme == .dark ? 0.1 : 0.06))
        .clipShape(.rect(cornerRadius: 8, style: .continuous))
        .contentShape(.rect(cornerRadius: 8, style: .continuous))
    }

    private func artwork(of item: HomeItem) -> ArtworkSource? {
        switch item {
        case let .album(album): album.artworkSource
        case let .playlist(playlist): libraryVM.playlistArtwork(playlist)
        }
    }

    private func placeholder(of item: HomeItem) -> String {
        if case .playlist = item { return "music.note.list" }
        return "music.note"
    }
}

private struct HomeShelf<Menu: View>: View {
    let title: LocalizedStringKey
    let items: [HomeItem]
    let zoomPrefix: String
    /// Up to this many tiles stacked in each column (filled top to bottom).
    var rows = 1
    @ViewBuilder let extraMenu: (HomeItem) -> Menu

    init(title: LocalizedStringKey, items: [HomeItem], zoomPrefix: String, rows: Int = 1, @ViewBuilder extraMenu: @escaping (HomeItem) -> Menu) {
        self.title = title
        self.items = items
        self.zoomPrefix = zoomPrefix
        self.rows = rows
        self.extraMenu = extraMenu
    }

    private var columns: [[HomeItem]] {
        let size = max(rows, 1)
        return stride(from: 0, to: items.count, by: size).map { Array(items[$0..<min($0 + size, items.count)]) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title2.bold())
                .padding(.horizontal, 20)

            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(columns, id: \.first?.id) { column in
                        VStack(alignment: .leading, spacing: 18) {
                            ForEach(column) { item in
                                tile(item)
                            }
                        }
                    }
                }
                .scrollTargetLayout()
            }
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.viewAligned)
            .contentMargins(.horizontal, 20, for: .scrollContent)
        }
    }

    private func tile(_ item: HomeItem) -> some View {
        let zoomID = "\(zoomPrefix)-\(item.id)"
        return RouteLink(item.route(zoomSource: zoomID)) {
            HomeItemTile(item: item, zoomID: zoomID, width: 156)
        }
        .buttonStyle(.plain)
        .contextMenu {
            HomeItemMenu(item: item)
            extraMenu(item)
        }
    }
}

/// The Pinned shelf. "Rearrange Pinned" in a tile's menu starts a Home
/// Screen-style jiggle mode: tiles wobble, hold one to pick it up and drag it,
/// the minus badge unpins, Done saves.
private struct PinnedShelf: View {
    let items: [HomeItem]
    /// Up to this many tiles stacked in each column (filled top to bottom).
    let rows: Int
    /// Opens in jiggle mode (from the Cover Flow), and says when it's done.
    var startsRearranging = false
    var onFinish: (() -> Void)?
    @EnvironmentObject private var libraryVM: LibraryViewModel

    @State private var isRearranging = false
    /// The working order while rearranging.
    @State private var order: [HomeItem] = []
    /// The tile being carried; its slot stays empty while it floats.
    @State private var dragged: HomeItem?
    /// Where the carried tile is drawn, in content coordinates.
    @State private var floatOrigin: CGPoint = .zero
    @State private var floatSize: CGSize = .zero
    @State private var isLifted = false
    /// Finger minus tile origin, kept for the whole drag.
    @State private var grabOffset: CGSize = .zero
    /// The last finger position and the scroll offset it was read at: while
    /// the shelf auto-scrolls under a still finger, the finger moves in the
    /// content by the scrolled amount.
    @State private var lastFinger: CGPoint = .zero
    @State private var scrollAtLastFinger: CGFloat = 0
    /// Each tile's slot, in content coordinates.
    @State private var frames: [String: CGRect] = [:]
    @State private var scrollPosition = ScrollPosition()
    @State private var scrollOffset: CGFloat = 0
    @State private var maxScrollOffset: CGFloat = 0
    @State private var viewportWidth: CGFloat = 0
    @State private var autoScroll: Task<Void, Never>?
    @State private var swapCount = 0

    private static let tileWidth: CGFloat = 156
    private static let margin: CGFloat = 20
    private static let space = "pinnedShelf"

    private var shown: [HomeItem] { isRearranging ? order : items }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Pinned")
                    .font(.title2.bold())
                Spacer()
                if isRearranging {
                    Button("Done") { finish() }
                        .font(.body.weight(.semibold))
                        .buttonStyle(.glass)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .frame(minHeight: 34)
            .padding(.horizontal, 20)

            ScrollView(.horizontal) {
                // One flat layout: a tile keeps its identity (and the drag)
                // when it moves to another column.
                ColumnsLayout(rows: max(rows, 1), spacing: 14, rowSpacing: 18) {
                    ForEach(shown) { item in
                        tile(item)
                    }
                }
                .overlay(alignment: .topLeading) { floatingTile }
                .coordinateSpace(name: Self.space)
                // Room for the minus badges and the wobble.
                .padding(.vertical, isRearranging ? 14 : 0)
                // No snapping to tiles while the shelf auto-scrolls.
                .scrollTargetLayout(isEnabled: !isRearranging)
            }
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition($scrollPosition)
            .scrollDisabled(dragged != nil)
            .contentMargins(.horizontal, Self.margin, for: .scrollContent)
            .onScrollGeometryChange(for: [CGFloat].self) { geometry in
                [geometry.contentOffset.x + geometry.contentInsets.leading,
                 geometry.contentSize.width - geometry.containerSize.width + geometry.contentInsets.leading + geometry.contentInsets.trailing,
                 geometry.containerSize.width]
            } action: { _, values in
                scrollOffset = values[0]
                maxScrollOffset = max(values[1], 0)
                viewportWidth = values[2]
            }
        }
        .animation(.smooth(duration: 0.3), value: isRearranging)
        .onAppear { if startsRearranging, !isRearranging { start() } }
        .sensoryFeedback(.impact(weight: .medium), trigger: isRearranging) { _, new in new }
        .sensoryFeedback(.impact(weight: .light), trigger: isLifted) { _, new in new }
        .sensoryFeedback(.selection, trigger: swapCount)
        .onChange(of: items.map(\.id)) { _, ids in
            // Pins changed elsewhere (or the last one went): follow along.
            guard isRearranging else { return }
            let kept = order.filter { ids.contains($0.id) }
            order = kept + items.filter { item in !kept.contains { $0.id == item.id } }
            if order.isEmpty { finish() }
        }
        .onDisappear { if isRearranging { finish() } }
    }

    // MARK: Tiles

    @ViewBuilder
    private func tile(_ item: HomeItem) -> some View {
        let zoomID = "pinned-\(item.id)"
        if isRearranging {
            HomeItemTile(item: item, zoomID: zoomID, width: Self.tileWidth)
                .allowsHitTesting(false)
                .overlay(alignment: .topLeading) { unpinBadge(item) }
                .modifier(Jiggle(isOn: true, seed: item.id.hashValue))
                .contentShape(Rectangle())
                // The carried tile floats above; its slot stays empty.
                .opacity(dragged?.id == item.id ? 0 : 1)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { frames[item.id] = $0 }
                .gesture(PickUpGesture(space: Self.space) { finger in
                    pickUp(item, at: finger)
                } onMove: { finger in
                    move(to: finger)
                } onEnd: {
                    drop()
                })
        } else {
            RouteLink(item.route(zoomSource: zoomID)) {
                HomeItemTile(item: item, zoomID: zoomID, width: Self.tileWidth)
            }
            .buttonStyle(.plain)
            .contextMenu {
                HomeItemMenu(item: item)
                Section {
                    Button("Rearrange Pinned", systemImage: "square.grid.3x1.below.line.grid.1x2") { start() }
                        .disabled(items.count < 2)
                }
            }
        }
    }

    @ViewBuilder
    private var floatingTile: some View {
        if let dragged {
            HomeItemTile(item: dragged, zoomID: "pinned-floating", width: Self.tileWidth)
                .frame(width: floatSize.width, height: floatSize.height, alignment: .topLeading)
                .scaleEffect(isLifted ? 1.08 : 1)
                .shadow(color: .black.opacity(isLifted ? 0.35 : 0), radius: 18, y: 10)
                .offset(x: floatOrigin.x, y: floatOrigin.y)
                .allowsHitTesting(false)
        }
    }

    private func unpinBadge(_ item: HomeItem) -> some View {
        Button {
            withAnimation(.smooth(duration: 0.3)) {
                order.removeAll { $0.id == item.id }
                libraryVM.unpin(item)
            }
        } label: {
            Image(systemName: "minus")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.primary)
                .frame(width: 26, height: 26)
                .glassEffect(.regular.interactive(), in: .circle)
        }
        .buttonStyle(.plain)
        .offset(x: -9, y: -9)
        .transition(.scale.combined(with: .opacity))
        .accessibilityLabel("Unpin \(item.title)")
    }

    // MARK: Rearranging

    private func start() {
        order = items
        isRearranging = true
    }

    private func finish() {
        stopAutoScroll()
        dragged = nil
        isLifted = false
        if isRearranging, order.map(\.id) != items.map(\.id) {
            libraryVM.setPinnedOrder(order)
        }
        isRearranging = false
        onFinish?()
    }

    /// The finger in content coordinates, following any auto-scroll.
    private var finger: CGPoint {
        CGPoint(x: lastFinger.x + scrollOffset - scrollAtLastFinger, y: lastFinger.y)
    }

    private func pickUp(_ item: HomeItem, at finger: CGPoint) {
        guard dragged == nil, let slot = frames[item.id] else { return }
        lastFinger = finger
        scrollAtLastFinger = scrollOffset
        grabOffset = CGSize(width: finger.x - slot.minX, height: finger.y - slot.minY)
        floatSize = slot.size
        floatOrigin = slot.origin
        dragged = item
        withAnimation(.spring(duration: 0.25, bounce: 0.3)) { isLifted = true }
    }

    private func move(to finger: CGPoint) {
        guard dragged != nil else { return }
        lastFinger = finger
        scrollAtLastFinger = scrollOffset
        followFinger()
        updateAutoScroll()
    }

    /// Puts the floating tile under the finger and its slot under the tile.
    private func followFinger() {
        let finger = finger
        floatOrigin = CGPoint(x: finger.x - grabOffset.width, y: finger.y - grabOffset.height)
        reorder(at: finger)
    }

    private func drop() {
        stopAutoScroll()
        guard let item = dragged else { return }
        // Settle into the slot, then hand back to the grid.
        withAnimation(.spring(duration: 0.35, bounce: 0.2)) {
            if let slot = frames[item.id] { floatOrigin = slot.origin }
            isLifted = false
        } completion: {
            if dragged?.id == item.id { dragged = nil }
        }
    }

    /// Moves the carried tile's slot to the tile under the finger.
    private func reorder(at finger: CGPoint) {
        guard let id = dragged?.id,
              let target = order.first(where: { $0.id != id && (frames[$0.id]?.contains(finger) ?? false) }),
              let from = order.firstIndex(where: { $0.id == id }),
              let to = order.firstIndex(where: { $0.id == target.id }) else { return }
        withAnimation(.spring(duration: 0.35, bounce: 0.15)) {
            order.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        }
        swapCount += 1
    }

    /// Near an edge, the shelf scrolls on its own so far tiles stay reachable.
    private func updateAutoScroll() {
        guard edgeDirection != 0 else {
            stopAutoScroll()
            return
        }
        guard autoScroll == nil else { return }
        autoScroll = Task { @MainActor in
            // The direction is read every frame: the finger can move to the
            // other edge without lifting.
            while !Task.isCancelled, dragged != nil, edgeDirection != 0 {
                let next = min(max(scrollOffset + edgeDirection * 7, 0), maxScrollOffset)
                guard next != scrollOffset else { break }
                scrollOffset = next
                scrollPosition.scrollTo(x: next)
                followFinger()
                try? await Task.sleep(for: .milliseconds(16))
            }
            autoScroll = nil
        }
    }

    /// -1 or 1 while the finger is held near an edge of the shelf, else 0.
    private var edgeDirection: CGFloat {
        // The finger in the visible frame.
        let x = finger.x + Self.margin - scrollOffset
        let edge: CGFloat = 60
        return x < edge ? -1 : x > viewportWidth - edge ? 1 : 0
    }

    private func stopAutoScroll() {
        autoScroll?.cancel()
        autoScroll = nil
    }
}

/// A UIKit long press: it fails as soon as the finger moves first, so a swipe
/// still scrolls the shelf; once it fires it tracks the finger like a drag.
struct PickUpGesture: UIGestureRecognizerRepresentable {
    let space: String
    let onBegin: (CGPoint) -> Void
    let onMove: (CGPoint) -> Void
    let onEnd: () -> Void

    init(space: String, onBegin: @escaping (CGPoint) -> Void, onMove: @escaping (CGPoint) -> Void, onEnd: @escaping () -> Void) {
        self.space = space
        self.onBegin = onBegin
        self.onMove = onMove
        self.onEnd = onEnd
    }

    func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
        let recognizer = UILongPressGestureRecognizer()
        recognizer.minimumPressDuration = 0.2
        recognizer.allowableMovement = 10
        return recognizer
    }

    func handleUIGestureRecognizerAction(_ recognizer: UILongPressGestureRecognizer, context: Context) {
        let location = context.converter.location(in: .named(space))
        switch recognizer.state {
        case .began: onBegin(location)
        case .changed: onMove(location)
        case .ended, .cancelled, .failed: onEnd()
        default: break
        }
    }
}

/// Tiles in columns of `rows`, filled top to bottom then left to right.
struct ColumnsLayout: Layout {
    let rows: Int
    let spacing: CGFloat
    let rowSpacing: CGFloat

    private func grid(_ subviews: Subviews) -> (sizes: [CGSize], widths: [CGFloat], heights: [CGFloat]) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        var widths = [CGFloat](repeating: 0, count: (sizes.count + rows - 1) / rows)
        var heights = [CGFloat](repeating: 0, count: min(rows, sizes.count))
        for (index, size) in sizes.enumerated() {
            widths[index / rows] = max(widths[index / rows], size.width)
            heights[index % rows] = max(heights[index % rows], size.height)
        }
        return (sizes, widths, heights)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let (_, widths, heights) = grid(subviews)
        return CGSize(
            width: widths.reduce(0, +) + spacing * CGFloat(max(widths.count - 1, 0)),
            height: heights.reduce(0, +) + rowSpacing * CGFloat(max(heights.count - 1, 0))
        )
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (sizes, widths, heights) = grid(subviews)
        for (index, subview) in subviews.enumerated() {
            let column = index / rows, row = index % rows
            let x = bounds.minX + widths[..<column].reduce(0, +) + spacing * CGFloat(column)
            let y = bounds.minY + heights[..<row].reduce(0, +) + rowSpacing * CGFloat(row)
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sizes[index]))
        }
    }
}

/// The Home Screen wobble: a small rotation back and forth, each tile slightly
/// out of step with its neighbours.
struct Jiggle: ViewModifier {
    let isOn: Bool
    let seed: Int

    func body(content: Content) -> some View {
        let amplitude = 1.6
        let step = 0.11 + Double(abs(seed) % 4) * 0.008
        let startsLeft = seed % 2 == 0
        content.keyframeAnimator(initialValue: 0.0, repeating: isOn) { view, angle in
            view.rotationEffect(.degrees(isOn ? angle : 0))
        } keyframes: { _ in
            KeyframeTrack {
                CubicKeyframe(startsLeft ? -amplitude : amplitude, duration: step)
                CubicKeyframe(startsLeft ? amplitude : -amplitude, duration: step * 2)
                CubicKeyframe(0, duration: step)
            }
        }
    }
}

private struct HomeItemTile: View {
    let item: HomeItem
    let zoomID: String
    var width: CGFloat?

    var body: some View {
        switch item {
        case let .album(album):
            AlbumTile(album: album, zoomID: zoomID, width: width)
        case let .playlist(playlist):
            PlaylistTile(playlist: playlist, zoomID: zoomID, width: width)
        }
    }
}

/// Context menu of an album / playlist tile.
struct HomeItemMenu: View {
    let item: HomeItem
    @EnvironmentObject private var libraryVM: LibraryViewModel
    @EnvironmentObject private var playerVM: PlayerViewModel

    private func addToPlaylistMenu(_ songs: [Song], excluding: UUID? = nil) -> some View {
        Menu("Add to Playlist", systemImage: "text.badge.plus") {
            Button("New Playlist…", systemImage: "plus") {
                libraryVM.requestNewPlaylist(adding: songs)
            }
            ForEach(libraryVM.editablePlaylists.filter { $0.id != excluding }) { target in
                Button(target.name) { libraryVM.addToPlaylist(songs: songs, playlistId: target.id) }
            }
        }
    }

    var body: some View {
        switch item {
        case let .album(album):
            Section {
                Button("Play", systemImage: "play") { playerVM.play(album.songs, shuffled: false) }
                Button("Shuffle", systemImage: "shuffle") { playerVM.play(album.songs, shuffled: true) }
                Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") {
                    album.songs.forEach { playerVM.addNextToQueue(song: $0) }
                }
            }
            Section {
                Button(libraryVM.isAlbumPinned(album.id) ? "Unpin from Home" : "Pin on Home", systemImage: libraryVM.isAlbumPinned(album.id) ? "pin.slash" : "pin") {
                    libraryVM.toggleAlbumPin(album.id)
                }
                Button("Covers Snake", systemImage: "square.grid.3x3") {
                    libraryVM.presentCoversSnake(title: album.title, songs: album.songs)
                }
            }
            Section { addToPlaylistMenu(album.songs) }
        case let .playlist(playlist):
            Section {
                Button("Play", systemImage: "play") { playerVM.playPlaylist(playlist) }
                Button("Shuffle", systemImage: "shuffle") { playerVM.playPlaylist(playlist, shuffled: true) }
            }
            Section {
                Button(libraryVM.isPlaylistPinned(id: playlist.id) ? "Unpin" : "Pin", systemImage: libraryVM.isPlaylistPinned(id: playlist.id) ? "pin.slash" : "pin") {
                    libraryVM.togglePlaylistPin(id: playlist.id)
                }
                Button("Covers Snake", systemImage: "square.grid.3x3") {
                    libraryVM.presentCoversSnake(title: playlist.name, songs: libraryVM.songs(in: playlist))
                }
            }
            Section { addToPlaylistMenu(libraryVM.songs(in: playlist), excluding: playlist.id) }
            Section {
                if playlist.isAutolist {
                    Button("Edit Autolist", systemImage: "slider.horizontal.3") {
                        libraryVM.requestEdit(of: playlist)
                    }
                } else {
                    Button("Edit Playlist", systemImage: "pencil") {
                        libraryVM.requestEdit(ofPlaylist: playlist)
                    }
                }
            }
            Section {
                Button(role: .destructive) {
                    libraryVM.deletePlaylist(playlist)
                } label: {
                    DestructiveLabel(playlist.isAutolist ? "Delete Autolist" : "Delete Playlist", systemImage: "trash")
                }
            }
        }
    }
}

private struct FirstImportPromptSheet: View {
    let onChooseFolder: () -> Void
    @EnvironmentObject private var libraryVM: LibraryViewModel
    @Environment(\.dismiss) private var dismiss
    @AppTintSelection private var appTint

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "text.badge.plus")
                .font(.system(size: 52, weight: .semibold))
                .foregroundStyle(appTint.color)
            Text("Match Lyrics Automatically")
                .font(.title.bold())
                .multilineTextAlignment(.center)
            Text("Choose the folder where your LRC files are stored, or find the best lyrics online for each song.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Label("You can change the folder anytime from the + menu.", systemImage: "info.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                onChooseFolder()
            } label: {
                Text("Choose LRC Folder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)

            AutoMatchLyricsButton(songs: libraryVM.songs)

            Button("Not Now") { dismiss() }
                .controlSize(.large)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 24)
        .presentationDetents([.large])
    }
}
