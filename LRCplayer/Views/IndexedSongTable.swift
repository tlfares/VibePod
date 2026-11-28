import SwiftUI
import UIKit
import Combine

/// "Play" / "Shuffle" glass capsules above a song list.
final class SongListHeaderView: UIView {
    private let onPlay: () -> Void
    private let onShuffle: () -> Void
    private var buttons: [UIButton] = []

    init(onPlay: @escaping () -> Void, onShuffle: @escaping () -> Void) {
        self.onPlay = onPlay
        self.onShuffle = onShuffle
        super.init(frame: CGRect(x: 0, y: 0, width: 390, height: 72))

        let play = Self.makeButton(title: String(localized: "Play"), systemImage: "play.fill") { [weak self] in self?.onPlay() }
        let shuffle = Self.makeButton(title: String(localized: "Shuffle"), systemImage: "shuffle") { [weak self] in self?.onShuffle() }
        buttons = [play, shuffle]
        let stack = UIStackView(arrangedSubviews: [play, shuffle])
        stack.axis = .horizontal
        stack.spacing = 12
        stack.distribution = .fillEqually
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
            stack.heightAnchor.constraint(equalToConstant: 48)
        ])
        directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:)") }

    /// The accent color changed in Settings.
    func applyTint() {
        for button in buttons {
            guard var configuration = button.configuration else { continue }
            Self.setColor(AppTint.current.uiColor, of: &configuration)
            button.configuration = configuration
        }
    }

    /// Glass buttons draw their symbol with the label color whatever the
    /// foreground color: bake the color into the symbol so icon and title match.
    static func setColor(_ color: UIColor, of configuration: inout UIButton.Configuration) {
        configuration.baseForegroundColor = color
        configuration.image = configuration.image?.withTintColor(color, renderingMode: .alwaysOriginal)
    }

    /// `color`: the app's accent unless given (white on colored pages).
    static func makeButton(title: String, systemImage: String, color: UIColor? = nil, action: @escaping () -> Void) -> UIButton {
        var configuration = UIButton.Configuration.glass()
        configuration.title = title
        configuration.image = UIImage(systemName: systemImage)
        configuration.imagePadding = 6
        configuration.cornerStyle = .capsule
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(textStyle: .headline)
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = .preferredFont(forTextStyle: .headline)
            return attributes
        }
        // Apple Music: accent-colored label on a neutral glass capsule.
        setColor(color ?? AppTint.current.uiColor, of: &configuration)
        return UIButton(configuration: configuration, primaryAction: UIAction { _ in action() })
    }
}

/// Song row: artwork, title, artist, lyrics badge and the now-playing glyph.
final class SongTableCell: UITableViewCell {
    static let reuseID = "SongTableCell"

    private let artworkView = UIImageView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let accessoryStack = UIStackView()
    private let lyricsBadgeView = UIImageView()
    private let downloadBadge = DownloadBadgeView(tint: .tertiaryLabel)
    private let nowPlayingView = UIImageView()
    private let artworkLoader = ArtworkImageLoader()
    private static let placeholder = UIImage(systemName: "music.note")

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        // A light veil instead of the opaque gray, so colored pages (playlists)
        // keep their color under the finger, like album pages.
        let selected = UIView()
        selected.backgroundColor = UIColor { $0.userInterfaceStyle == .dark ? UIColor.white.withAlphaComponent(0.1) : UIColor.black.withAlphaComponent(0.06) }
        selectedBackgroundView = selected

