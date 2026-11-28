import SwiftUI
import Intents

@main
struct LRCplayerApp: App {
    @UIApplicationDelegateAdaptor private var appDelegate: AppDelegate

    init() {
        MacApp.useBlackBackground()
        AppTint.adoptInfusedOnce()
        AppAppearance.startApplying()
        MusicHapticsService.shared.start()
        DiscordPresence.shared.refresh()
        HeadGestures.shared.refresh()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .commands { VibePodCommands() }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // No Siri on the Mac app (it isn't entitled to it).
        if !MacApp.isActive, INPreferences.siriAuthorizationStatus() == .notDetermined {
            INPreferences.requestSiriAuthorization { _ in }
        }
        // Silent pushes from iCloud when another device changes something.
        application.registerForRemoteNotifications()
        return true
    }

    /// Siri's "Play … in VibePod".
    func application(_ application: UIApplication, handlerFor intent: INIntent) -> Any? {
        intent is INPlayMediaIntent ? SiriMediaHandler.shared : nil
    }

    /// Portrait on a phone-sized screen, like Music, except in the full
    /// screen player; any way up on a screen big enough to be held either
    /// way (an unfolded iPhone Duo, an iPad).
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        guard !OrientationLock.isPortrait, let screen = window?.windowScene?.screen else { return .portrait }
        if LargeScreen.contains(screen.bounds.size) { return .all }
        if OrientationLock.isVideoFullScreen { return .allButUpsideDown }
        return OrientationLock.isPlayerOpen && OrientationLock.playerRotates ? .allButUpsideDown : .portrait
    }
}

enum OrientationLock {
    /// The games are laid out for a screen held upright.
    @MainActor static var isPortrait = false {
        didSet { if isPortrait != oldValue { refresh() } }
    }

    /// The full screen player turns sideways on a phone too.
    @MainActor static var isPlayerOpen = false {
        didSet { if isPlayerOpen != oldValue { refresh() } }
    }

    /// A music video full screen turns with the phone, whatever the setting.
    @MainActor static var isVideoFullScreen = false {
        didSet { if isVideoFullScreen != oldValue { refresh() } }
    }

    static let playerRotationKey = "playerRotatesOnPhone"

    /// The Settings switch for the player turning sideways on a phone (on
    /// by default). Larger screens always turn.
    static var playerRotates: Bool {
        UserDefaults.standard.object(forKey: playerRotationKey) as? Bool ?? true
    }

    /// Asks UIKit to read the supported orientations again (after a fold, an
    /// unfold, a lock or the player closing), turning the app upright if it
    /// has to be.
    @MainActor static func refresh() {
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            // The player has a window of its own above the app's.
            for window in scene.windows {
                var controller = window.rootViewController
                while let presented = controller?.presentedViewController { controller = presented }
                controller?.setNeedsUpdateOfSupportedInterfaceOrientations()
            }
            let mustStandUp = isPortrait || !(isVideoFullScreen || (isPlayerOpen && playerRotates) || LargeScreen.contains(scene.screen.bounds.size))
            if mustStandUp, scene.effectiveGeometry.interfaceOrientation.isLandscape {
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
            }
        }
    }
}

extension View {
    /// Keeps the app upright while this view is on screen.
    func portraitLocked() -> some View {
        onAppear { OrientationLock.isPortrait = true }
            .onDisappear { OrientationLock.isPortrait = false }
    }
}

enum LargeScreen {
    /// The narrowest side a screen needs before it turns sideways: the
    /// iPhone Duo's inner display and every iPad pass, its cover display and
    /// the largest single-screen iPhones don't.
    static let minimumSide: CGFloat = 600

    static func contains(_ size: CGSize) -> Bool {
        min(size.width, size.height) >= minimumSide
    }
}
