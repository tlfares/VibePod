import SwiftUI
import UIKit
import Combine

struct AlbumDetailView: View {
    let albumID: AlbumID
    @EnvironmentObject private var libraryVM: LibraryViewModel
    @EnvironmentObject private var playerVM: PlayerViewModel

    var body: some View {
        if let album = libraryVM.album(withID: albumID) {
            AlbumDetailRepresentable(album: album)
                .ignoresSafeArea()
                .background(Color(uiColor: Song.albumBackgroundUIColor(for: album.artworkSource)))
                .pageTitle("", large: false)
                .pageTrailingItem {
                    Menu {
                        HomeItemMenu(item: .album(album))
                    } label: {
                        BarIcon("More", systemImage: "ellipsis")
                            .foregroundStyle(.white)
                    }
                    .tint(.menuTint(from: Song.albumBackgroundUIColor(for: album.artworkSource)))
                }
                .environment(\.colorScheme, .dark)
        } else {
            ContentUnavailableView("Album Unavailable", systemImage: "square.stack")
        }
    }
}

private struct AlbumDetailRepresentable: UIViewControllerRepresentable {
    let album: Album
    @Environment(\.appServices) private var services

    func makeUIViewController(context: Context) -> CollectionSplitController<AlbumDetailViewController> {
        CollectionSplitController(page: AlbumDetailViewController(libraryVM: services.libraryVM, playerVM: services.playerVM, router: services.router))
    }

    func updateUIViewController(_ controller: CollectionSplitController<AlbumDetailViewController>, context: Context) {
        controller.page.configure(album: album)
    }
}

final class AlbumDetailViewController: UITableViewController, SplitCollectionPage {
    private let libraryVM: LibraryViewModel
    private let playerVM: PlayerViewModel
    private let router: AppRouter
    private let headerView = AlbumDetailHeaderView()
    private let fullScreenHeader = FullScreenArtworkHeaderView()
    private var isFullScreen = CollectionHeaderStyle.isFullScreen
    private var activeHeader: UIView { isFullScreen ? fullScreenHeader : headerView }
    private let footerLabel = UILabel()
    private var album: Album?
    private(set) var accentColor = UIColor.black {
        didSet { applyPageColor() }
    }
    private var renderedToken: Int?
    private var cancellables = Set<AnyCancellable>()
    /// Album artist differs per track (compilations): show each track's artist.
    private var showsTrackArtists = false
    /// The header stands beside the songs (`CollectionSplitController`).
    private var isSplit = false
    private let splitSpacer = UIView()
    /// What the header and footer were last sized for: the table lays out on
    /// every scroll frame, and measuring them each time cost frames.
    private var sizedFor: CollectionHeaderSizeKey?
    var splitHeader: FullScreenArtworkHeaderView { fullScreenHeader }

    func setSplit(_ split: Bool) {
        isSplit = split
        fullScreenHeader.removeFromSuperview()
        fullScreenHeader.stretch = 0
        tableView.topEdgeEffect.isHidden = false
        applyPageColor()
        sizeHeaderAndFooter(force: true)
        if !split, isFullScreen { fullScreenHeader.followScroll(of: tableView) }
    }

    init(libraryVM: LibraryViewModel, playerVM: PlayerViewModel, router: AppRouter) {
        self.libraryVM = libraryVM
        self.playerVM = playerVM
        self.router = router
        super.init(style: .plain)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:)") }

    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = .dark
        tableView.separatorColor = UIColor.white.withAlphaComponent(0.14)
        tableView.separatorInset = UIEdgeInsets(top: 0, left: 52, bottom: 0, right: 20)
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 52
        tableView.showsVerticalScrollIndicator = false
        tableView.register(AlbumSongTableCell.self, forCellReuseIdentifier: AlbumSongTableCell.reuseID)

        footerLabel.font = .preferredFont(forTextStyle: .footnote)
        footerLabel.textColor = UIColor.white.withAlphaComponent(0.6)
        footerLabel.numberOfLines = 0

