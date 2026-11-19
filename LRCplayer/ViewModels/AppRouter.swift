import SwiftUI

enum AppTab: String, CaseIterable, Identifiable, Hashable {
    case library
    case playlists
    case artists
    case albums
    case songs
    case genres
    case assistant
    case games
    case stats
    case search

    var id: String { rawValue }

    /// Tabs the user can add next to Library in Settings. Artists and
    /// Genres live in Search instead.
    static let optional: [AppTab] = [.playlists, .albums, .songs, .assistant, .games, .stats]
    /// Library + 3 + Search: the most an iPhone tab bar shows without "More".
    static let maxOptionalTabs = 3

    var title: String {
        switch self {
        case .library: String(localized: "Library")
        case .playlists: String(localized: "Playlists")
        case .artists: String(localized: "Artists")
        case .albums: String(localized: "Albums")
        case .songs: String(localized: "Songs")
        case .genres: String(localized: "Genres")
        case .assistant: String(localized: "Assistant")
        case .games: String(localized: "Games")
        case .stats: String(localized: "Stats")
        case .search: String(localized: "Search")
        }
    }

    var systemImage: String {
        switch self {
        case .library: "music.note.square.stack.fill"
        case .playlists: "music.note.list"
        case .artists: "music.microphone"
        case .albums: "square.stack.fill"
        case .songs: "music.note"
        case .genres: "guitars.fill"
        case .assistant: "sparkles"
        case .games: "arcade.stick"
        case .stats: "chart.bar.xaxis"
        case .search: "magnifyingglass"
        }
    }

    var rootRoute: LibraryRoute? {
        switch self {
        case .playlists: .playlists
        case .artists: .artists
        case .albums: .albums
        case .songs: .songs
        case .genres: .genres
        case .library, .assistant, .games, .stats, .search: nil
        }
    }
}

enum LibraryRoute: Hashable {
    case playlists
    case artists
    case albums
    case songs
    case genres
    /// `zoomSource` names the tile the page zooms out of, when there is one.
    case album(AlbumID, zoomSource: String? = nil)
    case artist(String)
    /// All of an artist's albums, laid out like the Albums page.
    case artistAlbums(String)
    case playlist(UUID, zoomSource: String? = nil)
    case genre(String)
    /// Every song, laid out like a genre page.
    case allSongs
    /// The songs whose lyrics are of this kind; nil for those without any.
    case lyricsSongs(LyricsSyncKind?)
    /// The albums of a genre, of all songs or of a lyrics list.
    case collectionAlbums(SongCollection)

    var zoomSourceID: String? {
        switch self {
        case let .album(_, zoomSource), let .playlist(_, zoomSource): zoomSource
        default: nil
        }
    }
}

@MainActor
final class AppRouter: ObservableObject {
    private static let tabsKey = "enabledOptionalTabs"

    @Published var selectedTab: AppTab = .library
    @Published var paths: [AppTab: [LibraryRoute]] = [:]
    @Published private(set) var optionalTabs: [AppTab]

    @Published var showSettings = false
    /// The assistant's sheet, in the mode it opens in.
    @Published var assistant: AssistantMode?

    /// Slides Settings in, on one of its pages if given.
    func openSettings(at destination: SettingsDestination? = nil) {
        settingsDestination = destination
        showSettings = true
    }
    /// Starts a game from Settings (set by the root view, which owns the
    /// full-screen game covers).
    var launchGame: ((GameLaunch) -> Void)?
    /// A Settings page to push before the panel slides in.
    @Published var settingsDestination: SettingsDestination?
    /// Which file picker the root `fileImporter` shows.
    @Published var importer: ImporterKind?

    enum ImporterKind: Identifiable {
        case audio
        case lyricsFolder
        case lyricsFile
        var id: Self { self }
    }

    init() {
        Self.applyLayoutDefaults()
        optionalTabs = Self.stored(Self.tabsKey, default: [.playlists, .albums], allowed: AppTab.optional)
    }

