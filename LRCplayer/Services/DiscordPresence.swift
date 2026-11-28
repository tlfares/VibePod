import Foundation
import Combine
import Security
#if !targetEnvironment(macCatalyst)
import DiscordC

/// Discord Rich Presence: "Listening to" the song playing, on the user's
/// Discord profile, through Discord's Social SDK. Off by default; the user
/// links their account once (OAuth in Discord), and the refresh token stays
/// in the Keychain.
@MainActor
final class DiscordPresence: ObservableObject {
    static let shared = DiscordPresence()

    static let enabledKey = "discordPresenceEnabled"
    nonisolated static let isSupported = true
    static let applicationID: UInt64 = 1565851662101254224

    enum State: Equatable {
        case unlinked
        case linking
        case connecting
        case ready(String?)
        case failed(String)
    }

    @Published private(set) var state: State = .unlinked
    @Published private(set) var userName: String?

    var isEnabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }
    var isLinked: Bool { DiscordKeychain.read() != nil }

    private var client = Discord_Client()
    private var hasClient = false
    private var pump: Timer?
    private var observers: Set<AnyCancellable> = []
    /// Album covers found online, by "artist|album" ("" when none).
    private var covers: [String: String] = [:]
    private var lastSent: String?
    private var lastStart: TimeInterval = 0

    private init() {}

    // MARK: Lifecycle

    /// At launch and whenever the switch moves.
    func refresh() {
        guard isEnabled else {
            shutDown()
            return
        }
        guard let refreshToken = DiscordKeychain.read() else {
            state = .unlinked
            return
        }
        startClient()
        guard state != .connecting, !isReady else { return }
        state = .connecting
        call { client, box in
            DiscordString.with(refreshToken) { token in
                Discord_Client_RefreshToken(client, Self.applicationID, token, DiscordCallbacks.tokenExchange, DiscordCallbacks.release, box)
            }
        } done: { [weak self] (result: TokenResult) in
            self?.received(result)
        }
    }

    /// Opens Discord (or its web page) to let the app set the user's status.
    func link() {
        startClient()
        state = .linking
        var verifier = Discord_AuthorizationCodeVerifier()
        Discord_Client_CreateAuthorizationCodeVerifier(&client, &verifier)
        var challenge = Discord_AuthorizationCodeChallenge()
        Discord_AuthorizationCodeVerifier_Challenge(&verifier, &challenge)
        var verifierString = Discord_String()
        Discord_AuthorizationCodeVerifier_Verifier(&verifier, &verifierString)
        let codeVerifier = DiscordString.take(verifierString)
        Discord_AuthorizationCodeVerifier_Drop(&verifier)

        var args = Discord_AuthorizationArgs()
        Discord_AuthorizationArgs_Init(&args)
        Discord_AuthorizationArgs_SetClientId(&args, Self.applicationID)
        var scopes = Discord_String()
        Discord_Client_GetDefaultPresenceScopes(&scopes)
        Discord_AuthorizationArgs_SetScopes(&args, scopes)
        Discord_Free(scopes.ptr)
        Discord_AuthorizationArgs_SetCodeChallenge(&args, &challenge)
        Discord_AuthorizationCodeChallenge_Drop(&challenge)

        call { client, box in
            Discord_Client_Authorize(client, &args, DiscordCallbacks.authorization, DiscordCallbacks.release, box)
        } done: { [weak self] (result: AuthorizationResult) in
            guard let self else { return }
            guard result.error == nil, !result.code.isEmpty else {
                self.state = .failed(result.error ?? String(localized: "Cancelled"))
                return
            }
            self.call { client, box in
                DiscordString.with(result.code) { code in
                    DiscordString.with(codeVerifier) { verifier in
                        DiscordString.with(result.redirectURI) { redirect in
                            Discord_Client_GetToken(client, Self.applicationID, code, verifier, redirect, DiscordCallbacks.tokenExchange, DiscordCallbacks.release, box)
                        }
                    }
                }
            } done: { [weak self] (result: TokenResult) in
                self?.received(result)
            }
        }
        Discord_AuthorizationArgs_Drop(&args)
    }

    /// Forgets the account and clears the status.
    func unlink() {
        DiscordKeychain.delete()
        shutDown()
        state = .unlinked
        userName = nil
    }

    private var isReady: Bool {
        if case .ready = state { return true }
        return false
    }

    private func startClient() {
        guard !hasClient else { return }
        Discord_Client_Init(&client)
        Discord_Client_SetApplicationId(&client, Self.applicationID)
        // The app owns the audio session: the SDK must never reconfigure it.
        Discord_Client_SetEngineManagedAudioSession(&client, true)
        hasClient = true
        // The SDK answers only when its callbacks are run.
        pump = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in Discord_RunCallbacks() }
        observe()
    }

    private func shutDown() {
        guard hasClient else { return }
        Discord_Client_ClearRichPresence(&client)
        Discord_Client_Disconnect(&client)
        // Lets the clear and the disconnect go out before the client goes.
        let pump = pump
        self.pump = nil
        observers = []
        lastSent = nil
        Task { @MainActor in
            for _ in 0..<10 {
                Discord_RunCallbacks()
                try? await Task.sleep(for: .milliseconds(100))
            }
            pump?.invalidate()
            if !self.hasClient || self.pump == nil {
                Discord_Client_Drop(&self.client)
                self.client = Discord_Client()
                self.hasClient = false
            }
        }
        if case .failed = state {} else { state = isLinked ? .connecting : .unlinked }
    }

    private func received(_ result: TokenResult) {
        guard result.error == nil, !result.accessToken.isEmpty else {
            // A refused refresh token: link again.
            DiscordKeychain.delete()
            state = .failed(result.error ?? String(localized: "Discord refused the sign-in"))
            return
        }
        DiscordKeychain.write(result.refreshToken)
        guard isEnabled else { return }
        state = .connecting
        call { client, box in
            DiscordString.with(result.accessToken) { token in
                Discord_Client_UpdateToken(client, Discord_AuthorizationTokenType_Bearer, token, DiscordCallbacks.plain, DiscordCallbacks.release, box)
            }
        } done: { [weak self] (result: PlainResult) in
            guard let self else { return }
            if let error = result.error {
                self.state = .failed(error)
                return
            }
            self.watchStatus()
            Discord_Client_Connect(&self.client)
        }
    }

    private func watchStatus() {
        call { client, box in
            Discord_Client_SetStatusChangedCallback(client, DiscordCallbacks.status, DiscordCallbacks.release, box)
        } done: { [weak self] (status: StatusResult) in
            guard let self else { return }
            if status.status == Discord_Client_Status_Ready {
                self.state = .ready(self.userName)
                self.lastSent = nil
                self.update()
            } else if status.status == Discord_Client_Status_Disconnected, self.isReady {
                self.state = .connecting
            }
        }
    }

    // MARK: Presence

    private func observe() {
        let player = MusicPlayerService.shared
        Publishers.CombineLatest(player.$currentSong.removeDuplicates { $0?.id == $1?.id }, player.$isPlaying.removeDuplicates())
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] _, _ in self?.update() }
            .store(in: &observers)
        // A seek moves the elapsed time Discord counts from: checked now
        // and then rather than on every playback tick.
        Timer.publish(every: 3, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.update() }
            .store(in: &observers)
    }

    private func update() {
        guard isReady, isEnabled else { return }
        let player = MusicPlayerService.shared
        // Private Listening shows nothing, as if paused.
        guard let song = player.currentSong, player.isPlaying, !PrivateListening.isOn else {
            if lastSent != "" {
                lastSent = ""
                Discord_Client_ClearRichPresence(&client)
            }
            return
        }
        let key = "\(song.artist)|\(song.album)"
        guard let cover = covers[key] else {
            Task { [weak self] in
                let url = await Self.coverURL(artist: song.artist, album: song.album, title: song.title)
                self?.covers[key] = url ?? ""
                self?.update()
            }
            return
        }
        let start = Date().addingTimeInterval(-player.currentTime)
        let signature = "\(song.id)|\(cover)"
        guard signature != lastSent || abs(start.timeIntervalSince1970 - lastStart) > 2 else { return }
        lastSent = signature
        lastStart = start.timeIntervalSince1970

        var activity = Discord_Activity()
        Discord_Activity_Init(&activity)
        Discord_Activity_SetType(&activity, Discord_ActivityTypes_Listening)
        // The profile says "Listening to <artist>", like streaming apps.
        var display = Discord_StatusDisplayTypes_State
        Discord_Activity_SetStatusDisplayType(&activity, &display)
        DiscordString.with(song.title) { var value = $0; Discord_Activity_SetDetails(&activity, &value) }
        DiscordString.with(song.artist) { var value = $0; Discord_Activity_SetState(&activity, &value) }

        var assets = Discord_ActivityAssets()
        Discord_ActivityAssets_Init(&assets)
        // The album's cover when Apple's catalog has that very album, else
        // the app's logo (the "logo" art asset in the Discord portal).
        DiscordString.with(cover.isEmpty ? "logo" : cover) { var value = $0; Discord_ActivityAssets_SetLargeImage(&assets, &value) }
        if !song.album.isEmpty {
            DiscordString.with(song.album) { var value = $0; Discord_ActivityAssets_SetLargeText(&assets, &value) }
        }
        Discord_Activity_SetAssets(&activity, &assets)
        Discord_ActivityAssets_Drop(&assets)

        var timestamps = Discord_ActivityTimestamps()
        Discord_ActivityTimestamps_Init(&timestamps)
        Discord_ActivityTimestamps_SetStart(&timestamps, UInt64(start.timeIntervalSince1970 * 1000))
        if player.duration > 0 {
            Discord_ActivityTimestamps_SetEnd(&timestamps, UInt64(start.addingTimeInterval(player.duration).timeIntervalSince1970 * 1000))
        }
        Discord_Activity_SetTimestamps(&activity, &timestamps)
        Discord_ActivityTimestamps_Drop(&timestamps)

        call { client, box in
            Discord_Client_UpdateRichPresence(client, &activity, DiscordCallbacks.plain, DiscordCallbacks.release, box)
        } done: { [weak self] (result: PlainResult) in
            if result.error != nil { self?.lastSent = nil }
        }
        Discord_Activity_Drop(&activity)
    }

    /// The album's cover from Apple's public catalog, for Discord to show:
    /// local artwork has no URL.
    private static func coverURL(artist: String, album: String, title: String) async -> String? {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        let useAlbum = !album.isEmpty
        components.queryItems = [
            URLQueryItem(name: "term", value: "\(artist) \(useAlbum ? album : title)"),
            URLQueryItem(name: "entity", value: useAlbum ? "album" : "song"),
            URLQueryItem(name: "limit", value: "5")
        ]
        guard let url = components.url, let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        struct Reply: Decodable {
            struct Item: Decodable {
                let artistName: String?
                let collectionName: String?
                let artworkUrl100: String?
            }
            let results: [Item]
        }
        guard let items = (try? JSONDecoder().decode(Reply.self, from: data))?.results else { return nil }
        // Only the same album by the same artist: a near miss showed another
        // record's cover, worse than the logo.
        let wantedArtist = AssistantText.normalize(artist)
        let wantedAlbum = AssistantText.normalize(AssistantText.baseTitle(album))
        let match = useAlbum ? items.first { item in
            let found = AssistantText.normalize(item.artistName ?? "")
            let foundAlbum = AssistantText.normalize(AssistantText.baseTitle(item.collectionName ?? ""))
            return !found.isEmpty && (found == wantedArtist || AssistantText.containsWords(found, wantedArtist))
                && (foundAlbum == wantedAlbum || AssistantText.similarity(foundAlbum, wantedAlbum) >= 0.9)
        } : nil
        return match?.artworkUrl100?.replacingOccurrences(of: "100x100bb", with: "512x512bb")
    }

    // MARK: Callbacks

    /// Runs `start` with a box the SDK hands back to its callback, which
    /// calls `done` on the main actor.
    private func call<Result>(_ start: (UnsafeMutablePointer<Discord_Client>, UnsafeMutableRawPointer) -> Void, done: @escaping @MainActor (Result) -> Void) {
        let box = Unmanaged.passRetained(DiscordCallbackBox { value in
            guard let value = value as? Result else { return }
            MainActor.assumeIsolated { done(value) }
        }).toOpaque()
        withUnsafeMutablePointer(to: &client) { start($0, box) }
    }
}

