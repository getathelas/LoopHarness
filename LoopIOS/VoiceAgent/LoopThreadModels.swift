//
//  LoopThreadModels.swift
//  Loop
//
//  Shared vocabulary for the realtime voice agent's thread layer. A "Loop
//  thread" is just a `SimpleConversation` — the voice agent is a conversational
//  router on top of the existing thread/sub-agent system, not a new store. These
//  types describe the status of a thread and the asynchronous updates that get
//  injected back into a live voice session.
//
//  Pure Foundation so the model + event vocabulary compiles on every target;
//  the audio/WebSocket session and UI that consume it are iOS-only.
//

import Foundation

/// Coarse lifecycle of the work happening on a thread, surfaced to the voice
/// agent via `getLoopThreadStatus`. Maps onto the underlying sub-agent state
/// but is intentionally phrased in message-not-task terms so the model never
/// leaks implementation details unless asked.
enum LoopThreadStatus: String, Codable {
    /// Dispatched but the agent hasn't started reasoning yet.
    case queued
    /// The agent is actively working (making model calls / running tools).
    case running
    /// The agent paused for something external (rare in v1).
    case waiting
    /// The agent finished and posted a result back into the thread.
    case complete
    /// The agent errored out or was cancelled.
    case failed

    /// A short, speakable phrase the voice agent can use if it needs to
    /// narrate status conversationally.
    var spokenPhrase: String {
        switch self {
        case .queued:   return "queued up"
        case .running:  return "working on it"
        case .waiting:  return "waiting on something"
        case .complete: return "done"
        case .failed:   return "ran into a problem"
        }
    }
}

/// The kind of thing that changed on a thread. `progress` is the only value
/// used in the MVP; the enum leaves room for richer classification later
/// (e.g. `question`, `artifactReady`) without breaking the event payload.
enum LoopThreadUpdateType: String, Codable {
    case progress
    case complete
    case failed
}

/// A single asynchronous update about a thread, delivered while a voice
/// session may be live. `RealtimeVoiceSession` turns this into a conversation
/// item so the agent can speak the `spokenSummary`; when `shouldInterrupt` is
/// true it cancels any in-flight speech first so the update lands immediately.
struct LoopThreadUpdate {
    let threadId: String
    let updateType: LoopThreadUpdateType
    /// Natural-language summary written to be read aloud — no status
    /// decoration, no ids, just what the user would want to hear.
    let spokenSummary: String
    /// When true, interrupt whatever the agent is currently saying to deliver
    /// this update. Completions of explicitly-requested work interrupt;
    /// incremental progress does not.
    let shouldInterrupt: Bool

    /// NotificationCenter userInfo round-trip. Kept here so the producer
    /// (`LoopThreadEventBridge`) and consumer (`RealtimeVoiceSession`) can't
    /// drift on key names.
    var userInfo: [String: Any] {
        return [
            "threadId": threadId,
            "updateType": updateType.rawValue,
            "spokenSummary": spokenSummary,
            "shouldInterrupt": shouldInterrupt,
        ]
    }

    init(threadId: String,
         updateType: LoopThreadUpdateType = .progress,
         spokenSummary: String,
         shouldInterrupt: Bool) {
        self.threadId = threadId
        self.updateType = updateType
        self.spokenSummary = spokenSummary
        self.shouldInterrupt = shouldInterrupt
    }

    init?(userInfo: [AnyHashable: Any]?) {
        guard let info = userInfo,
              let threadId = info["threadId"] as? String,
              let summary = info["spokenSummary"] as? String else {
            return nil
        }
        self.threadId = threadId
        self.updateType = (info["updateType"] as? String)
            .flatMap(LoopThreadUpdateType.init(rawValue:)) ?? .progress
        self.spokenSummary = summary
        self.shouldInterrupt = (info["shouldInterrupt"] as? Bool) ?? false
    }
}

extension Notification.Name {
    /// Posted (main queue) whenever a thread produces an update the voice
    /// agent should hear about. `userInfo` decodes to a `LoopThreadUpdate`.
    static let loopThreadUpdated = Notification.Name("loop.voiceAgent.threadUpdated")
}

/// Lightweight summary of a thread for `listLoopThreads`. Not persisted — built
/// on demand from the conversation store + sub-agent registry.
struct LoopThreadSummary {
    let threadId: String
    let title: String
    let status: LoopThreadStatus
    let latestSummary: String
    let updatedAt: Date
}
