import Foundation
import UIKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class SpotifyImportViewController: UIViewController, UITextFieldDelegate {
    private let libraryService: LibraryService
    private let linkContainer = UIVisualEffectView()
    private let linkField = UITextField()
    /// System paste control: unlike reading `UIPasteboard` programmatically it
    /// never triggers the "Allow Paste" privacy prompt.
    private let pasteControl: UIPasteControl = {
        let configuration = UIPasteControl.Configuration()
        configuration.displayMode = .iconAndLabel
        configuration.cornerStyle = .capsule
        return UIPasteControl(configuration: configuration)
    }()
    private let importButton = UIButton(type: .system)
    private let activity = UIActivityIndicatorView(style: .medium)
    private let statusLabel = UILabel()
    private var didImport = false

    init(libraryService: LibraryService) {
        self.libraryService = libraryService
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        title = String(localized: "Spotify (Beta)")
        navigationItem.largeTitleDisplayMode = .never

        let descriptionLabel = UILabel()
        descriptionLabel.text = String(localized: "This does not download any songs. It matches the songs already in your library to a public Spotify playlist.")
        descriptionLabel.font = .preferredFont(forTextStyle: .subheadline)
        descriptionLabel.adjustsFontForContentSizeCategory = true
        descriptionLabel.textColor = .secondaryLabel
        descriptionLabel.numberOfLines = 0

        configureLinkField()
        configurePasteControl()
        configureImportButton()

        statusLabel.font = .preferredFont(forTextStyle: .subheadline)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.textColor = .secondaryLabel
        statusLabel.numberOfLines = 0

        activity.hidesWhenStopped = true

        let pasteRow = UIStackView(arrangedSubviews: [pasteControl, UIView()])
        pasteRow.axis = .horizontal

        let stack = UIStackView(arrangedSubviews: [descriptionLabel, linkContainer, pasteRow, importButton, statusLabel, activity])
        stack.axis = .vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            linkContainer.heightAnchor.constraint(equalToConstant: 50),
            importButton.heightAnchor.constraint(equalToConstant: 52)
        ])
    }

    private func configureLinkField() {
        linkContainer.effect = UIGlassEffect(style: .regular)
        linkContainer.cornerConfiguration = .capsule()
        linkContainer.clipsToBounds = true
        linkContainer.translatesAutoresizingMaskIntoConstraints = false

        linkField.translatesAutoresizingMaskIntoConstraints = false
        linkField.borderStyle = .none
        linkField.backgroundColor = .clear
        linkField.placeholder = "https://open.spotify.com/playlist/..."
        linkField.autocorrectionType = .no
        linkField.autocapitalizationType = .none
        linkField.clearButtonMode = .whileEditing
        linkField.keyboardType = .URL
        linkField.delegate = self
        linkField.accessibilityLabel = String(localized: "Spotify playlist link")
        linkContainer.contentView.addSubview(linkField)
        NSLayoutConstraint.activate([
            linkField.topAnchor.constraint(equalTo: linkContainer.contentView.topAnchor),
            linkField.bottomAnchor.constraint(equalTo: linkContainer.contentView.bottomAnchor),
            linkField.leadingAnchor.constraint(equalTo: linkContainer.contentView.leadingAnchor, constant: 14),
            linkField.trailingAnchor.constraint(equalTo: linkContainer.contentView.trailingAnchor, constant: -8)
        ])
    }

    private func configurePasteControl() {
        pasteConfiguration = UIPasteConfiguration(acceptableTypeIdentifiers: [
            UTType.url.identifier,
            UTType.plainText.identifier
        ])
        pasteControl.target = self
    }

    /// Called by `pasteControl` with the pasteboard contents the user chose to paste.
    override func paste(itemProviders: [NSItemProvider]) {
        guard let provider = itemProviders.first else { return }
        let apply: @Sendable (String?) -> Void = { [weak self] string in
            guard let string else { return }
            Task { @MainActor [weak self] in
                self?.linkField.text = string.trimmingCharacters(in: .whitespacesAndNewlines)
                self?.statusLabel.text = ""
            }
        }
        if provider.canLoadObject(ofClass: URL.self) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in apply(url?.absoluteString) }
        } else if provider.canLoadObject(ofClass: String.self) {
            _ = provider.loadObject(ofClass: String.self) { string, _ in apply(string) }
        }
    }

    private func configureImportButton() {
        importButton.addTarget(self, action: #selector(importTapped), for: .touchUpInside)
        importButton.translatesAutoresizingMaskIntoConstraints = false

        var config = UIButton.Configuration.prominentGlass()
        config.cornerStyle = .capsule
        config.baseBackgroundColor = AppTint.current.uiColor
        config.baseForegroundColor = .white
        config.title = String(localized: "Fetch playlist")
        config.image = UIImage(systemName: "arrow.down.circle")
        config.imagePadding = 8
        config.imagePlacement = .leading
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = UIFont.preferredFont(forTextStyle: .headline)
            return outgoing
        }
        importButton.configuration = config
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        view.endEditing(true)
    }

    @objc private func importTapped() {
        let link = linkField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !link.isEmpty else {
            statusLabel.textColor = .systemRed
            statusLabel.text = String(localized: "Paste a Spotify link first.")
            return
        }
        guard SpotifyService.playlistID(from: link) != nil else {
            statusLabel.textColor = .systemRed
            statusLabel.text = String(localized: "Invalid Spotify link.")
            return
        }
        startImport(link: link)
    }

    private func startImport(link: String) {
        importButton.isEnabled = false
        activity.startAnimating()
        statusLabel.textColor = .secondaryLabel
        statusLabel.text = String(localized: "Fetching playlist...")
        linkField.resignFirstResponder()

        Task { [weak self] in
            guard let self else { return }
            do {
                let playlist = try await SpotifyService.fetchPlaylist(from: link) { [weak self] message in
                    self?.statusLabel.text = message
                }
                let session = SpotifyMatcher.makeSession(
                    from: link,
                    playlist: playlist,
                    localSongs: self.libraryService.songs,
                    existingMatches: nil
                )
                self.presentReview(session)
                self.statusLabel.text = ""
            } catch {
                self.statusLabel.textColor = .systemRed
                self.statusLabel.text = error.localizedDescription
            }
            self.activity.stopAnimating()
            self.importButton.isEnabled = true
        }
    }

    private func presentReview(_ session: SpotifyMatchSession) {
        didImport = false
        let review = SpotifyMatchReviewViewController(session: session, localSongs: libraryService.songs, isExisting: false)
        review.onConfirm = { [weak self] updated in
            guard let self else { return }
            self.didImport = true
            Task {
                let artwork = await SpotifyService.coverArtworkData(from: updated.playlist)
                self.libraryService.applyImportedPlaylist(session: updated, artworkDataOverride: artwork)
            }
        }
        review.onDismiss = { [weak self] in
            guard let self else { return }
            self.dismiss(animated: true) {
                if self.didImport {
                    self.showSuccessAlert(for: session)
                }
            }
        }
        let navigationController = UINavigationController(rootViewController: review)
        navigationController.navigationBar.tintColor = AppTint.current.uiColor
        navigationController.modalPresentationStyle = .pageSheet
        present(navigationController, animated: true)
    }

    private func showSuccessAlert(for session: SpotifyMatchSession) {
        let alert = UIAlertController(
            title: String(localized: "Playlist imported"),
            message: String(localized: "\u{201C}\(session.playlist.name)\u{201D}: \(session.orderedLocalSongIDs.count) songs added. Unmatched songs were skipped."),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default) { [weak self] _ in
            self?.navigationController?.popViewController(animated: true)
        })
        present(alert, animated: true)
    }
}

