import AVFoundation
import SwiftUI
import UIKit

enum WhatSongDifficulty: String, CaseIterable, Equatable {
    case easy
    case medium
    case hard

    var title: String {
        switch self {
        case .easy: return String(localized: "Easy")
        case .medium: return String(localized: "Medium")
        case .hard: return String(localized: "Hard")
        }
    }
}

struct WhatSongSession: Identifiable, Equatable {
    let id = UUID()
    let songs: [Song]
    let snippetDuration: TimeInterval
    let difficulty: WhatSongDifficulty
}

@MainActor
final class WhatSongGame: ObservableObject {
    @Published var currentSong: Song?
    @Published var choices: [Song] = []
    @Published var selectedChoice: Song?
    @Published var isCorrect: Bool = false
    @Published var score: Int = 0
    @Published var roundIndex: Int = 0
    @Published var totalRounds: Int = 0
    @Published var isGameOver: Bool = false
    @Published private(set) var isPaused = false
    /// Best number of right answers, kept across games.
    var bestScore: Int { UserDefaults.standard.integer(forKey: "whatSongBestScore") }
    /// Rounds answered so far: an ended game counts only those.
    var answeredRounds: Int { roundIndex - (selectedChoice == nil && !isGameOver ? 1 : 0) }
    @Published var isReady: Bool = false
    @Published var isPlaying: Bool = false

    let snippetDuration: TimeInterval
    let difficulty: WhatSongDifficulty

    private let playableSongs: [Song]
    private var usedSongIDs: Set<UUID> = []
    private var audioPlayer: AVPlayer?
    private var timeObserver: Any?
    /// Start of the current round's snippet, so "Replay" plays the same excerpt.
    private var clipStart: TimeInterval = 0
    private var hasStarted = false

    init(songs: [Song], snippetDuration: TimeInterval, difficulty: WhatSongDifficulty) {
        self.snippetDuration = snippetDuration
        self.difficulty = difficulty
        self.playableSongs = songs.filter { $0.isExcerptPlayable }
        self.totalRounds = min(self.playableSongs.count, 20)
    }

    /// Starts the first round. Called from `onAppear`, after the main player has
    /// been paused, so the snippet never overlaps the user's music.
    func start() {
        if hasStarted {
            // onDisappear/onAppear during the presentation: resume the round.
            if !isReady, !isGameOver { loadNextQuestion() }
            return
        }
        hasStarted = true
        loadNextQuestion()
    }

    func selectChoice(_ choice: Song) {
        guard let currentSong, selectedChoice == nil else { return }
        selectedChoice = choice
        isCorrect = choice.id == currentSong.id
        if isCorrect { score += 1 }
        // Let the player hear the answer again if the snippet already ended;
        // it then loops until the next round.
        if !isPlaying { playExcerpt(from: currentSong) }
    }

    func advance() {
        guard let currentSong else { return }
        usedSongIDs.insert(currentSong.id)
        if usedSongIDs.count >= totalRounds {
            finishGame()
            stopAudio()
            return
        }
        loadNextQuestion()
    }

    func pause() {
        guard isReady, !isGameOver, !isPaused else { return }
        stopAudio()
        isPaused = true
    }

    func resume() {
        guard isPaused else { return }
        isPaused = false
        if let currentSong { playExcerpt(from: currentSong) }
    }

    /// Stops here and shows the score so far.
    func end() {
        stop()
        isPaused = false
        finishGame()
    }

    /// Saves the best score once the game is over.
    private func finishGame() {
        isGameOver = true
        UserDefaults.standard.set(max(bestScore, score), forKey: "whatSongBestScore")
    }

    func stop() {
        stopAudio()
    }

    func replayCurrentSong() {
        guard let currentSong, selectedChoice == nil else { return }
        playExcerpt(from: currentSong)
    }

    private func loadNextQuestion() {
        guard !playableSongs.isEmpty else {
            finishGame()
            return
        }
        let unused = playableSongs.filter { !usedSongIDs.contains($0.id) }
        guard let song = unused.randomElement() ?? playableSongs.randomElement() else { return }
        currentSong = song
        roundIndex = usedSongIDs.count + 1
        selectedChoice = nil
        isCorrect = false
        buildChoices(for: song)
        let duration = min(snippetDuration, song.duration)
        let maxStart = max(0, song.duration - duration)
        clipStart = maxStart > 0 ? Double.random(in: 0...maxStart) : 0
        isReady = true
        playExcerpt(from: song)
    }

