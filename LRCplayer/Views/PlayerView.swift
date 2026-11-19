import SwiftUI
import MediaPlayer
import AVKit
import UIKit
import Combine

/// Fullscreen Now Playing. Presented as a full-screen cover that zooms out of
/// the mini player (and back into it on swipe down), like Apple Music.
struct PlayerView: View {
    @ObservedObject var playerVM: PlayerViewModel
    @ObservedObject var libraryVM: LibraryViewModel
    /// False when the presenting card draws the backdrop itself.
    var drawsBackground = true
    @EnvironmentObject private var router: AppRouter
    @State private var showQueueSheet = false
    @State private var scrubbingTime: TimeInterval?
    @State private var playlistPickerSong: Song?
    @State private var lyricsSurfaceReady = false
    /// Turning from one side to the other keeps the same size: this redraws.
    @State private var topOnTheRight = PlayerView.isTopOnTheRight
    @AppStorage(NowPlayingArtworkStyle.storageKey) private var fullScreenArtworkSetting = false
    @AppStorage("hiddenSettingsUnlocked") private var hiddenSettingsUnlocked = false
    /// A hidden feature: off for anyone without hidden settings showing.
    private var fullScreenArtwork: Bool { fullScreenArtworkSetting && hiddenSettingsUnlocked }
    @AppStorage(MotionArtworkService.storageKey) private var motionArtwork = true
    @ObservedObject private var motion = MotionArtworkState.shared
    @ObservedObject private var musicVideo = MusicVideoPlayer.shared
    @State private var videoPickerSong: Song?
    private let transitionAnchors = PlayerModeTransitionAnchors.nowPlaying
    /// Where the short landscape player's cover flies from and to.
    @StateObject private var flightAnchors = PlayerModeTransitionAnchors()

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if drawsBackground {
                    PlayerBackgroundRepresentable(artwork: playerVM.currentSong?.artworkSource)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                }

