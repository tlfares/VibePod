import UIKit
import SwiftUI
import Combine

/// What a playlist's filter row sorts its songs by. Off by default; kept per
/// playlist.
enum PlaylistFilterMode: String, CaseIterable, Identifiable {
    case off, artists, years, genres

    var id: Self { self }

    var title: String {
        switch self {
        case .off: String(localized: "Off")
        case .artists: String(localized: "Artists")
        case .years: String(localized: "Years")
        case .genres: String(localized: "Genres")
        }
    }

    var systemImage: String {
        switch self {
        case .off: "xmark"
        case .artists: "music.mic"
        case .years: "calendar"
        case .genres: "guitars"
        }
    }

    private static let storageKey = "playlistFilterModes"

    static func mode(for playlistID: UUID) -> PlaylistFilterMode {
        let stored = UserDefaults.standard.dictionary(forKey: storageKey) as? [String: String]
        return stored?[playlistID.uuidString].flatMap(PlaylistFilterMode.init(rawValue:)) ?? .off
    }

    static func setMode(_ mode: PlaylistFilterMode, for playlistID: UUID) {
        var stored = UserDefaults.standard.dictionary(forKey: storageKey) as? [String: String] ?? [:]
        stored[playlistID.uuidString] = mode == .off ? nil : mode.rawValue
        UserDefaults.standard.set(stored, forKey: storageKey)
    }
}

/// One card of the row: "All", or an artist, a year or a genre with the
/// songs it keeps.
struct PlaylistFilterEntry: Equatable {
    enum Kind: Equatable {
        case all
        case artist(String)
        case year(Int)
        case genre(String)
    }

