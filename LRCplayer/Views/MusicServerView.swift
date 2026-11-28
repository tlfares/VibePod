import SwiftUI
import UIKit
import Combine

/// Settings › Tools › Music Server: sign in to an OpenSubsonic server
/// (Navidrome, Gonic, Airsonic…), sync it, manage the downloads.
struct MusicServerView: View {
    @ObservedObject private var service = SubsonicService.shared
    @ObservedObject private var downloads = SubsonicDownloads.shared
    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var confirmSignOut = false
    @State private var confirmRemoveDownloads = false
    @FocusState private var focus: Field?

    private enum Field { case server, username, password }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Stream your own music from a Navidrome, Gonic, Airsonic or any other Subsonic-compatible server. Songs play over the network; download the ones you want offline from an album, a playlist or a song's menu.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if service.isConfigured {
                    accountCard
                        .transition(.blurReplace)
                    downloadsCard
                        .transition(.blurReplace)
                } else {
                    signInCard
                        .transition(.blurReplace)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .animation(.smooth, value: service.isConfigured)
            .animation(.smooth, value: service.isSyncing)
        }
        .scrollDismissesKeyboard(.interactively)
        .confirmationDialog("Sign Out?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) {
                withAnimation(.smooth) { service.disconnect() }
            }
        } message: {
            Text("The server's songs, playlists and downloads leave your library. Your server isn't changed.")
        }
        .confirmationDialog("Remove All Downloads?", isPresented: $confirmRemoveDownloads, titleVisibility: .visible) {
            Button("Remove Downloads", role: .destructive) {
                downloads.cancelAll()
                downloads.removeAllFiles()
            }
        } message: {
            Text("The songs stay in your library and stream again.")
        }
    }

    // MARK: - Sign in

    private var signInCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            field("Server", text: $server, prompt: "music.example.com", systemImage: "server.rack", field: .server)
                .keyboardType(.URL)
                .textContentType(.URL)
            Divider()
            field("Username", text: $username, prompt: String(localized: "Username"), systemImage: "person", field: .username)
                .textContentType(.username)
            Divider()
            HStack(spacing: 12) {
                Image(systemName: "key")
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .focused($focus, equals: .password)
                    .submitLabel(.go)
                    .onSubmit(connect)
            }
            if case let .failed(message) = service.state {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .transition(.blurReplace)
            }
            Button(action: connect) {
                Group {
                    if service.state == .connecting || service.isSyncing {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text(service.syncStatus ?? String(localized: "Connecting…"))
                                .contentTransition(.numericText())
                        }
                    } else {
                        Text("Connect")
                    }
                }
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .disabled(!canConnect)
        }
        .padding(16)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .animation(.smooth, value: service.state)
    }

    private func field(_ title: LocalizedStringKey, text: Binding<String>, prompt: String, systemImage: String, field: Field) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 24)
            TextField(title, text: text, prompt: Text(prompt))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focus, equals: field)
                .submitLabel(.next)
                .onSubmit { focus = field == .server ? .username : .password }
        }
    }

    private var canConnect: Bool {
        SubsonicService.normalizedServer(server) != nil
            && !username.trimmingCharacters(in: .whitespaces).isEmpty
            && !password.isEmpty
            && service.state != .connecting
            && !service.isSyncing
    }

    private func connect() {
        guard canConnect, SettingsSwipe.allowsTaps else { return }
        focus = nil
        let password = password
        Task {
            await service.connect(server: server, username: username, password: password)
            if service.isConfigured { self.password = "" }
        }
    }

    // MARK: - Connected

    private var accountCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "server.rack")
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(service.serverURL?.host ?? "")
                        .font(.headline)
                        .lineLimit(1)
                    Text(accountDetail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(remoteSongCount) songs")
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text(syncDetail)
                        .font(.footnote)
                        .foregroundStyle(syncFailed ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                        .contentTransition(.numericText())
                }
                Spacer()
                Button {
                    guard SettingsSwipe.allowsTaps else { return }
                    Task { await service.sync() }
                } label: {
                    if service.isSyncing {
                        ProgressView()
                    } else {
                        Label("Sync", systemImage: "arrow.clockwise")
                    }
                }
                .buttonStyle(.glass)
                .disabled(service.isSyncing)
            }
            Divider()
            Button("Sign Out", role: .destructive) {
                guard SettingsSwipe.allowsTaps else { return }
                confirmSignOut = true
            }
            .disabled(service.isSyncing)
        }
        .padding(16)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var downloadsCard: some View {
        let _ = downloads.revision
        let count = downloads.downloadedCount
        let pending = downloads.progress.count
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Downloads", systemImage: "arrow.down.circle")
                Spacer()
                Text(count == 0 ? String(localized: "None") : "\(count) · \(ByteCountFormatter.string(fromByteCount: downloads.totalBytes, countStyle: .file))")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            if pending > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: overallProgress)
                    HStack {
                        Text("\(pending) left")
                            .monospacedDigit()
                            .contentTransition(.numericText())
                        Spacer()
                        Button("Cancel") {
                            guard SettingsSwipe.allowsTaps else { return }
                            downloads.cancelAll()
                        }
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                .transition(.blurReplace)
            }
            if count > 0 {
                Divider()
                Button("Remove All Downloads", role: .destructive) {
                    guard SettingsSwipe.allowsTaps else { return }
                    confirmRemoveDownloads = true
                }
            }
        }
        .padding(16)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .animation(.smooth, value: pending)
    }

    private var overallProgress: Double {
        let values = downloads.progress.values
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    private var remoteSongCount: Int {
        SubsonicService.shared.library?.songs.reduce(0) { $0 + ($1.isRemote ? 1 : 0) } ?? 0
    }

    private var accountDetail: String {
        [service.username, service.serverDescription].compactMap { $0 }.joined(separator: " · ")
    }

    private var syncFailed: Bool {
        if case .failed = service.state { return true }
        return false
    }

    private var syncDetail: String {
        if let status = service.syncStatus { return status }
        if case let .failed(message) = service.state { return message }
        guard let lastSync = service.lastSync else { return String(localized: "Never synced") }
        return String(localized: "Synced \(lastSync.formatted(.relative(presentation: .named)))")
    }
}