                if Self.isShortLandscape(geometry.size) {
                    shortLandscapeLayout(in: geometry)
                } else if Self.isSideBySide(geometry.size) {
                    sideBySideLayout(in: geometry)
                } else {
                    stackedLayout(in: geometry)
                }
            }
        }
        .ignoresSafeArea()
        .overlay(alignment: .top) {
            StatusToast(message: playerVM.playbackError ?? musicVideo.message, showsProgress: playerVM.playbackError == nil && (musicVideo.isSearching || musicVideo.isLoadingVideo),
                        tint: playerVM.currentSong?.coverMenuTint)
                .padding(.top, 44)
        }
        .onGeometryChange(for: CGSize.self, of: \.size) { _ in
            topOnTheRight = Self.isTopOnTheRight
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            // The interface turns a moment after the device does.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                topOnTheRight = Self.isTopOnTheRight
            }
        }
        .environment(\.colorScheme, .dark)
        .statusBarHidden(false)
        .sheet(isPresented: $showQueueSheet) {
            PlayerQueueSheet(playerVM: playerVM)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $playlistPickerSong) { song in
            PlayerPlaylistPickerSheet(song: song)
        }
        .sheet(item: $videoPickerSong) { song in
            MusicVideoPickerSheet(song: song)
        }
        .onChange(of: musicVideo.picksAnotherVideo) { _, picks in
            guard picks else { return }
            musicVideo.picksAnotherVideo = false
            videoPickerSong = playerVM.currentSong
        }
        .onChange(of: playerVM.currentSong?.id, initial: true) {
            musicVideo.setSong(playerVM.currentSong)
            motion.setSong(playerVM.currentSong)
            updateStill()
        }
        .onChange(of: fullScreenArtwork) { updateStill() }
        .onChange(of: motion.video) { updateStill() }
        .onChange(of: motionArtwork) {
            motion.refresh(for: playerVM.currentSong)
        }
        .onChange(of: playerVM.isPlaying, initial: true) { _, playing in
            motion.isPlaying = playing
        }
        .onChange(of: playerVM.showLyrics, initial: true) { _, shows in
            musicVideo.isSuppressed = shows
            motion.isDimmed = shows
            updateStill()
        }
        .task {
            // The lyrics surface is built once the first opening has settled.
            // (The cover pager is built up front: the player is prepared before
            // it is first shown, and swapping it in later made the cover blink.)
            try? await Task.sleep(for: .milliseconds(600))
            lyricsSurfaceReady = true
        }
    }

    /// A wide, short screen (an unfolded iPhone Duo or an iPad held
    /// sideways): the cover and controls make a column, lyrics go beside it.
    static func isSideBySide(_ size: CGSize) -> Bool {
        size.width >= 700 && size.width > size.height * 1.15
    }

    /// An iPhone turned sideways: too short for a column under the cover.
    static func isShortLandscape(_ size: CGSize) -> Bool {
        size.width > size.height * 1.15 && size.height < 500
    }

    /// The cover or the lyrics on the left, the title and controls on the
    /// right, both in the screen's whole height.
    private func shortLandscapeLayout(in geometry: GeometryProxy) -> some View {
        let insets = Self.deviceInsets
        let top = topSafePadding(from: geometry) + 20
        let bottom = max(16, insets.bottom + 4)
        let controlsWidth = min(max(geometry.size.width * 0.42, 320), 420)
        let artworkSize = max(140, geometry.size.height - top - bottom - 40)
        let showsLyrics = playerVM.showLyrics
        // The cover stays on the phone's top half whichever way it turns:
        // with the top to the right, the sides swap.
        let mirrored = topOnTheRight

        return ZStack(alignment: .top) {
            HStack(spacing: 0) {
                ZStack {
                    FullscreenCoverPager(
                        previousSong: playerVM.previousSongPreview,
                        currentSong: playerVM.currentSong,
                        nextSong: playerVM.nextSongPreview,
                        artworkSize: artworkSize,
                        artworkScale: artworkScale,
                        allowsPaging: true,
                        resetID: 0,
                        transitionAnchors: transitionAnchors,
                        onPrevious: { playerVM.previousTrack() },
                        onNext: { playerVM.next() }
                    )
                    .frame(height: artworkSize + 40)
                    .mask { Rectangle().padding(.vertical, -80) }
                    .overlay {
                        NativePlayerTransitionAnchor(role: .large, anchors: transitionAnchors)
                            .frame(width: coverAnchorSize(artworkSize * artworkScale).width, height: coverAnchorSize(artworkSize * artworkScale).height)
                            .allowsHitTesting(false)
                    }
                    .overlay {
                        NativePlayerTransitionAnchor(role: .large, anchors: flightAnchors)
                            .frame(width: coverAnchorSize(artworkSize * artworkScale).width, height: coverAnchorSize(artworkSize * artworkScale).height)
                            .allowsHitTesting(false)
                    }
                    .opacity(showsLyrics ? 0 : 1)
                    .allowsHitTesting(!showsLyrics)

                    if showsLyrics {
                        LyricsView(playerVM: playerVM)
                            .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(mirrored ? .trailing : .leading, mirrored ? insets.right : insets.left)
                .environment(\.layoutDirection, .leftToRight)

                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    songInfoRow(showsArtwork: showsLyrics)
                        .padding(.bottom, 10)
                    if !showsLyrics {
                        NowPlayingLyricPreview(playerVM: playerVM)
                    }
                    playbackSection
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 24)
                .frame(width: controlsWidth)
                .padding(mirrored ? .leading : .trailing, mirrored ? insets.left : insets.right)
                .environment(\.layoutDirection, .leftToRight)
            }
            .environment(\.layoutDirection, mirrored ? .rightToLeft : .leftToRight)
            .padding(.top, top)
            .padding(.bottom, bottom)

            // The cover flies between its place and the title's side, like
            // the portrait player's.
            CoverFlightOverlay(showsLyrics: showsLyrics, artwork: playerVM.currentSong?.artworkSource, anchors: flightAnchors, covers: transitionAnchors)
                .allowsHitTesting(false)

            grabber
                .padding(.top, topSafePadding(from: geometry))
        }
        .frame(width: geometry.size.width, height: geometry.size.height)
        .animation(.smooth(duration: 0.4), value: showsLyrics)
    }

    /// Cover or lyrics above the controls, like Music on iPhone.
    private func stackedLayout(in geometry: GeometryProxy) -> some View {
        let bleeds = bleedsArtwork(in: geometry)
        // This layout is the upright one: the video stands in for the cover
        // from its first frame, decided here rather than in the cover's
        // builder, which runs outside this body as the phone turns back.
        let hidesCover = motion.videoHidesCover
        return VStack(spacing: 0) {
            // Full-screen artwork rises behind the grabber, which then
            // floats over it.
            if !bleeds {
                grabber
                    .padding(.top, topSafePadding(from: geometry))
            }

            NativePlayerModeTransition(
                showsLyrics: playerVM.showLyrics,
                contentID: PlayerModeContentID(
                    songID: playerVM.currentSong?.id,
                    previousSongID: playerVM.previousSongPreview?.id,
                    nextSongID: playerVM.nextSongPreview?.id,
                    isPlaying: playerVM.isPlaying,
                    showsLyrics: playerVM.showLyrics,
                    lyricsSurfaceReady: lyricsSurfaceReady,
                    songTitle: playerVM.currentSong?.title,
                    hasLRC: playerVM.currentSongHasLRC,
                    viewportSize: viewportSizeForContentID(geometry.size),
                    bleedsArtwork: bleeds,
                    hidesCover: hidesCover,
                    musicVideoRevision: musicVideo.revision
                ),
                anchors: transitionAnchors,
                artwork: playerVM.currentSong?.artworkSource,
                // The motion artwork behind stands in for the cover; it
                // still swipes between songs.
                cover: { coverContent(in: geometry, hidesCover: hidesCover) },
                lyrics: { lyricsModeContent(videoWidth: artworkBaseSize(for: geometry)).padding(.top, bleeds ? max(0, grabberHeight(in: geometry) - Self.deviceInsets.top) : 0) }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            playbackSection
                .padding(.horizontal, 28)
                .padding(.bottom, bottomPadding)
        }
        .background {
            // Full-screen, the bottom settles a little darker: under the
            // cover's blur, so it shows only as that melts away.
            if bleeds {
                LinearGradient(
                    stops: [.init(color: .clear, location: 0.45), .init(color: .black.opacity(0.14), location: 0.72), .init(color: .black.opacity(0.34), location: 1)],
                    startPoint: .top, endPoint: .bottom
                )
                .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .top) {
            if bleeds {
                grabber
                    .padding(.top, topSafePadding(from: geometry))
            }
        }
        .frame(width: geometry.size.width, height: geometry.size.height)
    }

    /// Full-Screen Artwork on an iPhone, under the lyrics: the cover stays
    /// behind them, dimmed like a motion artwork (whose video, when there's
    /// one, takes its place). The cover itself keeps its own blur.
    private func updateStill() {
        // The cover itself now stays behind the lyrics, under a veil.
        if motion.still != nil { motion.still = nil }
    }

    /// "Full-Screen Artwork" (Settings › Now Playing): on an iPhone held
    /// upright only. Sideways or on a wide screen the cover keeps its card.
    private func bleedsArtwork(in geometry: GeometryProxy) -> Bool {
        fullScreenArtwork && geometry.size.width < 600 && geometry.size.height > geometry.size.width
    }

    private func grabberHeight(in geometry: GeometryProxy) -> CGFloat {
        topSafePadding(from: geometry) + 24
    }

    /// The Now Playing column (cover, title, controls) with the lyrics
    /// beside it. Without lyrics the column stands in the middle.
    private func sideBySideLayout(in geometry: GeometryProxy) -> some View {
        let insets = Self.deviceInsets
        let top = topSafePadding(from: geometry) + 24
        let bottom = bottomPadding
        let columnWidth = min(max(geometry.size.width * 0.42, 340), 460)
        // Title row and controls under the cover: about 290 points.
        let artworkSize = max(160, min(columnWidth - 56, geometry.size.height - top - bottom - 290 - 40))
        let showsLyrics = playerVM.showLyrics

        return ZStack(alignment: .top) {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    FullscreenCoverPager(
                        previousSong: playerVM.previousSongPreview,
                        currentSong: playerVM.currentSong,
                        nextSong: playerVM.nextSongPreview,
                        artworkSize: artworkSize,
                        artworkScale: artworkScale,
                        allowsPaging: true,
                        resetID: 0,
                        transitionAnchors: transitionAnchors,
                        onPrevious: { playerVM.previousTrack() },
                        onNext: { playerVM.next() }
                    )
                    .frame(width: columnWidth, height: artworkSize + 40)
                    // The neighbouring covers wait just outside the pager:
                    // off screen when it spans the screen, beside the lyrics
                    // here. Taller than the pager so the shadow isn't cut.
                    .mask { Rectangle().padding(.vertical, -80) }
                    .overlay {
                        NativePlayerTransitionAnchor(role: .large, anchors: transitionAnchors)
                            .frame(width: coverAnchorSize(artworkSize * artworkScale).width, height: coverAnchorSize(artworkSize * artworkScale).height)
                            .allowsHitTesting(false)
                    }

                    songInfoRow
                        .padding(.horizontal, 28)
                        .padding(.top, 12)
                        .padding(.bottom, 14)

                    // Kept in the layout while the lyrics are open: taking
                    // it out would move the whole column (cover included)
                    // during the slide, which stutters on iPad.
                    NowPlayingLyricPreview(playerVM: playerVM)
                        .padding(.horizontal, 28)
                        .opacity(showsLyrics ? 0 : 1)
                        .allowsHitTesting(!showsLyrics)
                        .accessibilityHidden(showsLyrics)

                    playbackSection
                        .padding(.horizontal, 28)
                    Spacer(minLength: 0)
                }
                .frame(width: columnWidth)
                .padding(.leading, insets.left)
                .frame(maxWidth: showsLyrics ? columnWidth + insets.left : .infinity)

                if showsLyrics {
                    LyricsView(playerVM: playerVM)
                        .padding(.trailing, insets.right)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(.opacity.combined(with: .offset(x: 60)))
                }
            }
            .padding(.top, top)
            .padding(.bottom, bottom)

            grabber
                .padding(.top, topSafePadding(from: geometry))
        }
        .frame(width: geometry.size.width, height: geometry.size.height)
        .animation(.spring(duration: 0.55, bounce: 0.08), value: showsLyrics)
    }

    private var bottomPadding: CGFloat {
        max(28, Self.deviceInsets.bottom + 10)
    }

    private func viewportSizeForContentID(_ size: CGSize) -> CGSize {
        let step: CGFloat = 24
        return CGSize(width: floor(size.width / step) * step, height: floor(size.height / step) * step)
    }

    private var grabber: some View {
        Button {
            playerVM.dismissPlayer()
        } label: {
            Capsule()
                .fill(.white.opacity(0.4))
                .frame(width: 36, height: 5)
                .frame(width: 120, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close Now Playing")
    }

    private func topSafePadding(from geometry: GeometryProxy) -> CGFloat {
        // The iPhone Duo's cover display keeps its status bar on the side.
        max(Self.deviceInsets.top + 4, 12)
    }

    /// The phone turned with its top to the right (the interface's
    /// landscape left).
    static var isTopOnTheRight: Bool {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.effectiveGeometry.interfaceOrientation == .landscapeLeft
    }

    /// The screen's insets, fixed: the card moves away from the screen's
    /// edges while it closes, and following its live safe area made the
    /// whole layout jump as soon as it left the top.
    static var deviceInsets: UIEdgeInsets {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        // Sideways, the top inset can be zero: any window on screen will do,
        // as long as the grabber stays out of the status bar (which takes its
        // taps on an iPad).
        guard let window = windows.first(where: { $0.safeAreaInsets.top > 0 }) ?? windows.first(where: \.isKeyWindow) else {
            return UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0)
        }
        var insets = window.safeAreaInsets
        insets.top = max(insets.top, window.windowScene?.statusBarManager?.statusBarFrame.height ?? 0)
        return insets
    }

    @ViewBuilder
    private func coverContent(in geometry: GeometryProxy, hidesCover: Bool) -> some View {
        if bleedsArtwork(in: geometry) {
            fullScreenCoverContent(in: geometry, hidesCover: hidesCover)
        } else {
            cardCoverContent(in: geometry, hidesCover: hidesCover)
        }
    }

    /// The artwork edge to edge from the top of the screen, its lower part
    /// melting into the player's colors; the title and lyrics preview sit
    /// on the melt, like Music's motion artwork.
    private func fullScreenCoverContent(in geometry: GeometryProxy, hidesCover: Bool) -> some View {
        let width = geometry.size.width
        // Just under the status bar; the mirrored blur fills above.
        let lift = topSafePadding(from: geometry) + 14
        // The pager reaches down to the title: the whole cover area swipes.
        let reach = width * 0.4
        return ZStack(alignment: .top) {
            FullscreenCoverPager(
                previousSong: playerVM.previousSongPreview,
                currentSong: playerVM.currentSong,
                nextSong: playerVM.nextSongPreview,
                artworkSize: width,
                artworkScale: 1,
                allowsPaging: true,
                resetID: 0,
                bleeds: true,
                bleedLift: lift,
                transitionAnchors: transitionAnchors,
                onPrevious: { playerVM.previousTrack() },
                onNext: { playerVM.next() }
            )
            .frame(width: width, height: width + reach)
            .modifier(MotionCoverFade(hidden: hidesCover))
            .overlay(alignment: .top) {
                NativePlayerTransitionAnchor(role: .large, anchors: transitionAnchors)
                    .frame(width: width, height: width)
                    .allowsHitTesting(false)
            }
            .padding(.top, lift)

            // Keeps the status bar and grabber readable on light artwork.
            LinearGradient(stops: [.init(color: .black.opacity(0.22), location: 0), .init(color: .black.opacity(0.08), location: 0.5), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom)
                .frame(height: grabberHeight(in: geometry) + 80)
                .allowsHitTesting(false)


            VStack(spacing: 0) {
                Spacer(minLength: 0)
                songInfoRow
                    .padding(.horizontal, 28)
                    .padding(.bottom, 14)
                NowPlayingLyricPreview(playerVM: playerVM)
                    .padding(.horizontal, 28)
            }
            .shadow(color: .black.opacity(0.18), radius: 10, y: 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func cardCoverContent(in geometry: GeometryProxy, hidesCover: Bool) -> some View {
        let artworkSize = artworkBaseSize(for: geometry)

        // The title sits right above the scrubber, like Music; the cover is
        // centered in whatever height is left.
        return VStack(spacing: 0) {
            Spacer(minLength: 8)

            FullscreenCoverPager(
                previousSong: playerVM.previousSongPreview,
                currentSong: playerVM.currentSong,
                nextSong: playerVM.nextSongPreview,
                artworkSize: artworkSize,
                artworkScale: artworkScale,
                allowsPaging: true,
                resetID: playerVM.showLyrics ? 1 : 0,
                transitionAnchors: transitionAnchors,
                onPrevious: { playerVM.previousTrack() },
                onNext: { playerVM.next() }
            )
            .frame(width: geometry.size.width, height: artworkSize + 72)
            .modifier(MotionCoverFade(hidden: hidesCover))
            .overlay {
                NativePlayerTransitionAnchor(role: .large, anchors: transitionAnchors)
                    .frame(width: coverAnchorSize(artworkSize * artworkScale).width, height: coverAnchorSize(artworkSize * artworkScale).height)
                    .allowsHitTesting(false)
            }

            Spacer(minLength: 8)

            songInfoRow
                .padding(.horizontal, 28)
                .padding(.bottom, 14)

            NowPlayingLyricPreview(playerVM: playerVM)
                .padding(.horizontal, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var lyricsModeContent: some View { lyricsModeContent(videoWidth: nil) }

    /// The current song's music video plays (upright player): it keeps its
    /// size and moves up, the title and menu under it, the lyrics below.
    private func lyricsModeContent(videoWidth: CGFloat?) -> some View {
        // Upright (a width given): a tap on the cover brings the video up,
        // a tap on the video sends the cover back to the corner. The header
        // follows the video itself: this page is only rebuilt in one go.
        VStack(spacing: 0) {
            if let videoWidth {
                LyricsNowPlayingHeader(
                    song: playerVM.currentSong,
                    videoWidth: videoWidth,
                    artwork: AnyView(NativeCompactPlayerArtwork(artwork: playerVM.currentSong?.artworkSource, anchors: transitionAnchors)),
                    compactText: AnyView(songText(titleFont: .headline, artistFont: .subheadline)),
                    compactMenu: AnyView(moreMenu),
                    infoRow: AnyView(songInfoRow),
                    onTap: toggleVideo
                )
                .padding(.top, 14)
            } else {
                compactNowPlayingHeader(tapsVideo: false)
                    .padding(.top, 14)
                    .padding(.horizontal, 24)
            }

            Group {
                if lyricsSurfaceReady || playerVM.showLyrics {
                    LyricsView(playerVM: playerVM)
                } else {
                    Color.clear
                }
            }
            .padding(.top, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var showsVideoHeader: Bool {
        guard let id = playerVM.currentSong?.id else { return false }
        return musicVideo.shownSongID == id
    }

    private func toggleVideo() {
        guard let song = playerVM.currentSong, MusicVideoFeature.isAvailable else { return }
        MusicVideoPlayer.shared.toggle(for: song)
    }

    private func compactNowPlayingHeader(tapsVideo: Bool) -> some View {
        HStack(spacing: 12) {
            NativeCompactPlayerArtwork(
                artwork: playerVM.currentSong?.artworkSource,
                anchors: transitionAnchors
            )
            .frame(width: 56, height: 56)
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .onTapGesture { if tapsVideo { toggleVideo() } }
            .allowsHitTesting(tapsVideo && MusicVideoFeature.isAvailable)
            .shadow(color: .black.opacity(0.26), radius: 12, y: 7)

            songText(titleFont: .headline, artistFont: .subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)

            moreMenu
        }
        .frame(height: 60)
    }

    private var songInfoRow: some View { songInfoRow(showsArtwork: false) }

    /// The music video stands in for the cover: flights land on its shape.
    private func coverAnchorSize(_ side: CGFloat) -> CGSize {
        guard let id = playerVM.currentSong?.id, musicVideo.shownSongID == id else { return CGSize(width: side, height: side) }
        return MusicVideoPlayer.videoSize(side: side)
    }

    /// With the lyrics where the cover was, a small cover beside the title
    /// and artist keeps the song in sight, as tall as the two lines.
    private func songInfoRow(showsArtwork: Bool) -> some View {
        HStack(alignment: .center, spacing: 12) {
            if showsArtwork {
                // The flying cover lands here (see `CoverFlightOverlay`).
                NativeCompactPlayerArtwork(artwork: playerVM.currentSong?.artworkSource, anchors: transitionAnchors)
                    .frame(width: 52, height: 52)
                    .overlay {
                        NativePlayerTransitionAnchor(role: .compact, anchors: flightAnchors)
                            .allowsHitTesting(false)
                    }
                    .transition(.identity)
            }
            songText(titleFont: .title3.bold(), artistFont: .title3)
                .frame(maxWidth: .infinity, alignment: .leading)
            moreMenu
        }
    }

    private func songText(titleFont: Font, artistFont: Font) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(playerVM.currentSong?.title ?? String(localized: "Not Playing"))
                .font(titleFont)
                .foregroundStyle(.white)
                .lineLimit(1)

            Button {
                goToArtist()
            } label: {
                Text(playerVM.currentSong?.artist ?? "")
                    .font(artistFont)
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .disabled(currentArtist == nil)
        }
        .id(playerVM.currentSong?.id)
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.2), value: playerVM.currentSong?.id)
    }

    private var playbackSection: some View {
        VStack(spacing: 0) {
            PlayerSeekSection(
                playerService: playerVM.playerService,
                scrubbingTime: $scrubbingTime,
                onSeek: { playerVM.seek(to: $0) }
            )

            HStack(spacing: 0) {
                PlaybackControlButton(
                    icon: "backward.fill",
                    fontSize: 30,
                    frameSize: 64,
                    action: { playerVM.previous() },
                    longPressAction: { seek(by: -10) }
                )
                .frame(maxWidth: .infinity)

                Button {
                    playerVM.togglePlayPause()
                } label: {
                    Image(systemName: playerVM.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 44, weight: .semibold))
                        .contentTransition(.symbolEffect(.replace.downUp))
                        .frame(width: 80, height: 80)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PlayerIconButtonStyle())
                .accessibilityLabel(playerVM.isPlaying ? "Pause" : "Play")
                .frame(maxWidth: .infinity)

                PlaybackControlButton(
                    icon: "forward.fill",
                    fontSize: 30,
                    frameSize: 64,
                    action: { playerVM.next() },
                    longPressAction: { seek(by: 10) }
                )
                .frame(maxWidth: .infinity)
            }
            .foregroundStyle(.white)
            .padding(.top, 20)


            HStack {
                playerToggleButton("quote.bubble", activeSymbol: "quote.bubble.fill", isActive: playerVM.showLyrics, label: "Lyrics") {
                    playerVM.showLyrics.toggle()
                    if playerVM.showLyrics { lyricsSurfaceReady = true }
                }
                .frame(maxWidth: .infinity)

                AirPlayRoutePicker()
                    .frame(width: 44, height: 44)
                    .frame(maxWidth: .infinity)

                playerToggleButton("list.bullet", activeSymbol: "list.bullet", isActive: showQueueSheet, label: "Up Next") {
                    showQueueSheet = true
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.top, 26)
        }
    }

    private func playerToggleButton(_ symbol: String, activeSymbol: String, isActive: Bool, label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: isActive ? activeSymbol : symbol)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(isActive ? .black : .white.opacity(0.75))
                .frame(width: 40, height: 40)
                .background {
                    Circle()
                        .fill(.white.opacity(isActive ? 0.92 : 0))
                }
                .contentShape(Circle())
                .animation(.snappy(duration: 0.25), value: isActive)
        }
        .buttonStyle(PlayerIconButtonStyle())
        .accessibilityLabel(label)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    private var currentArtist: Artist? {
        playerVM.currentSong.flatMap(libraryVM.artist(for:))
    }

    private var currentAlbum: Album? {
        playerVM.currentSong.flatMap(libraryVM.album(containing:))
    }

    private func goToArtist() {
        guard let artist = currentArtist else { return }
        playerVM.dismissPlayer()
        router.open(.artist(artist.name))
    }

    private var moreMenu: some View {
        Menu {
            if let song = playerVM.currentSong {
                // Destructive rows together at the top, the far end from the button.
                Section {
                    if playerVM.currentSongHasLRC {
                        Button(LyricsGenerator.isGenerated(storedPath: song.lrcFilePath) ? String(localized: "Delete AI Lyrics") : String(localized: "Remove LRC"), destructiveImage: "text.badge.xmark") {
                            libraryVM.libraryService.removeLRCLyrics(for: song)
                        }
                    }
                    if playerVM.currentSongHasWordSync, playerVM.currentLyrics?.hasTimedLyrics == true {
                        Button(String(localized: "Delete Word by Word Sync"), destructiveImage: "text.word.spacing") {
                            WordSyncStore.delete(for: song.id)
                        }
                    }
                }
                Section {
                    if let album = currentAlbum, !album.isSingle {
                        Button("Go to Album", systemImage: "square.stack") {
                            playerVM.dismissPlayer()
                            router.open(.album(album.id))
                        }
                    }
                    if currentArtist != nil {
                        Button("Go to Artist", systemImage: "music.microphone") { goToArtist() }
                    }
                }
                Section {
                    Button("Add to Playlist…", systemImage: "text.badge.plus") {
                        playlistPickerSong = song
                    }
                }
                if motionArtwork, motion.video != nil || motion.isHiddenForAlbum {
                    Section {
                        if motion.isHiddenForAlbum {
                            Button("Show Video for This Album", systemImage: "play.rectangle") {
                                motion.setHidden(false, forAlbumOf: song)
                            }
                        } else {
                            Button("Hide Video for This Album", systemImage: "rectangle.slash") {
                                motion.setHidden(true, forAlbumOf: song)
                            }
                        }
                    }
                }
                Section {
                    Button("Associate LRC…", systemImage: "text.quote") {
                        libraryVM.beginLyricsAssociation(for: song)
                        router.importer = .lyricsFile
                    }
                }
                if let lyrics = playerVM.currentLyrics, !lyrics.hasTimedLyrics, lyrics.hasPlainText, AIFeatures.isAvailable {
                    Section {
                        Button("Sync with AI", systemImage: "sparkles") {
                            WordSyncGenerator.shared.syncPlain(song, lyrics: lyrics, in: libraryVM.libraryService)
                            showLyricsIfHidden()
                        }
                    }
                }
                if let lyrics = playerVM.currentLyrics, lyrics.hasTimedLyrics {
                    Section {
                        if playerVM.currentSongHasWordSync {
                            if playerVM.currentWordSyncHidden {
                                Button("Show Word by Word Sync", systemImage: "eye") {
                                    WordSyncStore.setHidden(false, for: song.id)
                                }
                            } else {
                                Button("Hide Word by Word Sync", systemImage: "eye.slash") {
                                    WordSyncStore.setHidden(true, for: song.id)
                                }
                            }
                        } else if AIFeatures.isAvailable {
                            Button("Sync Word by Word", systemImage: "text.word.spacing") {
                                // The file's lines: the timings are saved against them.
                                WordSyncGenerator.shared.sync(song, lyrics: playerVM.rawLyrics ?? lyrics)
                                showLyricsIfHidden()
                            }
                        }
                        TranslateLyricsMenuItem(onTranslate: showLyricsIfHidden)
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(.white.opacity(0.16), in: Circle())
                .contentShape(Circle())
        }
        .menuOrder(.fixed)
        // A menu's rows are built once: rebuilt when a song's video is
        // turned on or off, so the right rows show at the next tap.
        .id(musicVideo.revision)
        .tint(playerVM.currentSong?.coverMenuTint ?? .white)
        .disabled(playerVM.currentSong == nil)
        .accessibilityLabel("More")
    }

    private func showLyricsIfHidden() {
        guard !playerVM.showLyrics else { return }
        playerVM.showLyrics = true
        lyricsSurfaceReady = true
    }

    private func seek(by delta: TimeInterval) {
        let target = playerVM.playerService.preciseCurrentTime + delta
        playerVM.seek(to: max(0, min(target, playerVM.duration)))
    }

    /// As wide as the margins allow, up to what still leaves room for the
    /// title and controls below (the iPhone Duo's cover display is short).
    private func artworkBaseSize(for geometry: GeometryProxy) -> CGFloat {
        let maxArtwork: CGFloat = LargeScreen.contains(geometry.size) ? 520 : 400
        // Grabber, title row and controls: about 330 points plus the insets;
        // the pager adds 72 around the cover for its shadow.
        let room = geometry.size.height - topSafePadding(from: geometry) - bottomPadding - 330 - 72
        return max(200, min(geometry.size.width - 56, geometry.size.height * 0.45, room, maxArtwork))
    }

    /// Apple Music shrinks the cover while paused.
    private var artworkScale: CGFloat {
        playerVM.isPlaying ? 1 : 0.82
    }
}

/// "Add to Playlist" sheet (player, mini player). Creating a playlist happens
/// inline so it works while the player is covering the app.
struct PlayerPlaylistPickerSheet: View {
    let song: Song
    @EnvironmentObject private var libraryVM: LibraryViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                NavigationLink {
                    PlaylistEditorView(request: PlaylistEditorRequest(playlistID: nil, song: song), isPushed: true) {
                        dismiss()
                    }
                } label: {
                    Label("New Playlist…", systemImage: "plus")
                }

                if !libraryVM.editablePlaylists.isEmpty {
                    Section {
                        ForEach(libraryVM.editablePlaylists) { playlist in
                            let contains = playlist.songs.contains(song.id)
                            Button {
                                libraryVM.addToPlaylist(songId: song.id, playlistId: playlist.id)
                                dismiss()
                            } label: {
                                HStack(spacing: 12) {
                                    ArtworkImage(source: libraryVM.playlistArtwork(playlist), cornerRadius: 5, points: 44, placeholderSymbol: "music.note.list")
                                        .frame(width: 44, height: 44)
                                    Text(playlist.name)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    if contains {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.tint)
                                    }
                                }
                            }
                            .disabled(contains)
                        }
                    }
                }
            }
            .navigationTitle("Add to Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct PlayerModeContentID: Equatable {
    let songID: UUID?
    let previousSongID: UUID?
    let nextSongID: UUID?
    let isPlaying: Bool
    let showsLyrics: Bool
    let lyricsSurfaceReady: Bool
    let songTitle: String?
    let hasLRC: Bool
    let viewportSize: CGSize
    let bleedsArtwork: Bool
    let hidesCover: Bool
    /// A song's music video turned on or off: the ··· menu's rows change.
    var musicVideoRevision = 0
}

/// The motion artwork behind stands in for the cover, which still swipes
/// between songs; the title and lyrics preview stay.
private struct MotionCoverFade: ViewModifier {
    let hidden: Bool

    func body(content: Content) -> some View {
        content
            .opacity(hidden ? 0 : 1)
            .animation(.easeInOut(duration: 0.5), value: hidden)
    }
}

@MainActor
final class PlayerModeTransitionAnchors: ObservableObject {
    /// The Now Playing screen's anchors, also read by its presentation morph.
    static let nowPlaying = PlayerModeTransitionAnchors()

    enum Role {
        case large
        case compact
    }

    /// Every anchor registered for a role, newest last: a layout SwiftUI
    /// builds and throws away (in the middle of a rotation) registers one
    /// that never reaches the screen, and must not hide the one that did.
    private var largeViews = NSHashTable<UIView>.weakObjects()
    private var compactViews = NSHashTable<UIView>.weakObjects()
    private weak var lastLarge: UIView?
    private weak var lastCompact: UIView?

    var largeView: UIView? {
        get { Self.onScreen(lastLarge, among: largeViews) }
        set { Self.add(newValue, to: largeViews, last: &lastLarge) }
    }

    var compactView: UIView? {
        get { Self.onScreen(lastCompact, among: compactViews) }
        set { Self.add(newValue, to: compactViews, last: &lastCompact) }
    }

    private static func onScreen(_ last: UIView?, among views: NSHashTable<UIView>) -> UIView? {
        if let last, last.window != nil { return last }
        return views.allObjects.first { $0.window != nil } ?? last
    }

    private static func add(_ view: UIView?, to views: NSHashTable<UIView>, last: inout UIView?) {
        guard let view else { return views.removeAllObjects() }
        views.add(view)
        last = view
    }
    weak var largeArtworkView: UIView?
    weak var compactArtworkView: UIView?

    func register(_ view: UIView, for role: Role) {
        switch role {
        case .large: largeView = view
        case .compact: compactView = view
        }
    }

    func unregister(_ view: UIView, for role: Role) {
        switch role {
        case .large:
            largeViews.remove(view)
            if lastLarge === view { lastLarge = nil }
        case .compact:
            compactViews.remove(view)
            if lastCompact === view { lastCompact = nil }
        }
    }

    func registerArtworkView(_ view: UIView, for role: Role) {
        switch role {
        case .large:
            largeArtworkView = view
        case .compact:
            compactArtworkView = view
            compactView = view
        }
    }

    /// Hides the real covers (UIKit-side, so it's immediate and never
    /// re-renders the player) while the presentation's flying cover stands in.
    private var hiddenArtworkViews: [UIView] = []

    func setArtworkViewsHidden(_ isHidden: Bool, keepsLarge: Bool = false) {
        // Restore exactly what was hidden: the pager may have registered a
        // different page since.
        hiddenArtworkViews.forEach { $0.alpha = 1 }
        hiddenArtworkViews = []
        guard isHidden else { return }
        hiddenArtworkViews = [keepsLarge ? nil : largeArtworkView, compactArtworkView].compactMap { $0 }
        hiddenArtworkViews.forEach { $0.alpha = 0 }
    }

    func frame(for role: Role, in container: UIView) -> CGRect? {
        let anchor = role == .large ? largeView : compactView
        guard let anchor, anchor.bounds.width > 1, anchor.bounds.height > 1 else { return nil }
        let frame = anchor.convert(anchor.bounds, to: container)
        return role == .compact ? MusicVideoPlayer.fitted(frame) : frame
    }
}

private struct NativeCompactPlayerArtwork: UIViewRepresentable {
    let artwork: ArtworkSource?
    let anchors: PlayerModeTransitionAnchors

    func makeUIView(context: Context) -> CompactPlayerArtworkView {
        let view = CompactPlayerArtworkView()
        view.configure(artwork: artwork)
        anchors.registerArtworkView(view, for: .compact)
        return view
    }

    func updateUIView(_ view: CompactPlayerArtworkView, context: Context) {
        view.configure(artwork: artwork)
        anchors.registerArtworkView(view, for: .compact)
    }
}

private final class CompactPlayerArtworkView: UIView {
    private let imageView = UIImageView()
    /// The music video, playing, when it stands in for the cover.
    private let videoHost = MusicVideoHostView(role: .compact)
    private var artwork: ArtworkSource?

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        layer.cornerCurve = .continuous
        layer.cornerRadius = 8
        isUserInteractionEnabled = false

        imageView.clipsToBounds = true
        imageView.tintColor = .secondaryLabel
        addSubview(imageView)
        NotificationCenter.default.addObserver(self, selector: #selector(updateVideo), name: MusicVideoPlayer.stateDidChange, object: nil)
    }

    @objc private func updateVideo() {
        let shows = MusicVideoPlayer.shared.isShown(for: artwork)
        if shows, videoHost.superview == nil {
            addSubview(videoHost)
            setNeedsLayout()
        } else if !shows, videoHost.superview != nil {
            videoHost.removeFromSuperview()
        }
        // The cover fades as it takes the video's shape (and back).
        let alpha: CGFloat = shows ? 0 : 1
        if imageView.alpha != alpha {
            if window != nil {
                UIView.animate(withDuration: 0.35, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) { self.imageView.alpha = alpha }
            } else {
                imageView.alpha = alpha
            }
        }
        if shows { backgroundColor = .clear }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:)")
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        imageView.frame = bounds
        videoHost.frame = MusicVideoPlayer.fitted(bounds)
        videoHost.layer.cornerRadius = bounds.width > 100 ? 12 : 6
        layer.cornerRadius = bounds.width > 100 ? 12 : 8
    }

    func configure(artwork: ArtworkSource?) {
        self.artwork = artwork
        updateVideo()
        if let image = artwork.flatMap({ ArtworkImageCache.shared.imageSync(for: $0, points: 56) }) {
            imageView.image = image
            imageView.contentMode = .scaleAspectFill
            backgroundColor = .clear
        } else {
            imageView.image = UIImage(systemName: "music.note")
            imageView.contentMode = .center
            backgroundColor = UIColor.secondarySystemBackground.withAlphaComponent(0.75)
        }
    }
}

private struct NativePlayerTransitionAnchor: UIViewRepresentable {
    let role: PlayerModeTransitionAnchors.Role
    let anchors: PlayerModeTransitionAnchors

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        anchors.register(view, for: role)
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        anchors.register(view, for: role)
    }

    static func dismantleUIView(_ view: UIView, coordinator: ()) {
        // Registration is refreshed whenever SwiftUI installs the replacement anchor.
    }
}

/// The short landscape player's cover flight: the cover moves between its
/// place and the small one beside the title with the portrait player's
/// spring. The source is measured before SwiftUI lays out the new state,
/// the target after.
private struct CoverFlightOverlay: UIViewRepresentable {
    let showsLyrics: Bool
    let artwork: ArtworkSource?
    /// The two places, measured.
    let anchors: PlayerModeTransitionAnchors
    /// The real covers, hidden while the copy flies.
    let covers: PlayerModeTransitionAnchors

    final class Coordinator {
        var showsLyrics: Bool?
        var animator: UIViewPropertyAnimator?
        weak var flying: SharedArtworkTransitionView?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        context.coordinator.showsLyrics = showsLyrics
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        let coordinator = context.coordinator
        guard coordinator.showsLyrics != showsLyrics else { return }
        coordinator.showsLyrics = showsLyrics
        guard !UIAccessibility.isReduceMotionEnabled, view.window != nil else { return }

        let showsLyrics = showsLyrics
        let anchors = anchors
        let covers = covers
        let sourceRole: PlayerModeTransitionAnchors.Role = showsLyrics ? .large : .compact
        let targetRole: PlayerModeTransitionAnchors.Role = showsLyrics ? .compact : .large
        // Where it is now: a flight under way, or the anchor's old layout.
        let source = coordinator.flying?.layer.presentation()?.frame ?? anchors.frame(for: sourceRole, in: view)
        coordinator.animator?.stopAnimation(true)
        coordinator.flying?.removeFromSuperview()
        covers.setArtworkViewsHidden(false)
        guard let source, source.width > 1 else { return }

        let image = MusicVideoPlayer.coverImage(for: artwork, points: 400)
        let flying = SharedArtworkTransitionView(image: image ?? UIImage(systemName: "music.note"), usesPlaceholder: image == nil, isCompact: !showsLyrics, carriesVideo: MusicVideoPlayer.shared.isShown(for: artwork))
        flying.frame = source
        view.addSubview(flying)
        coordinator.flying = flying
        covers.setArtworkViewsHidden(true)

        // The new layout lands on the next run loop.
        DispatchQueue.main.async {
            guard coordinator.flying === flying else { return }
            view.superview?.layoutIfNeeded()
            covers.setArtworkViewsHidden(true)
            guard let target = anchors.frame(for: targetRole, in: view), target.width > 1 else {
                flying.removeFromSuperview()
                covers.setArtworkViewsHidden(false)
                return
            }
            let timing = UISpringTimingParameters(dampingRatio: 0.96, initialVelocity: CGVector(dx: 0, dy: showsLyrics ? 0.18 : -0.12))
            let animator = UIViewPropertyAnimator(duration: 0.62, timingParameters: timing)
            animator.addAnimations {
                flying.frame = target
                flying.applyCompactAppearance(showsLyrics)
            }
            animator.addCompletion { _ in
                guard coordinator.flying === flying else { return }
                covers.setArtworkViewsHidden(false)
                flying.removeFromSuperview()
                coordinator.animator = nil
            }
            coordinator.animator = animator
            animator.startAnimation()
        }
    }
}

private struct NativePlayerModeTransition<Cover: View, Lyrics: View>: UIViewControllerRepresentable {
    let showsLyrics: Bool
    let contentID: PlayerModeContentID
    let anchors: PlayerModeTransitionAnchors
    let artwork: ArtworkSource?
    let coverBuilder: () -> Cover
    let lyricsBuilder: () -> Lyrics

    init(
        showsLyrics: Bool,
        contentID: PlayerModeContentID,
        anchors: PlayerModeTransitionAnchors,
        artwork: ArtworkSource?,
        @ViewBuilder cover: @escaping () -> Cover,
        @ViewBuilder lyrics: @escaping () -> Lyrics
    ) {
        self.showsLyrics = showsLyrics
        self.contentID = contentID
        self.anchors = anchors
        self.artwork = artwork
        self.coverBuilder = cover
        self.lyricsBuilder = lyrics
    }

    func makeUIViewController(context: Context) -> NativePlayerModeTransitionController {
        NativePlayerModeTransitionController(
            cover: AnyView(coverBuilder()),
            lyrics: AnyView(lyricsBuilder()),
            contentID: contentID,
            anchors: anchors,
            artwork: artwork,
            showsLyrics: showsLyrics
        )
    }

    func updateUIViewController(_ controller: NativePlayerModeTransitionController, context: Context) {
        controller.updateContent(
            contentID: contentID,
            artwork: artwork,
            cover: { AnyView(self.coverBuilder()) },
            lyrics: { AnyView(self.lyricsBuilder()) }
        )
        controller.setLyricsVisible(showsLyrics, animated: !UIAccessibility.isReduceMotionEnabled)
    }
}

@MainActor
private final class NativePlayerModeTransitionController: UIViewController {
    private struct ArtworkFrames {
        let large: CGRect
        let compact: CGRect

        func isApproximatelyEqual(to other: ArtworkFrames) -> Bool {
            large.isApproximatelyEqual(to: other.large)
                && compact.isApproximatelyEqual(to: other.compact)
        }
    }

    private let coverController: UIHostingController<AnyView>
    private let lyricsController: UIHostingController<AnyView>
    private let anchors: PlayerModeTransitionAnchors
    private var contentID: PlayerModeContentID
    private var artworkSource: ArtworkSource?
    private var artworkImage: UIImage? { MusicVideoPlayer.coverImage(for: artworkSource, points: 400) }
    private var displayedLyricsState: Bool?
    private var transitionAnimator: UIViewPropertyAnimator?
    private var transitionGeneration = 0
    private weak var transitionArtworkView: SharedArtworkTransitionView?

    init(
        cover: AnyView,
        lyrics: AnyView,
        contentID: PlayerModeContentID,
        anchors: PlayerModeTransitionAnchors,
        artwork: ArtworkSource?,
        showsLyrics: Bool
    ) {
        coverController = UIHostingController(rootView: cover)
        // The cover is laid out on the whole screen's width: a side inset
        // (the folded iPhone Duo's status bar) would push it off center.
        coverController.safeAreaRegions = []
        lyricsController = UIHostingController(rootView: lyrics)
        self.anchors = anchors
        self.contentID = contentID
        artworkSource = artwork
        displayedLyricsState = showsLyrics
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:)")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        install(coverController)
        veil.isUserInteractionEnabled = false
        veil.contentView.addSubview(veilDim)
        veilDim.backgroundColor = .black
        view.addSubview(veil)
        install(lyricsController)
        // Full-screen artwork's blur runs down behind the controls.
        coverController.view.clipsToBounds = !contentID.bleedsArtwork
        let showsLyrics = displayedLyricsState ?? false
        applyState(showsLyrics: showsLyrics)
        coverController.view.isUserInteractionEnabled = !showsLyrics
        lyricsController.view.isUserInteractionEnabled = showsLyrics
        finishState(showsLyrics: showsLyrics)
    }

    /// Full-screen artwork under the lyrics: the cover holds still and a
    /// dimmed blur rises over it, like a motion artwork's.
    private let veil = UIVisualEffectView(effect: nil)
    private let veilDim = UIView()
    /// Full-screen cover, no video: it stays put under the lyrics.
    private var holdsCover: Bool { contentID.bleedsArtwork && !contentID.hidesCover }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Reaches past the top and down behind the controls, like the cover.
        veil.frame = view.bounds.inset(by: UIEdgeInsets(top: -300, left: 0, bottom: -900, right: 0))
        veilDim.frame = veil.bounds
    }

    func updateContent(contentID: PlayerModeContentID, artwork: ArtworkSource?, cover: () -> AnyView, lyrics: () -> AnyView) {
        guard self.contentID != contentID else { return }
        self.contentID = contentID
        artworkSource = artwork
        coverController.view.clipsToBounds = !contentID.bleedsArtwork
        coverController.rootView = cover()
        lyricsController.rootView = lyrics()
    }

    func setLyricsVisible(_ showsLyrics: Bool, animated: Bool) {
        loadViewIfNeeded()
        guard displayedLyricsState != showsLyrics else { return }
        displayedLyricsState = showsLyrics

        if let transitionAnimator {
            transitionAnimator.stopAnimation(false)
            transitionAnimator.finishAnimation(at: .current)
        }
        transitionGeneration += 1
        let generation = transitionGeneration

        coverController.view.isHidden = false
        lyricsController.view.isHidden = false
        coverController.view.isUserInteractionEnabled = !showsLyrics
        lyricsController.view.isUserInteractionEnabled = showsLyrics
        view.layoutIfNeeded()
        coverController.view.layoutIfNeeded()
        lyricsController.view.layoutIfNeeded()

        guard animated else {
            applyState(showsLyrics: showsLyrics)
            finishState(showsLyrics: showsLyrics)
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.startLyricsTransition(
                showsLyrics: showsLyrics,
                generation: generation,
                layoutAttempt: 0,
                previousFrames: nil
            )
        }
    }

    private func startLyricsTransition(
        showsLyrics: Bool,
        generation: Int,
        layoutAttempt: Int,
        previousFrames: ArtworkFrames?
    ) {
        guard generation == transitionGeneration,
              displayedLyricsState == showsLyrics else { return }

        view.setNeedsLayout()
        coverController.view.setNeedsLayout()
        lyricsController.view.setNeedsLayout()
        view.layoutIfNeeded()
        coverController.view.layoutIfNeeded()
        lyricsController.view.layoutIfNeeded()

        // Full-screen, the cover holds still: nothing flies, so no frames to
        // wait for; the small cover fades with the lyrics it sits in.
        let frames = holdsCover ? nil : measuredArtworkFrames(for: showsLyrics)
        let framesAreStable = holdsCover || frames.map { currentFrames in
            previousFrames?.isApproximatelyEqual(to: currentFrames) ?? false
        } ?? false

        if !framesAreStable, layoutAttempt < 5 {
            DispatchQueue.main.async { [weak self] in
                self?.startLyricsTransition(
                    showsLyrics: showsLyrics,
                    generation: generation,
                    layoutAttempt: layoutAttempt + 1,
                    previousFrames: frames
                )
            }
            return
        }

        let artworkTransition = frames.flatMap {
            prepareArtworkTransition(showsLyrics: showsLyrics, frames: $0)
        }

        let timing = UISpringTimingParameters(
            dampingRatio: 0.96,
            initialVelocity: CGVector(dx: 0, dy: showsLyrics ? 0.18 : -0.12)
        )
        let animator = UIViewPropertyAnimator(duration: 0.62, timingParameters: timing)
        // The motion artwork stands in for the large cover: with nothing to
        // fly from, the small cover fades in and out in its own place.
        // Full-screen, the cover stays behind the lyrics the same way.
        let hidesLarge = contentID.hidesCover || contentID.bleedsArtwork
        if hidesLarge, let transition = artworkTransition, let compact = frames?.compact {
            transition.view.frame = compact
            transition.view.applyCompactAppearance(true)
            transition.view.alpha = showsLyrics ? 0 : 1
        }
        animator.addAnimations { [weak self] in
            self?.applyState(showsLyrics: showsLyrics)
            if hidesLarge {
                artworkTransition?.view.alpha = showsLyrics ? 1 : 0
            } else {
                artworkTransition?.view.frame = artworkTransition?.targetFrame ?? .zero
                artworkTransition?.view.applyCompactAppearance(showsLyrics)
            }
        }
        animator.addCompletion { [weak self] position in
            guard position == .end else { return }
            self?.finishState(showsLyrics: showsLyrics)
            artworkTransition?.view.removeFromSuperview()
            self?.transitionAnimator = nil
        }
        transitionAnimator = animator
        animator.startAnimation()
    }

    private func install(_ child: UIViewController) {
        addChild(child)
        child.view.backgroundColor = .clear
        child.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(child.view)
        NSLayoutConstraint.activate([
            child.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            child.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            child.view.topAnchor.constraint(equalTo: view.topAnchor),
            child.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        child.didMove(toParent: self)
    }

    private func applyState(showsLyrics: Bool) {
        let veiled = showsLyrics && holdsCover
        // Same blur, dim and ease as a motion artwork's under the lyrics.
        // The blur stays set and only fades: animating the effect itself
        // re-renders it each frame over the whole cover.
        if veil.effect == nil { veil.effect = UIBlurEffect(style: .systemUltraThinMaterialDark); veil.alpha = 0; veilDim.alpha = 0.3 }
        if veil.alpha != (veiled ? 1 : 0) {
            UIView.animate(withDuration: 0.4, delay: 0, options: [.beginFromCurrentState, .curveEaseInOut]) {
                self.veil.alpha = veiled ? 1 : 0
            }
        }
        if holdsCover {
            coverController.view.transform = .identity
            coverController.view.alpha = 1
            lyricsController.view.transform = showsLyrics ? .identity : CGAffineTransform(translationX: 0, y: 104)
                .scaledBy(x: 0.985, y: 0.985)
            lyricsController.view.alpha = showsLyrics ? 1 : 0
        } else if showsLyrics {
            coverController.view.transform = CGAffineTransform(translationX: 0, y: -26)
                .scaledBy(x: 0.985, y: 0.985)
            coverController.view.alpha = 0
            lyricsController.view.transform = .identity
            lyricsController.view.alpha = 1
        } else {
            coverController.view.transform = .identity
            coverController.view.alpha = 1
            lyricsController.view.transform = CGAffineTransform(translationX: 0, y: 104)
                .scaledBy(x: 0.985, y: 0.985)
            lyricsController.view.alpha = 0
        }
    }

    private func finishState(showsLyrics: Bool) {
        coverController.view.isHidden = showsLyrics && !holdsCover
        lyricsController.view.isHidden = !showsLyrics
        coverController.view.accessibilityElementsHidden = showsLyrics
        lyricsController.view.accessibilityElementsHidden = !showsLyrics
        anchors.setArtworkViewsHidden(false)
        transitionArtworkView?.removeFromSuperview()
    }

    private func prepareArtworkTransition(
        showsLyrics: Bool,
        frames: ArtworkFrames
    ) -> (view: SharedArtworkTransitionView, targetFrame: CGRect)? {
        let sourceRole: PlayerModeTransitionAnchors.Role = showsLyrics ? .large : .compact
        let targetRole: PlayerModeTransitionAnchors.Role = showsLyrics ? .compact : .large
        let carriesVideo = MusicVideoPlayer.shared.isShown(for: artworkSource)
        // The video leaves from where it is seen, not the cover's anchor.
        let sourceFrame = sourceRole == .large
            ? (carriesVideo ? MusicVideoPlayer.shared.shownFrame(in: view) : nil) ?? frames.large
            : frames.compact
        let targetFrame = targetRole == .large ? frames.large : frames.compact
        if carriesVideo { print("VPDBG flight lyrics=\(showsLyrics) src=\(sourceFrame) anchorLarge=\(frames.large) compact=\(frames.compact)") }

        transitionArtworkView?.removeFromSuperview()
        let artworkView = SharedArtworkTransitionView(
            image: artworkImage ?? UIImage(systemName: "music.note"),
            usesPlaceholder: artworkImage == nil,
            isCompact: !showsLyrics,
            bleeds: contentID.bleedsArtwork,
            carriesVideo: carriesVideo
        )
        artworkView.frame = sourceFrame
        artworkView.isUserInteractionEnabled = false
        view.addSubview(artworkView)
        artworkView.layoutIfNeeded()
        transitionArtworkView = artworkView
        // Full-screen, the cover holds still behind the lyrics.
        anchors.setArtworkViewsHidden(true, keepsLarge: holdsCover)
        return (artworkView, targetFrame)
    }

    private func measuredArtworkFrames(for showsLyrics: Bool) -> ArtworkFrames? {
        let sourceRole: PlayerModeTransitionAnchors.Role = showsLyrics ? .large : .compact
        let targetRole: PlayerModeTransitionAnchors.Role = showsLyrics ? .compact : .large
        guard let sourceFrame = convertedArtworkFrame(for: sourceRole) else { return nil }

        let coverTransform = coverController.view.transform
        let coverAlpha = coverController.view.alpha
        let lyricsTransform = lyricsController.view.transform
        let lyricsAlpha = lyricsController.view.alpha

        var targetFrame: CGRect?
        UIView.performWithoutAnimation {
            applyState(showsLyrics: showsLyrics)
            view.layoutIfNeeded()
            coverController.view.layoutIfNeeded()
            lyricsController.view.layoutIfNeeded()
            targetFrame = convertedArtworkFrame(for: targetRole)

            coverController.view.transform = coverTransform
            coverController.view.alpha = coverAlpha
            lyricsController.view.transform = lyricsTransform
            lyricsController.view.alpha = lyricsAlpha
        }

        guard let targetFrame else { return nil }
        let large = sourceRole == .large ? sourceFrame : targetFrame
        let compact = sourceRole == .compact ? sourceFrame : targetFrame
        guard
              isValidArtworkFrames(large: large, compact: compact) else { return nil }
        return ArtworkFrames(large: large, compact: compact)
    }

    private func isValidArtworkFrames(large: CGRect, compact: CGRect) -> Bool {
        guard !large.isNull, !compact.isNull,
              large.origin.x.isFinite, large.origin.y.isFinite,
              large.width.isFinite, large.height.isFinite,
              compact.origin.x.isFinite, compact.origin.y.isFinite,
              compact.width.isFinite, compact.height.isFinite,
              (180...560).contains(large.width),
              (100...560).contains(large.height) else { return false }
        if MusicVideoPlayer.shared.shownSongID != nil, compact.width > 100 {
            // The music video moves up above the lyrics, its size kept.
            guard (100...600).contains(compact.width), (56...400).contains(compact.height) else { return false }
        } else {
            guard (44...64).contains(compact.width),
                  (20...64).contains(compact.height),
                  large.width > compact.width * 3,
                  large.height > compact.height * 2 else { return false }
        }

        let visibleBounds = view.bounds.insetBy(dx: -24, dy: -24)
        return visibleBounds.intersects(large) && visibleBounds.intersects(compact)
    }

    private func convertedArtworkFrame(for role: PlayerModeTransitionAnchors.Role) -> CGRect? {
        let anchorView: UIView?
        switch role {
        case .large:
            anchorView = anchors.largeView
        case .compact:
            anchorView = anchors.compactView
        }

        guard let anchorView,
              anchorView.bounds.width > 1,
              anchorView.bounds.height > 1 else { return nil }
        let frame = anchorView.convert(anchorView.bounds, to: view)
        return role == .compact ? MusicVideoPlayer.fitted(frame) : frame
    }
}

private extension CGRect {
    func isApproximatelyEqual(to other: CGRect, tolerance: CGFloat = 0.5) -> Bool {
        abs(minX - other.minX) <= tolerance
            && abs(minY - other.minY) <= tolerance
            && abs(width - other.width) <= tolerance
            && abs(height - other.height) <= tolerance
    }
}

private final class SharedArtworkTransitionView: UIView {
    private let imageView = UIImageView()
    private let fadeMask = ArtworkFadeMaskView()
    /// The large cover is the full-screen artwork.
    private let bleeds: Bool

    /// The playing music video, carried along in the flight.
    private let videoHost: MusicVideoHostView?

    init(image: UIImage?, usesPlaceholder: Bool, isCompact: Bool, bleeds: Bool = false, carriesVideo: Bool = false) {
        self.bleeds = bleeds
        videoHost = carriesVideo ? MusicVideoHostView(role: .flight) : nil
        super.init(frame: .zero)
        backgroundColor = .clear
        layer.shadowColor = UIColor.black.cgColor

        imageView.image = image
        imageView.contentMode = usesPlaceholder ? .center : .scaleAspectFill
        imageView.backgroundColor = usesPlaceholder
            ? UIColor.secondarySystemBackground.withAlphaComponent(0.92)
            : .clear
        imageView.tintColor = .secondaryLabel
        imageView.clipsToBounds = true
        imageView.layer.cornerCurve = .continuous
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(imageView)
        if let videoHost {
            // The video alone flies (its own still under it while it loads).
            imageView.isHidden = true
            videoHost.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(videoHost)
        }
        if bleeds { imageView.mask = fadeMask }

        applyCompactAppearance(isCompact)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:)")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        imageView.frame = bounds
        videoHost?.frame = bounds
        fadeMask.frame = bounds
    }

    /// Called in the flight's animation, right after the new frame.
    func applyCompactAppearance(_ isCompact: Bool) {
        // The music video above the lyrics is as large as on the cover page.
        let isCompact = isCompact && bounds.width < 100
        imageView.layer.cornerRadius = isCompact ? 8 : (bleeds ? 0 : 16)
        if let videoHost {
            videoHost.layer.cornerRadius = isCompact ? 6 : 12
            // The video follows the frame within the same animation.
            layoutIfNeeded()
            videoHost.layoutIfNeeded()
        }
        fadeMask.frame = bounds
        fadeMask.fades = bleeds && !isCompact
        layer.shadowOpacity = isCompact ? 0.26 : (bleeds ? 0 : 0.32)
        layer.shadowRadius = isCompact ? 12 : 28
        layer.shadowOffset = CGSize(width: 0, height: isCompact ? 7 : 18)
    }
}

private struct PlayerSeekSection: View {
    @StateObject private var progress: PlayerSeekProgress
    @Binding private var scrubbingTime: TimeInterval?
    let onSeek: (TimeInterval) -> Void

    init(
        playerService: MusicPlayerService,
        scrubbingTime: Binding<TimeInterval?>,
        onSeek: @escaping (TimeInterval) -> Void
    ) {
        _progress = StateObject(wrappedValue: PlayerSeekProgress(playerService: playerService))
        _scrubbingTime = scrubbingTime
        self.onSeek = onSeek
    }

    var body: some View {
        let displayTime = clamped(scrubbingTime ?? progress.currentTime)

        VStack(spacing: 4) {
            LiquidGlassSeekSlider(
                value: displayTime,
                duration: progress.duration,
                onSeek: { newValue in
                    scrubbingTime = nil
                    onSeek(newValue)
                },
                onScrub: { time in
                    scrubbingTime = time
                },
                onCancel: {
                    scrubbingTime = nil
                }
            )
            .frame(height: 30)
            .overlay {
                // Only while mixing: its blend mode turned the player's
                // fades (turning the phone) into dark blocks.
                if progress.mixGlow != .none { MixGlowView(glow: progress.mixGlow) }
            }

            HStack {
                Text(formattedTime(displayTime))
                Spacer()
                Text(formattedTime(max(progress.duration - displayTime, 0), remaining: true))
            }
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
    }

    private func clamped(_ time: TimeInterval) -> TimeInterval {
        guard progress.duration > 0 else { return 0 }
        return max(0, min(time, progress.duration))
    }

    private func formattedTime(_ time: TimeInterval, remaining: Bool = false) -> String {
        let safeTime = max(0, time)
        let minutes = Int(safeTime) / 60
        let seconds = Int(safeTime) % 60
        return String(format: remaining ? "-%d:%02d" : "%d:%02d", minutes, seconds)
    }
}


/// Like Music's: while songs mix, the end of the bar the music is going
/// out of (then, once the next song is in, its start) softly glows.
private struct MixGlowView: View {
    let glow: MixGlow
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 0) {
            spot.opacity(glow == .incoming ? 1 : 0)
            Spacer(minLength: 0)
            spot.opacity(glow == .outgoing ? 1 : 0)
        }
        .allowsHitTesting(false)
        .animation(.smooth(duration: 0.8), value: glow)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { pulse = true }
        }
    }

    private var spot: some View {
        Capsule()
            .fill(.white)
            .frame(width: 44, height: 7)
            .blur(radius: 7)
            .opacity(pulse ? 0.75 : 0.35)
            .blendMode(.plusLighter)
    }
}

@MainActor
private final class PlayerSeekProgress: ObservableObject {
    @Published private(set) var currentTime: TimeInterval
    @Published private(set) var duration: TimeInterval
    @Published private(set) var mixGlow: MixGlow

    private var cancellables = Set<AnyCancellable>()

    init(playerService: MusicPlayerService) {
        currentTime = playerService.currentTime
        duration = playerService.duration
        mixGlow = playerService.mixGlow

        playerService.$mixGlow
            .removeDuplicates()
            .assign(to: &$mixGlow)

        playerService.$currentTime
            .removeDuplicates()
            .assign(to: &$currentTime)

        playerService.$duration
            .removeDuplicates()
            .assign(to: &$duration)
    }
}

struct PlayerIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

struct PlaybackControlButton: View {
    let icon: String
    let fontSize: CGFloat
    let frameSize: CGFloat
    let action: () -> Void
    var longPressAction: (() -> Void)? = nil

    @State private var isPressed = false
    @State private var repeatTask: Task<Void, Never>?

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: fontSize, weight: .semibold))
            .frame(width: frameSize, height: frameSize)
            .scaleEffect(isPressed ? 0.86 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isPressed)
            .contentShape(Rectangle())
            .onTapGesture { action() }
            .onLongPressGesture(minimumDuration: 0.5, pressing: { pressing in
                isPressed = pressing
                if pressing {
                    startRepeating()
                } else {
                    stopRepeating()
                }
            }, perform: {})
            .onDisappear { stopRepeating() }
            .accessibilityLabel(icon.hasPrefix("backward") ? "Previous" : "Next")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { action() }
    }

    /// Holding the button skips through the song (after the long-press delay).
    private func startRepeating() {
        guard let longPressAction else { return }
        repeatTask?.cancel()
        repeatTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            while !Task.isCancelled {
                longPressAction()
                try? await Task.sleep(for: .milliseconds(600))
            }
        }
    }

    private func stopRepeating() {
        repeatTask?.cancel()
        repeatTask = nil
    }
}

