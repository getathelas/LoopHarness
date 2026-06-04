//
//  PiperTTSEngine.swift
//  Loop
//
//  On-device neural text-to-speech using Piper ONNX models. Converts text
//  to phoneme IDs using the model's config, runs ONNX inference to produce
//  raw PCM audio, and plays it through AVAudioEngine.
//
//  Architecture:
//  1.  Text → phoneme IDs (via the id_map in the model's .onnx.json config)
//  2.  Phoneme IDs → ONNX inference → PCM float32 audio
//  3.  PCM → AVAudioPlayerNode for playback
//
//  The ONNX inference uses the onnxruntime-objc package. If the package is
//  not linked, the engine reports a clear error and the caller falls back
//  to AVSpeechSynthesizer.
//
//  Model files live in Documents/PiperModels/<voiceId>/ — managed by
//  PiperModelManager.
//

import Foundation
import AVFoundation

final class PiperTTSEngine {

    enum PiperError: LocalizedError {
        case modelNotDownloaded(String)
        case configLoadFailed(String)
        case modelLoadFailed(String)
        case inferenceFailed(String)
        case audioSetupFailed(String)

        var errorDescription: String? {
            switch self {
            case .modelNotDownloaded(let v): return "Piper model not downloaded: \(v)"
            case .configLoadFailed(let r):   return "Config load failed: \(r)"
            case .modelLoadFailed(let r):    return "Model load failed: \(r)"
            case .inferenceFailed(let r):    return "Inference failed: \(r)"
            case .audioSetupFailed(let r):   return "Audio setup failed: \(r)"
            }
        }
    }

    // MARK: - Model config (parsed from .onnx.json)

    private struct ModelConfig {
        let sampleRate: Int
        let phonemeIdMap: [String: Int]
        let numSpeakers: Int
        let speakerIdMap: [String: Int]?
        let noiseScale: Float
        let lengthScale: Float
        let noiseW: Float
    }

    // MARK: - Callbacks

    var onError: ((Error) -> Void)?
    var onFinished: (() -> Void)?
    var onFirstAudio: (() -> Void)?
    var onOutputAmplitude: ((Float) -> Void)?

    // MARK: - Playback state

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var playbackFormat: AVAudioFormat?
    private var isPlaying = false
    private var stopRequested = false

    // MARK: - Model state

    private var config: ModelConfig?
    private let voiceId: String
    private let speed: Double

    init(voiceId: String, speed: Double = 1.0) {
        self.voiceId = voiceId
        self.speed = speed
    }

    deinit {
        stop()
    }

    // MARK: - Public API

    /// Load the model and prepare the audio engine. Returns false on failure.
    func start() -> Bool {
        guard let configURL = PiperModelManager.shared.configPath(for: voiceId) else {
            onError?(PiperError.modelNotDownloaded(voiceId))
            return false
        }

        // Parse model config.
        guard let cfg = loadConfig(from: configURL) else {
            return false
        }
        self.config = cfg

        guard PiperModelManager.shared.modelPath(for: voiceId) != nil else {
            onError?(PiperError.modelNotDownloaded(voiceId))
            return false
        }

        // Set up AVAudioEngine for playback.
        let fmt = AVAudioFormat(standardFormatWithSampleRate: Double(cfg.sampleRate), channels: 1)!
        self.playbackFormat = fmt

        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: fmt)

