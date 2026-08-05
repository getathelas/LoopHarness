//
//  CodexWindows.swift
//  LoopMac
//
//  Native Mac management surfaces for the Codex CLI integration: a project
//  registry/status window and a lightweight persisted job detail window.
//

import AppKit

final class CodexIntegrationWindowController: NSWindowController,
                                               NSTableViewDataSource,
                                               NSTableViewDelegate {
    static let shared = CodexIntegrationWindowController()

    private let statusLabel = NSTextField(labelWithString: "Checking Codex…")
    private let executableField = NSTextField()
    private let tableView = NSTableView()
    private var projects: [CodexProject] = []

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 430),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Codex Projects"
        window.minSize = NSSize(width: 560, height: 340)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        configure()
        NotificationCenter.default.addObserver(
            self, selector: #selector(projectsDidChange), name: .codexProjectsDidChange, object: nil
        )
    }

    required init?(coder: NSCoder) { fatalError() }
    deinit { NotificationCenter.default.removeObserver(self) }

    func show() {
        reload()
        checkStatus()
        showWindow(nil)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func configure() {
        guard let window else { return }
        let content = NSView()

        let heading = NSTextField(labelWithString: "Local Codex agents")
        heading.font = .systemFont(ofSize: 17, weight: .semibold)
        heading.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(heading)

        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(statusLabel)

        let executableLabel = NSTextField(labelWithString: "CLI path")
        executableLabel.font = .systemFont(ofSize: 11, weight: .medium)
        executableLabel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(executableLabel)

        executableField.placeholderString = "Auto-detect Codex CLI"
        executableField.stringValue = UserDefaults.standard.string(forKey: "loop.codex.executablePath") ?? ""
        executableField.translatesAutoresizingMaskIntoConstraints = false
        executableField.target = self
        executableField.action = #selector(saveExecutablePath)
        content.addSubview(executableField)

        let saveButton = NSButton(title: "Save & Check", target: self, action: #selector(saveExecutablePath))
        saveButton.bezelStyle = .rounded
        saveButton.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(saveButton)

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        content.addSubview(scroll)

        let nameColumn = NSTableColumn(identifier: .init("name"))
        nameColumn.title = "Project"
        nameColumn.width = 150
        let pathColumn = NSTableColumn(identifier: .init("path"))
        pathColumn.title = "Path"
        pathColumn.width = 390
        let accessColumn = NSTableColumn(identifier: .init("access"))
        accessColumn.title = "Access"
        accessColumn.width = 100
        [nameColumn, pathColumn, accessColumn].forEach(tableView.addTableColumn)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = false
        scroll.documentView = tableView

        let addButton = NSButton(title: "Add Project…", target: self, action: #selector(addProject))
        let refreshButton = NSButton(title: "Discover from Codex", target: self, action: #selector(refreshProjects))
        let accessButton = NSButton(title: "Toggle Write Access", target: self, action: #selector(toggleAccess))
        let removeButton = NSButton(title: "Remove", target: self, action: #selector(removeProject))
        let buttons = NSStackView(views: [addButton, refreshButton, accessButton, removeButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(buttons)

        let footnote = NSTextField(wrappingLabelWithString:
            "Projects discovered from Codex start read-only. Enable write access explicitly before Loop can dispatch an agent that changes files. Loop never requests unrestricted filesystem access."
        )
        footnote.font = .systemFont(ofSize: 11)
        footnote.textColor = .secondaryLabelColor
        footnote.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(footnote)

        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            heading.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            statusLabel.leadingAnchor.constraint(equalTo: heading.trailingAnchor, constant: 12),
            statusLabel.centerYAnchor.constraint(equalTo: heading.centerYAnchor),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),

            executableLabel.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 16),
            executableLabel.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            executableLabel.centerYAnchor.constraint(equalTo: executableField.centerYAnchor),
            executableField.leadingAnchor.constraint(equalTo: executableLabel.trailingAnchor, constant: 10),
            executableField.trailingAnchor.constraint(equalTo: saveButton.leadingAnchor, constant: -8),
            saveButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            saveButton.centerYAnchor.constraint(equalTo: executableField.centerYAnchor),

            scroll.topAnchor.constraint(equalTo: executableField.bottomAnchor, constant: 14),
            scroll.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            scroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -12),

            buttons.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            buttons.bottomAnchor.constraint(equalTo: footnote.topAnchor, constant: -12),
            footnote.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            footnote.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            footnote.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16)
        ])
        window.contentView = content
    }

    @objc private func projectsDidChange() { reload() }

    private func reload() {
        projects = CodexAgentService.shared.projects()
        tableView.reloadData()
    }

    private func checkStatus() {
        statusLabel.stringValue = "Checking Codex…"
        CodexAgentService.shared.status { [weak self] status in
            self?.statusLabel.stringValue = status
        }
    }

    @objc private func saveExecutablePath() {
        let path = executableField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.isEmpty { UserDefaults.standard.removeObject(forKey: "loop.codex.executablePath") }
        else { UserDefaults.standard.set(path, forKey: "loop.codex.executablePath") }
        CodexAppServerClient.shared.stop()
        checkStatus()
    }

    @objc private func addProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Project"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let alert = NSAlert()
        alert.messageText = "Allow Codex to change files?"
        alert.informativeText = "Read-only is safest and is enough for audits, explanations, and planning. You can enable writes later."
        alert.addButton(withTitle: "Read Only")
        alert.addButton(withTitle: "Allow Writes")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        guard response != .alertThirdButtonReturn else { return }
        let result = CodexAgentService.shared.addProject(
            path: url.path,
            allowWrites: response == .alertSecondButtonReturn
        )
        if case .failure(let error) = result { showError(error.localizedDescription) }
    }

    @objc private func refreshProjects() {
        statusLabel.stringValue = "Discovering projects…"
        CodexAgentService.shared.refreshProjects { [weak self] result in
            switch result {
            case .success(let projects): self?.statusLabel.stringValue = "Found \(projects.count) project(s)"
            case .failure(let error): self?.showError(error.localizedDescription); self?.checkStatus()
            }
            self?.reload()
        }
    }

    @objc private func toggleAccess() {
        guard tableView.selectedRow >= 0, tableView.selectedRow < projects.count else { return }
        let project = projects[tableView.selectedRow]
        _ = CodexAgentService.shared.addProject(
            path: project.path,
            name: project.name,
            allowWrites: project.defaultAccess != .workspaceWrite
        )
    }

    @objc private func removeProject() {
        guard tableView.selectedRow >= 0, tableView.selectedRow < projects.count else { return }
        if case .failure(let error) = CodexAgentService.shared.removeProject(id: projects[tableView.selectedRow].id) {
            showError(error.localizedDescription)
        }
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Codex integration"
        alert.informativeText = message
        alert.runModal()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { projects.count }

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard projects.indices.contains(row), let tableColumn else { return nil }
        let id = NSUserInterfaceItemIdentifier("CodexProjectCell")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView ?? NSTableCellView()
        cell.identifier = id
        let label = cell.textField ?? NSTextField(labelWithString: "")
        if cell.textField == nil {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.lineBreakMode = .byTruncatingMiddle
            cell.addSubview(label)
            cell.textField = label
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }
        let project = projects[row]
        switch tableColumn.identifier.rawValue {
        case "name": label.stringValue = project.name
        case "path": label.stringValue = project.path
        default: label.stringValue = project.defaultAccess.displayName
        }
        return cell
    }
}