    private func buildChoices(for correct: Song) {
        let total: Int = difficulty == .hard ? 4 : 3
        let distractorCount = total - 1
        let pool = playableSongs.filter { $0.id != correct.id }
        var distractors: [Song] = []

        switch difficulty {
        case .easy:
            distractors = Array(pool.shuffled().prefix(distractorCount))
        case .medium:
            distractors = sameArtistDistractors(for: correct, from: pool, count: distractorCount)
        case .hard:
            distractors = hardDistractors(for: correct, from: pool, count: distractorCount)
        }

        choices = ([correct] + distractors).shuffled()
    }

    private func sameArtistDistractors(for correct: Song, from pool: [Song], count: Int) -> [Song] {
        var distractors: [Song] = []
        let sameArtist = pool.filter { LibraryIndex.artistName(for: $0) == LibraryIndex.artistName(for: correct) }
        var candidates = Array((sameArtist.isEmpty ? pool : sameArtist).shuffled())
        while distractors.count < count, !candidates.isEmpty {
            distractors.append(candidates.removeFirst())
        }
        if distractors.count < count {
            let remaining = pool.filter { d in !distractors.contains { $0.id == d.id } }
            distractors.append(contentsOf: remaining.shuffled().prefix(count - distractors.count))
        }
        return distractors
    }

    private func hardDistractors(for correct: Song, from pool: [Song], count: Int) -> [Song] {
        var distractors: [Song] = []
        func appendUnique(_ candidates: [Song]) {
            for song in candidates.shuffled() where distractors.count < count {
                if !distractors.contains(where: { $0.id == song.id }) {
                    distractors.append(song)
                }
            }
        }
        appendUnique(pool.filter { $0.album == correct.album })
        if distractors.count < count {
            appendUnique(pool.filter { LibraryIndex.artistName(for: $0) == LibraryIndex.artistName(for: correct) && $0.year == correct.year })
        }
        if distractors.count < count {
            appendUnique(pool.filter { LibraryIndex.artistName(for: $0) == LibraryIndex.artistName(for: correct) })
        }
        if distractors.count < count {
            appendUnique(pool)
        }
        return distractors
    }

    private func playExcerpt(from song: Song) {
        stopAudio()
        guard song.duration > 0 else { return }

        let player = AVPlayer(url: song.excerptURL)
        let safeStart = clipStart
        let startTime = CMTime(seconds: safeStart, preferredTimescale: 600)
        let clipEnd = CMTime(seconds: safeStart + min(snippetDuration, song.duration), preferredTimescale: 600)

        timeObserver = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: clipEnd)],
            queue: .main
        ) { [weak self, weak player] in
            MainActor.assumeIsolated {
                guard let self, let player, self.audioPlayer === player else { return }
                if self.selectedChoice != nil {
                    // Answer revealed: keep looping the snippet.
                    self.seekAndPlay(player, to: startTime)
                } else {
                    player.pause()
                    self.isPlaying = false
                    self.removeObserver()
                }
            }
        }
        audioPlayer = player
        isPlaying = true
        seekAndPlay(player, to: startTime)
    }

    private func seekAndPlay(_ player: AVPlayer, to time: CMTime) {
        player.seek(to: time) { [weak self] finished in
            Task { @MainActor [weak self] in
                guard finished, let self, self.audioPlayer === player else { return }
                player.play()
            }
        }
    }

    private func stopAudio() {
        removeObserver()
        audioPlayer?.pause()
        audioPlayer = nil
        isPlaying = false
    }

    private func removeObserver() {
        if let obs = timeObserver {
            audioPlayer?.removeTimeObserver(obs)
            timeObserver = nil
        }
    }
}

struct WhatSongIsThatGameView: View {
    let session: WhatSongSession
    let onDismiss: () -> Void

    @StateObject private var game: WhatSongGame
    @ObservedObject var playerVM: PlayerViewModel
    @State private var backgroundPalette: [Color] = [
        Color(red: 0.10, green: 0.10, blue: 0.12),
        Color(red: 0.07, green: 0.07, blue: 0.09),
        Color(red: 0.04, green: 0.04, blue: 0.05)
    ]
    @State private var resumePlaybackOnExit = false

    init(session: WhatSongSession, playerVM: PlayerViewModel, onDismiss: @escaping () -> Void) {
        self.session = session
        self.playerVM = playerVM
        self.onDismiss = onDismiss
        _game = StateObject(wrappedValue: WhatSongGame(
            songs: session.songs,
            snippetDuration: session.snippetDuration,
            difficulty: session.difficulty
        ))
    }