    let kind: Kind
    let songIDs: Set<UUID>
    /// For artist photos: tells namesakes apart.
    var albums: [String] = []
    /// Up to three album covers, the most represented first, for the cards
    /// without a photo.
    var covers: [ArtworkSource?] = []
    /// The artist's own cover, as on their Search card: the album picked
    /// for them, or their most represented one.
    var artistCover: ArtworkSource?
    /// Each album's artwork, for the one picked for the artist.
    var albumArtwork: [String: ArtworkSource] = [:]
    /// A year's place in the row: each one gets its own colors.
    var colorIndex = 0
    /// "All"'s colors, from the playlist's own.
    var tint: UIColor?
    /// The playlist's generated cover colors, when it has one.
    var palette: CoverPalette?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.kind == rhs.kind && lhs.songIDs == rhs.songIDs && lhs.tint == rhs.tint && lhs.palette == rhs.palette && lhs.albums == rhs.albums
    }

    var title: String {
        switch kind {
        case .all: String(localized: "All")
        case .artist(let name): name
        case .year(let year): String(year)
        // "Unknown" is the grouping key of untagged songs: translated only here.
        case .genre(let name): name == "Unknown" ? String(localized: "Unknown", comment: "Genre of songs without one") : name
        }
    }

    private static func albumArtwork(of songs: [Song]) -> [String: ArtworkSource] {
        var artwork: [String: ArtworkSource] = [:]
        for song in songs where artwork[song.album] == nil { artwork[song.album] = song.artworkSource }
        return artwork
    }

    /// One cover per album, the albums with the most songs first.
    private static func covers(of songs: [Song]) -> [ArtworkSource?] {
        let byAlbum = Dictionary(grouping: songs, by: \.album)
        let albums = byAlbum.sorted {
            $0.value.count != $1.value.count ? $0.value.count > $1.value.count : $0.key < $1.key
        }
        let covers = albums.prefix(3).map { $0.value.first?.artworkSource }
        return covers.isEmpty ? [nil] : covers
    }

    /// "All" first, then the most represented artists and genres, or the
    /// years newest first.
    /// An artist's cover is the one Search shows: the album picked for them
    /// is looked for in the whole `library`, not only in the playlist.
    static func entries(for songs: [Song], mode: PlaylistFilterMode, library: [Song], tint: UIColor, palette: CoverPalette?) -> [PlaylistFilterEntry] {
        var entries = entries(for: songs, mode: mode)
        if !entries.isEmpty {
            entries[0].tint = tint
            entries[0].palette = palette
        }
        guard mode == .artists else { return entries }
        let names = Set(entries.compactMap { entry -> String? in
            if case .artist(let name) = entry.kind { name } else { nil }
        })
        let byArtist = Dictionary(grouping: library.filter { names.contains(LibraryIndex.artistName(for: $0)) }, by: LibraryIndex.artistName(for:))
        for index in entries.indices {
            guard case .artist(let name) = entries[index].kind, let songs = byArtist[name] else { continue }
            entries[index].albums = Array(Set(songs.map(\.album)))
            entries[index].albumArtwork = albumArtwork(of: songs)
        }
        return entries
    }

    private static func entries(for songs: [Song], mode: PlaylistFilterMode) -> [PlaylistFilterEntry] {
        let all = PlaylistFilterEntry(kind: .all, songIDs: Set(songs.map(\.id)), covers: covers(of: songs))
        switch mode {
        case .off:
            return []
        case .artists:
            let groups = Dictionary(grouping: songs, by: LibraryIndex.artistName(for:))
            return [all] + groups
                .sorted { $0.value.count != $1.value.count ? $0.value.count > $1.value.count : $0.key.libraryCompare($1.key) == .orderedAscending }
                .map { name, songs in
                    PlaylistFilterEntry(kind: .artist(name), songIDs: Set(songs.map(\.id)), albums: Array(Set(songs.map(\.album))), covers: covers(of: songs), artistCover: covers(of: songs).first ?? nil, albumArtwork: albumArtwork(of: songs))
                }
        case .years:
            let groups = Dictionary(grouping: songs.filter { $0.year > 0 }, by: \.year)
            return [all] + groups.keys.sorted(by: >).enumerated().map { index, year in
                PlaylistFilterEntry(kind: .year(year), songIDs: Set(groups[year, default: []].map(\.id)), covers: covers(of: groups[year, default: []]), colorIndex: index)
            }
        case .genres:
            let groups = Dictionary(grouping: songs) { song -> String in
                let genre = song.genre.trimmingCharacters(in: .whitespacesAndNewlines)
                return genre.isEmpty ? "Unknown" : genre
            }
            return [all] + groups
                // Untagged songs are many in local libraries: they come last.
                .sorted { lhs, rhs in
                    if (lhs.key == "Unknown") != (rhs.key == "Unknown") { return rhs.key == "Unknown" }
                    return lhs.value.count != rhs.value.count ? lhs.value.count > rhs.value.count : lhs.key.libraryCompare(rhs.key) == .orderedAscending
                }
                .map { name, songs in
                    PlaylistFilterEntry(kind: .genre(name), songIDs: Set(songs.map(\.id)), covers: covers(of: songs))
                }
        }
    }
}

/// The row above a playlist's songs: wide, low cards in a Cover Flow. The
/// card resting in the middle is the filter.
final class PlaylistFilterRowView: UIView, UICollectionViewDataSource, UICollectionViewDelegate {
    /// Search's browse cards, drawn at their own size and scaled down.
    static let searchCardSize = CGSize(width: 160, height: 108)
    static let cardSize = CGSize(width: 160 * 90 / 108, height: 90)
    static let height: CGFloat = 116

    /// The centered card changed, live while the row slides.
    var onSelect: (Int) -> Void = { _ in }

    private let layout = WideCoverFlowLayout()
    private lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
    private var entries: [PlaylistFilterEntry] = []
    private var centered = 0
    private var selected = 0
    private let feedback = UISelectionFeedbackGenerator()

    override init(frame: CGRect) {
        super.init(frame: frame)
        layout.cardSize = Self.cardSize
        collectionView.backgroundColor = .clear
        collectionView.clipsToBounds = false
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.decelerationRate = .normal
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(PlaylistFilterCell.self, forCellWithReuseIdentifier: PlaylistFilterCell.reuseID)
        addSubview(collectionView)
        clipsToBounds = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:)") }

