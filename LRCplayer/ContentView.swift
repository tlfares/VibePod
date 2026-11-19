import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var libraryService: LibraryService
    @StateObject private var libraryVM: LibraryViewModel
    @StateObject private var playerVM: PlayerViewModel
    @StateObject private var importService: FileImportService
    @StateObject private var router = AppRouter()
    @AppStorage(AppTint.storageKey) private var tintColorRawValue = AppTint.infused.rawValue
    @ObservedObject private var infused = InfusedTint.shared
    @AppStorage(AppAppearance.storageKey) private var appearanceRawValue = AppAppearance.dark.rawValue

    init() {
        let model = AppModel.shared
        _libraryService = StateObject(wrappedValue: model.libraryService)
        _libraryVM = StateObject(wrappedValue: model.libraryVM)
        _playerVM = StateObject(wrappedValue: model.playerVM)
        _importService = StateObject(wrappedValue: model.importService)
    }

    private var appTint: AppTint {
        AppTint(rawValue: tintColorRawValue) ?? .infused
    }

    @Environment(\.horizontalSizeClass) private var sizeClass

    private var tabs: some View {
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

    var body: some View {
        tabs
        .tabBarMinimizeBehavior(.onScrollDown)
        .tabViewBottomAccessory(isEnabled: playerVM.currentSong != nil) {
            MiniPlayerView()
        }
        .background {
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
                MiniPlayerView(replicaInline: inline)
                    .environmentObject(libraryVM)
                    .environmentObject(playerVM)
                    .environmentObject(router)
                    .modifier(StoredAppTint())
            }
        }
        .libraryFileImporter(isActive: !playerVM.showPlayer)
        .fullScreenCover(item: $libraryVM.coversSnakeSession) { session in
            CoversSnakeGameView(session: session, playerVM: playerVM) {
                libraryVM.coversSnakeSession = nil
            }
            .portraitLocked()
        }
        .fullScreenCover(item: $libraryVM.guessLyricsSession) { session in
            GuessTheNextLyricsGameView(session: session, playerVM: playerVM) {
                libraryVM.guessLyricsSession = nil
            }
            .portraitLocked()
        }
        .fullScreenCover(item: $libraryVM.whoSingsSession) { session in
            WhoSingsGameView(session: session, playerVM: playerVM) {
                libraryVM.whoSingsSession = nil
            }
            .portraitLocked()
        }
        .fullScreenCover(item: $libraryVM.whatSongSession) { session in
            WhatSongIsThatGameView(session: session, playerVM: playerVM) {
                libraryVM.whatSongSession = nil
            }
            .portraitLocked()
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
            get: { playerVM.showPlayer ? nil : libraryVM.playlistEditor },
            set: { libraryVM.playlistEditor = $0 }
        )) { request in
            NavigationStack {
                PlaylistEditorView(request: request)
            }
            .environmentObject(libraryVM)
            .environmentObject(router)
        }
        .sheet(item: Binding(
            get: { playerVM.showPlayer ? nil : libraryVM.songEditor },
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
        .overlay(alignment: .top) {
            StatusToast(message: libraryService.activityMessage ?? playerVM.playbackError, showsProgress: libraryService.activityMessage != nil)
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
        .onChange(of: playerVM.showPlayer, initial: true) { _, isOpen in
            OrientationLock.isPlayerOpen = isOpen
        }
        .onAppear { router.launchGame = launch }
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
                AssistantView(mode: .text, isTab: true)
            } else {
                tabRoot(tab)
            }
        }
        .environment(\.horizontalSizeClass, sizeClass)
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
