import SwiftUI
import UIKit
import Combine
import UniformTypeIdentifiers

// MARK: - Platform

/// The Mac app: Mac Catalyst, with the interface optimized for the Mac.
enum MacApp {
    static let isActive: Bool = {
        #if targetEnvironment(macCatalyst)
        true
        #else
        false
        #endif
    }()

    /// A window this narrow still fits the sidebar beside a page.
    static let minimumWindowSize = CGSize(width: 900, height: 600)
    /// First launch only: the system restores the user's size afterwards.
    static let defaultWindowSize = CGSize(width: 1280, height: 820)
    private static let placedKey = "macWindowSized"

    /// Sets the window's limits, and its size the very first time.
    @MainActor
    static func configure(_ scene: UIWindowScene) {
        guard isActive else { return }
        scene.sizeRestrictions?.minimumSize = minimumWindowSize
        #if targetEnvironment(macCatalyst)
        scene.titlebar?.titleVisibility = .visible
        #endif
        // Pages without a title (an artist, a playlist) and Now Playing show
        // the scene's: an invisible one rather than the app's name.
        scene.title = "\u{200B}"
        MacFullScreenTitlebar.install()
        guard !UserDefaults.standard.bool(forKey: placedKey) else { return }
        UserDefaults.standard.set(true, forKey: placedKey)
        // Once the window is on screen: asked any earlier, the request is
        // dropped.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let screen = scene.screen.bounds
            let size = CGSize(width: min(defaultWindowSize.width, screen.width - 80),
                              height: min(defaultWindowSize.height, screen.height - 80))
            let origin = CGPoint(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2)
            scene.requestGeometryUpdate(.Mac(systemFrame: CGRect(origin: origin, size: size))) { error in
                print("Mac window: \(error.localizedDescription)")
            }
        }
    }
}

extension MacApp {
    /// Black pages in Dark Mode, as on iPhone, instead of the Mac window's
    /// gray. Only the pages: replacing the system background color itself
    /// greyed the sidebar's symbols.
    @MainActor
    static func useBlackBackground() {
        guard isActive else { return }
        let containers: [UIAppearanceContainer.Type] = [TabNavigationController.self]
        UITableView.appearance(whenContainedInInstancesOf: containers).backgroundColor = .pageBackground
        UITableViewCell.appearance(whenContainedInInstancesOf: containers).backgroundColor = .pageBackground
    }
}

/// The Mac's full screen moves the title bar to a window of its own, whose
/// background covered the top of the artwork pages (a playlist, an artist)
/// with a gray band: the pages show through it, as in a window.
enum MacFullScreenTitlebar {
    @MainActor private static var isInstalled = false

    @MainActor
    static func install() {
        guard MacApp.isActive, !isInstalled else { return }
        isInstalled = true
        NotificationCenter.default.addObserver(forName: Notification.Name("NSWindowDidEnterFullScreenNotification"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                clear()
                // The bar's items settle just after.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { clear() }
            }
        }
    }

    /// Hides the background of the full-screen title bar, if there's one.
    @MainActor
    static func clear() {
        guard MacApp.isActive,
              let app = (NSClassFromString("NSApplication") as? NSObject.Type)?.value(forKey: "sharedApplication") as? NSObject,
              let windows = app.value(forKey: "windows") as? [NSObject] else { return }
        for window in windows where NSStringFromClass(type(of: window)) == "NSToolbarFullScreenWindow" {
            guard let content = window.value(forKey: "contentView") as? NSObject else { continue }
            hideBackgrounds(in: content)
        }
    }

    private static func hideBackgrounds(in view: NSObject) {
        if NSStringFromClass(type(of: view)) == "NSTitlebarBackgroundView" {
            if (view.value(forKey: "alphaValue") as? CGFloat ?? 0) != 0 { view.setValue(CGFloat(0), forKey: "alphaValue") }
            return
        }
        for subview in (view.value(forKey: "subviews") as? [NSObject]) ?? [] { hideBackgrounds(in: subview) }
    }
}