        let play: () -> Void = { [weak self] in
            guard let self, let songs = self.album?.songs else { return }
            self.playerVM.play(songs, shuffled: self.playerVM.shuffleMode == .on)
        }
        let shuffle: () -> Void = { [weak self] in
            self?.playerVM.toggleShuffle()
        }
        let openArtist: () -> Void = { [weak self] in
            guard let self, let album = self.album, self.libraryVM.artist(named: album.artist) != nil else { return }
            self.router.open(.artist(album.artist))
        }
        headerView.onPlay = play
        headerView.onShuffle = shuffle
        headerView.onArtist = openArtist
        fullScreenHeader.onPlay = play
        fullScreenHeader.onShuffle = shuffle
        fullScreenHeader.onSubtitle = openArtist
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

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateHeaderStyle()
        sizeHeaderAndFooter()
    }

    /// The style may have changed in Settings since this page was built, or
    /// the page turned sideways.
    private func updateHeaderStyle() {
        let fullScreen = CollectionHeaderStyle.isFullScreen(in: view.bounds.size)
        guard fullScreen != isFullScreen else { return }
        isFullScreen = fullScreen
        if !fullScreen { tableView.topEdgeEffect.isHidden = false }
        configureHeader()
        sizeHeaderAndFooter(force: true)
    }

    override func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard isFullScreen, !isSplit else { return }
        fullScreenHeader.followScroll(of: scrollView)
    }

    func configure(album: Album) {
        var hasher = Hasher()
        hasher.combine(album.id)
        for song in album.songs {
            hasher.combine(song.id)
            hasher.combine(song.title)
            hasher.combine(song.lrcFilePath)
            hasher.combine(song.year)
        }
        let token = hasher.finalize()
        guard token != renderedToken else { return }
        renderedToken = token
        self.album = album

        accentColor = Song.albumBackgroundUIColor(for: album.artworkSource)
        showsTrackArtists = Set(album.songs.map(\.artist)).count > 1
        configureHeader()
        footerLabel.text = Self.footerText(for: album)
        tableView.reloadData()
        sizeHeaderAndFooter(force: true)
        // The header column fits the title.
        if isSplit { parent?.view.setNeedsLayout() }
    }

    private func configureHeader() {
        guard let album else { return }
        let artistIsLink = libraryVM.artist(named: album.artist) != nil
        if isFullScreen {
            fullScreenHeader.setPageColor(accentColor)
            let details = [album.isSingle ? String(localized: "Single") : nil, album.genre.isEmpty ? nil : album.genre, album.year > 0 ? "\(album.year)" : nil]
            fullScreenHeader.configure(
                title: album.title,
                subtitle: album.artist,
                subtitleIsLink: artistIsLink,
                detail: details.compactMap { $0 }.joined(separator: " · "),
                artwork: album.artworkSource,
                placeholderSymbol: "music.note"
            )
        } else {
            headerView.configure(album: album, accentColor: accentColor, artistIsLink: artistIsLink)
        }
    }

    private func sizeHeaderAndFooter(force: Bool = false) {
        let width = tableView.bounds.width
        guard width > 0 else { return }
        if isFullScreen, !isSplit {
            fullScreenHeader.topInset = tableView.adjustedContentInset.top
            fullScreenHeader.artworkHeight = CollectionHeaderStyle.artworkHeight(in: view.bounds.size)
        }
        let key = CollectionHeaderSizeKey(size: view.bounds.size, topInset: tableView.adjustedContentInset.top, isSplit: isSplit, category: traitCollection.preferredContentSizeCategory)
        guard force || key != sizedFor else { return }
        sizedFor = key

        if isSplit {
            if force || tableView.tableHeaderView !== splitSpacer || abs(splitSpacer.frame.width - width) > 0.5 {
                splitSpacer.frame = CGRect(x: 0, y: 0, width: width, height: 8)
                tableView.tableHeaderView = splitSpacer
            }
        } else {
            let header = activeHeader
            let headerHeight = header.systemLayoutSizeFitting(
                CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
                withHorizontalFittingPriority: .required,
                verticalFittingPriority: .fittingSizeLevel
            ).height
            if force || tableView.tableHeaderView !== header || abs(header.frame.height - headerHeight) > 0.5 || abs(header.frame.width - width) > 0.5 {
                header.translatesAutoresizingMaskIntoConstraints = true
                header.frame = CGRect(x: 0, y: 0, width: width, height: headerHeight)
                tableView.tableHeaderView = header
            }
        }

        let labelSize = footerLabel.sizeThatFits(CGSize(width: width - 40, height: .greatestFiniteMagnitude))
        let footerHeight = labelSize.height + 40
        if force || tableView.tableFooterView == nil || abs((tableView.tableFooterView?.frame.height ?? 0) - footerHeight) > 0.5 || abs((tableView.tableFooterView?.frame.width ?? 0) - width) > 0.5 {
            let footer = UIView(frame: CGRect(x: 0, y: 0, width: width, height: footerHeight))
            footerLabel.frame = CGRect(x: 20, y: 14, width: width - 40, height: labelSize.height)
            footer.addSubview(footerLabel)
            tableView.tableFooterView = footer
        }
    }

    private static func footerText(for album: Album) -> String {
        var lines: [String] = []
        if album.year > 0 { lines.append("\(album.year)") }
        lines.append(String(localized: "\(album.songs.count) songs, \(album.formattedDuration)"))
        return lines.joined(separator: "\n")
    }

    private func refreshVisibleCells() {
        for indexPath in tableView.indexPathsForVisibleRows ?? [] {
            guard let cell = tableView.cellForRow(at: indexPath) as? AlbumSongTableCell else { continue }
            configure(cell, at: indexPath)
        }
    }

    private func configure(_ cell: AlbumSongTableCell, at indexPath: IndexPath) {
        guard let song = album?.songs[safe: indexPath.row] else { return }
        let isCurrent = playerVM.currentSong?.id == song.id
        cell.configure(
            song: song,
            trackNumber: song.trackNumber > 0 ? song.trackNumber : indexPath.row + 1,
            showsArtist: showsTrackArtists,
            isCurrent: isCurrent,
            isPlaying: isCurrent && playerVM.isPlaying,
            lyricsBadge: LyricsBadge.image(for: song.lyricsKind),
            backgroundColor: accentColor
        )
        cell.backgroundColor = rowColor
    }

    /// Split, the list starts on the artwork's blurred side: it lets it show
    /// through, and the split controller paints the page color behind.
    private var rowColor: UIColor { isSplit ? .clear : accentColor }

    private func applyPageColor() {
        guard isViewLoaded else { return }
        view.backgroundColor = rowColor
        tableView.backgroundColor = rowColor
        for cell in tableView.visibleCells { cell.backgroundColor = rowColor }
        if isSplit { parent?.view.backgroundColor = accentColor }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        album?.songs.count ?? 0
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: AlbumSongTableCell.reuseID, for: indexPath) as! AlbumSongTableCell
        configure(cell, at: indexPath)
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let album, let song = album.songs[safe: indexPath.row] else { return }
        playerVM.play(song: song, from: album.songs)
    }

    override func tableView(_ tableView: UITableView, leadingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        album?.songs[safe: indexPath.row].map { SongMenuBuilder.queueSwipeAction(for: $0, playerVM: playerVM) }
    }

    override func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard let song = album?.songs[safe: indexPath.row] else { return nil }
        return SongMenuBuilder.swipeLeftConfiguration(for: song, libraryVM: libraryVM, playerVM: playerVM, router: router, context: .album)
    }

    override func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        guard let song = album?.songs[safe: indexPath.row] else { return nil }
        return fixedContextMenu(identifier: song.id as NSUUID, previewProvider: nil) { [weak self] _ in
            guard let self else { return nil }
            return SongMenuBuilder.menu(for: song, libraryVM: self.libraryVM, playerVM: self.playerVM, router: self.router, showsAlbum: false, tint: .contentTint(from: self.accentColor))
        }
    }
}

extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

final class AlbumDetailHeaderView: UIView {
    var onPlay: (() -> Void)?
    var onShuffle: (() -> Void)?
    var onArtist: (() -> Void)?

    private let artworkView = UIImageView()
    private let artworkShadow = UIView()
    private let titleLabel = UILabel()
    private let artistButton = UIButton(type: .system)
    private let detailLabel = UILabel()
    private let artworkLoader = ArtworkImageLoader()
    private lazy var playButton = Self.makeButton(title: String(localized: "Play"), systemImage: "play.fill") { [weak self] in self?.onPlay?() }
    private lazy var shuffleButton = ShuffleToggleButton { [weak self] in self?.onShuffle?() }

    override init(frame: CGRect) {
        super.init(frame: frame)

        artworkShadow.layer.shadowColor = UIColor.black.cgColor
        artworkShadow.layer.shadowOpacity = 0.35
        artworkShadow.layer.shadowRadius = 24
        artworkShadow.layer.shadowOffset = CGSize(width: 0, height: 12)
        artworkShadow.translatesAutoresizingMaskIntoConstraints = false

        artworkView.contentMode = .scaleAspectFill
        artworkView.clipsToBounds = true
        artworkView.layer.cornerRadius = 10
        artworkView.layer.cornerCurve = .continuous
        artworkView.backgroundColor = UIColor.white.withAlphaComponent(0.12)
        artworkView.tintColor = UIColor.white.withAlphaComponent(0.5)
        artworkView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 72, weight: .medium)
        artworkView.translatesAutoresizingMaskIntoConstraints = false
        artworkShadow.addSubview(artworkView)

