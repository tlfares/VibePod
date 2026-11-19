import SwiftUI
import UIKit
import Combine

/// Alphabetical song list with the A–Z index, backed by UITableView so even
/// very large libraries scroll at full frame rate.
struct IndexedSongTable: UIViewControllerRepresentable {
    let songs: [Song]
    let sortMode: SongListSortMode
    var showsPlayButtons = true
    // Not observed: the table tracks playback itself, so a track change must
    // not re-run `update` (and re-sort the whole list).
    @Environment(\.appServices) private var services

    func makeUIViewController(context: Context) -> IndexedSongTableViewController {
        IndexedSongTableViewController(libraryVM: services.libraryVM, playerVM: services.playerVM, router: services.router)
    }

    func updateUIViewController(_ controller: IndexedSongTableViewController, context: Context) {
        controller.update(songs: songs, sortMode: sortMode, showsPlayButtons: showsPlayButtons)
    }
}

final class IndexedSongTableViewController: UITableViewController {
    private struct Section {
        let title: String
        let songs: [Song]
    }

    private let libraryVM: LibraryViewModel
    private let playerVM: PlayerViewModel
    private let router: AppRouter
    private var sections: [Section] = []
    private var orderedSongs: [Song] = []
    private var renderedToken: Int?
    private var cancellables = Set<AnyCancellable>()
    private lazy var header = SongListHeaderView(
        onPlay: { [weak self] in self?.play(shuffled: false) },
        onShuffle: { [weak self] in self?.play(shuffled: true) }
    )

    init(libraryVM: LibraryViewModel, playerVM: PlayerViewModel, router: AppRouter) {
        self.libraryVM = libraryVM
        self.playerVM = playerVM
        self.router = router
        super.init(style: .plain)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:)") }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.backgroundColor = .systemBackground
        tableView.rowHeight = 60
        tableView.separatorInset = UIEdgeInsets(top: 0, left: 76, bottom: 0, right: 0)
        tableView.sectionHeaderTopPadding = 0
        tableView.keyboardDismissMode = .onDrag
        tableView.sectionIndexColor = AppTint.current.uiColor
        tableView.sectionIndexBackgroundColor = .clear
        tableView.register(SongTableCell.self, forCellReuseIdentifier: SongTableCell.reuseID)

