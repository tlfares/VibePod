import SwiftUI
import UIKit
import Combine

struct LyricsView: View {
    let playerVM: PlayerViewModel
    @StateObject private var state: LyricsDisplayState
    @ObservedObject private var generator = LyricsGenerator.shared
    @ObservedObject private var wordSyncer = WordSyncGenerator.shared
    @State private var showLRCLIBLoading = false
    @State private var showLRCLIBError = false
    @State private var lrclibErrorMessage = ""
    /// LRCLIB answered but had nothing: the moment to offer generating them.
    @State private var lrclibFoundNothing = false
    @State private var aiAvailable = AIFeatures.isAvailable
    @AppStorage(Speechmatics.operatingPointKey) private var speechmaticsModel = Speechmatics.OperatingPoint.standard
    @ObservedObject private var translator = LyricsTranslator.shared
    @State private var sharing: LyricsShareRequest?
    @State private var marking: LyricsMarkRequest?

    init(playerVM: PlayerViewModel) {
        self.playerVM = playerVM
        _state = StateObject(wrappedValue: LyricsDisplayState(playerVM: playerVM))
    }

    var body: some View {
        Group {
            if let lyrics = state.lyrics, lyrics.hasTimedLyrics {
                TimedLyricsUIKitView(
                    lyrics: lyrics,
                    credit: credit(for: lyrics),
                    loadID: state.loadID,
                    currentLineID: state.currentLineID,
                    wordTimings: state.wordTimings,
                    trailingLines: state.trailingLines,
                    translations: translator.translations,
                    isVisible: state.isVisible,
                    currentTime: { [playerService = playerVM.playerService] in playerService.preciseCurrentTime },
                    onSeek: playerVM.seek(to:),
                    // Holding a line: correct it, share it, and (paused, the
                    // lyrics standing still) mark the song's start or outro.
                    canCorrect: { [playerVM] in playerVM.currentSongHasLRC },
                    canMark: { [playerVM] in !playerVM.isPlaying && playerVM.currentSongHasLRC },
                    onCorrect: { [playerVM] line, text in playerVM.correctLyricLine(line, to: text) },
                    onShare: { line in sharing = LyricsShareRequest(line: line) },
                    onMark: { [playerVM] line in
                        marking = playerVM.rawLine(for: line).map { LyricsMarkRequest(line: $0) }
                    }
                )
            } else if let lyrics = state.lyrics, lyrics.hasPlainText {
                PlainLyricsUIKitView(text: lyrics.plainText)
            } else if showLRCLIBLoading || generationStage != nil {
                // The progress card stands alone. Faded out instead, the
                // glass buttons were drawn over the card while they went.
                Color.clear
            } else {
                noLyricsView
                    .transition(.identity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .overlay {
            if showLRCLIBLoading {
                ZStack {
                    VStack(spacing: 14) {
                        TintedSpinner(color: .white.withAlphaComponent(0.7))
                        Text("Searching Lyrics...")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.primary)
                    }
                    .padding(28)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                }
            } else if let stage = generationStage {
                generationProgress(stage)
                    .transition(.blurReplace)
            }
        }
        .overlay(alignment: .top) {
            if let stage = wordSyncStage {
                loadingPill(stage.title)
                    .padding(.top, 12)
                    .transition(.blurReplace)
            } else if translator.isTranslating {
                loadingPill(String(localized: "Translating..."))
                    .padding(.top, 12)
                    .transition(.blurReplace)
            } else if state.lyrics?.hasTimedLyrics == true {
                SingAlongProgressPill()
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if state.lyrics?.hasTimedLyrics == true {
                SingAlongButton()
            }
        }
        .animation(.smooth, value: generationStage)
        .animation(.smooth, value: wordSyncStage)
        .animation(.smooth, value: translator.isTranslating)
        .alert("No Results", isPresented: $showLRCLIBError) {
            if lrclibFoundNothing && aiAvailable {
                Button("Generate with AI (Beta)") { generateLyrics() }
            }
            Button("Retry LRCLIB") { forceLRCLIB() }
            Button("Close", role: .cancel) {}
        } message: {
            Text(noResultsMessage)
        }
        // No accent colour anywhere in the full-screen player.
        .tint(.white)
        .sheet(item: $sharing) { request in
            LyricsShareSheet(playerVM: playerVM, startLine: request.line)
        }
        .sheet(item: $marking) { request in
            LyricsMarkSheet(playerVM: playerVM, line: request.line)
        }
        .alert("Couldn't Generate Lyrics", isPresented: generationFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(generationFailure ?? "")
        }
        .alert("Couldn't Sync Word by Word", isPresented: wordSyncFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(wordSyncFailure ?? "")
        }
        .onReceive(NotificationCenter.default.publisher(for: AIFeatures.didChangeNotification)) { _ in
            aiAvailable = AIFeatures.isAvailable
        }
        .translationTask(translator.configuration) { session in
            // Only to download the languages; used for this one batch.
            nonisolated(unsafe) let session = session
            await translator.translate(with: session)
        }
    }

    // MARK: AI lyrics

    private func credit(for lyrics: LRCLyrics) -> String? {
        if var credit = lyrics.aiCredit {
            // Syncs made before they were signed as such: the lyrics they
            // replaced are still remembered.
            if !credit.syncOnly, let song = playerVM.currentSong, let original = LyricsGenerator.original(for: song.id) {
                credit.syncOnly = true
                credit.source = LyricsGenerator.source(forStoredPath: original)
            }
            if !credit.syncOnly { return String(localized: "Transcribed and synced by \(credit.model) \u{2022} BETA") }
            if let source = credit.source { return String(localized: "Lyrics from \(source), synced by \(credit.model) \u{2022} BETA") }
            return String(localized: "Synced by \(credit.model) \u{2022} BETA")
        }
        if !state.wordTimings.isEmpty {
            if let source = playerVM.currentWordSyncSource { return String(localized: "Lyrics from \(source)") }
            return String(localized: "Words synced by AI \u{2022} BETA")
        }
        return nil
    }

    private var wordSyncStage: WordSyncGenerator.Stage? {
        playerVM.currentSong.flatMap { wordSyncer.stages[$0.id] }
    }

    private var wordSyncFailure: String? {
        playerVM.currentSong.flatMap { wordSyncer.failures[$0.id] }
    }

    private var wordSyncFailed: Binding<Bool> {
        Binding(
            get: { wordSyncFailure != nil },
            set: { shown in
                if !shown, let song = playerVM.currentSong { wordSyncer.clearFailure(for: song.id) }
            }
        )
    }

    /// Small, above the lyrics: they stay readable while the words sync
    /// or the translation comes.
    private func loadingPill(_ title: String) -> some View {
        HStack(spacing: 10) {
            TintedSpinner(color: .white.withAlphaComponent(0.7))
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .contentTransition(.opacity)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .capsule)
    }

    private var generationStage: LyricsGenerator.Stage? {
        playerVM.currentSong.flatMap { generator.stages[$0.id] }
    }

    private var generationFailure: String? {
        playerVM.currentSong.flatMap { generator.failures[$0.id] }
    }

    private var generationFailed: Binding<Bool> {
        Binding(
            get: { generationFailure != nil },
            set: { shown in
                if !shown, let song = playerVM.currentSong { generator.clearFailure(for: song.id) }
            }
        )
    }

    private var noResultsMessage: String {
        guard lrclibFoundNothing else {
            return lrclibErrorMessage.isEmpty ? String(localized: "No lyrics found for this song.") : lrclibErrorMessage
        }
        if aiAvailable {
            return String(localized: "No lyrics found for this song. \(AIProvider.current.name) can transcribe its vocals and sync them for you. The song's audio is sent to \(AIProvider.current.name); you can delete the result anytime.")
        }
        return String(localized: "No lyrics found for this song. AI Features in Settings › Tools can generate them.")
    }

    private var generateLabel: some View {
        Label("Generate", systemImage: "sparkles")
            .font(.headline)
            .padding(.horizontal, 6)
    }

    /// Picking a model keeps it and generates with it, once the menu has
    /// closed: the loading card replaced the button while the menu was
    /// still shrinking back into it, over the card.
    private var speechmaticsModelPicker: some View {
        Section("Speechmatics Model") {
            ForEach(Speechmatics.OperatingPoint.allCases) { point in
                Button {
                    speechmaticsModel = point
                    Task {
                        try? await Task.sleep(for: .milliseconds(400))
                        generateLyrics()
                    }
                } label: {
                    if point == speechmaticsModel {
                        Label(point.title, systemImage: "checkmark")
                    } else {
                        Text(point.title)
                    }
                }
            }
        }
    }

    private func generateLyrics() {
        guard let song = playerVM.currentSong else { return }
        generator.generate(for: song, in: playerVM.libraryService)
    }

    private func generationProgress(_ stage: LyricsGenerator.Stage) -> some View {
        VStack(spacing: 14) {
            TintedSpinner(color: .white.withAlphaComponent(0.7))
            VStack(spacing: 4) {
                Text(stage.title)
                    .font(.system(size: 15, weight: .medium))
                    .contentTransition(.opacity)
                Text("This can take a minute.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            BetaBadge()
        }
        .padding(28)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var noLyricsView: some View {
        VStack(spacing: 14) {
            Spacer()

            Image(systemName: "quote.bubble")
                .font(.system(size: 42, weight: .semibold))
                .foregroundStyle(.secondary)

            Text("No synced lyrics")
                .font(.system(size: 22, weight: .bold))

            Text("Add an LRC file with the same name as the song.")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 38)

            // With AI on, generating is offered from the start: no need to
            // wait for every source to come back empty first.
            HStack(spacing: 10) {
                Button {
                    searchLRCLIB()
                } label: {
                    Label(aiAvailable ? "Search" : "Search Lyrics", systemImage: "magnifyingglass")
                        .font(.headline)
                        .padding(.horizontal, 6)
                }
                if aiAvailable {
                    if Speechmatics.isOn {
                        // Held: Speechmatics' model, kept for the next ones.
                        Menu {
                            speechmaticsModelPicker
                        } label: {
                            generateLabel
                        } primaryAction: {
                            generateLyrics()
                        }
                        .menuStyle(.button)
                    } else {
                        Button {
                            generateLyrics()
                        } label: {
                            generateLabel
                        }
                    }
                }
            }
            .buttonStyle(.glass)
            .controlSize(.large)
            .padding(.top, 6)

            Text(aiAvailable
                 ? "Search: LRCLIB, KuGou, Musixmatch\u{2026} \u{2022} Generate: \(AIProvider.current.name) (Beta), sends the audio"
                 : "LRCLIB, KuGou, Musixmatch, LyricsPlus, Unison")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 38)

            Spacer()
        }
    }

    private func searchLRCLIB() {
        guard let song = playerVM.currentSong else { return }
        showLRCLIBLoading = true
        let query = LyricsSearch.Query(title: song.title, artist: song.artist, album: song.album, duration: song.duration > 0 ? song.duration : nil)

        Task { @MainActor in
            let results = await LyricsSearch.search(query)
            showLRCLIBLoading = false
            guard !results.isEmpty else {
                lrclibFoundNothing = true
                lrclibErrorMessage = ""
                showLRCLIBError = true
                return
            }
            presentResults(results, for: song)
        }
    }

    /// LRCLIB alone, waited for as long as it takes.
    private func forceLRCLIB() {
        guard let song = playerVM.currentSong else { return }
        showLRCLIBLoading = true
        let query = LyricsSearch.Query(title: song.title, artist: song.artist, album: song.album, duration: song.duration > 0 ? song.duration : nil)
        Task { @MainActor in
            let found: [LyricsCandidate]
            do {
                found = try await LRCLIBSource.search(query, attempts: 4)
            } catch {
                showLRCLIBLoading = false
                lrclibFoundNothing = false
                lrclibErrorMessage = String(localized: "LRCLIB isn't responding: \(error.localizedDescription)")
                showLRCLIBError = true
                return
            }
            let results = LyricsSearch.rank(found, for: query)
            showLRCLIBLoading = false
            guard !results.isEmpty else {
                lrclibFoundNothing = true
                lrclibErrorMessage = ""
                showLRCLIBError = true
                return
            }
            presentResults(results, for: song)
        }
    }

    private func presentResults(_ results: [LyricsCandidate], for song: Song) {
            let vc = LRCLIBResultsViewController(
                results: results,
                song: song,
                tint: song.coverSheetTint,
                onSelect: { candidate in
                    playerVM.importCandidate(candidate, for: song)
                },
                onGenerate: {
                    LyricsGenerator.shared.generate(for: song, in: playerVM.libraryService)
                }
            )
            let nav = UINavigationController(rootViewController: vc)
            nav.navigationBar.prefersLargeTitles = true
            Self.topViewController()?.present(nav, animated: true)
    }

    private static func topViewController(
        base: UIViewController? = {
            // The key window: Now Playing has its own above the app's, and a
            // sheet presented from the app's opened behind the player.
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
            return (scene?.keyWindow ?? scene?.windows.first)?.rootViewController
        }()
    ) -> UIViewController? {
        if let nav = base as? UINavigationController, let visible = nav.visibleViewController {
            return topViewController(base: visible)
        }
        if let presented = base?.presentedViewController {
            return topViewController(base: presented)
        }
        return base
    }
}

@MainActor
private final class LyricsDisplayState: ObservableObject {
    @Published private(set) var lyrics: LRCLyrics?
    @Published private(set) var currentLineID: LyricsLine.ID?
    @Published private(set) var wordTimings: [LyricsLine.ID: [WordTiming]]
    @Published private(set) var trailingLines: Set<LyricsLine.ID>
    @Published private(set) var isVisible: Bool
    @Published private(set) var loadID = 0

    private var cancellables = Set<AnyCancellable>()

    init(playerVM: PlayerViewModel) {
        lyrics = playerVM.currentLyrics
        currentLineID = playerVM.currentLyricLine?.id
        wordTimings = playerVM.currentWordTimings
        trailingLines = playerVM.currentTrailingLines
        isVisible = playerVM.showLyrics

        playerVM.$currentWordTimings
            .dropFirst()
            .sink { [weak self] timings in self?.wordTimings = timings }
            .store(in: &cancellables)

        playerVM.$currentTrailingLines
            .dropFirst()
            .sink { [weak self] lines in self?.trailingLines = lines }
            .store(in: &cancellables)

        playerVM.$currentLyrics
            .sink { [weak self] lyrics in
                guard let self else { return }
                self.lyrics = lyrics
                self.loadID &+= 1
            }
            .store(in: &cancellables)

        playerVM.$currentLyricLine
            .map { $0?.id }
            .removeDuplicates()
            .sink { [weak self] lineID in
                self?.currentLineID = lineID
            }
            .store(in: &cancellables)

        playerVM.$showLyrics
            .removeDuplicates()
            .sink { [weak self] isVisible in
                self?.isVisible = isVisible
            }
            .store(in: &cancellables)
    }
}

private struct TimedLyricsUIKitView: UIViewRepresentable {
    let lyrics: LRCLyrics
    /// Shown after the last line, like the songwriters in Apple Music.
    let credit: String?
    let loadID: Int
    let currentLineID: LyricsLine.ID?
    let wordTimings: [LyricsLine.ID: [WordTiming]]
    /// Lines a second singer sings, aligned to the trailing side.
    let trailingLines: Set<LyricsLine.ID>
    /// Original line → translation, shown small under it.
    let translations: [String: String]
    let isVisible: Bool
    /// The playback position, read every frame while words are lit.
    let currentTime: () -> TimeInterval
    let onSeek: (TimeInterval) -> Void
    let canCorrect: () -> Bool
    let canMark: () -> Bool
    let onCorrect: (LyricsLine, String) -> Void
    let onShare: (LyricsLine) -> Void
    let onMark: (LyricsLine) -> Void

    func makeUIView(context: Context) -> TimedLyricsTableView {
        // Built while the phone turns, its table's default dark background
        // faded out over the whole turn.
        var view: TimedLyricsTableView!
        UIView.performWithoutAnimation { view = TimedLyricsTableView() }
        return view
    }

    func updateUIView(_ view: TimedLyricsTableView, context: Context) {
        let offset = lyrics.offset
        view.configure(lines: lyrics.lines, loadID: loadID, currentLineID: currentLineID) { time in
            // Line timestamps include the [offset:] tag; playback time doesn't.
            onSeek(max(0, time - offset))
        }
        // Word times are on the lyrics' clock, like line timestamps.
        view.setWordTimings(wordTimings) { currentTime() + offset }
        view.setTrailingLines(trailingLines)
        view.setTranslations(translations)
        view.setCredit(credit)
        view.setLyricsVisible(isVisible)
        view.canCorrect = canCorrect
        view.canMark = canMark
        view.onCorrect = onCorrect
        view.onShare = onShare
        view.onMark = onMark
    }

}

/// A display link for drawings that follow the playback position: it rests
/// once playback is paused and the drawing has stopped changing, and wakes
/// as soon as playback resumes or the position moves (a seek).
@MainActor
final class PlaybackDisplayLink {
    private var link: CADisplayLink?
    private var wake: AnyCancellable?
    private var lastTime: TimeInterval?
    private var stillTicks = 0
    private let onTick: @MainActor () -> Void

    init(onTick: @escaping @MainActor () -> Void) {
        self.onTick = onTick
    }

    var isRunning: Bool { link != nil }

    func start() {
        stop()
        let link = CADisplayLink(target: Target(self), selector: #selector(Target.tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
        let player = MusicPlayerService.shared
        // Published on the main actor, where the player lives.
        nonisolated(unsafe) weak var owner = self
        wake = Publishers.Merge(
            player.$isPlaying.removeDuplicates().map { _ in () },
            player.$currentTime.removeDuplicates().map { _ in () }
        ).sink {
            MainActor.assumeIsolated { owner?.wakeUp() }
        }
    }

    func stop() {
        link?.invalidate()
        link = nil
        wake = nil
        stillTicks = 0
        lastTime = nil
    }

    func wakeUp() {
        stillTicks = 0
        link?.isPaused = false
    }

    /// Each tick, the time drawn and whether the drawing has come to rest.
    func note(time: TimeInterval, settled: Bool = true) {
        defer { lastTime = time }
        guard settled, time == lastTime, !MusicPlayerService.shared.isPlaying else {
            stillTicks = 0
            return
        }
        stillTicks += 1
        if stillTicks >= 6 { link?.isPaused = true }
    }

    /// The display link holds its target strongly.
    @MainActor private final class Target {
        weak var owner: PlaybackDisplayLink?
        init(_ owner: PlaybackDisplayLink) { self.owner = owner }
        @objc func tick() { owner?.onTick() }
    }
}

private final class TimedLyricsTableView: UIView, UITableViewDataSource, UITableViewDelegate {
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let edgeFadeMask = CAGradientLayer()
    private let feedback = UIImpactFeedbackGenerator(style: .light)
    private var lines: [LyricsLine] = []
    private var currentLineID: LyricsLine.ID?
    private var currentLineIndex: Int?
    private var linesToken: (loadID: Int, count: Int, first: UUID?, last: UUID?) = (0, 0, nil, nil)
    private var onSeek: ((TimeInterval) -> Void)?
    var canCorrect: (() -> Bool)?
    var canMark: (() -> Bool)?
    var onCorrect: ((LyricsLine, String) -> Void)?
    var onShare: ((LyricsLine) -> Void)?
    var onMark: ((LyricsLine) -> Void)?
    private var autoScrollEnabled = true
    private var isLyricsVisible = false
    private var lastViewportHeight: CGFloat = 0
    private var measuredWidth: CGFloat = 0
    private var rowHeightCache: [LyricsLine.ID: CGFloat] = [:]
    private var pendingOpeningScroll = false
    private var lastPlaybackScrollAt: TimeInterval = 0
    private var openingScrollAnimator: UIViewPropertyAnimator?
    private var resumeAutoScrollWork: DispatchWorkItem?
    private var wordTimings: [LyricsLine.ID: [WordTiming]] = [:]
    private var trailingLines: Set<LyricsLine.ID> = []
    private var translations: [String: String] = [:]
    private var lyricsTime: (() -> TimeInterval)?
    private lazy var wordClock = PlaybackDisplayLink { [weak self] in self?.updateCurrentWords() }
    /// Lyrics on screen right now, and when the last ones left: turning
    /// the phone rebuilds them, and the new ones carry on from the current
    /// line instead of rising from the top again.
    private static var shownCount = 0
    private static var lastShownAt: CFTimeInterval = 0

    override init(frame: CGRect) {
        super.init(frame: frame)

        backgroundColor = .clear
        clipsToBounds = true

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.backgroundColor = .clear
        tableView.isOpaque = false
        tableView.separatorStyle = .none
        tableView.showsVerticalScrollIndicator = false
        tableView.contentInsetAdjustmentBehavior = .never
        // The lyrics fade out on their own: no bar's edge over them (in the
        // Mac's full screen it showed as a gray band).
        if MacApp.isActive {
            tableView.topEdgeEffect.isHidden = true
            tableView.bottomEdgeEffect.isHidden = true
        }
        tableView.estimatedRowHeight = 0
        tableView.keyboardDismissMode = .none
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(TimedLyricsCell.self, forCellReuseIdentifier: TimedLyricsCell.reuseID)
        edgeFadeMask.startPoint = CGPoint(x: 0.5, y: 0)
        edgeFadeMask.endPoint = CGPoint(x: 0.5, y: 1)
        edgeFadeMask.colors = [
            UIColor.clear.cgColor,
            UIColor.black.cgColor,
            UIColor.black.cgColor,
            UIColor.clear.cgColor
        ]
        layer.mask = edgeFadeMask
        addSubview(tableView)

        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: trailingAnchor),
            tableView.topAnchor.constraint(equalTo: topAnchor),
            tableView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        feedback.prepare()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        // The first layout lands at once: during the phone's turn the table
        // grew out of the corner, a dark square under the cover.
        guard tableView.bounds.isEmpty else { return layoutContent() }
        UIView.performWithoutAnimation {
            layoutContent()
            tableView.layoutIfNeeded()
        }
    }

    private func layoutContent() {
        super.layoutSubviews()
        let viewportHeight = bounds.height
        guard viewportHeight > 0 else { return }
        updateLyricsEdgeFade(edgeFadeMask, bounds: tableView.bounds)
        if abs(measuredWidth - bounds.width) > 0.5 {
            measuredWidth = bounds.width
            rowHeightCache.removeAll(keepingCapacity: true)
            tableView.reloadData()
            // Rows change height with the width: once the turn is over, an
            // offset from the other orientation can point past the last
            // line, an empty screen.
            DispatchQueue.main.async { [weak self] in self?.settleAfterResize() }
        }
        guard abs(lastViewportHeight - viewportHeight) > 0.5 else { return }
        lastViewportHeight = viewportHeight
        let centeringInset = max(140, viewportHeight * 0.46)
        // The music video above (upright): the first lines start near the
        // top, not half way down, until the song reaches them. Without it,
        // the first line starts mid-screen as usual.
        let videoAbove = MusicVideoPlayer.shared.shownSongID != nil && traitCollection.verticalSizeClass == .regular
        let topInset = videoAbove ? max(20, viewportHeight * 0.08) : centeringInset
        tableView.contentInset = UIEdgeInsets(top: topInset, left: 0, bottom: centeringInset, right: 0)
        tableView.verticalScrollIndicatorInsets = tableView.contentInset
        if isLyricsVisible && autoScrollEnabled && !pendingOpeningScroll {
            scrollToCurrentLine(animated: false)
        }
    }

    private func settleAfterResize() {
        guard tableView.bounds.height > 0, !tableView.isDragging, !tableView.isDecelerating else { return }
        if isLyricsVisible && autoScrollEnabled && !pendingOpeningScroll {
            scrollToCurrentLine(animated: false)
            return
        }
        let minimumY = -tableView.adjustedContentInset.top
        let maximumY = max(minimumY, tableView.contentSize.height - tableView.bounds.height + tableView.adjustedContentInset.bottom)
        let y = min(max(tableView.contentOffset.y, minimumY), maximumY)
        if y != tableView.contentOffset.y { tableView.setContentOffset(CGPoint(x: 0, y: y), animated: false) }
    }

    func setCredit(_ credit: String?) {
        guard (tableView.tableFooterView as? UILabel)?.text != credit else { return }
        guard let credit else {
            tableView.tableFooterView = nil
            return
        }
        let label = CreditLabel()
        label.text = credit
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = UIColor.white.withAlphaComponent(0.42)
        label.numberOfLines = 0
        label.frame.size.height = 64
        tableView.tableFooterView = label
    }

    /// Indented like the lyrics, below the last line.
    private final class CreditLabel: UILabel {
        override func drawText(in rect: CGRect) {
            super.drawText(in: rect.inset(by: UIEdgeInsets(top: 18, left: 28, bottom: 0, right: 28)))
        }
    }

    func setWordTimings(_ timings: [LyricsLine.ID: [WordTiming]], lyricsTime: @escaping () -> TimeInterval) {
        self.lyricsTime = lyricsTime
        guard timings != wordTimings else { return }
        wordTimings = timings
        updateVisibleCells(animated: false)
        updateWordClock()
    }

    func setTrailingLines(_ lines: Set<LyricsLine.ID>) {
        guard lines != trailingLines else { return }
        trailingLines = lines
        updateVisibleCells(animated: false)
    }

    /// Rows grow to make room, in place, and the current line stays put.
    func setTranslations(_ translations: [String: String]) {
        guard translations != self.translations else { return }
        self.translations = translations
        rowHeightCache.removeAll(keepingCapacity: true)
        updateVisibleCells(animated: false)
        guard window != nil, !lines.isEmpty else { return tableView.reloadData() }
        UIView.animate(withDuration: 0.35, delay: 0, options: [.curveEaseInOut, .allowUserInteraction]) {
            self.tableView.performBatchUpdates(nil)
            if self.isLyricsVisible && self.autoScrollEnabled && !self.pendingOpeningScroll {
                self.scrollToCurrentLine(animated: false)
            }
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateWordClock()
    }

    /// Every frame while synced words show, so they fill as smoothly as
    /// they're sung.
    private func updateWordClock() {
        let shouldRun = window != nil && isLyricsVisible && !wordTimings.isEmpty
        guard shouldRun != wordClock.isRunning else { return }
        wordClock.stop()
        guard shouldRun else { return }
        wordClock.start()
        updateCurrentWords()
    }

    private func updateCurrentWords() {
        guard let row = currentLineIndex, let time = lyricsTime?(),
              let cell = tableView.cellForRow(at: IndexPath(row: row, section: 0)) as? TimedLyricsCell else { return }
        cell.updateWords(at: time)
        wordClock.note(time: time)
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        guard isLyricsVisible, (window == nil) != (newWindow == nil) else { return }
        noteShown(newWindow != nil)
    }

    private func noteShown(_ shown: Bool) {
        Self.shownCount = max(0, Self.shownCount + (shown ? 1 : -1))
        if !shown { Self.lastShownAt = CACurrentMediaTime() }
    }

    func setLyricsVisible(_ isVisible: Bool) {
        guard isLyricsVisible != isVisible else { return }
        // Others still on screen, or just gone: the same lyrics rebuilt.
        let continues = Self.shownCount > 0 || CACurrentMediaTime() - Self.lastShownAt < 0.6
        isLyricsVisible = isVisible
        if window != nil { noteShown(isVisible) }
        defer { updateWordClock() }

        if isVisible {
            autoScrollEnabled = true
            lastPlaybackScrollAt = 0
            updateVisibleCells(animated: false)
            if continues {
                pendingOpeningScroll = false
                DispatchQueue.main.async { [weak self] in self?.scrollToCurrentLine(animated: false) }
            } else {
                beginOpeningScroll()
            }
        } else {
            pendingOpeningScroll = false
            if let openingScrollAnimator {
                openingScrollAnimator.stopAnimation(false)
                openingScrollAnimator.finishAnimation(at: .current)
                self.openingScrollAnimator = nil
            }
        }
    }

    func configure(
        lines: [LyricsLine],
        loadID: Int,
        currentLineID: LyricsLine.ID?,
        onSeek: @escaping (TimeInterval) -> Void
    ) {
        self.onSeek = onSeek

        let token = (loadID, lines.count, lines.first?.id, lines.last?.id)
        let linesChanged = token != linesToken
        if linesChanged {
            self.lines = lines
            linesToken = token
            autoScrollEnabled = true
            pendingOpeningScroll = true
            rowHeightCache.removeAll(keepingCapacity: true)
            tableView.reloadData()
        }

        let currentLineChanged = self.currentLineID != currentLineID
        self.currentLineID = currentLineID
        currentLineIndex = currentLineID.flatMap { id in lines.firstIndex(where: { $0.id == id }) }
        guard linesChanged || currentLineChanged else { return }

        if linesChanged {
            if isLyricsVisible {
                beginOpeningScroll()
            }
            return
        }

        // Always update visual highlights/opacities when the current line changes and lyrics are visible,
        // even if the user has scrolled manually (autoScrollEnabled == false).
        if isLyricsVisible {
            updateVisibleCells(animated: true)
            updateCurrentWords()
        }

        // Auto-scrolling is only performed if auto-scroll is enabled and we are not in opening scroll
        guard isLyricsVisible, autoScrollEnabled, !pendingOpeningScroll else {
            return
        }

        let now = CACurrentMediaTime()
        if now - lastPlaybackScrollAt < 0.3 {
            scrollToCurrentLine(animated: false)
            return
        }
        lastPlaybackScrollAt = now
        DispatchQueue.main.async { [weak self] in
            self?.scrollToCurrentLine(
                animated: true,
                duration: 0.45,
                curve: .curveEaseOut,
                usesGentleDeceleration: true
            )
        }
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        lines.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: TimedLyricsCell.reuseID, for: indexPath) as! TimedLyricsCell
        configure(cell, at: indexPath, animated: false)
        return cell
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        guard lines.indices.contains(indexPath.row) else { return 56 }
        let line = lines[indexPath.row]
        if let cached = rowHeightCache[line.id] { return cached }
        let availableWidth = max(1, tableView.bounds.width - 56)
        let text = TimedLyricsCell.displayText(for: line)
        var height = TimedLyricsCell.textHeight(text, font: TimedLyricsCell.lyricFont, width: availableWidth) + 18
        if !line.isInstrumentalGap, let translation = translations[line.text] {
            height += TimedLyricsCell.translationSpacing + TimedLyricsCell.textHeight(translation, font: TimedLyricsCell.translationFont, width: availableWidth)
        }
        rowHeightCache[line.id] = height
        return height
    }

    func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        guard lines.indices.contains(indexPath.row) else { return nil }
        let line = lines[indexPath.row]
        guard !line.isInstrumentalGap else { return nil }
        let corrects = canCorrect?() == true
        let marks = canMark?() == true
        // The hold stops the follow: the menu's line stays where it is.
        autoScrollEnabled = false
        resumeAutoScrollWork?.cancel()
        return fixedContextMenu(identifier: nil, previewProvider: nil) { [weak self] _ in
            var children: [UIMenuElement] = [
                UIAction(title: String(localized: "Share Lyrics…"), image: UIImage(systemName: "square.and.arrow.up")) { _ in self?.onShare?(line) }
            ]
            if corrects {
                children.append(UIAction(title: String(localized: "Correct Line…"), image: UIImage(systemName: "pencil")) { _ in self?.askCorrection(for: line) })
            }
            if marks {
                children.append(UIAction(title: String(localized: "Song Start & Outro…"), image: UIImage(systemName: "text.line.first.and.arrowtriangle.forward")) { _ in self?.onMark?(line) })
            }
            return UIMenu(children: children)
        }
    }

    func tableView(_ tableView: UITableView, previewForHighlightingContextMenuWithConfiguration configuration: UIContextMenuConfiguration) -> UITargetedPreview? {
        nil
    }

    func tableView(_ tableView: UITableView, willEndContextMenuInteraction configuration: UIContextMenuConfiguration, animator: UIContextMenuInteractionAnimating?) {
        scheduleAutoScrollResume()
    }

    private func askCorrection(for line: LyricsLine) {
        guard var top = window?.rootViewController else { return }
        while let presented = top.presentedViewController { top = presented }
        let alert = UIAlertController(title: String(localized: "Correct Line"), message: nil, preferredStyle: .alert)
        alert.addTextField { field in
            field.text = line.text
            field.autocapitalizationType = .sentences
            field.clearButtonMode = .whileEditing
        }
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "Save"), style: .default) { [weak self, weak alert] _ in
            let text = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty, text != line.text else { return }
            self?.onCorrect?(line, text)
        })
        top.present(alert, animated: true)
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: false)
        guard lines.indices.contains(indexPath.row) else { return }
        let line = lines[indexPath.row]
        autoScrollEnabled = true
        currentLineID = line.id
        currentLineIndex = indexPath.row
        feedback.impactOccurred(intensity: 0.55)
        feedback.prepare()
        updateVisibleCells(animated: true)
        scrollToCurrentLine(animated: true, duration: 0.24, curve: .curveEaseOut)
        onSeek?(line.time)
        updateCurrentWords()
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        autoScrollEnabled = false
        resumeAutoScrollWork?.cancel()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { scheduleAutoScrollResume() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        scheduleAutoScrollResume()
    }

