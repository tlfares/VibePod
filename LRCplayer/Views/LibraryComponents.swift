import SwiftUI
import PhotosUI
import UIKit
import AVFoundation

// MARK: - Services

/// The app's long-lived models, reachable from UIKit bridges *without*
/// observing them (an `@EnvironmentObject` would re-run `updateUIViewController`
/// on every playback change).
struct AppServices: Equatable {
    let libraryVM: LibraryViewModel
    let playerVM: PlayerViewModel
    let router: AppRouter
    let importService: FileImportService

    static func == (lhs: AppServices, rhs: AppServices) -> Bool {
        lhs.libraryVM === rhs.libraryVM && lhs.playerVM === rhs.playerVM
            && lhs.router === rhs.router && lhs.importService === rhs.importService
    }
}

private struct AppServicesKey: EnvironmentKey {
    static let defaultValue: AppServices? = nil
}

extension EnvironmentValues {
    var appServicesStorage: AppServices? {
        get { self[AppServicesKey.self] }
        set { self[AppServicesKey.self] = newValue }
    }

    /// Always installed by `ContentView`.
    var appServices: AppServices {
        guard let services = appServicesStorage else {
            fatalError("AppServices missing from the environment")
        }
        return services
    }
}

// MARK: - Navigation

/// Artwork that a page zooms out of when it has a zoom ID.
struct TileArtwork: View {
    let source: ArtworkSource?
    var zoomID: String?
    var cornerRadius: CGFloat = 8
    var points: CGFloat = 180
    var placeholderSymbol = "music.note"

    var body: some View {
        if let zoomID {
            ZoomArtwork(id: zoomID, source: source, cornerRadius: cornerRadius, points: points, placeholderSymbol: placeholderSymbol)
        } else {
            ArtworkImage(source: source, cornerRadius: cornerRadius, points: points, placeholderSymbol: placeholderSymbol)
        }
    }
}

/// A tab's navigation stack (UIKit-backed, see `TabNavigationController`).
struct LibraryNavigationStack<Root: View>: View {
    let tab: AppTab
    @ViewBuilder let root: () -> Root

    var body: some View {
        TabNavigationHost(tab: tab, root: root)
            .ignoresSafeArea()
    }
}

/// A row or tile that opens a library page.
extension EnvironmentValues {
    /// Off while a pinch resizes the grid: lifting the fingers never opens
    /// the cover under them.
    @Entry var opensRoutes = true
    /// Set where pages stack somewhere other than the current tab (Stats
    /// opened from Settings).
    @Entry var routeOpener: (@MainActor (LibraryRoute) -> Void)? = nil
}

struct RouteLink<Label: View>: View {
    let route: LibraryRoute
    /// List rows get the disclosure chevron NavigationLink used to draw.
    var showsChevron = false
    @ViewBuilder let label: () -> Label
    /// The router unobserved: every link on screen redrew at each page
    /// pushed or tab picked.
    @Environment(\.appServicesStorage) private var services
    @Environment(\.opensRoutes) private var opensRoutes
    @Environment(\.routeOpener) private var routeOpener

    init(_ route: LibraryRoute, showsChevron: Bool = false, @ViewBuilder label: @escaping () -> Label) {
        self.route = route
        self.showsChevron = showsChevron
        self.label = label
    }

    var body: some View {
        Button {
            guard opensRoutes else { return }
            if let routeOpener {
                routeOpener(route)
            } else {
                services?.router.open(route)
            }
        } label: {
            if showsChevron {
                HStack {
                    label()
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            } else {
                label()
            }
        }
        .foregroundStyle(.primary)
    }
}

struct LibraryDestinationView: View {
    let route: LibraryRoute

    var body: some View {
        switch route {
        case .playlists:
            PlaylistListView()
        case .albums:
            AlbumGridView()
        case let .album(id, _):
            AlbumDetailView(albumID: id)
        case let .artist(name):
            ArtistDetailView(artistName: name)
        case let .artistAlbums(name):
            AlbumGridView(artistName: name)
        case let .playlist(id, _):
            PlaylistDetailView(playlistID: id)
        case let .genre(name):
            GenreDetailView(genreName: name)
        case .allSongs:
            AllSongsView()
        case let .lyricsSongs(kind):
            LyricsSongsView(kind: kind)
        case let .collectionAlbums(collection):
            CollectionAlbumsView(collection: collection)
        }
    }
}

// MARK: - Tiles

/// Grid / shelf tile: square artwork with title and subtitle, Apple Music style.
struct ArtworkTile: View {
    let title: String
    let subtitle: String
    let artwork: ArtworkSource?
    var zoomID: String?
    var placeholderSymbol = "music.note"
    var width: CGFloat?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TileArtwork(source: artwork, zoomID: zoomID, cornerRadius: 8, points: width ?? 180, placeholderSymbol: placeholderSymbol)
                .aspectRatio(1, contentMode: .fit)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(width: width)
        .contentShape(Rectangle())
    }
}

