import UIKit
import UIKit.UIGestureRecognizerSubclass
import AVFoundation
import Combine
import SwiftUI
import WebKit
import Security

/// The current song's motion artwork, looping silently behind the player.
/// Apple's videos are 3:4 at most: upright, the video is shown whole across
/// the top, uncropped, and melts into a blurred copy of itself that fills
/// the rest of the screen. Shades at the top and bottom keep the status bar
/// and controls readable on light videos; under the lyrics it dims.
final class MotionArtworkView: UIView {
    private struct Slot {
        let player: AVQueuePlayer
        let looper: AVPlayerLooper
        let layer: AVPlayerLayer
        /// The same video, filling the screen under the blur.
        let fill: AVPlayerLayer
        let video: MotionArtworkVideo
        var readiness: NSKeyValueObservation?
    }

    /// Everything below, faded out as one under the lyrics when the
    /// classic background is preferred there.
    private let content = UIView()
    private let fillContainer = UIView()
    private let fillBlur = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
    private let videoContainer = UIView()
    private let videoMask = CAGradientLayer()
    private let shadeView = UIView()
    private let shade = CAGradientLayer()
    private let dimView = UIView()
    /// Under the lyrics the video blurs as well as darkens, like Music's.
    private let blurView = UIVisualEffectView(effect: nil)
    private var slot: Slot?
    /// Full-Screen Artwork without a video: the cover in the video's place.
    private let stillView = UIImageView()
    private let stillFill = UIImageView()
    private var showsStill: Bool { slot == nil && stillView.image != nil }
    /// The scene's turn, known as the rotation starts rather than once
    /// the player has laid itself out again.
    private var geometryObservation: NSKeyValueObservation?
    private var cancellables = Set<AnyCancellable>()
    private let state = MotionArtworkState.shared

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        clipsToBounds = true
        addSubview(content)
        content.addSubview(fillContainer)
        fillBlur.alpha = 0
        content.addSubview(fillBlur)
        content.addSubview(videoContainer)
        for view in [stillView, stillFill] {
            view.contentMode = .scaleAspectFill
            view.clipsToBounds = true
            view.alpha = 0
        }
        fillContainer.addSubview(stillFill)
        videoContainer.addSubview(stillView)
        videoMask.colors = [UIColor.black.cgColor, UIColor.black.cgColor, UIColor.clear.cgColor]
        videoMask.locations = [0, 0.72, 1]
        // Status bar at the top, title and controls in the lower half.
        shade.colors = [0.32, 0, 0, 0.3, 0.6].map { UIColor.black.withAlphaComponent($0).cgColor }
        shade.locations = [0, 0.16, 0.45, 0.72, 1]
        shade.opacity = 0
        shadeView.layer.addSublayer(shade)
        content.addSubview(shadeView)
        dimView.backgroundColor = .black
        dimView.alpha = 0
        content.addSubview(blurView)
        content.addSubview(dimView)

        state.$video.removeDuplicates()
            .sink { [weak self] video in self?.show(video) }
            .store(in: &cancellables)
        state.$still.removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] image in self?.showStill(image) }
            .store(in: &cancellables)
        // `@Published` sends before the property changes: read it after.
        state.$isPlaying.combineLatest(state.$isDimmed).removeDuplicates { $0 == $1 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updatePlayback() }
            .store(in: &cancellables)
        // Landscape keeps the classic background: the video fades out.
        state.$isLandscape.removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] landscape in
                guard let self else { return }
                UIView.animate(withDuration: 0.3) { self.alpha = landscape ? 0 : 1 }
                self.updatePlayback()
            }
            .store(in: &cancellables)
        state.$isDimmed.removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateDim(animated: true) }
            .store(in: &cancellables)
        // The device turns a moment before the interface does: upright
        // again, the video starts coming back right away.
        NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)
            .sink { [weak self] _ in
                guard let self, self.window != nil, UIDevice.current.orientation == .portrait else { return }
                if self.state.isLandscape { self.state.isLandscape = false }
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in self?.slot?.player.pause() }
            .store(in: &cancellables)
        // Back from the lock screen the video can stay on its last frame:
        // it's started again from where it was.
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.resumeAfterBackground() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updatePlayback()
                self?.updateDim(animated: true)
            }
            .store(in: &cancellables)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:)") }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Laid out at the new size as the rotation starts: the video comes
        // back with the cover gone, not after.
        if bounds.width > 0, (bounds.width > bounds.height) != state.isLandscape {
            let landscape = bounds.width > bounds.height
            DispatchQueue.main.async { [state] in
                if state.isLandscape != landscape { state.isLandscape = landscape }
            }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        content.frame = bounds
        dimView.frame = bounds
        blurView.frame = bounds
        fillContainer.frame = bounds
        fillBlur.frame = bounds
        shadeView.frame = bounds
        shade.frame = bounds
        slot?.fill.frame = bounds
        // Whole across the width; where that's taller than the screen (a
        // wide one), it covers it instead.
        let aspect = max(slot?.video.aspect ?? (stillView.image != nil ? 1 : 0.75), 0.3)
        let height = bounds.width / aspect
        // The still sits under the status bar, melting into the blur above.
        let top = showsStill ? (window?.safeAreaInsets.top ?? 0) : 0
        if showsStill {
            // Long eased fades both ways: no visible edge against the blur.
            let ease: (Double) -> Double = { $0 * $0 * (3 - 2 * $0) }
            let steps = (0...8).map { Double($0) / 8 }
            let top = steps.map { (location: 0.26 * $0, alpha: ease($0)) }
            let bottom = steps.map { (location: 0.5 + 0.5 * $0, alpha: ease(1 - $0)) }
            videoMask.colors = (top + bottom).map { UIColor.black.withAlphaComponent($0.alpha).cgColor }
            videoMask.locations = (top + bottom).map { NSNumber(value: $0.location) }
        } else {
            videoMask.colors = [UIColor.black.cgColor, UIColor.black.cgColor, UIColor.clear.cgColor]
            videoMask.locations = [0, 0.72, 1]
        }
        if height + top < bounds.height - 1 {
            videoContainer.frame = CGRect(x: 0, y: top, width: bounds.width, height: height)
            videoMask.frame = videoContainer.bounds
            videoContainer.layer.mask = videoMask
        } else {
            videoContainer.frame = bounds
            videoContainer.layer.mask = nil
        }
        slot?.layer.frame = videoContainer.bounds
        stillView.frame = videoContainer.bounds
        stillFill.frame = bounds
        CATransaction.commit()
        updateDim(animated: true)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        geometryObservation = window?.windowScene?.observe(\.effectiveGeometry, options: [.initial, .new]) { @Sendable [weak self] scene, _ in
            Task { @MainActor in
                guard let self else { return }
                let landscape = scene.effectiveGeometry.interfaceOrientation.isLandscape
                if landscape != self.state.isLandscape { self.state.isLandscape = landscape }
            }
        }
        updatePlayback()
    }

    private func showStill(_ image: UIImage?) {
        if let image {
            stillView.image = image
            stillFill.image = image
        }
        updateStillAlpha(clearing: image == nil)
        setNeedsLayout()
        layoutIfNeeded()
    }

    /// The still shows only while no video does.
    private func updateStillAlpha(clearing: Bool = false) {
        let alpha: CGFloat = slot == nil && !clearing && stillView.image != nil ? 1 : 0
        UIView.animate(withDuration: 0.4, delay: 0, options: [.beginFromCurrentState, .curveEaseInOut]) {
            self.stillView.alpha = alpha
            self.stillFill.alpha = alpha
        } completion: { _ in
            if clearing, self.state.still == nil {
                self.stillView.image = nil
                self.stillFill.image = nil
                self.updateDim(animated: true)
            }
        }
        updateDim(animated: true)
    }

    private func show(_ video: MotionArtworkVideo?) {
        guard video != slot?.video else { return }
        if let old = slot {
            slot = nil
            old.readiness?.invalidate()
            CATransaction.begin()
            if video == nil {
                // Nothing replaces it: no lingering fade over the next cover.
                CATransaction.setDisableActions(true)
                for layer in [old.layer, old.fill] {
                    layer.removeAllAnimations()
                    layer.opacity = 0
                    layer.removeFromSuperlayer()
                }
                old.player.pause()
                CATransaction.commit()
                updateStillAlpha(); updateDim(animated: true)
                return
            }
            CATransaction.setCompletionBlock {
                old.player.pause()
                old.layer.removeFromSuperlayer()
                old.fill.removeFromSuperlayer()
            }
            for layer in [old.layer, old.fill] {
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = layer.presentation()?.opacity ?? layer.opacity
                fade.toValue = 0
                fade.duration = 0.4
                layer.add(fade, forKey: "fade")
                layer.opacity = 0
            }
            CATransaction.commit()
        }
        guard let video else { updateStillAlpha(); updateDim(animated: true); return }

        let item = AVPlayerItem(url: video.url)
        // No more pixels than the screen shows.
        let scale = window?.screen.scale ?? 3
        item.preferredMaximumResolution = CGSize(width: max(bounds.width, bounds.height) * scale, height: max(bounds.width, bounds.height) * scale)
        let player = AVQueuePlayer()
        player.isMuted = true
        player.allowsExternalPlayback = false
        player.preventsDisplaySleepDuringVideoPlayback = false
        player.audiovisualBackgroundPlaybackPolicy = .pauses
        let looper = AVPlayerLooper(player: player, templateItem: item)
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspectFill
        layer.opacity = 0
        videoContainer.layer.addSublayer(layer)
        let fill = AVPlayerLayer(player: player)
        fill.videoGravity = .resizeAspectFill
        fill.opacity = 0
        fillContainer.layer.addSublayer(fill)

        var slot = Slot(player: player, looper: looper, layer: layer, fill: fill, video: video)
        let url = video.url
        slot.readiness = layer.observe(\.isReadyForDisplay, options: [.new]) { @Sendable [weak self] _, _ in
            Task { @MainActor in
                guard let self, let slot = self.slot, slot.video.url == url,
                      slot.layer.isReadyForDisplay, slot.layer.opacity == 0 else { return }
                for layer in [slot.layer, slot.fill] {
                    let fade = CABasicAnimation(keyPath: "opacity")
                    fade.fromValue = 0
                    fade.toValue = 1
                    fade.duration = 0.6
                    fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    layer.add(fade, forKey: "fade")
                    layer.opacity = 1
                }
                self.updateDim(animated: true)
                self.state.noteReady(true, for: url)
            }
        }
        self.slot = slot
        updateStillAlpha()
        setNeedsLayout()
        layoutIfNeeded()
        updatePlayback()
    }

    /// Plays along with the music (or on through a pause, the default),
    /// only while on screen.
    private func updatePlayback() {
        guard let player = slot?.player else { return }
        let active = window != nil && (state.isPlaying || MotionArtworkService.keepsPlaying)
            && !state.isLandscape && !showsClassic && UIApplication.shared.applicationState != .background
        if active {
            if player.timeControlStatus == .paused { player.play() }
        } else {
            player.pause()
        }
    }

    private func resumeAfterBackground() {
        guard let slot else { return }
        // Not unhooking the layers: that blanks them for a frame. A nudge
        // to the current time unsticks a looper frozen mid-item.
        slot.player.seek(to: slot.player.currentTime(), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in self?.updatePlayback() }
        }
    }

    /// The thinnest dark material: blurred, barely tinted.
    private func setBlurred(_ blurred: Bool, animated: Bool) {
        guard (blurView.effect != nil) != blurred else { return }
        let effect = blurred ? UIBlurEffect(style: .systemUltraThinMaterialDark) : nil
        guard animated else { blurView.effect = effect; return }
        UIView.animate(withDuration: 0.4, delay: 0, options: [.beginFromCurrentState, .curveEaseInOut]) {
            self.blurView.effect = effect
        }
    }

    /// The lyrics are open and the classic background is preferred there.
    private var showsClassic: Bool {
        state.isDimmed && MotionArtworkService.classicUnderLyrics
    }

    private func updateDim(animated: Bool) {
        // The video fades away like the blur comes in, uncovering the
        // classic colors underneath.
        let contentAlpha: CGFloat = showsClassic ? 0 : 1
        if content.alpha != contentAlpha {
            if animated {
                UIView.animate(withDuration: 0.4, delay: 0, options: [.beginFromCurrentState, .curveEaseInOut]) {
                    self.content.alpha = contentAlpha
                }
            } else {
                content.alpha = contentAlpha
            }
        }
        // Under the lyrics, or filling a wide screen behind the controls;
        // only over a video actually showing, never over the plain colors.
        let showing = slot.map { $0.layer.opacity > 0 } ?? (stillView.image != nil && state.still != nil)
        let alpha: CGFloat = showing && state.isDimmed ? 0.3 : 0
        setBlurred(showing && state.isDimmed, animated: animated)
        let shadeOpacity: Float = showing ? 1 : 0
        guard dimView.alpha != alpha || shade.opacity != shadeOpacity else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(0.5)
        shade.opacity = shadeOpacity
        CATransaction.commit()
        let fillBlurAlpha: CGFloat = showing ? 1 : 0
        if fillBlur.alpha != fillBlurAlpha {
            if animated {
                UIView.animate(withDuration: 0.5) { self.fillBlur.alpha = fillBlurAlpha }
            } else {
                fillBlur.alpha = fillBlurAlpha
            }
        }
        guard animated else { dimView.alpha = alpha; return }
        UIView.animate(withDuration: 0.35, delay: 0, options: [.beginFromCurrentState, .curveEaseInOut]) {
            self.dimView.alpha = alpha
        }
    }
}

// MARK: - Music Video (YouTube)

/// The Extras feature: the song's YouTube music video in place of its
/// cover, muted, in time with the song. Searched with the user's own
/// YouTube Data API key, kept in the Keychain on this device only.
/// When a song's video shows without a tap on the cover.
enum MusicVideoAutoMode: String, CaseIterable {
    /// Always the cover first: a tap shows the video.
    case off
    /// Songs that already have their video show it at once.
    case associated
    /// And the full screen player looks one up for every song.
    case always

    static let key = "musicVideoAutoMode"
    static var current: MusicVideoAutoMode {
        UserDefaults.standard.string(forKey: key).flatMap(MusicVideoAutoMode.init) ?? .off
    }
}

enum MusicVideoFeature {
    static let enabledKey = "musicVideoEnabled"
    static let didChangeNotification = Notification.Name("MusicVideoFeatureDidChange")

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
    static var isAvailable: Bool { isEnabled && !searchKeys.isEmpty }

    private static let service = "com.fares.lrc.player.youtube"
    private static let account = "youtube-api-key"
    private static let backupAccount = "youtube-api-key-2"
    /// The day (in YouTube's time zone) the main key ran out of searches.
    private static let spentDayKey = "youtubeMainKeySpentDay"

    static var apiKey: String? {
        get { read(account) }
        set { write(newValue, to: account) }
    }

    /// Used once the main key has run out of today's searches.
    static var backupAPIKey: String? {
        get { read(backupAccount) }
        set { write(newValue, to: backupAccount) }
    }

    /// The keys to try, in order: the main one first, unless it already ran
    /// out today (quotas reset at midnight Pacific time).
    static var searchKeys: [String] {
        let main = apiKey, backup = backupAPIKey
        let spent = UserDefaults.standard.string(forKey: spentDayKey) == today
        return (spent ? [backup, main] : [main, backup]).compactMap { $0 }
    }

