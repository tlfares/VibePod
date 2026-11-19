import SwiftUI
import PhotosUI

/// Creates or edits a playlist: name and cover, with a live preview. Shown in
/// its own sheet, or pushed inside the player's "Add to Playlist" sheet.
struct PlaylistEditorView: View {
    let request: PlaylistEditorRequest
    /// Pushed in another sheet: the back button replaces Cancel.
    var isPushed = false
    /// Called after Create/Done/Delete, before the editor goes away.
    var onFinish: (() -> Void)?
    @EnvironmentObject private var libraryVM: LibraryViewModel
    @EnvironmentObject private var router: AppRouter
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var choice: CoverChoice
    @State private var showDeleteConfirmation = false
    /// A photo picked from the library, saved as the playlist's own artwork.
    @State private var photoData: Data?
    @State private var photoItem: PhotosPickerItem?
    @FocusState private var isNameFocused: Bool

    /// What the cover picker offers. `original` only exists for playlists
    /// imported with their own artwork.
    enum CoverChoice: Hashable {
        case original
        case mosaic
        case generated(CoverPalette, CoverStyle)

        var palette: CoverPalette? {
            if case let .generated(palette, _) = self { return palette }
            return nil
        }
    }

    init(request: PlaylistEditorRequest, isPushed: Bool = false, onFinish: (() -> Void)? = nil) {
        self.request = request
        self.isPushed = isPushed
        self.onFinish = onFinish
        _name = State(initialValue: "")
        _choice = State(initialValue: .mosaic)
    }