        titleLabel.font = UIFont.preferredFont(forTextStyle: .title2).withWeight(.bold)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = .white
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 2

        var artistConfiguration = UIButton.Configuration.plain()
        artistConfiguration.contentInsets = .zero
        artistConfiguration.imagePlacement = .trailing
        artistConfiguration.imagePadding = 4
        artistConfiguration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        artistConfiguration.titleLineBreakMode = .byTruncatingTail
        artistButton.configuration = artistConfiguration
        artistButton.addAction(UIAction { [weak self] _ in self?.onArtist?() }, for: .primaryActionTriggered)

        detailLabel.font = .preferredFont(forTextStyle: .footnote)
        detailLabel.adjustsFontForContentSizeCategory = true
        detailLabel.textColor = UIColor.white.withAlphaComponent(0.6)
        detailLabel.textAlignment = .center

        let buttons = UIStackView(arrangedSubviews: [playButton, shuffleButton])
        buttons.axis = .horizontal
        buttons.spacing = 12

        let textStack = UIStackView(arrangedSubviews: [titleLabel, artistButton, detailLabel])
        textStack.axis = .vertical
        textStack.alignment = .center
        textStack.spacing = 2

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

    func configure(album: Album, accentColor: UIColor, artistIsLink: Bool) {
        artworkLoader.load(album.artworkSource, into: artworkView, points: 260, placeholder: UIImage(systemName: "music.note"))
        titleLabel.text = album.title

        var artistConfiguration = artistButton.configuration ?? .plain()
        artistConfiguration.attributedTitle = AttributedString(album.artist, attributes: AttributeContainer([
            .font: UIFont.preferredFont(forTextStyle: .title3)
        ]))
        artistConfiguration.image = artistIsLink ? UIImage(systemName: "chevron.forward") : nil
        artistConfiguration.baseForegroundColor = UIColor.white.withAlphaComponent(artistIsLink ? 0.92 : 0.75)
        artistButton.configuration = artistConfiguration
        artistButton.isUserInteractionEnabled = artistIsLink

        let details = [album.isSingle ? String(localized: "Single") : nil, album.genre.isEmpty ? nil : album.genre, album.year > 0 ? "\(album.year)" : nil]
            .compactMap { $0 }
        detailLabel.text = details.joined(separator: " · ")
        detailLabel.isHidden = details.isEmpty

        playButton.configuration?.baseForegroundColor = .white
        playButton.tintColor = .white
        shuffleButton.pageColor = accentColor
    }

    private static func makeButton(title: String, systemImage: String, action: @escaping () -> Void) -> UIButton {
        var configuration = UIButton.Configuration.glass()
        configuration.title = title
        configuration.image = UIImage(systemName: systemImage)
        configuration.imagePadding = 6
        configuration.cornerStyle = .capsule
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(textStyle: .headline)
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = .preferredFont(forTextStyle: .headline)
            return attributes
        }
        return UIButton(configuration: configuration, primaryAction: UIAction { _ in action() })
    }
}

/// The round shuffle button of album and playlist pages: it doesn't start
/// anything, it turns shuffle on or off for what Play (or a song) starts.
/// On, it is white with the icon in the page's color.
final class ShuffleToggleButton: UIButton {
    var isOn = false { didSet { if isOn != oldValue { update() } } }
    var pageColor = UIColor.black { didSet { update() } }

    convenience init(action: @escaping () -> Void) {
        self.init(configuration: .glass(), primaryAction: UIAction { _ in action() })
        accessibilityLabel = String(localized: "Shuffle")
        update()
    }

    private func update() {
        var configuration: UIButton.Configuration = isOn ? .prominentGlass() : .glass()
        configuration.image = UIImage(systemName: "shuffle")
        configuration.cornerStyle = .capsule
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(textStyle: .headline)
        configuration.baseForegroundColor = isOn ? pageColor : .white
        tintColor = .white
        self.configuration = configuration
        accessibilityTraits = isOn ? [.button, .selected] : .button
    }
}

final class AlbumSongTableCell: UITableViewCell {
    static let reuseID = "AlbumSongTableCell"

    private let trackLabel = UILabel()
    private let titleLabel = UILabel()
    private let artistLabel = UILabel()
    private let durationLabel = UILabel()
    private let lyricsBadgeView = UIImageView()
    private let downloadBadge = DownloadBadgeView(tint: UIColor.white.withAlphaComponent(0.35))
    private let nowPlayingView = UIImageView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        overrideUserInterfaceStyle = .dark
        let selected = UIView()
        selected.backgroundColor = UIColor.white.withAlphaComponent(0.1)
        selectedBackgroundView = selected

        trackLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .regular)
        trackLabel.textColor = UIColor.white.withAlphaComponent(0.55)
        trackLabel.textAlignment = .center

        titleLabel.font = .preferredFont(forTextStyle: .body)
        titleLabel.textColor = .white
        artistLabel.font = .preferredFont(forTextStyle: .subheadline)
        artistLabel.textColor = UIColor.white.withAlphaComponent(0.6)

        durationLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .regular)
        durationLabel.textColor = UIColor.white.withAlphaComponent(0.55)

        lyricsBadgeView.tintColor = UIColor.white.withAlphaComponent(0.35)
        lyricsBadgeView.contentMode = .scaleAspectFit
        nowPlayingView.contentMode = .scaleAspectFit
        nowPlayingView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .footnote)

        let textStack = UIStackView(arrangedSubviews: [titleLabel, artistLabel])
        textStack.axis = .vertical
        textStack.spacing = 1

        let trailing = UIStackView(arrangedSubviews: [downloadBadge, lyricsBadgeView, durationLabel])
        trailing.axis = .horizontal
        trailing.spacing = 8
        trailing.alignment = .center
        [trailing, lyricsBadgeView, durationLabel].forEach {
            $0.setContentHuggingPriority(.required, for: .horizontal)
            $0.setContentCompressionResistancePriority(.required, for: .horizontal)
        }

        let leading = UIView()
        leading.translatesAutoresizingMaskIntoConstraints = false
        trackLabel.translatesAutoresizingMaskIntoConstraints = false
        nowPlayingView.translatesAutoresizingMaskIntoConstraints = false
        leading.addSubview(trackLabel)
        leading.addSubview(nowPlayingView)

        let row = UIStackView(arrangedSubviews: [leading, textStack, trailing])
        row.axis = .horizontal
        row.spacing = 8
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(row)

        NSLayoutConstraint.activate([
            leading.widthAnchor.constraint(equalToConstant: 28),
            leading.heightAnchor.constraint(equalToConstant: 22),
            trackLabel.centerXAnchor.constraint(equalTo: leading.centerXAnchor),
            trackLabel.centerYAnchor.constraint(equalTo: leading.centerYAnchor),
            nowPlayingView.centerXAnchor.constraint(equalTo: leading.centerXAnchor),
            nowPlayingView.centerYAnchor.constraint(equalTo: leading.centerYAnchor),
            row.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            row.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            row.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:)") }

    func configure(
        song: Song,
        trackNumber: Int,
        showsArtist: Bool,
        isCurrent: Bool,
        isPlaying: Bool,
        lyricsBadge: UIImage?,
        backgroundColor: UIColor
    ) {
        self.backgroundColor = backgroundColor
        trackLabel.text = "\(trackNumber)"
        trackLabel.isHidden = isCurrent
        titleLabel.text = song.title
        titleLabel.textColor = isCurrent ? UIColor.contentTint(from: backgroundColor) : .white
        artistLabel.text = song.artist
        artistLabel.isHidden = !showsArtist
        durationLabel.text = song.formattedDuration
        lyricsBadgeView.image = lyricsBadge
        lyricsBadgeView.isHidden = lyricsBadge == nil
        downloadBadge.configure(song: song)
        NowPlayingIndicator.apply(to: nowPlayingView, isCurrent: isCurrent, isPlaying: isPlaying, tint: UIColor.contentTint(from: backgroundColor))
    }
}

