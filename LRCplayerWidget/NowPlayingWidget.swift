import SwiftUI
import WidgetKit

struct NowPlayingEntry: TimelineEntry {
    let date: Date
    let state: WidgetNowPlayingState
}

struct NowPlayingProvider: TimelineProvider {
    func placeholder(in context: Context) -> NowPlayingEntry {
        NowPlayingEntry(date: .now, state: .read())
    }

    func getSnapshot(in context: Context, completion: @escaping (NowPlayingEntry) -> Void) {
        completion(NowPlayingEntry(date: .now, state: .read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NowPlayingEntry>) -> Void) {
        let entry = NowPlayingEntry(date: .now, state: .read())
        completion(Timeline(
            entries: [entry],
            policy: .after(Date().addingTimeInterval(30))
        ))
    }
}

struct NowPlayingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetKind.nowPlaying, provider: NowPlayingProvider()) { entry in
            NowPlayingWidgetView(entry: entry)
        }
        .configurationDisplayName("Now Playing")
        .description("Choose what the artwork, the song details and the rest of the widget open in VibePod's settings.")
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled()
    }
}

struct NowPlayingWidgetView: View {
    let entry: NowPlayingEntry

    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            switch family {
            case .systemSmall:
                SmallNowPlayingView(state: entry.state)
            default:
                MediumNowPlayingView(state: entry.state)
            }
        }
        .containerBackground(for: .widget) {
            CoverInspiredBackground(state: entry.state)
        }
        .widgetURL(WidgetTapZone.background.url)
    }
}

struct CoverInspiredBackground: View {
    let state: WidgetNowPlayingState

    var body: some View {
        ZStack {
            LinearGradient(
                colors: state.palette,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .saturation(1.35)

            Rectangle()
                .fill(.ultraThinMaterial)

            LinearGradient(
                colors: [Color.black.opacity(0.10), Color.black.opacity(0.45)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }
}

struct ArtworkView: View {
    let state: WidgetNowPlayingState
    var size: CGFloat
    var corner: CGFloat

    var body: some View {
        Group {
            if let artwork = state.artwork {
                Image(uiImage: artwork)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: corner, style: .continuous)
                        .fill(Color.white.opacity(0.14))
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.3, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.7))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }
}

struct ControlRow: View {
    let state: WidgetNowPlayingState
    var spacing: CGFloat
    var buttonSize: CGFloat = 38

    var body: some View {
        HStack(spacing: spacing) {
            Button(intent: PreviousTrackIntent()) {
                controlIcon("backward.fill")
            }
            .buttonStyle(.plain)

            Button(intent: TogglePlaybackIntent()) {
                controlIcon(state.isPlaying ? "pause.fill" : "play.fill", prominent: true)
            }
            .buttonStyle(.plain)

            Button(intent: NextTrackIntent()) {
                controlIcon("forward.fill")
            }
            .buttonStyle(.plain)
        }
    }

    private func controlIcon(_ systemName: String, prominent: Bool = false) -> some View {
        Image(systemName: systemName)
            .font(.system(size: min(21, max(15, buttonSize * 0.42)), weight: .semibold))
            .foregroundStyle(Color.white.opacity(prominent ? 1.0 : 0.85))
            .frame(width: buttonSize, height: buttonSize)
    }
}

struct SmallNowPlayingView: View {
    let state: WidgetNowPlayingState

    var body: some View {
        VStack(spacing: 5) {
            Link(destination: WidgetTapZone.artwork.url) {
                ArtworkView(state: state, size: 62, corner: 13)
            }

            Link(destination: WidgetTapZone.title.url) {
                VStack(spacing: 1) {
                    Text(state.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(state.artist)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }

            ControlRow(state: state, spacing: 8, buttonSize: 38)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(6)
    }
}

struct MediumNowPlayingView: View {
    let state: WidgetNowPlayingState

    var body: some View {
        HStack(spacing: 14) {
            Link(destination: WidgetTapZone.artwork.url) {
                ArtworkView(state: state, size: 88, corner: 16)
            }

            VStack(alignment: .leading, spacing: 4) {
                Spacer(minLength: 2)

                Link(destination: WidgetTapZone.title.url) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(state.title)
                            .font(.system(size: 17, weight: .bold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Text(state.artist)
                            .font(.system(size: 13))
                            .foregroundStyle(Color.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                }

                Spacer(minLength: 0)

                ControlRow(state: state, spacing: 18, buttonSize: 46)
                    .frame(maxWidth: .infinity, alignment: .center)

                Spacer(minLength: 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
