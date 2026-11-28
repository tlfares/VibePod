import UIKit

final class LRCLIBResultsViewController: UITableViewController {
    private let results: [LyricsCandidate]
    private let song: Song
    private let tint: UIColor
    private let onSelect: (LyricsCandidate) -> Void
    /// Last resort when none of the results fits: Mistral writes them.
    private let onGenerate: () -> Void
    private let aiAvailable = AIFeatures.isAvailable

    private enum Section: Int, CaseIterable {
        case searched, results, generate
    }

    init(results: [LyricsCandidate], song: Song, tint: UIColor, onSelect: @escaping (LyricsCandidate) -> Void, onGenerate: @escaping () -> Void) {
        self.results = results
        self.song = song
        self.tint = tint
        self.onSelect = onSelect
        self.onGenerate = onGenerate
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:)") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Lyrics Results")
        // System tint: a hard-coded white item was invisible on the light navigation bar.
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancelTapped))
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 72
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "result")
    }

    @objc private func cancelTapped() { dismiss(animated: true) }

    override func numberOfSections(in tableView: UITableView) -> Int { Section.allCases.count }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        Section(rawValue: section) == .results ? results.count : 1
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch Section(rawValue: section) {
        case .searched: String(localized: "Searched")
        case .results: String(localized: "Results (\(results.count))")
        case .generate: String(localized: "None of These?")
        case nil: nil
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch Section(rawValue: section) {
        case .results:
            String(localized: "Best matches first, then word by word, duet and synced lyrics. Tap a result to preview and import it.")
        case .generate:
            aiAvailable
                ? String(localized: "\(AIProvider.current.name) transcribes the vocals and syncs them to the song. The song's audio is sent to \(AIProvider.current.name); you can delete the result anytime.")
                : String(localized: "Turn on AI Features in Settings › Tools to have \(AIProvider.current.name) transcribe and sync this song's lyrics.")
        default:
            nil
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "result", for: indexPath)
        cell.selectionStyle = indexPath.section == Section.searched.rawValue ? .none : .default
        cell.accessoryView = nil

        if indexPath.section == Section.generate.rawValue {
            var config = cell.defaultContentConfiguration()
            config.text = String(localized: "Generate with \(AIProvider.current.name)")
            config.textProperties.color = aiAvailable ? tint : .tertiaryLabel
            config.image = UIImage(systemName: "sparkles")
            config.imageProperties.tintColor = aiAvailable ? tint : .tertiaryLabel
            cell.contentConfiguration = config
            cell.accessoryType = .none
            cell.accessoryView = BetaBadgeLabel(tint: tint)
            cell.selectionStyle = aiAvailable ? .default : .none
            return cell
        }

        if indexPath.section == Section.searched.rawValue {
            var config = cell.defaultContentConfiguration()
            config.text = "\(song.title) — \(song.artist)"
            config.secondaryText = song.album
            config.secondaryTextProperties.color = .secondaryLabel
            config.secondaryTextProperties.font = .preferredFont(forTextStyle: .footnote)
            // Content configurations and the legacy `imageView` must not be mixed.
            config.image = UIImage(systemName: "music.note")
            config.imageProperties.tintColor = tint
            cell.contentConfiguration = config
            cell.accessoryType = .none
            return cell
        }

        cell.accessoryType = .disclosureIndicator
        let r = results[indexPath.row]
        var config = cell.defaultContentConfiguration()
        config.text = r.title
        config.textProperties.font = .preferredFont(forTextStyle: .headline)
        config.textToSecondaryTextVerticalPadding = 4
        config.secondaryText = "\(r.source) · \(r.featureText)\n\(r.detailText)"
        config.secondaryTextProperties.color = .secondaryLabel
        config.secondaryTextProperties.font = .preferredFont(forTextStyle: .footnote)

        cell.contentConfiguration = config
        return cell
    }

    /// Held with Speechmatics on: its model, kept for the next ones.
    /// Picking one generates with it.
    override func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        guard indexPath.section == Section.generate.rawValue, aiAvailable, Speechmatics.isOn else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            let actions = Speechmatics.OperatingPoint.allCases.map { model in
                UIAction(title: model.title, state: model == Speechmatics.operatingPoint ? .on : .off) { _ in
                    Speechmatics.operatingPoint = model
                    guard let self else { return }
                    let onGenerate = self.onGenerate
                    self.dismiss(animated: true) { onGenerate() }
                }
            }
            return UIMenu(title: String(localized: "Speechmatics Model"), options: .displayInline, children: actions)
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.section == Section.generate.rawValue {
            guard aiAvailable else { return }
            let onGenerate = onGenerate
            dismiss(animated: true) { onGenerate() }
            return
        }
        guard indexPath.section == Section.results.rawValue else { return }
        let r = results[indexPath.row]
        let preview = LRCLIBPreviewViewController(result: r, song: song, tint: tint) { [weak self] result in
            self?.dismiss(animated: true) {
                self?.onSelect(result)
                self?.dismiss(animated: true)
            }
        }
        let nav = UINavigationController(rootViewController: preview)
        if let sheet = nav.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
        }
        present(nav, animated: true)
    }
}

