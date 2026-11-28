import SwiftUI
import UIKit
import Combine

/// Typing the secret code in a song search unlocks the hidden settings.
private struct HiddenSettingsUnlockModifier: ViewModifier {
    @Binding var searchText: String
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        content
            .onChange(of: searchText) { _, text in
                guard HiddenSettings.matchesUnlockCode(text) else { return }
                searchText = ""
                HiddenSettings.isUnlocked = true
                isPresented = true
            }
            .alert("Hidden Settings Enabled", isPresented: $isPresented) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("You'll find them at the bottom of Settings.")
            }
    }
}

extension View {
    func hiddenSettingsUnlock(searchText: Binding<String>, isPresented: Binding<Bool>) -> some View {
        modifier(HiddenSettingsUnlockModifier(searchText: searchText, isPresented: isPresented))
    }
}

struct SortMenu: View {
    @Binding var selection: String
    let options: [(id: String, title: String)]

    var body: some View {
        Menu {
            Picker("Sort By", selection: $selection) {
                ForEach(options, id: \.id) { option in
                    Text(option.title).tag(option.id)
                }
            }
        } label: {
            BarIcon("Sort", systemImage: "arrow.up.arrow.down")
        }
    }
}

// MARK: - Albums

/// How album collections are laid out: a grid of covers (2 to 4 a row on a
/// phone; wider screens fit as many as they hold) or a list.
enum AlbumLayout: String, CaseIterable {
    case grid, list

    static let storageKey = "albumsLayout"
    static let columnsKey = "albumsGridColumns"

    var title: String {
        switch self {
        case .grid: String(localized: "Grid")
        case .list: String(localized: "List")
        }
    }

    var symbol: String {
        switch self {
        case .grid: "square.grid.2x2"
        case .list: "list.bullet"
        }
    }

    static let columnChoices = 2...4

    @MainActor static var choosesColumns: Bool {
        UIDevice.current.userInterfaceIdiom == .phone
    }

    @MainActor static func gridColumns(_ count: Int) -> [GridItem] {
        guard choosesColumns else {
            return [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 16)]
        }
        let count = min(max(count, columnChoices.lowerBound), columnChoices.upperBound)
        return Array(repeating: GridItem(.flexible(), spacing: count > 2 ? 12 : 16), count: count)
    }
}

/// The View part of an albums (or playlists) menu: Grid or List, and covers
/// per row.
struct AlbumLayoutPickers: View {
    @AppStorage private var layoutRawValue: String
    @AppStorage private var columns: Int
    private let perRowTitle: LocalizedStringKey

    init(layoutKey: String = AlbumLayout.storageKey, columnsKey: String = AlbumLayout.columnsKey,
         defaultLayout: AlbumLayout = .grid, defaultColumns: Int = 3, perRowTitle: LocalizedStringKey = "Albums per Row") {
        _layoutRawValue = AppStorage(wrappedValue: defaultLayout.rawValue, layoutKey)
        _columns = AppStorage(wrappedValue: defaultColumns, columnsKey)
        self.perRowTitle = perRowTitle
    }

    var body: some View {
        Picker("View", selection: $layoutRawValue.animation(.smooth)) {
            ForEach(AlbumLayout.allCases, id: \.rawValue) { layout in
                Label(layout.title, systemImage: layout.symbol).tag(layout.rawValue)
            }
        }
        if layoutRawValue == AlbumLayout.grid.rawValue, AlbumLayout.choosesColumns {
            Picker(perRowTitle, selection: $columns.animation(.smooth)) {
                ForEach(Array(AlbumLayout.columnChoices), id: \.self) { count in
                    Text("\(count) per Row").tag(count)
                }
            }
        }
    }
}

/// Pinching a covers grid changes how many fit a row, like Photos:
/// spreading out enlarges them, pinching in fits more.
private struct GridColumnsPinch: ViewModifier {
    @Binding var columns: Int
    /// The magnification the last step happened at.
    @State private var baseline: CGFloat = 1
    @GestureState private var isPinching = false
    /// Covers stay closed through a pinch and just after it.
    @State private var holdsTaps = false