extension UIFont {
    func withWeight(_ weight: UIFont.Weight) -> UIFont {
        let descriptor = fontDescriptor.addingAttributes([
            .traits: [UIFontDescriptor.TraitKey.weight: weight]
        ])
        return UIFont(descriptor: descriptor, size: 0)
    }
}

/// Album, artist, genre and playlist pages always open on their artwork.
enum CollectionHeaderStyle {
    static let isFullScreen = true

    /// Whether a page of this size opens on its artwork: wide ones too,
    /// their sides filled by the blurred artwork.
    static func isFullScreen(in size: CGSize) -> Bool { isFullScreen }

    /// The artwork is square on a page taller than wide. On a wider page (an
    /// iPad, an unfolded iPhone Duo) a square would push the title off
    /// screen, so the artwork becomes a banner cropped from its middle, like
    /// Music on iPad.
    static func artworkHeight(in size: CGSize) -> CGFloat {
        min(size.width, (size.height * 0.6).rounded())
    }

    /// A page wider than tall and wide enough (an iPad or an unfolded iPhone
    /// Duo turned sideways) puts its header beside the songs.
    static func isSplit(in size: CGSize) -> Bool {
        size.width >= 700 && size.width > size.height
    }

    /// The header column of a split artist or genre page, whose photo fills
    /// the column's height with the name and buttons on its faded bottom.
    static func splitColumnWidth(in size: CGSize) -> CGFloat {
        min(max((size.width * 0.42).rounded(), 320), 540)
    }

    /// The artist or genre photo in a split column: a square against the
    /// left edge, the rest of the column its blurred extension.
    static func splitSquareSide(column: CGFloat) -> CGFloat {
        (column * 0.8).rounded()
    }

    /// The header column of a split page: the artwork square against the
    /// leading edge, then its right edge mirrored and blurred, carried on as
    /// far as its bottom edge is below it, so both melt into the page alike.
    /// The artwork is as large as the page allows with the title and buttons
    /// still above the bottom bars. `rest(side)` is what the header needs
    /// under an artwork of that side.
    static func splitColumn(in size: CGSize, safeArea: UIEdgeInsets, rest: (CGFloat) -> CGFloat) -> (width: CGFloat, artworkHeight: CGFloat, sideExtension: CGFloat) {
        let minimum: CGFloat = 200
        let available = size.height - safeArea.bottom
        let maxWidth = min(max((size.width * 0.55).rounded(), 400), 820)
        var side = (maxWidth * 0.75).rounded()
        var sideExtension: CGFloat = 0
        // A few times: a narrower artwork can wrap the title on one more line.
        for _ in 0..<3 {
            let below = rest(side)
            sideExtension = max(below - FullScreenArtworkHeaderView.buttonsCenterFromBottom, 0).rounded()
            side = max(min((available - below).rounded(.down), maxWidth - sideExtension), minimum)
        }
        return (side + sideExtension, side, sideExtension)
    }
}

/// What a collection page's header was last measured for.
struct CollectionHeaderSizeKey: Equatable {
    let size: CGSize
    let topInset: CGFloat
    let isSplit: Bool
    let category: UIContentSizeCategory
}

/// What `CollectionSplitController` needs from the page it holds.
@MainActor protocol SplitCollectionPage: UITableViewController {
    /// The header that leaves the list for its own column.
    var splitHeader: FullScreenArtworkHeaderView { get }
    /// The page color, painted behind the split page's clear list.
    var accentColor: UIColor { get }
    /// Split: the page gives up its header (keeping only what belongs to the
    /// list, like a filter row). Not split: it takes it back on top.
    func setSplit(_ split: Bool)
}

/// Album and playlist pages wider than tall: the artwork on the left with
/// the title and buttons under it, the songs scrolling on the right. Taller
/// than wide, the page is shown whole, as on iPhone.
final class CollectionSplitController<Page: SplitCollectionPage>: UIViewController {
    let page: Page
    private var isSplit = false

    init(page: Page) {
        self.page = page
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:)") }

    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = .dark
        addChild(page)
        view.addSubview(page.view)
        page.didMove(toParent: self)
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        // The sidebar shown or hidden.
        view.setNeedsLayout()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let bounds = view.bounds
        guard bounds.width > 0 else { return }
        view.backgroundColor = page.accentColor
        // The iPad's sidebar floats over the leading edge: the page lays
        // out in the room beside it.
        let leading = view.safeAreaInsets.left
        let room = CGSize(width: bounds.width - leading, height: bounds.height)
        let split = CollectionHeaderStyle.isSplit(in: room)
        if split != isSplit {
            isSplit = split
            page.setSplit(split)
        }
        page.splitHeader.scrollTarget = split ? page.tableView : nil
        guard split else {
            page.splitHeader.sideExtension = 0
            if page.view.frame != bounds { page.view.frame = bounds }
            return
        }
        let header = page.splitHeader
        if header.superview !== view {
            header.removeFromSuperview()
            header.translatesAutoresizingMaskIntoConstraints = true
            view.insertSubview(header, belowSubview: page.view)
        }
        let safeArea = view.safeAreaInsets
        header.topInset = safeArea.top
        func fittingHeight(_ width: CGFloat) -> CGFloat {
            header.systemLayoutSizeFitting(
                CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
                withHorizontalFittingPriority: .required,
                verticalFittingPriority: .fittingSizeLevel
            ).height
        }
        let column = CollectionHeaderStyle.splitColumn(in: room, safeArea: safeArea) { side in
            // The header's height minus its artwork's part below the bars.
            // The text follows the artwork's width, not the column's.
            header.artworkHeight = side
            header.sideExtension = max(header.sideExtension, 1)
            return fittingHeight(side + 1) - (side - safeArea.top)
        }
        header.artworkHeight = column.artworkHeight
        header.sideExtension = column.sideExtension
        let headerFrame = CGRect(x: leading, y: safeArea.top, width: column.width, height: fittingHeight(column.width))
        if header.frame != headerFrame { header.frame = headerFrame }
        // The songs start at the artwork's edge, over its blurred side.
        let listStart = leading + column.artworkHeight
        let pageFrame = CGRect(x: listStart, y: 0, width: bounds.width - listStart, height: bounds.height)
        if page.view.frame != pageFrame { page.view.frame = pageFrame }
    }
}

