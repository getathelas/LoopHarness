//
//  SSHSettingsWindowController.swift
//  LoopMac
//
//  "Settings ▸ SSH…" — the Mac counterpart to iOS's Settings → SSH
//  (`SSHConnectionsVC` + `SSHSettingsVC`). A master/detail window: the list of
//  saved SSH connections on the left, a per-connection editor on the right.
//  The checkmarked row is the *active* connection — the one the `ssh_client`
//  skill and background handoffs use. Everything persists through the shared,
//  cross-platform `SSHConfigStore`, so connections sync with the iOS app.
//
//  Secrets are write-only: once a private key is saved it's never read back
//  into the field. Editing a connection with a stored key shows a masked hint;
//  leave the key box blank to keep it, or type a new one to replace it.
//

import AppKit

final class SSHSettingsWindowController: NSWindowController {

    static let shared = SSHSettingsWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "SSH"
        window.minSize = NSSize(width: 620, height: 380)
        window.center()
        window.contentViewController = SSHSettingsViewController()
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - View controller

private final class SSHSettingsViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()

    // Detail form fields.
    private let nameField = SSHSettingsViewController.makeField(placeholder: "Name (e.g. prod-nyc1)")
    private let hostField = SSHSettingsViewController.makeField(placeholder: "Host (e.g. 192.168.1.10)")
    private let portField = SSHSettingsViewController.makeField(placeholder: "22")
    private let usernameField = SSHSettingsViewController.makeField(placeholder: "Username")
    private let privateKeyView = NSTextView()
    private let keyHintLabel = NSTextField(labelWithString: "")
    private let passphraseField = NSSecureTextField()
    private let statusLabel = NSTextField(labelWithString: "")
    private let statusDot = NSView()
    private let spinner = NSProgressIndicator()
    private let makeActiveButton = NSButton(title: "Make Active", target: nil, action: nil)
    private let testButton = NSButton(title: "Test Connection", target: nil, action: nil)
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private let detailStack = NSStackView()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "No SSH connections.\nClick + to add one.")

    private var connections: [SSHConfig] = []
    /// The connection currently loaded into the detail form (nil ⇒ nothing
    /// selected). We keep the full `SSHConfig` so an untouched key survives a save.
    private var editingID: UUID?
    /// True when the loaded connection already has a stored private key.
    private var savedKeyPresent = false
    /// True once the user has typed into the private-key box this edit.
    private var keyFieldEdited = false

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: 480))

        // ---- Left: connections list ----
        tableView.style = .inset
        tableView.headerView = nil
        tableView.rowHeight = 44
        tableView.allowsMultipleSelection = false
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.doubleAction = #selector(makeActiveClicked)
        tableView.target = self
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("SSHConn"))
        col.resizingMask = .autoresizingMask
        tableView.addTableColumn(col)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let addRemove = NSSegmentedControl(
            images: [
                NSImage(systemSymbolName: "plus", accessibilityDescription: "Add")!,
                NSImage(systemSymbolName: "minus", accessibilityDescription: "Remove")!,
            ],
            trackingMode: .momentary, target: self, action: #selector(addRemoveClicked))
        addRemove.segmentStyle = .smallSquare
        addRemove.translatesAutoresizingMaskIntoConstraints = false
        addRemove.setWidth(30, forSegment: 0)
        addRemove.setWidth(30, forSegment: 1)

        emptyLabel.alignment = .center
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        let sidebar = NSView()
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(scrollView)
        sidebar.addSubview(addRemove)
        sidebar.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: sidebar.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: addRemove.topAnchor, constant: -4),
            addRemove.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 6),
            addRemove.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -6),
            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: sidebar.leadingAnchor, constant: 12),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: sidebar.trailingAnchor, constant: -12),
        ])

        // ---- Right: editor ----
        let detail = buildDetail()

        // ---- Split ----
        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.translatesAutoresizingMaskIntoConstraints = false
        split.addArrangedSubview(sidebar)
        split.addArrangedSubview(detail)
        split.setHoldingPriority(.defaultLow, forSubviewAt: 1)

        root.addSubview(split)
        NSLayoutConstraint.activate([
            split.topAnchor.constraint(equalTo: root.topAnchor),
            split.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            split.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebar.widthAnchor.constraint(greaterThanOrEqualToConstant: 200),
            detail.widthAnchor.constraint(greaterThanOrEqualToConstant: 360),
        ])

        self.view = root

        NotificationCenter.default.addObserver(
            self, selector: #selector(storeChangedExternally),
            name: SSHConfigStore.didChangeNotification, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    override func viewWillAppear() {
        super.viewWillAppear()
        reload()
        if editingID == nil { selectRow(forID: SSHConfigStore.shared.effectiveSelectedID) }
    }

    // MARK: - Detail form

    private func buildDetail() -> NSView {
        let intro = NSTextField(wrappingLabelWithString: "The checkmarked connection is active — it's used by the ssh_client skill and background handoffs. The private key is kept in your keychain and never shown again after it's saved.")
        intro.font = .systemFont(ofSize: 11)
        intro.textColor = .secondaryLabelColor

        privateKeyView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        privateKeyView.isRichText = false
        privateKeyView.isAutomaticQuoteSubstitutionEnabled = false
        privateKeyView.isAutomaticSpellingCorrectionEnabled = false
        privateKeyView.delegate = self
        let keyScroll = NSScrollView()
        keyScroll.documentView = privateKeyView
        keyScroll.hasVerticalScroller = true
        keyScroll.borderType = .bezelBorder
        keyScroll.translatesAutoresizingMaskIntoConstraints = false
        keyScroll.heightAnchor.constraint(equalToConstant: 110).isActive = true

        keyHintLabel.font = .systemFont(ofSize: 11)
        keyHintLabel.textColor = .secondaryLabelColor
        keyHintLabel.maximumNumberOfLines = 2

        passphraseField.placeholderString = "Passphrase (optional)"
        passphraseField.font = .monospacedSystemFont(ofSize: 13, weight: .regular)

        // Status row.
        statusDot.translatesAutoresizingMaskIntoConstraints = false
        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 5
        statusDot.isHidden = true
        statusDot.widthAnchor.constraint(equalToConstant: 10).isActive = true
        statusDot.heightAnchor.constraint(equalToConstant: 10).isActive = true
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 3
        let statusRow = NSStackView(views: [spinner, statusDot, statusLabel])
        statusRow.orientation = .horizontal
        statusRow.spacing = 6
        statusRow.alignment = .centerY

        makeActiveButton.bezelStyle = .rounded
        makeActiveButton.target = self
        makeActiveButton.action = #selector(makeActiveClicked)
        testButton.bezelStyle = .rounded
        testButton.target = self
        testButton.action = #selector(testClicked)
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        saveButton.target = self
        saveButton.action = #selector(saveClicked)
        let buttonRow = NSStackView(views: [makeActiveButton, NSView(), testButton, saveButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8

        detailStack.orientation = .vertical
        detailStack.alignment = .leading
        detailStack.spacing = 6
        detailStack.translatesAutoresizingMaskIntoConstraints = false
        detailStack.addArrangedSubview(intro)
        detailStack.setCustomSpacing(14, after: intro)
        addRow(label: "Name", field: nameField)
        addRow(label: "Host", field: hostField)
        addRow(label: "Port", field: portField)
        addRow(label: "Username", field: usernameField)
        addRow(label: "Private Key (PEM)", field: keyScroll)
        detailStack.addArrangedSubview(keyHintLabel)
        addRow(label: "Passphrase", field: passphraseField)
        detailStack.setCustomSpacing(14, after: passphraseField)
        detailStack.addArrangedSubview(statusRow)

        // Pin field widths to the stack so they fill the detail pane.
        for f in [nameField, hostField, portField, usernameField, passphraseField] {
            f.translatesAutoresizingMaskIntoConstraints = false
            f.widthAnchor.constraint(equalTo: detailStack.widthAnchor).isActive = true
        }
        keyScroll.widthAnchor.constraint(equalTo: detailStack.widthAnchor).isActive = true

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(detailStack)
        container.addSubview(buttonRow)
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            detailStack.topAnchor.constraint(equalTo: container.topAnchor, constant: 18),
            detailStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            detailStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
            buttonRow.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            buttonRow.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
            buttonRow.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
            buttonRow.topAnchor.constraint(greaterThanOrEqualTo: detailStack.bottomAnchor, constant: 12),
        ])
        return container
    }

    private func addRow(label: String, field: NSView) {
        let lbl = NSTextField(labelWithString: label)
        lbl.font = .systemFont(ofSize: 11, weight: .medium)
        lbl.textColor = .secondaryLabelColor
        detailStack.addArrangedSubview(lbl)
        detailStack.addArrangedSubview(field)
        detailStack.setCustomSpacing(12, after: field)
    }

    // MARK: - Data

    private func reload() {
        connections = SSHConfigStore.shared.connections
        emptyLabel.isHidden = !connections.isEmpty
        tableView.reloadData()
        setDetailEnabled(editingID != nil)
    }

    @objc private func storeChangedExternally() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let keepID = self.editingID
            self.reload()
            self.selectRow(forID: keepID)
        }
    }

    private func selectRow(forID id: UUID?) {
        guard let id, let idx = connections.firstIndex(where: { $0.id == id }) else {
            tableView.deselectAll(nil)
            return
        }
        tableView.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
    }

    private func loadConnection(_ conn: SSHConfig) {
        editingID = conn.id
        nameField.stringValue = conn.name
        hostField.stringValue = conn.host
        portField.stringValue = conn.port == 0 ? "22" : String(conn.port)
        usernameField.stringValue = conn.username
        passphraseField.stringValue = conn.passphrase
        // Never re-display a stored key.
        savedKeyPresent = !conn.privateKey.isEmpty
        keyFieldEdited = false
        privateKeyView.string = ""
        updateKeyHint()
        setDetailEnabled(true)
        clearStatus()
        updateActiveButton()
    }

    private func updateKeyHint() {
        if savedKeyPresent && !keyFieldEdited {
            keyHintLabel.stringValue = "A key is saved for this connection. Leave blank to keep it, or type a new one to replace it."
        } else {
            keyHintLabel.stringValue = "Paste the PEM private key for this host."
        }
    }

    private func updateActiveButton() {
        let isActive = editingID != nil && editingID == SSHConfigStore.shared.effectiveSelectedID
        makeActiveButton.isEnabled = editingID != nil && !isActive
        makeActiveButton.title = isActive ? "Active" : "Make Active"
    }

    private func setDetailEnabled(_ enabled: Bool) {
        for v in [nameField, hostField, portField, usernameField, passphraseField] { v.isEnabled = enabled }
        privateKeyView.isEditable = enabled
        privateKeyView.isSelectable = enabled
        testButton.isEnabled = enabled
        saveButton.isEnabled = enabled
        if !enabled {
            nameField.stringValue = ""; hostField.stringValue = ""; portField.stringValue = ""
            usernameField.stringValue = ""; passphraseField.stringValue = ""; privateKeyView.string = ""
            keyHintLabel.stringValue = ""
            makeActiveButton.isEnabled = false
            makeActiveButton.title = "Make Active"
        }
    }

    /// Assembles the current field values into an `SSHConfig`, preserving a saved
    /// key when the box was left untouched.
    private func currentConfig() -> SSHConfig? {
        guard let id = editingID else { return nil }
        let stored = connections.first { $0.id == id }
        let port = Int(portField.stringValue.trimmingCharacters(in: .whitespaces)) ?? 22
        let host = hostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let typedKey = privateKeyView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        let privateKey = (!keyFieldEdited && savedKeyPresent) ? (stored?.privateKey ?? "") : typedKey
        return SSHConfig(
            id: id,
            name: name.isEmpty ? host : name,
            host: host,
            port: port,
            username: usernameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            privateKey: privateKey,
            passphrase: passphraseField.stringValue)
    }

    @discardableResult
    private func persist() -> SSHConfig? {
        guard let config = currentConfig() else { return nil }
        SSHConfigStore.shared.addOrUpdate(config)
        let keep = editingID
        reload()
        selectRow(forID: keep)
        return config
    }

    // MARK: - Actions

    @objc private func addRemoveClicked(_ sender: NSSegmentedControl) {
        if sender.selectedSegment == 0 { addConnection() } else { deleteSelected() }
    }

    private func addConnection() {
        // Persist a fresh empty connection, then select it for editing.
        let conn = SSHConfig(name: "New Connection")
        SSHConfigStore.shared.addOrUpdate(conn)
        reload()
        selectRow(forID: conn.id)
        loadConnection(conn)
        view.window?.makeFirstResponder(nameField)
    }

    private func deleteSelected() {
        guard let id = editingID else { return }
        SSHConfigStore.shared.delete(id: id)
        editingID = nil
        reload()
        selectRow(forID: SSHConfigStore.shared.effectiveSelectedID)
        if let sel = SSHConfigStore.shared.effectiveSelectedID,
           let conn = connections.first(where: { $0.id == sel }) {
            loadConnection(conn)
        }
    }

    @objc private func makeActiveClicked() {
        guard let id = editingID else { return }
        // Save any pending edits first so the active connection is current.
        persist()
        SSHConfigStore.shared.select(id: id)
        reload()
        selectRow(forID: id)
        updateActiveButton()
    }

    @objc private func saveClicked() {
        guard let config = persist() else { return }
        savedKeyPresent = !config.privateKey.isEmpty
        keyFieldEdited = false
        privateKeyView.string = ""
        updateKeyHint()

        guard config.isConfigured else {
            setStatus(.failed("Enter host, username, and private key to connect."))
            return
        }
        if !SSHConfigStore.shared.privateKeyPersists(id: config.id) {
            let st = SSHConfigStore.shared.lastKeyWriteStatus
            setStatus(.failed("Couldn't save the private key to the keychain (status \(st))."))
            return
        }
        runTest(config)
    }

    @objc private func testClicked() {
        guard let config = persist() else { return }
        guard config.isConfigured else {
            setStatus(.failed("Enter host, username, and private key to connect."))
            return
        }
        runTest(config)
    }

    private func runTest(_ config: SSHConfig) {
        setStatus(.checking)
        Task { @MainActor in
            do {
                try await SSHSkill.shared.testConnection(config)
                self.setStatus(.connected)
            } catch {
                self.setStatus(.failed("Could not connect: \(error.localizedDescription)"))
            }
        }
    }

    // MARK: - Status

    private enum ConnState { case checking, connected, failed(String) }

    private func clearStatus() {
        spinner.stopAnimation(nil)
        statusDot.isHidden = true
        statusLabel.stringValue = ""
    }

    private func setStatus(_ state: ConnState) {
        switch state {
        case .checking:
            statusDot.isHidden = true
            spinner.startAnimation(nil)
            statusLabel.stringValue = "Checking connection…"
            statusLabel.textColor = .secondaryLabelColor
        case .connected:
            spinner.stopAnimation(nil)
            statusDot.isHidden = false
            statusDot.layer?.backgroundColor = NSColor.systemGreen.cgColor
            statusLabel.stringValue = "Connected"
            statusLabel.textColor = .labelColor
        case .failed(let msg):
            spinner.stopAnimation(nil)
            statusDot.isHidden = false
            statusDot.layer?.backgroundColor = NSColor.systemRed.cgColor
            statusLabel.stringValue = msg
            statusLabel.textColor = .labelColor
        }
    }

    // MARK: - NSTableView

    func numberOfRows(in tableView: NSTableView) -> Int { connections.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let conn = connections[row]
        let cell = ConnRowCell.dequeue(in: tableView)
        cell.titleLabel.stringValue = conn.displayName
        cell.subtitleLabel.stringValue = conn.endpointSummary.isEmpty ? "Not configured" : conn.endpointSummary
        cell.setActive(conn.id == SSHConfigStore.shared.effectiveSelectedID)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard row >= 0, row < connections.count else { return }
        loadConnection(connections[row])
    }

    // MARK: - Field factory

    private static func makeField(placeholder: String) -> NSTextField {
        let f = NSTextField()
        f.placeholderString = placeholder
        f.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        f.lineBreakMode = .byTruncatingTail
        f.maximumNumberOfLines = 1
        return f
    }
}