@MainActor
final class SpotifyMatchReviewViewController: UITableViewController {
    let session: SpotifyMatchSession
    private let localSongs: [Song]
    private let isExisting: Bool
    var onConfirm: ((SpotifyMatchSession) -> Void)?
    var onDismiss: (() -> Void)?

    init(session: SpotifyMatchSession, localSongs: [Song], isExisting: Bool = false) {
        self.session = session
        self.localSongs = localSongs
        self.isExisting = isExisting
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = isExisting ? session.playlist.name : String(localized: "Review matches")
        navigationItem.largeTitleDisplayMode = .never
        tableView.register(SpotifyReviewCell.self, forCellReuseIdentifier: SpotifyReviewCell.reuseID)
        tableView.keyboardDismissMode = .interactive
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 64
        tableView.tableHeaderView = buildHeader()
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: String(localized: "Cancel"), style: .plain, target: self, action: #selector(cancelTapped))
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: isExisting ? String(localized: "Apply") : String(localized: "Import"), style: .prominent, target: self, action: #selector(confirmTapped))
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        view.window?.endEditing(true)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        tableView.sizeHeaderToFit()
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        session.results.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: SpotifyReviewCell.reuseID, for: indexPath) as! SpotifyReviewCell
        cell.configure(with: session.results[indexPath.row])
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        // Rows are addressed by index: the same track can appear several times
        // in a playlist, so its ID does not identify a row.
        let index = indexPath.row
        switch session.results[index].status {
        case .ambiguous:
            presentCandidates(forResultAt: index)
        case .unmatched:
            presentManualPicker(forResultAt: index)
        default:
            break
        }
    }

    override func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        let index = indexPath.row
        let isRemoved = session.results[index].status == .removed
        return fixedContextMenu(identifier: nil, previewProvider: nil) { [weak self] _ in
            guard let self else { return UIMenu() }
            var actions: [UIAction] = []
            actions.append(UIAction(title: String(localized: "Select Manually…"), image: UIImage(systemName: "checkmark.circle")) { [weak self] _ in
                self?.presentManualPicker(forResultAt: index)
            })
            if !isRemoved {
                actions.insert(UIAction(title: String(localized: "Remove"), image: UIImage(systemName: "trash")?.withTintColor(.menuDestructive, renderingMode: .alwaysOriginal), attributes: .destructive) { [weak self] _ in
                    self?.session.remove(at: index)
                    self?.reloadAfterChange()
                }, at: 0)
            }
            return UIMenu(children: actions)
        }
    }

    private func presentCandidates(forResultAt index: Int) {
        let result = session.results[index]
        guard !result.candidates.isEmpty else { return }
        let candidatesVC = SpotifyCandidatesViewController(track: result.track, candidates: result.candidates) { [weak self] song in
            self?.session.choose(at: index, song: song)
            self?.navigationController?.popViewController(animated: true)
            self?.reloadAfterChange()
        }
        navigationController?.pushViewController(candidatesVC, animated: true)
    }

    private func presentManualPicker(forResultAt index: Int) {
        guard session.results.indices.contains(index) else { return }
        let result = session.results[index]
        let picker = SongSearchPickerViewController(
            songs: localSongs,
            track: result.track,
            selectedSong: result.localSong,
            showsRecommendations: true
        )
        picker.onSelect = { [weak self] song in
            self?.session.choose(at: index, song: song)
            self?.navigationController?.popViewController(animated: true)
            self?.reloadAfterChange()
        }
        navigationController?.pushViewController(picker, animated: true)
    }

    private func reloadAfterChange() {
        tableView.tableHeaderView = buildHeader()
        tableView.sizeHeaderToFit()
        tableView.reloadData()
    }

    private func buildHeader() -> UIView {
        let container = UIView()
        container.backgroundColor = .clear

        let countsLabel = UILabel()
        countsLabel.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(for: .systemFont(ofSize: 15, weight: .semibold))
        countsLabel.textColor = .label
        countsLabel.numberOfLines = 0
        countsLabel.text = String(localized: "\(session.matchedCount) matched \u{2022} \(session.ambiguousCount) to pick \u{2022} \(session.unmatchedCount) not found \u{2022} \(session.removedCount) removed")

        let hintLabel = UILabel()
        hintLabel.font = .preferredFont(forTextStyle: .footnote)
        hintLabel.textColor = .secondaryLabel
        hintLabel.numberOfLines = 0
        hintLabel.text = String(localized: "Long-press a track to remove it or to select a local match manually.")

        let capLabel = UILabel()
        capLabel.font = .preferredFont(forTextStyle: .footnote)
        capLabel.textColor = .systemOrange
        capLabel.numberOfLines = 0
        // A hidden label still takes up its text height in this constraint
        // chain, so leave it empty instead of hiding it.
        capLabel.text = session.playlist.tracks.count == 100
            ? String(localized: "Playlists with more than 100 tracks are only partially fetched: the first 100 tracks are shown.")
            : nil

        for label in [countsLabel, hintLabel, capLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(label)
        }
        NSLayoutConstraint.activate([
            countsLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            countsLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            countsLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            hintLabel.topAnchor.constraint(equalTo: countsLabel.bottomAnchor, constant: 6),
            hintLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            hintLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            capLabel.topAnchor.constraint(equalTo: hintLabel.bottomAnchor, constant: 6),
            capLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            capLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            capLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12)
        ])
        return container
    }

    @objc private func confirmTapped() {
        view.window?.endEditing(true)
        onConfirm?(session)
        if let onDismiss {
            onDismiss()
        } else {
            dismiss(animated: true)
        }
    }

    @objc private func cancelTapped() {
        view.window?.endEditing(true)
        if let onDismiss {
            onDismiss()
        } else {
            dismiss(animated: true)
        }
    }
}

