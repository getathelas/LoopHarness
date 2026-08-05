//
//  CodexProtocol.swift
//  LoopMac
//
//  Small, deliberately stable model layer around the Codex app-server API.
//  Wire payloads stay as JSON dictionaries in CodexAppServerClient so a CLI
//  update can add fields without breaking decoding; only the state Loop owns
//  (projects and dispatched jobs) is Codable and persisted locally.
//

import Foundation

enum CodexAccessMode: String, Codable, CaseIterable {
    /// Wire values from the generated app-server `SandboxMode` schema.
    case readOnly = "read-only"
    case workspaceWrite = "workspace-write"

    var displayName: String {
        switch self {
        case .readOnly: return "Read only"
        case .workspaceWrite: return "Workspace write"
        }
    }
}

struct CodexProject: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var path: String
    var defaultAccess: CodexAccessMode
    var addedAt: Date
    var lastUsedAt: Date?

    init(path: String,
         name: String? = nil,
         defaultAccess: CodexAccessMode = .readOnly,
         addedAt: Date = Date()) {
        let standardized = URL(fileURLWithPath: path)
            .resolvingSymlinksInPath().standardizedFileURL.path
        self.id = standardized
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = (trimmedName?.isEmpty == false ? trimmedName : nil)
            ?? URL(fileURLWithPath: standardized).lastPathComponent
        self.path = standardized
        self.defaultAccess = defaultAccess
        self.addedAt = addedAt
        self.lastUsedAt = nil
    }
}

enum CodexAgentState: String, Codable {
    case queued
    case running
    case waiting
    case completed
    case cancelled
    case failed

    var isTerminal: Bool {
        switch self {
        case .completed, .cancelled, .failed: return true
        case .queued, .running, .waiting: return false
        }
    }
}

struct CodexAgentLogEntry: Codable {
    var date: Date
    var summary: String

    init(_ summary: String, date: Date = Date()) {
        self.date = date
        self.summary = summary
    }
}

struct CodexAgentJob: Codable, Identifiable {
    var id: String
    var threadId: String?
    var turnId: String?
    var conversationId: String
    var projectId: String
    var projectPath: String
    var task: String
    var access: CodexAccessMode
    var state: CodexAgentState
    var currentStep: String
    var createdAt: Date
    var updatedAt: Date
    var finalResponse: String?
    var error: String?
    var postedBack: Bool
    var logs: [CodexAgentLogEntry]

    var isTerminal: Bool { state.isTerminal }

    var displayTitle: String {
        let oneLine = task.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return oneLine.count > 80 ? String(oneLine.prefix(77)) + "…" : oneLine
    }
}

enum CodexAppServerError: LocalizedError {
    case executableNotFound
    case unavailable(String)
    case invalidResponse(String)
    case server(code: Int?, message: String)
    case terminated(String)

    var errorDescription: String? {
        switch self {
        case .executableNotFound:
            return "Codex CLI was not found. Install it, or set its path in Loop's Codex integration settings."
        case .unavailable(let message), .invalidResponse(let message), .terminated(let message):
            return message
        case .server(let code, let message):
            return code.map { "Codex app-server error \($0): \(message)" } ?? "Codex app-server error: \(message)"
        }
    }
}
