import Foundation

/// GPT-Live's protocol is distinct from Realtime: audio never commits turns.
enum LiveProtocol {
    static let endpoint = URL(string: "wss://api.openai.com/v1/live/sessions")!

    static func start(history: [(role: String, content: String)]) -> [String: Any] {
        // Conservative UTF-8 byte budget stays below the 8,192-token input limit.
        var remaining = 6_000
        let input: [[String: Any]] = history.reversed().compactMap { message in
            guard ["user", "assistant"].contains(message.role),
                  !message.content.isEmpty,
                  message.content.utf8.count <= remaining else { return nil }
            remaining -= message.content.utf8.count
            return ["type": "message", "role": message.role,
                    "content": [["type": message.role == "assistant" ? "output_text" : "input_text",
                                 "text": message.content]]]
        }.prefix(128).reversed()
        return ["type": "session.start", "session": [
            "model": "gpt-live-1", "store": false,
            "instructions": "You are Loop's live voice companion. Speak naturally and briefly. Delegate reasoning, personal context, tool use, and actions to LoopHarness. Never claim an action succeeded before the backend confirms it. Listen to corrections and ask when intent is unclear.",
            "input": input,
            "audio": ["format": ["type": "audio/pcm", "rate": 24000],
                      "output": ["voice": "marin"]],
            "delegation": ["type": "client"]
        ]]
    }

    static func commentary(_ content: String, delegationID: String) -> [[String: Any]] {
        // Each append is limited to 500 tokens. 450 UTF-8 bytes is a conservative
        // upper bound even for non-English text; split only at Character boundaries.
        var chunks: [String] = [], chunk = ""
        for character in content {
            let next = String(character)
            if !chunk.isEmpty && (chunk.utf8.count + next.utf8.count) > 450 {
                chunks.append(chunk); chunk = ""
            }
            chunk += next
        }
        if !chunk.isEmpty { chunks.append(chunk) }
        return chunks.map { ["type": "session.commentary.append", "delegation_id": delegationID,
                             "content": $0, "event_id": UUID().uuidString] }
    }
}

struct LiveTranscriptFragment: Codable, Identifiable {
    let id: String
    let role: String
    let delta: String
    let startMS: Double
    let endMS: Double
}

struct LiveToolRecord: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var input: String
    var output: String = ""
    var images: [LiveImageResult]? = nil
    var state: String = "running"
    var startedAt: Date = Date()
    var finishedAt: Date?
    var needsAttention: Bool = true

    mutating func finish(_ result: String) {
        output = result; finishedAt = Date()
        let json = (try? JSONSerialization.jsonObject(with: Data(result.utf8))) as? [String: Any]
        let status = (json?["status"] as? String ?? "").lowercased()
        if json?["error"] != nil || ["error", "failed", "blocked"].contains(status) { state = "failed"; needsAttention = true }
        else if ["pending", "requires_confirmation", "needs_confirmation", "requires_action"].contains(status) { state = "needs input"; needsAttention = true }
        else if ["success", "completed", "ok"].contains(status) || json?["success"] as? Bool == true { state = "completed" }
        else { state = "returned" }
    }
}

struct LiveActivityRecord: Codable, Equatable {
    var state: String = "thinking"
    var summary: String = ""
    var tools: [LiveToolRecord] = []
    var spoken: Bool = false
    var keepVisible: Bool { state != "complete" || tools.contains { $0.needsAttention || !["returned", "completed"].contains($0.state) } }
    var defaultExpanded: Bool { !spoken || keepVisible }
    var contextText: String {
        ([summary.isEmpty ? "Reasoning & tools: " + state : summary] + tools.map {
            "Tool \($0.name) [\($0.state)]\nInputs: \($0.input)\nResult: \($0.output)"
        }).joined(separator: "\n\n")
    }
}

struct LiveImageResult: Codable, Identifiable, Equatable {
    var id: String
    var title: String
    var url: String?
    var thumbnailURL: String?
    var sourceURL: String?
    var state: String
    var failureReason: String?
}
