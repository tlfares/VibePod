import SwiftUI

// MARK: - Look

extension CoverPalette {
    /// A Program's tile: the palette's gradient, as on its generated covers.
    var programGradient: LinearGradient {
        LinearGradient(colors: [colors.start.color, colors.end.color], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// A Program's icon: its symbol on its colors.
struct ProgramGlyph: View {
    let symbol: String
    let palette: CoverPalette
    var side: CGFloat = 44

    var body: some View {
        RoundedRectangle(cornerRadius: side * 0.27, style: .continuous)
            .fill(palette.programGradient)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: side * 0.44, weight: .semibold))
                    .foregroundStyle(.white)
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(width: side, height: side)
    }
}

/// An action's icon, colored by its kind as in Shortcuts.
private struct StepIcon: View {
    let symbol: String
    let color: Color
    var side: CGFloat = 30

    var body: some View {
        RoundedRectangle(cornerRadius: side * 0.26, style: .continuous)
            .fill(color.gradient)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: side * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: side, height: side)
    }
}

/// A value inside an action's sentence: tinted, tappable.
private struct ProgramToken: View {
    let text: String
    let tint: Color
    var isPlaceholder = false

    var body: some View {
        Text(text)
            .font(.body.weight(.semibold))
            .foregroundStyle(tint.opacity(isPlaceholder ? 0.7 : 1))
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

/// Words and tokens flowing on lines; a token too long for a line is cut
/// short instead of overflowing.
private struct TokenFlow: Layout {
    var spacing: CGFloat = 5
    var lineSpacing: CGFloat = 7

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = arrange(width: width, subviews: subviews)
        let height = rows.reduce(0) { $0 + $1.height } + CGFloat(max(rows.count - 1, 0)) * lineSpacing
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for (index, size) in zip(row.items, row.sizes) {
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                                      proposal: ProposedViewSize(width: size.width, height: size.height))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row { var items: [Int] = []; var sizes: [CGSize] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            var size = subviews[index].sizeThatFits(.unspecified)
            if size.width > width { size = subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil)) }
            if !row.items.isEmpty, row.width + spacing + size.width > width {
                rows.append(row)
                row = Row()
            }
            row.width += (row.items.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.items.append(index)
            row.sizes.append(size)
        }
        if !row.items.isEmpty { rows.append(row) }
        return rows
    }
}

struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(duration: 0.3, bounce: 0.3), value: configuration.isPressed)
    }
}

// MARK: - Shelf

/// The Programs, between the pinned playlists and the list: a tile each,
/// with its play button.
struct ProgramsShelf: View {
    let width: CGFloat
    @ObservedObject private var store = ProgramStore.shared
    @ObservedObject private var runner = ProgramRunner.shared
    @EnvironmentObject private var libraryVM: LibraryViewModel
    @EnvironmentObject private var playerVM: PlayerViewModel
    @State private var emptyRun: PlaybackProgram?
    @State private var pendingDelete: PlaybackProgram?

    var body: some View {
        if !store.programs.isEmpty {
            // Long and low, one under the other.
            let tileSize = CGSize(width: width > 0 ? width - 40 : 335, height: 60)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    SectionHeader(title: "Programs")
                    Spacer()
                    Button("New Program…", systemImage: "plus") { store.newProgram() }
                        .labelStyle(.iconOnly)
                        .font(.body.weight(.semibold))
                        .buttonStyle(.glass)
                        .buttonBorderShape(.circle)
                }
                .padding(.horizontal, 20)

                VStack(spacing: 10) {
                    ForEach(store.programs) { program in
                        tile(program, size: tileSize)
                            .transition(.scale(scale: 0.94).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
            }
            .alert("Nothing to Play", isPresented: Binding(get: { emptyRun != nil }, set: { if !$0 { emptyRun = nil } })) {
                if let program = emptyRun {
                    Button("Edit Program") { store.edit(program) }
                }
                Button("OK", role: .cancel) {}
            } message: {
                Text("None of this program’s actions found songs in your library.")
            }
            .confirmationDialog("Delete “\(pendingDelete?.name ?? "")”?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
                Button("Delete Program", role: .destructive) {
                    if let program = pendingDelete { withAnimation(.smooth) { store.delete(program) } }
                }
            } message: {
                Text("Your songs stay in your library.")
            }
        }
    }

    private func tile(_ program: PlaybackProgram, size: CGSize) -> some View {
        let isActive = runner.activeID == program.id
        return ProgramTile(program: program, size: size, isActive: isActive,
                           step: isActive ? runner.currentStep : nil, stepCount: runner.stepCount,
                           onPlay: { toggle(program) }, onEdit: { store.edit(program) })
            .contextMenu {
                Button(isActive ? "Stop" : "Play", systemImage: isActive ? "stop.fill" : "play.fill") { toggle(program) }
                Button("Edit", systemImage: "slider.horizontal.3") { store.edit(program) }
                Button("Duplicate", systemImage: "plus.square.on.square") { withAnimation(.smooth) { store.duplicate(program) } }
                Divider()
                Button("Delete", destructiveImage: "trash") { pendingDelete = program }
            }
    }

    private func toggle(_ program: PlaybackProgram) {
        if runner.activeID == program.id {
            runner.end()
            MusicPlayerService.shared.pause()
            return
        }
        if runner.run(program, library: libraryVM, player: playerVM) {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        } else {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            emptyRun = program
        }
    }
}

private struct ProgramTile: View {
    let program: PlaybackProgram
    let size: CGSize
    let isActive: Bool
    let step: Int?
    let stepCount: Int
    let onPlay: () -> Void
    let onEdit: () -> Void

