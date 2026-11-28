import AVFoundation
import SwiftUI
import UIKit

struct CoversSnakeSession: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let songs: [Song]
}

struct CoversSnakeGameView: View {
    let session: CoversSnakeSession
    @ObservedObject var playerVM: PlayerViewModel
    let onDismiss: () -> Void

    @StateObject private var game: CoversSnakeGame
    @State private var resumePlaybackOnExit = false
    @State private var didFinish = false

    init(session: CoversSnakeSession, playerVM: PlayerViewModel, onDismiss: @escaping () -> Void) {
        self.session = session
        self.playerVM = playerVM
        self.onDismiss = onDismiss
        _game = StateObject(wrappedValue: CoversSnakeGame(songs: session.songs))
    }

    var body: some View {
        ZStack {
            game.backgroundColor
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 0.32), value: game.foodSong.id)

            GeometryReader { proxy in
                let metrics = SnakeBoardMetrics(size: proxy.size)

                ZStack {
                    if game.isDead {
                        ForEach(game.fallingBlocks) { block in
                            SnakeArtworkBlock(artwork: game.artwork(for: block.song), isFood: false)
                                .frame(width: metrics.coverSize, height: metrics.coverSize)
                                .position(
                                    CGPoint(
                                        x: metrics.position(for: block.point).x + block.offset.width,
                                        y: metrics.position(for: block.point).y + block.offset.height
                                    )
                                )
                                .rotationEffect(.degrees(block.rotation))
                                .gesture(
                                    DragGesture()
                                        .onChanged { game.drag(blockID: block.id, translation: $0.translation) }
                                        .onEnded { game.release(blockID: block.id, value: $0) }
                                )
                        }
                    } else {
                        ForEach(game.segments) { segment in
                            SnakeArtworkBlock(artwork: game.artwork(for: segment.song), isFood: false)
                                .frame(width: metrics.coverSize, height: metrics.coverSize)
                                .position(metrics.position(for: segment.point))
                                .transition(.scale.combined(with: .opacity))
                        }

                        SnakeArrow(direction: game.displayDirection)
                            .frame(width: metrics.coverSize, height: metrics.coverSize)
                            .position(metrics.position(for: game.head))
                            .animation(.interpolatingSpring(stiffness: 150, damping: 12), value: game.displayDirection)

                        SnakeArtworkBlock(artwork: game.artwork(for: game.foodSong), isFood: game.foodTargetPoint == nil)
                            .frame(width: metrics.coverSize + 6, height: metrics.coverSize + 6)
                            .position(metrics.position(for: game.foodTargetPoint ?? game.food))
                            .animation(game.foodTargetPoint != nil ? .easeInOut(duration: game.movementDuration) : nil, value: game.foodTargetPoint)
                            .id(game.foodSong.id)
                            .transition(.scale(scale: 0.72).combined(with: .opacity))
                    }

                    if game.isDead {
                        VStack(spacing: 8) {
                            Text("\(game.score)")
                                .font(.system(size: 58, weight: .bold, design: .rounded))
                            Text("Best \(game.bestScore)")
                                .font(.system(size: 17, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.68))
                        }
                        .shadow(color: .black.opacity(0.28), radius: 12, y: 4)
                        .allowsHitTesting(false)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                    }
                }
                .animation(.linear(duration: game.movementDuration), value: game.head)
                .animation(.linear(duration: game.movementDuration), value: game.segments)
                .animation(.easeOut(duration: 0.12), value: game.foodSong.id)
                .contentShape(Rectangle())
                .gesture(game.isDead ? nil : DragGesture(minimumDistance: 4)
                    .onChanged { game.steer(with: $0.translation) }
                )
                .onAppear { game.setBoardSize(proxy.size) }
                .onChange(of: proxy.size) { _, size in
                    game.setBoardSize(size)
                }
            }
            .ignoresSafeArea()