    override func layoutSubviews() {
        super.layoutSubviews()
        // A little room at the sides of the screen, none lost for the cards.
        collectionView.frame = bounds
    }

    func configure(entries: [PlaylistFilterEntry], selected: Int) {
        let changed = entries != self.entries
        self.entries = entries
        self.selected = min(selected, max(entries.count - 1, 0))
        guard changed else { return }
        collectionView.reloadData()
        collectionView.layoutIfNeeded()
        centered = self.selected
        collectionView.contentOffset.x = CGFloat(self.selected) * layout.step
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        entries.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: PlaylistFilterCell.reuseID, for: indexPath) as! PlaylistFilterCell
        if let entry = entries[safe: indexPath.item] { cell.configure(entry) }
        return cell
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let index = min(max(Int((scrollView.contentOffset.x / layout.step).rounded()), 0), max(entries.count - 1, 0))
        guard index != centered else { return }
        centered = index
        feedback.selectionChanged()
        // Live while sliding, but only on a card the finger lingers on:
        // rebuilding the list for every card flicked past stutters.
        pendingSelect?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.settle() }
        pendingSelect = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        feedback.prepare()
        stopSlide()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { settle() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        settle()
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard indexPath.item != centered || indexPath.item != selected else { return }
        slide(to: CGFloat(indexPath.item) * layout.step)
    }

    private var pendingSelect: DispatchWorkItem?

    private func settle() {
        pendingSelect?.cancel()
        pendingSelect = nil
        guard centered != selected else { return }
        selected = centered
        onSelect(selected)
    }

    // A quick eased slide to a tapped card, like the artist pages' Cover Flow.
    private var slideLink: CADisplayLink?
    private var slideStart: (offset: CGFloat, time: CFTimeInterval) = (0, 0)
    private var slideTarget: CGFloat = 0
    private let slideDuration: CFTimeInterval = 0.28

    private func slide(to x: CGFloat) {
        stopSlide()
        slideStart = (collectionView.contentOffset.x, CACurrentMediaTime())
        slideTarget = x
        let link = CADisplayLink(target: SlideTarget(self), selector: #selector(SlideTarget.tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        slideLink = link
    }

    /// The display link holds its target strongly.
    private final class SlideTarget {
        weak var row: PlaylistFilterRowView?
        init(_ row: PlaylistFilterRowView) { self.row = row }
        @objc func tick() { row?.stepSlide() }
    }

    private func stepSlide() {
        let t = min((CACurrentMediaTime() - slideStart.time) / slideDuration, 1)
        let eased = 1 - pow(1 - t, 3)
        collectionView.contentOffset.x = slideStart.offset + (slideTarget - slideStart.offset) * eased
        guard t >= 1 else { return }
        stopSlide()
        settle()
    }

    private func stopSlide() {
        slideLink?.invalidate()
        slideLink = nil
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil { stopSlide() }
    }
}

// MARK: - Artist cards

/// A genre-like page's artists as Search's cards, in the playlist filters'
/// Cover Flow. Tapping a side card brings it to the center; tapping the
/// centered one opens the artist.
struct ArtistCardCoverFlow: UIViewRepresentable {
    let artists: [Artist]
    @Environment(\.appServices) private var services
    @Environment(\.routeOpener) private var routeOpener

    func makeUIView(context: Context) -> ArtistCardFlowView { ArtistCardFlowView() }

    func updateUIView(_ view: ArtistCardFlowView, context: Context) {
        let router = services.router
        let opener = routeOpener
        view.onOpen = { name in
            let route = LibraryRoute.artist(name)
            if let opener { opener(route) } else { router.open(route) }
        }
        view.configure(artists: artists)
    }
}

final class ArtistCardFlowView: UIView, UICollectionViewDataSource, UICollectionViewDelegate {
    static let cardSize = PlaylistFilterRowView.searchCardSize
    static let height: CGFloat = cardSize.height + 28