extension UIColor {
    /// The pages' background: black in Dark Mode on the Mac too.
    static let pageBackground = UIColor { traits in
        MacApp.isActive && traits.userInterfaceStyle == .dark ? .black : .systemBackground.resolvedColor(with: traits)
    }
}

/// What the Mac's window shows around the pages.
@MainActor
final class MacChrome: ObservableObject {
    static let shared = MacChrome()
    /// Now Playing covers the window. The pages' bar buttons hide meanwhile:
    /// the title bar draws them, above every window, the player's included.
    @Published var isPlayerOpen = false
    /// Full-screen covers on screen (Wrapped, the games): the bar buttons
    /// hide too, they belong to the home page only.
    @Published var coverCount = 0

    private init() {}
}

extension View {
    /// Hides the title bar's buttons on the Mac while this cover is shown.
    func macCoversWindow() -> some View {
        onAppear { if MacApp.isActive { MacChrome.shared.coverCount += 1 } }
            .onDisappear { if MacApp.isActive { MacChrome.shared.coverCount = max(0, MacChrome.shared.coverCount - 1) } }
    }
}

/// Reaches the window scene once the root view is in a window.
struct MacWindowConfigurator: UIViewRepresentable {
    func makeUIView(context: Context) -> Probe { Probe() }
    func updateUIView(_ view: Probe, context: Context) {}

    final class Probe: UIView {
        private var configured = false

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard !configured, let scene = window?.windowScene else { return }
            configured = true
            MacApp.configure(scene)
        }
    }
}

// MARK: - Player bar

/// The Mac's pointer is precise; a finger needs bigger targets and type.
private enum BarMetrics {
    static let isTouch = !MacApp.isActive
    static let button: CGFloat = isTouch ? 36 : 30
    static let playButton: CGFloat = isTouch ? 44 : 38
    static let artwork: CGFloat = isTouch ? 42 : 40
    static let title: CGFloat = isTouch ? 15 : 13
    static let subtitle: CGFloat = isTouch ? 13 : 12
    static let time: CGFloat = isTouch ? 11 : 10
    static let titleStyle = MiniPlayerTitleStyle(titleSize: title, subtitleSize: subtitle, alignment: .center)
}

/// Two fingers swiped up on the trackpad, once per gesture: pushes the bar
/// up into Now Playing, as the card is pulled back down.
private struct TrackpadSwipeUp: UIGestureRecognizerRepresentable {
    let action: () -> Void

    final class Tracker {
        var hasFired = false
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Tracker { Tracker() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.allowedScrollTypesMask = .continuous
        pan.allowedTouchTypes = []
        return pan
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        switch recognizer.state {
        case .began:
            context.coordinator.hasFired = false
        case .changed:
            let translation = recognizer.translation(in: recognizer.view)
            guard !context.coordinator.hasFired, -translation.y > 24, -translation.y > abs(translation.x) * 1.2 else { return }
            context.coordinator.hasFired = true
            action()
        default:
            break
        }
    }
}

/// Music's player bar, on the Mac and on a screen wide enough (an iPad, an
/// unfolded iPhone Duo): a Liquid Glass capsule floating at the bottom of
/// the page, with the controls at the left, the song in the middle and
/// lyrics, queue, AirPlay (and the Mac's volume) at the right. Clicking the
/// song opens Now Playing, which grows out of the bar.
struct MacPlayerBar: View {
    static let height: CGFloat = 58
    static let margin: CGFloat = 12
    /// What the pages leave free at their bottom for it.
    static let reservedHeight: CGFloat = height + margin * 2
    /// The narrowest window that takes it instead of the mini player: room
    /// for the controls, the song and the extras side by side.
    static let minimumWindowWidth: CGFloat = 700
    /// Floating above a bottom tab bar, it stays a bar, not a banner.
    static let maximumWidth: CGFloat = 1000

    /// The copy drawn inside the Now Playing card while it grows out of (or
    /// back into) the bar: no glass, no artwork, no geometry.
    var isReplica = false
    /// In the page on screen: only that copy says where the bar is.
    var isActive = true

