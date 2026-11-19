import AVFoundation
import NaturalLanguage
import Speech
import Synchronization
import SwiftUI
import UIKit

/// A game the user asked to start from the Games menu.
enum GameLaunch {
    case coversSnake(title: String, songs: [Song])
    case guessLyrics([Song])
    case whatSong([Song], snippetDuration: TimeInterval, difficulty: WhatSongDifficulty)
    case whoSings([Song], difficulty: WhatSongDifficulty)
}

/// The Games tab: the same menu as in Settings.
struct GamesTabView: View {
    @EnvironmentObject private var libraryVM: LibraryViewModel
    @EnvironmentObject private var router: AppRouter

    var body: some View {
        GamesMenu(songs: libraryVM.songs) { router.launchGame?($0) }
            // Counted again when the library changes.
            .id(libraryVM.songs.count)
            .ignoresSafeArea()
    }
}

private struct GamesMenu: UIViewControllerRepresentable {
    let songs: [Song]
    let onLaunch: (GameLaunch) -> Void

    func makeUIViewController(context: Context) -> LibraryGamesViewController {
        LibraryGamesViewController(songs: songs, onLaunch: onLaunch)
    }

    func updateUIViewController(_ controller: LibraryGamesViewController, context: Context) {}
}

/// Games menu, in Settings and as the Games tab.
final class LibraryGamesViewController: UIViewController {
    enum Game: CaseIterable, Identifiable {
        case coversSnake
        case guessLyrics
        case whatSong
        case whoSings
        case musicTiles

        var id: Self { self }

        var title: String {
            switch self {
            case .coversSnake: String(localized: "Covers Snake")
            case .guessLyrics: String(localized: "What Comes Next?")
            case .whatSong: String(localized: "What Song Is That?")
            case .whoSings: String(localized: "Who Sings This?")
            case .musicTiles: String(localized: "Music Tiles")
            }
        }

        var tagline: String {
            switch self {
            case .coversSnake: String(localized: "Eat the covers, grow longer.")
            case .guessLyrics: String(localized: "Finish the line being sung.")
            case .whatSong: String(localized: "Name the song from a snippet.")
            case .whoSings: String(localized: "Name the artist from the lyrics.")
            case .musicTiles: String(localized: "Tap the tiles to the beat.")
            }
        }

        var systemImage: String {
            switch self {
            case .coversSnake: "square.grid.3x3.fill"
            case .guessLyrics: "text.quote"
            case .whatSong: "waveform"
            case .whoSings: "music.mic"
            case .musicTiles: "pianokeys"
            }
        }

        var color: Color {
            switch self {
            case .coversSnake: AppTint.green.color
            case .guessLyrics: AppTint.orange.color
            case .whatSong: AppTint.purple.color
            case .whoSings: AppTint.red.color
            case .musicTiles: AppTint.blue.color
            }
        }

        var hasFilter: Bool { self == .guessLyrics || self == .whatSong || self == .whoSings }
    }

    /// Counted once (in the background): filtering the whole library on
    /// every render made the menu stutter.
    final class Counts: ObservableObject {
        @Published var synced: [Song]?
        @Published var playable: [Song]?
        /// Songs with lyrics, synced or not (Who Sings This?).
        @Published var lyrical: [Song]?
        var lyricalArtists = 0
    }

    private let songs: [Song]
    private let onLaunch: (GameLaunch) -> Void
    private let counts = Counts()
    private var syncedSongs: [Song]? { counts.synced }
    private var playableSongs: [Song]? { counts.playable }

    init(songs: [Song], onLaunch: @escaping (GameLaunch) -> Void) {
        self.songs = songs
        self.onLaunch = onLaunch
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:)") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Games")
        navigationItem.largeTitleDisplayMode = .always
        view.backgroundColor = .systemBackground

        let board = UIHostingController(rootView: GamesBoard(
            songCount: songs.count,
            counts: counts,
            onPlay: { [weak self] in self?.start($0) },
            onFilter: { [weak self] in self?.presentFilter(for: $0) },
            onPlayground: { [weak self] in self?.presentPlayground($0) }
        ).tint(AppTint.gamesColor))
        board.view.backgroundColor = .clear
        addChild(board)
        board.view.frame = view.bounds
        board.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(board.view)
        board.didMove(toParent: self)

        let songs = songs
        let counts = counts
        Task {
            let (synced, playable, lyrical) = await Task.detached(priority: .userInitiated) {
                (songs.filter { $0.lyricsKind == .synced }, songs.filter { $0.isExcerptPlayable }, songs.filter { $0.lyricsKind != .none })
            }.value
            counts.lyricalArtists = WhoSingsSettings.artistCount(lyrical)
            withAnimation(.smooth) {
                counts.lyrical = lyrical
                counts.synced = synced
                counts.playable = playable
            }
        }
    }

    private func start(_ game: Game) {
        switch game {
        case .coversSnake:
            onLaunch(.coversSnake(title: String(localized: "Full Library"), songs: songs))
        case .guessLyrics:
            guard let synced = syncedSongs, !synced.isEmpty else { return }
            onLaunch(.guessLyrics(synced))
        case .whatSong:
            guard let playable = playableSongs, playable.count >= 2 else { return }
            onLaunch(.whatSong(
                playable,
                snippetDuration: WhatSongSettings.savedSnippetDuration(),
                difficulty: WhatSongSettings.savedDifficulty()
            ))
        case .whoSings:
            guard let lyrical = counts.lyrical, counts.lyricalArtists >= WhoSingsSettings.minimumArtists else { return }
            onLaunch(.whoSings(lyrical, difficulty: WhoSingsSettings.savedDifficulty()))
        case .musicTiles:
            guard let playable = playableSongs, !playable.isEmpty else { return }
            // Played over the picker, which is still there when the game
            // closes: no trip back through the Home screen.
            weak var picker: UIViewController?
            let host = UIHostingController(rootView: MusicTilesPickerView(songs: playable, onCancel: {
                picker?.dismiss(animated: true)
            }, onStart: { song, difficulty in
                let session = MusicTilesSession(song: song, difficulty: difficulty)
                let game = UIHostingController(rootView: MusicTilesGameView(session: session, playerVM: AppModel.shared.playerVM) {
                    picker?.dismiss(animated: true)
                }
                .portraitLocked())
                game.modalPresentationStyle = .fullScreen
                picker?.present(game, animated: true)
            })
            // The cover flow on artist pages needs it; its router leads
            // nowhere from here.
            .environment(\.appServicesStorage, AppServices(libraryVM: AppModel.shared.libraryVM, playerVM: AppModel.shared.playerVM, router: AppRouter(), importService: AppModel.shared.importService))
            .environmentObject(AppModel.shared.libraryVM))
            picker = host
            host.sheetPresentationController?.prefersGrabberVisible = true
            host.sheetPresentationController?.detents = [.large()]
            present(host, animated: true)
        }
    }

    private func presentPlayground(_ mode: PlaygroundMode) {
        guard let playable = playableSongs else { return }
        let songs: [Song]
        switch mode {
        case .aCappella:
            songs = playable
        case .songVoice:
            let synced = Set((syncedSongs ?? []).map(\.id))
            songs = playable.filter { synced.contains($0.id) }
        }
        let host = UIHostingController(rootView: PlaygroundView(mode: mode, songs: songs, onClose: { [weak self] in
            self?.dismiss(animated: true)
        }).tint(AppTint.gamesColor)
            .environment(\.appServicesStorage, AppServices(libraryVM: AppModel.shared.libraryVM, playerVM: AppModel.shared.playerVM, router: AppRouter(), importService: AppModel.shared.importService))
            .environmentObject(AppModel.shared.libraryVM))
        host.sheetPresentationController?.prefersGrabberVisible = true
        host.sheetPresentationController?.detents = [.large()]
        present(host, animated: true)
    }

    private func presentFilter(for game: Game) {
        let isWhatSong = game == .whatSong
        let isWhoSings = game == .whoSings
        guard let songs = isWhatSong ? playableSongs : isWhoSings ? counts.lyrical : syncedSongs else { return }
        let host = UIHostingController(rootView: GameSetupView(
            title: game.title,
            songs: songs,
            minimum: isWhatSong ? 2 : 1,
            showsWhatSongOptions: isWhatSong,
            whoSings: isWhoSings,
            onCancel: { [weak self] in self?.dismiss(animated: true) },
            onStart: { [weak self] selected in
                guard let self else { return }
                if isWhoSings {
                    self.onLaunch(.whoSings(selected, difficulty: WhoSingsSettings.savedDifficulty()))
                } else if isWhatSong {
                    self.onLaunch(.whatSong(selected, snippetDuration: WhatSongSettings.savedSnippetDuration(), difficulty: WhatSongSettings.savedDifficulty()))
                } else {
                    self.onLaunch(.guessLyrics(selected))
                }
            }
        ))
        host.sheetPresentationController?.prefersGrabberVisible = true
        present(host, animated: true)
    }
}

