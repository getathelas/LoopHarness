//
//  RealtimeAudioEngine.swift
//  Loop
//
//  Full-duplex audio for the realtime voice session. Captures the microphone,
//  down-converts to the 24 kHz mono PCM16 the OpenAI Realtime API expects, and
//  streams it out via a callback; and plays back the 24 kHz PCM16 audio the API
//  streams down, buffered through an `AVAudioPlayerNode`.
//
//  Uses `.voiceChat` mode so the OS echo-cancels the speaker out of the mic
//  input — essential for a hands-free, always-listening session where the
//  assistant's own voice would otherwise feed back into server VAD.
//

import Foundation
import AVFoundation

final class RealtimeAudioEngine {

    /// The wire format both directions of the Realtime API use: 24 kHz, mono,
    /// signed 16-bit PCM.
    static let sampleRate: Double = 24_000

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()

    /// Float32 @ 24 kHz mono — what the player node renders. Non-interleaved
    /// (the AVAudioEngine convention for float buffers).
    private let playbackFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: RealtimeAudioEngine.sampleRate,
        channels: 1,
        interleaved: false
    )!

    /// Int16 @ 24 kHz mono — the capture target we hand to the network layer.
    private let captureFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: RealtimeAudioEngine.sampleRate,
        channels: 1,
        interleaved: true
    )!

    private var captureConverter: AVAudioConverter?

    /// Called with a chunk of 24 kHz mono PCM16 bytes each time the mic tap
    /// fires. Runs on the audio render thread — do minimal work.
    var onCapturedPCM16: ((Data) -> Void)?

    /// Live RMS amplitude in [0, 1] of mic input / TTS output, for driving a
    /// waveform in the UI. Optional.
    var onInputAmplitude: ((Float) -> Void)?
    var onOutputAmplitude: ((Float) -> Void)?

    private var isRunning = false
    /// When true the mic tap discards frames (used while the user isn't
    /// supposed to be heard — e.g. session paused). Playback still works.
    private var captureMuted = false

    // MARK: - Lifecycle

    func start() throws {
        guard !isRunning else { return }

        try configureSession()

        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)

        // Guard against a zero-sample-rate input format (can happen if the
        // session route isn't ready yet) — bail so we don't crash making the
        // converter.
        guard inputFormat.sampleRate > 0 else {
            throw NSError(domain: "RealtimeAudioEngine", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Audio input not ready."])
        }

        captureConverter = AVAudioConverter(from: inputFormat, to: captureFormat)

        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: playbackFormat)

        input.installTap(onBus: 0, bufferSize: 2_048, format: inputFormat) { [weak self] buffer, _ in
            self?.handleCapture(buffer: buffer)
        }

        engine.prepare()
        try engine.start()
        playerNode.play()
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        playerNode.stop()
        engine.stop()
        engine.detach(playerNode)
        isRunning = false
        deactivateSession()
    }

    func setCaptureMuted(_ muted: Bool) {
        captureMuted = muted
    }

    // MARK: - Playback

    /// Enqueue a chunk of 24 kHz mono PCM16 for playback. Thread-safe to call
    /// from the WebSocket receive loop.
    func enqueuePlayback(pcm16: Data) {
        guard isRunning, !pcm16.isEmpty else { return }
        guard let buffer = floatBuffer(fromPCM16: pcm16) else { return }
        emitOutputAmplitude(buffer)
        playerNode.scheduleBuffer(buffer, completionHandler: nil)
        if !playerNode.isPlaying { playerNode.play() }
    }

    /// Drop any audio still queued for playback — used when the agent is
    /// interrupted (barge-in) so it stops talking immediately.
    func clearPlayback() {
        guard isRunning else { return }
        playerNode.stop()
        playerNode.play()
    }

    // MARK: - Capture

    private func handleCapture(buffer: AVAudioPCMBuffer) {
        guard !captureMuted, let converter = captureConverter else { return }

        emitInputAmplitude(buffer)

        let ratio = captureFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: captureFormat, frameCapacity: capacity) else { return }

        var fed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inStatus in
            if fed {
                inStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            inStatus.pointee = .haveData
            return buffer
        }

        guard status != .error, error == nil, out.frameLength > 0,
              let channel = out.int16ChannelData else { return }

        let byteCount = Int(out.frameLength) * MemoryLayout<Int16>.size
        let data = Data(bytes: channel[0], count: byteCount)
        onCapturedPCM16?(data)
    }

    // MARK: - Conversion helpers

    /// Build a Float32 playback buffer from interleaved PCM16 bytes.
    private func floatBuffer(fromPCM16 data: Data) -> AVAudioPCMBuffer? {
        let sampleCount = data.count / MemoryLayout<Int16>.size
        guard sampleCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: playbackFormat,
                                            frameCapacity: AVAudioFrameCount(sampleCount)),
              let channel = buffer.floatChannelData else { return nil }
        buffer.frameLength = AVAudioFrameCount(sampleCount)

        data.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            let scale: Float = 1.0 / 32_768.0
            for i in 0..<sampleCount {
                channel[0][i] = Float(samples[i]) * scale
            }
        }
        return buffer
    }

    private func emitInputAmplitude(_ buffer: AVAudioPCMBuffer) {
        guard onInputAmplitude != nil else { return }
        let amp = rms(buffer)
        DispatchQueue.main.async { [weak self] in self?.onInputAmplitude?(amp) }
    }

    private func emitOutputAmplitude(_ buffer: AVAudioPCMBuffer) {
        guard onOutputAmplitude != nil, let channel = buffer.floatChannelData else { return }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return }
        var sum: Float = 0
        for i in 0..<n { let s = channel[0][i]; sum += s * s }
        let amp = min(1.0, sqrt(sum / Float(n)) * 4)
        DispatchQueue.main.async { [weak self] in self?.onOutputAmplitude?(amp) }
    }

    private func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        let n = Int(buffer.frameLength)
        guard n > 0 else { return 0 }
        if let f = buffer.floatChannelData {
            var sum: Float = 0
            for i in 0..<n { let s = f[0][i]; sum += s * s }
            return min(1.0, sqrt(sum / Float(n)) * 4)
        }
        if let i16 = buffer.int16ChannelData {
            var sum: Float = 0
            let scale: Float = 1.0 / 32_768.0
            for i in 0..<n { let s = Float(i16[0][i]) * scale; sum += s * s }
            return min(1.0, sqrt(sum / Float(n)) * 4)
        }
        return 0
    }

    // MARK: - Session

    private func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord,
                                mode: .voiceChat,
                                options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP])
        try session.setActive(true, options: [])
    }

    private func deactivateSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false, options: [.notifyOthersOnDeactivation])
    }
}
