//
//  LoopThreadService.swift
//  Loop
//
//  The local Swift tool layer behind the realtime voice agent. It translates
//  the voice agent's message-centric tool calls (create thread, send message,
//  check status, summarize) into operations on Loop's existing thread system:
//
//    • A "thread" is a `SimpleConversation` (threadId == conversation id).
//    • "Sending a message" appends a user turn and dispatches a `SubAgent` to
//      do the work in the background, exactly like the primary chat's
//      `spawn_sub_agent`. The sub-agent posts its result back into the
//      conversation when done — which is what drives the async voice updates.
//
//  The design philosophy is "send a message to another agent", not "create a
//  task": every method here is phrased around conversations, and the voice
//  layer never exposes sub-agent/implementation details unless asked.
//

import Foundation

final class LoopThreadService {

    static let shared = LoopThreadService()

    private let manager = SimpleConversationManager.shared

    /// Most-recent sub-agent dispatched for a given thread, so `status` and the
    /// update bridge can resolve the live worker for a conversation. Guarded by
    /// `queue` since tool calls arrive off the WebSocket's delegate queue.
    private var latestAgentByThread: [String: String] = [:]
    private let queue = DispatchQueue(label: "loop.voiceAgent.threadService")

    private init() {}

    // MARK: - Public API (called by the realtime tool dispatcher)

    struct CreateResult {
        let threadId: String
        let status: String
        let summary: String
    }

    /// Create a brand-new thread and dispatch its first message. Returns
    /// immediately — the agent works in the background.
    @discardableResult
    func createThread(title: String,
                      initialMessage: String,
                      agent: String?) -> CreateResult {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let conversation = manager.createConversation(
            title: cleanTitle.isEmpty ? defaultTitle(from: initialMessage) : cleanTitle
        )
        // Make this the active conversation so the user sees the new thread if
        // they glance at the screen; harmless if they don't.
        manager.currentConversation = conversation

        appendUserMessage(initialMessage, to: conversation.id)
        dispatchWork(threadId: conversation.id,
                     latestMessage: initialMessage,
                     agent: agent)

        return CreateResult(
            threadId: conversation.id,
            status: "created",
            summary: "Started a new thread “\(conversation.title)” and handed off the first message."
        )
    }

    struct SendResult {
        let threadId: String
        let status: String
        let summary: String
    }

    /// Append a message to an existing thread and dispatch a fresh agent turn
    /// with the thread's full context so it can refine prior work.
    func sendMessage(threadId: String, message: String) -> SendResult? {
        guard let conversation = manager.getConversation(by: threadId) else { return nil }
        appendUserMessage(message, to: threadId)
        dispatchWork(threadId: threadId, latestMessage: message, agent: nil)
        return SendResult(
            threadId: threadId,
            status: "running",
            summary: "Sent your message to the thread “\(conversation.title)” — it's working on it now."
        )
    }

    struct StatusResult {
        let status: LoopThreadStatus
        let latestSummary: String
    }

    /// Resolve the current status of a thread from its most-recent sub-agent
    /// (if any), falling back to the persisted transcript.
    func status(threadId: String) -> StatusResult? {
        guard let conversation = manager.getConversation(by: threadId) else { return nil }

        if let agentId = queue.sync(execute: { latestAgentByThread[threadId] }),
           let agent = SubAgentManager.shared.agent(id: agentId) {
            let status = mapStatus(agent.state)
            let summary = agent.result?.trimmingCharacters(in: .whitespacesAndNewlines)
            let latest = (summary?.isEmpty == false ? summary : nil)
                ?? lastAssistantText(in: conversation)
                ?? agent.currentStep
            return StatusResult(status: status, latestSummary: latest)
        }

        // No tracked worker — infer from the transcript. A thread with an
        // assistant reply is "complete"; one with only the seed message is
        // still "queued".
        if let latest = lastAssistantText(in: conversation) {
            return StatusResult(status: .complete, latestSummary: latest)
        }
        return StatusResult(status: .queued, latestSummary: "No updates yet.")
    }

    /// List threads, newest first, optionally filtered by status.
    func listThreads(statusFilter: LoopThreadStatus?) -> [LoopThreadSummary] {
        let conversations = manager.getAllConversations()
            .sorted { $0.updatedAt > $1.updatedAt }
        var out: [LoopThreadSummary] = []
        for conversation in conversations {
            let resolved = status(threadId: conversation.id)
            let threadStatus = resolved?.status ?? .complete
            if let filter = statusFilter, filter != threadStatus { continue }
            out.append(LoopThreadSummary(
                threadId: conversation.id,
                title: conversation.title,
                status: threadStatus,
                latestSummary: resolved?.latestSummary ?? "",
                updatedAt: conversation.updatedAt
            ))
        }
        return out
    }