    private var isNew: Bool { request.playlistID == nil }
    private var existing: Playlist? { request.playlistID.flatMap(libraryVM.playlist(withID:)) }
    private var hasOriginal: Bool { photoData != nil || existing?.artworkData?.isEmpty == false }
    /// The artwork is a photo picked here, not one that came with an import.
    private var isUserPhoto: Bool { photoData != nil || existing?.importSource == nil }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The playlist as it would be saved, for the previews.
    private var draft: Playlist {
        var playlist = existing ?? Playlist(name: "", songs: request.songs.map(\.id))
        playlist.name = trimmedName.isEmpty ? String(localized: "New Playlist") : trimmedName
        if let photoData { playlist.artworkData = photoData }
        playlist.cover = cover(for: choice)
        return playlist
    }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 18) {
                    CoverPreview(source: libraryVM.playlistArtwork(draft), side: 200, placeholderSymbol: "music.note.list")
                        .shadow(color: .black.opacity(0.3), radius: 18, y: 10)
                    TextField("Playlist Name", text: $name)
                        .font(.title3.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .submitLabel(.done)
                        .focused($isNameFocused)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 14))
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
                .padding(.bottom, 4)
            } footer: {
                if !request.songs.isEmpty {
                    Text(request.songs.count == 1 ? "“\(request.songs[0].title)” will be added to it." : "\(request.songs.count) songs will be added to it.")
                        .frame(maxWidth: .infinity)
                        .padding(.top, 4)
                }
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())

            Section {
                CoverChoiceRow(options: coverOptions, selection: $choice.animation(.smooth))
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Label(hasOriginal ? "Choose Another Photo…" : "Choose Photo…", systemImage: "photo.on.rectangle")
                }
            } header: {
                Text("Cover")
            } footer: {
                Text(coverFooter)
            }
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task {
                    guard let data = try? await item.loadTransferable(type: Data.self),
                          let image = UIImage(data: data) else { return }
                    withAnimation(.smooth) {
                        photoData = Self.squareJPEG(image)
                        choice = .original
                    }
                }
            }

            if let palette = choice.palette, case let .generated(_, style) = choice {
                Section("Colors") {
                    CoverChoiceRow(options: paletteOptions(style: style), selection: Binding(
                        get: { palette },
                        set: { new in withAnimation(.smooth) { choice = .generated(new, style) } }
                    ))
                }
            }

            if !isNew {
                Section {
                    Button("Delete Playlist", role: .destructive) {
                        showDeleteConfirmation = true
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(isNew ? "New Playlist" : "Edit Playlist")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !isPushed {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark", role: .cancel) { dismiss() }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(isNew ? "Create" : "Done", systemImage: "checkmark", role: .confirm) { save() }
                    .disabled(trimmedName.isEmpty)
            }
        }
        .confirmationDialog("Delete “\(existing?.name ?? "")”?", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
            Button("Delete Playlist", role: .destructive) { delete() }
        } message: {
            Text("The songs stay in your library.")
        }
        .onAppear(perform: load)
    }

    // MARK: Cover

    private var coverOptions: [CoverChoiceRow<CoverChoice>.Option] {
        var options: [CoverChoiceRow<CoverChoice>.Option] = []
        var playlist = draft
        if hasOriginal {
            playlist.cover = nil
            options.append(.init(id: .original, title: isUserPhoto ? String(localized: "Photo") : String(localized: "Original"), source: libraryVM.playlistArtwork(playlist)))
        }
        playlist.cover = .mosaic
        options.append(.init(id: .mosaic, title: String(localized: "Mix"), source: libraryVM.playlistArtwork(playlist)))
        // Each style in the colors picked so far.
        let palette = choice.palette ?? .ember
        for style in CoverStyle.allCases {
            options.append(.init(id: .generated(palette, style), title: style.title, source: .generated(draft.generatedCover(palette, style: style))))
        }
        return options
    }

    private func paletteOptions(style: CoverStyle) -> [CoverChoiceRow<CoverPalette>.Option] {
        CoverPalette.allCases.map { palette in
            .init(id: palette, title: palette.title, source: .generated(draft.generatedCover(palette, style: style)))
        }
    }

    /// Center-cropped and downsized: a cover needs no more than this.
    private static func squareJPEG(_ image: UIImage) -> Data? {
        let side = min(image.size.width, image.size.height)
        let target = min(side, 1200)
        let scale = target / side
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let square = UIGraphicsImageRenderer(size: CGSize(width: target, height: target), format: format).image { _ in
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            image.draw(in: CGRect(x: (target - size.width) / 2, y: (target - size.height) / 2, width: size.width, height: size.height))
        }
        return square.jpegData(compressionQuality: 0.88)
    }

    private var coverFooter: String {
        switch choice {
        case .original: isUserPhoto ? String(localized: "Your photo.") : String(localized: "The artwork the playlist was imported with.")
        case .mosaic: String(localized: "The covers of the first four albums in the playlist.")
        case .generated: String(localized: "Drawn by the app with the playlist’s name. It follows the name when you rename the playlist.")
        }
    }

    private func cover(for choice: CoverChoice) -> PlaylistCover? {
        switch choice {
        case .original: nil
        // Without imported artwork the mosaic is the default: keep `nil`.
        case .mosaic: hasOriginal ? .mosaic : nil
        case let .generated(palette, style): style == .classic ? .generated(palette) : .styled(palette, style)
        }
    }

    private func load() {
        guard let playlist = existing, name.isEmpty else {
            if isNew { isNameFocused = true }
            return
        }
        name = playlist.name
        switch playlist.cover {
        case let .generated(palette): choice = .generated(palette, .classic)
        case let .styled(palette, style): choice = .generated(palette, style)
        case .mosaic: choice = .mosaic
        case nil: choice = hasOriginal ? .original : .mosaic
        }
    }

    // MARK: Actions

    private func save() {
        let cover = cover(for: choice)
        if let id = request.playlistID {
            if let photoData { libraryVM.setPlaylistArtwork(id: id, data: photoData) }
            libraryVM.updatePlaylist(id: id, name: trimmedName, cover: cover)
            finish()
        } else {
            let playlist = libraryVM.createPlaylist(name: trimmedName, cover: cover, adding: request.songs)
            if let playlist, let photoData { libraryVM.setPlaylistArtwork(id: playlist.id, data: photoData) }
            finish()
            // Like Apple Music, a playlist made from scratch opens; one made to
            // hold a song stays out of the way.
            if let playlist, request.songs.isEmpty {
                router.open(.playlist(playlist.id))
            }
        }
    }

    private func delete() {
        guard let playlist = existing else { return }
        finish()
        if case let .playlist(shown, _)? = router.paths[router.selectedTab]?.last, shown == playlist.id {
            router.pop()
        }
        libraryVM.deletePlaylist(playlist)
    }

    private func finish() {
        if let onFinish { onFinish() } else { dismiss() }
    }
}

