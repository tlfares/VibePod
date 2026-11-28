import SwiftUI
import UIKit

// MARK: - Artist page

/// Like Music: the artist's photo edge to edge under the bars, the name on
/// it, the page tinted with the photo's color; then the albums as a cover
/// flow and every song.
struct ArtistDetailView: View {
    let artistName: String
    @EnvironmentObject private var libraryVM: LibraryViewModel
    @EnvironmentObject private var playerVM: PlayerViewModel
    @ObservedObject private var photos = ArtistImageService.shared
    /// The pull-down stretch, read by the header alone; the page itself
    /// only follows `chrome`, so scrolling doesn't recompute its body.
    @State private var stretch = HeaderStretch()
    @State private var chrome = PageChrome()
    @State private var songsCache = ArtistSongsCache()
    @AppStorage("artistCoverFlow") private var showsCoverFlow = true
    @AppStorage("artistSongSort2") private var sortRawValue = DetailSongSort.title.rawValue
    @AppStorage("detailSongsFollowAlbum") private var followsAlbum = false
    /// The album the songs follow: whichever Cover Flow turned last.
    @State private var followedAlbumID: AlbumID?
    /// Artists whose singles and EPs get their own Cover Flow (one per line).
    @AppStorage("artistsWithSeparateSingles") private var separateSinglesRaw = ""
    @State private var reviewsMerges = false
    @State private var mergesArtist = false
    /// The Songs header has reached the top bar: the albums are gone.
    @State private var reachedSongs = false

    var body: some View {
        if let artist = libraryVM.artist(named: artistName) {
            let albums = libraryVM.albums
                .filter { ArtistMerges.main(for: $0.artist) == artist.name }
                .sorted { ($0.year == 0 ? Int.max : -$0.year, $0.title) < ($1.year == 0 ? Int.max : -$1.year, $1.title) }
            let separates = separatesSingles(of: artist.name) && albums.contains(where: \.isSingleOrEP) && albums.contains { !$0.isSingleOrEP }
            let mainAlbums = separates ? albums.filter { !$0.isSingleOrEP } : albums
            let singles = separates ? albums.filter(\.isSingleOrEP) : []
            let followed = followedAlbumID.flatMap { id in albums.first { $0.id == id } } ?? mainAlbums.first
            let albumOnly = followsAlbum && showsCoverFlow && followed != nil
            let sort = DetailSongSort(rawValue: sortRawValue) ?? .title
            let songs = songsCache.songs(artist.songs, sort: sort, album: albumOnly ? followed : nil)
            let photo = photos.photo(for: artist.name, albums: artist.songs.map(\.album))
            let artwork = photo ?? ArtistAvatar.coverSong(in: artist.songs, artist: artist.name)?.artworkSource
            let pageColor = Color(uiColor: Song.albumBackgroundUIColor(for: artwork))
            GeometryReader { proxy in
                let size = CGSize(width: proxy.size.width, height: proxy.size.height + proxy.safeAreaInsets.top + proxy.safeAreaInsets.bottom)
                let headerHeight = CollectionHeaderStyle.artworkHeight(in: size)
                // Wider than tall: the square photo, its buttons and the
                // albums on the left, the songs alone on the right.
                let split = CollectionHeaderStyle.isSplit(in: size)
                let column = CollectionHeaderStyle.splitColumnWidth(in: size)
                HStack(spacing: 0) {
                if split {
                    SplitColumn(color: pageColor, width: column) {
                        ArtistHeader(
                            artist: artist,
                            albumCount: albums.count,
                            artwork: artwork,
                            isPhoto: photo != nil || photos.source(for: artist.name) == .albumArtwork,
                            pageColor: pageColor,
                            height: CollectionHeaderStyle.splitSquareSide(column: column),
                            topInset: proxy.safeAreaInsets.top,
                            stretch: HeaderStretch(),
                            trailingExtension: column - CollectionHeaderStyle.splitSquareSide(column: column)
                        )
                        albumShelves(artist: artist, mainAlbums: mainAlbums, singles: singles, separates: separates, width: column, pageColor: pageColor, inList: false)
                    }
                }
                List {
                    if !split {
                    ArtistHeader(
                        artist: artist,
                        albumCount: albums.count,
                        artwork: artwork,
                        isPhoto: photo != nil || photos.source(for: artist.name) == .albumArtwork,
                        pageColor: pageColor,
                        height: headerHeight,
                        topInset: proxy.safeAreaInsets.top,
                        stretch: stretch
                    )
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(pageColor)
                    }

                    if !split {
                        albumShelves(artist: artist, mainAlbums: mainAlbums, singles: singles, separates: separates, width: proxy.size.width, pageColor: pageColor, inList: true)
                    }

                    SectionHeader(title: "Songs")
                        .onGeometryChange(for: Bool.self) { $0.frame(in: .global).minY < proxy.safeAreaInsets.top + 8 } action: { reachedSongs = $0 }
                        .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 4, trailing: 20))
                        .listRowSeparator(.hidden)
                        .listRowBackground(pageColor)
                    ForEach(songs) { song in
                        SongRow(song: song, subtitle: song.album, trackNumber: albumOnly ? max(song.trackNumber, 0) : nil)
                            .onTapGesture { playerVM.play(song: song, from: songs) }
                            .contextMenu { SongContextMenu(song: song) }
                            .swipeActions(edge: .leading) { QueueSwipeButtons(song: song) }
                            .swipeActions(edge: .trailing) { SwipeLeftButtons(song: song, context: .artist) }
                            .listRowInsets(EdgeInsets(top: 6, leading: 20, bottom: 6, trailing: 20))
                            .alignmentGuide(.listRowSeparatorLeading) { _ in 56 }
                            .listRowSeparatorTint(.white.opacity(0.14))
                            .listRowBackground(pageColor)
                    }
                    Text(Self.footer(for: songs))
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.6))
                        .listRowInsets(EdgeInsets(top: 14, leading: 20, bottom: 28, trailing: 20))
                        .listRowSeparator(.hidden)
                        .listRowBackground(pageColor)
                }
                .listStyle(.plain)
                .alphabetIndex(songs, isShown: sort == .title && !albumOnly && reachedSongs, topInset: proxy.safeAreaInsets.top)
                .scrollContentBackground(.hidden)
                .contentMargins(.top, split ? proxy.safeAreaInsets.top : 0, for: .scrollContent)
                .scrollIndicators(.hidden)
                .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y + $0.contentInsets.top } action: { _, value in
                    let pulled = split ? 0 : max(0, -value)
                    if stretch.value != pulled { stretch.value = pulled }
                    // The bar stays clear while the photo is under it.
                    let next = split
                        ? PageChrome(showsTitle: false, showsEdge: value > 0)
                        : PageChrome(
                            showsTitle: value > headerHeight - proxy.safeAreaInsets.top - 20,
                            showsEdge: value >= headerHeight - proxy.safeAreaInsets.top - 56
                        )
                    if next != chrome { chrome = next }
                }
                .scrollEdgeEffectHidden(!chrome.showsEdge, for: .top)
                .ignoresSafeArea(edges: .top)
                .pageTitle(chrome.showsTitle ? artist.name : "", large: false)
                .pageTrailingItem { menu(for: artist, albums: albums).tint(.menuTint(from: Song.albumBackgroundUIColor(for: artwork))) }
                }
            }
            .sheet(isPresented: $reviewsMerges) { MergedArtistsSheet(main: artist.name) }
            .sheet(isPresented: $mergesArtist) { MergeArtistSheet(name: artist.name) }
            .background(pageColor)
            .environment(\.pageTint, .contentTint(from: Song.albumBackgroundUIColor(for: artwork)))
            .animation(.easeInOut(duration: 0.4), value: artwork?.cacheKey)
            .tint(.white)
            .environment(\.colorScheme, .dark)
        } else {
            ContentUnavailableView("Artist Unavailable", systemImage: "music.microphone")
        }
    }

    private func menu(for artist: Artist, albums: [Album]) -> some View {
        Menu {
            Section {
                Toggle(isOn: $showsCoverFlow.animation(.smooth)) {
                    Label("Cover Flow", systemImage: "rectangle.stack")
                }
                // Only when there's both to tell apart.
                if albums.contains(where: \.isSingleOrEP), albums.contains(where: { !$0.isSingleOrEP }) {
                    Toggle(isOn: Binding(
                        get: { separatesSingles(of: artist.name) },
                        set: { on in withAnimation(.smooth) { setSeparatesSingles(on, for: artist.name) } }
                    )) {
                        Label("Separate Cover Flow for Singles and EPs", systemImage: "square.stack.3d.down.right")
                    }
                }
            }
            DetailSongSortSection(sortRawValue: $sortRawValue, followsAlbum: $followsAlbum, choices: DetailSongSort.artistChoices, canFollow: showsCoverFlow)
            Section {
                // Some platforms have an unflattering photo: the choice is
                // remembered for this artist.
                Menu {
                    let current = photos.source(for: artist.name)
                    ForEach(ArtistPhotoSource.allCases) { source in
                        if source == .albumArtwork {
                            Menu {
                                let chosen = current == .albumArtwork
                                    ? ArtistAvatar.coverSong(in: artist.songs, artist: artist.name)?.album : nil
                                ForEach(albums.filter { $0.artworkSource != nil }) { album in
                                    Button {
                                        photos.setCoverAlbum(album.title, for: artist.name)
                                    } label: {
                                        if album.title == chosen {
                                            Label(album.title, systemImage: "checkmark")
                                        } else {
                                            Text(album.title)
                                        }
                                    }
                                }
                            } label: {
                                Label("Album Cover", systemImage: current == .albumArtwork ? "checkmark" : source.systemImage)
                            }
                        } else {
                            Button {
                                photos.setSource(source, for: artist.name)
                            } label: {
                                Label(source.title, systemImage: current == source ? "checkmark" : source.systemImage)
                            }
                        }
                    }
                } label: {
                    Label("Artist Photo", systemImage: "person.crop.square")
                }
            }
            Section {
                if !ArtistMerges.merged(into: artist.name).isEmpty {
                    Button("Review Merged Artists", systemImage: "person.2") { reviewsMerges = true }
                }
                Button("Merge Into Another Artist…", systemImage: "arrow.triangle.merge") { mergesArtist = true }
            }
        } label: {
            BarIcon("More", systemImage: "ellipsis")
                .foregroundStyle(.white)
        }
    }

    /// The albums, then singles and EPs: rows of the list, or the left
    /// column's shelves on a split page.
    @ViewBuilder
    private func albumShelves(artist: Artist, mainAlbums: [Album], singles: [Album], separates: Bool, width: CGFloat, pageColor: Color, inList: Bool) -> some View {
        if !mainAlbums.isEmpty {
            RouteLink(.artistAlbums(artist.name)) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    SectionHeader(title: "Albums")
                    Image(systemName: "chevron.forward")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .shelfRow(EdgeInsets(top: 12, leading: 20, bottom: 0, trailing: 20), color: pageColor, inList: inList)

            Group {
                if showsCoverFlow {
                    AlbumCoverFlow(albums: mainAlbums, width: width, glows: false) { followedAlbumID = mainAlbums[safe: $0]?.id }
                } else {
                    AlbumCarousel(albums: mainAlbums)
                }
            }
            .id(separates)
            .shelfRow(EdgeInsets(top: 4, leading: 0, bottom: 8, trailing: 0), color: pageColor, inList: inList)
        }

        if !singles.isEmpty {
            SectionHeader(title: "Singles & EPs")
                .shelfRow(EdgeInsets(top: 12, leading: 20, bottom: 0, trailing: 20), color: pageColor, inList: inList)
            Group {
                if showsCoverFlow {
                    AlbumCoverFlow(albums: singles, width: width, glows: false) { followedAlbumID = singles[safe: $0]?.id }
                } else {
                    AlbumCarousel(albums: singles)
                }
            }
            .shelfRow(EdgeInsets(top: 4, leading: 0, bottom: 8, trailing: 0), color: pageColor, inList: inList)
        }
    }

    private func separatesSingles(of name: String) -> Bool {
        separateSinglesRaw.split(separator: "\n").contains { $0 == name }
    }

    private func setSeparatesSingles(_ on: Bool, for name: String) {
        var names = separateSinglesRaw.split(separator: "\n").map(String.init).filter { $0 != name }
        if on { names.append(name) }
        separateSinglesRaw = names.joined(separator: "\n")
    }

    private static func footer(for songs: [Song]) -> String {
        let minutes = Int(songs.reduce(0) { $0 + max(0, $1.duration) }) / 60
        let duration = minutes >= 60 ? String(localized: "\(minutes / 60) hr \(minutes % 60) min") : String(localized: "\(minutes) min")
        return String(localized: "\(songs.count) songs, \(duration)")
    }
}