    /// Like Music: after browsing the lyrics, follow the song again.
    private func scheduleAutoScrollResume() {
        resumeAutoScrollWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.tableView.isDragging, !self.tableView.isDecelerating else { return }
            self.autoScrollEnabled = true
            self.scrollToCurrentLine(animated: true, duration: 0.6, curve: .curveEaseOut, usesGentleDeceleration: true)
        }
        resumeAutoScrollWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    private func beginOpeningScroll() {
        pendingOpeningScroll = true
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isLyricsVisible else { return }
            self.tableView.layoutIfNeeded()
            self.tableView.setContentOffset(
                CGPoint(x: 0, y: -self.tableView.adjustedContentInset.top),
                animated: false
            )
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isLyricsVisible else { return }
                self.pendingOpeningScroll = false
                self.scrollToCurrentLine(
                    animated: true,
                    duration: 0.60,
                    curve: .curveEaseOut,
                    usesGentleDeceleration: true
                )
            }
        }
    }

    private func updateVisibleCells(animated: Bool) {
        for indexPath in tableView.indexPathsForVisibleRows ?? [] {
            guard let cell = tableView.cellForRow(at: indexPath) as? TimedLyricsCell else { continue }
            configure(cell, at: indexPath, animated: animated)
        }
    }

    private func configure(_ cell: TimedLyricsCell, at indexPath: IndexPath, animated: Bool) {
        // A cell (re)drawn while the clock rests is brought to the sung point.
        wordClock.wakeUp()
        guard lines.indices.contains(indexPath.row) else { return }
        cell.configure(
            line: lines[indexPath.row],
            wordTimings: wordTimings[lines[indexPath.row].id],
            isTrailing: trailingLines.contains(lines[indexPath.row].id),
            translation: translations[lines[indexPath.row].text],
            isCurrent: lines[indexPath.row].id == currentLineID,
            isPast: currentLineIndex.map { indexPath.row < $0 } ?? false,
            animated: animated
        )
    }

    private func scrollToCurrentLine(
        animated: Bool,
        duration: TimeInterval = 0.48,
        curve: UIView.AnimationOptions = .curveEaseInOut,
        usesGentleDeceleration: Bool = false
    ) {
        guard tableView.bounds.height > 0, !lines.isEmpty else { return }

        tableView.layoutIfNeeded()
        let minimumY = -tableView.adjustedContentInset.top
        // Before the first line (the song restarted): back to the top.
        let row = currentLineID.flatMap { id in lines.firstIndex { $0.id == id } }
        let proposedY = row.map { tableView.rectForRow(at: IndexPath(row: $0, section: 0)).midY - tableView.bounds.height * 0.5 } ?? minimumY
        let maximumY = max(minimumY, tableView.contentSize.height - tableView.bounds.height + tableView.adjustedContentInset.bottom)
        let target = CGPoint(x: 0, y: min(max(proposedY, minimumY), maximumY))

        guard animated else {
            openingScrollAnimator?.stopAnimation(true)
            openingScrollAnimator = nil
            tableView.setContentOffset(target, animated: false)
            return
        }

        if let openingScrollAnimator {
            openingScrollAnimator.stopAnimation(false)
            openingScrollAnimator.finishAnimation(at: .current)
            self.openingScrollAnimator = nil
        }

        if usesGentleDeceleration {
            let timing = UISpringTimingParameters(dampingRatio: 1, initialVelocity: .zero)
            let animator = UIViewPropertyAnimator(duration: duration + 0.15, timingParameters: timing)
            animator.addAnimations {
                self.tableView.setContentOffset(target, animated: false)
            }
            animator.addCompletion { [weak self, weak animator] _ in
                guard self?.openingScrollAnimator === animator else { return }
                self?.openingScrollAnimator = nil
            }
            openingScrollAnimator = animator
            animator.startAnimation()
            return
        }

        UIView.animate(
            withDuration: duration,
            delay: 0,
            options: [.allowUserInteraction, .beginFromCurrentState, curve],
            animations: {
                self.tableView.setContentOffset(target, animated: false)
            }
        )
    }
}

