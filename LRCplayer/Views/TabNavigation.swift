import SwiftUI
import UIKit
import Combine

// MARK: - Zoom sources

/// Artwork views that pages zoom out of (and back into), by zoom ID. Several
/// tabs can show the same tile, so a source is looked up inside the
/// navigation controller that's transitioning.
@MainActor
final class ZoomSourceRegistry {
    static let shared = ZoomSourceRegistry()

    private final class WeakView {
        weak var view: UIView?
        init(_ view: UIView) { self.view = view }
    }

    private var views: [String: [WeakView]] = [:]

    func register(_ view: UIView, for id: String) {
        var entries = (views[id] ?? []).filter { $0.view != nil && $0.view !== view }
        entries.append(WeakView(view))
        views[id] = entries
    }

    func unregister(_ view: UIView, for id: String) {
        views[id] = views[id]?.filter { $0.view != nil && $0.view !== view }
    }

    /// The on-screen source for `id` inside `container`, if any. Without one,
    /// UIKit zooms the page out of the screen's center instead.
    func view(for id: String, in container: UIView) -> UIView? {
        views[id]?
            .compactMap(\.view)
            .last { $0.window != nil && $0.isDescendant(of: container) && !$0.bounds.isEmpty }
    }
}

/// A tile's artwork, drawn by UIKit so the view the page zooms out of and
/// back into *is* the cover: UIKit hides it for the whole flight, so the
/// closing page lands in an empty slot instead of fading onto a cover that's
/// already there.
struct ZoomArtwork: UIViewRepresentable {
    let id: String
    let source: ArtworkSource?
    var cornerRadius: CGFloat = 8
    var points: CGFloat = 180
    var placeholderSymbol = "music.note"

    final class ArtworkView: UIView {
        let imageView = UIImageView()
        let loader = ArtworkImageLoader()
        var zoomID: String?
        var sourceKey: String?

        override init(frame: CGRect) {
            super.init(frame: frame)
            layer.cornerCurve = .continuous
            clipsToBounds = true
            backgroundColor = .tertiarySystemFill
            imageView.clipsToBounds = true
            imageView.tintColor = .tertiaryLabel
            imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            imageView.frame = bounds
            addSubview(imageView)
            isUserInteractionEnabled = false
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let zoomID else { return }
            if window != nil {
                ZoomSourceRegistry.shared.register(self, for: zoomID)
            } else {
                ZoomSourceRegistry.shared.unregister(self, for: zoomID)
            }
        }
    }

    func makeUIView(context: Context) -> ArtworkView {
        ArtworkView()
    }

    func updateUIView(_ view: ArtworkView, context: Context) {
        view.layer.cornerRadius = cornerRadius
        if view.sourceKey != source?.cacheKey || view.imageView.image == nil {
            view.sourceKey = source?.cacheKey
            let placeholder = UIImage(systemName: placeholderSymbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: max(12, points * 0.3), weight: .medium))
            view.loader.load(source, into: view.imageView, points: points, placeholder: placeholder)
        }
        guard view.zoomID != id else { return }
        if let old = view.zoomID { ZoomSourceRegistry.shared.unregister(view, for: old) }
        view.zoomID = id
        if view.window != nil { ZoomSourceRegistry.shared.register(view, for: id) }
    }

    static func dismantleUIView(_ view: ArtworkView, coordinator: ()) {
        if let id = view.zoomID { ZoomSourceRegistry.shared.unregister(view, for: id) }
        view.loader.cancel()
    }
}

// MARK: - Environment

extension View {
    /// What every page needs; hosting controllers don't inherit SwiftUI's
    /// environment, so each page gets it explicitly.
    func appEnvironment(_ services: AppServices) -> some View {
        self
            .environmentObject(services.libraryVM)
            .environmentObject(services.playerVM)
            .environmentObject(services.router)
            .environmentObject(services.importService)
            .environment(\.appServicesStorage, services)
            .modifier(StoredAppTint())
    }
}

/// The accent color for views hosted outside the main hierarchy.
struct StoredAppTint: ViewModifier {
    @AppStorage(AppTint.storageKey) private var tintColorRawValue = AppTint.infused.rawValue
    @ObservedObject private var infused = InfusedTint.shared

