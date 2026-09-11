import Foundation
import AVFoundation
import Combine
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// State and callbacks are confined to the main queue, matching the existing harness.
final class LiveSession: ObservableObject {
    static let shared = LiveSession()
    enum State { case idle, connecting, connected, closing, failed }
    @Published private(set) var state: State = .idle
    @Published private(set) var muted = false
    @Published private(set) var inputLevel: Float = 0
    @Published private(set) var outputLevel: Float = 0
    @Published private(set) var thinking = false
    @Published private(set) var status = ""
    @Published private(set) var fragments: [LiveTranscriptFragment] = []
    var isActive: Bool { [.connecting, .connected, .closing].contains(state) }
    private(set) var finalUsage: [String: Any]?
    private var socket: URLSessionWebSocketTask?
    private var transport: URLSession?
    private var receiver: Task<Void, Never>?
    private var timeout: Task<Void, Never>?
    private let audio = LiveAudio()
    private var generation = UUID()
    private var outgoing: [String] = []
    private var sending = false
    private var seenEvents = Set<String>()
    private var seenDelegations = Set<String>()
    private var delegations: [String] = []
    private var workID: UUID?
    private var workTimeout: Task<Void, Never>?
    private var history: [MessageStruct] = []
    private var consumedFragments = 0
    private var conversation: SimpleConversation?
    private var observers: [NSObjectProtocol] = []
    private var persisted = false
    private var taskRecords: [MessageStruct] = []