/// The games, as Liquid Glass cards.
private struct GamesBoard: View {
    let songCount: Int
    @ObservedObject var counts: LibraryGamesViewController.Counts
    let onPlay: (LibraryGamesViewController.Game) -> Void
    let onFilter: (LibraryGamesViewController.Game) -> Void
    let onPlayground: (PlaygroundMode) -> Void
    @ObservedObject private var model = SingAlongModel.shared

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 16)], spacing: 16) {
                ForEach(LibraryGamesViewController.Game.allCases) { game in
                    card(game)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            VStack(alignment: .leading, spacing: 4) {
                Text("Playground")
                    .font(.title2.bold())
                Text("Silly things to do with your songs.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 20)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 16)], spacing: 16) {
                ForEach(PlaygroundMode.allCases.filter { $0 != .songVoice || HiddenSettings.alphaFeatures }) { mode in
                    playgroundCard(mode)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
    }

    private func playgroundDetail(_ mode: PlaygroundMode) -> String? {
        switch mode {
        case .aCappella:
            guard model.isInstalled else { return HiddenSettings.needsModelNote }
            return nil
        case .songVoice:
            return counts.synced?.isEmpty == true ? String(localized: "Needs songs with synced lyrics") : nil
        }
    }

    private func isAvailable(_ mode: PlaygroundMode) -> Bool {
        guard counts.playable?.isEmpty == false else { return false }
        switch mode {
        case .aCappella: return model.isInstalled
        case .songVoice: return counts.synced?.isEmpty == false
        }
    }

    private func playgroundCard(_ mode: PlaygroundMode) -> some View {
        let available = isAvailable(mode)
        return HStack(spacing: 14) {
            Image(systemName: mode.systemImage)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 46, height: 46)
                .glassEffect(.regular.tint(mode.color), in: .circle)
            VStack(alignment: .leading, spacing: 2) {
                Text(mode.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(playgroundDetail(mode) ?? mode.tagline)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 4)
            Button {
                onPlayground(mode)
            } label: {
                Image(systemName: "chevron.right")
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .tint(mode.color)
            .disabled(!available)
            .accessibilityLabel("Open")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .opacity(available ? 1 : 0.55)
        .contentShape(.rect(cornerRadius: 24))
        .onTapGesture { if available { onPlayground(mode) } }
    }

    private func isAvailable(_ game: LibraryGamesViewController.Game) -> Bool {
        switch game {
        case .coversSnake: songCount > 0
        case .guessLyrics: counts.synced?.isEmpty == false
        case .whatSong: (counts.playable?.count ?? 0) >= 2
        case .whoSings: counts.lyricalArtists >= WhoSingsSettings.minimumArtists
        case .musicTiles: counts.playable?.isEmpty == false
        }
    }

    private func detail(_ game: LibraryGamesViewController.Game) -> String? {
        switch game {
        case .coversSnake: String(localized: "\(songCount) playable songs")
        case .guessLyrics: counts.synced.map { String(localized: "\($0.count) songs with synced lyrics") }
        case .whatSong, .musicTiles: counts.playable.map { String(localized: "\($0.count) playable songs") }
        case .whoSings: counts.lyrical.map { _ in
            counts.lyricalArtists >= WhoSingsSettings.minimumArtists
                ? String(localized: "\(counts.lyricalArtists) artists with lyrics")
                : String(localized: "Needs lyrics from \(WhoSingsSettings.minimumArtists) artists")
        }
        }
    }

    private func card(_ game: LibraryGamesViewController.Game) -> some View {
        let available = isAvailable(game)
        return HStack(spacing: 14) {
            Group {
                if game == .coversSnake {
                    SnakeGlyph()
                } else {
                    Image(systemName: game.systemImage)
                        .font(.system(size: 20, weight: .semibold))
                }
            }
            .foregroundStyle(.white)
            .frame(width: 46, height: 46)
            .glassEffect(.regular.tint(game.color), in: .circle)
            VStack(alignment: .leading, spacing: 2) {
                Text(game.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(detail(game) ?? game.tagline)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .contentTransition(.numericText())
            }
            Spacer(minLength: 4)
            if game.hasFilter, available {
                Button {
                    onFilter(game)
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel("Choose Songs")
            }
            Button {
                onPlay(game)
            } label: {
                Image(systemName: "play.fill")
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .tint(game.color)
            .disabled(!available)
            .accessibilityLabel("Play")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .opacity(available || detail(game) == nil ? 1 : 0.55)
        .contentShape(.rect(cornerRadius: 24))
        .onTapGesture { if available { onPlay(game) } }
    }
}

/// Covers Snake's icon: chunky cubes and a triangle head, like in the game.
private struct SnakeGlyph: View {
    var body: some View {
        Canvas { context, size in
            let c = size.width / 4
            let gap: CGFloat = 2
            // Tail rising into a row of cubes, then the head.
            for (x, y) in [(0, 0), (0, 1), (1, 1), (2, 1)] {
                let rect = CGRect(x: CGFloat(x) * c + gap / 2, y: CGFloat(y) * c + gap / 2, width: c - gap, height: c - gap)
                context.fill(Path(roundedRect: rect, cornerRadius: c * 0.22), with: .foreground)
            }
            var head = Path()
            head.move(to: CGPoint(x: 3 * c + gap / 2, y: c))
            head.addLine(to: CGPoint(x: 4 * c, y: 1.5 * c))
            head.addLine(to: CGPoint(x: 3 * c + gap / 2, y: 2 * c))
            head.closeSubpath()
            context.fill(head, with: .foreground)
        }
        .frame(width: 30, height: 15)
        .accessibilityHidden(true)
    }
}

// MARK: - Game Setup

/// What Song Is That?'s saved choices.
enum WhatSongSettings {
    static let durationKey = "whatSongDuration"
    static let difficultyKey = "whatSongDifficulty"
    static let durations: [TimeInterval] = [10, 15, 30]

    static func savedSnippetDuration() -> TimeInterval {
        let saved = UserDefaults.standard.double(forKey: durationKey)
        return durations.contains(saved) ? saved : 15
    }

    static func savedDifficulty() -> WhatSongDifficulty {
        UserDefaults.standard.string(forKey: difficultyKey).flatMap(WhatSongDifficulty.init(rawValue:)) ?? .medium
    }
}

/// Before What Comes Next? or What Song Is That?: the game's options, then
/// the artists or albums it draws from, picked like covers in a grid.
struct GameSetupView: View {
    enum Grouping: CaseIterable {
        case artists, albums
        var title: String { self == .artists ? String(localized: "Artists") : String(localized: "Albums") }
    }

    private struct Source: Identifiable {
        let name: String
        let songs: [Song]
        var id: String { name }
    }

    let title: String
    let songs: [Song]
    /// Fewest songs a game needs.
    let minimum: Int
    /// What Song Is That? shows its snippet and difficulty pickers.
    let showsWhatSongOptions: Bool
    /// Who Sings This?: its own difficulty, and enough artists.
    var whoSings = false
    let onCancel: () -> Void
    let onStart: ([Song]) -> Void

    @AppStorage(WhatSongSettings.durationKey) private var duration: Double = 15
    @AppStorage(WhatSongSettings.difficultyKey) private var difficultyRaw = WhatSongDifficulty.medium.rawValue
    @AppStorage(WhoSingsSettings.difficultyKey) private var whoSingsDifficultyRaw = WhatSongDifficulty.medium.rawValue
    @State private var grouping = Grouping.artists
    /// Left out rather than picked: everything starts selected. Each
    /// grouping keeps its own, so switching never loses a choice.
    @State private var excludedByGrouping: [Grouping: Set<String>] = [:]
    @State private var pageHeights: [Grouping: CGFloat] = [:]
    /// Grouped once: regrouping on every switch made it late.
    private let sources: [Grouping: [Source]]

    init(title: String, songs: [Song], minimum: Int, showsWhatSongOptions: Bool, whoSings: Bool = false, onCancel: @escaping () -> Void, onStart: @escaping ([Song]) -> Void) {
        self.title = title
        self.songs = songs
        self.minimum = minimum
        self.showsWhatSongOptions = showsWhatSongOptions
        self.whoSings = whoSings
        self.onCancel = onCancel
        self.onStart = onStart
        let artists = Dictionary(grouping: songs) { ArtistMerges.main(for: $0.albumArtist ?? $0.artist) }
            .map { Source(name: $0.key, songs: $0.value) }
            // Most songs first: the artists the game will mostly be about.
            .sorted { ($0.songs.count, $1.name.lowercased()) > ($1.songs.count, $0.name.lowercased()) }
        let albums = Dictionary(grouping: songs, by: \.album)
            .map { Source(name: $0.key, songs: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        sources = [.artists: artists, .albums: albums]
    }

    private static func key(_ song: Song, _ grouping: Grouping) -> String {
        grouping == .artists ? ArtistMerges.main(for: song.albumArtist ?? song.artist) : song.album
    }

    private var excluded: Set<String> { excludedByGrouping[grouping] ?? [] }

    private var selectedSongs: [Song] {
        let excluded = excluded
        return songs.filter { !excluded.contains(Self.key($0, grouping)) }
    }

    var body: some View {
        let count = selectedSongs.count
        let enough = whoSings ? WhoSingsSettings.artistCount(selectedSongs) >= WhoSingsSettings.minimumArtists : count >= minimum
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if showsWhatSongOptions {
                        option("Snippet") {
                            GlassSegmentedPicker(
                                String(localized: "Snippet"),
                                options: WhatSongSettings.durations,
                                selection: Binding(get: { WhatSongSettings.durations.contains(duration) ? duration : 15 }, set: { duration = $0 }),
                                title: { String(localized: "\(Int($0)) s") },
                                commitsWhenSettled: true
                            )
                        }
                        option("Difficulty") {
                            GlassSegmentedPicker(
                                String(localized: "Difficulty"),
                                options: WhatSongDifficulty.allCases,
                                selection: Binding(get: { WhatSongDifficulty(rawValue: difficultyRaw) ?? .medium }, set: { difficultyRaw = $0.rawValue }),
                                title: \.title,
                                commitsWhenSettled: true
                            )
                        }
                    }
                    if whoSings {
                        option("Difficulty") {
                            GlassSegmentedPicker(
                                String(localized: "Difficulty"),
                                options: WhatSongDifficulty.allCases,
                                selection: Binding(get: { WhatSongDifficulty(rawValue: whoSingsDifficultyRaw) ?? .medium }, set: { whoSingsDifficultyRaw = $0.rawValue }),
                                title: \.title,
                                commitsWhenSettled: true
                            )
                        }
                        Text(whoSingsHint)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.top, -12)
                    }
                    option("Songs From") {
                        GlassSegmentedPicker(String(localized: "Songs From"), options: Grouping.allCases, selection: Binding(get: { grouping }, set: { new in
                            withAnimation(StatsMotion.page) { grouping = new }
                        }), title: \.title)
                    }
                    pages
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    onStart(selectedSongs)
                } label: {
                    Text(enough ? String(localized: "Play \(count) Songs") : whoSings ? String(localized: "Choose \(WhoSingsSettings.minimumArtists)+ Artists") : String(localized: "Choose More Songs"))
                        .font(.headline)
                        .contentTransition(.numericText())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.glassProminent)
                .disabled(!enough)
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
                .animation(.smooth, value: count)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { onCancel() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(excluded.isEmpty ? "None" : "All") {
                        withAnimation(.smooth) {
                            excludedByGrouping[grouping] = excluded.isEmpty ? Set((sources[grouping] ?? []).map(\.name)) : []
                        }
                    }
                }
            }
        }
        .tint(AppTint.gamesColor)
    }

    private var whoSingsHint: String {
        switch WhatSongDifficulty(rawValue: whoSingsDifficultyRaw) ?? .medium {
        case .easy: String(localized: "Two lines, four artists.")
        case .medium: String(localized: "One line, four artists.")
        case .hard: String(localized: "One line, six artists, often of the same genre.")
        }
    }

    /// Both grids stay built and only slide and fade, like Stats' pages.
    private var pages: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Grouping.allCases, id: \.self) { page in
                let position = Grouping.allCases.firstIndex(of: page)! - Grouping.allCases.firstIndex(of: grouping)!
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 14)], spacing: 18) {
                    ForEach(sources[page] ?? []) { source in
                        cell(source, in: page)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { pageHeights[page] = $0 }
                .offset(x: CGFloat(position) * 56)
                .opacity(page == grouping ? 1 : 0)
                .allowsHitTesting(page == grouping)
                .accessibilityHidden(page != grouping)
            }
        }
        .frame(height: pageHeights[grouping], alignment: .top)
    }

    private func option<Content: View>(_ label: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func cell(_ group: Source, in page: Grouping) -> some View {
        let isOn = !(excludedByGrouping[page] ?? []).contains(group.name)
        return Button {
            withAnimation(.snappy) {
                if isOn { excludedByGrouping[page, default: []].insert(group.name) } else { excludedByGrouping[page]?.remove(group.name) }
            }
        } label: {
            VStack(spacing: 6) {
                ZStack(alignment: .bottomTrailing) {
                    Group {
                        if page == .artists {
                            GeometryReader { proxy in
                                ArtistAvatarView(artistName: group.name, songs: group.songs, size: proxy.size.width)
                            }
                        } else {
                            TileArtwork(source: group.songs.first?.artworkSource, cornerRadius: 12, points: 120)
                        }
                    }
                    .aspectRatio(1, contentMode: .fit)
                    .saturation(isOn ? 1 : 0)
                    .opacity(isOn ? 1 : 0.4)
                    if isOn {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 24, height: 24)
                            .glassEffect(.regular.tint(AppTint.gamesColor), in: .circle)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                VStack(spacing: 1) {
                    Text(group.name)
                        .font(.footnote.weight(.medium))
                        .lineLimit(1)
                    Text("\(group.songs.count) songs")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .opacity(isOn ? 1 : 0.5)
            }
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: isOn)
    }
}

// MARK: - Pause

/// The games' pause screen, like Music Tiles': go on, or stop here and see
/// the score so far.
struct GamePauseOverlay: View {
    let onResume: () -> Void
    let onEnd: () -> Void

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
            VStack(spacing: 14) {
                Text("Paused")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.bottom, 12)
                Button(action: onResume) {
                    Label("Resume", systemImage: "play.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                }
                .buttonStyle(.glassProminent)
                Button(action: onEnd) {
                    Text("End Game")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                }
                .buttonStyle(.glass)
            }
            .padding(.horizontal, 40)
        }
        .transition(.opacity)
    }
}

/// The pause button at the top left of a game.
struct GamePauseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "pause.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 44, height: 44)
                .glassEffect(.regular.interactive(true), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Pause")
    }
}

// MARK: - Playground

enum PlaygroundMode: CaseIterable, Identifiable {
    case aCappella, songVoice

    var id: Self { self }

    var title: String {
        switch self {
        case .aCappella: String(localized: "A Cappella")
        case .songVoice: String(localized: "Song Voice")
        }
    }

    var tagline: String {
        switch self {
        case .aCappella: String(localized: "Just the vocals, no music.")
        case .songVoice: String(localized: "Type anything, the singer sings it.")
        }
    }

    var systemImage: String {
        switch self {
        case .aCappella: "music.mic"
        case .songVoice: "text.bubble.fill"
        }
    }

    var color: Color {
        switch self {
        case .aCappella: AppTint.red.color
        case .songVoice: AppTint.yellow.color
        }
    }
}

/// Picks the song to play with (A Cappella), or opens Song Voice.
struct PlaygroundView: View {
    let mode: PlaygroundMode
    let songs: [Song]
    let onClose: () -> Void

    static let aCappellaRecentKey = "aCappellaRecent"
    @State private var playing: Song?

    var body: some View {
        switch mode {
        case .aCappella:
            // The same picker as Music Tiles; the song plays full screen over it.
            MusicTilesPickerView(songs: songs, title: mode.title, showsDifficulty: false, recentKey: Self.aCappellaRecentKey, onCancel: onClose) { song, _ in
                let ids = [song.id] + MusicTilesGame.recentIDs(from: UserDefaults.standard.string(forKey: Self.aCappellaRecentKey) ?? "").filter { $0 != song.id }
                UserDefaults.standard.set(ids.prefix(6).map(\.uuidString).joined(separator: "\n"), forKey: Self.aCappellaRecentKey)
                playing = song
            }
            .fullScreenCover(item: $playing) { song in
                ACappellaView(song: song) { playing = nil }
            }
        case .songVoice:
            NavigationStack {
                SongVoiceView(songs: songs)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(role: .close) { onClose() }
                        }
                    }
            }
        }
    }
}

/// One song, decoded for the Playground, its vocals separated on request.
@MainActor
final class PlaygroundSong: ObservableObject {
    @Published private(set) var track: StageTrack?
    @Published private(set) var failed = false
    /// How far the separation is, while it runs.
    @Published private(set) var separation: Double?
    @Published private(set) var vocalsReady = false
    @Published private(set) var time: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var isPlaying = false
    /// Looking for where the singing starts, to play from there.
    @Published private(set) var findsVoice = false

    let song: Song
    private var stage: PlaygroundStage?
    private var onsetJob: Task<Void, Never>?
    private var loadJob: Task<Void, Never>?
    private var separationTask: Task<Bool, Never>?
    private var timer: Timer?
    private var wantsSeparation = false
    private var resumesPlayer = false

    init(song: Song) {
        self.song = song
    }

    func load(separating: Bool) {
        wantsSeparation = wantsSeparation || separating
        guard track == nil else {
            if separating { separate() }
            return
        }
        guard loadJob == nil else { return }
        let url = song.isMediaLibraryItem ? song.fileURL : song.playableFileURL
        loadJob = Task {
            let track = await Task.detached(priority: .userInitiated) { await StageTrack.load(url) }.value
            loadJob = nil
            guard let track, !Task.isCancelled else {
                failed = !Task.isCancelled
                return
            }
            self.track = track
            duration = Double(track.count) / StageTrack.sampleRate
            if wantsSeparation { separate() }
        }
    }

    func separate() {
        wantsSeparation = true
        guard let track, !vocalsReady, separationTask == nil else { return }
        separation = 0
        let id = song.id
        let report: @Sendable (Double) -> Void = { [weak self] fraction in
            Task { @MainActor in
                if self?.separation != nil { self?.separation = fraction }
            }
        }
        let task = Task.detached(priority: .userInitiated) {
            await VocalSeparator.separateAll(track, id: id, progress: report)
        }
        separationTask = task
        Task {
            let done = await task.value
            guard separationTask == task else { return }
            separationTask = nil
            separation = nil
            vocalsReady = done
            if !done { failed = true }
        }
    }

    /// Plays the vocals from where the singing starts, once the separation
    /// gets there: no silent intro.
    func playFromVoice() {
        guard onsetJob == nil else { return }
        findsVoice = true
        onsetJob = Task {
            defer {
                onsetJob = nil
                findsVoice = false
            }
            while track == nil, !failed {
                try? await Task.sleep(for: .milliseconds(150))
                if Task.isCancelled { return }
            }
            guard let track else { return }
            var scanned = 0
            var onset: Int?
            while scanned < track.count, onset == nil, !Task.isCancelled {
                guard track.isReady(sample: scanned) else {
                    if failed || (separationTask == nil && !vocalsReady) { break }
                    try? await Task.sleep(for: .milliseconds(150))
                    continue
                }
                let from = scanned
                let to = min(track.count, (scanned / VocalSeparator.stride + 1) * VocalSeparator.stride)
                onset = await Task.detached(priority: .userInitiated) { Self.voiceOnset(in: track, from: from, to: to) }.value
                scanned = to
            }
            // Started by hand meanwhile: left alone.
            guard !Task.isCancelled, stage == nil else { return }
            stage = PlaygroundStage(vocalsOf: track)
            let start = max(0, Double(onset ?? 0) / StageTrack.sampleRate - 0.4)
            seek(to: start)
            self.start()
        }
    }

    /// The first moment the vocals are clearly heard: a few windows in a row
    /// louder than what bleeds from the music.
    nonisolated private static func voiceOnset(in track: StageTrack, from: Int, to: Int) -> Int? {
        let window = 2048
        var loud = 0
        var start = from
        while start + window <= to {
            var energy: Float = 0
            for i in start..<(start + window) {
                let mono = (track.vocalsLeft[i] + track.vocalsRight[i]) / 2
                energy += mono * mono
            }
            if (energy / Float(window)).squareRoot() > 0.03 {
                loud += 1
                if loud == 3 { return start - 2 * window }
            } else {
                loud = 0
            }
            start += window
        }
        return nil
    }

    /// The vocals alone, played as they're separated.
    func toggleVocals() {
        if isPlaying {
            stage?.pause()
            update()
            return
        }
        guard let track else { return }
        if stage == nil { stage = PlaygroundStage(vocalsOf: track) }
        start()
    }

    func play(left: [Float], right: [Float]) {
        stage?.stop()
        stage = PlaygroundStage(left: left, right: right)
        start()
    }

    func seek(to time: TimeInterval) {
        stage?.seek(to: time)
        self.time = time
    }

    /// Leaving: everything stops, and the music comes back if it was playing.
    func close() {
        stage?.stop()
        stage = nil
        timer?.invalidate()
        timer = nil
        onsetJob?.cancel()
        loadJob?.cancel()
        separationTask?.cancel()
        separationTask = nil
        separation = nil
        isPlaying = false
        if resumesPlayer {
            resumesPlayer = false
            AppModel.shared.playerVM.togglePlayPause()
        }
    }

    private func start() {
        let player = AppModel.shared.playerVM
        if player.isPlaying {
            resumesPlayer = true
            player.togglePlayPause()
        }
        try? AVAudioSession.sharedInstance().setActive(true)
        stage?.play()
        update()
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func update() {
        guard let stage else { return }
        if stage.durationTime != duration, track == nil || stage.isRendered { duration = stage.durationTime }
        time = stage.time
        if isPlaying != stage.isPlaying { isPlaying = stage.isPlaying }
        if !stage.isPlaying {
            stage.pause()
            timer?.invalidate()
            timer = nil
        }
    }
}

/// Plays samples from memory; on vocals still being separated, it waits
/// where they aren't ready yet.
final class PlaygroundStage: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var node: AVAudioSourceNode?
    private let left: UnsafeMutablePointer<Float>
    private let right: UnsafeMutablePointer<Float>
    private let count: Int
    /// Keeps the vocals alive, and says which are ready.
    private let track: StageTrack?
    let isRendered: Bool

    private let playing = Atomic<Bool>(false)
    private let seekTarget = Atomic<Int>(-1)
    private let position = Atomic<Int>(0)
    // Audio thread only.
    private var cursor = 0

    init(vocalsOf track: StageTrack) {
        left = track.vocalsLeft
        right = track.vocalsRight
        count = track.count
        self.track = track
        isRendered = false
    }

    init(left samplesLeft: [Float], right samplesRight: [Float]) {
        count = min(samplesLeft.count, samplesRight.count)
        left = .allocate(capacity: max(1, count))
        right = .allocate(capacity: max(1, count))
        left.initialize(from: samplesLeft, count: count)
        right.initialize(from: samplesRight, count: count)
        track = nil
        isRendered = true
    }

    deinit {
        stop()
        if isRendered {
            left.deallocate()
            right.deallocate()
        }
    }

    var time: TimeInterval { Double(position.load(ordering: .relaxed)) / StageTrack.sampleRate }
    var durationTime: TimeInterval { Double(count) / StageTrack.sampleRate }
    var isPlaying: Bool { playing.load(ordering: .relaxed) }

    func play() {
        if position.load(ordering: .relaxed) >= count { seek(to: 0) }
        playing.store(true, ordering: .relaxed)
        if node == nil {
            let format = AVAudioFormat(standardFormatWithSampleRate: StageTrack.sampleRate, channels: 2)!
            let node = AVAudioSourceNode(format: format) { [unowned self] _, _, frameCount, buffers in
                let list = UnsafeMutableAudioBufferListPointer(buffers)
                guard list.count >= 2,
                      let outL = list[0].mData?.assumingMemoryBound(to: Float.self),
                      let outR = list[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
                self.render(Int(frameCount), outL, outR)
                return noErr
            }
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            self.node = node
            engine.prepare()
        }
        if !engine.isRunning { try? engine.start() }
    }

    func pause() {
        playing.store(false, ordering: .relaxed)
        if engine.isRunning { engine.pause() }
    }

    func seek(to time: TimeInterval) {
        let sample = min(count, max(0, Int(time * StageTrack.sampleRate)))
        seekTarget.store(sample, ordering: .relaxed)
        position.store(sample, ordering: .relaxed)
    }

    func stop() {
        playing.store(false, ordering: .relaxed)
        engine.stop()
        if let node { engine.detach(node) }
        node = nil
    }

    private func render(_ frames: Int, _ outL: UnsafeMutablePointer<Float>, _ outR: UnsafeMutablePointer<Float>) {
        outL.update(repeating: 0, count: frames)
        outR.update(repeating: 0, count: frames)
        let seek = seekTarget.exchange(-1, ordering: .relaxed)
        if seek >= 0 { cursor = seek }
        guard playing.load(ordering: .relaxed) else { return }
        for i in 0..<frames {
            if cursor >= count {
                playing.store(false, ordering: .relaxed)
                break
            }
            // Not separated yet: waits there.
            if let track, !track.isReady(sample: cursor) { break }
            outL[i] = left[cursor]
            outR[i] = right[cursor]
            cursor += 1
        }
        position.store(cursor, ordering: .relaxed)
    }
}

private func playgroundClock(_ time: TimeInterval) -> String {
    let seconds = max(0, Int(time))
    return "\(seconds / 60):" + String(format: "%02d", seconds % 60)
}

/// The song's vocals alone.
private struct ACappellaView: View {
    @StateObject private var model: PlaygroundSong
    let onClose: () -> Void

    init(song: Song, onClose: @escaping () -> Void) {
        _model = StateObject(wrappedValue: PlaygroundSong(song: song))
        self.onClose = onClose
    }

    private var status: String? {
        if model.failed { return String(localized: "This song couldn't be prepared.") }
        if model.track == nil { return String(localized: "Preparing the song…") }
        if model.findsVoice { return String(localized: "Finding where the singing starts…") }
        if let progress = model.separation { return String(localized: "Taking out the music… \(Int(progress * 100))%") }
        return nil
    }

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width - 64, proxy.size.height * 0.42)
            VStack(spacing: 0) {
                HStack {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.9))
                            .frame(width: 44, height: 44)
                            .glassEffect(.regular.interactive(true), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close")
                    Spacer()
                    Text("A Cappella")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.7))
                    Spacer()
                    Color.clear.frame(width: 44, height: 44)
                }
                .padding(.horizontal, 20)

                Spacer(minLength: 16)
                ArtworkImage(source: model.song.artworkSource, points: 360)
                    .frame(width: side, height: side)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .shadow(color: .black.opacity(0.3), radius: 24, y: 10)
                    .scaleEffect(model.isPlaying ? 1 : 0.86)
                    .animation(.spring(response: 0.5, dampingFraction: 0.72), value: model.isPlaying)
                Spacer(minLength: 16)

                VStack(alignment: .leading, spacing: 2) {
                    Text(model.song.title)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                    Text(model.song.artist)
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.6))
                }
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 28)

                VStack(spacing: 6) {
                    LiquidGlassSeekSlider(value: model.time, duration: model.duration) { model.seek(to: $0) }
                        .frame(height: 24)
                    HStack {
                        Text(playgroundClock(model.time))
                        Spacer()
                        Text(status ?? "")
                            .lineLimit(1)
                            .contentTransition(.numericText())
                        Spacer()
                        Text("-" + playgroundClock(model.duration - model.time))
                    }
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.55))
                }
                .padding(.horizontal, 28)
                .padding(.top, 18)
                .disabled(model.track == nil)

                HStack {
                    Button { model.toggleVocals() } label: {
                        Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 30, weight: .semibold))
                            .foregroundStyle(.white)
                            .contentTransition(.symbolEffect(.replace))
                            .frame(width: 76, height: 76)
                            .glassEffect(.regular.interactive(true), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .opacity(model.findsVoice ? 0.4 : 1)
                }
                .disabled(model.track == nil || model.findsVoice)
                .padding(.top, 28)
                Spacer(minLength: 40)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background {
            PlayerBackgroundRepresentable(artwork: model.song.artworkSource)
                .ignoresSafeArea()
        }
        .environment(\.colorScheme, .dark)
        .animation(.smooth, value: status)
        .onAppear {
            model.load(separating: true)
            model.playFromVoice()
        }
        .onDisappear { model.close() }
    }
}