struct AlbumTile: View {
    let album: Album
    var zoomID: String?
    var width: CGFloat?

    var body: some View {
        ArtworkTile(
            title: album.title,
            subtitle: album.artist,
            artwork: album.artworkSource,
            zoomID: zoomID,
            width: width
        )
    }
}

struct PlaylistTile: View {
    let playlist: Playlist
    var zoomID: String?
    var width: CGFloat?
    @EnvironmentObject private var libraryVM: LibraryViewModel

    var body: some View {
        ArtworkTile(
            title: playlist.name,
            subtitle: playlist.isAutolist ? String(localized: "Autolist") : String(localized: "Playlist"),
            artwork: libraryVM.playlistArtwork(playlist),
            zoomID: zoomID,
            placeholderSymbol: "music.note.list",
            width: width
        )
    }
}

// MARK: - Rows

/// SwiftUI song row (search results, artist pages).
extension EnvironmentValues {
    /// The page's content colour (playlist, album, artist, genre): song menus
    /// and the playing title use it instead of each song's own cover.
    @Entry var pageTint: UIColor?
}

struct SongRow: View {
    let song: Song
    var showsArtwork = true
    var subtitle: String?
    /// Shown in place of the artwork, as in an album.
    var trackNumber: Int?
    /// Off where the row can't be the playing one even if it's the same song
    /// (a second copy of it later in the queue).
    var highlightsCurrent = true
    @EnvironmentObject private var playerVM: PlayerViewModel
    @Environment(\.pageTint) private var pageTint

    var body: some View {
        let isCurrent = highlightsCurrent && playerVM.currentSong?.id == song.id
        HStack(spacing: 12) {
            if let trackNumber {
                Text(trackNumber > 0 ? "\(trackNumber)" : "")
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 24, alignment: .trailing)
            } else if showsArtwork {
                ArtworkImage(source: song.artworkSource, cornerRadius: 5, points: 44)
                    .frame(width: 44, height: 44)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .font(.body)
                    .foregroundStyle(isCurrent ? Color(uiColor: pageTint ?? song.coverSheetTint) : .primary)
                    .lineLimit(1)
                Text(subtitle ?? song.artist)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if let badge = LyricsBadge.image(for: song.lyricsKind) {
                Image(uiImage: badge)
                    .renderingMode(.template)
                    .foregroundStyle(.tertiary)
            }
            if isCurrent {
                Image(systemName: playerVM.isPlaying ? "waveform" : "speaker.fill")
                    .symbolEffect(.variableColor.iterative, isActive: playerVM.isPlaying)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color(uiColor: pageTint ?? song.coverSheetTint))
            }
        }
        .contentShape(Rectangle())
    }
}

/// Play / Shuffle capsule pair used at the top of song lists.
struct PlayShuffleButtons: View {
    let songs: [Song]
    @EnvironmentObject private var playerVM: PlayerViewModel

