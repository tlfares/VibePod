import SwiftUI
import UIKit
import Combine

struct PlaylistDetailView: View {
    let playlistID: UUID
    @EnvironmentObject private var libraryVM: LibraryViewModel
    @EnvironmentObject private var playerVM: PlayerViewModel
    @EnvironmentObject private var router: AppRouter
    @State private var isEditing = false
    @State private var showDeleteConfirmation = false
    @State private var refreshReview: RefreshReviewItem?
    @State private var refreshError: String?
    @State private var isRefreshing = false
    @State private var filterMode: PlaylistFilterMode

    init(playlistID: UUID) {
        self.playlistID = playlistID
        _filterMode = State(initialValue: PlaylistFilterMode.mode(for: playlistID))
    }

    var body: some View {
        if let playlist = libraryVM.playlist(withID: playlistID) {
            let songs = libraryVM.songs(in: playlist)
            PlaylistDetailRepresentable(playlist: playlist, songs: songs, isEditing: isEditing, filterMode: filterMode)
                .ignoresSafeArea()
                .background(Color(uiColor: PlaylistDetailViewController.accentColor(for: playlist, firstSong: songs.first)))
                .pageTitle("", large: false)
                .pageTrailingItem { barItems(for: playlist) }
                .environment(\.colorScheme, .dark)
                .confirmationDialog("Delete “\(playlist.name)”?", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
                    Button(playlist.isAutolist ? "Delete Autolist" : "Delete Playlist", role: .destructive) {
                        router.pop()
                        libraryVM.deletePlaylist(playlist)
                    }
                } message: {
                    Text("The songs stay in your library.")
                }
                .sheet(item: $refreshReview) { item in
                    SpotifyMatchReviewSheet(
                        session: item.session,
                        localSongs: libraryVM.songs,
                        isExisting: true,
                        onConfirm: { updated in
                            Task {
                                let artwork = await SpotifyService.coverArtworkData(from: updated.playlist)
                                libraryVM.libraryService.updateImportedPlaylist(id: playlist.id, session: updated, artworkDataOverride: artwork)
                            }
                        },
                        onDismiss: { refreshReview = nil }
                    )
                }
                .alert("Refresh Failed", isPresented: Binding(get: { refreshError != nil }, set: { if !$0 { refreshError = nil } })) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(refreshError ?? "")
                }
        } else {
            ContentUnavailableView("Playlist Unavailable", systemImage: "music.note.list")
        }
    }

    @ViewBuilder
    private func barItems(for playlist: Playlist) -> some View {
        if isEditing {
            Button {
                withAnimation { isEditing = false }
            } label: {
                BarIcon("Done", systemImage: "checkmark")
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        } else if playlist.isAutolist {
            autolistMenu(for: playlist)
        } else {
            Menu {
                    Section {
                        Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") {
                            libraryVM.songs(in: playlist).forEach { playerVM.addNextToQueue(song: $0) }
                        }
                        Button(libraryVM.isPlaylistPinned(id: playlist.id) ? "Unpin" : "Pin", systemImage: libraryVM.isPlaylistPinned(id: playlist.id) ? "pin.slash" : "pin") {
                            libraryVM.togglePlaylistPin(id: playlist.id)
                        }
                    }
                    Section {
                        Button("Edit Playlist", systemImage: "pencil") {
                            libraryVM.requestEdit(ofPlaylist: playlist)
                        }
                        Button("Reorder Songs", systemImage: "arrow.up.arrow.down") {
                            withAnimation { isEditing = true }
                        }
                        Menu("Sort By", systemImage: "line.3.horizontal.decrease") {
                            Picker("Sort By", selection: Binding(
                                get: { playlist.sortOrder },
                                set: { libraryVM.setPlaylistSortOrder(playlist, order: $0) }
                            )) {
                                ForEach(PlaylistSortOrder.allCases, id: \.self) { order in
                                    Label(order.title, systemImage: order.systemImage).tag(order)
                                }
                            }
                        }
                        filterMenu
                        if playlist.importSource != nil {
                            Button("Refresh from Spotify", systemImage: "arrow.clockwise") {
                                refresh(playlist)
                            }
                            .disabled(isRefreshing)
                        }
                    }
                    Section {
                        Menu("Add to Playlist", systemImage: "text.badge.plus") {
                            Button("New Playlist…", systemImage: "plus") {
                                libraryVM.requestNewPlaylist(adding: libraryVM.songs(in: playlist))
                            }
                            ForEach(libraryVM.editablePlaylists.filter { $0.id != playlist.id }) { target in
                                Button(target.name) {
                                    libraryVM.addToPlaylist(songs: libraryVM.songs(in: playlist), playlistId: target.id)
                                }
                            }
                        }
                        Button("Covers Snake", systemImage: "square.grid.3x3") {
                            libraryVM.presentCoversSnake(title: playlist.name, songs: libraryVM.songs(in: playlist))
                        }
                    }
                    Section {
                        Button(role: .destructive) {
                            showDeleteConfirmation = true
                        } label: {
                            DestructiveLabel(playlist.isAutolist ? "Delete Autolist" : "Delete Playlist", systemImage: "trash")
                        }
                    }
            } label: {
                BarIcon("More", systemImage: "ellipsis")
                    .foregroundStyle(.white)
            }
            .tint(.menuTint(from: PlaylistDetailViewController.accentColor(for: playlist, firstSong: libraryVM.songs(in: playlist).first)))
        }
    }

    /// The Cover Flow of artists, years or genres above the songs.
    private var filterMenu: some View {
        Menu("Filter Row", systemImage: "rectangle.stack") {
            Picker("Filter Row", selection: Binding(
                get: { filterMode },
                set: { mode in
                    filterMode = mode
                    PlaylistFilterMode.setMode(mode, for: playlistID)
                }
            )) {
                ForEach(PlaylistFilterMode.allCases) { mode in
                    Label(mode.title, systemImage: mode.systemImage).tag(mode)
                }
            }
        }
    }

    private func autolistMenu(for playlist: Playlist) -> some View {
        Menu {
            Section {
                Button("Delete Autolist", destructiveImage: "trash") {
                    showDeleteConfirmation = true
                }
            }
            Section {
                Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") {
                    libraryVM.songs(in: playlist).forEach { playerVM.addNextToQueue(song: $0) }
                }
                Button(libraryVM.isPlaylistPinned(id: playlist.id) ? "Unpin" : "Pin", systemImage: libraryVM.isPlaylistPinned(id: playlist.id) ? "pin.slash" : "pin") {
                    libraryVM.togglePlaylistPin(id: playlist.id)
                }
            }
            Section {
                Button("Edit Autolist", systemImage: "slider.horizontal.3") {
                    libraryVM.requestEdit(of: playlist)
                }
                // Instant Autolists are always up to date.
                if playlist.autolist?.refresh != .instant {
                    Button("Refresh Autolist", systemImage: "arrow.clockwise") {
                        libraryVM.refreshAutolist(id: playlist.id)
                    }
                }
                filterMenu
                if playlist.autolist?.effectiveOrder == .shuffled {
                    Button(playlist.autolist?.selection == .random ? "New Pick" : "Shuffle Again", systemImage: "shuffle") {
                        libraryVM.reshuffleAutolist(id: playlist.id)
                    }
                }
            }
            Section {
                Button("Covers Snake", systemImage: "square.grid.3x3") {
                    libraryVM.presentCoversSnake(title: playlist.name, songs: libraryVM.songs(in: playlist))
                }
            }
        } label: {
            BarIcon("More", systemImage: "ellipsis")
                .foregroundStyle(.white)
        }
        .menuOrder(.fixed)
        .tint(.menuTint(from: PlaylistDetailViewController.accentColor(for: playlist, firstSong: libraryVM.songs(in: playlist).first)))
    }

    private func refresh(_ playlist: Playlist) {
        guard let importSource = playlist.importSource else { return }
        isRefreshing = true
        Task {
            defer { isRefreshing = false }
            do {
                let remote = try await SpotifyService.fetchPlaylist(from: importSource.url)
                let session = SpotifyMatcher.makeSession(
                    from: importSource.url,
                    playlist: remote,
                    localSongs: libraryVM.songs,
                    existingMatches: importSource.matches
                )
                refreshReview = RefreshReviewItem(session: session)
            } catch {
                refreshError = error.localizedDescription
            }
        }
    }
}