// MARK: - Shared editor pieces

/// A large cover that crossfades when it changes. Decoded synchronously: the
/// editors change it one tap at a time and must never flash a placeholder.
struct CoverPreview: View {
    let source: ArtworkSource?
    let side: CGFloat
    var cornerRadius: CGFloat = 12
    var placeholderSymbol = "music.note"

    var body: some View {
        let image = source.flatMap { ArtworkImageCache.shared.imageSync(for: $0, points: side) }
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color(uiColor: .tertiarySystemFill))
            Image(systemName: placeholderSymbol)
                .font(.system(size: side * 0.3, weight: .medium))
                .foregroundStyle(.tertiary)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .id(source?.cacheKey)
                    .transition(.opacity)
            }
        }
        .frame(width: side, height: side)
        .clipShape(.rect(cornerRadius: cornerRadius, style: .continuous))
        .animation(.smooth(duration: 0.3), value: source?.cacheKey)
    }
}

/// A horizontal strip of real cover thumbnails to choose from.
struct CoverChoiceRow<ID: Hashable>: View {
    struct Option: Identifiable {
        let id: ID
        let title: String
        let source: ArtworkSource?
    }

    let options: [Option]
    @Binding var selection: ID

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(options) { option in
                        thumbnail(option).id(option.id)
                    }
                }
                .padding(.vertical, 14)
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, 16, for: .scrollContent)
            .scrollIndicators(.hidden)
            .onAppear { proxy.scrollTo(selection, anchor: .center) }
        }
        .listRowInsets(EdgeInsets())
    }

    private func thumbnail(_ option: Option) -> some View {
        let isSelected = option.id == selection
        return Button {
            selection = option.id
        } label: {
            VStack(spacing: 6) {
                ArtworkImage(source: option.source, cornerRadius: 8, points: 72, placeholderSymbol: "music.note.list")
                    .frame(width: 72, height: 72)
                    .padding(3)
                    .overlay {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .strokeBorder(.tint, lineWidth: 2.5)
                            .opacity(isSelected ? 1 : 0)
                    }
                Text(option.title)
                    .font(.caption)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Pushed page to tick any number of names (artists, genres). Nothing ticked
/// means "Any".
struct MultiSelectionPage<Leading: View>: View {
    let title: LocalizedStringKey
    let options: [String]
    @Binding var selection: [String]
    /// Drawn before each name (artist photos).
    @ViewBuilder var leading: (String) -> Leading
    @State private var searchText = ""

    var body: some View {
        let shown = searchText.isEmpty ? options : options.filter { $0.localizedStandardContains(searchText) }
        List {
            if searchText.isEmpty {
                Section {
                    row(String(localized: "Any"), showsLeading: false, isOn: selection.isEmpty) {
                        selection.removeAll()
                    }
                }
            }
            Section {
                ForEach(shown, id: \.self) { name in
                    row(name, showsLeading: true, isOn: selection.contains(name)) {
                        if let index = selection.firstIndex(of: name) {
                            selection.remove(at: index)
                        } else {
                            // Kept in the list's order, so names read the same everywhere.
                            selection = options.filter { selection.contains($0) || $0 == name }
                        }
                    }
                }
            }
        }
        .overlay {
            if shown.isEmpty, !searchText.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always))
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !selection.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Clear") { withAnimation(.smooth) { selection.removeAll() } }
                }
            }
        }
    }

    private func row(_ name: String, showsLeading: Bool, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.smooth(duration: 0.2)) { action() }
        } label: {
            HStack(spacing: 12) {
                if showsLeading { leading(name) }
                Text(name).foregroundStyle(.primary)
                Spacer()
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.tint)
                    .opacity(isOn ? 1 : 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

extension MultiSelectionPage where Leading == EmptyView {
    init(title: LocalizedStringKey, options: [String], selection: Binding<[String]>) {
        self.init(title: title, options: options, selection: selection) { _ in EmptyView() }
    }
}

extension CoverPalette.RGB {
    var color: Color { Color(red: red / 255, green: green / 255, blue: blue / 255) }
    var uiColor: UIColor { UIColor(red: red / 255, green: green / 255, blue: blue / 255, alpha: 1) }
}
