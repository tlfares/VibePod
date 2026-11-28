import SwiftUI
import UniformTypeIdentifiers

/// Another cover for a whole album: an image of yours, or one of the
/// artist's covers on Spotify. Opened from a song's Info.
struct AlbumCoverPicker: View {
    let album: Album
    @EnvironmentObject private var libraryVM: LibraryViewModel
    @Environment(\.dismiss) private var dismiss

    private enum Choice: Equatable {
        case image(Data)
        case release(SpotifyRelease)
    }

    private enum Phase: Equatable {
        case loading
        case loaded
        case noArtist
        case failed
    }

    @State private var artist: SpotifyArtist?
    @State private var releases: [SpotifyRelease] = []
    @State private var phase = Phase.loading
    @State private var choice: Choice?
    @State private var chosenImage: UIImage?
    @State private var showsPhotos = false
    @State private var showsFiles = false
    @State private var showsArtistSearch = false
    @State private var isSaving = false
    @State private var failedToSave = false

    private var albumTitle: String { album.title }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    preview
                    sourceButtons
                    spotifySection
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
            }
            .navigationTitle(album.isSingle ? "Cover" : "Album Cover")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Use", systemImage: "checkmark", action: save)
                            .disabled(choice == nil)
                    }
                }
            }
            .navigationDestination(isPresented: $showsArtistSearch) {
                SpotifyArtistSearch(initialTerm: artist?.name ?? album.artist) { picked in
                    showsArtistSearch = false
                    guard picked != artist else { return }
                    artist = picked
                    Task { await loadReleases() }
                }
            }
            .fullScreenCover(isPresented: $showsPhotos) {
                CroppingPhotoPicker { image in choose(image) }
                    .ignoresSafeArea()
            }
            .fileImporter(isPresented: $showsFiles, allowedContentTypes: [.image]) { result in
                guard case let .success(url) = result else { return }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                if let data = try? Data(contentsOf: url), let image = UIImage(data: data) {
                    choose(image)
                }
            }
            .alert("The cover couldn't be downloaded.", isPresented: $failedToSave) {
                Button("OK", role: .cancel) {}
            }
            .sensoryFeedback(.selection, trigger: choice)
            .task { await findArtist() }
        }
    }

    // MARK: Preview

    private var preview: some View {
        VStack(spacing: 14) {
            Group {
                switch choice {
                case .image:
                    if let chosenImage {
                        Image(uiImage: chosenImage).resizable().scaledToFill()
                    }
                case let .release(release):
                    RemoteCover(url: release.coverURL, pixels: 900)
                case nil:
                    ArtworkImage(source: album.artworkSource, cornerRadius: 0, points: 220)
                }
            }
            .frame(width: 220, height: 220)
            .clipShape(.rect(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.35), radius: 18, y: 10)
            .id(previewKey)
            .transition(.opacity.combined(with: .scale(scale: 0.96)))

            VStack(spacing: 3) {
                Text(albumTitle)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Text(album.isSingle ? album.artist : String(localized: "\(album.songs.count) songs · \(album.artist)"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.top, 12)
        .animation(.smooth(duration: 0.35), value: previewKey)
    }

    private var previewKey: String {
        switch choice {
        case .image(let data): "image-\(data.count)"
        case .release(let release): release.uri
        case nil: "current"
        }
    }

    // MARK: Your images

    private var sourceButtons: some View {
        HStack(spacing: 12) {
            Button {
                showsPhotos = true
            } label: {
                Label("Photos", systemImage: "photo.on.rectangle")
                    .frame(maxWidth: .infinity)
            }
            Button {
                showsFiles = true
            } label: {
                Label("Files", systemImage: "folder")
                    .frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.glass)
        .controlSize(.large)
    }

    private func choose(_ image: UIImage) {
        guard let data = SongEditorView.squareJPEG(image, maxSide: 1400), let square = UIImage(data: data) else { return }
        chosenImage = square
        withAnimation(.smooth(duration: 0.35)) { choice = .image(data) }
    }

    // MARK: Spotify

    private var spotifySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("On Spotify")
                    .font(.title3.bold())
                Spacer()
                Button {
                    showsArtistSearch = true
                } label: {
                    HStack(spacing: 4) {
                        Text(artist?.name ?? String(localized: "Choose Artist"))
                            .lineLimit(1)
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                    }
                    .font(.subheadline.weight(.medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
            }

            switch phase {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 160)
            case .noArtist:
                note("No artist with this name on Spotify.", action: "Search an Artist") { showsArtistSearch = true }
            case .failed:
                note("Spotify can't be reached.", action: "Try Again") { Task { await loadReleases() } }
            case .loaded where releases.isEmpty:
                note("No releases for this artist.", action: "Search an Artist") { showsArtistSearch = true }
            case .loaded:
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100, maximum: 180), spacing: 14, alignment: .top)], spacing: 18) {
                    ForEach(releases) { release in
                        releaseCell(release)
                    }
                }
            }
        }
        .animation(.smooth(duration: 0.3), value: phase)
    }

    private func releaseCell(_ release: SpotifyRelease) -> some View {
        let isChosen = choice == .release(release)
        return Button {
            withAnimation(.smooth(duration: 0.35)) { choice = isChosen ? nil : .release(release) }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                RemoteCover(url: release.thumbnailURL, pixels: 360)
                    .aspectRatio(1, contentMode: .fit)
                    .clipShape(.rect(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(.tint, lineWidth: isChosen ? 3 : 0)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if isChosen {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.title2)
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, .tint)
                                .padding(6)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                VStack(alignment: .leading, spacing: 1) {
                    Text(release.name)
                        .font(.footnote.weight(.medium))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if let year = release.year {
                        Text(String(year))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private func note(_ text: LocalizedStringKey, action: LocalizedStringKey, perform: @escaping () -> Void) -> some View {
        VStack(spacing: 12) {
            Text(text)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(action, action: perform)
                .buttonStyle(.glass)
        }
        .frame(maxWidth: .infinity, minHeight: 160)
    }

    /// The album's artist on Spotify: the one so named, else the first found.
    private func findArtist() async {
        guard artist == nil else { return }
        let name = album.artist
        do {
            let found = try await SpotifyCatalog.searchArtists(name)
            let key = SpotifyArtistSearch.key(name)
            artist = found.first { SpotifyArtistSearch.key($0.name) == key } ?? found.first
            guard artist != nil else {
                phase = .noArtist
                return
            }
            await loadReleases()
        } catch {
            phase = .failed
        }
    }

    /// Releases with the album's own title first: likely the one wanted.
    private func loadReleases() async {
        guard let artist else { return }
        phase = .loading
        do {
            let all = try await SpotifyCatalog.releases(of: artist)
            guard artist == self.artist else { return }
            let title = SpotifyArtistSearch.key(albumTitle)
            let matching = all.filter { release in
                let name = SpotifyArtistSearch.key(release.name)
                return !title.isEmpty && (name == title || name.hasPrefix(title) || title.hasPrefix(name))
            }
            releases = matching + all.filter { !matching.contains($0) }
            if case .release = choice { choice = nil }
            phase = .loaded
        } catch {
            phase = .failed
        }
    }

    // MARK: Save

    private func save() {
        guard let choice else { return }
        isSaving = true
        Task {
            let data: Data?
            switch choice {
            case let .image(bytes):
                data = bytes
            case let .release(release):
                data = (try? await SpotifyCatalog.coverData(for: release))
                    .flatMap(UIImage.init(data:))
                    .flatMap { SongEditorView.squareJPEG($0, maxSide: 1400) }
            }
            guard let data else {
                isSaving = false
                failedToSave = true
                return
            }
            ArtworkStore.replace(data, for: album.songs.map(\.id))
            libraryVM.objectWillChange.send()
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            dismiss()
        }
    }
}

/// Finds an artist on Spotify by name, for when the album's isn't the
/// right one.
struct SpotifyArtistSearch: View {
    let initialTerm: String
    let onPick: (SpotifyArtist) -> Void
    @State private var term: String
    @State private var artists: [SpotifyArtist] = []
    @State private var isSearching = false
    @State private var failed = false

    init(initialTerm: String, onPick: @escaping (SpotifyArtist) -> Void) {
        self.initialTerm = initialTerm
        self.onPick = onPick
        _term = State(initialValue: initialTerm)
    }

    /// Names compared without case, accents or punctuation.
    static func key(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .filter { $0.isLetter || $0.isNumber }
    }

    var body: some View {
        List {
            ForEach(artists) { artist in
                Button {
                    onPick(artist)
                } label: {
                    HStack(spacing: 12) {
                        RemoteCover(url: artist.imageURL, pixels: 150, symbol: "music.microphone")
                            .frame(width: 48, height: 48)
                            .clipShape(.circle)
                        Text(artist.name)
                            .foregroundStyle(Color.primary)
                        if artist.isVerified {
                            Image(systemName: "checkmark.seal.fill")
                                .foregroundStyle(.tint)
                                .imageScale(.small)
                        }
                    }
                }
            }
        }
        .overlay {
            if isSearching && artists.isEmpty {
                ProgressView()
            } else if failed {
                ContentUnavailableView("Spotify can't be reached.", systemImage: "wifi.exclamationmark")
            } else if !isSearching && artists.isEmpty && !term.trimmingCharacters(in: .whitespaces).isEmpty {
                ContentUnavailableView.search(text: term)
            }
        }
        .navigationTitle("Artist")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $term, placement: .navigationBarDrawer(displayMode: .always), prompt: "Artist on Spotify")
        .task(id: term) {
            // A pause while typing, then one search.
            if term != initialTerm || !artists.isEmpty {
                try? await Task.sleep(for: .milliseconds(350))
            }
            guard !Task.isCancelled else { return }
            guard !term.trimmingCharacters(in: .whitespaces).isEmpty else {
                failed = false
                withAnimation(.smooth(duration: 0.25)) { artists = [] }
                return
            }
            isSearching = true
            defer { isSearching = false }
            do {
                let found = try await SpotifyCatalog.searchArtists(term)
                guard !Task.isCancelled else { return }
                failed = false
                withAnimation(.smooth(duration: 0.25)) { artists = found }
            } catch {
                guard !Task.isCancelled else { return }
                failed = true
            }
        }
    }
}

/// A cover or photo from the web, decoded at the size it's drawn.
struct RemoteCover: View {
    let url: URL?
    var pixels: CGFloat = 300
    var symbol = "music.note"
    @State private var image: UIImage?

    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 400
        return cache
    }()

    var body: some View {
        ZStack {
            Rectangle().fill(Color(uiColor: .tertiarySystemFill))
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            } else {
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(.tertiary)
            }
        }
        .task(id: url) {
            guard let url else {
                image = nil
                return
            }
            let key = "\(url.absoluteString)@\(Int(pixels))" as NSString
            if let cached = Self.cache.object(forKey: key) {
                image = cached
                return
            }
            image = nil
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let decoded = await UIImage(data: data)?.byPreparingThumbnail(ofSize: CGSize(width: pixels, height: pixels)) else { return }
            Self.cache.setObject(decoded, forKey: key)
            withAnimation(.easeOut(duration: 0.2)) { image = decoded }
        }
    }
}