private struct RefreshReviewItem: Identifiable {
    let id = UUID()
    let session: SpotifyMatchSession
}

private struct PlaylistDetailRepresentable: UIViewControllerRepresentable {
    let playlist: Playlist
    let songs: [Song]
    let isEditing: Bool
    let filterMode: PlaylistFilterMode
    @Environment(\.appServices) private var services

    func makeUIViewController(context: Context) -> CollectionSplitController<PlaylistDetailViewController> {
        CollectionSplitController(page: PlaylistDetailViewController(libraryVM: services.libraryVM, playerVM: services.playerVM, router: services.router))
    }

    func updateUIViewController(_ split: CollectionSplitController<PlaylistDetailViewController>, context: Context) {
        let controller = split.page
        controller.configure(playlist: playlist, songs: songs, filterMode: filterMode)
        // Compared with the reorder mode, not `isEditing`: a row's swipe
        // also flips `isEditing`, and resetting it reset the filter too.
        if controller.isReordering != isEditing {
            controller.isReordering = isEditing
            controller.setEditing(isEditing, animated: true)
        }
    }
}

final class PlaylistDetailViewController: UITableViewController, SplitCollectionPage {
    private let libraryVM: LibraryViewModel
    private let playerVM: PlayerViewModel
    private let router: AppRouter
    private let headerView = PlaylistDetailHeaderView()
    private let fullScreenHeader = FullScreenArtworkHeaderView()
    private var isFullScreen = CollectionHeaderStyle.isFullScreen
    private var activeHeader: UIView { isFullScreen ? fullScreenHeader : headerView }
    /// Holds the header and, under it, the filter row.
    private let headerContainer = UIView()
    private let filterRow = PlaylistFilterRowView()
    private lazy var filterRowHeight = filterRow.heightAnchor.constraint(equalToConstant: 0)
    private var playlist: Playlist?
    /// The whole playlist; `songs` is what the filter row leaves of it.
    private var allSongs: [Song] = []
    private var songs: [Song] = []
    private var filterMode = PlaylistFilterMode.off
    private var filterEntries: [PlaylistFilterEntry] = []
    private var filterIndex = 0
    private var accentColor = UIColor(white: 0.16, alpha: 1)
    private var renderedToken: Int?
    private var cancellables = Set<AnyCancellable>()
    private static let addSongsCellID = "PlaylistAddSongsCell"
    /// The header stands beside the songs (`CollectionSplitController`); the
    /// filter row stays on top of them.
    private var isSplit = false
    private lazy var splitFilterTop = filterRow.topAnchor.constraint(equalTo: headerContainer.topAnchor, constant: 8)
    /// What the header was last sized for: the table lays out on every
    /// scroll frame, and measuring it each time cost frames.
    private var sizedFor: CollectionHeaderSizeKey?
    var splitHeader: FullScreenArtworkHeaderView { fullScreenHeader }

