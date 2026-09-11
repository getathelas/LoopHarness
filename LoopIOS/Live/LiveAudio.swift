import AVFoundation

/// Native PCM transport using voice processing for full-duplex echo cancellation.
final class LiveAudio {
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var queuedFrames = 0
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24000,
                                       channels: 1, interleaved: false)!
    var isRunning: Bool { engine?.isRunning == true }
    var onInput: ((Data, Float) -> Void)?
    var onOutputLevel: ((Float) -> Void)?

    func start() throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP])
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
        let source = engine.inputNode.outputFormat(forBus: 0)
        guard source.sampleRate > 0,
              let pcm = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: source, to: pcm) else {
            throw NSError(domain: "LiveAudio", code: 1, userInfo: [NSLocalizedDescriptionKey: "No microphone is available."])
        }
        let player = AVAudioPlayerNode()
        self.player = player
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
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
    }

    /// Called on main; completion measures actual playback, not transcript timing.
    func play(_ data: Data) throws {
        guard data.count % 2 == 0, !data.isEmpty, let player = player else { return }
        let count = data.count / 2
        // End a stalled session instead of allowing seconds of stale speech to build up.
        guard queuedFrames + count <= 24000 * 3 else {
            throw NSError(domain: "LiveAudio", code: 2, userInfo: [NSLocalizedDescriptionKey: "Audio playback fell behind. Please reconnect."])
        }
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
        queuedFrames += count
        onOutputLevel?(min(1, sqrt(energy / Float(count)) * 6))
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self, self.player === player else { return }
                self.queuedFrames -= count
                if self.queuedFrames == 0 { self.onOutputLevel?(0) }
            }
        }
    }

    func stop() {
        if let engine = engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        player?.stop(); player = nil; engine = nil; queuedFrames = 0
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
}