private final class TimedLyricsCell: UITableViewCell {
    static let reuseID = "TimedLyricsCell"
    static let lyricFont = UIFont.systemFont(ofSize: 30, weight: .bold)
    static let gapText = "• • •"
    static let translationFont = UIFont.systemFont(ofSize: 18, weight: .semibold)
    static let translationSpacing: CGFloat = 4
    private let lyricLabel = UILabel()
    /// The line in the language picked in Settings, small under it.
    private let translationLabel = UILabel()
    /// Shown instead of the label for lines synced word by word.
    private let wordView = WordSyncedLineView()
    private var line: LyricsLine?
    private var wordTimings: [WordTiming]?
    private var isTrailing = false
    private var isCurrent = false

    /// What carries the line's highlight: the label, or the synced words.
    private var lineView: UIView {
        wordTimings == nil ? lyricLabel : wordView
    }

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)

        backgroundColor = .clear
        contentView.backgroundColor = .clear
        selectionStyle = .none

        lyricLabel.font = Self.lyricFont
        lyricLabel.textColor = .white
        lyricLabel.numberOfLines = 0
        lyricLabel.textAlignment = .natural
        contentView.addSubview(lyricLabel)
        wordView.isHidden = true
        contentView.addSubview(wordView)
        translationLabel.font = Self.translationFont
        translationLabel.textColor = .white
        translationLabel.numberOfLines = 0
        translationLabel.isHidden = true
        contentView.addSubview(translationLabel)
    }

    static func textHeight(_ text: String, font: UIFont, width: CGFloat) -> CGFloat {
        ceil((text as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font],
            context: nil
        ).height)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let area = contentView.bounds.inset(by: UIEdgeInsets(top: 9, left: 28, bottom: 9, right: 28))
        if translationLabel.isHidden {
            lyricLabel.frame = area
        } else {
            let lyricHeight = Self.textHeight(lyricLabel.text ?? "", font: Self.lyricFont, width: area.width)
            lyricLabel.frame = CGRect(x: area.minX, y: area.minY, width: area.width, height: lyricHeight)
            translationLabel.frame = CGRect(x: area.minX, y: lyricLabel.frame.maxY + Self.translationSpacing, width: area.width, height: max(0, area.maxY - lyricLabel.frame.maxY - Self.translationSpacing))
        }
        wordView.frame = lyricLabel.frame
        if let line, let wordTimings {
            wordView.configure(text: line.text, timings: wordTimings, font: Self.lyricFont, alignment: alignment)
        }
    }

    /// A second singer's lines sit on the trailing side, like Music's duets.
    private var alignment: NSTextAlignment {
        isTrailing ? (effectiveUserInterfaceLayoutDirection == .rightToLeft ? .left : .right) : .natural
    }

    /// Lights the current line's words up to `time` (on the lyrics' clock).
    func updateWords(at time: TimeInterval) {
        guard isCurrent, wordTimings != nil else { return }
        wordView.update(at: time)
    }

    static func displayText(for line: LyricsLine) -> String {
        line.isInstrumentalGap ? gapText : line.text
    }

    /// Alpha (not text color, which UIKit can't animate) carries the highlight,
    /// so the current line fades in smoothly like in Apple Music.
    ///
    /// A line synced word by word lights up as it's sung instead: while
    /// current, its unsung words keep the upcoming lines' dimness, so it
    /// changes without a flash either way.
    func configure(line: LyricsLine, wordTimings: [WordTiming]?, isTrailing: Bool = false, translation: String? = nil, isCurrent: Bool, isPast: Bool, animated: Bool) {
        let isNewLine = self.line?.id != line.id
        let wordTimings = line.isInstrumentalGap ? nil : wordTimings
        if isNewLine || (self.wordTimings == nil) != (wordTimings == nil) {
            lyricLabel.layer.removeAllAnimations()
            wordView.layer.removeAllAnimations()
        }
        self.line = line
        self.wordTimings = wordTimings
        self.isTrailing = isTrailing
        lyricLabel.textAlignment = alignment
        lyricLabel.text = Self.displayText(for: line)
        lyricLabel.isHidden = wordTimings != nil
        wordView.isHidden = wordTimings == nil
        let translation = line.isInstrumentalGap ? nil : translation
        if translationLabel.text != translation || translationLabel.isHidden != (translation == nil) {
            translationLabel.text = translation
            translationLabel.textAlignment = alignment
            translationLabel.isHidden = translation == nil
            setNeedsLayout()
        }
        if let wordTimings {
            wordView.configure(text: line.text, timings: wordTimings, font: Self.lyricFont, alignment: alignment)
        }

        let wasCurrent = self.isCurrent && !isNewLine
        self.isCurrent = isCurrent
        let alpha: CGFloat = isCurrent ? 1 : (isPast ? 0.3 : 0.42)
        // Quieter than the line it translates.
        let translationAlpha = alpha * 0.62
        if animated, translationLabel.alpha != translationAlpha {
            UIView.animate(withDuration: isCurrent ? 0.3 : 0.5, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState, .curveEaseOut]) {
                self.translationLabel.alpha = translationAlpha
            }
        } else {
            translationLabel.alpha = translationAlpha
        }
        let view = lineView
        if wordTimings != nil {
            if isCurrent {
                // Also when the words came after the line turned current:
                // left whole, its unsung words drew nothing.
                if !wasCurrent || !wordView.isSinging { wordView.beginSinging() }
                // Unsung words are as dim as the line was: no fade needed.
                view.layer.removeAllAnimations()
                view.alpha = 1
                return
            }
            wordView.showWhole(animated: animated && wasCurrent)
        }
        guard animated, view.alpha != alpha else {
            view.layer.removeAllAnimations()
            view.alpha = alpha
            return
        }
        UIView.animate(
            withDuration: isCurrent ? 0.3 : 0.5,
            delay: 0,
            options: [.allowUserInteraction, .beginFromCurrentState, .curveEaseOut],
            animations: { view.alpha = alpha }
        )
    }
}