    @EnvironmentObject private var playerVM: PlayerViewModel
    @EnvironmentObject private var libraryVM: LibraryViewModel
    @EnvironmentObject private var router: AppRouter
    @ObservedObject private var morph = NowPlayingMorph.shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var showsQueue = false
    @State private var playlistPickerSong: Song?
    @State private var barFrame: CGRect = .zero
    @State private var artworkFrame: CGRect = .zero

    /// The replica sits in a standalone glass, where `.primary` renders
    /// vibrant (grayer): a plain color matches the real bar.
    private var primary: Color {
        guard isReplica else { return .primary }
        return colorScheme == .dark ? .white : .black
    }

    var body: some View {
        HStack(spacing: 0) {
            transport
                .frame(width: 196, alignment: .leading)
            Spacer(minLength: 12)
            nowPlaying
                .frame(maxWidth: 560)
                .layoutPriority(1)
            Spacer(minLength: 12)
            extras
                .frame(width: 196, alignment: .trailing)
        }
        .buttonStyle(MacBarButtonStyle())
        .foregroundStyle(primary)
        .opacity(!isReplica && morph.coversMiniPlayer ? 0 : 1)
        .padding(.horizontal, 12)
        .frame(height: Self.height)
        .frame(maxWidth: .infinity)
        .background {
            if !isReplica {
                Color.clear.glassEffect(.regular, in: Capsule())
            }
        }
        // Under the Now Playing card's own glass while it morphs.
        .opacity(!isReplica && morph.hidesFloatingGlass ? 0.02 : 1)
        // A click anywhere the buttons leave free opens Now Playing.
        .contentShape(Capsule())
        .onTapGesture { if !isReplica { openPlayer() } }
        .gesture(TrackpadSwipeUp(action: openPlayer))
        .simultaneousGesture(
            DragGesture(minimumDistance: 12).onEnded { value in
                // Pushed up with a finger (or the mouse), like the mini player.
                guard value.translation.height < -24,
                      abs(value.translation.height) > abs(value.translation.width) else { return }
                openPlayer()
            }
        )
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            barFrame = frame
            report()
        }
        .onChange(of: isActive) { report() }
        .onChange(of: colorScheme, initial: true) { report() }
        .popover(isPresented: $showsQueue, arrowEdge: .top) {
            PlayerQueueSheet(playerVM: playerVM)
                .frame(width: 380, height: 520)
        }
        .sheet(item: $playlistPickerSong) { song in
            PlayerPlaylistPickerSheet(song: song)
        }
    }

    // MARK: Parts

    private var transport: some View {
        HStack(spacing: 2) {
            Button {
                playerVM.toggleShuffle()
            } label: {
                Image(systemName: "shuffle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(playerVM.shuffleMode == .on ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            }
            .help(playerVM.shuffleMode == .on ? "Shuffle On" : "Shuffle Off")

            Button {
                playerVM.previous()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 17, weight: .semibold))
            }
            .help("Previous")

            Button {
                playerVM.togglePlayPause()
            } label: {
                Image(systemName: playerVM.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(MacBarButtonStyle(size: BarMetrics.playButton))
            .help(playerVM.isPlaying ? "Pause" : "Play")

            Button {
                playerVM.next()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 17, weight: .semibold))
            }
            .help("Next")

            Button {
                playerVM.toggleRepeat()
            } label: {
                Image(systemName: playerVM.repeatMode == .one ? "repeat.1" : "repeat")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(playerVM.repeatMode == .off ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                    .contentTransition(.symbolEffect(.replace))
            }
            .help(repeatHelp)
        }
    }

    private var repeatHelp: LocalizedStringKey {
        switch playerVM.repeatMode {
        case .off: "Repeat Off"
        case .all: "Repeat All"
        case .one: "Repeat One"
        }
    }

    private var nowPlaying: some View {
        HStack(spacing: 10) {
            ArtworkImage(source: playerVM.currentSong?.artworkSource, cornerRadius: 5, points: BarMetrics.artwork)
                .frame(width: BarMetrics.artwork, height: BarMetrics.artwork)
                .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
                .opacity(isReplica ? 0 : 1)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                    artworkFrame = frame
                    report()
                }

            VStack(spacing: 1) {
                // Swiped sideways to the previous or the next song, like the
                // mini player (a finger, or two on the trackpad).
                MiniPlayerTitlePager(
                    currentSong: playerVM.currentSong,
                    previousSong: playerVM.previousSongPreview,
                    nextSong: playerVM.nextSongPreview,
                    showsArtist: true,
                    style: BarMetrics.titleStyle,
                    onTap: openPlayer,
                    onPrevious: { playerVM.previousTrack() },
                    onNext: { playerVM.next() }
                )
                .frame(height: BarMetrics.titleStyle.height)
                .allowsHitTesting(!isReplica)
                MacBarProgress(playerVM: playerVM, isReplica: isReplica)
                    .padding(.top, 3)
            }
            .frame(maxWidth: .infinity)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: openPlayer)
        .contextMenu { contextMenu }
        .accessibilityElement(children: .contain)
        .accessibilityHint("Opens Now Playing")
    }