    private static let cornerRadius: CGFloat = 18
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous) }

    var body: some View {
        Button(action: onEdit) {
            HStack(spacing: 14) {
                Image(systemName: program.symbol)
                    .font(.system(size: 20, weight: .semibold))
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(program.name)
                        .font(.headline)
                        .lineLimit(1)
                    subtitle
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white.opacity(0.82))
                        .lineLimit(1)
                }
                Spacer(minLength: 52)
            }
            .foregroundStyle(.white)
            .padding(.leading, 16)
            .frame(width: size.width, height: size.height, alignment: .leading)
            .background {
                ZStack {
                    program.palette.programGradient
                    LinearGradient(colors: [.clear, .black.opacity(0.16)], startPoint: .leading, endPoint: .trailing)
                }
            }
            .clipShape(shape)
            .overlay { GlassRim(cornerRadius: Self.cornerRadius, intensity: 1.5) }
            .overlay {
                shape.strokeBorder(.white.opacity(isActive ? 0.55 : 0), lineWidth: 2)
            }
            .shadow(color: program.palette.colors.end.color.opacity(isActive ? 0.55 : 0.22), radius: isActive ? 16 : 8, y: 6)
            .contentShape(.contextMenuPreview, shape)
        }
        .buttonStyle(PressScaleStyle())
        .overlay(alignment: .trailing) {
            Button(action: onPlay) {
                Image(systemName: isActive ? "stop.fill" : "play.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 40, height: 40)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.tint(.white.opacity(0.12)).interactive(), in: .circle)
            .padding(.trailing, 10)
            .accessibilityLabel(isActive ? Text("Stop") : Text("Play \(program.name)"))
        }
        .animation(.smooth, value: isActive)
    }

    @ViewBuilder private var subtitle: some View {
        if isActive, let step {
            HStack(spacing: 4) {
                Image(systemName: "waveform")
                    .symbolEffect(.variableColor.iterative.reversing)
                Text("Step \(step + 1) of \(stepCount)")
            }
        } else {
            HStack(spacing: 4) {
                Text(program.steps.count == 1 ? String(localized: "1 action") : String(localized: "\(program.steps.count) actions"))
                if let minutes = program.stopAfter {
                    Text(verbatim: "·")
                    Image(systemName: "moon.fill")
                    Text(ProgramFormat.minutes(minutes))
                }
            }
        }
    }
}

// MARK: - Sentences

extension ProgramStep.Kind {
    /// The source still to pick, in its token.
    var placeholder: String {
        switch self {
        case .song: String(localized: "Song")
        case .album: String(localized: "Album")
        case .artist: String(localized: "Artist")
        case .genre: String(localized: "Genre")
        case .playlist: String(localized: "Playlist")
        case .decade: String(localized: "Decade")
        case .selection: String(localized: "Smart Pick")
        case .library: String(localized: "your library")
        }
    }

    /// The word between the amount and the source.
    var connector: String {
        switch self {
        case .artist: String(localized: "by", comment: "Program action: Play [all the songs] by [Artist]")
        case .decade: String(localized: "from the", comment: "Program action: Play [all the songs] from the [1990s]")
        default: String(localized: "from", comment: "Program action: Play [3 songs] from [Album]")
        }
    }

    var pickerTitle: String {
        switch self {
        case .song: String(localized: "Songs")
        case .album: String(localized: "Albums")
        case .artist: String(localized: "Artists")
        case .genre: String(localized: "Genres")
        case .playlist: String(localized: "Playlists")
        case .decade: String(localized: "Decades")
        case .selection: String(localized: "Smart Picks")
        case .library: String(localized: "Library")
        }
    }
}

extension ProgramStep {
    /// Takes the source picked in `other`, keeping how much and how it plays.
    mutating func adoptSource(of other: ProgramStep) {
        songID = other.songID
        album = other.album
        name = other.name
        playlistID = other.playlistID
        decade = other.decade
        selection = other.selection
    }