/// A lyric line lit word by word as it's sung, like Apple Music: each word
/// fills from the left behind a soft edge and glows as it's sung, held
/// notes most. The line is laid out exactly like the label it
/// replaces.
private final class WordSyncedLineView: UIView {
    /// How dim unsung words are: the same as upcoming lines.
    private static let unsungOpacity: Float = 0.42
    /// Held at least this long, a word glows.
    private static let fullBloom: TimeInterval = 1
    /// Room around the glyphs for the glow and accents.
    private static let padding: CGFloat = 8

    private struct Word {
        let container: CALayer
        let unsung: CALayer
        let sung: CALayer
        let fill: CAGradientLayer
        let timing: WordTiming
        /// The soft edge, as a share of the word's width.
        let edge: CGFloat
    }

    private var words: [Word] = []
    private var layoutKey: (text: String, width: CGFloat, timings: [WordTiming], alignment: NSTextAlignment)?
    /// Each word's last drawn progress, so idle frames cost nothing.
    private var drawnProgress: [CGFloat] = []
    private(set) var isSinging = false

    func configure(text: String, timings: [WordTiming], font: UIFont, alignment: NSTextAlignment = .natural) {
        let width = bounds.width
        guard width > 0 else { return }
        if let layoutKey, layoutKey.text == text, layoutKey.width == width, layoutKey.timings == timings, layoutKey.alignment == alignment { return }
        layoutKey = (text, width, timings, alignment)
        build(text: text, timings: timings, font: font, width: width, alignment: alignment)
    }

