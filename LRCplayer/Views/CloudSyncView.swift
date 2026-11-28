import SwiftUI

/// Settings › Tools › Device Sync: turns sync on, picks the main device
/// and links the others to it. Syncing itself happens on its own.
struct CloudSyncView: View {
    @ObservedObject private var sync = CloudSync.shared
    @State private var confirmingPrimary = false
    @AppStorage(CloudSync.resumeOffersKey) private var offersResume = true

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                header
                mainCard
                if sync.isEnabled && sync.isRunning {
                    if sync.primaryID == nil {
                        noPrimaryCard
                            .transition(.opacity.combined(with: .scale(scale: 0.97)))
                    }
                    if !sync.devices.isEmpty {
                        devicesCard
                            .transition(.opacity.combined(with: .scale(scale: 0.97)))
                    }
                }
                contentCard
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 32)
            .animation(.smooth, value: sync.isEnabled)
            .animation(.smooth, value: sync.devices)
            .animation(.smooth, value: sync.primaryID)
            .animation(.smooth, value: sync.status)
        }
        .scrollIndicators(.hidden)
        .refreshable {
            guard sync.isRunning else { return }
            await sync.syncNow()
        }
        .background(Color(uiColor: .settingsBackground).ignoresSafeArea())
        .confirmationDialog(
            "Make This the Main Device?",
            isPresented: $confirmingPrimary,
            titleVisibility: .visible
        ) {
            Button("Make Main Device") { sync.makePrimary() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("When a device is linked, what this device has comes first.")
        }
    }

    // MARK: Sections

    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90.icloud")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 64, height: 64)
                .glassEffect(.regular.tint(AppTint.current.color.opacity(0.25)), in: .circle)
            Text("Device Sync").font(.title2.bold())
            Text("Keep your plays, lyrics, playlists and settings the same on all your devices. Songs themselves stay on each device.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private var mainCard: some View {
        card {
            Toggle("Sync with iCloud", isOn: Binding(
                get: { sync.isEnabled },
                set: { sync.setEnabled($0) }
            ))
            if sync.isEnabled {
                Divider()
                HStack(spacing: 10) {
                    statusIcon
                    VStack(alignment: .leading, spacing: 2) {
                        Text(statusTitle).font(.subheadline.weight(.medium))
                        if let detail = statusDetail {
                            Text(detail)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .contentTransition(.opacity)
                    Spacer()
                }
                Text("Changes are synced on their own, in the background. Pull down to check now.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Divider()
                Toggle("Offer to Resume Playback", isOn: $offersResume)
                    .onChange(of: offersResume) { _, on in
                        if !on { sync.resumeOffer = nil }
                    }
                Text("Shows what was playing on another device, to pick it up here.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Text("Use the same Apple Account on each device, then turn this on everywhere.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch sync.status {
        case .starting, .syncing:
            ProgressView().frame(width: 24)
        case .failed:
            Image(systemName: "exclamationmark.icloud.fill")
                .foregroundStyle(.yellow)
                .frame(width: 24)
        case .upToDate, .off:
            Image(systemName: sync.isActive ? "checkmark.icloud.fill" : "icloud")
                .foregroundStyle(sync.isActive ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                .frame(width: 24)
        }
    }

    private var statusTitle: String {
        switch sync.status {
        case .off, .starting: String(localized: "Connecting to iCloud…")
        case .syncing: String(localized: "Syncing…")
        case .failed: String(localized: "Sync Paused")
        case .upToDate:
            if sync.primaryID == nil { String(localized: "No main device yet") }
            else if !sync.isActive { String(localized: "This device isn't linked") }
            else { String(localized: "Up to Date") }
        }
    }

    private var statusDetail: String? {
        switch sync.status {
        case let .failed(message):
            return message
        case let .upToDate(date):
            guard sync.isActive, let date = date ?? sync.lastSync else { return nil }
            return String(localized: "Last synced \(date.formatted(.relative(presentation: .named)))")
        default:
            return nil
        }
    }

    private var noPrimaryCard: some View {
        card {
            Label("Choose a Main Device", systemImage: "star.circle")
                .font(.headline)
            Text("Pick the device whose library is the reference, like your iPhone. Then link your other devices to it.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button {
                sync.makePrimary()
            } label: {
                Text("Make This the Main Device").frame(maxWidth: .infinity).padding(.vertical, 4)
            }
            .buttonStyle(.glassProminent)
            .padding(.top, 4)
        }
    }

    private var devicesCard: some View {
        card {
            Text("Devices").font(.headline)
            ForEach(Array(sync.devices.enumerated()), id: \.element.id) { offset, device in
                if offset > 0 { Divider() }
                deviceRow(device)
            }
            if sync.isPrimary {
                Text("Linked devices share everything with this one. When you link one, what this device has comes first.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if sync.primaryID != nil {
                Text("Turn on Device Sync on a device, then link it here or from the main device.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Make This the Main Device") { confirmingPrimary = true }
                    .buttonStyle(.glass)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4)
            }
        }
    }

    private func deviceRow(_ device: SyncDevice) -> some View {
        let isMe = device.id == sync.deviceID
        let isMain = device.id == sync.primaryID
        return HStack(spacing: 12) {
            Image(systemName: device.kind.systemImage)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(device.name)
                    if isMe {
                        Text("This Device")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(deviceDetail(device, isMain: isMain, isMe: isMe))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !isMain, sync.primaryID != nil, isMe || sync.isPrimary {
                Button(device.isLinked ? "Unlink" : "Link") {
                    sync.setLinked(!device.isLinked, device: device.id)
                }
                .buttonStyle(.glass)
                .tint(device.isLinked ? .secondary : .accentColor)
            }
        }
    }

    private func deviceDetail(_ device: SyncDevice, isMain: Bool, isMe: Bool) -> String {
        let state = isMain
            ? String(localized: "Main device")
            : (device.isLinked ? String(localized: "Linked") : String(localized: "Not linked"))
        guard !isMe else { return state }
        return state + " · " + device.lastSeen.formatted(.relative(presentation: .named))
    }

    private var contentCard: some View {
        card {
            Text("What's Synced").font(.headline)
            VStack(alignment: .leading, spacing: 10) {
                item("Plays, play counts and stats", systemImage: "chart.bar.fill")
                item("Lyrics, word by word sync and singers", systemImage: "quote.bubble.fill")
                item("Playlists and Autolists", systemImage: "music.note.list")
                item("Programs", systemImage: "calendar.badge.clock")
                item("Song details you edited", systemImage: "pencil")
                item("Imported listening history", systemImage: "clock.arrow.circlepath")
                item("Assistant conversation and memories", systemImage: "sparkles")
                item("Settings, pins and game scores", systemImage: "gearshape.fill")
                item("API keys and music server sign-in", systemImage: "key.fill")
                item("What's playing, to pick it up elsewhere", systemImage: "play.circle.fill")
            }
            Divider()
            Text("Not Synced").font(.headline)
            VStack(alignment: .leading, spacing: 10) {
                item("Song files and merged songs (use Library Transfer or the Finder)", systemImage: "waveform", muted: true)
                item("Artwork you changed", systemImage: "photo", muted: true)
                item("Settings that belong to one device (volume, layout, permissions)", systemImage: "iphone", muted: true)
                item("Discord connection", systemImage: "bubble.left.and.bubble.right", muted: true)
            }
            Text("Everything is stored in your private iCloud database. Keys are encrypted.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
    }

    private func item(_ title: LocalizedStringKey, systemImage: String, muted: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(muted ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                .frame(width: 24)
            Text(title)
                .font(.subheadline)
                .foregroundStyle(muted ? .secondary : .primary)
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12, content: content)
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: .rect(cornerRadius: 28))
    }
}
