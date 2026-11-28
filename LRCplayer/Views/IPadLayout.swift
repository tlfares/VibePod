import SwiftUI
import UIKit
import Combine

// MARK: - Navigation style

/// How the tabs are laid out on a regular-width screen (an iPad): the
/// floating bar at the bottom, like on iPhone, or the native sidebar.
enum IPadNavigation: String, CaseIterable, Identifiable {
    case tabBar
    case sidebar

    static let storageKey = "iPadNavigationStyle"

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .tabBar: "Tab Bar"
        case .sidebar: "Sidebar"
        }
    }
}

// MARK: - Floating mini player

/// On a regular-width screen the tab view's bottom accessory, and the tab
/// bar with it, stretch from edge to edge. There the mini player floats
/// above the bar on its own Liquid Glass capsule instead, centered at a
/// large phone's width, and the bar keeps its native, fitted size.
@MainActor
final class FloatingMiniPlayerState: ObservableObject {
    static let shared = FloatingMiniPlayerState()

    /// Room the floating mini player takes above the bar.
    static let height: CGFloat = 48
    static let spacing: CGFloat = 8
    static let width: CGFloat = 540

    /// What the pages leave free at their bottom for a floating player (the
    /// mini player, or the wide player bar); zero when none floats there.
    @Published var reservedHeight: CGFloat = 0
    /// The wide player bar takes the mini player's place: on the Mac, and on
    /// a screen wide enough for it.
    @Published var usesWideBar = false
    /// From the screen's bottom edge to the top of the tab bar.
    @Published private(set) var barTopInset: CGFloat = 0
    /// Width of the tab bar's visible capsule: the mini player matches it.
    @Published private(set) var barWidth: CGFloat = 0
    /// A tab bar standing on the side (a phone held sideways, an unfolded
    /// iPhone Duo): the player sits at the bottom, clear of it.
    @Published private(set) var sideBarInset: CGFloat = 0
    /// The tab bar stands on the side: its bottom accessory would be drawn
    /// cramped, so the mini player floats at the bottom instead.
    @Published private(set) var tabBarStandsAside = false

    private weak var tabBar: UITabBar?
    private var observations: [NSKeyValueObservation] = []
    private weak var platter: UIView?
    private var platterObservation: NSKeyValueObservation?

    /// Watches the tab bar's frame (read only: UIKit lays it out).
    func attach(to tabBarController: UITabBarController?) {
        guard let tabBar = tabBarController?.tabBar, tabBar !== self.tabBar else { return }
        self.tabBar = tabBar
        observations = [
            tabBar.layer.observe(\.bounds) { [weak self] _, _ in MainActor.assumeIsolated { self?.measureSoon() } },
            tabBar.layer.observe(\.position) { [weak self] _, _ in MainActor.assumeIsolated { self?.measureSoon() } },
        ]
        measure()
    }

    private var measurePending = false

    /// From the bar's own layout: published right after it, not during it
    /// (publishing inside UIKit's layout, while SwiftUI updates the tab bar
    /// as the screen turns, deadlocked SwiftUI's update lock).
    private func measureSoon() {
        guard !measurePending else { return }
        measurePending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.measurePending = false
            self.measure()
        }
    }

    func measure() {
        guard let tabBar, let window = tabBar.window else { return }
        let frame = tabBar.convert(tabBar.bounds, to: window)
        if let platter = Self.platter(of: tabBar), platter !== self.platter {
            self.platter = platter
            platterObservation = platter.layer.observe(\.bounds) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.measureSoon() }
            }
        }
        // Standing on the right edge: the player keeps to the bottom, clear
        // of it (the window's safe area may already keep it away).
        let isSide = !tabBar.isHidden && frame.height > frame.width && frame.minX > window.bounds.midX
        // Beside it, the player's bottom lines up with the tabs' capsule.
        let tabsBottom = tabBar.subviews
            .filter { !$0.isHidden && $0.alpha > 0.01 }
            .map { $0.convert($0.bounds, to: window).maxY }
            .max()
        let inset = isSide
            ? max(0, window.bounds.height - (tabsBottom ?? window.bounds.height - window.safeAreaInsets.bottom) - Self.spacing)
            : max(0, window.bounds.height - frame.minY)
        if abs(inset - barTopInset) > 0.5 { barTopInset = inset }
        let side = isSide ? max(0, window.bounds.maxX - frame.minX - window.safeAreaInsets.right) : 0
        if abs(side - sideBarInset) > 0.5 { sideBarInset = side }
        if isSide != tabBarStandsAside { tabBarStandsAside = isSide }
        let width = isSide ? 0 : Self.visibleWidth(of: tabBar)
        if abs(width - barWidth) > 0.5 { barWidth = width }
    }

    /// The bar's own frame spans the screen while its glass is fitted to
    /// the tabs: that's the widest tall subview (the tabs' platter).
    private static func platter(of tabBar: UITabBar) -> UIView? {
        tabBar.subviews
            .filter { !$0.isHidden && $0.alpha > 0.01 && $0.bounds.height > 20 }
            .max { $0.frame.width < $1.frame.width }
    }

    private static func visibleWidth(of tabBar: UITabBar) -> CGFloat {
        let widest = platter(of: tabBar)?.frame.width ?? tabBar.bounds.width
        return min(widest, tabBar.bounds.width)
    }
}