    func body(content: Content) -> some View {
        let tint = AppTint(rawValue: tintColorRawValue) ?? .infused
        content.tint(tint == .infused ? infused.color : tint.color)
    }
}

// MARK: - Page chrome (title, bar items, search)
//
// Hosting controllers don't bridge SwiftUI's `.navigationTitle`, `.toolbar`
// or `.searchable` to UIKit, so pages declare them with these modifiers and
// their controller installs the native equivalents.

struct PageTitle: Equatable {
    var text: String
    var large: Bool

    /// A literal title, localized.
    init(text: LocalizedStringResource, large: Bool) {
        self.text = String(localized: text)
        self.large = large
    }

    /// A dynamic title (a name), shown as is.
    @_disfavoredOverload
    init<S: StringProtocol>(text: S, large: Bool) {
        self.text = String(text)
        self.large = large
    }
}

struct PageBarItem: Equatable, @unchecked Sendable {
    let view: AnyView
    /// Views can't be compared: every update is applied.
    static func == (lhs: PageBarItem, rhs: PageBarItem) -> Bool { false }
}

struct PageSearch: Equatable, @unchecked Sendable {
    var text: String
    var prompt: String
    var alwaysVisible: Bool
    let setText: (String) -> Void

    static func == (lhs: PageSearch, rhs: PageSearch) -> Bool {
        lhs.text == rhs.text && lhs.prompt == rhs.prompt && lhs.alwaysVisible == rhs.alwaysVisible
    }
}

private struct PageTitleKey: PreferenceKey {
    static let defaultValue: PageTitle? = nil
    static func reduce(value: inout PageTitle?, nextValue: () -> PageTitle?) { value = nextValue() ?? value }
}

private struct PageLeadingKey: PreferenceKey {
    static let defaultValue: PageBarItem? = nil
    static func reduce(value: inout PageBarItem?, nextValue: () -> PageBarItem?) { value = nextValue() ?? value }
}

private struct PageTrailingKey: PreferenceKey {
    static let defaultValue: PageBarItem? = nil
    static func reduce(value: inout PageBarItem?, nextValue: () -> PageBarItem?) { value = nextValue() ?? value }
}

private struct PageSearchKey: PreferenceKey {
    static let defaultValue: PageSearch? = nil
    static func reduce(value: inout PageSearch?, nextValue: () -> PageSearch?) { value = nextValue() ?? value }
}

extension View {
    /// The page's navigation bar title (large by default, like Music's lists).
    func pageTitle(_ text: LocalizedStringResource, large: Bool = true) -> some View {
        preference(key: PageTitleKey.self, value: PageTitle(text: text, large: large))
    }

    /// A dynamic title (a name), shown as is.
    @_disfavoredOverload
    func pageTitle<S: StringProtocol>(_ text: S, large: Bool = true) -> some View {
        preference(key: PageTitleKey.self, value: PageTitle(text: text, large: large))
    }

    /// Bar items; buttons grouped in one view share one Liquid Glass capsule.
    func pageLeadingItem<Item: View>(@ViewBuilder _ item: () -> Item) -> some View {
        pageLeadingItem(isShown: true, item)
    }

    func pageLeadingItem<Item: View>(isShown: Bool, @ViewBuilder _ item: () -> Item) -> some View {
        preference(key: PageLeadingKey.self, value: isShown ? PageBarItem(view: AnyView(item())) : nil)
    }

    func pageTrailingItem<Item: View>(@ViewBuilder _ item: () -> Item) -> some View {
        pageTrailingItem(isShown: true, item)
    }

    /// A trailing item only some states have: hidden, the bar shows nothing
    /// there (an empty view would still get a glass circle).
    func pageTrailingItem<Item: View>(isShown: Bool, @ViewBuilder _ item: () -> Item) -> some View {
        preference(key: PageTrailingKey.self, value: isShown ? PageBarItem(view: AnyView(item())) : nil)
    }

    /// A search field in the navigation bar.
    func pageSearch(text: Binding<String>, prompt: LocalizedStringResource, alwaysVisible: Bool = false) -> some View {
        pageSearch(text: text, prompt: String(localized: prompt), alwaysVisible: alwaysVisible)
    }

