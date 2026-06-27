//
//  MacFeedCardListView.swift
//  LoopMac
//
//  AppKit port of the iOS FeedCardListView — the scannable vertical list of
//  feed cards shown on the empty new-tab screen, sitting just under the orb.
//  Each row is a compact dark panel (icon tile, title, one-line summary, kind
//  badge, hashtags) matching the iOS card styling. Click a row to open its
//  detail; right-click for Archive. Cards come from the shared CardStore, which
//  reads the same workspace as iOS, so both surfaces show the same cards.
//
//  The list has no scroll view of its own — it's added as a single tall view
//  into the conversation pane's message stack, so the outer scroll view owns
//  scrolling and the orb stays pinned above it.
//

#if os(macOS)
import AppKit

final class MacFeedCardListView: NSView {

    /// Warm gold used for badges and accents — matches the iOS card accent.
    static let accent = NSColor(srgbRed: 0.82, green: 0.66, blue: 0.40, alpha: 1)

    /// Fired when a row is clicked — the host opens the card's detail.
    var onTap: ((Card) -> Void)?
    /// Fired when the user archives a card — the host persists the state change.
    var onArchive: ((Card) -> Void)?

    private let titleLabel = NSTextField(labelWithString: "Cards")
    private let countLabel = NSTextField(labelWithString: "")
    private let rowsStack = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 26, weight: .bold)
        titleLabel.textColor = .labelColor

        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.font = .systemFont(ofSize: 13, weight: .regular)
        countLabel.textColor = .secondaryLabelColor

        let header = NSStackView(views: [titleLabel, countLabel])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 2
        header.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header)

        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.distribution = .fill
        rowsStack.spacing = 10
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rowsStack)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            header.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),

            rowsStack.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            rowsStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            rowsStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            rowsStack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    /// Replace the list contents and refresh.
    func setCards(_ cards: [Card]) {
        for v in rowsStack.arrangedSubviews { rowsStack.removeArrangedSubview(v); v.removeFromSuperview() }

        let n = cards.count
        countLabel.stringValue = "\(n) card\(n == 1 ? "" : "s") · newest first"

        for card in cards {
            let row = MacFeedCardRow(card: card)
            row.onTap = { [weak self] in self?.onTap?(card) }
            row.onArchive = { [weak self] in self?.onArchive?(card) }
            rowsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
        }
    }
}

// MARK: - Card row

/// A single scannable card row: icon tile, title, summary, kind badge, tags.
/// Mirrors the iOS FeedCardCell panel styling.
private final class MacFeedCardRow: NSView {

    var onTap: (() -> Void)?
    var onArchive: (() -> Void)?

    private let card: Card

    init(card: Card) {
        self.card = card
        super.init(frame: .zero)
        setup()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 20
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        applyAppearanceColors()

        let style = card.displayIcon

        // Icon tile.
        let iconTile = NSView()
        iconTile.translatesAutoresizingMaskIntoConstraints = false
        iconTile.wantsLayer = true
        iconTile.layer?.cornerRadius = 14
        iconTile.layer?.cornerCurve = .continuous
        iconTile.layer?.backgroundColor = style.tint.withAlphaComponent(0.22).cgColor

        let iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 22, weight: .semibold)
        iconView.image = NSImage(systemSymbolName: style.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(symbolConfig)
        iconView.contentTintColor = style.tint.withAlphaComponent(0.95)
        iconTile.addSubview(iconView)

        // Title + badge share the top row.
        let titleLabel = NSTextField(labelWithString: card.title)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 18, weight: .bold)
        titleLabel.textColor = .labelColor
        titleLabel.maximumNumberOfLines = 2
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.cell?.wraps = true
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let badge = MacFeedCardRow.makeBadge(text: card.displayBadge)

        let titleRow = NSStackView(views: [titleLabel, badge])
        titleRow.orientation = .horizontal
        titleRow.alignment = .top
        titleRow.spacing = 10
        titleRow.translatesAutoresizingMaskIntoConstraints = false