// MARK: - Header

/// The photo rises behind the bars and grows when pulled down; its lower part
/// melts into the page color, under the name and the Play button.
private struct ArtistHeader: View {
    let artist: Artist
    let albumCount: Int
    let artwork: ArtworkSource?
    /// An album cover stands in until the artist's photo is found.
    let isPhoto: Bool
    let pageColor: Color
    let height: CGFloat
    let topInset: CGFloat
    let stretch: HeaderStretch
    /// On a split page: the width of the blurred extension on the right,
    /// beside the square artwork kept on the left.
    var trailingExtension: CGFloat = 0
    @EnvironmentObject private var playerVM: PlayerViewModel

    var body: some View {
        let stretch = stretch.value
        ZStack(alignment: .bottom) {
            SideExtendedArtwork(artwork: artwork, leadingSquare: trailingExtension > 0) {
                ArtworkImage(source: artwork, cornerRadius: 0, points: height, placeholderSymbol: "music.microphone")
                    .id(artwork?.cacheKey)
                    .transition(.opacity)
                    // Covers stand in blurred: they aren't the artist.
                    .blur(radius: isPhoto ? 0 : 18, opaque: true)
            }
            .frame(height: height + stretch)

            // Keeps the bar buttons readable on a light photo.
            LinearGradient(colors: [.black.opacity(0.32), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: topInset + 40 + stretch)
                .frame(maxHeight: .infinity, alignment: .top)

            // Eased stops: a linear fade shows a band.
            LinearGradient(
                stops: [(0, 0) as (CGFloat, Double), (0.14, 0.08), (0.28, 0.22), (0.42, 0.42), (0.58, 0.64), (0.76, 0.85), (1, 1)].map {
                    Gradient.Stop(color: pageColor.opacity($0.1), location: $0.0)
                },
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: height * 0.45)

            // On a split page the photo melts into the songs' side the same
            // way it melts into the page below.
            if trailingExtension > 0 {
                LinearGradient(
                    stops: [(0, 0) as (CGFloat, Double), (0.14, 0.08), (0.28, 0.22), (0.42, 0.42), (0.58, 0.64), (0.76, 0.85), (1, 1)].map {
                        Gradient.Stop(color: pageColor.opacity($0.1), location: $0.0)
                    },
                    startPoint: .leading,
                    endPoint: .trailing
                )
                // Over the blurred extension only: the square stays whole.
                .frame(width: trailingExtension)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            }

            VStack(spacing: 20) {
                VStack(spacing: 2) {
                    Text(artist.name)
                        .font(.largeTitle.bold())
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                        .multilineTextAlignment(.center)
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.7))
                }
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.2), radius: 8)
                // The album page's buttons, swapped: on an artist page you
                // mostly shuffle.
                ArtistPlayButtons(
                    onShuffle: { playerVM.play(artist.songs, shuffled: true) },
                    onPlay: { playerVM.play(artist.songs, shuffled: false) }
                )
                .frame(maxWidth: 340)
                .frame(height: 48)
                .padding(.horizontal, 12)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .frame(height: height, alignment: .bottom)
        .frame(maxWidth: .infinity)
    }

    private var detail: String {
        guard albumCount > 0 else { return String(localized: "\(artist.songs.count) songs") }
        return String(localized: "\(albumCount) albums · \(artist.songs.count) songs")
    }
}

/// The header artwork. On a page wider than tall it stays whole and square
/// in the middle, over the same mirrored, blurred sides as album and
/// playlist pages.
private struct SideExtendedArtwork<Content: View>: View {
    let artwork: ArtworkSource?
    var photo: UIImage? = nil
    /// The square against the left edge, the blurred extension only on its
    /// right (split pages); otherwise centered between two.
    var leadingSquare = false
    @ViewBuilder let content: () -> Content
    @State private var backdrop: UIImage?

    /// Eased (position, opacity) stops for the sharp artwork's side edges.
    private static var edgeStops: [Gradient.Stop] {
        let edge: [(CGFloat, Double)] = [(0, 0), (0.25, 0.2), (0.5, 0.55), (0.75, 0.88), (1, 1)]
        let reach: CGFloat = 0.06
        return edge.map { Gradient.Stop(color: .black.opacity($0.1), location: $0.0 * reach) }
            + edge.reversed().map { Gradient.Stop(color: .black.opacity($0.1), location: 1 - $0.0 * reach) }
    }

    /// The same, on the right edge only.
    private static var trailingEdgeStops: [Gradient.Stop] {
        let edge: [(CGFloat, Double)] = [(0, 0), (0.25, 0.2), (0.5, 0.55), (0.75, 0.88), (1, 1)]
        return [Gradient.Stop(color: .black, location: 0)]
            + edge.reversed().map { Gradient.Stop(color: .black.opacity($0.1), location: 1 - $0.0 * 0.06) }
    }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let isWide = size.width > size.height + 1
            // Leading: the backdrop is laid out as if the square were
            // centered in it, so its blurred mirror continues the square.
            let backdropWidth = leadingSquare ? 2 * size.width - size.height : size.width
            ZStack {
                if isWide && leadingSquare {
                    ZStack(alignment: .topLeading) {
                        if let backdrop {
                            Image(uiImage: backdrop)
                                .resizable()
                                .scaledToFill()
                                .frame(width: backdropWidth, height: size.height)
                                .offset(x: size.width - backdropWidth)
                                .transition(.opacity)
                        }
                        content()
                            .frame(width: size.height, height: size.height)
                            .clipped()
                            .mask(LinearGradient(stops: Self.trailingEdgeStops, startPoint: .leading, endPoint: .trailing))
                    }
                    .frame(width: size.width, height: size.height, alignment: .topLeading)
                } else if isWide {
                    if let backdrop {
                        Image(uiImage: backdrop)
                            .resizable()
                            .scaledToFill()
                            .frame(width: size.width, height: size.height)
                            .transition(.opacity)
                    }
                    content()
                        .frame(width: size.height, height: size.height)
                        .clipped()
                        .mask(LinearGradient(stops: Self.edgeStops, startPoint: .leading, endPoint: .trailing))
                } else {
                    content()
                        .frame(width: size.width, height: size.height)
                }
            }
            .frame(width: size.width, height: size.height)
            .clipped()
            // Rendered once at the header's resting size; a pull only zooms it.
            .task(id: BackdropKey(source: artwork?.cacheKey, hasPhoto: photo != nil, width: isWide ? backdropWidth.rounded() : 0)) {
                guard isWide else { backdrop = nil; return }
                let height = size.height.rounded()
                let image: UIImage? = if let photo { photo } else if let artwork { await ArtworkImageCache.shared.image(for: artwork, points: height) } else { nil }
                guard let image else { backdrop = nil; return }
                let pageSize = CGSize(width: backdropWidth, height: height)
                let rendered = await Task.detached(priority: .userInitiated) {
                    FullScreenArtworkHeaderView.backdropImage(from: image, fitting: pageSize)
                }.value
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.25)) { backdrop = rendered }
            }
        }
    }

    private struct BackdropKey: Equatable {
        let source: String?
        let hasPhoto: Bool
        let width: CGFloat
    }
}

