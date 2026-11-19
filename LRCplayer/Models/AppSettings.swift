import SwiftUI
import UIKit
import Combine

enum AppTint: String, CaseIterable, Identifiable {
    /// Trial: follows the playing song's artwork (see `InfusedTint`).
    case infused
    case red
    case orange
    case yellow
    case green
    case blue
    case purple
    case gray

    static let storageKey = "appTintColor"
    static let didChangeNotification = Notification.Name("appTintDidChange")

    var id: String { rawValue }

    /// The color's name, for VoiceOver.
    var displayName: String {
        switch self {
        case .infused: String(localized: "Infused")
        case .red: String(localized: "Red")
        case .orange: String(localized: "Orange")
        case .yellow: String(localized: "Yellow")
        case .green: String(localized: "Green")
        case .blue: String(localized: "Blue")
        case .purple: String(localized: "Purple")
        case .gray: String(localized: "Gray")
        }
    }

    var uiColor: UIColor {
        switch self {
        case .infused:
            return InfusedTint.uiColor
        default:
            // Soft shades: bright on dark, deeper on light where the bright
            // ones wash out on white.
            let shades = softShades
            return UIColor { traits in
                let c = traits.userInterfaceStyle == .light ? shades.deep : shades.bright
                return UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
            }
        }
    }

    private var softShades: (bright: (CGFloat, CGFloat, CGFloat), deep: (CGFloat, CGFloat, CGFloat)) {
        switch self {
        case .infused, .gray: ((0.76, 0.77, 0.81), (0.45, 0.46, 0.51))
        case .red: ((1.0, 0.45, 0.42), (0.90, 0.22, 0.20))
        case .orange: ((1.0, 0.62, 0.38), (0.90, 0.42, 0.12))
        case .yellow: ((0.98, 0.84, 0.40), (0.76, 0.56, 0.0))
        case .green: ((0.42, 0.88, 0.62), (0.0, 0.60, 0.38))
        case .blue: ((0.40, 0.68, 1.0), (0.0, 0.46, 0.92))
        case .purple: ((0.72, 0.60, 1.0), (0.44, 0.32, 0.88))
        }
    }

    var color: Color { Color(uiColor: uiColor) }

    /// The settings swatch: always the soft dark-mode shade, which reads
    /// better as a preview than the deeper light-mode one.
    var swatchColor: Color {
        let c = softShades.bright
        return Color(red: c.0, green: c.1, blue: c.2)
    }

    static var current: AppTint {
        AppTint(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .infused
    }

    /// Infused became the default: everyone starts on it once, after the
    /// update, then picks whatever they like.
    static func adoptInfusedOnce() {
        let defaults = UserDefaults.standard
        let key = "appTintAdoptedInfused"
        guard !defaults.bool(forKey: key) else { return }
        defaults.set(true, forKey: key)
        defaults.set(AppTint.infused.rawValue, forKey: storageKey)
    }
}

/// A window that keeps its own style whatever the app's mode.
protocol FixedAppearanceWindow: UIWindow {}

/// Light, dark (the default) or following the system.
enum AppAppearance: String, CaseIterable, Identifiable {
    case light
    case dark
    case system