            VStack(spacing: 0) {
                HStack(alignment: .top) {
                    if game.isDead {
                        Button(action: finish) {
                            Image(systemName: "xmark")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 44, height: 44)
                                .glassEffect(.regular.interactive(true), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Close Covers Snake")
                    } else {
                        GamePauseButton { game.pause() }
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 3) {
                        Text("Covers Snake")
                            .font(.headline)
                        Text(session.title)
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 12)

                Spacer()

                if !game.isDead {
                    HStack(spacing: 8) {
                        Image(systemName: "music.note")
                            .font(.footnote.weight(.semibold))
                        Text(game.foodSong.title)
                            .lineLimit(1)
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.88))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .glassEffect(.regular.interactive(false), in: Capsule())
                    .padding(.bottom, 12)
                }
            }
        }
        .overlay {
            if game.isPaused {
                GamePauseOverlay(onResume: { game.resume() }, onEnd: { game.end() })
            }
        }
        .animation(.smooth(duration: 0.3), value: game.isPaused)
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .onAppear {
            resumePlaybackOnExit = playerVM.isPlaying
            if resumePlaybackOnExit { playerVM.togglePlayPause() }
            game.start()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            game.pause()
        }
        .onDisappear(perform: finishPlayback)
    }

    private func finish() {
        finishPlayback()
        onDismiss()
    }

    private func finishPlayback() {
        guard !didFinish else { return }
        didFinish = true
        game.stop()
        if resumePlaybackOnExit { playerVM.togglePlayPause() }
    }
}

private struct SnakeBoardMetrics {
    let columns = 13
    let rows = 22
    let columnSize: CGFloat
    let rowSize: CGFloat

    init(size: CGSize) {
        columnSize = size.width / CGFloat(columns)
        rowSize = size.height / CGFloat(rows)
    }

    var coverSize: CGFloat { max(20, min(columnSize, rowSize) * 1.13 - 3) }

    func position(for point: SnakePoint) -> CGPoint {
        CGPoint(
            x: (CGFloat(point.x) + 0.5) * columnSize,
            y: (CGFloat(point.y) + 0.5) * rowSize
        )
    }
}

private struct SnakeArtworkBlock: View {
    let artwork: Image?
    let isFood: Bool

    var body: some View {
        Group {
            if let artwork {
                artwork
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white.opacity(0.88))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.white.opacity(0.18))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .padding(isFood ? 3 : 0)
        .background {
            if isFood {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .glassEffect(.regular.interactive(false), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .overlay {
            if !isFood {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(.white.opacity(0.20), lineWidth: 0.7)
            }
        }
        .shadow(color: .black.opacity(isFood ? 0.33 : 0.18), radius: isFood ? 9 : 4, y: 3)
    }
}

private struct SnakeArrow: View {
    let direction: SnakeDirection

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(.clear)
                .glassEffect(.regular.interactive(false), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

            Image(systemName: "arrowtriangle.right.fill")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.white)
                .rotationEffect(direction.rotation)
        }
        .shadow(color: .black.opacity(0.22), radius: 5, y: 2)
    }
}

private struct SnakeSegment: Identifiable, Equatable {
    let id: UUID
    var point: SnakePoint
    let song: Song

    init(id: UUID = UUID(), point: SnakePoint, song: Song) {
        self.id = id
        self.point = point
        self.song = song
    }
}

private struct FallingSnakeBlock: Identifiable {
    let id = UUID()
    let song: Song
    let point: SnakePoint
    var offset: CGSize = .zero
    var rotation = 0.0
}

private struct SnakePoint: Hashable, Equatable {
    var x: Int
    var y: Int
}

private enum SnakeDirection: Equatable {
    case up, down, left, right

    var delta: SnakePoint {
        switch self {
        case .up: SnakePoint(x: 0, y: -1)
        case .down: SnakePoint(x: 0, y: 1)
        case .left: SnakePoint(x: -1, y: 0)
        case .right: SnakePoint(x: 1, y: 0)
        }
    }

