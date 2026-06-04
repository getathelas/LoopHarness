//
//  PiperTTSService.swift
//  Loop
//
//  On-device TTS using a Piper ONNX voice model. Loads a `.onnx` model and
//  its companion `*.onnx.json` config from the app bundle (or a
//  user-supplied URL) and synthesises speech into a 16-bit linear-PCM WAV
//  buffer playable through AVAudioPlayer / AVAudioEngine.
//
//  The first release ships a stub that exposes the full public API. When a
//  real Piper model is bundled (see README), the `synthesize` path will
//  invoke the ONNX Runtime and produce actual audio. Until then, callers
//  receive a `.modelNotFound` error and can fall back gracefully.
//
//  Thread safety: `synthesize` is called from a background queue;
//  everything else is read-only after init or main-queue-only. The service
//  itself is a singleton so model loading happens once.
//

import AVFoundation
import Foundation

// MARK: - PiperTTSService

final class PiperTTSService {

    static let shared = PiperTTSService()

    // MARK: Types

    enum PiperError: LocalizedError {
        case modelNotFound
        case configNotFound
        case modelLoadFailed(underlying: Error)
        case synthesisFailed(reason: String)

        var errorDescription: String? {
            switch self {
            case .modelNotFound:
                return "Piper voice model (.onnx) not found in the app bundle. See README for setup."
            case .configNotFound:
                return "Piper model config (.onnx.json) not found in the app bundle."
            case .modelLoadFailed(let err):
                return "Failed to load Piper model: \(err.localizedDescription)"
            case .synthesisFailed(let reason):
                return "Piper synthesis failed: \(reason)"
            }
        }
    }

    /// Configuration decoded from the `*.onnx.json` sidecar file that ships
    /// alongside the Piper ONNX model.
    struct ModelConfig: Decodable {
        let sampleRate: Int?
        let speakerId: Int?
        let lengthScale: Double?
        let noiseScale: Double?
        let noiseW: Double?

        enum CodingKeys: String, CodingKey {
            case audio
            case inference
        }

        enum AudioKeys: String, CodingKey {
            case sampleRate = "sample_rate"
        }

        enum InferenceKeys: String, CodingKey {
            case lengthScale = "length_scale"
            case noiseScale  = "noise_scale"
            case noiseW      = "noise_w"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let audio = try? container.nestedContainer(keyedBy: AudioKeys.self, forKey: .audio) {
                sampleRate = try? audio.decode(Int.self, forKey: .sampleRate)
            } else {
                sampleRate = nil
            }
            if let inference = try? container.nestedContainer(keyedBy: InferenceKeys.self, forKey: .inference) {
                lengthScale = try? inference.decode(Double.self, forKey: .lengthScale)
                noiseScale  = try? inference.decode(Double.self, forKey: .noiseScale)
                noiseW      = try? inference.decode(Double.self, forKey: .noiseW)
            } else {
                lengthScale = nil
                noiseScale  = nil
                noiseW      = nil
            }
            speakerId = nil
        }

        init(sampleRate: Int = 22050) {
            self.sampleRate = sampleRate
            self.speakerId = nil
            self.lengthScale = 1.0
            self.noiseScale = 0.667
            self.noiseW = 0.8
        }
    }

    // MARK: State

    /// Expected bundle resource name (without extension). Override via
    /// `configure(modelName:)` before first use if your model file is
    /// named differently.
    private(set) var modelName: String = "en_US-lessac-medium"

    /// Resolved paths — populated by `loadModel()`.
    private var modelURL: URL?
    private var config: ModelConfig?

    /// Whether the model + config pair were located and parsed successfully.
    private(set) var isModelLoaded: Bool = false

    // MARK: Init

    private init() {
        // Attempt eager load so `isModelLoaded` is accurate before the first
        // synthesis request. Non-fatal — callers check `isModelLoaded` or
        // handle the error from `synthesize`.
        _ = try? loadModelIfNeeded()
    }

    // MARK: Public API

    /// Override the expected model resource name. Must be called before the
    /// first `synthesize` call if your `.onnx` file has a different base name.
    func configure(modelName: String) {
        guard modelName != self.modelName else { return }
        self.modelName = modelName
        isModelLoaded = false
        modelURL = nil
        config = nil
        _ = try? loadModelIfNeeded()
    }