        playerVM.$currentSong.map { $0?.id }.removeDuplicates()
            .combineLatest(playerVM.$isPlaying.removeDuplicates())
            .dropFirst()
            .receive(on: DispatchQueue.main) // after willSet: the sink reads the model
            .sink { [weak self] _ in self?.refreshVisibleCells() }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: AppTint.didChangeNotification)
            .sink { [weak self] _ in
                self?.tableView.sectionIndexColor = AppTint.current.uiColor
                self?.header.applyTint()
                self?.refreshVisibleCells()
            }
            .store(in: &cancellables)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        adoptAsContentScrollView(tableView)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        sizeHeaderIfNeeded()
    }

    func update(songs: [Song], sortMode: SongListSortMode, showsPlayButtons: Bool) {
        let desiredHeader: UIView? = showsPlayButtons && !songs.isEmpty ? header : nil
        if tableView.tableHeaderView !== desiredHeader {
            tableView.tableHeaderView = desiredHeader
        }

        // Cheap content token: re-sort and reload only when something shown
        // actually changed.
        var hasher = Hasher()
        hasher.combine(sortMode)
        for song in songs {
            hasher.combine(song.id)
            hasher.combine(song.title)
            hasher.combine(song.artist)
            hasher.combine(song.album)
            hasher.combine(song.lrcFilePath)
        }
        let token = hasher.finalize()
        guard token != renderedToken else { return }
        renderedToken = token
        orderedSongs = Self.sorted(songs, by: sortMode)
        sections = Self.sections(for: orderedSongs, sortMode: sortMode)
        tableView.reloadData()
    }

    /// Width and text size the header was last measured for: layout runs on
    /// every scroll frame, the height only follows those two.
    private var sizedHeaderFor: (CGFloat, UIContentSizeCategory)?

    private func sizeHeaderIfNeeded() {
        guard tableView.tableHeaderView === header else { return }
        let width = tableView.bounds.width
        let category = traitCollection.preferredContentSizeCategory
        if let sized = sizedHeaderFor, sized.0 == width, sized.1 == category, abs(header.frame.width - width) <= 0.5 { return }
        sizedHeaderFor = (width, category)
        let height = header.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
        guard abs(header.frame.width - width) > 0.5 || abs(header.frame.height - height) > 0.5 else { return }
        header.frame = CGRect(x: 0, y: 0, width: width, height: height)
        tableView.tableHeaderView = header
    }

    private func play(shuffled: Bool) {
        playerVM.play(orderedSongs, shuffled: shuffled)
    }

    private func refreshVisibleCells() {
        for indexPath in tableView.indexPathsForVisibleRows ?? [] {
            guard let cell = tableView.cellForRow(at: indexPath) as? SongTableCell,
                  let song = song(at: indexPath) else { continue }
            configure(cell, with: song)
        }
    }

    private func song(at indexPath: IndexPath) -> Song? {
        guard sections.indices.contains(indexPath.section),
              sections[indexPath.section].songs.indices.contains(indexPath.row) else { return nil }
        return sections[indexPath.section].songs[indexPath.row]
    }

    private func configure(_ cell: SongTableCell, with song: Song) {
        let isCurrent = playerVM.currentSong?.id == song.id
        cell.configure(
            song: song,
            isCurrent: isCurrent,
            isPlaying: isCurrent && playerVM.isPlaying,
            lyricsBadge: LyricsBadge.image(for: song.lyricsKind)
        )
    }

    // MARK: Sorting

    private static func sorted(_ songs: [Song], by sortMode: SongListSortMode) -> [Song] {
        songs.sorted { lhs, rhs in
            let keys: [(String, String)] = sortMode == .title
                ? [(lhs.title, rhs.title), (lhs.artist, rhs.artist), (lhs.album, rhs.album)]
                : [(lhs.artist, rhs.artist), (lhs.album, rhs.album), (lhs.title, rhs.title)]
            for (left, right) in keys {
                let order = left.libraryCompare(right)
                if order != .orderedSame { return order == .orderedAscending }
            }
            return false
        }
    }

    private static func sections(for songs: [Song], sortMode: SongListSortMode) -> [Section] {
        var result: [Section] = []
        var currentTitle: String?
        var bucket: [Song] = []
        for song in songs {
            let title = sectionTitle(for: sortMode == .title ? song.title : song.artist)
            if title != currentTitle, let currentTitle {
                result.append(Section(title: currentTitle, songs: bucket))
                bucket = []
            }
            currentTitle = title
            bucket.append(song)
        }
        if let currentTitle { result.append(Section(title: currentTitle, songs: bucket)) }
        return result
    }

    private static func sectionTitle(for value: String) -> String {
        // Same grouping as the sort, so "#" is one section at the top.
        guard value.librarySortGroup != 0 else { return "#" }
        let folded = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        guard let first = folded.first else { return "#" }
        return String(first).uppercased()
    }

    // MARK: Data source

    override func numberOfSections(in tableView: UITableView) -> Int {
        sections.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        sections[section].songs.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: SongTableCell.reuseID, for: indexPath) as! SongTableCell
        if let song = song(at: indexPath) {
            configure(cell, with: song)
        }
        return cell
    }

    /// Letter headers, like Apple Music's Songs list: bold, at the page margin.
    override func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        guard sections.count > 1 else { return nil }
        let header = tableView.dequeueReusableHeaderFooterView(withIdentifier: Self.headerID) ?? UITableViewHeaderFooterView(reuseIdentifier: Self.headerID)
        var content = UIListContentConfiguration.plainHeader()
        content.text = sections[section].title
        content.textProperties.font = .preferredFont(forTextStyle: .headline)
        content.textProperties.color = .label
        content.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 6, leading: 20, bottom: 6, trailing: 20)
        header.contentConfiguration = content
        return header
    }

    override func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        sections.count > 1 ? UITableView.automaticDimension : 0
    }

    private static let headerID = "SongLetterHeader"

    override func sectionIndexTitles(for tableView: UITableView) -> [String]? {
        sections.count > 1 ? sections.map(\.title) : nil
    }

    override func tableView(_ tableView: UITableView, sectionForSectionIndexTitle title: String, at index: Int) -> Int {
        index
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let song = song(at: indexPath) else { return }
        playerVM.play(song: song, from: orderedSongs)
    }

    override func tableView(_ tableView: UITableView, leadingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        song(at: indexPath).map { SongMenuBuilder.queueSwipeAction(for: $0, playerVM: playerVM) }
    }

    override func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        UISwipeActionsConfiguration(actions: [])
    }

    override func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        guard let song = song(at: indexPath) else { return nil }
        return fixedContextMenu(identifier: song.id as NSUUID, previewProvider: nil) { [weak self] _ in
            guard let self else { return nil }
            return SongMenuBuilder.menu(for: song, libraryVM: self.libraryVM, playerVM: self.playerVM, router: self.router)
        }
    }
}