    private var extras: some View {
        HStack(spacing: 2) {
            Button {
                playerVM.showLyrics = true
                openPlayer()
            } label: {
                Image(systemName: "quote.bubble")
                    .font(.system(size: 14, weight: .medium))
            }
            .help("Lyrics")

            Button {
                showsQueue.toggle()
            } label: {
                Image(systemName: "list.bullet")
                    .font(.system(size: 14, weight: .medium))
            }
            .help("Up Next")

            Group {
                if isReplica {
                    Image(systemName: "airplay.audio")
                        .font(.system(size: 14, weight: .medium))
                } else {
                    AirPlayRoutePicker(tint: .label)
                        .frame(width: 22, height: 22)
                }
            }
            .frame(width: BarMetrics.button, height: BarMetrics.button)
            .help("AirPlay")

            // The system's volume belongs to the iPad's buttons.
            if MacApp.isActive {
                MacVolumeControl(playerService: playerVM.playerService)
            }
        }
        .foregroundStyle(.secondary)
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

    // MARK: Behavior

    private func openPlayer() {
        guard !isReplica, playerVM.currentSong != nil else { return }
        // Clicked while the card is still flying back: grab it.
        if NowPlayingMorph.shared.reopen?() == true { return }
        playerVM.showPlayer = true
    }

    /// Where Now Playing grows from and shrinks back to.
    private func report() {
        guard !isReplica, isActive, barFrame.width > 1 else { return }
        let geometry = MiniPlayerGeometry.shared
        geometry.frame = barFrame
        geometry.artworkFrame = artworkFrame
        geometry.artworkCornerRadius = 5
        geometry.isInline = false
        geometry.colorScheme = colorScheme
    }
}

/// Round, quiet buttons that light up under the pointer, like the Mac's.
private struct MacBarButtonStyle: ButtonStyle {
    var size: CGFloat = BarMetrics.button

    func makeBody(configuration: Configuration) -> some View {
        HoverLabel(configuration: configuration, size: size)
    }

    private struct HoverLabel: View {
        let configuration: ButtonStyleConfiguration
        let size: CGFloat
        @State private var isHovered = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .frame(width: size, height: size)
                .background {
                    Circle()
                        .fill(.primary.opacity(configuration.isPressed ? 0.14 : (isHovered ? 0.07 : 0)))
                }
                .contentShape(Circle())
                .scaleEffect(configuration.isPressed ? 0.92 : 1)
                .opacity(isEnabled ? 1 : 0.4)
                .animation(.smooth(duration: 0.15), value: isHovered)
                .animation(.smooth(duration: 0.12), value: configuration.isPressed)
                .onHover { isHovered = $0 }
        }
    }
}

/// The song's position: a thin bar between the elapsed and remaining
/// times, thicker under the pointer, dragged or clicked to seek.
private struct MacBarProgress: View {
    let playerVM: PlayerViewModel
    let isReplica: Bool
    @StateObject private var clock: MacPlaybackClock
    @State private var scrubTime: TimeInterval?
    @State private var isHovered = false