struct AirPlayRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.prioritizesVideoDevices = false
        picker.tintColor = .white
        picker.activeTintColor = .white
        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

struct LiquidGlassSeekSlider: UIViewRepresentable {
    let value: TimeInterval
    let duration: TimeInterval
    let onSeek: (TimeInterval) -> Void
    var onScrub: ((TimeInterval) -> Void)?
    var onCancel: (() -> Void)?

    func makeUIView(context: Context) -> MediaPlaybackSlider {
        let slider = MediaPlaybackSlider()
        slider.minimumValue = 0
        slider.isContinuous = true
        slider.accessibilityLabel = String(localized: "Position")
        slider.onCommit = { [coordinator = context.coordinator] value in
            coordinator.commit(value)
        }
        configure(slider)
        return slider
    }

    func updateUIView(_ slider: MediaPlaybackSlider, context: Context) {
        context.coordinator.parent = self
        slider.onCommit = { [coordinator = context.coordinator] value in
            coordinator.commit(value)
        }
        slider.onChanged = { [coordinator = context.coordinator] value in
            coordinator.scrub(value)
        }
        slider.onCancel = { [coordinator = context.coordinator] in
            coordinator.parent.onCancel?()
        }
        slider.maximumValue = Float(max(duration, 1))
        slider.isEnabled = duration > 0
        configure(slider)

        guard !slider.isScrubbing else { return }

        let clampedValue = Float(clamped(value))
        let secondDelta = abs(slider.value - clampedValue)
        guard secondDelta >= 0.8 else {
            if slider.value == 0, clampedValue > 0 {
                slider.setValue(clampedValue, animated: false)
            }
            return
        }
        slider.setValue(clampedValue, animated: false)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    private func configure(_ slider: MediaPlaybackSlider) {
        slider.minimumTrackTintColor = UIColor.label.withAlphaComponent(0.92)
        slider.maximumTrackTintColor = UIColor.label.withAlphaComponent(0.24)
        slider.thumbTintColor = UIColor.label.withAlphaComponent(0.92)

        if #available(iOS 26.0, *) {
            slider.sliderStyle = .thumbless
        }
    }