/// Download actions for an album or a playlist's menu, when it holds
/// server songs.
struct DownloadMenuSection: View {
    let songs: [Song]
    @ObservedObject private var downloads = SubsonicDownloads.shared

    var body: some View {
        let _ = downloads.revision
        let remote = songs.filter(\.isRemote)
        if !remote.isEmpty {
            let pending = remote.filter(downloads.isPending)
            let downloaded = remote.filter(\.isDownloaded)
            let missing = remote.filter { !downloads.isPending($0) && !$0.isDownloaded }
            Section {
                if !missing.isEmpty {
                    Button("Download", systemImage: "arrow.down.circle") { downloads.download(missing) }
                }
                if !pending.isEmpty {
                    Button("Cancel Download", systemImage: "xmark.circle") { downloads.cancel(pending) }
                }
                if !downloaded.isEmpty {
                    Button("Remove Download", destructiveImage: "arrow.down.circle.dotted") {
                        downloads.removeDownloads(downloaded)
                    }
                }
            }
        }
    }
}

/// The small mark beside a server song: downloaded, or a progress ring
/// while it downloads. Follows the downloads by itself.
final class DownloadBadgeView: UIView {
    private let imageView = UIImageView()
    private let trackLayer = CAShapeLayer()
    private let ringLayer = CAShapeLayer()
    private var songID: UUID?
    private var song: Song?
    private var cancellable: AnyCancellable?
    private static let side: CGFloat = 13

    init(tint: UIColor) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        tintColor = tint
        imageView.image = UIImage(systemName: "arrow.down.circle.fill")
        imageView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        for layer in [trackLayer, ringLayer] {
            layer.fillColor = UIColor.clear.cgColor
            layer.lineWidth = 2
            layer.lineCap = .round
            self.layer.addSublayer(layer)
        }
        ringLayer.strokeEnd = 0
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.side),
            heightAnchor.constraint(equalToConstant: Self.side),
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:)") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let path = UIBezierPath(
            arcCenter: CGPoint(x: bounds.midX, y: bounds.midY),
            radius: Self.side / 2 - 1,
            startAngle: -.pi / 2,
            endAngle: .pi * 1.5,
            clockwise: true
        ).cgPath
        trackLayer.path = path
        ringLayer.path = path
    }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        trackLayer.strokeColor = tintColor.withAlphaComponent(0.25).cgColor
        ringLayer.strokeColor = tintColor.cgColor
    }

    func configure(song: Song) {
        guard song.isRemote else {
            self.song = nil
            songID = nil
            cancellable = nil
            isHidden = true
            return
        }
        let changed = songID != song.id
        self.song = song
        songID = song.id
        if cancellable == nil {
            let downloads = SubsonicDownloads.shared
            cancellable = downloads.$progress.map { _ in () }
                .merge(with: downloads.$revision.map { _ in () })
                .receive(on: DispatchQueue.main)
                .sink { [weak self] in self?.update(animated: true) }
        }
        update(animated: !changed)
    }

    private func update(animated: Bool) {
        guard let song else { isHidden = true; return }
        tintColorDidChange()
        if let progress = SubsonicDownloads.shared.progress[song.id] {
            isHidden = false
            imageView.isHidden = true
            trackLayer.isHidden = false
            ringLayer.isHidden = false
            CATransaction.begin()
            CATransaction.setDisableActions(!animated)
            ringLayer.strokeEnd = max(0.06, progress)
            CATransaction.commit()
        } else if song.isDownloaded {
            isHidden = false
            trackLayer.isHidden = true
            ringLayer.isHidden = true
            if imageView.isHidden, animated {
                imageView.isHidden = false
                imageView.transform = CGAffineTransform(scaleX: 0.4, y: 0.4)
                imageView.alpha = 0
                UIView.animate(withDuration: 0.4, delay: 0, usingSpringWithDamping: 0.7, initialSpringVelocity: 0) {
                    self.imageView.transform = .identity
                    self.imageView.alpha = 1
                }
            } else {
                imageView.isHidden = false
            }
        } else {
            isHidden = true
        }
    }
}
