import Combine
import SwiftUI
import MediaAccessibility
import UIKit

/// The Settings panel, to the left of Library (see `TabRootController`): its
/// own navigation stack, for Stats, Games and the Spotify import.
final class SettingsPanelController: UINavigationController {
    private let services: AppServices

    init(services: AppServices) {
        self.services = services
        let opener = Opener()
        let page = PageHostingController(
            content: AnyView(SettingsView { opener.open?($0) }),
            services: services,
            title: PageTitle(text: "Settings", large: true)
        )
        page.view.backgroundColor = .settingsBackground
        super.init(rootViewController: page)
        opener.open = { [weak self] in self?.open($0) }
        navigationBar.prefersLargeTitles = true
        view.backgroundColor = .settingsBackground
        view.tintColor = AppTint.current.uiColor
        // A page asked for from elsewhere (the home Games button): already
        // pushed when the panel slides in.
        destinationObservation = services.router.$settingsDestination
            .compactMap { $0 }
            .sink { [weak self] destination in
                guard let self else { return }
                self.popToRootViewController(animated: false)
                self.open(destination, animated: false)
                self.services.router.settingsDestination = nil
            }
    }

    private var destinationObservation: AnyCancellable?

    /// Lets the page call back into its controller, which only exists once
    /// the page does.
    private final class Opener {
        var open: ((SettingsDestination) -> Void)?
    }

    @available(*, unavailable)
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        NotificationCenter.default.addObserver(forName: AppTint.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let color = AppTint.current.uiColor
                UIView.transition(with: self.navigationBar, duration: 0.6, options: [.transitionCrossDissolve, .allowUserInteraction]) {
                    self.view.tintColor = color
                }
                self.applyPageTint(animated: true)
            }
        }
        // A picker's selection dragged right isn't a swipe back (which iOS
        // lets start anywhere on the page).
        NotificationCenter.default.addObserver(forName: SettingsSwipe.controlTrackingDidChange, object: nil, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let enabled = !SettingsSwipe.isControlTracking
                self.interactiveContentPopGestureRecognizer?.isEnabled = enabled
                self.interactivePopGestureRecognizer?.isEnabled = enabled
            }
        }
    }

    /// Infused accent: a settings page's bar takes its tile's color.
    private func applyPageTint(animated: Bool) {
        let color = (AppTint.current == .infused ? topViewController?.settingsTileColor : nil) ?? AppTint.current.uiColor
        guard navigationBar.tintColor != color else { return }
        guard animated, view.window != nil else {
            navigationBar.tintColor = color
            return
        }
        UIView.transition(with: navigationBar, duration: 0.35, options: [.transitionCrossDissolve, .allowUserInteraction]) {
            self.navigationBar.tintColor = color
        }
    }

    override func pushViewController(_ viewController: UIViewController, animated: Bool) {
        super.pushViewController(viewController, animated: animated)
        applyPageTint(animated: animated)
    }

    override func popViewController(animated: Bool) -> UIViewController? {
        let popped = super.popViewController(animated: animated)
        applyPageTint(animated: animated)
        // A swipe back given up: the page stays, and so does its color.
        transitionCoordinator?.animate(alongsideTransition: nil) { [weak self] _ in
            self?.applyPageTint(animated: false)
        }
        return popped
    }

    override func popToRootViewController(animated: Bool) -> [UIViewController]? {
        let popped = super.popToRootViewController(animated: animated)
        applyPageTint(animated: animated)
        return popped
    }

    /// Library pages opened from a settings page stack here, above it.
    private func openRoute(_ route: LibraryRoute) {
        let controller = RouteHostingController(route: route, services: services) { [weak self] in self?.openRoute($0) }
        pushViewController(controller, animated: true)
    }

    private func open(_ destination: SettingsDestination, animated: Bool = true) {
        let songs = services.libraryVM.songs
        let controller: UIViewController
        switch destination {
        case .stats:
            let page = PageHostingController(
                content: AnyView(StatsView().tint(Color.statsTint).environment(\.routeOpener) { [weak self] in self?.openRoute($0) }),
                services: services,
                title: PageTitle(text: "Stats", large: true)
            )
            page.view.backgroundColor = .settingsBackground
            controller = page
        case .games:
            let router = services.router
            controller = LibraryGamesViewController(songs: songs) { game in
                router.launchGame?(game)
            }
        case .exclusive:
            let page = PageHostingController(
                content: AnyView(ExclusiveFeaturesView().settingsPageTint(.extrasTint)),
                services: services,
                title: PageTitle(text: "Exclusive Features", large: true)
            )
            page.view.backgroundColor = .settingsBackground
            controller = page
        case .spotify:
            controller = SpotifyImportViewController(libraryService: services.libraryVM.libraryService)
        case .ai:
            let page = PageHostingController(
                content: AnyView(AIFeaturesView().tint(Color.aiTint)),
                services: services,
                title: PageTitle(text: "AI Features", large: false)
            )
            page.view.backgroundColor = .settingsBackground
            controller = page
        case .transfer:
            let page = PageHostingController(
                content: AnyView(LibraryTransferView()),
                services: services,
                title: PageTitle(text: "Library Transfer", large: false)
            )
            page.view.backgroundColor = .settingsBackground
            controller = page
        case .equalizer:
            let page = PageHostingController(
                content: AnyView(EqualizerView()),
                services: services,
                title: PageTitle(text: "Equalizer", large: false)
            )
            page.view.backgroundColor = .settingsBackground
            controller = page
        case .merge:
            let page = PageHostingController(
                content: AnyView(SongMergeView()),
                services: services,
                title: PageTitle(text: "Merge Songs", large: false)
            )
            page.view.backgroundColor = .settingsBackground
            controller = page
        case .metadata:
            let page = PageHostingController(
                content: AnyView(MetadataFetchView()),
                services: services,
                title: PageTitle(text: "Missing Metadata", large: false)
            )
            page.view.backgroundColor = .settingsBackground
            controller = page
        }
        if let tile = destination.tileColor {
            controller.settingsTileColor = UIColor(tile)
            if AppTint.current == .infused { controller.view.tintColor = UIColor(tile) }
        }
        pushViewController(controller, animated: animated)
    }
}

/// A settings page's tile color, for its bar when the accent is Infused.
private nonisolated(unsafe) var settingsTileColorKey = 0

