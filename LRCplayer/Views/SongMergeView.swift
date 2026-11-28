import AVFoundation
import SwiftUI

/// Settings › Tools › Merge Songs: a part 1 and its part 2 made one song,
/// so shuffle never splits them. Each merge can be edited or undone.
struct SongMergeView: View {
    @EnvironmentObject private var libraryVM: LibraryViewModel
    @ObservedObject private var service = SongMergeService.shared
    @State private var editing: MergeEditorRequest?
    @State private var unmerging: SongMerge?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                header
                card {
                    Label("New Merge", systemImage: "plus.circle.fill").font(.headline)
                    Text("Pick a song and the one that follows it. They play as one from then on, with the transition you choose, in shuffle too.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button {
                        editing = MergeEditorRequest(merge: nil)
                    } label: {
                        Text("Merge Two Songs…").frame(maxWidth: .infinity).padding(.vertical, 4)
                    }
                    .buttonStyle(.glassProminent)
                }
                if !service.merges.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Merged Songs")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                        ForEach(service.merges) { merge in
                            mergeRow(merge)
                                .transition(.asymmetric(insertion: .scale(scale: 0.95).combined(with: .opacity), removal: .opacity))
                        }
                        Text("Unmerging gives both songs back as they were, with their plays.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                    }
                    .padding(.top, 8)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 32)
            .animation(.smooth, value: service.merges.map(\.id))
        }
        .scrollIndicators(.hidden)
        .background(Color(uiColor: .settingsBackground).ignoresSafeArea())
        .sheet(item: $editing) { request in
            SongMergeEditor(existing: request.merge)
        }
        .confirmationDialog(
            "Unmerge?",
            isPresented: Binding(get: { unmerging != nil }, set: { if !$0 { unmerging = nil } }),
            titleVisibility: .visible,
            presenting: unmerging
        ) { merge in
            Button("Unmerge", role: .destructive) {
                withAnimation(.smooth) { service.unmerge(merge, library: libraryVM.libraryService) }
            }
        } message: { merge in
            Text("“\(merge.parts[0].song.title)” and “\(merge.parts[1].song.title)” come back as two songs.")
        }
        .sensoryFeedback(.success, trigger: service.merges.count)
    }

    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.triangle.merge")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 64, height: 64)
                .glassEffect(.regular.tint(AppTint.current.color.opacity(0.25)), in: .circle)
            Text("Merge Songs").font(.title2.bold())
            Text("For a song that goes on in the next one: never one without the other.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private func mergeRow(_ merge: SongMerge) -> some View {
        let song = libraryVM.libraryService.song(withID: merge.id)
        return HStack(spacing: 14) {
            MergePairArtwork(first: merge.parts[0].song, second: merge.parts[1].song, size: 48)
            VStack(alignment: .leading, spacing: 3) {
                Text(song?.title ?? merge.parts[0].song.title)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(merge.parts[0].song.title).lineLimit(1)
                    Image(systemName: merge.transition.symbol)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.tint)
                    Text(merge.parts[1].song.title).lineLimit(1)
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Menu {
                Button("Edit…", systemImage: "slider.horizontal.3") {
                    editing = MergeEditorRequest(merge: merge)
                }
                Button("Unmerge", destructiveImage: "arrow.triangle.branch") {
                    unmerging = merge
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.semibold))
                    .frame(width: 36, height: 36)
                    .contentShape(Circle())
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .contextMenu {
            Button("Edit…", systemImage: "slider.horizontal.3") { editing = MergeEditorRequest(merge: merge) }
            Button("Unmerge", destructiveImage: "arrow.triangle.branch") { unmerging = merge }
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12, content: content)
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: .rect(cornerRadius: 28))
    }
}

struct MergeEditorRequest: Identifiable {
    let id = UUID()
    let merge: SongMerge?
}

/// Two covers, the second tucked behind the first.
struct MergePairArtwork: View {
    let first: Song
    let second: Song
    var size: CGFloat = 48