    init(playerVM: PlayerViewModel, isReplica: Bool) {
        self.playerVM = playerVM
        self.isReplica = isReplica
        _clock = StateObject(wrappedValue: MacPlaybackClock(playerService: playerVM.playerService))
    }

    var body: some View {
        let duration = clock.duration
        let time = min(max(scrubTime ?? clock.currentTime, 0), max(duration, 0))
        let progress = duration > 0 ? time / duration : 0
        let isLarge = isHovered || scrubTime != nil

        HStack(spacing: 8) {
            Text(Self.format(time))
                .frame(width: 38, alignment: .trailing)
            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(.primary.opacity(0.15))
                    Capsule().fill(.primary.opacity(isLarge ? 0.75 : 0.55))
                        .frame(width: max(width * progress, isLarge ? 5 : 3))
                }
                .frame(height: isLarge ? 5 : 3)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard !isReplica, duration > 0, width > 0 else { return }
                            scrubTime = min(max(value.location.x / width, 0), 1) * duration
                        }
                        .onEnded { _ in
                            if let scrubTime { playerVM.seek(to: scrubTime) }
                            scrubTime = nil
                        }
                )
            }
            .frame(height: 10)
            Text("-" + Self.format(max(duration - time, 0)))
                .frame(width: 38, alignment: .leading)
        }
        .font(.system(size: BarMetrics.time, weight: .medium).monospacedDigit())
        .foregroundStyle(.secondary)
        .animation(.smooth(duration: 0.15), value: isLarge)
        .onHover { isHovered = $0 }
        .accessibilityElement()
        .accessibilityLabel("Position")
        .accessibilityValue(Self.format(time))
    }

    private static func format(_ time: TimeInterval) -> String {
        let seconds = Int(max(0, time))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// The player's time, followed on its own: the bar around it doesn't
/// redraw at every tick.
@MainActor
private final class MacPlaybackClock: ObservableObject {
    @Published private(set) var currentTime: TimeInterval
    @Published private(set) var duration: TimeInterval

    init(playerService: MusicPlayerService) {
        currentTime = playerService.currentTime
        duration = playerService.duration
        playerService.$currentTime.removeDuplicates().assign(to: &$currentTime)
        playerService.$duration.removeDuplicates().assign(to: &$duration)
    }
}

/// The app's volume, under the Mac's, like Music's slider: thin, thicker
/// under the pointer, like the position.
private struct MacVolumeControl: View {
    let playerService: MusicPlayerService
    @State private var volume: Double = 1
    @State private var isHovered = false
    @State private var isDragging = false

    var body: some View {
        let isLarge = isHovered || isDragging
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 16)
                .contentTransition(.symbolEffect(.replace))
            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(.primary.opacity(0.15))
                    Capsule().fill(.primary.opacity(isLarge ? 0.75 : 0.55))
                        .frame(width: max(width * volume, isLarge ? 5 : 3))
                }
                .frame(height: isLarge ? 5 : 3)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            isDragging = true
                            set(Double(min(max(value.location.x / max(width, 1), 0), 1)))
                        }
                        .onEnded { _ in isDragging = false }
                )
            }
            .frame(width: 72, height: 16)
        }
        .padding(.leading, 6)
        .animation(.smooth(duration: 0.15), value: isLarge)
        .onHover { isHovered = $0 }
        .onReceive(playerService.$appVolume) { volume = Double($0) }
        .accessibilityElement()
        .accessibilityLabel("Volume")
        .accessibilityValue(Text(volume, format: .percent.precision(.fractionLength(0))))
        .accessibilityAdjustableAction { direction in
            set(volume + (direction == .increment ? 0.1 : -0.1))
        }
    }

    private func set(_ value: Double) {
        volume = min(max(value, 0), 1)
        playerService.setAppVolume(Float(volume))
    }

    private var icon: String {
        switch volume {
        case ..<0.01: "speaker.slash.fill"
        case ..<0.34: "speaker.wave.1.fill"
        case ..<0.67: "speaker.wave.2.fill"
        default: "speaker.wave.3.fill"
        }
    }
}