    var onOpen: (String) -> Void = { _ in }

    private let layout = WideCoverFlowLayout()
    private lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
    private var artists: [Artist] = []
    private var centered = 0
    private let feedback = UISelectionFeedbackGenerator()

    override init(frame: CGRect) {
        super.init(frame: frame)
        layout.cardSize = Self.cardSize
        collectionView.backgroundColor = .clear
        collectionView.clipsToBounds = false
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.decelerationRate = .normal
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(ArtistCardFlowCell.self, forCellWithReuseIdentifier: ArtistCardFlowCell.reuseID)
        addSubview(collectionView)
        clipsToBounds = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:)") }

    override func layoutSubviews() {
        super.layoutSubviews()
        collectionView.frame = bounds
    }

    func configure(artists: [Artist]) {
        // A card per name: a changed song count alone needn't reload.
        guard artists.map(\.name) != self.artists.map(\.name) else {
            self.artists = artists
            return
        }
        self.artists = artists
        centered = 0
        collectionView.reloadData()
        collectionView.contentOffset.x = 0
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        artists.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: ArtistCardFlowCell.reuseID, for: indexPath) as! ArtistCardFlowCell
        if let artist = artists[safe: indexPath.item] { cell.configure(artist) }
        return cell
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let index = min(max(Int((scrollView.contentOffset.x / layout.step).rounded()), 0), max(artists.count - 1, 0))
        guard index != centered else { return }
        centered = index
        feedback.selectionChanged()
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        feedback.prepare()
        stopSlide()
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let artist = artists[safe: indexPath.item] else { return }
        if indexPath.item == centered, slideLink == nil {
            onOpen(artist.name)
        } else {
            slide(to: CGFloat(indexPath.item) * layout.step)
        }
    }

    // A quick eased slide to a tapped card, like the playlist filters'.
    private var slideLink: CADisplayLink?
    private var slideStart: (offset: CGFloat, time: CFTimeInterval) = (0, 0)
    private var slideTarget: CGFloat = 0
    private let slideDuration: CFTimeInterval = 0.28

    private func slide(to x: CGFloat) {
        stopSlide()
        slideStart = (collectionView.contentOffset.x, CACurrentMediaTime())
        slideTarget = x
        let link = CADisplayLink(target: SlideTarget(self), selector: #selector(SlideTarget.tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        slideLink = link
    }

    /// The display link holds its target strongly.
    private final class SlideTarget {
        weak var row: ArtistCardFlowView?
        init(_ row: ArtistCardFlowView) { self.row = row }
        @objc func tick() { row?.stepSlide() }
    }

    private func stepSlide() {
        let t = min((CACurrentMediaTime() - slideStart.time) / slideDuration, 1)
        let eased = 1 - pow(1 - t, 3)
        collectionView.contentOffset.x = slideStart.offset + (slideTarget - slideStart.offset) * eased
        guard t >= 1 else { return }
        stopSlide()
    }

    private func stopSlide() {
        slideLink?.invalidate()
        slideLink = nil
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil { stopSlide() }
    }
}

private final class ArtistCardFlowCell: UICollectionViewCell {
    static let reuseID = "ArtistCardFlowCell"

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.25
        layer.shadowRadius = 8
        layer.shadowOffset = CGSize(width: 0, height: 4)
        // Drawn once, not every frame the card turns.
        contentView.layer.shouldRasterize = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:)") }

    override func layoutSubviews() {
        super.layoutSubviews()
        contentView.layer.rasterizationScale = traitCollection.displayScale
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: 12).cgPath
    }

    func configure(_ artist: Artist) {
        contentConfiguration = UIHostingConfiguration {
            ArtistCard(artist: artist)
                .environment(\.colorScheme, .dark)
        }
        .margins(.all, 0)
    }
}