// MARK: Song Voice

/// A sung word, its syllables and when it's sung.
struct VoiceWord: Sendable {
    let key: String
    /// As written, and as they sound (roughly), syllable by syllable.
    let spelled: [String]
    let sounds: [String]
    let start: TimeInterval
    let end: TimeInterval
    /// Synced word by word, not guessed from the line.
    let timed: Bool

    /// When syllables `from..<to` are sung, sharing the word by length.
    func slice(_ from: Int, _ to: Int) -> (TimeInterval, TimeInterval) {
        let weights = spelled.map { 1 + 0.12 * Double($0.count) }
        let total = weights.reduce(0, +)
        let before = weights[..<from].reduce(0, +)
        let inside = weights[from..<to].reduce(0, +)
        let span = end - start
        return (start + span * before / total, start + span * (before + inside) / total)
    }
}

struct VoiceLine: Sendable {
    let song: Int
    let words: [VoiceWord]
}

/// A cut to play: part of one song.
struct VoiceClip: Sendable {
    let song: Int
    let start: TimeInterval
    let end: TimeInterval
    /// Whole words: their edges are found in the voice itself.
    let trims: Bool
    let precise: Bool
    /// Glued to the one before, inside a word.
    let joinsPrevious: Bool
    /// The words it says, to find them in what's heard.
    let keys: [String]
    /// For a piece of a word: the part of it, from 0 to 1.
    var part: (Double, Double)? = nil
}

