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
    enum State { case idle, connecting, reconnecting, connected, closing, failed }
    @Published private(set) var state: State = .idle
    @Published private(set) var muted = false
    @Published private(set) var inputLevel: Float = 0
    @Published private(set) var outputLevel: Float = 0
    @Published private(set) var thinking = false
    @Published private(set) var status = ""
    @Published private(set) var fragments: [LiveTranscriptFragment] = []
    var isActive: Bool { [.connecting, .reconnecting, .connected, .closing].contains(state) }
    private(set) var finalUsage: [String: Any]?
    private var socket: LiveConnection?
    private var makeConnection: (String) -> LiveConnection = { LiveWebSocket(key: $0) }
    private var connectionGeneration = UUID()
    private var reconnectTask: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var retryCount = 0
    private var connectedAt: Date?
    private var lastLiveness = Date()
    private var pingPending = false
    private var initialHistory: [(role: String, content: String)] = []
    private var currentDelegations = Set<String>()
    private var deferredResults: [String] = []
    private var workCanContinue: Bool { state == .connected || state == .reconnecting }
    @Published private(set) var connectionDiagnostic = ""
    private var receiver: Task<Void, Never>?
    private var timeout: Task<Void, Never>?
    private let audio = LiveAudio()
    private var generation = UUID()
    private var outgoing: [String] = []
    private var sending = false
    private var seenEvents = Set<String>()
    private var seenDelegations = Set<String>()
    private var delegations: [String] = []
    private var pendingImages: [String: (origin: SimpleConversation, rowID: String, toolID: String, snapshot: MessageStruct)] = [:]
    private var pendingPDFs: [String: (origin: SimpleConversation, generation: UUID, row: MessageStruct)] = [:]
    private var workID: UUID?
    private var workTimeout: Task<Void, Never>?
    private var history: [MessageStruct] = []
    private var consumedFragments = 0
    private var conversation: SimpleConversation?
    private var observers: [NSObjectProtocol] = []
    private var persisted = false
    @Published private(set) var liveMessages: [MessageStruct] = []
    var conversationID: String? { conversation?.id }

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
                self.fail("Live audio was interrupted. Reconnect to continue.")
            })
        }
    }

    func start() {
        guard !isActive else { return }
        guard let key = KeyStore.shared.value(for: .openAI), !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            state = .failed; status = "Add your OpenAI API key in Settings → Keys to start live chat."; return
        }
        state = .connecting; status = "Connecting…"; muted = false
        fragments = []; liveMessages = []; persisted = false; consumedFragments = 0
        seenEvents = []; seenDelegations = []; delegations = []
        generation = UUID(); finalUsage = nil
        retryCount = 0; connectedAt = nil; currentDelegations = []; deferredResults = []
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
            initialHistory = history.filter { $0.functions.isEmpty }.map { ($0.role, $0.content) }
            connect(key: key)
        }
    }

    private func connect(key: String) {
        guard state == .connecting || state == .reconnecting else { return }
        let token = UUID(); connectionGeneration = token
        let connection = makeConnection(key)
        socket = connection
        let context = initialHistory + liveMessages.map { ($0.role, $0.content) }
        var start = LiveProtocol.start(history: context)
        if retryCount > 0, var configuration = start["session"] as? [String: Any] {
            let recovery = " The voice connection was interrupted. Continue this conversation from the supplied history. Do not repeat prior actions. Existing backend work remains owned by LoopHarness; wait for its result instead of delegating it again. Ask the user to repeat anything unheard during the gap."
            configuration["instructions"] = (configuration["instructions"] as? String ?? "") + recovery
            start["session"] = configuration
        }
        send(start)
        receiver = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let data: Data
                do { data = try await connection.receive() }
                catch {
                    guard let self, self.connectionGeneration == token else { return }
                    self.connectionFailed(error, stage: "receive"); return
                }
                guard let self, self.connectionGeneration == token else { return }
                self.lastLiveness = Date()
                // Bad payloads and playback errors are not socket failures.
                guard let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                    self.recordConnectionIssue(stage: "invalid-event"); continue
                }
                do { try self.receive(event, token: self.generation) }
                catch { self.recordConnectionIssue(stage: "playback", error: error) }
            }
        }
        timeout?.cancel()
        timeout = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard !Task.isCancelled, let self, self.connectionGeneration == token,
                  self.state == .connecting || self.state == .reconnecting else { return }
            self.connectionFailed(URLError(.timedOut), stage: "startup-timeout")
        }
    }

    private func recordConnectionIssue(stage: String, error: Error? = nil) {
        connectionDiagnostic = LiveRecovery.diagnostic(stage: stage, error: error,
            httpStatus: socket?.httpStatus, closeCode: socket?.closeCode ?? 0,
            retry: retryCount, queued: outgoing.count)
        AgentActivityLog.shared.log(.status, connectionDiagnostic)
        var recent = UserDefaults.standard.stringArray(forKey: "LiveConnectionDiagnostics") ?? []
        recent.append(ISO8601DateFormatter().string(from: Date()) + " " + connectionDiagnostic)
        UserDefaults.standard.set(Array(recent.suffix(40)), forKey: "LiveConnectionDiagnostics")
    }

    private func connectionFailed(_ error: Error, stage: String) {
        guard isActive else { return }
        if state == .closing { finish(); return }
        recordConnectionIssue(stage: stage, error: error)
        if !LiveRecovery.retryable(error: error, httpStatus: socket?.httpStatus, closeCode: socket?.closeCode ?? 0) {
            fail("Live could not connect. Check your API key, model access, or secure connection. Your conversation is saved.")
            return
        }
        recoverConnection()
    }

    private func recoverConnection() {
        guard state == .connected || state == .connecting || state == .reconnecting else { return }
        // Only a stable connection resets the budget; flapping must remain bounded.
        if let connectedAt, Date().timeIntervalSince(connectedAt) >= 30 { retryCount = 0 }
        connectedAt = nil
        guard retryCount < LiveRecovery.retryDelays.count else {
            fail("Couldn't restore live audio after five retries. Your conversation is saved. Tap Try again when you're ready.")
            return
        }
        let delay = LiveRecovery.retryDelays[retryCount]
        retryCount += 1
        state = .reconnecting
        status = "Connection interrupted · Reconnecting (\(retryCount)/\(LiveRecovery.retryDelays.count))…"
        resetConnection()
        audio.resetOutput(); inputLevel = 0; outputLevel = 0
        // Keep the current backend work and its IDs; never replay it on reconnect.
        if workID != nil { delegations = Array(delegations.prefix(1)) }
        else { delegations = [] }
        currentDelegations = []; seenEvents = []
        let token = connectionGeneration
        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self, self.state == .reconnecting,
                  self.connectionGeneration == token else { return }
            guard let key = KeyStore.shared.value(for: .openAI), !key.isEmpty else {
                self.fail("Add your OpenAI API key in Settings → Keys. Your conversation is saved."); return
            }
            self.connect(key: key)
        }
    }

    private func resetConnection() {
        connectionGeneration = UUID()
        reconnectTask?.cancel(); reconnectTask = nil
        heartbeat?.cancel(); heartbeat = nil; pingPending = false
        receiver?.cancel(); receiver = nil; timeout?.cancel(); timeout = nil
        socket?.cancel(); socket = nil
        outgoing = []; sending = false
    }

    private func startHeartbeat() {
        heartbeat?.cancel()
        lastLiveness = Date(); pingPending = false
        let token = connectionGeneration
        heartbeat = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(LiveRecovery.heartbeatInterval * 1_000_000_000))
                guard !Task.isCancelled, let self, self.connectionGeneration == token,
                      self.state == .connected else { return }
                self.checkHeartbeat()
            }
        }
    }

    private func checkHeartbeat(now: Date = Date()) {
        guard state == .connected, let connection = socket else { return }
        // Inbound events also prove liveness; silence alone is not an error.
        if now.timeIntervalSince(lastLiveness) >= LiveRecovery.heartbeatGrace {
            connectionFailed(URLError(.timedOut), stage: "heartbeat-timeout"); return
        }
        guard !pingPending else { return }
        pingPending = true
        let token = connectionGeneration
        connection.ping { [weak self] error in
            DispatchQueue.main.async {
                guard let self, self.connectionGeneration == token, self.state == .connected else { return }
                self.pingPending = false
                if let error { self.recordConnectionIssue(stage: "ping", error: error) }
                else { self.lastLiveness = Date() }
            }
        }
    }

    private func receive(_ event: [String: Any], token: UUID) throws {
        if let id = event["event_id"] as? String, !seenEvents.insert(id).inserted { return }
        let type = event["type"] as? String ?? ""
        if type == "session.closed" {
            finalUsage = event["usage"] as? [String: Any]
            if state == .closing { finish() }
            else {
                let reason = event["reason"] as? String
                let known = ["connection_lost", "expired", "content", "close_requested", "remote_hangup"]
                recordConnectionIssue(stage: "server-close-" + (known.contains(reason ?? "") ? reason! : "unknown"))
                if reason == "connection_lost" || reason == "expired" {
                    recoverConnection()
                } else if reason == "content" {
                    fail("Live chat ended by the service's safety filter. Your conversation is saved.")
                } else { finish() }
            }
            return
        }
        if type == "error" {
            if state == .closing { finish(); return }
            let details = event["error"] as? [String: Any] ?? [:]
            let code = details["code"] as? String ?? ""
            let kind = details["type"] as? String ?? ""
            let known = ["server_error", "server_is_overloaded", "rate_limit_exceeded", "slow_down",
                         "invalid_api_key", "insufficient_quota", "model_not_found", "immutable_field_update"]
            recordConnectionIssue(stage: "server-error-" + (known.contains(code) ? code : "other"))
            if ["server_error", "server_is_overloaded", "rate_limit_exceeded", "slow_down"].contains(code)
                || kind == "server_error" { recoverConnection() }
            else if ["invalid_api_key", "insufficient_quota", "model_not_found"].contains(code)
                || kind == "authentication_error" || state == .connecting || state == .reconnecting {
                fail("Live could not start. Check your API key, quota and model access. Your conversation is saved.")
            } else {
                // A rejected command is not a terminal session event.
                status = "A live request was rejected · Conversation still connected"
            }
            return
        }
        guard state != .closing else { return }
        switch type {
        case "session.started":
            guard state == .connecting || state == .reconnecting else { return }
            timeout?.cancel()
            let wasRecovering = state == .reconnecting
            audio.onInput = { [weak self] data, level in
                guard let self = self, self.generation == token, self.state == .connected else { return }
                self.inputLevel = self.muted ? 0 : level
                // Keep the stream clock moving while muted without sending microphone samples.
                let bytes = self.muted ? Data(repeating: 0, count: data.count) : data
                self.send(["type": "session.input_audio.append", "audio": bytes.base64EncodedString()])
            }
            audio.onPlaybackRecovery = { [weak self] in self?.recordConnectionIssue(stage: "playback-catchup") }
            audio.onOutputLevel = { [weak self] level in self?.outputLevel = level }
            do { if !audio.isRunning { try audio.start() } } catch { fail("Could not start live audio: \(error.localizedDescription)"); return }
            state = .connected; connectedAt = Date()
            status = wasRecovering ? "Reconnected · Please repeat anything missed" : "Listening"
            audio.playCue(.connected)
            startHeartbeat()
            for result in deferredResults {
                for event in LiveProtocol.commentary(result, delegationID: nil) { send(event) }
            }
            deferredResults = []
            runNextDelegation()
        case "session.output_audio.delta":
            if let value = event["delta"] as? String, let bytes = Data(base64Encoded: value) { try audio.play(bytes) }
        case "session.input_transcript.delta", "session.output_transcript.delta":
            guard let text = event["delta"] as? String else { return }
            fragments.append(LiveTranscriptFragment(id: event["event_id"] as? String ?? UUID().uuidString,
                role: type == "session.input_transcript.delta" ? "user" : "assistant", delta: text,
                startMS: event["start_ms"] as? Double ?? 0, endMS: event["end_ms"] as? Double ?? 0))
            let role = type == "session.input_transcript.delta" ? "user" : "assistant"
            if role == "assistant" {
                for index in liveMessages.indices where liveMessages[index].liveActivity?.state == "complete" {
                    liveMessages[index].liveActivity?.spoken = true
                }
            }
            if let last = liveMessages.last, last.role == role, last.model == "GPT Live 1" {
                liveMessages[liveMessages.count - 1].content += text
            } else {
                liveMessages.append(MessageStruct(role: role, content: text, model: "GPT Live 1"))
            }
        case "session.delegation.created":
            guard let delegation = event["delegation"] as? [String: Any],
                  delegation["target"] as? String == "client", let id = delegation["id"] as? String,
                  seenDelegations.insert(id).inserted else { return }
            guard delegations.count < 8 else { fail("Too many pending requests. Please reconnect."); return }
            currentDelegations.insert(id)
            delegations.append(id); runNextDelegation()
        default: break
        }
    }

    private func send(_ event: [String: Any]) {
        let type = event["type"] as? String
        // A replacement socket accepts only startup until session.started.
        guard state == .connected || type == "session.start" || type == "session.close" else { return }
        guard socket != nil, let data = try? JSONSerialization.data(withJSONObject: event),
              let text = String(data: data, encoding: .utf8) else { return }
        // Bound the audio send backlog to roughly two seconds.
        guard outgoing.count < 100 else {
            recordConnectionIssue(stage: "send-backpressure")
            recoverConnection(); return
        }
        outgoing.append(text); drain()
    }

    private func drain() {
        guard !sending, !outgoing.isEmpty, let connection = socket else { return }
        sending = true
        let message = outgoing.removeFirst(), token = connectionGeneration
        Task { @MainActor in
            do {
                try await connection.send(message)
                guard connectionGeneration == token else { return }
                sending = false; drain()
            } catch {
                guard connectionGeneration == token else { return }
                connectionFailed(error, stage: "send")
            }
        }
    }

    func toggleMute() {
        guard state == .connected else { return }
        muted.toggle(); inputLevel = 0
        audio.playCue(muted ? .muted : .unmuted)
        // Local zeroing is immediate; no server acknowledgment is needed for this UI state.
    }

    func stop() {
        guard isActive, state != .closing else { return }
        let wasConnected = state == .connected
        state = .closing; status = "Ending…"
        reconnectTask?.cancel(); reconnectTask = nil
        heartbeat?.cancel(); heartbeat = nil
        audio.stop(); inputLevel = 0; outputLevel = 0
        audio.playTerminalCue(.ended)
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
        let shouldAnnounce = isActive
        finish(); state = .failed; status = message
        if shouldAnnounce { audio.playTerminalCue(.disconnected) }
    }

    private func finish() {
        persistTranscript()
        generation = UUID(); workID = nil
        audio.stop(); inputLevel = 0; outputLevel = 0
        resetConnection()
        workTimeout?.cancel(); thinking = false
        delegations = []; currentDelegations = []; deferredResults = []
        state = .idle; status = "Call ended"
    }

    private func persistTranscript() {
        guard !persisted, let conversation = conversation else { return }
        persisted = true
        for index in liveMessages.indices where liveMessages[index].liveActivity != nil && ["thinking", "working"].contains(liveMessages[index].liveActivity?.state ?? "") {
            liveMessages[index].liveActivity?.state = "ended before completion"
        }
        for index in liveMessages.indices {
            if let activity = liveMessages[index].liveActivity { liveMessages[index].content = activity.contextText }
        }
        // Persist exactly the rows shown live, with stable IDs and tool ordering.
        // They remain available to the UI until it reloads the saved conversation.
        for row in liveMessages { SimpleConversationManager.shared.addMessage(row, to: conversation) }
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
        var card = MessageStruct(id: work.uuidString, role: "assistant", content: "Reasoning in progress", model: ModelSelectionStore.current.stampedMessageModel)
        card.liveActivity = LiveActivityRecord()
        liveMessages.append(card)
        status = "LoopHarness is thinking…"
        workTimeout = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000_000)
            guard !Task.isCancelled, let self = self, self.workID == work else { return }
            self.reportSlowWork(work: work, delegation: delegation)
        }
        reason(delegation: delegation, work: work, remaining: 12)
    }

    private func reportSlowWork(work: UUID, delegation: String) {
        guard workCanContinue, workID == work else { return }
        // Keep ownership of this request: starting another copy could repeat
        // a file write or another action whose result is still pending.
        if state == .connected { status = "Still working…" }
        AgentActivityLog.shared.log(.status, "Live task is still running after two minutes")
        for event in LiveProtocol.commentary("The task is still running. I’m keeping it open and will report the result when it finishes.", delegationID: currentDelegations.contains(delegation) ? delegation : nil) {
            send(event)
        }
    }

    private func reason(delegation: String, work: UUID, remaining: Int) {
        guard workCanContinue, workID == work else { return }
        guard remaining > 0 else { complete("The task reached its step limit. Please review the results before continuing.", delegation: delegation, work: work); return }
        let selected = ModelSelectionStore.current
        if let key = selected.requiredKey,
           KeyStore.shared.value(for: key)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            complete("\(selected.stampedMessageModel) cannot run because its \(key.displayName) key is unavailable. Open Settings → Keys to reconnect it, or select another thinking model in Settings → Model.", delegation: delegation, work: work, failed: true)
            return
        }
        addLatestContext()
        let snapshot = fragments.count
        let instruction = MessageStruct(role: "system", content: "You are LoopHarness, the reasoning and tools layer for a live voice conversation. Follow your existing instructions and tool permissions. Transcript fragments can overlap, contain mistakes, or be corrected later. Use the latest intent, ask for missing details, and do not repeat completed actions. Return concise verified facts and next steps for speech. Do not include secrets. When asked to show an existing image, call share_file with its workspace path in this turn. Do not substitute a previous tool log or a textual claim that an image is shown. Keep the answer under 100 words.")
        Cloud.connection.chat(messages: [instruction] + history.filter { $0.role != "system" }) { [weak self] response, error in
            DispatchQueue.main.async {
                guard let self = self, self.workCanContinue, self.workID == work else { return }
                guard let response = response, error == nil else {
                    let code = (error as NSError?)?.code ?? 0
                    let message = "\(selected.stampedMessageModel) failed before returning a result (error \(code)). Check its connection and access in Settings → Keys and Settings → Model."
                    AgentActivityLog.shared.log(.status, message)
                    self.complete(message, delegation: delegation, work: work, failed: true); return
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
        guard workCanContinue, workID == work else { return }
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
        call.liveRequestID = work.uuidString
        if state == .connected { status = "Using \(call.name.replacingOccurrences(of: "_", with: " "))…" }
        let origin = conversation
        let toolID = call.callId ?? UUID().uuidString
        let input = (try? JSONSerialization.data(withJSONObject: call.arguments, options: [.prettyPrinted, .sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let readOnly = ["get_", "list_", "read_", "search_", "find_", "check_", "file_read", "file_list", "file_search"].contains { call.name.hasPrefix($0) }
        if let row = liveMessages.firstIndex(where: { $0.id == work.uuidString }) {
            liveMessages[row].liveActivity?.state = "working"
            liveMessages[row].liveActivity?.tools.append(LiveToolRecord(id: toolID, name: call.name, input: input, needsAttention: !readOnly))
        }
        let startingRecord = liveMessages.first { $0.id == work.uuidString }
        AgentActivityLog.shared.log(.toolCall, call.name)
        audio.playCue(.tool)
        SkillDispatcher.shared.dispatch(call) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                var paired = result
                paired.callId = call.callId; paired.name = call.name
                AgentActivityLog.shared.log(.toolResult, call.name + " finished")
                // Update the same durable request card, including late results
                // after End. Never replay a tool merely to reconstruct its UI.
                guard var record = self.liveMessages.first(where: { $0.id == work.uuidString }) ?? startingRecord,
                      let tool = record.liveActivity?.tools.firstIndex(where: { $0.id == toolID }) else { return }
                record.liveActivity?.tools[tool].finish(paired.content)
                if let gallery = paired.imageGalleryAttachment {
                    record.liveActivity?.tools[tool].images = gallery.items.enumerated().map { offset, item in
                        LiveImageResult(id: gallery.id + "-" + String(offset), title: item.title ?? gallery.query,
                            url: item.originalURL, thumbnailURL: item.thumbnailURL, sourceURL: item.sourceLink, state: "ready")
                    }
                }
                if let file = paired.fileAttachment, file.kind == .image {
                    record.liveActivity?.tools[tool].images = [LiveImageResult(
                        id: file.id, title: file.fileName, url: file.resolvedFileURL.absoluteString,
                        state: file.status == .ready ? "ready" : file.status == .failed ? "failed" : "generating",
                        failureReason: file.failureReason)]
                }
                if record.liveActivity?.tools[tool].images?.contains(where: { $0.state == "generating" }) == true {
                    record.liveActivity?.tools[tool].state = "generating image"
                } else if let images = record.liveActivity?.tools[tool].images, !images.isEmpty {
                    record.liveActivity?.tools[tool].state = images.contains { $0.state == "failed" } ? "failed" : "completed"
                }
                if let activity = record.liveActivity { record.content = activity.contextText }
                if let row = self.liveMessages.firstIndex(where: { $0.id == work.uuidString }) { self.liveMessages[row] = record }
                if self.workID != work || !self.workCanContinue {
                    if ["thinking", "working"].contains(record.liveActivity?.state ?? "") {
                        record.liveActivity?.state = "ended before completion"
                        if let activity = record.liveActivity { record.content = activity.contextText }
                    }
                    if let origin { SimpleConversationManager.shared.updateMessage(record, in: origin) }
                    return
                }
                self.history.append(paired)
                self.execute(calls, index: index + 1, delegation: delegation, work: work, remaining: remaining, transcriptCount: transcriptCount)
            }
        }
    }

    func registerLivePDF(_ attachment: PDFAttachment, requestID: String) {
        guard let origin = conversation,
              liveMessages.contains(where: { $0.id == requestID }) else { return }
        let row = MessageStruct(id: "pdf-" + attachment.id, role: "assistant", content: "",
                                model: "loop-pdf", pdfAttachment: attachment)
        pendingPDFs[attachment.id] = (origin, generation, row)
    }

    /// PDF callbacks must not enter the normal chat host: it can create a
    /// different conversation and stop Live, and its rows get overwritten by
    /// the next transcript delta. Keep the artifact in the Live row stream.
    @discardableResult func receiveLivePDF(_ attachment: PDFAttachment) -> Bool {
        if pendingPDFs[attachment.id] == nil, attachment.status == .generating,
           let origin = conversation,
           let row = liveMessages.first(where: { $0.pdfAttachment?.id == attachment.id }) {
            pendingPDFs[attachment.id] = (origin, generation, row)
        }
        guard let pending = pendingPDFs[attachment.id] else { return false }
        var row = pending.row
        row.content = ""
        row.fileAttachment = nil
        row.pdfAttachment = attachment
        if let url = attachment.fileURL, attachment.status == .ready {
            // FileAttachment is persisted by the conversation store; the
            // render-only PDFAttachment is retained for preview/retry in memory.
            row.fileAttachment = FileAttachment(id: attachment.id, fileURL: url,
                fileName: url.lastPathComponent, kind: .pdf, mimeType: "application/pdf")
        }
        if attachment.status == .failed {
            row.content = "PDF generation failed: " + (attachment.failureReason ?? "Please retry.")
        }
        if let index = liveMessages.firstIndex(where: { $0.id == row.id }) { liveMessages[index] = row }
        else if generation == pending.generation { liveMessages.append(row) }
        if persisted || generation != pending.generation || conversation?.id != pending.origin.id {
            let stored = SimpleConversationManager.shared.getMessages(for: pending.origin)
            if stored.contains(where: { $0.id == row.id }) {
                SimpleConversationManager.shared.updateMessage(row, in: pending.origin)
            } else { SimpleConversationManager.shared.addMessage(row, to: pending.origin) }
        }
        if attachment.status != .generating { pendingPDFs.removeValue(forKey: attachment.id) }
        return true
    }

    func registerLiveImage(_ attachment: ImageAttachment, requestID: String) {
        guard let origin = conversation,
              let record = liveMessages.first(where: { $0.id == requestID }),
              let tool = record.liveActivity?.tools.last(where: { $0.name == "generate_image" && $0.images == nil }) else { return }
        pendingImages[attachment.id] = (origin, record.id, tool.id, record)
    }

    /// Returns true only for images submitted by this Live tool loop. Other
    /// generators retain their existing chat host. Keep routing after End.
    @discardableResult func receiveLiveImage(_ attachment: ImageAttachment) -> Bool {
        guard let pending = pendingImages[attachment.id] else { return false }
        let stored = SimpleConversationManager.shared.getMessages(for: pending.origin).first { $0.id == pending.rowID }
        var record = liveMessages.first { $0.id == pending.rowID }
            ?? stored.map { SimpleConversationManager.shared.messageStruct(from: $0) } ?? pending.snapshot
        guard let index = record.liveActivity?.tools.firstIndex(where: { $0.id == pending.toolID }) else { return true }
        let image = LiveImageResult(id: attachment.id, title: attachment.prompt,
            url: attachment.fileURL?.absoluteString, state: attachment.status.rawValue, failureReason: attachment.failureReason)
        var images = record.liveActivity?.tools[index].images ?? []
        if let i = images.firstIndex(where: { $0.id == image.id }) { images[i] = image } else { images.append(image) }
        record.liveActivity?.tools[index].images = images
        record.liveActivity?.tools[index].state = attachment.status == .generating ? "generating image" : attachment.status == .ready ? "completed" : "failed"
        if attachment.status != .generating { record.liveActivity?.tools[index].finishedAt = Date() }
        if let activity = record.liveActivity { record.content = activity.contextText }
        if let row = liveMessages.firstIndex(where: { $0.id == record.id }) { liveMessages[row] = record }
        if persisted || conversation?.id != pending.origin.id || stored != nil {
            SimpleConversationManager.shared.updateMessage(record, in: pending.origin)
        }
        if attachment.status != .generating { pendingImages.removeValue(forKey: attachment.id) }
        return true
    }

    private func complete(_ result: String, delegation: String, work: UUID, failed: Bool = false) {
        guard workCanContinue, workID == work else { return }
        if let row = liveMessages.firstIndex(where: { $0.id == work.uuidString }) {
            liveMessages[row].content = result
            liveMessages[row].liveActivity?.summary = result
            liveMessages[row].liveActivity?.state = failed ? "failed" : "complete"
            if let activity = liveMessages[row].liveActivity { liveMessages[row].content = activity.contextText }
        }
        let spokenResult = result.utf8.count <= 6000 ? result : String(result.prefix(1000)) + "… The full result is saved in the chat."
        if state == .connected {
            for event in LiveProtocol.commentary(spokenResult,
                delegationID: currentDelegations.contains(delegation) ? delegation : nil) { send(event) }
        } else { deferredResults.append(spokenResult) }
        guard workCanContinue, workID == work else { return }
        workTimeout?.cancel(); workID = nil; thinking = false
        if state == .connected { status = "Listening" }
        if !delegations.isEmpty { delegations.removeFirst() }
        runNextDelegation()
    }
}
