import Foundation

enum PlaylistSortOrder: String, Codable, CaseIterable {
    case manual
    case title
    case artist
    case dateAdded

    var title: String {
        switch self {
        case .manual: String(localized: "Manual")
        case .title: String(localized: "Title")
        case .artist: String(localized: "Artist")
        case .dateAdded: String(localized: "Date Added")
        }
    }

    var systemImage: String {
        switch self {
        case .manual: "arrow.up.arrow.down"
        case .title: "textformat"
        case .artist: "person"
        case .dateAdded: "calendar"
        }
    }
}

struct ImportedPlaylistMatch: Codable, Equatable {
    var remoteID: String
    var localSongID: UUID?
    var isRemoved: Bool
}

struct ImportSource: Codable, Equatable {
    var service: String
    var playlistID: String
    var url: String
    var matches: [ImportedPlaylistMatch]
}

enum PlaylistCover: Codable, Hashable, Sendable {
    /// 2x2 mix of the first four albums, even when there's imported artwork.
    case mosaic
    /// A cover drawn by the app with the playlist's name.
    case generated(CoverPalette)
    /// A generated cover in one of the newer styles.
    case styled(CoverPalette, CoverStyle)
}

struct Playlist: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var description: String
    var songs: [UUID]
    var createdAt: Date
    var modifiedAt: Date
    var artworkData: Data?
    var isSmartPlaylist: Bool
    var sortOrder: PlaylistSortOrder
    var manualSongOrder: [UUID]?
    var importSource: ImportSource?
    /// Set on Autolists: the app picks the songs from these rules.
    var autolist: AutolistRules?
    /// When the Autolist's songs were last picked; it waits for its
    /// `refresh` interval from there.
    var autolistUpdatedAt: Date?
    /// The cover the user picked; `nil`: the imported artwork if there is one,
    /// else the mosaic.
    var cover: PlaylistCover?

    init(
        id: UUID = UUID(),
        name: String,
        description: String = "",
        songs: [UUID] = [],
        createdAt: Date = Date(),
        modifiedAt: Date = Date(),
        artworkData: Data? = nil,
        isSmartPlaylist: Bool = false,
        sortOrder: PlaylistSortOrder = .manual,
        manualSongOrder: [UUID]? = nil,
        importSource: ImportSource? = nil,
        autolist: AutolistRules? = nil,
        cover: PlaylistCover? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.songs = songs
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.artworkData = artworkData
        self.isSmartPlaylist = isSmartPlaylist
        self.sortOrder = sortOrder
        self.manualSongOrder = manualSongOrder
        self.importSource = importSource
        self.autolist = autolist
        self.cover = cover
    }

    var isAutolist: Bool { autolist != nil }

    /// The generated cover in a given palette (playlists use their name).
    func generatedCover(_ palette: CoverPalette, style: CoverStyle = .classic) -> GeneratedCover {
        GeneratedCover(number: nil, title: name, caption: "", symbol: "music.note.list", palette: palette, style: style)
    }

    /// The palette of the cover on screen, when the app draws it.
    var coverPalette: CoverPalette? {
        if let autolist { return autolist.resolvedPalette }
        if case let .generated(palette) = cover { return palette }
        if case let .styled(palette, _) = cover { return palette }
        return nil
    }

    var songCount: Int { songs.count }

    var formattedDuration: String {
        String(localized: "\(songCount) songs")
    }

    static func == (lhs: Playlist, rhs: Playlist) -> Bool {
        lhs.id == rhs.id && lhs.songs == rhs.songs && lhs.name == rhs.name && lhs.artworkData == rhs.artworkData && lhs.sortOrder == rhs.sortOrder && lhs.importSource == rhs.importSource && lhs.autolist == rhs.autolist && lhs.cover == rhs.cover
    }
}
