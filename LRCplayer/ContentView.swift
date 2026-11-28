import SwiftUI
import UniformTypeIdentifiers
import Combine

struct ContentView: View {
    @StateObject private var libraryService: LibraryService
    @StateObject private var libraryVM: LibraryViewModel
    /// Not observed: the player publishes on every lyric line, and each
    /// change would rebuild the whole tab view (sidebar included). The root
    /// follows only what it shows, through `chrome`.
    private let playerVM: PlayerViewModel
    @StateObject private var chrome: PlayerChrome
    @StateObject private var importService: FileImportService
    @StateObject private var router = AppRouter()
    @AppStorage(AppTint.storageKey) private var tintColorRawValue = AppTint.infused.rawValue
    @ObservedObject private var infused = InfusedTint.shared
    @ObservedObject private var cloudSync = CloudSync.shared
    @AppStorage(AppAppearance.storageKey) private var appearanceRawValue = AppAppearance.dark.rawValue

    init() {
        let model = AppModel.shared
        _libraryService = StateObject(wrappedValue: model.libraryService)
        _libraryVM = StateObject(wrappedValue: model.libraryVM)
        playerVM = model.playerVM
        _chrome = StateObject(wrappedValue: PlayerChrome(playerVM: model.playerVM))
        _importService = StateObject(wrappedValue: model.importService)
    }

    private var appTint: AppTint {
        AppTint(rawValue: tintColorRawValue) ?? .infused
    }

    @Environment(\.horizontalSizeClass) private var sizeClass
    @AppStorage(IPadNavigation.storageKey) private var iPadNavigation = IPadNavigation.tabBar.rawValue

    /// The native sidebar, when asked for, on a regular-width screen;
    /// always on the Mac, like Music.
    private var usesSidebar: Bool {
        MacApp.isActive || (sizeClass == .regular && iPadNavigation == IPadNavigation.sidebar.rawValue)
    }

    @State private var windowSize: CGSize = .zero

    /// Music's wide player bar instead of the mini player: on the Mac, and
    /// on a large screen (an iPad, an unfolded iPhone Duo) wide enough for it.
    private var usesWideBar: Bool {
        MacApp.isActive
            || (LargeScreen.contains(windowSize) && windowSize.width >= MacPlayerBar.minimumWindowWidth)
    }

    @State private var tabBarStandsAside = false

    /// Wide screen with the bottom bar: the player floats above it. Beside a
    /// tab bar standing on the side (an iPhone Duo's screens), it floats at
    /// the bottom.
    private var usesFloatingMiniPlayer: Bool {
        !usesSidebar && (sizeClass == .regular || usesWideBar || tabBarStandsAside)
    }

    private var showsFloatingMiniPlayer: Bool {
        usesFloatingMiniPlayer && chrome.hasSong
    }

    /// Beside the sidebar, the wide bar floats at the bottom of every page,
    /// like Music's.
    private var usesPagePlayerBar: Bool {
        usesSidebar && usesWideBar
    }

    private var showsPagePlayerBar: Bool {
        usesPagePlayerBar && chrome.hasSong
    }

    /// What the pages leave free at their bottom for a floating player.
    private var playerRoom: CGFloat {
        if showsPagePlayerBar { return MacPlayerBar.reservedHeight }
        guard showsFloatingMiniPlayer else { return 0 }
        return (usesWideBar ? MacPlayerBar.height : FloatingMiniPlayerState.height) + FloatingMiniPlayerState.spacing
    }

    @ViewBuilder
    private var tabs: some View {
        if usesSidebar {
            sidebarTabs
        } else {
            barTabs
        }
    }

    private var barTabs: some View {
        TabView(selection: router.tabSelection) {
            ForEach(router.visibleTabs) { tab in
                Tab(tab.title, systemImage: tab.systemImage, value: tab, role: tab == .search ? .search : nil) {
                    tabContent(tab)
                }
            }
        }
        // Compact for the tab view only: the tab bar stays at the bottom
        // on iPad, as on iPhone.
        .environment(\.horizontalSizeClass, .compact)
    }