    static func markSpent(_ key: String) {
        guard key == apiKey else { return }
        UserDefaults.standard.set(today, forKey: spentDayKey)
    }

    private static var today: String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles") ?? .current
        let parts = calendar.dateComponents([.year, .month, .day], from: Date())
        return "\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)"
    }

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private static func read(_ account: String) -> String? {
        var request = query(account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
        return key
    }

    private static func write(_ value: String?, to account: String) {
        SecItemDelete(query(account) as CFDictionary)
        if let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            var item = query(account)
            item[kSecValueData as String] = Data(value.utf8)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(item as CFDictionary, nil)
        }
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }
}

/// A YouTube video that could be the song's.
struct MusicVideoCandidate: Codable, Hashable, Identifiable {
    let id: String
    let title: String
    let channel: String
    let duration: TimeInterval
    /// Width over height of the player YouTube gives it.
    let aspect: Double
    let views: Int
    var score: Double
    /// The year it was put online (older saved choices don't have it).
    var year: Int?
    /// Its owner keeps it on YouTube (error 101/150 here): not tried again
    /// by itself.
    var isBlocked: Bool?

    var thumbnail: URL? { URL(string: "https://i.ytimg.com/vi/\(id)/mqdefault.jpg") }
}

/// What was found and chosen for a song.
struct MusicVideoChoice: Codable {
    var isOn = false
    var candidates: [MusicVideoCandidate]?
    var videoID: String?
    /// Seconds into the video at the song's start; nil: guessed.
    var offset: TimeInterval?
    /// The clip's extra length comes after the song (an ending scene), not
    /// before it.
    var hasOutro: Bool?
    /// Picked by hand, or already played well: never swapped for another
    /// by itself.
    var isKept: Bool?
}

@MainActor
enum MusicVideoStore {
    private static var fileURL: URL {
        URL.applicationSupportDirectory.appending(path: "MusicVideos/choices.json")
    }

    private static var cache: [UUID: MusicVideoChoice] = {
        (try? Data(contentsOf: fileURL)).flatMap { try? JSONDecoder().decode([UUID: MusicVideoChoice].self, from: $0) } ?? [:]
    }()

    static func choice(for id: UUID) -> MusicVideoChoice {
        cache[id] ?? MusicVideoChoice()
    }

    /// Serial: the last choice always lands last.
    private static let writeQueue = DispatchQueue(label: "MusicVideoStore.write", qos: .utility)

    static func setChoice(_ choice: MusicVideoChoice, for id: UUID) {
        cache[id] = choice
        // Encoded and written off the main thread: this runs as the video
        // morphs in and on every nudge in the picker.
        let snapshot = cache, url = fileURL
        writeQueue.async {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
        }
    }

    static func isOn(for song: Song?) -> Bool {
        guard let song, MusicVideoFeature.isAvailable else { return false }
        return choice(for: song.id).isOn
    }

    /// Where in the video the song starts. Only the lengths can tell
    /// (the clip's sound can't be heard here): a clip much longer than the
    /// song most often opens on a scene before the music; a few seconds
    /// more are an ending card.
    static func guessedOffset(video: TimeInterval, song: TimeInterval) -> TimeInterval {
        guard video > 0, song > 0 else { return 0 }
        let extra = video - song
        // A few seconds: an ending card (or nothing).
        guard extra >= 6 else { return 0 }
        // Longer: mostly an intro before the music, a little end after.
        let ending = min(5, extra * 0.15)
        return min(240, ((extra - ending) * 2).rounded() / 2)
    }
}

enum MusicVideoError: LocalizedError {
    /// `busy`: too many searches this minute (the next key may still have some).
    case invalidKey, quota, busy, server(String), network(String)

    var errorDescription: String? {
        switch self {
        case .invalidKey: String(localized: "YouTube didn't accept the API key. Check it in Settings › Extras › YouTube Videos.")
        case .quota: String(localized: "Today's YouTube searches are used up. Try again tomorrow, or add a backup key in Settings › Extras › YouTube Videos.")
        case .busy: String(localized: "YouTube is getting too many searches. Try again in a minute.")
        case .server(let message): String(localized: "YouTube couldn't search: \(message)")
        case .network(let message): message
        }
    }
}

/// The YouTube Data API: a search (100 of the 10,000 daily units), then
/// the videos' lengths and shapes (1 unit).
enum YouTubeSearch {
    static func query(for song: Song) -> String {
        searchable("\(song.artist) \(cleanTitle(song.title))")
    }

    /// YouTube's search finds nothing with symbols in the words ("♫ Song",
    /// emoji), even when the video's title has them: words only.
    static func searchable(_ text: String) -> String {
        text.replacingOccurrences(of: #"[\p{So}\p{Sk}\p{Cs}\x{FE0F}\x{200D}]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    static func candidates(for song: Song, query: String? = nil, key: String) async throws -> [MusicVideoCandidate] {
        var search = URLComponents(string: "https://www.googleapis.com/youtube/v3/search")!
        search.queryItems = [
            .init(name: "part", value: "snippet"),
            .init(name: "type", value: "video"),
            .init(name: "maxResults", value: "15"),
            .init(name: "videoEmbeddable", value: "true"),
            .init(name: "fields", value: "items(id/videoId,snippet(title,channelTitle,publishedAt))"),
            .init(name: "q", value: query.map(searchable) ?? Self.query(for: song)),
            .init(name: "key", value: key)
        ]
        struct SearchResponse: Decodable {
            struct Item: Decodable {
                struct ID: Decodable { let videoId: String? }
                struct Snippet: Decodable { let title: String; let channelTitle: String; let publishedAt: String? }
                let id: ID
                let snippet: Snippet
            }
            let items: [Item]
        }
        let found = try JSONDecoder().decode(SearchResponse.self, from: try await get(search.url!))
        let snippets = Dictionary(found.items.compactMap { item in item.id.videoId.map { ($0, item.snippet) } }, uniquingKeysWith: { a, _ in a })
        guard !snippets.isEmpty else { return [] }

        var details = URLComponents(string: "https://www.googleapis.com/youtube/v3/videos")!
        details.queryItems = [
            .init(name: "part", value: "contentDetails,statistics,player,status"),
            .init(name: "maxWidth", value: "1280"),
            .init(name: "fields", value: "items(id,contentDetails/duration,statistics/viewCount,player(embedWidth,embedHeight),status/embeddable)"),
            .init(name: "id", value: found.items.compactMap(\.id.videoId).joined(separator: ",")),
            .init(name: "key", value: key)
        ]
        struct VideosResponse: Decodable {
            struct Item: Decodable {
                struct Content: Decodable { let duration: String }
                struct Stats: Decodable { let viewCount: String? }
                struct Player: Decodable { let embedWidth: Flexible?; let embedHeight: Flexible? }
                struct Status: Decodable { let embeddable: Bool? }
                let id: String
                let contentDetails: Content
                let statistics: Stats?
                let player: Player?
                let status: Status?
            }
            let items: [Item]
        }
        let videos = try JSONDecoder().decode(VideosResponse.self, from: try await get(details.url!)).items
        let order = found.items.compactMap(\.id.videoId)
        let candidates: [MusicVideoCandidate] = videos.compactMap { item in
            guard item.status?.embeddable != false, let snippet = snippets[item.id] else { return nil }
            let width = item.player?.embedWidth?.value ?? 16
            let height = item.player?.embedHeight?.value ?? 9
            var candidate = MusicVideoCandidate(
                id: item.id,
                title: unescape(snippet.title),
                channel: unescape(snippet.channelTitle),
                duration: isoDuration(item.contentDetails.duration),
                aspect: height > 0 ? min(max(width / height, 0.5), 2.5) : 16 / 9,
                views: Int(item.statistics?.viewCount ?? "") ?? 0,
                score: 0,
                year: snippet.publishedAt.flatMap { Int($0.prefix(4)) }
            )
            candidate.score = score(candidate, for: song)
            return candidate
        }
        // Best first; YouTube's own order breaks ties.
        return candidates.sorted {
            $0.score != $1.score ? $0.score > $1.score : (order.firstIndex(of: $0.id) ?? 0) < (order.firstIndex(of: $1.id) ?? 0)
        }
    }

    /// Good enough to play without asking.
    static let acceptedScore = 3.0

    /// A real clip, not a still cover with the audio, a lyric video, a
    /// live take or someone else's version.
    static func score(_ video: MusicVideoCandidate, for song: Song) -> Double {
        let title = normalized(video.title)
        let channel = normalized(video.channel)
        let songTitle = normalized(cleanTitle(song.title))
        let artist = normalized(song.artist.components(separatedBy: CharacterSet(charactersIn: ",&")).first ?? song.artist)
        var score = 0.0

        // "Artist - Topic" channels only carry the album audio on its cover.
        if video.channel.hasSuffix(" - Topic") { return -100 }
        // The song's words in the video's title (punctuation aside: "Hey,
        // Defriender!" is "Song A Day #782: Hey, Defriender").
        let songWords = words(songTitle)
        let titleWords = Set(words(title))
        let found = songWords.isEmpty ? 1 : Double(songWords.filter(titleWords.contains).count) / Double(songWords.count)
        let matches = found >= 0.99
        score += matches ? 3 : (found >= 0.6 ? 0 : -4)
        if !artist.isEmpty, channel.contains(artist) || title.contains(artist) { score += 2 }
        if channel.hasSuffix("vevo") || channel.contains("vevo") { score += 2 }

        let clip = ["official video", "official music video", "clip officiel", "music video", "videoclip", "video oficial", "official mv", " mv", "(official)", "[official]", "clip"]
        if clip.contains(where: title.contains) { score += 4 }
        let notClip = ["lyric", "lyrics", "paroles", "letra", "audio", "visualizer", "visualiser", "karaoke", "cover", "reaction", "live", "concert", "slowed", "sped up", "speed up", "8d", "remix", "instrumental", "nightcore", "1 hour", "loop", "acoustic", "piano", "tutorial", "behind the scenes", "making of", "teaser", "trailer", "shorts"]
        for word in notClip where title.contains(word) && !songTitle.contains(word) {
            score -= 5
        }

        if song.duration > 0, video.duration > 0 {
            let extra = video.duration - song.duration
            if extra < -max(20, song.duration * 0.15) || extra > 300 { score -= 8 }
            score -= abs(extra) / 40
        }
        // Length and year tell takes of the right song apart; they don't
        // make another video right.
        guard found >= 0.6 else {
            if video.views > 0 { score += log10(Double(video.views)) * 0.3 }
            return score
        }
        if song.duration > 0, video.duration > 0, abs(video.duration - song.duration) <= 4 {
            // The same length to a few seconds: most likely this very take.
            score += 1.5
        }
        // The song's year: a video from before is an earlier version (a
        // first take, a demo), one from that year (or the next) its own.
        if song.year > 1900, let year = video.year {
            if year == song.year || year == song.year + 1 {
                score += 2.5
            } else if year < song.year {
                score -= 2.5
            }
        }
        if video.views > 0 { score += log10(Double(video.views)) * 0.3 }
        return score
    }

    /// Its own connection, kept warm between the two requests (and the
    /// next search); a stuck network gives up quickly.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 8
        configuration.httpMaximumConnectionsPerHost = 2
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    private static func get(_ url: URL) async throws -> Data {
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(from: url)
        } catch {
            throw MusicVideoError.network(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            struct Failure: Decodable {
                struct Body: Decodable {
                    struct Reason: Decodable { let reason: String? }
                    let message: String?
                    let errors: [Reason]?
                }
                let error: Body
            }
            let failure = try? JSONDecoder().decode(Failure.self, from: data)
            let reasons = failure?.error.errors?.compactMap(\.reason) ?? []
            let message = failure?.error.message ?? ""
            // A spent key also comes back as 429 "rateLimitExceeded", the
            // day's limit only named in the message.
            let limited = status == 429 || reasons.contains { reason in
                ["quota", "ratelimit", "dailylimit"].contains { reason.lowercased().contains($0) }
            } || message.lowercased().contains("quota exceeded")
            if limited {
                let perMinute = message.lowercased().contains("per minute") || message.lowercased().contains("per 100 seconds")
                throw perMinute ? MusicVideoError.busy : MusicVideoError.quota
            }
            if status == 400 || status == 403, reasons.contains(where: { $0.contains("key") || $0 == "forbidden" || $0 == "accessNotConfigured" }) || status == 400 {
                throw MusicVideoError.invalidKey
            }
            throw MusicVideoError.server(failure?.error.message ?? "\(status)")
        }
        return data
    }

    /// "Song (feat. X) [Remastered]" → "Song".
    static func cleanTitle(_ title: String) -> String {
        var text = title
        for pattern in [#"\s*[\(\[][^\)\]]*[\)\]]"#, #"\s+-\s+.*$"#, #"\s+(feat|ft)\.?\s.*$"#] {
            text = text.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        }
        return text.trimmingCharacters(in: .whitespaces).isEmpty ? title : text.trimmingCharacters(in: .whitespaces)
    }

    static func words(_ text: String) -> [String] {
        text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }

    static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    static func unescape(_ text: String) -> String {
        var result = text
        for (entity, character) in [("&amp;", "&"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&lt;", "<"), ("&gt;", ">")] {
            result = result.replacingOccurrences(of: entity, with: character)
        }
        return result
    }

    /// "PT1H3M5S" → seconds.
    static func isoDuration(_ text: String) -> TimeInterval {
        var total = 0.0, number = ""
        for character in text {
            if character.isNumber || character == "." {
                number.append(character)
            } else {
                let value = Double(number) ?? 0
                switch character {
                case "H": total += value * 3600
                case "M": total += value * 60
                case "S": total += value
                default: break
                }
                number = ""
            }
        }
        return total
    }

    /// Google's APIs send some numbers as strings.
    struct Flexible: Decodable {
        let value: Double
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let number = try? container.decode(Double.self) {
                value = number
            } else {
                value = Double(try container.decode(String.self)) ?? 0
            }
        }
    }

    static func durationText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Plays the chosen video, muted and hidden, kept in time with the song
/// from the player's own clock. It's shown in the cover's place only once
/// it truly plays (no loading, no ad, no YouTube chrome), and gives its
/// colors to the background.
@MainActor
final class MusicVideoPlayer: NSObject, ObservableObject, WKScriptMessageHandler, WKNavigationDelegate {
    static let shared = MusicVideoPlayer()
    static let colorsDidChange = Notification.Name("MusicVideoColorsDidChange")

    /// The song whose video stands in for its cover right now.
    @Published private(set) var shownSongID: UUID?
    /// Width over height of what's shown (black bars left out).
    @Published private(set) var aspect: CGFloat = 16 / 9
    @Published private(set) var isSearching = false
    @Published private(set) var message: String?
    /// Bumped when a song's choice changes (menus follow).
    @Published private(set) var revision = 0
    private(set) var colors: [UIColor]? {
        didSet { NotificationCenter.default.post(name: Self.colorsDidChange, object: nil) }
    }

    private var song: Song?
    private var videoID: String?
    private var offset: TimeInterval = 0

    /// A merged song: each part's own clip, in one page, the second taking
    /// over with the song's transition (a cut, or a fade of the pictures).
    private struct MergeTiming: Equatable {
        var ids: [String]
        /// Where each part starts in its own song.
        var starts: [TimeInterval]
        var offsets: [TimeInterval]
        var durations: [TimeInterval]
        var aspects: [CGFloat]
        var secondAt: TimeInterval
        var overlap: TimeInterval
        var isCut: Bool

        /// How much of the second clip shows, 0 to 1.
        func mix(at time: TimeInterval) -> Double {
            if isCut || overlap < 0.05 { return time >= secondAt ? 1 : 0 }
            let x = min(1, max(0, (time - secondAt) / overlap))
            return x * x * (3 - 2 * x)
        }

        /// Where each clip should be, at this time of the merged song.
        func targets(at time: TimeInterval) -> (TimeInterval, TimeInterval) {
            (time + starts[0] + offsets[0], time - secondAt + starts[1] + offsets[1])
        }

        /// Video time minus song time, for the clip in front.
        func offset(of part: Int) -> TimeInterval {
            starts[part] + offsets[part] - (part == 1 ? secondAt : 0)
        }
    }

    private var mergeTiming: MergeTiming?
    /// The clip in front (0 or 1) while a merged song plays.
    private var leadPart = 0

    private static func merge(of song: Song) -> SongMerge? {
        guard let merge = SongMergeService.shared.merge(for: song.id), merge.parts.count == 2 else { return nil }
        return merge
    }

    /// The songs whose clips play for this one: its two parts when merged.
    func videoSongs(for song: Song) -> [Song] {
        Self.merge(of: song)?.parts.map(\.song) ?? [song]
    }

    /// A part of the merged song playing now.
    private func isPartOfCurrent(_ song: Song) -> Bool {
        guard let current = self.song, current.id != song.id else { return false }
        return videoSongs(for: current).contains { $0.id == song.id }
    }

    /// The clip on YouTube, where it is now (or the song's chosen one).
    func youTubeURL(for song: Song) -> URL? {
        let first = videoSongs(for: song).first ?? song
        let id = song.id == self.song?.id ? (videoID ?? MusicVideoStore.choice(for: first.id).videoID) : MusicVideoStore.choice(for: first.id).videoID
        guard let id else { return nil }
        let time = song.id == self.song?.id ? max(0, Int(MusicPlayerService.shared.preciseCurrentTime + offset)) : 0
        return URL(string: "https://www.youtube.com/watch?v=\(id)" + (time > 0 ? "&t=\(time)s" : ""))
    }
    private var videoDuration: TimeInterval = 0
    /// Width over height of YouTube's player for this video.
    private var embedAspect: CGFloat = 16 / 9
    private var isReady = false
    private var hasPlayed = false
    /// When it first played, and whether it is in step with the song: it
    /// shows once in step, so it doesn't jump to catch up in sight.
    private var firstPlayedAt: Date?
    private var isInSync = false
    private var isAd = false
    private var lastSeek = Date.distantPast
    private var tickTimer: Timer?
    private var colorTimer: Timer?
    private var searchTask: Task<Void, Never>?
    private var messageTask: Task<Void, Never>?
    private var hosts: [ObjectIdentifier: Weak] = [:]
    /// The picture within the video's own frames (black bars burned into
    /// the clip left out), as fractions, and the frames' shape.
    private var content = BarSample.full
    private var nativeAspect: CGFloat?
    private var barSamples: [BarSample] = []
    private var isSamplingBars = false
    /// Chosen in the sheet: a failure isn't covered up by the next result.
    private var pickedByHand = false
    /// Lyrics open: the video lives in the small cover beside the title.
    var isSuppressed = false {
        didSet { if oldValue != isSuppressed { rehost() } }
    }
    /// The full screen player is open (not collapsed into the mini player).
    var isPlayerPresented = false {
        didSet {
            guard oldValue != isPlayerPresented else { return }
            rehost()
            if isPlayerPresented, let song, wantedSongID != song.id, MusicVideoAutoMode.current == .always, autoWants(song) {
                wantedSongID = song.id
                reload()
                MotionArtworkState.shared.refresh(for: song)
            }
        }
    }
    /// The clip's own still, under the video until its first frame plays
    /// (its black bars cut off, like the video's).
    private(set) var thumbnail: UIImage?
    /// The video's latest frame: what a flying copy shows.
    private(set) var lastFrame: UIImage?
    private var thumbnailImage: UIImage? {
        didSet { thumbnail = thumbnailImage.map(picture(of:)) }
    }
    private var lastFrameImage: UIImage? {
        didSet { lastFrame = lastFrameImage.map(picture(of:)) }
    }
    /// What stands for the video when it can't be there itself.
    var still: UIImage? { lastFrame ?? thumbnail }
    static let stateDidChange = Notification.Name("MusicVideoStateDidChange")
    /// The video is truly playing (not loading): only then are its frames
    /// read for colors.
    private var isPlayingNow = false

    private struct Weak { weak var view: MusicVideoHostView? }

    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(appDidEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appWillEnterForeground), name: UIApplication.willEnterForegroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(boost), name: UIDevice.orientationDidChangeNotification, object: nil)
        // Play and pause resize the cover, wherever they come from.
        playingObserver = MusicPlayerService.shared.$isPlaying.removeDuplicates().sink { [weak self] _ in
            MainActor.assumeIsolated { self?.boost() }
        }
    }