    func body(content: Content) -> some View {
        if AlbumLayout.choosesColumns {
            content
                .environment(\.opensRoutes, !holdsTaps)
                .simultaneousGesture(
                    MagnifyGesture()
                        .updating($isPinching) { _, state, _ in state = true }
                        .onChanged { value in
                            let scale = value.magnification / baseline
                            let step = scale > 1.2 ? -1 : scale < 0.83 ? 1 : 0
                            guard step != 0 else { return }
                            baseline = value.magnification
                            let range = AlbumLayout.columnChoices
                            let next = min(max(columns + step, range.lowerBound), range.upperBound)
                            guard next != columns else { return }
                            withAnimation(.smooth) { columns = next }
                        }
                        .onEnded { _ in baseline = 1 }
                )
                .onChange(of: isPinching) { _, pinching in
                    if pinching {
                        holdsTaps = true
                    } else {
                        baseline = 1
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            if !isPinching { holdsTaps = false }
                        }
                    }
                }
                .sensoryFeedback(.selection, trigger: columns)
        } else {
            content
        }
    }
}

extension View {
    func pinchesGridColumns(_ columns: Binding<Int>) -> some View {
        modifier(GridColumnsPinch(columns: columns))
    }
}

/// An album in a list: small cover, title, artist (and year when known).
struct AlbumListRow: View {
    let album: Album
    var zoomID: String?
    var showsArtist = true

    var body: some View {
        HStack(spacing: 14) {
            TileArtwork(source: album.artworkSource, zoomID: zoomID, cornerRadius: 6, points: 64, placeholderSymbol: "music.note")
                .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 2) {
                Text(album.title)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                let details = [showsArtist ? album.artist : nil, album.year > 0 ? String(album.year) : nil].compactMap { $0 }
                if !details.isEmpty {
                    Text(details.joined(separator: " · "))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
        }
        .contentShape(Rectangle())
    }
}

struct AlbumGridView: View {
    enum SortMode: String, CaseIterable {
        case title, artist, recentlyAdded, year

        var title: String {
            switch self {
            case .title: String(localized: "Title")
            case .artist: String(localized: "Artist")
            case .recentlyAdded: String(localized: "Recently Added")
            case .year: String(localized: "Release Date")
            }
        }
    }

    /// Only this artist's albums (from an artist page).
    var artistName: String?
    /// Only the albums with one of these songs (from a genre-like page).
    var songIDs: Set<UUID>?
    @EnvironmentObject private var libraryVM: LibraryViewModel
    @AppStorage("albumsSortMode") private var sortModeRawValue = SortMode.recentlyAdded.rawValue
    @AppStorage(AlbumLayout.storageKey) private var layoutRawValue = AlbumLayout.grid.rawValue
    @AppStorage(AlbumLayout.columnsKey) private var columns = 3
    @State private var searchText = ""
    @State private var pageWidth: CGFloat = 0

    /// The Cover Flow atop the tab: the most played albums, mixed with the
    /// last played and the newest. Not on an artist's page nor in a search.
    private var highlights: [Album] {
        guard artistName == nil, songIDs == nil, searchText.isEmpty else { return [] }
        let highlights = Self.highlights(libraryVM.albums)
        return highlights.count > 2 ? highlights : []
    }

    static func highlights(_ albums: [Album], count: Int = 30) -> [Album] {
        let played = albums.compactMap { album -> (album: Album, plays: Int, last: Date)? in
            guard let last = album.songs.compactMap(\.lastPlayedAt).max() else { return nil }
            return (album, album.songs.reduce(0) { $0 + $1.playCount }, last)
        }
        let mostPlayed = played.filter { $0.plays > 0 }
            .sorted { $0.plays != $1.plays ? $0.plays > $1.plays : $0.last > $1.last }
            .map(\.album)
        let lastPlayedFirst = played.sorted { $0.last > $1.last }.map(\.album)
        let newest = albums.sorted { $0.dateAdded > $1.dateAdded }

        // Mostly favorites and what was just played, a new one now and then.
        var queues = [mostPlayed[...], lastPlayedFirst[...], newest[...]]
        let pattern = [0, 1, 0, 1, 2]
        var picked: [Album] = []
        var seen = Set<AlbumID>()
        var turn = 0
        while picked.count < count, queues.contains(where: { !$0.isEmpty }) {
            var queue = pattern[turn % pattern.count]
            turn += 1
            // An empty queue gives its turn to the next one.
            while queues[queue].isEmpty { queue = (queue + 1) % queues.count }
            let album = queues[queue].removeFirst()
            if seen.insert(album.id).inserted { picked.append(album) }
        }
        return picked
    }