/// Shuffle as the long glass capsule, Play as the round one: the same UIKit
/// glass buttons as album and playlist pages.
private struct ArtistPlayButtons: UIViewRepresentable {
    let onShuffle: () -> Void
    let onPlay: () -> Void

    final class Coordinator {
        var onShuffle: () -> Void = {}
        var onPlay: () -> Void = {}
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIStackView {
        let coordinator = context.coordinator
        let shuffle = SongListHeaderView.makeButton(title: String(localized: "Shuffle"), systemImage: "shuffle", color: .white) { coordinator.onShuffle() }
        var play = UIButton.Configuration.glass()
        play.image = UIImage(systemName: "play.fill")
        play.cornerStyle = .capsule
        play.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(textStyle: .headline)
        play.baseForegroundColor = .white
        let playButton = UIButton(configuration: play, primaryAction: UIAction { _ in coordinator.onPlay() })
        playButton.tintColor = .white
        playButton.accessibilityLabel = String(localized: "Play")
        let stack = UIStackView(arrangedSubviews: [shuffle, playButton])
        stack.axis = .horizontal
        stack.spacing = 12
        playButton.widthAnchor.constraint(equalTo: playButton.heightAnchor).isActive = true
        return stack
    }

    func updateUIView(_ stack: UIStackView, context: Context) {
        context.coordinator.onShuffle = onShuffle
        context.coordinator.onPlay = onPlay
    }
}

// MARK: - Carousel

/// The classic row of album tiles, when Cover Flow is off.
private struct AlbumCarousel: View {
    let albums: [Album]

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 14) {
                ForEach(albums) { album in
                    let zoomID = "artist-album-\(album.id.pinKey)-\(album.id.singleSongID?.uuidString ?? "")"
                    RouteLink(.album(album.id, zoomSource: zoomID)) {
                        ArtworkTile(
                            title: album.title,
                            subtitle: album.year > 0 ? "\(album.year)" : (album.isSingle ? String(localized: "Single") : String(localized: "Album")),
                            artwork: album.artworkSource,
                            zoomID: zoomID,
                            width: 156
                        )
                    }
                    .buttonStyle(.plain)
                    .contextMenu { HomeItemMenu(item: .album(album)) }
                }
            }
            .scrollTargetLayout()
        }
        .scrollIndicators(.hidden)
        .scrollTargetBehavior(.viewAligned)
        .contentMargins(.horizontal, 20, for: .scrollContent)
    }
}

// MARK: - Cover flow

/// The albums as a cover flow: the centered one faces you, the others turn
/// slightly toward it, stacked tight on both sides. It scrolls freely and
/// settles on any cover, ticking as each one passes. Tapping a side cover
/// brings it to the center, then opens it; tapping the centered one opens it.
struct AlbumCoverFlow: View {
    let albums: [Album]
    let width: CGFloat
    /// Off on pages whose background already carries the artwork's color.
    var glows = true
    /// The centered album's index, for pages that follow it.
    var onCenter: ((Int) -> Void)? = nil
    @State private var current = 0
    @Environment(\.routeOpener) private var routeOpener

    private var side: CGFloat { min(max(width * 0.36, 130), 180) }