    var body: some View {
        HStack(spacing: 12) {
            Button {
                playerVM.play(songs, shuffled: false)
            } label: {
                Label("Play", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            Button {
                playerVM.play(songs, shuffled: true)
            } label: {
                Label("Shuffle", systemImage: "shuffle")
                    .frame(maxWidth: .infinity)
            }
        }
        .font(.headline)
        .buttonStyle(.glass)
        .controlSize(.large)
        .disabled(songs.isEmpty)
    }
}

// MARK: - Song menus

/// One definition of the song context menu (SwiftUI). UIKit tables use
/// `SongMenuBuilder`, which mirrors it.
struct SongContextMenu: View {
    let song: Song
    var playlistContext: Playlist?
    /// Search only: everything known about the song.
    var onInfo: (() -> Void)?
    @EnvironmentObject private var libraryVM: LibraryViewModel
    @EnvironmentObject private var playerVM: PlayerViewModel
    @EnvironmentObject private var router: AppRouter

    @Environment(\.pageTint) private var pageTint

    private var tint: UIColor { pageTint ?? song.coverSheetTint }

    var body: some View {
        Group { content }
            .tint(Color(uiColor: tint))
    }

    @ViewBuilder private var content: some View {
        // Destructive rows sit together at the top, the far end from the finger.
        Section {
            if song.lrcFilePath != nil {
                Button(LyricsGenerator.isGenerated(storedPath: song.lrcFilePath) ? String(localized: "Delete AI Lyrics") : String(localized: "Remove LRC"), destructiveImage: "text.badge.xmark") {
                    libraryVM.libraryService.removeLRCLyrics(for: song)
                }
            }
            if let playlist = playlistContext, !playlist.isAutolist {
                Button("Remove from Playlist", destructiveImage: "minus.circle") {
                    libraryVM.removeFromPlaylist(songId: song.id, playlistId: playlist.id)
                }
            }
            if song.isDownloaded {
                Button("Remove Download", destructiveImage: "arrow.down.circle.dotted") {
                    SubsonicDownloads.shared.removeDownloads([song])
                }
            }
            // Server songs come back with the next sync: only their download goes.
            if !song.isRemote {
                Button("Delete from Library", destructiveImage: "trash") {
                    libraryVM.deleteSong(song)
                }
            }
        }
        Section {
            if song.isRemote, !song.isDownloaded, !SubsonicDownloads.shared.isPending(song) {
                Button("Download", systemImage: "arrow.down.circle") {
                    SubsonicDownloads.shared.download([song])
                }
            }
            Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") {
                playerVM.addNextToQueue(song: song)
            }
            Button("Play Last", systemImage: "text.line.last.and.arrowtriangle.forward") {
                playerVM.addToQueue(song: song)
            }
        }
        Section {
            Menu {
                Button("New Playlist…", systemImage: "plus") {
                    libraryVM.requestNewPlaylist(adding: song)
                }
                ForEach(libraryVM.editablePlaylists) { playlist in
                    Button(playlist.name) {
                        libraryVM.addToPlaylist(songId: song.id, playlistId: playlist.id)
                    }
                }
            } label: {
                // A submenu's icon ignores the tint: colour the image itself.
                Label {
                    Text("Add to Playlist")
                } icon: {
                    if let image = UIImage(systemName: "text.badge.plus")?.withTintColor(tint, renderingMode: .alwaysOriginal) {
                        Image(uiImage: image)
                    }
                }
            }
            if let album = libraryVM.album(containing: song), !album.isSingle {
                Button("Go to Album", systemImage: "square.stack") {
                    router.open(.album(album.id))
                }
            }
            if let artist = libraryVM.artist(for: song) {
                Button("Go to Artist", systemImage: "music.microphone") {
                    router.open(.artist(artist.name))
                }
            }
        }
        Section {
            if let onInfo {
                Button("Info", systemImage: "info.circle", action: onInfo)
            }
            if !song.isMediaLibraryItem, !song.isRemote {
                Button("Edit Info…", systemImage: "pencil") { libraryVM.songEditor = song }
            }
            if !song.isMediaLibraryItem, song.hasLocalAudio {
                Button("Share Song…", systemImage: "square.and.arrow.up") { SongExporter.share(song) }
            }
            Button("Associate LRC…", systemImage: "text.quote") {
                libraryVM.beginLyricsAssociation(for: song)
                router.importer = .lyricsFile
            }
        }
    }
}

@MainActor
enum SongMenuBuilder {
    static func menu(
        for song: Song,
        libraryVM: LibraryViewModel?,
        playerVM: PlayerViewModel?,
        router: AppRouter?,
        showsAlbum: Bool = true,
        playlistContext: UUID? = nil,
        tint pageTint: UIColor? = nil
    ) -> UIMenu {
        let tint = pageTint ?? song.coverSheetTint
        var queueActions: [UIMenuElement] = [
            UIAction(title: String(localized: "Play Next"), image: UIImage(systemName: "text.line.first.and.arrowtriangle.forward")) { [weak playerVM] _ in
                playerVM?.addNextToQueue(song: song)
            },
            UIAction(title: String(localized: "Play Last"), image: UIImage(systemName: "text.line.last.and.arrowtriangle.forward")) { [weak playerVM] _ in
                playerVM?.addToQueue(song: song)
            }
        ]
        guard let libraryVM else { return UIMenu(children: queueActions) }

        var libraryActions: [UIMenuElement] = []
        let downloads = SubsonicDownloads.shared
        if song.isRemote, !song.isDownloaded {
            if downloads.isPending(song) {
                libraryActions.append(UIAction(title: String(localized: "Cancel Download"), image: UIImage(systemName: "xmark.circle")) { _ in
                    downloads.cancel([song])
                })
            } else {
                libraryActions.append(UIAction(title: String(localized: "Download"), image: UIImage(systemName: "arrow.down.circle")) { _ in
                    downloads.download([song])
                })
            }
        }
        let newPlaylist = UIAction(title: String(localized: "New Playlist…"), image: UIImage(systemName: "plus")) { [weak libraryVM] _ in
            libraryVM?.requestNewPlaylist(adding: song)
        }
        let playlistActions = libraryVM.editablePlaylists.map { playlist in
            UIAction(title: playlist.name) { [weak libraryVM] _ in
                libraryVM?.addToPlaylist(songId: song.id, playlistId: playlist.id)
            }
        }
        libraryActions.append(UIMenu(
            title: String(localized: "Add to Playlist"),
            image: UIImage(systemName: "text.badge.plus")?.withTintColor(tint, renderingMode: .alwaysOriginal),
            children: [UIMenu(options: .displayInline, children: [newPlaylist])] + playlistActions
        ))
        if showsAlbum, let album = libraryVM.album(containing: song), !album.isSingle {
            libraryActions.append(UIAction(title: String(localized: "Go to Album"), image: UIImage(systemName: "square.stack")) { [weak router] _ in
                router?.open(.album(album.id))
            })
        }
        if let artist = libraryVM.artist(for: song) {
            libraryActions.append(UIAction(title: String(localized: "Go to Artist"), image: UIImage(systemName: "music.microphone")) { [weak router] _ in
                router?.open(.artist(artist.name))
            })
        }

        var lyricsActions: [UIMenuElement] = []
        if !song.isMediaLibraryItem, !song.isRemote {
            lyricsActions.append(UIAction(title: String(localized: "Edit Info…"), image: UIImage(systemName: "pencil")) { [weak libraryVM] _ in
                libraryVM?.songEditor = song
            })
        }
        if !song.isMediaLibraryItem, song.hasLocalAudio {
            lyricsActions.append(UIAction(title: String(localized: "Share Song…"), image: UIImage(systemName: "square.and.arrow.up")) { _ in
                SongExporter.share(song)
            })
        }
        lyricsActions += [
            UIAction(title: String(localized: "Associate LRC…"), image: UIImage(systemName: "text.quote")) { [weak libraryVM, weak router] _ in
                libraryVM?.beginLyricsAssociation(for: song)
                router?.importer = .lyricsFile
            }
        ]
        var destructive: [UIMenuElement] = []
        if song.lrcFilePath != nil {
            destructive.append(UIAction(title: LyricsGenerator.isGenerated(storedPath: song.lrcFilePath) ? String(localized: "Delete AI Lyrics") : String(localized: "Remove LRC"), image: UIImage(systemName: "text.badge.xmark")?.withTintColor(.menuDestructive, renderingMode: .alwaysOriginal), attributes: .destructive) { [weak libraryVM] _ in
                libraryVM?.libraryService.removeLRCLyrics(for: song)
            })
        }

        if let playlistContext {
            destructive.append(UIAction(title: String(localized: "Remove from Playlist"), image: UIImage(systemName: "minus.circle")?.withTintColor(.menuDestructive, renderingMode: .alwaysOriginal), attributes: .destructive) { [weak libraryVM] _ in
                libraryVM?.removeFromPlaylist(songId: song.id, playlistId: playlistContext)
            })
        }
        if song.isDownloaded {
            destructive.append(UIAction(title: String(localized: "Remove Download"), image: UIImage(systemName: "arrow.down.circle.dotted")?.withTintColor(.menuDestructive, renderingMode: .alwaysOriginal), attributes: .destructive) { _ in
                downloads.removeDownloads([song])
            })
        }
        // Server songs come back with the next sync: only their download goes.
        if !song.isRemote {
            destructive.append(UIAction(title: String(localized: "Delete from Library"), image: UIImage(systemName: "trash")?.withTintColor(.menuDestructive, renderingMode: .alwaysOriginal), attributes: .destructive) { [weak libraryVM] _ in
                libraryVM?.deleteSong(song)
            })
        }

        queueActions = [UIMenu(options: .displayInline, children: queueActions)]
        func tinted(_ elements: [UIMenuElement]) -> [UIMenuElement] {
            elements.map { element in
                if let menu = element as? UIMenu {
                    return menu.replacingChildren(tinted(menu.children))
                }
                if let action = element as? UIAction, !action.attributes.contains(.destructive), let image = action.image {
                    action.image = image.withTintColor(tint, renderingMode: .alwaysOriginal)
                }
                return element
            }
        }
        queueActions = tinted(queueActions)
        libraryActions = tinted(libraryActions)
        lyricsActions = tinted(lyricsActions)
        return UIMenu(children: [UIMenu(options: .displayInline, children: destructive)] + queueActions + [
            UIMenu(options: .displayInline, children: libraryActions),
            UIMenu(options: .displayInline, children: lyricsActions)
        ])
    }

