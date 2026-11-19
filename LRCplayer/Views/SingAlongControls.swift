import SwiftUI

/// How the separation's progress shows in the lyrics.
enum SingAlongProgressStyle: String, CaseIterable {
    case ring, pill

    static let storageKey = "singAlongProgressStyle"

    var title: String {
        switch self {
        case .ring: String(localized: "Ring")
        case .pill: String(localized: "Pill")
        }
    }

    var symbol: String {
        switch self {
        case .ring: "circle.dashed"
        case .pill: "capsule.fill"
        }
    }
}

/// The lyrics' microphone: turns the vocals down, with their level on a
/// slider above it while it's on.
struct SingAlongButton: View {
    @ObservedObject private var model = SingAlongModel.shared
    @ObservedObject private var singAlong = SingAlong.shared
    @AppStorage(SingAlongProgressStyle.storageKey) private var progressStyle = SingAlongProgressStyle.ring

    var body: some View {
        if model.isInstalled {
            VStack(spacing: 10) {
                if singAlong.isOn {
                    VocalLevelSlider(level: $singAlong.level)
                        .transition(.opacity.combined(with: .scale(scale: 0.6, anchor: .bottom)))
                }
                Button {
                    withAnimation(.smooth(duration: 0.35)) { singAlong.toggle() }
                } label: {
                    Image(systemName: "music.microphone")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(singAlong.isOn ? .black : .white)
                        .frame(width: 46, height: 46)
                        .background {
                            Circle().fill(.white.opacity(singAlong.isOn ? 0.92 : 0))
                        }
                        .overlay {
                            // Separation under way, from where the song plays.
                            if progressStyle == .ring, singAlong.isOn, singAlong.progress < 1 {
                                Circle()
                                    .trim(from: 0, to: max(0.02, singAlong.progress))
                                    .stroke(.black.opacity(0.55), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                                    .rotationEffect(.degrees(-90))
                                    .padding(3)
                                    .animation(.smooth, value: singAlong.progress)
                            }
                        }
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                // On, it's a plain white disc: glass would rim it.
                .glassEffect(singAlong.isOn ? .identity : .regular.interactive(), in: Circle())
                .sensoryFeedback(.selection, trigger: singAlong.isOn)
                .accessibilityLabel("Sing Along")
                .accessibilityAddTraits(singAlong.isOn ? .isSelected : [])
            }
            .padding(.trailing, 16)
            .padding(.bottom, 16)
        }
    }
}

/// Vertical: full is the original vocals, empty is none. Like iOS
/// sliders, it moves with the finger rather than jumping to it.
private struct VocalLevelSlider: View {
    @Binding var level: Float
    @State private var dragStart: Float?
    @GestureState private var isTouching = false
    private let height: CGFloat = 150

    var body: some View {
        ZStack(alignment: .bottom) {
            Capsule().fill(.clear)
            Rectangle()
                .fill(.white.opacity(0.9))
                .frame(height: height * CGFloat(level))
        }
        .frame(width: 46, height: height)
        .clipShape(Capsule())
        .glassEffect(.regular, in: Capsule())
        .contentShape(Capsule())
        .scaleEffect(isTouching ? 1.08 : 1)
        .animation(.spring(duration: 0.3, bounce: 0.3), value: isTouching)
        .gesture(
            DragGesture(minimumDistance: 0)
                .updating($isTouching) { _, touching, _ in touching = true }
                .onChanged { value in
                    let start = dragStart ?? level
                    dragStart = start
                    level = Float(min(1, max(0, CGFloat(start) - value.translation.height / height)))
                }
                .onEnded { _ in dragStart = nil }
        )
        .sensoryFeedback(.impact(weight: .light), trigger: level == 0 || level == 1) { _, atEnd in atEnd }
        .accessibilityElement()
        .accessibilityLabel("Vocals")
        .accessibilityValue("\(Int(level * 100)) percent")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: level = min(1, level + 0.1)
            case .decrement: level = max(0, level - 0.1)
            @unknown default: break
            }
        }
    }
}

/// The lyrics' top pill while the song is being separated.
struct SingAlongProgressPill: View {
    @ObservedObject private var singAlong = SingAlong.shared
    @AppStorage(SingAlongProgressStyle.storageKey) private var progressStyle = SingAlongProgressStyle.ring

    private var isSeparating: Bool { progressStyle == .pill && singAlong.isOn && singAlong.progress < 1 }

    var body: some View {
        ZStack {
            if isSeparating {
                pill
            }
        }
        .animation(.smooth, value: isSeparating)
    }

    private var pill: some View {
            HStack(spacing: 10) {
                TintedSpinner(color: .white.withAlphaComponent(0.7))
                Text("Separating Vocals \(Int(singAlong.progress * 100))%")
                    .font(.system(size: 14, weight: .semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.smooth, value: singAlong.progress)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .glassEffect(.regular, in: .capsule)
            .padding(.top, 12)
            .transition(.blurReplace)
    }
}

/// Settings › Exclusive Features: the model, downloaded on request.
struct SingAlongCard: View {
    @ObservedObject private var model = SingAlongModel.shared
    @AppStorage(SingAlongProgressStyle.storageKey) private var progressStyle = SingAlongProgressStyle.ring
    @State private var open = false
    @State private var cache = VocalsCache.usage()
    @State private var confirmsClear = false

    var body: some View {
        CollapsibleGlassCard(title: "Sing Along", systemImage: "music.microphone", expanded: $open) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Turn the vocals down under the lyrics")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                switch model.state {
                case .notInstalled:
                    Button {
                        withAnimation(.smooth) { model.download() }
                    } label: {
                        Label("Download Model (\(SingAlongModel.downloadSize))", systemImage: "arrow.down.circle.fill")
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    if cache.songs > 0 {
                        Button("Delete Separated Songs", systemImage: "trash") {
                            confirmsClear = true
                        }
                        .buttonStyle(.glassProminent)
                        .tint(.red)
                        .padding(.top, 4)
                        .transition(.blurReplace)
                    }
                case .downloading(let fraction):
                    HStack(spacing: 12) {
                        ProgressView(value: fraction)
                        Button("Cancel") { model.cancel() }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                    }
                case .installing:
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Installing...").foregroundStyle(.secondary)
                    }
                case .installed:
                    Text("Progress").font(.subheadline).foregroundStyle(.secondary)
                    GlassSegmentedPicker(
                        String(localized: "Progress"),
                        options: SingAlongProgressStyle.allCases,
                        selection: $progressStyle.animation(.smooth),
                        title: \.title,
                        symbol: \.symbol
                    )
                    Button {
                        withAnimation(.smooth) {
                            model.delete()
                            cache = VocalsCache.usage()
                        }
                    } label: {
                        // Tinted like the picker's selected segment.
                        Label("Delete Model", systemImage: "trash")
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 9)
                            .background(Capsule().fill(.red.opacity(0.3)))
                            .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .capsule)
                    .padding(.top, 8)
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                    Button("Try Again", systemImage: "arrow.clockwise") {
                        withAnimation(.smooth) { model.download() }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                }
                Label("On device, from where the song plays", systemImage: "iphone")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .featureTint(FeatureTint.singAlong)
        .onChange(of: open) { cache = VocalsCache.usage() }
        .alert("Delete Separated Songs?", isPresented: $confirmsClear) {
            Button("Delete", role: .destructive) {
                VocalsCache.clear()
                withAnimation(.smooth) { cache = VocalsCache.usage() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(cache.songs) songs, \(cache.bytes.formatted(.byteCount(style: .file))). They'll be separated again if you reinstall the model.")
        }
    }
}