        artworkView.contentMode = .scaleAspectFill
        artworkView.clipsToBounds = true
        artworkView.layer.cornerRadius = 5
        artworkView.layer.cornerCurve = .continuous
        artworkView.backgroundColor = .tertiarySystemFill
        artworkView.tintColor = .tertiaryLabel
        artworkView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 17, weight: .medium)
        artworkView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .preferredFont(forTextStyle: .body)
        subtitleLabel.font = .preferredFont(forTextStyle: .subheadline)
        subtitleLabel.textColor = .secondaryLabel

        let textStack = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        textStack.axis = .vertical
        textStack.spacing = 1
        textStack.translatesAutoresizingMaskIntoConstraints = false

        lyricsBadgeView.tintColor = .tertiaryLabel
        lyricsBadgeView.contentMode = .scaleAspectFit
        nowPlayingView.contentMode = .scaleAspectFit
        nowPlayingView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .footnote, scale: .default)
        [lyricsBadgeView, nowPlayingView].forEach {
            $0.setContentHuggingPriority(.required, for: .horizontal)
            $0.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        accessoryStack.axis = .horizontal
        accessoryStack.spacing = 6
        accessoryStack.alignment = .center
        accessoryStack.addArrangedSubview(downloadBadge)
        accessoryStack.addArrangedSubview(lyricsBadgeView)
        accessoryStack.addArrangedSubview(nowPlayingView)
        accessoryStack.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(artworkView)
        contentView.addSubview(textStack)
        contentView.addSubview(accessoryStack)
        NSLayoutConstraint.activate([
            artworkView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            artworkView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            artworkView.widthAnchor.constraint(equalToConstant: 44),
            artworkView.heightAnchor.constraint(equalToConstant: 44),
            textStack.leadingAnchor.constraint(equalTo: artworkView.trailingAnchor, constant: 12),
            textStack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            accessoryStack.leadingAnchor.constraint(greaterThanOrEqualTo: textStack.trailingAnchor, constant: 8),
            accessoryStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            accessoryStack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:)") }

    override func prepareForReuse() {
        super.prepareForReuse()
        artworkLoader.cancel()
        artworkView.image = nil
    }

    func configure(song: Song, isCurrent: Bool, isPlaying: Bool, lyricsBadge: UIImage?, subtitle: String? = nil, tint: UIColor? = nil) {
        // Only the playing row shows the cover tint: other rows skip the
        // palette (a cover decode on a cache miss, mid-scroll).
        let tint = isCurrent ? (tint ?? song.coverSheetTint) : (tint ?? AppTint.current.uiColor)
        artworkLoader.load(song.artworkSource, into: artworkView, points: 44, placeholder: Self.placeholder)
        titleLabel.text = song.title
        titleLabel.textColor = isCurrent ? tint : .label
        subtitleLabel.text = subtitle ?? song.artist
        lyricsBadgeView.image = lyricsBadge
        lyricsBadgeView.isHidden = lyricsBadge == nil || isCurrent
        downloadBadge.configure(song: song)
        NowPlayingIndicator.apply(to: nowPlayingView, isCurrent: isCurrent, isPlaying: isPlaying, tint: tint)
    }
}

/// Animated "now playing" glyph shared by every UIKit song list.
@MainActor
enum NowPlayingIndicator {
    static func apply(to imageView: UIImageView, isCurrent: Bool, isPlaying: Bool, tint: UIColor = AppTint.current.uiColor) {
        imageView.isHidden = !isCurrent
        imageView.tintColor = tint
        guard isCurrent else {
            imageView.removeAllSymbolEffects()
            return
        }
        imageView.image = UIImage(systemName: isPlaying ? "waveform" : "speaker.fill")
        if isPlaying {
            imageView.addSymbolEffect(.variableColor.iterative.dimInactiveLayers, options: .repeating)
        } else {
            imageView.removeAllSymbolEffects()
        }
    }
}

extension UIViewController {
    /// A UIKit scroll view hosted inside SwiftUI isn't seen by the navigation
    /// bar (scroll edge effect, large title collapse) nor by the tab bar
    /// (minimize on scroll). Register it on every ancestor up to the
    /// navigation controller's child.
    func adoptAsContentScrollView(_ scrollView: UIScrollView) {
        var candidate: UIViewController? = self
        while let current = candidate {
            current.setContentScrollView(scrollView, for: .top)
            current.setContentScrollView(scrollView, for: .bottom)
            if current.parent is UINavigationController || current.parent is UITabBarController { break }
            candidate = current.parent
        }
    }
}
