import AVFoundation
#if os(iOS)
import MusicKit
#endif

/// Native PCM transport using voice processing for full-duplex echo cancellation.
final class LiveAudio {
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var cuePlayer: AVAudioPlayerNode?
    private var terminalEngine: AVAudioEngine?
    private var terminalPlayer: AVAudioPlayerNode?
    private var terminalCleanup: DispatchWorkItem?
    private var speechReset: DispatchWorkItem?
    private var speechAnnounced = false
    private var lastToolCue = Date.distantPast
    private var queuedFrames = 0
    private var playbackGeneration = UUID()
    var onPlaybackRecovery: (() -> Void)?
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24000,
                                       channels: 1, interleaved: false)!
    var isRunning: Bool { engine?.isRunning == true }
    var onInput: ((Data, Float) -> Void)?
    var onOutputLevel: ((Float) -> Void)?

    func start() throws {
        stopTerminalCue()
        speechAnnounced = false
        lastToolCue = .distantPast
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP, .mixWithOthers])
        try session.setActive(true)
        #endif
        let engine = AVAudioEngine()
        self.engine = engine
        #if os(macOS)
        MicrophoneManager.shared.applySelectedInput(to: engine)
        #endif
        // Materialize both I/O nodes before switching them to VoiceProcessingIO.
        // That audio unit requires identical client-side capture/playback formats.
        _ = engine.outputNode
        try engine.inputNode.setVoiceProcessingEnabled(true)
        // Keep background music audible between utterances. Voice processing
        // ducks it when either participant speaks, without pausing its queue.
        if #available(iOS 17.0, macOS 14.0, *) {
            engine.inputNode.voiceProcessingOtherAudioDuckingConfiguration = .init(
                enableAdvancedDucking: true, duckingLevel: .mid)
        }
        // VoiceProcessingIO can expose aggregate microphone/reference channels.
        // Negotiate a mono client stream instead of downmixing that aggregate,
        // which can deliver silent capture even though the engine starts.
        let sampleRate = engine.inputNode.outputFormat(forBus: 0).sampleRate
        guard sampleRate > 0,
              let source = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let pcm = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: source, to: pcm) else {
            throw NSError(domain: "LiveAudio", code: 1, userInfo: [NSLocalizedDescriptionKey: "No microphone is available."])
        }
        let player = AVAudioPlayerNode()
        self.player = player
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        let cuePlayer = AVAudioPlayerNode()
        self.cuePlayer = cuePlayer
        engine.attach(cuePlayer)
        engine.connect(cuePlayer, to: engine.mainMixerNode, format: format)
        // Do not let the player's 24 kHz wire format become the I/O format.
        // The mixer resamples it to the capture format before VoiceProcessingIO.
        // Otherwise macOS fails initialization with kAudioUnitErr_FailedInitialization
        // (-10875) when the input is 48 kHz and the output inherits 24 kHz.
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: source)
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: source) { [weak self] buffer, _ in
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * 24000 / source.sampleRate) + 32
            guard let output = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: capacity) else { return }
            var supplied = false
            var error: NSError?
            converter.convert(to: output, error: &error) { _, status in
                guard !supplied else { status.pointee = .noDataNow; return nil }
                supplied = true; status.pointee = .haveData; return buffer
            }
            guard error == nil, output.frameLength > 0, let samples = output.int16ChannelData?[0] else { return }
            let count = Int(output.frameLength)
            var energy: Float = 0
            for i in 0..<count { let value = Float(samples[i]) / 32768; energy += value * value }
            let data = Data(bytes: samples, count: count * 2)
            let level = min(1, sqrt(energy / Float(count)) * 6)
            DispatchQueue.main.async { self?.onInput?(data, level) }
        }
        engine.prepare()
        try engine.start()
        player.play()
        cuePlayer.play()
    }

    /// Called on main; completion measures actual playback, not transcript timing.
    func play(_ data: Data) throws {
        guard data.count % 2 == 0, !data.isEmpty, let player = player else { return }
        let count = data.count / 2
        // A playback stall is local, not a failed network connection. Catch up
        // to fresh audio instead of ending the conversation or growing latency.
        if queuedFrames + count > 24000 * 3 {
            playbackGeneration = UUID()
            player.stop(); queuedFrames = 0
            speechReset?.cancel(); speechAnnounced = false
            player.play()
            onPlaybackRecovery?()
        }
        guard count <= 24000 * 3 else { return }
        let playbackToken = playbackGeneration
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
              let samples = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(count)
        var energy: Float = 0
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            for i in 0..<count {
                let value = Float(Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))) / 32768
                samples[i] = value; energy += value * value
            }
        }
        speechReset?.cancel()
        if !speechAnnounced {
            speechAnnounced = true
            // Queue before speech so the short cue is not masked by the voice.
            player.scheduleBuffer(LiveEarcon.speaking.buffer(format: format))
        }
        queuedFrames += count
        onOutputLevel?(min(1, sqrt(energy / Float(count)) * 6))
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self, self.player === player, self.playbackGeneration == playbackToken else { return }
                self.queuedFrames -= count
                if self.queuedFrames == 0 {
                    self.onOutputLevel?(0)
                    let reset = DispatchWorkItem { [weak self] in self?.speechAnnounced = false }
                    self.speechReset = reset
                    // Chunk boundaries and short natural pauses are not new utterances.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: reset)
                }
            }
        }
    }

    /// Keep capture/session alive during a short network recovery, including
    /// in the background. LiveSession drops mic samples until a socket is ready.
    func resetOutput() {
        playbackGeneration = UUID()
        speechReset?.cancel(); speechReset = nil; speechAnnounced = false
        player?.stop(); queuedFrames = 0
        cuePlayer?.stop()
        if isRunning { player?.play(); cuePlayer?.play() }
        onOutputLevel?(0)
    }

    func playCue(_ cue: LiveEarcon) {
        guard isRunning, let cuePlayer else { return }
        if cue == .tool {
            guard Date().timeIntervalSince(lastToolCue) >= 0.8 else { return }
            lastToolCue = Date()
        }
        cuePlayer.stop()
        cuePlayer.scheduleBuffer(cue.buffer(format: format))
        cuePlayer.play()
    }

    /// Plays after capture stops; this engine never opens the microphone.
    func playTerminalCue(_ cue: LiveEarcon) {
        stopTerminalCue()
        #if os(iOS)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
        } catch { return } // An OS interruption may prohibit playback.
        #endif
        let engine = AVAudioEngine(), player = AVAudioPlayerNode()
        terminalEngine = engine; terminalPlayer = player
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
            player.scheduleBuffer(cue.buffer(format: format))
            player.play()
        } catch { stopTerminalCue(); return }
        let cleanup = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.stopTerminalCue()
            #if os(iOS)
            if ApplicationMusicPlayer.shared.state.playbackStatus != .playing {
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
            #endif
        }
        terminalCleanup = cleanup
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: cleanup)
    }

    private func stopTerminalCue() {
        terminalCleanup?.cancel(); terminalCleanup = nil
        terminalPlayer?.stop(); terminalEngine?.stop()
        terminalPlayer = nil; terminalEngine = nil
    }

    func stop() {
        playbackGeneration = UUID()
        speechReset?.cancel(); speechReset = nil; speechAnnounced = false
        cuePlayer?.stop(); cuePlayer = nil
        if let engine = engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        player?.stop(); player = nil; engine = nil; queuedFrames = 0
        #if os(iOS)
        guard terminalEngine == nil else { return }
        let session = AVAudioSession.sharedInstance()
        if ApplicationMusicPlayer.shared.state.playbackStatus == .playing {
            // Live and MusicKit share the app's audio session. Release the
            // microphone without deactivating the music the user requested.
            try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        } else {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
        }
        #endif
    }
}
