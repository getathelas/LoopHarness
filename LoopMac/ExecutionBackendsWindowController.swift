//
//  ExecutionBackendsWindowController.swift
//  LoopMac
//
//  "Settings ▸ Execution Backend…" — the Mac counterpart to iOS's
//  Settings → Execution Backend (`ExecutionBackendVC` + `ExecutionBackendEditVC`).
//  A master/detail window listing the backends Loop can run from: the built-in
//  **Local** backend (always present, can't be deleted) plus any remote SSH VM
//  backends the user adds. The checkmarked row is the *active* backend — where
//  new conversations are created.
//
//  Selecting Local takes effect immediately. A remote becomes active only once
//  it's configured and a connection check passes ("Save & Validate"). Everything
//  persists through the shared, cross-platform `ExecutionBackendStore`; secrets
//  live in the Keychain and are never shown again after they're saved.
//

import AppKit

final class ExecutionBackendsWindowController: NSWindowController {

    static let shared = ExecutionBackendsWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 740, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Execution Backend"
        window.minSize = NSSize(width: 640, height: 420)
        window.center()
        window.contentViewController = ExecutionBackendsViewController()
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

private final class ExecutionBackendsViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()

    private let nameField = ExecutionBackendsViewController.makeField(placeholder: "Name (e.g. prod-nyc1)")
    private let hostField = ExecutionBackendsViewController.makeField(placeholder: "Host (e.g. vm.example.com)")
    private let portField = ExecutionBackendsViewController.makeField(placeholder: "22")
    private let usernameField = ExecutionBackendsViewController.makeField(placeholder: "Username")
    private let privateKeyView = NSTextView()
    private let keyHintLabel = NSTextField(labelWithString: "")
    private let passphraseField = NSSecureTextField()
    private let workspaceField = ExecutionBackendsViewController.makeField(placeholder: "~/loop-workspace")
    private let agentField = ExecutionBackendsViewController.makeField(placeholder: "main")

    private let statusLabel = NSTextField(labelWithString: "")
    private let statusDot = NSView()
    private let spinner = NSProgressIndicator()
    private let saveButton = NSButton(title: "Save & Validate", target: nil, action: nil)
    private let detailStack = NSStackView()
    private let localNotice = NSTextField(wrappingLabelWithString: "")

