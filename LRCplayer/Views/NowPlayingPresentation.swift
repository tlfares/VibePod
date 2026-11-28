import SwiftUI
import UIKit

/// Where the mini player sits on screen, so the Now Playing card can grow out
/// of it and collapse back into it (window coordinates).
@MainActor
final class MiniPlayerGeometry {
    static let shared = MiniPlayerGeometry()
    var frame: CGRect = .zero
    var artworkFrame: CGRect = .zero
    var artworkCornerRadius: CGFloat = 7
    var isInline = false
    /// The real mini player's appearance: its glass switches to light or dark
    /// with what's behind it, and its copy has to follow (the artist name
    /// changed shade on hand-over otherwise).
    var colorScheme: ColorScheme = .dark
    weak var accessoryContainer: UIView?
}

/// While the card morphs out of / into the mini player, the real one's
/// content hides so the card's copy is the only one on screen (the two can't
/// line up while the card dips), and comes back as the card hands over.
@MainActor
final class NowPlayingMorph: ObservableObject {
    static let shared = NowPlayingMorph()
    @Published private(set) var coversMiniPlayer = false
    /// The iPad's floating mini player hides its glass like the accessory's.
    @Published private(set) var hidesFloatingGlass = false
    /// Grabs a closing card back (the app already considers it closed).
    var reopen: (() -> Bool)?

    func setCovers(_ covers: Bool, animated: Bool) {
        // The real mini player's glass goes too: the card's own glass stands
        // in for it, and two stacked glasses read greyer than one, so the
        // material visibly changed when the card handed over.
        // It only comes back with `showAccessory()`, in the same frame the
        // card goes away: any overlap of the two blinked.
        // Not quite 0: a glass at 0 stops rendering and, shown again, spent a
        // frame barely frosted, and UIKit lets touches through anything at
        // 1% or less (a tap meant to grab the card back hit the page below).
        // At 2%, under the card, it can't be seen.
        if covers {
            MiniPlayerGeometry.shared.accessoryContainer?.alpha = 0.02
            if !hidesFloatingGlass { hidesFloatingGlass = true }
        }
        guard coversMiniPlayer != covers else { return }
        if animated {
            withAnimation(.easeInOut(duration: 0.3)) { coversMiniPlayer = covers }
        } else {
            coversMiniPlayer = covers
        }
    }

    func showAccessory() {
        MiniPlayerGeometry.shared.accessoryContainer?.alpha = 1
        if hidesFloatingGlass { hidesFloatingGlass = false }
    }
}

/// Presents Now Playing the way Music does: the mini player's capsule expands
/// into the full-screen card while its artwork flies to the large cover, and
/// a downward drag shrinks the card back into the mini player.
struct NowPlayingPresenter<Content: View, Mini: View>: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let artwork: ArtworkSource?
    /// Lyrics mode: the cover flies to the small header artwork instead.
    let showsLyrics: Bool
    @ViewBuilder let content: () -> Content
    /// The mini player's content (for an inline or regular placement), drawn
    /// in the card so it *becomes* the mini player instead of fading over it.
    let mini: (Bool) -> Mini

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> UIViewController {
        let controller = UIViewController()
        controller.view.isUserInteractionEnabled = false
        controller.view.backgroundColor = .clear
        return controller
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {
        let coordinator = context.coordinator
        coordinator.artwork = artwork
        // Built ahead of time so the first open doesn't pay for the player's
        // first layout or its backdrop.
        coordinator.prepare(content: content, mini: mini)
        coordinator.playerController?.setArtwork(artwork)
        coordinator.playerController?.showsLyrics = showsLyrics
        coordinator.onDismissed = { isPresented = false }
        if isPresented {
            coordinator.present(from: controller, content: content, mini: mini)
        } else {
            coordinator.dismiss()
        }
    }

    @MainActor
    final class Coordinator {
        var artwork: ArtworkSource?
        var onDismissed: (() -> Void)?
        private(set) var playerController: NowPlayingCardController?

        func prepare(content: () -> Content, mini: @escaping (Bool) -> Mini) {
            guard playerController == nil else { return }
            playerController = NowPlayingCardController(rootView: AnyView(content()))
            playerController?.miniProvider = { AnyView(mini($0)) }
        }

        func present(from anchor: UIViewController, content: () -> Content, mini: @escaping (Bool) -> Mini) {
            prepare(content: content, mini: mini)
            guard let controller = playerController, let window = anchor.view.window, let scene = window.windowScene else { return }
            controller.artworkProvider = { [weak self] in self?.artwork }
            controller.setArtwork(artwork)
            controller.onClosing = { [weak self] in self?.onDismissed?() }
            controller.open(in: scene, above: window)
        }

        func dismiss() {
            playerController?.collapse(velocity: 0)
        }
    }
}

/// The player's own window, above the app's. It lets every touch it doesn't
/// need fall through to the app: while the card closes the app is already
/// fully usable (tap a tile, or the mini player to grab the card back).
/// Always dark, like the player it holds, sheets included: it doesn't take
/// the app's mode (see `AppAppearance`).
private final class NowPlayingWindow: UIWindow, FixedAppearanceWindow {
    weak var card: NowPlayingCardController?

    override init(windowScene: UIWindowScene) {
        super.init(windowScene: windowScene)
        overrideUserInterfaceStyle = .dark
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let card, card.acceptsTouches else { return nil }
        let view = super.hitTest(point, with: event)
        return view === rootViewController?.view ? nil : view
    }
}

final class NowPlayingCardController: UIViewController, UIGestureRecognizerDelegate {
    var artworkProvider: (() -> ArtworkSource?)?
    /// Called as soon as the card starts closing (the app is usable from then on).
    var onClosing: (() -> Void)?
    var showsLyrics = false
    var miniProvider: ((Bool) -> AnyView)?

