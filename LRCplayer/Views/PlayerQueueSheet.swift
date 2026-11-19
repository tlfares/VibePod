import SwiftUI

/// "Playing Next": shuffle / repeat, then the upcoming songs, which can be
/// reordered (long press and drag) or removed (swipe).
struct PlayerQueueSheet: View {
    @ObservedObject var playerVM: PlayerViewModel
    @AppStorage(MusicPlayerService.autoMixKey) private var autoMix = false
    @AppTintSelection private var appTint

    private struct QueueItem: Identifiable {
        let index: Int
        let song: Song
        /// Songs can be queued twice, so identity is the queue position.
        var id: String { "\(index)-\(song.id.uuidString)" }
    }

    private var upcoming: [QueueItem] {
        let start = playerVM.currentIndex + 1
        guard playerVM.queue.indices.contains(start) else { return [] }
        return playerVM.queue[start...].enumerated().map { QueueItem(index: start + $0.offset, song: $0.element) }
    }

    var body: some View {
        NavigationStack {
            List {
                if let current = playerVM.currentSong {
                    Section {
                        HStack(spacing: 12) {
                            ArtworkImage(source: current.artworkSource, cornerRadius: 6, points: 52)
                                .frame(width: 52, height: 52)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(current.title)
                                    .font(.headline)
                                    .lineLimit(1)
                                Text(current.artist)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "waveform")
                                .symbolEffect(.variableColor.iterative, isActive: playerVM.isPlaying)
                                .foregroundStyle(playerVM.currentSong?.coverMenuTint ?? .white)
                        }
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                }

                Section {
                    // The list's own side margins, like the songs and headers, so the
                    // capsules line up with everything else. Even space above and
                    // below: the section header below brings its own top padding.
                    controls
                        .listRowInsets(EdgeInsets(top: 14, leading: 16, bottom: 0, trailing: 16))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                .listSectionSeparator(.hidden)
                .listSectionSpacing(0)

                Section {
                    ForEach(upcoming) { item in
                        Button {
                            playerVM.playQueueItem(at: item.index)
                        } label: {
                            SongRow(song: item.song, highlightsCurrent: false)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.clear)
                    }
                    .onMove { source, destination in
                        guard let from = source.first else { return }
                        let offset = playerVM.currentIndex + 1
                        playerVM.moveQueueItem(from: from + offset, to: destination + offset)
                    }
                    .onDelete { offsets in
                        let offset = playerVM.currentIndex + 1
                        for index in offsets.sorted(by: >) {
                            playerVM.removeFromQueue(at: index + offset)
                        }
                    }
                } header: {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Playing Next")
                            .font(.title3.bold())
                            .foregroundStyle(.primary)
                        Spacer()
                        Text(detailText)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .textCase(nil)
                } footer: {
                    if upcoming.isEmpty {
                        Text(playerVM.repeatMode == .all ? "The queue will start over." : "Nothing else is queued.")
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .navigationTitle("Up Next")
            .navigationBarTitleDisplayMode(.inline)
            .animation(.snappy(duration: 0.3), value: playerVM.currentIndex)
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button {
                playerVM.toggleShuffle()
            } label: {
                Label("Shuffle", systemImage: "shuffle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(QueueToggleStyle(isOn: playerVM.shuffleMode == .on, tint: coverTint))

            Button {
                playerVM.toggleRepeat()
            } label: {
                Label(repeatTitle, systemImage: playerVM.repeatMode == .one ? "repeat.1" : "repeat")
                    .contentTransition(.symbolEffect(.replace))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(QueueToggleStyle(isOn: playerVM.repeatMode != .off, tint: coverTint))

            Button {
                autoMix.toggle()
            } label: {
                Label("AutoMix", systemImage: "circlebadge.2.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(QueueToggleStyle(isOn: autoMix, tint: coverTint))
        }
        .font(.subheadline.weight(.semibold))
        .lineLimit(1)
        .minimumScaleFactor(0.75)
    }

    private var repeatTitle: LocalizedStringKey {
        switch playerVM.repeatMode {
        case .off, .all: "Repeat"
        case .one: "Repeat One"
        }
    }

    private var detailText: String {
        let minutes = Int(upcoming.reduce(0) { $0 + $1.song.duration }) / 60
        return String(localized: "\(upcoming.count) songs · \(minutes) min")
    }
}

private extension PlayerQueueSheet {
    /// The playing cover's color, deep enough for white labels.
    var coverTint: Color {
        playerVM.currentSong?.coverTint ?? appTint.color
    }
}

private struct QueueToggleStyle: ButtonStyle {
    let isOn: Bool
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isOn ? Color.white : Color.primary)
            .padding(.vertical, 11)
            .background {
                Capsule().fill(isOn ? tint.opacity(0.62) : .clear)
            }
            .glassEffect(.regular.interactive(), in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.snappy(duration: 0.2), value: configuration.isPressed)
            .animation(.snappy(duration: 0.25), value: isOn)
    }
}

extension Song {
    /// The cover's color, deep enough for white labels (queue toggles).
    var coverTint: Color? {
        guard let first = playerArtworkColors.first else { return nil }
        var hue = CGFloat(0), saturation = CGFloat(0), brightness = CGFloat(0), alpha = CGFloat(0)
        UIColor(first).getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return Color(hue: hue, saturation: saturation < 0.12 ? saturation : max(saturation, 0.45), brightness: min(max(brightness, 0.42), 0.68))
    }

    /// The same hue for icons on a menu's dark glass: lighter, and never
    /// neon, so it reads beside white text. Grey covers stay soft white.
    var coverMenuTint: Color? {
        playerArtworkColors.first.map { Color.menuTint(from: UIColor($0)) }
    }

    /// The cover's colour for system sheets, which can be light or dark:
    /// deeper on light backgrounds, lighter on dark ones.
    var coverSheetTint: UIColor {
        playerArtworkColors.first.map { UIColor.contentTint(from: UIColor($0)) } ?? .label
    }
}

extension UIColor {
    /// A cover or page colour as a tint for text and icons: pale on dark
    /// backgrounds, deeper on light ones. Grey gives the label colour.
    static func contentTint(from color: UIColor) -> UIColor {
        var hue = CGFloat(0), saturation = CGFloat(0), brightness = CGFloat(0), alpha = CGFloat(0)
        color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        guard saturation >= 0.12 else { return .label }
        return UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(hue: hue, saturation: min(max(saturation, 0.12), 0.22), brightness: 1, alpha: 1)
                : UIColor(hue: hue, saturation: min(max(saturation, 0.55), 0.8), brightness: 0.55, alpha: 1)
        }
    }
}

extension Color {
    /// A pale version of a cover or page colour for menu icons on dark
    /// glass: readable beside white text. Grey stays soft white.
    static func menuTint(from color: UIColor) -> Color {
        var hue = CGFloat(0), saturation = CGFloat(0), brightness = CGFloat(0), alpha = CGFloat(0)
        color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        guard saturation >= 0.12 else { return Color(white: 0.88) }
        return Color(hue: hue, saturation: min(max(saturation, 0.12), 0.22), brightness: 1)
    }
}