    var body: some View {
        let album = albums[safe: current]
        VStack(spacing: 6) {
            CoverFlowCollection(entries: albums.map { album in
                var entry = CoverFlowEntry(album: album)
                if let routeOpener {
                    let route = entry.route
                    entry.open = { routeOpener(route) }
                }
                return entry
            }, side: side, current: $current, glows: glows)
                .frame(height: side + 20)
            if let album {
                VStack(spacing: 1) {
                    Text(album.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(subtitle(for: album))
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                }
                .padding(.horizontal, 32)
                .id(album.id)
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: album?.id)
        .onChange(of: current) { _, index in onCenter?(index) }
    }

    private func subtitle(for album: Album) -> String {
        [album.isSingle ? String(localized: "Single") : String(localized: "Album"), album.year > 0 ? "\(album.year)" : nil]
            .compactMap { $0 }
            .joined(separator: " · ")
    }
}

/// What the Cover Flow shows for one cover: its artwork, where a tap on it
/// goes and its context menu.
struct CoverFlowEntry {
    let id: String
    let artwork: ArtworkSource?
    let zoomID: String
    let route: LibraryRoute
    let menu: @MainActor (AppServices) -> UIMenu
    /// Replaces opening `route`, for pages with their own navigation.
    var open: (@MainActor () -> Void)?

    init(album: Album, zoomPrefix: String = "artist-album") {
        let zoomID = "\(zoomPrefix)-\(album.id.pinKey)-\(album.id.singleSongID?.uuidString ?? "")"
        id = "album-\(album.id.pinKey)-\(album.id.singleSongID?.uuidString ?? "")"
        artwork = album.artworkSource
        self.zoomID = zoomID
        route = .album(album.id, zoomSource: zoomID)
        menu = { services in
            UIMenu(children: [
                UIAction(title: String(localized: "Play"), image: UIImage(systemName: "play")) { _ in services.playerVM.play(album.songs, shuffled: false) },
                UIAction(title: String(localized: "Shuffle"), image: UIImage(systemName: "shuffle")) { _ in services.playerVM.play(album.songs, shuffled: true) },
                UIAction(title: String(localized: "Play Next"), image: UIImage(systemName: "text.line.first.and.arrowtriangle.forward")) { _ in
                    album.songs.reversed().forEach { services.playerVM.addNextToQueue(song: $0) }
                },
                UIAction(title: String(localized: "Go to Album"), image: UIImage(systemName: "square.stack")) { _ in
                    services.router.open(.album(album.id, zoomSource: nil))
                }
            ])
        }
    }

    @MainActor init(item: HomeItem, artwork: ArtworkSource?, onRearrange: @escaping @MainActor () -> Void) {
        let zoomID = "pinned-flow-\(item.id)"
        id = item.id
        self.artwork = artwork
        self.zoomID = zoomID
        route = item.route(zoomSource: zoomID)
        menu = { services in
            let playback: UIMenu
            let unpin: UIAction
            switch item {
            case let .album(album):
                playback = CoverFlowEntry(album: album).menu(services)
                unpin = UIAction(title: String(localized: "Unpin from Home"), image: UIImage(systemName: "pin.slash")) { _ in services.libraryVM.toggleAlbumPin(album.id) }
            case let .playlist(playlist):
                playback = UIMenu(children: [
                    UIAction(title: String(localized: "Play"), image: UIImage(systemName: "play")) { _ in services.playerVM.playPlaylist(playlist) },
                    UIAction(title: String(localized: "Shuffle"), image: UIImage(systemName: "shuffle")) { _ in services.playerVM.playPlaylist(playlist, shuffled: true) }
                ])
                unpin = UIAction(title: String(localized: "Unpin"), image: UIImage(systemName: "pin.slash")) { _ in services.libraryVM.togglePlaylistPin(id: playlist.id) }
            }
            let rearrange = UIAction(title: String(localized: "Rearrange Pinned"), image: UIImage(systemName: "square.grid.3x1.below.line.grid.1x2")) { _ in onRearrange() }
            return UIMenu(children: [
                UIMenu(options: .displayInline, children: playback.children),
                UIMenu(options: .displayInline, children: [unpin, rearrange])
            ])
        }
    }
}

/// Playlists as a Cover Flow, each opened by `onOpen`.
struct PlaylistCoverFlow: View {
    let playlists: [Playlist]
    let width: CGFloat
    let onOpen: @MainActor (Playlist) -> Void
    @EnvironmentObject private var libraryVM: LibraryViewModel
    @State private var current = 0

    private var side: CGFloat { min(max(width * 0.36, 130), 180) }

    var body: some View {
        let playlist = playlists[safe: current]
        VStack(spacing: 6) {
            CoverFlowCollection(entries: playlists.map { playlist in
                var entry = CoverFlowEntry(item: .playlist(playlist), artwork: libraryVM.playlistArtwork(playlist), onRearrange: {})
                entry.open = { onOpen(playlist) }
                return entry
            }, side: side, current: $current)
                .frame(height: side + 20)
            if let playlist {
                VStack(spacing: 1) {
                    Text(playlist.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text("\(playlist.songs.count) songs")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 32)
                .id(playlist.id)
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: playlist?.id)
        .onChange(of: playlists.count) { _, count in current = min(current, max(count - 1, 0)) }
    }
}

/// The albums atop the Albums tab as a Cover Flow, each with its artist.
struct AlbumHighlightsCoverFlow: View {
    let albums: [Album]
    let width: CGFloat
    @State private var current = 0

    private var side: CGFloat { min(max(width * 0.36, 130), 180) }

    var body: some View {
        let album = albums[safe: current]
        VStack(spacing: 6) {
            CoverFlowCollection(entries: albums.map { CoverFlowEntry(album: $0, zoomPrefix: "albums-flow") }, side: side, current: $current)
                .frame(height: side + 20)
            if let album {
                VStack(spacing: 1) {
                    Text(album.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(album.artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 32)
                .id(album.id)
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: album?.id)
        .onChange(of: albums.count) { _, count in current = min(current, max(count - 1, 0)) }
    }
}

/// The Library's pinned albums and playlists as one Cover Flow.
struct PinnedCoverFlow: View {
    let items: [HomeItem]
    let width: CGFloat
    /// Replaces the item's own subtitle.
    var subtitle: ((HomeItem) -> String)? = nil
    let onRearrange: @MainActor () -> Void
    @EnvironmentObject private var libraryVM: LibraryViewModel
    @State private var current = 0

    private var side: CGFloat { min(max(width * 0.36, 130), 180) }

    var body: some View {
        let item = items[safe: current]
        VStack(spacing: 6) {
            CoverFlowCollection(entries: items.map { item in
                switch item {
                case let .album(album): CoverFlowEntry(item: item, artwork: album.artworkSource, onRearrange: onRearrange)
                case let .playlist(playlist): CoverFlowEntry(item: item, artwork: libraryVM.playlistArtwork(playlist), onRearrange: onRearrange)
                }
            }, side: side, current: $current)
                .frame(height: side + 20)
            if let item {
                VStack(spacing: 1) {
                    Text(item.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(subtitle?(item) ?? item.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 32)
                .id(item.id)
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: item?.id)
        .onChange(of: items.count) { _, count in current = min(current, max(count - 1, 0)) }
    }
}

/// A UICollectionView: SwiftUI redrew every cover as each one passed the
/// center, which hitched and cut fast flicks short.
private struct CoverFlowCollection: UIViewRepresentable {
    let entries: [CoverFlowEntry]
    let side: CGFloat
    @Binding var current: Int
    var glows = true
    @Environment(\.appServices) private var services

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UICollectionView {
        let layout = CoverFlowLayout()
        let view = CoverFlowView(frame: .zero, collectionViewLayout: layout)
        view.backgroundColor = .clear
        view.clipsToBounds = false
        view.showsHorizontalScrollIndicator = false
        view.decelerationRate = .normal
        view.register(CoverFlowCell.self, forCellWithReuseIdentifier: CoverFlowCell.reuseID)
        view.dataSource = context.coordinator
        view.delegate = context.coordinator
        context.coordinator.collectionView = view
        return view
    }

    func updateUIView(_ view: UICollectionView, context: Context) {
        let coordinator = context.coordinator
        coordinator.services = services
        coordinator.onCenter = { index in if current != index { current = index } }
        (view.collectionViewLayout as? CoverFlowLayout)?.side = side
        (view as? CoverFlowView)?.glows = glows
        // A changed cover counts too, not just a changed list.
        let keys = entries.map { [$0.id, $0.artwork?.cacheKey ?? ""] }
        if coordinator.entries.map({ [$0.id, $0.artwork?.cacheKey ?? ""] }) != keys {
            coordinator.entries = entries
            view.reloadData()
        }
    }

    @MainActor
    final class Coordinator: NSObject, UICollectionViewDataSource, UICollectionViewDelegate {
        var entries: [CoverFlowEntry] = []
        var services: AppServices?
        var onCenter: (Int) -> Void = { _ in }
        weak var collectionView: UICollectionView?
        private var centered = 0
        /// A tapped side cover, opened once it has slid to the center.
        private var pendingOpen: Int?
        /// Tied to the view: on the Mac, it taps the trackpad.
        private var feedback: UISelectionFeedbackGenerator?

        func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
            entries.count
        }

        func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: CoverFlowCell.reuseID, for: indexPath) as! CoverFlowCell
            if let entry = entries[safe: indexPath.item] {
                cell.configure(artwork: entry.artwork, zoomID: entry.zoomID, side: (collectionView.collectionViewLayout as? CoverFlowLayout)?.side ?? 150)
            }
            return cell
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard let layout = collectionView?.collectionViewLayout as? CoverFlowLayout else { return }
            let index = min(max(Int((scrollView.contentOffset.x / layout.step).rounded()), 0), max(entries.count - 1, 0))
            guard index != centered else { return }
            centered = index
            if MacApp.isActive {
                MacHaptics.tick()
            } else {
                if feedback == nil { feedback = UISelectionFeedbackGenerator(view: scrollView) }
                feedback?.selectionChanged(at: CGPoint(x: scrollView.bounds.midX, y: scrollView.bounds.midY))
            }
            onCenter(index)
        }

        func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
            guard let entry = entries[safe: indexPath.item], let layout = collectionView.collectionViewLayout as? CoverFlowLayout else { return }
            if indexPath.item == centered {
                pendingOpen = nil
                open(entry)
            } else {
                pendingOpen = indexPath.item
                slide(collectionView, to: CGFloat(indexPath.item) * layout.step)
            }
        }

        private var slideLink: CADisplayLink?
        private var slideStart: (offset: CGFloat, time: CFTimeInterval) = (0, 0)
        private var slideTarget: CGFloat = 0
        private let slideDuration: CFTimeInterval = 0.24

        /// Quicker than `setContentOffset(animated:)`, which also lingered
        /// before telling it had ended, so the page opened late.
        private func slide(_ view: UICollectionView, to x: CGFloat) {
            slideLink?.invalidate()
            slideStart = (view.contentOffset.x, CACurrentMediaTime())
            slideTarget = x
            let link = CADisplayLink(target: self, selector: #selector(stepSlide))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
            link.add(to: .main, forMode: .common)
            slideLink = link
        }

        @objc private func stepSlide() {
            guard let view = collectionView else { stopSlide(); return }
            let t = min((CACurrentMediaTime() - slideStart.time) / slideDuration, 1)
            let eased = 1 - pow(1 - t, 3)
            view.contentOffset.x = slideStart.offset + (slideTarget - slideStart.offset) * eased
            guard t >= 1 else { return }
            stopSlide()
            guard let index = pendingOpen, index == centered, let entry = entries[safe: index] else { return }
            pendingOpen = nil
            // Lets the stand-in settle over the centered cover for the zoom.
            view.setNeedsLayout()
            view.layoutIfNeeded()
            open(entry)
        }

        private func stopSlide() {
            slideLink?.invalidate()
            slideLink = nil
        }

        private func open(_ entry: CoverFlowEntry) {
            (collectionView as? CoverFlowView)?.noteOpening()
            if let open = entry.open { open() } else { services?.router.open(entry.route) }
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            // A swipe never opens anything.
            pendingOpen = nil
            stopSlide()
        }

        func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath], point: CGPoint) -> UIContextMenuConfiguration? {
            guard let entry = indexPaths.first.flatMap({ entries[safe: $0.item] }), let services else { return nil }
            return fixedContextMenu(identifier: nil, previewProvider: nil) { _ in entry.menu(services) }
        }
    }
}

/// Covers one `step` apart, the centered one pushing its neighbors aside;
/// each turned and shrunk by its distance from the center, and layered so
/// the closer ones are on top. Flicks end on a cover.
private final class CoverFlowLayout: UICollectionViewLayout {
    var side: CGFloat = 150 { didSet { if side != oldValue { invalidateLayout() } } }
    /// Distance between covers' slots: narrower than a cover, so they stack.
    var step: CGFloat { side * 0.34 }
    /// Extra room either side of the centered cover.
    private var gap: CGFloat { side * 0.78 - step }

    private var count: Int { collectionView?.numberOfItems(inSection: 0) ?? 0 }

    override var collectionViewContentSize: CGSize {
        guard let view = collectionView else { return .zero }
        return CGSize(width: CGFloat(max(count - 1, 0)) * step + view.bounds.width, height: view.bounds.height)
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool { true }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        guard let view = collectionView, count > 0 else { return [] }
        let center = view.contentOffset.x / step
        let reach = Int((view.bounds.width / 2 + gap + side) / step) + 1
        let first = max(0, Int(center) - reach)
        let last = min(count - 1, Int(center) + reach)
        guard first <= last else { return [] }
        return (first...last).compactMap { layoutAttributesForItem(at: IndexPath(item: $0, section: 0)) }
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard let view = collectionView else { return nil }
        let attributes = UICollectionViewLayoutAttributes(forCellWith: indexPath)
        let position = CGFloat(indexPath.item) - view.contentOffset.x / step
        let turn = min(max(position, -1), 1)
        let x = view.contentOffset.x + view.bounds.width / 2 + position * step + turn * gap
        attributes.size = CGSize(width: side, height: side)
        attributes.center = CGPoint(x: x, y: view.bounds.height / 2)
        // The centered cover drawn flat, as the stand-in over it is: one in
        // perspective rendered a hair differently, and the stand-in blinked.
        guard abs(position) > 0.001 else {
            attributes.zIndex = 1000
            return attributes
        }
        var transform = CATransform3DIdentity
        transform.m34 = -1 / (side * 3)
        let scale = 1 - min(abs(position), 1) * 0.24
        transform = CATransform3DScale(transform, scale, scale, 1)
        transform = CATransform3DRotate(transform, -turn * .pi * 38 / 180, 0, 1, 0)
        attributes.transform3D = transform
        attributes.zIndex = 1000 - Int(abs(position) * 10)
        return attributes
    }

    override func targetContentOffset(forProposedContentOffset proposed: CGPoint, withScrollingVelocity velocity: CGPoint) -> CGPoint {
        let index = (proposed.x / step).rounded()
        return CGPoint(x: min(max(index, 0), CGFloat(max(count - 1, 0))) * step, y: proposed.y)
    }
}

/// Pages zoom out of a stand-in laid over the centered cover, never out of
/// a cover itself: the zoom back leaves a portal in its source, drawn as
/// the source was when the page closed, and the covers can be scrolled
/// before it settles. A cover kept that portal at full size as it moved
/// aside. The stand-in shows only while the covers rest, so whatever the
/// zoom leaves in it goes when they move. The cover under it stays shown:
/// the zoom hides the stand-in until it settles, and the cover fills in.
private final class CoverFlowView: UICollectionView {
    private let standIn = UIImageView()
    /// UIKit plays the zoom back inside the source's superview. Over the
    /// covers, so the page lands on top of them rather than between them.
    private let standInHost = StandInHost()
    private var standInZoomID: String?
    /// The zoom adds its views around the stand-in on the way out too: the
    /// cover under it stays then, or its spot blinked empty as the page left.
    private var isOpening = false
    /// Light spilled under the covers, beneath them all.
    private let glowLayer = CALayer()
    private let glowBand = CAGradientLayer()
    private let glowFade = CAGradientLayer()
    var glows = true { didSet { if glows != oldValue { setNeedsLayout() } } }

    override init(frame: CGRect, collectionViewLayout layout: UICollectionViewLayout) {
        super.init(frame: frame, collectionViewLayout: layout)
        CoverFlowCell.style(standIn)
        standIn.backgroundColor = .clear
        standIn.alpha = 0
        standInHost.isUserInteractionEnabled = false
        standInHost.onChange = { [weak self] in self?.setNeedsLayout() }
        standInHost.onRemove = { [weak self] in self?.isOpening = false }
        standInHost.layer.zPosition = 10_000
        standInHost.addSubview(standIn)
        addSubview(standInHost)
        glowLayer.zPosition = -10_000
        glowBand.startPoint = CGPoint(x: 0, y: 0.5)
        glowBand.endPoint = CGPoint(x: 1, y: 0.5)
        glowLayer.addSublayer(glowBand)
        // An ellipse over the band: soft above and below, gone at the sides.
        glowFade.type = .radial
        glowFade.startPoint = CGPoint(x: 0.5, y: 0.5)
        glowFade.endPoint = CGPoint(x: 1, y: 1)
        glowFade.colors = [UIColor.black.cgColor, UIColor.black.withAlphaComponent(0.68).cgColor, UIColor.clear.cgColor]
        glowFade.locations = [0, 0.45, 1]
        glowLayer.mask = glowFade
        layer.addSublayer(glowLayer)
        clipsToBounds = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:)") }

    /// A page is opening from the stand-in.
    func noteOpening() {
        isOpening = true
        // A page opened without a zoom never adds anything to wait for.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, !self.standInHost.subviews.contains(where: { $0 !== self.standIn }) else { return }
            self.isOpening = false
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutGlows()
        // Until its artwork has loaded, the centered cover stays itself: the
        // stand-in would show a gray square.
        let resting = restingCell.flatMap { $0.cover.image?.isSymbolImage == false ? $0 : nil }
        UIView.performWithoutAnimation {
            if let resting {
                if subviews.last !== standInHost { bringSubviewToFront(standInHost) }
                standInHost.frame = bounds
                standIn.bounds = resting.bounds
                standIn.center = standInHost.convert(resting.center, from: self)
                standIn.image = resting.cover.image
                standIn.contentMode = resting.cover.contentMode
                if standInZoomID != resting.zoomID {
                    if let old = standInZoomID { ZoomSourceRegistry.shared.unregister(standIn, for: old) }
                    standInZoomID = resting.zoomID
                    if let id = resting.zoomID { ZoomSourceRegistry.shared.register(standIn, for: id) }
                }
            }
            standIn.alpha = resting == nil ? 0 : 1
            // While the page flies back the spot stays empty, as the zoom
            // hides the stand-in; the cover shows once the page has landed.
            let landing = resting != nil && !isOpening && standInHost.subviews.contains { $0 !== standIn }
            for case let cell as CoverFlowCell in visibleCells {
                cell.cover.isHidden = landing && cell === resting
            }
        }
    }

    /// One long light along the bottom of the covers, each tinting the part
    /// under it, the centered one most; it fades out toward the sides.
    private func layoutGlows() {
        guard let layout = collectionViewLayout as? CoverFlowLayout else { return }
        let lit = visibleCells.compactMap { cell -> (x: CGFloat, width: CGFloat, color: UIColor, weight: CGFloat)? in
            guard let cell = cell as? CoverFlowCell, let color = cell.glowColor, let path = indexPath(for: cell) else { return nil }
            let distance = abs(CGFloat(path.item) - contentOffset.x / layout.step)
            return (cell.frame.midX - bounds.minX, cell.frame.width, color, max(1 - distance * 0.3, 0.3))
        }
        .sorted { $0.x < $1.x }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        glowLayer.isHidden = lit.isEmpty || !glows
        guard let first = lit.first, let last = lit.last, bounds.width > 0 else { return }
        let height = layout.side * 0.85
        glowLayer.frame = CGRect(x: bounds.minX, y: bounds.midY + layout.side / 2 - height * 0.45, width: bounds.width, height: height)
        glowBand.frame = glowLayer.bounds
        glowFade.frame = glowLayer.bounds
        // Out past the outer covers the light dies away: nothing above casts it.
        let stops = [(x: first.x - first.width * 0.75, color: first.color, alpha: CGFloat(0))]
            + lit.map { (x: $0.x, color: $0.color, alpha: 0.58 * $0.weight) }
            + [(x: last.x + last.width * 0.75, color: last.color, alpha: CGFloat(0))]
        glowBand.colors = stops.map { $0.color.withAlphaComponent($0.alpha * $0.color.cgColor.alpha).cgColor }
        glowBand.locations = stops.map { NSNumber(value: Double(min(max($0.x / bounds.width, 0), 1))) }
    }

    /// The centered cover, while the covers are still.
    private var restingCell: CoverFlowCell? {
        guard !isDragging, !isDecelerating, let layout = collectionViewLayout as? CoverFlowLayout else { return nil }
        let index = (contentOffset.x / layout.step).rounded()
        guard abs(contentOffset.x - index * layout.step) < 0.5 else { return nil }
        return cellForItem(at: IndexPath(item: Int(index), section: 0)) as? CoverFlowCell
    }
}

/// Tells when UIKit adds or removes the zoom's views around the stand-in.
private final class StandInHost: UIView {
    var onChange: () -> Void = {}
    var onRemove: () -> Void = {}
    override func didAddSubview(_ subview: UIView) { super.didAddSubview(subview); onChange() }
    override func willRemoveSubview(_ subview: UIView) {
        super.willRemoveSubview(subview)
        // Captures the callbacks, not self: this also runs while the host
        // deallocates, and a weak reference to it then aborts.
        let onRemove = onRemove, onChange = onChange
        DispatchQueue.main.async {
            onRemove()
            onChange()
        }
    }
}

private final class CoverFlowCell: UICollectionViewCell {
    static let reuseID = "CoverFlowCell"
    let cover = CoverImageView()
    private(set) var zoomID: String?
    /// The light its artwork casts on the floor below.
    private(set) var glowColor: UIColor?
    private let loader = ArtworkImageLoader()

    static func style(_ view: UIImageView) {
        view.clipsToBounds = true
        view.layer.cornerRadius = 14
        view.layer.cornerCurve = .continuous
        view.backgroundColor = UIColor.white.withAlphaComponent(0.08)
        view.tintColor = UIColor.white.withAlphaComponent(0.5)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        cover.frame = contentView.bounds
        cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        Self.style(cover)
        // The stand-in copies the artwork, which loads after the cell shows.
        cover.onImage = { [weak self] in
            guard let self else { return }
            self.glowColor = self.cover.image.flatMap { $0.isSymbolImage ? nil : Self.glowColor(for: $0) }
            self.superview?.setNeedsLayout()
        }
        contentView.addSubview(cover)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:)") }

    /// The color covering most of the artwork, bright enough to read as
    /// light. By area, not vividness: a navy cover with pink arrows glows
    /// blue.
    private static func glowColor(for image: UIImage) -> UIColor {
        guard let cgImage = image.cgImage else { return UIColor(white: 1, alpha: 0.5) }
        let side = 16
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(
            data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return UIColor(white: 1, alpha: 0.5) }
        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))

        // Twelve hues, plus the grays; each keeps its pixels' sum.
        var buckets: [Int: (count: Int, r: CGFloat, g: CGFloat, b: CGFloat)] = [:]
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let r = CGFloat(pixels[index]) / 255, g = CGFloat(pixels[index + 1]) / 255, b = CGFloat(pixels[index + 2]) / 255
            var hue = CGFloat(0), saturation = CGFloat(0), brightness = CGFloat(0), alpha = CGFloat(0)
            UIColor(red: r, green: g, blue: b, alpha: 1).getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
            let key = saturation < 0.18 || brightness < 0.12 ? -1 : Int(hue * 12) % 12
            let sum = buckets[key] ?? (0, 0, 0, 0)
            buckets[key] = (sum.count + 1, sum.r + r, sum.g + g, sum.b + b)
        }
        let total = CGFloat(side * side)
        func average(_ key: Int) -> UIColor? {
            guard let sum = buckets[key], sum.count > 0 else { return nil }
            let count = CGFloat(sum.count)
            return UIColor(red: sum.r / count, green: sum.g / count, blue: sum.b / count, alpha: 1)
        }
        func light(_ color: UIColor, strength: CGFloat) -> UIColor {
            var hue = CGFloat(0), saturation = CGFloat(0), brightness = CGFloat(0), alpha = CGFloat(0)
            color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
            return UIColor(hue: hue, saturation: min(saturation * 1.1, 1), brightness: max(brightness, 0.75), alpha: strength)
        }
        let colored = buckets.filter { $0.key != -1 }.max { $0.value.count < $1.value.count }
        let grays = CGFloat(buckets[-1]?.count ?? 0)
        if let colored, CGFloat(colored.value.count) >= grays, let color = average(colored.key) {
            return light(color, strength: 1)
        }
        // Mostly black, white or gray: its color, if it has one, glows
        // faintly; otherwise a neutral light as bright as the cover.
        if let colored, CGFloat(colored.value.count) / total > 0.08, let color = average(colored.key) {
            return light(color, strength: 0.55)
        }
        var white = CGFloat(0), alpha = CGFloat(0)
        (average(-1) ?? .black).getWhite(&white, alpha: &alpha)
        return UIColor(white: 1, alpha: 0.12 + 0.45 * white)
    }

    func configure(artwork: ArtworkSource?, zoomID: String, side: CGFloat) {
        loader.load(artwork, into: cover, points: side, placeholder: UIImage(systemName: "music.note"))
        self.zoomID = zoomID
        superview?.setNeedsLayout()
    }
}

private final class CoverImageView: UIImageView {
    var onImage: () -> Void = {}
    override var image: UIImage? { didSet { onImage() } }
}

// MARK: - Genre page

/// The artist page's layout for a genre: its photo edge to edge, then the
/// artists who play it, its albums and every song.
struct GenreDetailView: View {
    let genreName: String
    @EnvironmentObject private var libraryVM: LibraryViewModel

    var body: some View {
        if let genre = libraryVM.genre(named: genreName) {
            let photo = GenreStyle(genre.name).imageName.flatMap { UIImage(named: $0) }
            SongCollectionPage(
                title: genre.name,
                songs: genre.songs,
                photo: photo,
                artwork: photo == nil ? genre.artworkSource : nil,
                placeholderSymbol: "guitars",
                collection: .genre(genre.name),
                sortKey: "genreSongSort"
            )
        } else {
            ContentUnavailableView("Genre Unavailable", systemImage: "guitars")
        }
    }
}

/// Every song in the library, laid out like a genre.
struct AllSongsView: View {
    @EnvironmentObject private var libraryVM: LibraryViewModel

    var body: some View {
        if libraryVM.songs.isEmpty {
            ContentUnavailableView("No Songs", systemImage: "music.note")
        } else {
            SongCollectionPage(
                title: String(localized: "All Songs"),
                songs: libraryVM.songs,
                waves: SongCollectionPage.burgundy,
                collection: .all,
                sortKey: "allSongsSort"
            )
        }
    }
}

/// What a song page derives from its songs, kept between renders: the page
/// renders on every scroll frame, and sorting thousands of songs each time
/// would stutter. (Arrays passed through unchanged compare in constant time.)
/// An artist page's sorted songs, kept until the songs, the sort or the
/// followed album change: sorting hundreds of titles on each pass of the
/// page shows in its scrolling.
@MainActor private final class ArtistSongsCache {
    private var source: [Song]?
    private var sort: DetailSongSort?
    private var album: AlbumID?
    private var list: [Song] = []

    func songs(_ songs: [Song], sort: DetailSongSort, album: Album?) -> [Song] {
        if source != songs || self.sort != sort || self.album != album?.id {
            list = DetailSongSort.songs(songs, sort: sort, album: album)
            source = songs
            self.sort = sort
            self.album = album?.id
        }
        return list
    }
}

@MainActor private final class SongCollectionCache {
    private struct ListKey: Equatable {
        let sort: DetailSongSort
        let album: AlbumID?
    }

    private var source: [Song]?
    private var library: [Album]?
    private(set) var artists: [(name: String, count: Int)] = []
    private(set) var albums: [Album] = []
    /// The artists themselves, for their cards.
    private(set) var artistItems: [Artist] = []
    private var listKey: ListKey?
    private var list: [Song] = []

    func update(songs: [Song], library: [Album], artist: (String) -> Artist?) {
        guard source != songs || self.library != library else { return }
        source = songs
        self.library = library
        listKey = nil
        artists = SongCollectionPage.artists(in: songs)
        albums = SongCollectionPage.albums(in: songs, from: library)
        artistItems = artists.compactMap { artist($0.name) }
    }

    func songs(sort: DetailSongSort, album: Album?) -> [Song] {
        let key = ListKey(sort: sort, album: album?.id)
        if listKey != key {
            list = DetailSongSort.songs(source ?? [], sort: sort, album: album)
            listKey = key
        }
        return list
    }
}

/// How far the header is pulled down past the top.
@Observable @MainActor private final class HeaderStretch {
    var value: CGFloat = 0
}

/// The bar's state, which only changes at two scroll positions.
private struct PageChrome: Equatable {
    var showsTitle = false
    var showsEdge = false
}

/// The genre page's layout for any set of songs: artwork edge to edge, then
/// their albums, their artists and every song.
struct SongCollectionPage: View {
    let title: String
    let allSongs: [Song]
    let photo: UIImage?
    let artwork: ArtworkSource?
    let placeholderSymbol: String
    /// Where the Albums header leads.
    let collection: SongCollection?
    @EnvironmentObject private var libraryVM: LibraryViewModel
    /// Not observed: the player publishes on every lyric line, and each
    /// render re-diffs every row.
    @Environment(\.appServices) private var services
    /// Only the header reads it, and the page only learns when the title or
    /// the bar's edge flips: re-rendering the page (and re-diffing thousands
    /// of rows) on every scroll frame made the list stutter.
    @State private var stretch = HeaderStretch()
    @State private var chrome = PageChrome()
    @AppStorage("artistCoverFlow") private var showsCoverFlow = true
    @AppStorage private var sortRawValue: String
    @AppStorage("detailSongsFollowAlbum") private var followsAlbum = false
    @State private var centeredAlbum = 0
    /// The Songs header has reached the top bar: the albums are gone.
    @State private var reachedSongs = false
    @State private var cache = SongCollectionCache()

    /// `sortKey` keeps each kind of page's song order apart.
    init(title: String, songs: [Song], photo: UIImage? = nil, artwork: ArtworkSource?, placeholderSymbol: String = "music.note", collection: SongCollection?, sortKey: String) {
        self.title = title
        self.allSongs = songs
        self.photo = photo
        self.artwork = artwork
        self.placeholderSymbol = placeholderSymbol
        self.collection = collection
        _sortRawValue = AppStorage(wrappedValue: DetailSongSort.title.rawValue, sortKey)
    }

    /// Pages with no face of their own get the playlists' waves, in `palette`.
    init(title: String, songs: [Song], palette: CoverPalette, collection: SongCollection?, sortKey: String) {
        self.init(title: title, songs: songs, waves: palette.colors, collection: collection, sortKey: sortKey)
    }

    typealias WavesColors = (start: CoverPalette.RGB, end: CoverPalette.RGB, glow: CoverPalette.RGB)

    init(title: String, songs: [Song], waves colors: WavesColors, collection: SongCollection?, sortKey: String) {
        self.init(title: title, songs: songs, photo: Self.waves(colors), artwork: nil, collection: collection, sortKey: sortKey)
    }

    /// All Songs' wine red.
    static let burgundy: WavesColors = (CoverPalette.RGB(140, 18, 48), CoverPalette.RGB(52, 4, 20), CoverPalette.RGB(220, 80, 110))

    @MainActor private static var wavesImages: [String: UIImage] = [:]

    @MainActor private static func waves(_ colors: WavesColors) -> UIImage {
        let key = "\(colors.start)-\(colors.end)-\(colors.glow)"
        if let image = wavesImages[key] { return image }
        let image = GeneratedCoverRenderer.wavesBanner(colors: colors, size: CGSize(width: 440, height: 520), scale: 3)
        wavesImages[key] = image
        return image
    }

    var body: some View {
        let _ = cache.update(songs: allSongs, library: libraryVM.albums) { [libraryVM] in libraryVM.artist(named: $0) }
        let artists = cache.artists
        let albums = cache.albums
        let albumOnly = followsAlbum && showsCoverFlow && albums.count > 1 && albums[safe: centeredAlbum] != nil
        let sort = DetailSongSort(rawValue: sortRawValue) ?? .title
        let songs = cache.songs(sort: sort, album: albumOnly ? albums[safe: centeredAlbum] : nil)
        let pageColor = Color(uiColor: photo.map(Self.pageColor) ?? Song.albumBackgroundUIColor(for: artwork))
        GeometryReader { proxy in
            let size = CGSize(width: proxy.size.width, height: proxy.size.height + proxy.safeAreaInsets.top + proxy.safeAreaInsets.bottom)
            let headerHeight = CollectionHeaderStyle.artworkHeight(in: size)
            // Wider than tall: the square photo, its buttons, the albums and
            // artists on the left, the songs alone on the right.
            let split = CollectionHeaderStyle.isSplit(in: size)
            let column = CollectionHeaderStyle.splitColumnWidth(in: size)
            HStack(spacing: 0) {
            if split {
                SplitColumn(color: pageColor, width: column) {
                    GenreHeader(
                        title: title,
                        songs: allSongs,
                        detail: Self.detail(artists: artists.count, songs: allSongs.count),
                        photo: photo,
                        artwork: artwork,
                        placeholderSymbol: placeholderSymbol,
                        pageColor: pageColor,
                        height: CollectionHeaderStyle.splitSquareSide(column: column),
                        topInset: proxy.safeAreaInsets.top,
                        stretch: HeaderStretch(),
                        trailingExtension: column - CollectionHeaderStyle.splitSquareSide(column: column)
                    )
                    shelves(albums: albums, artists: artists, width: column, pageColor: pageColor, inList: false)
                }
            }
            List {
                if !split {
                GenreHeader(
                    title: title,
                    songs: allSongs,
                    detail: Self.detail(artists: artists.count, songs: allSongs.count),
                    photo: photo,
                    artwork: artwork,
                    placeholderSymbol: placeholderSymbol,
                    pageColor: pageColor,
                    height: headerHeight,
                    topInset: proxy.safeAreaInsets.top,
                    stretch: stretch
                )
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(pageColor)
                }

                if !split {
                    shelves(albums: albums, artists: artists, width: proxy.size.width, pageColor: pageColor, inList: true)
                }

                SectionHeader(title: "Songs")
                    .onGeometryChange(for: Bool.self) { $0.frame(in: .global).minY < proxy.safeAreaInsets.top + 8 } action: { reachedSongs = $0 }
                    .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 4, trailing: 20))
                    .listRowSeparator(.hidden)
                    .listRowBackground(pageColor)
                ForEach(songs) { song in
                    SongRow(song: song, subtitle: song.artist, trackNumber: albumOnly ? max(song.trackNumber, 0) : nil)
                        .onTapGesture { services.playerVM.play(song: song, from: songs) }
                        .contextMenu { SongContextMenu(song: song) }
                        .swipeActions(edge: .leading) { QueueSwipeButtons(song: song) }
                            .swipeActions(edge: .trailing) { SwipeLeftButtons(song: song, context: .artist) }
                        .listRowInsets(EdgeInsets(top: 6, leading: 20, bottom: 6, trailing: 20))
                        .alignmentGuide(.listRowSeparatorLeading) { _ in 56 }
                        .listRowSeparatorTint(.white.opacity(0.14))
                        .listRowBackground(pageColor)
                }
                Text(Self.footer(for: songs, albums: albumOnly ? 1 : albums.count))
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.6))
                    .listRowInsets(EdgeInsets(top: 14, leading: 20, bottom: 28, trailing: 20))
                    .listRowSeparator(.hidden)
                    .listRowBackground(pageColor)
            }
            .listStyle(.plain)
            .alphabetIndex(songs, isShown: sort == .title && !albumOnly && reachedSongs, topInset: proxy.safeAreaInsets.top)
            .scrollContentBackground(.hidden)
            .contentMargins(.top, split ? proxy.safeAreaInsets.top : 0, for: .scrollContent)
            .scrollIndicators(.hidden)
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y + $0.contentInsets.top } action: { _, value in
                let pulled = split ? 0 : max(0, -value)
                if stretch.value != pulled { stretch.value = pulled }
                let next = split
                    ? PageChrome(showsTitle: false, showsEdge: value > 0)
                    : PageChrome(
                        showsTitle: value > headerHeight - proxy.safeAreaInsets.top - 20,
                        showsEdge: value >= headerHeight - proxy.safeAreaInsets.top - 56
                    )
                if next != chrome { chrome = next }
            }
            .scrollEdgeEffectHidden(!chrome.showsEdge, for: .top)
            .ignoresSafeArea(edges: .top)
            .pageTitle(chrome.showsTitle ? title : "", large: false)
            .pageTrailingItem { menu.tint(.menuTint(from: photo.map(Self.pageColor) ?? Song.albumBackgroundUIColor(for: artwork))) }
            }
        }
        .background(pageColor)
        .environment(\.pageTint, .contentTint(from: photo.map(Self.pageColor) ?? Song.albumBackgroundUIColor(for: artwork)))
        .tint(.white)
        .environment(\.colorScheme, .dark)
    }

    /// The albums and artists: rows of the list, or the left column's
    /// shelves on a split page.
    @ViewBuilder
    private func shelves(albums: [Album], artists: [(name: String, count: Int)], width: CGFloat, pageColor: Color, inList: Bool) -> some View {
        if !albums.isEmpty {
            Group {
                if let collection {
                    RouteLink(.collectionAlbums(collection)) {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            SectionHeader(title: "Albums")
                            Image(systemName: "chevron.forward")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else {
                    SectionHeader(title: "Albums")
                }
            }
            .shelfRow(EdgeInsets(top: 12, leading: 20, bottom: 0, trailing: 20), color: pageColor, inList: inList)
            Group {
                if showsCoverFlow && albums.count > 1 {
                    AlbumCoverFlow(albums: albums, width: width, glows: false) { centeredAlbum = $0 }
                } else {
                    AlbumCarousel(albums: albums)
                }
            }
            .shelfRow(EdgeInsets(top: 4, leading: 0, bottom: 8, trailing: 0), color: pageColor, inList: inList)
        }

        if artists.count > 1 {
            SectionHeader(title: "Artists")
                .shelfRow(EdgeInsets(top: 12, leading: 20, bottom: 0, trailing: 20), color: pageColor, inList: inList)
            Group {
                if showsCoverFlow {
                    ArtistCardCoverFlow(artists: cache.artistItems)
                        .frame(height: ArtistCardFlowView.height)
                } else {
                    GenreArtistRow(artists: artists)
                }
            }
            .shelfRow(EdgeInsets(top: 4, leading: 0, bottom: 8, trailing: 0), color: pageColor, inList: inList)
        }
    }

    private var menu: some View {
        Menu {
            Section {
                Toggle(isOn: $showsCoverFlow.animation(.smooth)) {
                    Label("Cover Flow", systemImage: "rectangle.stack")
                }
            }
            DetailSongSortSection(sortRawValue: $sortRawValue, followsAlbum: $followsAlbum, choices: DetailSongSort.genreChoices, canFollow: showsCoverFlow)
        } label: {
            BarIcon("More", systemImage: "ellipsis")
                .foregroundStyle(.white)
        }
    }

    /// The songs' artists, those with the most of them first.
    fileprivate static func artists(in songs: [Song]) -> [(name: String, count: Int)] {
        Dictionary(grouping: songs, by: LibraryIndex.artistName(for:))
            .map { (name: $0.key, count: $0.value.count) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Albums with at least one of the songs, newest first.
    fileprivate static func albums(in songs: [Song], from all: [Album]) -> [Album] {
        let ids = Set(songs.map(\.id))
        return all
            .filter { $0.songs.contains { ids.contains($0.id) } }
            .sorted { ($0.year == 0 ? Int.max : -$0.year, $0.title) < ($1.year == 0 ? Int.max : -$1.year, $1.title) }
    }

    /// Sampling the full photo on every render would be wasteful.
    @MainActor private static var pageColors: [ObjectIdentifier: UIColor] = [:]

    @MainActor private static func pageColor(for image: UIImage) -> UIColor {
        if let color = pageColors[ObjectIdentifier(image)] { return color }
        let small = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).image { _ in
            image.draw(in: CGRect(x: 0, y: 0, width: 32, height: 32))
        }
        let color = Song.pageUIColor(for: small)
        pageColors[ObjectIdentifier(image)] = color
        return color
    }

    private static func detail(artists: Int, songs: Int) -> String {
        guard artists > 1 else { return String(localized: "\(songs) songs") }
        return String(localized: "\(artists) artists · \(songs) songs")
    }

    private static func footer(for songs: [Song], albums: Int) -> String {
        let minutes = Int(songs.reduce(0) { $0 + max(0, $1.duration) }) / 60
        let duration = minutes >= 60 ? String(localized: "\(minutes / 60) hr \(minutes % 60) min") : String(localized: "\(minutes) min")
        guard albums > 0 else { return String(localized: "\(songs.count) songs, \(duration)") }
        return String(localized: "\(albums) albums, \(songs.count) songs, \(duration)")
    }
}

/// A split page's left column: the square artwork and its buttons, then
/// the shelves, scrolling on their own from the top of the screen; the
/// songs keep the right side.
private struct SplitColumn<Content: View>: View {
    let color: Color
    let width: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            VStack(spacing: 0) { content() }
                .padding(.bottom, 20)
        }
        .scrollIndicators(.hidden)
        // The square artwork runs up under the status bar and the buttons,
        // its own gradient keeping them readable.
        .scrollEdgeEffectHidden(true, for: .top)
        .ignoresSafeArea(edges: .top)
        .frame(width: width)
        .background(color)
        .overlay(alignment: .trailing) { SplitColumnEdge(color: color).ignoresSafeArea(edges: .top) }
    }
}