    private enum Phase {
        case hidden, expanding, shown, dragging, collapsing
    }

    /// Where the flying cover goes, in the player's own (full-screen) space.
    private struct CoverTarget {
        var frame: CGRect
        var cornerRadius: CGFloat
        var shadow: HeroShadow
        /// The full-screen artwork: it melts at the bottom.
        var fades = false
    }

    private let hosting: UIHostingController<AnyView>
    private let cardView = UIView()
    /// Lives in the card rather than the player so the morph never shows an
    /// empty card while the controls fade.
    private let backgroundView = PlayerBackgroundUIView()
    /// Under the card, the same Liquid Glass as the mini player's — unclipped,
    /// with its own capsule corners, so it renders exactly like the real one.
    /// Music's card is glass while it is mini-player-sized: it turns to glass
    /// halfway through closing and opens as glass.
    private let glassView = UIVisualEffectView(effect: UIGlassEffect())
    /// The mini player's title and buttons, hanging from the card's top edge
    /// between the glass and the colors.
    private let miniHosting = UIHostingController(rootView: AnyView(EmptyView()))
    private var miniHostingInline: Bool?
    private var miniHostingScheme: ColorScheme?
    /// Carries the flying cover's shadow (the image view itself clips). Above
    /// the card (in the same coordinates) so it stays solid while the card
    /// dissolves; it shares the card's spring, so it lands with it.
    private let heroContainer = UIView()
    private let heroView = UIImageView()
    /// The playing music video, carried by the flying cover.
    private var heroVideo: MusicVideoHostView?
    private let heroFade = ArtworkFadeMaskView()
    private var phase: Phase = .hidden {
        didSet {
            MusicVideoPlayer.shared.isPlayerPresented = phase != .hidden
        }
    }
    private var animators: [UIViewPropertyAnimator] = []
    /// The last cover position measured with the player at rest: SwiftUI may
    /// not have laid the cover out yet when an opening starts.
    private var restingTargets: [RestingKey: CoverTarget] = [:]

    /// Resting places per mode and per orientation: turning the phone back
    /// lands the flying cover where it rested before, even when the rebuilt
    /// layout isn't measurable yet.
    private struct RestingKey: Hashable {
        var showsLyrics: Bool
        var isLandscape: Bool
    }

    private var restingKey: RestingKey {
        RestingKey(showsLyrics: showsLyrics, isLandscape: screenBounds.width > screenBounds.height)
    }
    private var dragOffset: CGFloat = 0
    /// The colors' turn against the screen's, in multiples of a quarter turn.
    private var backgroundAngle: CGFloat = 0
    private var phaseToken = UUID()
    private weak var scrollViewUnderTouch: UIScrollView?
    private lazy var pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
    /// Two fingers on a trackpad (a Mac, an iPad) pull the card down like a drag does.
    private lazy var scrollPan: UIPanGestureRecognizer = {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.allowedScrollTypesMask = .continuous
        pan.allowedTouchTypes = []
        return pan
    }()
    private var overlayWindow: NowPlayingWindow?
    private weak var appWindow: UIWindow?

    init(rootView: AnyView) {
        hosting = UIHostingController(rootView: rootView)
        super.init(nibName: nil, bundle: nil)
        NowPlayingMorph.shared.reopen = { [weak self] in
            guard let self, self.phase == .collapsing else { return false }
            self.overlayWindow?.makeKey()
            self.expand(fromCurrentState: true)
            return true
        }
    }

    /// Touches outside the card always reach the app; the card itself takes
    /// them unless it's closing.
    fileprivate var acceptsTouches: Bool {
        presentedViewController != nil || phase == .shown || phase == .dragging || phase == .expanding
    }