    private func clamped(_ time: TimeInterval) -> TimeInterval {
        guard duration > 0 else { return 0 }
        return max(0, min(time, duration))
    }

    final class Coordinator: NSObject {
        var parent: LiquidGlassSeekSlider

        init(parent: LiquidGlassSeekSlider) {
            self.parent = parent
        }

        @MainActor func commit(_ value: Float) {
            parent.onSeek(TimeInterval(value))
        }

        @MainActor func scrub(_ value: Float) {
            parent.onScrub?(TimeInterval(value))
        }
    }
}

    final class MediaPlaybackSlider: UISlider {
    var onCommit: ((Float) -> Void)?
    var onChanged: ((Float) -> Void)?
    var onCancel: (() -> Void)?
    private(set) var isScrubbing = false
    private var trackingStartX: CGFloat = 0
    private var trackingStartValue: Float = 0

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: 0, dy: -12).contains(point)
    }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        isScrubbing = true
        trackingStartX = touch.location(in: self).x
        trackingStartValue = value
        return true
    }

    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        updateValue(relativeTo: touch)
        onChanged?(value)
        return true
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        if let touch {
            updateValue(relativeTo: touch)
        }
        isScrubbing = false
        onCommit?(value)
    }

    override func cancelTracking(with event: UIEvent?) {
        isScrubbing = false
        onCancel?()
    }

    private func updateValue(relativeTo touch: UITouch) {
        let track = trackRect(forBounds: bounds)
        guard track.width > 0 else { return }

        let locationX = touch.location(in: self).x
        let delta = Float((locationX - trackingStartX) / track.width)
        let range = maximumValue - minimumValue
        let updatedValue = trackingStartValue + delta * range
        setValue(min(max(updatedValue, minimumValue), maximumValue), animated: false)
    }
}