    @_disfavoredOverload
    func pageSearch<S: StringProtocol>(text: Binding<String>, prompt: S, alwaysVisible: Bool = false) -> some View {
        preference(key: PageSearchKey.self, value: PageSearch(
            text: text.wrappedValue,
            prompt: String(prompt),
            alwaysVisible: alwaysVisible,
            setText: { text.wrappedValue = $0 }
        ))
    }
}

/// Reads a page's chrome preferences and hands them to its controller.
private struct PageChromeReader: View {
    let content: AnyView
    weak var controller: PageHostingController?

    var body: some View {
        content
            .onPreferenceChange(PageTitleKey.self) { value in
                MainActor.assumeIsolated { controller?.apply(title: value) }
            }
            .onPreferenceChange(PageLeadingKey.self) { value in
                MainActor.assumeIsolated { controller?.apply(leading: value) }
            }
            .onPreferenceChange(PageTrailingKey.self) { value in
                MainActor.assumeIsolated { controller?.apply(trailing: value) }
            }
            .onPreferenceChange(PageSearchKey.self) { value in
                MainActor.assumeIsolated { controller?.apply(search: value) }
            }
    }
}

/// A page of a tab's stack: SwiftUI content with native UIKit chrome.
class PageHostingController: UIHostingController<AnyView>, UISearchResultsUpdating {
    let services: AppServices
    private var leadingHost: UIHostingController<AnyView>?
    private var trailingHost: UIHostingController<AnyView>?
    private var search: PageSearch?

    /// `title` is the page's known title, set before its first frame so the
    /// bar is right from the start of the push; the page can refine it.
    init(content: AnyView, services: AppServices, title: PageTitle) {
        self.services = services
        super.init(rootView: AnyView(EmptyView()))
        rootView = AnyView(PageChromeReader(content: AnyView(content.appEnvironment(services)), controller: self))
        apply(title: title)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        adoptMainScrollView()
    }

    /// UIKit collapses the large title and minimizes the tab bar by watching
    /// the page's scroll view, which it can't find inside SwiftUI's hierarchy:
    /// hand it the page's main (largest vertical) one.
    private func adoptMainScrollView() {
        if let current = contentScrollView(for: .top), current.window != nil { return }
        var best: UIScrollView?
        var queue: [UIView] = [view]
        while !queue.isEmpty {
            let candidate = queue.removeFirst()
            if let scrollView = candidate as? UIScrollView,
               scrollView.bounds.height > view.bounds.height * 0.5,
               scrollView.bounds.width > view.bounds.width * 0.8 {
                best = scrollView
                break
            }
            queue.append(contentsOf: candidate.subviews)
        }
        guard let best else { return }
        setContentScrollView(best, for: .top)
        setContentScrollView(best, for: .bottom)
    }

    @available(*, unavailable)
    @MainActor required dynamic init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    fileprivate func apply(title: PageTitle?) {
        guard let title else { return }
        if navigationItem.title != title.text { navigationItem.title = title.text }
        let mode: UINavigationItem.LargeTitleDisplayMode = title.large ? .always : .never
        if navigationItem.largeTitleDisplayMode != mode { navigationItem.largeTitleDisplayMode = mode }
    }

    fileprivate func apply(leading: PageBarItem?) {
        navigationItem.leftBarButtonItem = barItem(for: leading, host: &leadingHost)
    }

    fileprivate func apply(trailing: PageBarItem?) {
        navigationItem.rightBarButtonItem = barItem(for: trailing, host: &trailingHost)
    }

    /// Hosts the SwiftUI item in a bar button (reusing the item, so an open
    /// menu isn't torn down by an update).
    private func barItem(for item: PageBarItem?, host: inout UIHostingController<AnyView>?) -> UIBarButtonItem? {
        guard let item else {
            host = nil
            return nil
        }
        let view = AnyView(item.view.appEnvironment(services))
        if let host, let existing = [navigationItem.leftBarButtonItem, navigationItem.rightBarButtonItem]
            .compactMap({ $0 }).first(where: { $0.customView === host.view }) {
            host.rootView = view
            host.view.invalidateIntrinsicContentSize()
            return existing
        }
        let newHost = UIHostingController(rootView: view)
        newHost.sizingOptions = [.intrinsicContentSize]
        newHost.view.backgroundColor = .clear
        host = newHost
        return UIBarButtonItem(customView: newHost.view)
    }

