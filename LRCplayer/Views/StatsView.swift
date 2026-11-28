import Charts
import SwiftUI

/// Stats, in Settings: the library's makeup, and what's been listened to
/// (when recording is on). Same glass cards on black as Settings.
struct StatsView: View {
    private enum Tab: CaseIterable {
        case library, listening

        var title: String {
            switch self {
            case .library: String(localized: "Library")
            case .listening: String(localized: "Listening")
            }
        }

        var symbol: String {
            switch self {
            case .library: "music.note.house.fill"
            case .listening: "headphones"
            }
        }
    }

    @State private var tab = Tab.library
    @State private var pageHeights: [Tab: CGFloat] = [:]
    @State private var hidden = StatsHidden.all

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                GlassSegmentedPicker("Stats", options: Tab.allCases, selection: Binding(get: { tab }, set: show), title: \.title, symbol: \.symbol)

                pages
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .background(Color(uiColor: .settingsBackground).ignoresSafeArea())
        .onReceive(NotificationCenter.default.publisher(for: StatsHidden.didChange)) { _ in
            withAnimation(.smooth) { hidden = StatsHidden.all }
        }
        .pageTrailingItem(isShown: !hidden.isEmpty) {
            Menu {
                Section("Hidden from Stats") {
                    ForEach(hidden, id: \.item) { entry in
                        Button(entry.label, systemImage: Self.symbol(for: entry.item)) {
                            StatsHidden.show(entry.item)
                        }
                    }
                }
                Button("Show All", systemImage: "eye") { StatsHidden.showAll() }
            } label: {
                BarIcon("Hidden from Stats", systemImage: "ellipsis")
                    .foregroundStyle(Color.statsTint)
            }
            // The bar lives in UIKit: the section's tint has to be set here.
            .tint(Color.statsTint)
        }
    }

    /// Both pages stay built: switching only slides and fades them, so it
    /// starts with the tap (building a page on the switch made it late and
    /// dropped frames). The stack takes the shown page's height, so the
    /// scroll ends where that page does.
    private var pages: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Tab.allCases, id: \.self) { page in
                Group {
                    switch page {
                    case .library: LibraryStatsSection()
                    case .listening: ListeningStatsSection()
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { pageHeights[page] = $0 }
                .offset(x: CGFloat(position(of: page) - position(of: tab)) * Self.slide)
                .opacity(page == tab ? 1 : 0)
                .allowsHitTesting(page == tab)
                .accessibilityHidden(page != tab)
            }
        }
        .frame(height: pageHeights[tab], alignment: .top)
    }

    /// How far a page slides as it fades: enough to read the direction,
    /// little enough that the cards' glass barely has to move.
    private static let slide: CGFloat = 56

    private static func symbol(for item: StatsHidden.Item) -> String {
        switch item {
        case .song: "music.note"
        case .album: "square.stack"
        case .artist: "music.microphone"
        case .line: "quote.bubble"
        }
    }

    private func position(of page: Tab) -> Int { Tab.allCases.firstIndex(of: page) ?? 0 }

    private func show(_ newTab: Tab) {
        withAnimation(StatsMotion.page) { tab = newTab }
    }
}

enum StatsMotion {
    /// Pages sliding in, and a period's numbers changing.
    static let page = Animation.spring(response: 0.42, dampingFraction: 0.9)
}

// MARK: - Library

private struct LibraryStatsSection: View {
    @EnvironmentObject private var libraryVM: LibraryViewModel
    @State private var showsAllArtists = false
    @State private var showsYears = true
    @State private var showsAllGenres = false

    var body: some View {
        // One pass over the songs: cheap enough to follow library changes.
        let stats = LibraryStatsSnapshot(songs: libraryVM.songs)
        VStack(spacing: 16) {
            StatsCard("Overview", systemImage: "square.grid.2x2.fill") {
                Grid(horizontalSpacing: 12, verticalSpacing: 18) {
                    GridRow {
                        StatFigure(value: stats.songCount.formatted(), label: stats.songCount == 1 ? "Song" : "Songs")
                        StatFigure(value: stats.albumCount.formatted(), label: stats.albumCount == 1 ? "Album" : "Albums")
                    }
                    GridRow {
                        StatFigure(value: stats.artistCount.formatted(), label: stats.artistCount == 1 ? "Artist" : "Artists")
                        StatFigure(value: StatsFormat.duration(stats.totalDuration), label: "Total Time")
                    }
                }
            }

            if !stats.topArtists.isEmpty {
                StatsCard("Top Artists", systemImage: "music.microphone", isExpanded: expansion($showsAllArtists, count: stats.topArtists.count)) {
                    RankedList(items: stats.topArtists, isExpanded: showsAllArtists) { rank, artist in
                        RankedRow(rank: rank, title: artist.name, detail: StatsFormat.songs(artist.songs.count)) {
                            ArtistAvatarView(artistName: artist.name, songs: artist.songs, size: 44)
                        }
                    }
                }
            }

            if !stats.genres.isEmpty {
                StatsCard("Genres", systemImage: "guitars.fill", isExpanded: expansion($showsAllGenres, count: stats.genres.count)) {
                    RankedList(items: stats.genres, isExpanded: showsAllGenres) { _, genre in
                        ShareRow(title: genre.name, count: genre.count, total: stats.songCount)
                    }
                }
            }

            StatsCard("Lyrics", systemImage: "quote.bubble.fill") {
                LyricsCoverage(withLyrics: stats.lyricsCount, total: stats.songCount)
            }

            if !stats.releaseYears.isEmpty {
                StatsCard("Release Years", systemImage: "calendar", accessory: showsYears ? String(localized: "By Year") : String(localized: "By Decade")) {
                    Group {
                        if showsYears {
                            YearChart(
                                years: stats.releaseYears,
                                caption: StatsFormat.peak(of: stats.releaseYears.map { (String($0.year), $0.count) }).map { String(localized: "Most of your library is from \($0).") },
                                value: StatsFormat.songs
                            )
                        } else {
                            DistributionChart(
                                bars: stats.releaseDecades.map { ($0.name, $0.count) },
                                axisLabels: nil,
                                caption: StatsFormat.peak(of: stats.releaseDecades.map { ($0.name, $0.count) })
                                    .flatMap { name in stats.releaseDecades.first { $0.name == name }?.decade }
                                    .map { String(localized: "Most of your library is from the \($0)s.") },
                                value: StatsFormat.songs
                            )
                        }
                    }
                    .transition(.opacity)
                }
                .contentShape(.rect(cornerRadius: 28))
                .onTapGesture {
                    guard SettingsSwipe.allowsTaps else { return }
                    withAnimation(.easeInOut(duration: 0.25)) { showsYears.toggle() }
                }
                .accessibilityHint(showsYears ? "Shows decades" : "Shows each year")
                .accessibilityAddTraits(.isButton)
            }

            SoundStatsSection(songs: libraryVM.songs)
        }
    }
}

/// A name, its share of the library as a bar, and its count.
private struct ShareRow: View {
    let title: String
    let count: Int
    let total: Int
    var value: (Int) -> String = StatsFormat.songs

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).lineLimit(1)
                Spacer()
                Text(value(count))
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            ShareBar(fraction: total == 0 ? 0 : Double(count) / Double(total))
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Sound

/// What the library sounds like, once it has been listened to.
private struct SoundStatsSection: View {
    let songs: [Song]
    @ObservedObject private var analysis = LibrarySoundAnalysis.shared
    @State private var showsAllEnergetic = false
    @State private var showsAllCalm = false
    @State private var confirmsDelete = false

    var body: some View {
        let measured = songs.compactMap { song in analysis.profiles[song.id].map { (song, $0) } }
        let pending = analysis.pending(in: songs).count
        VStack(spacing: 16) {
            // Above what it adds, so its progress stays in sight.
            if analysis.isRunning || pending > 0 {
                analyzeCard(pending: pending, hasResults: measured.count >= 5)
            }
            if measured.count >= 5 {
                cards(measured)
            }
            if !analysis.isRunning, !analysis.profiles.isEmpty {
                Button(role: .destructive) {
                    confirmsDelete = true
                } label: {
                    Label("Delete Analysis", systemImage: "trash")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.glass)
                .confirmationDialog("Delete the analysis?", isPresented: $confirmsDelete, titleVisibility: .visible) {
                    Button("Delete Analysis", role: .destructive) {
                        withAnimation(.smooth) { analysis.reset() }
                    }
                } message: {
                    Text("Mood, Tempo and the other cards it added go away until you analyze your library again. AutoMix and Music Haptics keep their data.")
                }
            }
        }
        .animation(.smooth, value: analysis.isRunning)
    }