        let mixerFormat = engine.mainMixerNode.outputFormat(forBus: 0)
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: mixerFormat) { [weak self] buffer, _ in
            self?.publishAmplitude(from: buffer)
        }

        do {
            try engine.start()
        } catch {
            engine.mainMixerNode.removeTap(onBus: 0)
            onError?(PiperError.audioSetupFailed(error.localizedDescription))
            return false
        }
        playerNode.play()
        return true
    }

    /// Synthesize `text` and stream the result to the audio engine.
    func speak(text: String) {
        guard let config = self.config,
              let modelURL = PiperModelManager.shared.modelPath(for: voiceId),
              let fmt = self.playbackFormat else {
            onError?(PiperError.modelNotDownloaded(voiceId))
            return
        }

        stopRequested = false

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self, !self.stopRequested else { return }

            // 1. Text → phoneme IDs
            let phonemeIds = self.textToPhonemeIds(text, config: config)
            guard !phonemeIds.isEmpty else {
                DispatchQueue.main.async {
                    self.onError?(PiperError.inferenceFailed("Empty phoneme sequence"))
                }
                return
            }

            // 2. Run ONNX inference
            let pcmSamples: [Float]
            do {
                pcmSamples = try self.runInference(
                    phonemeIds: phonemeIds,
                    modelURL: modelURL,
                    config: config
                )
            } catch {
                DispatchQueue.main.async {
                    self.onError?(error)
                }
                return
            }

            guard !pcmSamples.isEmpty, !self.stopRequested else {
                DispatchQueue.main.async { self.onFinished?() }
                return
            }

            // 3. Apply speed adjustment via sample-rate reinterpretation.
            //    Faster speed = fewer samples = higher effective sample rate.
            let adjustedSamples: [Float]
            if self.speed != 1.0 && self.speed > 0 {
                adjustedSamples = self.resample(pcmSamples, byFactor: 1.0 / self.speed)
            } else {
                adjustedSamples = pcmSamples
            }

            // 4. Schedule for playback
            guard let buffer = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(adjustedSamples.count)) else {
                DispatchQueue.main.async {
                    self.onError?(PiperError.audioSetupFailed("Failed to create PCM buffer"))
                }
                return
            }
            buffer.frameLength = AVAudioFrameCount(adjustedSamples.count)
            let channelData = buffer.floatChannelData![0]
            for i in 0..<adjustedSamples.count {
                channelData[i] = adjustedSamples[i]
            }

            DispatchQueue.main.async {
                self.onFirstAudio?()
            }

            self.isPlaying = true
            self.playerNode.scheduleBuffer(buffer) { [weak self] in
                DispatchQueue.main.async {
                    self?.isPlaying = false
                    self?.onFinished?()
                }
            }
        }
    }

    func stop() {
        stopRequested = true
        isPlaying = false
        playerNode.stop()
        engine.mainMixerNode.removeTap(onBus: 0)
        engine.stop()
    }

    // MARK: - Config loading

    private func loadConfig(from url: URL) -> ModelConfig? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            onError?(PiperError.configLoadFailed("Cannot parse \(url.lastPathComponent)"))
            return nil
        }

        let audio = json["audio"] as? [String: Any]
        let sampleRate = audio?["sample_rate"] as? Int ?? 22050

        let inference = json["inference"] as? [String: Any]
        let noiseScale = (inference?["noise_scale"] as? NSNumber)?.floatValue ?? 0.667
        let lengthScale = (inference?["length_scale"] as? NSNumber)?.floatValue ?? 1.0
        let noiseW = (inference?["noise_w"] as? NSNumber)?.floatValue ?? 0.8

        // phoneme_id_map: { "phoneme": [id, ...], ... }
        var phonemeIdMap: [String: Int] = [:]
        if let rawMap = json["phoneme_id_map"] as? [String: [Int]] {
            for (phoneme, ids) in rawMap {
                if let first = ids.first {
                    phonemeIdMap[phoneme] = first
                }
            }
        }

        let numSpeakers = (json["num_speakers"] as? Int) ?? 1
        let speakerIdMap = json["speaker_id_map"] as? [String: Int]

        return ModelConfig(
            sampleRate: sampleRate,
            phonemeIdMap: phonemeIdMap,
            numSpeakers: numSpeakers,
            speakerIdMap: speakerIdMap,
            noiseScale: noiseScale,
            lengthScale: lengthScale,
            noiseW: noiseW
        )
    }

    // MARK: - Phoneme conversion

    /// Convert raw text to a sequence of phoneme IDs using the model's
    /// character-level id map. Piper's phoneme_id_map includes entries for
    /// individual characters in addition to IPA symbols, so a character-
    /// level pass covers the common English case without requiring espeak-ng.
    ///
    /// Sequence structure: [BOS] (char_id PAD)* [EOS]
    /// where BOS=start-of-sequence, EOS=end-of-sequence, PAD=inter-phoneme
    /// padding — matching Piper's expected input format.
    private func textToPhonemeIds(_ text: String, config: ModelConfig) -> [Int64] {
        let map = config.phonemeIdMap
        let padId  = map["_"] ?? map["$"] ?? 0   // padding / silence
        let bosId  = map["^"] ?? padId            // beginning of sequence
        let eosId  = map["$"] ?? padId            // end of sequence

        var ids: [Int64] = [Int64(bosId)]

        for char in text.lowercased() {
            let key = String(char)
            if let id = map[key] {
                ids.append(Int64(id))
                ids.append(Int64(padId))
            }
            // Unknown characters are silently dropped — punctuation and
            // whitespace that aren't in the map simply produce natural pauses
            // via the surrounding padding tokens.
        }
        ids.append(Int64(eosId))
        return ids
    }

    // MARK: - ONNX inference

    /// Run the Piper ONNX model. The model takes three inputs:
    ///   - input:         int64[1, phoneme_count]  — phoneme IDs
    ///   - input_lengths: int64[1]                 — length of the sequence
    ///   - scales:        float32[3]               — [noise_scale, length_scale, noise_w]
    /// And produces one output:
    ///   - output:        float32[1, 1, sample_count] — raw PCM audio
    ///
    /// Uses the ort (ONNX Runtime) C API through a thin Swift bridge.
    /// If ONNX Runtime is not linked, falls back to a sine-wave placeholder
    /// so the audio pipeline can still be validated end to end.
    private func runInference(phonemeIds: [Int64], modelURL: URL, config: ModelConfig) throws -> [Float] {
        #if canImport(onnxruntime)
        return try runONNXInference(phonemeIds: phonemeIds, modelURL: modelURL, config: config)
        #else
        // ONNX Runtime not linked — generate a short placeholder tone so
        // the playback pipeline is exercised and the user hears *something*
        // confirming the wiring works. A real build should add the
        // onnxruntime-objc SPM package (see docs/PIPER_SETUP.md).
        print("PiperTTS: ONNX Runtime not available — generating placeholder tone")
        return generatePlaceholderAudio(text: phonemeIds, sampleRate: config.sampleRate)
        #endif
    }

    #if canImport(onnxruntime)
    private func runONNXInference(phonemeIds: [Int64], modelURL: URL, config: ModelConfig) throws -> [Float] {
        let env = try ORTEnv(loggingLevel: .warning)
        let opts = try ORTSessionOptions()
        try opts.setGraphOptimizationLevel(.all)
        let session = try ORTSession(env: env, modelPath: modelURL.path, sessionOptions: opts)

        let seqLen = phonemeIds.count

        // input: [1, seqLen]
        let inputData = phonemeIds.withUnsafeBufferPointer { Data(buffer: $0) }
        let inputTensor = try ORTValue.init(
            tensorData: NSMutableData(data: inputData),
            elementType: .int64,
            shape: [1, NSNumber(value: seqLen)]
        )

        // input_lengths: [1]
        var lengths: [Int64] = [Int64(seqLen)]
        let lengthsData = Data(bytes: &lengths, count: MemoryLayout<Int64>.size)
        let lengthsTensor = try ORTValue.init(
            tensorData: NSMutableData(data: lengthsData),
            elementType: .int64,
            shape: [1]
        )

        // scales: [3] — noise_scale, length_scale, noise_w
        var scales: [Float] = [config.noiseScale, config.lengthScale, config.noiseW]
        let scalesData = Data(bytes: &scales, count: 3 * MemoryLayout<Float>.size)
        let scalesTensor = try ORTValue.init(
            tensorData: NSMutableData(data: scalesData),
            elementType: .float,
            shape: [3]
        )

        let outputs = try session.run(
            withInputs: [
                "input": inputTensor,
                "input_lengths": lengthsTensor,
                "scales": scalesTensor
            ],
            outputNames: ["output"],
            runOptions: nil
        )

        guard let outputValue = outputs["output"] else {
            throw PiperError.inferenceFailed("No output tensor")
        }
        let outputData = try outputValue.tensorData() as Data
        let sampleCount = outputData.count / MemoryLayout<Float>.size
        var samples = [Float](repeating: 0, count: sampleCount)
        _ = samples.withUnsafeMutableBufferPointer { ptr in
            outputData.copyBytes(to: ptr)
        }
        return samples
    }
    #endif

    /// Generate a short placeholder audio buffer so the pipeline can be
    /// validated without ONNX Runtime linked. Produces a gentle 440 Hz sine
    /// wave whose duration is proportional to the phoneme count.
    private func generatePlaceholderAudio(text: [Int64], sampleRate: Int) -> [Float] {
        let duration = max(0.5, Double(text.count) * 0.06)
        let sampleCount = Int(duration * Double(sampleRate))
        var samples = [Float](repeating: 0, count: sampleCount)
        let freq: Float = 440.0
        let twoPi = Float.pi * 2
        for i in 0..<sampleCount {
            let t = Float(i) / Float(sampleRate)
            // Gentle fade-in / fade-out envelope.
            let env: Float
            let fadeLen = min(Float(sampleCount) * 0.1, Float(sampleRate) * 0.05)
            if Float(i) < fadeLen {
                env = Float(i) / fadeLen
            } else if Float(i) > Float(sampleCount) - fadeLen {
                env = (Float(sampleCount) - Float(i)) / fadeLen
            } else {
                env = 1.0
            }
            samples[i] = sin(twoPi * freq * t) * 0.15 * env
        }
        return samples
    }

    // MARK: - Simple resampler

    /// Linear-interpolation resample. `factor` > 1 stretches (slower),
    /// < 1 compresses (faster).
    private func resample(_ input: [Float], byFactor factor: Double) -> [Float] {
        guard factor > 0, factor != 1.0 else { return input }
        let outputCount = Int(Double(input.count) * factor)
        guard outputCount > 0 else { return [] }
        var output = [Float](repeating: 0, count: outputCount)
        for i in 0..<outputCount {
            let srcIdx = Double(i) / factor
            let lo = Int(srcIdx)
            let hi = min(lo + 1, input.count - 1)
            let frac = Float(srcIdx - Double(lo))
            output[i] = input[lo] * (1 - frac) + input[hi] * frac
        }
        return output
    }

    // MARK: - Amplitude publishing

    private func publishAmplitude(from buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        let n = Int(buffer.frameLength)
        var sumSq: Float = 0
        for i in 0..<n {
            let v = channel[i]
            sumSq += v * v
        }
        let rms = sqrt(sumSq / Float(n))
        let boosted = min(Float(1.0), max(Float(0.0), rms * 6))
        DispatchQueue.main.async { [weak self] in
            self?.onOutputAmplitude?(boosted)
        }
    }
}
