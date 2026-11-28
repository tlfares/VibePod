import SwiftUI
import UniformTypeIdentifiers

/// Settings › Tools › Import Listening History: other services' data
/// exports, linked to the library, added to the stats.
struct HistoryImportView: View {
    @AppStorage(ImportedHistory.separateKey) private var separately = false
    @State private var picking = false
    @State private var session: HistoryImportSession?
    @State private var opened: OpenedPackage?
    @State private var renaming: UUID?
    @State private var newName = ""
    @State private var deleting: UUID?
    @State private var matching: Set<UUID> = []
    @State private var helpOpen = false

    private struct OpenedPackage: Identifiable { let id: UUID }

    private var store: ImportedHistory { .shared }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Bring your listening history from Spotify, Apple Music, Deezer, YouTube Music, Last.fm or ListenBrainz into your stats. Songs are linked to the ones in your library, and what's uncertain is left for you to check.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let session {
                    HistoryImportCard(session: session, chooseAgain: chooseAgain) {
                        withAnimation(.smooth) { self.session = nil }
                    }
                    .transition(.blurReplace)
                } else {
                    chooseCard
                        .transition(.blurReplace)
                }
                if !store.packages.isEmpty {
                    packagesCard
                        .transition(.blurReplace)
                    separateCard
                        .transition(.blurReplace)
                }
                CollapsibleGlassCard(title: "Getting Your Export", systemImage: "questionmark.circle", expanded: $helpOpen) {
                    help
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .animation(.smooth, value: session == nil)
            .animation(.smooth, value: store.packages.map(\.id))
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.zip, .json, .commaSeparatedText, .spreadsheet, .folder, .data], allowsMultipleSelection: true) { result in
            guard case let .success(urls) = result, !urls.isEmpty else { return }
            withAnimation(.smooth) { session = HistoryImportSession(urls: urls) }
        }
        .sheet(item: $opened) { package in
            HistoryPackageDetail(packageID: package.id)
        }
        .alert("Rename Import", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                if let renaming { store.rename(renaming, to: newName) }
            }
        }
        .confirmationDialog("Delete This Import?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete Import", role: .destructive) {
                if let deleting { withAnimation(.smooth) { store.remove(deleting) } }
            }
        } message: {
            Text("Its plays leave your stats. Your export file isn't changed.")
        }
    }

    // MARK: Choose

    private var chooseCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Choose Your Export")
                        .font(.headline)
                    Text("The zip as you received it, or the files inside.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Button(action: chooseAgain) {
                Text("Choose File…")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
        }
        .padding(16)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func chooseAgain() {
        guard SettingsSwipe.allowsTaps else { return }
        session?.cancel()
        session = nil
        picking = true
    }

    // MARK: Packages

    private var packagesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Imported")
                .font(.headline)
            ForEach(Array(store.packages.reversed().enumerated()), id: \.element.id) { position, package in
                if position > 0 { Divider() }
                row(package)
            }
        }
        .padding(16)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func row(_ package: ImportedHistoryPackage) -> some View {
        HStack(spacing: 12) {
            Button {
                guard SettingsSwipe.allowsTaps else { return }
                opened = OpenedPackage(id: package.id)
            } label: {
                HStack(spacing: 12) {
                    HistoryServiceTile(service: package.service, size: 42)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(package.name)
                            .font(.body.weight(.semibold))
                            .lineLimit(1)
                        Text(HistoryFormat.period(package.firstPlay, package.lastPlay))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("\(String(localized: "\(package.countedPlays) plays")) · \(HistoryFormat.percent(package.linkedShare)) in your library")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        if matching.contains(package.id) {
                            Text("Matching…")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.secondary)
                        } else if package.reviewCount > 0 {
                            Text("\(package.reviewCount) to check")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.orange)
                        }
                    }
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Menu {
                Button("Check Songs", systemImage: "checklist") {
                    opened = OpenedPackage(id: package.id)
                }
                Button("Rename", systemImage: "pencil") {
                    newName = package.name
                    renaming = package.id
                }
                Button("Match Again", systemImage: "arrow.triangle.2.circlepath") {
                    matchAgain(package.id)
                }
                Divider()
                Button("Delete Import", destructiveImage: "trash") {
                    deleting = package.id
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.semibold))
                    .frame(width: 36, height: 36)
                    .contentShape(Circle())
            }
            .glassEffect(.regular.interactive(), in: Circle())
        }
    }

    private func matchAgain(_ id: UUID) {
        matching.insert(id)
        Task {
            await store.matchAgain(id)
            matching.remove(id)
        }
    }

    private var separateCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Show Separately", isOn: $separately)
            Text("Imported plays stay out of your VibePod stats, Year in Music and Autolists, and show on their own in Stats.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .onChange(of: separately) {
            NotificationCenter.default.post(name: ListeningStatsService.historyDidChange, object: nil)
        }
    }

    // MARK: Help

    private var help: some View {
        VStack(alignment: .leading, spacing: 14) {
            helpRow(.spotify, "Account › Privacy › Download your data. Ask for the extended streaming history: it goes back to your first play (the account data covers one year).")
            helpRow(.appleMusic, "privacy.apple.com › Get a copy of your data › Apple Media Services information.")
            helpRow(.deezer, "Account settings › Privacy › My personal data: the .xlsx file.")
            helpRow(.youtubeMusic, "takeout.google.com › YouTube and YouTube Music › history, in JSON.")
            helpRow(.lastfm, "A CSV of your scrobbles: artist, album, title, date.")
            helpRow(.listenBrainz, "Settings › Export listens.")
            Text("Your export is read on this iPhone. Only artist names may go to \(AIProvider.current.name), when AI features are on, to spot an artist known under another name.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func helpRow(_ service: ImportedHistoryPackage.Service, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            HistoryServiceTile(service: service, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(service.name)
                    .font(.subheadline.weight(.semibold))
                Text(text)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Import card

/// The import under way: reading, then what it will add.
private struct HistoryImportCard: View {
    @Bindable var session: HistoryImportSession
    let chooseAgain: () -> Void
    let close: () -> Void
    @State private var linkingArtist = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch session.phase {
            case .reading, .matching:
                progress
                    .transition(.blurReplace)
            case .ready:
                summary
                    .transition(.blurReplace)
            case let .failed(message):
                failure(message)
                    .transition(.blurReplace)
            }
        }
        .padding(16)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .animation(.smooth, value: session.phase)
        .sheet(isPresented: $linkingArtist) {
            HistoryArtistLinkSheet(tracks: session.tracks, aliases: session.aliases) { exportArtist, libraryArtist in
                session.link(exportArtist, to: libraryArtist)
            }
        }
    }

    private var progress: some View {
        HStack(spacing: 12) {
            ProgressView()
            VStack(alignment: .leading, spacing: 2) {
                Text(status)
                    .font(.body.weight(.semibold))
                    .contentTransition(.opacity)
                if session.playCount > 0 {
                    Text("\(session.playCount) plays")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
            }
            Spacer(minLength: 8)
            Button("Cancel") {
                session.cancel()
                close()
            }
            .font(.subheadline)
        }
    }

    private var status: LocalizedStringKey {
        switch session.phase {
        case .matching: "Finding your songs…"
        default: "Reading the export…"
        }
    }

    // MARK: Summary

    private var summary: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                HistoryServiceTile(service: session.service, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    TextField("Name", text: $session.name)
                        .font(.headline)
                        .submitLabel(.done)
                    if let first = session.firstPlay, let last = session.lastPlay {
                        Text(HistoryFormat.period(first, last))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 14) {
                GridRow {
                    figure("Plays", session.playCount.formatted())
                    figure("In Your Library", HistoryFormat.percent(session.playCount > 0 ? Double(session.linkedPlays) / Double(session.playCount) : 0))
                }
                GridRow {
                    figure("To Check", session.reviewCount.formatted(), highlighted: session.reviewCount > 0)
                    figure("Already Counted", session.duplicates.formatted())
                }
            }
            Text("Songs not in your library still count, under their own name. You can check and correct the links anytime.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button {
                guard SettingsSwipe.allowsTaps else { return }
                linkingArtist = true
            } label: {
                Label("Artists Not Found", systemImage: "person.crop.circle.badge.questionmark")
                    .font(.subheadline.weight(.medium))
            }
            HStack(spacing: 10) {
                Button {
                    session.cancel()
                    close()
                } label: {
                    Text("Cancel")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                Button {
                    guard SettingsSwipe.allowsTaps else { return }
                    session.commit()
                    close()
                } label: {
                    Text("Add to Stats")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
            }
            .controlSize(.large)
        }
    }

    private func figure(_ title: LocalizedStringKey, _ value: String, highlighted: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2.bold())
                .monospacedDigit()
                .foregroundStyle(highlighted ? AnyShapeStyle(.orange) : AnyShapeStyle(.primary))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func failure(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline)
                .foregroundStyle(.orange)
            HStack(spacing: 10) {
                Button(action: close) {
                    Text("Cancel")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                Button(action: chooseAgain) {
                    Text("Choose Another File")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
            }
            .controlSize(.large)
        }
    }
}

// MARK: - Package detail

/// An import's songs: what to check, what's linked, what isn't in the
/// library, what's left out; and the artists linked.
private struct HistoryPackageDetail: View {
    let packageID: UUID

    @Environment(\.dismiss) private var dismiss
    @State private var filter = Filter.review
    @State private var search = ""
    @State private var fixing: FixTarget?
    @State private var matching = false
    @State private var didPickFilter = false
    @State private var linkingArtist = false

    private struct FixTarget: Identifiable { let id: Int }

    enum Filter: CaseIterable, Hashable {
        case review, linked, missing, excluded

        var title: LocalizedStringKey {
            switch self {
            case .review: "To Check"
            case .linked: "Linked"
            case .missing: "Missing"
            case .excluded: "Left Out"
            }
        }

        func includes(_ link: ImportedHistoryPackage.Link) -> Bool {
            switch self {
            case .review: link == .review
            case .linked: link == .matched || link == .confirmed
            case .missing: link == .missing || link == .unlinked
            case .excluded: link == .excluded
            }
        }
    }

    private var store: ImportedHistory { .shared }

    var body: some View {
        NavigationStack {
            Group {
                if let package = store.package(packageID) {
                    list(package)
                } else {
                    ContentUnavailableView("Import Deleted", systemImage: "tray")
                }
            }
            .navigationTitle(store.package(packageID)?.name ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button("Match Again", systemImage: "arrow.triangle.2.circlepath") {
                            matching = true
                            Task {
                                await store.matchAgain(packageID)
                                matching = false
                            }
                        }
                    } label: {
                        if matching {
                            ProgressView()
                        } else {
                            Image(systemName: "ellipsis")
                        }
                    }
                    .disabled(matching)
                }
            }
            .searchable(text: $search, prompt: Text("Songs and Artists"))
        }
        .sheet(item: $fixing) { target in
            HistoryTrackFixSheet(packageID: packageID, index: target.id)
        }
        .sheet(isPresented: $linkingArtist) {
            if let package = store.package(packageID) {
                HistoryArtistLinkSheet(tracks: package.tracks, aliases: package.aliases) { exportArtist, libraryArtist in
                    matching = true
                    Task {
                        await store.setAlias(packageID, exportArtist: exportArtist, libraryArtist: libraryArtist)
                        matching = false
                    }
                }
            }
        }
        .onAppear {
            guard !didPickFilter, let package = store.package(packageID) else { return }
            didPickFilter = true
            if package.reviewCount == 0 { filter = .linked }
        }
    }

    private func list(_ package: ImportedHistoryPackage) -> some View {
        let rows = rows(in: package)
        let library = AppModel.shared.libraryService
        return List {
            Section {
                HStack(spacing: 12) {
                    HistoryServiceTile(service: package.service, size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(HistoryFormat.period(package.firstPlay, package.lastPlay))
                            .font(.subheadline.weight(.semibold))
                        Text("\(String(localized: "\(package.countedPlays) plays")) · \(HistoryFormat.percent(package.linkedShare)) in your library")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        if let duplicates = store.duplicates[package.id], duplicates > 0 {
                            Text("\(duplicates) already counted elsewhere")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Picker("Show", selection: $filter) {
                    ForEach(Filter.allCases, id: \.self) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .listRowSeparator(.hidden)
            }

            Section {
                if rows.isEmpty {
                    Text(search.isEmpty ? emptyNote : String(localized: "No Results"))
                        .foregroundStyle(.secondary)
                }
                ForEach(rows, id: \.self) { index in
                    let track = package.tracks[index]
                    Button {
                        fixing = FixTarget(id: index)
                    } label: {
                        HistoryTrackRow(track: track, song: track.songID.flatMap(library.song(withID:)))
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        if track.link == .review {
                            Button("Confirm", systemImage: "checkmark") {
                                store.setLink(packageID, track: index, songID: track.songID, link: .confirmed)
                            }
                            .tint(.green)
                        } else if track.link == .excluded {
                            Button("Count", systemImage: "arrow.uturn.backward") {
                                store.setLink(packageID, track: index, songID: track.songID, link: track.songID == nil ? .missing : .confirmed)
                            }
                            .tint(.blue)
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if track.link == .review || track.isLinked {
                            Button("Unlink", systemImage: "link") {
                                store.setLink(packageID, track: index, songID: nil, link: .unlinked)
                            }
                            .tint(.orange)
                        }
                        if track.link != .excluded {
                            Button("Leave Out", systemImage: "eye.slash") {
                                store.setLink(packageID, track: index, songID: track.songID, link: .excluded)
                            }
                            .tint(.gray)
                        }
                    }
                }
            } header: {
                if filter == .review, !rows.isEmpty, search.isEmpty {
                    HStack {
                        Text("\(rows.count) to check")
                        Spacer()
                        Button("Confirm All") {
                            withAnimation(.smooth) { store.confirmAll(packageID) }
                        }
                        .font(.subheadline.weight(.semibold))
                        .textCase(nil)
                    }
                }
            } footer: {
                if !rows.isEmpty {
                    Text(footnote)
                }
            }

            Section {
                ForEach(package.aliases.sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }, id: \.key) { alias in
                    HStack(spacing: 8) {
                        Text(alias.key)
                        Image(systemName: "arrow.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                        Text(alias.value)
                            .foregroundStyle(.secondary)
                    }
                    .lineLimit(1)
                    .swipeActions {
                        Button("Unlink", systemImage: "link", role: .destructive) {
                            matching = true
                            Task {
                                await store.setAlias(packageID, exportArtist: alias.key, libraryArtist: nil)
                                matching = false
                            }
                        }
                    }
                }
                Button {
                    linkingArtist = true
                } label: {
                    Label("Link an Artist…", systemImage: "person.crop.circle.badge.checkmark")
                }
            } header: {
                Text("Linked Artists")
            } footer: {
                Text("For an artist your library knows under another name, like a project and the person behind it: its plays count for the artist of your library, and its songs are matched again.")
            }
        }
        .animation(.smooth, value: filter)
    }

    private func rows(in package: ImportedHistoryPackage) -> [Int] {
        let query = search.trimmingCharacters(in: .whitespaces)
        return package.tracks.indices
            .filter { index in
                let track = package.tracks[index]
                guard filter.includes(track.link) else { return false }
                guard !query.isEmpty else { return true }
                return track.title.localizedCaseInsensitiveContains(query)
                    || track.artist.localizedCaseInsensitiveContains(query)
                    || track.album.localizedCaseInsensitiveContains(query)
            }
            .sorted { package.tracks[$0].plays > package.tracks[$1].plays }
    }

    private var emptyNote: String {
        switch filter {
        case .review: String(localized: "Nothing to check.")
        case .linked: String(localized: "No song linked to your library.")
        case .missing: String(localized: "Every song is in your library.")
        case .excluded: String(localized: "Nothing left out.")
        }
    }

    private var footnote: String {
        switch filter {
        case .review: String(localized: "Probably the same song: another version, or a title written differently. Until confirmed, they count under their own name. Swipe to confirm, or tap to choose another song.")
        case .linked: String(localized: "These plays count for the songs of your library.")
        case .missing: String(localized: "These songs aren't in your library: their plays count under their own name. Tap one to link it.")
        case .excluded: String(localized: "These plays don't count in your stats.")
        }
    }
}

private struct HistoryTrackRow: View {
    let track: ImportedHistoryPackage.Track
    let song: Song?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .lineLimit(1)
                    Text([track.artist, track.album].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(track.plays.formatted())
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if let song, track.link == .review || track.isLinked {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                    ArtworkImage(source: song.artworkSource, cornerRadius: 4, points: 24)
                        .frame(width: 24, height: 24)
                    Text("\(song.title) — \(song.artist)")
                        .font(.footnote)
                        .foregroundStyle(track.link == .review ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                }
            }
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Fix a song

/// Links a song of the export to the right song of the library, or says
/// it isn't there, or leaves it out.
private struct HistoryTrackFixSheet: View {
    let packageID: UUID
    let index: Int

    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var suggestions: [Song] = []
    @State private var linkingArtist = false

    private var store: ImportedHistory { .shared }
    private var track: ImportedHistoryPackage.Track? {
        store.package(packageID).flatMap { $0.tracks.indices.contains(index) ? $0.tracks[index] : nil }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let track {
                    list(track)
                } else {
                    ContentUnavailableView("Import Deleted", systemImage: "tray")
                }
            }
            .navigationTitle("Link Song")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .searchable(text: $search, prompt: Text("Search Your Library"))
        }
        .task { suggestions = suggest() }
        .sheet(isPresented: $linkingArtist) {
            if let track {
                HistoryArtistPicker(exportArtist: track.artist) { artist in
                    let id = packageID
                    let exportArtist = track.artist
                    Task { await ImportedHistory.shared.setAlias(id, exportArtist: exportArtist, libraryArtist: artist) }
                    dismiss()
                }
            }
        }
    }

    private func list(_ track: ImportedHistoryPackage.Track) -> some View {
        let library = AppModel.shared.libraryService
        let current = track.songID.flatMap(library.song(withID:))
        return List {
            Section {
                VStack(alignment: .leading, spacing: 3) {
                    Text(track.title)
                        .font(.headline)
                    Text([track.artist, track.album].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(String(localized: "\(track.plays) plays"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }

            if search.isEmpty {
                Section {
                    if track.link == .excluded {
                        action("Count in Stats", systemImage: "arrow.uturn.backward") {
                            store.setLink(packageID, track: index, songID: track.songID, link: track.songID == nil ? .missing : .confirmed)
                        }
                    } else {
                        if track.songID != nil, track.link == .review || track.isLinked {
                            action("Not This Song", systemImage: "link") {
                                store.setLink(packageID, track: index, songID: nil, link: .unlinked)
                            }
                        }
                        action("Leave Out of Stats", systemImage: "eye.slash") {
                            store.setLink(packageID, track: index, songID: track.songID, link: .excluded)
                        }
                    }
                    Button {
                        linkingArtist = true
                    } label: {
                        Label("Link “\(track.artist)” to an Artist…", systemImage: "person.crop.circle.badge.checkmark")
                    }
                }

                if let current, track.link == .review {
                    Section("Proposed") {
                        songRow(current, track: track)
                    }
                }
                if !suggestions.isEmpty {
                    Section("Suggestions") {
                        ForEach(suggestions.filter { $0.id != current?.id }) { song in
                            songRow(song, track: track)
                        }
                    }
                }
            }

            Section(search.isEmpty ? "All Songs" : "Results") {
                ForEach(results) { song in
                    songRow(song, track: track)
                }
            }
        }
    }

    private func action(_ title: LocalizedStringKey, systemImage: String, perform: @escaping () -> Void) -> some View {
        Button {
            perform()
            dismiss()
        } label: {
            Label(title, systemImage: systemImage)
        }
    }

    private func songRow(_ song: Song, track: ImportedHistoryPackage.Track) -> some View {
        Button {
            store.setLink(packageID, track: index, songID: song.id, link: .confirmed)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                ArtworkImage(source: song.artworkSource, cornerRadius: 6, points: 44)
                    .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(song.title)
                        .lineLimit(1)
                    Text("\(song.artist) · \(song.album)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if song.id == track.songID, track.isLinked {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var results: [Song] {
        let songs = AppModel.shared.libraryService.songs
        let query = search.trimmingCharacters(in: .whitespaces)
        let filtered = query.isEmpty ? songs : songs.filter {
            $0.title.localizedCaseInsensitiveContains(query) || $0.artist.localizedCaseInsensitiveContains(query) || $0.album.localizedCaseInsensitiveContains(query)
        }
        return filtered.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// Library songs whose title shares the most words with this one, its
    /// artist's first.
    private func suggest() -> [Song] {
        guard let track else { return [] }
        let words = Set(HistoryText.looseTitle(track.title).split(separator: " "))
        guard !words.isEmpty else { return [] }
        let artists = HistoryText.artistKeys(store.package(packageID)?.aliases[track.artist] ?? track.artist)
        var scored: [(song: Song, score: Double)] = []
        for song in AppModel.shared.libraryService.songs {
            let other = Set(HistoryText.looseTitle(song.title).split(separator: " "))
            let common = words.intersection(other).count
            guard common > 0 else { continue }
            var score = Double(common) / Double(words.union(other).count)
            if !HistoryText.artistKeys(song.artist).union(song.albumArtist.map(HistoryText.artistKeys) ?? []).isDisjoint(with: artists) { score += 0.5 }
            if score >= 0.4 { scored.append((song, score)) }
        }
        return scored.sorted { $0.score > $1.score }.prefix(6).map(\.song)
    }
}

/// Links an artist of the export to one of the library, by hand: first
/// who in the export (most played first), then who in the library.
private struct HistoryArtistLinkSheet: View {
    let tracks: [ImportedHistoryPackage.Track]
    let aliases: [String: String]
    let onLink: (String, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    /// The export's artists the library doesn't already know by that name,
    /// with their plays.
    private var artists: [(name: String, plays: Int)] {
        let library = Set(AppModel.shared.libraryService.songs.map { HistoryText.key(LibraryIndex.artistName(for: $0)) })
        let query = search.trimmingCharacters(in: .whitespaces)
        return Dictionary(grouping: tracks, by: \.artist)
            .compactMap { artist, tracks -> (name: String, plays: Int)? in
                guard aliases[artist] == nil, !library.contains(HistoryText.key(artist)),
                      query.isEmpty || artist.localizedCaseInsensitiveContains(query) else { return nil }
                return (artist, tracks.reduce(0) { $0 + $1.plays })
            }
            .sorted { $0.plays > $1.plays }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(artists, id: \.name) { artist in
                        NavigationLink {
                            HistoryLibraryArtistList(exportArtist: artist.name) { libraryArtist in
                                onLink(artist.name, libraryArtist)
                                dismiss()
                            }
                        } label: {
                            HStack {
                                Text(artist.name).lineLimit(1)
                                Spacer(minLength: 8)
                                Text(String(localized: "\(artist.plays) plays"))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                    }
                } footer: {
                    Text("Artists of the export your library doesn't have under that name.")
                }
            }
            .navigationTitle("Link an Artist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .searchable(text: $search, prompt: Text("Artists"))
        }
    }
}

/// The artists of the library, to say who an export artist is.
private struct HistoryLibraryArtistList: View {
    let exportArtist: String
    let onPick: (String) -> Void

    @State private var search = ""

    private var artists: [String] {
        let names = Set(AppModel.shared.libraryService.songs.map(LibraryIndex.artistName(for:)))
        let query = search.trimmingCharacters(in: .whitespaces)
        return names
            .filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    var body: some View {
        List {
            Section {
                ForEach(artists, id: \.self) { artist in
                    Button {
                        onPick(artist)
                    } label: {
                        Text(artist)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } footer: {
                Text("Every play of “\(exportArtist)” in this import counts for the artist you choose, and its songs are matched again.")
            }
        }
        .navigationTitle("Who Is “\(exportArtist)”?")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: Text("Artists"))
    }
}

/// The same list on its own, from a song of the export.
private struct HistoryArtistPicker: View {
    let exportArtist: String
    let onPick: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            HistoryLibraryArtistList(exportArtist: exportArtist) { artist in
                onPick(artist)
                dismiss()
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Building blocks

struct HistoryServiceTile: View {
    let service: ImportedHistoryPackage.Service
    var size: CGFloat = 40

    var body: some View {
        Image(systemName: service.symbol)
            .font(.system(size: size * 0.44, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(service.tint.gradient, in: RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
    }
}

extension ImportedHistoryPackage.Service {
    var symbol: String {
        switch self {
        case .spotify: "dot.radiowaves.left.and.right"
        case .appleMusic: "music.note"
        case .deezer: "waveform"
        case .youtubeMusic: "play.fill"
        case .lastfm: "antenna.radiowaves.left.and.right"
        case .listenBrainz: "headphones"
        case .other: "tray.and.arrow.down.fill"
        }
    }

    var tint: Color {
        switch self {
        case .spotify: Color(red: 0.11, green: 0.73, blue: 0.33)
        case .appleMusic: Color(red: 0.98, green: 0.24, blue: 0.33)
        case .deezer: Color(red: 0.6, green: 0.27, blue: 0.98)
        case .youtubeMusic: Color(red: 0.93, green: 0.16, blue: 0.16)
        case .lastfm: Color(red: 0.76, green: 0.08, blue: 0.1)
        case .listenBrainz: Color(red: 0.92, green: 0.48, blue: 0.2)
        case .other: Color(white: 0.45)
        }
    }
}

enum HistoryFormat {
    /// "Mar 2019 – Oct 2023".
    static func period(_ first: Date, _ last: Date) -> String {
        let style = Date.FormatStyle.dateTime.month(.abbreviated).year()
        let start = first.formatted(style)
        let end = last.formatted(style)
        return start == end ? start : "\(start) – \(end)"
    }

    static func percent(_ share: Double) -> String {
        share.formatted(.percent.precision(.fractionLength(0)))
    }
}