/// A word the recognizer heard in an excerpt's voice, in seconds from its start.
struct HeardWord: Sendable {
    let key: String
    let start: TimeInterval
    let end: TimeInterval
}

/// What was typed, as shown: sung as is, or in pieces.
struct VoicePiece: Sendable {
    let text: String
    let found: Bool
}

struct VoicePhrase: Identifiable, Sendable {
    let id = UUID()
    let text: String
    let pieces: [VoicePiece]
    let isWhole: Bool
    let source: String?
}

enum SongVoice {
    static func key<S: StringProtocol>(_ text: S) -> String {
        String(text).lowercased().folding(options: .diacriticInsensitive, locale: nil).filter { $0.isLetter || $0.isNumber }
    }

    private static let vowels: Set<Character> = ["a", "e", "i", "o", "u", "y"]
    private static let onsets: Set<String> = ["bl", "br", "cl", "cr", "dr", "fl", "fr", "gl", "gr", "pl", "pr", "tr", "vr",
                                              "ch", "ph", "th", "sh", "gn", "qu", "wh", "kn", "wr"]

    /// Split between vowel groups, keeping clusters like "tr" together.
    static func syllables(_ key: String) -> [String] {
        let letters = Array(key)
        var groups: [(start: Int, end: Int)] = []
        var index = 0
        while index < letters.count {
            guard vowels.contains(letters[index]) else {
                index += 1
                continue
            }
            var end = index
            while end < letters.count, vowels.contains(letters[end]) { end += 1 }
            groups.append((index, end))
            index = end
        }
        guard groups.count > 1 else { return [key] }
        var result: [String] = []
        var start = 0
        for group in 1..<groups.count {
            let clusterStart = groups[group - 1].end
            let clusterEnd = groups[group].start
            let cut: Int
            if clusterEnd - clusterStart <= 1 {
                cut = clusterStart
            } else if onsets.contains(String(letters[(clusterEnd - 2)..<clusterEnd])) {
                cut = clusterEnd - 2
            } else {
                cut = clusterEnd - 1
            }
            result.append(String(letters[start..<cut]))
            start = cut
        }
        result.append(String(letters[start...]))
        return result
    }