    // MARK: Pace

    /// Something may move: the follow loop back to full rate, and a fresh
    /// frame from the page for a move's still.
    @objc func boost() {
        lastMotionAt = CACurrentMediaTime()
        guard followsSlowly else { return }
        followsSlowly = false
        displayLink?.preferredFrameRateRange = .default
        updateFramePace(captureNow: true)
    }

    private func slowDownIfIdle(at now: CFTimeInterval) {
        guard !followsSlowly, now - lastMotionAt > 0.6, let displayLink else { return }
        followsSlowly = true
        displayLink.preferredFrameRateRange = CAFrameRateRange(minimum: 8, maximum: 15, preferred: 15)
        updateFramePace(captureNow: false)
    }

    /// Black bars are still being looked for: frames keep coming fast.
    private var barsSettled: Bool {
        guard let videoID else { return true }
        return MusicVideoBars.saved(for: videoID) != nil || barSamples.count >= 40
    }

    private func updateFramePace(captureNow: Bool) {
        let fast = !followsSlowly || !barsSettled
        guard fast != framesFast || captureNow, let videoFrame, videoID != nil else { return }
        framesFast = fast
        webView.evaluateJavaScript("window.vp_frames && vp_frames(\(fast), \(captureNow && fast)); 0", in: videoFrame, in: .page) { _ in }
    }

    /// Touches anywhere in the windows the video is seen in.
    private func watchTouches(in window: UIWindow?) {
        guard let window, !watchedWindows.contains(window) else { return }
        watchedWindows.add(window)
        window.addGestureRecognizer(TouchWatcher { MusicVideoPlayer.shared.boost() })
    }

    /// The one view holding the video. It never moves between places (a
    /// moved video shows black until it draws again): it lies over the
    /// window's content and follows the place's frame on screen, frame by
    /// frame, flights included (WebKit's video ignores animations, not
    /// plain moves).
    private(set) lazy var carrier: MusicVideoCarrier = {
        let carrier = MusicVideoCarrier(webView: webView)
        carrier.alpha = 0
        return carrier
    }()
    /// The place the video follows.
    private weak var target: MusicVideoHostView?
    private var displayLink: CADisplayLink?
    /// Nothing has moved for a while: the follow loop runs slowly (a
    /// display link at the screen's full rate keeps ProMotion at 120 Hz and
    /// wakes the app 120 times a second). Any touch, or anything about to
    /// move a place, brings it back to full rate before the first frame.
    private var followsSlowly = false
    private var lastMotionAt: CFTimeInterval = 0
    /// The page draws a frame of the video every 0.35 s (for the still a
    /// move shows, the colors, the black bars); every 1.5 s while idle.
    private var framesFast = true
    private var watchedWindows = NSHashTable<UIWindow>.weakObjects()
    private var playingObserver: AnyCancellable?

    private(set) lazy var webView: WKWebView = {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.allowsAirPlayForMediaPlayback = false
        configuration.allowsPictureInPictureMediaPlayback = false
        let controller = WKUserContentController()
        controller.add(self, name: "video")
        // In YouTube's frame: none of its own buttons, titles or overlays,
        // and word of ads (the cover stays while one plays).
        controller.addUserScript(WKUserScript(source: Self.frameScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        configuration.userContentController = controller
        // Born at its one size: a narrower page shows zoomed in (its
        // viewport is the device's width and can't zoom out).
        let width = Self.stageWidth
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: width, height: width / max(0.5, embedAspect)), configuration: configuration)
        view.isOpaque = false
        view.backgroundColor = .black
        view.scrollView.backgroundColor = .black
        view.scrollView.isScrollEnabled = false
        view.isUserInteractionEnabled = false
        view.alpha = 0
        view.navigationDelegate = self
        return view
    }()

    // MARK: Choosing

    func setSong(_ song: Song?) {
        guard song?.id != self.song?.id else { return }
        self.song = song
        hiddenSongID = nil
        wantedSongID = song.flatMap { autoWants($0) ? $0.id : nil }
        reload()
    }

    /// The song whose video is asked for (a tap on the cover, or the
    /// setting); the others play with their cover.
    @Published private(set) var wantedSongID: UUID?
    /// Put back to its cover by hand: stays so until another song.
    private var hiddenSongID: UUID?

    func isWanted(for song: Song?) -> Bool {
        song != nil && song?.id == wantedSongID
    }

    private func autoWants(_ song: Song) -> Bool {
        guard MusicVideoFeature.isAvailable, song.id != hiddenSongID else { return false }
        switch MusicVideoAutoMode.current {
        case .off: return false
        case .associated: return videoSongs(for: song).allSatisfy { MusicVideoStore.choice(for: $0.id).videoID != nil }
        case .always: return videoSongs(for: song).allSatisfy { MusicVideoStore.choice(for: $0.id).videoID != nil } || isPlayerPresented
        }
    }

    /// A tap on the cover: its video (found first if need be), or back to
    /// the cover.
    func toggle(for song: Song) {
        guard MusicVideoFeature.isAvailable, song.id == self.song?.id else { return }
        // Asked for, but it never came (the cover still there, nothing
        // loading): a tap tries again rather than doing nothing.
        if wantedSongID == song.id, shownSongID != song.id, !isLoadingVideo, !isSearching {
            stalledRetryID = nil
            unload()
            reload()
            revision += 1
            return
        }
        if wantedSongID == song.id {
            wantedSongID = nil
            hiddenSongID = song.id
            morphOut()
        } else {
            wantedSongID = song.id
            hiddenSongID = nil
            reload()
        }
        revision += 1
        MotionArtworkState.shared.refresh(for: song)
    }