// MARK: - Menu bar

extension FocusedValues {
    /// The window's router, for the menu bar.
    @Entry var appRouter: AppRouter?
}

/// The menu bar, like Music's: File for playlists and imports, Controls
/// for playback, View to go to each section. Also fills the iPad's menu bar.
struct VibePodCommands: Commands {
    @FocusedValue(\.appRouter) private var router

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…", action: openSettings)
                .keyboardShortcut(",")
                .disabled(router == nil)
        }

        CommandGroup(replacing: .newItem) {
            Button("New Playlist…") { AppModel.shared.libraryVM.requestNewPlaylist() }
                .keyboardShortcut("n")
            Button("New Autolist…") { AppModel.shared.libraryVM.requestNewAutolist() }
                .keyboardShortcut("n", modifiers: [.command, .option])
            Divider()
            Button("Import Files…") { router?.importer = .audio }
                .keyboardShortcut("o")
                .disabled(router == nil)
            Button("Import Music Library") { AppModel.shared.libraryVM.importPhoneMusicLibrary() }
            Button("Import Music Playlists") { AppModel.shared.libraryVM.importPhoneMusicPlaylists() }
            Button("Choose LRC Folder…") { router?.importer = .lyricsFolder }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(router == nil)
        }

        CommandMenu("Controls") {
            PlaybackMenu()
        }

        CommandGroup(before: .sidebar) {
            ForEach(Array(Self.sections.enumerated()), id: \.element) { index, tab in
                Button(tab.title) { go(to: tab) }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))))
                    .disabled(router == nil)
            }
            Button("Search") { go(to: .search) }
                .keyboardShortcut("f")
                .disabled(router == nil)
            Divider()
        }

        // Nothing to format, and no help book.
        CommandGroup(replacing: .textFormatting) {}
        CommandGroup(replacing: .help) {}
    }

    /// In the sidebar's order, numbered from ⌘1.
    private static let sections: [AppTab] = [.library, .playlists, .albums, .assistant, .games, .stats]

    private func go(to tab: AppTab) {
        AppModel.shared.playerVM.showPlayer = false
        router?.selectedTab = tab
    }

    /// Like the sidebar's Settings: their own page.
    private func openSettings() {
        AppModel.shared.playerVM.showPlayer = false
        router?.openSettings()
    }
}

/// The Controls menu. Follows only what it shows: the player publishes at
/// every lyric line, and the menu bar would be rebuilt as often.
private struct PlaybackMenu: View {
    @StateObject private var state = PlaybackMenuState()

    private var playerVM: PlayerViewModel { AppModel.shared.playerVM }

