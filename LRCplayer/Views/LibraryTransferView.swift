import SwiftUI
import UniformTypeIdentifiers

/// Settings › Tools › Library Transfer: sends songs to another device
/// running VibePod nearby, or receives them.
struct LibraryTransferView: View {
    @ObservedObject private var transfer = LibraryTransferService.shared
    @State private var choosingSongs = false
    @State private var choosingForExport = false
    @State private var importing = false
    @State private var savingArchive = false
    @AppStorage(TransferContent.storageKey) private var contentRaw = TransferContent.all.rawValue

    private var included: TransferContent { TransferContent(rawValue: contentRaw) }

    private func includes(_ part: TransferContent) -> Binding<Bool> {
        Binding(
            get: { included.contains(part) },
            set: { on in
                var new = included
                if on { new.insert(part) } else { new.remove(part) }
                // Something has to go.
                if !new.isEmpty { contentRaw = new.rawValue }
            }
        )
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                header
                content
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 32)
            .animation(.smooth, value: transfer.state)
            .animation(.smooth, value: transfer.peers)
        }
        .scrollIndicators(.hidden)
        .background(Color(uiColor: .settingsBackground).ignoresSafeArea())
        .sheet(isPresented: $choosingSongs) {
            TransferSelectionView { songs in
                if choosingForExport {
                    transfer.startExport(songs, content: included)
                } else {
                    transfer.startSending(songs, content: included)
                }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.zip]) { result in
            if case let .success(url) = result { transfer.startImport(from: url) }
        }
        .fileMover(isPresented: $savingArchive, file: transfer.exportedArchive) { _ in }
        .alert(
            transfer.invitation.map(Self.invitationTitle) ?? "",
            isPresented: Binding(
                get: { transfer.invitation != nil },
                set: { if !$0 { transfer.invitation?.decline() } }
            ),
            presenting: transfer.invitation
        ) { invitation in
            Button("Decline", role: .cancel) { invitation.decline() }
            Button("Accept") { invitation.accept() }
        } message: { invitation in
            Text(invitation.content.contains(.audio)
                 ? "Songs you already have won't be sent again."
                 : "Only for songs you already have.")
        }
        .onDisappear {
            // Nobody is left to pick a device or answer an invitation.
            switch transfer.state {
            case .browsing, .advertising, .finished, .failed: transfer.cancel()
            default: break
            }
        }
    }

    // MARK: Sections

    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.up.arrow.down")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 64, height: 64)
                .glassEffect(.regular.tint(AppTint.current.color.opacity(0.25)), in: .circle)
            Text("Library Transfer").font(.title2.bold())
            Text("Send songs, lyrics and stats to your other devices nearby, or keep them in a zip file.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        switch transfer.state {
        case .idle:
            startCards
        case .browsing:
            browsingCard
        case .advertising:
            advertisingCard
        case let .connecting(peer):
            card {
                HStack(spacing: 12) {
                    ProgressView()
                    Text(transfer.isSending ? "Waiting for \(peer)…" : "Connecting to \(peer)…")
                }
                if transfer.isSending {
                    Text("Accept the transfer on \(peer).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                cancelButton
            }
        case let .transferring(peer):
            transferringCard(title: transfer.isSending ? "Sending to \(peer)" : "Receiving from \(peer)", footnote: "Keep VibePod open on both devices until the end.")
        case let .archiving(isExport):
            transferringCard(title: isExport ? "Exporting" : "Importing", footnote: "Keep VibePod open until the end.")
        case let .finished(summary):
            finishedCard(summary)
        case let .failed(message):
            card {
                Label("Transfer Stopped", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.yellow)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                doneButton
            }
        }
    }

    private var startCards: some View {
        VStack(spacing: 16) {
            card {
                Label("Include", systemImage: "checklist").font(.headline)
                Toggle("Music", isOn: includes(.audio))
                Toggle("Lyrics", isOn: includes(.lyrics))
                Toggle("Stats", isOn: includes(.stats))
                Text(included.contains(.audio)
                     ? String(localized: "Lyrics come with their word sync. Stats are play counts, listening history and most replayed lines.")
                     : Self.withoutMusicNote(included))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
            }
            .animation(.smooth, value: contentRaw)
            card {
                Label("Send", systemImage: "arrow.up.circle.fill").font(.headline)
                Text("Choose artists, albums or songs, then a device nearby with Library Transfer open on Receive. Songs it already has are skipped, so sending again only sends what's new.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button {
                    choosingForExport = false
                    choosingSongs = true
                } label: {
                    Text("Choose Music…").frame(maxWidth: .infinity).padding(.vertical, 4)
                }
                .buttonStyle(.glassProminent)
            }
            card {
                Label("Receive", systemImage: "arrow.down.circle.fill").font(.headline)
                Text("Makes this \(UIDevice.current.model) visible to your other devices while this page is open. Received songs are stored in VibePod.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button {
                    transfer.startReceiving()
                } label: {
                    Text("Receive").frame(maxWidth: .infinity).padding(.vertical, 4)
                }
                .buttonStyle(.glass)
            }
            card {
                Label("Zip File", systemImage: "doc.zipper").font(.headline)
                Text("Export what you choose into a zip, to keep or to open on another device. Importing adds the songs you don't have, and lyrics and stats to the ones you do.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Button {
                        choosingForExport = true
                        choosingSongs = true
                    } label: {
                        Text("Export…").frame(maxWidth: .infinity).padding(.vertical, 4)
                    }
                    .buttonStyle(.glass)
                    Button {
                        importing = true
                    } label: {
                        Text("Import…").frame(maxWidth: .infinity).padding(.vertical, 4)
                    }
                    .buttonStyle(.glass)
                }
            }
        }
    }

    private var browsingCard: some View {
        card {
            HStack(spacing: 10) {
                Text("Choose a Device").font(.headline)
                Spacer()
                ProgressView()
            }
            if transfer.peers.isEmpty {
                Text("Open VibePod on your other device, then Settings › Library Transfer › Receive. Both need Wi-Fi and Bluetooth on.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(transfer.peers) { peer in
                        Button {
                            transfer.send(to: peer)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: peer.model.localizedCaseInsensitiveContains("iPad") ? "ipad" : "iphone")
                                    .font(.title3)
                                    .foregroundStyle(.tint)
                                    .frame(width: 28)
                                Text(peer.name)
                                Spacer()
                                Image(systemName: "chevron.forward")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .transition(.opacity)
                        if peer != transfer.peers.last { Divider() }
                    }
                }
            }
            cancelButton
        }
    }

    private var advertisingCard: some View {
        card {
            HStack(spacing: 14) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .symbolEffect(.variableColor.iterative, options: .repeating)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ready to Receive").font(.headline)
                    Text("Visible as \(UIDevice.current.name)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Text("On your other device, open Settings › Library Transfer › Choose Music… Keep this page open.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            cancelButton
        }
    }

    private func transferringCard(title: LocalizedStringKey, footnote: LocalizedStringKey) -> some View {
        let progress = transfer.progress
        return card {
            HStack(spacing: 14) {
                ArtworkImage(source: progress.current?.artworkSource, cornerRadius: 8, points: 56)
                    .frame(width: 56, height: 56)
                    .id(progress.current?.id)
                    .transition(.opacity)
                VStack(alignment: .leading, spacing: 2) {
                    Text(progress.current?.title ?? " ")
                        .font(.headline)
                        .lineLimit(1)
                    Text(progress.current?.artist ?? " ")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .animation(nil, value: progress.current?.id)
            }
            .animation(.smooth, value: progress.current?.id)
            ProgressView(value: progress.fraction)
                .animation(.linear(duration: 0.2), value: progress.fraction)
            HStack {
                Text(title)
                Spacer()
                Text("\(min(progress.completed + 1, max(progress.total, 1))) of \(progress.total)")
                    .monospacedDigit()
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            Text(footnote)
                .font(.footnote)
                .foregroundStyle(.tertiary)
            Button("Stop", role: .destructive) { transfer.cancel() }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity)
                .padding(.top, 4)
        }
    }

    private func finishedCard(_ summary: LibraryTransferService.Summary) -> some View {
        card {
            Label(finishedTitle(summary), systemImage: "checkmark.circle.fill")
                .font(.headline)
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 4) {
                let extras = Extras(summary.content)
                switch summary.mode {
                case .export:
                    Text(Self.exportSummary(summary))
                case .import:
                    if summary.transferred > 0 { Text("\(summary.transferred) songs added.") }
                    if summary.updated > 0 { Text(extras.updated(summary.updated)) }
                    if summary.alreadyThere > 0 { Text("\(summary.alreadyThere) songs already in your library.") }
                    if summary.notThere > 0 { Text("\(summary.notThere) songs skipped: not in your library, and the zip has no audio for them.") }
                case .nearby:
                    if summary.isSender {
                        if summary.content.contains(.audio) || summary.transferred > 0 {
                            Text("\(summary.transferred) songs sent to \(summary.peer).")
                        }
                        if summary.updated > 0 { Text(extras.sent(summary.updated, to: summary.peer)) }
                        if summary.alreadyThere > 0 {
                            Text("\(summary.alreadyThere) songs already on \(summary.peer).")
                        }
                        if summary.notThere > 0 { Text("\(summary.notThere) songs skipped: not on \(summary.peer).") }
                    } else {
                        if summary.transferred > 0 || summary.updated == 0 {
                            Text("\(summary.transferred) songs received from \(summary.peer).")
                        }
                        if summary.updated > 0 { Text(extras.updated(summary.updated)) }
                    }
                }
                if summary.failed > 0 {
                    Text("\(summary.failed) songs couldn't be transferred.")
                        .foregroundStyle(.yellow)
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            if summary.mode == .export, let archive = transfer.exportedArchive {
                HStack(spacing: 12) {
                    Button {
                        savingArchive = true
                    } label: {
                        Label("Save to Files", systemImage: "folder").frame(maxWidth: .infinity).padding(.vertical, 4)
                    }
                    .buttonStyle(.glassProminent)
                    ShareLink(item: archive) {
                        Label("Share", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity).padding(.vertical, 4)
                    }
                    .buttonStyle(.glass)
                }
                .padding(.top, 4)
                Button("Done") { transfer.cancel() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            } else {
                doneButton
            }
        }
    }

    private func finishedTitle(_ summary: LibraryTransferService.Summary) -> LocalizedStringKey {
        switch summary.mode {
        case .export: return "Export Ready"
        case .import: return summary.transferred + summary.updated == 0 ? "Nothing New" : "Import Complete"
        case .nearby: return summary.transferred + summary.updated == 0 ? "Already Up to Date" : "Transfer Complete"
        }
    }

    private var cancelButton: some View {
        Button("Cancel") { transfer.cancel() }
            .buttonStyle(.glass)
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
    }

    private var doneButton: some View {
        Button {
            transfer.cancel()
        } label: {
            Text("Done").frame(maxWidth: .infinity).padding(.vertical, 4)
        }
        .buttonStyle(.glassProminent)
        .padding(.top, 4)
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12, content: content)
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: .rect(cornerRadius: 28))
    }

    static func songs(_ count: Int) -> String {
        String(localized: "\(count) songs")
    }

    private static func invitationTitle(_ invitation: LibraryTransferService.Invitation) -> String {
        let peer = invitation.peer
        let count = invitation.songCount
        if invitation.content.contains(.audio) {
            return count > 0
                ? String(localized: "\(peer) wants to send you \(count) songs.")
                : String(localized: "\(peer) wants to send you songs.")
        }
        switch Extras(invitation.content) {
        case .lyricsAndStats: return String(localized: "\(peer) wants to send you lyrics and stats for \(count) songs.")
        case .lyrics: return String(localized: "\(peer) wants to send you lyrics for \(count) songs.")
        case .stats: return String(localized: "\(peer) wants to send you stats for \(count) songs.")
        }
    }

    private static func withoutMusicNote(_ content: TransferContent) -> String {
        switch Extras(content) {
        case .lyricsAndStats: String(localized: "Without Music, lyrics and stats only go to songs the other device already has. Play counts keep the higher one, so sending twice never counts plays twice.")
        case .lyrics: String(localized: "Without Music, lyrics only go to songs the other device already has. Play counts keep the higher one, so sending twice never counts plays twice.")
        case .stats: String(localized: "Without Music, stats only go to songs the other device already has. Play counts keep the higher one, so sending twice never counts plays twice.")
        }
    }

    private static func exportSummary(_ summary: LibraryTransferService.Summary) -> String {
        let count = summary.transferred
        let hasExtras = !summary.content.subtracting(.audio).isEmpty
        if summary.content.contains(.audio) {
            guard hasExtras else { return String(localized: "\(count) songs in the zip, with their audio.") }
            switch Extras(summary.content) {
            case .lyricsAndStats: return String(localized: "\(count) songs in the zip, with their audio, lyrics and stats.")
            case .lyrics: return String(localized: "\(count) songs in the zip, with their audio and lyrics.")
            case .stats: return String(localized: "\(count) songs in the zip, with their audio and stats.")
            }
        }
        switch Extras(summary.content) {
        case .lyricsAndStats: return String(localized: "\(count) songs in the zip, with no audio, lyrics and stats.")
        case .lyrics: return String(localized: "\(count) songs in the zip, with no audio, lyrics only.")
        case .stats: return String(localized: "\(count) songs in the zip, with no audio, stats only.")
        }
    }

    /// What goes along with (or instead of) the audio.
    private enum Extras {
        case lyricsAndStats, lyrics, stats

        init(_ content: TransferContent) {
            switch (content.contains(.lyrics), content.contains(.stats)) {
            case (true, true): self = .lyricsAndStats
            case (true, false): self = .lyrics
            default: self = .stats
            }
        }

        func updated(_ count: Int) -> String {
            switch self {
            case .lyricsAndStats: String(localized: "Lyrics and stats updated for \(count) songs.")
            case .lyrics: String(localized: "Lyrics updated for \(count) songs.")
            case .stats: String(localized: "Stats updated for \(count) songs.")
            }
        }

        func sent(_ count: Int, to peer: String) -> String {
            switch self {
            case .lyricsAndStats: String(localized: "Lyrics and stats sent for \(count) songs already on \(peer).")
            case .lyrics: String(localized: "Lyrics sent for \(count) songs already on \(peer).")
            case .stats: String(localized: "Stats sent for \(count) songs already on \(peer).")
            }
        }
    }
}

// MARK: - Selection

/// The sheet picking what to send: whole artists, whole albums, or songs.
struct TransferSelectionView: View {
    let onSend: ([Song]) -> Void

    @EnvironmentObject private var libraryVM: LibraryViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var scope = Scope.artists
    @State private var selected = Set<UUID>()
    @State private var searchText = ""
    @State private var sortedSongs: [Song] = []

    enum Scope: CaseIterable {
        case artists, albums, songs

        var title: String {
            switch self {
            case .artists: String(localized: "Artists")
            case .albums: String(localized: "Albums")
            case .songs: String(localized: "Songs")
            }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                switch scope {
                case .artists:
                    ForEach(shownArtists) { artist in
                        row(songs: artist.songs) {
                            ArtistAvatarView(artistName: artist.name, songs: artist.songs, size: 44)
                        } title: {
                            Text(artist.name)
                        } subtitle: {
                            Text(LibraryTransferView.songs(artist.songs.count))
                        }
                    }
                case .albums:
                    ForEach(shownAlbums) { album in
                        row(songs: album.songs) {
                            ArtworkImage(source: album.artworkSource, cornerRadius: 6, points: 44)
                                .frame(width: 44, height: 44)
                        } title: {
                            Text(album.title)
                        } subtitle: {
                            Text(album.artist)
                        }
                    }
                case .songs:
                    ForEach(shownSongs) { song in
                        row(songs: [song]) {
                            ArtworkImage(source: song.artworkSource, cornerRadius: 6, points: 44)
                                .frame(width: 44, height: 44)
                        } title: {
                            Text(song.title)
                        } subtitle: {
                            Text(song.artist)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .overlay {
                if !searchText.isEmpty, isEmptySearch {
                    ContentUnavailableView.search(text: searchText)
                }
            }
            .safeAreaBar(edge: .top) {
                GlassSegmentedPicker("Show", options: Scope.allCases, selection: $scope, title: \.title)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
            .safeAreaBar(edge: .bottom) {
                Button {
                    let songs = libraryVM.songs.filter { selected.contains($0.id) }
                    dismiss()
                    onSend(songs)
                } label: {
                    Text(selected.isEmpty ? "Send" : "Send \(selected.count) songs")
                        .font(.headline)
                        .contentTransition(.numericText())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.glassProminent)
                .disabled(selected.isEmpty)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                .animation(.smooth, value: selected.count)
            }
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always))
            .navigationTitle("Choose Music")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    let allSelected = !libraryVM.songs.isEmpty && selected.count == libraryVM.songs.count
                    Button(allSelected ? "Deselect All" : "Select All") {
                        selected = allSelected ? [] : Set(libraryVM.songs.map(\.id))
                    }
                }
            }
        }
        .task {
            sortedSongs = libraryVM.songs.sorted { $0.title.libraryCompare($1.title) == .orderedAscending }
        }
    }

    // MARK: Rows

    private var shownArtists: [Artist] {
        searchText.isEmpty ? libraryVM.artists : libraryVM.artists.filter { $0.name.localizedStandardContains(searchText) }
    }

    private var shownAlbums: [Album] {
        searchText.isEmpty ? libraryVM.albums : libraryVM.albums.filter {
            $0.title.localizedStandardContains(searchText) || $0.artist.localizedStandardContains(searchText)
        }
    }

    private var shownSongs: [Song] {
        searchText.isEmpty ? sortedSongs : sortedSongs.filter {
            $0.title.localizedStandardContains(searchText) || $0.artist.localizedStandardContains(searchText)
        }
    }

    private var isEmptySearch: Bool {
        switch scope {
        case .artists: shownArtists.isEmpty
        case .albums: shownAlbums.isEmpty
        case .songs: shownSongs.isEmpty
        }
    }

    /// A row selecting all of `songs` at once; partly selected shows a dash.
    private func row<Artwork: View, Title: View, Subtitle: View>(
        songs: [Song],
        @ViewBuilder artwork: () -> Artwork,
        @ViewBuilder title: () -> Title,
        @ViewBuilder subtitle: () -> Subtitle
    ) -> some View {
        let count = songs.lazy.filter { selected.contains($0.id) }.count
        let isAll = count == songs.count && count > 0
        return Button {
            if isAll {
                selected.subtract(songs.map(\.id))
            } else {
                selected.formUnion(songs.map(\.id))
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isAll ? "checkmark.circle.fill" : count > 0 ? "minus.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(count > 0 ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                    .contentTransition(.symbolEffect(.replace))
                artwork()
                VStack(alignment: .leading, spacing: 2) {
                    title().lineLimit(1)
                    subtitle()
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Missing Metadata

/// Fills in covers, genres and years from Apple Music's catalog, then
/// Deezer's. Only what's missing is written.
@MainActor
final class MetadataFetcher: ObservableObject {
    static let shared = MetadataFetcher()

    @Published private(set) var isRunning = false
    @Published private(set) var done = 0
    @Published private(set) var total = 0
    @Published private(set) var filled = 0
    @Published private(set) var failures: [Failure] = []
    /// This run's.
    @Published private(set) var successes: [Success] = []
    /// Every run's, newest first, kept to undo them.
    @Published private(set) var history: [Success] = MetadataFetcher.loadHistory()

    struct Success: Identifiable, Codable {
        var id = UUID()
        let songID: UUID
        let title: String
        let artist: String
        let fields: Fields
        let source: String
        var date = Date()
        /// What the song had before.
        var oldAlbum: String
        var oldGenre: String
        var oldYear: Int
    }

    private static let historyKey = "metadataFetchHistory"

    private static func loadHistory() -> [Success] {
        guard let data = UserDefaults.standard.data(forKey: historyKey) else { return [] }
        return (try? JSONDecoder().decode([Success].self, from: data)) ?? []
    }

    private func saveHistory() {
        UserDefaults.standard.set(try? JSONEncoder().encode(history), forKey: Self.historyKey)
    }

    /// Puts back what the song had before this update.
    func revert(_ success: Success, in library: LibraryService) {
        if var song = library.song(withID: success.songID) {
            if success.fields.contains(.album) { song.album = success.oldAlbum }
            if success.fields.contains(.genre) { song.genre = success.oldGenre }
            if success.fields.contains(.year) { song.year = success.oldYear }
            if success.fields.contains(.cover) { ArtworkStore.remove(for: song.id) }
            library.updateSong(song)
        }
        successes.removeAll { $0.id == success.id }
        history.removeAll { $0.id == success.id }
        saveHistory()
    }

    static func lacksAlbum(_ song: Song) -> Bool {
        let album = song.album.trimmingCharacters(in: .whitespaces)
        return album.isEmpty || album == "Unknown Album"
    }

    struct Fields: OptionSet, Sendable, Codable {
        let rawValue: Int
        static let cover = Fields(rawValue: 1)
        static let genre = Fields(rawValue: 2)
        static let year = Fields(rawValue: 4)
        static let album = Fields(rawValue: 8)

        var names: String {
            [(Fields.cover, String(localized: "Cover")), (.album, String(localized: "Album")), (.genre, String(localized: "Genre")), (.year, String(localized: "Year"))]
                .filter { contains($0.0) }.map(\.1).joined(separator: ", ")
        }
    }

    /// A catalog track.
    struct Candidate: Identifiable, Sendable {
        let id = UUID()
        var title: String
        var artist: String
        var source: String
        var album: String?
        var coverURL: URL?
        var genre: String?
        var year: Int?
        var duration: TimeInterval?
        /// Deezer: genre and year come from the album.
        var deezerAlbumID: Int?
    }

    struct Failure: Identifiable {
        let id = UUID()
        let songID: UUID
        let title: String
        let artist: String
        let fields: Fields
        let reason: String
        /// Close but not close enough: the user picks.
        let candidates: [Candidate]
    }

    static func missing(_ song: Song, in wanted: Fields) -> Fields {
        var fields: Fields = []
        if wanted.contains(.cover), song.artworkData == nil { fields.insert(.cover) }
        if wanted.contains(.genre), song.genre.trimmingCharacters(in: .whitespaces).isEmpty { fields.insert(.genre) }
        if wanted.contains(.year), song.year <= 0 { fields.insert(.year) }
        if wanted.contains(.album), lacksAlbum(song) { fields.insert(.album) }
        return fields
    }

    func run(_ library: LibraryService, fields wanted: Fields) {
        guard !isRunning else { return }
        let songs = library.songs.filter { !Self.missing($0, in: wanted).isEmpty }
        guard !songs.isEmpty else { return }
        isRunning = true
        done = 0
        filled = 0
        failures = []
        successes = []
        total = songs.count
        Task {
            for song in songs {
                let fields = Self.missing(song, in: wanted)
                let outcome = await Self.lookup(song)
                if let match = outcome.match {
                    let missed = await apply(match, to: song.id, fields: fields, in: library)
                    if !missed.isEmpty {
                        failures.append(Failure(songID: song.id, title: song.title, artist: song.artist, fields: missed, reason: String(localized: "Found on \(match.source), without it"), candidates: []))
                    }
                } else {
                    failures.append(Failure(songID: song.id, title: song.title, artist: song.artist, fields: fields, reason: outcome.reason, candidates: outcome.candidates))
                }
                done += 1
            }
            isRunning = false
        }
    }

    /// A candidate picked from the recap.
    func choose(_ candidate: Candidate, for failure: Failure, in library: LibraryService) {
        Task {
            let missed = await apply(candidate, to: failure.songID, fields: failure.fields, in: library)
            failures.removeAll { $0.id == failure.id }
            if !missed.isEmpty {
                failures.append(Failure(songID: failure.songID, title: failure.title, artist: failure.artist, fields: missed, reason: String(localized: "Found on \(candidate.source), without it"), candidates: []))
            }
        }
    }

    /// Writes what the song lacks; returns what the match didn't have.
    private func apply(_ match: Candidate, to id: UUID, fields: Fields, in library: LibraryService) async -> Fields {
        var match = match
        if let album = match.deezerAlbumID, !fields.isDisjoint(with: [.genre, .year]) {
            await Self.deezerAlbum(album, into: &match)
        }
        guard var song = library.song(withID: id) else { return [] }
        let before = song
        var missed: Fields = []
        var changed = false
        if fields.contains(.album) {
            if let album = match.album, !album.isEmpty { song.album = album; changed = true } else { missed.insert(.album) }
        }
        if fields.contains(.cover) {
            if let url = match.coverURL, let data = try? await LyricsHTTP.data(url) {
                ArtworkStore.store(data, for: id)
                ArtworkImageCache.shared.removeImages(forKeyPrefix: id.uuidString)
                changed = true
            } else {
                missed.insert(.cover)
            }
        }
        if fields.contains(.genre) {
            if let genre = match.genre, !genre.isEmpty { song.genre = genre; changed = true } else { missed.insert(.genre) }
        }
        if fields.contains(.year) {
            if let year = match.year, year > 0 { song.year = year; changed = true } else { missed.insert(.year) }
        }
        if changed {
            library.updateSong(song)
            filled += 1
            let success = Success(songID: id, title: song.title, artist: song.artist, fields: fields.subtracting(missed), source: match.source,
                                  oldAlbum: before.album, oldGenre: before.genre, oldYear: before.year)
            successes.append(success)
            history.insert(success, at: 0)
            saveHistory()
        }
        return missed
    }

    // MARK: Matching

    /// Without decorations: "♫ Title ♫" is "Title".
    nonisolated static func clean(_ value: String) -> String {
        let kept = value.unicodeScalars.filter { !$0.properties.isEmojiPresentation && $0.properties.generalCategory != .otherSymbol }
        return String(String.UnicodeScalarView(kept)).trimmingCharacters(in: .whitespaces)
    }

    nonisolated static func score(_ candidate: Candidate, for song: Song) -> Double {
        let title = TextMatch.similarity(TextMatch.core(clean(candidate.title)), TextMatch.core(clean(song.title)))
        let artist = TextMatch.artistSimilarity(candidate.artist, song.artist)
        var durationMatch = 0.5
        if let duration = candidate.duration, song.duration > 0 {
            durationMatch = abs(duration - song.duration) <= 3 ? 1 : 0
        }
        return title * 0.6 + artist * 0.25 + durationMatch * 0.15
    }

    /// Sure enough to apply: same title, and the artist or the length agrees
    /// (an artist credited under another name still matches by length).
    nonisolated static func isSure(_ candidate: Candidate, for song: Song) -> Bool {
        let title = TextMatch.similarity(TextMatch.core(clean(candidate.title)), TextMatch.core(clean(song.title)))
        guard title >= 0.85 else { return false }
        let sameLength = candidate.duration.map { song.duration > 0 && abs($0 - song.duration) <= 3 } ?? false
        return TextMatch.artistSimilarity(candidate.artist, song.artist) >= 0.5 || sameLength
    }

    struct Outcome: Sendable {
        var match: Candidate?
        var reason = ""
        var candidates: [Candidate] = []
    }

    nonisolated private static func lookup(_ song: Song) async -> Outcome {
        let title = clean(song.title)
        let artist = song.artist == "Unknown Artist" ? "" : song.artist
        let (apple, appleResponded) = await apple("\(artist) \(title)")
        var all = apple
        if let sure = apple.first(where: { isSure($0, for: song) }) { return Outcome(match: sure) }
        var fromDeezer = await deezer("\(artist) \(title)")
        if !fromDeezer.contains(where: { isSure($0, for: song) }), !artist.isEmpty { fromDeezer += await deezer(title) }
        all += fromDeezer
        if let sure = fromDeezer.first(where: { isSure($0, for: song) }) { return Outcome(match: sure) }
        guard !all.isEmpty else {
            return Outcome(reason: appleResponded ? String(localized: "Not on Apple Music or Deezer") : String(localized: "Apple Music didn't respond, not on Deezer"))
        }
        let ranked = all.sorted { score($0, for: song) > score($1, for: song) }
        return Outcome(reason: String(localized: "Not sure which one: choose"), candidates: Array(ranked.prefix(8)))
    }

    /// iTunes Search: free, no key, about 20 requests a minute.
    nonisolated private static func apple(_ term: String) async -> ([Candidate], Bool) {
        guard let url = LyricsHTTP.url("https://itunes.apple.com/search", ["term": term, "entity": "song", "limit": "10"]) else { return ([], true) }
        var json: Any?
        for attempt in 0..<3 {
            if let value = try? await LyricsHTTP.json(url) {
                json = value
                break
            }
            // Throttled: wait it out.
            try? await Task.sleep(for: .seconds(attempt == 0 ? 5 : 30))
        }
        try? await Task.sleep(for: .seconds(2.5))
        guard let results = (json as? [String: Any])?["results"] as? [[String: Any]] else { return ([], false) }
        return (results.map { hit in
            Candidate(
                title: hit["trackName"] as? String ?? "",
                artist: hit["artistName"] as? String ?? "",
                source: "Apple Music",
                album: hit["collectionName"] as? String,
                coverURL: (hit["artworkUrl100"] as? String).flatMap { URL(string: $0.replacingOccurrences(of: "100x100bb", with: "1000x1000bb")) },
                genre: hit["primaryGenreName"] as? String,
                year: (hit["releaseDate"] as? String).flatMap { Int($0.prefix(4)) },
                duration: (hit["trackTimeMillis"] as? Double).map { $0 / 1000 }
            )
        }, true)
    }

    nonisolated private static func deezer(_ term: String) async -> [Candidate] {
        guard let url = LyricsHTTP.url("https://api.deezer.com/search", ["q": term, "limit": "10"]),
              let json = try? await LyricsHTTP.json(url),
              let results = (json as? [String: Any])?["data"] as? [[String: Any]] else { return [] }
        return results.map { hit in
            let album = hit["album"] as? [String: Any]
            return Candidate(
                title: hit["title"] as? String ?? "",
                artist: (hit["artist"] as? [String: Any])?["name"] as? String ?? "",
                source: "Deezer",
                album: album?["title"] as? String,
                coverURL: (album?["cover_xl"] as? String).flatMap(URL.init(string:)),
                duration: hit["duration"] as? Double,
                deezerAlbumID: album?["id"] as? Int
            )
        }
    }

    nonisolated private static func deezerAlbum(_ id: Int, into candidate: inout Candidate) async {
        guard let url = URL(string: "https://api.deezer.com/album/\(id)"),
              let album = try? await LyricsHTTP.json(url) as? [String: Any] else { return }
        if candidate.year == nil, let date = album["release_date"] as? String { candidate.year = Int(date.prefix(4)) }
        if candidate.genre == nil,
           let genres = (album["genres"] as? [String: Any])?["data"] as? [[String: Any]] {
            candidate.genre = genres.first?["name"] as? String
        }
    }
}

/// Settings › Tools › Missing Metadata.
struct MetadataFetchView: View {
    @EnvironmentObject private var libraryVM: LibraryViewModel
    @ObservedObject private var fetcher = MetadataFetcher.shared
    @State private var covers = true
    @State private var genres = true
    @State private var years = true
    @State private var albums = true
    @State private var choosing: MetadataFetcher.Failure?

    private var songs: [Song] { libraryVM.libraryService.songs }

    private var fields: MetadataFetcher.Fields {
        var fields: MetadataFetcher.Fields = []
        if covers { fields.insert(.cover) }
        if genres { fields.insert(.genre) }
        if years { fields.insert(.year) }
        if albums { fields.insert(.album) }
        return fields
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Missing covers, albums, genres and years, from Apple Music and Deezer. Only empty fields are filled.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                VStack(spacing: 12) {
                    row("Covers", systemImage: "photo", isOn: $covers, missing: songs.filter { $0.artworkData == nil }.count)
                    Divider()
                    row("Albums", systemImage: "square.stack", isOn: $albums, missing: songs.filter(MetadataFetcher.lacksAlbum).count)
                    Divider()
                    row("Genres", systemImage: "guitars", isOn: $genres, missing: songs.filter { $0.genre.trimmingCharacters(in: .whitespaces).isEmpty }.count)
                    Divider()
                    row("Years", systemImage: "calendar", isOn: $years, missing: songs.filter { $0.year <= 0 }.count)
                }
                .padding(16)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))

                if fetcher.isRunning {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: fetcher.total == 0 ? 0 : Double(fetcher.done) / Double(fetcher.total))
                        Text("\(fetcher.done)/\(fetcher.total) · \(fetcher.filled) updated")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .contentTransition(.numericText())
                    }
                    .transition(.blurReplace)
                } else {
                    Button {
                        withAnimation(.smooth) { fetcher.run(libraryVM.libraryService, fields: fields) }
                    } label: {
                        Label("Fetch", systemImage: "arrow.down.circle.fill")
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .disabled(!songs.contains { !MetadataFetcher.missing($0, in: fields).isEmpty })
                    .transition(.blurReplace)
                    if fetcher.total > 0 {
                        Label("\(fetcher.filled) of \(fetcher.total) songs updated", systemImage: "checkmark.circle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                if !fetcher.failures.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Not Updated (\(fetcher.failures.count))")
                            .font(.headline)
                        ForEach(fetcher.failures) { failure in
                            failureRow(failure)
                            if failure.id != fetcher.failures.last?.id { Divider() }
                        }
                    }
                    .padding(16)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .transition(.blurReplace)
                }
                if !fetcher.successes.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Updated (\(fetcher.successes.count))")
                            .font(.headline)
                        ForEach(fetcher.successes) { success in
                            successRow(success, showsDate: false)
                            if success.id != fetcher.successes.last?.id { Divider() }
                        }
                    }
                    .padding(16)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .transition(.blurReplace)
                }
                let previous = fetcher.history.filter { item in !fetcher.successes.contains { $0.id == item.id } }
                if !previous.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Previous Sessions")
                            .font(.headline)
                        ForEach(previous) { success in
                            successRow(success, showsDate: true)
                            if success.id != previous.last?.id { Divider() }
                        }
                    }
                    .padding(16)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .transition(.blurReplace)
                }
                Label("Apple Music, then Deezer · about 3 s per song", systemImage: "network")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
            .animation(.smooth, value: fetcher.isRunning)
            .animation(.smooth, value: fetcher.done)
            .animation(.smooth, value: fetcher.failures.count)
            .animation(.smooth, value: fetcher.history.count)
        }
        .sheet(item: $choosing) { failure in
            MetadataCandidatesSheet(failure: failure)
        }
    }

    private func successRow(_ success: MetadataFetcher.Success, showsDate: Bool) -> some View {
        HStack(spacing: 12) {
            ArtworkImage(source: libraryVM.libraryService.song(withID: success.songID)?.artworkSource, cornerRadius: 6, points: 44)
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(success.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(showsDate ? "\(success.artist) · \(success.date.formatted(date: .abbreviated, time: .shortened))" : success.artist)
                    .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                Label("\(success.fields.names) · \(success.source)", systemImage: "checkmark.circle")
                    .font(.footnote)
                    .foregroundStyle(.green)
            }
            Spacer(minLength: 0)
            Button {
                withAnimation(.smooth) { fetcher.revert(success, in: libraryVM.libraryService) }
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.footnote.weight(.semibold))
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .accessibilityLabel("Revert")
        }
    }

    @ViewBuilder
    private func failureRow(_ failure: MetadataFetcher.Failure) -> some View {
        let canChoose = !failure.candidates.isEmpty
        let content = HStack(spacing: 12) {
            ArtworkImage(source: libraryVM.libraryService.song(withID: failure.songID)?.artworkSource, cornerRadius: 6, points: 44)
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(failure.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(failure.artist).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                Label("\(failure.fields.names): \(failure.reason)", systemImage: canChoose ? "questionmark.circle" : "exclamationmark.circle")
                    .font(.footnote)
                    .foregroundStyle(canChoose ? .orange : .red)
            }
            Spacer(minLength: 0)
            if canChoose {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        if canChoose {
            Button { choosing = failure } label: { content }
                .buttonStyle(.plain)
        } else {
            content
        }
    }

    private func row(_ title: LocalizedStringKey, systemImage: String, isOn: Binding<Bool>, missing: Int) -> some View {
        Toggle(isOn: isOn) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(missing == 0 ? "None missing" : "\(missing) missing")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: systemImage)
            }
        }
    }
}

/// The catalog's closest tracks for a song: tap the right one.
private struct MetadataCandidatesSheet: View {
    let failure: MetadataFetcher.Failure
    @EnvironmentObject private var libraryVM: LibraryViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(failure.candidates) { candidate in
                Button {
                    MetadataFetcher.shared.choose(candidate, for: failure, in: libraryVM.libraryService)
                    dismiss()
                } label: {
                    HStack(spacing: 12) {
                        AsyncImage(url: candidate.coverURL) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            Color.secondary.opacity(0.2)
                        }
                        .frame(width: 48, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(candidate.title).lineLimit(1)
                            Text(candidate.artist).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                            Text([candidate.source, candidate.duration.map { Duration.seconds($0).formatted(.time(pattern: .minuteSecond)) }]
                                .compactMap { $0 }.joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .foregroundStyle(.primary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .navigationTitle(failure.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
    }
}