private extension View {
    /// A shelf as a list row, or padded alike in a split page's column.
    @ViewBuilder
    func shelfRow(_ insets: EdgeInsets, color: Color, inList: Bool) -> some View {
        if inList {
            listRowInsets(insets)
                .listRowSeparator(.hidden)
                .listRowBackground(color)
        } else {
            padding(insets)
        }
    }
}

/// The header column's right edge on a split page, melting into the page
/// like the album and playlist columns.
private struct SplitColumnEdge: View {
    let color: Color

    var body: some View {
        LinearGradient(
            stops: [(0, 0) as (CGFloat, Double), (0.2, 0.1), (0.4, 0.3), (0.6, 0.58), (0.8, 0.84), (1, 1)].map {
                Gradient.Stop(color: color.opacity($0.1), location: $0.0)
            },
            startPoint: .leading,
            endPoint: .trailing
        )
        .frame(width: 72)
        .allowsHitTesting(false)
    }
}

/// The artist header, with the genre's photo; without one, the top album's
/// cover blurred, as on artist pages.
private struct GenreHeader: View {
    let title: String
    let songs: [Song]
    let detail: String
    let photo: UIImage?
    let artwork: ArtworkSource?
    let placeholderSymbol: String
    let pageColor: Color
    let height: CGFloat
    let topInset: CGFloat
    let stretch: HeaderStretch
    /// On a split page: the width of the blurred extension on the right,
    /// beside the square artwork kept on the left.
    var trailingExtension: CGFloat = 0
    @Environment(\.appServices) private var services