// MARK: - SDK glue

struct AuthorizationResult { let error: String?; let code: String; let redirectURI: String }
struct TokenResult { let error: String?; let accessToken: String; let refreshToken: String }
struct PlainResult { let error: String? }
struct StatusResult { let status: Discord_Client_Status }

final class DiscordCallbackBox {
    let deliver: (Any) -> Void
    init(_ deliver: @escaping (Any) -> Void) { self.deliver = deliver }

    static func from(_ pointer: UnsafeMutableRawPointer?) -> DiscordCallbackBox? {
        pointer.map { Unmanaged<DiscordCallbackBox>.fromOpaque($0).takeUnretainedValue() }
    }
}

/// C callbacks: they can't capture, so each reads its box from userData.
/// Discord_RunCallbacks calls them on the main thread.
enum DiscordCallbacks {
    static let release: Discord_FreeFn = { pointer in
        if let pointer { Unmanaged<DiscordCallbackBox>.fromOpaque(pointer).release() }
    }

    static let plain: Discord_Client_UpdateTokenCallback = { result, userData in
        DiscordCallbackBox.from(userData)?.deliver(PlainResult(error: error(result)))
    }

    static let authorization: Discord_Client_AuthorizationCallback = { result, code, redirectURI, userData in
        let value = AuthorizationResult(error: error(result), code: DiscordString.take(code), redirectURI: DiscordString.take(redirectURI))
        DiscordCallbackBox.from(userData)?.deliver(value)
    }