    /// Applies the presenter's state. Mini-player taps reopen through `reopen`.
    func open(in scene: UIWindowScene, above window: UIWindow) {
        appWindow = window
        switch phase {
        case .hidden:
            let overlay = overlayWindow ?? NowPlayingWindow(windowScene: scene)
            overlay.card = self
            overlay.backgroundColor = .clear
            overlay.windowLevel = window.windowLevel + 1
            if overlay.rootViewController !== self { overlay.rootViewController = self }
            overlayWindow = overlay
            overlay.frame = window.frame
            removeHandOverStill()
            prepareForExpand(in: overlay.bounds)
            overlay.isHidden = false
            overlay.makeKey()
            // One frame later, so the card's first frame (the mini player)
            // is on screen before it starts growing.
            DispatchQueue.main.async { self.expand() }
        case .collapsing:
            // isPresented stays true until the closing animation finishes.
            // Unrelated SwiftUI updates (including tab changes) must not
            // interrupt it; only the mini player's explicit reopen can do so.
            break
        case .expanding, .shown, .dragging:
            break
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setArtwork(_ source: ArtworkSource?) {
        loadViewIfNeeded()
        backgroundView.update(source: source, animated: phase != .hidden)
        // Decoded ahead of time: a full-size cover decoded when the finger
        // lifts stalls the flight's first frames.
        if let source, ArtworkImageCache.shared.cachedImage(for: source, points: 340) == nil {
            Task { _ = await ArtworkImageCache.shared.image(for: source, points: 340) }
        }
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        cardView.clipsToBounds = true
        cardView.layer.cornerCurve = .continuous
        glassView.cornerConfiguration = .capsule(maximumRadius: 55)
        glassView.isUserInteractionEnabled = false
        glassView.isHidden = true
        view.addSubview(glassView)

        addChild(miniHosting)
        miniHosting.view.backgroundColor = .clear
        miniHosting.view.isUserInteractionEnabled = false
        miniHosting.sizingOptions = []
        miniHosting.view.alpha = 0
        // Inside the glass, like the real mini player's content: Liquid Glass
        // gives its text a vibrant treatment (the artist name picks up the
        // colors behind), which a copy outside it didn't get.
        glassView.contentView.addSubview(miniHosting.view)
        miniHosting.didMove(toParent: self)

        view.addSubview(cardView)
        cardView.addSubview(backgroundView)

        addChild(hosting)
        hosting.view.backgroundColor = .clear
        hosting.sizingOptions = []
        // Its layout uses the screen's fixed insets (PlayerView.deviceInsets).
        hosting.safeAreaRegions = []
        cardView.addSubview(hosting.view)
        hosting.didMove(toParent: self)

        heroView.contentMode = .scaleAspectFill
        heroView.clipsToBounds = true
        heroView.layer.cornerCurve = .continuous
        heroView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        heroContainer.addSubview(heroView)
        heroContainer.layer.shadowColor = UIColor.black.cgColor
        heroContainer.isHidden = true
        view.addSubview(heroContainer)

        pan.delegate = self
        view.addGestureRecognizer(pan)
        // A trackpad's two fingers: the Mac's, an iPad's keyboard.
        scrollPan.delegate = self
        view.addGestureRecognizer(scrollPan)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard phase == .shown else { return }
        restFullScreen()
        // Keep the resting cover position fresh (lyrics mode, pause shrink…).
        rememberRestingTarget()
    }

    /// Turning the phone: the cover flies to its new place while the old
    /// layout dissolves into the new one, like Music.
    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        let turn = coordinator.targetTransform
        backgroundAngle -= atan2(turn.b, turn.a)
        backgroundAngle = (backgroundAngle / (.pi / 2)).rounded() * (.pi / 2)
        guard phase == .shown else { return }

        // The old layout, drawn once from what is on screen (cheap: no
        // extra render pass), stays centered while the screen turns, then
        // fades. A plain image: nothing in it can move or spill out.
        let bounds = hosting.view.bounds
        let image = UIGraphicsImageRenderer(bounds: bounds).image { _ in
            hosting.view.drawHierarchy(in: bounds, afterScreenUpdates: false)
        }
        let still = UIImageView(image: image)
        still.frame = hosting.view.frame
        still.clipsToBounds = true
        still.autoresizingMask = [.flexibleLeftMargin, .flexibleRightMargin, .flexibleTopMargin, .flexibleBottomMargin]

        // Lyrics mode has no cover on the left sideways: nothing to fly.
        let origin = showsLyrics ? nil : measureCoverTarget()
        let flies = origin.map {
            prepareHero(at: hosting.view.convert($0.frame, to: view), cornerRadius: $0.cornerRadius, shadow: $0.shadow, fades: $0.fades)
        } == true
        // No cover pages at all while the screen turns: the flying cover
        // stands in for the current one, and the neighbours stay out.
        // Without a flight the real cover stays.
        FullscreenCoverPager.Controller.hidesPages = flies
        if flies, let origin {
            // The image's own cover is cut out: only the flying one moves.
            let hole = CAShapeLayer()
            let path = UIBezierPath(rect: bounds)
            path.append(UIBezierPath(roundedRect: origin.frame, cornerRadius: origin.cornerRadius))
            hole.path = path.cgPath
            hole.fillRule = .evenOdd
            still.layer.mask = hole
        }
        cardView.insertSubview(still, aboveSubview: hosting.view)
        hosting.view.alpha = 0
        // Upright, a video stands in for the cover: the flying one rises
        // out of it turning sideways, and melts into it turning back.
        let videoUpright = MotionArtworkState.shared.videoHidesCover
        let toUpright = size.height > size.width
        // A flying video stays itself all the way.
        if flies, videoUpright, !toUpright, heroVideo == nil { heroContainer.alpha = 0 }

        coordinator.animate(alongsideTransition: { _ in
            self.restFullScreen()
            self.backgroundView.layoutIfNeeded()
            self.hosting.view.layoutIfNeeded()
            still.alpha = 0
            guard flies else { return }
            if videoUpright, self.heroVideo == nil { self.heroContainer.alpha = toUpright ? 0 : 1 }
            if let target = self.measureCoverTarget() ?? self.restingTargets[self.restingKey] {
                // The new cover was just built: it stays hidden under the flight.
                PlayerModeTransitionAnchors.nowPlaying.setArtworkViewsHidden(true)
                self.heroContainer.frame = self.hosting.view.convert(target.frame, to: self.view)
                self.heroView.layer.cornerRadius = target.cornerRadius
                self.setHeroFade(size: target.frame.size, fades: target.fades)
                // The video turns with this very animation (chasing the
                // flying cover, it lagged a frame behind).
                // Like the flying cover: from where it's seen, no shift.
                if let heroVideo = self.heroVideo {
                    MusicVideoPlayer.shared.turnAlong(to: heroVideo, shift: .zero)
                }
            }
        }, completion: { _ in
            MusicVideoPlayer.shared.endTurnAlong()
            still.removeFromSuperview()
            guard flies else {
                FullscreenCoverPager.Controller.hidesPages = false
                return self.rememberRestingTarget()
            }
            // The real cover takes over only once the rebuilt layout has
            // settled (a turn upright rebuilds the cover a beat later):
            // until then the flying one stays, and the pages stay hidden.
            DispatchQueue.main.async {
                self.hosting.view.layoutIfNeeded()
                let handOff = {
                    FullscreenCoverPager.Controller.hidesPages = false
                    self.finishHero()
                    self.rememberRestingTarget()
                }
                guard let target = self.measureCoverTarget() else { return handOff() }
                let landed = self.hosting.view.convert(target.frame, to: self.view)
                let hero = self.heroContainer.frame
                guard abs(landed.midX - hero.midX) > 1 || abs(landed.midY - hero.midY) > 1 || abs(landed.width - hero.width) > 1 else {
                    return handOff()
                }
                PlayerModeTransitionAnchors.nowPlaying.setArtworkViewsHidden(true)
                UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 0) {
                    self.heroContainer.frame = landed
                    self.heroView.layer.cornerRadius = target.cornerRadius
                    self.setHeroFade(size: landed.size, fades: target.fades)
                } completion: { _ in handOff() }
            }
        })
    }