    var body: some View {
        ZStack {
            backgroundLayer
            content
            if game.isPaused {
                GamePauseOverlay(onResume: { game.resume() }, onEnd: { game.end() })
            }
        }
        .animation(.smooth(duration: 0.3), value: game.isPaused)
        .animation(.smooth(duration: 0.35), value: game.isGameOver)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            game.pause()
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .onAppear {
            resumePlaybackOnExit = playerVM.isPlaying
            if resumePlaybackOnExit { playerVM.togglePlayPause() }
            updatePalette()
            game.start()
        }
        .onChange(of: game.currentSong?.id) { _, _ in updatePalette() }
        .onChange(of: game.selectedChoice?.id) { _, _ in updatePalette() }
        .onDisappear {
            game.stop()
            if resumePlaybackOnExit { playerVM.togglePlayPause() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if game.isGameOver {
            gameOverView
        } else if game.isReady, let song = game.currentSong {
            questionView(song: song)
        } else {
            ZStack(alignment: .topLeading) {
                ProgressView()
                    .tint(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                gameHeader
            }
        }
    }

    private func questionView(song: Song) -> some View {
        VStack(spacing: 0) {
            gameHeader

            Spacer()

            VStack(spacing: 10) {
                coverSquare(for: song)

                VStack(spacing: 3) {
                    if game.selectedChoice != nil {
                        if game.isCorrect {
                            Text("Correct!")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.green)
                        } else {
                            Text("Nope — \(song.title) by \(song.artist)")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.white.opacity(0.6))
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                        }
                    } else {
                        Text("What song is that?")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                }
                .padding(.top, 6)
            }
            .padding(.top, 24)

            Spacer()

            Button {
                game.replayCurrentSong()
            } label: {
                Label("Replay", systemImage: "arrow.clockwise")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.75))
            }
            .padding(.bottom, 14)
            .opacity(canReplay ? 1 : 0)
            .disabled(!canReplay)
            .accessibilityHidden(!canReplay)

            VStack(spacing: 10) {
                ForEach(game.choices) { choice in
                    choiceButton(choice)
                }
            }
            .padding(.horizontal, 20)

            Spacer()

            Button {
                withAnimation(.easeInOut(duration: 0.25)) {
                    game.advance()
                }
            } label: {
                Text("Next")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
            }
            .buttonStyle(.glass)
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
            .disabled(game.selectedChoice == nil)
            .opacity(game.selectedChoice != nil ? 1 : 0)
        }
        .animation(.easeInOut(duration: 0.25), value: game.selectedChoice?.id)
        .animation(.easeInOut(duration: 0.3), value: game.currentSong?.id)
    }

    private var canReplay: Bool {
        game.selectedChoice == nil && !game.isPlaying
    }