    /// Roughly how a syllable sounds, so different spellings meet
    /// ("eau" and "o", "ph" and "f", soft and hard "c", silent endings).
    static func sound(_ syllable: String, isLast: Bool) -> String {
        var text = syllable
        for (from, to) in [("eau", "o"), ("ph", "f"), ("qu", "k"), ("ck", "k"), ("sh", "ch"), ("au", "o"), ("ai", "e"), ("ei", "e"), ("y", "i"), ("x", "ks"), ("z", "s"), ("q", "k")] {
            text = text.replacingOccurrences(of: from, with: to)
        }
        let letters = Array(text)
        var result = ""
        for (index, letter) in letters.enumerated() {
            let next = index + 1 < letters.count ? letters[index + 1] : nil
            switch letter {
            case "c":
                result.append(next == "h" ? "c" : (next == "e" || next == "i") ? "s" : "k")
            case "h":
                if index > 0, letters[index - 1] == "c" { result.append("h") }
            default:
                if result.last != letter { result.append(letter) }
            }
        }
        if isLast, result.count > 1, let last = result.last, "stdxp".contains(last) { result.removeLast() }
        return result.isEmpty ? syllable : result
    }

    static func nucleus(_ sound: String) -> String {
        let vowelsOnly = sound.filter { vowels.contains($0) }
        return vowelsOnly.isEmpty ? sound : vowelsOnly
    }

    static func word(key: String, start: TimeInterval, end: TimeInterval, timed: Bool) -> VoiceWord {
        let spelled = syllables(key)
        let sounds = spelled.enumerated().map { sound($0.element, isLast: $0.offset == spelled.count - 1) }
        return VoiceWord(key: key, spelled: spelled, sounds: sounds, start: start, end: end, timed: timed)
    }
}

/// Every sung word of the songs given, indexed by word and by syllable.
struct VoiceLibrary: Sendable {
    struct WordRef: Sendable { let line: Int; let word: Int }
    struct SyllableRef: Sendable { let line: Int; let word: Int; let syllable: Int }

    let songs: [Song]
    let lines: [VoiceLine]
    private let words: [String: [WordRef]]
    private let syllables: [String: [SyllableRef]]
    private let nuclei: [String: [SyllableRef]]

    var isEmpty: Bool { lines.isEmpty }

    static func build(_ sources: [(song: Song, lyrics: URL)]) -> VoiceLibrary {
        var songs: [Song] = []
        var lines: [VoiceLine] = []
        for source in sources {
            guard let parsed = LRCParser.parse(url: source.lyrics) else { continue }
            let (lyrics, timings) = LyricsMarks.forGames(parsed, songID: source.song.id)
            guard lyrics.hasTimedLyrics else { continue }
            let song = songs.count
            let offset = lyrics.offset
            var added = false
            for (index, line) in lyrics.lines.enumerated() where !line.isInstrumentalGap {
                let ranges = LyricWords.ranges(in: line.text)
                guard !ranges.isEmpty else { continue }
                var words: [VoiceWord] = []
                if let lineTimings = timings[line.id] {
                    for (range, timing) in zip(ranges, lineTimings) where timing.end > timing.start {
                        let key = SongVoice.key(line.text[range])
                        if !key.isEmpty { words.append(SongVoice.word(key: key, start: timing.start - offset, end: timing.end - offset, timed: true)) }
                    }
                } else {
                    // Spread over the line by syllables.
                    let next = lyrics.lines.indices.contains(index + 1) ? lyrics.lines[index + 1].time : line.time + 4
                    let span = max(0.3, min(next - line.time, Double(ranges.count) * 0.4 + 0.4) * 0.92)
                    let counts = ranges.map { VocalTimeline.syllableCount(line.text[$0]) }
                    let total = Double(max(1, counts.reduce(0, +)))
                    var time = line.time - offset
                    for (range, count) in zip(ranges, counts) {
                        let length = span * Double(count) / total
                        let key = SongVoice.key(line.text[range])
                        if !key.isEmpty { words.append(SongVoice.word(key: key, start: time, end: time + length, timed: false)) }
                        time += length
                    }
                }
                if !words.isEmpty {
                    lines.append(VoiceLine(song: song, words: words))
                    added = true
                }
            }
            if added { songs.append(source.song) }
        }
        var words: [String: [WordRef]] = [:]
        var syllables: [String: [SyllableRef]] = [:]
        var nuclei: [String: [SyllableRef]] = [:]
        // Word-synced ones first: their timing is right.
        let order = lines.indices.sorted { (lines[$0].words.first?.timed == true ? 0 : 1) < (lines[$1].words.first?.timed == true ? 0 : 1) }
        for line in order {
            for (index, word) in lines[line].words.enumerated() {
                words[word.key, default: []].append(WordRef(line: line, word: index))
                for (syllable, sound) in word.sounds.enumerated() {
                    let ref = SyllableRef(line: line, word: index, syllable: syllable)
                    syllables[sound, default: []].append(ref)
                    nuclei[SongVoice.nucleus(sound), default: []].append(ref)
                }
            }
        }
        return VoiceLibrary(songs: songs, lines: lines, words: words, syllables: syllables, nuclei: nuclei)
    }

    private func word(_ line: Int, _ index: Int) -> VoiceWord { lines[line].words[index] }

    /// A word sung too fast or too slow for its syllables is probably
    /// badly timed.
    private func timingCost(_ word: VoiceWord) -> Double {
        let expected = 0.1 + 0.12 * Double(word.spelled.count)
        let length = max(0.03, word.end - word.start)
        return (word.timed ? 0 : 0.35) + 0.25 * min(2, abs(log(length / expected)))
    }

    private struct Typed {
        let text: String
        let key: String
        let spelled: [String]
        let sounds: [String]
    }

    private enum Step {
        case run(line: Int, word: Int, count: Int)
        case pieces([(text: String, ref: SyllableRef?, count: Int)])
    }

