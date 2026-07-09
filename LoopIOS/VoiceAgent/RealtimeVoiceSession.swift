//
//  RealtimeVoiceSession.swift
//  Loop
//
//  Drives a live OpenAI Realtime API voice session over a WebSocket. The
//  session is the conversational *router*: it listens to the user, exposes the
//  `LoopThread*` tools so it can create threads and hand work off to background
//  agents, and injects asynchronous thread updates back into the conversation
//  as they arrive. It does not do long-running reasoning itself.
//
//  Audio capture/playback is handled by `RealtimeAudioEngine`; this class owns
//  the socket, the event protocol, tool dispatch, and update injection.
//

import Foundation
import AVFoundation

protocol RealtimeVoiceSessionDelegate: AnyObject {
    func voiceSession(_ session: RealtimeVoiceSession, didChangeState state: RealtimeVoiceSession.State)
    func voiceSession(_ session: RealtimeVoiceSession, didFailWith message: String)
    func voiceSession(_ session: RealtimeVoiceSession, didUpdateInputAmplitude amp: Float)
    func voiceSession(_ session: RealtimeVoiceSession, didUpdateOutputAmplitude amp: Float)
    /// Live assistant transcript, appended as it streams. Optional to use.
    func voiceSession(_ session: RealtimeVoiceSession, didReceiveTranscript text: String)
}

extension RealtimeVoiceSessionDelegate {
    func voiceSession(_ session: RealtimeVoiceSession, didUpdateInputAmplitude amp: Float) {}
    func voiceSession(_ session: RealtimeVoiceSession, didUpdateOutputAmplitude amp: Float) {}
    func voiceSession(_ session: RealtimeVoiceSession, didReceiveTranscript text: String) {}
}

final class RealtimeVoiceSession: NSObject {

    enum State: Equatable {
        case idle
        case connecting
        case listening
        case thinking
        case speaking
        case ended
        case failed(String)
    }

    /// What the session is scoped to. On the Home screen it's `.global` (can
    /// create/route across all threads); opened from a thread it's `.thread`,
    /// so new messages default to continuing that conversation.
    enum Scope {
        case global
        case thread(id: String, title: String)

        var threadId: String? {
            if case let .thread(id, _) = self { return id }
            return nil
        }
    }

    weak var delegate: RealtimeVoiceSessionDelegate?

    private let scope: Scope
    private let model: String
    private let audio = RealtimeAudioEngine()

    private var socket: URLSessionWebSocketTask?
    private var urlSession: URLSession?

    /// call_id → function name, captured from `response.output_item.added` so
    /// we know which tool to run when the arguments finish streaming.
    private var pendingCallNames: [String: String] = [:]

    /// Whether a model response is currently being generated — gates
    /// `response.cancel` so we don't cancel when nothing's in flight.
    private var hasActiveResponse = false