    static let storageKey = "appAppearance"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .light: String(localized: "Light")
        case .dark: String(localized: "Dark")
        case .system: String(localized: "System")
        }
    }

    var symbol: String {
        switch self {
        case .light: "sun.max.fill"
        case .dark: "moon.fill"
        case .system: "circle.lefthalf.filled"
        }
    }

    var style: UIUserInterfaceStyle {
        switch self {
        case .light: .light
        case .dark: .dark
        case .system: .unspecified
        }
    }

    static var current: AppAppearance {
        AppAppearance(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .dark
    }

    /// Set on the windows rather than through SwiftUI's
    /// `preferredColorScheme`, which doesn't go back to the system's style
    /// once it has forced one. Windows opened later get it as they appear;
    /// the root view applies it at launch and whenever the setting changes.
    @MainActor static func startApplying() {
        NotificationCenter.default.addObserver(forName: UIWindow.didBecomeVisibleNotification, object: nil, queue: nil) { note in
            let window = note.object as? UIWindow
            MainActor.assumeIsolated {
                guard let window, !(window is FixedAppearanceWindow) else { return }
                window.overrideUserInterfaceStyle = current.style
            }
        }
    }

    /// `animated`: cross-fades to the new style (a style change otherwise
    /// swaps every color in one frame).
    @MainActor static func apply(animated: Bool) {
        let style = current.style
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows where !(window is FixedAppearanceWindow) && window.overrideUserInterfaceStyle != style {
                guard animated else {
                    window.overrideUserInterfaceStyle = style
                    continue
                }
                // A still of the screen as it is, faded out over the new style.
                // (A view transition's "before" image kept the Liquid Glass
                // live: it switched to the new style in the first frame.)
                let still = window.screen.snapshotView(afterScreenUpdates: false)
                still.frame = window.bounds
                still.isUserInteractionEnabled = false
                window.addSubview(still)
                window.overrideUserInterfaceStyle = style
                UIView.animate(withDuration: 0.4, delay: 0, options: [.curveEaseInOut, .allowUserInteraction]) {
                    still.alpha = 0
                } completion: { _ in
                    still.removeFromSuperview()
                }
            }
        }
    }
}

@propertyWrapper
struct AppTintSelection: DynamicProperty {
    @AppStorage(AppTint.storageKey) private var rawValue = AppTint.infused.rawValue

    var wrappedValue: AppTint {
        AppTint(rawValue: rawValue) ?? .infused
    }
}

enum HiddenSettings {
    private static let unlockKey = "hiddenSettingsUnlocked"
    private static let hideArtworkKey = "hideNowPlayingArtwork"
    static let didChangeNotification = Notification.Name("hiddenSettingsDidChange")

    private static let unlockCode: String = {
        guard let data = Data(base64Encoded: "MjQ0MzQ0") else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }()

    static var isUnlocked: Bool {
        get { UserDefaults.standard.bool(forKey: unlockKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: unlockKey)
            NotificationCenter.default.post(name: didChangeNotification, object: nil)
        }
    }

    static var hideNowPlayingArtwork: Bool {
        get { UserDefaults.standard.bool(forKey: hideArtworkKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: hideArtworkKey)
            NotificationCenter.default.post(name: didChangeNotification, object: nil)
        }
    }

    /// Features not stable enough for everyone, shown only while hidden
    /// settings are unlocked.
    static let alphaFeaturesKey = "alphaFeatures"
    static var alphaFeatures: Bool {
        get { isUnlocked && UserDefaults.standard.bool(forKey: alphaFeaturesKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: alphaFeaturesKey)
            NotificationCenter.default.post(name: didChangeNotification, object: nil)
        }
    }

    /// Why a feature needing the separation model is greyed out.
    static let needsModelNote = String(localized: "Needs the on-device model: Settings › Exclusive Features › Sing Along")

    static func matchesUnlockCode(_ text: String) -> Bool {
        guard !unlockCode.isEmpty else { return false }
        return text == unlockCode
    }
}

struct RecentlyPlayedEntry: Codable, Identifiable, Equatable {
    enum Kind: String, Codable {
        case album
        case playlist
    }

    let kind: Kind
    let id: String
    let date: Date
}

@MainActor
final class RecentPlayedStore: ObservableObject {
    static let shared = RecentPlayedStore()

    private static let storageKey = "recentlyPlayedEntries"

    @Published private(set) var entries: [RecentlyPlayedEntry] = []

    private init() {
        load()
    }

    func record(albumArtist: String, albumName: String) {
        guard !albumName.isEmpty else { return }
        upsert(kind: .album, id: "\(albumArtist)|||\(albumName)")
    }

    func record(playlistID: UUID) {
        upsert(kind: .playlist, id: playlistID.uuidString)
    }