    /// Back to the cover: the video grows back into the square and fades
    /// over it while the cover returns, then stops.
    private func morphOut() {
        searchTask?.cancel()
        isSearching = false
        endLoading()
        guard shownSongID != nil, carrier.alpha > 0.01 else {
            unloadAfterGrace()
            return
        }
        morphStart = nil
        morphOutRect = carrier.frame
        morphOutStart = CACurrentMediaTime()
        Self.haptic()
        setShown(nil)
        vpLog("morph out from \(morphOutRect)")
        updateFollowing()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            guard let self else { return }
            self.morphOutStart = nil
            if self.wantedSongID != self.song?.id || self.wantedSongID == nil { self.unloadAfterGrace() } else { self.rehost(); self.tick() }
        }
    }

    /// Closed by mistake, maybe: the clip plays on unseen and silent a few
    /// seconds, so a tap back brings it at once.
    private var graceUnload: DispatchWorkItem?

    private func unloadAfterGrace() {
        graceUnload?.cancel()
        guard videoID != nil else { unload(); return }
        setAudible(false)
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.graceUnload = nil
            if self.wantedSongID == nil || self.wantedSongID != self.song?.id { self.unload() }
        }
        graceUnload = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: item)
    }

    /// The next song's clip looked up while this one plays.
    private var prefetchTask: Task<Void, Never>?
    private var prefetchedSongID: UUID?

    private func prefetchNext() {
        let player = MusicPlayerService.shared
        let index = player.currentIndex + 1
        guard player.queue.indices.contains(index) else { return }
        let next = player.queue[index]
        guard next.id != prefetchedSongID, next.id != song?.id else { return }
        let missing = videoSongs(for: next).filter {
            let choice = MusicVideoStore.choice(for: $0.id)
            return choice.videoID == nil && choice.candidates?.isEmpty != false
        }
        guard !missing.isEmpty else { return }
        prefetchedSongID = next.id
        prefetchTask?.cancel()
        prefetchTask = Task { [weak self] in
            // Not on the clip's first seconds.
            try? await Task.sleep(for: .seconds(3))
            for part in missing {
                guard let self, !Task.isCancelled else { return }
                _ = try? await self.search(nil, for: part)
            }
        }
    }

    /// In iOS's own player: its slider and buttons lead the song.
    private var isFullScreen = false

    /// The frame the video element lives in, for native full screen.
    private var videoFrame: WKFrameInfo?

    /// iOS's own video player, full screen (it turns with the phone); the
    /// video comes back in place after.
    func enterFullScreen() {
        guard shownSongID != nil else { return }
        let script = "var v = document.querySelector('video'); if (v && v.webkitEnterFullscreen) { v.webkitEnterFullscreen() }"
        webView.evaluateJavaScript(script, in: videoFrame, in: .page) { result in
            if case .failure(let error) = result { print("VPDBG fullscreen failed: \(error)") }
        }
    }

    /// Full screen, the song follows the video: a move of iOS's slider
    /// seeks the song, its play and pause buttons play and pause it.
    private func followVideo(time: Double, state: Int) {
        let player = MusicPlayerService.shared
        // Entering full screen may pause it a moment: not a tap.
        guard state == 1 || state == 2, Date().timeIntervalSince(lastSeek) > 1 else { return }
        let songTime = time - offset
        if songTime >= 0, songTime < player.duration, abs(songTime - player.preciseCurrentTime) > 1 {
            player.seek(to: songTime)
        }
        // Only a change of the video's own: never a tug of war with the song.
        defer { lastFreeState = state }
        guard let last = lastFreeState, last != state else { return }
        if state == 2, player.isPlaying {
            player.pause()
        } else if state == 1, !player.isPlaying {
            player.play()
        }
    }

    private var lastFreeState: Int?

    /// Asked from the video's menu: the picker of another video.
    @Published var picksAnotherVideo = false

    private var morphOutStart: CFTimeInterval?
    private var morphOutRect: CGRect = .zero

    static func haptic() {
        let generator = UIImpactFeedbackGenerator(style: .soft)
        generator.impactOccurred(intensity: 0.75)
    }

    /// The feature or the key changed: what's playing follows.
    func refresh() {
        if let song, wantedSongID != song.id, autoWants(song) { wantedSongID = song.id }
        reload()
        revision += 1
    }

    func choose(_ candidate: MusicVideoCandidate, for song: Song, byHand: Bool = false, reloads: Bool = true) {
        pickedByHand = byHand
        var choice = MusicVideoStore.choice(for: song.id)
        choice.isOn = true
        choice.videoID = candidate.id
        choice.offset = nil
        choice.hasOutro = nil
        choice.isKept = byHand ? true : nil
        MusicVideoStore.setChoice(choice, for: song.id)
        revision += 1
        MotionArtworkState.shared.refresh(for: song)
        if reloads, let current = self.song, song.id == current.id || isPartOfCurrent(song) {
            // Picked in the sheet: shown.
            wantedSongID = current.id
            hiddenSongID = nil
            videoID = nil
            mergeTiming = nil
            reload()
        }
    }

    /// Nil goes back to the guess.
    func setOffset(_ value: TimeInterval?, for song: Song) {
        var choice = MusicVideoStore.choice(for: song.id)
        choice.offset = value
        MusicVideoStore.setChoice(choice, for: song.id)
        if song.id == self.song?.id {
            offset = value ?? currentGuess(for: song, choice: choice)
            lastSeek = .distantPast
            tick()
        } else if isPartOfCurrent(song), var timing = mergeTiming, let current = self.song,
                  let part = videoSongs(for: current).firstIndex(where: { $0.id == song.id }) {
            timing.offsets[part] = value ?? currentGuess(for: song, choice: choice)
            mergeTiming = timing
            offset = timing.offset(of: leadPart)
            lastSeek = .distantPast
            tick()
        }
        revision += 1
    }

    func offset(for song: Song) -> TimeInterval {
        let choice = MusicVideoStore.choice(for: song.id)
        return choice.offset ?? currentGuess(for: song, choice: choice)
    }

    private func currentGuess(for song: Song, choice: MusicVideoChoice) -> TimeInterval {
        // All the extra at the end: the picture starts with the song.
        if choice.hasOutro == true { return 0 }
        let video = choice.candidates?.first { $0.id == choice.videoID }
        return MusicVideoStore.guessedOffset(video: video?.duration ?? 0, song: song.duration)
    }

    /// How much longer the clip runs than the song.
    private func extraLength(for song: Song, choice: MusicVideoChoice) -> TimeInterval {
        let listed = choice.candidates?.first { $0.id == choice.videoID }?.duration ?? 0
        let playing = song.id == self.song?.id && videoID == choice.videoID && videoDuration > 0 ? videoDuration : 0
        let duration = playing > 0 ? playing : listed
        guard duration > 0, song.duration > 0 else { return 0 }
        return duration - song.duration
    }

    func hasOutro(for song: Song) -> Bool {
        MusicVideoStore.choice(for: song.id).hasOutro == true
    }

    /// The sheet's length: the intro's (where the song starts in the
    /// clip), or the outro's (what's left after it ends).
    func partLength(for song: Song) -> TimeInterval {
        let choice = MusicVideoStore.choice(for: song.id)
        let start = offset(for: song)
        guard choice.hasOutro == true else { return start }
        return max(0, (extraLength(for: song, choice: choice) - start) * 10).rounded() / 10
    }

    func setPartLength(_ value: TimeInterval, for song: Song) {
        let choice = MusicVideoStore.choice(for: song.id)
        setOffset(choice.hasOutro == true ? extraLength(for: song, choice: choice) - value : value, for: song)
    }

    /// The same length, read as an intro or an outro (a guess stays one).
    func setHasOutro(_ hasOutro: Bool, for song: Song) {
        var choice = MusicVideoStore.choice(for: song.id)
        guard (choice.hasOutro == true) != hasOutro else { return }
        let length = partLength(for: song)
        let isSet = choice.offset != nil
        choice.hasOutro = hasOutro
        MusicVideoStore.setChoice(choice, for: song.id)
        if isSet { setPartLength(length, for: song) } else { setOffset(nil, for: song) }
    }

    /// A new search (the sheet's), kept for the song.
    func search(_ query: String?, for song: Song) async throws -> [MusicVideoCandidate] {
        // The backup key takes over once the main one runs out for the day.
        let keys = MusicVideoFeature.searchKeys
        guard !keys.isEmpty else { return [] }
        var found: [MusicVideoCandidate] = []
        for (index, key) in keys.enumerated() {
            let isLast = index == keys.count - 1
            do {
                found = try await YouTubeSearch.candidates(for: song, query: query, key: key)
                break
            } catch MusicVideoError.quota {
                // Spent for the day: the next one first until it resets.
                MusicVideoFeature.markSpent(key)
                if isLast { throw MusicVideoError.quota }
            } catch MusicVideoError.busy {
                if isLast { throw MusicVideoError.busy }
            }
        }
        var choice = MusicVideoStore.choice(for: song.id)
        // Videos already found blocked stay marked.
        let blocked = Set((choice.candidates ?? []).filter { $0.isBlocked == true }.map(\.id))
        found = found.map { candidate in
            var candidate = candidate
            if blocked.contains(candidate.id) { candidate.isBlocked = true }
            return candidate
        }
        // The chosen one stays listed.
        let kept = choice.candidates?.first { $0.id == choice.videoID && !found.map(\.id).contains($0.id) }
        choice.candidates = found + (kept.map { [$0] } ?? [])
        MusicVideoStore.setChoice(choice, for: song.id)
        revision += 1
        return choice.candidates ?? []
    }

    private func reload() {
        searchTask?.cancel()
        guard let song, MusicVideoFeature.isAvailable, wantedSongID == song.id else {
            if morphOutStart == nil { unload() }
            return
        }
        graceUnload?.cancel()
        graceUnload = nil
        if let merge = Self.merge(of: song) {
            reloadMerged(song, merge: merge)
            return
        }
        let choice = MusicVideoStore.choice(for: song.id)
        if let id = choice.videoID {
            let video = choice.candidates?.first { $0.id == id }
            offset = choice.offset ?? MusicVideoStore.guessedOffset(video: video?.duration ?? 0, song: song.duration)
            embedAspect = CGFloat(video?.aspect ?? 16 / 9)
            if id != videoID || mergeTiming != nil {
                mergeTiming = nil
                load(id, durationHint: video?.duration ?? 0)
            }
            return
        }
        // Already looked up ahead (while the one before played): no wait.
        if let found = choice.candidates, !found.isEmpty {
            if let best = found.first(where: { $0.isBlocked != true }), best.score >= YouTubeSearch.acceptedScore {
                choose(best, for: song)
            } else {
                unload()
                show(String(localized: "No music video found. Touch and hold the cover, then Wrong Video?, to pick one."))
            }
            return
        }
        // First time on for this song: find its clip.
        unload()
        isSearching = true
        show(String(localized: "Looking for the music video…"), for: nil)
        searchTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.song?.id == song.id { self.isSearching = false } }
            do {
                let found = try await self.search(nil, for: song)
                guard !Task.isCancelled, self.song?.id == song.id else { return }
                if let best = found.first(where: { $0.isBlocked != true }), best.score >= YouTubeSearch.acceptedScore {
                    self.message = nil
                    self.choose(best, for: song)
                } else {
                    self.show(String(localized: "No music video found. Touch and hold the cover, then Wrong Video?, to pick one."))
                }
            } catch {
                guard self.song?.id == song.id else { return }
                self.show((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    /// Both parts' clips (each found first if need be), then one page
    /// playing the two.
    private func reloadMerged(_ song: Song, merge: SongMerge) {
        let parts = merge.parts.map(\.song)
        let choices = parts.map { MusicVideoStore.choice(for: $0.id) }
        let ids = choices.compactMap(\.videoID)
        if ids.count == 2 {
            let videos = zip(ids, choices).map { id, choice in choice.candidates?.first { $0.id == id } }
            let layout = merge.layout
            let timing = MergeTiming(
                ids: ids,
                starts: merge.parts.map(\.start),
                offsets: parts.map { offset(for: $0) },
                durations: videos.map { $0?.duration ?? 0 },
                aspects: videos.map { CGFloat($0?.aspect ?? 16 / 9) },
                secondAt: layout.secondAt,
                overlap: layout.overlap,
                isCut: merge.transition == .cut)
            guard timing != mergeTiming || videoID == nil else { return }
            mergeTiming = timing
            leadPart = timing.mix(at: MusicPlayerService.shared.preciseCurrentTime) >= 0.5 ? 1 : 0
            offset = timing.offset(of: leadPart)
            embedAspect = timing.aspects[leadPart]
            load(ids[leadPart], durationHint: timing.durations[leadPart])
            return
        }
        unload()
        isSearching = true
        show(String(localized: "Looking for the music videos…"), for: nil)
        searchTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.song?.id == song.id { self.isSearching = false } }
            do {
                for (part, choice) in zip(parts, choices) where choice.videoID == nil {
                    var found = choice.candidates ?? []
                    if found.isEmpty { found = try await self.search(nil, for: part) }
                    guard !Task.isCancelled, self.song?.id == song.id else { return }
                    guard let best = found.first(where: { $0.isBlocked != true }), best.score >= YouTubeSearch.acceptedScore else {
                        self.show(String(localized: "No music video found for “\(part.title)”. Touch and hold the cover, then Wrong Video?, to pick one."))
                        return
                    }
                    self.choose(best, for: part, reloads: false)
                }
                guard !Task.isCancelled, self.song?.id == song.id else { return }
                self.message = nil
                self.isSearching = false
                self.reload()
            } catch {
                guard self.song?.id == song.id else { return }
                self.show((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    /// The second clip takes over (or the first, on a seek back): the
    /// picture's crop, shape and colors become its own.
    private func setLead(_ part: Int) {
        guard let timing = mergeTiming, part != leadPart else { return }
        leadPart = part
        let id = timing.ids[part]
        videoID = id
        offset = timing.offset(of: part)
        videoDuration = timing.durations[part]
        embedAspect = timing.aspects[part]
        isAd = false
        barSamples = []
        isSamplingBars = false
        if let saved = MusicVideoBars.saved(for: id) {
            content = saved.content
            nativeAspect = saved.aspect
        } else {
            content = BarSample.full
            nativeAspect = nil
        }
        withAnimation(.smooth(duration: 0.5)) { aspect = shownAspect }
        carrier.setNeedsLayout()
        lastFrameImage = nil
        loadThumbnailColors(id)
        framesFast = true
        updateFramePace(captureNow: true)
        NotificationCenter.default.post(name: Self.stateDidChange, object: nil)
    }

    private func show(_ text: String, for seconds: Double? = 4) {
        messageTask?.cancel()
        withAnimation(.smooth) { message = text }
        guard let seconds else { return }
        messageTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            withAnimation(.smooth) { self?.message = nil }
        }
    }

    // MARK: Playing

    private func load(_ id: String, durationHint: TimeInterval, keepsStill: Bool = false) {
        setAudible(false)
        webView.alpha = 0
        let reloads = keepsStill && id == videoID
        if !reloads {
            thumbnailImage = nil
            lastFrameImage = nil
        } else if let still {
            carrier.cover(with: still)
            adoptedAt = Date()
        }
        videoID = id
        videoDuration = durationHint
        isReady = false
        hasPlayed = false
        firstPlayedAt = nil
        isInSync = false
        isAd = false
        barSamples = []
        isSamplingBars = false
        if let saved = MusicVideoBars.saved(for: id) {
            content = saved.content
            nativeAspect = saved.aspect
        } else {
            content = BarSample.full
            nativeAspect = nil
        }
        aspect = shownAspect
        carrier.setNeedsLayout()
        framesFast = true
        boost()
        lastSeek = .distantPast
        let start = max(0, Int(MusicPlayerService.shared.preciseCurrentTime + offset))
        let html: String
        if let timing = mergeTiming {
            let (a, b) = timing.targets(at: MusicPlayerService.shared.preciseCurrentTime)
            html = Self.mergedPage(ids: timing.ids, starts: [max(0, Int(a)), max(0, Int(max(b, timing.starts[1] + timing.offsets[1])))])
        } else {
            html = Self.page(videoID: id, start: start)
        }
        webView.loadHTMLString(html, baseURL: Self.origin)
        startTimers()
        // The cover stays until the video truly plays; it loads meanwhile,
        // out of sight.
        if !reloads {
            setShown(nil)
            startLoading()
        }
        parkCarrier()
        NotificationCenter.default.post(name: Self.stateDidChange, object: nil)
        if !reloads { loadThumbnailColors(id) }
        updateHolds()
    }

    private func unload() {
        graceUnload?.cancel()
        graceUnload = nil
        endLoading()
        setAudible(false)
        webView.alpha = 0
        setShown(nil)
        stopTimers()
        mergeTiming = nil
        if videoID != nil {
            videoID = nil
            isReady = false
            webView.loadHTMLString("<html><body style='background:#000'></body></html>", baseURL: nil)
        }
    }

    private func startTimers() {
        stopTimers()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            MainActor.assumeIsolated { MusicVideoPlayer.shared.tick() }
        }
        colorTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in
            MainActor.assumeIsolated { MusicVideoPlayer.shared.sampleFrame() }
        }
    }

    private func stopTimers() {
        tickTimer?.invalidate()
        colorTimer?.invalidate()
        tickTimer = nil
        colorTimer = nil
    }

    private var hostIsVisible: Bool {
        webView.window != nil
    }

    /// A web view plays only in a window: before any place shows the
    /// video, it waits in one, unseen.
    private func parkCarrier() {
        guard carrier.window == nil else { return }
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        guard let window = windows.first(where: \.isKeyWindow) ?? windows.first else { return }
        carrier.alpha = 0
        window.addSubview(carrier)
        carrier.frame = CGRect(x: 0, y: 0, width: 16, height: 9)
    }

    /// Played and drawn, a picture of it in hand: the video takes the
    /// cover's place (the cover morphs into its shape).
    private var retriedID: String?

    private func showIfReady() {
        // Only when wanted: on the way back to the cover it still plays a
        // moment, and must not come back over it.
        guard let song, shownSongID != song.id, wantedSongID == song.id, morphOutStart == nil,
              hasPlayed, !isAd, still != nil,
              isInSync || Date().timeIntervalSince(firstPlayedAt ?? .distantFuture) > 2.5 else { return }
        vpLog("ready: shown")
        prefetchNext()
        morphStart = nil
        morphPending = true
        setShown(song.id)
        rehost()
        endLoading()
        // It plays: kept for this song from now on.
        for part in videoSongs(for: song) {
            var choice = MusicVideoStore.choice(for: part.id)
            guard let chosen = choice.videoID, mergeTiming?.ids.contains(chosen) ?? (chosen == videoID), choice.isKept != true else { continue }
            choice.isKept = true
            MusicVideoStore.setChoice(choice, for: part.id)
        }
        // The background takes the video's colors at once.
        lastColorsAt = .distantPast
        if let still { updateColors(from: still) }
    }

    /// While the video loads (the cover still there): a word at the top.
    @Published private(set) var isLoadingVideo = false

    private func startLoading() {
        loadingGeneration += 1
        isLoadingVideo = true
        show(String(localized: "Loading the music video…"), for: nil)
        watchLoading()
    }

    private var loadWatch: DispatchWorkItem?
    /// The clip already loaded again once for being stuck.
    private var stalledRetryID: String?

    /// Not playing after a while (a page that never started, a stalled
    /// stream): loaded once more, then back to the cover with a word, a
    /// tap on it trying again.
    private func watchLoading() {
        loadWatch?.cancel()
        let id = videoID
        let work = DispatchWorkItem { [weak self] in
            guard let self, let song = self.song, let id, self.videoID == id,
                  self.wantedSongID == song.id, self.shownSongID != song.id else { return }
            self.vpLog("stalled: ready \(self.isReady) played \(self.hasPlayed) ad \(self.isAd) still \(self.still != nil)")
            if self.stalledRetryID != id {
                self.stalledRetryID = id
                self.load(id, durationHint: self.videoDuration)
            } else {
                self.unload()
                self.isLoadingVideo = false
                self.show(String(localized: "The music video didn't load. Tap the cover to try again."))
            }
        }
        loadWatch = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 14, execute: work)
    }

    private var loadingGeneration = 0

    private func endLoading() {
        loadWatch?.cancel()
        loadWatch = nil
        guard isLoadingVideo else { return }
        messageTask?.cancel()
        withAnimation(.smooth) { message = nil }
        // The spinner stays while the word slides away (else a warning
        // sign shows for an instant).
        loadingGeneration += 1
        let generation = loadingGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, self.loadingGeneration == generation, self.message == nil else { return }
            self.isLoadingVideo = false
        }
    }

    /// The seek bar moved: the video follows it at once (not the other
    /// way round, for a moment).
    func playerDidSeek() {
        guard !isFollowing else { return }
        userSeekedAt = Date()
        lastSeek = .distantPast
        tick()
    }

    private var isFollowing = false
    private var userSeekedAt = Date.distantPast
    private var lastPlayingAt = Date.distantPast
    private var lastVideoTime: TimeInterval = 0
    private var appIsActive = UIApplication.shared.applicationState != .background
    /// Back from the lock screen: reloaded if it doesn't play again soon.
    private var resumeDeadline: Date?
    /// The clip's sound is the one heard (the file plays on, silent, as
    /// the clock for the lyrics and the seek bar).
    private(set) var isAudible = false

    /// When the video last moved to another place (its cover lifts once
    /// it has played a moment there).
    private var adoptedAt = Date.distantPast

    private func uncoverIfDrawn() {
        guard isPlayingNow, Date().timeIntervalSince(adoptedAt) > 0.5, carrier.covers else { return }
        carrier.uncover()
    }

    private func tick() {
        guard isReady, let id = videoID else { return }
        let player = MusicPlayerService.shared
        let reachable = hostIsVisible && appIsActive
        let now = Date()
        // Just after a seek of the bar (or while the file is heard), the
        // video follows the file; otherwise the file follows the video.
        let videoFollows = true
        var target = player.preciseCurrentTime + offset
        let play = reachable && (player.isPlaying || !hasPlayed)
        let canSeek = videoFollows && now.timeIntervalSince(lastSeek) > 1.2
        let free = isFullScreen
        var script = "window.vp_tick ? vp_tick(\(target), \(play), \(canSeek), \(free)) : null"
        if let timing = mergeTiming {
            let time = player.preciseCurrentTime
            let mix = timing.mix(at: time)
            let (a, b) = timing.targets(at: time)
            let lead = mix >= 0.5 ? 1 : 0
            setLead(lead)
            target = lead == 1 ? b : a
            // The second clip waits, paused where it comes in, until just before.
            let bRest = max(0, timing.starts[1] + timing.offsets[1])
            let bWakes = time > timing.secondAt - 2
            script = "window.vp_tick2 ? vp_tick2(\(a), \(b), \(mix), \(bWakes), \(bRest), \(play), \(canSeek), \(free)) : null"
        }
        webView.evaluateJavaScript(script) { [weak self] result, _ in
            MainActor.assumeIsolated {
                guard let self, self.videoID == id, let values = result as? [Double], values.count >= 4 else { return }
                let (time, state, zone, seeked) = (values[0], Int(values[1]), Int(values[2]), values[3] > 0)
                let now = Date()
                if free {
                    self.followVideo(time: time, state: state)
                    return
                }

                if seeked { self.lastSeek = now }
                self.isInSync = state == 1 && !seeked && abs(time - target) < 0.35
                self.lastVideoTime = time
                if state == 1, time > 0 {
                    if !self.hasPlayed { self.firstPlayedAt = now }
                    self.hasPlayed = true
                    self.lastPlayingAt = now
                    self.resumeDeadline = nil
                }
                // A short stall keeps the clip; a long one hands back to the file.
                let stalled = state == 3 && now.timeIntervalSince(self.lastPlayingAt) > 1.5
                let going = state == 1 || (state == 3 && !stalled) || (state == 2 && self.hasPlayed && !player.isPlaying)
                self.isPlayingNow = state == 1
                self.showIfReady()
                self.uncoverIfDrawn()
                _ = (going, zone, reachable)
                self.updateVideoAlpha()

                if let deadline = self.resumeDeadline, now > deadline, player.isPlaying {
                    self.resumeDeadline = nil
                    self.load(id, durationHint: self.videoDuration, keepsStill: true)
                }
            }
        }
    }

    /// The file ended before the clip: the clip plays on to its end.
    private var holdsEnd = false

    /// Asked when the file ends: true while the clip still has more.
    func holdsSongEnd() -> Bool {
        // The library's sound plays: the song ends when the file does.
        false
    }

    private func setAudible(_ audible: Bool) {
        guard audible != isAudible else { return }
        isAudible = audible
        if !audible { holdsEnd = false }
        // A quick cross-fade between the file and the clip.
        MusicPlayerService.shared.setVideoAudible(audible)
    }

    private var wentAwayAt: Date?

    @objc private func appDidEnterBackground() {
        appIsActive = false
        wentAwayAt = Date()
        updateFollowing()
        // The page stops in the background: the file takes over, in time.
        setAudible(false)
        webView.evaluateJavaScript("window.vp_pause && vp_pause()")
    }

    @objc private func appWillEnterForeground() {
        appIsActive = true
        lastPlayingAt = Date()
        updateFollowing()
        // A while away, the page is often frozen (or its process gone):
        // a fresh one, where the song is, its last frame shown meanwhile.
        if let away = wentAwayAt, Date().timeIntervalSince(away) > 20, let id = videoID {
            wentAwayAt = nil
            resumeDeadline = nil
            load(id, durationHint: videoDuration, keepsStill: true)
            return
        }
        wentAwayAt = nil
        resumeDeadline = videoID == nil ? nil : Date().addingTimeInterval(4)
        tick()
    }

    nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        MainActor.assumeIsolated {
            guard let id = videoID else { return }
            load(id, durationHint: videoDuration, keepsStill: true)
        }
    }

    /// While the clip is on, it is the cover: everywhere, playing or not.
    private func setShown(_ id: UUID?) {
        guard shownSongID != id else { return }
        withAnimation(.spring(duration: 0.6, bounce: 0.12)) { shownSongID = id }
        revision += 1
        updateFollowing()
        follow()
        if id == nil {
            thumbnailImage = nil
            if colors != nil { colors = nil }
        }
        NotificationCenter.default.post(name: Self.stateDidChange, object: nil)
    }

    /// The picture shows once its first frame has played (the clip's still
    /// stands in until then), and steps aside during an ad.
    private func updateVideoAlpha() {
        let alpha: CGFloat = hasPlayed && !isAd ? 1 : 0
        updateHolds()
        guard webView.alpha != alpha else { return }
        UIView.animate(withDuration: 0.35, delay: 0, options: [.curveEaseInOut, .beginFromCurrentState, .allowUserInteraction]) {
            self.webView.alpha = alpha
        }
        if alpha == 1 { sampleFrame() }
    }

    nonisolated func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            // YouTube's frame (not our page) holds the video element.
            // Two clips (a merged song): only the one in front is heard from.
            if type == "ad" || type == "frame", mergeTiming != nil, let id = videoID,
               message.frameInfo.request.url?.absoluteString.contains(id) == false { return }
            if type == "ad" || type == "frame" || type == "fullscreen", !message.frameInfo.isMainFrame { videoFrame = message.frameInfo }
            switch type {
            case "fullscreen":
                let on = body["on"] as? Bool ?? false
                isFullScreen = on
                lastFreeState = nil
                lastSeek = Date()
                vpLog("fullscreen \(on)")
                // Taken back once iOS's player has let go (and once more, late).
                for delay in [0.3, 1.2, 3] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MusicPlayerService.shared.reclaimNowPlaying() }
                }
            case "ready":
                isReady = true
                if let duration = body["duration"] as? Double, duration > 0 { videoDuration = duration }
                tick()
            case "ad":
                isAd = body["ad"] as? Bool ?? false
                updateVideoAlpha()
            case "error":
                failed(code: body["code"] as? Int ?? 0, part: body["part"] as? Int)
            case "frame":
                guard let id = videoID, let url = body["data"] as? String else { return }
                // Decoded away from the main thread: never a hitch mid-animation.
                Task { [weak self] in
                    let image = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                        guard let comma = url.firstIndex(of: ","),
                              let data = Data(base64Encoded: String(url[url.index(after: comma)...])),
                              let image = UIImage(data: data) else { return nil }
                        return image.preparingForDisplay() ?? image
                    }.value
                    guard let self, let image, self.videoID == id else { return }
                    self.lastFrameImage = image
                    self.lastCanvasFrameAt = Date()
                    self.sampleBars(image)
                    self.updateFramePace(captureNow: false)
                    self.updateColors(from: self.lastFrame ?? image)
                    NotificationCenter.default.post(name: Self.frameDidChange, object: nil)
                }
            default:
                break
            }
        }
    }

    /// Not playable here (embedding off, age-restricted, removed): the
    /// next good candidate, else the cover with a word.
    private func failed(code: Int, part: Int? = nil) {
        guard let current = self.song, var id = videoID else { return }
        var song = current
        if let part, let timing = mergeTiming, timing.ids.indices.contains(part) {
            id = timing.ids[part]
            song = videoSongs(for: current)[part]
        }
        var choice = MusicVideoStore.choice(for: song.id)
        // Only for good (removed, private, not embeddable) and never a
        // video kept: a passing error tries the same one again, once.
        let forGood = [100, 101, 150].contains(code)
        let blocked = code == 101 || code == 150
        if blocked, let index = choice.candidates?.firstIndex(where: { $0.id == id }) {
            choice.candidates?[index].isBlocked = true
            MusicVideoStore.setChoice(choice, for: song.id)
            revision += 1
        }
        let candidates = choice.candidates ?? []
        let after = candidates.drop { $0.id != id }.dropFirst().filter { $0.isBlocked != true }
        let kept = pickedByHand || choice.isKept == true || choice.offset != nil
        if !forGood, retriedID != id {
            retriedID = id
            if let lead = videoID { load(lead, durationHint: videoDuration, keepsStill: true) }
        } else if forGood, !kept, let next = after.first(where: { $0.score >= YouTubeSearch.acceptedScore }) {
            choose(next, for: song)
        } else if blocked {
            unload()
            show(String(localized: "Its owner only lets this video play on YouTube. Touch and hold the cover, then Wrong Video?, to pick another."))
        } else {
            unload()
            show(String(localized: "This video can't be played in VibePod (error \(code)). Touch and hold the cover, then Wrong Video?, to pick another."))
        }
    }

    // MARK: Hosts

    func attach(_ host: MusicVideoHostView) {
        hosts[ObjectIdentifier(host)] = Weak(view: host)
        rehost()
    }

    func detach(_ host: MusicVideoHostView) {
        hosts[ObjectIdentifier(host)] = nil
        rehost()
    }

    /// One video, one place: a flying cover first (it carries the playing
    /// video along), else where the cover is on screen right now.
    func rehost() {
        boost()
        hosts = hosts.filter { $0.value.view != nil }
        let visible = hosts.values.compactMap(\.view).filter { $0.window != nil }
        let wanted: MusicVideoHostView.Role = isPlayerPresented ? (isSuppressed ? .compact : .large) : .mini
        // A flying cover carries the video; else where the cover is.
        let flies = visible.contains { $0.role == .flight }
        let host = visible.last { $0.role == .flight }
            ?? visible.last { $0.role == wanted && Self.opacity(of: $0) > 0.02 }
            ?? visible.last { $0.role == wanted }
            ?? (target.flatMap { t in visible.contains { $0 === t } && Self.opacity(of: t) > 0.02 ? t : nil })
            ?? visible.first { Self.opacity(of: $0) > 0.02 }
        // While one flies, the places it leaves and reaches show nothing
        // (like the real covers under a flying one).
        for view in hosts.values.compactMap(\.view) {
            view.alpha = flies && view.role != .flight ? 0 : 1
        }
        target = host
        updateHolds()
        moveCarrier(to: host)
        updateFollowing()
        follow()
        tick()
    }

    /// Only one picture at a time: the place shows the clip's still until
    /// the video itself draws, then nothing (the video alone, over it).
    private func updateHolds() {
        let drawn = hasPlayed && !isAd
        for view in hosts.values.compactMap(\.view) {
            view.holds = view === target && !drawn
        }
    }

    /// The window's top view holding the place: the video lies over it
    /// (sheets and menus, in views of their own, stay above).
    private static func container(of view: UIView) -> UIView? {
        guard let window = view.window else { return nil }
        var current: UIView = view
        while let parent = current.superview, parent !== window { current = parent }
        return current.superview === window ? current : nil
    }

    /// The place wanted may not show yet (the lyrics, hidden until their
    /// transition starts): the video stays where it is seen meanwhile.
    /// Into the place's window (the player has one of its own): black
    /// there until it draws again, so its last frame covers it meanwhile.
    private func moveCarrier(to host: MusicVideoHostView?) {
        // Fading out over the cover it left: it stays put, wherever its
        // place went (else it jumps behind the player and vanishes).
        guard morphOutStart == nil,
              let host, let container = Self.container(of: host), carrier.superview !== container else { return }
        container.addSubview(carrier)
        if still != nil { carrier.cover(with: still) }
        adoptedAt = Date()
        lastSeek = .distantPast
        vpLog("move carrier -> \(host.role) in \(type(of: container))")
    }

    /// Where the video is seen right now, on its cover: a flight leaving
    /// the cover starts exactly there.
    func shownFrame(in view: UIView) -> CGRect? {
        guard shownSongID != nil, morphOutStart == nil, target?.role == .large,
              carrier.alpha > 0.5, let container = carrier.superview, container.window === view.window else { return nil }
        return container.convert(carrier.frame, to: view)
    }

    private func retarget() {
        let visible = hosts.values.compactMap(\.view).filter { $0.window != nil }
        guard !visible.contains(where: { $0.role == .flight }) else { return }
        let wanted: MusicVideoHostView.Role = isPlayerPresented ? (isSuppressed ? .compact : .large) : .mini
        // The place wanted as soon as it's there (it may still be fading
        // in); else the one most in sight (walked only then: this runs
        // every display-link frame).
        guard let best = visible.last(where: { $0.role == wanted })
                ?? visible.map({ ($0, Self.opacity(of: $0)) }).filter({ $0.1 > 0.02 }).max(by: { $0.1 < $1.1 })?.0,
              best !== target else { return }
        // The lyrics' place, not faded in yet (its flight is about to
        // start): the video stays on the cover it is seen on meanwhile.
        if wanted == .compact, Self.opacity(of: best) <= 0.02,
           let target, target.window != nil, Self.opacity(of: target) > 0.02 { return }
        vpLog("retarget \(target.map { "\($0.role)" } ?? "nil") -> \(best.role)")
        target = best
        moveCarrier(to: best)
        updateHolds()
    }

    private var morphStart: CFTimeInterval?
    /// Shown, the cover's place not laid out yet: the fade starts there.
    private var morphPending = false

    private static func easeInOut(_ x: Double) -> CGFloat {
        CGFloat(x * x * (3 - 2 * x))
    }

    /// SwiftUI's `.spring(duration: 0.6, bounce: 0.12)`, the cover's.
    private static func coverSpring(_ t: CFTimeInterval) -> CGFloat {
        guard t > 0 else { return 0 }
        let omega = 2 * Double.pi / 0.6
        let zeta = 1 - 0.12
        let omegaD = omega * (1 - zeta * zeta).squareRoot()
        let decay = exp(-zeta * omega * t)
        return CGFloat(1 - decay * (cos(omegaD * t) + zeta * omega / omegaD * sin(omegaD * t)))
    }

    private let logStart = Date()
    /// Debug traces, off: printing costs on the hot paths.
    private static let logs = false
    func vpLog(_ text: @autoclosure () -> String) {
        guard Self.logs else { return }
        print("VPDBG \(String(format: "%.3f", Date().timeIntervalSince(logStart))) \(text())")
    }

    private static func opacity(of view: UIView) -> CGFloat {
        var opacity = CGFloat(1)
        var current: UIView? = view
        while let v = current {
            if v.isHidden { return 0 }
            opacity *= v.alpha
            current = v.superview
        }
        return opacity
    }

    private func updateFollowing() {
        let follows = (target != nil && shownSongID != nil || morphOutStart != nil) && appIsActive
        if follows {
            watchTouches(in: carrier.window)
            watchTouches(in: target?.window)
        }
        if follows, displayLink == nil {
            let link = CADisplayLink(target: self, selector: #selector(follow))
            link.add(to: .main, forMode: .common)
            displayLink = link
            followsSlowly = false
            lastMotionAt = CACurrentMediaTime()
        } else if !follows, let link = displayLink {
            followsSlowly = false
            updateFramePace(captureNow: false)
            link.invalidate()
            displayLink = nil
        }
    }

    /// The video over its place: the place's frame and opacity on screen
    /// right now (mid-animation included), its corners.
    @objc private func follow() {
        let now = CACurrentMediaTime()
        if let start = morphOutStart {
            boost()
            let t = CACurrentMediaTime() - start
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            carrier.frame = morphOutRect
            carrier.alpha = 1 - Self.easeInOut(min(1, max(0, t - 0.05) / 0.34))
            CATransaction.commit()
            return
        }
        retarget()
        guard let target, target.window != nil, shownSongID != nil,
              let container = carrier.superview, Self.container(of: target) === container,
              let place = target.layer.presentation(), let base = container.layer.presentation() else {
            if carrier.alpha != 0 {
                carrier.alpha = 0
                lastMotionAt = now
            }
            slowDownIfIdle(at: now)
            return
        }
        var frame = place.convert(place.bounds, to: base)
        var opacity = CGFloat(1)
        var layer: CALayer? = place
        while let current = layer, current !== base {
            if current.isHidden { opacity = 0; break }
            opacity *= CGFloat(current.opacity)
            layer = current.superlayer
        }
        let radius = place.cornerRadius * (place.bounds.width > 0 ? frame.width / place.bounds.width : 1)
        // Just shown: the video starts as the square cover (filling it)
        // and eases into its rectangle with the cover's own spring, fading
        // in over it.
        // Just shown: the video fades in as the cover's middle band (it
        // never zooms) while the cover around it folds away with its
        // spring.
        if morphPending {
            let wanted: MusicVideoHostView.Role = isPlayerPresented ? (isSuppressed ? .compact : .large) : .mini
            if target.role == wanted || target.role == .flight {
                morphPending = false
                morphStart = CACurrentMediaTime()
                Self.haptic()
            } else {
                opacity = 0
            }
        }
        if let start = morphStart {
            let t = CACurrentMediaTime() - start
            if t > 1 { morphStart = nil }
            opacity *= Self.easeInOut(min(1, t / 0.32))
        }
        let changed = container.subviews.last !== carrier || !carrier.frame.isApproximately(frame)
            || abs(carrier.alpha - opacity) > 0.001 || abs(carrier.cornerRadius - radius) > 0.01
        guard changed || morphStart != nil || morphPending else {
            slowDownIfIdle(at: now)
            return
        }
        // Moving: full rate from the very next frame.
        lastMotionAt = now
        if followsSlowly { boost() }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if container.subviews.last !== carrier { container.bringSubviewToFront(carrier) }
        if !carrier.frame.isApproximately(frame) { carrier.frame = frame }
        if abs(carrier.alpha - opacity) > 0.001 { carrier.alpha = opacity }
        carrier.cornerRadius = radius
        carrier.setShadow(width: frame.width, isMini: target.role == .mini)
        CATransaction.commit()
    }

    // MARK: Colors and shape

    /// Clip stills kept on disk: the next time, there at once.
    private static func stillURL(for id: String) -> URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let folder = caches.appendingPathComponent("MusicVideoStills", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("\(id).jpg")
    }

    private func loadThumbnailColors(_ id: String) {
        if let url = Self.stillURL(for: id), let data = try? Data(contentsOf: url), let image = UIImage(data: data) {
            thumbnailImage = image
            NotificationCenter.default.post(name: Self.stateDidChange, object: nil)
        }
        Task { [weak self] in
            // The clip's own 16:9 stills (hq/sd ones are 4:3, cropped):
            // the large one when there is one, else the medium one.
            var still: UIImage?
            // A frame picked from the video itself (the default ones are
            // often a close-up chosen by the channel).
            for name in ["hq720_1", "mq1", "mqdefault"] {
                guard let url = URL(string: "https://i.ytimg.com/vi/\(id)/\(name).jpg"),
                      let (data, response) = try? await URLSession.shared.data(from: url),
                      (response as? HTTPURLResponse)?.statusCode == 200,
                      let image = UIImage(data: data), image.size.width > 200 else { continue }
                still = image
                if let file = Self.stillURL(for: id) { try? data.write(to: file) }
                break
            }
            guard let still else { return }
            let palette = await Task.detached(priority: .utility) { Song.playerUIColors(from: still) }.value
            guard let self, self.videoID == id else { return }
            self.thumbnailImage = still
            NotificationCenter.default.post(name: Self.stateDidChange, object: nil)
            if self.colors == nil, self.shownSongID != nil { self.colors = palette }
        }
    }

    /// A small picture of the frame on screen: its colors for the
    /// background, and black bars, left out of the shape.
    private var lastCanvasFrameAt = Date.distantPast
    private var lastColorsAt = Date.distantPast

    /// The background follows the video's own colors, a few seconds at a
    /// time (scene to scene, not frame to frame).
    private func updateColors(from frame: UIImage) {
        guard shownSongID != nil, Date().timeIntervalSince(lastColorsAt) > 3 else { return }
        lastColorsAt = Date()
        let id = videoID
        Task { [weak self] in
            let palette = await Task.detached(priority: .utility) { Song.playerUIColors(from: frame) }.value
            guard let self, self.videoID == id, self.shownSongID != nil else { return }
            self.colors = palette
        }
    }

    private func sampleFrame() {
        // The page's own frames come first; a snapshot only when they don't.
        guard Date().timeIntervalSince(lastCanvasFrameAt) > (framesFast ? 1 : 2.5) else { return }
        guard videoID != nil, isPlayingNow, !isAd, webView.window != nil, webView.alpha > 0, appIsActive else { return }
        let configuration = WKSnapshotConfiguration()
        configuration.snapshotWidth = 240
        let id = videoID
        webView.takeSnapshot(with: configuration) { [weak self] image, _ in
            MainActor.assumeIsolated {
                guard let self, let image, self.videoID == id,
                      let sample = FrameSample(image), !sample.isBlank else { return }
                self.lastFrameImage = image
                self.updateColors(from: self.lastFrame ?? image)
                NotificationCenter.default.post(name: Self.frameDidChange, object: nil)
            }
        }
    }

    static let frameDidChange = Notification.Name("MusicVideoFrameDidChange")

    nonisolated private static func middle(of image: UIImage) -> UIImage {
        guard let cg = image.cgImage else { return image }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let rect = CGRect(x: w * 0.18, y: h * 0.2, width: w * 0.64, height: h * 0.6).integral
        return cg.cropping(to: rect).map { UIImage(cgImage: $0) } ?? image
    }

    private static func cropped(_ image: UIImage, to aspect: CGFloat) -> UIImage {
        guard let cg = image.cgImage else { return image }
        let width = CGFloat(cg.width), height = min(CGFloat(cg.height), width / aspect)
        let rect = CGRect(x: 0, y: (CGFloat(cg.height) - height) / 2, width: width, height: height).integral
        return cg.cropping(to: rect).map { UIImage(cgImage: $0, scale: image.scale, orientation: image.imageOrientation) } ?? image
    }

    /// The song's cover, or its clip's still while the clip stands in.
    static func coverImage(for source: ArtworkSource?, points: CGFloat) -> UIImage? {
        let player = MusicVideoPlayer.shared
        if let id = player.shownSongID, source == .song(id), let still = player.thumbnail { return still }
        return source.flatMap { ArtworkImageCache.shared.imageSync(for: $0, points: points) }
    }

    /// The music video's rectangle inside a box, centered.
    static func fitted(_ rect: CGRect) -> CGRect {
        guard shared.shownSongID != nil else { return rect }
        return fittedAlways(rect)
    }

    static func fittedAlways(_ rect: CGRect) -> CGRect {
        let player = MusicVideoPlayer.shared
        guard rect.width > 0, rect.height > 0 else { return rect }
        // Fit inside the box: a square cover gets the video's shape, a box
        // already shaped like the video stays as it is.
        let aspect = max(0.3, player.aspect)
        let size = rect.width / rect.height > aspect
            ? CGSize(width: rect.height * aspect, height: rect.height)
            : CGSize(width: rect.width, height: rect.width / aspect)
        return CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
    }

    /// The video's box for a cover of this side: as wide as the cover, or
    /// for an upright clip, as tall as it (never taller than the cover).
    static func videoSize(side: CGFloat) -> CGSize {
        let aspect = max(0.3, shared.aspect)
        return aspect >= 1 ? CGSize(width: side, height: side / aspect) : CGSize(width: side * aspect, height: side)
    }

    func isShown(for source: ArtworkSource?) -> Bool {
        guard let id = shownSongID else { return false }
        return source == .song(id)
    }

    /// The web view's one width: the screen's (its page's device width).
    static let stageWidth: CGFloat = {
        let screen = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen.bounds.size ?? CGSize(width: 393, height: 852)
        return min(screen.width, screen.height)
    }()

    var playerAspect: CGFloat { embedAspect }

    // MARK: Black bars

    /// Where the picture lies in YouTube's player, as fractions of it.
    var stageCrop: CGRect { Self.picture(content, aspect: nativeAspect ?? embedAspect, inBoxOf: embedAspect) }

    /// The shape shown: the picture's, black bars left out.
    private var shownAspect: CGFloat {
        let crop = stageCrop
        guard crop.height > 0 else { return embedAspect }
        return embedAspect * crop.width / crop.height
    }

    /// A video of this shape fitted in a box of that one (YouTube's player,
    /// a still), then the picture within it.
    nonisolated static func picture(_ content: CGRect, aspect: CGFloat, inBoxOf box: CGFloat) -> CGRect {
        guard aspect > 0, box > 0 else { return content }
        let video = aspect > box
            ? CGRect(x: 0, y: (1 - box / aspect) / 2, width: 1, height: box / aspect)
            : CGRect(x: (1 - aspect / box) / 2, y: 0, width: aspect / box, height: 1)
        return CGRect(x: video.minX + content.minX * video.width, y: video.minY + content.minY * video.height,
                      width: content.width * video.width, height: content.height * video.height)
    }

    /// A frame or still with the black bars cut off.
    private func picture(of image: UIImage) -> UIImage {
        guard let cg = image.cgImage, cg.height > 0 else { return image }
        let box = CGFloat(cg.width) / CGFloat(cg.height)
        let crop = Self.picture(content, aspect: nativeAspect ?? box, inBoxOf: box)
        guard crop.width < 0.995 || crop.height < 0.995 else { return image }
        let rect = CGRect(x: crop.minX * CGFloat(cg.width), y: crop.minY * CGFloat(cg.height),
                          width: crop.width * CGFloat(cg.width), height: crop.height * CGFloat(cg.height)).integral
        return cg.cropping(to: rect).map { UIImage(cgImage: $0, scale: image.scale, orientation: image.imageOrientation) } ?? image
    }

    /// The first seconds' frames tell the bars that stay (a dark scene or
    /// a title card says nothing: only bright frames count, and the
    /// picture is everything any of them lit).
    private func sampleBars(_ image: UIImage) {
        guard let id = videoID, MusicVideoBars.saved(for: id) == nil, barSamples.count < 40, !isSamplingBars else { return }
        isSamplingBars = true
        Task { [weak self] in
            let sample = await Task.detached(priority: .utility) { BarSample(image) }.value
            guard let self, self.videoID == id else { return }
            self.isSamplingBars = false
            guard let sample else { return }
            self.barSamples.append(sample)
            guard self.barSamples.count >= 8 else { return }
            let found = BarSample.picture(of: self.barSamples)
            if self.barSamples.count >= 20 { MusicVideoBars.save(found, aspect: sample.aspect, for: id) }
            guard !found.isApproximately(self.content) || self.nativeAspect == nil else { return }
            self.content = found
            self.nativeAspect = sample.aspect
            let shape = self.shownAspect
            if abs(shape - self.aspect) > 0.01 {
                vpLog("bars: picture \(found) shape \(shape)")
                self.boost()
                withAnimation(.spring(duration: 0.6, bounce: 0.12)) { self.aspect = shape }
            }
            let frame = self.lastFrameImage, still = self.thumbnailImage
            self.lastFrameImage = frame
            self.thumbnailImage = still
            self.carrier.setNeedsLayout()
            NotificationCenter.default.post(name: Self.stateDidChange, object: nil)
        }
    }

    // MARK: Page

    /// YouTube wants embeds in apps to name themselves as the referrer:
    /// https:// and the bundle ID. Without it, every video fails.
    private static let origin = URL(string: "https://\(Bundle.main.bundleIdentifier ?? "com.fares.lrc.player")")!

    private static func page(videoID: String, start: Int) -> String {
        """
        <!doctype html><html><head>
        <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">
        <meta name="referrer" content="strict-origin-when-cross-origin">
        <style>html,body{margin:0;padding:0;background:#000;overflow:hidden;width:100%;height:100%}#p{position:absolute;left:0;top:0;width:100%;height:100%;pointer-events:none}</style>
        </head><body><div id="p"></div>
        <script>
        var player = null, ready = false, lead = 0, measuring = false;
        function post(m) { try { window.webkit.messageHandlers.video.postMessage(m) } catch (e) {} }
        function onYouTubeIframeAPIReady() {
          player = new YT.Player('p', {
            videoId: '\(videoID)', width: '100%', height: '100%',
            playerVars: { autoplay: 0, controls: 0, disablekb: 1, fs: 0, iv_load_policy: 3, modestbranding: 1, playsinline: 1, rel: 0, mute: 1, cc_load_policy: 0, start: \(start), origin: '\(origin.absoluteString)', widget_referrer: '\(origin.absoluteString)' },
            events: {
              onReady: function () { player.mute(); ready = true; post({ type: 'ready', duration: player.getDuration() }) },
              onError: function (e) { post({ type: 'error', code: e.data }) }
            }
          });
        }
        function vp_pause() { if (ready && player) player.pauseVideo() }
        function vp_tick(t, play, canSeek, free) {
          if (!ready || !player || !player.getPlayerState) return null;
          var s = player.getPlayerState(), c = player.getCurrentTime() || 0, d = player.getDuration() || 0, seeked = 0;
          if (player.isMuted && !player.isMuted()) player.mute();
          // Full screen in iOS's player: the video leads, the song follows.
          if (free) return [c, s, 1, 0];
          if (t < 0) {
            if (s == 1 || s == 3) player.pauseVideo();
            if (canSeek && c > 0.5) { player.seekTo(0, true); seeked = 1 }
            return [c, s, 0, seeked];
          }
          if (d > 0 && t > d - 0.4) {
            if (s == 1 || s == 3) player.pauseVideo();
            return [c, s, 2, seeked];
          }
          // A seek lands late by its own loading: the next one aims that far
          // ahead. None while loading (it would start over).
          if (measuring && s == 1) {
            measuring = false;
            var late = t - c;
            if (Math.abs(late) < 2) lead = Math.min(Math.max(lead + late * 0.6, 0), 1.5);
          }
          if (canSeek && s != 3 && Math.abs(c - t) > 0.35) { player.seekTo(t + lead, true); seeked = 1; measuring = true }
          if (play && s != 1 && s != 3) player.playVideo();
          if (!play && (s == 1 || s == 3)) player.pauseVideo();
          return [c, s, 1, seeked];
        }
        </script>
        <script src="https://www.youtube.com/iframe_api"></script>
        </body></html>
        """
    }

    /// A merged song's page: the two parts' clips stacked, the second over
    /// the first, shown as much as `mix` says.
    private static func mergedPage(ids: [String], starts: [Int]) -> String {
        """
        <!doctype html><html><head>
        <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">
        <meta name="referrer" content="strict-origin-when-cross-origin">
        <style>html,body{margin:0;padding:0;background:#000;overflow:hidden;width:100%;height:100%}.v{position:absolute;left:0;top:0;width:100%;height:100%;pointer-events:none}#q{opacity:0}</style>
        </head><body><div class="v" id="p"></div><div class="v" id="q"></div>
        <script>
        var P = [null, null], R = [false, false], L = [0, 0], M = [false, false], posted = false, lead = 0;
        var ids = ['\(ids[0])', '\(ids[1])'], starts = [\(starts[0]), \(starts[1])];
        function post(m) { try { window.webkit.messageHandlers.video.postMessage(m) } catch (e) {} }
        function make(i) {
          P[i] = new YT.Player(i ? 'q' : 'p', {
            videoId: ids[i], width: '100%', height: '100%',
            playerVars: { autoplay: 0, controls: 0, disablekb: 1, fs: 0, iv_load_policy: 3, modestbranding: 1, playsinline: 1, rel: 0, mute: 1, cc_load_policy: 0, start: starts[i], origin: '\(origin.absoluteString)', widget_referrer: '\(origin.absoluteString)' },
            events: {
              onReady: function () {
                P[i].mute(); R[i] = true;
                if (R[0] && R[1] && !posted) { posted = true; post({ type: 'ready', duration: P[lead].getDuration() }) }
              },
              onError: function (e) { post({ type: 'error', code: e.data, part: i }) }
            }
          });
        }
        function onYouTubeIframeAPIReady() { make(0); make(1) }
        function vp_pause() { for (var i = 0; i < 2; i++) if (R[i]) P[i].pauseVideo() }
        function drive(i, t, play, canSeek) {
          var p = P[i], s = p.getPlayerState(), c = p.getCurrentTime() || 0, d = p.getDuration() || 0, seeked = 0;
          if (p.isMuted && !p.isMuted()) p.mute();
          if (t < 0) {
            if (s == 1 || s == 3) p.pauseVideo();
            if (canSeek && c > 0.5) { p.seekTo(0, true); seeked = 1 }
            return [c, s, 0, seeked];
          }
          if (d > 0 && t > d - 0.4) {
            if (s == 1 || s == 3) p.pauseVideo();
            return [c, s, 2, seeked];
          }
          if (M[i] && s == 1) {
            M[i] = false;
            var late = t - c;
            if (Math.abs(late) < 2) L[i] = Math.min(Math.max(L[i] + late * 0.6, 0), 1.5);
          }
          if (canSeek && s != 3 && Math.abs(c - t) > 0.35) { p.seekTo(t + L[i], true); seeked = 1; M[i] = true }
          if (play && s != 1 && s != 3) p.playVideo();
          if (!play && (s == 1 || s == 3)) p.pauseVideo();
          return [c, s, 1, seeked];
        }
        function rest(i, at, canSeek) {
          var p = P[i], s = p.getPlayerState(), c = p.getCurrentTime() || 0;
          if (s == 1 || s == 3) p.pauseVideo();
          if (at >= 0 && canSeek && s != 3 && Math.abs(c - at) > 1) p.seekTo(at, true);
          return [c, s, 0, 0];
        }
        function vp_tick2(tA, tB, mix, bWakes, bRest, play, canSeek, free) {
          if (!R[0] || !R[1]) return null;
          lead = mix >= 0.5 ? 1 : 0;
          document.getElementById('q').style.opacity = mix;
          if (free) { var f = P[lead]; return [f.getCurrentTime() || 0, f.getPlayerState(), 1, 0] }
          var a = mix < 1 ? drive(0, tA, play, canSeek) : rest(0, -1, false);
          var b = mix > 0 || bWakes ? drive(1, tB, play, canSeek) : rest(1, bRest, canSeek);
          return lead ? b : a;
        }
        </script>
        <script src="https://www.youtube.com/iframe_api"></script>
        </body></html>
        """
    }

    /// In YouTube's frame: only the video (none of its buttons, icons,
    /// titles or overlays), and word of ads (the cover stays meanwhile).
    private static let frameScript = """
    (function () {
      if (location.hostname.indexOf('youtube') < 0) return;
      // Nothing but the picture: every element hidden, the video shown
      // again (a visible child shows inside a hidden parent).
      var css = 'body *{visibility:hidden!important;pointer-events:none!important}video{visibility:visible!important}' +
        '.html5-video-player>*:not(.html5-video-container){display:none!important}' +
        '.ytp-bezel,.ytp-bezel-text-wrapper,.ytp-pause-overlay,.ytp-large-play-button,.ytp-spinner,.ytp-chrome-top,.ytp-chrome-bottom,.ytp-gradient-top,.ytp-gradient-bottom,.ytp-watermark,.ytp-cued-thumbnail-overlay{display:none!important;opacity:0!important}' +
        'html,body,.html5-video-player{background:#000!important}video{object-fit:contain!important}';
      function addStyle() {
        if (document.getElementById('vp-style')) return;
        var style = document.createElement('style');
        style.id = 'vp-style';
        style.textContent = css;
        (document.head || document.documentElement).appendChild(style);
      }
      addStyle();
      new MutationObserver(addStyle).observe(document.documentElement, { childList: true, subtree: true });
      function fullscreen(on) {
        try { window.webkit.messageHandlers.video.postMessage({ type: 'fullscreen', on: on }) } catch (e) {}
      }
      // Muted for good: iOS's player turns the sound on at a press of the
      // volume buttons, and the clip's sound then takes over the song's.
      document.addEventListener('volumechange', function (e) {
        var v = e.target;
        if (v && v.tagName === 'VIDEO' && !v.muted) v.muted = true;
      }, true);
      document.addEventListener('webkitbeginfullscreen', function () { fullscreen(true) }, true);
      document.addEventListener('webkitendfullscreen', function () { fullscreen(false) }, true);
      var lastAd = null;
      setInterval(function () {
        var p = document.querySelector('.html5-video-player');
        var ad = !!(p && (p.classList.contains('ad-showing') || p.classList.contains('ad-interrupting')));
        if (ad !== lastAd) {
          lastAd = ad;
          try { window.webkit.messageHandlers.video.postMessage({ type: 'ad', ad: ad }) } catch (e) {}
        }
      }, 400);
      // The frame on screen, drawn from the video itself (WebKit's
      // snapshots leave a playing video out): it stands in for the video
      // while that moves.
      // Every 0.35 s while things move (or black bars are being looked
      // for); every 1.5 s at rest, the app asking for one at once when a
      // touch may start a move.
      var canvas = null, fast = true, timer = null;
      function capture() {
        var v = document.querySelector('video');
        if (document.hidden || !v || v.paused || v.readyState < 2 || !v.videoWidth || lastAd) return;
        try {
          canvas = canvas || document.createElement('canvas');
          var w = 480, h = Math.round(w * v.videoHeight / v.videoWidth);
          if (canvas.width !== w || canvas.height !== h) { canvas.width = w; canvas.height = h }
          canvas.getContext('2d').drawImage(v, 0, 0, w, h);
          window.webkit.messageHandlers.video.postMessage({ type: 'frame', data: canvas.toDataURL('image/jpeg', 0.75) });
        } catch (e) {}
      }
      function schedule() {
        clearTimeout(timer);
        timer = setTimeout(function () { capture(); schedule() }, fast ? 350 : 1500);
      }
      window.vp_frames = function (f, now) { fast = f; if (now) capture(); schedule() };
      schedule();
    })();
    """
}