    var body: some View {
        ZStack(alignment: .topLeading) {
            ArtworkImage(source: second.artworkSource, cornerRadius: size * 0.16, points: size)
                .frame(width: size * 0.82, height: size * 0.82)
                .offset(x: size * 0.3, y: 0)
                .opacity(0.75)
            ArtworkImage(source: first.artworkSource, cornerRadius: size * 0.16, points: size)
                .frame(width: size * 0.82, height: size * 0.82)
                .offset(y: size * 0.18)
                .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
        }
        .frame(width: size * 1.12, height: size, alignment: .topLeading)
    }
}

// MARK: - Editor

private struct SongMergeEditor: View {
    let existing: SongMerge?

    enum TitleChoice: Hashable { case first, second, custom }
    enum Slot: Identifiable { case first, second; var id: Self { self } }

    @EnvironmentObject private var libraryVM: LibraryViewModel
    @EnvironmentObject private var playerVM: PlayerViewModel
    @Environment(\.dismiss) private var dismiss

    /// The first and the second, each chosen on its own.
    @State private var slots: [Song?] = [nil, nil]
    private var songs: [Song] { slots.compactMap { $0 } }
    /// Per song: where it starts and ends in the merge.
    @State private var starts: [UUID: TimeInterval] = [:]
    @State private var ends: [UUID: TimeInterval] = [:]
    @State private var transition: SongMerge.Transition = .cut
    @State private var fade: TimeInterval = 4
    @State private var titleChoice: TitleChoice = .first
    @State private var customTitle = ""
    @State private var metadataSongID: UUID?
    @State private var picking: Slot?
    @State private var progress: Double?
    @State private var errorMessage: String?
    @State private var swapTurn = 0
    @StateObject private var preview = MergePreviewPlayer()