/// Cover Flow for wide cards. A wide card turned as far as a square cover
/// shows mostly its edge, so it turns less, its neighbors sit further out,
/// and the perspective follows its width rather than its height.
final class WideCoverFlowLayout: UICollectionViewLayout {
    var cardSize = CGSize(width: 145, height: 90) { didSet { invalidateLayout() } }
    /// Between the stacked cards' slots.
    var step: CGFloat { cardSize.width * 0.3 }
    /// Extra room either side of the centered card, so its neighbors clear it.
    private var gap: CGFloat { cardSize.width * 0.84 - step }
    private static let turn: CGFloat = .pi * 42 / 180

    private var count: Int { collectionView?.numberOfItems(inSection: 0) ?? 0 }

    override var collectionViewContentSize: CGSize {
        guard let view = collectionView else { return .zero }
        return CGSize(width: CGFloat(max(count - 1, 0)) * step + view.bounds.width, height: view.bounds.height)
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool { true }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        guard let view = collectionView, count > 0 else { return [] }
        let center = view.contentOffset.x / step
        let reach = Int((view.bounds.width / 2 + gap + cardSize.width) / step) + 1
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
        attributes.size = cardSize
        attributes.center = CGPoint(
            x: view.contentOffset.x + view.bounds.width / 2 + position * step + turn * gap,
            y: view.bounds.height / 2
        )
        guard abs(position) > 0.001 else {
            attributes.zIndex = 1000
            return attributes
        }
        var transform = CATransform3DIdentity
        transform.m34 = -1 / (cardSize.width * 2.6)
        let scale = 1 - min(abs(position), 1) * 0.2
        transform = CATransform3DScale(transform, scale, scale, 1)
        transform = CATransform3DRotate(transform, -turn * Self.turn, 0, 1, 0)
        attributes.transform3D = transform
        attributes.zIndex = 1000 - Int(abs(position) * 10)
        // Far down the stack the cards fade into the page.
        attributes.alpha = max(0, 1 - max(abs(position) - 3, 0) * 0.5)
        return attributes
    }

    override func targetContentOffset(forProposedContentOffset proposed: CGPoint, withScrollingVelocity velocity: CGPoint) -> CGPoint {
        let index = (proposed.x / step).rounded()
        return CGPoint(x: min(max(index, 0), CGFloat(max(count - 1, 0))) * step, y: proposed.y)
    }
}

private final class PlaylistFilterCell: UICollectionViewCell {
    static let reuseID = "PlaylistFilterCell"

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.25
        layer.shadowRadius = 8
        layer.shadowOffset = CGSize(width: 0, height: 4)
        // Drawn once, not every frame the card turns.
        contentView.layer.shouldRasterize = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:)") }

    override func layoutSubviews() {
        super.layoutSubviews()
        contentView.layer.rasterizationScale = traitCollection.displayScale
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: 10).cgPath
    }

    func configure(_ entry: PlaylistFilterEntry) {
        contentConfiguration = UIHostingConfiguration { PlaylistFilterCard(entry: entry) }
            .margins(.all, 0)
    }
}

/// Search's own cards, smaller: the artist's photo card (or the fanned
/// covers without one), the genre's photo or emblem, and for "All" and the
/// years, the covers or a waves banner.
private struct PlaylistFilterCard: View {
    let entry: PlaylistFilterEntry
    @ObservedObject private var photos = ArtistImageService.shared

    var body: some View {
        let full = PlaylistFilterRowView.searchCardSize
        let size = PlaylistFilterRowView.cardSize
        card
            .frame(width: full.width, height: full.height)
            .scaleEffect(size.height / full.height)
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, .dark)
    }

    @ViewBuilder private var card: some View {
        switch entry.kind {
        case .all:
            AllCard(title: entry.title, tint: entry.tint ?? .darkGray, palette: entry.palette)
        case .artist(let name):
            if let photo = photos.photo(for: name, albums: entry.albums)
                ?? photos.coverAlbum(for: name).flatMap({ entry.albumArtwork[$0] })
                ?? entry.artistCover {
                ArtistPhotoCard(title: name, photo: photo)
            } else {
                BrowseCard(title: name, covers: entry.covers, placeholderSymbol: "music.microphone")
            }
        case .year(let year):
            WavesCard(title: String(year), palette: WavesCard.yearPalettes[entry.colorIndex % WavesCard.yearPalettes.count])
        case .genre(let name):
            let style = GenreStyle(name)
            if let image = style.image {
                PhotoCard(title: entry.title) { _ in
                    Image(uiImage: image).resizable().scaledToFill()
                }
            } else {
                GenreIllustrationCard(title: entry.title, style: style)
            }
        }
    }
}

