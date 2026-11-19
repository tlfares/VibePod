import SwiftUI
import AVFoundation
import Combine

struct GuessLyricsSession: Identifiable, Equatable {
    let id = UUID()
    let songs: [Song]
}

@MainActor
final class GuessTheNextLyricsGame: ObservableObject {
    let songs: [Song]

    @Published private(set) var currentSong: Song?
    /// The lyric line shown to the player (trimmed, never empty).
    @Published private(set) var questionText: String?
    /// The correct next line (trimmed, never empty). Always one of `choices`.
    @Published private(set) var answerText: String?
    @Published private(set) var choices: [String] = []
    @Published private(set) var selectedChoice: String?
    @Published private(set) var isCorrect: Bool?
    @Published private(set) var score = 0
    @Published private(set) var roundIndex = 0
    @Published private(set) var totalRounds = 0
    @Published private(set) var isGameOver = false
    @Published private(set) var isPaused = false
    /// Best number of right answers, kept across games.
    var bestScore: Int { UserDefaults.standard.integer(forKey: "guessLyricsBestScore") }
    /// Rounds answered so far: an ended game counts only those.
    var answeredRounds: Int { roundIndex - (selectedChoice == nil && !isGameOver ? 1 : 0) }
    @Published private(set) var isReady = false

    /// Everything needed for one round. Built off the main thread because it
    /// reads and parses LRC files.
    private struct Question: Sendable {
        let song: Song
        let questionText: String
        let answerText: String
        let choices: [String]
        /// Playback time (already corrected for the LRC `offset` tag).
        let questionStart: TimeInterval
        let questionEnd: TimeInterval
        let answerStart: TimeInterval
    }

    private var audioPlayer: AVPlayer?
    private var timeObserver: Any?
    private var usedSongIDs: Set<UUID> = []
    private let playableSongs: [Song]
    private var currentQuestion: Question?
    private var loadTask: Task<Void, Never>?
    private var pendingPlaybackTask: Task<Void, Never>?
    private var hasStarted = false
    private var pendingSongID: UUID?

    init(songs: [Song]) {
        self.songs = songs
        self.playableSongs = songs.filter { $0.lyricsKind == .synced }
        self.totalRounds = min(playableSongs.count, 20)
    }

    /// Starts the first round. Called from `onAppear`, after the main player has
    /// been paused, so the excerpt never overlaps the user's music.
    func start() {
        if hasStarted {
            // A presentation hiccup can call onDisappear (which cancels the
            // pending load) then onAppear again: resume instead of hanging.
            if !isReady, !isGameOver, loadTask == nil { loadNextQuestion() }
            return
        }
        hasStarted = true
        loadNextQuestion()
    }

