import SwiftUI
import UIKit

/// Apple Music's mini player, hosted as the tab bar's bottom accessory: it sits
/// above the tab bar and slides inline between the tab buttons when the bar
/// minimizes on scroll.
struct MiniPlayerView: View {
    /// The copy drawn inside the Now Playing card while it turns into (or out
    /// of) the mini player: no artwork (the flying cover stands in), no
    /// geometry reporting, and the real one's inline state.
    var replicaInline: Bool? = nil
    @EnvironmentObject private var playerVM: PlayerViewModel
    @EnvironmentObject private var libraryVM: LibraryViewModel
    @EnvironmentObject private var router: AppRouter
    @ObservedObject private var morph = NowPlayingMorph.shared
    @ObservedObject private var musicVideo = MusicVideoPlayer.shared
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    @Environment(\.colorScheme) private var colorScheme
    @State private var playlistPickerSong: Song?

    private var isReplica: Bool { replicaInline != nil }
    private var showsVideo: Bool {
        guard !isReplica, let id = playerVM.currentSong?.id else { return false }
        return musicVideo.shownSongID == id
    }

    /// The replica sits inside a standalone glass, which renders `.primary`
    /// vibrant: grayed in light mode, where the real mini player's buttons
    /// are black. A plain color matches them.
    private var controlsStyle: Color {
        guard isReplica else { return .primary }
        return colorScheme == .dark ? .white : .black
    }
    private var isInline: Bool { replicaInline ?? (placement == .inline) }