    func isOpposite(to other: SnakeDirection) -> Bool {
        switch (self, other) {
        case (.up, .down), (.down, .up), (.left, .right), (.right, .left): true
        default: false
        }
    }

    var rotation: Angle {
        switch self {
        case .up: .degrees(-90)
        case .down: .degrees(90)
        case .left: .degrees(180)
        case .right: .zero
        }
    }
}

@MainActor
private final class CoversSnakeGame: ObservableObject {
    @Published private(set) var head: SnakePoint = SnakePoint(x: 6, y: 9)
    @Published private(set) var segments: [SnakeSegment] = []
    @Published private(set) var food: SnakePoint = SnakePoint(x: 9, y: 9)
    @Published private(set) var foodSong: Song
    @Published private(set) var direction: SnakeDirection = .right
    @Published private(set) var displayDirection: SnakeDirection = .right
    @Published private(set) var isDead = false
    @Published private(set) var isPaused = false
    @Published private(set) var fallingBlocks: [FallingSnakeBlock] = []
    @Published private(set) var foodTargetPoint: SnakePoint?
    /// Backdrop tint for the current food song. Computed once per food change
    /// instead of re-sampling the artwork palette on every movement tick.
    @Published private(set) var backgroundColor: Color = .black

    private let songs: [Song]
    private let previewPlayer = CoversSnakePreviewPlayer()
    private var pendingDirection: SnakeDirection = .right
    private var timer: Timer?
    private var dragOrigins: [UUID: CGSize] = [:]
    private var boardSize: CGSize = .zero
    private var remainingFoodSongs: [Song] = []
    private var lastFoodSongID: UUID?
    /// True between eating a cover and the next one spawning.
    private var isFoodPending = false
    /// Decoded artwork per song, so the board (redrawn every tick) never goes
    /// back to the artwork store / disk for segments it has already shown.
    private var artworkCache: [UUID: Image?] = [:]
    private let columns = 13
    private let rows = 22

    init(songs: [Song]) {
        self.songs = songs
        // Callers never pass an empty list, but don't crash if they do.
        self.foodSong = songs.first ?? Song(title: "", fileURL: URL(fileURLWithPath: "/"))
        reset()
    }

    var score: Int { segments.count }
    var bestScore: Int { UserDefaults.standard.integer(forKey: "coversSnakeBestScore") }
    var movementDuration: Double { 0.17 }

    func artwork(for song: Song) -> Image? {
        if let cached = artworkCache[song.id] { return cached }
        let image = song.artwork
        artworkCache[song.id] = image
        return image
    }

    func start() {
        guard timer == nil, !isDead else { return }
        previewPlayer.playExcerpt(of: foodSong)
        scheduleMovementTimer()
    }