    static let tokenExchange: Discord_Client_TokenExchangeCallback = { result, access, refresh, _, _, scopes, userData in
        Discord_Free(scopes.ptr)
        let value = TokenResult(error: error(result), accessToken: DiscordString.take(access), refreshToken: DiscordString.take(refresh))
        DiscordCallbackBox.from(userData)?.deliver(value)
    }

    static let status: Discord_Client_OnStatusChanged = { status, _, _, userData in
        DiscordCallbackBox.from(userData)?.deliver(StatusResult(status: status))
    }

    /// nil on success; the result is the callback's to drop.
    private static func error(_ result: UnsafeMutablePointer<Discord_ClientResult>?) -> String? {
        guard let result else { return String(localized: "No result") }
        defer { Discord_ClientResult_Drop(result) }
        if Discord_ClientResult_Successful(result) { return nil }
        var message = Discord_String()
        Discord_ClientResult_Error(result, &message)
        let text = DiscordString.take(message)
        return text.isEmpty ? String(localized: "Discord error") : text
    }
}

enum DiscordString {
    static func with<T>(_ text: String, _ body: (Discord_String) -> T) -> T {
        var bytes = Array(text.utf8)
        return bytes.withUnsafeMutableBufferPointer { buffer in
            body(Discord_String(ptr: buffer.baseAddress, size: buffer.count))
        }
    }