    @ViewBuilder
    private func cards(_ measured: [(Song, SoundProfile)]) -> some View {
        let total = measured.count
        let calm = measured.filter { $0.1.energy < 0.4 }.count
        let energetic = measured.filter { $0.1.energy >= 0.65 }.count
        let beats = measured.map(\.1.bpm).filter { $0 > 0 }.sorted()
        // By energy (tempo, loudness, brightness); ties broken the same way
        // every time.
        let byEnergy = measured.sorted { ($0.1.energy, $0.1.loudness, $1.0.title) > ($1.1.energy, $1.1.loudness, $0.0.title) }

        StatsCard("Mood", systemImage: "bolt.heart.fill") {
            VStack(alignment: .leading, spacing: 14) {
                Text(moodSummary(calm: calm, energetic: energetic, total: total))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                ShareRow(title: String(localized: "Energetic"), count: energetic, total: total)
                ShareRow(title: String(localized: "Balanced"), count: total - calm - energetic, total: total)
                ShareRow(title: String(localized: "Calm"), count: calm, total: total)
            }
        }

        if !beats.isEmpty {
            StatsCard("Tempo", systemImage: "metronome.fill") {
                VStack(alignment: .leading, spacing: 18) {
                    Grid(horizontalSpacing: 12, verticalSpacing: 18) {
                        GridRow {
                            StatFigure(value: "\(Int(beats[beats.count / 2].rounded()))", label: "Typical BPM")
                            StatFigure(value: "\(Int(beats.first!.rounded()))–\(Int(beats.last!.rounded()))", label: "Range")
                        }
                    }
                    DistributionChart(
                        bars: Self.tempoBands.map { band in (band.name, beats.filter { band.range.contains($0) }.count) },
                        axisLabels: nil,
                        caption: nil,
                        value: StatsFormat.songs
                    )
                }
            }
        }

        StatsCard("Most Energetic", systemImage: "flame.fill", isExpanded: expansion($showsAllEnergetic, count: byEnergy.count)) {
            RankedList(items: Array(byEnergy.prefix(StatsList.expandedCount)), isExpanded: showsAllEnergetic) { rank, item in
                songRow(rank: rank, item)
            }
        }

        StatsCard("Calmest", systemImage: "leaf.fill", isExpanded: expansion($showsAllCalm, count: byEnergy.count)) {
            RankedList(items: Array(byEnergy.reversed().prefix(StatsList.expandedCount)), isExpanded: showsAllCalm) { rank, item in
                songRow(rank: rank, item)
            }
        }

        StatsCard("Sound", systemImage: "waveform") {
            VStack(alignment: .leading, spacing: 4) {
                soundGroup("Loudest", items: measured.sorted { $0.1.loudness > $1.1.loudness }) {
                    // dBFS is negative (0 is the loudest a file can be):
                    // shown as a 0–100 level instead.
                    "\(Int((min(1, max(0, ($0.loudness + 30) / 30)) * 100).rounded()))/100"
                }
                Divider().padding(.vertical, 10)
                soundGroup("Most Dynamic", caption: "Biggest gap between quiet and loud parts.", items: measured.sorted { $0.1.dynamics > $1.1.dynamics }) {
                    String(localized: "\(Int($0.dynamics.rounded())) dB gap")
                }
            }
        }
    }