    /// Swiping a song left: what Settings › Home picked (Go to Album by
    /// default). None where it would lead to the page already open.
    static func swipeLeftAction(for song: Song, libraryVM: LibraryViewModel?, playerVM: PlayerViewModel?, router: AppRouter?, context: SongSwipeAction.Context) -> UIContextualAction? {
        guard let target = SongSwipeAction.current.target(for: song, libraryVM: libraryVM, context: context) else { return nil }
        let action = UIContextualAction(style: .normal, title: target.title) { [weak playerVM, weak router] _, _, completion in
            completion(true)
            // Once the row has closed.
            DispatchQueue.main.async { target.perform(playerVM: playerVM, router: router) }
        }
        action.backgroundColor = target.color
        action.image = UIImage(systemName: target.symbol)
        return action
    }

    static func swipeLeftConfiguration(for song: Song, libraryVM: LibraryViewModel?, playerVM: PlayerViewModel?, router: AppRouter?, context: SongSwipeAction.Context) -> UISwipeActionsConfiguration {
        let actions = [swipeLeftAction(for: song, libraryVM: libraryVM, playerVM: playerVM, router: router, context: context)].compactMap { $0 }
        let configuration = UISwipeActionsConfiguration(actions: actions)
        configuration.performsFirstActionWithFullSwipe = true
        return configuration
    }