/// The full-screen header of album and playlist pages: the artwork edge to
/// edge under the bars, kept clean. Below it the artwork carries on as its own
/// bottom edge mirrored and blurred, melting into the page color; the title
/// and Play / Shuffle sit on that extension. Pulling down stretches the
/// artwork.
final class FullScreenArtworkHeaderView: UIView {
    /// In its own column: a scroll over it (the trackpad, a wheel) scrolls
    /// the songs beside it.
    weak var scrollTarget: UIScrollView?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if let scrollTarget, event?.type == .scroll, self.point(inside: point, with: event) { return scrollTarget }
        return super.hitTest(point, with: event)
    }

    var onPlay: (() -> Void)?
    var onShuffle: (() -> Void)?
    var onSubtitle: (() -> Void)?

    /// The table's top inset (status and navigation bars): the artwork rises
    /// behind them.
    var topInset: CGFloat = 0 {
        didSet { if topInset != oldValue { updateArtworkFrame() } }
    }
    /// The artwork's height under the bars, from
    /// `CollectionHeaderStyle.artworkHeight(in:)`.
    var artworkHeight: CGFloat = 0 {
        didSet { if artworkHeight != oldValue { updateArtworkFrame() } }
    }
    /// Overscroll at the top; the artwork grows to fill it.
    var stretch: CGFloat = 0 {
        didSet { if stretch != oldValue { updateArtworkFrame() } }
    }

    /// How far the blurred extension reaches up over the artwork, so the
    /// sharp artwork melts into it instead of meeting it at a seam.
    private static let overlap: CGFloat = 56

    private let artworkContainer = UIView()
    private let artworkView = UIImageView()
    /// On a page wider than tall, the artwork stays whole and square in the
    /// middle; its edges carry on to the sides mirrored and blurred, and the
    /// sharp artwork melts into them.
    private let backdropView = UIImageView()
    private let artworkEdgeMask = CAGradientLayer()
    private let topScrim = CAGradientLayer()
    private let extensionView = UIImageView()
    private let extensionMask = CAGradientLayer()
    private let fade = CAGradientLayer()
    /// A split page's right side: the artwork square against the leading
    /// edge, its right edge mirrored and blurred over `sideExtension` points
    /// (as far as the extension goes below it), and the same fade turned
    /// sideways. The title and buttons center under the artwork.
    private let sideFade = CAGradientLayer()
    private let artworkTrailingMask = CAGradientLayer()
    var sideExtension: CGFloat = 0 {
        didSet {
            guard sideExtension != oldValue else { return }
            if (sideExtension > 0) != (oldValue > 0) { updateSideMode() }
            setNeedsLayout()
        }
    }
    /// From the header's bottom to its buttons' middle, where the extension
    /// below the artwork ends.
    static let buttonsCenterFromBottom: CGFloat = 44
    private var pageCentered: [NSLayoutConstraint] = []
    private var artworkCentered: [NSLayoutConstraint] = []
    /// How much of the artwork, from its bottom, the page color rises into.
    static let fadeRise: CGFloat = 0.45
    /// Eased stops (location, opacity): a linear fade shows a visible band.
    static let fadeStops: [(location: NSNumber, alpha: CGFloat)] = [(0, 0), (0.14, 0.08), (0.28, 0.22), (0.42, 0.42), (0.58, 0.64), (0.76, 0.85), (1, 1)]
    private let titleLabel = UILabel()
    private let subtitleButton = UIButton(type: .system)
    private let detailLabel = UILabel()
    private let artworkLoader = ArtworkImageLoader()
    private lazy var playButton = SongListHeaderView.makeButton(title: String(localized: "Play"), systemImage: "play.fill", color: .white) { [weak self] in self?.onPlay?() }
    private lazy var shuffleButton = ShuffleToggleButton { [weak self] in self?.onShuffle?() }
    private var containerTop: NSLayoutConstraint!
    private var containerHeight: NSLayoutConstraint!
    private var loadedWidth: CGFloat = 0
    private var artwork: ArtworkSource?
    private var placeholderSymbol = "music.note"
    private var extensionTask: Task<Void, Never>?
    private var renderedExtensionSize: CGSize = .zero
    private var renderedArtworkHeight: CGFloat = 0
    private var renderedSideMode = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = false

        artworkContainer.clipsToBounds = true
        artworkContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(artworkContainer)

        backdropView.contentMode = .scaleAspectFill
        backdropView.clipsToBounds = true
        backdropView.translatesAutoresizingMaskIntoConstraints = false
        artworkContainer.addSubview(backdropView)

        artworkEdgeMask.startPoint = CGPoint(x: 0, y: 0.5)
        artworkEdgeMask.endPoint = CGPoint(x: 1, y: 0.5)
        // Eased, like the page fade: a linear edge shows as a band.
        let edge: [(CGFloat, CGFloat)] = [(0, 0), (0.25, 0.2), (0.5, 0.55), (0.75, 0.88), (1, 1)]
        let reach: CGFloat = 0.06
        artworkEdgeMask.colors = (edge + edge.reversed()).map { UIColor.black.withAlphaComponent($0.1).cgColor }
        artworkEdgeMask.locations = (edge.map { $0.0 * reach } + edge.reversed().map { 1 - $0.0 * reach }).map { NSNumber(value: Double($0)) }

        // Linear, like the extension below fading in over the artwork.
        artworkTrailingMask.startPoint = CGPoint(x: 0, y: 0.5)
        artworkTrailingMask.endPoint = CGPoint(x: 1, y: 0.5)
        artworkTrailingMask.colors = [UIColor.black.cgColor, UIColor.black.cgColor, UIColor.clear.cgColor]

        artworkView.contentMode = .scaleAspectFill
        artworkView.clipsToBounds = true
        artworkView.backgroundColor = UIColor.white.withAlphaComponent(0.08)
        artworkView.tintColor = UIColor.white.withAlphaComponent(0.5)
        artworkView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 96, weight: .medium)
        artworkView.translatesAutoresizingMaskIntoConstraints = false
        artworkContainer.addSubview(artworkView)

        // Keeps the bar buttons readable on light artwork.
        topScrim.colors = [UIColor.black.withAlphaComponent(0.32).cgColor, UIColor.black.withAlphaComponent(0).cgColor]
        artworkContainer.layer.addSublayer(topScrim)

        // The mirrored, blurred extension: faded in over the artwork's last
        // points, then covered by the page color as it goes down.
        extensionView.contentMode = .scaleToFill
        extensionView.translatesAutoresizingMaskIntoConstraints = false
        extensionMask.colors = [UIColor.clear.cgColor, UIColor.black.cgColor]
        extensionView.layer.mask = extensionMask
        addSubview(extensionView)
        // One fade for both: it rises over the artwork's lower part and
        // carries on over the extension, under the text.
        layer.insertSublayer(fade, above: extensionView.layer)
        sideFade.startPoint = CGPoint(x: 0, y: 0.5)
        sideFade.endPoint = CGPoint(x: 1, y: 0.5)
        sideFade.isHidden = true
        layer.insertSublayer(sideFade, above: fade)

        titleLabel.font = UIFont.preferredFont(forTextStyle: .title1).withWeight(.bold)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.adjustsFontSizeToFitWidth = true
        titleLabel.minimumScaleFactor = 0.8
        titleLabel.textColor = .white
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 2

        var subtitleConfiguration = UIButton.Configuration.plain()
        subtitleConfiguration.contentInsets = .zero
        subtitleConfiguration.imagePlacement = .trailing
        subtitleConfiguration.imagePadding = 4
        subtitleConfiguration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        subtitleConfiguration.titleLineBreakMode = .byTruncatingTail
        subtitleButton.configuration = subtitleConfiguration
        subtitleButton.addAction(UIAction { [weak self] _ in self?.onSubtitle?() }, for: .primaryActionTriggered)

        detailLabel.font = .preferredFont(forTextStyle: .footnote)
        detailLabel.adjustsFontForContentSizeCategory = true
        detailLabel.textColor = UIColor.white.withAlphaComponent(0.7)
        detailLabel.textAlignment = .center

        let textStack = UIStackView(arrangedSubviews: [titleLabel, subtitleButton, detailLabel])
        textStack.axis = .vertical
        textStack.alignment = .center
        textStack.spacing = 2
        textStack.translatesAutoresizingMaskIntoConstraints = false
        // A soft shadow keeps the text readable on a bright extension.
        textStack.layer.shadowColor = UIColor.black.cgColor
        textStack.layer.shadowOpacity = 0.2
        textStack.layer.shadowRadius = 8
        textStack.layer.shadowOffset = .zero
        addSubview(textStack)

        let buttons = UIStackView(arrangedSubviews: [playButton, shuffleButton])
        buttons.axis = .horizontal
        buttons.spacing = 12
        buttons.translatesAutoresizingMaskIntoConstraints = false
        addSubview(buttons)

        containerTop = artworkContainer.topAnchor.constraint(equalTo: topAnchor)
        containerHeight = artworkContainer.heightAnchor.constraint(equalToConstant: 0)
        // Square while the page allows, else edge to edge.
        let squareArtwork = artworkView.widthAnchor.constraint(equalTo: artworkContainer.heightAnchor)
        squareArtwork.priority = .required - 1
        // A large image must not widen the square past it.
        artworkView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        artworkView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttonsWidth = buttons.widthAnchor.constraint(equalTo: widthAnchor, constant: -64)
        buttonsWidth.priority = .defaultHigh
        let buttonsWidthOnArtwork = buttons.widthAnchor.constraint(equalTo: artworkView.widthAnchor, constant: -64)
        buttonsWidthOnArtwork.priority = .defaultHigh
        pageCentered = [
            artworkView.centerXAnchor.constraint(equalTo: artworkContainer.centerXAnchor),
            textStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            textStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            buttons.centerXAnchor.constraint(equalTo: centerXAnchor),
            buttonsWidth
        ]
        artworkCentered = [
            artworkView.leadingAnchor.constraint(equalTo: artworkContainer.leadingAnchor),
            textStack.centerXAnchor.constraint(equalTo: artworkView.centerXAnchor),
            textStack.widthAnchor.constraint(equalTo: artworkView.widthAnchor, constant: -48),
            buttons.centerXAnchor.constraint(equalTo: artworkView.centerXAnchor),
            buttonsWidthOnArtwork
        ]
        NSLayoutConstraint.activate(pageCentered)
        NSLayoutConstraint.activate([
            containerTop,
            containerHeight,
            artworkContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            artworkContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            backdropView.leadingAnchor.constraint(equalTo: artworkContainer.leadingAnchor),
            backdropView.trailingAnchor.constraint(equalTo: artworkContainer.trailingAnchor),
            backdropView.topAnchor.constraint(equalTo: artworkContainer.topAnchor),
            backdropView.bottomAnchor.constraint(equalTo: artworkContainer.bottomAnchor),
            artworkView.widthAnchor.constraint(lessThanOrEqualTo: artworkContainer.widthAnchor),
            squareArtwork,
            artworkView.topAnchor.constraint(equalTo: artworkContainer.topAnchor),
            artworkView.bottomAnchor.constraint(equalTo: artworkContainer.bottomAnchor),

            extensionView.topAnchor.constraint(equalTo: artworkContainer.bottomAnchor, constant: -Self.overlap),
            extensionView.leadingAnchor.constraint(equalTo: leadingAnchor),
            extensionView.trailingAnchor.constraint(equalTo: trailingAnchor),
            extensionView.bottomAnchor.constraint(equalTo: buttons.centerYAnchor),

            textStack.topAnchor.constraint(equalTo: artworkContainer.bottomAnchor, constant: 12),

            buttons.topAnchor.constraint(equalTo: textStack.bottomAnchor, constant: 20),
            buttons.widthAnchor.constraint(lessThanOrEqualToConstant: 340),
            buttons.heightAnchor.constraint(equalToConstant: 48),
            shuffleButton.widthAnchor.constraint(equalTo: shuffleButton.heightAnchor),
            buttons.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -(Self.buttonsCenterFromBottom - 24))
        ])
    }

    private func updateSideMode() {
        let side = sideExtension > 0
        NSLayoutConstraint.deactivate(side ? pageCentered : artworkCentered)
        NSLayoutConstraint.activate(side ? artworkCentered : pageCentered)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:)") }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        artworkContainer.layoutIfNeeded()
        let artworkBounds = artworkContainer.bounds
        let isWide = artworkView.bounds.width < artworkBounds.width - 1
        let artworkWidth = artworkView.bounds.width
        if sideExtension > 0 {
            // The sharp artwork melts into its mirrored right edge over the
            // same points the extension below fades in over it.
            artworkView.layer.mask = artworkTrailingMask
            artworkTrailingMask.frame = artworkView.bounds
            let start = artworkWidth > 0 ? max(0, 1 - Self.overlap / artworkWidth) : 1
            artworkTrailingMask.locations = [0, NSNumber(value: Double(start)), 1]
        } else {
            artworkView.layer.mask = isWide ? artworkEdgeMask : nil
            artworkEdgeMask.frame = artworkView.bounds
        }
        topScrim.frame = CGRect(x: 0, y: 0, width: artworkBounds.width, height: min(stretch + topInset + 40, artworkBounds.height))
        let extensionBounds = extensionView.bounds
        extensionMask.frame = extensionBounds
        let overlapEnd = extensionBounds.height > 0 ? Self.overlap / extensionBounds.height : 0
        extensionMask.locations = [0, NSNumber(value: Double(overlapEnd))]
        // The page color rises from the buttons well into the artwork.
        let artworkBottom = artworkContainer.frame.maxY
        let fadeTop = artworkBottom - artworkHeight * Self.fadeRise
        fade.frame = CGRect(x: 0, y: fadeTop, width: bounds.width, height: max(extensionView.frame.maxY - fadeTop, 0))
        // The same fade as below, turned sideways: from as far into the
        // artwork to the column's edge, as far past the artwork.
        sideFade.isHidden = sideExtension <= 0
        let sideTop = artworkContainer.frame.minY
        let sideStart = artworkContainer.frame.minX + artworkView.frame.maxX - artworkHeight * Self.fadeRise
        sideFade.frame = CGRect(x: sideStart, y: sideTop, width: max(bounds.width - sideStart, 0), height: max(extensionView.frame.maxY - sideTop, 0))
        CATransaction.commit()
        // Decoded at the width it is shown.
        if abs(artworkBounds.width - loadedWidth) > 1, artworkBounds.width > 0 {
            loadedWidth = artworkBounds.width
            loadArtwork()
        } else if extensionBounds.width > 0, abs(extensionBounds.height - renderedExtensionSize.height) > 1 || abs(extensionBounds.width - renderedExtensionSize.width) > 1 || abs(artworkHeight - renderedArtworkHeight) > 1 || (sideExtension > 0) != renderedSideMode {
            // A title on more lines makes the extension taller, a turn
            // reshapes the artwork: redraw it so the mirror still meets it.
            loadExtension()
        }
    }

    /// Rising behind the bars and growing with the overscroll, the artwork
    /// still ends at the same place: the header's height never changes.
    private func updateArtworkFrame() {
        containerTop.constant = -(topInset + stretch)
        containerHeight.constant = artworkHeight + stretch
        setNeedsLayout()
    }

    func setShuffle(isOn: Bool) {
        shuffleButton.isOn = isOn
    }

    /// Stretches the artwork on overscroll, and keeps the bar's scroll edge
    /// effect off while the artwork is still under it.
    func followScroll(of scrollView: UIScrollView) {
        let offset = scrollView.contentOffset.y + scrollView.adjustedContentInset.top
        stretch = max(0, -offset)
        layoutIfNeeded()
        scrollView.topEdgeEffect.isHidden = offset < artworkContainer.frame.maxY - 56
    }

    func setPageColor(_ color: UIColor) {
        shuffleButton.pageColor = color
        let stops = Self.fadeStops
        fade.colors = stops.map { color.withAlphaComponent($0.alpha).cgColor }
        fade.locations = stops.map(\.location)
        sideFade.colors = fade.colors
        sideFade.locations = fade.locations
        extensionView.backgroundColor = color
        artworkContainer.backgroundColor = color
    }

    func configure(title: String, subtitle: String?, subtitleIsLink: Bool, detail: String, artwork: ArtworkSource?, placeholderSymbol: String) {
        let artworkChanged = artwork?.cacheKey != self.artwork?.cacheKey || self.artwork == nil
        self.artwork = artwork
        self.placeholderSymbol = placeholderSymbol
        if artworkChanged { loadArtwork() }
        titleLabel.text = title

        var configuration = subtitleButton.configuration ?? .plain()
        configuration.attributedTitle = AttributedString(subtitle ?? "", attributes: AttributeContainer([
            .font: UIFont.preferredFont(forTextStyle: .title3).withWeight(.medium)
        ]))
        configuration.image = subtitleIsLink ? UIImage(systemName: "chevron.forward") : nil
        configuration.baseForegroundColor = UIColor.white.withAlphaComponent(subtitleIsLink ? 0.95 : 0.8)
        subtitleButton.configuration = configuration
        subtitleButton.isUserInteractionEnabled = subtitleIsLink
        subtitleButton.isHidden = subtitle?.isEmpty ?? true

        detailLabel.text = detail
        detailLabel.isHidden = detail.isEmpty
    }

    private func loadArtwork() {
        let points = max(loadedWidth, 300)
        artworkLoader.load(artwork, into: artworkView, points: points, placeholder: UIImage(systemName: placeholderSymbol))
        loadExtension()
    }

    /// Builds the extension from the decoded artwork, off the main thread.
    private func loadExtension() {
        extensionTask?.cancel()
        guard let artwork else {
            extensionView.image = nil
            backdropView.image = nil
            return
        }
        let size = extensionView.bounds.size
        guard size.width > 0, size.height > Self.overlap else { return }
        let pageWidth = artworkContainer.bounds.width
        renderedExtensionSize = size
        let artworkHeight = artworkHeight
        renderedArtworkHeight = artworkHeight
        let points = max(loadedWidth, 300)
        let key = artwork.cacheKey
        let overlap = Self.overlap
        let atLeading = sideExtension > 0
        renderedSideMode = atLeading
        extensionTask = Task { [weak self] in
            guard let image = await ArtworkImageCache.shared.image(for: artwork, points: points) else { return }
            let (backdrop, rendered) = await Task.detached(priority: .userInitiated) {
                let fitting = CGSize(width: pageWidth, height: artworkHeight)
                let backdrop: UIImage? = if pageWidth <= artworkHeight + 1 {
                    nil
                } else if atLeading {
                    Self.trailingBackdropImage(from: image, fitting: fitting)
                } else {
                    Self.backdropImage(from: image, fitting: fitting)
                }
                return (backdrop, Self.extensionImage(from: image, backdrop: backdrop, squareAtLeading: atLeading, fitting: size, artworkHeight: artworkHeight, overlap: overlap))
            }.value
            guard !Task.isCancelled, let self, self.artwork?.cacheKey == key else { return }
            UIView.transition(with: self.extensionView, duration: 0.25, options: .transitionCrossDissolve) {
                self.extensionView.image = rendered
            }
            UIView.transition(with: self.backdropView, duration: 0.25, options: .transitionCrossDissolve) {
                self.backdropView.image = backdrop
            }
        }
    }

    /// The artwork's last rows, then the same rows mirrored below them, all
    /// blurred together: the artwork seems to carry on past its edge. Drawn
    /// small (it is blurred anyway) but in the view's exact proportions, so
    /// the artwork's edge lands exactly where it is on screen.
    nonisolated private static func extensionImage(from image: UIImage, backdrop: UIImage?, squareAtLeading: Bool, fitting viewSize: CGSize, artworkHeight: CGFloat, overlap overlapPoints: CGFloat) -> UIImage? {
        let side: CGFloat = 160
        let scale = side / viewSize.width
        let overlap = overlapPoints * scale
        let size = CGSize(width: side, height: (viewSize.height * scale).rounded(.up))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        // Aspect-fill into the artwork's frame (square, or a banner on a wide
        // page), as the artwork view shows it, its bottom edge at `overlap`.
        let frame = CGRect(x: 0, y: overlap - artworkHeight * scale, width: side, height: artworkHeight * scale)
        // On a wide page, the square artwork over its blurred sides.
        // On a split page, against the leading edge.
        let square = backdrop == nil ? frame : CGRect(x: squareAtLeading ? frame.minX : frame.midX - frame.height / 2, y: frame.minY, width: frame.height, height: frame.height)
        let strip = UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            for mirrored in [false, true] {
                cg.saveGState()
                // Mirror around the artwork's bottom edge.
                if mirrored {
                    cg.translateBy(x: 0, y: overlap * 2)
                    cg.scaleBy(x: 1, y: -1)
                }
                cg.clip(to: frame)
                backdrop?.draw(in: frame)
                cg.clip(to: square)
                image.draw(in: aspectFill(image.size, in: square))
                cg.restoreGState()
            }
        }
        guard let input = CIImage(image: strip) else { return strip }
        let blurred = input.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 9])
            .cropped(to: input.extent)
        guard let output = CIContext(options: [.useSoftwareRenderer: false]).createCGImage(blurred, from: input.extent) else { return strip }
        return UIImage(cgImage: output)
    }

    /// The whole artwork square in the middle of a wide page, its left and
    /// right edges mirrored out to the page's sides, heavily blurred. Under
    /// the sharp artwork it shows only past its softened edges.
    nonisolated static func backdropImage(from image: UIImage, fitting viewSize: CGSize) -> UIImage? {
        let width: CGFloat = 240
        let scale = width / viewSize.width
        let size = CGSize(width: width, height: (viewSize.height * scale).rounded(.up))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let square = CGRect(x: (width - size.height) / 2, y: 0, width: size.height, height: size.height)
        let filled = aspectFill(image.size, in: square)
        let canvas = UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            image.draw(in: filled)
            // Mirrored around each side edge, out to the page's sides.
            for edge in [square.minX, square.maxX] {
                cg.saveGState()
                cg.clip(to: edge == square.minX ? CGRect(x: 0, y: 0, width: edge, height: size.height) : CGRect(x: edge, y: 0, width: width - edge, height: size.height))
                cg.translateBy(x: edge * 2, y: 0)
                cg.scaleBy(x: -1, y: 1)
                image.draw(in: filled)
                cg.restoreGState()
            }
        }
        // White where the sides are far from the artwork: there they take
        // the heavy blur, next to it the light one.
        let ramp = square.width * 0.4
        let mask = UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            let colors = [UIColor.black.cgColor, UIColor.white.cgColor] as CFArray
            UIColor.white.setFill()
            cg.fill(CGRect(origin: .zero, size: size))
            UIColor.black.setFill()
            cg.fill(square)
            guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(), colors: colors, locations: [0, 1]) else { return }
            cg.saveGState()
            cg.clip(to: CGRect(x: 0, y: 0, width: square.minX, height: size.height))
            cg.drawLinearGradient(gradient, start: CGPoint(x: square.minX, y: 0), end: CGPoint(x: square.minX - ramp, y: 0), options: [.drawsAfterEndLocation])
            cg.restoreGState()
            cg.clip(to: CGRect(x: square.maxX, y: 0, width: width - square.maxX, height: size.height))
            cg.drawLinearGradient(gradient, start: CGPoint(x: square.maxX, y: 0), end: CGPoint(x: square.maxX + ramp, y: 0), options: [.drawsAfterEndLocation])
        }
        guard let input = CIImage(image: canvas), let maskImage = CIImage(image: mask) else { return canvas }
        // Next to the artwork the mirror stays close to it, so the artwork
        // needs only a narrow fade and text on it stays sharp; farther out
        // it dissolves, so text reaching the edge doesn't streak.
        let light = input.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 2.5])
        let heavy = input.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 24])
        let blurred = heavy
            .applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: light, kCIInputMaskImageKey: maskImage.clampedToExtent()])
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 1.5])
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.1, kCIInputBrightnessKey: -0.02])
            .cropped(to: input.extent)
        guard let output = CIContext(options: [.useSoftwareRenderer: false]).createCGImage(blurred, from: input.extent) else { return canvas }
        return UIImage(cgImage: output)
    }

    /// A split page's artwork square against the leading edge, its right
    /// edge mirrored out to the column's edge, blurred as much as the
    /// extension below it is: drawn at the same 160 points across.
    nonisolated static func trailingBackdropImage(from image: UIImage, fitting viewSize: CGSize) -> UIImage? {
        let width: CGFloat = 160
        let scale = width / viewSize.width
        let size = CGSize(width: width, height: (viewSize.height * scale).rounded(.up))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let square = CGRect(x: 0, y: 0, width: size.height, height: size.height)
        let filled = aspectFill(image.size, in: square)
        let canvas = UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            cg.saveGState()
            cg.clip(to: square)
            image.draw(in: filled)
            cg.restoreGState()
            // Mirrored around the right edge.
            cg.clip(to: CGRect(x: square.maxX, y: 0, width: width - square.maxX, height: size.height))
            cg.translateBy(x: square.maxX * 2, y: 0)
            cg.scaleBy(x: -1, y: 1)
            image.draw(in: filled)
        }
        guard let input = CIImage(image: canvas) else { return canvas }
        let blurred = input.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 9])
            .cropped(to: input.extent)
        guard let output = CIContext(options: [.useSoftwareRenderer: false]).createCGImage(blurred, from: input.extent) else { return canvas }
        return UIImage(cgImage: output)
    }

    nonisolated static func aspectFill(_ imageSize: CGSize, in frame: CGRect) -> CGRect {
        let fill = max(frame.width / max(imageSize.width, 1), frame.height / max(imageSize.height, 1))
        let drawn = CGSize(width: imageSize.width * fill, height: imageSize.height * fill)
        return CGRect(x: frame.midX - drawn.width / 2, y: frame.midY - drawn.height / 2, width: drawn.width, height: drawn.height)
    }
}
