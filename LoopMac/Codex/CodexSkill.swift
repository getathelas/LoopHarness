//
//  CodexSkill.swift
//  LoopMac
//
//  Model-facing tools for discovering local projects and dispatching Codex
//  app-server agents into one or several of them. Long-running calls return
//  immediately; CodexAgentService publishes progress and posts the terminal
//  response back into the originating Loop conversation.
//

import Foundation

struct CodexSkill {
    static let shared = CodexSkill()

    static let systemPromptFragment = """
You can delegate repository work to local Codex agents on this Mac.
- codex_list_projects discovers projects from Codex history and lists projects explicitly registered with Loop.
- codex_add_project registers an existing local directory. Projects default to read-only; set allow_writes only when the user has asked Codex to make changes there.
- codex_dispatch_agent starts one agent and returns immediately. Use project_id from codex_list_projects. Access defaults to the project's policy; workspace_write is rejected unless writes were explicitly enabled for that project.
- codex_dispatch_agents starts up to three independent project tasks at once. Use it when the user asks to fan work out across projects.
- codex_list_agents reports live and completed jobs; codex_continue_agent sends a follow-up on a completed thread; codex_cancel_agent interrupts an active turn.

After dispatch, tell the user the agent is running. Do not wait or claim work is complete: Loop posts the result back into this conversation when the Codex turn ends. Never request unrestricted filesystem access; only read_only and workspace_write are supported.
"""

    static let tools: [[String: Any]] = [
        tool("codex_list_projects",
             "List local projects available to Codex. Optionally refresh from Codex thread history first.",
             properties: [
                "refresh": ["type": "boolean", "description": "Refresh projects from local Codex history before listing (default true)."]
             ]),
        tool("codex_add_project",
             "Register an existing local directory as a Codex project.",
             properties: [
                "path": ["type": "string", "description": "Absolute path to an existing project directory."],
                "name": ["type": "string", "description": "Optional display name."],
                "allow_writes": ["type": "boolean", "description": "Allow workspace-write Codex agents in this project (default false)."]
             ], required: ["path"]),
        tool("codex_dispatch_agent",
             "Start a local Codex agent in one registered project. Returns immediately and posts the final result back later.",
             properties: [
                "project_id": ["type": "string", "description": "Project id/path/name from codex_list_projects."],
                "task": ["type": "string", "description": "Clear, self-contained task for Codex."],
                "access": ["type": "string", "enum": ["read_only", "workspace_write"], "description": "Filesystem access. Defaults to the project's configured policy."]
             ], required: ["project_id", "task"]),
        tool("codex_dispatch_agents",
             "Fan out independent Codex tasks across up to three registered projects.",
             properties: [
                "tasks": [
                    "type": "array",
                    "maxItems": 3,
                    "items": [
                        "type": "object",
                        "properties": [
                            "project_id": ["type": "string"],
                            "task": ["type": "string"],
                            "access": ["type": "string", "enum": ["read_only", "workspace_write"]]
                        ],
                        "required": ["project_id", "task"]
                    ]
                ]
             ], required: ["tasks"]),
        tool("codex_list_agents",
             "List Codex agents tracked by Loop, including live state and final result.",
             properties: [
                "project_id": ["type": "string", "description": "Optional project id/path/name filter."]
             ]),
        tool("codex_continue_agent",
             "Continue a completed Codex thread with a follow-up instruction.",
             properties: [
                "agent_id": ["type": "string"],
                "instruction": ["type": "string"]
             ], required: ["agent_id", "instruction"]),
        tool("codex_cancel_agent",
             "Interrupt a currently running Codex agent turn.",
             properties: ["agent_id": ["type": "string"]],
             required: ["agent_id"])
    ]

    private static let names = Set(tools.compactMap {
        ($0["function"] as? [String: Any])?["name"] as? String
    })

    func handles(functionName: String) -> Bool { Self.names.contains(functionName) }

    func statusText(for call: FunctionCallStruct) -> String? {
        switch call.name {
        case "codex_list_projects": return "discovering Codex projects"
        case "codex_add_project": return "registering a Codex project"
        case "codex_dispatch_agent": return "starting a Codex agent"
        case "codex_dispatch_agents": return "starting Codex agents"
        case "codex_list_agents": return "checking Codex agents"
        case "codex_continue_agent": return "continuing a Codex agent"
        case "codex_cancel_agent": return "stopping a Codex agent"
        default: return nil
        }
    }