    private var albums: [Album] {
        var albums = libraryVM.albums
        if let artistName {
            albums = albums.filter { ArtistMerges.main(for: $0.artist) == artistName }
        }
        if let songIDs {
            albums = albums.filter { $0.songs.contains { songIDs.contains($0.id) } }
        }
        if !searchText.isEmpty {
            albums = albums.filter {
                $0.title.localizedStandardContains(searchText) || $0.artist.localizedStandardContains(searchText)
            }
        }
        switch SortMode(rawValue: sortModeRawValue) ?? .title {
        case .title:
            break
        case .artist:
            albums.sort {
                let order = $0.artist.libraryCompare($1.artist)
                return order == .orderedSame ? $0.title.libraryCompare($1.title) == .orderedAscending : order == .orderedAscending
            }
        case .recentlyAdded:
            albums.sort { $0.dateAdded > $1.dateAdded }
        case .year:
            albums.sort { ($0.year == 0 ? Int.max : -$0.year, $0.title) < ($1.year == 0 ? Int.max : -$1.year, $1.title) }
        }
        return albums
    }

    var body: some View {
        let albums = albums
        let highlights = highlights
        Group {
            if layoutRawValue == AlbumLayout.list.rawValue {
                List {
                    if !highlights.isEmpty {
                        AlbumHighlightsCoverFlow(albums: highlights, width: pageWidth)
                            .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 16, trailing: 0))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }
                    ForEach(albums) { album in
                        let zoomID = "albums-\(album.id.pinKey)-\(album.id.singleSongID?.uuidString ?? "")"
                        RouteLink(.album(album.id, zoomSource: zoomID)) {
                            AlbumListRow(album: album, zoomID: zoomID, showsArtist: artistName == nil)
                        }
                        .contextMenu { HomeItemMenu(item: .album(album)) }
                        .listRowInsets(EdgeInsets(top: 6, leading: 20, bottom: 6, trailing: 20))
                        .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.plain)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        if !highlights.isEmpty {
                            AlbumHighlightsCoverFlow(albums: highlights, width: pageWidth)
                                .padding(.top, 8)
                                .padding(.bottom, 12)
                        }
                        LazyVGrid(columns: AlbumLayout.gridColumns(columns), spacing: columns > 2 ? 18 : 22) {
                            ForEach(albums) { album in
                                let zoomID = "albums-\(album.id.pinKey)-\(album.id.singleSongID?.uuidString ?? "")"
                                RouteLink(.album(album.id, zoomSource: zoomID)) {
                                    AlbumTile(album: album, zoomID: zoomID)
                                }
                                .buttonStyle(.plain)
                                .contextMenu { HomeItemMenu(item: .album(album)) }
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                    }
                }
                .pinchesGridColumns($columns)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { pageWidth = $0 }
        .overlay {
            if albums.isEmpty {
                if searchText.isEmpty {
                    ContentUnavailableView("No Albums", systemImage: "square.stack")
                } else {
                    ContentUnavailableView.search(text: searchText)
                }
            }
        }
        .pageTitle("Albums")
        .pageSearch(text: $searchText, prompt: "Find in Albums")
        .pageTrailingItem {
            Menu {
                Picker("Sort By", selection: $sortModeRawValue) {
                    ForEach(SortMode.allCases, id: \.rawValue) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
                Section { AlbumLayoutPickers() }
            } label: {
                BarIcon("Sort and View", systemImage: "ellipsis")
            }
        }
    }
}

// MARK: - Artists

struct QueueSwipeButtons: View {
    let song: Song
    @EnvironmentObject private var playerVM: PlayerViewModel

    var body: some View {
        Button {
            // Right after the current song, after those already added.
            playerVM.addNextToQueue(song: song)
        } label: {
            Label("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward")
        }
        .tint(.orange)
    }
}

struct SectionHeader: View {
    let title: LocalizedStringKey

    var body: some View {
        Text(title)
            .font(.title2.bold())
            .foregroundStyle(.primary)
            .textCase(nil)
            .padding(.top, 8)
    }
}

// MARK: - Playlists

struct PlaylistListView: View {
    enum SortMode: String, CaseIterable {
        case title, recentlyAdded, recentlyUpdated

        var title: String {
            switch self {
            case .title: String(localized: "Title")
            case .recentlyAdded: String(localized: "Recently Added")
            case .recentlyUpdated: String(localized: "Recently Updated")
            }
        }
    }

    static let layoutKey = "playlistsLayout"
    static let columnsKey = "playlistsGridColumns"

    /// Pinned ones first, in their own order; the sort applies to the rest.
    /// Unsearched, the pinned ones can be left to the Cover Flow above.
    @MainActor static func rows(_ libraryVM: LibraryViewModel, sort: SortMode, search: String, hidesPinned: Bool = false) -> [Playlist] {
        let pinned = libraryVM.orderedPinnedPlaylists
        let pinnedIDs = Set(pinned.map(\.id))
        var others = libraryVM.playlists.filter { !pinnedIDs.contains($0.id) }
        switch sort {
        case .title: others.sort { $0.name.libraryCompare($1.name) == .orderedAscending }
        case .recentlyAdded: others.sort { $0.createdAt > $1.createdAt }
        case .recentlyUpdated: others.sort { ($0.autolistUpdatedAt ?? $0.modifiedAt) > ($1.autolistUpdatedAt ?? $1.modifiedAt) }
        }
        let all = pinned + others
        if search.isEmpty, hidesPinned { return others }
        return search.isEmpty ? all : all.filter { $0.name.localizedStandardContains(search) }
    }

    static func detail(for playlist: Playlist) -> String {
        playlist.isAutolist
            ? String(localized: "Autolist · \(playlist.songCount) songs")
            : String(localized: "\(playlist.songCount) songs")
    }

    @EnvironmentObject private var libraryVM: LibraryViewModel
    @AppStorage(Self.layoutKey) private var layoutRawValue = AlbumLayout.list.rawValue
    @AppStorage(Self.columnsKey) private var columns = 2
    @AppStorage("playlistsSortMode") private var sortModeRawValue = SortMode.title.rawValue
    @State private var searchText = ""
    /// Rearranging the pinned playlists (a long press opens the context menu,
    /// so dragging needs its own mode).
    @State private var isRearranging = false
    @State private var pageWidth: CGFloat = 0
    @ObservedObject private var programs = ProgramStore.shared

    var body: some View {
        let pinnedCount = libraryVM.orderedPinnedPlaylists.count
        Group {
            // Pinned playlists are rearranged in the list.
            if layoutRawValue == AlbumLayout.grid.rawValue, !isRearranging {
                grid
            } else {
                PlaylistTable(searchText: searchText, sortMode: sortMode, isRearranging: isRearranging) {
                    isRearranging = true
                }
                .ignoresSafeArea()
            }
        }
            .overlay {
                if !searchText.isEmpty, !libraryVM.playlists.contains(where: { $0.name.localizedStandardContains(searchText) }) {
                    ContentUnavailableView.search(text: searchText)
                }
            }
            .pageTitle("Playlists")
            .pageSearch(text: $searchText, prompt: "Find in Playlists")
            .pageTrailingItem {
                if isRearranging {
                    Button {
                        isRearranging = false
                    } label: {
                        BarIcon("Done", systemImage: "checkmark")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                } else {
                    Menu {
                        Section {
                            Button("New Playlist…", systemImage: "plus") { libraryVM.requestNewPlaylist() }
                            Button("New Autolist…", systemImage: "wand.and.stars") { libraryVM.requestNewAutolist() }
                            Button("New Program…", systemImage: "rectangle.stack.badge.play") { programs.newProgram() }
                        }
                        if pinnedCount > 1, searchText.isEmpty {
                            Section {
                                Button("Edit Pinned", systemImage: "pencil") { isRearranging = true }
                            }
                        }
                        Picker("Sort By", selection: $sortModeRawValue) {
                            ForEach(SortMode.allCases, id: \.rawValue) { mode in
                                Text(mode.title).tag(mode.rawValue)
                            }
                        }
                        Section {
                            AlbumLayoutPickers(layoutKey: Self.layoutKey, columnsKey: Self.columnsKey,
                                               defaultLayout: .list, defaultColumns: 2, perRowTitle: "Playlists per Row")
                        }
                    } label: {
                        BarIcon("More", systemImage: "ellipsis")
                    }
                }
            }
            .onChange(of: searchText) { _, text in
                if !text.isEmpty { isRearranging = false }
            }
            .onChange(of: pinnedCount) { _, count in
                if count < 2 { isRearranging = false }
            }
            .sheet(item: $programs.editor) { request in
                ProgramEditorView(request: request)
            }
    }

    private var sortMode: SortMode { SortMode(rawValue: sortModeRawValue) ?? .title }

    private var grid: some View {
        let shown = Self.rows(libraryVM, sort: sortMode, search: searchText, hidesPinned: true)
        let pinned = searchText.isEmpty ? libraryVM.orderedPinnedPlaylists : []
        return ScrollView {
            VStack(spacing: 0) {
                if !pinned.isEmpty {
                    PinnedCoverFlow(items: pinned.map(HomeItem.playlist), width: pageWidth, subtitle: Self.subtitle) {
                        isRearranging = true
                    }
                    .padding(.top, 8)
                    .padding(.bottom, 12)
                }
                if searchText.isEmpty {
                    ProgramsShelf(width: pageWidth)
                        .padding(.top, pinned.isEmpty ? 8 : 0)
                }
                LazyVGrid(columns: AlbumLayout.gridColumns(columns), spacing: columns > 2 ? 18 : 22) {
                    ForEach(shown) { playlist in
                        let zoomID = "playlist-row-\(playlist.id.uuidString)"
                        RouteLink(.playlist(playlist.id, zoomSource: zoomID)) {
                            PlaylistTile(playlist: playlist, zoomID: zoomID)
                        }
                        .buttonStyle(.plain)
                        .contextMenu { HomeItemMenu(item: .playlist(playlist)) }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
        }
        .pinchesGridColumns($columns)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { pageWidth = $0 }
    }

    /// The pinned Cover Flow's line under each playlist.
    static func subtitle(_ item: HomeItem) -> String {
        if case let .playlist(playlist) = item { detail(for: playlist) } else { item.subtitle }
    }
}

/// The Playlists list, pinned ones first. A UITableView: pinning moves the
/// row once its swipe has closed (`didEndEditingRowAt`), with a real row
/// move drawn above the rows it passes. SwiftUI's List can do neither.
private struct PlaylistTable: UIViewControllerRepresentable {
    let searchText: String
    let sortMode: PlaylistListView.SortMode
    let isRearranging: Bool
    let onRearrange: @MainActor () -> Void
    @Environment(\.appServices) private var services

    func makeUIViewController(context: Context) -> PlaylistTableViewController {
        PlaylistTableViewController(services: services)
    }

    func updateUIViewController(_ controller: PlaylistTableViewController, context: Context) {
        controller.onRearrange = onRearrange
        controller.update(searchText: searchText, sortMode: sortMode, isRearranging: isRearranging)
    }
}

/// The pinned playlists' Cover Flow atop the table, its own SwiftUI root.
private struct PlaylistTableHeader: View {
    let services: AppServices
    let width: CGFloat
    let onRearrange: @MainActor () -> Void
    /// Changes the root (and so the height) as soon as the shelf comes or goes.
    let showsPrograms: Bool
    /// Each program is a line of its own: the height follows their count.
    let programCount: Int
    let showsPinned: Bool
    @ObservedObject var libraryVM: LibraryViewModel

    var body: some View {
        let pinned = libraryVM.orderedPinnedPlaylists
        VStack(spacing: 0) {
            if showsPinned, !pinned.isEmpty {
                PinnedCoverFlow(items: pinned.map(HomeItem.playlist), width: width,
                                subtitle: PlaylistListView.subtitle, onRearrange: onRearrange)
                    .padding(.bottom, showsPrograms ? 4 : 0)
            }
            if showsPrograms {
                ProgramsShelf(width: width)
            }
        }
            .padding(.top, 8)
            .padding(.bottom, 16)
            .environment(\.appServicesStorage, services)
            .environmentObject(services.libraryVM)
            .environmentObject(services.playerVM)
            .environmentObject(services.router)
    }
}

private final class PlaylistTableViewController: UITableViewController {
    private enum Section: Int, CaseIterable {
        case playlists
    }

    private static let cellID = "PlaylistCell"
    private static let rowHeight: CGFloat = 68

    private let services: AppServices
    private var libraryVM: LibraryViewModel { services.libraryVM }
    private var playerVM: PlayerViewModel { services.playerVM }
    private var router: AppRouter { services.router }
    private var cancellables = Set<AnyCancellable>()
    var onRearrange: @MainActor () -> Void = {}
    private var header: UIHostingController<PlaylistTableHeader>?

    private var searchText = ""
    private var sortMode = PlaylistListView.SortMode(rawValue: UserDefaults.standard.string(forKey: "playlistsSortMode") ?? "") ?? .title
    private var rows: [Playlist] = []
    private var pinnedIDs: Set<UUID> = []
    /// Our rearranging mode; `tableView.isEditing` is also on during a swipe.
    private var isRearranging = false
    /// Pinned from a swipe or a context menu: applied once that has closed.
    private var pendingPinToggle: UUID?

    init(services: AppServices) {
        self.services = services
        super.init(style: .plain)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:)") }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.backgroundColor = .pageBackground
        tableView.rowHeight = Self.rowHeight
        tableView.separatorStyle = .none
        tableView.keyboardDismissMode = .onDrag
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: Self.cellID)
        (rows, pinnedIDs) = currentRows()

        // After willSet: the sink reads the model.
        libraryVM.$playlists.map { _ in () }
            .merge(with: libraryVM.$pinnedPlaylists.map { _ in () })
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.reloadFromModel() }
            .store(in: &cancellables)
        ProgramStore.shared.$programs.map(\.count)
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateHeader() }
            .store(in: &cancellables)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        adoptAsContentScrollView(tableView)
    }

    /// Width and text size the header was last laid out for: layout runs on
    /// every scroll frame, model changes call updateHeader() themselves.
    private var headerLayoutKey: (CGFloat, UIContentSizeCategory)?

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let key = (tableView.bounds.width, traitCollection.preferredContentSizeCategory)
        if let last = headerLayoutKey, last == key { return }
        headerLayoutKey = key
        updateHeader()
    }

    func update(searchText: String, sortMode: PlaylistListView.SortMode, isRearranging: Bool) {
        if searchText != self.searchText || sortMode != self.sortMode {
            self.searchText = searchText
            self.sortMode = sortMode
            reloadFromModel()
        }
        if self.isRearranging != isRearranging {
            self.isRearranging = isRearranging
            // Rearranging brings the pinned rows back from the Cover Flow.
            reloadFromModel()
            tableView.setEditing(isRearranging, animated: true)
            for path in tableView.indexPathsForVisibleRows ?? [] {
                guard let cell = tableView.cellForRow(at: path), let playlist = rows[safe: path.row] else { continue }
                cell.accessoryType = isRearranging ? .none : .disclosureIndicator
                cell.showsReorderControl = isRearranging && pinnedIDs.contains(playlist.id)
            }
        }
    }

    // MARK: Header

    /// The pinned playlists' Cover Flow, while there are some and the rows
    /// are neither searched nor rearranged.
    private func updateHeader() {
        // The header spans the table, under the Mac's sidebar too, but its
        // content keeps to the safe area: sized to what's left.
        let width = tableView.bounds.width - tableView.safeAreaInsets.left - tableView.safeAreaInsets.right
        let frameWidth = tableView.bounds.width
        let showsPrograms = !ProgramStore.shared.programs.isEmpty
        let shows = (!pinnedIDs.isEmpty || showsPrograms) && searchText.isEmpty && !isRearranging && width > 0
        guard shows else {
            if let header {
                header.willMove(toParent: nil)
                tableView.tableHeaderView = nil
                header.removeFromParent()
                self.header = nil
            }
            return
        }
        // Also called on every scroll: the root only changes with the width,
        // the Cover Flow follows the pinned playlists on its own.
        let root = PlaylistTableHeader(services: services, width: width, onRearrange: { [weak self] in self?.onRearrange() },
                                       showsPrograms: showsPrograms, programCount: ProgramStore.shared.programs.count,
                                       showsPinned: !pinnedIDs.isEmpty, libraryVM: libraryVM)
        let header: UIHostingController<PlaylistTableHeader>
        if let existing = self.header {
            header = existing
            if header.rootView.width != width || header.rootView.showsPrograms != showsPrograms
                || header.rootView.showsPinned != root.showsPinned || header.rootView.programCount != root.programCount { header.rootView = root }
        } else {
            header = UIHostingController(rootView: root)
            header.view.backgroundColor = .clear
            addChild(header)
            header.didMove(toParent: self)
            self.header = header
        }
        let height = header.sizeThatFits(in: CGSize(width: frameWidth, height: .greatestFiniteMagnitude)).height
        if tableView.tableHeaderView !== header.view || abs(header.view.frame.height - height) > 0.5 || abs(header.view.frame.width - frameWidth) > 0.5 {
            header.view.frame = CGRect(x: 0, y: 0, width: frameWidth, height: height)
            tableView.tableHeaderView = header.view
        }
    }

    // MARK: Model

    private func currentRows() -> ([Playlist], Set<UUID>) {
        let pinnedIDs = Set(libraryVM.orderedPinnedPlaylists.map(\.id))
        return (PlaylistListView.rows(libraryVM, sort: sortMode, search: searchText, hidesPinned: !isRearranging), pinnedIDs)
    }

    /// Follows changes made anywhere else: rows only removed or only added
    /// animate, anything else reloads.
    private func reloadFromModel() {
        let (newRows, newPinned) = currentRows()
        let oldIDs = rows.map(\.id)
        let newIDs = newRows.map(\.id)
        rows = newRows
        pinnedIDs = newPinned
        updateHeader()
        let section = Section.playlists.rawValue
        if oldIDs == newIDs {
            if let visible = tableView.indexPathsForVisibleRows?.filter({ $0.section == section }), !visible.isEmpty {
                tableView.reconfigureRows(at: visible)
            }
        } else if Set(newIDs).isSubset(of: oldIDs), oldIDs.filter(Set(newIDs).contains) == newIDs {
            let removed = oldIDs.indices.filter { !newIDs.contains(oldIDs[$0]) }
            tableView.deleteRows(at: removed.map { IndexPath(row: $0, section: section) }, with: .automatic)
        } else if Set(oldIDs).isSubset(of: newIDs), newIDs.filter(Set(oldIDs).contains) == oldIDs {
            let added = newIDs.indices.filter { !oldIDs.contains(newIDs[$0]) }
            tableView.insertRows(at: added.map { IndexPath(row: $0, section: section) }, with: .automatic)
        } else {
            tableView.reloadData()
        }
    }

    /// Slides the row to its new place, above the rows it passes.
    private func togglePin(_ id: UUID) {
        guard let from = rows.firstIndex(where: { $0.id == id }) else {
            libraryVM.togglePlaylistPin(id: id)
            return
        }
        libraryVM.togglePlaylistPin(id: id)
        let (newRows, newPinned) = currentRows()
        guard Set(newRows.map(\.id)) == Set(rows.map(\.id)),
              let to = newRows.firstIndex(where: { $0.id == id }) else {
            reloadFromModel()
            return
        }
        rows = newRows
        pinnedIDs = newPinned
        updateHeader()
        let section = Section.playlists.rawValue
        let source = IndexPath(row: from, section: section)
        let cell = tableView.cellForRow(at: source)
        if let cell { configure(cell, with: newRows[to]) }
        guard from != to else { return }
        cell?.layer.zPosition = 1
        tableView.performBatchUpdates {
            tableView.moveRow(at: source, to: IndexPath(row: to, section: section))
        } completion: { _ in
            cell?.layer.zPosition = 0
        }
    }

    // MARK: Cells

    private func configure(_ cell: UITableViewCell, with playlist: Playlist) {
        let zoomID = "playlist-row-\(playlist.id.uuidString)"
        let artwork = libraryVM.playlistArtwork(playlist)
        let isPinned = pinnedIDs.contains(playlist.id)
        cell.contentConfiguration = UIHostingConfiguration {
            HStack(spacing: 14) {
                TileArtwork(source: artwork, zoomID: zoomID, cornerRadius: 6, points: 56, placeholderSymbol: "music.note.list")
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(playlist.name)
                            .lineLimit(1)
                        if isPinned {
                            Image(systemName: "pin.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .accessibilityLabel("Pinned")
                        }
                    }
                    Text(PlaylistListView.detail(for: playlist))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
        .margins(.horizontal, 20)
        .margins(.vertical, 6)
        cell.accessoryType = isRearranging ? .none : .disclosureIndicator
        cell.showsReorderControl = isRearranging && isPinned
        cell.backgroundColor = .pageBackground
    }

    // MARK: Data source

    override func numberOfSections(in tableView: UITableView) -> Int {
        Section.allCases.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section) {
        case .playlists: rows.count
        case nil: 0
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: Self.cellID, for: indexPath)
        configure(cell, with: rows[indexPath.row])
        return cell
    }

    // MARK: Selection

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let playlist = rows[indexPath.row]
        router.open(.playlist(playlist.id, zoomSource: "playlist-row-\(playlist.id.uuidString)"))
    }

    // MARK: Swipes

    override func tableView(_ tableView: UITableView, leadingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard indexPath.section == Section.playlists.rawValue else { return nil }
        let id = rows[indexPath.row].id
        let isPinned = pinnedIDs.contains(id)
        let action = UIContextualAction(style: .normal, title: isPinned ? String(localized: "Unpin") : String(localized: "Pin")) { [weak self] _, _, done in
            self?.pendingPinToggle = id
            done(true)
        }
        action.image = UIImage(systemName: isPinned ? "pin.slash.fill" : "pin.fill")
        action.backgroundColor = .systemOrange
        return UISwipeActionsConfiguration(actions: [action])
    }

    override func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard indexPath.section == Section.playlists.rawValue else { return nil }
        let playlist = rows[indexPath.row]
        let action = UIContextualAction(style: .destructive, title: String(localized: "Delete")) { [weak self] _, _, done in
            self?.libraryVM.deletePlaylist(playlist)
            done(true)
        }
        action.image = UIImage(systemName: "trash")
        return UISwipeActionsConfiguration(actions: [action])
    }