/// How far black bars reach into a bright frame, from each side.
struct BarSample: Sendable {
    let top: CGFloat, bottom: CGFloat, left: CGFloat, right: CGFloat
    /// The frame's width over height (the video's own).
    let aspect: CGFloat

    init?(_ image: UIImage) {
        guard let cg = image.cgImage, cg.width > 16, cg.height > 16 else { return nil }
        let width = cg.width, height = cg.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        // Lit pixels per row and column (a logo in a bar stays a few).
        var rows = [Int](repeating: 0, count: height), columns = [Int](repeating: 0, count: width)
        var total = 0
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
                total += r + g + b
                if max(r, g, b) > 30 { rows[y] += 1; columns[x] += 1 }
            }
        }
        // A dark frame can't tell a bar from the night.
        guard Double(total) / Double(width * height * 3) >= 26 else { return nil }
        let rowLit = max(2, width / 40), columnLit = max(2, height / 40)
        guard let first = rows.firstIndex(where: { $0 > rowLit }), let last = rows.lastIndex(where: { $0 > rowLit }),
              let leading = columns.firstIndex(where: { $0 > columnLit }), let trailing = columns.lastIndex(where: { $0 > columnLit }) else { return nil }
        top = CGFloat(first) / CGFloat(height)
        bottom = CGFloat(height - 1 - last) / CGFloat(height)
        left = CGFloat(leading) / CGFloat(width)
        right = CGFloat(width - 1 - trailing) / CGFloat(width)
        aspect = CGFloat(width) / CGFloat(height)
    }

    /// The picture all the frames lit: bars come in even pairs and most of
    /// the frame stays. Thin bars count too (a few pixels on a 720 px
    /// snapshot), and the cut goes a hair past the bar: its edge is soft
    /// from compression and would otherwise stay as a fine line.
    /// Always a hair cut on every side: a bar of a pixel or two (too thin
    /// to find) or the player's own rounding never shows as a black line.
    static let edge: CGFloat = 0.006

    /// The whole frame, with that hair cut.
    static let full = CGRect(x: edge, y: edge, width: 1 - 2 * edge, height: 1 - 2 * edge)

    static func picture(of samples: [BarSample]) -> CGRect {
        func pair(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
            let bar = min(a, b)
            return abs(a - b) <= 0.03 && bar >= 0.005 ? bar + 0.006 : edge
        }
        var vertical = pair(samples.map(\.top).min() ?? 0, samples.map(\.bottom).min() ?? 0)
        var horizontal = pair(samples.map(\.left).min() ?? 0, samples.map(\.right).min() ?? 0)
        if 1 - 2 * vertical < 0.4 { vertical = edge }
        if 1 - 2 * horizontal < 0.4 { horizontal = edge }
        return CGRect(x: horizontal, y: vertical, width: 1 - 2 * horizontal, height: 1 - 2 * vertical)
    }
}