    /// Swiping a song right: a single "Add to Queue". Songs added this way
    /// play right after the current one, in the order they were added.
    static func queueSwipeAction(for song: Song, playerVM: PlayerViewModel?) -> UISwipeActionsConfiguration {
        let addToQueue = UIContextualAction(style: .normal, title: String(localized: "Add to Queue")) { [weak playerVM] _, _, completion in
            playerVM?.addNextToQueue(song: song)
            completion(true)
        }
        addToQueue.backgroundColor = .systemOrange
        addToQueue.image = UIImage(systemName: "text.line.last.and.arrowtriangle.forward")
        let configuration = UISwipeActionsConfiguration(actions: [addToQueue])
        configuration.performsFirstActionWithFullSwipe = true
        return configuration
    }
}

/// Lyrics badge shown next to songs that have an LRC file.
enum LyricsBadge {
    static func image(for kind: LyricsKind) -> UIImage? {
        switch kind {
        case .synced: UIImage(systemName: "quote.bubble.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 10))
        case .unsynced: UIImage(systemName: "quote.bubble", withConfiguration: UIImage.SymbolConfiguration(pointSize: 10))
        case .none: nil
        }
    }
}

/// A destructive menu item's label: red icon as well as red text, which a
/// page's tint would otherwise override.
extension Button where Label == DestructiveLabel {
    /// A destructive menu row whose icon is red like its text: menus
    /// otherwise draw it in the tint (white on album and artist pages).
    init(_ title: LocalizedStringResource, destructiveImage: String, action: @escaping () -> Void) {
        self.init(role: .destructive, action: action) { DestructiveLabel(title, systemImage: destructiveImage) }
    }

    @_disfavoredOverload
    init<S: StringProtocol>(_ title: S, destructiveImage: String, action: @escaping () -> Void) {
        let title = String(title)
        self.init(role: .destructive, action: action) { DestructiveLabel(title, systemImage: destructiveImage) }
    }
}

struct DestructiveLabel: View {
    let title: Text
    let systemImage: String

    init(_ title: LocalizedStringResource, systemImage: String) {
        self.title = Text(title)
        self.systemImage = systemImage
    }

    @_disfavoredOverload
    init<S: StringProtocol>(_ title: S, systemImage: String) {
        self.title = Text(title)
        self.systemImage = systemImage
    }

    var body: some View {
        Label {
            title
        } icon: {
            if let image = UIImage(systemName: systemImage)?.withTintColor(.menuDestructive, renderingMode: .alwaysOriginal) {
                Image(uiImage: image)
            }
        }
    }
}


/// Title, artist, album… and cover of an imported song, as Apple Music's
/// "Edit Info". The file itself isn't touched.
struct SongEditorView: View {
    let song: Song
    @EnvironmentObject private var libraryVM: LibraryViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var artist: String
    @State private var album: String
    @State private var albumArtist: String
    @State private var genre: String
    @State private var year: String
    @State private var track: String
    @State private var disc: String
    @State private var showsPhotoPicker = false
    @State private var newCover: Data?
    @State private var removesCover = false

    init(song: Song) {
        self.song = song
        _title = State(initialValue: song.title)
        _artist = State(initialValue: song.artist)
        _album = State(initialValue: song.album)
        _albumArtist = State(initialValue: song.albumArtist ?? "")
        _genre = State(initialValue: song.genre)
        _year = State(initialValue: song.year > 0 ? String(song.year) : "")
        _track = State(initialValue: song.trackNumber > 0 ? String(song.trackNumber) : "")
        _disc = State(initialValue: song.discNumber > 0 ? String(song.discNumber) : "")
    }

    private var hasCover: Bool { newCover != nil || (!removesCover && song.artworkData != nil) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        cover.frame(width: 160, height: 160)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
                Section {
                    Button(hasCover ? "Choose Another Cover…" : "Choose Cover…", systemImage: "photo.on.rectangle") {
                        showsPhotoPicker = true
                    }
                    if hasCover {
                        Button("Remove Cover", destructiveImage: "trash") {
                            newCover = nil
                            removesCover = true
                        }
                    }
                }
                Section {
                    TextField("Title", text: $title)
                    TextField("Artist", text: $artist)
                    TextField("Album", text: $album)
                    TextField("Album Artist", text: $albumArtist)
                    TextField("Genre", text: $genre)
                }
                Section {
                    TextField("Year", text: $year).keyboardType(.numberPad)
                    TextField("Track Number", text: $track).keyboardType(.numberPad)
                    TextField("Disc Number", text: $disc).keyboardType(.numberPad)
                }
            }
            .navigationTitle("Edit Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: save)
                        .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .fullScreenCover(isPresented: $showsPhotoPicker) {
                // The system picker with its own square crop, as Contacts.
                CroppingPhotoPicker { image in
                    newCover = Self.squareJPEG(image)
                    removesCover = false
                }
                .ignoresSafeArea()
            }
        }
    }