final class SpotifyReviewCell: UITableViewCell {
    static let reuseID = "SpotifyReviewCell"
    private let statusLabel = UILabel()
    private var trackID: String?
    private var loadTask: Task<Void, Never>?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: .subtitle, reuseIdentifier: reuseIdentifier)
        statusLabel.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
        statusLabel.textAlignment = .right
        statusLabel.numberOfLines = 1
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.frame = CGRect(x: 0, y: 0, width: 92, height: 40)
        accessoryView = statusLabel
        imageView?.contentMode = .scaleAspectFill
        imageView?.layer.cornerRadius = 6
        imageView?.layer.masksToBounds = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        loadTask?.cancel()
        loadTask = nil
        trackID = nil
        imageView?.image = nil
    }

    func configure(with result: SpotifyMatchResult) {
        textLabel?.text = result.track.name
        textLabel?.numberOfLines = 2
        let subtitle = result.track.album.isEmpty ? result.track.artist : "\(result.track.artist) \u{2022} \(result.track.album)"
        detailTextLabel?.text = result.track.year.map { "\(subtitle) \u{2022} \($0)" } ?? subtitle
        detailTextLabel?.numberOfLines = 2

        let fallback = CoverPlaceholders.musicNote(size: 44)
        imageView?.image = fallback

        let track = result.track
        let id = track.id
        trackID = id
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            let image = await SpotifyTrackMetaStore.shared.image(for: track)
            guard !Task.isCancelled, let self, self.trackID == id else { return }
            self.imageView?.image = image.map { CoverThumbnails.thumbnail($0) } ?? fallback
        }

        switch result.status {
        case .matched:
            statusLabel.textColor = .systemGreen
            statusLabel.text = String(localized: "\u{2713} Found")
            accessoryType = .none
            contentView.alpha = 1
        case .ambiguous:
            statusLabel.textColor = .systemOrange
            statusLabel.text = String(localized: "Pick")
            accessoryType = .disclosureIndicator
            contentView.alpha = 1
        case .unmatched:
            statusLabel.textColor = .systemRed
            statusLabel.text = String(localized: "Not found")
            accessoryType = .none
            contentView.alpha = 1
        case .removed:
            statusLabel.textColor = .systemRed
            statusLabel.text = String(localized: "Removed")
            accessoryType = .none
            contentView.alpha = 0.5
        }
    }
}