    func setSplit(_ split: Bool) {
        isSplit = split
        fullScreenHeader.removeFromSuperview()
        fullScreenHeader.stretch = 0
        splitFilterTop.isActive = split
        tableView.topEdgeEffect.isHidden = false
        sizeHeader(force: true)
        if !split, isFullScreen { fullScreenHeader.followScroll(of: tableView) }
    }

    init(libraryVM: LibraryViewModel, playerVM: PlayerViewModel, router: AppRouter) {
        self.libraryVM = libraryVM
        self.playerVM = playerVM
        self.router = router
        super.init(style: .plain)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:)") }

    static func accentColor(for playlist: Playlist, firstSong: Song?) -> UIColor {
        if let palette = playlist.coverPalette { return palette.pageColor.uiColor }
        return accentColor(for: firstSong)
    }

    static func accentColor(for firstSong: Song?) -> UIColor {
        guard let firstSong, firstSong.artworkData != nil else { return UIColor(white: 0.16, alpha: 1) }
        return firstSong.albumBackgroundUIColor
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = .dark
        tableView.separatorColor = UIColor.white.withAlphaComponent(0.14)
        tableView.separatorInset = UIEdgeInsets(top: 0, left: 76, bottom: 0, right: 20)
        tableView.rowHeight = 60
        tableView.showsVerticalScrollIndicator = false
        tableView.allowsSelectionDuringEditing = false
        tableView.register(SongTableCell.self, forCellReuseIdentifier: SongTableCell.reuseID)
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: Self.addSongsCellID)

        let play: () -> Void = { [weak self] in
            guard let self, !self.songs.isEmpty else { return }
            self.playerVM.play(self.songs, shuffled: self.playerVM.shuffleMode == .on)
            if let id = self.playlist?.id { RecentPlayedStore.shared.record(playlistID: id) }
        }
        let shuffle: () -> Void = { [weak self] in
            self?.playerVM.toggleShuffle()
        }
        headerContainer.clipsToBounds = false
        filterRow.translatesAutoresizingMaskIntoConstraints = false
        filterRow.isHidden = true
        headerContainer.addSubview(filterRow)
        NSLayoutConstraint.activate([
            filterRow.leadingAnchor.constraint(equalTo: headerContainer.leadingAnchor),
            filterRow.trailingAnchor.constraint(equalTo: headerContainer.trailingAnchor),
            filterRow.bottomAnchor.constraint(equalTo: headerContainer.bottomAnchor),
            filterRowHeight
        ])
        filterRow.onSelect = { [weak self] index in self?.selectFilter(index) }

