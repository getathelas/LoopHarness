//
//  LoopThreadEventBridge.swift
//  Loop
//
//  Translates the existing sub-agent completion signal
//  (`.subAgentDidPostMessage`) into the voice agent's `LoopThreadUpdated`
//  protocol (`.loopThreadUpdated`). This is the seam that lets asynchronous
//  background work surface in a live voice conversation: when an agent posts a
//  result back into a thread, we emit a speakable update that
//  `RealtimeVoiceSession` injects into the session.
//
//  Kept separate from the session so the mapping exists app-wide (a session
//  can start after work was dispatched) and so the "when does a thread update"
//  policy lives in one place.
//

import Foundation

final class LoopThreadEventBridge {

    static let shared = LoopThreadEventBridge()

    private var activated = false

    private init() {}

    /// Begin translating sub-agent completions into thread updates. Idempotent
    /// — safe to call every time a voice session starts.
    func activate() {
        guard !activated else { return }
        activated = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(subAgentDidPost(_:)),
            name: .subAgentDidPostMessage,
            object: nil
        )
    }

    @objc private func subAgentDidPost(_ note: Notification) {
        guard let info = note.userInfo,
              let threadId = info["conversationId"] as? String else { return }

        let summary = (info["summary"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        // Fall back to the thread's latest status summary when the posted
        // summary is empty (e.g. a failed agent that had no result body).
        let spoken: String
        let updateType: LoopThreadUpdateType
        if !summary.isEmpty {
            spoken = summary
            updateType = .complete
        } else if let status = LoopThreadService.shared.status(threadId: threadId) {
            spoken = status.latestSummary
            updateType = status.status == .failed ? .failed : .complete
        } else {
            return
        }

        // A completed hand-off the user asked for should interrupt whatever the
        // voice agent is currently saying so the update lands promptly.
        let update = LoopThreadUpdate(
            threadId: threadId,
            updateType: updateType,
            spokenSummary: spoken,
            shouldInterrupt: true
        )

        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .loopThreadUpdated,
                object: nil,
                userInfo: update.userInfo
            )
        }
    }
}
