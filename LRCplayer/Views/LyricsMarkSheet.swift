import SwiftUI

struct LyricsMarkRequest: Identifiable {
    let id = UUID()
    /// The file's line (not cut by an existing mark).
    let line: LyricsLine
}

/// Held line › Song Start & Outro: which word the singing really starts on
/// (a transcript's "Music" over the intro goes), or the outro's first word
/// (talk after the song: kept out of the games, or hidden and skipped).
struct LyricsMarkSheet: View {
    let playerVM: PlayerViewModel
    let line: LyricsLine

    enum Kind: Hashable { case start, outro }

    @Environment(\.dismiss) private var dismiss
    @State private var kind: Kind = .start
    @State private var word = 0
    @State private var skipsOutro = false
    @State private var marks = LyricsMarks()

    private var words: [String] {
        LyricWords.ranges(in: line.text).map { String(line.text[$0]) }
    }

    private var songID: UUID? { playerVM.currentSong?.id }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    Picker("Mark", selection: $kind.animation(.smooth(duration: 0.35))) {
                        Text("Song Starts").tag(Kind.start)
                        Text("Outro Starts").tag(Kind.outro)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    VStack(alignment: .leading, spacing: 14) {
                        Text(kind == .start ? "Tap the first sung word" : "Tap the outro's first word")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .contentTransition(.interpolate)
                        WordFlow(spacing: 6, lineSpacing: 8) {
                            ForEach(words.indices, id: \.self) { index in
                                chip(index)
                            }
                        }
                        Text(explanation)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .contentTransition(.interpolate)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if kind == .outro {
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle("Hide the Outro", isOn: $skipsOutro.animation(.smooth))
                                .font(.body.weight(.semibold))
                            Text(skipsOutro
                                 ? "The outro's lyrics disappear and the next song plays as soon as it starts, as if the song ended there."
                                 : "The outro's lyrics stay, but the games won't ask about them.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .contentTransition(.interpolate)
                        }
                        .padding(16)
                        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .transition(.blurReplace)
                    }

                    if marks.start != nil || marks.outro != nil {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Marks on This Song")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                            if let start = marks.start {
                                markRow(title: "Song starts at", mark: start, symbol: "text.line.first.and.arrowtriangle.forward") {
                                    marks.start = nil
                                }
                            }
                            if let outro = marks.outro {
                                markRow(title: marks.skipsOutro ? "Ends at (outro hidden)" : "Outro starts at", mark: outro, symbol: "text.line.last.and.arrowtriangle.forward") {
                                    marks.outro = nil
                                    marks.skipsOutro = false
                                }
                            }
                        }
                        .transition(.blurReplace)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
            .navigationTitle("Song Start & Outro")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", systemImage: "checkmark") { save() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear(perform: setUp)
        .onChange(of: kind) { _, kind in
            // The word already marked on this line, or the likely one.
            word = defaultWord(for: kind)
            if kind == .outro { skipsOutro = marks.skipsOutro }
        }
        .sensoryFeedback(.selection, trigger: word)
    }

    // MARK: Words

    private func chip(_ index: Int) -> some View {
        let selected = index == word
        // Start: what comes before goes. Outro: what follows is the outro.
        let dropped = kind == .start ? index < word : false
        let isOutro = kind == .outro && index >= word
        return Button {
            withAnimation(.smooth(duration: 0.3)) { word = index }
        } label: {
            Text(words[index])
                .font(.title2.weight(.bold))
                .strikethrough(dropped, color: .white.opacity(0.5))
                .foregroundStyle(.white.opacity(dropped ? 0.3 : (isOutro && !selected ? 0.75 : 1)))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background {
                    if isOutro && !selected {
                        Capsule().fill(.white.opacity(0.08))
                    }
                }
                .glassEffect(selected ? .regular.tint(.white.opacity(0.25)).interactive() : .identity, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var explanation: LocalizedStringKey {
        let chosen = words.indices.contains(word) ? words[word] : ""
        switch kind {
        case .start:
            return word == 0
                ? "The song starts with this line. Pick a later word to leave out what comes before it."
                : "Everything before “\(chosen)” leaves the lyrics, and tapping this line starts the song at “\(chosen)”."
        case .outro:
            return "From “\(chosen)” on, the lyrics are the outro (talk, a skit after the song)."
        }
    }

    private func markRow(title: LocalizedStringKey, mark: LyricsMarks.Mark, symbol: String, remove: @escaping () -> Void) -> some View {
        let markWords = LyricWords.ranges(in: mark.lineText).map { String(mark.lineText[$0]) }
        let shown = markWords.indices.contains(mark.word) ? markWords[mark.word...].prefix(4).joined(separator: " ") : mark.lineText
        return HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("“\(shown)…”")
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button("Remove", systemImage: "trash") {
                // Removed at once: the lyrics come back behind the sheet.
                withAnimation(.smooth) { remove() }
                if let songID { LyricsMarks.save(marks, for: songID) }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.glass)
        }
        .padding(14)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    // MARK: State

    private func setUp() {
        guard let songID else { return }
        marks = LyricsMarks.load(for: songID)
        skipsOutro = marks.skipsOutro
        let lyrics = playerVM.rawLyrics
        let index = lyrics?.lines.firstIndex { $0.id == line.id } ?? 0
        let count = lyrics?.lines.count ?? 1
        // A mark already on this line opens on its kind; else the end of
        // the song suggests an outro, the start a start.
        if let start = marks.start, isThisLine(start) {
            kind = .start
        } else if let outro = marks.outro, isThisLine(outro) {
            kind = .outro
        } else {
            kind = index > count / 2 ? .outro : .start
        }
        word = defaultWord(for: kind)
    }

    private func isThisLine(_ mark: LyricsMarks.Mark) -> Bool {
        mark.lineText == line.text && abs(mark.lineTime - line.time) < 0.5
    }

    private func defaultWord(for kind: Kind) -> Int {
        switch kind {
        case .start:
            if let start = marks.start, isThisLine(start) { return min(start.word, max(words.count - 1, 0)) }
            // "Music Hello…": most likely the second word.
            return words.count > 1 ? 1 : 0
        case .outro:
            if let outro = marks.outro, isThisLine(outro) { return min(outro.word, max(words.count - 1, 0)) }
            return 0
        }
    }

    private func save() {
        guard let songID else { return dismiss() }
        let mark = LyricsMarks.Mark(lineTime: line.time, lineText: line.text, word: word)
        switch kind {
        case .start:
            marks.start = word == 0 && isFirstLine ? nil : mark
        case .outro:
            marks.outro = mark
            marks.skipsOutro = skipsOutro
        }
        LyricsMarks.save(marks, for: songID)
        dismiss()
    }

    /// Starting on the first line's first word is no mark at all.
    private var isFirstLine: Bool {
        playerVM.rawLyrics?.lines.first { !$0.isInstrumentalGap }?.id == line.id
    }
}

/// Words laid out like text: as many per row as fit, wrapping.
struct WordFlow: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + CGFloat(max(rows.count - 1, 0)) * lineSpacing
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.items {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row { var items: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = row.items.isEmpty ? size.width : row.width + spacing + size.width
            if needed > width, !row.items.isEmpty {
                rows.append(row)
                row = Row()
            }
            row.width = row.items.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.items.append(index)
        }
        if !row.items.isEmpty { rows.append(row) }
        return rows
    }
}