struct FullscreenCoverPager: UIViewControllerRepresentable {
    let previousSong: Song?
    let currentSong: Song?
    let nextSong: Song?
    let artworkSize: CGFloat
    let artworkScale: CGFloat
    let allowsPaging: Bool
    let resetID: Int
    /// Full-screen artwork: square corners, no shadow, melting at the bottom.
    var bleeds = false
    /// How far below the top the full-screen artwork sits.
    var bleedLift: CGFloat = 0
    let transitionAnchors: PlayerModeTransitionAnchors
    let onPrevious: () -> Void
    let onNext: () -> Void

    func makeUIViewController(context: Context) -> Controller {
        Controller()
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.configure(
            previousSong: previousSong,
            currentSong: currentSong,
            nextSong: nextSong,
            artworkSize: artworkSize,
            artworkScale: artworkScale,
            allowsPaging: allowsPaging,
            resetID: resetID,
            bleeds: bleeds,
            bleedLift: bleedLift,
            transitionAnchors: transitionAnchors,
            onPrevious: onPrevious,
            onNext: onNext
        )
    }

    final class Controller: UIViewController, UIScrollViewDelegate {
        private enum PageKind {
            case previous
            case current
            case next
        }

        private let scrollView = UIScrollView()
        private let stackView = UIStackView()
        private var pageControllers: [UIHostingController<AnyView>] = []
        private var pageKinds: [PageKind] = []
        private var currentPageIndex = 0
        private var pageSignature = ""
        private var onPrevious: (() -> Void)?
        private var onNext: (() -> Void)?
        private var currentSongID: UUID?
        /// When a swipe last changed the song: those already slid into place.
        private var swipedAt = Date.distantPast
        private var didLayoutInitialOffset = false
        private var lastLayoutWidth: CGFloat = 0
        private var isRecentering = false
        private var renderedArtworkSize: CGFloat = 0
        private var renderedArtworkScale: CGFloat = 1
        private var renderedBleeds = false
        private var renderedLift: CGFloat = 0
        private var didApplyInitialArtworkScale = false
        private var lastResetID = 0

        override func viewDidLoad() {
            super.viewDidLoad()

            view.backgroundColor = .clear
            view.clipsToBounds = false
            scrollView.backgroundColor = .clear
            scrollView.clipsToBounds = false
            scrollView.delegate = self
            scrollView.isPagingEnabled = true
            scrollView.showsHorizontalScrollIndicator = false
            scrollView.showsVerticalScrollIndicator = false
            scrollView.alwaysBounceHorizontal = true
            scrollView.alwaysBounceVertical = false
            scrollView.decelerationRate = .fast
            scrollView.contentInsetAdjustmentBehavior = .never
            scrollView.translatesAutoresizingMaskIntoConstraints = false

            stackView.axis = .horizontal
            stackView.alignment = .fill
            stackView.distribution = .fill
            stackView.spacing = 0
            stackView.clipsToBounds = false
            stackView.translatesAutoresizingMaskIntoConstraints = false

            view.addSubview(scrollView)
            scrollView.addSubview(stackView)

            NSLayoutConstraint.activate([
                scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                scrollView.topAnchor.constraint(equalTo: view.topAnchor),
                scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

                stackView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
                stackView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
                stackView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
                stackView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
                stackView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor)
            ])