    private var gameHeader: some View {
        HStack {
            if game.isReady {
                GamePauseButton { game.pause() }
            } else {
                Button { finish() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 44, height: 44)
                    .glassEffect(.regular.interactive(true), in: Circle())
            }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 3) {
                Text("What Song is That?")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                Text(game.difficulty.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                Text("Round \(game.roundIndex) of \(game.totalRounds) · \(game.score) pts")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }

    private func coverSquare(for song: Song) -> some View {
        Group {
            if game.selectedChoice != nil, let artwork = song.artwork {
                artwork
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 200, height: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
            } else {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white.opacity(0.12))
                    .frame(width: 200, height: 200)
                    .overlay {
                        Text("?")
                            .font(.system(size: 104, weight: .bold))
                            .foregroundStyle(.white)
                    }
            }
        }
    }

    @ViewBuilder
    private func choiceButton(_ choice: Song) -> some View {
        let isSelected = game.selectedChoice?.id == choice.id
        let isCorrectChoice = game.currentSong?.id == choice.id
        let revealed = game.selectedChoice != nil
        let dimmed = revealed && !isCorrectChoice && !isSelected

        Button {
            game.selectChoice(choice)
        } label: {
            HStack(spacing: 14) {
                Group {
                    if let artwork = choice.artwork {
                        artwork
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.white.opacity(0.12))
                            .overlay {
                                Image(systemName: "music.note")
                                    .font(.system(size: 20, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.6))
                            }
                    }
                }
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .opacity(dimmed ? 0.35 : 1)

                VStack(alignment: .leading, spacing: 3) {
                    Text(choice.title)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(choiceTextColor(revealed: revealed, selected: isSelected, correct: isCorrectChoice))
                        .lineLimit(1)
                    Text(choice.artist)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
                .opacity(dimmed ? 0.4 : 1)

                Spacer()

                Image(systemName: isCorrectChoice ? "checkmark" : "xmark")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(isCorrectChoice ? .green : .red)
                    .opacity(revealed ? (isCorrectChoice || isSelected ? 1 : 0) : 0)
                    .frame(width: 20)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(choiceBackgroundFill(revealed: revealed, selected: isSelected, correct: isCorrectChoice))
                    .glassEffect(.regular.interactive(!revealed), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            )
        }
        .disabled(game.selectedChoice != nil)
    }

    private func choiceTextColor(revealed: Bool, selected: Bool, correct: Bool) -> Color {
        if !revealed { return .white }
        if correct { return .green }
        if selected { return .red }
        return .white.opacity(0.4)
    }

    private func choiceBackgroundFill(revealed: Bool, selected: Bool, correct: Bool) -> some ShapeStyle {
        if revealed && correct { return Color.green.opacity(0.22) }
        if revealed && selected { return Color.red.opacity(0.22) }
        return Color.white.opacity(0.1)
    }

    private var gameOverView: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "headphones")
                .font(.system(size: 52, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))

            VStack(spacing: 6) {
                Text("Game Over")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.white)
                Text("\(game.score) / \(game.answeredRounds) correct")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                Text("Best \(game.bestScore)")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.45))
            }

            Spacer()

            Button { finish() } label: {
                Text("Done")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
            }
            .buttonStyle(.glassProminent)
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
        }
    }

    private var backgroundLayer: some View {
        ZStack {
            LinearGradient(
                colors: [
                    backgroundPalette[safe: 0] ?? Song.fallbackArtworkColors[0],
                    backgroundPalette[safe: 1] ?? Song.fallbackArtworkColors[1],
                    backgroundPalette[safe: 2] ?? Song.fallbackArtworkColors[2]
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .saturation(game.selectedChoice == nil ? 0.55 : 1.38)

            Rectangle()
                .fill(.ultraThinMaterial)
                .opacity(game.selectedChoice == nil ? 0.3 : 1)

            LinearGradient(
                colors: [
                    Color.black.opacity(0.08),
                    Color(UIColor.systemBackground).opacity(0.24),
                    Color(UIColor.systemBackground).opacity(0.64)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .animation(.easeInOut(duration: 0.45), value: game.currentSong?.id)
        .animation(.easeInOut(duration: 0.45), value: game.selectedChoice?.id)
    }

    private func updatePalette() {
        let colors: [Color] = game.selectedChoice == nil
            ? [
                Color(red: 0.10, green: 0.10, blue: 0.12),
                Color(red: 0.07, green: 0.07, blue: 0.09),
                Color(red: 0.04, green: 0.04, blue: 0.05)
            ]
            : (game.currentSong?.playerArtworkColors ?? Song.fallbackArtworkColors)
        withAnimation(.easeInOut(duration: 0.45)) {
            backgroundPalette = colors
        }
    }

    private func finish() {
        game.stop()
        onDismiss()
    }
}

extension Song {
    /// Can be heard in a game: a file on disk, or a server song, streamed.
    var isExcerptPlayable: Bool {
        hasDecodableAudio || (isRemote && remoteID != nil)
    }

    /// Where a game's excerpt plays from: the file, or the server's stream.
    @MainActor var excerptURL: URL {
        guard isRemote, !isDownloaded else { return playableFileURL }
        return SubsonicService.shared.streamURL(for: self) ?? playableFileURL
    }

    /// A file on disk, read whole (Music Tiles, the Playground): a streamed
    /// song doesn't qualify.
    var hasDecodableAudio: Bool {
        // Media-library items without an exportable asset (e.g. DRM / cloud-only
        // tracks) are stored with a placeholder `media-library://` URL that
        // AVPlayer cannot open: games would play silence for them.
        if isMediaLibraryItem { return fileURL.scheme != "media-library" }
        let url = playableFileURL
        return url.isFileURL && FileManager.default.fileExists(atPath: url.path)
    }
}

// MARK: - Who Sings This?

struct WhoSingsSession: Identifiable, Equatable {
    let id = UUID()
    let songs: [Song]
    let difficulty: WhatSongDifficulty
}

enum WhoSingsSettings {
    static let difficultyKey = "whoSingsDifficulty"
    static let minimumArtists = 4

    static func savedDifficulty() -> WhatSongDifficulty {
        UserDefaults.standard.string(forKey: difficultyKey).flatMap(WhatSongDifficulty.init(rawValue:)) ?? .medium
    }

    static func artistCount(_ songs: [Song]) -> Int {
        Set(songs.map(LibraryIndex.artistName(for:))).count
    }

    /// Easy: two lines; harder: one line and more artists to pick from.
    static func lineCount(_ difficulty: WhatSongDifficulty) -> Int { difficulty == .easy ? 2 : 1 }
    static func choiceCount(_ difficulty: WhatSongDifficulty) -> Int {
        switch difficulty {
        case .easy, .medium: 4
        case .hard: 6
        }
    }
}

@MainActor
final class WhoSingsGame: ObservableObject {
    struct Question {
        let song: Song
        let artist: String
        let lines: [String]
        /// Lyrics time (offset included) of the first line shown.
        let time: TimeInterval?
        let offset: TimeInterval
        /// Synced lyrics from the lines shown onwards: they keep coming in
        /// while the answer plays.
        let flow: [Entry]
    }

    struct Entry {
        let text: String
        let time: TimeInterval
        /// Words as written and when each is sung; empty without word sync.
        let words: [String]
        let timings: [WordTiming]
    }

    /// Where the answer is, on the lyrics clock; nil when nothing plays.
    func lyricsTime() -> TimeInterval? {
        guard selected != nil, let audio, let question else { return nil }
        let t = audio.currentTime().seconds
        return t.isFinite ? t + question.offset : nil
    }

    @Published private(set) var question: Question?
    @Published private(set) var choices: [String] = []
    @Published private(set) var selected: String?
    @Published private(set) var score = 0
    @Published private(set) var roundIndex = 0
    @Published private(set) var isGameOver = false
    @Published private(set) var isPaused = false

    let difficulty: WhatSongDifficulty
    let totalRounds: Int
    var bestScore: Int { UserDefaults.standard.integer(forKey: "whoSingsBestScore.\(difficulty.rawValue)") }
    var isCorrect: Bool { selected != nil && selected == question?.artist }
    var answeredRounds: Int { roundIndex - (selected == nil && !isGameOver ? 1 : 0) }

    private let songs: [Song]
    let artistsByName: [String: [Song]]
    private var used: Set<UUID> = []
    private var audio: AVPlayer?
    private var started = false

    init(songs: [Song], difficulty: WhatSongDifficulty) {
        self.songs = songs
        self.difficulty = difficulty
        artistsByName = Dictionary(grouping: songs, by: LibraryIndex.artistName(for:))
        totalRounds = min(songs.count, 20)
    }

    func start() {
        guard !started else { return }
        started = true
        next()
    }

    func select(_ artist: String) {
        guard selected == nil, let question else { return }
        selected = artist
        if artist == question.artist { score += 1 }
        playReveal()
    }

    func next() {
        stopAudio()
        guard roundIndex < totalRounds else { return finish() }
        // A few tries: some songs have nothing usable (all short lines).
        for _ in 0..<12 {
            let pool = songs.filter { !used.contains($0.id) }
            guard let song = pool.randomElement() else { break }
            used.insert(song.id)
            if let q = Self.makeQuestion(song: song, lines: WhoSingsSettings.lineCount(difficulty)) {
                question = q
                choices = buildChoices(for: q)
                selected = nil
                roundIndex += 1
                return
            }
        }
        finish()
    }

    func pause() {
        guard question != nil, !isGameOver, !isPaused else { return }
        audio?.pause()
        isPaused = true
    }

    func resume() {
        guard isPaused else { return }
        isPaused = false
        if selected != nil { audio?.play() }
    }

    func end() {
        stopAudio()
        isPaused = false
        finish()
    }

    func stop() { stopAudio() }

    private func finish() {
        stopAudio()
        isGameOver = true
        UserDefaults.standard.set(max(bestScore, score), forKey: "whoSingsBestScore.\(difficulty.rawValue)")
    }

    private func buildChoices(for q: Question) -> [String] {
        let count = WhoSingsSettings.choiceCount(difficulty) - 1
        let others = artistsByName.keys.filter { $0 != q.artist }
        var picked: [String] = []
        if difficulty == .hard {
            // Same genre first: harder to tell apart.
            let genre = q.song.genre.lowercased()
            if !genre.isEmpty {
                picked = Array(others.filter { name in artistsByName[name]?.contains { $0.genre.lowercased() == genre } == true }.shuffled().prefix(count))
            }
        }
        picked += others.filter { !picked.contains($0) }.shuffled().prefix(count - picked.count)
        return ([q.artist] + picked).shuffled()
    }

    nonisolated private static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: #"\[[^\]]*\]|<[^>]*>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Lines long enough to say something, without the artist's own name.
    private static func makeQuestion(song: Song, lines count: Int) -> Question? {
        guard let url = song.resolvedLyricsFileURL(), let parsed = LRCParser.parse(url: url) else { return nil }
        // From the real start, the outro (talk after the song) left out.
        let (lyrics, wordSync) = LyricsMarks.forGames(parsed, songID: song.id)
        let artist = LibraryIndex.artistName(for: song)
        let timed = lyrics.lines.filter { !$0.isInstrumentalGap }.sorted { $0.time < $1.time }
        let flow: [Entry] = timed.compactMap { line in
            let text = clean(line.text)
            guard !text.isEmpty else { return nil }
            let timings = wordSync[line.id] ?? []
            let words = timings.isEmpty ? [] : LyricWords.ranges(in: line.text).map { String(line.text[$0]) }
            return Entry(text: text, time: line.time, words: words, timings: timings)
        }
        let entries: [(String, TimeInterval?)] = timed.isEmpty
            ? lyrics.plainText.components(separatedBy: .newlines).map { (clean($0), nil) }
            : flow.map { ($0.text, $0.time) }
        let usable = entries.filter { !$0.0.isEmpty }
        guard usable.count >= count else { return nil }
        // Neither the main name nor the one the file carries gives it away.
        let names = Set([artist, LibraryIndex.taggedArtistName(for: song)].map { $0.lowercased() })
        let starts = (0...(usable.count - count)).filter { i in
            let group = usable[i..<(i + count)].map(\.0)
            return group.allSatisfy { $0.count >= 12 } && !group.contains { line in names.contains { line.lowercased().contains($0) } }
        }
        guard let i = starts.randomElement() else { return nil }
        let group = Array(usable[i..<(i + count)])
        return Question(song: song, artist: artist, lines: group.map(\.0), time: group[0].1,
                        offset: lyrics.offset, flow: timed.isEmpty ? [] : Array(flow[i...]))
    }

    /// The answer, heard: the song from the line shown.
    private func playReveal() {
        guard let question, question.song.isExcerptPlayable else { return }
        let player = AVPlayer(url: question.song.excerptURL)
        // Line times include the [offset:] tag; playback time doesn't.
        let start = max(0, (question.time.map { $0 - question.offset } ?? question.song.duration * 0.3) - 0.3)
        audio = player
        player.seek(to: CMTime(seconds: start, preferredTimescale: 600)) { [weak self] done in
            Task { @MainActor in
                guard done, let self, self.audio === player, !self.isPaused else { return }
                player.play()
            }
        }
    }

    private func stopAudio() {
        audio?.pause()
        audio = nil
    }
}

struct WhoSingsGameView: View {
    let onDismiss: () -> Void
    @StateObject private var game: WhoSingsGame
    @ObservedObject var playerVM: PlayerViewModel
    @State private var resumePlaybackOnExit = false

    init(session: WhoSingsSession, playerVM: PlayerViewModel, onDismiss: @escaping () -> Void) {
        self.playerVM = playerVM
        self.onDismiss = onDismiss
        _game = StateObject(wrappedValue: WhoSingsGame(songs: session.songs, difficulty: session.difficulty))
    }

    var body: some View {
        ZStack {
            background
            if game.isGameOver {
                gameOver
            } else if let q = game.question {
                question(q)
            }
            if game.isPaused {
                GamePauseOverlay(onResume: { game.resume() }, onEnd: { game.end() })
            }
        }
        .animation(.smooth(duration: 0.3), value: game.isPaused)
        .animation(.smooth(duration: 0.35), value: game.isGameOver)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in game.pause() }
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .onAppear {
            resumePlaybackOnExit = playerVM.isPlaying
            if resumePlaybackOnExit { playerVM.togglePlayPause() }
            game.start()
        }
        .onDisappear {
            game.stop()
            if resumePlaybackOnExit { playerVM.togglePlayPause() }
        }
    }

    private var background: some View {
        ZStack {
            if game.selected != nil, let q = game.question {
                PlayerBackgroundRepresentable(artwork: q.song.artworkSource, showsMotion: false)
                    .transition(.opacity)
            } else {
                LinearGradient(colors: [Color(white: 0.11), Color(white: 0.05)], startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .animation(.easeInOut(duration: 0.45), value: game.selected)
    }

    private var header: some View {
        HStack {
            GamePauseButton { game.pause() }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text("Who Sings This?")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                Text(game.difficulty.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                Text("Round \(game.roundIndex) of \(game.totalRounds) · \(game.score) pts")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.7))
                    .contentTransition(.numericText())
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }

    private func question(_ q: WhoSingsGame.Question) -> some View {
        let revealed = game.selected != nil
        let columns = game.choices.count > 4 ? 3 : 2
        return VStack(spacing: 0) {
            header
            Spacer(minLength: 12).layoutPriority(-2)
            BottomClipLayout {
                TimelineView(.animation(paused: !revealed || q.flow.isEmpty || game.isPaused)) { _ in
                    lyricsBlock(q, now: revealed ? game.lyricsTime() : nil)
                }
            }
            .clipped()
            .modifier(OverflowFade(active: revealed && !q.flow.isEmpty))
            .layoutPriority(-1)
            .padding(.horizontal, 28)
            .id(q.song.id)
            .transition(.opacity.combined(with: .scale(scale: 0.96)))

            Group {
                if revealed {
                    VStack(spacing: 2) {
                        Text(game.isCorrect ? "Correct!" : "It's \(q.artist)")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(game.isCorrect ? .green : .white)
                        Text(q.song.title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(1)
                    }
                } else {
                    Text("Who sings this?")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            .padding(.top, 18)
            Spacer(minLength: 12).layoutPriority(-2)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: columns), spacing: 14) {
                ForEach(game.choices, id: \.self) { artist in
                    choice(artist, correct: artist == q.artist, size: columns == 3 ? 76 : 96)
                }
            }
            .padding(.horizontal, 20)

            Button {
                flowTime = -.infinity
                withAnimation(.easeInOut(duration: 0.25)) { game.next() }
            } label: {
                Text("Next")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
            }
            .buttonStyle(.glass)
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 28)
            .opacity(revealed ? 1 : 0)
            .disabled(!revealed)
        }
        .animation(.easeInOut(duration: 0.25), value: game.selected)
    }

    /// Lines that came in after the reveal: they push everything else
    /// (but Next) out of the way.

    @State private var flowTime: TimeInterval = -.infinity

    private func lyricsBlock(_ q: WhoSingsGame.Question, now: TimeInterval?) -> some View {
        let base = q.lines.count
        // The layout follows its own clock, moved in one animation each time
        // a line or a word comes in: what grows and what it pushes move together.
        var key = 0
        if let now, !q.flow.isEmpty {
            let lines = q.flow.prefix { $0.time <= now }
            key = lines.count * 10_000 + (lines.last?.timings.filter { $0.start <= now }.count ?? 0)
        }
        let layoutTime = now == nil ? -.infinity : flowTime
        let shown = q.flow.isEmpty ? base : max(base, q.flow.prefix { $0.time <= layoutTime }.count)
        let extra = shown - base
        let size: CGFloat = base > 1 ? 24 : 28
        let visible = q.flow.isEmpty ? [] : Array(q.flow.prefix(shown).suffix(14))
        return VStack(spacing: 10) {
            if visible.isEmpty {
                ForEach(Array(q.lines.enumerated()), id: \.offset) { _, line in
                    Text("“\(line)”")
                        .font(.system(size: size, weight: .bold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .minimumScaleFactor(0.6)
                }
            } else {
                ForEach(Array(visible.enumerated()), id: \.element.time) { i, entry in
                    let isQuoted = q.flow.prefix(shown).count - visible.count + i < base
                    Group {
                        if let now, !entry.timings.isEmpty, entry.timings.count == entry.words.count {
                            CenteredFlow(spacing: size * 0.27, lineSpacing: 4,
                                         rowsUpTo: isQuoted ? nil : max(0, entry.timings.filter { $0.start <= layoutTime }.count - 1)) {
                                ForEach(Array(entry.words.enumerated()), id: \.offset) { w, word in
                                    let text = (isQuoted && w == 0 ? "“" : "") + word + (isQuoted && w == entry.words.count - 1 ? "”" : "")
                                    RevealWord(text: text, timing: entry.timings[w], now: now, appears: !isQuoted)
                                }
                            }
                        } else {
                            sungText(entry, now: now, quoted: isQuoted)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .font(.system(size: size, weight: .bold))
                        .transition(.opacity.animation(.easeOut(duration: 0.5)))
                }
            }
        }
        .onChange(of: key) { _, _ in
            guard let now else { return }
            withAnimation(.smooth(duration: 0.6)) { flowTime = now }
        }
    }

    /// Lit as sung: word by word with word sync, else the whole line.
    private func sungText(_ entry: WhoSingsGame.Entry, now: TimeInterval?, quoted: Bool) -> Text {
        let open = quoted ? "“" : "", close = quoted ? "”" : ""
        guard let now else { return Text(open + entry.text + close).foregroundColor(.white) }
        let dim = Color.white.opacity(0.42)
        guard !entry.timings.isEmpty, entry.timings.count == entry.words.count else {
            return Text(open + entry.text + close).foregroundColor(now >= entry.time ? .white : dim)
        }
        var out = AttributedString(open)
        out.foregroundColor = now >= entry.timings[0].start ? .white : dim
        for (i, word) in entry.words.enumerated() {
            var piece = AttributedString((i == 0 ? "" : " ") + word)
            piece.foregroundColor = now >= entry.timings[i].start ? .white : dim
            out += piece
        }
        var tail = AttributedString(close)
        tail.foregroundColor = now >= (entry.timings.last?.start ?? 0) ? .white : dim
        out += tail
        return Text(out)
    }

    private func choice(_ artist: String, correct: Bool, size: CGFloat) -> some View {
        let revealed = game.selected != nil
        let isSelected = game.selected == artist
        let dimmed = revealed && !correct && !isSelected
        return Button { game.select(artist) } label: {
            VStack(spacing: 8) {
                ZStack(alignment: .bottomTrailing) {
                    ArtistAvatarView(artistName: artist, songs: game.artistsByName[artist] ?? [], size: size)
                        .frame(width: size, height: size)
                        // Faded as one: else the monogram under the photo shows through.
                        .compositingGroup()
                        .overlay {
                            Circle().strokeBorder(correct ? Color.green : .red, lineWidth: 3)
                                .opacity(revealed && (correct || isSelected) ? 1 : 0)
                        }
                    if revealed && (correct || isSelected) {
                        Image(systemName: correct ? "checkmark" : "xmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 26, height: 26)
                            .glassEffect(.regular.tint(correct ? .green : .red), in: .circle)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                Text(artist)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(revealed ? (correct ? .green : isSelected ? .red : .white.opacity(0.4)) : .white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .compositingGroup()
            .opacity(dimmed ? 0.4 : 1)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(revealed)
        .sensoryFeedback(game.isCorrect ? .success : .error, trigger: isSelected)
    }

    private var gameOver: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "music.mic")
                .font(.system(size: 52, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
            VStack(spacing: 6) {
                Text("Game Over")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.white)
                Text("\(game.score) / \(game.answeredRounds) correct")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                Text("Best \(game.bestScore)")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.45))
            }
            Spacer()
            Button { game.stop(); onDismiss() } label: {
                Text("Done")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
            }
            .buttonStyle(.glassProminent)
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
        }
    }
}

/// Takes the height its content wants, up to what's offered: past that it
/// keeps the bottom (the newest lines) and lets the top go.
private struct BottomClipLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let ideal = child.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: proposal.width ?? ideal.width, height: min(ideal.height, proposal.height ?? ideal.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let child = subviews.first else { return }
        let ideal = child.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
        child.place(at: CGPoint(x: bounds.midX, y: bounds.maxY), anchor: .bottom,
                    proposal: ProposedViewSize(width: bounds.width, height: ideal.height))
    }
}

/// A soft top edge once lines start leaving.
private struct OverflowFade: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        content.mask {
            LinearGradient(stops: [.init(color: active ? .clear : .black, location: 0),
                                   .init(color: .black, location: active ? 0.08 : 0)],
                           startPoint: .top, endPoint: .bottom)
        }
    }
}

/// One word, lit from left to right as it's sung (soft edge, like the
/// player); in lines that weren't on screen, it also eases in on its cue.
private struct RevealWord: View {
    let text: String
    let timing: WordTiming
    let now: TimeInterval
    let appears: Bool

    var body: some View {
        let length = max(0.12, timing.end - timing.start)
        let fill = min(1, max(0, (now - timing.start) / length))
        let edge = 0.35
        let head = fill * (1 + edge)
        Text(text)
            .foregroundStyle(.white.opacity(appears ? 0 : 0.42))
            .overlay {
                Text(text)
                    .foregroundStyle(.white)
                    .mask {
                        LinearGradient(stops: [.init(color: .black, location: head - edge),
                                               .init(color: .clear, location: head)],
                                       startPoint: .leading, endPoint: .trailing)
                    }
            }
    }
}

/// Words wrapped into centered rows.
private struct CenteredFlow: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat
    /// Only rows up to this word's count toward the height (the rest wait,
    /// unseen, until it's their turn); nil: all of them.
    var rowsUpTo: Int? = nil

    private func rows(_ width: CGFloat, _ subviews: Subviews) -> [[(Int, CGSize)]] {
        var rows: [[(Int, CGSize)]] = [[]]
        var x: CGFloat = 0
        for (i, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { rows.append([]); x = 0 }
            rows[rows.count - 1].append((i, size))
            x += size.width + spacing
        }
        return rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var rows = rows(width, subviews)
        if let last = rowsUpTo, let row = rows.firstIndex(where: { $0.contains { $0.0 >= last } }) {
            rows = Array(rows.prefix(row + 1))
        }
        let height = rows.reduce(0) { $0 + ($1.map(\.1.height).max() ?? 0) } + CGFloat(max(0, rows.count - 1)) * lineSpacing
        let widest = rows.map { $0.reduce(0) { $0 + $1.1.width } + CGFloat(max(0, $0.count - 1)) * spacing }.max() ?? 0
        return CGSize(width: proposal.width ?? widest, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(bounds.width, subviews) {
            let rowWidth = row.reduce(0) { $0 + $1.1.width } + CGFloat(max(0, row.count - 1)) * spacing
            let rowHeight = row.map(\.1.height).max() ?? 0
            var x = bounds.midX - rowWidth / 2
            for (i, size) in row {
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += rowHeight + lineSpacing
        }
    }
}