/// "All" on the same waves as the years, in the playlist cover's colors:
/// the page under it is a darkened shade of them, so it stands out.
private struct AllCard: View {
    let title: String
    let tint: UIColor
    let palette: CoverPalette?
    private static let cache = NSCache<NSString, UIImage>()

    var body: some View {
        ZStack(alignment: .topLeading) {
            Image(uiImage: palette.map(Self.banner(for:)) ?? Self.banner(for: tint))
                .resizable()
                .scaledToFill()
            Text(title)
                .font(.system(size: 30, weight: .heavy))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
                .padding(12)
        }
        .frame(height: 108)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay { GlassRim(cornerRadius: 12) }
    }

    private static func banner(for palette: CoverPalette) -> UIImage {
        let key = palette.rawValue as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let image = GeneratedCoverRenderer.wavesBanner(palette: palette, size: PlaylistFilterRowView.searchCardSize, scale: 3)
        cache.setObject(image, forKey: key)
        return image
    }

    /// Artwork covers: the page color is the artwork's, darkened; brought
    /// back up to the cover's own.
    private static func banner(for tint: UIColor) -> UIImage {
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        tint.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        let key = String(format: "%.3f-%.3f-%.3f", hue, saturation, brightness) as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let shifted = hue
        func rgb(_ h: CGFloat, _ s: CGFloat, _ b: CGFloat) -> CoverPalette.RGB {
            var r: CGFloat = 0, g: CGFloat = 0, bl: CGFloat = 0
            UIColor(hue: h, saturation: min(1, s), brightness: min(1, b), alpha: 1).getRed(&r, green: &g, blue: &bl, alpha: nil)
            return CoverPalette.RGB(Double(r) * 255, Double(g) * 255, Double(bl) * 255)
        }
        let colors = (
            start: rgb(shifted, saturation, brightness * 2.2 + 0.1),
            end: rgb(shifted, saturation * 1.05, brightness * 1.5 + 0.05),
            glow: rgb(shifted, saturation * 0.6, brightness * 2.6 + 0.3)
        )
        let image = GeneratedCoverRenderer.wavesBanner(colors: colors, size: PlaylistFilterRowView.searchCardSize, scale: 3)
        cache.setObject(image, forKey: key)
        return image
    }
}

/// A year on the playlists' waves, each year of the row in its own colors.
private struct WavesCard: View {
    let title: String
    let palette: CoverPalette
    /// Every palette but the greys, ordered so neighbors contrast.
    static let yearPalettes: [CoverPalette] = [
        .ember, .lagoon, .orchid, .lime, .ocean, .peach, .indigo,
        .mint, .cherry, .forest, .sunrise, .dusk, .rose, .midnight
    ]
    private static let cache = NSCache<NSString, UIImage>()

    var body: some View {
        ZStack(alignment: .topLeading) {
            Image(uiImage: Self.banner(palette))
                .resizable()
                .scaledToFill()
            Text(title)
                .font(.system(size: 30, weight: .heavy))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
                .padding(12)
        }
        .frame(height: 108)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay { GlassRim(cornerRadius: 12) }
    }

    private static func banner(_ palette: CoverPalette) -> UIImage {
        let key = palette.rawValue as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let image = GeneratedCoverRenderer.wavesBanner(palette: palette, size: PlaylistFilterRowView.searchCardSize, scale: 3)
        cache.setObject(image, forKey: key)
        return image
    }
}