    var body: some View {
        let stretch = stretch.value
        ZStack(alignment: .bottom) {
            SideExtendedArtwork(artwork: artwork, photo: photo, leadingSquare: trailingExtension > 0) {
                if let photo {
                    Image(uiImage: photo)
                        .resizable()
                        .scaledToFill()
                } else {
                    ArtworkImage(source: artwork, cornerRadius: 0, points: height, placeholderSymbol: placeholderSymbol)
                        .blur(radius: 18, opaque: true)
                }
            }
            .frame(height: height + stretch)
            .frame(maxWidth: .infinity)

            LinearGradient(colors: [.black.opacity(0.32), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: topInset + 40 + stretch)
                .frame(maxHeight: .infinity, alignment: .top)

            LinearGradient(
                stops: [(0, 0) as (CGFloat, Double), (0.14, 0.08), (0.28, 0.22), (0.42, 0.42), (0.58, 0.64), (0.76, 0.85), (1, 1)].map {
                    Gradient.Stop(color: pageColor.opacity($0.1), location: $0.0)
                },
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: height * 0.45)

            // On a split page the photo melts into the songs' side the same
            // way it melts into the page below.
            if trailingExtension > 0 {
                LinearGradient(
                    stops: [(0, 0) as (CGFloat, Double), (0.14, 0.08), (0.28, 0.22), (0.42, 0.42), (0.58, 0.64), (0.76, 0.85), (1, 1)].map {
                        Gradient.Stop(color: pageColor.opacity($0.1), location: $0.0)
                    },
                    startPoint: .leading,
                    endPoint: .trailing
                )
                // Over the blurred extension only: the square stays whole.
                .frame(width: trailingExtension)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            }

            VStack(spacing: 20) {
                VStack(spacing: 2) {
                    Text(title)
                        .font(.largeTitle.bold())
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                        .multilineTextAlignment(.center)
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.7))
                }
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.2), radius: 8)
                ArtistPlayButtons(
                    onShuffle: { services.playerVM.play(songs, shuffled: true) },
                    onPlay: { services.playerVM.play(songs, shuffled: false) }
                )
                .frame(maxWidth: 340)
                .frame(height: 48)
                .padding(.horizontal, 12)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .frame(height: height, alignment: .bottom)
        .frame(maxWidth: .infinity)
    }
}