/// "Play" / "Shuffle" glass capsules above a song list.
final class SongListHeaderView: UIView {
    private let onPlay: () -> Void
    private let onShuffle: () -> Void
    private var buttons: [UIButton] = []

    init(onPlay: @escaping () -> Void, onShuffle: @escaping () -> Void) {
        self.onPlay = onPlay
        self.onShuffle = onShuffle
        super.init(frame: CGRect(x: 0, y: 0, width: 390, height: 72))

        let play = Self.makeButton(title: String(localized: "Play"), systemImage: "play.fill") { [weak self] in self?.onPlay() }
        let shuffle = Self.makeButton(title: String(localized: "Shuffle"), systemImage: "shuffle") { [weak self] in self?.onShuffle() }
        buttons = [play, shuffle]
        let stack = UIStackView(arrangedSubviews: [play, shuffle])
        stack.axis = .horizontal
        stack.spacing = 12
        stack.distribution = .fillEqually
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
            stack.heightAnchor.constraint(equalToConstant: 48)
        ])
        directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:)") }

    /// The accent color changed in Settings.
    func applyTint() {
        for button in buttons {
            guard var configuration = button.configuration else { continue }
            Self.setColor(AppTint.current.uiColor, of: &configuration)
            button.configuration = configuration
        }
    }

    /// Glass buttons draw their symbol with the label color whatever the
    /// foreground color: bake the color into the symbol so icon and title match.
    static func setColor(_ color: UIColor, of configuration: inout UIButton.Configuration) {
        configuration.baseForegroundColor = color
        configuration.image = configuration.image?.withTintColor(color, renderingMode: .alwaysOriginal)
    }

    /// `color`: the app's accent unless given (white on colored pages).
    static func makeButton(title: String, systemImage: String, color: UIColor? = nil, action: @escaping () -> Void) -> UIButton {
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
        // Apple Music: accent-colored label on a neutral glass capsule.
        setColor(color ?? AppTint.current.uiColor, of: &configuration)
        return UIButton(configuration: configuration, primaryAction: UIAction { _ in action() })
    }
}

/// Song row: artwork, title, artist, lyrics badge and the now-playing glyph.
final class SongTableCell: UITableViewCell {
    static let reuseID = "SongTableCell"

    private let artworkView = UIImageView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let accessoryStack = UIStackView()
    private let lyricsBadgeView = UIImageView()
    private let nowPlayingView = UIImageView()
    private let artworkLoader = ArtworkImageLoader()
    private static let placeholder = UIImage(systemName: "music.note")

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        // A light veil instead of the opaque gray, so colored pages (playlists)
        // keep their color under the finger, like album pages.
        let selected = UIView()
        selected.backgroundColor = UIColor { $0.userInterfaceStyle == .dark ? UIColor.white.withAlphaComponent(0.1) : UIColor.black.withAlphaComponent(0.06) }
        selectedBackgroundView = selected