    private func soundGroup(_ title: LocalizedStringKey, caption: LocalizedStringKey? = nil, items: [(Song, SoundProfile)], value: @escaping (SoundProfile) -> String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.tint)
            if let caption {
                Text(caption)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            RankedList(items: Array(items.prefix(3)), isExpanded: false) { rank, item in
                RankedRow(rank: rank, title: item.0.title, detail: item.0.artist, trailing: value(item.1)) {
                    TileArtwork(source: item.0.artworkSource, cornerRadius: 6, points: 44).frame(width: 44, height: 44)
                }
            }
        }
    }

    private func songRow(rank: Int, _ item: (Song, SoundProfile)) -> some View {
        // Ranked by energy, so that's what the row shows; the tempo is one
        // part of it.
        RankedRow(rank: rank, title: item.0.title, detail: item.1.bpm > 0 ? String(localized: "\(item.0.artist) · \(Int(item.1.bpm.rounded())) BPM") : item.0.artist, trailing: item.1.energy.formatted(.percent.precision(.fractionLength(0)))) {
            TileArtwork(source: item.0.artworkSource, cornerRadius: 6, points: 44).frame(width: 44, height: 44)
        }
    }

    private func moodSummary(calm: Int, energetic: Int, total: Int) -> String {
        let balanced = total - calm - energetic
        if energetic >= calm, energetic >= balanced { return String(localized: "Your library mostly gets things moving.") }
        if calm >= balanced { return String(localized: "Your library mostly keeps things calm.") }
        return String(localized: "Your library sits between calm and energetic.")
    }

    private static let tempoBands: [(name: String, range: ClosedRange<Double>)] = [
        (String(localized: "Slow"), 0...89.99), (String(localized: "Moderate"), 90...119.99), (String(localized: "Fast"), 120...149.99), (String(localized: "Very Fast"), 150...999)
    ]

    private func analyzeCard(pending: Int, hasResults: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if analysis.isRunning {
                HStack {
                    Text("Analyzing Your Library…").font(.headline)
                    Spacer()
                    Text(analysis.progress.formatted(.percent.precision(.fractionLength(0))))
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
                ProgressView(value: analysis.progress)
                    .tint(Color.statsTint)
                Button("Cancel", role: .cancel) { analysis.cancel() }
                    .buttonStyle(.glass)
                    .frame(maxWidth: .infinity)
            } else {
                Text(hasResults ? "\(pending) songs not analyzed yet." : "Find out how energetic or calm your music is, its tempo and more, by listening to each song on this \(UIDevice.current.model).")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button {
                    analysis.start(songs: songs)
                } label: {
                    Label(hasResults ? "Analyze New Songs" : "Analyze Library for More Details", systemImage: "waveform.badge.magnifyingglass")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.glassProminent)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
    }
}

/// How many songs have lyrics, as a share of the library.
private struct LyricsCoverage: View {
    @EnvironmentObject private var libraryVM: LibraryViewModel
    @ObservedObject private var index = LyricsSyncIndex.shared
    let withLyrics: Int
    let total: Int

    private var fraction: Double { total == 0 ? 0 : Double(withLyrics) / Double(total) }

    private var breakdown: [LyricsSyncKind: Int]? {
        index.kinds.map { kinds in
            kinds.values.reduce(into: [.wordSynced: 0, .synced: 0, .plain: 0]) { $0[$1, default: 0] += 1 }
        }
    }

    var body: some View {
        let breakdown = breakdown
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(fraction.formatted(.percent.precision(.fractionLength(0))))
                    .font(.title.bold())
                    .monospacedDigit()
                Spacer()
                Text("\(withLyrics) of \(total) songs")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            LyricsKindBar(counts: breakdown, total: total)
            HStack(alignment: .top, spacing: 8) {
                ForEach(LyricsSyncKind.allCases, id: \.self) { kind in
                    let count = breakdown?[kind]
                    RouteLink(.lyricsSongs(kind)) {
                        LyricsKindLegend(kind: kind, count: count, withLyrics: withLyrics)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled((count ?? 0) == 0)
                }
            }
            .padding(.top, 2)
            if withLyrics < total {
                RouteLink(.lyricsSongs(nil)) {
                    NoLyricsRow(count: total - withLyrics, total: total)
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
                AutoMatchLyricsButton(songs: libraryVM.songs)
                    .padding(.top, 4)
            }
        }
        .task(id: LyricsSyncIndex.signature(of: libraryVM.songs)) {
            index.refresh(libraryVM.songs)
        }
    }
}

/// Each song's kind of lyrics, shared by the Stats card and the lists it
/// opens; worked out off the main thread whenever lyrics files change.
@MainActor final class LyricsSyncIndex: ObservableObject {
    static let shared = LyricsSyncIndex()

    /// Songs with a lyrics file only; nil until the first pass ends.
    @Published private(set) var kinds: [UUID: LyricsSyncKind]?
    private var songs: [Song] = []
    private var signature: Int?
    private var wordSyncRevision = 0
    private var task: Task<Void, Never>?

    private init() {
        NotificationCenter.default.addObserver(forName: WordSyncStore.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.wordSyncRevision += 1
                self.refresh(self.songs)
            }
        }
    }

    nonisolated static func hasLyrics(_ song: Song) -> Bool {
        song.lrcFilePath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    /// Changes whenever a song gains, loses or swaps its lyrics file.
    static func signature(of songs: [Song]) -> Int {
        var hasher = Hasher()
        for song in songs {
            hasher.combine(song.id)
            hasher.combine(song.lrcFilePath)
        }
        return hasher.finalize()
    }

    func refresh(_ songs: [Song]) {
        var hasher = Hasher()
        hasher.combine(Self.signature(of: songs))
        hasher.combine(wordSyncRevision)
        let signature = hasher.finalize()
        guard signature != self.signature else { return }
        self.signature = signature
        self.songs = songs
        let files = songs.compactMap { song -> (id: UUID, path: String)? in
            guard let path = song.lrcFilePath?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else { return nil }
            return (song.id, path)
        }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        task?.cancel()
        task = Task {
            let kinds = await Task.detached(priority: .utility) {
                LyricsSyncKind.kinds(for: files, documents: documents)
            }.value
            guard !Task.isCancelled else { return }
            withAnimation(.smooth(duration: 0.5)) { self.kinds = kinds }
        }
    }
}

/// The songs without lyrics, under the kinds: what Auto-Match would fill.
private struct NoLyricsRow: View {
    let count: Int
    let total: Int

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(.quaternary).frame(width: 8, height: 8)
            Text("No Lyrics")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Group {
                Text(StatsFormat.songs(count))
                    .foregroundStyle(.secondary)
                Text(total == 0 ? 0 : Double(count) / Double(total), format: .percent.precision(.fractionLength(0)))
                    .font(.subheadline.weight(.semibold))
            }
            .font(.caption)
            .monospacedDigit()
            .contentTransition(.numericText())
            LegendChevron()
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// The small chevron after a legend's number: the songs behind it open.
private struct LegendChevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }
}

/// How a song's lyrics follow the music.
enum LyricsSyncKind: CaseIterable, Sendable {
    case wordSynced, synced, plain

    var title: LocalizedStringKey {
        switch self {
        case .wordSynced: "Word by Word"
        case .synced: "Synced Lines"
        case .plain: "Not Synced"
        }
    }

    /// Deepest for the richest lyrics.
    var shade: Color {
        switch self {
        case .wordSynced: Color.statsTint
        case .synced: Color.statsTint.opacity(0.6)
        case .plain: Color.statsTint.opacity(0.3)
        }
    }

    /// The waves behind the page listing these songs.
    var palette: CoverPalette {
        switch self {
        case .wordSynced: .lagoon
        case .synced: .ocean
        case .plain: .midnight
        }
    }

    /// The title of the page listing these songs.
    var listTitle: String {
        switch self {
        case .wordSynced: String(localized: "Word-by-Word Lyrics")
        case .synced: String(localized: "Synced Lyrics")
        case .plain: String(localized: "Unsynced Lyrics")
        }
    }

    /// Reads every lyrics file once; runs off the main thread.
    nonisolated static func kinds(for songs: [(id: UUID, path: String)], documents: URL) -> [UUID: LyricsSyncKind] {
        var kinds: [UUID: LyricsSyncKind] = [:]
        kinds.reserveCapacity(songs.count)
        for song in songs {
            kinds[song.id] = kind(of: song.id, path: song.path, documents: documents)
        }
        return kinds
    }

    nonisolated private static let wordTagRegex = try! NSRegularExpression(pattern: #"<\d{1,3}:\d{1,2}(?:[.:]\d{1,3})?>"#)

    nonisolated private static func kind(of id: UUID, path: String, documents: URL) -> LyricsSyncKind {
        guard let url = LibraryService.resolveLyricsURL(stored: path, documents: documents),
              let data = try? Data(contentsOf: url),
              let content = LRCParser.decode(data) else { return .plain }
        let lyrics = LRCParser.parse(content: content)
        guard lyrics.hasTimedLyrics else { return .plain }
        // Enhanced LRC carries its own word timings; others may have generated ones.
        if wordTagRegex.firstMatch(in: content, range: NSRange(content.startIndex..., in: content)) != nil
            || !WordSyncStore.load(for: id, lyrics: lyrics).isEmpty {
            return .wordSynced
        }
        return .synced
    }
}

/// The share of songs with lyrics, split by how well they're synced.
private struct LyricsKindBar: View {
    let counts: [LyricsSyncKind: Int]?
    let total: Int

    var body: some View {
        GeometryReader { geometry in
            let segments = LyricsSyncKind.allCases.compactMap { kind -> (LyricsSyncKind, Int)? in
                guard let count = counts?[kind], count > 0 else { return nil }
                return (kind, count)
            }
            let gap: CGFloat = segments.count > 1 ? 2 : 0
            let usable = max(0, geometry.size.width - gap * CGFloat(max(0, segments.count - 1)))
            HStack(spacing: gap) {
                ForEach(segments, id: \.0) { kind, count in
                    Capsule()
                        .fill(kind.shade)
                        .frame(width: max(6, usable * Double(count) / Double(max(total, 1))))
                }
            }
        }
        .frame(height: 6)
        .background(Capsule().fill(.quaternary))
        .clipShape(Capsule())
    }
}

private struct LyricsKindLegend: View {
    let kind: LyricsSyncKind
    let count: Int?
    let withLyrics: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Circle().fill(kind.shade).frame(width: 8, height: 8)
                Text(kind.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Group {
                if let count {
                    HStack(spacing: 4) {
                        Text(withLyrics == 0 ? 0 : Double(count) / Double(withLyrics), format: .percent.precision(.fractionLength(0)))
                        if count > 0 { LegendChevron() }
                    }
                } else {
                    Text(verbatim: "–").redacted(reason: .placeholder)
                }
            }
            .font(.subheadline.weight(.semibold))
            .monospacedDigit()
            .contentTransition(.numericText())
        }
        .accessibilityElement(children: .combine)
    }
}

/// The library's numbers, computed once when the page opens.
private struct LibraryStatsSnapshot {
    struct ArtistShare {
        let name: String
        let songs: [Song]
    }

    let songCount: Int
    let albumCount: Int
    let artistCount: Int
    let totalDuration: TimeInterval
    let topArtists: [ArtistShare]
    let releaseDecades: [(decade: Int, name: String, count: Int)]
    /// Only the years with songs.
    let releaseYears: [(year: Int, count: Int)]
    let lyricsCount: Int
    /// Empty when most songs have no genre: the ranking would mislead.
    let genres: [(name: String, count: Int)]

    init(songs: [Song]) {
        songCount = songs.count
        totalDuration = songs.reduce(0) { $0 + max(0, $1.duration) }
        albumCount = Set(songs.map { "\($0.albumArtist ?? $0.artist)|\($0.album)" }).count

        let artistGroups = Dictionary(grouping: songs, by: LibraryIndex.artistName(for:))
        artistCount = artistGroups.count
        let sortedArtists = artistGroups.sorted { lhs, rhs in
            if lhs.value.count == rhs.value.count {
                return lhs.key.localizedCaseInsensitiveCompare(rhs.key) == .orderedAscending
            }
            return lhs.value.count > rhs.value.count
        }
        topArtists = sortedArtists.prefix(StatsList.expandedCount).map { ArtistShare(name: $0.key, songs: $0.value) }

        let dated = songs.filter { $0.year > 0 }
        let decadeGroups = Dictionary(grouping: dated) { ($0.year / 10) * 10 }
        releaseDecades = decadeGroups.keys.sorted().map { decade in
            (decade: decade, name: String(localized: "\(decade)s"), count: decadeGroups[decade]?.count ?? 0)
        }
        let yearGroups = Dictionary(grouping: dated, by: \.year)
        releaseYears = yearGroups.keys.sorted().map { year in
            (year: year, count: yearGroups[year]?.count ?? 0)
        }

        let tagged = songs.compactMap { song -> String? in
            let genre = song.genre.trimmingCharacters(in: .whitespacesAndNewlines)
            return genre.isEmpty ? nil : genre
        }
        if tagged.count * 2 > songs.count {
            // "Hip-Hop" and "hip-hop" are one genre.
            var names: [String: String] = [:]
            var counts: [String: Int] = [:]
            for genre in tagged {
                let key = genre.lowercased()
                names[key] = names[key] ?? genre
                counts[key, default: 0] += 1
            }
            genres = counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }
                .prefix(StatsList.expandedCount)
                .map { (name: names[$0.key] ?? $0.key, count: $0.value) }
        } else {
            genres = []
        }

        lyricsCount = songs.filter {
            $0.lrcFilePath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }.count
    }
}