    private func build(text: String, timings: [WordTiming], font: UIFont, width: CGFloat, alignment: NSTextAlignment) {
        words.forEach { $0.container.removeFromSuperlayer() }
        words = []
        drawnProgress = []

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        let storage = NSTextStorage(string: text, attributes: [.font: font, .foregroundColor: UIColor.white, .paragraphStyle: paragraph])
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        let glyphs = layoutManager.glyphRange(for: container)
        let used = layoutManager.usedRect(for: container)

        // The whole line drawn once; every word shows its own part of it.
        let padding = Self.padding
        let imageSize = CGSize(width: width + padding * 2, height: ceil(used.maxY) + padding * 2)
        let format = UIGraphicsImageRendererFormat.preferred()
        let image = UIGraphicsImageRenderer(size: imageSize, format: format).image { _ in
            layoutManager.drawGlyphs(forGlyphRange: glyphs, at: CGPoint(x: padding, y: padding))
        }
        guard let cgImage = image.cgImage else { return }

        // A word that wraps ("self-/control") is one piece per line, its
        // time shared out by width: as a single box spanning both lines it
        // lit the start of the next line before this one had finished.
        var pieces: [(rect: CGRect, timing: WordTiming)] = []
        let ranges = LyricWords.ranges(in: text)
        for (range, timing) in zip(ranges, timings) {
            let glyphRange = layoutManager.glyphRange(forCharacterRange: NSRange(range, in: text), actualCharacterRange: nil)
            var rects: [CGRect] = []
            layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { _, _, _, lineRange, _ in
                let part = NSIntersectionRange(glyphRange, lineRange)
                guard part.length > 0 else { return }
                rects.append(layoutManager.boundingRect(forGlyphRange: part, in: container))
            }
            if rects.isEmpty { rects = [layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)] }
            let total = max(rects.reduce(0) { $0 + $1.width }, 1)
            var start = timing.start
            for rect in rects {
                let end = rect == rects.last ? timing.end : start + (timing.end - timing.start) * rect.width / total
                pieces.append((rect, WordTiming(start: start, end: end)))
                start = end
            }
        }
        for (wordRect, timing) in pieces {
            let rect = wordRect.insetBy(dx: -3, dy: -padding / 2)
            let contentsRect = CGRect(
                x: (rect.minX + padding) / imageSize.width,
                y: (rect.minY + padding) / imageSize.height,
                width: rect.width / imageSize.width,
                height: rect.height / imageSize.height
            )

            let word = CALayer()
            word.frame = rect
            word.shadowColor = UIColor.white.cgColor
            word.shadowOffset = .zero
            word.shadowRadius = 7
            let unsung = CALayer()
            let sung = CALayer()
            for part in [unsung, sung] {
                part.frame = word.bounds
                part.contents = cgImage
                part.contentsRect = contentsRect
                part.contentsScale = image.scale
                word.addSublayer(part)
            }
            let fill = CAGradientLayer()
            fill.frame = word.bounds
            fill.startPoint = CGPoint(x: 0, y: 0.5)
            fill.endPoint = CGPoint(x: 1, y: 0.5)
            fill.colors = [UIColor.black.cgColor, UIColor.black.cgColor, UIColor.clear.cgColor, UIColor.clear.cgColor]
            sung.mask = fill
            layer.addSublayer(word)
            words.append(Word(container: word, unsung: unsung, sung: sung, fill: fill, timing: timing, edge: min(0.6, 16 / max(rect.width, 1))))
        }
        drawnProgress = Array(repeating: -1, count: words.count)
        buildSweep()
        if isSinging {
            beginSinging()
        } else {
            showWhole(animated: false)
        }
    }

    /// The line about to be sung: every word unlit, as dim as it was.
    func beginSinging() {
        isSinging = true
        withoutAnimations {
            for index in words.indices {
                // A reused cell's fade out of its last line would hide them.
                words[index].unsung.removeAllAnimations()
                words[index].unsung.opacity = Self.unsungOpacity
                draw(index, progress: 0)
            }
        }
    }

    /// Not the current line: all its words alike.
    func showWhole(animated: Bool) {
        isSinging = false
        let apply = {
            for index in self.words.indices {
                self.words[index].unsung.opacity = 0
                self.draw(index, progress: 1, settled: true)
            }
        }
        if animated {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.5)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
            apply()
            CATransaction.commit()
        } else {
            withoutAnimations(apply)
        }
    }

    // MARK: Sweep

    /// The fill runs through the line in one movement: each word starts at
    /// its own time and lasts until the next one starts, and the speed eases
    /// between words instead of jumping, so the fill never stops mid-line
    /// but slows down and speeds up with the singing.
    /// When the fill reaches each word's start (and the line's end): at the
    /// n-th time it's at position n, in words (2.5 is halfway through the
    /// third word).
    private var sweepTimes: [TimeInterval] = []
    /// The fill's speed at each of `sweepTimes`, in words per second.
    private var sweepSlopes: [Double] = []

    private func buildSweep() {
        guard let last = words.last else {
            sweepTimes = []
            sweepSlopes = []
            return
        }
        var times = words.map(\.timing.start) + [max(last.timing.end, last.timing.start + 0.05)]
        for index in times.indices.dropFirst() where times[index] <= times[index - 1] {
            times[index] = times[index - 1] + 0.02
        }
        // Monotone cubic (Fritsch–Carlson): smooth, and never runs backwards.
        let count = times.count
        let secants = (0..<(count - 1)).map { 1 / (times[$0 + 1] - times[$0]) }
        var slopes = [Double](repeating: 0, count: count)
        slopes[0] = secants[0]
        slopes[count - 1] = secants[count - 2]
        for index in 1..<(count - 1) {
            let before = secants[index - 1]
            let after = secants[index]
            // Harmonic mean: a slow word next to a quick one doesn't overshoot.
            slopes[index] = 2 / (1 / before + 1 / after)
        }
        sweepTimes = times
        sweepSlopes = slopes
    }

    /// How far the fill is through the line at `time`, in words.
    private func sweepPosition(at time: TimeInterval) -> Double {
        guard let first = sweepTimes.first, let last = sweepTimes.last else { return 0 }
        if time <= first { return 0 }
        if time >= last { return Double(sweepTimes.count - 1) }
        var low = 0
        var high = sweepTimes.count - 1
        while high - low > 1 {
            let middle = (low + high) / 2
            if sweepTimes[middle] <= time { low = middle } else { high = middle }
        }
        let span = sweepTimes[high] - sweepTimes[low]
        let t = (time - sweepTimes[low]) / span
        let t2 = t * t
        let t3 = t2 * t
        let position = (2 * t3 - 3 * t2 + 1) * Double(low)
            + (t3 - 2 * t2 + t) * span * sweepSlopes[low]
            + (-2 * t3 + 3 * t2) * Double(high)
            + (t3 - t2) * span * sweepSlopes[high]
        return min(max(position, Double(low)), Double(high))
    }

    func update(at time: TimeInterval) {
        if !isSinging { beginSinging() }
        let position = sweepPosition(at: time)
        withoutAnimations {
            for index in words.indices {
                draw(index, progress: CGFloat(min(max(position - Double(index), 0), 1)))
            }
        }
    }

    private func draw(_ index: Int, progress: CGFloat, settled: Bool = false) {
        let key = settled ? 2 : progress
        guard drawnProgress[index] != key else { return }
        drawnProgress[index] = key
        let word = words[index]

        // The lit part's edge sweeps past the word's end, so it ends fully lit.
        let edge = word.edge
        let front = progress * (1 + edge)
        word.fill.locations = [0, NSNumber(value: Double(front - edge)), NSNumber(value: Double(front)), 1]

        var glow: Float = 0
        if !settled, progress > 0, progress < 1 {
            // Every word glows as it fills, then settles; held notes most.
            let held = sweepTimes.indices.contains(index + 1) ? sweepTimes[index + 1] - sweepTimes[index] : 0
            let strength = 0.55 + 0.45 * min(max(held / Self.fullBloom, 0), 1)
            glow = Float(0.55 * sin(.pi * progress) * strength)
        }
        word.container.shadowOpacity = glow
    }

    private func withoutAnimations(_ changes: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        changes()
        CATransaction.commit()
    }
}