        artworkView.contentMode = .scaleAspectFill
        artworkView.clipsToBounds = true
        artworkView.layer.cornerRadius = 5
        artworkView.layer.cornerCurve = .continuous
        artworkView.backgroundColor = .tertiarySystemFill
        artworkView.tintColor = .tertiaryLabel
        artworkView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 17, weight: .medium)
        artworkView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .preferredFont(forTextStyle: .body)
        subtitleLabel.font = .preferredFont(forTextStyle: .subheadline)
        subtitleLabel.textColor = .secondaryLabel

        let textStack = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        textStack.axis = .vertical
        textStack.spacing = 1
        textStack.translatesAutoresizingMaskIntoConstraints = false

        lyricsBadgeView.tintColor = .tertiaryLabel
        lyricsBadgeView.contentMode = .scaleAspectFit
        nowPlayingView.contentMode = .scaleAspectFit
        nowPlayingView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .footnote, scale: .default)
        [lyricsBadgeView, nowPlayingView].forEach {
            $0.setContentHuggingPriority(.required, for: .horizontal)
            $0.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        accessoryStack.axis = .horizontal
        accessoryStack.spacing = 6
        accessoryStack.alignment = .center
        accessoryStack.addArrangedSubview(lyricsBadgeView)
        accessoryStack.addArrangedSubview(nowPlayingView)
        accessoryStack.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(artworkView)
        contentView.addSubview(textStack)
        contentView.addSubview(accessoryStack)
        NSLayoutConstraint.activate([
            artworkView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            artworkView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            artworkView.widthAnchor.constraint(equalToConstant: 44),
            artworkView.heightAnchor.constraint(equalToConstant: 44),
            textStack.leadingAnchor.constraint(equalTo: artworkView.trailingAnchor, constant: 12),
            textStack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            accessoryStack.leadingAnchor.constraint(greaterThanOrEqualTo: textStack.trailingAnchor, constant: 8),
            accessoryStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            accessoryStack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:)") }

    override func prepareForReuse() {
        super.prepareForReuse()
        artworkLoader.cancel()
        artworkView.image = nil
    }

    func configure(song: Song, isCurrent: Bool, isPlaying: Bool, lyricsBadge: UIImage?, subtitle: String? = nil, tint: UIColor? = nil) {
        // Only the playing row shows the cover tint: other rows skip the
        // palette (a cover decode on a cache miss, mid-scroll).
        let tint = isCurrent ? (tint ?? song.coverSheetTint) : (tint ?? AppTint.current.uiColor)
        artworkLoader.load(song.artworkSource, into: artworkView, points: 44, placeholder: Self.placeholder)
        titleLabel.text = song.title
        titleLabel.textColor = isCurrent ? tint : .label
        subtitleLabel.text = subtitle ?? song.artist
        lyricsBadgeView.image = lyricsBadge
        lyricsBadgeView.isHidden = lyricsBadge == nil || isCurrent
        NowPlayingIndicator.apply(to: nowPlayingView, isCurrent: isCurrent, isPlaying: isPlaying, tint: tint)
    }
}

/// Animated "now playing" glyph shared by every UIKit song list.
@MainActor
enum NowPlayingIndicator {
    static func apply(to imageView: UIImageView, isCurrent: Bool, isPlaying: Bool, tint: UIColor = AppTint.current.uiColor) {
        imageView.isHidden = !isCurrent
        imageView.tintColor = tint
        guard isCurrent else {
            imageView.removeAllSymbolEffects()
            return
        }
        imageView.image = UIImage(systemName: isPlaying ? "waveform" : "speaker.fill")
        if isPlaying {
            imageView.addSymbolEffect(.variableColor.iterative.dimInactiveLayers, options: .repeating)
        } else {
            imageView.removeAllSymbolEffects()
        }
    }
}

extension UIViewController {
    /// A UIKit scroll view hosted inside SwiftUI isn't seen by the navigation
    /// bar (scroll edge effect, large title collapse) nor by the tab bar
    /// (minimize on scroll). Register it on every ancestor up to the
    /// navigation controller's child.
    func adoptAsContentScrollView(_ scrollView: UIScrollView) {
        var candidate: UIViewController? = self
        while let current = candidate {
            current.setContentScrollView(scrollView, for: .top)
            current.setContentScrollView(scrollView, for: .bottom)
            if current.parent is UINavigationController || current.parent is UITabBarController { break }
            candidate = current.parent
        }
    }
}