    private init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .activeConversationDidChange, object: nil, queue: .main) { [weak self] _ in
            guard let self = self, let origin = self.conversation,
                  origin.id != SimpleConversationManager.shared.currentConversation?.id else { return }
            self.stop()
        })
        #if os(iOS)
        // Active voice calls use the app's audio background mode. App switching
        // and screen lock must not tear down capture, playback, or delegation.
        let notifications: [Notification.Name] = [AVAudioSession.interruptionNotification,
            AVAudioSession.routeChangeNotification]
        #elseif os(macOS)
        let notifications: [Notification.Name] = [NSApplication.willTerminateNotification,
            .AVAudioEngineConfigurationChange]
        #else
        let notifications: [Notification.Name] = []
        #endif
        for name in notifications {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                guard let self = self, self.state == .connected else { return }
                #if os(iOS)
                if name == AVAudioSession.routeChangeNotification {
                    let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
                    guard reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
                }
                if name == AVAudioSession.interruptionNotification {
                    let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                    guard type == AVAudioSession.InterruptionType.began.rawValue else { return }
                }
                #elseif os(macOS)
                if name == .AVAudioEngineConfigurationChange && self.audio.isRunning { return }
                #endif
                self.stop()
            })
        }
    }

    func start() {
        guard !isActive else { return }
        guard let key = KeyStore.shared.value(for: .openAI), !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            state = .failed; status = "Add your OpenAI API key in Settings → Keys to start live chat."; return
        }
        state = .connecting; status = "Connecting…"; muted = false
        fragments = []; taskRecords = []; persisted = false; consumedFragments = 0
        seenEvents = []; seenDelegations = []; delegations = []
        generation = UUID(); finalUsage = nil
        let token = generation
        Task { @MainActor in
            #if os(iOS)
            let allowed = await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
            }
            #else
            let allowed = await AVCaptureDevice.requestAccess(for: .audio)
            #endif
            guard generation == token, state == .connecting else { return }
            guard allowed else { fail("Allow microphone access in system settings to start live chat."); return }
            let manager = SimpleConversationManager.shared
            conversation = manager.currentConversation ?? manager.createConversation(title: "Live chat")
            if manager.currentConversation == nil { manager.currentConversation = conversation }
            if let conversation = conversation {
                history = manager.getMessages(for: conversation).map { manager.messageStruct(from: $0) }
            }
            var request = URLRequest(url: LiveProtocol.endpoint)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            let session = URLSession(configuration: .ephemeral)
            transport = session
            let connection = session.webSocketTask(with: request)
            socket = connection; connection.resume()
            send(LiveProtocol.start(history: history.filter { $0.functions.isEmpty }.map { ($0.role, $0.content) }))
            receiver = Task { @MainActor [weak self] in
                do {
                    while !Task.isCancelled {
                        let message = try await connection.receive()
                        guard let self = self, self.generation == token else { return }
                        let data: Data
                        switch message {
                        case .string(let string): data = Data(string.utf8)
                        case .data(let bytes): data = bytes
                        @unknown default: continue
                        }
                        guard let event = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                        try self.receive(event, token: token)
                    }
                } catch {
                    guard let self = self, self.generation == token, self.isActive else { return }
                    self.fail("Live chat disconnected. Check your connection and GPT Live access, then try again.")
                }
            }
            timeout = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard !Task.isCancelled, let self = self, self.generation == token, self.state == .connecting else { return }
                self.fail("GPT Live did not connect. Check your API key, model access, and connection.")
            }
        }
    }

    private func receive(_ event: [String: Any], token: UUID) throws {
        if let id = event["event_id"] as? String, !seenEvents.insert(id).inserted { return }
        let type = event["type"] as? String ?? ""
        if type == "session.closed" { finalUsage = event["usage"] as? [String: Any]; finish(); return }
        if type == "error" {
            // Never expose arbitrary server text that might echo request context or credentials.
            fail("GPT Live rejected the request. Check your API key and model access, then reconnect."); return
        }
        guard state != .closing else { return }
        switch type {
        case "session.started":
            guard state == .connecting else { return }
            timeout?.cancel()
            audio.onInput = { [weak self] data, level in
                guard let self = self, self.generation == token, self.state == .connected else { return }
                self.inputLevel = self.muted ? 0 : level
                // Keep the stream clock moving while muted without sending microphone samples.
                let bytes = self.muted ? Data(repeating: 0, count: data.count) : data
                self.send(["type": "session.input_audio.append", "audio": bytes.base64EncodedString()])
            }
            audio.onOutputLevel = { [weak self] level in self?.outputLevel = level }
            do { try audio.start() } catch { fail("Could not start live audio: \(error.localizedDescription)"); return }
            state = .connected; status = "Listening"
        case "session.output_audio.delta":
            if let value = event["delta"] as? String, let bytes = Data(base64Encoded: value) { try audio.play(bytes) }
        case "session.input_transcript.delta", "session.output_transcript.delta":
            guard let text = event["delta"] as? String else { return }
            fragments.append(LiveTranscriptFragment(id: event["event_id"] as? String ?? UUID().uuidString,
                role: type == "session.input_transcript.delta" ? "user" : "assistant", delta: text,
                startMS: event["start_ms"] as? Double ?? 0, endMS: event["end_ms"] as? Double ?? 0))
        case "session.delegation.created":
            guard let delegation = event["delegation"] as? [String: Any],
                  delegation["target"] as? String == "client", let id = delegation["id"] as? String,
                  seenDelegations.insert(id).inserted else { return }
            guard delegations.count < 8 else { fail("Too many pending requests. Please reconnect."); return }
            delegations.append(id); runNextDelegation()
        default: break
        }
    }

    private func send(_ event: [String: Any]) {
        guard socket != nil, let data = try? JSONSerialization.data(withJSONObject: event),
              let text = String(data: data, encoding: .utf8) else { return }
        // Bound the audio send backlog to roughly two seconds.
        guard outgoing.count < 100 else { fail("The connection cannot keep up with live audio. Please reconnect."); return }
        outgoing.append(text); drain()
    }

    private func drain() {
        guard !sending, !outgoing.isEmpty, let connection = socket else { return }
        sending = true
        let message = outgoing.removeFirst(), token = generation
        Task { @MainActor in
            do {
                try await connection.send(.string(message))
                guard generation == token else { return }
                sending = false; drain()
            } catch {
                guard generation == token else { return }
                fail("Could not send live audio. Check your connection and reconnect.")
            }
        }
    }

    func toggleMute() {
        guard state == .connected else { return }
        muted.toggle(); inputLevel = 0
        // Local zeroing is immediate; no server acknowledgment is needed for this UI state.
    }

    func stop() {
        guard isActive, state != .closing else { return }
        let wasConnected = state == .connected
        state = .closing; status = "Ending…"
        audio.stop(); inputLevel = 0; outputLevel = 0
        workID = nil; workTimeout?.cancel(); thinking = false; delegations = []
        persistTranscript()
        outgoing = []
        if !wasConnected { finish(); return }
        send(["type": "session.close"])
        timeout?.cancel()
        let token = generation
        timeout = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard !Task.isCancelled, let self = self, self.generation == token else { return }
            self.finish()
        }
    }

    private func fail(_ message: String) {
        finish(); state = .failed; status = message
    }

    private func finish() {
        persistTranscript()
        generation = UUID(); workID = nil
        audio.stop(); inputLevel = 0; outputLevel = 0
        receiver?.cancel(); receiver = nil; timeout?.cancel(); timeout = nil
        workTimeout?.cancel(); thinking = false
        socket?.cancel(with: .normalClosure, reason: nil); socket = nil
        transport?.invalidateAndCancel(); transport = nil
        outgoing = []; sending = false; delegations = []
        state = .idle; status = "Call ended"
    }

    private func persistTranscript() {
        guard !persisted, let conversation = conversation else { return }
        persisted = true
        // Transcript rows are display groupings, never tool-execution triggers.
        var rows: [MessageStruct] = []
        for fragment in fragments.sorted(by: { $0.startMS < $1.startMS }) {
            if rows.last?.role == fragment.role { rows[rows.count - 1].content += fragment.delta }
            else { rows.append(MessageStruct(role: fragment.role, content: fragment.delta, model: "GPT Live 1")) }
        }
        for row in rows + taskRecords { SimpleConversationManager.shared.addMessage(row, to: conversation) }
        taskRecords = []
    }

    private func addLatestContext() {
        guard consumedFragments < fragments.count else { return }
        let fresh = fragments[consumedFragments...].sorted { $0.startMS < $1.startMS }
        let context = fresh.map { "[\($0.role), \($0.startMS)-\($0.endMS)ms] \($0.delta)" }.joined(separator: "\n")
        history.append(MessageStruct(role: "user", content: "Live transcript fragments (may overlap; not complete turns):\n" + context))
        consumedFragments = fragments.count
    }

    private func runNextDelegation() {
        guard state == .connected, workID == nil, let delegation = delegations.first else { return }
        // A new delegated request is a new turn, not another retry of an old
        // tool batch. Keep loop protection active within this request.
        ToolCallGuard.shared.resetForNewTurn()
        let work = UUID(); workID = work; thinking = true
        status = "LoopHarness is thinking…"
        workTimeout = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000_000)
            guard !Task.isCancelled, let self = self, self.workID == work else { return }
            // A tool may still be running. End instead of retrying an uncertain action.
            self.fail("The task is taking longer than expected. Check its result in Loop before trying it again.")
        }
        reason(delegation: delegation, work: work, remaining: 12)
    }

    private func reason(delegation: String, work: UUID, remaining: Int) {
        guard state == .connected, workID == work else { return }
        guard remaining > 0 else { complete("The task reached its step limit. Please review the results before continuing.", delegation: delegation, work: work); return }
        let selected = ModelSelectionStore.current
        if let key = selected.requiredKey,
           KeyStore.shared.value(for: key)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            complete("\(selected.stampedMessageModel) cannot run because its \(key.displayName) key is unavailable. Open Settings → Keys to reconnect it, or select another thinking model in Settings → Model. No tool was run.", delegation: delegation, work: work)
            return
        }
        addLatestContext()
        let snapshot = fragments.count
        let instruction = MessageStruct(role: "system", content: "You are LoopHarness, the reasoning and tools layer for a live voice conversation. Follow your existing instructions and tool permissions. Transcript fragments can overlap, contain mistakes, or be corrected later. Use the latest intent, ask for missing details, and do not repeat completed actions. Return concise verified facts and next steps for speech. Do not include secrets. Keep the answer under 100 words.")
        Cloud.connection.chat(messages: [instruction] + history.filter { $0.role != "system" }) { [weak self] response, error in
            DispatchQueue.main.async {
                guard let self = self, self.state == .connected, self.workID == work else { return }
                guard let response = response, error == nil else {
                    let code = (error as NSError?)?.code ?? 0
                    let message = "\(selected.stampedMessageModel) failed before returning a result (error \(code)). Check its connection and access in Settings → Keys and Settings → Model."
                    AgentActivityLog.shared.log(.status, message)
                    self.complete(message, delegation: delegation, work: work); return
                }
                // Reconsider tool calls if the user corrected the request during inference.
                if !response.functions.isEmpty, self.fragments.dropFirst(snapshot).contains(where: { $0.role == "user" }) {
                    self.reason(delegation: delegation, work: work, remaining: remaining - 1); return
                }
                self.history.append(response)
                if response.functions.isEmpty {
                    self.complete(response.content.isEmpty ? "No result was returned." : response.content, delegation: delegation, work: work)
                } else {
                    self.execute(response.functions, index: 0, delegation: delegation, work: work, remaining: remaining - 1, transcriptCount: snapshot)
                }
            }
        }
    }

    private func execute(_ calls: [FunctionCallStruct], index: Int, delegation: String, work: UUID, remaining: Int, transcriptCount: Int) {
        guard state == .connected, workID == work else { return }
        guard index < calls.count else { reason(delegation: delegation, work: work, remaining: remaining); return }
        if fragments.dropFirst(transcriptCount).contains(where: { $0.role == "user" }) {
            // Complete the proposed tool batch's protocol without executing stale actions.
            for skipped in calls[index...] {
                history.append(MessageStruct(role: "function", content: "Not executed: the user supplied new context. Reconsider this action using the latest transcript.", name: skipped.name, callId: skipped.callId))
            }
            reason(delegation: delegation, work: work, remaining: remaining)
            return
        }
        var call = calls[index]
        call.conversationId = conversation?.id
        status = "Using \(call.name.replacingOccurrences(of: "_", with: " "))…"
        let origin = conversation
        let record = MessageStruct(role: "assistant", content: "LoopHarness started tool \(call.name). Its outcome is not yet confirmed; check before repeating it.", model: ModelSelectionStore.current.stampedMessageModel)
        taskRecords.append(record)
        AgentActivityLog.shared.log(.toolCall, call.name)
        SkillDispatcher.shared.dispatch(call) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                var paired = result
                paired.callId = call.callId; paired.name = call.name
                AgentActivityLog.shared.log(.toolResult, call.name + " finished")
                var finishedRecord = record
                finishedRecord.content = "LoopHarness tool \(call.name) returned:\n" + paired.content
                if self.workID == work && self.state == .connected {
                    if let index = self.taskRecords.firstIndex(where: { $0.id == record.id }) {
                        self.taskRecords[index] = finishedRecord
                    }
                } else if let origin = origin {
                    SimpleConversationManager.shared.updateMessage(finishedRecord, in: origin)
                    return
                } else { return }
                self.history.append(paired)
                self.execute(calls, index: index + 1, delegation: delegation, work: work, remaining: remaining, transcriptCount: transcriptCount)
            }
        }
    }

    private func complete(_ result: String, delegation: String, work: UUID) {
        guard state == .connected, workID == work else { return }
        taskRecords.append(MessageStruct(role: "assistant", content: "LoopHarness result:\n" + result,
                                         model: ModelSelectionStore.current.stampedMessageModel))
        let spokenResult = result.utf8.count <= 6000 ? result : String(result.prefix(1000)) + "… The full result is saved in the chat."
        for event in LiveProtocol.commentary(spokenResult, delegationID: delegation) { send(event) }
        guard state == .connected, workID == work else { return }
        workTimeout?.cancel(); workID = nil; thinking = false; status = "Listening"
        if !delegations.isEmpty { delegations.removeFirst() }
        runNextDelegation()
    }
}