    private static let layoutDefaultsKey = "layoutDefaultsV2Applied"

    /// Puts everyone on the new layout once, on update: Playlists and Albums
    /// tabs.
    /// Any change made after that sticks.
    private static func applyLayoutDefaults() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: layoutDefaultsKey) else { return }
        defaults.set(true, forKey: layoutDefaultsKey)
        defaults.set([AppTab.playlists, .albums].map(\.rawValue).joined(separator: ","), forKey: tabsKey)
    }

    private static func stored(_ key: String, default defaultTabs: [AppTab], allowed: [AppTab]) -> [AppTab] {
        guard let stored = UserDefaults.standard.string(forKey: key) else { return defaultTabs }
        return stored
            .split(separator: ",")
            .compactMap { AppTab(rawValue: String($0)) }
            .filter(allowed.contains)
    }

    var visibleTabs: [AppTab] {
        [.library] + optionalTabs + [.search]
    }

    /// The tabs between Library and Search, in their order.
    func setOptionalTabs(_ tabs: [AppTab]) {
        let tabs = Array(tabs.filter(AppTab.optional.contains).prefix(AppTab.maxOptionalTabs))
        for removed in optionalTabs where !tabs.contains(removed) {
            if selectedTab == removed { selectedTab = .library }
            paths[removed] = nil
        }
        optionalTabs = tabs
        UserDefaults.standard.set(optionalTabs.map(\.rawValue).joined(separator: ","), forKey: Self.tabsKey)
    }

    // MARK: Navigation
    //
    // Each tab's UINavigationController is the source of truth; `paths` only
    // mirrors it.

    private final class WeakNavigator {
        weak var controller: TabNavigationController?
        init(_ controller: TabNavigationController) { self.controller = controller }
    }

    private var navigators: [AppTab: WeakNavigator] = [:]

    func register(_ navigator: TabNavigationController, for tab: AppTab) {
        guard navigators[tab]?.controller !== navigator else { return }
        navigators[tab] = WeakNavigator(navigator)
    }

    func didShow(_ routes: [LibraryRoute], in tab: AppTab) {
        if paths[tab] ?? [] != routes { paths[tab] = routes }
    }

    /// Pushes a page on the current tab (search pushes stay in search).
    func open(_ route: LibraryRoute) {
        if let navigator = navigators[selectedTab]?.controller {
            navigator.push(route)
        } else {
            paths[selectedTab, default: []].append(route)
        }
    }

    /// Pops the current tab's top page.
    func pop() {
        navigators[selectedTab]?.controller?.popViewController(animated: true)
    }

    /// Like `open`, but jumps to the Library tab first (widget deep links).
    func openInLibrary(_ route: LibraryRoute) {
        selectedTab = .library
        // The page opens on Library, which Settings would hide.
        showSettings = false
        if let navigator = navigators[.library]?.controller {
            navigator.setRoutes([route], animated: false)
        } else {
            paths[.library] = [route]
        }
    }

    /// The tab bar's selection; tapping the current tab again pops it to its
    /// root, like every Apple app.
    var tabSelection: Binding<AppTab> {
        Binding(
            get: { self.selectedTab },
            set: { tab in
                if tab == self.selectedTab, tab == .library, self.showSettings {
                    // Library's tab brings Library back from Settings.
                    self.showSettings = false
                } else if tab == self.selectedTab {
                    self.navigators[tab]?.controller?.popToRoot()
                } else {
                    let leftOpenSettings = self.selectedTab == .library && self.showSettings
                    self.selectedTab = tab
                    // Settings don't wait behind another tab: Library comes
                    // back on its home.
                    if leftOpenSettings { self.showSettings = false }
                }
            }
        )
    }

    /// Routes queued before a tab's navigation controller existed.
    func takePendingRoutes(for tab: AppTab) -> [LibraryRoute] {
        paths[tab] ?? []
    }
}