    var body: some View {
        Button(state.isPlaying ? "Pause" : "Play") { playerVM.togglePlayPause() }
            .keyboardShortcut(.space, modifiers: [])
        Button("Next") { playerVM.next() }
            .keyboardShortcut(.rightArrow)
        Button("Previous") { playerVM.previous() }
            .keyboardShortcut(.leftArrow)
        // In Now Playing only: elsewhere the arrows stay the lists'.
        Button("Back 10 Seconds") { playerVM.skip(by: -10) }
            .keyboardShortcut(.leftArrow, modifiers: [])
            .disabled(!state.isPlayerOpen)
        Button("Forward 10 Seconds") { playerVM.skip(by: 10) }
            .keyboardShortcut(.rightArrow, modifiers: [])
            .disabled(!state.isPlayerOpen)
        Button("Previous Line") { playerVM.stepLyricLine(by: -1) }
            .keyboardShortcut(.upArrow, modifiers: [])
            .disabled(!state.showsSyncedLyrics)
        Button("Next Line") { playerVM.stepLyricLine(by: 1) }
            .keyboardShortcut(.downArrow, modifiers: [])
            .disabled(!state.showsSyncedLyrics)
        Divider()
        Toggle("Shuffle", isOn: Binding(
            get: { state.shuffle },
            set: { _ in playerVM.toggleShuffle() }
        ))
        Picker("Repeat", selection: Binding(
            get: { state.repeatMode },
            set: { mode in
                // The player only cycles: off → all → one.
                for _ in 0..<3 where AppModel.shared.playerVM.repeatMode != mode { playerVM.toggleRepeat() }
            }
        )) {
            Text("Off").tag(RepeatMode.off)
            Text("All").tag(RepeatMode.all)
            Text("One").tag(RepeatMode.one)
        }
        Divider()
        Button("Volume Up") { stepVolume(by: 0.1) }
            .keyboardShortcut(.upArrow)
        Button("Volume Down") { stepVolume(by: -0.1) }
            .keyboardShortcut(.downArrow)
        Divider()
        // Now Playing's own window never takes keys: the menu closes it.
        Button("Close Now Playing") { playerVM.dismissPlayer() }
            .keyboardShortcut(.cancelAction)
            .disabled(!state.isPlayerOpen)
        Button("Now Playing") {
            playerVM.showLyrics = false
            playerVM.showPlayer = true
        }
        .keyboardShortcut("p", modifiers: [.command, .shift])
        .disabled(!state.hasSong)
        Button("Lyrics") {
            playerVM.showLyrics = true
            playerVM.showPlayer = true
        }
        .keyboardShortcut("l", modifiers: [.command, .shift])
        .disabled(!state.hasSong)
    }

    private func stepVolume(by step: Float) {
        let service = MusicPlayerService.shared
        service.setAppVolume((service.appVolume + step).rounded(toPlaces: 1))
    }
}

@MainActor
private final class PlaybackMenuState: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var shuffle = false
    @Published private(set) var repeatMode = RepeatMode.off
    @Published private(set) var hasSong = false
    @Published private(set) var isPlayerOpen = false
    @Published private(set) var showsSyncedLyrics = false

    init() {
        let playerVM = AppModel.shared.playerVM
        MacChrome.shared.$isPlayerOpen.removeDuplicates().assign(to: &$isPlayerOpen)
        MacChrome.shared.$isPlayerOpen
            .combineLatest(playerVM.$showLyrics, playerVM.$currentLyrics.map { $0?.hasTimedLyrics == true })
            .map { $0 && $1 && $2 }
            .removeDuplicates()
            .assign(to: &$showsSyncedLyrics)
        playerVM.$isPlaying.removeDuplicates().assign(to: &$isPlaying)
        playerVM.$shuffleMode.map { $0 == .on }.removeDuplicates().assign(to: &$shuffle)
        playerVM.$repeatMode.removeDuplicates().assign(to: &$repeatMode)
        playerVM.$currentSong.map { $0 != nil }.removeDuplicates().assign(to: &$hasSong)
    }
}

private extension Float {
    func rounded(toPlaces places: Int) -> Float {
        let scale = Float(pow(10, Double(places)))
        return (self * scale).rounded() / scale
    }
}

// MARK: - Drag and drop