    fileprivate func apply(search: PageSearch?) {
        self.search = search
        guard let search else {
            navigationItem.searchController = nil
            return
        }
        let controller: UISearchController
        if let existing = navigationItem.searchController {
            controller = existing
        } else {
            controller = UISearchController(searchResultsController: nil)
            controller.obscuresBackgroundDuringPresentation = false
            controller.searchResultsUpdater = self
            navigationItem.searchController = controller
        }
        controller.searchBar.placeholder = search.prompt
        navigationItem.hidesSearchBarWhenScrolling = !search.alwaysVisible
        // The page changed the text itself (cleared after an unlock code…).
        if controller.searchBar.text ?? "" != search.text {
            controller.searchBar.text = search.text
        }
    }

    func updateSearchResults(for searchController: UISearchController) {
        let text = searchController.searchBar.text ?? ""
        guard let search, search.text != text else { return }
        search.setText(text)
    }
}

// MARK: - Navigation controller

/// A pushed page, remembering its route.
final class RouteHostingController: PageHostingController {
    let route: LibraryRoute

    /// `opener` stacks the page's own links where it is (see `routeOpener`).
    init(route: LibraryRoute, services: AppServices, opener: (@MainActor (LibraryRoute) -> Void)? = nil) {
        self.route = route
        super.init(
            content: AnyView(LibraryDestinationView(route: route).environment(\.routeOpener, opener)),
            services: services,
            title: route.pageTitle(services.libraryVM)
        )
        applyBackChevron()
        if !route.hasColoredPage {
            NotificationCenter.default.addObserver(forName: AppTint.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.applyBackChevron() }
            }
        }
    }

    /// The glass back button ignores the bar's tint, so the chevron is drawn
    /// in its color: the accent, like Music's, or white on album and playlist
    /// pages, which are always dark on their artwork's color (in light mode
    /// the chevron came out black there).
    private func applyBackChevron() {
        let color = route.hasColoredPage ? UIColor.white : AppTint.current.uiColor
        let chevron = UIImage(systemName: "chevron.backward", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold))?
            .withTintColor(color, renderingMode: .alwaysOriginal)
        let appearance = UINavigationBarAppearance()
        appearance.configureWithDefaultBackground()
        appearance.setBackIndicatorImage(chevron, transitionMaskImage: chevron)
        navigationItem.standardAppearance = appearance
        navigationItem.scrollEdgeAppearance = appearance
        navigationItem.compactAppearance = appearance
    }
}

extension LibraryRoute {
    /// Pages drawn dark on their artwork's color.
    var hasColoredPage: Bool {
        switch self {
        case .album, .playlist, .artist, .genre, .allSongs, .lyricsSongs: true
        default: false
        }
    }
}

/// Each tab's stack is a plain UIKit navigation controller, like Music's: its
/// zoom transitions can be interrupted and re-grabbed at any time, and UIKit
/// stays the single source of truth for what's on screen. (SwiftUI's
/// NavigationStack kept its own copy of the path, which went out of sync when
/// a zoom was interrupted: the home screen showed while the closed page still
/// took the touches.)
final class TabNavigationController: UINavigationController, UINavigationControllerDelegate {
    let appTab: AppTab
    private let services: AppServices