@MainActor
final class SpotifyCandidatesViewController: UITableViewController {
    private let track: SpotifyTrack
    private let candidates: [Song]
    private let onSelect: (Song) -> Void

    init(track: SpotifyTrack, candidates: [Song], onSelect: @escaping (Song) -> Void) {
        self.track = track
        self.candidates = candidates
        self.onSelect = onSelect
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = track.name
        navigationItem.largeTitleDisplayMode = .never
        tableView.register(CoverSongCell.self, forCellReuseIdentifier: CoverSongCell.reuseID)
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 64
        tableView.tableHeaderView = buildHeader()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        tableView.sizeHeaderToFit()
    }

    private func buildHeader() -> UIView {
        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .footnote)
        label.textColor = .secondaryLabel
        label.numberOfLines = 0
        label.text = String(localized: "Several local songs match this track. Pick the right one:")
        label.translatesAutoresizingMaskIntoConstraints = false

        let container = UIView()
        container.backgroundColor = .clear
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10)
        ])
        return container
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        candidates.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: CoverSongCell.reuseID, for: indexPath) as! CoverSongCell
        cell.configure(with: candidates[indexPath.row])
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        onSelect(candidates[indexPath.row])
    }
}

@MainActor
final class SongSearchPickerViewController: UITableViewController, UISearchResultsUpdating {
    private let allSongs: [Song]
    private let track: SpotifyTrack
    private let selectedSong: Song?
    private let showsRecommendations: Bool
    private var recommendations: [Song] = []
    private var filteredSongs: [Song]
    var onSelect: ((Song) -> Void)?