    func handle(functionCall: FunctionCallStruct,
                completion: @escaping (MessageStruct) -> Void) {
        switch functionCall.name {
        case "codex_list_projects": listProjects(functionCall.arguments, completion)
        case "codex_add_project": addProject(functionCall.arguments, completion)
        case "codex_dispatch_agent": dispatchOne(functionCall.arguments, completion)
        case "codex_dispatch_agents": dispatchMany(functionCall.arguments, completion)
        case "codex_list_agents": listAgents(functionCall.arguments, completion)
        case "codex_continue_agent": continueAgent(functionCall.arguments, completion)
        case "codex_cancel_agent": cancelAgent(functionCall.arguments, completion)
        default: completion(Self.result(functionCall.name, ["status": "error", "error": "Unknown Codex tool."]))
        }
    }

    private func listProjects(_ args: [String: Any], _ completion: @escaping (MessageStruct) -> Void) {
        let finish: ([CodexProject]) -> Void = { projects in
            completion(Self.result("codex_list_projects", [
                "count": projects.count,
                "projects": projects.map(Self.projectPayload)
            ]))
        }
        if (args["refresh"] as? Bool) ?? true {
            CodexAgentService.shared.refreshProjects { result in
                switch result {
                case .success(let projects): finish(projects)
                case .failure(let error):
                    let cached = CodexAgentService.shared.projects()
                    completion(Self.result("codex_list_projects", [
                        "status": "partial",
                        "warning": error.localizedDescription,
                        "count": cached.count,
                        "projects": cached.map(Self.projectPayload)
                    ]))
                }
            }
        } else {
            finish(CodexAgentService.shared.projects())
        }
    }

    private func addProject(_ args: [String: Any], _ completion: @escaping (MessageStruct) -> Void) {
        guard let path = Self.string(args, "path") else {
            completion(Self.error("codex_add_project", "path is required")); return
        }
        switch CodexAgentService.shared.addProject(
            path: path,
            name: Self.string(args, "name"),
            allowWrites: (args["allow_writes"] as? Bool) ?? false
        ) {
        case .success(let project):
            completion(Self.result("codex_add_project", ["status": "registered", "project": Self.projectPayload(project)]))
        case .failure(let error):
            completion(Self.error("codex_add_project", error.localizedDescription))
        }
    }

    private func dispatchOne(_ args: [String: Any], _ completion: @escaping (MessageStruct) -> Void) {
        dispatchPayload(args) { payload in
            completion(Self.result("codex_dispatch_agent", payload))
        }
    }

    private func dispatchMany(_ args: [String: Any], _ completion: @escaping (MessageStruct) -> Void) {
        guard let tasks = args["tasks"] as? [[String: Any]], !tasks.isEmpty else {
            completion(Self.error("codex_dispatch_agents", "tasks must contain at least one task")); return
        }
        guard tasks.count <= 3 else {
            completion(Self.error("codex_dispatch_agents", "A maximum of three agents can be dispatched at once.")); return
        }
        var payloads = Array(repeating: [String: Any](), count: tasks.count)
        let group = DispatchGroup()
        for (index, task) in tasks.enumerated() {
            group.enter()
            dispatchPayload(task) { payload in
                payloads[index] = payload
                group.leave()
            }
        }
        group.notify(queue: .main) {
            let dispatched = payloads.filter { ($0["status"] as? String) == "dispatched" }.count
            completion(Self.result("codex_dispatch_agents", [
                "status": dispatched == payloads.count ? "dispatched" : "partial",
                "dispatched": dispatched,
                "results": payloads,
                "message": "Started \(dispatched) Codex agent(s). Results will be posted back into this conversation when each turn completes."
            ]))
        }
    }

    private func dispatchPayload(_ args: [String: Any], completion: @escaping ([String: Any]) -> Void) {
        guard let identifier = Self.string(args, "project_id") else {
            completion(["status": "error", "error": "project_id is required"]); return
        }
        guard let task = Self.string(args, "task") else {
            completion(["status": "error", "project_id": identifier, "error": "task is required"]); return
        }
        guard let project = CodexAgentService.shared.project(matching: identifier) else {
            completion(["status": "error", "project_id": identifier, "error": "Unknown project. Call codex_list_projects or codex_add_project first."])
            return
        }
        let access: CodexAccessMode
        switch Self.string(args, "access") {
        case "read_only": access = .readOnly
        case "workspace_write": access = .workspaceWrite
        case nil: access = project.defaultAccess
        default:
            completion(["status": "error", "project_id": identifier, "error": "access must be read_only or workspace_write"])
            return
        }
        CodexAgentService.shared.dispatch(
            task: task,
            project: project,
            access: access,
            conversationId: Self.conversationId()
        ) { result in
            switch result {
            case .success(let job):
                completion([
                    "status": "dispatched",
                    "agent_id": job.id,
                    "thread_id": job.threadId ?? "",
                    "project": project.name,
                    "access": access == .workspaceWrite ? "workspace_write" : "read_only",
                    "message": "Codex is running. Loop will post the final result back into this conversation."
                ])
            case .failure(let error):
                completion(["status": "error", "project": project.name, "error": error])
            }
        }
    }