    /// Synthesize `text` into a 16-bit linear-PCM WAV `Data` blob suitable
    /// for `AVAudioPlayer(data:)`.
    ///
    /// This runs synchronously and may take tens to hundreds of milliseconds
    /// depending on text length and device — call from a background queue.
    ///
    /// - Returns: WAV data on success.
    /// - Throws: `PiperError` on failure.
    func synthesize(text: String) throws -> Data {
        try loadModelIfNeeded()

        guard let config = config, let modelURL = modelURL else {
            throw PiperError.modelNotFound
        }

        // ---------------------------------------------------------------
        // PLACEHOLDER: real Piper ONNX inference goes here.
        //
        // When the Piper ONNX Runtime dependency is integrated:
        //   1. Tokenize `text` into phoneme IDs using espeak-ng or a
        //      bundled phoneme map.
        //   2. Run the ONNX session with the phoneme tensor + config
        //      scales (noiseScale, noiseW, lengthScale).
        //   3. Read the float32 PCM output tensor, convert to Int16
        //      samples.
        //   4. Wrap in a WAV header (see `wavData(from:sampleRate:)`).
        //
        // For now: generate a short silence so the audio pipeline
        // exercises the full code path without crashing. Replace this
        // block once the ONNX Runtime + model are bundled.
        // ---------------------------------------------------------------

        let sampleRate = config.sampleRate ?? 22050
        let durationSeconds = 0.5
        let sampleCount = Int(Double(sampleRate) * durationSeconds)
        let samples = [Int16](repeating: 0, count: sampleCount)

        print("PiperTTS: stub synthesis for \(text.prefix(40))… "
              + "(model: \(modelURL.lastPathComponent), sr: \(sampleRate))")

        return wavData(from: samples, sampleRate: sampleRate)
    }

    // MARK: Internal

    @discardableResult
    private func loadModelIfNeeded() throws -> Bool {
        if isModelLoaded { return true }

        guard let onnxURL = Bundle.main.url(forResource: modelName, withExtension: "onnx") else {
            throw PiperError.modelNotFound
        }

        let jsonURL = onnxURL.appendingPathExtension("json")
        guard FileManager.default.fileExists(atPath: jsonURL.path) else {
            throw PiperError.configNotFound
        }

        do {
            let data = try Data(contentsOf: jsonURL)
            config = try JSONDecoder().decode(ModelConfig.self, from: data)
        } catch {
            throw PiperError.modelLoadFailed(underlying: error)
        }

        modelURL = onnxURL
        isModelLoaded = true
        print("PiperTTS: model loaded — \(onnxURL.lastPathComponent), "
              + "sampleRate=\(config?.sampleRate ?? 22050)")
        return true
    }

    /// Build a minimal WAV file (RIFF header + raw PCM) from 16-bit samples.
    private func wavData(from samples: [Int16], sampleRate: Int) -> Data {
        let channels: Int16 = 1
        let bitsPerSample: Int16 = 16
        let byteRate = Int32(sampleRate) * Int32(channels) * Int32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let dataSize = Int32(samples.count * Int(bitsPerSample / 8))
        let chunkSize = 36 + dataSize

        var data = Data()

        // RIFF header
        data.append(contentsOf: [UInt8]("RIFF".utf8))
        data.append(withUnsafeBytes(of: chunkSize.littleEndian) { Data($0) })
        data.append(contentsOf: [UInt8]("WAVE".utf8))

        // fmt sub-chunk
        data.append(contentsOf: [UInt8]("fmt ".utf8))
        data.append(withUnsafeBytes(of: Int32(16).littleEndian) { Data($0) }) // sub-chunk size
        data.append(withUnsafeBytes(of: Int16(1).littleEndian) { Data($0) })  // PCM format
        data.append(withUnsafeBytes(of: channels.littleEndian) { Data($0) })
        data.append(withUnsafeBytes(of: Int32(sampleRate).littleEndian) { Data($0) })
        data.append(withUnsafeBytes(of: byteRate.littleEndian) { Data($0) })
        data.append(withUnsafeBytes(of: blockAlign.littleEndian) { Data($0) })
        data.append(withUnsafeBytes(of: bitsPerSample.littleEndian) { Data($0) })

        // data sub-chunk
        data.append(contentsOf: [UInt8]("data".utf8))
        data.append(withUnsafeBytes(of: dataSize.littleEndian) { Data($0) })
        samples.forEach { sample in
            data.append(withUnsafeBytes(of: sample.littleEndian) { Data($0) })
        }

        return data
    }
}