/// The black bars found in each video, so the next time it starts cut.
@MainActor
enum MusicVideoBars {
    // v2: thin bars and the edge margin; videos measured before sample again.
    private static let key = "musicVideoBars3"
    private static var cache: [String: [Double]] = UserDefaults.standard.dictionary(forKey: key) as? [String: [Double]] ?? [:]

    static func saved(for id: String) -> (content: CGRect, aspect: CGFloat)? {
        guard let v = cache[id], v.count == 5 else { return nil }
        return (CGRect(x: v[0], y: v[1], width: v[2], height: v[3]), CGFloat(v[4]))
    }

    static func save(_ content: CGRect, aspect: CGFloat, for id: String) {
        cache[id] = [content.minX, content.minY, content.width, content.height, aspect].map(Double.init)
        UserDefaults.standard.set(cache, forKey: key)
    }
}

/// What a frame looks like at a glance: blank (black, or not drawn) and
/// how much of its height isn't a black bar.
private struct FrameSample {
    let isBlank: Bool
    let contentFraction: CGFloat?

    init?(_ image: UIImage) {
        guard let cg = image.cgImage, cg.width > 4, cg.height > 4 else { return nil }
        let width = cg.width, height = cg.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        // Each row's brightest pixel.
        var rows = [Int](repeating: 0, count: height)
        for y in 0..<height {
            var brightest = 0
            for x in 0..<width {
                let i = (y * width + x) * 4
                brightest = max(brightest, Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2]))
            }
            rows[y] = brightest
        }
        let dark = 22
        var total = 0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            total += Int(pixels[i]) + Int(pixels[i + 1]) + Int(pixels[i + 2])
        }
        let mean = Double(total) / Double(width * height * 3)
        isBlank = (rows.max() ?? 0) < 30 || mean < 16
        guard !isBlank else { contentFraction = nil; return }
        let top = rows.firstIndex { $0 > dark } ?? 0
        let bottom = height - 1 - (rows.lastIndex { $0 > dark } ?? (height - 1))
        // Bars come in pairs; a dark scene at the top alone isn't one.
        if top > 0 || bottom > 0, abs(top - bottom) <= max(2, height / 20) {
            contentFraction = CGFloat(height - top - bottom) / CGFloat(height)
        } else {
            contentFraction = 1
        }
    }
}