struct FloatingMiniPlayer: View {
    @ObservedObject private var state = FloatingMiniPlayerState.shared
    @ObservedObject private var morph = NowPlayingMorph.shared

    var body: some View {
        Group {
            if state.usesWideBar {
                // Its own glass, and its own fade while Now Playing morphs.
                MacPlayerBar()
                    .frame(maxWidth: MacPlayerBar.maximumWidth)
            } else {
                MiniPlayerView()
                    .frame(height: FloatingMiniPlayerState.height)
                    .frame(width: state.barWidth > 0 ? state.barWidth : nil)
                    .frame(maxWidth: FloatingMiniPlayerState.width)
                    .glassEffect(.regular.interactive(), in: Capsule())
                    .animation(.smooth(duration: 0.3), value: state.barWidth)
                    // Under the Now Playing card's own glass while it morphs.
                    .opacity(morph.hidesFloatingGlass ? 0.02 : 1)
            }
        }
            .padding(.trailing, state.sideBarInset)
            .padding(.horizontal, 20)
            .padding(.bottom, state.barTopInset + FloatingMiniPlayerState.spacing)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .ignoresSafeArea(.container, edges: .bottom)
            .onAppear { state.measure() }
            // Rotation, window resize: the bar moves after this layout pass.
            .onGeometryChange(for: CGSize.self) { $0.size } action: { _ in
                state.measure()
                DispatchQueue.main.async { state.measure() }
            }
    }
}

// MARK: - iPad player canvas

/// Where one part of the iPad player sits: its untransformed size, its
/// center, and the scale and alpha Core Animation draws it with.
struct IPadPlayerPlacement: Equatable {
    var center: CGPoint
    var size: CGSize
    var scale: CGFloat = 1
    var alpha: CGFloat = 1
    var isInteractive = true
}

/// The iPad player's parts (lyrics, cover, title, controls), each in its
/// own hosting view, placed and animated by UIKit. A change of layout runs
/// in Core Animation, not as a SwiftUI update per frame, and as each part
/// is a real view in its place (transform included), touches always land
/// where the part is drawn. The parts are never rebuilt: turning the iPad
/// or opening the lyrics only moves, scales and fades them.
struct IPadPlayerCanvas: UIViewControllerRepresentable {
    var parts: [AnyView]
    var placements: [IPadPlayerPlacement]

    func makeUIViewController(context: Context) -> Controller {
        let controller = Controller(parts: parts)
        controller.apply(placements, animated: false)
        return controller
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.update(parts)
        let animated = context.transaction.animation != nil && !context.transaction.disablesAnimations
        controller.apply(placements, animated: animated)
    }

    final class Controller: UIViewController {
        private let hosts: [UIHostingController<AnyView>]
        private var current: [IPadPlayerPlacement] = []

        init(parts: [AnyView]) {
            hosts = parts.map { part in
                let host = UIHostingController(rootView: part)
                host.sizingOptions = []
                host.safeAreaRegions = []
                return host
            }
            super.init(nibName: nil, bundle: nil)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:)") }

        override func loadView() {
            view = PassthroughView()
            view.backgroundColor = .clear
        }

        override func viewDidLoad() {
            super.viewDidLoad()
            for host in hosts {
                addChild(host)
                host.view.backgroundColor = .clear
                view.addSubview(host.view)
                host.didMove(toParent: self)
            }
        }

        func update(_ parts: [AnyView]) {
            for (host, part) in zip(hosts, parts) { host.rootView = part }
        }

        func apply(_ placements: [IPadPlayerPlacement], animated: Bool) {
            guard placements != current else { return }
            loadViewIfNeeded()
            let first = current.isEmpty
            current = placements
            for (host, placement) in zip(hosts, placements) {
                host.view.isUserInteractionEnabled = placement.isInteractive
                host.view.accessibilityElementsHidden = placement.alpha < 0.01
            }
            let changes = { [hosts] in
                for (host, placement) in zip(hosts, placements) {
                    let bounds = CGRect(origin: .zero, size: placement.size)
                    if host.view.bounds != bounds { host.view.bounds = bounds }
                    host.view.center = placement.center
                    host.view.transform = CGAffineTransform(scaleX: placement.scale, y: placement.scale)
                    host.view.alpha = placement.alpha
                }
            }
            if animated && !first {
                UIView.animate(springDuration: 0.5, bounce: 0.06, initialSpringVelocity: 0, delay: 0,
                               options: [.beginFromCurrentState, .allowUserInteraction], animations: changes)
            } else if first {
                UIView.performWithoutAnimation(changes)
            } else {
                // Unanimated: inside a rotation, UIKit's own animation
                // carries the change.
                changes()
            }
        }
    }

    /// Touches between the parts reach what lies beneath.
    final class PassthroughView: UIView {
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            let hit = super.hitTest(point, with: event)
            return hit === self ? nil : hit
        }
    }
}