    var body: some View {
        HStack(spacing: isInline ? 10 : 12) {
            ArtworkImage(source: playerVM.currentSong?.artworkSource, cornerRadius: isInline ? 5 : 7, points: 40)
                .opacity(showsVideo ? 0 : 1)
                .overlay {
                    // The music video stands in for the cover here too,
                    // playing: as wide as the cover, centered.
                    if showsVideo {
                        let side: CGFloat = isInline ? 28 : 36
                        MusicVideoHost(role: .mini, cornerRadius: isInline ? 4 : 5)
                            .frame(width: MusicVideoPlayer.videoSize(side: side).width, height: MusicVideoPlayer.videoSize(side: side).height)
                            .transition(.identity)
                    }
                }
                .frame(width: isInline ? 28 : 36, height: isInline ? 28 : 36)
                .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
                .opacity(isReplica ? 0 : 1)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                    guard !isReplica else { return }
                    MiniPlayerGeometry.shared.artworkFrame = frame
                    MiniPlayerGeometry.shared.artworkCornerRadius = isInline ? 5 : 7
                    MiniPlayerGeometry.shared.isInline = isInline
                }

            MiniPlayerTitlePager(
                currentSong: playerVM.currentSong,
                previousSong: playerVM.previousSongPreview,
                nextSong: playerVM.nextSongPreview,
                showsArtist: true,
                onTap: openPlayer,
                onPrevious: { playerVM.previousTrack() },
                onNext: { playerVM.next() }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Button {
                playerVM.togglePlayPause()
            } label: {
                Image(systemName: playerVM.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: isInline ? 17 : 20, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(playerVM.isPlaying ? "Pause" : "Play")

            if !isInline {
                Button {
                    playerVM.next()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Next")
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(controlsStyle)
        .opacity(!isReplica && morph.coversMiniPlayer ? 0 : 1)
        .padding(.leading, isInline ? 8 : 10)
        .padding(.trailing, isInline ? 6 : 8)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture(perform: openPlayer)
        .simultaneousGesture(
            DragGesture(minimumDistance: 12).onEnded { value in
                // Swipe up opens the player, like Music.
                guard value.translation.height < -24,
                      abs(value.translation.height) > abs(value.translation.width) else { return }
                openPlayer()
            }
        )
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            guard !isReplica else { return }
            MiniPlayerGeometry.shared.frame = frame
        }
        .background { if !isReplica { AccessoryContainerProbe() } }
        .onChange(of: colorScheme, initial: true) { _, scheme in
            guard !isReplica else { return }
            MiniPlayerGeometry.shared.colorScheme = scheme
        }
        .contextMenu { contextMenu }
        .sheet(item: $playlistPickerSong) { song in
            PlayerPlaylistPickerSheet(song: song)
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens Now Playing")
    }

    @ViewBuilder
    private var contextMenu: some View {
        if let song = playerVM.currentSong {
            Section {
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
                Button("Add to Playlist…", systemImage: "text.badge.plus") {
                    playlistPickerSong = song
                }
            }
        }
    }

    private func openPlayer() {
        guard playerVM.currentSong != nil else { return }
        // Tapped while the card is still flying back: grab it.
        if NowPlayingMorph.shared.reopen?() == true { return }
        playerVM.showPlayer = true
    }
}

private struct MiniPlayerTitlePager: UIViewRepresentable {
    let currentSong: Song?
    let previousSong: Song?
    let nextSong: Song?
    let showsArtist: Bool
    let onTap: () -> Void
    let onPrevious: () -> Void
    let onNext: () -> Void

    func makeUIView(context: Context) -> MiniPlayerTitleScrollView {
        MiniPlayerTitleScrollView()
    }

    func updateUIView(_ view: MiniPlayerTitleScrollView, context: Context) {
        view.configure(
            currentSong: currentSong,
            previousSong: previousSong,
            nextSong: nextSong,
            showsArtist: showsArtist,
            onTap: onTap,
            onPrevious: onPrevious,
            onNext: onNext
        )
    }
}

private final class MiniPlayerTitleScrollView: UIView, UIScrollViewDelegate {
    private enum PageKind {
        case previous
        case current
        case next
    }

    private let scrollView = DirectionLockedPagingScrollView()
    private let stackView = UIStackView()
    private var pages: [MiniPlayerTrackTextStack] = []
    private var pageKinds: [PageKind] = []
    private var currentPageIndex = 0
    private var currentSongID: UUID?
    private var previousSongID: UUID?
    private var nextSongID: UUID?
    private var onTap: (() -> Void)?
    private var onPrevious: (() -> Void)?
    private var onNext: (() -> Void)?
    private var didLayoutInitialOffset = false
    private var lastLayoutWidth: CGFloat = 0
    private var isRecentering = false
    private var showsArtist = true

    override init(frame: CGRect) {
        super.init(frame: frame)

        clipsToBounds = true
        backgroundColor = .clear

        scrollView.backgroundColor = .clear
        scrollView.delegate = self
        scrollView.isPagingEnabled = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = true
        scrollView.alwaysBounceVertical = false
        scrollView.decelerationRate = .fast
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        stackView.axis = .horizontal
        stackView.alignment = .fill
        stackView.distribution = .fill
        stackView.spacing = 0
        stackView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(scrollView)
        scrollView.addSubview(stackView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            stackView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            stackView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stackView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stackView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor)
        ])

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        tap.cancelsTouchesInView = false
        addGestureRecognizer(tap)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = scrollView.bounds.width
        guard width > 0 else { return }
        // The accessory resizes when it moves inline into the minimized tab
        // bar: keep the current page centered at the new width.
        if !didLayoutInitialOffset || (abs(width - lastLayoutWidth) > 0.5 && !scrollView.isDragging && !scrollView.isDecelerating) {
            didLayoutInitialOffset = true
            lastLayoutWidth = width
            scrollView.layoutIfNeeded()
            recenter(animated: false)
        }
    }

    func configure(
        currentSong: Song?,
        previousSong: Song?,
        nextSong: Song?,
        showsArtist: Bool,
        onTap: @escaping () -> Void,
        onPrevious: @escaping () -> Void,
        onNext: @escaping () -> Void
    ) {
        if self.showsArtist != showsArtist {
            self.showsArtist = showsArtist
            pages.forEach { $0.showsArtist = showsArtist }
        }
        self.onTap = onTap
        self.onPrevious = onPrevious
        self.onNext = onNext

        let pageModels = makePageModels(previousSong: previousSong, currentSong: currentSong, nextSong: nextSong)
        // Labels always follow the songs (cheap), so a skipped update can
        // never leave the old title on screen.
        ensurePageCount(pageModels.count)
        for (index, model) in pageModels.enumerated() {
            pages[index].configure(song: model.song)
        }

        let didChange =
            currentSongID != currentSong?.id ||
            previousSongID != previousSong?.id ||
            nextSongID != nextSong?.id ||
            pageKinds != pageModels.map(\.kind)

        guard didChange else { return }

        currentSongID = currentSong?.id
        previousSongID = previousSong?.id
        nextSongID = nextSong?.id
        pageKinds = pageModels.map(\.kind)
        currentPageIndex = pageModels.firstIndex { $0.kind == .current } ?? 0

        scrollView.isScrollEnabled = pageModels.count > 1
        // Lay the new pages out first so the offset lands on the current one.
        stackView.layoutIfNeeded()
        scrollView.layoutIfNeeded()
        recenter(animated: false)
    }

    private func makePageModels(
        previousSong: Song?,
        currentSong: Song?,
        nextSong: Song?
    ) -> [(kind: PageKind, song: Song?)] {
        var models: [(PageKind, Song?)] = []
        if let previousSong {
            models.append((.previous, previousSong))
        }
        models.append((.current, currentSong))
        if let nextSong {
            models.append((.next, nextSong))
        }
        return models
    }

    private func ensurePageCount(_ count: Int) {
        while pages.count < count {
            let page = MiniPlayerTrackTextStack()
            page.showsArtist = showsArtist
            page.translatesAutoresizingMaskIntoConstraints = false
            pages.append(page)
            stackView.addArrangedSubview(page)
            page.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor).isActive = true
        }

        while pages.count > count {
            let page = pages.removeLast()
            page.removeFromSuperview()
        }
    }

    private func recenter(animated: Bool) {
        guard scrollView.bounds.width > 0 else { return }
        isRecentering = true
        scrollView.setContentOffset(
            CGPoint(x: CGFloat(currentPageIndex) * scrollView.bounds.width, y: 0),
            animated: animated
        )
        if !animated {
            isRecentering = false
        }
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        isRecentering = false
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        isRecentering = false
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            finishScroll()
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        finishScroll()
    }

    private func finishScroll() {
        guard !isRecentering, scrollView.bounds.width > 0 else { return }

        let rawPage = Int(round(scrollView.contentOffset.x / scrollView.bounds.width))
        let page = min(max(rawPage, 0), max(pageKinds.count - 1, 0))
        let kind = pageKinds.indices.contains(page) ? pageKinds[page] : .current

        switch kind {
        case .previous:
            onPrevious?()
        case .next:
            onNext?()
        case .current:
            recenter(animated: true)
        }
    }

    @objc private func handleTap() {
        guard !scrollView.isDragging, !scrollView.isDecelerating else { return }
        onTap?()
    }
}

private final class DirectionLockedPagingScrollView: UIScrollView {
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === panGestureRecognizer {
            let velocity = panGestureRecognizer.velocity(in: self)
            guard abs(velocity.x) > abs(velocity.y) * 1.18 else { return false }
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }
}

private final class MiniPlayerTrackTextStack: UIView {
    private let titleLabel = UILabel()
    private let artistLabel = UILabel()

    var showsArtist = true {
        didSet {
            artistLabel.isHidden = !showsArtist
            setNeedsLayout()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)

        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = .label
        titleLabel.lineBreakMode = .byTruncatingTail

        artistLabel.font = .systemFont(ofSize: 13, weight: .regular)
        artistLabel.textColor = .secondaryLabel
        artistLabel.lineBreakMode = .byTruncatingTail

        addSubview(titleLabel)
        addSubview(artistLabel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let titleHeight = ceil(titleLabel.font.lineHeight)
        let artistHeight = ceil(artistLabel.font.lineHeight)
        let total = showsArtist ? titleHeight + artistHeight : titleHeight
        let top = (bounds.height - total) / 2
        titleLabel.frame = CGRect(x: 0, y: top, width: bounds.width, height: titleHeight)
        artistLabel.frame = CGRect(x: 0, y: top + titleHeight, width: bounds.width, height: artistHeight)
    }

    func configure(song: Song?) {
        titleLabel.text = song?.title ?? String(localized: "Not Playing")
        artistLabel.text = song?.artist ?? ""
    }
}

/// Finds the UIKit container the tab view draws the accessory's Liquid Glass
/// in, so the Now Playing card can hide it while its own glass stands in
/// (two glasses stacked read greyer than one).
struct AccessoryContainerProbe: UIViewRepresentable {
    final class Probe: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            DispatchQueue.main.async { [weak self] in
                var view = self?.superview
                while let current = view {
                    if String(describing: type(of: current)).contains("TabAccessoryContainer") {
                        MiniPlayerGeometry.shared.accessoryContainer = current
                        return
                    }
                    view = current.superview
                }
            }
        }
    }
    func makeUIView(context: Context) -> Probe {
        let probe = Probe()
        probe.isUserInteractionEnabled = false
        return probe
    }
    func updateUIView(_ uiView: Probe, context: Context) {}
}