            ensurePageControllerCount(1)
            applyNeighbourVisibility()
            neighboursObserver = NotificationCenter.default.addObserver(forName: Self.neighboursNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.applyNeighbourVisibility() }
            }
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            if Self.hidesPages { applyNeighbourVisibility() }
            let width = scrollView.bounds.width
            guard width > 0 else { return }
            // Also when the width changes (an iPhone Duo folded or unfolded
            // with the player open): pages are a width apart.
            guard !didLayoutInitialOffset || (abs(width - lastLayoutWidth) > 0.5 && !scrollView.isDragging && !scrollView.isDecelerating) else { return }
            didLayoutInitialOffset = true
            lastLayoutWidth = width
            scrollView.layoutIfNeeded()
            recenter(animated: false)
        }

        /// True while the screen turns: the offset lags the resizing pages,
        /// so the neighbouring covers would peek in. The presentation's
        /// flying cover stands in for the current one.
        static var hidesPages = false {
            didSet { NotificationCenter.default.post(name: neighboursNotification, object: nil) }
        }
        static let neighboursNotification = Notification.Name("FullscreenCoverPager.neighbours")

        private var neighboursObserver: NSObjectProtocol?

        fileprivate func applyNeighbourVisibility() {
            // The whole strip, so pages added during the turn are hidden too.
            scrollView.alpha = Self.hidesPages ? 0 : 1
        }

        func configure(
            previousSong: Song?,
            currentSong: Song?,
            nextSong: Song?,
            artworkSize: CGFloat,
            artworkScale: CGFloat,
            allowsPaging: Bool,
            resetID: Int,
            bleeds: Bool,
            bleedLift: CGFloat,
            transitionAnchors: PlayerModeTransitionAnchors,
            onPrevious: @escaping () -> Void,
            onNext: @escaping () -> Void
        ) {
            self.onPrevious = onPrevious
            self.onNext = onNext
            // Decode the neighbours' covers ahead of a swipe.
            for song in [previousSong, nextSong].compactMap({ $0 }) {
                let source = song.artworkSource
                Task.detached(priority: .utility) { _ = await ArtworkImageCache.shared.image(for: source, points: artworkSize) }
            }

            let pages = makePages(previousSong: previousSong, currentSong: currentSong, nextSong: nextSong)
            let nextPageSignature = signature(for: pages)
            let pageCountChanged = pageControllers.count != pages.count
            let pageSignatureChanged = pageSignature != nextPageSignature
            let artworkSizeChanged = abs(renderedArtworkSize - artworkSize) > 0.5
            let artworkScaleChanged = abs(renderedArtworkScale - artworkScale) > 0.001

            let sizeChanged = artworkSizeChanged || artworkScaleChanged
            let needsRebuild = pageCountChanged || pageSignatureChanged || artworkSizeChanged || renderedBleeds != bleeds || abs(renderedLift - bleedLift) > 0.5
            let resetChanged = lastResetID != resetID

            // Always align the page count before touching pageControllers by index,
            // otherwise a 1 -> 3 transition (initial open) crashes with index-out-of-range.
            if pageCountChanged {
                ensurePageControllerCount(pages.count)
            }
            pageKinds = pages.map(\.kind)
            currentPageIndex = pages.firstIndex { $0.kind == .current } ?? 0
            // Full-screen, the page registers its sharp artwork itself: the
            // blur around it stays while a copy flies in its place.
            if !bleeds {
                transitionAnchors.registerArtworkView(pageControllers[currentPageIndex].view, for: .large)
            }

            // Full-screen, a song changed by the buttons (or ending) fades
            // over: a cut showed the new cover before its colors below.
            // Mixing, the covers cross-fade as slowly as the songs do.
            let mixing = MusicPlayerService.shared.mixGlow != .none
            if bleeds == renderedBleeds, bleeds || mixing, currentSongID != nil, currentSongID != currentSong?.id,
               Date().timeIntervalSince(swipedAt) > 0.6, view.window != nil,
               case let area = CGRect(x: 0, y: -bleedLift, width: view.bounds.width, height: bleedLift + view.bounds.height * 2.1),
               let still = view.resizableSnapshotView(from: area, afterScreenUpdates: false, withCapInsets: .zero) {
                // The blur reaches above and below the pager: all of it fades.
                still.frame = area
                still.isUserInteractionEnabled = false
                view.addSubview(still)
                UIView.animate(withDuration: mixing ? 1.4 : 0.4, delay: 0.05, options: [.curveEaseInOut, .allowUserInteraction]) {
                    still.alpha = 0
                } completion: { _ in
                    still.removeFromSuperview()
                }
            }

            if needsRebuild {
                for (index, page) in pages.enumerated() {
                    pageControllers[index].rootView = AnyView(
                        FullscreenCoverPage(
                            song: page.song,
                            artworkSize: artworkSize,
                            bleeds: bleeds,
                            lift: bleedLift,
                            opensLeading: index == 0,
                            opensTrailing: index == pages.count - 1,
                            anchors: page.kind == .current ? transitionAnchors : nil
                        )
                    )
                }
                renderedLift = bleedLift
                renderedArtworkSize = artworkSize
                renderedBleeds = bleeds
            }

            if sizeChanged {
                applyArtworkScale(artworkScale)
            }

            scrollView.isScrollEnabled = allowsPaging && pages.count > 1

            if currentSongID != currentSong?.id || pageSignatureChanged {
                currentSongID = currentSong?.id
                pageSignature = nextPageSignature
                recenter(animated: false)
            }

            if resetChanged {
                lastResetID = resetID
                recenter(animated: false)
            }
        }

        private func applyArtworkScale(_ scale: CGFloat) {
            let transform = CGAffineTransform(scaleX: scale, y: scale)
            let shouldAnimate = didApplyInitialArtworkScale && view.window != nil
            let changes = { [pageControllers] in
                pageControllers.forEach { $0.view.transform = transform }
            }

            if shouldAnimate {
                // Apple Music's cover "breathes" in and out with a soft spring.
                UIView.animate(
                    springDuration: 0.55,
                    bounce: 0.22,
                    initialSpringVelocity: 0,
                    delay: 0,
                    options: [.allowUserInteraction, .beginFromCurrentState],
                    animations: changes
                )
            } else {
                changes()
                didApplyInitialArtworkScale = true
            }

            renderedArtworkScale = scale
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            isRecentering = false
        }


        func scrollViewDidScroll(_ scrollView: UIScrollView) {
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate {
                finishScroll()
            }
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            finishScroll()
        }

        private func finishScroll() {
            guard !isRecentering, scrollView.bounds.width > 0 else { return }

            let rawPage = Int(round(scrollView.contentOffset.x / scrollView.bounds.width))
            let page = min(max(rawPage, 0), max(pageKinds.count - 1, 0))
            switch pageKinds[safe: page] {
            case .previous:
                swipedAt = Date()
                onPrevious?()
                return
            case .next:
                swipedAt = Date()
                onNext?()
                return
            default:
                break
            }

            recenter(animated: page == currentPageIndex)
        }

        private func recenter(animated: Bool) {
            guard scrollView.bounds.width > 0 else { return }
            isRecentering = true
            scrollView.setContentOffset(CGPoint(x: scrollView.bounds.width * CGFloat(currentPageIndex), y: 0), animated: animated)
            if !animated {
                isRecentering = false
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [weak self] in
                    self?.isRecentering = false
                }
            }
        }

        private func makePages(previousSong: Song?, currentSong: Song?, nextSong: Song?) -> [(kind: PageKind, song: Song?)] {
            var pages: [(kind: PageKind, song: Song?)] = []
            if let previousSong {
                pages.append((.previous, previousSong))
            }
            pages.append((.current, currentSong))
            if let nextSong {
                pages.append((.next, nextSong))
            }
            return pages
        }

        private func signature(for pages: [(kind: PageKind, song: Song?)]) -> String {
            pages
                .map { "\($0.kind)-\($0.song?.id.uuidString ?? "nil")" }
                .joined(separator: "|")
        }

        private func ensurePageControllerCount(_ count: Int) {
            while pageControllers.count < count {
                let controller = UIHostingController(rootView: AnyView(FullscreenCoverPage(song: nil, artworkSize: 240)))
                // Centered on the page, not on its safe area (see the cover
                // controller).
                controller.safeAreaRegions = []
                addChild(controller)
                controller.view.backgroundColor = .clear
                controller.view.clipsToBounds = false
                controller.view.transform = CGAffineTransform(scaleX: renderedArtworkScale, y: renderedArtworkScale)
                controller.view.translatesAutoresizingMaskIntoConstraints = false
                stackView.addArrangedSubview(controller.view)
                NSLayoutConstraint.activate([
                    controller.view.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
                    controller.view.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor)
                ])
                controller.didMove(toParent: self)
                pageControllers.append(controller)
            }

            while pageControllers.count > count, let controller = pageControllers.last {
                controller.willMove(toParent: nil)
                stackView.removeArrangedSubview(controller.view)
                controller.view.removeFromSuperview()
                controller.removeFromParent()
                pageControllers.removeLast()
            }
        }
    }
}

struct FullscreenCoverPage: View {
    let song: Song?
    let artworkSize: CGFloat
    var bleeds = false
    var lift: CGFloat = 0
    /// The first or last page: its blur carries on into the void the
    /// rubber band shows.
    var opensLeading = false
    var opensTrailing = false
    /// The current page's: its sharp artwork hides while a copy flies.
    var anchors: PlayerModeTransitionAnchors?
    @ObservedObject private var musicVideo = MusicVideoPlayer.shared

    /// The song's music video stands in for the cover: the square flattens
    /// to the video's shape, centered, as wide as before.
    private var showsVideo: Bool {
        anchors != nil && song != nil && musicVideo.shownSongID == song?.id
    }