    private func scheduleMovementTimer() {
        timer?.invalidate()
        // Scheduled on the main run loop, so the block always runs on the main thread.
        let timer = Timer(timeInterval: movementDuration, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.advance()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        previewPlayer.stop()
    }

    func pause() {
        guard !isDead, !isPaused else { return }
        stop()
        isPaused = true
    }

    func resume() {
        guard isPaused else { return }
        isPaused = false
        start()
    }

    /// Stops here: the snake falls apart and the score (saved) shows.
    func end() {
        isPaused = false
        previewPlayer.stop()
        die()
    }

    func steer(with translation: CGSize) {
        let requestedDirection: SnakeDirection
        if abs(translation.width) > abs(translation.height) {
            requestedDirection = translation.width < 0 ? .left : .right
        } else {
            requestedDirection = translation.height < 0 ? .up : .down
        }
        guard !requestedDirection.isOpposite(to: direction) else { return }
        pendingDirection = requestedDirection
        displayDirection = requestedDirection
    }

    func setBoardSize(_ size: CGSize) {
        boardSize = size
    }

    private func reset() {
        head = SnakePoint(x: columns / 2, y: rows / 2)
        segments = []
        direction = .right
        displayDirection = .right
        pendingDirection = .right
        foodTargetPoint = nil
        spawnFood()
    }

    private func advance() {
        guard !isDead else { return }
        if !pendingDirection.isOpposite(to: direction) {
            direction = pendingDirection
        }
        displayDirection = direction

        let delta = direction.delta
        let currentHead = head
        let newHead = SnakePoint(x: currentHead.x + delta.x, y: currentHead.y + delta.y)

        guard newHead.x >= 0, newHead.x < columns, newHead.y >= 0, newHead.y < rows else {
            die()
            return
        }

        // While the eaten cover is still flying to the tail, `food` points at the
        // old cell; it must not count as food a second time.
        let ateFood = newHead == food && !isFoodPending
        // The tail cell is vacated on this tick unless the snake grows, so moving
        // into it is legal.
        let blockingSegments = ateFood ? segments[...] : segments.dropLast()
        if blockingSegments.contains(where: { $0.point == newHead }) {
            die()
            return
        }

        head = newHead

        if ateFood {
            let previousSegments = segments
            let tailPosition = previousSegments.last?.point ?? currentHead
            var shifted = previousSegments.enumerated().map { index, segment in
                var segment = segment
                segment.point = index == 0 ? currentHead : previousSegments[index - 1].point
                return segment
            }
            shifted.append(SnakeSegment(point: tailPosition, song: foodSong))
            segments = shifted
            foodTargetPoint = tailPosition
            isFoodPending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + movementDuration) { [weak self] in
                guard let self, !self.isDead else { return }
                self.spawnFood()
                DispatchQueue.main.async { [weak self] in
                    self?.foodTargetPoint = nil
                }
            }
        } else if !segments.isEmpty {
            let previousSegments = segments
            var shifted = previousSegments
            for index in shifted.indices {
                shifted[index].point = index == 0 ? currentHead : previousSegments[index - 1].point
            }
            segments = shifted
        }
    }

    private func die() {
        guard !isDead else { return }
        isDead = true
        foodTargetPoint = nil
        timer?.invalidate()
        timer = nil
        UserDefaults.standard.set(max(bestScore, score), forKey: "coversSnakeBestScore")

        fallingBlocks = segments.map { segment in
            FallingSnakeBlock(
                song: segment.song,
                point: segment.point
            )
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            withAnimation(.timingCurve(0.2, 0.72, 0.4, 1, duration: 0.82)) {
                for index in self.fallingBlocks.indices {
                    let point = self.fallingBlocks[index].point
                    let currentY = (CGFloat(point.y) + 0.5) * (self.boardSize.height / CGFloat(self.rows))
                    let currentX = (CGFloat(point.x) + 0.5) * (self.boardSize.width / CGFloat(self.columns))
                    let floorY = self.boardSize.height - CGFloat.random(in: 78...170)
                    let floorX = min(max(currentX + CGFloat.random(in: -72...72), 28), self.boardSize.width - 28)
                    self.fallingBlocks[index].offset = CGSize(
                        width: floorX - currentX,
                        height: max(floorY - currentY, 0)
                    )
                    self.fallingBlocks[index].rotation = Double.random(in: -32...32)
                }
            }
        }
    }

    func drag(blockID: UUID, translation: CGSize) {
        guard let index = fallingBlocks.firstIndex(where: { $0.id == blockID }) else { return }
        let origin = dragOrigins[blockID] ?? fallingBlocks[index].offset
        dragOrigins[blockID] = origin
        fallingBlocks[index].offset = CGSize(
            width: origin.width + translation.width,
            height: origin.height + translation.height
        )
        fallingBlocks[index].rotation = Double(translation.width) * 0.04
    }

    func release(blockID: UUID, value: DragGesture.Value) {
        guard let index = fallingBlocks.firstIndex(where: { $0.id == blockID }) else { return }
        let origin = dragOrigins.removeValue(forKey: blockID) ?? fallingBlocks[index].offset
        let targetOffset = CGSize(
            width: origin.width + value.predictedEndTranslation.width,
            height: origin.height + value.predictedEndTranslation.height
        )
        let momentum = value.predictedEndTranslation.width - value.translation.width
        withAnimation(.interpolatingSpring(stiffness: 80, damping: 12)) {
            fallingBlocks[index].offset = targetOffset
            fallingBlocks[index].rotation = Double(value.predictedEndTranslation.width) * 0.04 + momentum * 0.008
        }
    }