    func selectChoice(_ choice: String) {
        guard selectedChoice == nil, let question = currentQuestion else { return }
        selectedChoice = choice
        isCorrect = choice == question.answerText
        if isCorrect == true { score += 1 }

        stopAudio()
        pendingPlaybackTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled, let self, self.currentQuestion?.song.id == question.song.id else { return }
            self.playExcerpt(from: question.song, at: question.answerStart, until: nil)
        }
    }

    func advance() {
        guard loadTask == nil else { return }
        loadNextQuestion()
    }

    func pause() {
        guard isReady, !isGameOver, !isPaused else { return }
        pendingPlaybackTask?.cancel()
        stopAudio()
        isPaused = true
    }

    func resume() {
        guard isPaused else { return }
        isPaused = false
        if let question = currentQuestion {
            if selectedChoice == nil {
                playExcerpt(from: question.song, at: question.questionStart, until: question.questionEnd)
            } else {
                playExcerpt(from: question.song, at: question.answerStart, until: nil)
            }
        }
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
        UserDefaults.standard.set(max(bestScore, score), forKey: "guessLyricsBestScore")
    }

    func stop() {
        if loadTask != nil, let pending = pendingSongID {
            // The cancelled round never happened: keep its song available.
            usedSongIDs.remove(pending)
        }
        loadTask?.cancel()
        loadTask = nil
        pendingSongID = nil
        stopAudio()
    }

    private func loadNextQuestion() {
        stopAudio()
        let available = playableSongs.filter { !usedSongIDs.contains($0.id) }
        guard roundIndex < totalRounds, let song = available.randomElement() else {
            finishGame()
            isReady = true
            return
        }
        usedSongIDs.insert(song.id)
        pendingSongID = song.id
        let otherSongs = playableSongs.filter { $0.id != song.id }

        loadTask = Task { [weak self] in
            let question = await Task.detached(priority: .userInitiated) {
                Self.makeQuestion(for: song, distractorSources: otherSongs)
            }.value
            guard !Task.isCancelled, let self else { return }
            self.loadTask = nil
            self.pendingSongID = nil
            guard let question else {
                // No usable lyric pair in this file: drop it from the round count.
                // Capped at 20: only shrinks once too few songs are left.
                if available.count - 1 < self.totalRounds - self.roundIndex {
                    self.totalRounds = max(0, self.totalRounds - 1)
                }
                self.loadNextQuestion()
                return
            }
            self.apply(question)
        }
    }

    private func apply(_ question: Question) {
        currentQuestion = question
        currentSong = question.song
        questionText = question.questionText
        answerText = question.answerText
        choices = question.choices
        selectedChoice = nil
        isCorrect = nil
        roundIndex += 1
        isReady = true
        playExcerpt(from: question.song, at: question.questionStart, until: question.questionEnd)
    }

    // MARK: - Question building (off the main actor)

    nonisolated private static func cleaned(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func makeQuestion(for song: Song, distractorSources: [Song]) -> Question? {
        guard let url = song.resolvedLyricsFileURL(),
              let parsed = LRCParser.parse(url: url) else { return nil }
        // From the real start, the outro (talk after the song) left out.
        let lyrics = LyricsMarks.forGames(parsed, songID: song.id).lyrics
        guard lyrics.hasTimedLyrics else { return nil }

        // Keep instrumental / empty lines in the timeline (they end the question
        // excerpt), but never use them as a question or an answer.
        let timeline = lyrics.lines.sorted { $0.time < $1.time }
        let texts = timeline.map { cleaned($0.text) }
        let lyricIndices = timeline.indices.filter { !texts[$0].isEmpty }
        guard lyricIndices.count >= 2 else { return nil }

        let pairs = zip(lyricIndices, lyricIndices.dropFirst()).map { ($0, $1) }
        // Avoid trivial rounds where the next line repeats the question line.
        let distinctPairs = pairs.filter { texts[$0.0].caseInsensitiveCompare(texts[$0.1]) != .orderedSame }
        guard let (questionIndex, answerIndex) = (distinctPairs.isEmpty ? pairs : distinctPairs).randomElement() else {
            return nil
        }
        let questionText = texts[questionIndex]
        let answerText = texts[answerIndex]

        var seen: Set<String> = [answerText.lowercased(), questionText.lowercased()]
        var distractors: [String] = []
        func collect(_ candidates: [String]) {
            for text in candidates where distractors.count < 2 && !text.isEmpty {
                if seen.insert(text.lowercased()).inserted {
                    distractors.append(text)
                }
            }
        }
        collect(texts.shuffled())
        if distractors.count < 2 {
            for other in distractorSources.shuffled() where distractors.count < 2 {
                guard let otherURL = other.resolvedLyricsFileURL(),
                      let otherLyrics = LRCParser.parse(url: otherURL) else { continue }
                collect(otherLyrics.lines.map { cleaned($0.text) }.shuffled())
            }
        }

        // LRC timestamps are shifted by the `offset` tag (see LRCLyrics.line(at:)).
        let offset = lyrics.offset
        let questionStart = timeline[questionIndex].time - offset
        // The question excerpt stops at the very next timeline entry, which may
        // be an instrumental gap before the answer.
        let questionEnd = timeline[questionIndex + 1].time - offset

        return Question(
            song: song,
            questionText: questionText,
            answerText: answerText,
            choices: ([answerText] + distractors).shuffled(),
            questionStart: questionStart,
            questionEnd: questionEnd,
            answerStart: timeline[answerIndex].time - offset
        )
    }

    // MARK: - Audio

    private func stopAudio() {
        pendingPlaybackTask?.cancel()
        pendingPlaybackTask = nil
        removeObserver()
        audioPlayer?.pause()
        audioPlayer = nil
    }

    /// Plays `song` from `startTime`; stops at `endTime` when given, otherwise
    /// plays on until the next round.
    private func playExcerpt(from song: Song, at startTime: TimeInterval, until endTime: TimeInterval?) {
        stopAudio()
        guard song.duration > 0 else { return }

        let player = AVPlayer(url: song.playableFileURL)
        let safeStart = min(max(startTime, 0), max(0, song.duration - 0.1))
        audioPlayer = player

        if let endTime {
            let clipEnd = min(max(endTime, safeStart + 0.3), song.duration)
            timeObserver = player.addBoundaryTimeObserver(
                forTimes: [NSValue(time: CMTime(seconds: clipEnd, preferredTimescale: 600))],
                queue: .main
            ) { [weak self, weak player] in
                MainActor.assumeIsolated {
                    guard let self, let player, self.audioPlayer === player else { return }
                    player.pause()
                    self.removeObserver()
                }
            }
        }

        // Exact seek: the excerpt has to start on the lyric line, not a keyframe nearby.
        player.seek(
            to: CMTime(seconds: safeStart, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self] finished in
            Task { @MainActor [weak self] in
                guard finished, let self, self.audioPlayer === player else { return }
                player.play()
            }
        }
    }

    private func removeObserver() {
        if let obs = timeObserver {
            audioPlayer?.removeTimeObserver(obs)
            timeObserver = nil
        }
    }
}