    init(tab: AppTab, services: AppServices, root: AnyView) {
        self.appTab = tab
        self.services = services
        let rootTitle = tab.rootRoute?.pageTitle(services.libraryVM) ?? PageTitle(text: tab.title, large: true)
        let rootController = PageHostingController(content: root, services: services, title: rootTitle)
        super.init(rootViewController: rootController)
        navigationBar.prefersLargeTitles = true
        delegate = self
        applyTint()
        NotificationCenter.default.addObserver(forName: AppTint.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyTint() }
        }
    }

    /// UIKit bar items (the back chevron) follow the accent, like Music's.
    private func applyTint() {
        let color = AppTint.current.uiColor
        guard view.window != nil else {
            view.tintColor = color
            navigationBar.tintColor = color
            return
        }
        UIView.transition(with: navigationBar, duration: 0.6, options: [.transitionCrossDissolve, .allowUserInteraction]) {
            self.view.tintColor = color
            self.navigationBar.tintColor = color
        }
    }

    @available(*, unavailable)
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var routes: [LibraryRoute] {
        viewControllers.compactMap { ($0 as? RouteHostingController)?.route }
    }

    func push(_ route: LibraryRoute) {
        // A second tap on the same tile while its page is opening.
        if let top = topViewController as? RouteHostingController, top.route == route, !top.isMovingFromParent {
            return
        }
        pushViewController(makeController(for: route), animated: true)
    }

    func setRoutes(_ routes: [LibraryRoute], animated: Bool) {
        let root = viewControllers.first.map { [$0] } ?? []
        setViewControllers(root + routes.map(makeController), animated: animated)
    }

    func popToRoot() {
        popToRootViewController(animated: true)
    }

    private func makeController(for route: LibraryRoute) -> UIViewController {
        let controller = RouteHostingController(route: route, services: services)
        if let zoomID = route.zoomSourceID {
            let options = UIViewController.Transition.ZoomOptions()
            controller.preferredTransition = .zoom(options: options) { [weak self] _ in
                guard let self else { return nil }
                return ZoomSourceRegistry.shared.view(for: zoomID, in: self.view)
            }
        }
        return controller
    }

    func navigationController(_ navigationController: UINavigationController, didShow viewController: UIViewController, animated: Bool) {
        services.router.didShow(routes, in: appTab)
    }
}

/// Hosts a tab's navigation controller in the SwiftUI tab view.
struct TabNavigationHost<Root: View>: UIViewControllerRepresentable {
    let tab: AppTab
    @ViewBuilder let root: () -> Root
    @Environment(\.appServices) private var services

    func makeUIViewController(context: Context) -> TabRootController {
        let controller = TabNavigationController(tab: tab, services: services, root: AnyView(root()))
        services.router.register(controller, for: tab)
        let pending = services.router.takePendingRoutes(for: tab)
        if !pending.isEmpty { controller.setRoutes(pending, animated: false) }
        // Settings sit to the left of Library, where their button is.
        let services = services
        let panel: (() -> UIViewController)? = tab == .library ? { SettingsPanelController(services: services) } : nil
        return TabRootController(navigation: controller, makePanel: panel, router: services.router)
    }

    func updateUIViewController(_ controller: TabRootController, context: Context) {
        services.router.register(controller.navigation, for: tab)
    }
}

/// A tab's root: its navigation stack, and for Library the Settings panel
/// that lives to its left. Opening slides the whole page off to the right and
/// the panel in after it (only from the Settings button: the page itself
/// has no swipe for it); a swipe to the left on the panel brings the page
/// back. The tab bar and the mini player stay on top, over both.
final class TabRootController: UIViewController, UIGestureRecognizerDelegate {
    let navigation: TabNavigationController
    private let makePanel: (() -> UIViewController)?
    private weak var router: AppRouter?
    private var panel: UIViewController?
    private var animator: UIViewPropertyAnimator?
    private var observation: AnyCancellable?
    /// 0: the page is on screen; 1: the panel is.
    private var progress: CGFloat = 0
    private var panStartProgress: CGFloat = 0
    /// Where the slide is heading.
    private var isOpen = false