    private var backends: [ExecutionBackend] = []
    /// Backend currently loaded into the form (nil ⇒ nothing selected).
    private var editingID: String?
    private var savedKeyPresent = false
    private var keyFieldEdited = false

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 740, height: 540))

        // ---- Left: backend list ----
        tableView.style = .inset
        tableView.headerView = nil
        tableView.rowHeight = 44
        tableView.allowsMultipleSelection = false
        tableView.dataSource = self
        tableView.delegate = self
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Backend"))
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

        let sidebar = NSView()
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(scrollView)
        sidebar.addSubview(addRemove)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: sidebar.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: addRemove.topAnchor, constant: -4),
            addRemove.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 6),
            addRemove.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -6),
        ])

        // ---- Right: editor ----
        let detail = buildDetail()

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
            sidebar.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
            detail.widthAnchor.constraint(greaterThanOrEqualToConstant: 380),
        ])

        self.view = root

        NotificationCenter.default.addObserver(
            self, selector: #selector(storeChangedExternally),
            name: ExecutionBackendStore.didChangeNotification, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    override func viewWillAppear() {
        super.viewWillAppear()
        reload()
        if editingID == nil { selectRow(forID: ExecutionBackendStore.shared.selectedBackendID) }
    }

    // MARK: - Detail form

    private func buildDetail() -> NSView {
        let intro = NSTextField(wrappingLabelWithString: "Loop drives the OpenClaw agent on a remote VM: conversations come from the agent's sessions and new messages run the agent over SSH. The workspace path is used for the Files and Skills tabs. Save & Validate connects, and on success makes this backend active.")
        intro.font = .systemFont(ofSize: 11)
        intro.textColor = .secondaryLabelColor

        localNotice.stringValue = "Local runs Loop on this Mac, storing conversations on-device and in iCloud. It's always available and can't be removed or edited. Click “Make Active” to run new conversations here."
        localNotice.font = .systemFont(ofSize: 12)
        localNotice.textColor = .secondaryLabelColor
        localNotice.isHidden = true

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
        keyScroll.heightAnchor.constraint(equalToConstant: 100).isActive = true

        keyHintLabel.font = .systemFont(ofSize: 11)
        keyHintLabel.textColor = .secondaryLabelColor
        keyHintLabel.maximumNumberOfLines = 2

        passphraseField.placeholderString = "Passphrase (optional)"
        passphraseField.font = .monospacedSystemFont(ofSize: 13, weight: .regular)

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

        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        saveButton.target = self
        saveButton.action = #selector(saveClicked)
        let buttonRow = NSStackView(views: [NSView(), saveButton])
        buttonRow.orientation = .horizontal

        detailStack.orientation = .vertical
        detailStack.alignment = .leading
        detailStack.spacing = 6
        detailStack.translatesAutoresizingMaskIntoConstraints = false
        detailStack.addArrangedSubview(intro)
        detailStack.addArrangedSubview(localNotice)
        detailStack.setCustomSpacing(14, after: intro)
        addRow(label: "Name", field: nameField)
        addRow(label: "Host", field: hostField)
        addRow(label: "Port", field: portField)
        addRow(label: "Username", field: usernameField)
        addRow(label: "Private Key (PEM)", field: keyScroll)
        detailStack.addArrangedSubview(keyHintLabel)
        addRow(label: "Passphrase", field: passphraseField)
        addRow(label: "Workspace Path", field: workspaceField)
        addRow(label: "Agent ID", field: agentField)
        detailStack.setCustomSpacing(14, after: agentField)
        detailStack.addArrangedSubview(statusRow)

        for f in [nameField, hostField, portField, usernameField, passphraseField, workspaceField, agentField] {
            f.translatesAutoresizingMaskIntoConstraints = false
            f.widthAnchor.constraint(equalTo: detailStack.widthAnchor).isActive = true
        }
        keyScroll.widthAnchor.constraint(equalTo: detailStack.widthAnchor).isActive = true
        localNotice.widthAnchor.constraint(equalTo: detailStack.widthAnchor).isActive = true

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let doc = NSView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(detailStack)
        NSLayoutConstraint.activate([
            detailStack.topAnchor.constraint(equalTo: doc.topAnchor, constant: 18),
            detailStack.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 18),
            detailStack.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -18),
            detailStack.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -18),
        ])
        scroll.documentView = doc

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scroll)
        container.addSubview(buttonRow)
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            doc.widthAnchor.constraint(equalTo: scroll.widthAnchor),
            buttonRow.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 8),
            buttonRow.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            buttonRow.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
            buttonRow.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
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
        // Track the label so we can hide the whole row for the Local backend.
        fieldLabels[field] = lbl
    }

    /// Maps each editable field to its caption label, so the Local backend can
    /// hide the entire form (it has nothing to configure).
    private var fieldLabels: [NSView: NSTextField] = [:]

    // MARK: - Data

    private func reload() {
        backends = ExecutionBackendStore.shared.backends
        tableView.reloadData()
    }

    @objc private func storeChangedExternally() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let keep = self.editingID
            self.reload()
            self.selectRow(forID: keep)
        }
    }

    private func selectRow(forID id: String?) {
        guard let id, let idx = backends.firstIndex(where: { $0.id == id }) else {
            tableView.deselectAll(nil); return
        }
        tableView.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
    }

    private func loadBackend(_ backend: ExecutionBackend) {
        editingID = backend.id
        clearStatus()
        if backend.isLocal {
            setFormHidden(true)
            // Reflect whether Local is the active backend.
            if backend.id == ExecutionBackendStore.shared.selectedBackendID {
                saveButton.title = "Active"
                saveButton.isEnabled = false
            } else {
                saveButton.title = "Make Active"
                saveButton.isEnabled = true
            }
            return
        }

        setFormHidden(false)
        saveButton.title = "Save & Validate"
        saveButton.isEnabled = true
        let cfg = backend.config
        nameField.stringValue = backend.name
        hostField.stringValue = cfg.host
        portField.stringValue = cfg.port == 0 ? "22" : String(cfg.port)
        usernameField.stringValue = cfg.username
        workspaceField.stringValue = cfg.workspacePath
        agentField.stringValue = cfg.agentId
        passphraseField.stringValue = ""
        savedKeyPresent = !cfg.privateKey.isEmpty
        keyFieldEdited = false
        privateKeyView.string = ""
        updateKeyHint()
    }

    private func setFormHidden(_ hidden: Bool) {
        localNotice.isHidden = !hidden
        let fields: [NSView] = [nameField, hostField, portField, usernameField,
                                passphraseField, workspaceField, agentField]
        for f in fields {
            f.isHidden = hidden
            fieldLabels[f]?.isHidden = hidden
        }
        keyHintLabel.isHidden = hidden
        // The key box lives in a scroll view (its superview chain); hide the row label.
        for (view, label) in fieldLabels where label.stringValue == "Private Key (PEM)" {
            view.isHidden = hidden
        }
        privateKeyView.enclosingScrollView?.isHidden = hidden
    }

    private func updateKeyHint() {
        if savedKeyPresent && !keyFieldEdited {
            keyHintLabel.stringValue = "A key is saved for this backend. Leave blank to keep it, or type a new one to replace it."
        } else {
            keyHintLabel.stringValue = "Paste the PEM private key for this VM."
        }
    }

    private func currentBackend() -> ExecutionBackend? {
        guard let id = editingID else { return nil }
        let stored = backends.first { $0.id == id }
        let port = Int(portField.stringValue.trimmingCharacters(in: .whitespaces)) ?? 22
        let host = hostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let typedKey = privateKeyView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        let privateKey = (!keyFieldEdited && savedKeyPresent) ? (stored?.config.privateKey ?? "") : typedKey
        let typedPass = passphraseField.stringValue
        let hadPass = !(stored?.config.passphrase.isEmpty ?? true)
        let passphrase = typedPass.isEmpty && hadPass ? (stored?.config.passphrase ?? "") : typedPass
        let config = OpenClawConfig(
            host: host,
            port: port,
            username: usernameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            privateKey: privateKey,
            passphrase: passphrase,
            workspacePath: workspaceField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            agentId: agentField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        return ExecutionBackend(id: id, name: name.isEmpty ? host : name, config: config)
    }

    // MARK: - Actions

    @objc private func addRemoveClicked(_ sender: NSSegmentedControl) {
        if sender.selectedSegment == 0 { addBackend() } else { deleteSelected() }
    }

    private func addBackend() {
        let backend = ExecutionBackendStore.shared.addOrUpdate(ExecutionBackend(name: "New Backend"))
        reload()
        selectRow(forID: backend.id)
        loadBackend(backend)
        view.window?.makeFirstResponder(nameField)
    }

    private func deleteSelected() {
        guard let id = editingID, id != ExecutionBackend.localID else { return }
        ExecutionBackendStore.shared.delete(id: id)
        editingID = nil
        reload()
        selectRow(forID: ExecutionBackendStore.shared.selectedBackendID)
        if let b = ExecutionBackendStore.shared.backend(id: ExecutionBackendStore.shared.selectedBackendID) {
            loadBackend(b)
        }
    }

    @objc private func saveClicked() {
        guard let id = editingID else { return }

        // Local: the button just activates it.
        if id == ExecutionBackend.localID {
            ExecutionBackendStore.shared.select(id: ExecutionBackend.localID)
            reload(); selectRow(forID: id); loadBackend(.local)
            return
        }

        guard let draft = currentBackend() else { return }
        let backend = ExecutionBackendStore.shared.addOrUpdate(draft)
        savedKeyPresent = !backend.config.privateKey.isEmpty
        keyFieldEdited = false
        privateKeyView.string = ""
        updateKeyHint()
        reload(); selectRow(forID: backend.id)

        guard backend.config.isConfigured else {
            ExecutionBackendStore.shared.setValidated(false, for: backend.id)
            setStatus(.failed("Enter host, username, private key, and workspace path to connect."))
            return
        }

        setStatus(.checking)
        let config = backend.config
        Task { @MainActor in
            do {
                let summary = try await OpenClawConversationStore.validate(config)
                ExecutionBackendStore.shared.setValidated(true, for: id)
                ExecutionBackendStore.shared.select(id: id)
                self.setStatus(.connected(summary))
                self.reload(); self.selectRow(forID: id)
            } catch {
                ExecutionBackendStore.shared.setValidated(false, for: id)
                self.setStatus(.failed("Could not connect: \(error.localizedDescription)"))
                self.reload(); self.selectRow(forID: id)
            }
        }
    }

    // MARK: - Status

    private enum ConnState { case checking, connected(String), failed(String) }

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
            statusLabel.stringValue = "Validating connection…"
            statusLabel.textColor = .secondaryLabelColor
        case .connected(let detail):
            spinner.stopAnimation(nil)
            statusDot.isHidden = false
            statusDot.layer?.backgroundColor = NSColor.systemGreen.cgColor
            statusLabel.stringValue = "Connected — \(detail)"
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

    func numberOfRows(in tableView: NSTableView) -> Int { backends.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let backend = backends[row]
        let store = ExecutionBackendStore.shared
        let cell = ConnRowCell.dequeue(in: tableView)
        cell.titleLabel.stringValue = backend.displayName
        cell.setSymbol(backend.isLocal ? "internaldrive" : "externaldrive.badge.icloud")

        if backend.isLocal {
            cell.subtitleLabel.stringValue = backend.subtitle
        } else if !backend.config.isConfigured {
            cell.subtitleLabel.stringValue = "Tap to configure"
        } else if store.isValidated(id: backend.id) {
            cell.subtitleLabel.stringValue = "\(backend.subtitle) · Connected"
        } else {
            cell.subtitleLabel.stringValue = "\(backend.subtitle) · Not connected"
        }
        cell.setActive(backend.id == store.selectedBackendID)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard row >= 0, row < backends.count else { return }
        loadBackend(backends[row])
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

extension ExecutionBackendsViewController: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        if !privateKeyView.string.isEmpty { keyFieldEdited = true }
        updateKeyHint()
    }
}
