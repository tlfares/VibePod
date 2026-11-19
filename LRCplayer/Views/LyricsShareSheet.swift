import SwiftUI
import UIKit

struct LyricsShareRequest: Identifiable {
    let id = UUID()
    let line: LyricsLine
}

/// Held line › Share Lyrics: first which lines (the held one, plus those
/// around it), then the card: its background, a still or a video lighting
/// word by word like the player, shared from the system sheet.
struct LyricsShareSheet: View {
    let playerVM: PlayerViewModel
    let startLine: LyricsLine

    /// The chosen lines travel with the step: the destination is built
    /// from them, never from a state read when the stack was set up.
    enum Step: Hashable { case design(ClosedRange<Int>) }

    @Environment(\.dismiss) private var dismiss
    @State private var path: [Step] = []
    @State private var range: ClosedRange<Int> = 0...0

    static let maxLines = 8

    /// The sung lines (instrumental gaps left out), as shown.
    private var lines: [LyricsLine] {
        playerVM.currentLyrics?.lines.filter { !$0.isInstrumentalGap } ?? []
    }

    var body: some View {
        NavigationStack(path: $path) {
            LyricsLinePicker(lines: lines, range: $range)
                .navigationTitle("Share Lyrics")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", systemImage: "xmark") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Next", systemImage: "chevron.forward") { path.append(.design(range)) }
                            .disabled(lines.isEmpty)
                    }
                }
                .navigationDestination(for: Step.self) { step in
                    let chosen: ClosedRange<Int> = { if case .design(let range) = step { range } else { range } }()
                    LyricsCardDesigner(playerVM: playerVM, lines: Array(lines[chosen.clamped(to: 0...max(lines.count - 1, 0))]), allLines: playerVM.currentLyrics?.lines ?? [])
                }
        }
        .presentationDetents([.large])
        .onAppear {
            let index = lines.firstIndex { $0.id == startLine.id }
                ?? lines.firstIndex { abs($0.time - startLine.time) < 0.05 } ?? 0
            range = index...index
        }
    }
}

// MARK: - Step 1: the lines

