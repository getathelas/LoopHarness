//
//  CodexAgentService.swift
//  LoopMac
//
//  Project registry and durable job coordinator for local Codex agents. It
//  translates Loop operations into app-server thread/turn calls, persists
//  enough state to survive relaunch, and posts a terminal result back into
//  the conversation that dispatched the work exactly once.
//

import AppKit
import Foundation
import UserNotifications

extension Notification.Name {
    static let codexAgentsDidChange = Notification.Name("loop.codex.agentsDidChange")
    static let codexAgentDidPostMessage = Notification.Name("loop.codex.agentDidPostMessage")
    static let codexProjectsDidChange = Notification.Name("loop.codex.projectsDidChange")
}

final class CodexAgentService {
    static let shared = CodexAgentService()

    enum DispatchResult {
        case success(CodexAgentJob)
        case failure(String)
    }

    private let client = CodexAppServerClient.shared
    private let queue = DispatchQueue(label: "loop.codex.agent-service")
    private let projectsKey = "loop.codex.projects.v1"
    private let jobsKey = "loop.codex.jobs.v1"
    private let maxLogs = 100
    private var responseTextByJob: [String: String] = [:]

    private init() {
        client.onNotification = { [weak self] method, params in
            self?.handleNotification(method: method, params: params)
        }
    }

    // MARK: - Availability and account

    func status(completion: @escaping (String) -> Void) {
        guard CodexAppServerClient.isAvailable else {
            completion("Codex CLI not found")
            return
        }
        client.request(method: "account/read", params: ["refreshToken": false]) { result in
            switch result {
            case .failure(let error): completion(error.localizedDescription)
            case .success(let payload):
                if let account = payload["account"] as? [String: Any] {
                    let email = account["email"] as? String
                    let type = account["type"] as? String
                    completion(email ?? type.map { "Connected (\($0))" } ?? "Connected")
                } else {
                    completion("Codex CLI installed; sign-in required")
                }
            }
        }
    }

    // MARK: - Projects