/// Where the video shows: YouTube's player, centered, cut to the frame
/// (so black bars fall outside).
final class MusicVideoHostView: UIView {
    enum Role { case large, compact, mini, flight }

    let role: Role
    private let stillView = UIImageView()
    /// The video lies over this place right now: its still shows under it
    /// (until the video's first frame plays).
    var holds = false {
        didSet { if oldValue != holds { updateHolding() } }
    }

    init(role: Role) {
        self.role = role
        super.init(frame: .zero)
        clipsToBounds = true
        layer.cornerCurve = .continuous
        backgroundColor = .clear
        isUserInteractionEnabled = false
        stillView.isHidden = true
        stillView.contentMode = .scaleAspectFill
        stillView.clipsToBounds = true
        addSubview(stillView)
        NotificationCenter.default.addObserver(self, selector: #selector(update), name: MusicVideoPlayer.stateDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(update), name: MusicVideoPlayer.frameDidChange, object: nil)
        update()
        updateHolding()
    }

    override init(frame: CGRect) { fatalError("init(role:)") }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The still is only seen while holding: no image swaps otherwise.
    @objc private func update() {
        guard holds else { return }
        let still = MusicVideoPlayer.shared.still
        if stillView.image !== still { stillView.image = still }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            MusicVideoPlayer.shared.attach(self)
        } else {
            MusicVideoPlayer.shared.detach(self)
        }
    }