    var body: some View {
        ZStack {
            if bleeds {
                // Square at the top of the page: the page reaches further
                // down so the area under the cover swipes too.
                bleedingArtwork
                    .frame(width: artworkSize, height: artworkSize)
                    .frame(maxHeight: .infinity, alignment: .top)
            } else {
                ZStack {
                    artwork
                        .frame(width: artworkSize, height: artworkSize)
                        .opacity(showsVideo ? 0 : 1)
                    if showsVideo {
                        // The corners the cover page clips to: the video,
                        // over it, rounds its own.
                        MusicVideoHost(role: .large, cornerRadius: 12)
                            .frame(width: MusicVideoPlayer.videoSize(side: artworkSize).width, height: MusicVideoPlayer.videoSize(side: artworkSize).height)
                            // There at once: the video over it fades in itself.
                            .transition(.identity)
                    }
                }
                .frame(width: showsVideo ? MusicVideoPlayer.videoSize(side: artworkSize).width : artworkSize,
                       height: showsVideo ? MusicVideoPlayer.videoSize(side: artworkSize).height : artworkSize)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                // A tap: the song's music video, or back to the cover.
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .onTapGesture {
                    guard anchors != nil, let song, MusicVideoFeature.isAvailable else { return }
                    MusicVideoPlayer.shared.toggle(for: song)
                }
                .modifier(MusicVideoMenu(song: anchors != nil ? song : nil, width: artworkSize))
                .shadow(color: .black.opacity(0.32), radius: 28, y: 18)
                // Whatever rebuilt the page, the shape always eases.
                .animation(.spring(duration: 0.6, bounce: 0.12), value: showsVideo)
                // A page handed another song (after a swipe) starts afresh:
                // its cover doesn't morph from the last song's video.
                .id(song?.id)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var artwork: some View {
        ArtworkImage(source: song?.artworkSource, cornerRadius: 12, points: artworkSize)
    }

    private var blurWidth: CGFloat {
        artworkSize * (1 + (opensLeading ? 1 : 0) + (opensTrailing ? 1 : 0))
    }

    /// The sharp artwork over one continuous blur of itself: its top and
    /// bottom edges mirrored above and below, blurred together so there's
    /// no seam, melting into the colors at the bottom. As wide as the page:
    /// pages swipe like panels.
    private var screenHeight: CGFloat {
        (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen.bounds.height ?? .greatestFiniteMagnitude
    }

    private var bleedingArtwork: some View {
        let size = artworkSize
        // Down to the bottom of the screen, behind the controls.
        let below = size * 1.1
        let total = lift + size + below
        let source = song?.artworkSource
        let width = size * (1 + (opensLeading ? 1 : 0) + (opensTrailing ? 1 : 0))
        return ZStack {
            BleedingArtworkBlur(
                request: BleedingBlurRequest(
                    source: source, size: size, lift: lift, below: below,
                    opensLeading: opensLeading, opensTrailing: opensTrailing
                )
            )
            .frame(width: width, height: total)
            .mask {
                // The blur reaches past the screen: the melt into the
                // player's own background ends at the screen's bottom.
                NowPlayingArtworkStyle.extensionFade(start: (lift + size) / total, end: min(1, screenHeight / total))
            }
            .offset(x: ((opensTrailing ? size : 0) - (opensLeading ? size : 0)) / 2, y: (below - lift) / 2)

            BleedingArtworkSharp(source: source, points: size, anchors: anchors)
                .frame(width: size, height: size)
        }
        .allowsHitTesting(false)
    }
}

struct BleedingBlurRequest: Hashable {
    let source: ArtworkSource?
    let size: CGFloat
    let lift: CGFloat
    let below: CGFloat
    let opensLeading: Bool
    let opensTrailing: Bool

    /// The same cover with the other sides open.
    var variants: [BleedingBlurRequest] {
        [(false, false), (true, false), (false, true), (true, true)]
            .filter { $0 != (opensLeading, opensTrailing) }
            .map { BleedingBlurRequest(source: source, size: size, lift: lift, below: below, opensLeading: $0.0, opensTrailing: $0.1) }
    }

    static func == (a: Self, b: Self) -> Bool { a.key == b.key }
    func hash(into hasher: inout Hasher) { hasher.combine(key) }

    var key: String {
        "\(source?.cacheKey ?? "-")|\(Int(size))|\(Int(lift))|\(Int(below))|\(opensLeading)|\(opensTrailing)"
    }
}

/// The blur behind the full-screen artwork, drawn once per song as a
/// single image: the artwork with its edges mirrored above and below (and
/// sideways into the void at the queue's ends), blurred with clamped
/// edges so nothing dark creeps in.
private struct BleedingArtworkBlur: View {
    let request: BleedingBlurRequest
    @State private var image: UIImage?
    @State private var key: String?

    var body: some View {
        let displayed = key == request.key ? image : BleedingBlurRenderer.cached(request)
        ZStack {
            if let displayed {
                Image(uiImage: displayed).resizable()
            }
        }
        .task(id: request.key) {
            if let cached = BleedingBlurRenderer.cached(request) {
                image = cached
                key = request.key
            } else {
                let rendered = await BleedingBlurRenderer.render(request)
                guard !Task.isCancelled else { return }
                image = rendered
                key = request.key
            }
            // A swipe rebuilds the pages and the one reaching the queue's
            // end opens a side: its other shapes are ready by then, no blink.
            for variant in request.variants where BleedingBlurRenderer.cached(variant) == nil {
                _ = await BleedingBlurRenderer.render(variant)
            }
        }
    }
}

@MainActor
enum BleedingBlurRenderer {
    private static let cache = NSCache<NSString, UIImage>()
    private static let context = CIContext(options: [.useSoftwareRenderer: false])
    /// Drawn small: it's blurred anyway.
    private static let scale: CGFloat = 0.25

    static func cached(_ request: BleedingBlurRequest) -> UIImage? {
        cache.object(forKey: request.key as NSString)
    }

    static func render(_ request: BleedingBlurRequest) async -> UIImage? {
        guard let source = request.source,
              let artwork = await ArtworkImageCache.shared.image(for: source, points: 160) else { return nil }
        let key = request.key
        let ciContext = context
        let s = scale
        let image = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            let side = request.size * s
            let columns = 1 + (request.opensLeading ? 1 : 0) + (request.opensTrailing ? 1 : 0)
            let canvas = CGSize(width: side * CGFloat(columns), height: (request.lift + request.size + request.below) * s)
            let top = request.lift * s
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let drawn = UIGraphicsImageRenderer(size: canvas, format: format).image { renderer in
                let cg = renderer.cgContext
                for column in 0..<columns {
                    let flipsX = (request.opensLeading && column == 0) || (request.opensTrailing && column == columns - 1)
                    cg.saveGState()
                    cg.translateBy(x: CGFloat(column) * side, y: 0)
                    if flipsX {
                        cg.translateBy(x: side, y: 0)
                        cg.scaleBy(x: -1, y: 1)
                    }
                    // The artwork, then its top mirrored above and its
                    // bottom mirrored below (twice, the space below is
                    // taller than the artwork).
                    artwork.draw(in: CGRect(x: 0, y: top, width: side, height: side))
                    for y in [top - side, top + side] {
                        cg.saveGState()
                        cg.translateBy(x: 0, y: 2 * y + side)
                        cg.scaleBy(x: 1, y: -1)
                        artwork.draw(in: CGRect(x: 0, y: y, width: side, height: side))
                        cg.restoreGState()
                    }
                    artwork.draw(in: CGRect(x: 0, y: top + 2 * side, width: side, height: side))
                    cg.restoreGState()
                }
            }
            guard let input = CIImage(image: drawn) else { return nil }
            let extent = input.extent
            let blurred = input.clampedToExtent()
                .applyingGaussianBlur(sigma: 36 * s)
                .cropped(to: extent)
            guard let output = ciContext.createCGImage(blurred, from: extent) else { return nil }
            return UIImage(cgImage: output)
        }.value
        if let image { cache.setObject(image, forKey: key as NSString) }
        return image
    }
}

private struct BleedingArtworkSharp: UIViewRepresentable {
    let source: ArtworkSource?
    let points: CGFloat
    let anchors: PlayerModeTransitionAnchors?

    func makeUIView(context: Context) -> BleedingArtworkView { BleedingArtworkView() }

    func updateUIView(_ view: BleedingArtworkView, context: Context) {
        view.configure(source: source, points: points)
        anchors?.registerArtworkView(view, for: .large)
    }
}

/// The full-screen cover's sharp artwork, melting at both edges.
final class BleedingArtworkView: UIView {
    private let imageView = UIImageView()
    private let fadeMask = ArtworkFadeMaskView()
    private var key: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        addSubview(imageView)
        fadeMask.fades = true
        imageView.mask = fadeMask
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:)")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        imageView.frame = bounds
        fadeMask.frame = bounds
    }

    func configure(source: ArtworkSource?, points: CGFloat) {
        let key = source.map { "\($0)-\(points)" }
        guard key != self.key else { return }
        self.key = key
        guard let source else { imageView.image = nil; return }
        if let image = ArtworkImageCache.shared.cachedImage(for: source, points: points) {
            imageView.image = image
            return
        }
        imageView.image = ArtworkImageCache.shared.cachedImage(for: source, points: 160)
        Task { [weak self] in
            let image = await ArtworkImageCache.shared.image(for: source, points: points)
            guard let self, self.key == key else { return }
            self.imageView.image = image
        }
    }
}

/// "Full-Screen Artwork" in Settings › Now Playing.
enum NowPlayingArtworkStyle {
    static let storageKey = "nowPlayingFullScreenArtwork"

    /// Opaque down to just past the middle, then eased out (a linear melt
    /// shows as a band). Shared by the cover and the covers that fly in
    /// its place, so nothing changes at the hand-off.
    /// Both edges melt, eased, into the blurred extensions above and below.
    /// The top melts slowly, the bottom quicker (the title sits there).
    static let fadeStops: [(location: CGFloat, opacity: CGFloat)] = [
        (0, 0), (0.08, 0.2), (0.17, 0.52), (0.26, 0.82), (0.34, 1),
        (0.66, 1), (0.75, 0.84), (0.84, 0.55), (0.92, 0.22), (1, 0)
    ]

    /// Solid down to `start`, then eased out.
    static func extensionFade(start: CGFloat, end: CGFloat = 1) -> some View {
        // A smoothstep in many stops: no kink anywhere for the eye to catch.
        let steps = 24
        let fade = (0...steps).map { step -> Gradient.Stop in
            let t = CGFloat(step) / CGFloat(steps)
            // Smootherstep: flat at both ends, no edge where it starts or stops.
            let eased = t * t * t * (t * (t * 6 - 15) + 10)
            return .init(color: .black.opacity(1 - eased), location: start + (end - start) * t)
        }
        return LinearGradient(
            stops: [.init(color: .black, location: 0)] + fade,
            startPoint: .top,
            endPoint: .bottom
        )
    }

    static var fade: some View {
        LinearGradient(
            stops: fadeStops.map { Gradient.Stop(color: .black.opacity($0.opacity), location: $0.location) },
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

/// A mask for a flying cover: solid while it is a card, melting at the
/// bottom like the full-screen artwork when `fades`. Both are views, so a
/// spring moving the cover carries the mask along (set its frame and
/// `fades` in the same animation).
final class ArtworkFadeMaskView: UIView {
    private final class GradientView: UIView {
        override class var layerClass: AnyClass { CAGradientLayer.self }
    }

    private let solid = UIView()

    var fades = false {
        didSet { solid.alpha = fades ? 0 : 1 }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        let gradient = GradientView()
        if let layer = gradient.layer as? CAGradientLayer {
            layer.colors = NowPlayingArtworkStyle.fadeStops.map { UIColor.black.withAlphaComponent($0.opacity).cgColor }
            layer.locations = NowPlayingArtworkStyle.fadeStops.map { NSNumber(value: Double($0.location)) }
        }
        solid.backgroundColor = .black
        for view in [gradient, solid] {
            view.frame = bounds
            view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(view)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:)")
    }
}

// MARK: - Native GPU-Accelerated Player Background

struct PlayerBackgroundRepresentable: UIViewRepresentable {
    let artwork: ArtworkSource?

    func makeUIView(context: Context) -> PlayerBackgroundUIView {
        let view = PlayerBackgroundUIView()
        view.update(source: artwork, animated: false)
        return view
    }

    func updateUIView(_ uiView: PlayerBackgroundUIView, context: Context) {
        uiView.update(source: artwork, animated: true)
    }
}

final class PlayerBackgroundUIView: UIView {
    // 4 radial gradient spot layers near the 4 corners of the player
    private let spotLayers: [CAGradientLayer] = (0..<4).map { _ in
        let layer = CAGradientLayer()
        layer.type = .radial
        layer.startPoint = CGPoint(x: 0.5, y: 0.5)
        layer.endPoint = CGPoint(x: 1.0, y: 1.0)
        layer.locations = [0.0, 0.25, 0.55, 0.80, 1.0]
        return layer
    }

    private let scrimLayer = CALayer()
    private let vignetteLayer = CAGradientLayer()
    /// Above the colors, upright whatever this view's own turn.
    private let motionView = MotionArtworkView()

    private var currentSource: ArtworkSource?
    private var currentColors: [UIColor]?
    /// The cover's own colors, under a music video's while one shows.
    private var artworkColors: [UIColor]?
    private var videoObserver: NSObjectProtocol?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupLayers()
        videoObserver = NotificationCenter.default.addObserver(forName: MusicVideoPlayer.colorsDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.followVideoColors() }
        }
    }

    /// Fades to the video's colors as its scenes change, and back to the
    /// cover's when it stops.
    private func followVideoColors() {
        // The cover's colors stay (the video's made a flat, muddy blur).
        guard Self.followsVideo else { return }
        if let colors = MusicVideoPlayer.shared.colors {
            applyColors(colors, animated: true, duration: 1.4)
        } else if let artworkColors {
            applyColors(artworkColors, animated: true, duration: 0.8)
        }
    }
    private static let followsVideo = true

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupLayers() {
        // Deep dark base (not pitch black so diffused colors blend softly into dark atmosphere)
        backgroundColor = UIColor(red: 0.05, green: 0.05, blue: 0.07, alpha: 1.0)
        clipsToBounds = true

        for spot in spotLayers {
            layer.addSublayer(spot)
        }

        // Scrim layer: gentle darkening so text, artwork, and buttons pop
        scrimLayer.backgroundColor = UIColor.black.withAlphaComponent(0.20).cgColor
        layer.addSublayer(scrimLayer)

        // Vignette layer: subtle darkening gradient toward bottom for playback controls
        vignetteLayer.startPoint = CGPoint(x: 0.5, y: 0)
        vignetteLayer.endPoint = CGPoint(x: 0.5, y: 1)
        updateVignetteColors()
        layer.addSublayer(vignetteLayer)

        addSubview(motionView)
    }

    /// The card turns this view against the screen's turn so the colors
    /// stay put; the video turns back to stay upright.
    override var transform: CGAffineTransform {
        didSet { setNeedsLayout() }
    }

    private func updateVignetteColors() {
        vignetteLayer.colors = [
            UIColor.clear.cgColor,
            UIColor.black.withAlphaComponent(0.12).cgColor,
            UIColor.black.withAlphaComponent(0.38).cgColor
        ]
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        // Inside a rotation the color spots follow the screen's turn instead
        // of jumping to their new corners.
        let duration = UIView.inheritedAnimationDuration
        if duration > 0 {
            CATransaction.setAnimationDuration(duration)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        } else {
            CATransaction.setDisableActions(true)
        }

        scrimLayer.frame = bounds
        vignetteLayer.frame = bounds

        let angle = atan2(transform.b, transform.a)
        let sideways = Int((abs(angle) / (.pi / 2)).rounded()) % 2 == 1
        motionView.transform = .identity
        motionView.bounds.size = sideways ? CGSize(width: bounds.height, height: bounds.width) : bounds.size
        motionView.center = CGPoint(x: bounds.midX, y: bounds.midY)
        motionView.transform = CGAffineTransform(rotationAngle: -angle)

        // Large spot diameter so the 4 blooms gracefully overlap in the center
        let spotDiameter = max(bounds.width, bounds.height) * 1.1

        // Center coordinates for the 4 spots near the 4 corners:
        // Top-Left, Top-Right, Bottom-Left, Bottom-Right
        let centers: [CGPoint] = [
            CGPoint(x: bounds.width * 0.12, y: bounds.height * 0.14), // Top-Left
            CGPoint(x: bounds.width * 0.88, y: bounds.height * 0.14), // Top-Right
            CGPoint(x: bounds.width * 0.12, y: bounds.height * 0.82), // Bottom-Left
            CGPoint(x: bounds.width * 0.88, y: bounds.height * 0.82)  // Bottom-Right
        ]

        for (index, spot) in spotLayers.enumerated() {
            let center = centers[index]
            spot.frame = CGRect(
                x: center.x - spotDiameter / 2,
                y: center.y - spotDiameter / 2,
                width: spotDiameter,
                height: spotDiameter
            )
        }

        CATransaction.commit()
    }

    private func spotCGColors(for color: UIColor) -> [CGColor] {
        return [
            color.withAlphaComponent(0.92).cgColor,
            color.withAlphaComponent(0.68).cgColor,
            color.withAlphaComponent(0.35).cgColor,
            color.withAlphaComponent(0.12).cgColor,
            color.withAlphaComponent(0.0).cgColor
        ]
    }

    func update(source: ArtworkSource?, animated: Bool) {
        if source == currentSource && currentColors != nil {
            return
        }
        currentSource = source
        guard let source else {
            artworkColors = Song.fallbackArtworkUIColors
            applyColors(Song.fallbackArtworkUIColors, animated: animated)
            return
        }
        Task { [weak self] in
            let colors = await Task.detached(priority: .userInitiated) {
                Song.playerArtworkUIColors(for: source)
            }.value
            guard let self, self.currentSource == source else { return }
            self.artworkColors = colors
            if !Self.followsVideo || MusicVideoPlayer.shared.colors == nil {
                self.applyColors(colors, animated: animated)
            }
        }
    }

    private func applyColors(_ newColors: [UIColor], animated: Bool, duration: CFTimeInterval? = nil) {
        currentColors = newColors

        for (index, spot) in spotLayers.enumerated() {
            let color = newColors[safe: index] ?? newColors.first ?? Song.fallbackArtworkUIColors[index % Song.fallbackArtworkUIColors.count]
            let newCGColors = spotCGColors(for: color)

            guard animated, let oldColors = (spot.presentation()?.colors as? [CGColor]) ?? (spot.colors as? [CGColor]), !oldColors.isEmpty else {
                spot.removeAllAnimations()
                spot.colors = newCGColors
                continue
            }

            let animation = CABasicAnimation(keyPath: "colors")
            animation.fromValue = oldColors
            animation.toValue = newCGColors
            animation.duration = duration ?? (MusicPlayerService.shared.mixGlow != .none ? 1.6 : 0.85)
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

            spot.colors = newCGColors
            spot.add(animation, forKey: "colorsTransition")
        }
    }
}


/// The line being sung, between the title and the scrubber, like Music.
/// A tap opens the lyrics. Its own view so only it follows the song.
struct NowPlayingLyricPreview: View {
    static let storageKey = "showPlayerLyricPreview"