    private func rememberRestingTarget() {
        if let target = measureCoverTarget() { restingTargets[restingKey] = target }
    }

    private var currentTarget: CoverTarget? {
        measureCoverTarget() ?? restingTargets[restingKey]
    }

    // MARK: Geometry

    private var screenBounds: CGRect { view.bounds }

    private var displayCornerRadius: CGFloat {
        (view.window?.safeAreaInsets.bottom ?? 34) > 0 ? 55 : 0
    }

    /// Where the tab view draws the mini player, read from UIKit: SwiftUI's
    /// global frame is relative to whatever hosts the accessory, which on
    /// iPad isn't always the window (the card closed toward the top).
    private var accessoryFrame: CGRect? {
        guard let container = MiniPlayerGeometry.shared.accessoryContainer,
              container.window != nil, container.bounds.width > 1 else { return nil }
        let frame = container.convert(container.bounds, to: view)
        return screenBounds.intersects(frame) ? frame : nil
    }

    private var miniFrame: CGRect {
        if let frame = accessoryFrame { return frame }
        let frame = MiniPlayerGeometry.shared.frame
        guard frame.width > 1, screenBounds.intersects(frame) else {
            // No visible mini player: collapse toward the bottom edge.
            return CGRect(x: 20, y: screenBounds.maxY - 110, width: screenBounds.width - 40, height: 56)
        }
        return frame
    }

    private var miniArtworkFrame: CGRect {
        let geometry = MiniPlayerGeometry.shared
        let mini = miniFrame
        // Placed by its offset in the mini player: both global frames share
        // whatever origin SwiftUI measured them from.
        let artwork = geometry.artworkFrame.offsetBy(dx: mini.minX - geometry.frame.minX, dy: mini.minY - geometry.frame.minY)
        guard geometry.artworkFrame.width > 1, mini.insetBy(dx: -4, dy: -4).contains(artwork) else {
            return CGRect(x: mini.minX + 10, y: mini.midY - 18, width: 36, height: 36)
        }
        return MusicVideoPlayer.fitted(artwork)
    }

    /// Where the player hangs inside a card laid out at `card`: full-screen
    /// size, top edge on the card's, centered — so it rises and sinks with the
    /// card like Music's instead of being squashed.
    private func contentOrigin(in card: CGRect) -> CGPoint {
        CGPoint(x: (card.width - screenBounds.width) / 2, y: 0)
    }

    private func layoutCard(_ frame: CGRect) {
        layoutCardSize(frame.size)
        layoutCardPosition(frame)
    }

    /// Size and shape: animated without bounce.
    private func layoutCardSize(_ size: CGSize) {
        cardView.bounds.size = size
        glassView.bounds.size = size
        miniHosting.view.frame = CGRect(x: 0, y: 0, width: size.width, height: miniFrame.height)
        let contentFrame = CGRect(origin: contentOrigin(in: CGRect(origin: .zero, size: size)), size: screenBounds.size)
        // Turned against the screen's own turn, so its colors stay put
        // while the phone rotates.
        let turnedSideways = Int((abs(backgroundAngle) / (.pi / 2)).rounded()) % 2 == 1
        backgroundView.transform = .identity
        backgroundView.bounds.size = turnedSideways
            ? CGSize(width: contentFrame.height, height: contentFrame.width)
            : contentFrame.size
        backgroundView.center = CGPoint(x: contentFrame.midX, y: contentFrame.midY)
        backgroundView.transform = CGAffineTransform(rotationAngle: backgroundAngle)
        hosting.view.frame = contentFrame
    }

    /// Position: the part that dips when the mini player lands, like Music's.
    private func layoutCardPosition(_ frame: CGRect) {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        cardView.center = center
        glassView.center = center
    }

    private func restFullScreen() {
        cardView.transform = .identity
        layoutCard(screenBounds)
        cardView.layer.cornerRadius = 0
        cardView.alpha = 1
        backgroundView.alpha = 1
        hosting.view.alpha = 1
        glassView.isHidden = true
        miniHosting.view.alpha = 0
    }

    /// Shows the morph's glass and mini player content, matching the real
    /// mini player's current placement.
    private func prepareMiniLayer(alpha: CGFloat) {
        let inline = MiniPlayerGeometry.shared.isInline
        let scheme = MiniPlayerGeometry.shared.colorScheme
        if miniHostingInline != inline || miniHostingScheme != scheme, let miniProvider {
            miniHostingInline = inline
            miniHostingScheme = scheme
            miniHosting.rootView = AnyView(miniProvider(inline).environment(\.colorScheme, scheme))
        }
        // The glass too, not just its content: the overlay window is always
        // dark, and a light glass read frostier than the real one in dark
        // mode (and a dark one would in light mode), so the material changed
        // on hand-over.
        glassView.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light
        miniHosting.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light
        if glassView.effect == nil { glassView.effect = UIGlassEffect() }
        glassView.alpha = 1
        glassView.isHidden = false
        miniHosting.view.alpha = alpha
        miniHosting.view.layoutIfNeeded()
    }

    private static func motionHidesLargeCover(_ target: CoverTarget) -> Bool {
        target.shadow != .compact && MotionArtworkState.shared.hidesCover
    }