final class CodexAgentDetailWindowController: NSWindowController {
    private static var open: [String: CodexAgentDetailWindowController] = [:]

    static func show(agentId: String) {
        if let existing = open[agentId] {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = CodexAgentDetailWindowController(agentId: agentId)
        open[agentId] = controller
        controller.showWindow(nil)
        controller.window?.center()
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private let agentId: String
    private let heading = NSTextField(labelWithString: "")
    private let status = NSTextField(labelWithString: "")
    private let textView = NSTextView()
    private let actionButton = NSButton()

    private init(agentId: String) {
        self.agentId = agentId
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 500),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Codex Agent"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        configure()
        NotificationCenter.default.addObserver(
            self, selector: #selector(reload), name: .codexAgentsDidChange, object: nil
        )
        reload()
    }

    required init?(coder: NSCoder) { fatalError() }
    deinit { NotificationCenter.default.removeObserver(self) }

    private func configure() {
        guard let window else { return }
        let content = NSView()
        heading.font = .systemFont(ofSize: 15, weight: .semibold)
        heading.lineBreakMode = .byTruncatingTail
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        for view in [heading, status] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        textView.isEditable = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 10, height: 10)
        scroll.documentView = textView
        content.addSubview(scroll)
        actionButton.target = self
        actionButton.action = #selector(action)
        actionButton.bezelStyle = .rounded
        actionButton.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(actionButton)
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            heading.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            heading.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            status.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 3),
            status.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: actionButton.topAnchor, constant: -12),
            actionButton.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
            actionButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14)
        ])
        window.contentView = content
    }

    @objc private func reload() {
        guard let job = CodexAgentService.shared.job(id: agentId) else { return }
        heading.stringValue = job.displayTitle
        let project = URL(fileURLWithPath: job.projectPath).lastPathComponent
        status.stringValue = "\(project) · \(job.state.rawValue.capitalized) · \(job.access.displayName) · \(job.currentStep)"
        let log = job.logs.map { "[\(Self.time.string(from: $0.date))] \($0.summary)" }.joined(separator: "\n")
        var sections = ["TASK\n\(job.task)", "ACTIVITY\n\(log)"]
        if let response = job.finalResponse { sections.append("RESULT\n\(response)") }
        if let error = job.error { sections.append("ERROR\n\(error)") }
        textView.string = sections.joined(separator: "\n\n")
        actionButton.title = job.isTerminal ? "Continue…" : "Cancel Agent"
    }

    @objc private func action() {
        guard let job = CodexAgentService.shared.job(id: agentId) else { return }
        if job.isTerminal {
            let alert = NSAlert()
            alert.messageText = "Continue Codex agent"
            alert.informativeText = "Enter a follow-up instruction for the same Codex thread."
            alert.addButton(withTitle: "Continue")
            alert.addButton(withTitle: "Cancel")
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 420, height: 24))
            alert.accessoryView = field
            guard alert.runModal() == .alertFirstButtonReturn,
                  !field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            CodexAgentService.shared.continueAgent(id: agentId, instruction: field.stringValue) { _ in }
        } else {
            CodexAgentService.shared.cancel(id: agentId) { _ in }
        }
    }

    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

extension CodexAgentDetailWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        Self.open.removeValue(forKey: agentId)
    }
}