        headerView.onPlay = play
        headerView.onShuffle = shuffle
        fullScreenHeader.onPlay = play
        fullScreenHeader.onShuffle = shuffle
        playerVM.$shuffleMode.removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] mode in
                self?.headerView.setShuffle(isOn: mode == .on)
                self?.fullScreenHeader.setShuffle(isOn: mode == .on)
            }
            .store(in: &cancellables)

        playerVM.$currentSong.map { $0?.id }.removeDuplicates()
            .combineLatest(playerVM.$isPlaying.removeDuplicates())
            .dropFirst()
            .receive(on: DispatchQueue.main) // after willSet: the sink reads the model
            .sink { [weak self] _ in self?.refreshVisibleCells() }
            .store(in: &cancellables)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        adoptAsContentScrollView(tableView)
        updateHeaderStyle()
    }

    /// The style may have changed in Settings since this page was built, or
    /// the page turned sideways.
    private func updateHeaderStyle() {
        let fullScreen = CollectionHeaderStyle.isFullScreen(in: view.bounds.size)
        guard fullScreen != isFullScreen else { return }
        isFullScreen = fullScreen
        if !fullScreen { tableView.topEdgeEffect.isHidden = false }
        configureHeader()
        sizeHeader(force: true)
    }

    override func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard isFullScreen, !isSplit else { return }
        fullScreenHeader.followScroll(of: scrollView)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateHeaderStyle()
        sizeHeader()
        if let footer = tableView.tableFooterView, abs(footer.frame.width - tableView.bounds.width) > 0.5 {
            updateEmptyFooter()
        }
    }

    /// The Edit mode SwiftUI asked for (reordering), as opposed to a swipe.
    var isReordering = false

    override func setEditing(_ editing: Bool, animated: Bool) {
        // A row's swipe actions toggle editing too: leave the filter alone.
        guard editing == isReordering else {
            super.setEditing(editing, animated: animated)
            return
        }
        // Reordering moves songs within the whole playlist.
        if editing, filterIndex != 0 {
            filterIndex = 0
            filterRow.configure(entries: [], selected: 0)
            filterRow.configure(entries: filterEntries, selected: 0)
            songs = allSongs
            tableView.reloadData()
        }
        super.setEditing(editing, animated: animated)
        tableView.setEditing(editing, animated: animated)
        filterRow.isUserInteractionEnabled = !editing
        UIView.animate(withDuration: 0.25) { self.filterRow.alpha = editing ? 0.4 : 1 }
        // The "Add Songs" row hides while reordering.
        guard playlist?.isAutolist == false else { return }
        let addRow = IndexPath(row: songs.count, section: 0)
        if editing {
            tableView.deleteRows(at: [addRow], with: .fade)
        } else {
            tableView.insertRows(at: [addRow], with: .fade)
        }
    }

    func configure(playlist: Playlist, songs: [Song], filterMode: PlaylistFilterMode) {
        var hasher = Hasher()
        hasher.combine(filterMode)
        hasher.combine(playlist.id)
        hasher.combine(playlist.name)
        hasher.combine(playlist.artworkData?.count)
        hasher.combine(playlist.autolist)
        hasher.combine(playlist.cover)
        for song in songs {
            hasher.combine(song.id)
            hasher.combine(song.title)
            hasher.combine(song.lrcFilePath)
        }
        let token = hasher.finalize()
        guard token != renderedToken else { return }
        renderedToken = token
        self.playlist = playlist
        allSongs = songs
        accentColor = Self.accentColor(for: playlist, firstSong: songs.first)
        updateFilter(mode: filterMode)

        view.backgroundColor = accentColor
        tableView.backgroundColor = accentColor
        configureHeader()
        updateEmptyFooter()
        // The header column fits the title.
        if isSplit { parent?.view.setNeedsLayout() }
        // A reorder already moved the rows on screen: skip that one reload.
        let isEchoOfReorder = pendingReorderIDs == songs.map(\.id)
        pendingReorderIDs = nil
        if !isEchoOfReorder {
            tableView.reloadData()
        }
        sizeHeader(force: true)
    }

    private var pendingReorderIDs: [UUID]?

    private func configureHeader() {
        guard let playlist else { return }
        let songsDetail = Self.detailText(for: allSongs)
        let detail = playlist.isAutolist ? String(localized: "Autolist · \(songsDetail)") : songsDetail
        if isFullScreen {
            fullScreenHeader.setPageColor(accentColor)
            fullScreenHeader.configure(
                title: playlist.name,
                subtitle: nil,
                subtitleIsLink: false,
                detail: detail,
                artwork: libraryVM.playlistArtwork(playlist),
                placeholderSymbol: "music.note.list"
            )
        } else {
            headerView.setPageColor(accentColor)
            headerView.configure(name: playlist.name, artwork: libraryVM.playlistArtwork(playlist), detail: detail)
        }
    }

    /// Manual playlists end with an "Add Songs" row; Autolists fill themselves.
    private var showsAddRow: Bool { !isEditing && playlist?.isAutolist == false }

    /// An empty Autolist says why, instead of showing a blank page.
    private func updateEmptyFooter() {
        guard let rules = playlist?.autolist, songs.isEmpty else {
            tableView.tableFooterView = nil
            return
        }
        let label = UILabel()
        label.text = Self.emptyMessage(for: rules)
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.textColor = UIColor.white.withAlphaComponent(0.6)
        label.textAlignment = .center
        label.numberOfLines = 0
        let width = max(tableView.bounds.width, 120)
        let size = label.sizeThatFits(CGSize(width: width - 64, height: .greatestFiniteMagnitude))
        let footer = UIView(frame: CGRect(x: 0, y: 0, width: width, height: size.height + 48))
        label.frame = CGRect(x: 32, y: 24, width: width - 64, height: size.height)
        label.autoresizingMask = [.flexibleWidth]
        footer.addSubview(label)
        tableView.tableFooterView = footer
    }

    private static func emptyMessage(for rules: AutolistRules) -> String {
        switch rules.selection {
        case .mostPlayed, .recentlyPlayed:
            String(localized: "Songs show up here as you listen to them.")
        case .forgotten:
            String(localized: "Songs you loved but haven’t played in a month show up here.")
        case .workoutFavorites:
            WorkoutListening.isEnabled
                ? String(localized: "Songs you play during your workouts show up here.")
                : String(localized: "Turn on Workouts in Exclusive Features to fill this playlist.")
        case .energetic, .calm, .upTempo:
            LibrarySoundAnalysis.isUnlocked ? String(localized: "No songs match these rules right now.") : String(localized: "Analyze your library in Stats to fill this playlist.")
        case .leastPlayed, .recentlyAdded, .neverPlayed, .random:
            String(localized: "No songs match these rules right now.")
        }
    }

    /// Rebuilds the row's cards, keeping the one chosen while it still exists.
    private func updateFilter(mode: PlaylistFilterMode) {
        let previous = filterEntries[safe: filterIndex]?.kind
        filterMode = mode
        filterEntries = PlaylistFilterEntry.entries(for: allSongs, mode: mode, library: libraryVM.songs, tint: accentColor, palette: playlist?.coverPalette)
        // A row of "All" and one card filters nothing.
        if filterEntries.count < 3 { filterEntries = [] }
        filterIndex = previous.flatMap { kind in filterEntries.firstIndex { $0.kind == kind } } ?? 0
        filterRow.isHidden = filterEntries.isEmpty
        filterRowHeight.constant = filterEntries.isEmpty ? 0 : PlaylistFilterRowView.height
        filterRow.configure(entries: filterEntries, selected: filterIndex)
        songs = filteredSongs()
    }

    private func filteredSongs() -> [Song] {
        guard filterIndex > 0, let kept = filterEntries[safe: filterIndex]?.songIDs else { return allSongs }
        return allSongs.filter { kept.contains($0.id) }
    }

    private func selectFilter(_ index: Int) {
        guard index != filterIndex, !isEditing else { return }
        filterIndex = index
        songs = filteredSongs()
        // Only the rows fade: a crossfade of the whole table also froze the
        // filter row (in its header) under a snapshot while it slid.
        tableView.reloadSections(IndexSet(integer: 0), with: .fade)
    }

    /// The active header goes in the container, above the filter row.
    private func installHeader() {
        guard !isSplit else { return }
        let header = activeHeader
        guard header.superview !== headerContainer else { return }
        [headerView, fullScreenHeader].forEach { if $0 !== header { $0.removeFromSuperview() } }
        header.translatesAutoresizingMaskIntoConstraints = false
        headerContainer.insertSubview(header, at: 0)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: headerContainer.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: headerContainer.trailingAnchor),
            header.topAnchor.constraint(equalTo: headerContainer.topAnchor),
            header.bottomAnchor.constraint(equalTo: filterRow.topAnchor)
        ])
    }

    private func sizeHeader(force: Bool = false) {
        let width = tableView.bounds.width
        guard width > 0 else { return }
        installHeader()
        let header = headerContainer
        if isFullScreen, !isSplit {
            fullScreenHeader.topInset = tableView.adjustedContentInset.top
            fullScreenHeader.artworkHeight = CollectionHeaderStyle.artworkHeight(in: view.bounds.size)
        }
        let key = CollectionHeaderSizeKey(size: view.bounds.size, topInset: tableView.adjustedContentInset.top, isSplit: isSplit, category: traitCollection.preferredContentSizeCategory)
        guard force || key != sizedFor || tableView.tableHeaderView !== header else { return }
        sizedFor = key
        let height = header.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
        guard force || tableView.tableHeaderView !== header || abs(header.frame.height - height) > 0.5 || abs(header.frame.width - width) > 0.5 else { return }
        header.frame = CGRect(x: 0, y: 0, width: width, height: height)
        tableView.tableHeaderView = header
    }

    private static func detailText(for songs: [Song]) -> String {
        let minutes = Int(songs.reduce(0) { $0 + max(0, $1.duration) }) / 60
        let duration = minutes >= 60 ? String(localized: "\(minutes / 60) hr \(minutes % 60) min") : String(localized: "\(minutes) min")
        return String(localized: "\(songs.count) songs · \(duration)")
    }

    private func refreshVisibleCells() {
        for indexPath in tableView.indexPathsForVisibleRows ?? [] {
            guard let cell = tableView.cellForRow(at: indexPath) as? SongTableCell,
                  let song = songs[safe: indexPath.row] else { continue }
            configure(cell, with: song)
        }
    }

    private func configure(_ cell: SongTableCell, with song: Song) {
        let isCurrent = playerVM.currentSong?.id == song.id
        cell.configure(
            song: song,
            isCurrent: isCurrent,
            isPlaying: isCurrent && playerVM.isPlaying,
            lyricsBadge: LyricsBadge.image(for: song.lyricsKind),
            tint: .contentTint(from: accentColor)
        )
        cell.backgroundColor = accentColor
    }

    // MARK: Data source

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        songs.count + (showsAddRow ? 1 : 0)
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let song = songs[safe: indexPath.row] else {
            let cell = tableView.dequeueReusableCell(withIdentifier: Self.addSongsCellID, for: indexPath)
            var content = cell.defaultContentConfiguration()
            content.text = String(localized: "Add Songs")
            // The cover's color, like the "…" menu's icons.
            let tint = UIColor(Color.menuTint(from: accentColor))
            content.textProperties.color = tint
            content.image = UIImage(systemName: "plus")
            content.imageProperties.tintColor = tint
            content.imageProperties.reservedLayoutSize = CGSize(width: 44, height: 44)
            content.imageToTextPadding = 12
            cell.contentConfiguration = content
            cell.backgroundColor = accentColor
            return cell
        }
        let cell = tableView.dequeueReusableCell(withIdentifier: SongTableCell.reuseID, for: indexPath) as! SongTableCell
        configure(cell, with: song)
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let song = songs[safe: indexPath.row] else {
            presentAddSongs()
            return
        }
        playerVM.play(song: song, from: songs)
        if let id = playlist?.id { RecentPlayedStore.shared.record(playlistID: id) }
    }

    override func tableView(_ tableView: UITableView, leadingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        songs[safe: indexPath.row].map { SongMenuBuilder.queueSwipeAction(for: $0, playerVM: playerVM) }
    }

    override func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard let song = songs[safe: indexPath.row], let playlistID = playlist?.id, playlist?.isAutolist == false else { return nil }
        let remove = UIContextualAction(style: .destructive, title: String(localized: "Remove")) { [weak self] _, _, completion in
            self?.libraryVM.removeFromPlaylist(songId: song.id, playlistId: playlistID)
            completion(true)
        }
        remove.image = UIImage(systemName: "minus.circle")
        return UISwipeActionsConfiguration(actions: [remove])
    }

    override func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        guard let song = songs[safe: indexPath.row] else { return nil }
        let playlistID = playlist?.isAutolist == false ? playlist?.id : nil
        return fixedContextMenu(identifier: song.id as NSUUID, previewProvider: nil) { [weak self] _ in
            guard let self else { return nil }
            return SongMenuBuilder.menu(for: song, libraryVM: self.libraryVM, playerVM: self.playerVM, router: self.router, playlistContext: playlistID, tint: .contentTint(from: self.accentColor))
        }
    }

    override func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool {
        indexPath.row < songs.count && playlist?.isAutolist == false
    }

    override func tableView(_ tableView: UITableView, editingStyleForRowAt indexPath: IndexPath) -> UITableViewCell.EditingStyle {
        .none
    }

    override func tableView(_ tableView: UITableView, shouldIndentWhileEditingRowAt indexPath: IndexPath) -> Bool {
        false
    }

    override func tableView(_ tableView: UITableView, targetIndexPathForMoveFromRowAt sourceIndexPath: IndexPath, toProposedIndexPath proposedDestinationIndexPath: IndexPath) -> IndexPath {
        IndexPath(row: min(proposedDestinationIndexPath.row, songs.count - 1), section: 0)
    }

    override func tableView(_ tableView: UITableView, moveRowAt sourceIndexPath: IndexPath, to destinationIndexPath: IndexPath) {
        guard sourceIndexPath != destinationIndexPath,
              songs.indices.contains(sourceIndexPath.row), songs.indices.contains(destinationIndexPath.row),
              let playlistID = playlist?.id else { return }
        let song = songs.remove(at: sourceIndexPath.row)
        songs.insert(song, at: destinationIndexPath.row)
        pendingReorderIDs = songs.map(\.id)
        libraryVM.setPlaylistSongOrder(playlistId: playlistID, songIds: songs.map(\.id))
    }

    private func presentAddSongs() {
        guard let playlistID = playlist?.id else { return }
        let picker = PlaylistSongPickerViewController(
            songs: libraryVM.songs,
            existingIDs: Set(songs.map(\.id))
        ) { [weak self] selected in
            selected.forEach { self?.libraryVM.addToPlaylist(songId: $0.id, playlistId: playlistID) }
        }
        let navigationController = UINavigationController(rootViewController: picker)
        navigationController.view.tintColor = AppTint.current.uiColor
        navigationController.sheetPresentationController?.prefersGrabberVisible = true
        present(navigationController, animated: true)
    }
}