    /// The cover's frame in the player's own space. Only trusted when it looks
    /// like a laid-out cover (square, on screen, below the status bar).
    private func measureCoverTarget() -> CoverTarget? {
        let anchors = PlayerModeTransitionAnchors.nowPlaying
        // Side by side, the lyrics sit next to the large cover: there's no
        // compact one on screen.
        let compact = showsLyrics ? anchors.compactView.flatMap { $0.window != nil ? $0 : nil } : nil
        guard let anchor = compact ?? anchors.largeView,
              anchor.window != nil, anchor.bounds.width > 20 else { return nil }
        let frame = anchor.convert(anchor.bounds, to: hosting.view)
        let bounds = CGRect(origin: .zero, size: screenBounds.size)
        // The full-screen artwork is as wide as the screen.
        let bleeds = compact == nil && frame.width > bounds.width - 2
        guard abs(frame.width - frame.height) < 2 || MusicVideoPlayer.shared.shownSongID != nil, bounds.insetBy(dx: -1, dy: -1).contains(frame), frame.minY > 40 else { return nil }
        if compact != nil { return CoverTarget(frame: MusicVideoPlayer.fitted(frame), cornerRadius: frame.width > 100 ? 12 : (MusicVideoPlayer.shared.shownSongID != nil ? 6 : 8), shadow: .compact) }
        return bleeds
            ? CoverTarget(frame: frame, cornerRadius: 0, shadow: .none, fades: true)
            : CoverTarget(frame: frame, cornerRadius: 12, shadow: .large)
    }

    private func prepareHero(at frame: CGRect, cornerRadius: CGFloat, shadow: HeroShadow, fades: Bool = false) -> Bool {
        let source = artworkProvider?()
        let carriesVideo = MusicVideoPlayer.shared.isShown(for: source)
        guard let source,
              let image = (carriesVideo ? MusicVideoPlayer.coverImage(for: source, points: 340) : nil)
                ?? ArtworkImageCache.shared.cachedImage(for: source, points: 340)
                ?? ArtworkImageCache.shared.imageSync(for: source, points: 340) else {
            heroContainer.isHidden = true
            return false
        }
        heroView.image = image
        heroContainer.frame = frame
        heroContainer.alpha = 1
        heroView.layer.cornerRadius = cornerRadius
        if carriesVideo, heroVideo == nil {
            let host = MusicVideoHostView(role: .flight)
            host.frame = heroContainer.bounds
            host.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            heroContainer.addSubview(host)
            heroVideo = host
        }
        // The video alone flies.
        heroView.isHidden = heroVideo != nil
        setHeroFade(size: frame.size, fades: fades)
        setHeroShadow(shadow)
        heroContainer.isHidden = false
        PlayerModeTransitionAnchors.nowPlaying.setArtworkViewsHidden(true)
        return true
    }

    /// In an animation, the melt follows the flying cover's size.
    private func setHeroFade(size: CGSize, fades: Bool) {
        heroFade.frame = CGRect(origin: .zero, size: size)
        heroFade.fades = fades
        if fades { heroView.mask = heroFade }
        if let heroVideo {
            // The video follows the flight's shape within the same animation.
            heroVideo.layer.cornerRadius = heroView.layer.cornerRadius
            heroContainer.layoutIfNeeded()
            heroVideo.layoutIfNeeded()
        }
    }

    private func finishHero() {
        // The real covers back first: the video, handed back to one of
        // them, finds it shown and lies over it at once (else the cover
        // shows a frame or two).
        PlayerModeTransitionAnchors.nowPlaying.setArtworkViewsHidden(false)
        heroVideo?.removeFromSuperview()
        heroVideo = nil
        heroView.isHidden = false
        heroContainer.isHidden = true
        heroContainer.layer.removeAllAnimations()
        heroView.mask = nil
    }

    /// The cover's shadow in each place it sits, so it travels with the
    /// flying cover instead of popping in when the real one takes over.
    enum HeroShadow {
        case mini, compact, large, none

        var values: (opacity: Float, radius: CGFloat, offset: CGFloat) {
            switch self {
            case .mini: (0.18, 1.5, 1)
            // SwiftUI's shadow radius is about twice Core Animation's.
            case .compact: (0.26, 6, 7)
            case .large: (0.32, 14, 18)
            // Same size as the mini player's: only its opacity grows.
            case .none: (0, 1.5, 1)
            }
        }
    }

    private func setHeroShadow(_ shadow: HeroShadow) {
        let values = shadow.values
        let layer = heroContainer.layer
        layer.removeAnimation(forKey: "shadow")
        layer.shadowOpacity = values.opacity
        layer.shadowRadius = values.radius
        layer.shadowOffset = CGSize(width: 0, height: values.offset)
    }

    private func animateHeroShadow(to shadow: HeroShadow, duration: CFTimeInterval, timing: CAMediaTimingFunction) {
        let layer = heroContainer.layer
        let values = shadow.values
        let group = CAAnimationGroup()
        group.animations = [
            Self.basic("shadowOpacity", from: layer.shadowOpacity, to: values.opacity),
            Self.basic("shadowRadius", from: layer.shadowRadius, to: values.radius),
            Self.basic("shadowOffset", from: layer.shadowOffset, to: CGSize(width: 0, height: values.offset))
        ]
        group.duration = duration
        group.timingFunction = timing
        layer.shadowOpacity = values.opacity
        layer.shadowRadius = values.radius
        layer.shadowOffset = CGSize(width: 0, height: values.offset)
        layer.add(group, forKey: "shadow")
    }