    private var songSectionIndex: Int {
        showsRecommendations && !recommendations.isEmpty ? 2 : 1
    }

    init(songs: [Song], track: SpotifyTrack, selectedSong: Song?, showsRecommendations: Bool = false) {
        self.allSongs = songs
        self.filteredSongs = songs
        self.track = track
        self.selectedSong = selectedSong
        self.showsRecommendations = showsRecommendations
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Select local song")
        navigationItem.largeTitleDisplayMode = .never
        let search = UISearchController(searchResultsController: nil)
        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = false
        definesPresentationContext = true
        tableView.keyboardDismissMode = .interactive
        tableView.register(SelectionPreviewCell.self, forCellReuseIdentifier: SelectionPreviewCell.reuseID)
        tableView.register(CoverSongCell.self, forCellReuseIdentifier: CoverSongCell.reuseID)
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 64
        if showsRecommendations {
            // Fuzzy-scoring the whole library is too slow for the main thread.
            let track = track
            let songs = allSongs
            Task { [weak self] in
                let found = await Task.detached(priority: .userInitiated) {
                    SpotifyMatcher.recommendations(for: track, in: songs)
                }.value
                guard !Task.isCancelled, let self, !found.isEmpty else { return }
                self.recommendations = found
                self.tableView.reloadData()
            }
        }
    }


    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        navigationItem.searchController?.isActive = false
        view.window?.endEditing(true)
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        songSectionIndex + 1
    }

    override func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        indexPath.section == 0 ? SelectionPreviewCell.estimatedHeight : UITableView.automaticDimension
    }

    func updateSearchResults(for searchController: UISearchController) {
        let query = (searchController.searchBar.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            filteredSongs = allSongs
        } else {
            filteredSongs = allSongs.filter { song in
                song.title.localizedCaseInsensitiveContains(query)
                    || song.artist.localizedCaseInsensitiveContains(query)
            }
        }
        tableView.reloadData()
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if section == 0 { return 1 }
        if section == 1, songSectionIndex == 2 { return recommendations.count }
        return filteredSongs.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        if section == 0 { return nil }
        if section == 1, songSectionIndex == 2 { return String(localized: "Recommendations") }
        return filteredSongs.count == allSongs.count ? String(localized: "All songs") : String(localized: "Results")
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if indexPath.section == 0 {
            let cell = tableView.dequeueReusableCell(withIdentifier: SelectionPreviewCell.reuseID, for: indexPath) as! SelectionPreviewCell
            cell.configure(track: track, selectedSong: selectedSong)
            return cell
        }
        if indexPath.section == 1, songSectionIndex == 2 {
            let cell = tableView.dequeueReusableCell(withIdentifier: CoverSongCell.reuseID, for: indexPath) as! CoverSongCell
            cell.configure(with: recommendations[indexPath.row])
            return cell
        }
        let cell = tableView.dequeueReusableCell(withIdentifier: CoverSongCell.reuseID, for: indexPath) as! CoverSongCell
        cell.configure(with: filteredSongs[indexPath.row])
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.section != 0 else { return }
        if indexPath.section == 1, songSectionIndex == 2 {
            onSelect?(recommendations[indexPath.row])
        } else {
            onSelect?(filteredSongs[indexPath.row])
        }
    }
}