final class PlaylistDetailHeaderView: UIView {
    var onPlay: (() -> Void)?
    var onShuffle: (() -> Void)?

    private let artworkView = UIImageView()
    private let artworkShadow = UIView()
    private let nameLabel = UILabel()
    private let detailLabel = UILabel()
    private let artworkLoader = ArtworkImageLoader()
    private lazy var shuffleButton = ShuffleToggleButton { [weak self] in self?.onShuffle?() }

    override init(frame: CGRect) {
        super.init(frame: frame)

        artworkShadow.layer.shadowColor = UIColor.black.cgColor
        artworkShadow.layer.shadowOpacity = 0.35
        artworkShadow.layer.shadowRadius = 24
        artworkShadow.layer.shadowOffset = CGSize(width: 0, height: 12)

        artworkView.contentMode = .scaleAspectFill
        artworkView.clipsToBounds = true
        artworkView.layer.cornerRadius = 10
        artworkView.layer.cornerCurve = .continuous
        artworkView.backgroundColor = UIColor.white.withAlphaComponent(0.12)
        artworkView.tintColor = UIColor.white.withAlphaComponent(0.5)
        artworkView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 72, weight: .medium)
        artworkView.translatesAutoresizingMaskIntoConstraints = false
        artworkShadow.addSubview(artworkView)