    @ViewBuilder
    private var cover: some View {
        if let newCover, let image = UIImage(data: newCover) {
            Image(uiImage: image).resizable().scaledToFill()
        } else if hasCover {
            ArtworkImage(source: song.artworkSource, points: 160)
        } else {
            Rectangle().fill(.quaternary).overlay { Image(systemName: "music.note").font(.largeTitle).foregroundStyle(.secondary) }
        }
    }

    private func save() {
        var updated = song
        updated.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.artist = trimmedArtist.isEmpty ? "Unknown Artist" : trimmedArtist
        let trimmedAlbum = album.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.album = trimmedAlbum.isEmpty ? "Unknown Album" : trimmedAlbum
        let trimmedAlbumArtist = albumArtist.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.albumArtist = trimmedAlbumArtist.isEmpty ? nil : trimmedAlbumArtist
        updated.genre = genre.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.year = Int(year) ?? 0
        updated.trackNumber = Int(track) ?? 0
        updated.discNumber = Int(disc) ?? 0
        if let newCover {
            ArtworkStore.replace(newCover, for: song.id)
        } else if removesCover {
            ArtworkStore.remove(for: song.id)
        }
        libraryVM.libraryService.updateSong(updated)
        dismiss()
    }

    /// The image cropped to its centre square, as a JPEG of `maxSide` at most.
    static func squareJPEG(_ image: UIImage, maxSide: CGFloat = 1200) -> Data? {
        let side = min(image.size.width, image.size.height)
        let target = min(side, maxSide)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: target, height: target), format: format)
        return renderer.jpegData(withCompressionQuality: 0.88) { _ in
            let scale = target / side
            let drawn = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            image.draw(in: CGRect(x: (target - drawn.width) / 2, y: (target - drawn.height) / 2, width: drawn.width, height: drawn.height))
        }
    }
}

/// Everything known about a song: its tags, its file, its lyrics and what
/// the app measured from its audio. Opened from Search.
struct SongInfoView: View {
    let song: Song
    @EnvironmentObject private var libraryVM: LibraryViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var coverAlbum: Album?
    @State private var audio: AudioDetails?
    @State private var mix: AutoMixProfile?
    @State private var hasWordSync = false
    @State private var summary = ""
    @State private var hasSummary = false

