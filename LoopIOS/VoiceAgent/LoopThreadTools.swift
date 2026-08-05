//
//  LoopThreadTools.swift
//  Loop
//
//  Declares the function tools exposed to the OpenAI Realtime session and
//  routes tool calls to `LoopThreadService`, returning a JSON string the
//  session hands back to the model as a `function_call_output`.
//
//  Tool surface (message-centric by design):
//    MVP:   createLoopThread, sendLoopMessage, getLoopThreadStatus
//    Then:  listLoopThreads, summarizeLoopThread
//

import Foundation

enum LoopThreadTools {

    /// The tool set advertised in `session.update`. Shape matches the Realtime
    /// API's function-tool schema: a flat object with `type: "function"`, a
    /// `name`, `description`, and JSON-Schema `parameters`.
    static let toolSchemas: [[String: Any]] = [
        [
            "type": "function",
            "name": "createLoopThread",
            "description": "Create a new Loop thread (a fresh conversation with another agent) and send it an opening message. Use this for a new artifact, a different objective, or unrelated work. Returns immediately; the work happens in the background and you'll get an update when there's progress.",
            "parameters": [
                "type": "object",
                "properties": [
                    "title": [
                        "type": "string",
                        "description": "A short human title for the thread, e.g. 'Trip itinerary' or 'Landing page copy'."
                    ],
                    "initialMessage": [
                        "type": "string",
                        "description": "The first message to send to the thread — what you want the other agent to do."
                    ],
                    "agent": [
                        "type": "string",
                        "description": "Optional hint about which kind of agent should handle it: 'coding', 'research', or 'general'. Defaults to general."
                    ]
                ],
                "required": ["title", "initialMessage"]
            ]
        ],
        [
            "type": "function",
            "name": "sendLoopMessage",
            "description": "Send another message to an existing Loop thread. Use this to continue when it's the same artifact, same goal, or a refinement of previous work. If you're unsure whether to continue an existing thread or start a new one, ask the user.",
            "parameters": [
                "type": "object",
                "properties": [
                    "threadId": [
                        "type": "string",
                        "description": "The id of the thread to send to (from createLoopThread or listLoopThreads)."
                    ],
                    "message": [
                        "type": "string",
                        "description": "The message to send to the thread."
                    ]
                ],
                "required": ["threadId", "message"]
            ]
        ],
        [
            "type": "function",
            "name": "getLoopThreadStatus",
            "description": "Check the current status of a thread and get its latest summary. Status is one of queued, running, waiting, complete, or failed.",
            "parameters": [
                "type": "object",
                "properties": [
                    "threadId": [
                        "type": "string",
                        "description": "The id of the thread to check."
                    ]
                ],
                "required": ["threadId"]
            ]
        ],
        [
            "type": "function",
            "name": "listLoopThreads",
            "description": "List the user's Loop threads, newest first, with their status. Optionally filter by status.",
            "parameters": [
                "type": "object",
                "properties": [
                    "status": [
                        "type": "string",
                        "description": "Optional filter: queued, running, waiting, complete, or failed."
                    ]
                ],
                "required": []
            ]
        ],
        [
            "type": "function",
            "name": "summarizeLoopThread",
            "description": "Summarize a thread's conversation so you can catch the user up. Use 'brief' for a one-liner or 'detailed' for a recap of the recent exchange.",
            "parameters": [
                "type": "object",
                "properties": [
                    "threadId": [
                        "type": "string",
                        "description": "The id of the thread to summarize."
                    ],
                    "style": [
                        "type": "string",
                        "enum": ["brief", "detailed"],
                        "description": "How much detail to include. Defaults to brief."
                    ]
                ],
                "required": ["threadId"]
            ]
        ]
    ]

    static let toolNames: Set<String> = [
        "createLoopThread", "sendLoopMessage", "getLoopThreadStatus",
        "listLoopThreads", "summarizeLoopThread",
    ]

    /// Run a tool call by name with decoded JSON arguments and return the JSON
    /// string result to feed back into the session. Never throws — errors come
    /// back as `{ "error": "..." }` so the model can recover conversationally.
    static func dispatch(name: String, arguments: [String: Any]) -> String {
        let service = LoopThreadService.shared
        switch name {
        case "createLoopThread":
            guard let initialMessage = arguments["initialMessage"] as? String,
                  !initialMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return json(["error": "initialMessage is required"])
            }
            let title = (arguments["title"] as? String) ?? ""
            let agent = arguments["agent"] as? String
            let result = service.createThread(title: title,
                                              initialMessage: initialMessage,
                                              agent: agent)
            return json([
                "threadId": result.threadId,
                "status": result.status,
                "summary": result.summary,
            ])

        case "sendLoopMessage":
            guard let threadId = arguments["threadId"] as? String,
                  let message = arguments["message"] as? String,
                  !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return json(["error": "threadId and message are required"])
            }
            guard let result = service.sendMessage(threadId: threadId, message: message) else {
                return json(["error": "No thread found with id \(threadId)"])
            }
            return json([
                "threadId": result.threadId,
                "status": result.status,
                "summary": result.summary,
            ])

        case "getLoopThreadStatus":
            guard let threadId = arguments["threadId"] as? String else {
                return json(["error": "threadId is required"])
            }
            guard let result = service.status(threadId: threadId) else {
                return json(["error": "No thread found with id \(threadId)"])
            }
            return json([
                "status": result.status.rawValue,
                "latestSummary": result.latestSummary,
            ])

        case "listLoopThreads":
            let filter = (arguments["status"] as? String)
                .flatMap { LoopThreadStatus(rawValue: $0.lowercased()) }
            let threads = service.listThreads(statusFilter: filter)
            let rows: [[String: Any]] = threads.map { thread in
                return [
                    "threadId": thread.threadId,
                    "title": thread.title,
                    "status": thread.status.rawValue,
                    "latestSummary": thread.latestSummary,
                ]
            }
            return json(["count": rows.count, "threads": rows])

        case "summarizeLoopThread":
            guard let threadId = arguments["threadId"] as? String else {
                return json(["error": "threadId is required"])
            }
            let style = arguments["style"] as? String
            guard let summary = service.summarize(threadId: threadId, style: style) else {
                return json(["error": "No thread found with id \(threadId)"])
            }
            return json(["summary": summary])

        default:
            return json(["error": "Unknown tool \(name)"])
        }
    }

    // MARK: - Helpers

    private static func json(_ payload: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }
}
