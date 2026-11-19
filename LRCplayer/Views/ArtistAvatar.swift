import SwiftUI
import UIKit

// MARK: - Artist Avatar

/// Circular artist image: the artist's photo (`ArtistImageService`), else the
/// most represented album cover, else a monogram.
enum ArtistAvatar {
    /// The cover chosen from the artist page's menu, else the most
    /// represented one.
    @MainActor
    static func coverSong(in songs: [Song], artist: String) -> Song? {
        if let title = ArtistImageService.shared.coverAlbum(for: artist),
           let song = songs.first(where: { $0.album == title && $0.artworkSource != nil }) {
            return song
        }
        return artworkSong(in: songs)
    }

    static func artworkSong(in songs: [Song]) -> Song? {
        let byAlbum = Dictionary(grouping: songs, by: \.album)
        return byAlbum.max { lhs, rhs in
            lhs.value.count == rhs.value.count ? lhs.key > rhs.key : lhs.value.count < rhs.value.count
        }?.value.first
    }

    /// Stable across launches (`hashValue` is randomly seeded per process).
    static func monogramHue(for name: String) -> Double {
        var hash: UInt64 = 5381
        for byte in name.utf8 { hash = (hash &* 33) &+ UInt64(byte) }
        return Double(hash % 360) / 360
    }

    static func monogram(for name: String) -> String {
        String(name.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased()
    }
}

struct ArtistAvatarView: View {
    let artistName: String
    let songs: [Song]
    var size: CGFloat = 48
    @ObservedObject private var photos = ArtistImageService.shared

    var body: some View {
        let artwork = photos.photo(for: artistName, albums: songs.map(\.album)) ?? ArtistAvatar.coverSong(in: songs, artist: artistName)?.artworkSource
        ZStack {
            Circle().fill(Color(hue: ArtistAvatar.monogramHue(for: artistName), saturation: 0.32, brightness: 0.38))
            Text(ArtistAvatar.monogram(for: artistName))
                .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
            if let artwork {
                ArtworkImage(source: artwork, cornerRadius: size / 2, points: size)
                    .id(artwork.cacheKey)
                    .transition(.opacity)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .animation(.easeInOut(duration: 0.3), value: artwork?.cacheKey)
    }
}

@MainActor
enum ArtistAvatarUIKit {
    static func configure(cell: UITableViewCell, artistName: String, songs: [Song], size: CGFloat = 40) {
        guard var config = cell.contentConfiguration as? UIListContentConfiguration else { return }
        // The artist's whole library, not just the songs listed here, so the
        // cover chosen on the artist page is found like everywhere else.
        let songs = AppModel.shared.libraryVM.artists.first { $0.name == artistName }?.songs ?? songs
        let artwork = ArtistImageService.shared.photo(for: artistName, albums: songs.map(\.album)) ?? ArtistAvatar.coverSong(in: songs, artist: artistName)?.artworkSource
        config.image = artwork.flatMap { ArtworkImageCache.shared.imageSync(for: $0, points: size) }
            ?? monogramImage(for: artistName, size: size)
        config.imageProperties.cornerRadius = size / 2
        config.imageProperties.maximumSize = CGSize(width: size, height: size)
        config.imageProperties.reservedLayoutSize = CGSize(width: size, height: size)
        cell.contentConfiguration = config
        cell.accessibilityIdentifier = artistName
        // Not decoded yet: swapped in when it is, unless the cell was reused.
        guard let artwork, ArtworkImageCache.shared.imageSync(for: artwork, points: size) == nil else { return }
        Task {
            guard let image = await ArtworkImageCache.shared.image(for: artwork, points: size),
                  cell.accessibilityIdentifier == artistName,
                  var current = cell.contentConfiguration as? UIListContentConfiguration else { return }
            current.image = image
            cell.contentConfiguration = current
        }
    }

    private static func monogramImage(for name: String, size: CGFloat) -> UIImage {
        let color = UIColor(hue: ArtistAvatar.monogramHue(for: name), saturation: 0.32, brightness: 0.38, alpha: 1)
        return UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { _ in
            let rect = CGRect(origin: .zero, size: CGSize(width: size, height: size))
            color.setFill()
            UIBezierPath(ovalIn: rect).fill()
            let text = NSAttributedString(string: ArtistAvatar.monogram(for: name), attributes: [
                .font: UIFont.systemFont(ofSize: size * 0.42, weight: .semibold),
                .foregroundColor: UIColor.white
            ])
            let textSize = text.size()
            text.draw(at: CGPoint(x: (size - textSize.width) / 2, y: (size - textSize.height) / 2))
        }
    }
}