    /// Produce a conversational summary of a thread. `brief` is a one-liner
    /// drawn from the latest result; `detailed` walks the recent transcript.
    func summarize(threadId: String, style: String?) -> String? {
        guard let conversation = manager.getConversation(by: threadId) else { return nil }
        let detailed = (style ?? "brief").lowercased() == "detailed"

        let messages = manager.getMessages(for: conversation)
            .filter { $0.role == "user" || $0.role == "assistant" }
        guard !messages.isEmpty else {
            return "The thread “\(conversation.title)” doesn't have any messages yet."
        }

        if !detailed {
            if let latest = lastAssistantText(in: conversation) {
                return latest
            }
            return "You've asked about “\(conversation.title)” but there's no reply yet."
        }

        // Detailed: stitch the last several exchanges into a readable recap.
        let recent = messages.suffix(8)
        let lines: [String] = recent.map { msg in
            let who = msg.role == "user" ? "You" : "Loop"
            let text = msg.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(who): \(text)"
        }
        return "Here's where the thread “\(conversation.title)” stands:\n" + lines.joined(separator: "\n")
    }

    // MARK: - Update bookkeeping

    /// The thread a sub-agent belongs to, if we dispatched it. Used by the
    /// event bridge to attribute `.subAgentDidPostMessage` back to a thread
    /// when the notification's conversationId needs corroboration.
    func threadId(forAgent agentId: String) -> String? {
        return queue.sync {
            latestAgentByThread.first(where: { $0.value == agentId })?.key
        }
    }

    /// True when a conversation id is a thread the voice agent is tracking.
    func isTrackedThread(_ threadId: String) -> Bool {
        return queue.sync { latestAgentByThread[threadId] != nil }
    }

    // MARK: - Internals

    private func appendUserMessage(_ text: String, to threadId: String) {
        guard let conversation = manager.getConversation(by: threadId) else { return }
        let message = MessageStruct(role: "user", content: text)
        manager.addMessage(message, to: conversation)
    }

    /// Spawn a sub-agent seeded with the thread's context so it can continue or
    /// refine prior work, and remember it as the thread's live worker.
    private func dispatchWork(threadId: String, latestMessage: String, agent: String?) {
        let kind = kind(from: agent)
        let task = buildTask(threadId: threadId, latestMessage: latestMessage)
        let spawned = SubAgentManager.shared.spawn(task: task,
                                                    kind: kind,
                                                    parentConversationId: threadId)
        queue.sync { latestAgentByThread[threadId] = spawned.id }
    }

    /// Build a self-contained prompt for the sub-agent. It includes the recent
    /// thread transcript so the detached agent has continuity, then states the
    /// latest message as the thing to act on.
    private func buildTask(threadId: String, latestMessage: String) -> String {
        guard let conversation = manager.getConversation(by: threadId) else {
            return latestMessage
        }
        let history = manager.getMessages(for: conversation)
            .filter { $0.role == "user" || $0.role == "assistant" }
        // Drop the just-appended latest user message from the history block so
        // it isn't duplicated with the explicit instruction below.
        let priorHistory = history.dropLast()

        var sections: [String] = []
        if !priorHistory.isEmpty {
            let transcript = priorHistory.suffix(12).map { msg -> String in
                let who = msg.role == "user" ? "User" : "Assistant"
                return "\(who): \(msg.content.trimmingCharacters(in: .whitespacesAndNewlines))"
            }.joined(separator: "\n")
            sections.append("""
            You are continuing an existing thread. Here is the recent context:

            \(transcript)
            """)
        }
        sections.append("""
        The user's latest message on this thread is:

        \(latestMessage.trimmingCharacters(in: .whitespacesAndNewlines))

        Do the work this asks for. If it refines earlier work in this thread,
        build on that rather than starting over. Reply with a tight,
        conversational summary of what you did or produced — it will be read
        aloud to the user.
        """)
        return sections.joined(separator: "\n\n")
    }

    private func kind(from agent: String?) -> SubAgentKind {
        switch agent?.lowercased() {
        case "coding", "code", "engineer", "developer": return .coding
        case "research", "researcher", "search":        return .research
        default:                                          return .general
        }
    }

    private func mapStatus(_ state: SubAgentState) -> LoopThreadStatus {
        switch state {
        case .active:          return .running
        case .sleeping:        return .running
        case .waitingForInput: return .waiting
        case .completed:       return .complete
        case .failed:          return .failed
        }
    }

    private func lastAssistantText(in conversation: SimpleConversation) -> String? {
        let messages = manager.getMessages(for: conversation)
        guard let last = messages.last(where: {
            $0.role == "assistant" && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else { return nil }
        return last.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func defaultTitle(from message: String) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        if trimmed.isEmpty { return "New thread" }
        if trimmed.count <= 40 { return trimmed }
        return String(trimmed.prefix(37)) + "…"
    }
}
