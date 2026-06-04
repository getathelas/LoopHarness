//
//  PiperModelManager.swift
//  Loop
//
//  Manages Piper ONNX voice models: discovery, download, caching, and
//  lifecycle. Models are stored under the app's Documents/PiperModels/
//  directory so they persist across launches and are visible in the Files
//  app.
//
//  Each voice model consists of two files:
//    • <voice>.onnx       — the ONNX inference graph
//    • <voice>.onnx.json  — model config (sample rate, phoneme map, etc.)
//
//  The manager ships with metadata for a curated set of English voices.
//  On first use (or when the user picks a voice that isn't downloaded yet)
//  it pulls the model pair from the Piper release CDN on GitHub.
//

import Foundation

// MARK: - Voice descriptor

/// Metadata for a single Piper voice model.
struct PiperVoiceDescriptor: Equatable {
    let id: String
    let displayName: String
    let quality: Quality
    /// Base URL for the .onnx and .onnx.json files (GitHub Releases CDN).
    let remoteBaseURL: URL
    let sampleRate: Int

    enum Quality: String { case low, medium, high }
}

// MARK: - Manager

final class PiperModelManager {

    static let shared = PiperModelManager()

    /// Posted when the set of downloaded voices changes (a download finishes
    /// or a model is deleted). Observers should refresh any voice-list UI.
    static let modelsDidChangeNotification = Notification.Name("PiperModelManager.modelsDidChange")

    // Curated English voices. IDs match the Piper release naming convention
    // (<lang>_<region>-<name>-<quality>). The remote URLs point to the
    // rhasspy/piper GitHub Releases asset tree.
    private static let catalog: [PiperVoiceDescriptor] = [
        PiperVoiceDescriptor(
            id: "en_US-lessac-medium",
            displayName: "Lessac (medium, female)",
            quality: .medium,
            remoteBaseURL: URL(string: "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/lessac/medium/")!,
            sampleRate: 22050
        ),
        PiperVoiceDescriptor(
            id: "en_US-lessac-high",
            displayName: "Lessac (high, female)",
            quality: .high,
            remoteBaseURL: URL(string: "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/lessac/high/")!,
            sampleRate: 22050
        ),
        PiperVoiceDescriptor(
            id: "en_US-amy-medium",
            displayName: "Amy (medium, female)",
            quality: .medium,
            remoteBaseURL: URL(string: "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/amy/medium/")!,
            sampleRate: 22050
        ),
        PiperVoiceDescriptor(
            id: "en_US-ryan-medium",
            displayName: "Ryan (medium, male)",
            quality: .medium,
            remoteBaseURL: URL(string: "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/ryan/medium/")!,
            sampleRate: 22050
        ),
        PiperVoiceDescriptor(
            id: "en_US-ryan-high",
            displayName: "Ryan (high, male)",
            quality: .high,
            remoteBaseURL: URL(string: "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/ryan/high/")!,
            sampleRate: 22050
        ),
        PiperVoiceDescriptor(
            id: "en_GB-alan-medium",
            displayName: "Alan (medium, male, British)",
            quality: .medium,
            remoteBaseURL: URL(string: "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_GB/alan/medium/")!,
            sampleRate: 22050
        ),
    ]

    /// All voices the user can choose from, regardless of download state.
    var availableVoices: [PiperVoiceDescriptor] { Self.catalog }

    /// ID of the default voice when the user hasn't picked one yet.
    var defaultVoiceId: String { Self.catalog.first?.id ?? "" }