    /// The cuts that say `text` best: runs of the same words in a row in a
    /// song first (sung together, they sound natural), then whole words,
    /// then syllables that sound alike.
    func plan(_ text: String) -> (phrases: [VoicePhrase], clips: [VoiceClip]) {
        let typed: [Typed] = text.split(whereSeparator: { $0.isWhitespace }).compactMap { token in
            let key = SongVoice.key(token)
            guard !key.isEmpty else { return nil }
            let word = SongVoice.word(key: key, start: 0, end: 0, timed: true)
            return Typed(text: String(token), key: key, spelled: word.spelled, sounds: word.sounds)
        }
        let count = typed.count
        guard count > 0 else { return ([], []) }
        var best = [Double](repeating: .infinity, count: count + 1)
        var steps = [(from: Int, step: Step)?](repeating: nil, count: count + 1)
        best[0] = 0
        for start in 0..<count where best[start] < .infinity {
            for ref in (words[typed[start].key] ?? []).prefix(600) {
                let line = lines[ref.line]
                var cost = 1.0
                var length = 0
                while start + length < count, ref.word + length < line.words.count, line.words[ref.word + length].key == typed[start + length].key {
                    cost += timingCost(line.words[ref.word + length])
                    length += 1
                    if best[start] + cost < best[start + length] {
                        best[start + length] = best[start] + cost
                        steps[start + length] = (start, .run(line: ref.line, word: ref.word, count: length))
                    }
                }
            }
            let (pieces, cost) = pieces(for: typed[start])
            if best[start] + 2.5 + cost < best[start + 1] {
                best[start + 1] = best[start] + 2.5 + cost
                steps[start + 1] = (start, .pieces(pieces))
            }
        }
        var chosen: [(from: Int, to: Int, step: Step)] = []
        var end = count
        while end > 0, let step = steps[end] {
            chosen.append((step.from, end, step.step))
            end = step.from
        }
        chosen.reverse()

        var phrases: [VoicePhrase] = []
        var clips: [VoiceClip] = []
        for item in chosen {
            let text = typed[item.from..<item.to].map(\.text).joined(separator: " ")
            switch item.step {
            case let .run(line, first, length):
                let words = lines[line].words[first..<(first + length)]
                let song = lines[line].song
                clips.append(VoiceClip(song: song, start: words.first!.start, end: words.last!.end, trims: true,
                                       precise: words.allSatisfy(\.timed), joinsPrevious: false, keys: words.map(\.key)))
                phrases.append(VoicePhrase(text: text, pieces: [VoicePiece(text: text, found: true)], isWhole: true, source: songs[song].title))
            case let .pieces(pieces):
                var shown: [VoicePiece] = []
                var sources = Set<Int>()
                var isFirst = true
                for piece in pieces {
                    shown.append(VoicePiece(text: piece.text, found: piece.ref != nil))
                    guard let ref = piece.ref else { continue }
                    let source = word(ref.line, ref.word)
                    let (start, end) = source.slice(ref.syllable, ref.syllable + piece.count)
                    let song = lines[ref.line].song
                    sources.insert(song)
                    let span = max(0.001, source.end - source.start)
                    clips.append(VoiceClip(song: song, start: start, end: end, trims: false, precise: source.timed, joinsPrevious: !isFirst,
                                           keys: [source.key], part: ((start - source.start) / span, (end - source.start) / span)))
                    isFirst = false
                }
                let source = sources.count == 1 ? songs[sources.first!].title : sources.isEmpty ? nil : String(localized: "\(sources.count) songs")
                phrases.append(VoicePhrase(text: text, pieces: shown, isWhole: false, source: source))
            }
        }
        return (phrases, clips)
    }

    /// A word no song sings, from syllables of others: the same sounds in a
    /// row, at the same place in their word, when there are.
    private func pieces(for typed: Typed) -> ([(text: String, ref: SyllableRef?, count: Int)], Double) {
        let count = typed.sounds.count
        var best = [Double](repeating: .infinity, count: count + 1)
        var steps = [(from: Int, ref: SyllableRef?, count: Int)?](repeating: nil, count: count + 1)
        best[0] = 0
        func relax(_ from: Int, _ length: Int, _ cost: Double, _ ref: SyllableRef?) {
            if best[from] + cost < best[from + length] {
                best[from + length] = best[from] + cost
                steps[from + length] = (from, ref, length)
            }
        }
        for start in 0..<count where best[start] < .infinity {
            let matches = (syllables[typed.sounds[start]] ?? []).prefix(400)
            for ref in matches {
                let source = word(ref.line, ref.word)
                var length = 0
                var spelling = 0.0
                while start + length < count, ref.syllable + length < source.sounds.count,
                      source.sounds[ref.syllable + length] == typed.sounds[start + length] {
                    if source.spelled[ref.syllable + length] != typed.spelled[start + length] { spelling += 0.15 }
                    length += 1
                    var cost = 1 + spelling + timingCost(source)
                    if (ref.syllable == 0) != (start == 0) { cost += 0.4 }
                    if (ref.syllable + length == source.sounds.count) != (start + length == count) { cost += 0.4 }
                    relax(start, length, cost, ref)
                }
            }
            if matches.isEmpty {
                for ref in (nuclei[SongVoice.nucleus(typed.sounds[start])] ?? []).prefix(200) {
                    let source = word(ref.line, ref.word)
                    var cost = 2.2 + timingCost(source)
                    if (ref.syllable == 0) != (start == 0) { cost += 0.4 }
                    if (ref.syllable + 1 == source.sounds.count) != (start + 1 == count) { cost += 0.4 }
                    relax(start, 1, cost, ref)
                }
            }
            relax(start, 1, 5, nil)
        }
        var result: [(text: String, ref: SyllableRef?, count: Int)] = []
        var end = count
        while end > 0, let step = steps[end] {
            result.append((typed.spelled[step.from..<end].joined(), step.ref, step.count))
            end = step.from
        }
        return (result.reversed(), best[count])
    }
}

/// Part of a song decoded around some cuts, its vocals separated if they
/// could be.
struct VoiceExcerpt: Sendable {
    let track: StageTrack
    let start: TimeInterval
    let hasVocals: Bool
    var heard: [HeardWord] = []
}

/// On-device speech recognition run on a separated voice, to know where
/// each word really is.
enum VoiceListener {
    static func authorize() async -> Bool {
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { @Sendable status in continuation.resume(returning: status) }
        }
        return status == .authorized
    }

    /// The language the lyrics are written in.
    static func locale(for text: String) -> Locale {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let language = recognizer.dominantLanguage?.rawValue ?? "en"
        let identifiers = ["fr": "fr-FR", "en": "en-US", "es": "es-ES", "de": "de-DE", "it": "it-IT", "pt": "pt-BR", "ja": "ja-JP", "ko": "ko-KR"]
        return Locale(identifier: identifiers[language] ?? language)
    }

    static func words(in track: StageTrack, locale: Locale) async -> [HeardWord] {
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else { return [] }
        let rate = 16_000.0
        let step = StageTrack.sampleRate / rate
        let count = Int(Double(track.count) / step)
        guard count > 1600,
              let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
              let samples = buffer.floatChannelData?[0] else { return [] }
        // Down to 16 kHz mono, averaging so nothing aliases.
        var peak: Float = 0
        for i in 0..<count {
            let from = Int(Double(i) * step)
            let to = min(track.count, max(from + 1, Int(Double(i + 1) * step)))
            var sum: Float = 0
            for j in from..<to { sum += track.vocalsLeft[j] + track.vocalsRight[j] }
            samples[i] = sum / Float(2 * (to - from))
            peak = max(peak, abs(samples[i]))
        }
        if peak > 0.001 { for i in 0..<count { samples[i] *= 0.8 / peak } }
        buffer.frameLength = AVAudioFrameCount(count)
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = false
        request.taskHint = .dictation
        request.addsPunctuation = false
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        request.append(buffer)
        request.endAudio()
        let done = Mutex(false)
        let segments: [HeardWord] = await withCheckedContinuation { continuation in
            let finish: @Sendable ([HeardWord]) -> Void = { words in
                let first = done.withLock { done in
                    defer { done = true }
                    return !done
                }
                if first { continuation.resume(returning: words) }
            }
            recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal {
                    finish(result.bestTranscription.segments.compactMap { segment in
                        let key = SongVoice.key(segment.substring)
                        guard !key.isEmpty, segment.duration > 0 else { return nil }
                        return HeardWord(key: key, start: segment.timestamp, end: segment.timestamp + segment.duration)
                    })
                } else if error != nil {
                    finish([])
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 20) { finish([]) }
        }
        return segments
    }
}