/// Every line, the chosen ones lit on one glass block: tap a line above or
/// below to take it in (and those between), tap an end one to let it go.
private struct LyricsLinePicker: View {
    let lines: [LyricsLine]
    @Binding var range: ClosedRange<Int>
    @Namespace private var glass
    @State private var bounce = 0

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(hint)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .contentTransition(.interpolate)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 14)
                    ForEach(lines.indices, id: \.self) { index in
                        row(index)
                            .id(index)
                    }
                }
                .padding(.vertical, 12)
                .padding(.bottom, 40)
            }
            .scrollIndicators(.hidden)
            .onAppear {
                proxy.scrollTo(range.lowerBound, anchor: .center)
            }
        }
        .sensoryFeedback(.selection, trigger: range)
        .sensoryFeedback(.impact(weight: .light), trigger: bounce)
    }

    private var hint: LocalizedStringKey {
        let count = range.count
        return count >= LyricsShareSheet.maxLines
            ? "\(count) lines, the most a card can hold"
            : "Tap the lines around it to add them"
    }

    @ViewBuilder
    private func row(_ index: Int) -> some View {
        let selected = range.contains(index)
        let isFirst = index == range.lowerBound
        let isLast = index == range.upperBound
        Button {
            toggle(index)
        } label: {
            Text(lines[index].text)
                .font(.system(size: 26, weight: .bold))
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(selected ? Color.primary : Color.secondary.opacity(0.55))
                .padding(.horizontal, 20)
                .padding(.top, isFirst || !selected ? 14 : 7)
                .padding(.bottom, isLast || !selected ? 14 : 7)
                .background(alignment: .center) {
                    // One block under the chosen lines: each row draws its
                    // part, the ends rounded.
                    if selected {
                        UnevenRoundedRectangle(
                            topLeadingRadius: isFirst ? 24 : 0,
                            bottomLeadingRadius: isLast ? 24 : 0,
                            bottomTrailingRadius: isLast ? 24 : 0,
                            topTrailingRadius: isFirst ? 24 : 0,
                            style: .continuous
                        )
                        .fill(Color.primary.opacity(0.09))
                        .transition(.opacity)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func toggle(_ index: Int) {
        withAnimation(.smooth(duration: 0.3)) {
            if index < range.lowerBound {
                let lower = max(index, range.upperBound - LyricsShareSheet.maxLines + 1)
                if lower != index { bounce += 1 }
                range = lower...range.upperBound
            } else if index > range.upperBound {
                let upper = min(index, range.lowerBound + LyricsShareSheet.maxLines - 1)
                if upper != index { bounce += 1 }
                range = range.lowerBound...upper
            } else if range.count == 1 {
                bounce += 1
            } else if index == range.lowerBound {
                range = (index + 1)...range.upperBound
            } else if index == range.upperBound {
                range = range.lowerBound...(index - 1)
            } else {
                // Inside: keep from the start through this one.
                range = range.lowerBound...index
            }
        }
    }
}

// MARK: - Step 2: the card

private struct LyricsCardDesigner: View {
    let playerVM: PlayerViewModel
    let lines: [LyricsLine]
    let allLines: [LyricsLine]

    enum Format: Hashable { case image, video }

    @Environment(\.dismiss) private var dismiss
    @AppStorage("lyricsCardBackground") private var backgroundKey = "blur"
    @State private var format: Format = .image
    @State private var preview: LyricsCardRenderer?
    @State private var previewStart = Date()
    @State private var exporting: Double?
    @State private var errorMessage: String?
    @State private var exportTask: Task<Void, Never>?

    private static let previewWidth: CGFloat = 270

    private var song: Song? { playerVM.currentSong }

    private var background: LyricsCardBackground {
        get {
            switch backgroundKey {
            case "black": return .black
            case "white": return .white
            case "blur": return .blur
            default: return CoverPalette(rawValue: backgroundKey).map { .palette($0) } ?? .blur
            }
        }
    }

    private func key(_ background: LyricsCardBackground) -> String {
        switch background {
        case .blur: "blur"
        case .black: "black"
        case .white: "white"
        case .palette(let palette): palette.rawValue
        }
    }

    private var hasWordTimings: Bool {
        lines.contains { playerVM.currentWordTimings[$0.id] != nil }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 26) {
                previewCard
                    .padding(.top, 8)

                Picker("Format", selection: $format.animation(.smooth)) {
                    Label("Image", systemImage: "photo").tag(Format.image)
                    Label("Video", systemImage: "play.rectangle").tag(Format.video)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 20)

                backgroundPicker

                if format == .video {
                    Text(hasWordTimings
                         ? "The lines light word by word, like in the player, over the song."
                         : "The lines light one after another, over the song. Sync the song word by word for the full effect.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                        .transition(.blurReplace)
                }
            }
            .padding(.bottom, 110)
        }
        .scrollIndicators(.hidden)
        .safeAreaInset(edge: .bottom) { shareButton }
        .navigationTitle("Customize")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: backgroundKey) { buildPreview() }
        .onChange(of: format) { _, _ in previewStart = Date() }
        .onDisappear { exportTask?.cancel() }
        .alert("Couldn't Share", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .sensoryFeedback(.selection, trigger: backgroundKey)
    }

    // MARK: Preview

    private var previewCard: some View {
        let ratio = preview.map { $0.size.height / max($0.size.width, 1) } ?? 16 / 9
        // Tall cards a little narrower, so they fit the screen.
        let width = ratio > 1.4 ? Self.previewWidth : 330
        let height = width * ratio
        return ZStack {
            if let preview {
                if format == .video {
                    let clip = span
                    TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                        let elapsed = context.date.timeIntervalSince(previewStart)
                        let length = clip.end - clip.start + 0.8
                        let time = clip.start + elapsed.truncatingRemainder(dividingBy: length)
                        Image(uiImage: preview.image(at: min(time, clip.end)))
                            .resizable()
                    }
                } else {
                    Image(uiImage: preview.image(at: nil))
                        .resizable()
                }
            } else {
                Color.black
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .shadow(color: .black.opacity(0.3), radius: 24, y: 12)
        .contentTransition(.opacity)
        .animation(.smooth(duration: 0.35), value: backgroundKey)
        .animation(.smooth(duration: 0.4), value: ratio)
    }

    private var backgroundPicker: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 14) {
                ForEach(LyricsCardBackground.all, id: \.self) { option in
                    let selected = key(option) == backgroundKey
                    Button {
                        withAnimation(.smooth(duration: 0.3)) { backgroundKey = key(option) }
                    } label: {
                        swatch(option)
                            .frame(width: 46, height: 46)
                            .clipShape(Circle())
                            .overlay {
                                Circle().strokeBorder(Color.primary.opacity(option == .white || option == .black ? 0.18 : 0), lineWidth: 1)
                            }
                            .padding(4)
                            .overlay {
                                Circle()
                                    .strokeBorder(Color.primary, lineWidth: 2.5)
                                    .opacity(selected ? 1 : 0)
                                    .scaleEffect(selected ? 1 : 0.85)
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(label(option))
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 4)
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder
    private func swatch(_ option: LyricsCardBackground) -> some View {
        switch option {
        case .blur:
            let colors = Song.playerArtworkUIColors(for: song?.artworkSource).map(Color.init(uiColor:))
            ZStack {
                AngularGradient(colors: colors + [colors.first ?? .gray], center: .center)
                    .blur(radius: 6)
                Image(systemName: "photo")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
            }
        case .palette(let palette):
            let c = palette.colors
            LinearGradient(colors: [Color(red: c.start.red / 255, green: c.start.green / 255, blue: c.start.blue / 255),
                                    Color(red: c.end.red / 255, green: c.end.green / 255, blue: c.end.blue / 255)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        case .black:
            Color.black
        case .white:
            Color.white
        }
    }

    private func label(_ option: LyricsCardBackground) -> String {
        switch option {
        case .blur: String(localized: "Artwork Colors")
        case .black: String(localized: "Black")
        case .white: String(localized: "White")
        case .palette(let palette): palette.title
        }
    }

    // MARK: Share

    private var shareButton: some View {
        Button {
            share()
        } label: {
            ZStack {
                if let exporting {
                    HStack(spacing: 10) {
                        ProgressView(value: exporting)
                            .progressViewStyle(.circular)
                            .tint(.white)
                        Text("Making the Video…")
                    }
                    .transition(.blurReplace)
                } else {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .transition(.blurReplace)
                }
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
        .buttonStyle(.glassProminent)
        .disabled(exporting != nil || preview == nil)
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
        .animation(.smooth, value: exporting != nil)
    }

    private func share() {
        guard let song else { return }
        let renderer = makeRenderer(width: LyricsCardRenderer.width)
        switch format {
        case .image:
            do {
                let url = try LyricsCardExporter.writeImage(renderer.image(at: nil))
                present(url)
            } catch {
                errorMessage = error.localizedDescription
            }
        case .video:
            let clip = span
            let audioURL: URL? = song.isMediaLibraryItem ? song.fileURL : song.playableFileURL
            let offset = playerVM.currentLyrics?.offset ?? 0
            exporting = 0
            exportTask = Task {
                do {
                    let url = try await Task.detached(priority: .userInitiated) {
                        try await LyricsCardExporter.writeVideo(renderer: renderer, start: clip.start, end: clip.end, audioURL: audioURL, audioOffset: offset) { value in
                            Task { @MainActor in exporting = value }
                        }
                    }.value
                    exporting = nil
                    present(url)
                } catch is CancellationError {
                    exporting = nil
                } catch {
                    exporting = nil
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func present(_ url: URL) {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first,
            var top = window.rootViewController else { return }
        while let presented = top.presentedViewController { top = presented }
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let popover = controller.popoverPresentationController {
            popover.sourceView = top.view
            popover.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.maxY - 60, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        top.present(controller, animated: true)
    }

    // MARK: Card

    private func buildPreview() {
        let scale = min(UIScreen.main.scale, 2)
        withAnimation(.smooth(duration: 0.3)) {
            preview = makeRenderer(width: 330 * scale)
        }
    }

    private func makeRenderer(width: CGFloat) -> LyricsCardRenderer {
        let cover = song.flatMap { ArtworkImageCache.shared.imageSync(for: $0.artworkSource, points: 240) }
        return LyricsCardRenderer(
            width: width,
            lines: cardLines,
            title: song?.title ?? "",
            artist: song?.artist ?? "",
            cover: cover,
            coverColors: Song.playerArtworkUIColors(for: song?.artworkSource),
            background: background
        )
    }

    /// Each line ends where the next one in the song starts (a gap too).
    private var cardLines: [LyricsCardLine] {
        lines.map { line in
            let next = allLines.first { $0.time > line.time + 0.01 }?.time
            let words = playerVM.currentWordTimings[line.id]
            let end = next ?? (words?.last.map { $0.end + 1 } ?? line.time + 4)
            return LyricsCardLine(text: line.text, start: line.time, end: end, words: words)
        }
    }

    /// The video's span: a beat before the first line, through the last
    /// one (its last word and a breath), a minute at most.
    private var span: (start: TimeInterval, end: TimeInterval) {
        let cards = cardLines
        guard let first = cards.first, let last = cards.last else { return (0, 1) }
        let start = max(0, first.start - 0.6)
        var end = last.words?.last.map { min($0.end + 1.2, last.end + 0.6) } ?? last.end
        end = max(end, last.start + 1.5)
        return (start, min(end, start + 60))
    }
}