    /// Copies an SDK-owned string and frees it.
    static func take(_ string: Discord_String) -> String {
        defer { Discord_Free(string.ptr) }
        guard let pointer = string.ptr, string.size > 0 else { return "" }
        return String(decoding: UnsafeBufferPointer(start: pointer, count: string.size), as: UTF8.self)
    }
}

/// The refresh token, the only secret kept.
private enum DiscordKeychain {
    private static var query: [String: Any] { [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.fares.lrc.player.discord",
        kSecAttrAccount as String: "refreshToken"
    ] }

    static func read() -> String? {
        var item: CFTypeRef?
        var search = query
        search[kSecReturnData as String] = true
        guard SecItemCopyMatching(search as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String) {
        delete()
        var item = query
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(item as CFDictionary, nil)
    }

    static func delete() {
        SecItemDelete(query as CFDictionary)
    }
}

#else

/// Discord's Social SDK has no Mac Catalyst build: no Rich Presence on Mac.
@MainActor
final class DiscordPresence: ObservableObject {
    static let shared = DiscordPresence()
    static let enabledKey = "discordPresenceEnabled"
    nonisolated static let isSupported = false

    enum State: Equatable { case unlinked, linking, connecting, ready(String?), failed(String) }

    @Published private(set) var state: State = .unlinked
    var isLinked: Bool { false }

    private init() {}

    func refresh() {}
    func link() {}
    func unlink() {}
}

#endif