    /// The swipe has closed: the row is back in place and can move (once
    /// the table has left its swipe editing state, on the next turn).
    override func tableView(_ tableView: UITableView, didEndEditingRowAt indexPath: IndexPath?) {
        guard let id = pendingPinToggle else { return }
        pendingPinToggle = nil
        DispatchQueue.main.async { [weak self] in self?.togglePin(id) }
    }

    // MARK: Rearranging

    override func tableView(_ tableView: UITableView, editingStyleForRowAt indexPath: IndexPath) -> UITableViewCell.EditingStyle {
        isRearranging ? .none : .delete
    }

    override func tableView(_ tableView: UITableView, shouldIndentWhileEditingRowAt indexPath: IndexPath) -> Bool {
        false
    }

    override func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool {
        isRearranging && indexPath.section == Section.playlists.rawValue && pinnedIDs.contains(rows[indexPath.row].id)
    }

    /// Pinned rows stay among the pinned ones.
    override func tableView(_ tableView: UITableView, targetIndexPathForMoveFromRowAt source: IndexPath, toProposedIndexPath proposed: IndexPath) -> IndexPath {
        let lastPinned = rows.filter { pinnedIDs.contains($0.id) }.count - 1
        let row = proposed.section == Section.playlists.rawValue ? min(proposed.row, lastPinned) : lastPinned
        return IndexPath(row: max(0, row), section: Section.playlists.rawValue)
    }