// MARK: - Listening

private struct ListeningStatsSection: View {
    @EnvironmentObject private var libraryVM: LibraryViewModel
    @State private var isEnabled = ListeningStatsService.shared.isEnabled
    @State private var range = ListeningStatsTimeRange.week
    /// With imported plays shown separately: which ones.
    @State private var source = ListeningStatsService.Source.vibePod
    @State private var showsSources = ListeningStatsSection.sourcesShown
    @State private var stats = ListeningStatsAggregated.empty
    @State private var entryCount = 0
    @State private var confirmsEnable = false
    @State private var confirmsErase = false
    @State private var showsAllSongs = false
    @State private var showsAllLines = false
    @State private var showsAllAlbums = false
    @State private var showsAllArtists = false
    @State private var showsAllGenres = false
    @State private var showsAllWorkoutSongs = false
    /// nil: every kind of workout.
    @State private var workoutActivity: String?
    @State private var showsYears = true
    @State private var extras = ListeningExtras.empty

    private var service: ListeningStatsService { .shared }

    var body: some View {
        VStack(spacing: 16) {
            if isEnabled {
                if showsSources {
                    GlassSegmentedPicker("Source", options: [ListeningStatsService.Source.vibePod, .imported], selection: Binding(get: { source }, set: showSource), title: { $0 == .vibePod ? "VibePod" : String(localized: "Imported") })
                }
                GlassSegmentedPicker("Period", options: ranges(for: shownSource), selection: Binding(get: { range }, set: show), title: \.label)

                if stats.totalSongsPlayed == 0 {
                    StatsCard("Nothing Yet", systemImage: "headphones") {
                        Text(shownSource == .imported ? String(localized: "No imported plays in this period.") : range.nothingRecordedNote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    content
                }

                if shownSource != .imported {
                    StatsCard("Recording", systemImage: "record.circle") {
                        VStack(alignment: .leading, spacing: 14) {
                            Toggle("Record Listening", isOn: Binding(
                                get: { isEnabled },
                                set: { setEnabled($0) }
                            ))
                            Divider()
                            Button("Erase All Listening Data", role: .destructive) {
                                guard SettingsSwipe.allowsTaps else { return }
                                confirmsErase = true
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.red)
                            .disabled(entryCount == 0)
                            Text(entryCount == 0 ? "Nothing recorded yet." : "\(entryCount) plays recorded, on this iPhone only.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                StatsCard("Listening Stats", systemImage: "headphones") {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("See what you play most, and when. What you play is recorded on this iPhone only, and you can pause or erase it anytime.")
                            .foregroundStyle(.secondary)
                        Button {
                            guard SettingsSwipe.allowsTaps else { return }
                            confirmsEnable = true
                        } label: {
                            Text("Turn On")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .frame(height: 30)
                        }
                        .buttonStyle(.glassProminent)
                    }
                }
            }
        }
        .onAppear(perform: refresh)
        .task { await WorkoutListening.sync() }
        .onReceive(NotificationCenter.default.publisher(for: StatsHidden.didChange)) { _ in
            withAnimation(.smooth) { refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: WorkoutListening.didChange)) { _ in
            withAnimation(.smooth) { refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: ListeningStatsService.historyDidChange)) { _ in
            withAnimation(.smooth) {
                showsSources = Self.sourcesShown
                refresh()
            }
        }
        .alert("Turn On Listening Stats?", isPresented: $confirmsEnable) {
            Button("Cancel", role: .cancel) {}
            Button("Turn On") { setEnabled(true) }
        } message: {
            Text("Which songs you play, when, and for how long will be recorded. This stays on your iPhone and is never shared.")
        }
        .alert("Erase All Listening Data?", isPresented: $confirmsErase) {
            Button("Cancel", role: .cancel) {}
            Button("Erase", role: .destructive) {
                service.eraseAllData()
                ReplayedLines.reset()
                withAnimation(.smooth) { refresh() }
            }
        } message: {
            Text("Every recorded play is deleted. This can't be undone.")
        }
    }

    @ViewBuilder
    private var content: some View {
        StatsCard("Overview", systemImage: "square.grid.2x2.fill") {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Listening Time")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(StatsFormat.duration(stats.totalListeningTime))
                            .font(.largeTitle.bold())
                            .monospacedDigit()
                        // The period reaches back before the first play recorded.
                        if let first = service.firstRecordDate(source: shownSource),
                           first > Date().addingTimeInterval(-range.interval) {
                            Text("since \(first.formatted(.dateTime.day().month(.wide).year()))")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                    }
                }
                Grid(horizontalSpacing: 12) {
                    GridRow {
                        StatFigure(value: stats.totalSongsPlayed.formatted(), label: stats.totalSongsPlayed == 1 ? "Play" : "Plays")
                        StatFigure(value: stats.uniqueSongs.formatted(), label: stats.uniqueSongs == 1 ? "Song" : "Songs")
                        StatFigure(value: stats.uniqueArtists.formatted(), label: stats.uniqueArtists == 1 ? "Artist" : "Artists")
                    }
                }
            }
        }

        if extras.timeline.count > 1 {
            StatsCard("Over Time", systemImage: "chart.xyaxis.line") {
                ListeningTimelineChart(points: extras.timeline, unit: extras.timelineUnit)
            }
        }

        if !stats.topSongs.isEmpty {
            StatsCard("Top Songs", systemImage: "music.note", isExpanded: expansion($showsAllSongs, count: stats.topSongs.count)) {
                RankedList(items: stats.topSongs, isExpanded: showsAllSongs) { rank, song in
                    RankedRow(rank: rank, title: song.title, detail: song.artist, trailing: StatsFormat.plays(song.count)) {
                        ArtworkImage(source: libraryVM.songs.first { $0.id == song.songID }?.artworkSource, cornerRadius: 6, points: 44)
                            .frame(width: 44, height: 44)
                    }
                    .hidesFromStats(.song(song.songID), label: song.title)
                }
            }
        }

        if !stats.topAlbums.isEmpty {
            StatsCard("Top Albums", systemImage: "square.stack.fill", isExpanded: expansion($showsAllAlbums, count: stats.topAlbums.count)) {
                RankedList(items: stats.topAlbums, isExpanded: showsAllAlbums) { rank, album in
                    RankedRow(rank: rank, title: album.name, detail: album.artist, trailing: StatsFormat.plays(album.count)) {
                        ArtworkImage(source: albumArtwork(name: album.name, artist: album.artist), cornerRadius: 6, points: 44)
                            .frame(width: 44, height: 44)
                    }
                    .hidesFromStats(.album(album.name, artist: album.artist), label: album.name)
                }
            }
        }

        if !stats.topArtists.isEmpty {
            StatsCard("Top Artists", systemImage: "music.microphone", isExpanded: expansion($showsAllArtists, count: stats.topArtists.count)) {
                RankedList(items: stats.topArtists, isExpanded: showsAllArtists) { rank, artist in
                    RankedRow(rank: rank, title: artist.name, detail: StatsFormat.duration(artist.totalTime), trailing: StatsFormat.plays(artist.count)) {
                        ArtistAvatarView(artistName: artist.name, songs: libraryVM.artist(named: artist.name)?.songs ?? libraryVM.songs.filter { $0.artist == artist.name }, size: 44)
                    }
                    .hidesFromStats(.artist(artist.name), label: artist.name)
                }
            }
        }

        let replayed = ReplayedLines.top(40)
            .filter { entry in !StatsHidden.contains(.line(key: entry.id)) && libraryVM.songs.contains { $0.id == entry.songID } }
        if !replayed.isEmpty {
            StatsCard("Most Replayed Lines", systemImage: "gobackward", isExpanded: expansion($showsAllLines, count: replayed.count)) {
                RankedList(items: replayed, isExpanded: showsAllLines) { rank, entry in
                    let song = libraryVM.songs.first { $0.id == entry.songID }
                    RankedRow(rank: rank, title: String(localized: "“\(entry.text)”"), detail: song?.title ?? "", titleLines: nil, trailing: StatsFormat.replays(entry.count)) {
                        ArtworkImage(source: song?.artworkSource, cornerRadius: 6, points: 44)
                            .frame(width: 44, height: 44)
                    }
                    .hidesFromStats(.line(key: entry.id), label: String(localized: "“\(entry.text)”"))
                }
            }
        }

        if !extras.years.isEmpty {
            StatsCard("Release Years", systemImage: "calendar", accessory: showsYears ? String(localized: "By Year") : String(localized: "By Decade")) {
                Group {
                    if showsYears {
                        YearChart(
                            years: extras.years,
                            caption: StatsFormat.peak(of: extras.years.map { (String($0.year), $0.count) }).map { String(localized: "You mostly play music from \($0).") },
                            value: StatsFormat.plays
                        )
                    } else {
                        DistributionChart(
                            bars: extras.decades.map { ($0.name, $0.count) },
                            axisLabels: nil,
                            caption: StatsFormat.peak(of: extras.decades.map { ($0.name, $0.count) })
                                .flatMap { name in extras.decades.first { $0.name == name }?.decade }
                                .map { String(localized: "You mostly play music from the \($0)s.") },
                            value: StatsFormat.plays
                        )
                    }
                }
                .transition(.opacity)
            }
            .contentShape(.rect(cornerRadius: 28))
            .onTapGesture {
                guard SettingsSwipe.allowsTaps else { return }
                withAnimation(.easeInOut(duration: 0.25)) { showsYears.toggle() }
            }
            .accessibilityHint(showsYears ? "Shows decades" : "Shows each year")
            .accessibilityAddTraits(.isButton)
        }

        if !extras.genres.isEmpty {
            StatsCard("Genres", systemImage: "guitars.fill", isExpanded: expansion($showsAllGenres, count: extras.genres.count)) {
                RankedList(items: extras.genres, isExpanded: showsAllGenres) { _, genre in
                    ShareRow(title: genre.name, count: genre.count, total: stats.totalSongsPlayed, value: StatsFormat.plays)
                }
            }
        }

        if extras.workoutPlays > 0 {
            let workoutSongs = workoutActivity.flatMap { extras.workoutSongsByActivity[$0] } ?? extras.workoutSongs
            StatsCard("During Workouts", systemImage: "figure.run", isExpanded: expansion($showsAllWorkoutSongs, count: workoutSongs.count)) {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(StatsFormat.duration(extras.workoutSeconds))
                            .font(.title.bold())
                            .monospacedDigit()
                        Text("listened over \(extras.workoutCount) workouts")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if extras.workoutActivities.count > 1 {
                        VStack(spacing: 12) {
                            ForEach(extras.workoutActivities.prefix(5), id: \.name) { activity in
                                ShareRow(title: activity.name, count: activity.count, total: extras.workoutPlays, value: StatsFormat.plays)
                            }
                        }
                        WorkoutActivityFilter(activities: extras.workoutActivities.map(\.name), selection: $workoutActivity)
                    }
                    RankedList(items: workoutSongs, isExpanded: showsAllWorkoutSongs) { rank, song in
                        RankedRow(rank: rank, title: song.title, detail: song.artist, trailing: StatsFormat.plays(song.count)) {
                            ArtworkImage(source: libraryVM.songs.first { $0.id == song.songID }?.artworkSource, cornerRadius: 6, points: 44)
                                .frame(width: 44, height: 44)
                        }
                        .hidesFromStats(.song(song.songID), label: song.title)
                    }
                    .id(workoutActivity)
                    .transition(.opacity)
                }
            }
            .onChange(of: extras.workoutActivities.map(\.name)) { _, names in
                if let workoutActivity, !names.contains(workoutActivity) { self.workoutActivity = nil }
            }
        }

        StatsCard("Time of Day", systemImage: "clock.fill") {
            let hours = (0..<24).map { (StatsFormat.hour($0), stats.hourlyDistribution[$0] ?? 0) }
            DistributionChart(
                bars: hours,
                axisLabels: [0, 6, 12, 18].map { StatsFormat.hour($0) },
                caption: StatsFormat.peak(of: hours)
                    .flatMap { label in hours.firstIndex { $0.0 == label } }
                    .map { String(localized: "You listen most around \(StatsFormat.time(atHour: $0)).") },
                value: StatsFormat.plays
            )
        }

        StatsCard("Day of the Week", systemImage: "calendar") {
            // Keyed by Calendar weekday (1 = Sunday); shown from the locale's
            // first weekday.
            let calendar = Calendar.current
            let days = (0..<7).map { offset in
                let weekday = (calendar.firstWeekday - 1 + offset) % 7 + 1
                return (calendar.shortWeekdaySymbols[weekday - 1], stats.dailyDistribution[weekday] ?? 0)
            }
            DistributionChart(
                bars: days,
                axisLabels: nil,
                caption: StatsFormat.peak(of: days).flatMap { short in
                    calendar.shortWeekdaySymbols.firstIndex(of: short).map { String(localized: "Your busiest day is \(calendar.weekdaySymbols[$0]).") }
                },
                value: StatsFormat.plays
            )
        }
    }

    private func albumArtwork(name: String, artist: String) -> ArtworkSource? {
        libraryVM.songs.first { $0.album == name && $0.artist == artist }?.artworkSource
    }

    private func setEnabled(_ enabled: Bool) {
        service.setEnabled(enabled)
        withAnimation(.smooth) {
            isEnabled = enabled
            refresh()
        }
    }

    private func refresh() {
        stats = service.aggregate(for: range, source: shownSource)
        extras = ListeningExtras(entries: service.entries(in: range, source: shownSource), range: range, songs: libraryVM.songs)
        entryCount = service.totalEntriesCount()
    }

    /// The source picked, when imported plays are shown separately.
    private var shownSource: ListeningStatsService.Source? {
        showsSources ? source : nil
    }

    private static var sourcesShown: Bool {
        ImportedHistory.showsSeparately && !ImportedHistory.shared.packages.isEmpty
    }

    private func ranges(for source: ListeningStatsService.Source?) -> [ListeningStatsTimeRange] {
        ListeningStatsTimeRange.allCases.filter { $0 != .allTime || service.hasMoreThanAYear(source: source) }
    }

    /// Imported plays are often years old: rather than an empty week, the
    /// shortest period that holds some is shown.
    private func showSource(_ newSource: ListeningStatsService.Source) {
        let resolved: ListeningStatsService.Source? = showsSources ? newSource : nil
        let available = ranges(for: resolved)
        var newRange = available.contains(range) ? range : (available.last ?? .year)
        var newStats = service.aggregate(for: newRange, source: resolved)
        if newStats.totalSongsPlayed == 0 {
            for candidate in available where candidate.interval > newRange.interval {
                let candidateStats = service.aggregate(for: candidate, source: resolved)
                if candidateStats.totalSongsPlayed > 0 {
                    newRange = candidate
                    newStats = candidateStats
                    break
                }
            }
        }
        let newExtras = ListeningExtras(entries: service.entries(in: newRange, source: resolved), range: newRange, songs: libraryVM.songs)
        withAnimation(StatsMotion.page) {
            source = newSource
            range = newRange
            stats = newStats
            extras = newExtras
        }
    }

    /// The period's numbers change in place, with the tap: the bars grow or
    /// shrink to their new values rather than the page being rebuilt.
    private func show(_ newRange: ListeningStatsTimeRange) {
        let newStats = service.aggregate(for: newRange, source: shownSource)
        let newExtras = ListeningExtras(entries: service.entries(in: newRange, source: shownSource), range: newRange, songs: libraryVM.songs)
        withAnimation(StatsMotion.page) {
            range = newRange
            stats = newStats
            extras = newExtras
        }
    }
}

private extension ListeningStatsTimeRange {
    var nothingRecordedNote: String {
        switch self {
        case .week: String(localized: "No listening recorded in the last 7 days. A song counts once it's played for 10 seconds.")
        case .month: String(localized: "No listening recorded in the last 30 days. A song counts once it's played for 10 seconds.")
        case .year: String(localized: "No listening recorded in the last year. A song counts once it's played for 10 seconds.")
        case .allTime: String(localized: "No listening recorded yet. A song counts once it's played for 10 seconds.")
        }
    }
}

// MARK: - Building blocks

/// The expansion binding for a ranked card: none when there's nothing past
/// the first rows.
private func expansion(_ binding: Binding<Bool>, count: Int) -> Binding<Bool>? {
    count > StatsList.collapsedCount ? binding : nil
}

private enum StatsList {
    static let collapsedCount = 5
    static let expandedCount = 10
}

/// A Settings-style glass card. With `isExpanded`, its header unfolds the
/// rest of a ranked list, like Settings' cards unfold.
private struct StatsCard<Content: View>: View {
    let title: LocalizedStringKey
    let systemImage: String
    let isExpanded: Binding<Bool>?
    let accessory: String?
    @ViewBuilder var content: Content