/// The "BETA" capsule of `BetaBadge`, for UIKit rows.
private final class BetaBadgeLabel: UILabel {
    init(tint: UIColor) {
        super.init(frame: .zero)
        text = String(localized: "BETA")
        font = .systemFont(ofSize: 10, weight: .heavy)
        attributedText = NSAttributedString(string: String(localized: "BETA"), attributes: [.kern: 0.6, .font: font as Any])
        textColor = tint
        textAlignment = .center
        backgroundColor = tint.withAlphaComponent(0.18)
        layer.borderColor = tint.withAlphaComponent(0.35).cgColor
        layer.borderWidth = 0.5
        layer.masksToBounds = true
        let size = intrinsicContentSize
        frame.size = CGSize(width: size.width + 14, height: size.height + 6)
        layer.cornerRadius = frame.height / 2
    }

    required init?(coder: NSCoder) { fatalError("init(coder:)") }
}

// MARK: - Preview

final class LRCLIBPreviewViewController: UIViewController {
    private let result: LyricsCandidate
    private let song: Song
    private let tint: UIColor
    private let onImport: (LyricsCandidate) -> Void
    private let textView = UITextView()

    init(result: LyricsCandidate, song: Song, tint: UIColor, onImport: @escaping (LyricsCandidate) -> Void) {
        self.result = result
        self.song = song
        self.tint = tint
        self.onImport = onImport
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:)") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Preview")
        view.backgroundColor = .pageBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancelTapped))

        let importBtn = UIBarButtonItem(title: String(localized: "Import"), style: .prominent, target: self, action: #selector(importTapped))
        importBtn.tintColor = tint
        importBtn.isEnabled = result.hasLyrics
        navigationItem.rightBarButtonItem = importBtn

        let header = UILabel()
        header.numberOfLines = 0
        header.textAlignment = .center
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.preferredFont(forTextStyle: .headline),
            .foregroundColor: UIColor.label
        ]
        let subtitleAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.preferredFont(forTextStyle: .subheadline),
            .foregroundColor: UIColor.secondaryLabel
        ]
        let attrStr = NSMutableAttributedString()
        attrStr.append(NSAttributedString(string: "\(result.title)\n", attributes: titleAttrs))
        attrStr.append(NSAttributedString(string: result.detailText, attributes: subtitleAttrs))
        header.attributedText = attrStr
        header.translatesAutoresizingMaskIntoConstraints = false

        textView.isEditable = false
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textColor = .label
        textView.backgroundColor = .clear
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 16, right: 12)

        if result.hasLyrics {
            textView.text = preview
        } else {
            textView.text = String(localized: "No lyrics content available.")
            textView.textColor = .secondaryLabel
        }

        let separator = UIView()
        separator.backgroundColor = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(header)
        view.addSubview(separator)
        view.addSubview(textView)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            separator.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            separator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1.0 / max(traitCollection.displayScale, 1)),

            textView.topAnchor.constraint(equalTo: separator.bottomAnchor),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    /// The lines as they'll show: a second singer's after an arrow.
    private var preview: String {
        guard result.isSynced else { return result.plainText ?? "" }
        let trailing = result.trailingLineIndices
        return result.lines.enumerated().map { index, line in
            let minutes = Int(line.time) / 60
            let stamp = String(format: "%02d:%05.2f", minutes, line.time - Double(minutes * 60))
            return "[\(stamp)] " + (trailing.contains(index) ? "→ " : "") + line.text
        }.joined(separator: "\n")
    }

    @objc private func cancelTapped() { dismiss(animated: true) }

    @objc private func importTapped() {
        guard result.hasLyrics else { return }
        onImport(result)
    }
}

private extension LyricsCandidate {
    /// "Artist — Album — 3:45", skipping missing parts.
    var detailText: String {
        let length = duration.map { String(format: "%d:%02d", Int($0) / 60, Int($0) % 60) } ?? ""
        return [artist, album ?? "", length].filter { !$0.isEmpty }.joined(separator: " — ")
    }
}