        let textStack = NSStackView()
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 3
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.addArrangedSubview(titleRow)
        titleRow.widthAnchor.constraint(equalTo: textStack.widthAnchor).isActive = true

        if let subtitle = card.displaySubtitle {
            let subtitleLabel = NSTextField(labelWithString: subtitle)
            subtitleLabel.font = .systemFont(ofSize: 14, weight: .regular)
            subtitleLabel.textColor = .secondaryLabelColor
            subtitleLabel.maximumNumberOfLines = 1
            subtitleLabel.lineBreakMode = .byTruncatingTail
            textStack.addArrangedSubview(subtitleLabel)
            textStack.setCustomSpacing(10, after: subtitleLabel)
        }

        if !card.tags.isEmpty {
            let tagsLabel = NSTextField(labelWithString: card.tags.map { "#\($0)" }.joined(separator: " "))
            tagsLabel.font = .systemFont(ofSize: 12, weight: .regular)
            tagsLabel.textColor = .tertiaryLabelColor
            tagsLabel.maximumNumberOfLines = 1
            tagsLabel.lineBreakMode = .byTruncatingTail
            textStack.addArrangedSubview(tagsLabel)
        }

        addSubview(iconTile)
        addSubview(textStack)

        NSLayoutConstraint.activate([
            iconTile.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            iconTile.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            iconTile.widthAnchor.constraint(equalToConstant: 52),
            iconTile.heightAnchor.constraint(equalToConstant: 52),
            iconTile.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -16),

            iconView.centerXAnchor.constraint(equalTo: iconTile.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconTile.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 26),
            iconView.heightAnchor.constraint(equalToConstant: 26),

            textStack.leadingAnchor.constraint(equalTo: iconTile.trailingAnchor, constant: 14),
            textStack.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            textStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            textStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
        ])

        let click = NSClickGestureRecognizer(target: self, action: #selector(rowClicked))
        addGestureRecognizer(click)
    }

    private static func makeBadge(text: String) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        container.layer?.cornerRadius = 7
        container.layer?.cornerCurve = .continuous
        container.layer?.backgroundColor = MacFeedCardListView.accent.withAlphaComponent(0.12).cgColor
        container.setContentHuggingPriority(.required, for: .horizontal)
        container.setContentCompressionResistancePriority(.required, for: .horizontal)

        let label = NSTextField(labelWithString: text)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 11, weight: .bold)
        label.textColor = MacFeedCardListView.accent
        container.addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 9),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -9),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4),
        ])
        return container
    }

    @objc private func rowClicked() { onTap?() }

    // Right-click → Archive, mirroring the iOS swipe action.
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let item = NSMenuItem(title: "Archive", action: #selector(archiveClicked), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return menu
    }

    @objc private func archiveClicked() { onArchive?() }

    // Subtle hover feedback so the row reads as clickable.
    private var trackingAreaRef: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingAreaRef { removeTrackingArea(existing) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        applyAppearanceColors()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        applyAppearanceColors()
    }

    // MARK: - Light/dark adaptation

    private var isHovering = false

    private var isDarkMode: Bool {
        effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    /// Resolve the panel fill + border for the current appearance. Layer-backed
    /// CGColors don't auto-adapt, so this is re-applied whenever the effective
    /// appearance (or hover state) changes.
    private func applyAppearanceColors() {
        let dark = isDarkMode
        layer?.backgroundColor = (dark
            ? NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1)
            : NSColor(srgbRed: 0.96, green: 0.96, blue: 0.97, alpha: 1)).cgColor
        let border = isHovering
            ? MacFeedCardListView.accent.withAlphaComponent(0.5)
            : (dark ? NSColor(white: 1, alpha: 0.06) : NSColor(white: 0, alpha: 0.08))
        layer?.borderColor = border.cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearanceColors()
    }
}

#endif