    private func updateHolding() {
        if holds { update() }
        stillView.isHidden = !holds
        backgroundColor = holds ? .black : .clear
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // The video's rectangle, fitted in the place, centered.
        stillView.frame = MusicVideoPlayer.fittedAlways(bounds)
    }
}

/// The video itself, over its place: YouTube's player at its one size
/// (the screen's width: its page lays out at device width, no zoom),
/// scaled to the place's width, centered; and the last frame over it
/// while it draws again after a move.
final class MusicVideoCarrier: UIView {
    /// Rounds and cuts the video; the carrier itself casts the cover's
    /// shadow around it.
    private let clip = UIView()
    private let stage = UIView()
    private let coverView = UIImageView()
    private(set) var covers = false

    var cornerRadius: CGFloat {
        get { clip.layer.cornerRadius }
        set {
            guard clip.layer.cornerRadius != newValue else { return }
            clip.layer.cornerRadius = newValue
            updateShadowPath()
        }
    }

    init(webView: WKWebView) {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        layer.shadowColor = UIColor.black.cgColor
        clip.isUserInteractionEnabled = false
        clip.clipsToBounds = true
        clip.layer.cornerCurve = .continuous
        addSubview(clip)
        stage.isUserInteractionEnabled = false
        stage.frame = webView.bounds
        webView.frame = stage.bounds
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        stage.addSubview(webView)
        clip.addSubview(stage)
        coverView.contentMode = .scaleAspectFill
        coverView.clipsToBounds = true
        coverView.isHidden = true
        clip.addSubview(coverView)
    }

    /// The cover's shadow for a place this wide (a flight's grows and
    /// shrinks between the two).
    func setShadow(width: CGFloat, isMini: Bool) {
        let (opacity, radius, y): (CGFloat, CGFloat, CGFloat)
        if isMini || width < 56 {
            let t = isMini ? 0 : min(1, max(0, (width - 40) / 16))
            (opacity, radius, y) = (0.18 + t * 0.08, 3 + t * 9, 1 + t * 6)
        } else {
            let t = min(1, max(0, (width - 56) / 244))
            (opacity, radius, y) = (0.26 + t * 0.06, 12 + t * 16, 7 + t * 11)
        }
        if abs(CGFloat(layer.shadowOpacity) - opacity) > 0.002 { layer.shadowOpacity = Float(opacity) }
        if abs(layer.shadowRadius - radius) > 0.05 { layer.shadowRadius = radius }
        if abs(layer.shadowOffset.height - y) > 0.05 { layer.shadowOffset = CGSize(width: 0, height: y) }
    }

    private func updateShadowPath() {
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: clip.layer.cornerRadius).cgPath
    }

    override init(frame: CGRect) { fatalError("init(webView:)") }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func cover(with image: UIImage?) {
        guard let image else { return }
        covers = true
        coverView.layer.removeAllAnimations()
        coverView.image = image
        coverView.alpha = 1
        coverView.isHidden = false
    }

    func uncover() {
        guard covers else { return }
        covers = false
        UIView.animate(withDuration: 0.25, delay: 0, options: [.beginFromCurrentState]) {
            self.coverView.alpha = 0
        } completion: { _ in
            guard !self.covers else { return }
            self.coverView.isHidden = true
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        clip.frame = bounds
        coverView.frame = bounds
        updateShadowPath()
        guard bounds.width > 0 else { return }
        let width = MusicVideoPlayer.stageWidth
        let size = CGSize(width: width, height: width / max(0.5, MusicVideoPlayer.shared.playerAspect))
        if stage.bounds.size != size {
            stage.transform = .identity
            stage.bounds = CGRect(origin: .zero, size: size)
            stage.layoutIfNeeded()
        }
        // The picture (black bars left out) fills the place.
        let crop = MusicVideoPlayer.shared.stageCrop
        let picture = CGSize(width: max(1, size.width * crop.width), height: max(1, size.height * crop.height))
        let scale = max(bounds.width / picture.width, bounds.height / picture.height)
        stage.center = CGPoint(x: bounds.midX - (crop.midX - 0.5) * size.width * scale,
                               y: bounds.midY - (crop.midY - 0.5) * size.height * scale)
        stage.transform = CGAffineTransform(scaleX: scale, y: scale)
    }
}

private extension CGRect {
    func isApproximately(_ other: CGRect) -> Bool {
        abs(minX - other.minX) < 0.01 && abs(minY - other.minY) < 0.01
            && abs(width - other.width) < 0.01 && abs(height - other.height) < 0.01
    }
}

struct MusicVideoHost: UIViewRepresentable {
    var role: MusicVideoHostView.Role = .large
    var cornerRadius: CGFloat = 0

    func makeUIView(context: Context) -> MusicVideoHostView { MusicVideoHostView(role: role) }
    func updateUIView(_ view: MusicVideoHostView, context: Context) {
        view.layer.cornerRadius = cornerRadius
        view.setNeedsLayout()
    }
}

/// When the video found isn't the right one: YouTube's other results (or
/// a search of one's own) to pick from, and the video's timing.
struct MusicVideoPickerSheet: View {
    /// The song playing; a merged one has a tab for each part's clip.
    private let playing: Song

    init(song: Song) { playing = song }

    @Environment(\.dismiss) private var dismiss
    @State private var partIndex = 0
    private var parts: [Song] { MusicVideoPlayer.shared.videoSongs(for: playing) }
    /// The part being picked for (the song itself when not merged).
    private var song: Song { parts[min(partIndex, parts.count - 1)] }
    @ObservedObject private var player = MusicVideoPlayer.shared
    @State private var candidates: [MusicVideoCandidate] = []
    @State private var query = ""
    @State private var isSearching = false
    @State private var error: String?
    /// The intro's length (or the outro's).
    @State private var offset: TimeInterval = 0
    @State private var hasOutro = false

    private var choice: MusicVideoChoice { MusicVideoStore.choice(for: song.id) }

    var body: some View {
        NavigationStack {
            List {
                if parts.count > 1 {
                    Section {
                        Picker("Part", selection: $partIndex.animation(.smooth)) {
                            ForEach(parts.indices, id: \.self) { index in
                                Text(parts[index].title).tag(index)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                    } footer: {
                        Text("A merged song: each part plays its own video, with the merge's transition.")
                    }
                }
                if choice.videoID != nil {
                    Section {
                        Picker("Extra in the Clip", selection: Binding(get: { hasOutro }, set: setHasOutro)) {
                            Text("Intro").tag(false)
                            Text("Outro").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(hasOutro ? "Outro Length" : "Intro Length")
                                    .contentTransition(.interpolate)
                                Spacer()
                                Text(offsetText)
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                                    .contentTransition(.numericText())
                            }
                            HStack(spacing: 12) {
                                Button("Earlier", systemImage: "minus") { nudge(-0.5) }
                                    .labelStyle(.iconOnly)
                                    .buttonStyle(.glass)
                                Slider(value: $offset, in: hasOutro ? 0...240 : -60...180, step: 0.1) { editing in
                                    if !editing { player.setPartLength(offset, for: song) }
                                }
                                Button("Later", systemImage: "plus") { nudge(0.5) }
                                    .labelStyle(.iconOnly)
                                    .buttonStyle(.glass)
                            }
                        }
                        if choice.offset != nil {
                            Button("Reset") {
                                player.setOffset(nil, for: song)
                                withAnimation(.smooth) { offset = player.partLength(for: song) }
                            }
                        }
                    } footer: {
                        Text(hasOutro
                             ? "The clip goes on after the song (an ending scene): set how long, and the picture starts with the song."
                             : "The clip starts before the song (an opening scene): set how long. Also shifts a picture that runs ahead of or behind the song.")
                    }
                }
                Section {
                    if isSearching && candidates.isEmpty {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                        .listRowBackground(Color.clear)
                    }
                    ForEach(candidates) { candidate in
                        Button { pick(candidate) } label: { row(candidate) }
                            .buttonStyle(.plain)
                    }
                } header: {
                    if !candidates.isEmpty { Text("Videos on YouTube") }
                } footer: {
                    if let error {
                        Text(error).foregroundStyle(.red)
                    } else if !isSearching && candidates.isEmpty {
                        Text("No videos found. Search for it above.")
                    }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search YouTube")
            .onSubmit(of: .search) { search(query) }
            .navigationTitle("Music Video")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear(perform: loadPart)
        .onChange(of: partIndex) { loadPart() }
        // A video found blocked while the sheet is open gets its mark.
        .onChange(of: player.revision) {
            if let saved = choice.candidates, !saved.isEmpty { candidates = saved }
        }
    }

    private func loadPart() {
        query = YouTubeSearch.query(for: song)
        candidates = choice.candidates ?? []
        hasOutro = player.hasOutro(for: song)
        offset = player.partLength(for: song)
        error = nil
        if candidates.isEmpty { search(nil) }
    }

    private var offsetText: String {
        if hasOutro || offset == 0 { return String(format: "%.1f s", abs(offset)) }
        return String(format: "%@%.1f s", offset > 0 ? "+" : "−", abs(offset))
    }

    private func nudge(_ step: TimeInterval) {
        let range: ClosedRange<TimeInterval> = hasOutro ? 0...240 : -60...180
        withAnimation(.smooth) { offset = min(range.upperBound, max(range.lowerBound, ((offset + step) * 10).rounded() / 10)) }
        player.setPartLength(offset, for: song)
    }

    private func setHasOutro(_ value: Bool) {
        withAnimation(.smooth) { hasOutro = value }
        player.setHasOutro(value, for: song)
        withAnimation(.smooth) { offset = player.partLength(for: song) }
    }

    private func row(_ candidate: MusicVideoCandidate) -> some View {
        HStack(spacing: 12) {
            AsyncImage(url: candidate.thumbnail) { image in
                image.resizable().aspectRatio(16 / 9, contentMode: .fill)
            } placeholder: {
                Rectangle().fill(.quaternary)
            }
            .frame(width: 112, height: 63)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(alignment: .bottomTrailing) {
                Text(YouTubeSearch.durationText(candidate.duration))
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .padding(4)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(candidate.title)
                    .font(.subheadline)
                    .lineLimit(2)
                if candidate.isBlocked == true {
                    Label("Only Plays on YouTube", systemImage: "nosign")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text(candidate.channel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if candidate.id == choice.videoID {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.tint)
            }
        }
        .opacity(candidate.isBlocked == true ? 0.55 : 1)
        .contentShape(Rectangle())
        // New identity only when the row's own marks change: an offset nudge
        // keeps the thumbnails instead of reloading all of them.
        .id("\(candidate.id)-\(candidate.isBlocked == true)-\(candidate.id == choice.videoID)")
    }

    private func pick(_ candidate: MusicVideoCandidate) {
        player.choose(candidate, for: song, byHand: true)
        withAnimation(.smooth) {
            hasOutro = player.hasOutro(for: song)
            offset = player.partLength(for: song)
        }
    }

    private func search(_ text: String?) {
        let typed = text?.trimmingCharacters(in: .whitespaces)
        isSearching = true
        error = nil
        let target = song
        Task {
            do {
                let found = try await player.search(typed?.isEmpty == false ? typed : nil, for: target)
                if target.id == song.id { withAnimation(.smooth) { candidates = found } }
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            isSearching = false
        }
    }
}

/// Extras › Music Videos: the switch and the YouTube key.
struct MusicVideoCard: View {
    @AppStorage(MusicVideoFeature.enabledKey) private var isEnabled = false
    @AppStorage(MusicVideoAutoMode.key) private var autoMode = MusicVideoAutoMode.off.rawValue
    @State private var open = false

    private var autoModeFootnote: LocalizedStringKey {
        switch MusicVideoAutoMode(rawValue: autoMode) ?? .off {
        case .off: "Every song starts with its cover. Tap it to show the video."
        case .associated: "Songs whose video you already watched show it right away."
        case .always: "Opening Now Playing looks up the video of every song (each lookup uses about 1% of the key's daily searches)."
        }
    }
    @State private var key = MusicVideoFeature.apiKey ?? ""
    @State private var backupKey = MusicVideoFeature.backupAPIKey ?? ""

    var body: some View {
        CollapsibleGlassCard(title: "YouTube Videos", systemImage: "play.tv.fill", expanded: $open) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Music Video Instead of Cover", isOn: $isEnabled.animation(.smooth))
                    .onChange(of: isEnabled) { notify() }
                Text("Tap the cover in Now Playing: the song's YouTube music video takes its place, muted and in time with your file. Tap it again for the cover.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if isEnabled {
                    Picker("Show Video", selection: $autoMode) {
                        Text("Tap to Show").tag(MusicVideoAutoMode.off.rawValue)
                        Text("Previously Played Videos").tag(MusicVideoAutoMode.associated.rawValue)
                        Text("Automatically").tag(MusicVideoAutoMode.always.rawValue)
                    }
                    .pickerStyle(.menu)
                    .onChange(of: autoMode) { notify() }
                    Text(autoModeFootnote)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    SecureField("YouTube API Key", text: $key)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .glassEffect(.regular, in: .capsule)
                        .onSubmit(save)
                        .onChange(of: key) { save() }
                    Text("Free: in Google Cloud Console, turn on YouTube Data API v3 and create an API key. About 100 songs can be looked up a day; each one is looked up once.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    SecureField("Backup API Key", text: $backupKey)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .glassEffect(.regular, in: .capsule)
                        .onSubmit(saveBackup)
                        .onChange(of: backupKey) { saveBackup() }
                    Text("Optional: a key from another Google Cloud project, used once the first one runs out of searches for the day.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Link(destination: URL(string: "https://console.cloud.google.com/apis/library/youtube.googleapis.com")!) {
                        Label("Open Google Cloud Console", systemImage: "arrow.up.right.square")
                            .font(.footnote.weight(.medium))
                    }
                }
            }
        }
        .featureTint(FeatureTint.musicVideo)
    }

    private func save() {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != (MusicVideoFeature.apiKey ?? "") else { return }
        MusicVideoFeature.apiKey = trimmed
        notify()
    }

    private func saveBackup() {
        let trimmed = backupKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != (MusicVideoFeature.backupAPIKey ?? "") else { return }
        MusicVideoFeature.backupAPIKey = trimmed
        notify()
    }

    private func notify() {
        MusicVideoPlayer.shared.refresh()
        MotionArtworkState.shared.refresh(for: MusicPlayerService.shared.currentSong)
    }
}

/// Hears every touch in a window without taking part: the video's follow
/// loop speeds up before whatever the touch moves starts moving.
private final class TouchWatcher: UIGestureRecognizer, UIGestureRecognizerDelegate {
    private let onTouch: () -> Void

    init(onTouch: @escaping () -> Void) {
        self.onTouch = onTouch
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        delegate = self
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        onTouch()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        onTouch()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        onTouch()
        state = .failed
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        state = .failed
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRequireFailureOf other: UIGestureRecognizer) -> Bool { false }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool { false }
}