extension SongVoice {
    /// The cuts one after the other, each as loud as the others, a breath
    /// between words and crossfaded inside them.
    static func assemble(_ clips: [VoiceClip], windows: [Int], excerpts: [Int: VoiceExcerpt], withMusic: Bool) -> ([Float], [Float]) {
        var used: [Int: Set<Int>] = [:]
        let rate = StageTrack.sampleRate
        var left: [Float] = []
        var right: [Float] = []
        let gap = Int(0.07 * rate)
        let cross = Int(0.012 * rate)
        let edge = Int(0.006 * rate)
        for (index, clip) in clips.enumerated() {
            guard let excerpt = excerpts[windows[index]] else { continue }
            let track = excerpt.track
            let pad = clip.trims && excerpt.hasVocals ? (clip.precise ? 0.06 : 0.14) : 0.012
            var from = max(0, Int((clip.start - pad - excerpt.start) * rate))
            var to = min(track.count, Int((clip.end + pad - excerpt.start) * rate))
            if let heard = located(clip, in: excerpt, avoiding: used[windows[index], default: []]) {
                // Where the recognizer heard the words: cut right there.
                used[windows[index], default: []].formUnion(heard.indices)
                from = max(0, Int((heard.start - excerpt.start) * rate))
                to = min(track.count, Int((heard.end - excerpt.start) * rate))
                if clip.part == nil { (from, to) = tightened(track, from, to) }
            } else if clip.trims, excerpt.hasVocals {
                (from, to) = trimmed(track, from, to)
            }
            guard to - from > Int(0.03 * rate) else { continue }
            let voice = excerpt.hasVocals && !withMusic
            let sourceL = voice ? track.vocalsLeft : track.left
            let sourceR = voice ? track.vocalsRight : track.right
            // Loudness measured on the voice, so every cut sounds as loud.
            let measureL = excerpt.hasVocals ? track.vocalsLeft : track.left
            let measureR = excerpt.hasVocals ? track.vocalsRight : track.right
            var energy: Float = 0
            for i in from..<to {
                let mono = (measureL[i] + measureR[i]) / 2
                energy += mono * mono
            }
            let rms = (energy / Float(to - from)).squareRoot()
            let gain = rms > 0.0001 ? min(8, 0.1 / rms) : 1
            let joinsNext = index + 1 < clips.count && clips[index + 1].joinsPrevious
            let fadeIn = min((to - from) / 2, clip.joinsPrevious ? cross : edge)
            let fadeOut = min((to - from) / 2, joinsNext ? cross : edge)
            var cutL = [Float](repeating: 0, count: to - from)
            var cutR = [Float](repeating: 0, count: to - from)
            for i in from..<to {
                let j = i - from
                var shape: Float = 1
                if j < fadeIn { shape = Float(j) / Float(fadeIn) }
                if to - 1 - i < fadeOut { shape = min(shape, Float(to - 1 - i) / Float(fadeOut)) }
                cutL[j] = sourceL[i] * gain * shape
                cutR[j] = sourceR[i] * gain * shape
            }
            if clip.joinsPrevious, !left.isEmpty {
                let overlap = min(fadeIn, left.count, cutL.count)
                for k in 0..<overlap {
                    left[left.count - overlap + k] += cutL[k]
                    right[right.count - overlap + k] += cutR[k]
                }
                left += cutL[overlap...]
                right += cutR[overlap...]
            } else {
                if !left.isEmpty {
                    left += repeatElement(0, count: gap)
                    right += repeatElement(0, count: gap)
                }
                left += cutL
                right += cutR
            }
        }
        // As loud as can be without clipping.
        let peak = zip(left, right).reduce(Float(0)) { max($0, abs($1.0), abs($1.1)) }
        if peak > 0.001 {
            let gain = 0.9 / peak
            left = left.map { $0 * gain }
            right = right.map { $0 * gain }
        }
        return (left, right)
    }

    /// The clip's words among those heard near where the lyrics put them,
    /// in song time; a piece of a word gets its part of the heard word.
    private static func located(_ clip: VoiceClip, in excerpt: VoiceExcerpt, avoiding: Set<Int>) -> (start: TimeInterval, end: TimeInterval, indices: [Int])? {
        let heard = excerpt.heard
        guard !heard.isEmpty, let firstKey = clip.keys.first else { return nil }
        let tolerance = clip.precise ? 0.7 : 1.6
        let expected = clip.part == nil ? clip.start : clip.start - (clip.end - clip.start) * (clip.part!.0 / max(0.01, clip.part!.1 - clip.part!.0))
        var best: (score: Double, start: TimeInterval, end: TimeInterval, indices: [Int])?
        for (index, word) in heard.enumerated() where !avoiding.contains(index) && matches(word.key, firstKey) {
            let start = word.start + excerpt.start
            let distance = abs(start - expected)
            guard distance < tolerance else { continue }
            // The rest of the words, in a row after it.
            var indices = [index]
            var next = index + 1
            var missed = 0
            for key in clip.keys.dropFirst() {
                if next < heard.count, matches(heard[next].key, key) {
                    indices.append(next)
                    next += 1
                } else if next + 1 < heard.count, matches(heard[next + 1].key, key) {
                    indices.append(next + 1)
                    next += 2
                } else {
                    missed += 1
                }
            }
            guard missed * 3 <= clip.keys.count else { continue }
            var end = heard[indices.last!].end + excerpt.start
            if missed > 0, clip.keys.count > 1 { end = max(end, clip.end) }
            let score = distance + Double(missed) * 0.5 + (word.key == firstKey ? 0 : 0.3)
            if best == nil || score < best!.score { best = (score, start, end, indices) }
        }
        guard var found = best else { return nil }
        if let part = clip.part {
            let span = found.end - found.start
            (found.start, found.end) = (found.start + span * part.0, found.start + span * part.1)
            return (found.start - 0.01, found.end + 0.01, found.indices)
        }
        return (found.start - 0.05, found.end + 0.07, found.indices)
    }

    private static func matches(_ heard: String, _ key: String) -> Bool {
        if heard == key { return true }
        guard min(heard.count, key.count) >= 3 else { return false }
        if heard.hasPrefix(key) || key.hasPrefix(heard) { return true }
        return key.count >= 4 && distance(Array(heard), Array(key)) <= (key.count >= 7 ? 2 : 1)
    }

    private static func distance(_ a: [Character], _ b: [Character]) -> Int {
        var row = Array(0...b.count)
        for i in 1...max(1, a.count) where !a.isEmpty {
            var previous = row[0]
            row[0] = i
            for j in 1...max(1, b.count) where !b.isEmpty {
                let current = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, previous + (a[i - 1] == b[j - 1] ? 0 : 1))
                previous = current
            }
        }
        return row[b.count]
    }

    /// Only the silence at the edges taken off, nothing sung.
    private static func tightened(_ track: StageTrack, _ from: Int, _ to: Int) -> (Int, Int) {
        let hop = 220
        func level(_ at: Int) -> Float {
            var energy: Float = 0
            for i in at..<min(to, at + hop) {
                let mono = (track.vocalsLeft[i] + track.vocalsRight[i]) / 2
                energy += mono * mono
            }
            return (energy / Float(hop)).squareRoot()
        }
        guard to - from > hop * 6 else { return (from, to) }
        var newFrom = from
        while newFrom + hop * 4 < to, level(newFrom) < 0.006 { newFrom += hop }
        var newTo = to
        while newTo - hop * 4 > newFrom, level(newTo - hop) < 0.006 { newTo -= hop }
        return (max(from, newFrom - hop), min(to, newTo + hop))
    }

    /// Tightened to where the voice is heard, never by more than a third
    /// on either side.
    private static func trimmed(_ track: StageTrack, _ from: Int, _ to: Int) -> (Int, Int) {
        let hop = 220
        var envelope: [Float] = []
        var start = from
        while start + hop <= to {
            var energy: Float = 0
            for i in start..<(start + hop) {
                let mono = (track.vocalsLeft[i] + track.vocalsRight[i]) / 2
                energy += mono * mono
            }
            envelope.append((energy / Float(hop)).squareRoot())
            start += hop
        }
        guard let peak = envelope.max(), peak > 0.005 else { return (from, to) }
        let threshold = max(0.008, peak * 0.12)
        guard let first = envelope.firstIndex(where: { $0 > threshold }),
              let last = envelope.lastIndex(where: { $0 > threshold }) else { return (from, to) }
        let length = to - from
        let newFrom = min(from + max(0, first - 3) * hop, from + length / 3)
        let newTo = max(min(to, from + (last + 4) * hop), to - length / 3)
        return newTo > newFrom ? (newFrom, newTo) : (from, to)
    }
}

/// Builds the library, finds the cuts, gathers them and plays the result.
@MainActor
final class SongVoiceModel: ObservableObject {
    @Published private(set) var library: VoiceLibrary?
    @Published private(set) var status: String?
    @Published private(set) var phrases: [VoicePhrase] = []
    @Published private(set) var isBusy = false
    @Published private(set) var isPlaying = false

    private var libraryKey: String?
    private var buildJob: Task<Void, Never>?
    private var job: Task<Void, Never>?
    private var stage: PlaygroundStage?
    private var timer: Timer?
    private var resumesPlayer = false

    func prepare(songs: [Song]) {
        let key = "\(songs.count)-\(songs.first?.id.uuidString ?? "")-\(songs.last?.id.uuidString ?? "")"
        guard key != libraryKey || (library == nil && buildJob == nil) else { return }
        libraryKey = key
        library = nil
        phrases = []
        buildJob?.cancel()
        buildJob = nil
        guard !songs.isEmpty else {
            status = nil
            return
        }
        status = String(localized: "Reading the lyrics…")
        let service = AppModel.shared.libraryService
        let sources = songs.compactMap { song in service.resolvedLyricsURL(for: song).map { (song: song, lyrics: $0) } }
        buildJob = Task {
            let library = await Task.detached(priority: .userInitiated) { VoiceLibrary.build(sources) }.value
            guard !Task.isCancelled, libraryKey == key else { return }
            buildJob = nil
            self.library = library
            status = library.isEmpty ? String(localized: "No synced lyrics to take words from.") : nil
        }
    }

    func sing(_ text: String, withMusic: Bool) {
        guard let library else { return }
        job?.cancel()
        stopPlayback()
        isBusy = true
        status = String(localized: "Finding the words…")
        let separates = SingAlongModel.shared.isInstalled
        job = Task {
            defer { if !Task.isCancelled { isBusy = false } }
            let plan = await Task.detached(priority: .userInitiated) { library.plan(text) }.value
            guard !Task.isCancelled else { return }
            withAnimation(.smooth) { phrases = plan.phrases }
            guard !plan.clips.isEmpty else {
                status = String(localized: "None of these sounds are in the songs.")
                return
            }
            let samples = await gather(plan.clips, songs: library.songs, withMusic: withMusic, separates: separates)
            guard !Task.isCancelled else { return }
            guard let samples, !samples.0.isEmpty else {
                status = String(localized: "The songs couldn't be read.")
                return
            }
            status = nil
            play(samples.0, samples.1)
        }
    }