extension SSHSettingsViewController: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        if !privateKeyView.string.isEmpty { keyFieldEdited = true }
        updateKeyHint()
    }
}

// MARK: - Row cell

/// Shared two-line list cell with a leading checkmark for the active row. Reused
/// by both the SSH and Execution Backend windows.
final class ConnRowCell: NSTableCellView {
    let titleLabel = NSTextField(labelWithString: "")
    let subtitleLabel = NSTextField(labelWithString: "")
    let glyph = NSImageView()
    let checkmark = NSImageView()

    static func dequeue(in tableView: NSTableView) -> ConnRowCell {
        let id = NSUserInterfaceItemIdentifier("ConnRowCell")
        if let reused = tableView.makeView(withIdentifier: id, owner: nil) as? ConnRowCell { return reused }
        let cell = ConnRowCell()
        cell.identifier = id
        return cell
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }
    required init?(coder: NSCoder) { super.init(coder: coder); setup() }

    private func setup() {
        glyph.translatesAutoresizingMaskIntoConstraints = false
        glyph.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)
        glyph.contentTintColor = .secondaryLabelColor
        addSubview(glyph)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)

        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail
        addSubview(subtitleLabel)

        checkmark.translatesAutoresizingMaskIntoConstraints = false
        checkmark.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Active")
        checkmark.contentTintColor = .controlAccentColor
        checkmark.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        checkmark.isHidden = true
        addSubview(checkmark)

        NSLayoutConstraint.activate([
            glyph.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
            glyph.widthAnchor.constraint(equalToConstant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: 8),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: checkmark.leadingAnchor, constant: -6),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 1),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: checkmark.leadingAnchor, constant: -6),
            checkmark.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            checkmark.centerYAnchor.constraint(equalTo: centerYAnchor),
            checkmark.widthAnchor.constraint(equalToConstant: 14),
        ])
    }

    func setSymbol(_ name: String) {
        glyph.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }

    func setActive(_ active: Bool) {
        checkmark.isHidden = !active
        titleLabel.font = active ? .systemFont(ofSize: 13, weight: .semibold) : .systemFont(ofSize: 13)
    }
}