    /// Every section of the library in the sidebar, like Music on iPad;
    /// hidden, the top bar shows Library, each section and Search.
    private var sidebarTabs: some View {
        TabView(selection: router.tabSelection) {
            sidebarTab(.library)
            if MacApp.isActive {
                // A plain tab on the Mac: as the search tab, the system took
                // the field's focus back as soon as it was clicked.
                Tab(AppTab.search.title, systemImage: AppTab.search.systemImage, value: AppTab.search) {
                    tabContent(.search)
                }
            }
            // Not in sections: with the sidebar hidden, a section was a
            // single item of the top bar, opening the last of its pages
            // with no way to pick another.
            ForEach([AppTab.playlists, .albums, .assistant, .games, .stats]) { sidebarTab($0) }
            if !MacApp.isActive {
                Tab(AppTab.search.title, systemImage: AppTab.search.systemImage, value: AppTab.search, role: .search) {
                    tabContent(.search)
                }
            }
            // Reached from the button at the bottom of the sidebar.
            Tab(AppTab.settings.title, systemImage: AppTab.settings.systemImage, value: AppTab.settings) {
                tabContent(.settings)
            }
            .defaultVisibility(.hidden, for: .sidebar)
            .defaultVisibility(.hidden, for: .tabBar)
        }
        .tabViewStyle(.sidebarAdaptable)
        .defaultAdaptableTabBarPlacement(.sidebar)
        .tabViewSidebarBottomBar {
            Button {
                // Their own page; clicked again, back to their first
                // page, like the sidebar's other rows.
                if router.selectedTab == .settings {
                    NotificationCenter.default.post(name: SettingsTabPage.popToRoot, object: nil)
                }
                router.selectedTab = .settings
            } label: {
                Label("Settings", systemImage: "gearshape")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                    .background {
                        // Selected like the sidebar's rows.
                        if router.selectedTab == .settings {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color(uiColor: AppTint.current.uiColor))
                        }
                    }
                    .foregroundStyle(router.selectedTab == .settings ? Color.white : Color.primary)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, MacApp.isActive ? 10 : 0)
            .padding(.bottom, MacApp.isActive ? 6 : 0)
        }
    }

    private func sidebarTab(_ tab: AppTab) -> some TabContent<AppTab> {
        // Every one of them in the top bar too (the sidebar hidden): the
        // tab bar's own choice of tabs is for the bottom bar.
        Tab(tab.title, systemImage: tab.systemImage, value: tab) {
            tabContent(tab)
        }
    }

    var body: some View {
        tabs
        // The floating mini player stays put: the bar doesn't shrink under it.
        .tabBarMinimizeBehavior(usesFloatingMiniPlayer ? .never : .onScrollDown)
        .tabViewBottomAccessory(isEnabled: chrome.hasSong && !usesFloatingMiniPlayer && !usesPagePlayerBar) {
            MiniPlayerView()
        }
        .overlay {
            if showsFloatingMiniPlayer {
                FloatingMiniPlayer()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.smooth(duration: 0.35), value: showsFloatingMiniPlayer)
        .onChange(of: playerRoom, initial: true) { _, room in
            FloatingMiniPlayerState.shared.reservedHeight = room
        }
        .onChange(of: usesWideBar, initial: true) { _, wide in
            FloatingMiniPlayerState.shared.usesWideBar = wide
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { windowSize = $0 }
        .onReceive(FloatingMiniPlayerState.shared.$tabBarStandsAside.removeDuplicates()) { tabBarStandsAside = $0 }
        .background {
            NowPlayingHost(playerVM: playerVM, libraryVM: libraryVM, router: router, importService: importService)
        }
        .libraryFileImporter(isActive: !chrome.showPlayer)
        .modifier(MacDropImportIfNeeded())
        .fullScreenCover(item: $libraryVM.coversSnakeSession) { session in
            CoversSnakeGameView(session: session, playerVM: playerVM) {
                libraryVM.coversSnakeSession = nil
            }
            .portraitLocked()
            .macCoversWindow()
        }
        .fullScreenCover(item: $libraryVM.guessLyricsSession) { session in
            GuessTheNextLyricsGameView(session: session, playerVM: playerVM) {
                libraryVM.guessLyricsSession = nil
            }
            .portraitLocked()
            .macCoversWindow()
        }
        .fullScreenCover(item: $libraryVM.whoSingsSession) { session in
            WhoSingsGameView(session: session, playerVM: playerVM) {
                libraryVM.whoSingsSession = nil
            }
            .portraitLocked()
            .macCoversWindow()
        }
        .fullScreenCover(item: $libraryVM.whatSongSession) { session in
            WhatSongIsThatGameView(session: session, playerVM: playerVM) {
                libraryVM.whatSongSession = nil
            }
            .portraitLocked()
            .macCoversWindow()
        }
        .sheet(item: $router.assistant) { mode in
            AssistantView(mode: mode)
                .environmentObject(libraryVM)
                .environmentObject(playerVM)
                .environmentObject(router)
                .modifier(StoredAppTint())
        }
        .sheet(item: $libraryVM.autolistEditor) { request in
            AutolistEditorView(request: request)
                .environmentObject(libraryVM)
                .environmentObject(router)
        }
        // Shown once the player closes, like the other root presentations.
        .sheet(item: Binding(
            get: { chrome.showPlayer ? nil : libraryVM.playlistEditor },
            set: { libraryVM.playlistEditor = $0 }
        )) { request in
            NavigationStack {
                PlaylistEditorView(request: request)
            }
            .environmentObject(libraryVM)
            .environmentObject(router)
        }
        .sheet(item: Binding(
            get: { chrome.showPlayer ? nil : libraryVM.songEditor },
            set: { libraryVM.songEditor = $0 }
        )) { song in
            SongEditorView(song: song)
                .environmentObject(libraryVM)
        }
        .alert("Import", isPresented: Binding(
            get: { importService.lastError != nil },
            set: { if !$0 { importService.lastError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importService.lastError ?? "")
        }
        .alert("Some Songs Weren't Imported", isPresented: Binding(
            get: { libraryService.importNotice != nil },
            set: { if !$0 { libraryService.importNotice = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(libraryService.importNotice ?? "")
        }
        .overlay(alignment: .top) {
            VStack(spacing: 8) {
                StatusToast(message: libraryService.activityMessage ?? chrome.playbackError, showsProgress: libraryService.activityMessage != nil)
                ResumeBanner(offer: chrome.showPlayer ? nil : cloudSync.resumeOffer) { offer in
                    cloudSync.resume(offer)
                } dismiss: {
                    cloudSync.resumeOffer = nil
                }
            }
        }
        .onOpenURL(perform: handleWidgetURL)
        .onReceive(SiriRouting.shared.$route.compactMap { $0 }) { route in
            SiriRouting.shared.route = nil
            playerVM.showPlayer = false
            router.assistant = nil
            router.openInLibrary(route)
        }
        .onReceive(SiriRouting.shared.$openAssistant.compactMap { $0 }) { mode in
            SiriRouting.shared.openAssistant = nil
            playerVM.showPlayer = false
            router.assistant = mode
        }
        .task { SiriIndex.shared.start() }

        // Folding or unfolding an iPhone Duo moves the app to the other
        // screen, which may turn sideways (or no longer may).
        .onGeometryChange(for: Bool.self) { LargeScreen.contains($0.size) } action: { _ in
            OrientationLock.refresh()
        }
        .onChange(of: chrome.showPlayer, initial: true) { _, isOpen in
            OrientationLock.isPlayerOpen = isOpen
            MacChrome.shared.isPlayerOpen = isOpen
        }
        .onAppear { router.launchGame = launch }
        .onChange(of: usesSidebar, initial: true) { _, uses in
            router.usesSidebar = uses
            // Settings follow the layout: their page beside the sidebar,
            // the panel beside Library with the tab bar.
            if uses, router.showSettings {
                router.showSettings = false
                router.selectedTab = .settings
            } else if !uses, router.selectedTab == .settings {
                router.selectedTab = .library
                DispatchQueue.main.async { router.showSettings = true }
            }
        }
        .background { if MacApp.isActive { MacWindowConfigurator() } }
        .focusedSceneValue(\.appRouter, router)
        // Workouts from Health, for the Workout Autolist and the assistant.
        .task { await WorkoutListening.sync() }
        .environmentObject(libraryVM)
        .environmentObject(playerVM)
        .environmentObject(router)
        .environmentObject(importService)
        .environment(\.appServicesStorage, AppServices(libraryVM: libraryVM, playerVM: playerVM, router: router, importService: importService))
        .tint(appTint == .infused ? infused.color : appTint.color)
        .onChange(of: appearanceRawValue, initial: true) { old, new in AppAppearance.apply(animated: old != new) }
    }

    /// A tab's page, with the real size class back (the tab view itself
    /// reads compact).
    private func tabContent(_ tab: AppTab) -> some View {
        Group {
            if tab == .assistant {
                AssistantView(mode: .text, isTab: true, bottomInset: playerRoom)
            } else if tab == .settings {
                SettingsTabPage()
            } else {
                tabRoot(tab)
            }
        }
        .environment(\.horizontalSizeClass, sizeClass)
        .overlay(alignment: .bottom) {
            if showsPagePlayerBar {
                MacPlayerBar(isActive: router.selectedTab == tab)
                    .padding(.horizontal, MacPlayerBar.margin + 8)
                    .padding(.bottom, MacPlayerBar.margin)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.smooth(duration: 0.35), value: showsPagePlayerBar)
    }

    @ViewBuilder
    private func tabRoot(_ tab: AppTab) -> some View {
        LibraryNavigationStack(tab: tab) {
            switch tab {
            case .library:
                LibraryView()
            case .search:
                SearchView()
            case .games:
                GamesTabView()
            case .stats:
                StatsView()
            default:
                if let route = tab.rootRoute {
                    LibraryDestinationView(route: route)
                }
            }
        }
    }

    /// Starts a game, closing Settings first.
    private func launch(_ game: GameLaunch) {
        let hadSettings = router.showSettings
        router.showSettings = false
        Task {
            if hadSettings { try? await Task.sleep(for: .milliseconds(450)) }
            switch game {
            case let .coversSnake(title, songs):
                libraryVM.presentCoversSnake(title: title, songs: songs)
            case let .guessLyrics(songs):
                libraryVM.presentGuessLyrics(songs: songs)
            case let .whatSong(songs, duration, difficulty):
                libraryVM.presentWhatSong(songs: songs, snippetDuration: duration, difficulty: difficulty)
            case let .whoSings(songs, difficulty):
                libraryVM.presentWhoSings(songs: songs, difficulty: difficulty)
            }
        }
    }

    private func handleWidgetURL(_ url: URL) {
        guard url.scheme?.lowercased() == "lrcplayer" else { return }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        switch url.host?.lowercased() {
        case "widget":
            guard let zone = query.first(where: { $0.name == "zone" })?.value.flatMap(WidgetTapZone.init(rawValue:)) else { return }
            perform(zone.action)
        // Links from widgets rendered before the tap actions became settings.
        case "player":
            perform(query.first(where: { $0.name == "lyrics" })?.value == "1" ? .lyrics : .player)
        case "collection":
            perform(.collection)
        default:
            break
        }
    }

    private func perform(_ action: NowPlayingTapAction) {
        guard let song = playerVM.currentSong else { return }
        switch action {
        case .lyrics, .player:
            playerVM.showLyrics = action == .lyrics && (playerVM.currentLyrics?.hasTimedLyrics == true || playerVM.currentSongHasLRC)
            playerVM.showPlayer = true
        case .collection, .album:
            let route = action == .collection
                ? libraryVM.collectionRoute(for: song, queue: playerVM.queue)
                : libraryVM.album(containing: song).map { LibraryRoute.album($0.id) }
            guard let route else { return }
            playerVM.dismissPlayer()
            router.openInLibrary(route)
        case .app:
            break
        }
    }
}

// MARK: - File importer

private struct LibraryFileImporter: ViewModifier {
    let isActive: Bool
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var libraryVM: LibraryViewModel
    @EnvironmentObject private var importService: FileImportService
    /// The picker's dismissal can clear `router.importer` before the result
    /// arrives: the kind is kept here for it.
    @State private var kind: AppRouter.ImporterKind?

    func body(content: Content) -> some View {
        content
        .onChange(of: router.importer) { _, new in if let new { kind = new } }
        .fileImporter(
            isPresented: Binding(
                get: { isActive && router.importer != nil },
                set: { if !$0 { router.importer = nil } }
            ),
            allowedContentTypes: contentTypes,
            allowsMultipleSelection: router.importer == .audio
        ) { result in
            let kind = router.importer ?? kind
            router.importer = nil
            self.kind = nil
            guard case let .success(urls) = result, !urls.isEmpty else {
                if kind == .lyricsFile { libraryVM.songPendingLRCAssociation = nil }
                return
            }
            switch kind {
            case .audio:
                Task { await importService.importFiles(urls) }
            case .lyricsFolder:
                libraryVM.selectLyricsFolder(urls[0])
            case .lyricsFile:
                libraryVM.associateSelectedLyrics(urls[0])
            case nil:
                break
            }
        }
    }

    private var contentTypes: [UTType] {
        switch router.importer {
        case .audio: FileImportService.importableContentTypes
        case .lyricsFolder: [.folder]
        case .lyricsFile: [UTType(filenameExtension: "lrc") ?? .plainText, .plainText]
        // Never presented without a kind; SwiftUI still warns on an empty list.
        case nil: [.item]
        }
    }
}

extension View {
    /// The app's single document picker (one per presentation context: the
    /// player covers the app, so it has its own).
    func libraryFileImporter(isActive: Bool) -> some View {
        modifier(LibraryFileImporter(isActive: isActive))
    }
}

// MARK: - Status toast

/// Small Liquid Glass capsule for long-running work and playback errors.
struct StatusToast: View {
    let message: String?
    let showsProgress: Bool
    /// The player's: its spinner in the cover's colors, like its menus.
    var tint: Color? = nil

    var body: some View {
        Group {
            if let message {
                HStack(spacing: 10) {
                    if showsProgress {
                        ProgressView()
                            .controlSize(.small)
                            .tint(tint)
                    } else {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                    }
                    Text(message)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .glassEffect(.regular, in: Capsule())
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.35), value: message)
        .allowsHitTesting(false)
    }
}

// MARK: - Resume banner

/// What was playing on another device, offered quietly at the top: the app
/// stays usable, and it goes away on its own.
struct ResumeBanner: View {
    let offer: SyncResumeOffer?
    let resume: (SyncResumeOffer) -> Void
    let dismiss: () -> Void

    var body: some View {
        Group {
            if let offer {
                HStack(spacing: 12) {
                    Image(systemName: Self.symbol(for: offer.deviceName))
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.tint)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Playing on your \(offer.deviceName)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(offer.song.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Button {
                        resume(offer)
                    } label: {
                        Image(systemName: "play.fill")
                            .font(.subheadline.weight(.semibold))
                            .frame(width: 36, height: 36)
                    }
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.circle)
                    .accessibilityLabel("Resume")
                    Button(action: dismiss) {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 28)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close")
                }
                .padding(.leading, 16)
                .padding(.trailing, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: 420)
                .glassEffect(.regular, in: Capsule())
                .padding(.horizontal, 16)
                .transition(.move(edge: .top).combined(with: .opacity))
                .task(id: offer.id) {
                    // Not in the way for long.
                    try? await Task.sleep(for: .seconds(30))
                    if !Task.isCancelled { dismiss() }
                }
            }
        }
        .animation(.snappy(duration: 0.35), value: offer?.id)
        .padding(.top, offer == nil ? 0 : 8)
    }

    private static func symbol(for deviceName: String) -> String {
        switch deviceName {
        case "Mac": "macbook"
        case "iPad": "ipad"
        default: "iphone"
        }
    }
}

/// What the root view shows of the player, published only when it changes.
@MainActor
final class PlayerChrome: ObservableObject {
    @Published private(set) var hasSong = false
    @Published private(set) var showPlayer = false
    @Published private(set) var playbackError: String?

    init(playerVM: PlayerViewModel) {
        hasSong = playerVM.currentSong != nil
        showPlayer = playerVM.showPlayer
        playbackError = playerVM.playbackError
        playerVM.$currentSong.map { $0 != nil }.removeDuplicates().assign(to: &$hasSong)
        playerVM.$showPlayer.removeDuplicates().assign(to: &$showPlayer)
        playerVM.$playbackError.removeDuplicates().assign(to: &$playbackError)
    }
}

/// The Now Playing card, on its own: following the player doesn't rebuild
/// the tab view.
private struct NowPlayingHost: View {
    @ObservedObject var playerVM: PlayerViewModel
    let libraryVM: LibraryViewModel
    let router: AppRouter
    let importService: FileImportService

    var body: some View {
        NowPlayingPresenter(isPresented: $playerVM.showPlayer, artwork: playerVM.currentSong?.artworkSource, showsLyrics: playerVM.showLyrics) {
            PlayerView(playerVM: playerVM, libraryVM: libraryVM, drawsBackground: false)
                .libraryFileImporter(isActive: true)
                .environmentObject(libraryVM)
                .environmentObject(playerVM)
                .environmentObject(router)
                .environmentObject(importService)
                .environment(\.appServicesStorage, AppServices(libraryVM: libraryVM, playerVM: playerVM, router: router, importService: importService))
                .modifier(StoredAppTint())
        } mini: { inline in
            MiniPlayerReplica(inline: inline)
                .environmentObject(libraryVM)
                .environmentObject(playerVM)
                .environmentObject(router)
                .modifier(StoredAppTint())
        }
    }
}

/// The bar drawn inside the Now Playing card while it grows out of (or back
/// into) the one on screen: the wide bar or the mini player.
private struct MiniPlayerReplica: View {
    let inline: Bool
    @ObservedObject private var state = FloatingMiniPlayerState.shared

    var body: some View {
        if state.usesWideBar && !inline {
            MacPlayerBar(isReplica: true)
        } else {
            MiniPlayerView(replicaInline: inline)
        }
    }
}


/// Settings beside the sidebar (the Mac, an iPad): the panel's navigation
/// stack, as a page.
private struct SettingsTabPage: UIViewControllerRepresentable {
    static let popToRoot = Notification.Name("SettingsTabPage.popToRoot")
    @Environment(\.appServices) private var services

    func makeUIViewController(context: Context) -> SettingsPanelController {
        let controller = SettingsPanelController(services: services)
        context.coordinator.observation = NotificationCenter.default.addObserver(forName: Self.popToRoot, object: nil, queue: .main) { [weak controller] _ in
            MainActor.assumeIsolated { _ = controller?.popToRootViewController(animated: true) }
        }
        return controller
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var observation: NSObjectProtocol?
        deinit { observation.map(NotificationCenter.default.removeObserver) }
    }

    func updateUIViewController(_ controller: SettingsPanelController, context: Context) {}
}