private struct PlainLyricsUIKitView: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> PlainLyricsTextView {
        var view: PlainLyricsTextView!
        UIView.performWithoutAnimation { view = PlainLyricsTextView() }
        return view
    }

    func updateUIView(_ view: PlainLyricsTextView, context: Context) {
        view.configure(text: text)
    }

}

private final class PlainLyricsTextView: UIView {
    private let textView = UITextView()
    private var renderedText = ""
    private let edgeFadeMask = CAGradientLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        clipsToBounds = true

        textView.backgroundColor = .clear
        textView.isOpaque = false
        textView.isEditable = false
        textView.isSelectable = false
        textView.isScrollEnabled = true
        textView.alwaysBounceVertical = true
        textView.showsVerticalScrollIndicator = false
        textView.contentInsetAdjustmentBehavior = .never
        textView.textContainerInset = UIEdgeInsets(top: 34, left: 23, bottom: 54, right: 23)
        textView.textContainer.lineFragmentPadding = 5
        addSubview(textView)

        edgeFadeMask.startPoint = CGPoint(x: 0.5, y: 0)
        edgeFadeMask.endPoint = CGPoint(x: 0.5, y: 1)
        edgeFadeMask.colors = [
            UIColor.clear.cgColor,
            UIColor.black.cgColor,
            UIColor.black.cgColor,
            UIColor.clear.cgColor
        ]
        layer.mask = edgeFadeMask
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        textView.frame = bounds
        updateLyricsEdgeFade(edgeFadeMask, bounds: bounds)
    }

    func configure(text: String) {
        guard renderedText != text else { return }
        renderedText = text

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 8
        let content = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: UIFont.systemFont(ofSize: 26, weight: .bold),
                .foregroundColor: UIColor.label.withAlphaComponent(0.92),
                .paragraphStyle: paragraph
            ]
        )
        content.append(NSAttributedString(
            string: "\n\nThe associated LRC file is not synced.",
            attributes: [
                .font: UIFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: UIColor.label.withAlphaComponent(0.42)
            ]
        ))
        textView.attributedText = content
    }
}

private func updateLyricsEdgeFade(_ mask: CAGradientLayer, bounds: CGRect) {
    guard bounds.height > 0 else { return }
    let topFade = min(42 / bounds.height, 0.16)
    let bottomFade = max(topFade, 1 - min(62 / bounds.height, 0.2))

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    mask.frame = CGRect(origin: .zero, size: bounds.size)
    mask.locations = [0, NSNumber(value: Double(topFade)), NSNumber(value: Double(bottomFade)), 1]
    CATransaction.commit()
}

struct TintedSpinner: UIViewRepresentable {
    let color: UIColor

    func makeUIView(context: Context) -> UIActivityIndicatorView {
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.color = color
        spinner.startAnimating()
        return spinner
    }

    func updateUIView(_ uiView: UIActivityIndicatorView, context: Context) {
        uiView.color = color
    }
}