/// A set of songs with a page of its own, whose albums open in a grid.
enum SongCollection: Hashable {
    case genre(String)
    case all
    /// The songs whose lyrics are of this kind; nil for those without any.
    case lyrics(LyricsSyncKind?)

    /// Nil while the lyrics kinds are still being worked out.
    @MainActor func songs(in libraryVM: LibraryViewModel, index: LyricsSyncIndex) -> [Song]? {
        switch self {
        case let .genre(name):
            return libraryVM.genre(named: name)?.songs ?? []
        case .all:
            return libraryVM.songs
        case .lyrics(nil):
            return libraryVM.songs.filter { !LyricsSyncIndex.hasLyrics($0) }
        case let .lyrics(kind?):
            guard let kinds = index.kinds else { return nil }
            return libraryVM.songs.filter { kinds[$0.id] == kind }
        }
    }
}

/// The albums of a song page, laid out like the Albums tab.
struct CollectionAlbumsView: View {
    let collection: SongCollection
    @EnvironmentObject private var libraryVM: LibraryViewModel
    @ObservedObject private var index = LyricsSyncIndex.shared

    var body: some View {
        let songs = collection.songs(in: libraryVM, index: index)
        AlbumGridView(songIDs: Set((songs ?? []).map(\.id)))
            .task(id: LyricsSyncIndex.signature(of: libraryVM.songs)) {
                if case .lyrics = collection { index.refresh(libraryVM.songs) }
            }
    }
}