    struct AudioDetails {
        var codec: String?
        var bitrate: Double?
        var sampleRate: Double?
        var channels: Int?
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        ArtworkImage(source: song.artworkSource, points: 72)
                            .frame(width: 72, height: 72)
                            .clipShape(.rect(cornerRadius: 8, style: .continuous))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(song.title).font(.headline)
                            Text(song.artist).foregroundStyle(.secondary)
                        }
                    }
                    .listRowBackground(Color.clear)
                    // Clear of the cell's rounded corners, which clipped the cover.
                    .listRowInsets(EdgeInsets(top: 12, leading: 20, bottom: 12, trailing: 20))
                }

                if let album = libraryVM.album(containing: song) {
                    Section {
                        Button(album.isSingle ? "Change Cover…" : "Change Album Cover…", systemImage: "photo.on.rectangle") {
                            coverAlbum = album
                        }
                    } footer: {
                        if album.songs.count > 1 {
                            Text("For the \(album.songs.count) songs of “\(album.title)”.")
                        }
                    }
                }

                Section("Metadata") {
                    row("Title", song.title)
                    row("Artist", song.artist)
                    row("Album", song.album)
                    row("Album Artist", song.albumArtist)
                    row("Genre", song.genre)
                    row("Year", song.year > 0 ? String(song.year) : nil)
                    row("Track", song.trackNumber > 0 ? String(song.trackNumber) : nil)
                    row("Disc", song.discNumber > 0 ? String(song.discNumber) : nil)
                    row("Duration", Self.clock(song.duration))
                }

                Section("File") {
                    row("Source", song.isMediaLibraryItem ? String(localized: "Music Library") : String(localized: "Imported File"))
                    if !song.isMediaLibraryItem { row("File Name", song.playableFileURL.lastPathComponent) }
                    row("Format", song.format.isEmpty ? song.playableFileURL.pathExtension.uppercased() : song.format.uppercased())
                    row("Codec", audio?.codec)
                    row("Bitrate", audio?.bitrate.map { String(localized: "\(Int(($0 / 1000).rounded())) kbps") })
                    row("Sample Rate", audio?.sampleRate.map { String(localized: "\(($0 / 1000).formatted(.number.precision(.fractionLength(1)))) kHz") })
                    row("Channels", audio?.channels.map { $0 == 1 ? String(localized: "Mono") : $0 == 2 ? String(localized: "Stereo") : "\($0)" })
                    row("Size", song.fileSize > 0 ? ByteCountFormatter.string(fromByteCount: song.fileSize, countStyle: .file) : nil)
                }

                Section("Listening") {
                    row("Plays", String(song.playCount))
                    row("Last Played", song.lastPlayedAt?.formatted(date: .abbreviated, time: .shortened))
                    row("Added", song.addedAt.formatted(date: .abbreviated, time: .shortened))
                }

                Section("Lyrics") {
                    row("Lyrics", lyricsSource)
                    if song.lrcFilePath != nil { row("Word Sync", hasWordSync ? String(localized: "Yes") : String(localized: "No")) }
                }

                if hasSummary {
                    Section {
                        TextField("What the lyrics are about", text: $summary, axis: .vertical)
                            .lineLimit(2...6)
                    } header: {
                        Text("Lyrics Summary")
                    } footer: {
                        Text("Written by \(AIProvider.current.name) from the lyrics, for the assistant. Edit it if it's wrong; empty it to remove it.")
                    }
                }

                Section {
                    if let sound = LibrarySoundAnalysis.storedProfiles()[song.id] {
                        row("Mood", {
                            switch sound.mood {
                            case .energetic: String(localized: "Energetic")
                            case .balanced: String(localized: "Balanced")
                            case .calm: String(localized: "Calm")
                            }
                        }())
                        row("Energy", sound.energy.formatted(.percent.precision(.fractionLength(0))))
                        row("Tempo", sound.bpm > 0 ? String(localized: "\(Int(sound.bpm.rounded())) BPM") : String(localized: "No steady beat"))
                        row("Loudness", String(localized: "\(sound.loudness.formatted(.number.precision(.fractionLength(1)))) dBFS"))
                        row("Dynamics", String(localized: "\(sound.dynamics.formatted(.number.precision(.fractionLength(1)))) dB"))
                        row("Brightness", sound.brightness.formatted(.number.precision(.fractionLength(3))))
                    }
                    if let mix {
                        if LibrarySoundAnalysis.storedProfiles()[song.id] == nil {
                            row("Tempo", mix.bpm > 0 ? String(localized: "\(Int(mix.bpm.rounded())) BPM") : String(localized: "No steady beat"))
                        }
                        row("Intro", Self.clock(mix.attack))
                        row("Leading Silence", String(localized: "\(mix.start.formatted(.number.precision(.fractionLength(2)))) s"))
                        row("Outro Starts", Self.clock(mix.outroStart))
                        row("Last Sound", Self.clock(mix.end))
                        row("First Beat", String(localized: "\(mix.beatOffset.formatted(.number.precision(.fractionLength(2)))) s"))
                    }
                    if LibrarySoundAnalysis.storedProfiles()[song.id] == nil, mix == nil {
                        Text("Not analyzed yet. Stats measures the library, and AutoMix each song it plays.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Analysis")
                }
            }
            .navigationTitle("Info")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $coverAlbum) { album in AlbumCoverPicker(album: album) }
            .onAppear {
                if let text = LyricsSummaries.shared.summary(for: song.id) {
                    summary = text
                    hasSummary = true
                }
            }
            .onDisappear {
                guard hasSummary, summary != (LyricsSummaries.shared.summary(for: song.id) ?? "") else { return }
                LyricsSummaries.shared.setSummary(summary, for: song.id)
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
            }
            .task { await load() }
        }
    }

    private var lyricsSource: String {
        guard song.lrcFilePath != nil else { return String(localized: "None") }
        return LyricsGenerator.isGenerated(storedPath: song.lrcFilePath) ? String(localized: "AI Transcript") : String(localized: "LRC File")
    }

    @ViewBuilder
    private func row(_ title: LocalizedStringKey, _ value: String?) -> some View {
        if let value, !value.trimmingCharacters(in: .whitespaces).isEmpty {
            LabeledContent(title) {
                Text(value).textSelection(.enabled).multilineTextAlignment(.trailing)
            }
        }
    }

    private static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds.isFinite ? seconds : 0))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func load() async {
        mix = await AutoMixAnalyzer.shared.storedProfile(for: song.id)
        if let url = AppModel.shared.libraryService.resolvedLyricsURL(for: song), let lyrics = LRCParser.parse(url: url) {
            hasWordSync = !WordSyncStore.load(for: song.id, lyrics: lyrics).isEmpty
        }
        let url = song.isMediaLibraryItem ? song.fileURL : song.playableFileURL
        guard url.scheme != "media-library" else { return }
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first else { return }
        var details = AudioDetails()
        if let rate = try? await track.load(.estimatedDataRate), rate > 0 { details.bitrate = Double(rate) }
        if let format = try? await track.load(.formatDescriptions).first,
           let basic = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee {
            details.sampleRate = basic.mSampleRate
            details.channels = Int(basic.mChannelsPerFrame)
            details.codec = Self.codecName(basic.mFormatID)
        }
        audio = details
    }

    private static func codecName(_ id: AudioFormatID) -> String {
        switch id {
        case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2: "AAC"
        case kAudioFormatAppleLossless: "Apple Lossless"
        case kAudioFormatMPEGLayer3: "MP3"
        case kAudioFormatFLAC: "FLAC"
        case kAudioFormatLinearPCM: "PCM"
        case kAudioFormatOpus: "Opus"
        default:
            String(bytes: [24, 16, 8, 0].map { UInt8((id >> $0) & 0xFF) }, encoding: .ascii) ?? String(localized: "Unknown")
        }
    }
}