final class CoverSongCell: UITableViewCell {
    static let reuseID = "CoverSongCell"

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: .subtitle, reuseIdentifier: reuseIdentifier)
        imageView?.contentMode = .scaleAspectFill
        imageView?.layer.cornerRadius = 6
        imageView?.layer.masksToBounds = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(with song: Song) {
        textLabel?.text = song.title
        textLabel?.numberOfLines = 2
        let detail = song.album.isEmpty ? song.artist : "\(song.artist) \u{2022} \(song.album)"
        detailTextLabel?.text = detail
        detailTextLabel?.numberOfLines = 2
        if let artwork = Song.artworkImage(from: song.artworkData) {
            imageView?.image = CoverThumbnails.thumbnail(artwork)
        } else {
            imageView?.image = CoverPlaceholders.musicNote(size: 44)
        }
    }
}

final class SelectionPreviewCell: UITableViewCell {
    static let reuseID = "SelectionPreviewCell"
    static let estimatedHeight: CGFloat = 170

    private let sourceCaption = UILabel()
    private let sourceCover = UIImageView()
    private let sourceTitle = UILabel()
    private let sourceArtist = UILabel()
    private let currentCaption = UILabel()
    private let currentCover = UIImageView()
    private let currentTitle = UILabel()
    private let currentArtist = UILabel()

    private var trackID: String?
    private var loadTask: Task<Void, Never>?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: .default, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none

        sourceCaption.text = String(localized: "SPOTIFY SOURCE")
        currentCaption.text = String(localized: "CURRENTLY SELECTED")
        for label in [sourceCaption, currentCaption] {
            label.font = UIFont.systemFont(ofSize: 11, weight: .semibold)
            label.textColor = .secondaryLabel
        }
        for label in [sourceTitle, currentTitle] {
            label.font = UIFont.systemFont(ofSize: 15, weight: .semibold)
            label.textColor = .label
            label.numberOfLines = 1
        }
        for label in [sourceArtist, currentArtist] {
            label.font = UIFont.systemFont(ofSize: 13)
            label.textColor = .secondaryLabel
            label.numberOfLines = 1
        }
        for cover in [sourceCover, currentCover] {
            cover.contentMode = .scaleAspectFill
            cover.layer.cornerRadius = 6
            cover.layer.masksToBounds = true
            cover.translatesAutoresizingMaskIntoConstraints = false
        }

        let sourceTitleStack = UIStackView(arrangedSubviews: [sourceTitle, sourceArtist])
        sourceTitleStack.axis = .vertical
        sourceTitleStack.spacing = 2
        let currentTitleStack = UIStackView(arrangedSubviews: [currentTitle, currentArtist])
        currentTitleStack.axis = .vertical
        currentTitleStack.spacing = 2

        let sourceRow = UIStackView(arrangedSubviews: [sourceCover, sourceTitleStack])
        sourceRow.axis = .horizontal
        sourceRow.alignment = .center
        sourceRow.spacing = 12
        let currentRow = UIStackView(arrangedSubviews: [currentCover, currentTitleStack])
        currentRow.axis = .horizontal
        currentRow.alignment = .center
        currentRow.spacing = 12