    @MainActor
    func sourceTitle(in library: LibraryViewModel) -> String? {
        switch kind {
        case .song: songID.flatMap { id in library.songs.first { $0.id == id } }?.title
        case .album: album?.name
        case .artist, .genre: name
        case .playlist: playlistID.flatMap { id in library.playlists.first { $0.id == id } }?.name
        case .decade: decade.map { String(localized: "\(String($0))s", comment: "A decade in a program action: from the [1990s]") }
        case .selection: selection?.title
        case .library: kind.placeholder
        }
    }

    var hasSource: Bool {
        switch kind {
        case .song: songID != nil
        case .album: album != nil
        case .artist, .genre: name != nil
        case .playlist: playlistID != nil
        case .decade: decade != nil
        case .selection: selection != nil
        case .library: true
        }
    }

    static func timesTitle(_ count: Int) -> String {
        switch count {
        case 1: String(localized: "once")
        case 2: String(localized: "twice")
        default: String(localized: "\(count) times")
        }
    }
}

// MARK: - Action card

private struct ProgramStepCard: View {
    @Binding var step: ProgramStep
    let isFirst: Bool
    let isMissing: Bool
    let sourceTitle: String?
    let onChooseSource: () -> Void
    let onDuplicate: () -> Void
    let onDelete: () -> Void

    private var tint: Color { step.kind.color }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            StepIcon(symbol: step.kind == .selection ? (step.selection?.symbol ?? step.kind.symbol) : step.kind.symbol, color: tint)
            TokenFlow {
                sentence
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 3)
            Menu {
                if step.kind.needsSource {
                    Button("Change \(step.kind.placeholder)…", systemImage: "arrow.triangle.2.circlepath") { onChooseSource() }
                }
                Button("Duplicate", systemImage: "plus.square.on.square") { onDuplicate() }
                Button("Delete", destructiveImage: "trash") { onDelete() }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .contentShape(.rect)
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder private var sentence: some View {
        Text("Play", comment: "Program action, before what plays")
        if step.kind == .song {
            sourceToken
            Menu {
                Picker("Times", selection: $step.repeats.animation(.smooth)) {
                    ForEach(1...10, id: \.self) { Text(ProgramStep.timesTitle($0)).tag($0) }
                }
            } label: {
                ProgramToken(text: ProgramStep.timesTitle(step.repeats), tint: tint)
            }
        } else {
            amountToken
            Text(step.kind.connector)
            sourceToken
            orderToken
            if !isFirst {
                Menu {
                    Picker("Songs Played Before", selection: $step.skipsEarlier.animation(.smooth)) {
                        Text("Leave Out Songs Played Before").tag(true)
                        Text("Include Songs Played Before").tag(false)
                    }
                } label: {
                    ProgramToken(text: step.skipsEarlier ? String(localized: "except those played before") : String(localized: "including those played before"), tint: tint)
                }
            }
        }
    }

    @ViewBuilder private var sourceToken: some View {
        switch step.kind {
        case .library:
            ProgramToken(text: step.kind.placeholder, tint: tint)
        case .selection:
            Menu {
                Picker("Smart Pick", selection: $step.selection.animation(.smooth)) {
                    ForEach(ProgramStep.offeredSelections) { selection in
                        Label(selection.title, systemImage: selection.symbol).tag(Optional(selection))
                    }
                }
            } label: {
                ProgramToken(text: sourceTitle ?? step.kind.placeholder, tint: tint)
            }
        default:
            Button(action: onChooseSource) {
                if isMissing, step.hasSource {
                    ProgramToken(text: sourceTitle ?? String(localized: "Not in Library"), tint: .red)
                } else {
                    ProgramToken(text: sourceTitle ?? step.kind.placeholder, tint: tint, isPlaceholder: !step.hasSource)
                }
            }
            .buttonStyle(.borderless)
        }
    }

    private var amountToken: some View {
        Menu {
            Picker("Amount", selection: $step.amount.animation(.smooth)) {
                Text("All the Songs").tag(ProgramStep.Amount.all)
            }
            Picker("A Number of Songs", selection: $step.amount.animation(.smooth)) {
                ForEach(ProgramStep.Amount.songChoices, id: \.self) { count in
                    Text(ProgramStep.Amount.songs(count).title).tag(ProgramStep.Amount.songs(count))
                }
            }
            .pickerStyle(.menu)
            Picker("A Duration", selection: $step.amount.animation(.smooth)) {
                ForEach(ProgramStep.Amount.minuteChoices, id: \.self) { minutes in
                    Text(ProgramFormat.minutes(minutes)).tag(ProgramStep.Amount.minutes(minutes))
                }
            }
            .pickerStyle(.menu)
        } label: {
            ProgramToken(text: step.amount.title, tint: tint)
        }
    }

    private var orderToken: some View {
        Menu {
            Picker("Order", selection: $step.order.animation(.smooth)) {
                Label(step.kind == .selection ? String(localized: "Ranked") : String(localized: "In Order"), systemImage: "list.number")
                    .tag(ProgramStep.Order.inOrder)
                Label("Shuffled", systemImage: "shuffle").tag(ProgramStep.Order.shuffled)
            }
        } label: {
            ProgramToken(text: step.order == .shuffled ? String(localized: "shuffled") : (step.kind == .selection ? String(localized: "ranked") : String(localized: "in order")), tint: tint)
        }
    }
}

// MARK: - Editor

struct ProgramEditorView: View {
    private struct StepRef: Identifiable { let id: UUID }