    init(_ title: LocalizedStringKey, systemImage: String, isExpanded: Binding<Bool>? = nil, accessory: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.isExpanded = isExpanded
        self.accessory = accessory
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let isExpanded {
                Button {
                    guard SettingsSwipe.allowsTaps else { return }
                    withAnimation(.interactiveSpring(response: 0.35, dampingFraction: 0.85)) {
                        isExpanded.wrappedValue.toggle()
                    }
                } label: {
                    header(isExpanded: isExpanded.wrappedValue)
                }
                .buttonStyle(.plain)
                .accessibilityValue(isExpanded.wrappedValue ? "Showing top \(StatsList.expandedCount)" : "Showing top \(StatsList.collapsedCount)")
            } else {
                header(isExpanded: nil)
            }
            content
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
    }

    private func header(isExpanded: Bool?) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.headline)
                .foregroundStyle(.tint)
                .frame(width: 26)
            Text(title).font(.headline)
            Spacer()
            if let accessory {
                Text(accessory)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
                    .id(accessory)
            }
            if let isExpanded {
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// A figure and what it counts.
private struct StatFigure: View {
    let value: String
    let label: LocalizedStringKey

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.title2.bold())
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// The first rows of a ranking, separated like a list; all of them when
/// expanded, the extra rows unfolding below.
private struct RankedList<Item, Row: View>: View {
    let items: [Item]
    let isExpanded: Bool
    @ViewBuilder let row: (Int, Item) -> Row

    private var visible: ArraySlice<Item> {
        items.prefix(isExpanded ? StatsList.expandedCount : StatsList.collapsedCount)
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(visible.enumerated()), id: \.offset) { index, item in
                VStack(spacing: 0) {
                    if index > 0 {
                        Divider().padding(.leading, 90)
                    }
                    row(index + 1, item)
                        .padding(.vertical, 8)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

private struct RankedRow<Artwork: View>: View {
    let rank: Int
    let title: String
    let detail: String
    var titleLines: Int? = 1
    var trailing: String?
    @ViewBuilder let artwork: Artwork

    init(rank: Int, title: String, detail: String, titleLines: Int? = 1, trailing: String? = nil, @ViewBuilder artwork: () -> Artwork) {
        self.rank = rank
        self.title = title
        self.detail = detail
        self.titleLines = titleLines
        self.trailing = trailing
        self.artwork = artwork()
    }

    var body: some View {
        HStack(spacing: 12) {
            Text("\(rank)")
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
                // Wide enough for "10", so ranks and artwork line up.
                .frame(width: 22)
            artwork
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(titleLines)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let trailing {
                Text(trailing)
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ShareBar: View {
    let fraction: Double

    var body: some View {
        Capsule()
            .fill(.quaternary)
            .frame(height: 6)
            .overlay(alignment: .leading) {
                GeometryReader { geometry in
                    Capsule()
                        .fill(.tint)
                        .frame(width: max(6, geometry.size.width * min(max(fraction, 0), 1)))
                }
            }
    }
}

/// Bars for a distribution, the highest in full tint.
private struct DistributionChart: View {
    let bars: [(String, Int)]
    /// The x labels to show (all of them when nil).
    let axisLabels: [String]?
    let caption: String?
    /// What a bar's count reads as in the touch-and-hold callout.
    var value: (Int) -> String = { $0.formatted() }
    @AppTintSelection private var appTint
    @State private var selected: String?

    var body: some View {
        let highest = bars.map(\.1).max() ?? 0
        let picked = bars.first { $0.0 == selected }
        VStack(alignment: .leading, spacing: 12) {
            if let caption {
                Text(caption)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Chart(Array(bars.enumerated()), id: \.offset) { _, bar in
                // Slimmer when there are few bars, so two don't fill the card.
                BarMark(x: .value("Period", bar.0), y: .value("Count", bar.1), width: .ratio(bars.count < 6 ? 0.4 : 0.7))
                    .foregroundStyle(Color.statsTint.opacity(StatsSelection.opacity(isPicked: picked.map { $0.0 == bar.0 }, isHighest: bar.1 == highest && highest > 0)))
                    .cornerRadius(4)
                if let picked, picked.0 == bar.0 {
                    RuleMark(x: .value("Period", bar.0))
                        .foregroundStyle(Color.secondary.opacity(0.35))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                        .zIndex(-1)
                        .annotation(position: .top, spacing: 4, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                            StatsCallout(title: picked.0, value: value(picked.1))
                        }
                }
            }
            .chartXSelection(value: $selected)
            .sensoryFeedback(.selection, trigger: selected) { _, new in new != nil }
            .holdsSettingsSwipe(while: selected != nil)
            .chartXAxis {
                AxisMarks { value in
                    let label = value.as(String.self) ?? ""
                    AxisValueLabel {
                        // Unlisted labels stay empty, keeping their bar's slot.
                        Text(axisLabels.map { $0.contains(label) } ?? true ? label : "")
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                    AxisGridLine()
                    AxisValueLabel()
                }
            }
            .frame(height: 150)
        }
    }
}

/// Songs per release year on a continuous axis, so gaps between years show.
private struct YearChart: View {
    let years: [(year: Int, count: Int)]
    let caption: String?
    var value: (Int) -> String = StatsFormat.songs
    @AppTintSelection private var appTint
    @State private var selection: Double?

    /// The year under the finger, when it has songs.
    private var picked: (year: Int, count: Int)? {
        guard let selection else { return nil }
        let year = Int(selection.rounded())
        return years.first { $0.year == year }
    }

    var body: some View {
        let highest = years.map(\.count).max() ?? 0
        let first = years.first?.year ?? 0
        let last = years.last?.year ?? 0
        VStack(alignment: .leading, spacing: 12) {
            if let caption {
                Text(caption)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Chart {
                ForEach(years, id: \.year) { item in
                    bar(year: item.year, count: item.count, isHighest: item.count == highest)
                }
                if let picked {
                    RuleMark(x: .value("Year", Double(picked.year)))
                        .foregroundStyle(Color.secondary.opacity(0.35))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                        .zIndex(-1)
                        .annotation(position: .top, spacing: 4, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                            StatsCallout(title: String(picked.year), value: value(picked.count))
                        }
                }
            }
            .chartXSelection(value: $selection)
            .sensoryFeedback(.selection, trigger: picked?.year) { _, new in new != nil }
            .holdsSettingsSwipe(while: selection != nil)
            .chartXScale(domain: Double(first - 1)...Double(last + 1))
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { value in
                    AxisValueLabel {
                        // Years without a thousands separator.
                        if let year = value.as(Double.self), year == year.rounded() { Text(String(Int(year))) }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                    AxisGridLine()
                    AxisValueLabel()
                }
            }
            .frame(height: 150)
        }
    }

    /// Spans in years: a relative width has no band to be relative to on a
    /// continuous axis.
    private func bar(year: Int, count: Int, isHighest: Bool) -> some ChartContent {
        let start: Double = Double(year) - 0.4
        let end: Double = Double(year) + 0.4
        let color: Color = Color.statsTint.opacity(StatsSelection.opacity(isPicked: picked.map { $0.year == year }, isHighest: isHighest))
        let mark = RectangleMark(
            xStart: PlottableValue.value("Year", start),
            xEnd: PlottableValue.value("Year", end),
            yStart: PlottableValue.value("Count", 0),
            yEnd: PlottableValue.value("Count", count)
        )
        return mark.foregroundStyle(color).cornerRadius(3)
    }
}

// MARK: - Selection

private enum StatsSelection {
    /// While a bar is held, it alone is in full tint.
    static func opacity(isPicked: Bool?, isHighest: Bool) -> Double {
        if let isPicked { return isPicked ? 1 : 0.25 }
        return isHighest ? 1 : 0.45
    }
}

/// The callout over a held bar, as in Health.
private struct StatsCallout: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: .rect(cornerRadius: 10))
        .fixedSize()
    }
}

extension View {
    /// While a chart follows the finger, neither the swipe back nor the
    /// panel's close takes the drag.
    func holdsSettingsSwipe(while tracking: Bool) -> some View {
        onChange(of: tracking) { _, tracking in SettingsSwipe.isControlTracking = tracking }
            .onDisappear { if tracking { SettingsSwipe.isControlTracking = false } }
    }

    /// Touch and hold: Hide from Stats.
    fileprivate func hidesFromStats(_ item: StatsHidden.Item, label: String) -> some View {
        contentShape(.rect)
            .contextMenu {
                Button("Hide from Stats", systemImage: "eye.slash") {
                    StatsHidden.hide(item, label: label)
                }
            }
    }
}

/// What the period's plays were: over time, by release year, by genre.
private struct ListeningExtras {
    struct Point: Identifiable {
        let date: Date
        let seconds: TimeInterval
        var id: Date { date }
    }

    var timeline: [Point] = []
    var timelineUnit: Calendar.Component = .day
    var years: [(year: Int, count: Int)] = []
    var decades: [(decade: Int, name: String, count: Int)] = []
    var genres: [(name: String, count: Int)] = []
    // During workouts (Apple Health).
    var workoutSeconds: TimeInterval = 0
    var workoutCount = 0
    var workoutSongs: [(songID: UUID, title: String, artist: String, count: Int)] = []
    var workoutActivities: [(name: String, count: Int)] = []
    var workoutSongsByActivity: [String: [(songID: UUID, title: String, artist: String, count: Int)]] = [:]
    var workoutPlays = 0

    static let empty = ListeningExtras()

    private init() {}

    init(entries: [ListeningStatsEntry], range: ListeningStatsTimeRange, songs: [Song]) {
        guard let first = entries.map(\.timestamp).min() else { return }
        let calendar = Calendar.current
        let unit: Calendar.Component = switch range {
        case .week, .month: .day
        case .year: .weekOfYear
        case .allTime: .month
        }
        timelineUnit = unit
        let now = Date()
        let rangeStart = range == .allTime ? first : now.addingTimeInterval(-range.interval)
        var sums: [Date: TimeInterval] = [:]
        for entry in entries {
            guard let bucket = calendar.dateInterval(of: unit, for: entry.timestamp)?.start else { continue }
            sums[bucket, default: 0] += entry.durationPlayed
        }
        var points: [Point] = []
        var cursor = calendar.dateInterval(of: unit, for: rangeStart)?.start ?? rangeStart
        while cursor <= now, points.count < 400 {
            points.append(Point(date: cursor, seconds: sums[cursor] ?? 0))
            guard let next = calendar.date(byAdding: unit, value: 1, to: cursor) else { break }
            cursor = next
        }
        timeline = points

        let byID = Dictionary(songs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var yearCounts: [Int: Int] = [:]
        var genreCounts: [String: Int] = [:]
        for entry in entries {
            guard let song = byID[entry.songID] else { continue }
            if song.year > 0 { yearCounts[song.year, default: 0] += 1 }
            let genre = song.genre.trimmingCharacters(in: .whitespacesAndNewlines)
            if !genre.isEmpty { genreCounts[genre, default: 0] += 1 }
        }
        years = yearCounts.keys.sorted().map { (year: $0, count: yearCounts[$0] ?? 0) }
        let decadeCounts = Dictionary(grouping: yearCounts) { ($0.key / 10) * 10 }.mapValues { $0.reduce(0) { $0 + $1.value } }
        decades = decadeCounts.keys.sorted().map { (decade: $0, name: String(localized: "\($0)s"), count: decadeCounts[$0] ?? 0) }
        genres = genreCounts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(StatsList.expandedCount)
            .map { (name: $0.key, count: $0.value) }

        guard WorkoutListening.isEnabled else { return }
        let plays = WorkoutListening.plays(in: entries, sessions: WorkoutListening.storedSessions())
        workoutPlays = plays.count
        workoutSeconds = plays.reduce(0) { $0 + $1.entry.durationPlayed }
        workoutCount = Set(plays.map(\.session.start)).count
        var activityCounts: [String: Int] = [:]
        for play in plays { activityCounts[play.session.activityName, default: 0] += 1 }
        func ranked(_ plays: some Sequence<(entry: ListeningStatsEntry, session: WorkoutSession)>) -> [(songID: UUID, title: String, artist: String, count: Int)] {
            var songCounts: [UUID: (entry: ListeningStatsEntry, count: Int)] = [:]
            for play in plays { songCounts[play.entry.songID, default: (play.entry, 0)].count += 1 }
            return songCounts.values
                .filter { !StatsHidden.contains(.song($0.entry.songID)) }
                .sorted { $0.count != $1.count ? $0.count > $1.count : $0.entry.title < $1.entry.title }
                .prefix(StatsList.expandedCount)
                .map { (songID: $0.entry.songID, title: byID[$0.entry.songID]?.title ?? $0.entry.title, artist: byID[$0.entry.songID]?.artist ?? $0.entry.artist, count: $0.count) }
        }
        workoutSongs = ranked(plays)
        if activityCounts.count > 1 {
            workoutSongsByActivity = Dictionary(grouping: plays) { $0.session.activityName }.mapValues { ranked($0) }
        }
        workoutActivities = activityCounts.sorted { $0.value > $1.value }.map { (name: $0.key, count: $0.value) }
    }
}

/// Which songs to show in During Workouts: all, or one kind of workout.
private struct WorkoutActivityFilter: View {
    let activities: [String]
    @Binding var selection: String?

    var body: some View {
        ScrollView(.horizontal) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    chip(String(localized: "All"), value: nil)
                    ForEach(activities, id: \.self) { chip($0, value: $0) }
                }
            }
            .padding(.vertical, 6)
        }
        // Scrolls edge to edge of the card and stops there, rather than
        // spilling past it and off the screen.
        .contentMargins(.horizontal, 20, for: .scrollContent)
        .padding(.horizontal, -20)
        .padding(.vertical, -4)
        .scrollIndicators(.hidden)
        .sensoryFeedback(.selection, trigger: selection)
    }

    @ViewBuilder
    private func chip(_ title: String, value: String?) -> some View {
        let button = Button {
            withAnimation(.smooth(duration: 0.3)) { selection = value }
        } label: {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 4)
        }
        if selection == value {
            button.buttonStyle(.glassProminent)
        } else {
            button.buttonStyle(.glass)
        }
    }
}

/// Listening time across the period, as a smooth wave; touch and hold to
/// read a day, week or month. Drawn as one shape over a fixed number of
/// samples, so a new period morphs the wave in a single spring instead of
/// marks being added and removed.
private struct ListeningTimelineChart: View {
    let points: [ListeningExtras.Point]
    let unit: Calendar.Component
    @State private var selected: Int?
    @State private var calloutWidth: CGFloat = 0

    private var hours: Bool { (points.map(\.seconds).max() ?? 0) >= 2 * 3600 }

    private func amount(_ seconds: TimeInterval) -> Double { seconds / (hours ? 3600 : 60) }

    /// The top of the scale: the highest value rounded up to 1, 2 or 5 × 10ⁿ.
    private var top: Double {
        let highest = points.map { amount($0.seconds) }.max() ?? 0
        guard highest > 0 else { return 1 }
        let magnitude = pow(10, floor(log10(highest)))
        return [1.0, 2, 5, 10].map { $0 * magnitude }.first { $0 >= highest } ?? highest
    }

    private var samples: WaveSamples {
        WaveSamples(resampling: points.map { amount($0.seconds) / top })
    }

    var body: some View {
        let top = top
        VStack(spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                GeometryReader { geometry in
                    plot(in: geometry.size)
                }
                yLabels(top: top)
            }
            xLabels
        }
        .padding(.top, 8)
        .frame(height: 158)
        .sensoryFeedback(.selection, trigger: selected) { _, new in new != nil }
        .holdsSettingsSwipe(while: selected != nil)
    }

    private func plot(in size: CGSize) -> some View {
        let samples = samples
        return ZStack(alignment: .topLeading) {
            Path { path in
                for fraction in [0.0, 0.5, 1] {
                    let y = size.height * fraction
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                }
            }
            .stroke(Color.secondary.opacity(0.18), style: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))

            WaveShape(samples: samples, closed: true)
                .fill(LinearGradient(colors: [Color.statsTint.opacity(0.55), Color.statsTint.opacity(0.2)], startPoint: .top, endPoint: .bottom))
            WaveShape(samples: samples, closed: false)
                .stroke(Color.statsTint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))

            if let selected, points.indices.contains(selected) {
                let point = points[selected]
                let x = points.count > 1 ? size.width * CGFloat(selected) / CGFloat(points.count - 1) : size.width / 2
                let y = size.height * (1 - CGFloat(min(1, max(0, amount(point.seconds) / top))))
                Rectangle()
                    .fill(Color.secondary.opacity(0.35))
                    .frame(width: 1, height: size.height + 8)
                    .position(x: x, y: size.height / 2 - 4)
                Circle()
                    .fill(Color.statsTint)
                    .frame(width: 9, height: 9)
                    .position(x: x, y: y)
                StatsCallout(title: title(for: point.date), value: StatsFormat.duration(point.seconds))
                    .onGeometryChange(for: CGFloat.self, of: \.size.width) { calloutWidth = $0 }
                    .position(x: min(max(x, calloutWidth / 2), size.width - calloutWidth / 2), y: -28)
            }
        }
        .contentShape(.rect)
        .gesture(
            LongPressGesture(minimumDuration: 0.12)
                .sequenced(before: DragGesture(minimumDistance: 0))
                .onChanged { value in
                    guard case let .second(true, drag?) = value, points.count > 1 else { return }
                    let fraction = min(1, max(0, drag.location.x / max(1, size.width)))
                    let index = Int((fraction * CGFloat(points.count - 1)).rounded())
                    if index != selected { selected = index }
                }
                .onEnded { _ in selected = nil }
        )
    }

    /// Three labels on the grid lines: the top, half of it and zero.
    private func yLabels(top: Double) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            ForEach(Array([top, top / 2, 0].enumerated()), id: \.offset) { index, value in
                if index > 0 { Spacer(minLength: 0) }
                Text(label(value))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .contentTransition(.numericText(value: value))
                    .frame(height: 0)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func label(_ value: Double) -> String {
        let shown = value == value.rounded() || value >= 10 ? String(Int(value.rounded())) : value.formatted(.number.precision(.fractionLength(1)))
        return hours ? String(localized: "\(shown) h") : String(localized: "\(shown) min")
    }

    /// Four dates under the wave, fading over when the period changes.
    private var xLabels: some View {
        let indices = points.count > 1 ? [0, 1, 2, 3].map { Int((Double($0) / 3 * Double(points.count - 1)).rounded()) } : []
        return HStack(spacing: 0) {
            ForEach(Array(indices.enumerated()), id: \.offset) { position, index in
                if position > 0 { Spacer(minLength: 4) }
                Text(points[index].date, format: unit == .month ? .dateTime.month(.abbreviated).year(.twoDigits) : .dateTime.day().month(.abbreviated))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .id("\(unit)-\(points.first?.date.timeIntervalSince1970 ?? 0)-\(points.count)")
        .transition(.opacity)
        .padding(.trailing, 36)
    }

    private func title(for date: Date) -> String {
        switch unit {
        case .weekOfYear: String(localized: "Week of \(date.formatted(.dateTime.day().month(.abbreviated)))")
        case .month: date.formatted(.dateTime.month(.wide).year())
        default: date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        }
    }
}

/// A wave's heights (0…1) at a fixed number of evenly spaced points: any
/// period's wave animates into any other's.
private struct WaveSamples: VectorArithmetic {
    static let count = 96
    var values: [Double]

    init(_ values: [Double]) { self.values = values }

    /// A smooth curve through `heights` (Catmull-Rom), read at `count` points.
    init(resampling heights: [Double]) {
        guard heights.count > 1 else {
            values = Array(repeating: heights.first ?? 0, count: Self.count)
            return
        }
        let last = heights.count - 1
        values = (0..<Self.count).map { sample in
            let position = Double(sample) / Double(Self.count - 1) * Double(last)
            let i = min(Int(position), last - 1)
            let t = position - Double(i)
            let p0 = heights[max(i - 1, 0)], p1 = heights[i], p2 = heights[i + 1], p3 = heights[min(i + 2, last)]
            let value = 0.5 * (2 * p1 + (p2 - p0) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t * t + (3 * p1 - p0 - 3 * p2 + p3) * t * t * t)
            return min(1, max(0, value))
        }
    }

    static var zero: WaveSamples { WaveSamples(Array(repeating: 0, count: count)) }
    static func + (lhs: WaveSamples, rhs: WaveSamples) -> WaveSamples { WaveSamples(zip(lhs.values, rhs.values).map(+)) }
    static func - (lhs: WaveSamples, rhs: WaveSamples) -> WaveSamples { WaveSamples(zip(lhs.values, rhs.values).map(-)) }
    mutating func scale(by rhs: Double) { values = values.map { $0 * rhs } }
    var magnitudeSquared: Double { values.reduce(0) { $0 + $1 * $1 } }
}

private struct WaveShape: Shape {
    var samples: WaveSamples
    /// Closed down to the baseline, for the fill under the line.
    var closed: Bool

    var animatableData: WaveSamples {
        get { samples }
        set { samples = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let values = samples.values
        guard values.count > 1 else { return Path() }
        let step = rect.width / CGFloat(values.count - 1)
        func point(_ i: Int) -> CGPoint {
            CGPoint(x: rect.minX + step * CGFloat(i), y: rect.maxY - rect.height * CGFloat(min(1, max(0, values[i]))))
        }
        var path = Path()
        path.move(to: point(0))
        for i in 1..<values.count {
            let p0 = point(max(i - 2, 0)), p1 = point(i - 1), p2 = point(i), p3 = point(min(i + 1, values.count - 1))
            path.addCurve(
                to: p2,
                control1: CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: min(rect.maxY, p1.y + (p2.y - p0.y) / 6)),
                control2: CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: min(rect.maxY, p2.y - (p3.y - p1.y) / 6))
            )
        }
        if closed {
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
        }
        return path
    }
}

// MARK: - Formatting

private enum StatsFormat {
    /// "4 hr, 12 min"; days and hours from a day on.
    static func duration(_ seconds: TimeInterval) -> String {
        let whole = Int(max(0, seconds))
        guard whole >= 60 else { return String(localized: "< 1 min") }
        let units: Set<Duration.UnitsFormatStyle.Unit> = whole >= 86_400 ? [.days, .hours] : [.hours, .minutes]
        return Duration.seconds(whole).formatted(.units(allowed: units, width: .abbreviated, maximumUnitCount: 2))
    }

    /// The label of the highest bar, when there's one clear highest.
    static func peak(of bars: [(String, Int)]) -> String? {
        guard let top = bars.max(by: { $0.1 < $1.1 }), top.1 > 0,
              bars.filter({ $0.1 == top.1 }).count == 1 else { return nil }
        return top.0
    }

    static func songs(_ value: Int) -> String {
        String(localized: "\(value) songs")
    }

    static func plays(_ value: Int) -> String {
        String(localized: "\(value) plays")
    }

    static func replays(_ value: Int) -> String {
        String(localized: "\(value) replays")
    }

    /// The hour as the locale writes it on an axis ("6 PM", "18").
    static func hour(_ hour: Int) -> String {
        date(atHour: hour).formatted(.dateTime.hour(.defaultDigits(amPM: .abbreviated)))
    }

    /// The hour as a time of day ("10:00 PM", "22:00").
    static func time(atHour hour: Int) -> String {
        date(atHour: hour).formatted(date: .omitted, time: .shortened)
    }

    private static func date(atHour hour: Int) -> Date {
        Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date()) ?? Date()
    }
}

// MARK: - Lyrics lists

/// The songs whose lyrics are of one kind (none, for `nil`), opened from the
/// Stats card; laid out like a genre.
struct LyricsSongsView: View {
    let kind: LyricsSyncKind?
    @EnvironmentObject private var libraryVM: LibraryViewModel
    @ObservedObject private var index = LyricsSyncIndex.shared

    var body: some View {
        let songs = SongCollection.lyrics(kind).songs(in: libraryVM, index: index)
        Group {
            if let songs, !songs.isEmpty {
                SongCollectionPage(
                    title: kind?.listTitle ?? String(localized: "No Lyrics"),
                    songs: songs,
                    palette: kind?.palette ?? .graphite,
                    collection: .lyrics(kind),
                    sortKey: "lyricsSongSort"
                )
            } else if songs == nil {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if kind == nil {
                ContentUnavailableView("Every Song Has Lyrics", systemImage: "quote.bubble")
            } else {
                ContentUnavailableView("No Songs", systemImage: "quote.bubble")
            }
        }
        .task(id: LyricsSyncIndex.signature(of: libraryVM.songs)) {
            index.refresh(libraryVM.songs)
        }
    }
}