        let divider = UIView()
        divider.backgroundColor = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        let stack = UIStackView(arrangedSubviews: [sourceCaption, sourceRow, divider, currentCaption, currentRow])
        stack.axis = .vertical
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
            sourceCover.widthAnchor.constraint(equalToConstant: 44),
            sourceCover.heightAnchor.constraint(equalToConstant: 44),
            currentCover.widthAnchor.constraint(equalToConstant: 44),
            currentCover.heightAnchor.constraint(equalToConstant: 44),
            divider.heightAnchor.constraint(equalToConstant: 1)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        loadTask?.cancel()
        loadTask = nil
        trackID = nil
        sourceCover.image = nil
    }

    func configure(track: SpotifyTrack, selectedSong: Song?) {
        sourceTitle.text = track.name
        sourceArtist.text = track.artist
        let fallback = CoverPlaceholders.musicNote(size: 44)
        sourceCover.image = fallback
        let id = track.id
        trackID = id
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            let image = await SpotifyTrackMetaStore.shared.image(for: track)
            guard !Task.isCancelled, let self, self.trackID == id else { return }
            self.sourceCover.image = image ?? fallback
        }

        if let selectedSong {
            currentTitle.text = selectedSong.title
            currentTitle.textColor = .label
            currentArtist.text = selectedSong.artist
            currentCover.image = Song.artworkImage(from: selectedSong.artworkData) ?? CoverPlaceholders.musicNote(size: 44)
        } else {
            currentTitle.text = String(localized: "To be selected")
            currentTitle.textColor = .secondaryLabel
            currentArtist.text = ""
            currentCover.image = CoverPlaceholders.questionMark(size: 44)
        }
    }
}

private extension UITableView {
    /// Sizes an Auto Layout-built `tableHeaderView` to the table's current width.
    /// Sizing it in `viewDidLoad` used a zero width (multi-line labels then
    /// measured one character per line) and ignored the horizontal constraint.
    func sizeHeaderToFit() {
        guard let header = tableHeaderView, bounds.width > 0 else { return }
        let height = header.systemLayoutSizeFitting(
            CGSize(width: bounds.width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
        guard header.frame.width != bounds.width || header.frame.height != height else { return }
        header.frame = CGRect(x: 0, y: 0, width: bounds.width, height: height)
        tableHeaderView = header
    }
}

enum CoverPlaceholders {
    static func musicNote(size: CGFloat) -> UIImage {
        symbol("music.note", size: size)
    }

    static func questionMark(size: CGFloat) -> UIImage {
        symbol("questionmark", size: size)
    }

    private static func symbol(_ name: String, size: CGFloat) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { context in
            UIColor.secondarySystemFill.setFill()
            context.fill(CGRect(x: 0, y: 0, width: size, height: size))

            let config = UIImage.SymbolConfiguration(pointSize: size * 0.38, weight: .medium)
            guard let symbol = UIImage(systemName: name, withConfiguration: config) else { return }
            let tinted = symbol.withTintColor(.systemGray2, renderingMode: .alwaysOriginal)
            let origin = CGPoint(
                x: (size - tinted.size.width) / 2,
                y: (size - tinted.size.height) / 2
            )
            tinted.draw(at: origin)
        }
    }
}

enum CoverThumbnails {
    static func thumbnail(_ image: UIImage, size: CGFloat = 44) -> UIImage {
        let target = CGSize(width: size, height: size)
        let scale = max(target.width / image.size.width, target.height / image.size.height)
        let scaledSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let origin = CGPoint(
            x: (target.width - scaledSize.width) / 2,
            y: (target.height - scaledSize.height) / 2
        )
        return UIGraphicsImageRenderer(size: target).image { _ in
            image.draw(in: CGRect(origin: origin, size: scaledSize))
        }
    }
}

@MainActor
struct SpotifyMatchReviewSheet: UIViewControllerRepresentable {
    let session: SpotifyMatchSession
    let localSongs: [Song]
    var isExisting: Bool = false
    var onConfirm: (SpotifyMatchSession) -> Void
    var onDismiss: () -> Void

    func makeUIViewController(context: Context) -> UINavigationController {
        let review = SpotifyMatchReviewViewController(session: session, localSongs: localSongs, isExisting: isExisting)
        let navigationController = UINavigationController(rootViewController: review)
        navigationController.navigationBar.tintColor = AppTint.current.uiColor
        updateUIViewController(navigationController, context: context)
        return navigationController
    }

    func updateUIViewController(_ navigationController: UINavigationController, context: Context) {
        // Refresh the callbacks so they never capture a stale copy of the parent view.
        guard let review = navigationController.viewControllers.first as? SpotifyMatchReviewViewController else { return }
        review.onConfirm = onConfirm
        review.onDismiss = onDismiss
    }
}