    init(navigation: TabNavigationController, makePanel: (() -> UIViewController)?, router: AppRouter) {
        self.navigation = navigation
        self.makePanel = makePanel
        self.router = router
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .settingsBackground
        addChild(navigation)
        navigation.view.frame = view.bounds
        navigation.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(navigation.view)
        navigation.didMove(toParent: self)

        guard makePanel != nil else { return }
        observation = router?.$showSettings
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isOpen in
                guard let self, self.isOpen != isOpen else { return }
                // Closed from another tab: nothing to watch, snap shut.
                self.setPanel(open: isOpen, animated: self.router?.selectedTab == self.navigation.appTab)
            }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // The slide is a translation by the width: a new width (the screen
        // turned, an iPhone Duo folded) needs it again.
        if animator == nil { apply(progress: progress) }
    }

    override func contentScrollView(for edge: NSDirectionalRectEdge) -> UIScrollView? {
        // The open panel's scroll view drives the large title and the tab
        // bar's minimizing, like a page's.
        if progress > 0.5, let panel = panel as? UINavigationController {
            return panel.topViewController?.contentScrollView(for: edge)
        }
        return navigation.contentScrollView(for: edge)
    }

    private func loadPanel() -> UIViewController? {
        if let panel { return panel }
        guard let panel = makePanel?() else { return nil }
        addChild(panel)
        panel.view.frame = view.bounds
        panel.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.insertSubview(panel.view, belowSubview: navigation.view)
        panel.didMove(toParent: self)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.delegate = self
        panel.view.addGestureRecognizer(pan)
        self.panel = panel
        apply(progress: 0)
        return panel
    }

    private func apply(progress: CGFloat) {
        self.progress = progress
        let width = view.bounds.width
        navigation.view.transform = CGAffineTransform(translationX: progress * width, y: 0)
        panel?.view.transform = CGAffineTransform(translationX: (progress - 1) * width, y: 0)
    }

    private func setPanel(open: Bool, velocity: CGFloat = 0, animated: Bool = true) {
        guard open || panel != nil, loadPanel() != nil else { return }
        isOpen = open
        let target: CGFloat = open ? 1 : 0
        guard animated else {
            animator?.stopAnimation(true)
            animator = nil
            apply(progress: target)
            navigation.view.isUserInteractionEnabled = !open
            panel?.view.isUserInteractionEnabled = open
            if !open { (panel as? UINavigationController)?.popToRootViewController(animated: false) }
            setNeedsUpdateOfScrollEdgeElements()
            return
        }
        let current = presentedProgress()
        animator?.stopAnimation(true)
        apply(progress: current)
        navigation.view.isUserInteractionEnabled = !open
        panel?.view.isUserInteractionEnabled = open
        // The finger's speed, relative to the distance left.
        let distance = abs(target - current) * view.bounds.width
        let relative = distance > 1 ? abs(velocity) / distance : 0
        let timing = UISpringTimingParameters(duration: 0.5, bounce: 0, initialVelocity: CGVector(dx: relative, dy: 0))
        let animator = UIViewPropertyAnimator(duration: 0.5, timingParameters: timing)
        animator.addAnimations { self.apply(progress: target) }
        animator.addCompletion { [weak self] position in
            guard let self, position == .end else { return }
            self.animator = nil
            // Settings reopen on their main page.
            if !open { (self.panel as? UINavigationController)?.popToRootViewController(animated: false) }
            self.setNeedsUpdateOfScrollEdgeElements()
        }
        self.animator = animator
        animator.startAnimation()
        setNeedsUpdateOfScrollEdgeElements()
    }

    private func setNeedsUpdateOfScrollEdgeElements() {
        // Hands the tab bar the scroll view now in front.
        setContentScrollView(contentScrollView(for: .bottom), for: .bottom)
    }

    /// Where the slide is on screen, mid-animation included.
    private func presentedProgress() -> CGFloat {
        let width = view.bounds.width
        guard width > 0 else { return progress }
        let x = navigation.view.layer.presentation()?.affineTransform().tx ?? navigation.view.transform.tx
        return min(max(x / width, 0), 1)
    }

    // MARK: Closing swipe

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        // A picker's selection being dragged keeps the finger.
        guard !SettingsSwipe.isControlTracking else { return false }
        // Only a leftward, mostly horizontal swipe, from any page of the
        // panel (a pushed page swipes right to go back to Settings).
        let velocity = pan.velocity(in: view)
        return velocity.x < 0 && abs(velocity.x) > abs(velocity.y)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        // Sliding a switch's knob to the left turns it off, not the panel.
        var view = touch.view
        while let current = view, current !== self.view {
            if current is UISwitch || current is UISlider { return false }
            view = current.superview
        }
        return true
    }

    @objc private func handlePan(_ pan: UIPanGestureRecognizer) {
        let width = max(view.bounds.width, 1)
        switch pan.state {
        case .began:
            let current = presentedProgress()
            animator?.stopAnimation(true)
            animator = nil
            apply(progress: current)
            panStartProgress = current
            // The panel owns the swipe: its scroll view doesn't scroll along,
            // and the row or card under the finger isn't tapped.
            cancelOtherGestures(in: panel?.view, keeping: pan)
            SettingsSwipe.begin()
        case .changed:
            let translation = pan.translation(in: view).x
            apply(progress: min(max(panStartProgress + translation / width, 0), 1))
        case .ended, .cancelled, .failed:
            let velocity = pan.velocity(in: view).x
            let projected = progress + velocity * 0.18 / width
            let close = pan.state == .ended && (projected < 0.6 || velocity < -600)
            SettingsSwipe.end()
            if close {
                setPanel(open: false, velocity: velocity)
                router?.showSettings = false
            } else {
                setPanel(open: true, velocity: velocity)
            }
        default:
            break
        }
    }

    /// Disabling a recognizer for a moment cancels what it was tracking.
    private func cancelOtherGestures(in view: UIView?, keeping pan: UIGestureRecognizer) {
        guard let view else { return }
        for recognizer in view.gestureRecognizers ?? [] where recognizer !== pan && recognizer.isEnabled {
            recognizer.isEnabled = false
            recognizer.isEnabled = true
        }
        for subview in view.subviews { cancelOtherGestures(in: subview, keeping: pan) }
    }
}