    private(set) var state: State = .idle {
        didSet {
            guard state != oldValue else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.delegate?.voiceSession(self, didChangeState: self.state)
            }
        }
    }

    init(scope: Scope, model: String = "gpt-4o-realtime-preview-2024-12-17") {
        self.scope = scope
        self.model = model
        super.init()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Lifecycle

    func start() {
        guard case .idle = state else { return }
        guard let key = KeyStore.shared.value(for: .openAI), !key.isEmpty else {
            fail("Add an OpenAI API key in Settings → Integrations to use voice.")
            return
        }

        // Make sure background work surfaces as thread updates for injection.
        LoopThreadEventBridge.shared.activate()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleThreadUpdate(_:)),
            name: .loopThreadUpdated,
            object: nil
        )

        state = .connecting

        guard var components = URLComponents(string: "wss://api.openai.com/v1/realtime") else {
            fail("Could not build the realtime URL.")
            return
        }
        components.queryItems = [URLQueryItem(name: "model", value: model)]
        guard let url = components.url else {
            fail("Could not build the realtime URL.")
            return
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta")

        let session = URLSession(configuration: .default)
        self.urlSession = session
        let task = session.webSocketTask(with: request)
        self.socket = task
        task.resume()

        receiveLoop()
        // The socket is open once the first message flows; configure the
        // session immediately — the server queues our session.update until the
        // connection is ready.
        configureSession()
        startAudio()
    }

    func stop() {
        NotificationCenter.default.removeObserver(self, name: .loopThreadUpdated, object: nil)
        audio.stop()
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        pendingCallNames.removeAll()
        state = .ended
    }

    /// Mute/unmute the microphone without tearing down the session.
    func setMuted(_ muted: Bool) {
        audio.setCaptureMuted(muted)
    }

    // MARK: - Audio

    private func startAudio() {
        audio.onCapturedPCM16 = { [weak self] data in
            self?.sendAudioChunk(data)
        }
        audio.onInputAmplitude = { [weak self] amp in
            guard let self = self else { return }
            self.delegate?.voiceSession(self, didUpdateInputAmplitude: amp)
        }
        audio.onOutputAmplitude = { [weak self] amp in
            guard let self = self else { return }
            self.delegate?.voiceSession(self, didUpdateOutputAmplitude: amp)
        }
        do {
            try audio.start()
        } catch {
            fail("Couldn't start audio: \(error.localizedDescription)")
        }
    }

    private func sendAudioChunk(_ pcm16: Data) {
        let b64 = pcm16.base64EncodedString()
        send(["type": "input_audio_buffer.append", "audio": b64])
    }

    // MARK: - Session configuration

    private func configureSession() {
        let sessionConfig: [String: Any] = [
            "type": "session.update",
            "session": [
                "modalities": ["audio", "text"],
                "instructions": instructions(),
                "voice": "alloy",
                "input_audio_format": "pcm16",
                "output_audio_format": "pcm16",
                "input_audio_transcription": ["model": "whisper-1"],
                "turn_detection": [
                    "type": "server_vad",
                    "threshold": 0.5,
                    "prefix_padding_ms": 300,
                    "silence_duration_ms": 500,
                ],
                "tools": LoopThreadTools.toolSchemas,
                "tool_choice": "auto",
                "temperature": 0.8,
            ],
        ]
        send(sessionConfig)
    }

    private func instructions() -> String {
        var base = """
        You are Loop, a warm, concise voice assistant. You are a conversational
        router: you do NOT do long-running work yourself. When the user wants
        something done, you send a message to another agent by creating or
        continuing a Loop thread, then keep the conversation going while that
        work happens in the background.

        The primitive is a MESSAGE, not a task. Think "send a message to another
        agent," never "create a task." A thread is just a conversation.

        Threading rules:
        - Continue the same thread (sendLoopMessage) when it's the same artifact,
          the same goal, or a refinement of previous work.
        - Create a new thread (createLoopThread) for a new artifact, a different
          objective, or unrelated work.
        - If you're unsure, ask: "Should I continue the existing thread or create
          a new one?"

        Never expose implementation details (thread ids, sub-agents, tools)
        unless the user explicitly asks. Speak naturally and briefly, like a
        person. When you hand something off, say so in one short line
        ("Got it, I'll hand that to the document agent"). When background work
        finishes you'll receive a note prefixed with [BACKGROUND UPDATE] — relay
        it to the user naturally and offer a next step.
        """

        if case let .thread(id, title) = scope {
            base += """


            This session is scoped to an existing thread titled "\(title)"
            (threadId: \(id)). Default to continuing THIS thread with
            sendLoopMessage unless the user clearly wants something unrelated.
            """
        }
        return base
    }

    // MARK: - Update injection

    @objc private func handleThreadUpdate(_ note: Notification) {
        guard let update = LoopThreadUpdate(userInfo: note.userInfo) else { return }

        // Scoped sessions only care about their own thread; a global session
        // relays updates for any thread.
        if let scoped = scope.threadId, scoped != update.threadId { return }

        let text = "[BACKGROUND UPDATE] \(update.spokenSummary)"

        if update.shouldInterrupt {
            // Barge in: stop the current response + drop queued audio so the
            // update is delivered promptly.
            if hasActiveResponse {
                send(["type": "response.cancel"])
            }
            audio.clearPlayback()
        }

        send([
            "type": "conversation.item.create",
            "item": [
                "type": "message",
                "role": "user",
                "content": [["type": "input_text", "text": text]],
            ],
        ])
        send(["type": "response.create"])
    }

    // MARK: - WebSocket receive

    private func receiveLoop() {
        socket?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let error):
                // A cancelled socket (we called stop()) shouldn't surface as an
                // error to the user.
                if case .ended = self.state { return }
                self.fail("Connection lost: \(error.localizedDescription)")
            case .success(let message):
                switch message {
                case .string(let text):
                    self.handleServerEvent(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self.handleServerEvent(text)
                    }
                @unknown default:
                    break
                }
                // Keep listening.
                self.receiveLoop()
            }
        }
    }

    private func handleServerEvent(_ text: String) {
        guard let data = text.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = event["type"] as? String else {
            return
        }

        switch type {
        case "session.created", "session.updated":
            if state == .connecting { state = .listening }

        case "input_audio_buffer.speech_started":
            // User barged in — stop any playback so we're not talking over them.
            audio.clearPlayback()
            state = .listening

        case "response.created":
            hasActiveResponse = true
            state = .thinking

        case "response.audio.delta":
            if let b64 = event["delta"] as? String,
               let pcm = Data(base64Encoded: b64) {
                state = .speaking
                audio.enqueuePlayback(pcm16: pcm)
            }

        case "response.audio_transcript.delta":
            if let delta = event["delta"] as? String {
                delegate?.voiceSession(self, didReceiveTranscript: delta)
            }

        case "response.output_item.added":
            if let item = event["item"] as? [String: Any],
               (item["type"] as? String) == "function_call",
               let callId = item["call_id"] as? String,
               let name = item["name"] as? String {
                pendingCallNames[callId] = name
            }

        case "response.function_call_arguments.done":
            handleFunctionCall(event)

        case "response.done":
            hasActiveResponse = false
            state = .listening

        case "error":
            let message = ((event["error"] as? [String: Any])?["message"] as? String)
                ?? "The realtime session reported an error."
            // Non-fatal server errors (e.g. an empty audio buffer commit)
            // shouldn't kill the whole session — log via transcript and keep
            // going. Only surface as failure if we never connected.
            if state == .connecting {
                fail(message)
            }

        default:
            break
        }
    }

    private func handleFunctionCall(_ event: [String: Any]) {
        guard let callId = event["call_id"] as? String else { return }
        let name = (event["name"] as? String) ?? pendingCallNames[callId] ?? ""
        guard LoopThreadTools.toolNames.contains(name) else { return }
        pendingCallNames.removeValue(forKey: callId)

        let argsString = (event["arguments"] as? String) ?? "{}"
        let arguments = (try? JSONSerialization.jsonObject(
            with: Data(argsString.utf8))) as? [String: Any] ?? [:]

        // Dispatch off the main queue — the tool layer touches the
        // conversation store and spawns sub-agents.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let output = LoopThreadTools.dispatch(name: name, arguments: arguments)
            self?.send([
                "type": "conversation.item.create",
                "item": [
                    "type": "function_call_output",
                    "call_id": callId,
                    "output": output,
                ],
            ])
            // Ask the model to continue now that it has the tool result.
            self?.send(["type": "response.create"])
        }
    }

    // MARK: - Send helpers

    private func send(_ payload: [String: Any]) {
        guard let socket = socket,
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else { return }
        socket.send(.string(text)) { [weak self] error in
            guard let self = self, let error = error else { return }
            if case .ended = self.state { return }
            self.fail("Send failed: \(error.localizedDescription)")
        }
    }

    private func fail(_ message: String) {
        state = .failed(message)
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.voiceSession(self, didFailWith: message)
        }
        audio.stop()
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
    }
}