        nameLabel.font = UIFont.preferredFont(forTextStyle: .title2).withWeight(.bold)
        nameLabel.textColor = .white
        nameLabel.textAlignment = .center
        nameLabel.numberOfLines = 2

        detailLabel.font = .preferredFont(forTextStyle: .subheadline)
        detailLabel.textColor = UIColor.white.withAlphaComponent(0.6)
        detailLabel.textAlignment = .center

        let play = SongListHeaderView.makeButton(title: String(localized: "Play"), systemImage: "play.fill", color: .white) { [weak self] in self?.onPlay?() }
        let buttons = UIStackView(arrangedSubviews: [play, shuffleButton])
        buttons.spacing = 12

        let textStack = UIStackView(arrangedSubviews: [nameLabel, detailLabel])
        textStack.axis = .vertical
        textStack.alignment = .center
        textStack.spacing = 4

        let stack = UIStackView(arrangedSubviews: [artworkShadow, textStack, buttons])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 18
        stack.setCustomSpacing(22, after: textStack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            artworkView.leadingAnchor.constraint(equalTo: artworkShadow.leadingAnchor),
            artworkView.trailingAnchor.constraint(equalTo: artworkShadow.trailingAnchor),
            artworkView.topAnchor.constraint(equalTo: artworkShadow.topAnchor),
            artworkView.bottomAnchor.constraint(equalTo: artworkShadow.bottomAnchor),
            artworkShadow.widthAnchor.constraint(equalToConstant: 260),
            artworkShadow.heightAnchor.constraint(equalToConstant: 260),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -20),
            textStack.widthAnchor.constraint(equalTo: stack.widthAnchor),
            // As wide as the artwork above, not the whole page.
            buttons.widthAnchor.constraint(equalTo: artworkShadow.widthAnchor),
            buttons.heightAnchor.constraint(equalToConstant: 48),
            shuffleButton.widthAnchor.constraint(equalTo: shuffleButton.heightAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:)") }