    private func spawnFood() {
        isFoodPending = false
        let occupied = Set(segments.map(\.point) + [head])
        let available = (0..<columns).flatMap { x in
            (0..<rows).map { y in SnakePoint(x: x, y: y) }
        }.filter { !occupied.contains($0) }
        food = available.randomElement() ?? SnakePoint(x: 0, y: 0)
        foodSong = nextFoodSong()
        backgroundColor = Color(uiColor: foodSong.albumBackgroundUIColor)
        if timer != nil {
            previewPlayer.playExcerpt(of: foodSong)
        }
    }

    private func nextFoodSong() -> Song {
        guard !songs.isEmpty else { return foodSong }
        if remainingFoodSongs.isEmpty {
            remainingFoodSongs = songs.shuffled()
            if remainingFoodSongs.count > 1,
               remainingFoodSongs.first?.id == lastFoodSongID {
                remainingFoodSongs.swapAt(0, 1)
            }
        }
        let song = remainingFoodSongs.removeFirst()
        lastFoodSongID = song.id
        return song
    }
}

/// Plays a looping ~30 s excerpt of the current food song.
///
/// Only one AVPlayer is alive at a time: the previous implementation cached an
/// AVAudioPlayer per song for the whole game (memory grew with every cover
/// eaten) and created them synchronously on the main thread (file I/O stalls
/// in the middle of the movement animation). AVPlayer loads asynchronously.
@MainActor
private final class CoversSnakePreviewPlayer {
    private static weak var activePreviewPlayer: CoversSnakePreviewPlayer?

    private var player: AVPlayer?
    private var boundaryObserver: Any?
    private var currentSongID: UUID?

    func playExcerpt(of song: Song) {
        if Self.activePreviewPlayer !== self {
            Self.activePreviewPlayer?.stopCurrentClip()
            Self.activePreviewPlayer = self
        }
        stopCurrentClip()
        guard song.isExcerptPlayable else { return }

        let clipLength = song.duration > 0 ? min(30, song.duration) : 30
        let maximumStart = max(0, song.duration - clipLength)
        let startSeconds = maximumStart > 6 ? Double.random(in: 3...maximumStart) : 0
        let startTime = CMTime(seconds: startSeconds, preferredTimescale: 600)
        let endTime = CMTime(seconds: startSeconds + clipLength, preferredTimescale: 600)

        let player = AVPlayer(url: song.excerptURL)
        let songID = song.id
        self.player = player
        currentSongID = songID

        // Loop the excerpt: when the end boundary is reached, jump back to its start.
        boundaryObserver = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: endTime)],
            queue: .main
        ) { [weak self, weak player] in
            MainActor.assumeIsolated {
                guard let self, let player else { return }
                self.seekAndPlay(player, to: startTime, songID: songID)
            }
        }
        seekAndPlay(player, to: startTime, songID: songID)
    }

    func stop() {
        stopCurrentClip()
        if Self.activePreviewPlayer === self {
            Self.activePreviewPlayer = nil
        }
    }

    private func seekAndPlay(_ player: AVPlayer, to time: CMTime, songID: UUID) {
        player.seek(to: time) { [weak self] finished in
            Task { @MainActor [weak self] in
                guard finished,
                      let self,
                      self.currentSongID == songID,
                      self.player === player,
                      Self.activePreviewPlayer === self
                else { return }
                player.play()
            }
        }
    }

    private func stopCurrentClip() {
        if let boundaryObserver {
            player?.removeTimeObserver(boundaryObserver)
        }
        boundaryObserver = nil
        player?.pause()
        player = nil
        currentSongID = nil
    }
}