/// Songs, LRC files and whole folders dropped on the window are imported,
/// like into Music.
struct MacDropImport: ViewModifier {
    @EnvironmentObject private var importService: FileImportService
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            .onDrop(of: [.fileURL, .audio, .folder], isTargeted: $isTargeted) { providers in
                Task { await importDropped(providers) }
                return true
            }
            .overlay {
                if isTargeted {
                    DropHighlight()
                        .transition(.opacity)
                }
            }
            .animation(.smooth(duration: 0.2), value: isTargeted)
    }

    private func importDropped(_ providers: [NSItemProvider]) async {
        var dropped: [DroppedFile] = []
        for provider in providers {
            if let file = await Self.load(provider) { dropped.append(file) }
        }
        guard !dropped.isEmpty else { return }
        // The originals are only readable while their access is open.
        let scoped = dropped.filter { $0.isInPlace && $0.url.startAccessingSecurityScopedResource() }
        defer {
            scoped.forEach { $0.url.stopAccessingSecurityScopedResource() }
            for file in dropped where !file.isInPlace {
                try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent())
            }
        }
        let files = Self.importableFiles(in: dropped.map(\.url))
        guard !files.isEmpty else { return }
        await importService.importFiles(files)
    }

    private struct DroppedFile: Sendable {
        let url: URL
        let isInPlace: Bool
    }

    /// The dropped file where it is, or else a copy (the system deletes its
    /// own as soon as the handler returns).
    private static func load(_ provider: NSItemProvider) async -> DroppedFile? {
        let lrc = UTType(filenameExtension: "lrc")
        guard let type = provider.registeredContentTypes.first(where: {
            $0.conforms(to: .audio) || $0.conforms(to: .folder) || $0 == lrc || $0.conforms(to: .plainText)
        }) else { return nil }
        return await withCheckedContinuation { continuation in
            _ = provider.loadInPlaceFileRepresentation(forTypeIdentifier: type.identifier) { url, isInPlace, _ in
                guard let url else { return continuation.resume(returning: nil) }
                if isInPlace { return continuation.resume(returning: DroppedFile(url: url, isInPlace: true)) }
                let folder = FileManager.default.temporaryDirectory
                    .appendingPathComponent("Dropped", isDirectory: true)
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                let copy = folder.appendingPathComponent(url.lastPathComponent)
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: url, to: copy)
                    continuation.resume(returning: DroppedFile(url: copy, isInPlace: false))
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// Folders are opened, all the way down: their songs and lyrics.
    private nonisolated static func importableFiles(in urls: [URL]) -> [URL] {
        let fileManager = FileManager.default
        func isImportable(_ url: URL) -> Bool {
            let ext = url.pathExtension.lowercased()
            return Song.supportedAudioExtensions.contains(ext) || ext == "lrc"
        }
        var files: [URL] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            guard isDirectory.boolValue else {
                if isImportable(url) || url.pathExtension.lowercased() == "txt" { files.append(url) }
                continue
            }
            let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants])
            while let file = enumerator?.nextObject() as? URL {
                if isImportable(file) { files.append(file) }
            }
        }
        return files
    }
}

/// The window lights up under files dragged over it.
private struct DropHighlight: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.tint, style: StrokeStyle(lineWidth: 3, dash: [10, 7]))
                .background(.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            Label("Drop to Import", systemImage: "square.and.arrow.down")
                .font(.title3.weight(.semibold))
                .padding(.horizontal, 22)
                .padding(.vertical, 14)
                .glassEffect(.regular, in: Capsule())
        }
        .padding(10)
        .allowsHitTesting(false)
    }
}

/// Drops import on the Mac only: on iPhone and iPad, dragging stays the
/// app's own (songs into playlists).
struct MacDropImportIfNeeded: ViewModifier {
    func body(content: Content) -> some View {
        if MacApp.isActive {
            content.modifier(MacDropImport())
        } else {
            content
        }
    }
}


/// The trackpad's haptics, through AppKit's performer: UIKit's feedback
/// generators stay silent while scrolling on the Mac.
@MainActor
enum MacHaptics {
    private typealias Perform = @convention(c) (AnyObject, Selector, Int, UInt) -> Void
    private static let performer: (AnyObject, Selector, Perform)? = {
        guard let manager = NSClassFromString("NSHapticFeedbackManager") as? NSObject.Type else { return nil }
        let getter = NSSelectorFromString("defaultPerformer")
        guard manager.responds(to: getter),
              let performer = manager.perform(getter)?.takeUnretainedValue() as? NSObject else { return nil }
        let selector = NSSelectorFromString("performFeedbackPattern:performanceTime:")
        guard performer.responds(to: selector) else { return nil }
        return (performer, selector, unsafeBitCast(performer.method(for: selector), to: Perform.self))
    }()

    /// A light tap under the fingers (level change, played now).
    @MainActor
    static func tick() {
        guard let (performer, selector, perform) = performer else { return }
        perform(performer, selector, 2, 1)
    }
}
