//
//  CardDetailViewController.swift
//  Loop
//
//  Expanded detail for a single card, presented as a dark sheet. A header row
//  carries the icon tile, kind badge, and a close button; the body renders the
//  card's markdown; a pinned bottom bar offers Archive / Done.
//

#if os(iOS)
import UIKit

final class CardDetailViewController: UIViewController {

    private let card: Card

    /// Warm gold accent shared with the card list.
    private let accent = FeedCardListView.accent
    /// Near-black sheet background.
    private let sheetBackground = UIColor(red: 0.05, green: 0.05, blue: 0.055, alpha: 1)

    // MARK: - UI

    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()

    private let iconTile: UIView = {
        let v = UIView()
        v.layer.cornerRadius = 11
        v.layer.cornerCurve = .continuous
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()

    private let iconView: UIImageView = {
        let iv = UIImageView()
        iv.contentMode = .scaleAspectFit
        iv.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
        iv.translatesAutoresizingMaskIntoConstraints = false
        return iv
    }()

    private let badgeLabel: UILabel = {
        let l = UILabel()
        l.font = .systemFont(ofSize: 13, weight: .bold)
        return l
    }()

    private let titleLabel: UILabel = {
        let l = UILabel()
        l.font = .systemFont(ofSize: 32, weight: .bold)
        l.textColor = .white
        l.numberOfLines = 0
        return l
    }()

    /// Vertical stack holding the body content. When the body contains
    /// markdown tables the stack receives interleaved text labels and
    /// table grid views; otherwise a single label identical to the old
    /// `bodyLabel`.
    private let bodyStack: UIStackView = {
        let s = UIStackView()
        s.axis = .vertical
        s.spacing = 12
        s.alignment = .fill
        return s
    }()

    private let divider: UIView = {
        let v = UIView()
        v.backgroundColor = UIColor(white: 1, alpha: 0.1)
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()

    private let metaLabel: UILabel = {
        let l = UILabel()
        l.font = .systemFont(ofSize: 14, weight: .regular)
        l.textColor = UIColor(white: 0.5, alpha: 1)
        l.numberOfLines = 0
        return l
    }()

    // MARK: - Init

    init(card: Card) {
        self.card = card
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = sheetBackground
        navigationController?.setNavigationBarHidden(true, animated: false)
        if let sheet = (navigationController ?? self).sheetPresentationController {
            sheet.prefersGrabberVisible = true
        }
        setupLayout()
        populate()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: animated)
    }

    // MARK: - Layout

    private func setupLayout() {
        let header = makeHeader()
        header.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(header)

        let actionBar = makeActionBar()
        actionBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(actionBar)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.showsVerticalScrollIndicator = false
        view.addSubview(scrollView)

        contentStack.axis = .vertical
        contentStack.spacing = 18
        contentStack.alignment = .fill
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(contentStack)

        contentStack.addArrangedSubview(titleLabel)
        contentStack.addArrangedSubview(bodyStack)
        contentStack.addArrangedSubview(divider)
        contentStack.addArrangedSubview(metaLabel)
        contentStack.setCustomSpacing(22, after: bodyStack)
        contentStack.setCustomSpacing(14, after: divider)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 4),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),

            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 18),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: actionBar.topAnchor),

            contentStack.topAnchor.constraint(equalTo: scrollView.topAnchor),
            contentStack.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor, constant: 24),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: -24),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: -24),
            contentStack.widthAnchor.constraint(equalTo: scrollView.widthAnchor, constant: -48),

            divider.heightAnchor.constraint(equalToConstant: 1),

            actionBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            actionBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            actionBar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
        ])
    }

    /// Icon tile + kind badge on the left, close button on the right.
    private func makeHeader() -> UIView {
        let container = UIView()

        iconTile.addSubview(iconView)
        container.addSubview(iconTile)
        container.addSubview(badgeLabel)
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false

        let close = UIButton(type: .system)
        close.setImage(UIImage(systemName: "xmark",
                               withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)),
                       for: .normal)
        close.tintColor = UIColor(white: 0.85, alpha: 1)
        close.backgroundColor = UIColor(white: 1, alpha: 0.1)
        close.layer.cornerRadius = 18
        close.translatesAutoresizingMaskIntoConstraints = false
        close.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        container.addSubview(close)

        NSLayoutConstraint.activate([
            iconTile.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            iconTile.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            iconTile.widthAnchor.constraint(equalToConstant: 40),
            iconTile.heightAnchor.constraint(equalToConstant: 40),
            container.heightAnchor.constraint(equalToConstant: 40),

            iconView.centerXAnchor.constraint(equalTo: iconTile.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconTile.centerYAnchor),

            badgeLabel.leadingAnchor.constraint(equalTo: iconTile.trailingAnchor, constant: 12),
            badgeLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),

            close.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            close.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            close.widthAnchor.constraint(equalToConstant: 36),
            close.heightAnchor.constraint(equalToConstant: 36),
        ])
        return container
    }

    /// Pinned Archive (gold-outlined) / Done (filled) buttons.
    private func makeActionBar() -> UIView {
        let archive = UIButton(type: .system)
        archive.setTitle("Archive", for: .normal)
        archive.setTitleColor(accent, for: .normal)
        archive.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        archive.backgroundColor = accent.withAlphaComponent(0.08)
        archive.layer.cornerRadius = 14
        archive.layer.cornerCurve = .continuous
        archive.layer.borderWidth = 1
        archive.layer.borderColor = accent.withAlphaComponent(0.7).cgColor
        archive.addTarget(self, action: #selector(archiveTapped), for: .touchUpInside)

        let done = UIButton(type: .system)
        done.setTitle("Done", for: .normal)
        done.setTitleColor(.white, for: .normal)
        done.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        done.backgroundColor = UIColor(white: 1, alpha: 0.1)
        done.layer.cornerRadius = 14
        done.layer.cornerCurve = .continuous
        done.addTarget(self, action: #selector(doneTapped), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [archive, done])
        stack.axis = .horizontal
        stack.spacing = 14
        stack.distribution = .fillEqually
        archive.heightAnchor.constraint(equalToConstant: 56).isActive = true
        done.heightAnchor.constraint(equalToConstant: 56).isActive = true
        return stack
    }

    // MARK: - Populate

    private func populate() {
        let style = card.displayIcon
        iconView.image = UIImage(systemName: style.symbol)
        iconView.tintColor = style.tint.withAlphaComponent(0.95)
        iconTile.backgroundColor = style.tint.withAlphaComponent(0.22)

        badgeLabel.attributedText = NSAttributedString(
            string: card.displayBadge,
            attributes: [.kern: 1.5, .foregroundColor: accent,
                         .font: UIFont.systemFont(ofSize: 13, weight: .bold)])

        titleLabel.text = card.title
        populateBody()

        var meta = "\(card.kind.rawValue.capitalized) card"
        if let source = card.source { meta += " · created from \(source)" }
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .none
        meta += " · \(df.string(from: card.createdAt))"
        metaLabel.text = meta
    }

    // MARK: - Body (table-aware)

    private let cardBodyFont = UIFont.systemFont(ofSize: 17, weight: .regular)
    private let cardTextColor = UIColor(white: 0.82, alpha: 1.0)

    /// Parse the card body through `MarkdownSegmenter` and populate
    /// `bodyStack` with text labels and/or styled table grids.
    private func populateBody() {
        bodyStack.arrangedSubviews.forEach {
            bodyStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        let body = card.body
        guard card.kind == .markdown else {
            let label = makeCardBodyLabel()
            label.text = body
            bodyStack.addArrangedSubview(label)
            return
        }

        let segments = MarkdownSegmenter.segments(from: body)
        for segment in segments {
            switch segment {
            case .text(let prose):
                let label = makeCardBodyLabel()
                label.attributedText = CardMarkdown.attributed(
                    prose,
                    bodyFont: cardBodyFont,
                    textColor: cardTextColor,
                    headingColor: .white,
                    bulletColor: accent)
                bodyStack.addArrangedSubview(label)

            case .table(let table):
                bodyStack.addArrangedSubview(makeCardTableView(table: table))

            case .codeBlock(let block):
                bodyStack.addArrangedSubview(makeCardCodeBlockView(block: block))
            }
        }
    }

    private func makeCardBodyLabel() -> UILabel {
        let l = UILabel()
        l.font = cardBodyFont
        l.textColor = cardTextColor
        l.numberOfLines = 0
        return l
    }

    /// Styled table grid for the dark card detail sheet. Horizontally
    /// scrollable when the table is wider than the available width.
    private func makeCardTableView(table: MarkdownTable) -> UIView {
        let cellPadH: CGFloat = 10
        let cellPadV: CGFloat = 7
        let minCol: CGFloat = 52
        let maxCol: CGFloat = 200
        let cellFont = UIFont.systemFont(ofSize: 15, weight: .regular)
        let headerCellFont = UIFont.systemFont(ofSize: 15, weight: .semibold)

        // Measure column widths
        var columnWidths = Array(repeating: minCol, count: table.columnCount)
        let allRows = [table.headers] + table.rows
        for (rowIdx, row) in allRows.enumerated() {
            for (col, cell) in row.enumerated() where col < table.columnCount {
                let font = (rowIdx == 0) ? headerCellFont : cellFont
                let size = (cell as NSString).size(withAttributes: [.font: font])
                let needed = ceil(size.width) + cellPadH * 2
                columnWidths[col] = min(maxCol, max(columnWidths[col], needed))
            }
        }
        let totalTableWidth = columnWidths.reduce(0, +)

        // Wrapper with rounded border
        let wrapper = UIView()
        wrapper.translatesAutoresizingMaskIntoConstraints = false
        wrapper.clipsToBounds = true
        wrapper.layer.cornerRadius = 10
        wrapper.layer.cornerCurve = .continuous
        wrapper.layer.borderWidth = 0.5
        wrapper.layer.borderColor = UIColor(white: 1, alpha: 0.15).cgColor
        wrapper.backgroundColor = UIColor(white: 1, alpha: 0.06)

        let scrollView = UIScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.showsHorizontalScrollIndicator = true
        scrollView.showsVerticalScrollIndicator = false
        wrapper.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: wrapper.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
        ])

        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.backgroundColor = .clear
        scrollView.addSubview(container)

        let fillWidth = container.widthAnchor.constraint(
            equalTo: scrollView.frameLayoutGuide.widthAnchor)
        fillWidth.priority = UILayoutPriority(999)
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            container.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            container.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            container.widthAnchor.constraint(greaterThanOrEqualToConstant: totalTableWidth),
            fillWidth,
            container.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
        ])

        let vstack = UIStackView()
        vstack.translatesAutoresizingMaskIntoConstraints = false
        vstack.axis = .vertical
        vstack.alignment = .fill
        vstack.distribution = .fill
        vstack.spacing = 0
        container.addSubview(vstack)
        NSLayoutConstraint.activate([
            vstack.topAnchor.constraint(equalTo: container.topAnchor),
            vstack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            vstack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            vstack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])

        // Header row
        vstack.addArrangedSubview(
            makeCardTableRow(cells: table.headers, alignments: table.alignments,
                             columnWidths: columnWidths, isHeader: true, alt: false,
                             cellFont: cellFont, headerFont: headerCellFont))
        // Data rows
        for (i, row) in table.rows.enumerated() {
            let div = UIView()
            div.translatesAutoresizingMaskIntoConstraints = false
            div.backgroundColor = UIColor(white: 1, alpha: 0.08)
            div.heightAnchor.constraint(equalToConstant: 0.5).isActive = true
            vstack.addArrangedSubview(div)
            vstack.addArrangedSubview(
                makeCardTableRow(cells: row, alignments: table.alignments,
                                 columnWidths: columnWidths, isHeader: false,
                                 alt: !i.isMultiple(of: 2),
                                 cellFont: cellFont, headerFont: headerCellFont))
        }

        // Height calculation
        var totalHeight: CGFloat = 0
        for (rowIdx, row) in allRows.enumerated() {
            var maxH: CGFloat = 0
            for (col, cell) in row.enumerated() where col < table.columnCount {
                let font = (rowIdx == 0) ? headerCellFont : cellFont
                let w = columnWidths[col] - cellPadH * 2
                let rect = (cell as NSString).boundingRect(
                    with: CGSize(width: w, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: [.font: font], context: nil)
                maxH = max(maxH, ceil(rect.height) + cellPadV * 2)
            }
            totalHeight += maxH
            if rowIdx > 0 { totalHeight += 0.5 }
        }
        wrapper.heightAnchor.constraint(equalToConstant: totalHeight).isActive = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            scrollView.flashScrollIndicators()
        }
        return wrapper
    }

    private func makeCardTableRow(cells: [String],
                                  alignments: [MarkdownColumnAlignment],
                                  columnWidths: [CGFloat],
                                  isHeader: Bool,
                                  alt: Bool,
                                  cellFont: UIFont,
                                  headerFont: UIFont) -> UIView {
        let row = UIView()
        row.translatesAutoresizingMaskIntoConstraints = false
        if isHeader {
            row.backgroundColor = UIColor(white: 1, alpha: 0.08)
        } else if alt {
            row.backgroundColor = UIColor(white: 1, alpha: 0.03)
        }

        let hstack = UIStackView()
        hstack.translatesAutoresizingMaskIntoConstraints = false
        hstack.axis = .horizontal
        hstack.alignment = .fill
        hstack.distribution = .fill
        hstack.spacing = 0
        row.addSubview(hstack)
        NSLayoutConstraint.activate([
            hstack.topAnchor.constraint(equalTo: row.topAnchor),
            hstack.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            hstack.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            hstack.trailingAnchor.constraint(equalTo: row.trailingAnchor),
        ])

        for (i, text) in cells.enumerated() {
            let alignment = i < alignments.count ? alignments[i] : .left
            let width = i < columnWidths.count ? columnWidths[i] : 70

            let cell = UIView()
            cell.translatesAutoresizingMaskIntoConstraints = false
            cell.widthAnchor.constraint(equalToConstant: width).isActive = true

            let label = UILabel()
            label.translatesAutoresizingMaskIntoConstraints = false
            label.numberOfLines = 0
            label.font = isHeader ? headerFont : cellFont
            label.textColor = isHeader ? .white : cardTextColor
            let paragraph = NSMutableParagraphStyle()
            switch alignment {
            case .left:   paragraph.alignment = .left
            case .center: paragraph.alignment = .center
            case .right:  paragraph.alignment = .right
            }
            paragraph.lineBreakMode = .byWordWrapping
            label.attributedText = NSAttributedString(
                string: text,
                attributes: [.font: label.font!, .foregroundColor: label.textColor!,
                             .paragraphStyle: paragraph])

            cell.addSubview(label)
            NSLayoutConstraint.activate([
                label.topAnchor.constraint(equalTo: cell.topAnchor, constant: 7),
                label.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -7),
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -10),
            ])

            if i > 0 {
                let line = UIView()
                line.translatesAutoresizingMaskIntoConstraints = false
                line.backgroundColor = UIColor(white: 1, alpha: 0.08)
                cell.addSubview(line)
                NSLayoutConstraint.activate([
                    line.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
                    line.topAnchor.constraint(equalTo: cell.topAnchor),
                    line.bottomAnchor.constraint(equalTo: cell.bottomAnchor),
                    line.widthAnchor.constraint(equalToConstant: 0.5),
                ])
            }
            hstack.addArrangedSubview(cell)
        }
        return row
    }

    /// Styled code block for the dark card detail sheet.
    private func makeCardCodeBlockView(block: MarkdownCodeBlock) -> UIView {
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.backgroundColor = UIColor(white: 1, alpha: 0.06)
        container.layer.cornerRadius = 8
        container.layer.cornerCurve = .continuous

        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.numberOfLines = 0
        label.font = UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        label.textColor = UIColor(white: 0.82, alpha: 1)
        label.text = block.code
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
        ])

        if let lang = block.language, !lang.isEmpty {
            let badge = UILabel()
            badge.translatesAutoresizingMaskIntoConstraints = false
            badge.text = lang
            badge.font = UIFont.monospacedSystemFont(ofSize: 10, weight: .medium)
            badge.textColor = UIColor(white: 0.5, alpha: 1)
            container.addSubview(badge)
            NSLayoutConstraint.activate([
                badge.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
                badge.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            ])
        }
        return container
    }

    // MARK: - Actions

    @objc private func closeTapped() { dismiss(animated: true) }

    @objc private func doneTapped() {
        // "Done" acknowledges the card but keeps it in the feed.
        CardStore.shared.updateState(id: card.id, state: .kept)
        dismiss(animated: true)
    }

    @objc private func archiveTapped() {
        CardStore.shared.updateState(id: card.id, state: .archived)
        dismiss(animated: true)
    }
}

#endif