    let isNew: Bool
    private let original: PlaybackProgram
    @State private var program: PlaybackProgram
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var libraryVM: LibraryViewModel
    @EnvironmentObject private var playerVM: PlayerViewModel
    @ObservedObject private var runner = ProgramRunner.shared

    @State private var showsActions = false
    @State private var showsIcon = false
    @State private var showsDescribe = false
    @State private var sourceStep: StepRef?
    @State private var confirmsDelete = false
    @State private var confirmsDiscard = false
    @State private var estimate = ProgramResolver.Plan()
    @State private var generation: Task<Void, Never>?
    @State private var isGenerating = false
    @State private var generationError: String?
    @FocusState private var nameFocused: Bool

    init(request: ProgramEditorRequest) {
        isNew = request.isNew
        original = request.program
        _program = State(initialValue: request.program)
    }

    private var hasChanges: Bool { program != original }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    header
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 4, trailing: 20))

                Section {
                    ForEach($program.steps) { $step in
                        ProgramStepCard(step: $step,
                                        isFirst: program.steps.first?.id == step.id,
                                        isMissing: estimate.missing.contains(step.id),
                                        sourceTitle: step.sourceTitle(in: libraryVM),
                                        onChooseSource: { sourceStep = StepRef(id: step.id) },
                                        onDuplicate: { duplicate(step) },
                                        onDelete: { remove(step) })
                    }
                    .onMove { source, destination in
                        withAnimation(.smooth) { program.steps.move(fromOffsets: source, toOffset: destination) }
                    }
                    .onDelete { offsets in
                        withAnimation(.smooth) { program.steps.remove(atOffsets: offsets) }
                    }
                    if isGenerating {
                        generatingRow
                    }
                    if program.steps.isEmpty, !isGenerating {
                        emptyState
                    }
                } header: {
                    if !program.steps.isEmpty { Text("Actions") }
                } footer: {
                    if !program.steps.isEmpty { estimateFooter }
                }

                Section {
                    sleepCard
                } header: {
                    Text("When It Ends")
                } footer: {
                    Text("Playback stops even if songs are left, like a sleep timer.")
                }

                if !isNew {
                    Section {
                        Button("Delete Program", role: .destructive) { confirmsDelete = true }
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .listRowSpacing(10)
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom) { bottomBar }
            .navigationTitle(isNew ? "New Program" : "Edit Program")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark", role: .cancel) {
                        if hasChanges { confirmsDiscard = true } else { close() }
                    }
                    .confirmationDialog("Discard your changes?", isPresented: $confirmsDiscard, titleVisibility: .visible) {
                        Button("Discard Changes", role: .destructive) { close() }
                        Button("Keep Editing", role: .cancel) {}
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isNew ? "Create" : "Done", systemImage: "checkmark", role: .confirm) { save(); close() }
                        .disabled(program.steps.isEmpty || isGenerating)
                }
            }
            .interactiveDismissDisabled(hasChanges)
            .task(id: program.steps) {
                estimate = ProgramResolver.resolve(program, library: libraryVM)
            }
            .sheet(isPresented: $showsActions) {
                ProgramActionLibrary { step in
                    withAnimation(.spring(duration: 0.45, bounce: 0.2)) { program.steps.append(step) }
                }
            }
            .sheet(isPresented: $showsIcon) {
                ProgramIconPicker(symbol: $program.symbol, palette: $program.palette)
            }
            .sheet(isPresented: $showsDescribe) {
                ProgramDescribeSheet(replaces: !program.steps.isEmpty) { text in generate(text) }
            }
            .sheet(item: $sourceStep) { ref in
                if let step = program.steps.first(where: { $0.id == ref.id }) {
                    NavigationStack {
                        ProgramSourcePicker(kind: step.kind) { picked in
                            if let index = program.steps.firstIndex(where: { $0.id == ref.id }) {
                                withAnimation(.smooth) { program.steps[index].adoptSource(of: picked) }
                            }
                            sourceStep = nil
                        }
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Cancel", systemImage: "xmark", role: .cancel) { sourceStep = nil }
                            }
                        }
                    }
                }
            }
            .confirmationDialog("Delete “\(program.name)”?", isPresented: $confirmsDelete, titleVisibility: .visible) {
                Button("Delete Program", role: .destructive) {
                    ProgramStore.shared.delete(original)
                    close()
                }
            } message: {
                Text("Your songs stay in your library.")
            }
            .alert("\(AIProvider.current.name)", isPresented: Binding(get: { generationError != nil }, set: { if !$0 { generationError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(generationError ?? "")
            }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 14) {
            Button { showsIcon = true } label: {
                ProgramGlyph(symbol: program.symbol, palette: program.palette, side: 84)
                    .shadow(color: program.palette.colors.end.color.opacity(0.4), radius: 14, y: 8)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "pencil")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.primary)
                            .frame(width: 26, height: 26)
                            .glassEffect(.regular, in: .circle)
                            .offset(x: 6, y: 6)
                    }
            }
            .buttonStyle(PressScaleStyle())
            .accessibilityLabel("Change Icon")

            TextField("Program Name", text: $program.name)
                .font(.title2.bold())
                .multilineTextAlignment(.center)
                .submitLabel(.done)
                .focused($nameFocused)

            if AIFeatures.isAvailable {
                Button {
                    showsDescribe = true
                } label: {
                    Label("Describe It to \(AIProvider.current.name)", systemImage: "sparkles")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.glass)
                .disabled(isGenerating)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    // MARK: Rows

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "rectangle.stack.badge.play")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)
            Text("Build Your Program")
                .font(.headline)
            Text("Add actions one after another: a song, an album, an artist… They play in that order, picked again every time.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .padding(.horizontal, 8)
    }

    private var generatingRow: some View {
        HStack(spacing: 12) {
            ProgressView()
                .frame(width: 30, height: 30)
            Text(program.steps.isEmpty ? "\(AIProvider.current.name) is building your program…" : "\(AIProvider.current.name) is adding actions…")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .phaseAnimator([0.45, 1]) { text, opacity in text.opacity(opacity) } animation: { _ in .easeInOut(duration: 0.9) }
            Spacer()
            Button("Stop") { generation?.cancel() }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.borderless)
        }
        .padding(.vertical, 6)
        .moveDisabled(true)
        .deleteDisabled(true)
    }

    @ViewBuilder private var estimateFooter: some View {
        if estimate.songs.isEmpty {
            Text("No songs to play yet.")
        } else {
            let count = estimate.songs.count
            let duration = program.stopAfter.map { min(estimate.duration, TimeInterval($0 * 60)) } ?? estimate.duration
            Text(count == 1 ? String(localized: "About 1 song · \(ProgramFormat.duration(duration))") : String(localized: "About \(count) songs · \(ProgramFormat.duration(duration))"))
        }
    }

    private var sleepCard: some View {
        HStack(alignment: .top, spacing: 12) {
            StepIcon(symbol: "moon.zzz.fill", color: .indigo)
            TokenFlow {
                Text("Stop playback after", comment: "Program: Stop playback after [30 min]")
                Menu {
                    Picker("Stop After", selection: $program.stopAfter.animation(.smooth)) {
                        Text("Never", comment: "Program: playback never stops").tag(Int?.none)
                        ForEach([5, 10, 15, 20, 30, 45, 60, 90, 120], id: \.self) { minutes in
                            Text(ProgramFormat.minutes(minutes)).tag(Int?.some(minutes))
                        }
                    }
                } label: {
                    ProgramToken(text: program.stopAfter.map(ProgramFormat.minutes) ?? String(localized: "the last song"), tint: .indigo)
                }
                if program.stopAfter != nil {
                    Menu {
                        Picker("Ending", selection: $program.fadesOut.animation(.smooth)) {
                            Text("Fading Out").tag(true)
                            Text("At Once").tag(false)
                        }
                    } label: {
                        ProgramToken(text: program.fadesOut ? String(localized: "fading out") : String(localized: "at once"), tint: .indigo)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 3)
        }
        .padding(.vertical, 6)
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Button {
                nameFocused = false
                showsActions = true
            } label: {
                Label("Add Action", systemImage: "plus")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .disabled(isGenerating)

            Button {
                play()
            } label: {
                Image(systemName: "play.fill")
                    .font(.headline)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .disabled(estimate.songs.isEmpty || isGenerating)
            .accessibilityLabel("Play")
        }
        .controlSize(.large)
        .padding(.horizontal, 20)
        .padding(.bottom, 6)
    }

    // MARK: Actions

    private func duplicate(_ step: ProgramStep) {
        guard let index = program.steps.firstIndex(where: { $0.id == step.id }) else { return }
        var copy = step
        copy.id = UUID()
        withAnimation(.smooth) { program.steps.insert(copy, at: index + 1) }
    }

    private func remove(_ step: ProgramStep) {
        withAnimation(.smooth) { program.steps.removeAll { $0.id == step.id } }
    }

    private func normalized() -> PlaybackProgram {
        var saved = program
        saved.name = saved.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if saved.name.isEmpty { saved.name = String(localized: "My Program") }
        return saved
    }

    private func save() {
        ProgramStore.shared.save(normalized())
    }

    private func play() {
        let saved = normalized()
        if !saved.steps.isEmpty { ProgramStore.shared.save(saved) }
        if runner.run(saved, library: libraryVM, player: playerVM) {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            close()
        }
    }

    private func close() {
        generation?.cancel()
        dismiss()
    }

    /// Mistral's steps come in one by one, as it writes them.
    private func generate(_ description: String) {
        generation?.cancel()
        let previous = program.steps
        let keepsLook = !program.name.trimmingCharacters(in: .whitespaces).isEmpty
        withAnimation(.smooth) {
            program.steps = []
            isGenerating = true
        }
        generation = Task {
            do {
                let stream = try ProgramGenerator.stream(description, library: libraryVM)
                for try await event in stream {
                    switch event {
                    case let .header(header):
                        withAnimation(.smooth(duration: 0.5)) {
                            if !keepsLook {
                                if let name = header.name { program.name = name }
                                if let symbol = header.symbol { program.symbol = symbol }
                                if let palette = header.palette { program.palette = palette }
                            }
                            if let stopAfter = header.stopAfter { program.stopAfter = stopAfter }
                            if let fades = header.fadesOut { program.fadesOut = fades }
                        }
                    case let .step(step):
                        withAnimation(.spring(duration: 0.5, bounce: 0.25)) { program.steps.append(step) }
                        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                    }
                }
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled {
                    if program.steps.isEmpty { program.steps = previous }
                    generationError = error.localizedDescription
                }
            }
            withAnimation(.smooth) { isGenerating = false }
        }
    }
}

// MARK: - Describe

private struct ProgramDescribeSheet: View {
    let replaces: Bool
    let onCreate: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var focused: Bool

    private struct Idea: Identifiable {
        let id = UUID()
        let symbol: String
        let title: String
        let prompt: String
    }

    private var ideas: [Idea] {
        [
            Idea(symbol: "figure.run", title: String(localized: "Workout"),
                 prompt: String(localized: "A workout: two calm songs to warm up, then my most energetic songs shuffled, then the rest of my library.")),
            Idea(symbol: "moon.zzz.fill", title: String(localized: "Sleep"),
                 prompt: String(localized: "To fall asleep: my calmest songs, softly, and stop after 30 minutes with a fade.")),
            Idea(symbol: "brain.head.profile", title: String(localized: "Focus"),
                 prompt: String(localized: "An hour to focus: calm albums played in order, then calm songs shuffled.")),
            Idea(symbol: "car.fill", title: String(localized: "Commute"),
                 prompt: String(localized: "My commute, about 25 minutes: songs I haven’t heard in a while, then recent additions.")),
            Idea(symbol: "party.popper.fill", title: String(localized: "Party"),
                 prompt: String(localized: "A party: my most played songs shuffled, then upbeat genres for two hours."))
        ]
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                TextField("Describe the moment, the music, how long…", text: $text, axis: .vertical)
                    .lineLimit(4...8)
                    .focused($focused)
                    .padding(14)
                    .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                VStack(alignment: .leading, spacing: 10) {
                    Text("Ideas")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(ideas) { idea in
                                Button {
                                    withAnimation(.smooth) { text = idea.prompt }
                                } label: {
                                    Label(idea.title, systemImage: idea.symbol)
                                        .font(.subheadline.weight(.medium))
                                }
                                .buttonStyle(.glass)
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                    .scrollClipDisabled()
                }

                Text(replaces
                     ? "\(AIProvider.current.name) picks from your library and writes the actions. They replace the current ones."
                     : "\(AIProvider.current.name) picks from your library and writes the actions. You can change them afterwards.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(20)
            .navigationTitle("Describe a Program")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create", systemImage: "sparkles", role: .confirm) {
                        let description = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        dismiss()
                        onCreate(description)
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Action library

private struct ProgramActionLibrary: View {
    let onAdd: (ProgramStep) -> Void
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var libraryVM: LibraryViewModel
    @State private var search = ""

    private static let sources: [ProgramStep.Kind] = [.song, .album, .artist, .genre, .playlist, .decade]

    var body: some View {
        NavigationStack {
            List {
                if search.isEmpty {
                    Section("Play From") {
                        ForEach(Self.sources) { kind in
                            NavigationLink {
                                ProgramSourcePicker(kind: kind, onPick: add)
                            } label: {
                                ActionRow(symbol: kind.symbol, color: kind.color, title: kind.title, summary: kind.summary)
                            }
                        }
                    }
                    Section("Smart Picks") {
                        ForEach(ProgramStep.offeredSelections) { selection in
                            Button {
                                var step = ProgramStep(kind: .selection)
                                step.selection = selection
                                add(step)
                            } label: {
                                ActionRow(symbol: selection.symbol, color: ProgramStep.Kind.selection.color, title: selection.title, summary: selection.summary)
                            }
                        }
                    }
                    Section {
                        Button {
                            add(ProgramStep(kind: .library))
                        } label: {
                            ActionRow(symbol: ProgramStep.Kind.library.symbol, color: ProgramStep.Kind.library.color,
                                      title: ProgramStep.Kind.library.title, summary: ProgramStep.Kind.library.summary)
                        }
                    } header: {
                        Text("To Keep Going")
                    } footer: {
                        Text("Put it last: the rest of your library plays after the other actions.")
                    }
                } else {
                    ProgramSourceResults(search: search, onPick: add)
                }
            }
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Songs, Albums, Artists…")
            .navigationTitle("Add Action")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark", role: .cancel) { dismiss() }
                }
            }
        }
    }

    private func add(_ step: ProgramStep) {
        onAdd(step)
        dismiss()
    }
}

private struct ActionRow: View {
    let symbol: String
    let color: Color
    let title: String
    let summary: String

    var body: some View {
        HStack(spacing: 14) {
            StepIcon(symbol: symbol, color: color, side: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(Color.primary)
                Text(summary)
                    .font(.footnote)
                    .foregroundStyle(Color.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Sources

/// Every kind of source matching a search, to add one in a tap.
private struct ProgramSourceResults: View {
    let search: String
    let onPick: (ProgramStep) -> Void
    @EnvironmentObject private var libraryVM: LibraryViewModel

    var body: some View {
        let artists = libraryVM.artists.filter { $0.name.localizedStandardContains(search) }.prefix(5)
        let albums = libraryVM.albums.filter { !$0.isSingle && ($0.title.localizedStandardContains(search) || $0.artist.localizedStandardContains(search)) }.prefix(5)
        let songs = libraryVM.songs.filter { $0.title.localizedStandardContains(search) }.prefix(6)
        let playlists = libraryVM.playlists.filter { $0.name.localizedStandardContains(search) }.prefix(5)
        let genres = libraryVM.genres.filter { $0.name.localizedStandardContains(search) }.prefix(4)

        if artists.isEmpty, albums.isEmpty, songs.isEmpty, playlists.isEmpty, genres.isEmpty {
            ContentUnavailableView.search(text: search)
                .listRowBackground(Color.clear)
        }
        if !artists.isEmpty {
            Section("Artists") {
                ForEach(Array(artists), id: \.name) { artist in
                    SourceRow(title: artist.name, subtitle: ProgramSourcePicker.songCount(artist.songs.count)) {
                        ArtistAvatarView(artistName: artist.name, songs: artist.songs, size: 44)
                    } action: {
                        var step = ProgramStep(kind: .artist)
                        step.name = artist.name
                        onPick(step)
                    }
                }
            }
        }
        if !albums.isEmpty {
            Section("Albums") {
                ForEach(Array(albums), id: \.id) { album in
                    SourceRow(title: album.title, subtitle: album.artist) {
                        ArtworkImage(source: album.artworkSource, cornerRadius: 6, points: 44)
                    } action: {
                        var step = ProgramStep(kind: .album)
                        step.album = album.id
                        onPick(step)
                    }
                }
            }
        }
        if !songs.isEmpty {
            Section("Songs") {
                ForEach(Array(songs)) { song in
                    SourceRow(title: song.title, subtitle: song.artist) {
                        ArtworkImage(source: song.artworkSource, cornerRadius: 6, points: 44)
                    } action: {
                        var step = ProgramStep(kind: .song)
                        step.songID = song.id
                        onPick(step)
                    }
                }
            }
        }
        if !playlists.isEmpty {
            Section("Playlists") {
                ForEach(Array(playlists)) { playlist in
                    SourceRow(title: playlist.name, subtitle: PlaylistListView.detail(for: playlist)) {
                        ArtworkImage(source: libraryVM.playlistArtwork(playlist), cornerRadius: 6, points: 44, placeholderSymbol: "music.note.list")
                    } action: {
                        var step = ProgramStep(kind: .playlist)
                        step.playlistID = playlist.id
                        onPick(step)
                    }
                }
            }
        }
        if !genres.isEmpty {
            Section("Genres") {
                ForEach(Array(genres), id: \.name) { genre in
                    SourceRow(title: genre.name, subtitle: ProgramSourcePicker.songCount(genre.songs.count)) {
                        StepIcon(symbol: "guitars.fill", color: ProgramStep.Kind.genre.color, side: 44)
                    } action: {
                        var step = ProgramStep(kind: .genre)
                        step.name = genre.name
                        onPick(step)
                    }
                }
            }
        }
    }
}

private struct SourceRow<Thumbnail: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let thumbnail: () -> Thumbnail
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                thumbnail()
                    .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

/// Picks one source of a kind: a song, an album, an artist…
struct ProgramSourcePicker: View {
    let kind: ProgramStep.Kind
    let onPick: (ProgramStep) -> Void
    @EnvironmentObject private var libraryVM: LibraryViewModel
    @State private var search = ""

    static func songCount(_ count: Int) -> String {
        count == 1 ? String(localized: "1 song") : String(localized: "\(count) songs")
    }

    var body: some View {
        List {
            content
        }
        .listStyle(.plain)
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always))
        .navigationTitle(kind.pickerTitle)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func matches(_ text: String) -> Bool {
        search.isEmpty || text.localizedStandardContains(search)
    }

    private func pick(_ configure: (inout ProgramStep) -> Void) {
        var step = ProgramStep(kind: kind)
        configure(&step)
        onPick(step)
    }

    @ViewBuilder private var content: some View {
        switch kind {
        case .song:
            ForEach(libraryVM.songs.filter { matches($0.title) || matches($0.artist) }) { song in
                SourceRow(title: song.title, subtitle: song.artist) {
                    ArtworkImage(source: song.artworkSource, cornerRadius: 6, points: 44)
                } action: { pick { $0.songID = song.id } }
            }
        case .album:
            ForEach(libraryVM.albums.filter { !$0.isSingle && (matches($0.title) || matches($0.artist)) }, id: \.id) { album in
                SourceRow(title: album.title, subtitle: album.artist) {
                    ArtworkImage(source: album.artworkSource, cornerRadius: 6, points: 44)
                } action: { pick { $0.album = album.id } }
            }
        case .artist:
            ForEach(libraryVM.artists.filter { matches($0.name) }, id: \.name) { artist in
                SourceRow(title: artist.name, subtitle: Self.songCount(artist.songs.count)) {
                    ArtistAvatarView(artistName: artist.name, songs: artist.songs, size: 44)
                } action: { pick { $0.name = artist.name } }
            }
        case .genre:
            ForEach(libraryVM.genres.filter { matches($0.name) }, id: \.name) { genre in
                SourceRow(title: genre.name, subtitle: Self.songCount(genre.songs.count)) {
                    StepIcon(symbol: "guitars.fill", color: kind.color, side: 44)
                } action: { pick { $0.name = genre.name } }
            }
        case .playlist:
            ForEach(libraryVM.playlists.filter { matches($0.name) }) { playlist in
                SourceRow(title: playlist.name, subtitle: PlaylistListView.detail(for: playlist)) {
                    ArtworkImage(source: libraryVM.playlistArtwork(playlist), cornerRadius: 6, points: 44, placeholderSymbol: "music.note.list")
                } action: { pick { $0.playlistID = playlist.id } }
            }
        case .decade:
            ForEach(decades.filter { matches(AutolistRules.decadeTitle($0.decade)) }, id: \.decade) { entry in
                SourceRow(title: AutolistRules.decadeTitle(entry.decade), subtitle: Self.songCount(entry.count)) {
                    StepIcon(symbol: "calendar", color: kind.color, side: 44)
                } action: { pick { $0.decade = entry.decade } }
            }
        case .selection, .library:
            EmptyView()
        }
    }

    private var decades: [(decade: Int, count: Int)] {
        var counts: [Int: Int] = [:]
        for song in libraryVM.songs where song.year > 1900 {
            counts[song.year / 10 * 10, default: 0] += 1
        }
        return counts.sorted { $0.key > $1.key }.map { (decade: $0.key, count: $0.value) }
    }
}

// MARK: - Icon

private struct ProgramIconPicker: View {
    @Binding var symbol: String
    @Binding var palette: CoverPalette
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 26) {
                    ProgramGlyph(symbol: symbol, palette: palette, side: 96)
                        .shadow(color: palette.colors.end.color.opacity(0.4), radius: 16, y: 8)
                        .padding(.top, 6)

                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 8), spacing: 12) {
                        ForEach(CoverPalette.allCases) { option in
                            Button {
                                withAnimation(.smooth) { palette = option }
                            } label: {
                                Circle()
                                    .fill(option.programGradient)
                                    .aspectRatio(1, contentMode: .fit)
                                    .padding(4)
                                    .overlay {
                                        Circle().strokeBorder(Color.primary.opacity(option == palette ? 0.85 : 0), lineWidth: 2.5)
                                    }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(option.title)
                            .accessibilityAddTraits(option == palette ? .isSelected : [])
                        }
                    }

                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 6), spacing: 12) {
                        ForEach(ProgramGenerator.symbols, id: \.self) { option in
                            Button {
                                withAnimation(.smooth) { symbol = option }
                            } label: {
                                ZStack {
                                    Circle()
                                        .fill(palette.programGradient)
                                        .opacity(option == symbol ? 1 : 0)
                                        .scaleEffect(option == symbol ? 1 : 0.6)
                                    Image(systemName: option)
                                        .font(.system(size: 21, weight: .medium))
                                        .foregroundStyle(option == symbol ? Color.white : Color.primary)
                                }
                                .frame(width: 50, height: 50)
                                .frame(maxWidth: .infinity)
                                .contentShape(.circle)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(20)
            }
            .navigationTitle("Icon")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark", role: .confirm) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