    private static func basic(_ keyPath: String, from: Any, to: Any) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = to
        return animation
    }

    // MARK: Timing

    /// Every moving part shares one spring, so nothing drifts apart. Music's
    /// figures (measured frame by frame on a screen recording): ~0.38 s,
    /// three quarters of the way after 0.17 s, no overshoot when opening and a
    /// ~4 pt dip when the mini player lands.
    private func spring(duration: TimeInterval, bounce: CGFloat, velocity: CGFloat = 0) -> UIViewPropertyAnimator {
        let timing = UISpringTimingParameters(duration: duration, bounce: bounce, initialVelocity: CGVector(dx: velocity, dy: velocity))
        return UIViewPropertyAnimator(duration: duration, timingParameters: timing)
    }

    private func run(_ animator: UIViewPropertyAnimator, after delay: TimeInterval = 0) {
        animators.append(animator)
        animator.startAnimation(afterDelay: delay)
    }

    private func stopAnimations() {
        for animator in animators where animator.state == .active {
            animator.stopAnimation(true)
        }
        animators = []
    }

    /// Springs report completion only once fully at rest, long after the
    /// motion is over to the eye; the phase ends at `time` instead.
    private func after(_ time: TimeInterval, in phase: Phase, _ action: @escaping () -> Void) {
        let token = UUID()
        phaseToken = token
        DispatchQueue.main.asyncAfter(deadline: .now() + time) { [weak self] in
            guard let self, self.phaseToken == token, self.phase == phase else { return }
            action()
        }
    }

    // MARK: Expand

    /// Puts the card over the mini player before the first frame.
    func prepareForExpand(in bounds: CGRect) {
        loadViewIfNeeded()
        stopAnimations()
        finishHero()
        phase = .expanding
        view.frame = bounds
        hosting.view.alpha = 0
        backgroundView.alpha = 0
        cardView.alpha = 1
        cardView.transform = .identity
        dragOffset = 0
        let start = miniFrame
        layoutCard(start)
        cardView.layer.cornerRadius = start.height / 2
        // The first frame is a copy of the mini player (glass + content):
        // nothing changes on screen until it starts to grow.
        prepareMiniLayer(alpha: 1)
        NowPlayingMorph.shared.setCovers(true, animated: false)
    }

    /// `fromCurrentState`: grabbed back while closing — it grows again from
    /// wherever it is, every fade continuing from its current value.
    func expand(fromCurrentState: Bool = false) {
        if fromCurrentState {
            stopAnimations()
            phase = .expanding
            glassView.effect = UIGlassEffect()
            glassView.alpha = 1
            heroContainer.alpha = 1
            NowPlayingMorph.shared.setCovers(true, animated: false)
        }
        guard phase == .expanding else { return }
        view.layoutIfNeeded()
        hosting.view.layoutIfNeeded()

        if !fromCurrentState {
            let start = miniFrame
            layoutCard(start)
            cardView.layer.cornerRadius = start.height / 2
        }

        let target = currentTarget
        if let target { restingTargets[restingKey] = target }
        let geometry = MiniPlayerGeometry.shared
        var hasHero = !heroContainer.isHidden && fromCurrentState
        if !hasHero, target != nil {
            hasHero = prepareHero(at: miniArtworkFrame, cornerRadius: geometry.artworkCornerRadius, shadow: .mini)
        }

        let duration: TimeInterval = 0.38
        let full = screenBounds
        let size = spring(duration: duration, bounce: 0)
        size.addAnimations {
            self.layoutCardSize(full.size)
            self.cardView.layer.cornerRadius = self.displayCornerRadius
            if hasHero, let target {
                self.heroContainer.bounds.size = target.frame.size
                self.heroView.layer.cornerRadius = target.cornerRadius
                self.setHeroFade(size: target.frame.size, fades: target.fades)
            }
        }
        let position = spring(duration: duration, bounce: 0)
        position.addAnimations {
            self.layoutCardPosition(full)
            if hasHero, let target {
                self.heroContainer.center = CGPoint(x: target.frame.midX, y: target.frame.midY)
            }
        }
        run(size)
        run(position)
        // The mini player's glass grows, its title and buttons give way to the
        // artwork colors, then the controls come in.
        run(UIViewPropertyAnimator(duration: 0.1, curve: .easeOut) { self.miniHosting.view.alpha = 0 })
        run(UIViewPropertyAnimator(duration: 0.14, curve: .easeOut) { self.backgroundView.alpha = 1 }, after: 0.02)
        run(UIViewPropertyAnimator(duration: 0.2, curve: .easeOut) { self.hosting.view.alpha = 1 }, after: 0.04)
        if hasHero, let target {
            animateHeroShadow(to: target.shadow, duration: duration * 0.7, timing: CAMediaTimingFunction(name: .easeOut))
            // The motion artwork takes the large cover's place: the flying
            // one melts into it instead of landing.
            if Self.motionHidesLargeCover(target) {
                run(UIViewPropertyAnimator(duration: 0.14, curve: .easeOut) { self.heroContainer.alpha = 0 })
            }
        }
        after(duration * 1.25, in: .expanding) {
            self.stopAnimations()
            self.phase = .shown
            self.finishHero()
            self.restFullScreen()
            self.rememberRestingTarget()
        }
    }

    // MARK: Collapse

    func collapse(velocity: CGFloat) {
        guard phase != .collapsing, phase != .hidden else { return }
        let fromDrag = phase == .dragging
        let heroInFlight = phase == .expanding && !heroContainer.isHidden
        // Freezes everything (mid-opening, mid-drag) where it is on screen.
        stopAnimations()
        if !heroInFlight { finishHero() }
        phase = .collapsing
        // The app takes touches again right away (the card lets them through).
        // Its state only flips once the card has landed: re-rendering the app
        // the instant the finger lifts stalled the first frames of the flight.
        appWindow?.makeKey()

        let current = cardView.frame
        cardView.transform = .identity
        dragOffset = 0
        layoutCard(current)
        cardView.alpha = 1
        if fromDrag || cardView.layer.cornerRadius < displayCornerRadius {
            cardView.layer.cornerRadius = max(cardView.layer.cornerRadius, displayCornerRadius)
        }

        prepareMiniLayer(alpha: miniHosting.view.alpha)
        layoutCard(current)
        NowPlayingMorph.shared.setCovers(true, animated: false)

        let end = miniFrame
        let geometry = MiniPlayerGeometry.shared
        var hasHero = heroInFlight
        heroView.mask = nil
        if !hasHero, let target = currentTarget {
            let origin = contentOrigin(in: current)
            let from = target.frame.offsetBy(dx: current.minX + origin.x, dy: current.minY + origin.y)
            // No melt on the way down: the mask's offscreen pass drew a dark
            // rim around the small cover. The player fades out at once anyway.
            hasHero = prepareHero(at: from, cornerRadius: target.cornerRadius, shadow: target.shadow)
            // No cover was showing over the motion artwork: it comes out of it.
            if hasHero, Self.motionHidesLargeCover(target) {
                heroContainer.alpha = 0
                run(UIViewPropertyAnimator(duration: 0.22, curve: .easeOut) { self.heroContainer.alpha = 1 })
            }
        }
        let heroEnd = miniArtworkFrame

        let duration: TimeInterval = 0.4
        // The finger's speed carries into the spring (relative to the distance left).
        // Relative to the top edge's travel (what the finger drags): the
        // card's center can already sit below the mini player's while the
        // card is still tall, which made the old center-based figure huge.
        let travel = max(end.minY - current.minY, 40)
        let size = spring(duration: duration * 0.9, bounce: 0)
        size.addAnimations {
            self.layoutCardSize(end.size)
            self.cardView.layer.cornerRadius = end.height / 2
            if hasHero {
                self.heroContainer.bounds.size = heroEnd.size
                self.heroView.layer.cornerRadius = geometry.artworkCornerRadius
                self.setHeroFade(size: heroEnd.size, fades: false)
            }
        }
        // Only the position bounces: the mini player dips a few points below
        // its place and comes back up, without changing size.
        // Measured on Music (60 fps): the mini player dips ~6 pt below its
        // place ~0.29 s in, then settles back by ~0.4 s.
        // A flick's speed is capped: the full speed of a fast throw made the card
        // slam into the mini player.
        let cappedVelocity = min(max(velocity, 0), 1400)
        let position = spring(duration: 0.36, bounce: 0.17, velocity: min(cappedVelocity / travel, 4))
        position.addAnimations {
            self.layoutCardPosition(end)
            if hasHero {
                self.heroContainer.center = CGPoint(x: heroEnd.midX, y: heroEnd.midY)
            }
        }
        // Square again: the mask goes, its offscreen pass left a dark rim
        // around the cover in the mini player.
        if hasHero { size.addCompletion { _ in self.heroView.mask = nil } }
        run(size)
        run(position)
        run(UIViewPropertyAnimator(duration: 0.12, curve: .easeIn) { self.hosting.view.alpha = 0 })
        // Halfway down, like Music's, the colors give way to the glass and
        // the mini player's title and buttons appear at the card's top: the
        // card *is* the mini player from then on.
        if MotionArtworkState.shared.hidesCover {
            // Over a motion artwork the big video shrinking into the capsule
            // read as a squashed picture: it gives way to the glass at once,
            // and the card is the mini player for most of the way down.
            run(UIViewPropertyAnimator(duration: duration * 0.4, curve: .easeOut) { self.backgroundView.alpha = 0 })
            run(UIViewPropertyAnimator(duration: duration * 0.35, curve: .easeInOut) { self.miniHosting.view.alpha = 1 }, after: duration * 0.15)
        } else {
            run(UIViewPropertyAnimator(duration: duration * 0.3, curve: .easeInOut) { self.backgroundView.alpha = 0 }, after: duration * 0.3)
            run(UIViewPropertyAnimator(duration: duration * 0.3, curve: .easeInOut) { self.miniHosting.view.alpha = 1 }, after: duration * 0.36)
        }
        if hasHero { animateHeroShadow(to: .mini, duration: duration * 0.6, timing: CAMediaTimingFunction(name: .easeInEaseOut)) }
        // Hand-over, once the dip has settled. The real mini player can't
        // take over any earlier: the card only reaches its height as the dip
        // ends. The swap itself is a cut (fading either glass dropped its
        // text's vibrancy, so the artist name changed shade), and a still of
        // the card fades off the real one to blend the two glasses: the tab
        // bar draws its glass a little sharper than a standalone one.
        after(duration * 1.15, in: .collapsing) {
            // The real content comes back while its container is still
            // hidden, so it has rendered by the time the container shows.
            // The app learns the player closed now too: it rebuilds the mini
            // player's content, which showed an empty glass for a frame when
            // that happened at the swap.
            NowPlayingMorph.shared.setCovers(false, animated: false)
            self.onClosing?()
            self.after(3.0 / 60.0, in: .collapsing) {
                // A still of the card alone takes its place in the app's
                // window as the card goes: shown again, the real mini
                // player's glass is there at once but its content only a
                // frame later (an empty capsule), and its first frame drew a
                // dark halo around the cover. The still covers both.
                self.addHandOverStill()
                self.finishCollapse()
            }
        }
    }

    private var handOverStill: UIView?

    /// A still of the card where the mini player is, laid over the real one
    /// in the app's window (under the card until it goes).
    private func addHandOverStill() {
        removeHandOverStill()
        guard let appWindow, let screen = view.window?.screen else { return }
        let still = screen.snapshotView(afterScreenUpdates: false)
        let frame = glassView.frame
        let holder = UIView(frame: appWindow.convert(frame, from: view))
        holder.isUserInteractionEnabled = false
        holder.clipsToBounds = true
        holder.layer.cornerCurve = .continuous
        holder.layer.cornerRadius = frame.height / 2
        still.frame = CGRect(origin: CGPoint(x: -holder.frame.minX, y: -holder.frame.minY), size: screen.bounds.size)
        holder.addSubview(still)
        // The flying cover isn't in the screen's still: a copy of it stays
        // on, or the card showed without its cover for a frame.
        if !heroContainer.isHidden, let image = heroView.image {
            let cover = UIImageView(image: image)
            cover.contentMode = .scaleAspectFill
            cover.clipsToBounds = true
            cover.layer.cornerCurve = .continuous
            cover.layer.cornerRadius = heroView.layer.cornerRadius
            cover.frame = holder.convert(heroContainer.frame, from: view)
            holder.addSubview(cover)
        }
        appWindow.addSubview(holder)
        handOverStill = holder
    }

    /// The still fades off the real mini player.
    private func fadeHandOverStill() {
        guard let holder = handOverStill else { return }
        // A beat late: the real one's first frames stay covered.
        UIView.animate(withDuration: 0.3, delay: 2.0 / 60.0, options: [.curveEaseInOut, .allowUserInteraction]) {
            holder.alpha = 0
        } completion: { _ in
            holder.removeFromSuperview()
        }
    }

    private func removeHandOverStill() {
        handOverStill?.removeFromSuperview()
        handOverStill = nil
    }

    private func finishCollapse() {
        stopAnimations()
        fadeHandOverStill()
        finishHero()
        phase = .hidden
        NowPlayingMorph.shared.setCovers(false, animated: false)
        // One transaction: the real mini player and the card swap in the
        // same frame, never both or neither on screen.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        NowPlayingMorph.shared.showAccessory()
        overlayWindow?.isHidden = true
        CATransaction.commit()
        dragOffset = 0
        // The card resets once its window is off screen.
        DispatchQueue.main.async {
            guard self.phase == .hidden else { return }
            self.restFullScreen()
        }
    }

    // MARK: Interactive dismissal

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: view).y
        switch gesture.state {
        case .began:
            if phase == .expanding {
                // Grabbed while opening: finish the fades, keep the card where it is.
                stopAnimations()
                finishHero()
                hosting.view.alpha = 1
                backgroundView.alpha = 1
                miniHosting.view.alpha = 0
                glassView.isHidden = true
            } else {
                stopAnimations()
            }
            phase = .dragging
            // The card owns the drag from now on: a slow drag is rarely
            // straight, and the cover pager or the lyrics would otherwise
            // start sliding along with it.
            cancelScrollViews(in: hosting.view)
        case .changed:
            // Follows the finger; pulling up only stretches a little.
            dragOffset = translation >= 0 ? translation : -pow(-translation, 0.7)
            cardView.transform = CGAffineTransform(translationX: 0, y: dragOffset)
            cardView.layer.cornerRadius = displayCornerRadius * min(max(dragOffset / 80, 0), 1)
        case .ended, .cancelled, .failed:
            let velocity = gesture.velocity(in: view).y
            // Like Music: where the card would coast to decides, not just where it is.
            let projected = dragOffset + velocity * 0.18
            if gesture.state == .ended, dragOffset > 10, projected > screenBounds.height * 0.25 {
                collapse(velocity: velocity)
            } else {
                let animator = spring(duration: 0.34, bounce: 0.1, velocity: -velocity / max(abs(dragOffset), 1))
                let full = screenBounds
                animator.addAnimations {
                    self.cardView.transform = .identity
                    self.layoutCard(full)
                    self.cardView.layer.cornerRadius = 0
                }
                animator.addCompletion { _ in
                    if self.phase == .dragging { self.phase = .shown }
                }
                dragOffset = 0
                run(animator)
            }
        default:
            break
        }
    }

    private func cancelScrollViews(in root: UIView) {
        var queue = [root]
        while !queue.isEmpty {
            let view = queue.removeFirst()
            if let scrollView = view as? UIScrollView {
                scrollView.panGestureRecognizer.isEnabled = false
                scrollView.panGestureRecognizer.isEnabled = true
                // A pager left between pages snaps back to its page.
                if scrollView.isPagingEnabled, scrollView.bounds.width > 0 {
                    let page = (scrollView.contentOffset.x / scrollView.bounds.width).rounded()
                    scrollView.setContentOffset(CGPoint(x: page * scrollView.bounds.width, y: scrollView.contentOffset.y), animated: true)
                }
            }
            queue.append(contentsOf: view.subviews)
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard phase == .shown || phase == .dragging || phase == .expanding, presentedViewController == nil else { return false }
        return findScrollView(from: touch.view)
    }

    /// Notes the scrollable content under the finger (or pointer); false
    /// over a slider, which keeps its own drags.
    private func findScrollView(from hitView: UIView?) -> Bool {
        scrollViewUnderTouch = nil
        var view = hitView
        while let current = view, current !== self.view {
            if current is UISlider { return false }
            if let scrollView = current as? UIScrollView, scrollViewUnderTouch == nil,
               scrollView.contentSize.height > scrollView.bounds.height + 1 {
                scrollViewUnderTouch = scrollView
            }
            view = current.superview
        }
        return true
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer, pan === self.pan || pan === scrollPan else { return true }
        if pan === scrollPan {
            // Scrolls carry no touch: check the card and what's under the pointer here.
            guard phase == .shown || phase == .dragging || phase == .expanding, presentedViewController == nil,
                  findScrollView(from: view.hitTest(pan.location(in: view), with: nil)) else { return false }
        }
        let velocity = pan.velocity(in: view)
        guard velocity.y > 0, velocity.y > abs(velocity.x) * 1.2 else { return false }
        if let scrollView = scrollViewUnderTouch,
           scrollView.contentOffset.y > -scrollView.adjustedContentInset.top + 1 {
            return false
        }
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        other.view is UIScrollView && other.view === scrollViewUnderTouch
    }
}