    /// Root directory for cached models.
    private var modelsDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("PiperModels", isDirectory: true)
    }

    private init() {
        try? FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Query

    /// Descriptor for `voiceId`, or nil if it isn't in the catalog.
    func descriptor(for voiceId: String) -> PiperVoiceDescriptor? {
        Self.catalog.first { $0.id == voiceId }
    }

    /// Whether both the .onnx and .onnx.json files exist locally.
    func isDownloaded(_ voiceId: String) -> Bool {
        let dir = modelsDirectory.appendingPathComponent(voiceId, isDirectory: true)
        let onnx = dir.appendingPathComponent("\(voiceId).onnx")
        let json = dir.appendingPathComponent("\(voiceId).onnx.json")
        return FileManager.default.fileExists(atPath: onnx.path)
            && FileManager.default.fileExists(atPath: json.path)
    }

    /// Local path to the .onnx model file, or nil if not downloaded.
    func modelPath(for voiceId: String) -> URL? {
        guard isDownloaded(voiceId) else { return nil }
        return modelsDirectory
            .appendingPathComponent(voiceId, isDirectory: true)
            .appendingPathComponent("\(voiceId).onnx")
    }

    /// Local path to the .onnx.json config file, or nil if not downloaded.
    func configPath(for voiceId: String) -> URL? {
        guard isDownloaded(voiceId) else { return nil }
        return modelsDirectory
            .appendingPathComponent(voiceId, isDirectory: true)
            .appendingPathComponent("\(voiceId).onnx.json")
    }

    // MARK: - Download

    enum DownloadError: LocalizedError {
        case unknownVoice(String)
        case networkError(Error)
        case fileSystemError(Error)

        var errorDescription: String? {
            switch self {
            case .unknownVoice(let id):    return "Unknown Piper voice: \(id)"
            case .networkError(let err):   return "Download failed: \(err.localizedDescription)"
            case .fileSystemError(let e):  return "File error: \(e.localizedDescription)"
            }
        }
    }

    /// Download the model pair for `voiceId`. Calls `completion` on main.
    /// If the model is already present, completes immediately with success.
    func download(voiceId: String, completion: @escaping (Result<Void, DownloadError>) -> Void) {
        guard let desc = descriptor(for: voiceId) else {
            DispatchQueue.main.async { completion(.failure(.unknownVoice(voiceId))) }
            return
        }
        if isDownloaded(voiceId) {
            DispatchQueue.main.async { completion(.success(())) }
            return
        }

        let voiceDir = modelsDirectory.appendingPathComponent(voiceId, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: voiceDir, withIntermediateDirectories: true)
        } catch {
            DispatchQueue.main.async { completion(.failure(.fileSystemError(error))) }
            return
        }

        let onnxURL  = desc.remoteBaseURL.appendingPathComponent("\(voiceId).onnx")
        let jsonURL  = desc.remoteBaseURL.appendingPathComponent("\(voiceId).onnx.json")
        let localOnnx = voiceDir.appendingPathComponent("\(voiceId).onnx")
        let localJson = voiceDir.appendingPathComponent("\(voiceId).onnx.json")

        let group = DispatchGroup()
        var downloadError: Error?

        for (remote, local) in [(onnxURL, localOnnx), (jsonURL, localJson)] {
            group.enter()
            URLSession.shared.downloadTask(with: remote) { tempURL, _, error in
                defer { group.leave() }
                if let error = error {
                    downloadError = error
                    return
                }
                guard let tempURL = tempURL else {
                    downloadError = NSError(domain: "PiperModelManager", code: -1,
                                           userInfo: [NSLocalizedDescriptionKey: "No data received"])
                    return
                }
                do {
                    if FileManager.default.fileExists(atPath: local.path) {
                        try FileManager.default.removeItem(at: local)
                    }
                    try FileManager.default.moveItem(at: tempURL, to: local)
                } catch {
                    downloadError = error
                }
            }.resume()
        }

        group.notify(queue: .main) { [weak self] in
            if let error = downloadError {
                // Clean up partial download.
                try? FileManager.default.removeItem(at: voiceDir)
                completion(.failure(.networkError(error)))
                return
            }
            NotificationCenter.default.post(name: PiperModelManager.modelsDidChangeNotification, object: nil)
            self?.logModelSizes(voiceId: voiceId)
            completion(.success(()))
        }
    }

    /// Delete a downloaded model to free disk space.
    func deleteModel(voiceId: String) {
        let dir = modelsDirectory.appendingPathComponent(voiceId, isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        NotificationCenter.default.post(name: PiperModelManager.modelsDidChangeNotification, object: nil)
    }

    /// Ensure the default voice is downloaded. Called at app launch so the
    /// first Piper speak attempt doesn't stall on a download.
    func preloadDefaultIfNeeded() {
        let id = defaultVoiceId
        guard !id.isEmpty, !isDownloaded(id) else { return }
        download(voiceId: id) { result in
            switch result {
            case .success:
                print("PiperModelManager: preloaded default voice \(id)")
            case .failure(let err):
                print("PiperModelManager: preload failed — \(err.localizedDescription)")
            }
        }
    }

    private func logModelSizes(voiceId: String) {
        guard let onnx = modelPath(for: voiceId) else { return }
        let attrs = try? FileManager.default.attributesOfItem(atPath: onnx.path)
        let bytes = attrs?[.size] as? Int64 ?? 0
        let mb = Double(bytes) / 1_048_576
        print("PiperModelManager: \(voiceId) model size: \(String(format: "%.1f", mb)) MB")
    }
}