struct GuessTheNextLyricsGameView: View {
    let session: GuessLyricsSession
    let onDismiss: () -> Void

    @StateObject private var game: GuessTheNextLyricsGame
    @ObservedObject var playerVM: PlayerViewModel
    @State private var backgroundPalette: [Color] = Song.fallbackArtworkColors
    @State private var resumePlaybackOnExit = false

    init(session: GuessLyricsSession, playerVM: PlayerViewModel, onDismiss: @escaping () -> Void) {
        self.session = session
        self.playerVM = playerVM
        self.onDismiss = onDismiss
        _game = StateObject(wrappedValue: GuessTheNextLyricsGame(songs: session.songs))
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
                Button { finish() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                        .frame(width: 44, height: 44)
                        .glassEffect(.regular.interactive(true), in: Circle())
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .accessibilityLabel("Close")
            }
        }
    }

    private func questionView(song: Song) -> some View {
        VStack(spacing: 0) {
            HStack {
                GamePauseButton { game.pause() }

                Spacer()

                Text("\(game.score)/\(game.totalRounds)")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)

            Spacer()

            VStack(spacing: 10) {
                if let artwork = song.artwork {
                    artwork
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 160, height: 160)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
                } else {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .frame(width: 160, height: 160)
                        .overlay {
                            Image(systemName: "music.note")
                                .font(.system(size: 40, weight: .medium))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                }

                VStack(spacing: 3) {
                    Text(song.title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(song.artist)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
                .padding(.top, 6)
            }

            Spacer()

            VStack(spacing: 16) {
                if let questionText = game.questionText {
                    Text(questionText)
                        .font(.system(size: questionFontSize, weight: .bold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                }

                VStack(spacing: 10) {
                    ForEach(game.choices, id: \.self) { choice in
                        choiceButton(choice)
                    }
                }
                .padding(.horizontal, 20)
            }

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
        .animation(.easeInOut(duration: 0.25), value: game.selectedChoice)
        .animation(.easeInOut(duration: 0.3), value: game.currentSong?.id)
    }

    @ViewBuilder
    private func choiceButton(_ choice: String) -> some View {
        let isSelected = game.selectedChoice == choice
        let isCorrectChoice = game.answerText == choice
        let revealed = game.selectedChoice != nil
        let fontSize = lyricsFontSize

        Button {
            game.selectChoice(choice)
        } label: {
            HStack(spacing: 12) {
                Text(choice)
                    .font(.system(size: fontSize, weight: .bold))
                    .foregroundStyle(choiceTextColor(revealed: revealed, selected: isSelected, correct: isCorrectChoice))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                Image(systemName: isCorrectChoice ? "checkmark" : "xmark")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(isCorrectChoice ? .green : .red)
                    .opacity(revealed ? (isCorrectChoice || isSelected ? 1 : 0) : 0)
                    .frame(width: 20)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(choiceBackgroundFill(revealed: revealed, selected: isSelected, correct: isCorrectChoice))
                    .glassEffect(.regular.interactive(!revealed), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            )
        }
        .disabled(game.selectedChoice != nil)
    }

    private var lyricsFontSize: CGFloat {
        let maxLen = game.choices.map(\.count).max() ?? 0
        if maxLen <= 40 { return 28 }
        if maxLen <= 80 { return 24 }
        if maxLen <= 120 { return 20 }
        return 17
    }

    private var questionFontSize: CGFloat {
        let len = game.questionText?.count ?? 0
        let base = lyricsFontSize
        if len <= 50 { return base }
        if len <= 100 { return max(base - 4, 16) }
        if len <= 160 { return max(base - 8, 14) }
        return 14
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
            .saturation(1.38)

            Rectangle()
                .fill(.ultraThinMaterial)

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
    }

    private func updatePalette() {
        withAnimation(.easeInOut(duration: 0.45)) {
            backgroundPalette = game.currentSong?.playerArtworkColors ?? Song.fallbackArtworkColors
        }
    }

    private func finish() {
        game.stop()
        onDismiss()
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