/// SwiftUI buttons don't use a gesture recognizer that the closing swipe
/// can cancel: the card or row the finger started on fired when it lifted.
/// They ask this first.
@MainActor
enum SettingsSwipe {
    private static var isActive = false
    private static var endedAt = Date.distantPast
    static let controlTrackingDidChange = Notification.Name("SettingsSwipe.controlTrackingDidChange")

    /// Set while a control follows the finger (a picker's selection being
    /// dragged): neither the panel's close nor a page's swipe back takes it.
    static var isControlTracking = false {
        didSet {
            guard isControlTracking != oldValue else { return }
            NotificationCenter.default.post(name: controlTrackingDidChange, object: nil)
        }
    }

    /// Also false just after a swipe, as the lifted finger's tap arrives.
    static var allowsTaps: Bool {
        !isActive && Date().timeIntervalSince(endedAt) > 0.3
    }

    static func begin() { isActive = true }

    static func end() {
        isActive = false
        endedAt = Date()
    }
}

// MARK: - Bar item content

/// An icon sized like a native bar button, for `pageLeadingItem` /
/// `pageTrailingItem` (the item's Liquid Glass comes from UIKit).
/// A word instead of a symbol, in the same glass capsule.
struct BarText: View {
    let title: LocalizedStringResource

    init(_ title: LocalizedStringResource) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.system(size: 17, weight: .medium))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 12)
            .frame(height: 36)
            .contentShape(Rectangle())
    }
}

struct BarIcon: View {
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
        Image(systemName: systemImage)
            .font(.system(size: 17, weight: .medium))
            .frame(width: 36, height: 36)
            .contentShape(Rectangle())
            .accessibilityLabel(title)
    }
}

extension LibraryRoute {
    /// The bar title a page starts with.
    @MainActor
    func pageTitle(_ libraryVM: LibraryViewModel) -> PageTitle {
        switch self {
        case .playlists: PageTitle(text: "Playlists", large: true)
        case .artists: PageTitle(text: "Artists", large: true)
        case .albums, .artistAlbums: PageTitle(text: "Albums", large: true)
        case .songs: PageTitle(text: "Songs", large: true)
        case .genres: PageTitle(text: "Genres", large: true)
        case .album, .playlist: PageTitle(text: "", large: false)
        case let .artist(name): PageTitle(text: name, large: true)
        case let .genre(name): PageTitle(text: name, large: true)
        case .allSongs, .lyricsSongs: PageTitle(text: "", large: false)
        case .collectionAlbums: PageTitle(text: "Albums", large: true)
        }
    }
}