/// Round artist photos with their names, as in Music's artist shelves.
private struct GenreArtistRow: View {
    let artists: [(name: String, count: Int)]
    @EnvironmentObject private var libraryVM: LibraryViewModel

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 16) {
                ForEach(artists, id: \.name) { artist in
                    RouteLink(.artist(artist.name)) {
                        VStack(spacing: 6) {
                            ArtistAvatarView(artistName: artist.name, songs: libraryVM.artist(named: artist.name)?.songs ?? [], size: 96)
                            VStack(spacing: 0) {
                                Text(artist.name)
                                    .font(.footnote.weight(.medium))
                                    .lineLimit(1)
                                Text("\(artist.count) songs")
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.6))
                            }
                        }
                        .frame(width: 96)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .scrollTargetLayout()
        }
        .scrollIndicators(.hidden)
        .scrollTargetBehavior(.viewAligned)
        .contentMargins(.horizontal, 20, for: .scrollContent)
    }
}

// MARK: - Song order

/// How an artist's or a genre's songs are listed under the albums.
enum DetailSongSort: String, CaseIterable {
    case album, title, artist, year, mostPlayed, recentlyAdded

    static let artistChoices: [DetailSongSort] = [.title, .album, .year, .mostPlayed, .recentlyAdded]
    static let genreChoices: [DetailSongSort] = [.title, .artist, .album, .year, .mostPlayed, .recentlyAdded]

    var title: String {
        switch self {
        case .album: String(localized: "Album")
        case .title: String(localized: "Title")
        case .artist: String(localized: "Artist")
        case .year: String(localized: "Release Date")
        case .mostPlayed: String(localized: "Most Played")
        case .recentlyAdded: String(localized: "Recently Added")
        }
    }

    /// The songs in this order; only those of `album` when one is given,
    /// then always in track order.
    static func songs(_ songs: [Song], sort: DetailSongSort, album: Album?) -> [Song] {
        var songs = songs
        var sort = sort
        if let album {
            let ids = Set(album.songs.map(\.id))
            songs = songs.filter { ids.contains($0.id) }
            sort = .album
        }
        let byTitle = { (a: Song, b: Song) in a.title.localizedStandardCompare(b.title) == .orderedAscending }
        let byTrack = { (a: Song, b: Song) -> Bool in
            if a.album != b.album { return a.album.localizedStandardCompare(b.album) == .orderedAscending }
            return (a.discNumber, a.trackNumber) != (b.discNumber, b.trackNumber)
                ? (a.discNumber, a.trackNumber) < (b.discNumber, b.trackNumber) : byTitle(a, b)
        }
        switch sort {
        case .title: return songs.sorted(by: byTitle)
        case .artist:
            return songs.sorted {
                let order = $0.artist.localizedStandardCompare($1.artist)
                return order != .orderedSame ? order == .orderedAscending : byTitle($0, $1)
            }
        case .album: return songs.sorted(by: byTrack)
        case .year:
            // Newest first, unknown years last; an album keeps its track order.
            return songs.sorted {
                let a = $0.year == 0 ? Int.min : $0.year, b = $1.year == 0 ? Int.min : $1.year
                return a != b ? a > b : byTrack($0, $1)
            }
        case .mostPlayed: return songs.sorted { $0.playCount != $1.playCount ? $0.playCount > $1.playCount : byTitle($0, $1) }
        case .recentlyAdded: return songs.sorted { $0.addedAt != $1.addedAt ? $0.addedAt > $1.addedAt : byTitle($0, $1) }
        }
    }
}

/// The song order and album filter in an artist's or a genre's "…" menu.
private struct DetailSongSortSection: View {
    @Binding var sortRawValue: String
    @Binding var followsAlbum: Bool
    let choices: [DetailSongSort]
    let canFollow: Bool

    var body: some View {
        Section("Songs") {
            Picker(selection: $sortRawValue.animation(.smooth)) {
                ForEach(choices, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
            } label: {
                Label("Sort By", systemImage: "arrow.up.arrow.down")
            }
            .pickerStyle(.menu)
            Toggle(isOn: $followsAlbum.animation(.smooth)) {
                Label("Selected Album Only", systemImage: "square.stack")
            }
            .disabled(!canFollow)
        }
    }
}

// MARK: - Alphabet index

extension View {
    /// A letter index on the trailing edge, jumping to the first song of
    /// each letter; `songs` must be in title order.
    func alphabetIndex(_ songs: [Song], isShown: Bool, topInset: CGFloat = 0) -> some View {
        modifier(AlphabetIndex(songs: songs, isShown: isShown, topInset: topInset))
    }
}

private struct AlphabetIndex: ViewModifier {
    let songs: [Song]
    let isShown: Bool
    /// The bar the list scrolls under, kept clear to center the index.
    let topInset: CGFloat
    @State private var lastLetter: String?

    static func letter(for title: String) -> String {
        // Like the title sort: anything before "A" (quotes, symbols, digits) is "#".
        let first = title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .uppercased().first
        guard let first, first.isLetter, first.isASCII else { return "#" }
        return String(first)
    }

    func body(content: Content) -> some View {
        ScrollViewReader { proxy in
            content.overlay(alignment: .trailing) {
                let targets = firstSongs
                if isShown && targets.count > 1 {
                    let letters = targets.map(\.letter)
                    VStack(spacing: 0) {
                        ForEach(letters, id: \.self) { letter in
                            Text(letter)
                                .font(.system(size: 11, weight: .semibold))
                                .frame(width: 22, height: 15)
                        }
                    }
                    .foregroundStyle(.white)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local).onChanged { value in
                        let index = min(max(Int(value.location.y / 15), 0), letters.count - 1)
                        let target = targets[index]
                        guard target.letter != lastLetter else { return }
                        lastLetter = target.letter
                        UISelectionFeedbackGenerator().selectionChanged()
                        proxy.scrollTo(target.id, anchor: .top)
                    }.onEnded { _ in lastLetter = nil })
                    .padding(.trailing, 2)
                    .padding(.top, topInset)
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: isShown)
        }
    }

    private var firstSongs: [(letter: String, id: UUID)] {
        var seen = Set<String>()
        return songs.compactMap { song in
            let letter = Self.letter(for: song.title)
            return seen.insert(letter).inserted ? (letter, song.id) : nil
        }
    }
}