    /// Decodes the songs around the cuts (close cuts together) and
    /// separates the voice there: from what Sing Along kept, or now.
    private func gather(_ clips: [VoiceClip], songs: [Song], withMusic: Bool, separates: Bool) async -> ([Float], [Float])? {
        var windows: [(song: Int, start: TimeInterval, end: TimeInterval)] = []
        var windowOf = [Int](repeating: 0, count: clips.count)
        for index in clips.indices.sorted(by: { (clips[$0].song, clips[$0].start) < (clips[$1].song, clips[$1].start) }) {
            let clip = clips[index]
            if let last = windows.last, last.song == clip.song, clip.start - last.end < 2, clip.end - last.start < 25 {
                windows[windows.count - 1].end = max(last.end, clip.end)
            } else {
                windows.append((clip.song, clip.start, clip.end))
            }
            windowOf[index] = windows.count - 1
        }
        var excerpts: [Int: VoiceExcerpt] = [:]
        let listens = separates ? await VoiceListener.authorize() : false
        var locales: [Int: Locale] = [:]
        for (index, window) in windows.enumerated() {
            let locale = locales[window.song] ?? VoiceListener.locale(for: library?.lines.filter { $0.song == window.song }.prefix(40)
                .map { $0.words.map(\.key).joined(separator: " ") }.joined(separator: ". ") ?? "")
            locales[window.song] = locale
            status = windows.count > 1 ? String(localized: "Gathering the voice… \(index + 1)/\(windows.count)") : String(localized: "Gathering the voice…")
            let song = songs[window.song]
            let url = song.isMediaLibraryItem ? song.fileURL : song.playableFileURL
            let start = max(0, window.start - 1.5)
            let range = start...(window.end + 1.5)
            let id = song.id
            let excerpt = await Task.detached(priority: .userInitiated) { () -> VoiceExcerpt? in
                guard let track = await StageTrack.load(url, range: range) else { return nil }
                var hasVocals = false
                if separates {
                    hasVocals = VocalsCache.excerpt(id, from: Int(start * StageTrack.sampleRate), into: track)
                    if !hasVocals, !Task.isCancelled { hasVocals = await VocalSeparator.separateExcerpt(track) }
                }
                var excerpt = VoiceExcerpt(track: track, start: start, hasVocals: hasVocals)
                if hasVocals, listens, !Task.isCancelled { excerpt.heard = await VoiceListener.words(in: track, locale: locale) }
                return excerpt
            }.value
            if Task.isCancelled { return nil }
            excerpts[index] = excerpt
        }
        status = String(localized: "Putting it together…")
        let assembled = windowOf
        return await Task.detached(priority: .userInitiated) {
            SongVoice.assemble(clips, windows: assembled, excerpts: excerpts, withMusic: withMusic)
        }.value
    }

    func replay() {
        guard let stage else { return }
        stage.seek(to: 0)
        start()
    }

    var canReplay: Bool { stage != nil && !isBusy }

    private func play(_ left: [Float], _ right: [Float]) {
        stage?.stop()
        stage = PlaygroundStage(left: left, right: right)
        start()
    }

    private func start() {
        let player = AppModel.shared.playerVM
        if player.isPlaying {
            resumesPlayer = true
            player.togglePlayPause()
        }
        try? AVAudioSession.sharedInstance().setActive(true)
        stage?.play()
        isPlaying = true
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func update() {
        guard let stage, stage.isPlaying else {
            stage?.pause()
            isPlaying = false
            timer?.invalidate()
            timer = nil
            return
        }
    }

    private func stopPlayback() {
        stage?.stop()
        stage = nil
        timer?.invalidate()
        timer = nil
        isPlaying = false
    }

    /// Leaving: everything stops, and the music comes back if it was playing.
    func close() {
        job?.cancel()
        job = nil
        isBusy = false
        stopPlayback()
        if resumesPlayer {
            resumesPlayer = false
            AppModel.shared.playerVM.togglePlayPause()
        }
    }
}

/// Type a sentence, the singer sings it: runs of words and whole words cut
/// from the songs, other words pieced together from syllables.
private struct SongVoiceView: View {
    let songs: [Song]

    @StateObject private var model = SongVoiceModel()
    @ObservedObject private var separator = SingAlongModel.shared
    @AppStorage("songVoiceAllSongs") private var allSongs = false
    @State private var songID: UUID?
    @State private var text = ""
    @State private var withMusic = false
    @FocusState private var isTyping: Bool

    private var song: Song? { songs.first { $0.id == songID } }
    private var sources: [Song] { allSongs ? songs : song.map { [$0] } ?? [] }
    /// Without the model, the words come with their music.
    private var keepsMusic: Bool { withMusic || !separator.isInstalled }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Picker("Voice", selection: $allSongs) {
                    Text("One Song").tag(false)
                    Text("All Songs").tag(true)
                }
                .pickerStyle(.segmented)

                if allSongs {
                    Text("The best bits of \(songs.count) songs with synced lyrics.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    NavigationLink {
                        PlaygroundSongPicker(songs: songs) { songID = $0.id }
                    } label: {
                        HStack(spacing: 12) {
                            if let song {
                                ArtworkImage(source: song.artworkSource, points: 48)
                                    .frame(width: 48, height: 48)
                                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(song.title).font(.headline).foregroundStyle(.primary)
                                    Text(song.artist).font(.subheadline).foregroundStyle(.secondary)
                                }
                                .lineLimit(1)
                            } else {
                                Text("Choose a Song").font(.headline)
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 18))
                }

                TextField("What should they sing?", text: $text, axis: .vertical)
                    .lineLimit(2...6)
                    .focused($isTyping)
                    .padding(14)
                    .glassEffect(.regular, in: .rect(cornerRadius: 18))

                VStack(alignment: .leading, spacing: 4) {
                    Toggle("With the Music", isOn: $withMusic)
                        .disabled(!separator.isInstalled)
                    Text(separator.isInstalled ? "Off, it's the voice alone." : "The voice alone needs the Sing Along model, in Settings.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 10) {
                    Button {
                        isTyping = false
                        model.sing(text, withMusic: keepsMusic)
                    } label: {
                        Label("Sing It", systemImage: "waveform")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(model.library?.isEmpty != false || SongVoice.key(text).isEmpty || model.isBusy)

                    if model.canReplay {
                        Button { model.replay() } label: {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 17, weight: .semibold))
                                .frame(width: 50, height: 50)
                        }
                        .buttonStyle(.glass)
                        .buttonBorderShape(.circle)
                        .accessibilityLabel("Play Again")
                    }
                }

                if let status = model.status {
                    HStack(spacing: 8) {
                        if model.isBusy || model.library == nil { ProgressView().controlSize(.small) }
                        Text(status).monospacedDigit()
                    }
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
                }

                if !model.phrases.isEmpty {
                    PlaygroundFlow(spacing: 8) {
                        ForEach(model.phrases) { phrase in
                            phraseChip(phrase)
                        }
                    }
                    Text("Highlighted words are sung as is; the others are pieced together from syllables of other words.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Song Voice")
        .onAppear { model.prepare(songs: sources) }
        .onChange(of: allSongs) { model.prepare(songs: sources) }
        .onChange(of: songID) { model.prepare(songs: sources) }
        .onDisappear { model.close() }
    }

    private func phraseChip(_ phrase: VoicePhrase) -> some View {
        VStack(spacing: 3) {
            HStack(spacing: 2) {
                if phrase.isWhole {
                    Text(phrase.text)
                } else {
                    ForEach(Array(phrase.pieces.enumerated()), id: \.offset) { index, piece in
                        if index > 0 { Text("·").foregroundStyle(.tertiary) }
                        Text(piece.text)
                            .strikethrough(!piece.found)
                            .foregroundStyle(piece.found ? .primary : .tertiary)
                    }
                }
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .glassEffect(phrase.isWhole ? .regular.tint(.accentColor.opacity(0.6)) : .regular, in: .capsule)
            if allSongs, let source = phrase.source {
                Text(source)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: 140)
            }
        }
    }
}

/// The songs, most played first, searchable (Song Voice's picker).
private struct PlaygroundSongList: View {
    let songs: [Song]
    let onPick: (Song) -> Void

    @State private var query = ""

    private var results: [Song] {
        let sorted = songs.sorted {
            $0.playCount != $1.playCount ? $0.playCount > $1.playCount : $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return sorted }
        return sorted.filter { $0.title.localizedStandardContains(text) || $0.artist.localizedStandardContains(text) }
    }

    var body: some View {
        List(results) { song in
            Button { onPick(song) } label: {
                HStack(spacing: 12) {
                    ArtworkImage(source: song.artworkSource, points: 48)
                        .frame(width: 48, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(song.title).foregroundStyle(.primary)
                        Text(song.artist).font(.subheadline).foregroundStyle(.secondary)
                    }
                    .lineLimit(1)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .listStyle(.plain)
        .scrollDismissesKeyboard(.immediately)
        .overlay {
            if results.isEmpty, !query.isEmpty { ContentUnavailableView.search(text: query) }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Songs and Artists")
    }
}

private struct PlaygroundSongPicker: View {
    let songs: [Song]
    let onPick: (Song) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        PlaygroundSongList(songs: songs) { song in
            onPick(song)
            dismiss()
        }
        .navigationTitle("Choose a Song")
    }
}

/// Lines of chips, wrapping.
private struct PlaygroundFlow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                y += line + spacing
                x = 0
                line = 0
            }
            x += size.width + spacing
            line = max(line, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(width, widest), height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += line + spacing
                x = bounds.minX
                line = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}