    func setShuffle(isOn: Bool) {
        shuffleButton.isOn = isOn
    }

    func setPageColor(_ color: UIColor) {
        shuffleButton.pageColor = color
    }

    func configure(name: String, artwork: ArtworkSource?, detail: String) {
        artworkLoader.load(artwork, into: artworkView, points: 260, placeholder: UIImage(systemName: "music.note.list"))
        nameLabel.text = name
        detailLabel.text = detail
    }
}

/// Multi-select song picker ("Add Songs" in a playlist).
final class PlaylistSongPickerViewController: UITableViewController, UISearchResultsUpdating {
    private let allSongs: [Song]
    private let existingIDs: Set<UUID>
    private let onAdd: ([Song]) -> Void
    private var filtered: [Song] = []
    private var selectedIDs = Set<UUID>()
    private let searchController = UISearchController(searchResultsController: nil)

    init(songs: [Song], existingIDs: Set<UUID>, onAdd: @escaping ([Song]) -> Void) {
        allSongs = songs.sorted { $0.title.libraryCompare($1.title) == .orderedAscending }
        self.existingIDs = existingIDs
        self.onAdd = onAdd
        super.init(style: .plain)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:)") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Add Songs")
        filtered = allSongs
        tableView.rowHeight = 60
        tableView.separatorInset = UIEdgeInsets(top: 0, left: 76, bottom: 0, right: 0)
        tableView.register(SongTableCell.self, forCellReuseIdentifier: SongTableCell.reuseID)
        tableView.keyboardDismissMode = .onDrag

        searchController.searchResultsUpdater = self
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchBar.placeholder = String(localized: "Search Library")
        navigationItem.searchController = searchController
        navigationItem.hidesSearchBarWhenScrolling = false

        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: String(localized: "Add"), primaryAction: UIAction { [weak self] _ in
            guard let self else { return }
            let selected = self.allSongs.filter { self.selectedIDs.contains($0.id) }
            self.onAdd(selected)
            self.dismiss(animated: true)
        })
        navigationItem.rightBarButtonItem?.style = .prominent
        updateAddButton()
    }

    func updateSearchResults(for searchController: UISearchController) {
        let text = searchController.searchBar.text ?? ""
        filtered = text.isEmpty ? allSongs : allSongs.filter {
            $0.title.localizedStandardContains(text) || $0.artist.localizedStandardContains(text) || $0.album.localizedStandardContains(text)
        }
        tableView.reloadData()
    }

    private func updateAddButton() {
        navigationItem.rightBarButtonItem?.isEnabled = !selectedIDs.isEmpty
        navigationItem.rightBarButtonItem?.title = selectedIDs.isEmpty ? String(localized: "Add") : String(localized: "Add (\(selectedIDs.count))")
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        filtered.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: SongTableCell.reuseID, for: indexPath) as! SongTableCell
        let song = filtered[indexPath.row]
        let alreadyIn = existingIDs.contains(song.id)
        cell.configure(song: song, isCurrent: false, isPlaying: false, lyricsBadge: nil, subtitle: alreadyIn ? String(localized: "\(song.artist) · In Playlist") : song.artist)
        cell.accessoryType = selectedIDs.contains(song.id) ? .checkmark : .none
        cell.tintColor = AppTint.current.uiColor
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let id = filtered[indexPath.row].id
        if selectedIDs.remove(id) == nil { selectedIDs.insert(id) }
        tableView.cellForRow(at: indexPath)?.accessoryType = selectedIDs.contains(id) ? .checkmark : .none
        updateAddButton()
    }
}