    @ObservedObject var playerVM: PlayerViewModel
    @AppStorage(Self.storageKey) private var isEnabled = true

    var body: some View {
        if isEnabled, playerVM.currentSongHasLRC, playerVM.currentLyrics?.lines.isEmpty == false {
            Button {
                playerVM.showLyrics = true
            } label: {
                HStack(spacing: 8) {
                    lineView
                        .id(lineText)
                        .transition(.opacity)
                    Image(systemName: "chevron.forward")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.62))
                    Spacer(minLength: 0)
                }
                .frame(height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .animation(.easeInOut(duration: 0.25), value: lineText)
            .accessibilityLabel("Lyrics: \(lineText)")
            .accessibilityHint("Opens the lyrics")
            .padding(.bottom, 14)
        }
    }

    @ViewBuilder
    private var lineView: some View {
        let line = playerVM.currentLyricLine
        if let line, !line.isInstrumentalGap, let timings = playerVM.currentWordTimings[line.id], !timings.isEmpty {
            WordSyncedPreviewLine(text: line.text, timings: timings, lineEnd: lineEnd(after: line), playerService: playerVM.playerService)
        } else {
            Text(lineText)
                .font(Self.font)
                .foregroundStyle(.white)
                .lineLimit(1)
        }
    }

    static let font = Font.body.weight(.semibold)

    /// When the next line takes over: the scroll must have reached the end.
    private func lineEnd(after line: LyricsLine) -> TimeInterval? {
        playerVM.currentLyrics?.lines.first { $0.time > line.time }?.time
    }

    /// Before the first line and through instrumental breaks, the next
    /// line to come.
    private var lineText: String {
        if let line = playerVM.currentLyricLine, !line.isInstrumentalGap { return line.text }
        let lines = playerVM.currentLyrics?.lines ?? []
        let now = playerVM.currentLyricLine?.time ?? -.infinity
        return lines.first { $0.time > now && !$0.isInstrumentalGap }?.text ?? ""
    }
}


/// A word-synced line lights up as it is sung (no glow here) and, when too
/// long for its row, scrolls along with the singing instead of ending in an
/// ellipsis. Driven by the display, like the lyrics.
private struct WordSyncedPreviewLine: UIViewRepresentable {
    let text: String
    let timings: [WordTiming]
    let lineEnd: TimeInterval?
    let playerService: MusicPlayerService

    func makeUIView(context: Context) -> PreviewLineUIView {
        PreviewLineUIView()
    }

    func updateUIView(_ view: PreviewLineUIView, context: Context) {
        view.time = { [playerService] in playerService.preciseCurrentTime }
        view.configure(text: text, timings: timings, lineEnd: lineEnd)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: PreviewLineUIView, context: Context) -> CGSize? {
        CGSize(width: min(uiView.textWidth, proposal.width ?? uiView.textWidth), height: 28)
    }
}

final class PreviewLineUIView: UIView {
    var time: (() -> TimeInterval)?
    private(set) var textWidth: CGFloat = 0

    private let strip = CALayer()
    private let dimLayer = CALayer()
    private let litLayer = CALayer()
    private let litMask = CAGradientLayer()
    private let edgeMask = CAGradientLayer()
    private var text = ""
    private var timings: [WordTiming] = []
    /// Where each word starts along the text, in points, and where it ends.
    private var wordStarts: [CGFloat] = []
    private lazy var link = PlaybackDisplayLink { [weak self] in self?.tick() }

    /// The scroll's lag behind the singing, in seconds.
    private static let scrollSmoothing: TimeInterval = 0.45
    private var lineEnd: TimeInterval?
    private var scrollOffset: CGFloat?
    private var scrollTime: TimeInterval?

    private static let softEdge: CGFloat = 22
    private static let fade: CGFloat = 14

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        dimLayer.opacity = 0.45
        litMask.startPoint = CGPoint(x: 0, y: 0.5)
        litMask.endPoint = CGPoint(x: 1, y: 0.5)
        litMask.colors = [UIColor.black.cgColor, UIColor.black.cgColor, UIColor.clear.cgColor, UIColor.clear.cgColor]
        litLayer.mask = litMask
        strip.addSublayer(dimLayer)
        strip.addSublayer(litLayer)
        layer.addSublayer(strip)
        edgeMask.startPoint = CGPoint(x: 0, y: 0.5)
        edgeMask.endPoint = CGPoint(x: 1, y: 0.5)
        edgeMask.colors = [UIColor.clear.cgColor, UIColor.black.cgColor, UIColor.black.cgColor, UIColor.clear.cgColor]
        layer.mask = edgeMask
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(text: String, timings: [WordTiming], lineEnd: TimeInterval?) {
        // The line is over at the next line or with its last word, whichever
        // comes first.
        let ends = [lineEnd, timings.last?.end].compactMap { $0 }
        self.lineEnd = ends.min()
        link.wakeUp()
        guard text != self.text || timings != self.timings else { return }
        self.text = text
        self.timings = timings
        scrollOffset = nil
        scrollTime = nil
        let font = UIFont.systemFont(ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize, weight: .semibold)
        let attributed = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: UIColor.white])
        let size = attributed.size()
        textWidth = ceil(size.width)
        let image = UIGraphicsImageRenderer(size: CGSize(width: textWidth, height: ceil(size.height))).image { _ in
            attributed.draw(at: .zero)
        }.cgImage
        wordStarts = LyricWords.ranges(in: text).map {
            NSAttributedString(string: String(text[..<$0.lowerBound]), attributes: [.font: font]).size().width
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dimLayer.contents = image
        litLayer.contents = image
        CATransaction.commit()
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let height = dimLayer.contents.map { CGFloat(($0 as! CGImage).height) / max(traitCollection.displayScale, 1) } ?? bounds.height
        let frame = CGRect(x: 0, y: (bounds.height - height) / 2, width: textWidth, height: height)
        strip.frame = frame
        dimLayer.frame = CGRect(origin: .zero, size: frame.size)
        litLayer.frame = dimLayer.frame
        litMask.frame = dimLayer.frame
        edgeMask.frame = bounds
        CATransaction.commit()
        tick()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        link.stop()
        guard window != nil else { return }
        link.start()
    }

    /// The sung point, in points along the text: it glides from one word's
    /// start to the next over the time between them.
    private func sungPoint(at now: TimeInterval) -> CGFloat {
        let count = min(wordStarts.count, timings.count)
        guard count > 0, now >= timings[0].start else { return 0 }
        for index in 0..<count {
            let start = timings[index].start
            let next = index + 1 < count ? timings[index + 1].start : timings[index].end
            guard now < next else { continue }
            let progress = CGFloat(min(max((now - start) / max(next - start, 0.05), 0), 1))
            let from = wordStarts[index]
            let to = index + 1 < count ? wordStarts[index + 1] : textWidth
            return from + (to - from) * progress
        }
        return textWidth
    }

    private func tick() {
        guard textWidth > 0, bounds.width > 0, let now = time?() else { return }
        let point = sungPoint(at: now)
        let available = bounds.width
        let overflow = max(textWidth - available, 0)
        // Starts moving once the singing reaches the middle, then keeps the
        // sung point there. The target follows each word's own pace, so the
        // scroll eases toward it rather than copying its changes of speed.
        // It aims a lag ahead, so on average it is where the singing is,
        // and has reached the end of the line by the time the line ends.
        let ahead = sungPoint(at: now + Self.scrollSmoothing)
        let target = min(max(ahead - available * 0.5, 0), overflow)
        var offset: CGFloat
        if let last = scrollOffset, let lastTime = scrollTime, now >= lastTime, now - lastTime < 0.25 {
            let smoothing = 1 - exp(-(now - lastTime) / Self.scrollSmoothing)
            offset = last + (target - last) * CGFloat(smoothing)
            // Easing alone only gets close: over the line's last moments the
            // scroll closes the gap to the end exactly by the time it ends.
            if let lineEnd, lineEnd - now < Self.scrollSmoothing, offset < overflow {
                let share = min((now - lastTime) / max(lineEnd - now, 1.0 / 120), 1)
                offset = max(offset, last + (overflow - last) * CGFloat(share))
            }
        } else {
            offset = target
        }
        scrollOffset = offset
        scrollTime = now
        // Rests once paused and the scroll has caught up.
        link.note(time: now, settled: abs(target - offset) < 0.1)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        strip.frame.origin.x = -offset
        // The lit part ends in a soft edge, fully lit once the line is sung.
        let edge = Self.softEdge / textWidth
        let lit = point >= textWidth ? 1 + edge : point / textWidth
        litMask.locations = [0, NSNumber(value: Double(max(lit - edge, 0))), NSNumber(value: Double(lit)), 1]
        // Edges fade only where they cut text off.
        let left = min(offset, Self.fade) / available
        let right = min(overflow - offset, Self.fade) / available
        edgeMask.locations = [0, NSNumber(value: Double(left)), NSNumber(value: Double(1 - right)), 1]
        CATransaction.commit()
    }
}

/// The Now Playing menu's translation item, when Lyrics Translation is on.
/// Its own view: the translator's updates don't redraw the player.
private struct TranslateLyricsMenuItem: View {
    let onTranslate: () -> Void
    @ObservedObject private var translator = LyricsTranslator.shared
    @AppStorage(LyricsTranslator.enabledKey) private var isEnabled = false

    var body: some View {
        if isEnabled {
            if translator.isRequested {
                Button("Show Original Lyrics", systemImage: "character.bubble") {
                    translator.setTranslated(false)
                }
            } else {
                Button("Translate Lyrics", systemImage: "translate") {
                    translator.setTranslated(true)
                    onTranslate()
                }
            }
        }
    }
}

/// Touch and hold the music video: back to the cover, another video, or
/// iOS's own player full screen.
private struct MusicVideoMenu: ViewModifier {
    let song: Song?
    let width: CGFloat
    @ObservedObject private var musicVideo = MusicVideoPlayer.shared

    private var showsVideo: Bool { song != nil && musicVideo.shownSongID == song?.id }

    func body(content: Content) -> some View {
        content.contextMenu {
            // While the video is wanted (shown, or not found).
            if let song, musicVideo.isWanted(for: song) {
                Button("Show Cover", systemImage: "photo") {
                    MusicVideoPlayer.shared.toggle(for: song)
                }
                Button("Wrong Video?", systemImage: "rectangle.stack.badge.play") {
                    MusicVideoPlayer.shared.picksAnotherVideo = true
                }
                if showsVideo {
                    Button("Show Full Screen", systemImage: "arrow.up.left.and.arrow.down.right") {
                        MusicVideoPlayer.shared.enterFullScreen()
                    }
                }
                if let url = MusicVideoPlayer.shared.youTubeURL(for: song) {
                    Button("Open in YouTube", systemImage: "play.rectangle") {
                        // The YouTube app takes its links; Safari otherwise.
                        if MusicPlayerService.shared.isPlaying { MusicPlayerService.shared.pause() }
                        UIApplication.shared.open(url)
                    }
                }
            }
        } preview: {
            preview
        }
        // The menu's icons in the cover's colors, like the ··· menu.
        .tint(song?.coverMenuTint ?? .white)
    }

    /// The video lives above the page: its frame stands in for it.
    @ViewBuilder private var preview: some View {
        if showsVideo, let still = musicVideo.still {
            Image(uiImage: still)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: MusicVideoPlayer.videoSize(side: width).width, height: MusicVideoPlayer.videoSize(side: width).height)
                .clipped()
        } else {
            ArtworkImage(source: song?.artworkSource, cornerRadius: 0, points: width)
                .frame(width: width, height: width)
        }
    }
}

/// The upright lyrics' header: the small cover in the corner beside the
/// title, or the music video up top at the cover's width with the title
/// under it. One cover morphs between the two with the video's spring.
private struct LyricsNowPlayingHeader: View {
    let song: Song?
    let videoWidth: CGFloat
    let artwork: AnyView
    let compactText: AnyView
    let compactMenu: AnyView
    let infoRow: AnyView
    let onTap: () -> Void
    @ObservedObject private var musicVideo = MusicVideoPlayer.shared

    private static let side: CGFloat = 56
    private static let inset: CGFloat = 24

    var body: some View {
        let shows = song != nil && musicVideo.shownSongID == song?.id
        // An upright clip stays shorter here: the lyrics need the room.
        let size = shows
            ? MusicVideoPlayer.videoSize(side: musicVideo.aspect < 1 ? videoWidth * 0.6 : videoWidth)
            : CGSize(width: Self.side, height: Self.side)
        // Under the video, or level with the small cover.
        let rowTop = shows ? size.height + 16 : 0
        ZStack(alignment: .topLeading) {
            HStack(spacing: 12) {
                compactText.frame(maxWidth: .infinity, alignment: .leading)
                compactMenu
            }
            .frame(height: 60)
            .padding(.leading, Self.inset + Self.side + 12)
            .padding(.trailing, Self.inset)
            .padding(.top, rowTop)
            .opacity(shows ? 0 : 1)
            .allowsHitTesting(!shows)

            infoRow
                .padding(.horizontal, 28)
                .padding(.top, rowTop)
                .opacity(shows ? 1 : 0)
                .allowsHitTesting(shows)

            artwork
                .frame(width: size.width, height: size.height)
                .contentShape(RoundedRectangle(cornerRadius: shows ? 12 : 6, style: .continuous))
                .onTapGesture(perform: onTap)
                .allowsHitTesting(MusicVideoFeature.isAvailable)
                .modifier(MusicVideoMenu(song: song, width: videoWidth))
                .shadow(color: .black.opacity(shows ? 0.32 : 0.26), radius: shows ? 28 : 12, y: shows ? 18 : 7)
                .padding(.top, shows ? 0 : 2)
                .padding(.leading, shows ? 0 : Self.inset)
                .frame(maxWidth: .infinity, alignment: shows ? .top : .topLeading)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .animation(.spring(duration: 0.6, bounce: 0.12), value: shows)
    }
}