extension UIColor {
    /// The tone iOS gives destructive menu text, so icons match it.
    static let menuDestructive = UIColor(red: 0.92, green: 0.48, blue: 0.49, alpha: 1)
}

/// A context menu that keeps its rows in written order, so destructive rows
/// stay at the top whichever way the menu opens.
@MainActor
func fixedContextMenu(identifier: NSCopying?, previewProvider: UIContextMenuContentPreviewProvider?, actionProvider: UIContextMenuActionProvider?) -> UIContextMenuConfiguration {
    let configuration = UIContextMenuConfiguration(identifier: identifier, previewProvider: previewProvider, actionProvider: actionProvider)
    configuration.preferredMenuElementOrder = .fixed
    return configuration
}


/// What swiping a song left does, picked in Settings › Home.
enum SongSwipeAction: String, CaseIterable, Identifiable {
    case none, goToAlbum, goToArtist, playLast

    static let storageKey = "songSwipeLeftAction"

    static var current: SongSwipeAction {
        SongSwipeAction(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .goToAlbum
    }

    /// The page the list is on: no swipe to it.
    enum Context { case list, album, artist }

    var id: Self { self }

    var title: String {
        switch self {
        case .none: String(localized: "None")
        case .goToAlbum: String(localized: "Go to Album")
        case .goToArtist: String(localized: "Go to Artist")
        case .playLast: String(localized: "Play Last")
        }
    }

    var symbol: String {
        switch self {
        case .none: "nosign"
        case .goToAlbum: "square.stack"
        case .goToArtist: "music.microphone"
        case .playLast: "text.line.last.and.arrowtriangle.forward"
        }
    }

    struct Target {
        let title: String
        let symbol: String
        let color: UIColor
        let perform: @MainActor (PlayerViewModel?, AppRouter?) -> Void

        @MainActor func perform(playerVM: PlayerViewModel?, router: AppRouter?) { perform(playerVM, router) }
    }

    @MainActor
    func target(for song: Song, libraryVM: LibraryViewModel?, context: Context) -> Target? {
        switch self {
        case .none:
            return nil
        case .goToAlbum:
            guard context != .album, let album = libraryVM?.album(containing: song), !album.isSingle else { return nil }
            let id = album.id
            return Target(title: title, symbol: symbol, color: .systemIndigo) { _, router in router?.open(.album(id)) }
        case .goToArtist:
            guard context != .artist, let artist = libraryVM?.artist(for: song) else { return nil }
            let name = artist.name
            return Target(title: title, symbol: symbol, color: .systemIndigo) { _, router in router?.open(.artist(name)) }
        case .playLast:
            return Target(title: title, symbol: symbol, color: .systemOrange) { playerVM, _ in playerVM?.addToQueue(song: song) }
        }
    }
}

/// The SwiftUI lists' left swipe (the same as the tables').
struct SwipeLeftButtons: View {
    let song: Song
    var context: SongSwipeAction.Context = .list
    @EnvironmentObject private var libraryVM: LibraryViewModel
    @EnvironmentObject private var playerVM: PlayerViewModel
    @EnvironmentObject private var router: AppRouter
    @AppStorage(SongSwipeAction.storageKey) private var raw = SongSwipeAction.goToAlbum.rawValue

    var body: some View {
        if let target = (SongSwipeAction(rawValue: raw) ?? .goToAlbum).target(for: song, libraryVM: libraryVM, context: context) {
            Button {
                DispatchQueue.main.async { target.perform(playerVM: playerVM, router: router) }
            } label: {
                Label(target.title, systemImage: target.symbol)
            }
            .tint(Color(uiColor: target.color))
        }
    }
}
