//
//  MacCardDetailWindowController.swift
//  LoopMac
//
//  Detail window for a feed card, opened when a row in MacFeedCardListView is
//  clicked. Mirrors the iOS CardDetailViewController: the rendered poster up
//  top (the poster already contains the styled markdown/image), then the title,
//  provenance, tags, and raw body text, with an Archive / Done action bar.
//

#if os(macOS)
import AppKit

final class MacCardDetailWindowController: NSWindowController {

    private static let accent = MacFeedCardListView.accent

    private let card: Card
    private let onArchive: (Card) -> Void

    init(card: Card, onArchive: @escaping (Card) -> Void) {
        self.card = card
        self.onArchive = onArchive

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 640),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = card.title.isEmpty ? "Card" : card.title
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: 420, height: 420)
        window.backgroundColor = .windowBackgroundColor

        super.init(window: window)
        window.contentView = makeContent()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present() {
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeContent() -> NSView {
        let root = NSView()

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        root.addSubview(scrollView)

        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
        content.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        content.translatesAutoresizingMaskIntoConstraints = false

        let documentView = FlippedView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(content)
        scrollView.documentView = documentView

        // For image cards the asset is the actual content, so show it. Markdown
        // cards used to render a poster image mirroring iOS; that's dropped on
        // Mac in favor of the native title + body text below.
        if card.kind == .image,
           let url = CardStore.shared.posterURL(for: card),
           let image = NSImage(contentsOf: url) {
            let imageView = NSImageView()
            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.image = image
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.wantsLayer = true
            imageView.layer?.cornerRadius = 16
            imageView.layer?.cornerCurve = .continuous
            imageView.layer?.masksToBounds = true
            content.addArrangedSubview(imageView)
            NSLayoutConstraint.activate([
                imageView.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -48),
                imageView.heightAnchor.constraint(equalTo: imageView.widthAnchor, multiplier: 3.0 / 4.0),
            ])
            content.setCustomSpacing(20, after: imageView)
        }

        let titleLabel = NSTextField(labelWithString: card.title)
        titleLabel.font = .systemFont(ofSize: 24, weight: .bold)
        titleLabel.textColor = .labelColor
        titleLabel.maximumNumberOfLines = 0
        titleLabel.lineBreakMode = .byWordWrapping
        titleLabel.cell?.wraps = true
        content.addArrangedSubview(titleLabel)
        titleLabel.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -48).isActive = true

        var meta = card.displayBadge.capitalized
        if let source = card.source, !source.isEmpty { meta += " · created from \(source)" }
        let metaLabel = NSTextField(labelWithString: meta)
        metaLabel.font = .systemFont(ofSize: 13, weight: .regular)
        metaLabel.textColor = Self.accent
        content.addArrangedSubview(metaLabel)

        if !card.tags.isEmpty {
            let tagsLabel = NSTextField(labelWithString: card.tags.map { "#\($0)" }.joined(separator: "  "))
            tagsLabel.font = .systemFont(ofSize: 13, weight: .regular)
            tagsLabel.textColor = .tertiaryLabelColor
            content.addArrangedSubview(tagsLabel)
        }

        if card.kind == .markdown, !card.body.isEmpty {
            content.setCustomSpacing(18, after: card.tags.isEmpty ? metaLabel : content.arrangedSubviews.last!)
            let bodyLabel = NSTextField(wrappingLabelWithString: card.body)
            bodyLabel.font = .systemFont(ofSize: 15, weight: .regular)
            bodyLabel.textColor = .labelColor
            bodyLabel.isSelectable = true
            content.addArrangedSubview(bodyLabel)
            bodyLabel.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -48).isActive = true
        }

        // Action bar pinned to the bottom.
        let archiveButton = NSButton(title: "Archive", target: self, action: #selector(archiveTapped))
        archiveButton.bezelStyle = .rounded
        archiveButton.contentTintColor = Self.accent
        let doneButton = NSButton(title: "Done", target: self, action: #selector(doneTapped))
        doneButton.bezelStyle = .rounded
        doneButton.keyEquivalent = "\r"

        let actionBar = NSStackView(views: [NSView(), archiveButton, doneButton])
        actionBar.orientation = .horizontal
        actionBar.spacing = 12
        actionBar.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(actionBar)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: actionBar.topAnchor, constant: -10),

            content.topAnchor.constraint(equalTo: documentView.topAnchor),
            content.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.widthAnchor),

            actionBar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            actionBar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            actionBar.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
        ])

        return root
    }

    @objc private func archiveTapped() {
        let alert = NSAlert()
        alert.messageText = "Archive this card?"
        alert.informativeText = card.title.isEmpty
            ? "This card will be moved to your archive."
            : "“\(card.title)” will be moved to your archive."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Archive")
        alert.addButton(withTitle: "Cancel")

        let respond: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            self.onArchive(self.card)
            self.window?.close()
        }

        if let window {
            alert.beginSheetModal(for: window, completionHandler: respond)
        } else {
            respond(alert.runModal())
        }
    }

    @objc private func doneTapped() {
        window?.close()
    }
}

#endif