extension UIViewController {
    var settingsTileColor: UIColor? {
        get { objc_getAssociatedObject(self, &settingsTileColorKey) as? UIColor }
        set { objc_setAssociatedObject(self, &settingsTileColorKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }
}

extension UIColor {
    /// Black, as in XMGo; in light mode, the grouped gray, on which the glass
    /// cards still read (they barely did on white).
    static let settingsBackground = UIColor { traits in
        traits.userInterfaceStyle == .dark ? .black : .systemGroupedBackground
    }
}

enum SettingsDestination {
    case stats, games, exclusive, spotify, ai, transfer, metadata, equalizer, merge

    /// The tile the page opens from, when it has one.
    var tileColor: Color? {
        switch self {
        case .stats: .statsTint
        case .games: .gamesTint
        case .exclusive: .extrasTint
        case .ai: .aiTint
        default: nil
        }
    }
}

/// Settings as XMGo shows them: folding Liquid Glass cards on black.
struct SettingsView: View {
    let open: (SettingsDestination) -> Void

    @EnvironmentObject private var router: AppRouter
    @AppStorage(AppTint.storageKey) private var tintRawValue = AppTint.infused.rawValue
    @AppStorage(AppAppearance.storageKey) private var appearanceRawValue = AppAppearance.dark.rawValue
    @AppStorage("playlistsAlwaysOnTop") private var playlistsOnTop = false
    @AppStorage("showRecentlyPlayedSection") private var showRecentlyPlayed = true
    @AppStorage(HomeSuggestions.rowsKey) private var suggestionRows = HomeSuggestions.defaultRows
    @AppStorage(HomeSuggestions.playlistsKey) private var suggestsPlaylists = true
    @AppStorage(HomeSuggestions.albumsKey) private var suggestsAlbums = true
    @AppStorage(HomeSuggestions.artistsKey) private var suggestsArtists = true
    @AppStorage(HomeSuggestions.hiddenKey) private var hiddenSuggestions = ""
    @AppStorage(HomeShortcut.leadingKey) private var leadingShortcut = HomeShortcut.leadingDefault
    @AppStorage(HomeShortcut.trailingKey) private var trailingShortcut = HomeShortcut.trailingDefault
    @AppStorage(HomeShortcut.leading2Key) private var leadingShortcut2 = HomeShortcut.none
    @AppStorage(HomeShortcut.leading3Key) private var leadingShortcut3 = HomeShortcut.none
    @AppStorage(NowPlayingArtworkStyle.storageKey) private var fullScreenArtwork = false
    @AppStorage(OrientationLock.playerRotationKey) private var playerRotates = true
    @AppStorage(NowPlayingLyricPreview.storageKey) private var showsLyricPreview = true
    @AppStorage(PrivateListening.key) private var privateListening = false
    @AppStorage(VolumeLeveling.enabledKey) private var volumeLeveling = false
    @AppStorage(VolumeLeveling.maxBoostKey) private var maxBoost = 6.0
    @State private var appearanceOpen = false
    @State private var equalizerSummary = EQPreset.summary
    @State private var nowPlayingOpen = false
    @State private var homeOpen = false
    @State private var widgetOpen = false
    @State private var toolsOpen = false
    @State private var hiddenOpen = false
    @State private var hiddenUnlocked = HiddenSettings.isUnlocked
    @State private var hideArtwork = HiddenSettings.hideNowPlayingArtwork
    @State private var alphaFeatures = UserDefaults.standard.bool(forKey: HiddenSettings.alphaFeaturesKey)

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                HStack(spacing: 16) {
                    FeatureTile(title: "Stats", systemImage: "chart.bar.xaxis", color: .statsTint) { open(.stats) }
                    FeatureTile(title: "Games", systemImage: "arcade.stick", color: .gamesTint) { open(.games) }
                }
                HStack(spacing: 16) {
                    FeatureTile(title: "Exclusive Features", systemImage: "star.fill", color: .extrasTint) { open(.exclusive) }
                    FeatureTile(title: "AI Features", systemImage: "sparkles", color: .aiTint, isBeta: true) { open(.ai) }
                }
                CollapsibleGlassCard(title: "Appearance", systemImage: "paintpalette.fill", expanded: $appearanceOpen) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Mode").font(.subheadline).foregroundStyle(.secondary)
                        GlassSegmentedPicker(
                            "Appearance",
                            options: AppAppearance.allCases,
                            selection: Binding(
                                get: { AppAppearance(rawValue: appearanceRawValue) ?? .dark },
                                set: { appearanceRawValue = $0.rawValue }
                            ),
                            title: \.title,
                            symbol: \.symbol,
                            commitsWhenSettled: true
                        )
                        Divider().padding(.vertical, 4)
                        Text("Accent color").font(.subheadline).foregroundStyle(.secondary)
                        HStack(spacing: 0) {
                            ForEach(AppTint.allCases) { tint in
                                tintSwatch(tint).frame(maxWidth: .infinity)
                            }
                        }
                        if tintRawValue == AppTint.infused.rawValue {
                            Text("Accent color infused by the playing song's artwork.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                                .transition(.opacity)
                        }
                    }
                }
                CollapsibleGlassCard(title: "Playback", systemImage: "play.circle.fill", expanded: $nowPlayingOpen) {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Volume Leveling", isOn: $volumeLeveling)
                            .onChange(of: volumeLeveling) { _, on in
                                if on, let song = MusicPlayerService.shared.currentSong { VolumeLeveling.measureIfNeeded(song) }
                                MusicPlayerService.shared.refreshVolumeLeveling()
                            }
                        if volumeLeveling {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("Maximum Boost")
                                    Spacer()
                                    Text("+\(Int(maxBoost)) dB").foregroundStyle(.secondary).monospacedDigit()
                                }
                                Slider(value: $maxBoost, in: VolumeLeveling.boostRange, step: 1) { editing in
                                    if !editing { MusicPlayerService.shared.refreshVolumeLeveling() }
                                }
                                Text("How much a quiet song can be raised. Higher keeps quiet songs closer to loud ones, but lowers the overall volume.")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                            .transition(.opacity)
                        }
                        Divider()
                        Button { open(.equalizer) } label: {
                            HStack {
                                Text("Equalizer").foregroundStyle(.primary)
                                Spacer()
                                Text(equalizerSummary).foregroundStyle(.secondary)
                                Image(systemName: "chevron.right")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .onReceive(NotificationCenter.default.publisher(for: Equalizer.didChange)) { _ in
                            equalizerSummary = EQPreset.summary
                        }
                        Divider()
                        Toggle("Private Listening", isOn: $privateListening)
                        Text("What you play isn't counted in Stats or play counts.")
                            .font(.footnote).foregroundStyle(.secondary)
                        Divider()
                        Toggle("Lyrics Preview", isOn: $showsLyricPreview)
                        if UIDevice.current.userInterfaceIdiom == .phone {
                            Divider()
                            Toggle("Rotate with iPhone", isOn: $playerRotates)
                                .onChange(of: playerRotates) { OrientationLock.refresh() }
                        }
                    }
                }
                CollapsibleGlassCard(title: "Home", systemImage: "house.fill", expanded: $homeOpen) {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Playlists First", isOn: $playlistsOnTop)
                        Toggle("Recently Played", isOn: $showRecentlyPlayed)
                        Divider().padding(.vertical, 4)
                        Text("Suggestions").font(.subheadline).foregroundStyle(.secondary)
                        Toggle("Playlists", isOn: $suggestsPlaylists)
                        Toggle("Albums", isOn: $suggestsAlbums)
                        Toggle("Artists", isOn: $suggestsArtists)
                        Stepper(value: $suggestionRows, in: HomeSuggestions.rowRange) {
                            HStack {
                                Text("Rows")
                                Spacer()
                                Text("\(suggestionRows)").foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                        let hiddenCount = HomeSuggestions.hiddenIDs(hiddenSuggestions).count
                        if hiddenCount > 0 {
                            Button("Recommend \(hiddenCount) Hidden Again") {
                                guard SettingsSwipe.allowsTaps else { return }
                                withAnimation(.smooth) { HomeSuggestions.showHidden() }
                            }
                            .transition(.opacity)
                        }
                        Text("Touch and hold a suggestion on Home to stop recommending it.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Divider().padding(.vertical, 4)
                        Text("Toolbar Shortcuts").font(.subheadline).foregroundStyle(.secondary)
                        ShortcutEditor(leading: $leadingShortcut, leading2: $leadingShortcut2, leading3: $leadingShortcut3, trailing: $trailingShortcut)
                        Text("Touch and hold a shortcut, then drag it into a slot, between them or out of the bar. AutoMix and Music Haptics switch on and off right from the toolbar.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Divider().padding(.vertical, 4)
                        Text("Tab Bar").font(.subheadline).foregroundStyle(.secondary)
                        TabBarEditor()
                        Text("Touch and hold a tab, then drag it into the bar, around or out of it. Library and Search keep their ends.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                CollapsibleGlassCard(title: "Widget", systemImage: "widget.small", expanded: $widgetOpen) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("What a tap on the Now Playing widget opens").font(.subheadline).foregroundStyle(.secondary)
                        ForEach(WidgetTapZone.allCases) { zone in
                            WidgetTapActionRow(zone: zone)
                        }
                        Text("Lyrics opens the player when the song has none. Playlist or Album opens the playlist playing, or else the song's album.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                CollapsibleGlassCard(title: "Tools", systemImage: "wrench.and.screwdriver.fill", expanded: $toolsOpen) {
                    VStack(alignment: .leading, spacing: 14) {
                        toolRow("Import from Spotify", systemImage: "square.and.arrow.down", destination: .spotify)
                        Divider()
                        toolRow("Library Transfer", systemImage: "arrow.up.arrow.down", destination: .transfer)
                        Divider()
                        toolRow("Merge Songs", systemImage: "arrow.triangle.merge", destination: .merge)
                        Divider()
                        toolRow("Missing Metadata", systemImage: "photo.badge.arrow.down", isBeta: true, destination: .metadata)
                    }
                }
                if hiddenUnlocked {
                    CollapsibleGlassCard(title: "Hidden Settings", systemImage: "eye.slash.fill", expanded: $hiddenOpen) {
                        VStack(alignment: .leading, spacing: 12) {
                            Toggle("Hide Artwork on Lock Screen", isOn: $hideArtwork)
                                .onChange(of: hideArtwork) { _, value in HiddenSettings.hideNowPlayingArtwork = value }
                            Divider()
                            Toggle(isOn: $fullScreenArtwork) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Full-Screen Artwork")
                                    Text("In the player. Still buggy.")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Divider()
                            Toggle(isOn: $alphaFeatures) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Alpha Features")
                                    Text("Song Voice and Tiles Play the Beats. Not stable yet.")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .onChange(of: alphaFeatures) { _, value in HiddenSettings.alphaFeatures = value }
                            Divider()
                            Button("Disable Hidden Settings", role: .destructive) {
                                guard SettingsSwipe.allowsTaps else { return }
                                HiddenSettings.isUnlocked = false
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.red)
                        }
                    }
                }

                Text(Self.versionText)
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 12)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .background(Color(uiColor: .settingsBackground).ignoresSafeArea())
        .pageLeadingItem {
            // For whoever doesn't think of swiping back.
            Button {
                router.showSettings = false
            } label: {
                BarIcon("Close Settings", systemImage: "chevron.backward")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
        }
        .onReceive(NotificationCenter.default.publisher(for: HiddenSettings.didChangeNotification)) { _ in
            withAnimation(.smooth) { hiddenUnlocked = HiddenSettings.isUnlocked }
            hideArtwork = HiddenSettings.hideNowPlayingArtwork
        }
    }

    /// "VibePod 1.2 (34)", from the bundle.
    private static let versionText: String = {
        let info = Bundle.main.infoDictionary ?? [:]
        let name = info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? "VibePod"
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String
        return build.map { "\(name) \(version) (\($0))" } ?? "\(name) \(version)"
    }()

    private func tintSwatch(_ tint: AppTint) -> some View {
        let isSelected = tintRawValue == tint.rawValue
        return Button {
            guard SettingsSwipe.allowsTaps else { return }
            withAnimation(.smooth) { tintRawValue = tint.rawValue }
            NotificationCenter.default.post(name: AppTint.didChangeNotification, object: tint)
        } label: {
            Circle()
                .fill(tint == .infused
                      ? AnyShapeStyle(AngularGradient(colors: AppTint.allCases.filter { $0 != .infused && $0 != .gray }.map(\.swatchColor) + [AppTint.red.swatchColor], center: .center))
                      : AnyShapeStyle(tint.swatchColor))
                .frame(width: 36, height: 36)
                .overlay {
                    if isSelected {
                        Image(systemName: "checkmark").font(.subheadline.weight(.bold)).foregroundStyle(.black)
                    }
                }
                .overlay {
                    Circle().stroke(Color.primary.opacity(isSelected ? 0.9 : 0.28), lineWidth: isSelected ? 2 : 1)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tint.displayName)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func toolRow(_ title: LocalizedStringKey, systemImage: String, detail: String? = nil, isBeta: Bool = false, destination: SettingsDestination) -> some View {
        Button {
            guard SettingsSwipe.allowsTaps else { return }
            open(destination)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .foregroundStyle(.tint)
                    .frame(width: 24)
                Text(title)
                if isBeta {
                    BetaBadge()
                }
                Spacer()
                if let detail {
                    Text(detail).foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.forward")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Features Apple keeps to Apple Music, each in its own card.
/// Each exclusive feature in its own color: the symbol, the switch and the
/// buttons of its card.
enum FeatureTint {
    /// Apple Music's red, like Video Artwork.
    static let autoMix = Color(red: 0xFA / 255, green: 0x2D / 255, blue: 0x48 / 255)
    /// Warm, physical: the Taptic Engine's orange.
    static let haptics = Color(red: 0xFF / 255, green: 0x9F / 255, blue: 0x0A / 255)
    /// Apple Music's red: its own animated covers.
    static let videoArtwork = Color(red: 0xFA / 255, green: 0x2D / 255, blue: 0x48 / 255)
    /// Apple Translate's cyan.
    static let translation = Color(red: 0x05 / 255, green: 0xD6 / 255, blue: 0xE4 / 255)
    /// A stage light's purple.
    static let singAlong = Color(red: 0xBF / 255, green: 0x5A / 255, blue: 0xF2 / 255)
    /// YouTube's red.
    static let musicVideo = Color(red: 0xFF / 255, green: 0x00 / 255, blue: 0x33 / 255)
    /// Discord's blurple.
    static let discord = Color(red: 0x58 / 255, green: 0x65 / 255, blue: 0xF2 / 255)
    /// A plain, light blue (not cyan).
    static let headGestures = Color(red: 0x64 / 255, green: 0xA2 / 255, blue: 0xFF / 255)
}

struct ExclusiveFeaturesView: View {
    @AppStorage(MusicPlayerService.autoMixKey) private var autoMix = false
    @AppStorage(AutoMixOptions.styleKey) private var autoMixStyle = AutoMixOptions.Style.autoMix
    @AppStorage(AutoMixOptions.crossfadeKey) private var crossfade = 4.0
    @AppStorage(AutoMixOptions.vocalsKey) private var autoMixVocals = true
    @AppStorage(MusicHapticsService.storageKey) private var musicHaptics = false
    @AppStorage(MusicHapticsService.appleStorageKey) private var appleHaptics = false
    @State private var systemHapticsOn = MAMusicHapticsManager.shared.isActive
    @AppStorage(MusicHapticsSettings.intensityKey) private var hapticsIntensity = 1.0
    @AppStorage(MusicHapticsFocus.storageKey) private var hapticsFocus = MusicHapticsFocus.instruments
    @State private var autoMixOpen = false
    @State private var hapticsOpen = false
    @State private var motionOpen = false
    @State private var translationOpen = false
    @AppStorage(MotionArtworkService.storageKey) private var motionArtwork = true
    @AppStorage(MotionArtworkService.keepsPlayingKey) private var motionKeepsPlaying = true
    @AppStorage(MotionArtworkService.classicUnderLyricsKey) private var motionClassicUnderLyrics = false
    @AppStorage(LyricsTranslator.enabledKey) private var translatesLyrics = false
    @AppStorage(LyricsTranslator.automaticKey) private var translatesAutomatically = false
    @AppStorage(LyricsTranslator.targetKey) private var translationTarget = ""
    @State private var translationLanguages: [Locale.Language] = []

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Text("Features that you usually see only for streaming platforms, never for local songs")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                CollapsibleGlassCard(title: "AutoMix", systemImage: "circlebadge.2.fill", expanded: $autoMixOpen) {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Song Transitions", isOn: $autoMix.animation(.smooth))
                        if autoMix {
                            Text("Transition Style").font(.subheadline).foregroundStyle(.secondary)
                            GlassSegmentedPicker(
                                "Transition Style",
                                options: AutoMixOptions.Style.allCases,
                                selection: $autoMixStyle.animation(.smooth),
                                title: \.title,
                                symbol: \.symbol
                            )
                            switch autoMixStyle {
                            case .autoMix:
                                Text("Blends at the ideal moment, on the beat.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                Toggle("Keep Vocals Apart", isOn: $autoMixVocals)
                                Text("Two voices never overlap, using synced lyrics.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            case .crossfade:
                                Text("Blends over a fixed duration.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                Text("Crossfade Duration").font(.subheadline).foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("\(Int(crossfade)) seconds")
                                        .foregroundStyle(.secondary)
                                        .contentTransition(.numericText())
                                        .animation(.smooth, value: crossfade)
                                    HStack(spacing: 12) {
                                        Text("1s").foregroundStyle(.secondary)
                                        Slider(value: $crossfade, in: AutoMixOptions.crossfadeRange, step: 1)
                                        Text("12s").foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
                .featureTint(FeatureTint.autoMix)
                if MusicHapticsService.isSupported {
                    CollapsibleGlassCard(title: "Music Haptics", systemImage: "iphone.radiowaves.left.and.right", expanded: $hapticsOpen) {
                        VStack(alignment: .leading, spacing: 12) {
                            Toggle("Music Haptics Custom", isOn: Binding(
                                get: { musicHaptics },
                                set: { on in withAnimation(.smooth) { musicHaptics = on; if on { appleHaptics = false } } }
                            ))
                            Label("Only while the app is open", systemImage: "iphone")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Toggle("Music Haptics Apple", isOn: Binding(
                                get: { appleHaptics },
                                set: { on in
                                    withAnimation(.smooth) { appleHaptics = on; if on { musicHaptics = false } }
                                    MusicPlayerService.shared.refreshNowPlayingInfo()
                                }
                            ))
                            Label("Only for popular songs on Apple's servers", systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .onReceive(NotificationCenter.default.publisher(for: MAMusicHapticsManager.activeStatusDidChangeNotification).receive(on: DispatchQueue.main)) { _ in
                                    withAnimation(.smooth) { systemHapticsOn = MAMusicHapticsManager.shared.isActive }
                                }
                            if appleHaptics && !systemHapticsOn {
                                Label("Turn on Music Haptics in iOS", systemImage: "exclamationmark.triangle.fill")
                                    .font(.footnote)
                                    .foregroundStyle(.orange)
                            }
                            if musicHaptics {
                                Text("Follow").font(.subheadline).foregroundStyle(.secondary)
                                GlassSegmentedPicker(
                                    "Follow",
                                    options: MusicHapticsFocus.allCases,
                                    selection: $hapticsFocus,
                                    title: \.title,
                                    symbol: \.symbol
                                )
                                Text("Intensity").font(.subheadline).foregroundStyle(.secondary)
                                HStack(spacing: 12) {
                                    Image(systemName: "iphone.gen3.radiowaves.left.and.right").imageScale(.small).foregroundStyle(.secondary)
                                    Slider(value: $hapticsIntensity, in: MusicHapticsSettings.intensityRange)
                                    Image(systemName: "iphone.gen3.radiowaves.left.and.right").imageScale(.large).foregroundStyle(.secondary)
                                }
                                Button("Reset to Defaults") {
                                    withAnimation(.smooth) {
                                        let defaults = MusicHapticsSettings()
                                        hapticsIntensity = defaults.intensity
                                        hapticsFocus = defaults.focus
                                    }
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.tint)
                                .disabled(MusicHapticsSettings(intensity: hapticsIntensity, focus: hapticsFocus) == MusicHapticsSettings())
                            }
                        }
                    }
                    .featureTint(FeatureTint.haptics)
                }
                CollapsibleGlassCard(title: "Video Artwork", systemImage: "play.rectangle.fill", expanded: $motionOpen) {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Animated Covers", isOn: $motionArtwork.animation(.smooth))
                        Text("Only for songs that have one on \(Image(systemName: "apple.logo"))Music")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        if motionArtwork {
                            Toggle("Keep Playing When Paused", isOn: $motionKeepsPlaying)
                            Toggle("Classic Background Behind Lyrics", isOn: $motionClassicUnderLyrics)
                        }
                    }
                }
                .featureTint(FeatureTint.videoArtwork)
                MusicVideoCard()
                CollapsibleGlassCard(title: "Lyrics Translation", systemImage: "translate", expanded: $translationOpen) {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Translate Lyrics", isOn: $translatesLyrics.animation(.smooth))
                        if translatesLyrics {
                            Toggle("Translate Automatically", isOn: $translatesAutomatically.animation(.smooth))
                            Text(translatesAutomatically ? "Every song, as soon as its lyrics open" : "From \(Image(systemName: "ellipsis")) in Now Playing")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .contentTransition(.opacity)
                            HStack {
                                Text("Language")
                                Spacer(minLength: 12)
                                Picker("Language", selection: $translationTarget) {
                                    Text(LyricsTranslator.displayName(of: Locale.current.language)).tag("")
                                    ForEach(translationLanguages.filter { $0.minimalIdentifier != Locale.current.language.minimalIdentifier }, id: \.minimalIdentifier) { language in
                                        Text(LyricsTranslator.displayName(of: language)).tag(language.minimalIdentifier)
                                    }
                                }
                                .pickerStyle(.menu)
                                .labelsHidden()
                                .lineLimit(1)
                                .fixedSize()
                                .tint(.secondary)
                            }
                        }
                        Label("On device, under each line", systemImage: "iphone")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .featureTint(FeatureTint.translation)
                .task { translationLanguages = await LyricsTranslator.supportedTargets() }
                if SingAlongModel.isSupported {
                    SingAlongCard()
                }
                DiscordPresenceCard()
                HeadGesturesCard()
                if WorkoutListening.isAvailable {
                    WorkoutsCard()
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .background(Color(uiColor: .settingsBackground).ignoresSafeArea())
    }
}

/// Settings › Home › Tab Bar: the bar as it looks. A tab picked up (a short
/// hold) follows the finger: over the bar the others make room for it,
/// anywhere else it leaves the bar. Library and Search keep their ends.
private struct TabBarEditor: View {
    @EnvironmentObject private var router: AppRouter
    @State private var dragged: AppTab?
    @State private var location: CGPoint = .zero
    @State private var barFrame: CGRect = .zero
    /// Back to false when the touch ends or is cancelled (which skips
    /// onEnded), so a tab is never left hanging.
    @GestureState private var isHolding = false

    private static let space = "tabBarEditor"

    /// The bar without the tab being dragged.
    private var barTabs: [AppTab] { router.optionalTabs.filter { $0 != dragged } }

    /// Where the dragged tab would land: the slot under the finger, while
    /// it's over the bar and there's room.
    private var gapIndex: Int? {
        guard let dragged, barFrame.insetBy(dx: 0, dy: -28).contains(location) else { return nil }
        if !router.optionalTabs.contains(dragged), barTabs.count >= AppTab.maxOptionalTabs { return nil }
        let slotWidth = barFrame.width / CGFloat(barTabs.count + 3)
        let slot = Int(((location.x - barFrame.minX) / slotWidth).rounded(.down)) - 1
        return min(max(slot, 0), barTabs.count)
    }

    var body: some View {
        let unused = AppTab.optional.filter { !router.optionalTabs.contains($0) }
        VStack(spacing: 16) {
            HStack(spacing: 0) {
                item(.library).frame(maxWidth: .infinity).opacity(0.45)
                ForEach(router.optionalTabs) { tab in
                    if let index = barTabs.firstIndex(of: tab), index == gapIndex { gap }
                    handle(tab)
                        .frame(maxWidth: tab == dragged ? 0 : .infinity)
                }
                if gapIndex == barTabs.count { gap }
                item(.search).frame(maxWidth: .infinity).opacity(0.45)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity)
            .glassEffect(.regular, in: .capsule)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { barFrame = $0 }

            Group {
                if unused.isEmpty {
                    Text("Drag a tab out of the bar to remove it")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 12)], spacing: 14) {
                        ForEach(unused) { tab in
                            handle(tab, circled: true)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 76)
        }
        .coordinateSpace(.named(Self.space))
        .overlay(alignment: .topLeading) {
            if let dragged {
                item(dragged)
                    .foregroundStyle(.tint)
                    .frame(width: 72, height: 56)
                    .glassEffect(.regular, in: .capsule)
                    .scaleEffect(1.08)
                    .position(location)
                    .allowsHitTesting(false)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.smooth(duration: 0.25), value: gapIndex)
        .animation(.smooth(duration: 0.25), value: router.optionalTabs)
        .sensoryFeedback(.selection, trigger: gapIndex)
        .sensoryFeedback(.impact(weight: .light), trigger: dragged) { _, new in new != nil }
        .onChange(of: isHolding) { _, holding in
            if !holding { drop() }
        }
    }

    /// Where the dragged tab would go, a dashed circle like the ones below.
    private var gap: some View {
        dashedCircle
            .frame(width: 40, height: 40)
            .frame(maxWidth: .infinity)
            .transition(.scale.combined(with: .opacity))
    }

    private var dashedCircle: some View {
        Circle().strokeBorder(.tint.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
    }

    private func item(_ tab: AppTab) -> some View {
        VStack(spacing: 3) {
            Image(systemName: tab.systemImage)
                .font(.title3)
                .frame(height: 24)
            Text(tab.title)
                .font(.caption2.weight(.medium))
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.vertical, 2)
    }

    private func handle(_ tab: AppTab, circled: Bool = false) -> some View {
        Group {
            if circled {
                VStack(spacing: 4) {
                    Image(systemName: tab.systemImage)
                        .font(.title3)
                        .frame(width: 50, height: 50)
                        .overlay { dashedCircle }
                    Text(tab.title)
                        .font(.caption2.weight(.medium))
                        .fixedSize()
                }
            } else {
                item(tab)
            }
        }
        .foregroundStyle(.tint)
        .opacity(tab == dragged ? 0 : 1)
        .contentShape(.rect)
        .gesture(
            LongPressGesture(minimumDuration: 0.12)
                .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space)))
                .onChanged { value in
                    guard case .second(true, let drag?) = value else { return }
                    location = drag.location
                    if dragged == nil {
                        SettingsSwipe.isControlTracking = true
                        withAnimation(.smooth(duration: 0.2)) { dragged = tab }
                    }
                }
                .updating($isHolding) { _, holding, _ in holding = true }
                .onEnded { _ in drop() }
        )
    }

    private func drop() {
        SettingsSwipe.isControlTracking = false
        guard let tab = dragged else { return }
        var tabs = barTabs
        if let index = gapIndex {
            tabs.insert(tab, at: index)
        }
        withAnimation(.smooth(duration: 0.25)) {
            router.setOptionalTabs(tabs)
            dragged = nil
        }
    }
}

/// The home toolbar's two shortcut slots, edited like the tab bar: hold a
/// shortcut and drag it into a slot, across, or out. Each slot sits on the
/// capsule's inner side, so the toolbar reads the same both ways.
private struct ShortcutEditor: View {
    @Binding var leading: HomeShortcut
    @Binding var leading2: HomeShortcut
    @Binding var leading3: HomeShortcut
    @Binding var trailing: HomeShortcut
    @State private var dragged: HomeShortcut?
    /// The slot it was lifted from, if not from the shelf below.
    @State private var origin: Side?
    @State private var location: CGPoint = .zero
    @State private var frames: [Side: CGRect] = [:]
    @GestureState private var isHolding = false

    /// Beside Settings (up to three), or before Add.
    private enum Side: Hashable { case leading(Int), trailing }

    private func value(_ side: Side) -> HomeShortcut {
        switch side {
        case .leading(0): leading
        case .leading(1): leading2
        case .leading: leading3
        case .trailing: trailing
        }
    }

    /// The filled slots beside Settings, then one empty to drop into.
    private var leadingSlots: [Int] {
        let filled = (0..<3).filter { value(.leading($0)) != .none }
        return filled.count < 3 ? filled + [filled.count] : filled
    }
    private static let space = "shortcutEditor"

    /// The slot under the finger, generously.
    private var target: Side? {
        guard dragged != nil else { return nil }
        return frames.first { $0.value.insetBy(dx: -24, dy: -24).contains(location) }?.key
    }

    var body: some View {
        let shelf = HomeShortcut.allCases.filter { $0 != .none && $0 != leading && $0 != leading2 && $0 != leading3 && $0 != trailing }
        VStack(spacing: 16) {
            HStack {
                capsule {
                    Image(systemName: "gearshape").foregroundStyle(.secondary)
                    ForEach(leadingSlots, id: \.self) { slot(.leading($0)) }
                }
                Spacer()
                Text("Library").font(.headline)
                Spacer()
                capsule {
                    slot(.trailing)
                    Image(systemName: "plus").foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)

            Group {
                if shelf.isEmpty {
                    Text("Drag a shortcut out of the bar to remove it")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 12)], spacing: 14) {
                        ForEach(shelf) { shortcut in
                            VStack(spacing: 4) {
                                icon(shortcut)
                                    .frame(width: 50, height: 50)
                                    .overlay { dashed(tinted: true) }
                                Text(shortcut.title)
                                    .font(.caption2.weight(.medium))
                                    .lineLimit(1)
                                    .fixedSize()
                            }
                            .foregroundStyle(.tint)
                            .opacity(shortcut == dragged ? 0 : 1)
                            .contentShape(.rect)
                            .gesture(drag(shortcut, from: nil))
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 76)
        }
        .coordinateSpace(.named(Self.space))
        .overlay(alignment: .topLeading) {
            if let dragged {
                icon(dragged)
                    .foregroundStyle(.tint)
                    .frame(width: 52, height: 52)
                    .glassEffect(.regular, in: .circle)
                    .scaleEffect(1.08)
                    .position(location)
                    .allowsHitTesting(false)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.smooth(duration: 0.25), value: target)
        .animation(.smooth(duration: 0.25), value: leading)
        .animation(.smooth(duration: 0.25), value: leading2)
        .animation(.smooth(duration: 0.25), value: leading3)
        .animation(.smooth(duration: 0.25), value: trailing)
        .sensoryFeedback(.selection, trigger: target)
        .sensoryFeedback(.impact(weight: .light), trigger: dragged) { _, new in new != nil }
        .onChange(of: isHolding) { _, holding in
            if !holding { drop() }
        }
    }

    private func capsule<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 4) { content() }
            .font(.body.weight(.medium))
            .padding(.horizontal, 6)
            .frame(height: 44)
            .glassEffect(.regular, in: .capsule)
    }

    /// The slot's shortcut, or a grey dashed circle when it has none (or
    /// its shortcut is being dragged away).
    private func slot(_ side: Side) -> some View {
        let shortcut = value(side)
        let shown = origin == side ? HomeShortcut.none : shortcut
        return ZStack {
            if shown == .none || target == side {
                dashed(tinted: target == side)
                    .transition(.scale.combined(with: .opacity))
            }
            if shown != .none, target != side {
                icon(shown).foregroundStyle(.tint)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .frame(width: 34, height: 34)
        .contentShape(.circle)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { frames[side] = $0 }
        .gesture(shortcut == .none ? nil : drag(shortcut, from: side))
    }

    private func icon(_ shortcut: HomeShortcut) -> some View {
        Image(systemName: shortcut.symbol ?? "circle.dashed").font(.title3)
    }

    private func dashed(tinted: Bool) -> some View {
        Circle().strokeBorder(tinted ? AnyShapeStyle(.tint.opacity(0.6)) : AnyShapeStyle(.secondary.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
    }

    private func drag(_ shortcut: HomeShortcut, from side: Side?) -> some Gesture {
        LongPressGesture(minimumDuration: 0.12)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space)))
            .onChanged { value in
                guard case .second(true, let drag?) = value else { return }
                location = drag.location
                if dragged == nil {
                    SettingsSwipe.isControlTracking = true
                    withAnimation(.smooth(duration: 0.2)) {
                        dragged = shortcut
                        origin = side
                    }
                }
            }
            .updating($isHolding) { _, holding, _ in holding = true }
            .onEnded { _ in drop() }
    }

    /// Into a slot (its shortcut swapping to where this one came from), or
    /// out of the bar.
    private func drop() {
        SettingsSwipe.isControlTracking = false
        guard let shortcut = dragged else { return }
        let landing = target
        withAnimation(.smooth(duration: 0.25)) {
            if landing != origin {
                let displaced = landing.map(value) ?? .none
                if let origin { set(origin, displaced) }
                if let landing { set(landing, shortcut) }
            }
            dragged = nil
            origin = nil
            // No gaps beside Settings.
            let kept = [leading, leading2, leading3].filter { $0 != .none }
            leading = kept.count > 0 ? kept[0] : .none
            leading2 = kept.count > 1 ? kept[1] : .none
            leading3 = kept.count > 2 ? kept[2] : .none
        }
    }

    private func set(_ side: Side, _ shortcut: HomeShortcut) {
        switch side {
        case .leading(0): leading = shortcut
        case .leading(1): leading2 = shortcut
        case .leading: leading3 = shortcut
        case .trailing: trailing = shortcut
        }
    }
}

/// Discord Rich Presence: off by default, then a one-time link to the
/// user's Discord account.
private struct DiscordPresenceCard: View {
    @AppStorage(DiscordPresence.enabledKey) private var enabled = false
    @ObservedObject private var presence = DiscordPresence.shared
    @State private var open = false

    var body: some View {
        CollapsibleGlassCard(title: "Discord Status", image: Image("DiscordLogo"), expanded: $open) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Rich Presence", isOn: $enabled.animation(.smooth))
                    .onChange(of: enabled) { presence.refresh() }
                Text("Your Discord profile shows what you're listening to, with the song, the artist and the time left. Covers come from Apple's catalog.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if enabled {
                    HStack {
                        Text(status).foregroundStyle(.secondary)
                        Spacer()
                        if presence.isLinked {
                            Button("Unlink") {
                                guard SettingsSwipe.allowsTaps else { return }
                                presence.unlink()
                            }
                            .buttonStyle(.glassProminent)
                        } else {
                            Button("Link Discord") {
                                guard SettingsSwipe.allowsTaps else { return }
                                presence.link()
                            }
                            .buttonStyle(.glassProminent)
                            .disabled(presence.state == .linking)
                        }
                    }
                }
            }
        }
        .featureTint(FeatureTint.discord)
    }

    private var status: String {
        switch presence.state {
        case .unlinked: String(localized: "Not linked")
        case .linking: String(localized: "Waiting for Discord…")
        case .connecting: String(localized: "Connecting…")
        case .ready: String(localized: "Connected")
        case .failed(let message): message
        }
    }
}

/// One of the pages at the top of Settings, as a glass block half the
/// width of a card.
private struct FeatureTile: View {
    let title: LocalizedStringKey
    let systemImage: String
    let color: Color
    var isBeta = false
    let action: () -> Void

    var body: some View {
        Button {
            guard SettingsSwipe.allowsTaps else { return }
            action()
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    Image(systemName: systemImage)
                        .font(.title2)
                        .foregroundStyle(color)
                        // Same height whatever the symbol, so titles line up.
                        .frame(height: 28)
                    Spacer(minLength: 4)
                    if isBeta {
                        // The tile's color, not the app's accent.
                        BetaBadge().tint(color)
                    }
                }
                Spacer(minLength: 16)
                HStack(alignment: .lastTextBaseline) {
                    Text(title)
                        .font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.forward")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect(cornerRadius: 28))
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 28))
    }
}

/// One part of the widget and the action it opens, as a menu.
private struct WidgetTapActionRow: View {
    let zone: WidgetTapZone
    @AppStorage private var rawValue: String

    init(zone: WidgetTapZone) {
        self.zone = zone
        _rawValue = AppStorage(wrappedValue: zone.defaultAction.rawValue, zone.storageKey)
    }

    var body: some View {
        HStack {
            Text(zone.title)
            Spacer(minLength: 12)
            Picker(zone.title, selection: $rawValue) {
                ForEach(NowPlayingTapAction.allCases) { action in
                    Text(action.title).tag(action.rawValue)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .lineLimit(1)
            .fixedSize()
            .tint(.secondary)
        }
    }
}

/// XMGo's audio mode picker: a glass capsule whose tinted selection slides
/// between the options. With symbols, each option shows one above its title.
///
/// Like iOS's segmented controls, the selection can be dragged: it follows
/// the finger and settles on the nearest option. The new value is handed
/// over as the selection starts moving, or once it has settled with
/// `commitsWhenSettled` (for a change that would hide the slide, like the
/// style cross-fade).
struct GlassSegmentedPicker<Value: Hashable>: View {
    let options: [Value]
    @Binding var selection: Value
    let title: (Value) -> String
    let symbol: ((Value) -> String)?
    let label: String
    let commitsWhenSettled: Bool

    /// What the capsule shows, ahead of `selection` until it settles.
    @State private var shown: Value?
    /// The slide whose end hands its option over (a newer one replaces it).
    @State private var pendingSlide: UUID?
    /// The capsule's leading edge while it follows the finger.
    @State private var dragX: CGFloat?
    @State private var width: CGFloat = 0
    /// The selection held under the finger: it lifts, like iOS's glass
    /// selections do.
    @State private var isHolding = false
    @GestureState private var isTouching = false

    private static var inset: CGFloat { 4 }
    private static var settle: Animation { .spring(response: 0.32, dampingFraction: 0.86) }

    /// A literal label, localized.
    init(_ label: LocalizedStringResource, options: [Value], selection: Binding<Value>, title: @escaping (Value) -> String, symbol: ((Value) -> String)? = nil, commitsWhenSettled: Bool = false) {
        self.init(String(localized: label), options: options, selection: selection, title: title, symbol: symbol, commitsWhenSettled: commitsWhenSettled)
    }

    /// A label already localized (or dynamic), used as is.
    @_disfavoredOverload
    init<S: StringProtocol>(_ label: S, options: [Value], selection: Binding<Value>, title: @escaping (Value) -> String, symbol: ((Value) -> String)? = nil, commitsWhenSettled: Bool = false) {
        self.label = String(label)
        self.options = options
        _selection = selection
        self.title = title
        self.symbol = symbol
        self.commitsWhenSettled = commitsWhenSettled
    }

    private var current: Value { shown ?? selection }
    private var segment: CGFloat { options.isEmpty ? 0 : (width - Self.inset * 2) / CGFloat(options.count) }

    private func index(of value: Value) -> Int { options.firstIndex(of: value) ?? 0 }

    private func nearestIndex(toLeadingEdge x: CGFloat) -> Int {
        guard segment > 0 else { return 0 }
        return min(max(Int((x / segment).rounded()), 0), options.count - 1)
    }

    var body: some View {
        let highlighted = dragX.map { nearestIndex(toLeadingEdge: $0) } ?? index(of: current)
        ZStack(alignment: .leading) {
            Capsule()
                .fill(.tint.opacity(isHolding ? 0.22 : 0.30))
                .glassEffect(.regular.interactive(), in: .capsule)
                .frame(width: max(segment, 0))
                .scaleEffect(isHolding ? 1.1 : 1)
                .offset(x: dragX ?? CGFloat(index(of: current)) * segment)
            HStack(spacing: 0) {
                ForEach(Array(options.enumerated()), id: \.element) { offset, option in
                    VStack(spacing: 5) {
                        if let symbol {
                            Image(systemName: symbol(option)).font(.headline)
                        }
                        Text(title(option))
                            .font(symbol == nil ? .subheadline.weight(.semibold) : .caption2.weight(.semibold))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(offset == highlighted ? .primary : .secondary)
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAddTraits(offset == highlighted ? .isSelected : [])
                    .accessibilityAction { select(option) }
                }
            }
        }
        .frame(height: symbol == nil ? 40 : 58)
        .padding(Self.inset)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .contentShape(Capsule())
        .gesture(drag)
        // Not interactive: the whole capsule bouncing under the finger
        // fought the selection's slide (only the selection moves, as in
        // iOS's segmented controls).
        .glassEffect(.regular, in: .capsule)
        .onChange(of: isTouching) { _, touching in
            // Also on a cancelled touch, which skips `onEnded`.
            if !touching {
                SettingsSwipe.isControlTracking = false
                if isHolding { withAnimation(Self.settle) { isHolding = false } }
                if dragX != nil { withAnimation(Self.settle) { dragX = nil } }
            }
        }
        .onChange(of: selection) { _, _ in
            if pendingSlide == nil { shown = nil }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($isTouching) { _, state, _ in state = true }
            .onChanged { value in
                SettingsSwipe.isControlTracking = true
                let startsOnSelection = Int((value.startLocation.x - Self.inset) / max(segment, 1)) == index(of: current)
                if startsOnSelection, !isHolding {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) { isHolding = true }
                }
                // A drag starts on the selection, like iOS's; elsewhere the
                // touch is a tap on the option it lifts on.
                let startIndex = Int((value.startLocation.x - Self.inset) / max(segment, 1))
                guard abs(value.translation.width) > 6, startIndex == index(of: current) || dragX != nil else { return }
                let start = CGFloat(index(of: current)) * segment
                let x = min(max(start + value.translation.width, 0), segment * CGFloat(options.count - 1))
                if dragX == nil {
                    withAnimation(.interactiveSpring(response: 0.2, dampingFraction: 0.9)) { dragX = x }
                } else {
                    dragX = x
                }
            }
            .onEnded { value in
                guard SettingsSwipe.allowsTaps else { return }
                let target: Int
                if let dragX {
                    target = nearestIndex(toLeadingEdge: dragX)
                } else {
                    target = min(max(Int((value.location.x - Self.inset) / max(segment, 1)), 0), options.count - 1)
                }
                select(options[target])
            }
    }

    private func select(_ option: Value) {
        guard commitsWhenSettled else {
            pendingSlide = nil
            withAnimation(Self.settle) {
                shown = nil
                dragX = nil
                isHolding = false
            }
            if option != selection { selection = option }
            return
        }
        let slide = UUID()
        pendingSlide = option == selection ? nil : slide
        withAnimation(Self.settle, completionCriteria: .logicallyComplete) {
            shown = option == selection ? nil : option
            dragX = nil
            isHolding = false
        } completion: {
            guard pendingSlide == slide else { return }
            pendingSlide = nil
            // `shown` stays until `selection` actually changes: the owner
            // may apply it a moment later.
            selection = option
        }
    }
}

private struct KeepsFeatureTintKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// A card in its feature's own color: Infused leaves it so.
    var keepsFeatureTint: Bool {
        get { self[KeepsFeatureTintKey.self] }
        set { self[KeepsFeatureTintKey.self] = newValue }
    }
}

extension View {
    /// An exclusive feature's card in its own color, whatever the accent.
    func featureTint(_ color: Color) -> some View {
        tint(color).environment(\.keepsFeatureTint, true)
    }
}

/// XMGo's folding card: a header that toggles, and its content below.
struct CollapsibleGlassCard<Content: View>: View {
    @AppStorage(AppTint.storageKey) private var tintRawValue = AppTint.infused.rawValue
    @Environment(\.keepsFeatureTint) private var keepsFeatureTint
    let title: String
    let systemImage: String
    /// An asset image in place of the symbol (a brand's logo).
    var image: Image?
    @Binding var isExpanded: Bool
    @ViewBuilder var content: Content

    /// A literal title, localized.
    init(title: LocalizedStringResource, systemImage: String = "", image: Image? = nil, expanded: Binding<Bool>, @ViewBuilder content: () -> Content) {
        self.init(title: String(localized: title), systemImage: systemImage, image: image, expanded: expanded, content: content)
    }

    /// A title already localized (or dynamic), shown as is.
    @_disfavoredOverload
    init<S: StringProtocol>(title: S, systemImage: String = "", image: Image? = nil, expanded: Binding<Bool>, @ViewBuilder content: () -> Content) {
        self.title = String(title)
        self.systemImage = systemImage
        self.image = image
        _isExpanded = expanded
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                guard SettingsSwipe.allowsTaps else { return }
                withAnimation(.interactiveSpring(response: 0.35, dampingFraction: 0.85)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    Group {
                        if let image {
                            image.resizable().scaledToFit().frame(height: 15)
                        } else {
                            Image(systemName: systemImage).font(.headline)
                        }
                    }
                    .foregroundStyle(.tint)
                    .frame(width: 26)
                    Text(title).font(.headline)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")

            if isExpanded {
                content
                    .padding(.top, 18)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(ModuleTint(color: tintRawValue == AppTint.infused.rawValue && !keepsFeatureTint ? moduleColor : nil))
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 28))
        .animation(.interactiveSpring(response: 0.35, dampingFraction: 0.85), value: isExpanded)
    }
}

extension Color {
    static let statsTint = tileShade(hue: 0.57)
    static let aiTint = tileShade(hue: 0.73)
    static let gamesTint = tileShade(hue: 0.36)
    static let extrasTint = tileShade(hue: 0.14, darkSaturation: 0.45, lightBrightness: 0.78)
    /// Apple Fitness's electric lime; a deeper green on light, where lime washes out.
    static let fitnessGreen = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .light
            ? UIColor(hue: 0.29, saturation: 0.95, brightness: 0.68, alpha: 1)
            : UIColor(hue: 0.235, saturation: 0.9, brightness: 1, alpha: 1)
    })

    /// Pale on dark; deeper on light, where pale shades wash out on white.
    static func tileShade(hue: CGFloat, darkSaturation: CGFloat = 0.32, lightBrightness: CGFloat = 0.82) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .light
                ? UIColor(hue: hue, saturation: 0.7, brightness: lightBrightness, alpha: 1)
                : UIColor(hue: hue, saturation: darkSaturation, brightness: 1, alpha: 1)
        })
    }
}

// MARK: - Equalizer

enum EQPreset: String, CaseIterable, Identifiable {
    case flat, acoustic, bassBooster, bassReducer, classical, dance, deep, electronic,
         hipHop, jazz, latin, loudness, lounge, piano, pop, rnb, rock, smallSpeakers,
         spokenWord, trebleBooster, trebleReducer, vocalBooster

    var id: String { rawValue }

    var title: String {
        switch self {
        case .flat: String(localized: "Flat")
        case .acoustic: String(localized: "Acoustic")
        case .bassBooster: String(localized: "Bass Booster")
        case .bassReducer: String(localized: "Bass Reducer")
        case .classical: String(localized: "Classical")
        case .dance: String(localized: "Dance")
        case .deep: String(localized: "Deep")
        case .electronic: String(localized: "Electronic")
        case .hipHop: String(localized: "Hip-Hop")
        case .jazz: String(localized: "Jazz")
        case .latin: String(localized: "Latin")
        case .loudness: String(localized: "Loudness")
        case .lounge: String(localized: "Lounge")
        case .piano: String(localized: "Piano")
        case .pop: String(localized: "Pop")
        case .rnb: String(localized: "R&B")
        case .rock: String(localized: "Rock")
        case .smallSpeakers: String(localized: "Small Speakers")
        case .spokenWord: String(localized: "Spoken Word")
        case .trebleBooster: String(localized: "Treble Booster")
        case .trebleReducer: String(localized: "Treble Reducer")
        case .vocalBooster: String(localized: "Vocal Booster")
        }
    }

    /// 32 Hz … 16 kHz.
    var gains: [Double] {
        switch self {
        case .flat: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        case .acoustic: [4.5, 4.5, 3.5, 1, 1.5, 1.5, 3, 3.5, 3, 2]
        case .bassBooster: [5.5, 4.5, 3.5, 2.5, 1, 0, 0, 0, 0, 0]
        case .bassReducer: [-5.5, -4.5, -3.5, -2.5, -1, 0, 0, 0, 0, 0]
        case .classical: [4.5, 3.5, 3, 2.5, -1.5, -1.5, 0, 2, 3, 3.5]
        case .dance: [3.5, 6, 5, 0, 2, 3.5, 5, 4.5, 3.5, 0]
        case .deep: [5, 3.5, 1.5, 1, 3, 2.5, 1.5, -2, -3.5, -4.5]
        case .electronic: [4.5, 4, 1.5, 0, -2, 2, 1, 1.5, 4, 5]
        case .hipHop: [5, 4.5, 1.5, 3, -1, -1, 1.5, -0.5, 2, 3]
        case .jazz: [4, 3, 1.5, 2, -1.5, -1.5, 0, 1.5, 3, 3.5]
        case .latin: [4.5, 3, 0, 0, -1.5, -1.5, -1.5, 0, 3, 4.5]
        case .loudness: [6, 4, 0, 0, -2, 0, -1, -5, 5, 1]
        case .lounge: [-3, -1.5, -0.5, 1.5, 4, 2.5, 0, -1.5, 2, 1]
        case .piano: [3, 2, 0, 2.5, 3, 1.5, 3.5, 4.5, 3, 3.5]
        case .pop: [-1.5, -1, 0, 2, 4, 4, 2, 0, -1, -1.5]
        case .rnb: [2.5, 7, 5.5, 1.5, -2.5, -1.5, 2, 2.5, 3, 3.5]
        case .rock: [5, 4, 3, 1.5, -0.5, -1, 0.5, 2.5, 3.5, 4.5]
        case .smallSpeakers: [5.5, 4.5, 3.5, 2.5, 1, 0, -1, -2.5, -3.5, -4.5]
        case .spokenWord: [-3.5, -0.5, 0, 0.5, 3.5, 4.5, 4.5, 4, 2, 0]
        case .trebleBooster: [0, 0, 0, 0, 0, 1, 2.5, 3.5, 4.5, 5.5]
        case .trebleReducer: [0, 0, 0, 0, 0, -1, -2.5, -3.5, -4.5, -5.5]
        case .vocalBooster: [-1.5, -3, -3, 1.5, 3.5, 3.5, 3, 1.5, 0, -1.5]
        }
    }

    static func matching(_ gains: [Double]) -> EQPreset? {
        allCases.first { preset in zip(preset.gains, gains).allSatisfy { abs($0 - $1) < 0.01 } }
    }

    /// What the Playback card shows next to “Equalizer”.
    static var summary: String {
        guard Equalizer.isOn else { return String(localized: "Off") }
        return matching(Equalizer.gains)?.title ?? String(localized: "Custom")
    }
}

struct EqualizerView: View {
    @State private var isOn = Equalizer.isOn
    @State private var gains = Equalizer.gains

    private var preset: EQPreset? { EQPreset.matching(gains) }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Equalizer", isOn: $isOn.animation(.smooth))
                        .onChange(of: isOn) { _, on in Equalizer.setOn(on) }
                    Divider()
                    HStack {
                        Text("Preset")
                        Spacer()
                        Menu {
                            Picker("Preset", selection: Binding(
                                get: { preset },
                                set: { if let new = $0 { select(new) } }
                            )) {
                                ForEach(EQPreset.allCases) { Text($0.title).tag(Optional($0)) }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(preset?.title ?? String(localized: "Custom"))
                                Image(systemName: "chevron.up.chevron.down").font(.footnote.weight(.medium))
                            }
                        }
                        .disabled(!isOn)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassEffect(.regular, in: .rect(cornerRadius: 28))

                EQResponseCurve(gains: GainVector(values: gains))
                    .frame(height: 110)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 18)
                    .glassEffect(.regular, in: .rect(cornerRadius: 28))
                    .opacity(isOn ? 1 : 0.4)

                bands
                    .padding(.top, 8)
                    .opacity(isOn ? 1 : 0.4)
                    .disabled(!isOn)

                Text("Boosts are taken off the overall level, so the sound never clips. Double-tap a slider to bring it back to 0.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .animation(.smooth, value: isOn)
    }

    private var bands: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Equalizer.frequencies.indices, id: \.self) { i in
                VStack(spacing: 8) {
                    Text(Self.gainLabel(gains[i]))
                        .font(.caption2.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(gains[i] == 0 ? .secondary : .primary)
                        .contentTransition(.numericText(value: gains[i]))
                    GlassBandSlider(
                        value: Binding(get: { gains[i] }, set: { gains[i] = $0; Equalizer.setGains(gains) }),
                        range: Equalizer.range,
                        label: Self.frequencyLabel(Equalizer.frequencies[i])
                    )
                    .frame(width: 28, height: 250)
                    Text(Self.frequencyLabel(Equalizer.frequencies[i]))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func select(_ preset: EQPreset) {
        withAnimation(.smooth(duration: 0.45)) { gains = preset.gains }
        Equalizer.setGains(preset.gains)
    }

    static func gainLabel(_ gain: Double) -> String {
        if gain == 0 { return "0" }
        let text = gain == gain.rounded() ? String(Int(gain)) : gain.formatted(.number.precision(.fractionLength(1)))
        return gain > 0 ? "+" + text : text
    }

    static func frequencyLabel(_ f: Double) -> String {
        f >= 1000 ? "\(Int(f / 1000))K" : "\(Int(f))"
    }
}

/// A thick vertical Liquid Glass slider, filled from 0 dB toward the value.
struct GlassBandSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let label: String

    @State private var dragStart: Double?

    var body: some View {
        GeometryReader { geo in
            let height = geo.size.height
            let span = range.upperBound - range.lowerBound
            let zeroY = height * range.upperBound / span
            let valueY = height * (range.upperBound - value) / span
            ZStack(alignment: .top) {
                Rectangle()
                    .fill(.primary.opacity(0.18))
                    .frame(height: 1)
                    .offset(y: zeroY - 0.5)
                Rectangle()
                    .fill(.tint)
                    .frame(height: abs(valueY - zeroY))
                    .offset(y: min(valueY, zeroY))
                Capsule()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.25), radius: 2)
                    .frame(width: geo.size.width * 0.55, height: 4)
                    .offset(y: min(max(valueY - 2, 6), height - 10))
            }
            .frame(width: geo.size.width, height: height, alignment: .top)
            .clipShape(Capsule())
            .contentShape(Capsule())
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        if dragStart == nil {
                            dragStart = value
                            SettingsSwipe.isControlTracking = true
                        }
                        let raw = (dragStart ?? 0) - drag.translation.height / height * span
                        var new = min(max((raw * 2).rounded() / 2, range.lowerBound), range.upperBound)
                        if abs(raw) < 0.6 { new = 0 } // a little detent at 0 dB
                        if new != value { value = new }
                    }
                    .onEnded { _ in
                        dragStart = nil
                        SettingsSwipe.isControlTracking = false
                    }
            )
            .simultaneousGesture(
                TapGesture(count: 2).onEnded {
                    withAnimation(.smooth) { value = 0 }
                }
            )
        }
        .glassEffect(.regular.interactive(), in: Capsule())
        .sensoryFeedback(trigger: value) { old, new in
            let edges = [0, range.lowerBound, range.upperBound]
            return edges.contains(new) && !edges.contains(old) ? .selection : nil
        }
        .accessibilityElement()
        .accessibilityLabel(label.hasSuffix("K") ? "\(label.dropLast()) kilohertz" : "\(label) hertz")
        .accessibilityValue("\(EqualizerView.gainLabel(value)) decibels")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = min(value + 1, range.upperBound)
            case .decrement: value = max(value - 1, range.lowerBound)
            @unknown default: break
            }
        }
    }
}

/// Ten gains that SwiftUI can interpolate, so the curve morphs between presets.
struct GainVector: VectorArithmetic {
    var values: [Double]

    static var zero: GainVector { GainVector(values: []) }

    private static func combine(_ a: GainVector, _ b: GainVector, _ op: (Double, Double) -> Double) -> GainVector {
        let count = max(a.values.count, b.values.count)
        return GainVector(values: (0..<count).map { op(a.values[safe: $0] ?? 0, b.values[safe: $0] ?? 0) })
    }

    static func + (a: GainVector, b: GainVector) -> GainVector { combine(a, b, +) }
    static func - (a: GainVector, b: GainVector) -> GainVector { combine(a, b, -) }
    mutating func scale(by rhs: Double) { values = values.map { $0 * rhs } }
    var magnitudeSquared: Double { values.reduce(0) { $0 + $1 * $1 } }
}

/// The equalizer's real frequency response, 20 Hz – 20 kHz.
struct EQResponseCurve: View {
    var gains: GainVector

    var body: some View {
        ZStack {
            EQGrid().stroke(.primary.opacity(0.12), lineWidth: 1)
            EQCurveShape(gains: gains, closed: true)
                .fill(LinearGradient(colors: [Color.accentColor.opacity(0.28), Color.accentColor.opacity(0.04)], startPoint: .top, endPoint: .bottom))
                .foregroundStyle(.tint)
            EQCurveShape(gains: gains, closed: false)
                .stroke(.tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}

private struct EQGrid: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        for f in [100.0, 1000, 10000] {
            let x = rect.minX + rect.width * Equalizer.position(ofFrequency: f)
            path.move(to: CGPoint(x: x, y: rect.minY))
            path.addLine(to: CGPoint(x: x, y: rect.maxY))
        }
        return path
    }
}

private struct EQCurveShape: Shape {
    var gains: GainVector
    let closed: Bool

    var animatableData: GainVector {
        get { gains }
        set { gains = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let steps = 120
        let values = gains.values.count == Equalizer.frequencies.count ? gains.values : Array(repeating: 0, count: Equalizer.frequencies.count)
        let freqs = (0...steps).map { Equalizer.frequency(atPosition: Double($0) / Double(steps)) }
        let response = Equalizer.response(gains: values, at: freqs)
        let scale = rect.height / 2 / 15 // ±15 dB
        var path = Path()
        for (i, db) in response.enumerated() {
            let point = CGPoint(
                x: rect.minX + rect.width * CGFloat(i) / CGFloat(steps),
                y: rect.midY - CGFloat(max(min(db, 15), -15)) * scale
            )
            i == 0 ? path.move(to: point) : path.addLine(to: point)
        }
        if closed {
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
            path.closeSubpath()
        }
        return path
    }
}

extension CollapsibleGlassCard {
    /// Infused accent: each settings module has its own color, keyed by its
    /// symbol (titles change with the language).
    var moduleColor: Color {
        if image != nil { return .tileShade(hue: 0.66) } // Discord's blurple
        let hue: CGFloat? = switch systemImage {
        case "paintpalette.fill": 0.92
        case "play.circle.fill": 0.0
        case "house.fill": 0.08
        case "widget.small": 0.47
        case "circlebadge.2.fill": 0.53
        case "iphone.radiowaves.left.and.right": 0.82
        case "play.rectangle.fill": 0.64
        case "translate": 0.40
        case "figure.run": 0.30
        case "music.microphone": 0.12
        default: nil
        }
        guard let hue else { return AppTint.gray.color } // Tools, Hidden Settings
        if systemImage == "play.circle.fill" { return .tileShade(hue: hue, darkSaturation: 0.55) }
        if systemImage == "figure.run" { return .fitnessGreen }
        return .tileShade(hue: hue)
    }
}

private struct ModuleTint: ViewModifier {
    let color: Color?
    func body(content: Content) -> some View {
        if let color { content.tint(color) } else { content }
    }
}

/// Apple Health workouts: what you play while you exercise (Stats, the
/// Workout Autolist, the assistant).
private struct HeadGesturesCard: View {
    @AppStorage(HeadGestures.enabledKey) private var isEnabled = false
    @AppStorage(HeadGestures.sensitivityKey) private var sensitivity = 0.5
    @ObservedObject private var gestures = HeadGestures.shared
    @State private var open = false
    @State private var lit: HeadGesture?

    var body: some View {
        CollapsibleGlassCard(title: "AirPods Gestures", systemImage: "airpods.gen4", expanded: $open) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Control With Your Head", isOn: Binding(get: { isEnabled }, set: { on in
                    guard SettingsSwipe.allowsTaps else { return }
                    withAnimation(.smooth) { isEnabled = on }
                    HeadGestures.shared.refresh()
                }))
                Text("Nod, shake or tilt your head to control the music, hands-free. With AirPods (3rd generation or later), AirPods Pro, AirPods Max, Beats Fit Pro, Powerbeats Pro 2 and later models.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if isEnabled {
                    Label(status, systemImage: gestures.isConnected ? "checkmark.circle.fill" : "airpods.gen4")
                        .font(.footnote)
                        .foregroundStyle(gestures.isConnected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        .contentTransition(.opacity)
                        .animation(.smooth, value: gestures.isConnected)
                    VStack(spacing: 0) {
                        ForEach(HeadGesture.allCases) { gesture in
                            HeadGestureRow(gesture: gesture, isLit: lit == gesture)
                            if gesture != HeadGesture.allCases.last {
                                Divider().padding(.leading, 40)
                            }
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Sensitivity")
                        HStack(spacing: 10) {
                            Image(systemName: "minus")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                            Slider(value: $sensitivity, in: 0...1) {
                                Text("Sensitivity")
                            } onEditingChanged: { editing in
                                if !editing { HeadGestures.shared.updateSensitivity() }
                            }
                            Image(systemName: "plus")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                        }
                        Text("More sensitive picks up lighter gestures, but may react to other movements.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .transition(.opacity)
                }
            }
        }
        .featureTint(FeatureTint.headGestures)
        .onChange(of: gestures.lastGesture?.at) {
            guard let gesture = gestures.lastGesture?.gesture else { return }
            withAnimation(.smooth(duration: 0.2)) { lit = gesture }
            Task {
                try? await Task.sleep(for: .seconds(0.8))
                withAnimation(.smooth(duration: 0.5)) { if lit == gesture { lit = nil } }
            }
        }
    }

    private var status: String {
        if gestures.isDenied {
            String(localized: "Allow Motion & Fitness for VibePod in Settings › Privacy.")
        } else if gestures.isConnected {
            String(localized: "Ready. Try a gesture: its row lights up.")
        } else {
            String(localized: "Put in compatible AirPods to start.")
        }
    }
}

private struct HeadGestureRow: View {
    let gesture: HeadGesture
    let isLit: Bool
    @AppStorage private var actionRaw: String
    @State private var choosing = false

    init(gesture: HeadGesture, isLit: Bool) {
        self.gesture = gesture
        self.isLit = isLit
        _actionRaw = AppStorage(wrappedValue: HeadGestureAction.none.rawValue, gesture.storageKey)
    }

    private var action: HeadGestureAction { HeadGestureAction(rawValue: actionRaw) ?? .none }

    var body: some View {
        // A plain button, the whole row: the choice opens in a sheet.
        Button {
            guard SettingsSwipe.allowsTaps else { return }
            choosing = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: gesture.systemImage)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(isLit ? AnyShapeStyle(.white) : AnyShapeStyle(.tint))
                    .frame(width: 28, height: 28)
                    .background(.tint.opacity(isLit ? 1 : 0.15), in: .circle)
                    .scaleEffect(isLit ? 1.15 : 1)
                Text(gesture.title)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: 8)
                Text(action.title)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .contentTransition(.opacity)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .frame(minHeight: 48)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $choosing) {
            HeadGestureActionSheet(gesture: gesture, actionRaw: $actionRaw)
        }
    }
}

private struct HeadGestureActionSheet: View {
    let gesture: HeadGesture
    @Binding var actionRaw: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    choice(.none)
                }
                Section {
                    ForEach(HeadGestureAction.allCases.filter { $0 != .none }) { action in
                        choice(action)
                    }
                }
            }
            .navigationTitle(gesture.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(role: .confirm) { dismiss() }
                }
            }
        }
        // Opaque, like a settings page; only the confirm button is tinted.
        .presentationBackground(Color(uiColor: .systemGroupedBackground))
        .presentationDetents([.medium, .large])
        .sensoryFeedback(.selection, trigger: actionRaw)
    }

    private func choice(_ action: HeadGestureAction) -> some View {
        Button {
            actionRaw = action.rawValue
            Task {
                try? await Task.sleep(for: .seconds(0.25))
                dismiss()
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: action.systemImage)
                    .foregroundStyle(.primary)
                    .frame(width: 28)
                Text(action.title)
                    .foregroundStyle(.primary)
                Spacer()
                if actionRaw == action.rawValue {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                }
            }
            .contentShape(.rect)
        }
    }
}

private struct WorkoutsCard: View {
    @AppStorage(WorkoutListening.enabledKey) private var isEnabled = false
    @State private var open = false
    @State private var isWorking = false
    @State private var sessions = WorkoutListening.storedSessions().count

    var body: some View {
        CollapsibleGlassCard(title: "Workouts", systemImage: "figure.run", expanded: $open) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: Binding(get: { isEnabled }, set: setEnabled)) {
                    HStack(spacing: 8) {
                        Text("Sync with Apple Health")
                        if isWorking { ProgressView().controlSize(.small) }
                    }
                }
                .disabled(isWorking)
                Text("Reads your workouts (times and kinds only) to find the music you play while you exercise: in Stats, in a Workout Autolist and for the assistant. Nothing leaves your iPhone.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if isEnabled {
                    Text(sessions == 0
                         ? String(localized: "No workouts found yet. If you have some, allow VibePod to read them in Health › Sharing.")
                         : String(localized: "\(sessions) workouts found."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }
            }
        }
        // Apple Fitness's green, whatever the app's tint: icon and toggle.
        .tint(.fitnessGreen)
        .onReceive(NotificationCenter.default.publisher(for: WorkoutListening.didChange)) { _ in
            withAnimation(.smooth) { sessions = WorkoutListening.storedSessions().count }
        }
    }

    private func setEnabled(_ on: Bool) {
        guard SettingsSwipe.allowsTaps else { return }
        if on {
            isWorking = true
            Task {
                _ = await WorkoutListening.enable()
                withAnimation(.smooth) {
                    sessions = WorkoutListening.storedSessions().count
                    isWorking = false
                }
            }
        } else {
            withAnimation(.smooth) { WorkoutListening.disable() }
        }
    }
}