    func projects() -> [CodexProject] {
        queue.sync { loadProjectsUnlocked().sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending } }
    }

    @discardableResult
    func addProject(path: String,
                    name: String? = nil,
                    allowWrites: Bool = false) -> Result<CodexProject, Error> {
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .failure(CodexAppServerError.unavailable("Project directory does not exist: \(url.path)"))
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
            .resolvingSymlinksInPath().standardizedFileURL.path
        guard url.path != "/", url.path != home else {
            return .failure(CodexAppServerError.unavailable(
                "Choose a specific project directory, not the filesystem root or your entire home directory."
            ))
        }
        var saved = CodexProject(path: url.path,
                                 name: name,
                                 defaultAccess: allowWrites ? .workspaceWrite : .readOnly)
        queue.sync {
            var all = loadProjectsUnlocked()
            if let index = all.firstIndex(where: { $0.id == saved.id }) {
                saved.addedAt = all[index].addedAt
                saved.lastUsedAt = all[index].lastUsedAt
                all[index] = saved
            } else {
                all.append(saved)
            }
            saveProjectsUnlocked(all)
        }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .codexProjectsDidChange, object: nil)
        }
        return .success(saved)
    }

    func refreshProjects(completion: @escaping (Result<[CodexProject], Error>) -> Void) {
        let sourceKinds = ["cli", "vscode", "exec", "appServer", "subAgent", "subAgentReview",
                           "subAgentCompact", "subAgentThreadSpawn", "subAgentOther", "unknown"]
        fetchProjectPaths(cursor: nil,
                          pagesRemaining: 10,
                          accumulated: [],
                          sourceKinds: sourceKinds,
                          completion: completion)
    }

    private func fetchProjectPaths(cursor: String?,
                                   pagesRemaining: Int,
                                   accumulated: Set<String>,
                                   sourceKinds: [String],
                                   completion: @escaping (Result<[CodexProject], Error>) -> Void) {
        var params: [String: Any] = [
            "limit": 100,
            "sortKey": "updated_at",
            "sourceKinds": sourceKinds
        ]
        if let cursor { params["cursor"] = cursor }
        client.request(method: "thread/list", params: params) { result in
            switch result {
            case .failure(let error): completion(.failure(error))
            case .success(let payload):
                let threads = payload["data"] as? [[String: Any]] ?? []
                var paths = accumulated
                paths.formUnion(threads.compactMap {
                    ($0["cwd"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                }.filter { !$0.isEmpty })
                if let next = payload["nextCursor"] as? String,
                   !next.isEmpty,
                   pagesRemaining > 1 {
                    self.fetchProjectPaths(cursor: next,
                                           pagesRemaining: pagesRemaining - 1,
                                           accumulated: paths,
                                           sourceKinds: sourceKinds,
                                           completion: completion)
                    return
                }
                for path in paths {
                    _ = self.addProject(path: path)
                }
                completion(.success(self.projects()))
            }
        }
    }

    func project(matching identifier: String) -> CodexProject? {
        let needle = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let standardized = URL(fileURLWithPath: needle)
            .resolvingSymlinksInPath().standardizedFileURL.path
        return projects().first {
            $0.id == needle || $0.path == standardized || $0.name.caseInsensitiveCompare(needle) == .orderedSame
        }
    }

    func removeProject(id: String) -> Result<Void, Error> {
        if allJobs().contains(where: { !$0.isTerminal && $0.projectId == id }) {
            return .failure(CodexAppServerError.unavailable("Stop the running Codex agent before removing this project."))
        }
        var removed = false
        queue.sync {
            var all = loadProjectsUnlocked()
            let before = all.count
            all.removeAll { $0.id == id }
            removed = all.count != before
            if removed { saveProjectsUnlocked(all) }
        }
        guard removed else {
            return .failure(CodexAppServerError.unavailable("Project is no longer registered."))
        }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .codexProjectsDidChange, object: nil)
        }
        return .success(())
    }

    // MARK: - Jobs

    func allJobs() -> [CodexAgentJob] {
        queue.sync { loadJobsUnlocked().sorted { $0.createdAt > $1.createdAt } }
    }

    func job(id: String) -> CodexAgentJob? {
        queue.sync { loadJobsUnlocked().first { $0.id == id || $0.threadId == id } }
    }

    func dispatch(task: String,
                  project: CodexProject,
                  access: CodexAccessMode,
                  conversationId: String,
                  completion: @escaping (DispatchResult) -> Void) {
        guard !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            completion(.failure("task is required")); return
        }
        guard access != .workspaceWrite || project.defaultAccess == .workspaceWrite else {
            completion(.failure("Write access is not enabled for \(project.name). Add or update the project with allow_writes=true first."))
            return
        }
        if access == .workspaceWrite,
           allJobs().contains(where: { !$0.isTerminal && $0.projectId == project.id && $0.access == .workspaceWrite }) {
            completion(.failure("A write-enabled Codex agent is already running in \(project.name). Wait for it to finish or cancel it before starting another."))
            return
        }

        let now = Date()
        var job = CodexAgentJob(
            id: UUID().uuidString,
            threadId: nil,
            turnId: nil,
            conversationId: conversationId,
            projectId: project.id,
            projectPath: project.path,
            task: task,
            access: access,
            state: .queued,
            currentStep: "Starting Codex",
            createdAt: now,
            updatedAt: now,
            finalResponse: nil,
            error: nil,
            postedBack: false,
            logs: [CodexAgentLogEntry("Queued for \(project.name) (\(access.displayName))")]
        )
        upsert(job)

        client.request(method: "thread/start", params: [
            "cwd": project.path,
            "approvalPolicy": "never",
            "sandbox": access.rawValue,
            "developerInstructions": "This turn is unattended. Do not ask the user questions or request expanded permissions. Use best judgment within the configured sandbox, and explain any blocker in the final response.",
            "serviceName": "loop_harness"
        ]) { result in
            switch result {
            case .failure(let error):
                self.fail(jobId: job.id, message: error.localizedDescription)
                completion(.failure(error.localizedDescription))
            case .success(let payload):
                guard let thread = payload["thread"] as? [String: Any],
                      let threadId = thread["id"] as? String else {
                    let message = "Codex did not return a thread id."
                    self.fail(jobId: job.id, message: message)
                    completion(.failure(message))
                    return
                }
                job.threadId = threadId
                job.state = .running
                job.currentStep = "Codex is working"
                job.updatedAt = Date()
                job.logs.append(CodexAgentLogEntry("Started thread \(threadId.prefix(12))"))
                self.upsert(job)
                self.touchProject(project.id)

                self.client.request(method: "turn/start", params: [
                    "threadId": threadId,
                    "input": [["type": "text", "text": task]]
                ]) { turnResult in
                    switch turnResult {
                    case .failure(let error):
                        self.fail(jobId: job.id, message: error.localizedDescription)
                    case .success(let turnPayload):
                        if let turn = turnPayload["turn"] as? [String: Any],
                           let turnId = turn["id"] as? String {
                            self.mutate(jobId: job.id) {
                                $0.turnId = turnId
                                $0.currentStep = "Turn in progress"
                                $0.logs.append(CodexAgentLogEntry("Turn \(turnId.prefix(12)) started"))
                            }
                        }
                    }
                }
                completion(.success(job))
            }
        }
    }

    func continueAgent(id: String,
                       instruction: String,
                       completion: @escaping (Result<CodexAgentJob, Error>) -> Void) {
        guard let original = job(id: id), let threadId = original.threadId else {
            completion(.failure(CodexAppServerError.unavailable("No tracked Codex agent with id \(id).")))
            return
        }
        guard original.isTerminal else {
            completion(.failure(CodexAppServerError.unavailable("That Codex agent is still running. Use cancel before replacing its active turn.")))
            return
        }
        client.request(method: "thread/resume", params: ["threadId": threadId]) { result in
            switch result {
            case .failure(let error): completion(.failure(error))
            case .success:
                self.mutate(jobId: original.id) {
                    $0.state = .running
                    $0.currentStep = "Continuing Codex thread"
                    $0.finalResponse = nil
                    $0.error = nil
                    $0.postedBack = false
                    $0.logs.append(CodexAgentLogEntry("Follow-up: \(instruction)"))
                }
                self.responseTextByJob[original.id] = ""
                self.client.request(method: "turn/start", params: [
                    "threadId": threadId,
                    "input": [["type": "text", "text": instruction]]
                ]) { turnResult in
                    switch turnResult {
                    case .failure(let error):
                        self.fail(jobId: original.id, message: error.localizedDescription)
                        completion(.failure(error))
                    case .success(let payload):
                        self.mutate(jobId: original.id) {
                            $0.turnId = (payload["turn"] as? [String: Any])?["id"] as? String
                            $0.currentStep = "Turn in progress"
                        }
                        completion(.success(self.job(id: original.id) ?? original))
                    }
                }
            }
        }
    }

    func cancel(id: String, completion: @escaping (Result<CodexAgentJob, Error>) -> Void) {
        guard let current = job(id: id),
              let threadId = current.threadId,
              let turnId = current.turnId else {
            completion(.failure(CodexAppServerError.unavailable("No active Codex turn found for \(id).")))
            return
        }
        client.request(method: "turn/interrupt", params: ["threadId": threadId, "turnId": turnId]) { result in
            switch result {
            case .failure(let error): completion(.failure(error))
            case .success:
                self.finish(jobId: current.id, state: .cancelled, error: nil)
                completion(.success(self.job(id: current.id) ?? current))
            }
        }
    }

    /// Relaunch recovery cannot re-subscribe to an in-flight turn reliably
    /// without resuming it, so mark interrupted local children explicitly.
    /// Stored completed jobs remain available in the inspector.
    func resumePending() {
        for job in allJobs() where !job.isTerminal {
            fail(jobId: job.id, message: "Loop quit while this local Codex agent was running. Continue it to start a new turn on the same Codex thread.")
        }
    }

    // MARK: - Notifications

    private func handleNotification(method: String, params: [String: Any]) {
        guard let threadId = params["threadId"] as? String,
              let current = allJobs().first(where: { $0.threadId == threadId }) else { return }

        switch method {
        case "item/agentMessage/delta":
            let delta = params["delta"] as? String ?? ""
            responseTextByJob[current.id, default: ""].append(delta)
        case "item/started":
            guard let item = params["item"] as? [String: Any] else { return }
            let type = (item["type"] as? String ?? "item").replacingOccurrences(of: "_", with: " ")
            mutate(jobId: current.id) {
                $0.currentStep = Self.stepText(for: item, fallback: type)
                $0.logs.append(CodexAgentLogEntry($0.currentStep))
            }
        case "item/completed":
            guard let item = params["item"] as? [String: Any] else { return }
            if let text = Self.agentMessageText(from: item), !text.isEmpty {
                responseTextByJob[current.id] = text
            }
        case "thread/status/changed":
            if let status = params["status"] as? [String: Any],
               let type = status["type"] as? String,
               type == "active",
               ((status["activeFlags"] as? [String]) ?? []).contains(where: {
                   $0 == "waitingOnApproval" || $0 == "waitingOnUserInput"
               }) {
                mutate(jobId: current.id) { $0.state = .waiting; $0.currentStep = "Waiting for input" }
            }
        case "item/commandExecution/requestApproval",
             "item/fileChange/requestApproval",
             "item/permissions/requestApproval",
             "mcpServer/elicitation/request":
            mutate(jobId: current.id) {
                $0.currentStep = "Permission escalation declined"
                $0.logs.append(CodexAgentLogEntry("Loop declined an unattended permission or external-input request."))
            }
        case "item/tool/requestUserInput":
            mutate(jobId: current.id) {
                $0.state = .running
                $0.currentStep = "Continuing with best judgment"
                $0.logs.append(CodexAgentLogEntry("Loop auto-resolved an unattended clarification request."))
            }
        case "turn/completed":
            let turn = params["turn"] as? [String: Any]
            let status = turn?["status"] as? String ?? "completed"
            if status == "completed" {
                finish(jobId: current.id, state: .completed, error: nil)
            } else if status == "interrupted" || status == "cancelled" {
                finish(jobId: current.id, state: .cancelled, error: nil)
            } else {
                let message = ((turn?["error"] as? [String: Any])?["message"] as? String)
                    ?? "Codex turn ended with status \(status)."
                finish(jobId: current.id, state: .failed, error: message)
            }
        default:
            break
        }
    }

    private static func stepText(for item: [String: Any], fallback: String) -> String {
        if let command = item["command"] as? String, !command.isEmpty { return "Running: \(command)" }
        if let name = item["name"] as? String, !name.isEmpty { return "Using \(name)" }
        switch fallback {
        case "commandExecution": return "Running a command"
        case "fileChange": return "Editing files"
        case "agentMessage": return "Writing the response"
        default: return fallback.prefix(1).uppercased() + fallback.dropFirst()
        }
    }

    private static func agentMessageText(from item: [String: Any]) -> String? {
        if let text = item["text"] as? String { return text }
        if let content = item["content"] as? [[String: Any]] {
            let parts = content.compactMap { $0["text"] as? String }
            return parts.isEmpty ? nil : parts.joined()
        }
        return nil
    }

    // MARK: - Persistence and completion

    private func mutate(jobId: String, _ body: (inout CodexAgentJob) -> Void) {
        var updated: CodexAgentJob?
        queue.sync {
            var jobs = loadJobsUnlocked()
            guard let index = jobs.firstIndex(where: { $0.id == jobId }) else { return }
            body(&jobs[index])
            jobs[index].updatedAt = Date()
            if jobs[index].logs.count > maxLogs {
                jobs[index].logs.removeFirst(jobs[index].logs.count - maxLogs)
            }
            updated = jobs[index]
            saveJobsUnlocked(jobs)
        }
        if let updated { broadcast(updated.id) }
    }

    private func upsert(_ job: CodexAgentJob) {
        queue.sync {
            var jobs = loadJobsUnlocked()
            if let index = jobs.firstIndex(where: { $0.id == job.id }) { jobs[index] = job }
            else { jobs.append(job) }
            saveJobsUnlocked(jobs)
        }
        broadcast(job.id)
    }

    private func fail(jobId: String, message: String) {
        finish(jobId: jobId, state: .failed, error: message)
    }

    private func finish(jobId: String, state: CodexAgentState, error: String?) {
        let response = responseTextByJob.removeValue(forKey: jobId)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        mutate(jobId: jobId) {
            $0.state = state
            $0.currentStep = state == .completed ? "Completed" : state.rawValue.capitalized
            $0.finalResponse = response?.isEmpty == false ? response : $0.finalResponse
            $0.error = error
            $0.logs.append(CodexAgentLogEntry(error ?? $0.currentStep))
        }
        postBackIfNeeded(jobId: jobId)
    }

    private func postBackIfNeeded(jobId: String) {
        guard let job = job(id: jobId), job.isTerminal, !job.postedBack else { return }
        let manager = SimpleConversationManager.shared
        let parent = manager.getAllConversations().first(where: { $0.id == job.conversationId })
            ?? manager.currentConversation
            ?? manager.loadLastConversation()
        guard let parent else { return }

        let body: String
        switch job.state {
        case .completed:
            body = "✅ Codex finished `\(URL(fileURLWithPath: job.projectPath).lastPathComponent)`.\n\n" +
                (job.finalResponse ?? "The Codex turn completed without a final text response.")
        case .cancelled:
            body = "🚫 Codex agent for `\(URL(fileURLWithPath: job.projectPath).lastPathComponent)` was cancelled."
        case .failed:
            body = "❌ Codex agent for `\(URL(fileURLWithPath: job.projectPath).lastPathComponent)` failed: \(job.error ?? "Unknown error")"
        case .queued, .running, .waiting:
            return
        }
        var message = MessageStruct(role: "assistant", content: body, model: "Codex")
        message.name = "codex_agent_\(job.id.prefix(8))"
        manager.addMessage(message, to: parent)
        mutate(jobId: job.id) { $0.postedBack = true }
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .codexAgentDidPostMessage,
                object: nil,
                userInfo: ["conversationId": parent.id, "messageId": message.id]
            )
            guard !NSApplication.shared.isActive else { return }
            let content = UNMutableNotificationContent()
            content.title = "Codex · \(URL(fileURLWithPath: job.projectPath).lastPathComponent)"
            content.body = job.state == .completed ? "Agent completed" : body
            content.sound = .default
            UNUserNotificationCenter.current().add(UNNotificationRequest(
                identifier: "loop.codex.\(job.id)",
                content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
            ))
        }
    }

    private func touchProject(_ id: String) {
        queue.sync {
            var projects = loadProjectsUnlocked()
            guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
            projects[index].lastUsedAt = Date()
            saveProjectsUnlocked(projects)
        }
    }

    private func broadcast(_ jobId: String) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .codexAgentsDidChange,
                object: nil,
                userInfo: ["agentId": jobId]
            )
        }
    }

    private func loadProjectsUnlocked() -> [CodexProject] {
        guard let data = UserDefaults.standard.data(forKey: projectsKey) else { return [] }
        return (try? JSONDecoder().decode([CodexProject].self, from: data)) ?? []
    }

    private func saveProjectsUnlocked(_ projects: [CodexProject]) {
        if let data = try? JSONEncoder().encode(projects) {
            UserDefaults.standard.set(data, forKey: projectsKey)
        }
    }

    private func loadJobsUnlocked() -> [CodexAgentJob] {
        guard let data = UserDefaults.standard.data(forKey: jobsKey) else { return [] }
        return (try? JSONDecoder().decode([CodexAgentJob].self, from: data)) ?? []
    }

    private func saveJobsUnlocked(_ jobs: [CodexAgentJob]) {
        if let data = try? JSONEncoder().encode(jobs) {
            UserDefaults.standard.set(data, forKey: jobsKey)
        }
    }
}
