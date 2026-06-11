//
//  KeyResultStore.swift
//  Loop
//
//  Local JSON-file persistence for Key Results. Mirrors the pattern used by
//  `ConversationFileStore` (iCloud Documents container) but stores a single
//  JSON array file rather than per-item NDJSON — the dataset is small enough
//  that atomic rewrites are fine for v1.
//
//  File location:
//      <iCloudContainer>/Documents/key_results.json
//  Falls back to the app's local Documents/ if iCloud is unavailable (same
//  fallback strategy as `ConversationFileStore`).
//

import Foundation

final class KeyResultStore {

    static let shared = KeyResultStore()

    static let didChangeNotification = Notification.Name("KeyResultStoreDidChange")

    private let fileManager = FileManager.default
    private let ioQueue = DispatchQueue(label: "com.bhat.intel.keyresultstore.io", qos: .utility)

    private var cache: [KeyResult] = []
    private let cacheLock = NSLock()

    private init() {
        loadFromDisk()
    }

    // MARK: - Public reads

    var allKeyResults: [KeyResult] {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return cache
    }

    func keyResult(by id: String) -> KeyResult? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return cache.first(where: { $0.id == id })
    }

    // MARK: - Public writes

    func save(_ kr: KeyResult) {
        var toSave = kr
        toSave.updatedAt = Date()
        // Never persist the token in the JSON file.
        if let token = toSave.bearerToken, !token.isEmpty {
            KeyResultKeychainHelper.save(token: token, for: toSave.id)
        }
        toSave.bearerToken = nil

        cacheLock.lock()
        if let idx = cache.firstIndex(where: { $0.id == toSave.id }) {
            cache[idx] = toSave
        } else {
            cache.append(toSave)
        }
        cacheLock.unlock()

        flushToDisk()
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    func delete(id: String) {
        cacheLock.lock()
        cache.removeAll(where: { $0.id == id })
        cacheLock.unlock()

        KeyResultKeychainHelper.delete(for: id)
        flushToDisk()
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    // MARK: - Disk I/O

    private var fileURL: URL {
        // Prefer iCloud container (same one ConversationFileStore uses).
        if let container = fileManager.url(forUbiquityContainerIdentifier: "iCloud.com.bhat.intel") {
            let docs = container.appendingPathComponent("Documents")
            try? fileManager.createDirectory(at: docs, withIntermediateDirectories: true)
            return docs.appendingPathComponent("key_results.json")
        }
        // Fallback to local Documents.
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("key_results.json")
    }

    private func loadFromDisk() {
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let items = try decoder.decode([KeyResult].self, from: data)
            cacheLock.lock()
            cache = items
            cacheLock.unlock()
        } catch {
            // Silently start empty on decode failure — matches ConversationFileStore behavior.
        }
    }

    private func flushToDisk() {
        cacheLock.lock()
        let snapshot = cache
        cacheLock.unlock()

        ioQueue.async { [weak self] in
            guard let self else { return }
            do {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(snapshot)
                try data.write(to: self.fileURL, options: .atomic)
            } catch {
                // Best-effort; next save will retry.
            }
        }
    }
}
