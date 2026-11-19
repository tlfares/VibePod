import SwiftUI

/// Creates or edits an Autolist. The cover and the song count follow every
/// change live.
struct AutolistEditorView: View {
    let request: AutolistEditorRequest
    @EnvironmentObject private var libraryVM: LibraryViewModel
    @EnvironmentObject private var router: AppRouter
    @Environment(\.dismiss) private var dismiss
    @State private var rules: AutolistRules
    @State private var history = AutolistEngine.HistoryCounts()
    @State private var showDeleteConfirmation = false
    @FocusState private var isNameFocused: Bool

    init(request: AutolistEditorRequest) {
        self.request = request
        _rules = State(initialValue: request.rules)
    }

    private var isNew: Bool { request.playlistID == nil }

    var body: some View {
        let matchIDs = libraryVM.previewAutolist(rules, history: history)
        let matches = matchIDs.count
        let mix = libraryVM.mosaicArtwork(Playlist(name: "", songs: matchIDs))
        NavigationStack {
            Form {
                Section {
                    header(mix: mix)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())

                Section {
                    Picker("Songs", selection: $rules.selection.animation(.smooth)) {
                        // The sound picks unlock once Stats has analyzed the library.
                        ForEach(AutolistRules.Selection.allCases.filter { ($0.needsSoundAnalysis ? LibrarySoundAnalysis.isUnlocked : $0.needsWorkouts ? WorkoutListening.isEnabled : true) || $0 == rules.selection }) { selection in
                            Label(selection.title, systemImage: selection.symbol).tag(selection)
                        }
                    }
                    if rules.selection.usesPeriod {
                        Picker("Period", selection: $rules.period.animation(.smooth)) {
                            ForEach(AutolistRules.Period.allCases) { Text($0.title).tag($0) }
                        }
                    }
                    Picker("Maximum", selection: $rules.limit.animation(.smooth)) {
                        ForEach(AutolistRules.limitChoices, id: \.self) { limit in
                            Text(limit.map { String(localized: "\($0) Songs") } ?? String(localized: "No Limit")).tag(limit)
                        }
                    }
                    if rules.selection.hasRanking {
                        Picker("Order", selection: $rules.order) {
                            ForEach(AutolistRules.Order.allCases) { Text($0.title).tag($0) }
                        }
                    }
                } footer: {
                    Text(selectionFooter)
                }

                Section {
                    NavigationLink {
                        MultiSelectionPage(title: "Artists", options: listed(libraryVM.artists.map(\.name), keeping: rules.artists), selection: $rules.artists) { name in
                            // Same round photo as the Artists page; a monogram when unknown.
                            ArtistAvatarView(artistName: name, songs: libraryVM.artist(named: name)?.songs ?? [], size: 36)
                        }
                    } label: {
                        LabeledContent("Artists", value: AutolistRules.artistsSummary(rules.artists) ?? String(localized: "Any"))
                    }
                    NavigationLink {
                        MultiSelectionPage(title: "Genres", options: listed(libraryVM.genres.map(\.name), keeping: rules.genres), selection: $rules.genres)
                    } label: {
                        LabeledContent("Genres", value: AutolistRules.genresSummary(rules.genres) ?? String(localized: "Any"))
                    }
                    Picker("Decade", selection: $rules.decade.animation(.smooth)) {
                        Text("Any").tag(Int?.none)
                        ForEach(decades, id: \.self) { decade in
                            Text(AutolistRules.decadeTitle(decade)).tag(Int?.some(decade))
                        }
                    }
                    Toggle("Only Songs with Lyrics", isOn: $rules.requiresLyrics.animation(.smooth))
                } header: {
                    Text("Filters")
                } footer: {
                    if matches == 0 {
                        Text("No songs match right now.")
                    } else {
                        Text("\(matches) songs match right now.")
                    }
                }

                Section {
                    Picker("Update", selection: $rules.refresh.animation(.smooth)) {
                        ForEach(AutolistRules.Refresh.allCases) { Text($0.title).tag($0) }
                    }
                } footer: {
                    Text(refreshFooter)
                }

                Section("Cover") {
                    CoverChoiceRow(options: styleOptions(mix: mix), selection: Binding(
                        get: { rules.usesMix ? nil : rules.style },
                        set: { new in
                            withAnimation(.smooth) {
                                rules.usesMix = new == nil
                                if let new { rules.style = new }
                            }
                        }
                    ))
                }

                if !rules.usesMix {
                    Section("Colors") {
                        CoverChoiceRow(options: coverOptions, selection: $rules.palette.animation(.smooth))
                    }
                }

                if !isNew {
                    Section {
                        Button("Delete Autolist", role: .destructive) {
                            showDeleteConfirmation = true
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(isNew ? "New Autolist" : "Edit Autolist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isNew ? "Create" : "Done", systemImage: "checkmark", role: .confirm) { save() }
                }
            }
            .confirmationDialog("Delete “\(rules.name)”?", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
                Button("Delete Autolist", role: .destructive) { delete() }
            } message: {
                Text("The songs stay in your library.")
            }
        }
    }

    // MARK: Header

    private func header(mix: ArtworkSource?) -> some View {
        VStack(spacing: 18) {
            CoverPreview(source: rules.usesMix ? mix : .generated(rules.cover), side: 200, placeholderSymbol: "music.note.list")
                .shadow(color: .black.opacity(0.3), radius: 18, y: 10)
            TextField(rules.automaticName, text: $rules.customName)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
                .submitLabel(.done)
                .focused($isNameFocused)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 14))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    // MARK: Pickers

    /// Names saved earlier stay listed even if their songs are gone.
    private func listed(_ options: [String], keeping selected: [String]) -> [String] {
        options + selected.filter { !options.contains($0) }
    }

    private var decades: [Int] {
        var set = Set(libraryVM.songs.compactMap { $0.year > 0 ? $0.year / 10 * 10 : nil })
        if let decade = rules.decade { set.insert(decade) }
        return set.sorted(by: >)
    }

    private var selectionFooter: String {
        var text = rules.selection.summary
        if rules.selection.usesPeriod, rules.period != .allTime, !ListeningStatsService.shared.isEnabled {
            text += " " + String(localized: "Plays in a period come from your listening history, which is off: turn it on in Settings › Stats.")
        }
        return text
    }

    private var refreshFooter: String {
        let text = switch rules.refresh {
        case .instant: String(localized: "Picks its songs again as soon as you listen or add music.")
        case .manual: String(localized: "Picks its songs again only when you choose Refresh Autolist in its \u{2022}\u{2022}\u{2022} menu.")
        case .daily: String(localized: "Picks its songs again every day. Refresh Autolist in its \u{2022}\u{2022}\u{2022} menu does it right away.")
        case .everyTwoDays: String(localized: "Picks its songs again every 2 days. Refresh Autolist in its \u{2022}\u{2022}\u{2022} menu does it right away.")
        case .weekly: String(localized: "Picks its songs again every week. Refresh Autolist in its \u{2022}\u{2022}\u{2022} menu does it right away.")
        case .monthly: String(localized: "Picks its songs again every month. Refresh Autolist in its \u{2022}\u{2022}\u{2022} menu does it right away.")
        }
        guard rules.refresh != .instant,
              let date = request.playlistID.flatMap(libraryVM.playlist(withID:))?.autolistUpdatedAt else { return text }
        return text + " " + String(localized: "Last updated \(date.formatted(.relative(presentation: .named))).")
    }

    // MARK: Cover

    /// Mix (`nil`), then each drawn style in the colors picked so far.
    private func styleOptions(mix: ArtworkSource?) -> [CoverChoiceRow<CoverStyle?>.Option] {
        var options: [CoverChoiceRow<CoverStyle?>.Option] = [.init(id: nil, title: String(localized: "Mix"), source: mix)]
        for style in CoverStyle.allCases {
            var preview = rules
            preview.style = style
            options.append(.init(id: style, title: style.title, source: .generated(preview.cover)))
        }
        return options
    }

    /// Real covers to pick from: the selection's own colors, then each palette.
    private var coverOptions: [CoverChoiceRow<CoverPalette?>.Option] {
        var options = [CoverChoiceRow<CoverPalette?>.Option]()
        for palette in [nil] + CoverPalette.allCases.map(Optional.some) {
            var preview = rules
            preview.palette = palette
            options.append(.init(id: palette, title: palette?.title ?? String(localized: "Auto"), source: .generated(preview.cover)))
        }
        return options
    }

    // MARK: Actions

    private func save() {
        if let id = request.playlistID {
            libraryVM.updateAutolist(id: id, rules: rules)
            dismiss()
        } else {
            let playlist = libraryVM.createAutolist(rules)
            dismiss()
            router.open(.playlist(playlist.id))
        }
    }

    private func delete() {
        guard let id = request.playlistID, let playlist = libraryVM.playlist(withID: id) else { return }
        dismiss()
        // Leave the Autolist's page if it is the one on screen.
        if case let .playlist(shown, _)? = router.paths[router.selectedTab]?.last, shown == id {
            router.pop()
        }
        libraryVM.deletePlaylist(playlist)
    }
}