    private func listAgents(_ args: [String: Any], _ completion: @escaping (MessageStruct) -> Void) {
        var jobs = CodexAgentService.shared.allJobs()
        if let identifier = Self.string(args, "project_id") {
            guard let project = CodexAgentService.shared.project(matching: identifier) else {
                completion(Self.error("codex_list_agents", "Unknown project \(identifier).")); return
            }
            jobs = jobs.filter { $0.projectId == project.id }
        }
        completion(Self.result("codex_list_agents", [
            "count": jobs.count,
            "agents": jobs.map(Self.jobPayload)
        ]))
    }

    private func continueAgent(_ args: [String: Any], _ completion: @escaping (MessageStruct) -> Void) {
        guard let id = Self.string(args, "agent_id"), let instruction = Self.string(args, "instruction") else {
            completion(Self.error("codex_continue_agent", "agent_id and instruction are required")); return
        }
        CodexAgentService.shared.continueAgent(id: id, instruction: instruction) { result in
            switch result {
            case .success(let job): completion(Self.result("codex_continue_agent", ["status": "running", "agent": Self.jobPayload(job)]))
            case .failure(let error): completion(Self.error("codex_continue_agent", error.localizedDescription))
            }
        }
    }

    private func cancelAgent(_ args: [String: Any], _ completion: @escaping (MessageStruct) -> Void) {
        guard let id = Self.string(args, "agent_id") else {
            completion(Self.error("codex_cancel_agent", "agent_id is required")); return
        }
        CodexAgentService.shared.cancel(id: id) { result in
            switch result {
            case .success(let job): completion(Self.result("codex_cancel_agent", ["status": "cancelled", "agent": Self.jobPayload(job)]))
            case .failure(let error): completion(Self.error("codex_cancel_agent", error.localizedDescription))
            }
        }
    }

    private static func tool(_ name: String,
                             _ description: String,
                             properties: [String: Any],
                             required: [String] = []) -> [String: Any] {
        ["type": "function", "function": [
            "name": name,
            "description": description,
            "parameters": ["type": "object", "properties": properties, "required": required]
        ]]
    }

    private static func string(_ args: [String: Any], _ key: String) -> String? {
        guard let value = (args[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    private static func conversationId() -> String {
        let manager = SimpleConversationManager.shared
        if let current = manager.currentConversation { return current.id }
        if let last = manager.loadLastConversation() { return last.id }
        let fresh = manager.createConversation(title: "Codex results")
        manager.currentConversation = fresh
        return fresh.id
    }

    private static func projectPayload(_ project: CodexProject) -> [String: Any] {
        [
            "id": project.id,
            "name": project.name,
            "path": project.path,
            "default_access": project.defaultAccess == .workspaceWrite ? "workspace_write" : "read_only"
        ]
    }

    private static func jobPayload(_ job: CodexAgentJob) -> [String: Any] {
        [
            "agent_id": job.id,
            "thread_id": job.threadId ?? "",
            "project_id": job.projectId,
            "project_path": job.projectPath,
            "task": job.task,
            "access": job.access == .workspaceWrite ? "workspace_write" : "read_only",
            "status": job.state.rawValue,
            "current_step": job.currentStep,
            "final_response": job.finalResponse ?? "",
            "error": job.error ?? ""
        ]
    }

    private static func result(_ name: String, _ payload: [String: Any]) -> MessageStruct {
        let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let content = data.flatMap { String(data: $0, encoding: .utf8) }
            ?? "{\"status\":\"error\",\"error\":\"failed to encode result\"}"
        return MessageStruct(role: "function", content: content, name: name)
    }

    private static func error(_ name: String, _ message: String) -> MessageStruct {
        result(name, ["status": "error", "error": message])
    }
}