    func remove(entry: RecentlyPlayedEntry) {
        entries.removeAll { $0 == entry }
        save()
    }

    private func upsert(kind: RecentlyPlayedEntry.Kind, id: String) {
        var updated = entries.filter { !($0.kind == kind && $0.id == id) }
        updated.insert(RecentlyPlayedEntry(kind: kind, id: id, date: Date()), at: 0)
        entries = Array(updated.prefix(40))
        save()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([RecentlyPlayedEntry].self, from: data) else { return }
        entries = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}

enum HomeLibrarySortMode: String, CaseIterable {
    case recentlyAdded
    case oldestToNewest
    case newestToOldest
    case title
    case artist

    var title: String {
        switch self {
        case .recentlyAdded: return String(localized: "Recently Added")
        case .oldestToNewest: return String(localized: "Oldest to Newest")
        case .newestToOldest: return String(localized: "Newest to Oldest")
        case .title: return String(localized: "Title")
        case .artist: return String(localized: "Artist")
        }
    }

    var icon: String {
        switch self {
        case .recentlyAdded: return "clock"
        case .oldestToNewest: return "arrow.up"
        case .newestToOldest: return "arrow.down"
        case .title: return "textformat.abc"
        case .artist: return "music.mic"
        }
    }
}

/// The "Infused" accent: the playing song's artwork hue, soft on dark and
/// deeper on light like the fixed shades. Changes glide (SwiftUI animates the
/// published color; UIKit bars get a cross-fade from their observers).
@MainActor
final class InfusedTint: ObservableObject {
    static let shared = InfusedTint()

    /// Read by `AppTint.uiColor` from anywhere; written on the main actor.
    nonisolated(unsafe) private(set) static var uiColor: UIColor = AppTint.gray.uiColor

    @Published private(set) var color: Color = Color(uiColor: AppTint.gray.uiColor)
    private var cancellable: AnyCancellable?
    private var sourceKey: String?

    private init() {
        cancellable = MusicPlayerService.shared.$currentSong
            .map { $0?.artworkSource }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] source in
                MainActor.assumeIsolated { self?.update(source) }
            }
    }

    private func update(_ source: ArtworkSource?) {
        let key = source?.cacheKey
        guard key != sourceKey else { return }
        sourceKey = key
        let tint = Self.tint(from: Song.albumBackgroundUIColor(for: source), hasArtwork: source != nil)
        Self.uiColor = tint
        withAnimation(.smooth(duration: 0.8)) { color = Color(uiColor: tint) }
        if AppTint.current == .infused {
            NotificationCenter.default.post(name: AppTint.didChangeNotification, object: AppTint.infused)
        }
    }

    /// Nonisolated: SwiftUI resolves the dynamic color off the main thread
    /// while rendering, so the provider must not inherit the main actor.
    nonisolated private static func tint(from page: UIColor, hasArtwork: Bool) -> UIColor {
        var hue = CGFloat(0), saturation = CGFloat(0), brightness = CGFloat(0), alpha = CGFloat(0)
        page.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        // Gray, black and white covers: a neutral accent.
        guard hasArtwork, saturation >= 0.12 else { return AppTint.gray.uiColor }
        let light = UIColor(hue: hue, saturation: 0.72, brightness: 0.74, alpha: 1)
        let dark = UIColor(hue: hue, saturation: 0.42, brightness: 1, alpha: 1)
        return UIColor { @Sendable traits in
            traits.userInterfaceStyle == .light ? light : dark
        }
    }
}

extension AppTint {
    /// Games keep their tile's green when the accent is Infused.
    static var gamesColor: Color { current == .infused ? .gamesTint : current.color }
}

extension View {
    /// Settings pages take their tile's color when the accent is Infused.
    @ViewBuilder
    func settingsPageTint(_ color: Color?) -> some View {
        if let color, AppTint.current == .infused { tint(color) } else { self }
    }
}