    private var isReady: Bool { slots.allSatisfy { $0 != nil } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    lane(.first)
                    lane(.second)
                    if isReady {
                        Group {
                            transitionCard
                            titleCard
                            if needsMetadataChoice { metadataCard }
                        }
                        .transition(.opacity.combined(with: .offset(y: 12)))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, isReady ? 100 : 32)
                .animation(.smooth(duration: 0.4), value: slots.map { $0?.id })
                .animation(.smooth(duration: 0.35), value: transition)
            }
            .scrollIndicators(.hidden)
            .safeAreaInset(edge: .bottom) {
                if isReady { previewBar }
            }
            .navigationTitle(existing == nil ? "Merge Songs" : "Edit Merge")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(existing == nil ? "Merge" : "Save", systemImage: "checkmark") { merge() }
                        .disabled(!isReady || progress != nil || finalTitle.isEmpty)
                }
            }
            .overlay { if let progress { progressOverlay(progress) } }
            .disabled(progress != nil)
        }
        .interactiveDismissDisabled(progress != nil)
        .sheet(item: $picking) { slot in
            MergeSongPicker(excluding: Set(songs.map(\.id))) { song in
                choose(song, for: slot)
            }
        }
        .alert("Couldn't Merge", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .onAppear(perform: setUp)
        .onDisappear { preview.stop() }
        .onChange(of: transition) { _, _ in preview.stop() }
        .sensoryFeedback(.selection, trigger: transition)
        .sensoryFeedback(.impact(weight: .medium), trigger: swapTurn)
    }

    // MARK: Songs

    /// One song on its own level: its cover's glow behind, a glass chip to
    /// change it, its waveform to swipe through and its cursor to drag.
    @ViewBuilder
    private func lane(_ slot: Slot) -> some View {
        let index = slot == .first ? 0 : 1
        let song = slots[index]
        VStack(alignment: slot == .first ? .leading : .trailing, spacing: 12) {
            HStack(spacing: 10) {
                if slot == .second {
                    swapButton
                    Spacer(minLength: 8)
                }
                if let song {
                    songChip(song, slot: slot)
                        .id(song.id)
                        .transition(.blurReplace)
                }
                if slot == .first { Spacer(minLength: 0) }
            }
            if let song {
                MergeLaneWaveform(
                    song: song,
                    edge: slot == .first ? .end : .start,
                    time: slot == .first ? endBinding(song) : startBinding(song),
                    accent: playheadColor(for: song),
                    isPreviewing: preview.clock != nil,
                    alignOffset: slot == .second ? overlap : 0,
                    playhead: { playhead(for: slot, at: $0) }
                )
                .id(song.id)
                .transition(.opacity)
            } else {
                Button {
                    picking = slot
                } label: {
                    Label(slot == .first ? "Choose the First Song" : "Choose the Song That Follows", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.glass)
            }
        }
        .padding(.vertical, 6)
        .background { if let song { MergeCoverGlow(song: song) } }
    }

    private func songChip(_ song: Song, slot: Slot) -> some View {
        Button {
            picking = slot
        } label: {
            HStack(spacing: 10) {
                ArtworkImage(source: song.artworkSource, cornerRadius: 7, points: 38)
                    .frame(width: 38, height: 38)
                VStack(alignment: .leading, spacing: 1) {
                    Text(song.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(song.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(maxWidth: 190, alignment: .leading)
            }
            .padding(5)
            .padding(.trailing, 9)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .accessibilityHint("Changes the song")
    }

    /// Where the preview is in this song: the first's playhead runs up to
    /// its cursor and goes, the second's comes in at its own; both move
    /// together through a fade.
    private func playhead(for slot: Slot, at date: Date) -> TimeInterval? {
        guard let clock = preview.clock, let layout = preview.layout, songs.count == 2 else { return nil }
        let t = preview.currentTime ?? clock.start + date.timeIntervalSince(clock.at)
        let parts = draft.parts
        if slot == .first {
            return t <= parts[0].length ? parts[0].start + t : nil
        }
        return t >= layout.secondAt ? parts[1].start + t - layout.secondAt : nil
    }

    @Environment(\.colorScheme) private var colorScheme

    /// How long both play together: the second level sits that much to the
    /// left, so one moment is at the same spot on both.
    private var overlap: TimeInterval {
        guard isReady else { return 0 }
        return preview.layout?.overlap ?? SongMergeService.layout(for: draft).overlap
    }

    /// The cover's color, light enough to read on the dark page (deeper on
    /// a light one).
    private func playheadColor(for song: Song) -> Color {
        let base = UIColor(song.playerArtworkColors.first ?? .accentColor)
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        base.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        if colorScheme == .dark {
            return Color(hue: hue, saturation: min(saturation, 0.5), brightness: max(brightness, 0.92))
        }
        return Color(hue: hue, saturation: max(saturation, 0.65), brightness: min(brightness, 0.6))
    }

    private var swapButton: some View {
        Button {
            guard isReady else { return }
            preview.stop()
            withAnimation(.spring(duration: 0.5, bounce: 0.25)) {
                slots.reverse()
                swapTurn += 1
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.subheadline.weight(.semibold))
                .rotationEffect(.degrees(Double(swapTurn) * 180))
                .frame(width: 36, height: 36)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .opacity(isReady ? 1 : 0)
        .disabled(!isReady)
        .accessibilityLabel("Swap the Order")
    }

    private func startBinding(_ song: Song) -> Binding<TimeInterval> {
        Binding(get: { starts[song.id] ?? 0 }, set: { starts[song.id] = $0; preview.stop() })
    }

    private func endBinding(_ song: Song) -> Binding<TimeInterval> {
        Binding(get: { ends[song.id] ?? song.duration }, set: { ends[song.id] = $0; preview.stop() })
    }

    private func choose(_ song: Song, for slot: Slot) {
        let index = slot == .first ? 0 : 1
        withAnimation(.smooth) { slots[index] = song }
        // Silence at the edges trimmed when it's been measured.
        Task {
            let profile = await AutoMixAnalyzer.shared.storedProfile(for: song.id)
            if starts[song.id] == nil { starts[song.id] = profile.map { max(0, $0.start - 0.05) } ?? 0 }
            if ends[song.id] == nil { ends[song.id] = profile.map { min(song.duration, $0.end + 0.3) } ?? song.duration }
        }
        if isReady {
            customTitle = Self.suggestedTitle(songs[0].title, songs[1].title)
            if metadataSongID == nil || !songs.contains(where: { $0.id == metadataSongID }) { metadataSongID = songs[0].id }
        }
        preview.stop()
    }

    // MARK: Transition

    private var transitionCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Transition")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                ForEach(SongMerge.Transition.allCases, id: \.self) { option in
                    let selected = option == transition
                    Button {
                        withAnimation(.smooth(duration: 0.3)) { transition = option }
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: option.symbol)
                                .font(.title3.weight(.semibold))
                                .symbolEffect(.bounce, value: selected)
                            Text(option.title)
                                .font(.footnote.weight(.semibold))
                        }
                        .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .glassEffect(selected ? .regular.tint(AppTint.current.color.opacity(0.22)).interactive() : .regular.interactive(), in: .rect(cornerRadius: 18))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            Group {
                switch transition {
                case .cut:
                    Text("The second song starts the moment the first stops.")
                case .crossfade:
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Length")
                            Spacer()
                            Text("\(fade, specifier: "%.1f") s")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .contentTransition(.numericText(value: fade))
                        }
                        .font(.subheadline)
                        Slider(value: $fade, in: 1...12, step: 0.5)
                            .onChange(of: fade) { _, _ in preview.stop() }
                    }
                case .autoMix:
                    Text("Mixed on the beat, like AutoMix: the second song comes in over the first one's end.")
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .transition(.blurReplace)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
    }

    // MARK: Title & metadata

    private var titleCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Title")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            choiceRow(songs[0].title, selected: titleChoice == .first) { titleChoice = .first }
            choiceRow(songs[1].title, selected: titleChoice == .second) { titleChoice = .second }
            HStack(spacing: 12) {
                checkmark(titleChoice == .custom)
                TextField("Custom Title", text: $customTitle)
                    .font(.body)
                    .submitLabel(.done)
                    .simultaneousGesture(TapGesture().onEnded { withAnimation(.smooth) { titleChoice = .custom } })
                    .onChange(of: customTitle) { _, _ in
                        if titleChoice != .custom { withAnimation(.smooth) { titleChoice = .custom } }
                    }
            }
            .padding(.vertical, 2)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
        .sensoryFeedback(.selection, trigger: titleChoice)
    }

    private var needsMetadataChoice: Bool {
        songs.count == 2 && (songs[0].album != songs[1].album || songs[0].artist != songs[1].artist)
    }

    private var metadataCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Album & Artwork")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("The two songs come from different albums: the merged song takes one's album, artist and artwork.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            ForEach(songs) { song in
                let selected = metadataSongID == song.id
                Button {
                    withAnimation(.smooth) { metadataSongID = song.id }
                } label: {
                    HStack(spacing: 12) {
                        ArtworkImage(source: song.artworkSource, cornerRadius: 7, points: 44)
                            .frame(width: 44, height: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(song.album).font(.body).lineLimit(1)
                            Text(song.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        checkmark(selected)
                    }
                    .padding(10)
                    .background {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.primary.opacity(selected ? 0.08 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
        .sensoryFeedback(.selection, trigger: metadataSongID)
    }

    private func choiceRow(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.smooth) { action() }
        } label: {
            HStack(spacing: 12) {
                checkmark(selected)
                Text(title).lineLimit(2)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func checkmark(_ selected: Bool) -> some View {
        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
            .font(.title3)
            .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
            .contentTransition(.symbolEffect(.replace))
    }

    private var finalTitle: String {
        switch titleChoice {
        case .first: songs.first?.title ?? ""
        case .second: songs.count > 1 ? songs[1].title : ""
        case .custom: customTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// "Song (Part 1)" + "Song (Part 2)" → "Song".
    private static func suggestedTitle(_ a: String, _ b: String) -> String {
        let common = String(zip(a, b).prefix { $0 == $1 }.map(\.0))
        let trimmed = common
            .replacingOccurrences(of: #"[\s\-–—:,(\[]*(pt\.?|part|partie)?\s*$"#, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count >= 3 ? trimmed : "\(a) / \(b)"
    }

    // MARK: Preview

    private var previewBar: some View {
        Button {
            if preview.isPlaying {
                preview.stop()
            } else {
                playerVM.playerService.pause()
                Task { await preview.play(draft) }
            }
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    if preview.isLoading {
                        ProgressView()
                    } else {
                        Image(systemName: preview.isPlaying ? "stop.fill" : "play.fill")
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                .frame(width: 22)
                Text(preview.isPlaying ? "Stop" : "Play the Transition")
                    .contentTransition(.interpolate)
                if preview.isPlaying {
                    Spacer(minLength: 0)
                    MergePreviewProgress(preview: preview)
                        .transition(.opacity)
                }
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
        .buttonStyle(.glass)
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
        .animation(.smooth, value: preview.isPlaying)
    }

    private var draft: SongMerge {
        let parts = songs.map { song in
            SongMerge.Part(song: song, start: starts[song.id] ?? 0, end: ends[song.id] ?? song.duration)
        }
        return SongMerge(id: existing?.id ?? UUID(), parts: parts, transition: transition, fade: fade)
    }

    // MARK: Merge

    private func merge() {
        guard isReady else { return }
        preview.stop()
        var merge = draft
        if existing != nil { merge = SongMerge(id: UUID(), parts: merge.parts, transition: merge.transition, fade: merge.fade) }
        let metadataIndex = songs.firstIndex { $0.id == metadataSongID } ?? 0
        let title = finalTitle
        progress = 0
        Task {
            do {
                try await SongMergeService.shared.apply(merge, title: title, metadataFrom: metadataIndex, replacing: existing, library: libraryVM.libraryService) { value in
                    Task { @MainActor in progress = value }
                }
                progress = nil
                dismiss()
            } catch {
                progress = nil
                errorMessage = error.localizedDescription
            }
        }
    }

    private func progressOverlay(_ value: Double) -> some View {
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView(value: value)
                    .progressViewStyle(.linear)
                    .frame(width: 180)
                Text("Merging…").font(.headline)
            }
            .padding(28)
            .glassEffect(.regular, in: .rect(cornerRadius: 28))
        }
        .transition(.opacity)
    }

    private func setUp() {
        guard let existing, songs.isEmpty else { return }
        slots = existing.parts.map(\.song)
        for part in existing.parts {
            starts[part.song.id] = part.start
            ends[part.song.id] = part.end
        }
        transition = existing.transition
        fade = existing.fade
        let merged = libraryVM.libraryService.song(withID: existing.id)
        let title = merged?.title ?? songs[0].title
        if title == songs[0].title { titleChoice = .first }
        else if title == songs[1].title { titleChoice = .second }
        else { titleChoice = .custom }
        customTitle = titleChoice == .custom ? title : Self.suggestedTitle(songs[0].title, songs[1].title)
        metadataSongID = songs.first { $0.album == merged?.album && $0.artist == merged?.artist }?.id ?? songs[0].id
    }
}

// MARK: - Lanes

/// The cover's color, glowing softly behind its song's level.
private struct MergeCoverGlow: View {
    let song: Song

    var body: some View {
        let color = song.playerArtworkColors.first ?? .accentColor
        Ellipse()
            .fill(color.gradient)
            .opacity(0.42)
            .blur(radius: 46)
            .padding(.horizontal, -10)
            .padding(.vertical, 4)
            .allowsHitTesting(false)
            .transition(.opacity)
            .id(song.id)
    }
}

/// The song's waveform on a timeline to swipe through, the part played
/// lit. The cursor (where the first song stops, or the second starts) is
/// dragged, or put down with a tap; both songs open with it at the same spot.
struct MergeLaneWaveform: View {
    let song: Song
    enum Edge { case start, end }
    let edge: Edge
    @Binding var time: TimeInterval
    var accent: Color = .primary
    var isPreviewing = false
    /// Seconds the song sits to the left of the anchor (the overlap, for
    /// the second song).
    var alignOffset: TimeInterval = 0
    var playhead: (Date) -> TimeInterval? = { _ in nil }

    @State private var bars: [Float] = []
    @State private var dragging = false
    @State private var width: CGFloat = 0
    @State private var scroll = ScrollPosition()
    @State private var placed = false
    @State private var secondTick = 0

    private static let pointsPerSecond: CGFloat = 10
    private static let height: CGFloat = 84
    /// Where the cursor sits on screen when the song opens.
    private static let anchor: CGFloat = 0.62

    private var duration: TimeInterval { max(song.duration, 1) }
    private var contentWidth: CGFloat { CGFloat(duration) * Self.pointsPerSecond }

    var body: some View {
        ScrollView(.horizontal) {
            let x = CGFloat(time) * Self.pointsPerSecond
            ZStack(alignment: .leading) {
                Canvas { context, size in
                    guard !bars.isEmpty else { return }
                    let step = size.width / CGFloat(bars.count)
                    let barWidth = max(1.5, step * 0.62)
                    for (index, value) in bars.enumerated() {
                        let height = max(3, CGFloat(value) * size.height)
                        let barX = CGFloat(index) * step + (step - barWidth) / 2
                        let rect = CGRect(x: barX, y: (size.height - height) / 2, width: barWidth, height: height)
                        let kept = edge == .end ? barX < x : barX + barWidth > x
                        context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2),
                                     with: .color(Color.primary.opacity(kept ? 0.85 : 0.16)))
                    }
                }
                .frame(width: contentWidth, height: Self.height)
                .overlay {
                    if bars.isEmpty {
                        Capsule()
                            .fill(Color.primary.opacity(0.08))
                            .frame(height: 4)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture(coordinateSpace: .local) { location in
                    withAnimation(.smooth(duration: 0.3)) { time = clamp(TimeInterval(location.x / Self.pointsPerSecond)) }
                }
                if isPreviewing {
                    TimelineView(.animation) { context in
                        let at = playhead(context.date)
                        Capsule()
                            .fill(accent)
                            .frame(width: 2, height: Self.height + 8)
                            .shadow(color: accent.opacity(0.6), radius: 4)
                            .offset(x: CGFloat(at ?? 0) * Self.pointsPerSecond - 1)
                            .opacity(at == nil ? 0 : 1)
                    }
                    .frame(width: contentWidth, alignment: .leading)
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }
                cursor
                    .offset(x: x - 22)
            }
            .frame(height: Self.height + 44)
            .padding(.leading, width * Self.anchor)
            .padding(.trailing, width * (1 - Self.anchor))
        }
        .scrollIndicators(.hidden)
        .scrollPosition($scroll)
        .scrollClipDisabled()
        .frame(height: Self.height + 44)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { value in
            width = value
            place()
        }
        .task(id: song.id) {
            let count = min(1600, max(160, Int(duration / 0.3)))
            let loaded = await SongMergeService.shared.waveform(for: song, count: count)
            withAnimation(.smooth(duration: 0.4)) { bars = loaded }
        }
        .onAppear(perform: place)
        // Another transition (or fade length): the level slides to stay lined up.
        .onChange(of: alignOffset) { old, new in
            guard placed, abs(old - new) > 0.01 else { return }
            withAnimation(.smooth(duration: 0.45)) {
                scroll.scrollTo(x: CGFloat(time + new) * Self.pointsPerSecond)
            }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: dragging)
        .sensoryFeedback(.selection, trigger: secondTick)
    }

    /// The cursor at its spot on screen, once.
    private func place() {
        guard !placed, width > 0 else { return }
        placed = true
        scroll.scrollTo(x: CGFloat(time + alignOffset) * Self.pointsPerSecond)
    }

    private var cursor: some View {
        VStack(spacing: 0) {
            Circle()
                .fill(.tint)
                .frame(width: dragging ? 20 : 14, height: dragging ? 20 : 14)
                .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
                .frame(height: 22)
            Capsule()
                .fill(.tint)
                .frame(width: 3, height: Self.height)
            Text(Self.format(time))
                .font(.caption2.weight(.semibold))
                .monospacedDigit()
                .contentTransition(.numericText(value: time))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .glassEffect(.regular, in: .capsule)
                .fixedSize()
                .frame(height: 22)
        }
        .frame(width: 44)
        .offset(y: 0)
        .contentShape(Rectangle())
        .highPriorityGesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    if !dragging { dragStart = time }
                    dragging = true
                    let moved = clamp(dragStart + TimeInterval(value.translation.width / Self.pointsPerSecond))
                    if Int(moved) != Int(time) { secondTick += 1 }
                    time = moved
                }
                .onEnded { _ in dragging = false }
        )
        .animation(.smooth(duration: 0.2), value: dragging)
        .accessibilityElement()
        .accessibilityLabel(edge == .end ? "Stops at" : "Starts at")
        .accessibilityValue(Self.format(time))
        .accessibilityAdjustableAction { direction in
            time = clamp(time + (direction == .increment ? 0.5 : -0.5))
        }
    }

    @State private var dragStart: TimeInterval = 0

    /// At least 5 s of the song kept.
    private func clamp(_ value: TimeInterval) -> TimeInterval {
        switch edge {
        case .end: min(max(value, 5), duration)
        case .start: min(max(value, 0), duration - 5)
        }
    }

    static func format(_ time: TimeInterval) -> String {
        let tenths = Int((time * 10).rounded())
        return String(format: "%d:%02d.%d", tenths / 600, (tenths / 10) % 60, tenths % 10)
    }
}

// MARK: - Preview

/// Plays the merge as it will sound, from a few seconds before the second
/// song comes in to a few seconds after.
@MainActor
final class MergePreviewPlayer: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var isLoading = false
    @Published private(set) var fraction: Double = 0
    /// Where the preview started on the merged song's clock, and when.
    @Published private(set) var clock: (start: TimeInterval, at: Date)?
    @Published private(set) var layout: SongMergeLayout?

    /// The player's own clock: the playheads never drift from what's heard.
    var currentTime: TimeInterval? {
        guard let player, player.timeControlStatus == .playing else { return nil }
        let seconds = player.currentTime().seconds
        return seconds.isFinite ? seconds : nil
    }

    private var player: AVPlayer?
    private var observer: Any?
    private var range: ClosedRange<TimeInterval> = 0...1
    private var request = 0

    func play(_ merge: SongMerge) async {
        stop()
        request += 1
        let current = request
        isLoading = true
        let profiles = merge.transition == .autoMix
            ? (await AutoMixAnalyzer.shared.profile(for: merge.parts[0].song), await AutoMixAnalyzer.shared.profile(for: merge.parts[1].song))
            : (nil, nil)
        let layout = SongMergeService.layout(for: merge, profiles: profiles)
        guard let (composition, mix) = try? await SongMergeService.composition(for: merge, layout: layout), current == request else {
            if current == request { isLoading = false }
            return
        }
        let item = AVPlayerItem(asset: composition)
        item.audioMix = mix
        let player = AVPlayer(playerItem: item)
        let start = max(0, layout.secondAt - 7)
        range = start...min(layout.duration, layout.secondAt + layout.overlap + 7)
        await player.seek(to: CMTime(seconds: start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        guard current == request else { return }
        self.player = player
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 20), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                let seconds = time.seconds
                self.fraction = (seconds - self.range.lowerBound) / (self.range.upperBound - self.range.lowerBound)
                if seconds >= self.range.upperBound { self.stop() }
            }
        }
        isLoading = false
        isPlaying = true
        self.layout = layout
        clock = (start, Date())
        player.play()
    }

    func stop() {
        request += 1
        if let observer { player?.removeTimeObserver(observer) }
        observer = nil
        player?.pause()
        player = nil
        isPlaying = false
        isLoading = false
        fraction = 0
        clock = nil
        layout = nil
    }
}

private struct MergePreviewProgress: View {
    @ObservedObject var preview: MergePreviewPlayer

    var body: some View {
        Capsule()
            .fill(Color.primary.opacity(0.15))
            .frame(width: 90, height: 5)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(.tint)
                    .frame(width: 90 * min(max(preview.fraction, 0), 1), height: 5)
            }
    }
}

// MARK: - Song picker

private struct MergeSongPicker: View {
    let excluding: Set<UUID>
    let onPick: (Song) -> Void

    @EnvironmentObject private var libraryVM: LibraryViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    private var shown: [Song] {
        let merged = Set(SongMergeService.shared.merges.map(\.id))
        let songs = libraryVM.libraryService.songs.filter { !excluding.contains($0.id) && !merged.contains($0.id) }
        let query = searchText.trimmingCharacters(in: .whitespaces)
        let filtered = query.isEmpty ? songs : songs.filter {
            $0.title.localizedCaseInsensitiveContains(query) || $0.artist.localizedCaseInsensitiveContains(query) || $0.album.localizedCaseInsensitiveContains(query)
        }
        return filtered.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            List(shown) { song in
                Button {
                    onPick(song)
                    dismiss()
                } label: {
                    HStack(spacing: 12) {
                        ArtworkImage(source: song.artworkSource, cornerRadius: 6, points: 44)
                            .frame(width: 44, height: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(song.title).lineLimit(1)
                            Text("\(song.artist) · \(song.album)").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        Text(MergeLaneWaveform.format(song.duration).dropLast(2))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always))
            .navigationTitle("Choose a Song")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
            }
        }
    }
}