    override func tableView(_ tableView: UITableView, moveRowAt source: IndexPath, to destination: IndexPath) {
        guard source != destination else { return }
        rows.insert(rows.remove(at: source.row), at: destination.row)
        libraryVM.movePinnedPlaylists(
            fromOffsets: IndexSet(integer: source.row),
            toOffset: destination.row > source.row ? destination.row + 1 : destination.row
        )
    }

    // MARK: Context menu

    override func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        guard indexPath.section == Section.playlists.rawValue, !isRearranging else { return nil }
        let playlist = rows[indexPath.row]
        return fixedContextMenu(identifier: playlist.id as NSUUID, previewProvider: nil) { [weak self] _ in
            self?.menu(for: playlist)
        }
    }

    override func tableView(_ tableView: UITableView, willEndContextMenuInteraction configuration: UIContextMenuConfiguration, animator: UIContextMenuInteractionAnimating?) {
        guard let id = pendingPinToggle else { return }
        pendingPinToggle = nil
        if let animator {
            animator.addCompletion { [weak self] in self?.togglePin(id) }
        } else {
            togglePin(id)
        }
    }

    /// The same menu as the playlist tiles' (`HomeItemMenu`).
    private func menu(for playlist: Playlist) -> UIMenu {
        let libraryVM = libraryVM
        let playerVM = playerVM
        let isPinned = pinnedIDs.contains(playlist.id)
        let play = UIMenu(options: .displayInline, children: [
            UIAction(title: String(localized: "Play"), image: UIImage(systemName: "play")) { _ in playerVM.playPlaylist(playlist) },
            UIAction(title: String(localized: "Shuffle"), image: UIImage(systemName: "shuffle")) { _ in playerVM.playPlaylist(playlist, shuffled: true) }
        ])
        let more = UIMenu(options: .displayInline, children: [
            UIAction(title: isPinned ? String(localized: "Unpin") : String(localized: "Pin"), image: UIImage(systemName: isPinned ? "pin.slash" : "pin")) { [weak self] _ in
                self?.pendingPinToggle = playlist.id
            },
            UIAction(title: String(localized: "Covers Snake"), image: UIImage(systemName: "square.grid.3x3")) { _ in
                libraryVM.presentCoversSnake(title: playlist.name, songs: libraryVM.songs(in: playlist))
            }
        ])
        let edit = UIMenu(options: .displayInline, children: [
            playlist.isAutolist
                ? UIAction(title: String(localized: "Edit Autolist"), image: UIImage(systemName: "slider.horizontal.3")) { _ in libraryVM.requestEdit(of: playlist) }
                : UIAction(title: String(localized: "Edit Playlist"), image: UIImage(systemName: "pencil")) { _ in libraryVM.requestEdit(ofPlaylist: playlist) }
        ])
        let delete = UIMenu(options: .displayInline, children: [
            UIAction(title: playlist.isAutolist ? String(localized: "Delete Autolist") : String(localized: "Delete Playlist"), image: UIImage(systemName: "trash")?.withTintColor(.menuDestructive, renderingMode: .alwaysOriginal), attributes: .destructive) { _ in
                libraryVM.deletePlaylist(playlist)
            }
        ])
        return UIMenu(children: [delete, play, more, edit])
    }
}
