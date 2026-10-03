//
//  CodexAppServerClient.swift
//  LoopMac
//
//  Owns one long-lived `codex app-server --listen stdio://` child process.
//  App-server speaks newline-delimited JSON-RPC (without a `jsonrpc` field)
//  over stdin/stdout. The client serializes all process and callback state on
//  one queue and exposes only request/notification primitives to the service.
//

import Foundation

final class CodexAppServerClient {
    static let shared = CodexAppServerClient()

    typealias JSONObject = [String: Any]
    typealias NotificationHandler = (_ method: String, _ params: JSONObject) -> Void

    private let queue = DispatchQueue(label: "loop.codex.app-server")
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutBuffer = Data()
    private var nextRequestId = 1
    private var pending: [Int: (Result<JSONObject, Error>) -> Void] = [:]
    private var startupCallbacks: [(Result<Void, Error>) -> Void] = []
    private var isReady = false
    private var stderrTail = ""

    var onNotification: NotificationHandler?

    private init() {}

    static func resolvedExecutablePath() -> String? {
        let defaultsPath = UserDefaults.standard.string(forKey: "loop.codex.executablePath")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var candidates: [String] = []
        if let defaultsPath, !defaultsPath.isEmpty { candidates.append(defaultsPath) }
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map { "\($0)/codex" })
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        candidates.append(contentsOf: [
            "\(home)/.local/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex"
        ])
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var isAvailable: Bool {
        resolvedExecutablePath() != nil && ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] == nil
    }

    func start(completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async {
            if self.isReady {
                DispatchQueue.main.async { completion(.success(())) }
                return
            }
            self.startupCallbacks.append(completion)
            guard self.process == nil else { return }
            self.launch()
        }
    }

    func stop() {
        queue.async {
            self.process?.terminationHandler = nil
            if self.process?.isRunning == true { self.process?.terminate() }
            self.failConnection(CodexAppServerError.terminated("Codex app-server stopped."))
        }
    }

    func request(method: String,
                 params: JSONObject = [:],
                 completion: @escaping (Result<JSONObject, Error>) -> Void) {
        start { result in
            switch result {
            case .failure(let error): completion(.failure(error))
            case .success:
                self.queue.async {
                    let id = self.nextRequestId
                    self.nextRequestId += 1
                    self.pending[id] = completion
                    do {
                        try self.write(["method": method, "id": id, "params": params])
                    } catch {
                        self.pending.removeValue(forKey: id)
                        DispatchQueue.main.async { completion(.failure(error)) }
                    }
                }
            }
        }
    }

    func notify(method: String, params: JSONObject = [:]) {
        queue.async {
            guard self.isReady else { return }
            try? self.write(["method": method, "params": params])
        }
    }

    private func launch() {
        guard ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] == nil else {
            finishStartup(.failure(CodexAppServerError.unavailable(
                "Codex agents require the non-sandboxed Mac build because Loop must launch the local Codex CLI."
            )))
            return
        }
        guard let executable = Self.resolvedExecutablePath() else {
            finishStartup(.failure(CodexAppServerError.executableNotFound))
            return
        }

        let child = Process()
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        child.executableURL = URL(fileURLWithPath: executable)
        child.arguments = ["app-server", "--listen", "stdio://"]
        child.standardInput = input
        child.standardOutput = output
        child.standardError = errors
        child.terminationHandler = { [weak self] process in
            self?.queue.async {
                let suffix = self?.stderrTail.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let detail = suffix.isEmpty ? "" : " \(suffix)"
                self?.failConnection(CodexAppServerError.terminated(
                    "Codex app-server exited with status \(process.terminationStatus).\(detail)"
                ))
            }
        }

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.queue.async { self?.consumeStdout(data) }
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            self?.queue.async {
                self?.stderrTail.append(text)
                if let count = self?.stderrTail.count, count > 4_000 {
                    self?.stderrTail = String(self?.stderrTail.suffix(4_000) ?? "")
                }
            }
        }

        do {
            try child.run()
            process = child
            stdinHandle = input.fileHandleForWriting
            let initializeId = nextRequestId
            nextRequestId += 1
            pending[initializeId] = { [weak self] result in
                guard let self else { return }
                switch result {
                case .failure(let error): self.queue.async { self.finishStartup(.failure(error)) }
                case .success:
                    self.queue.async {
                        do {
                            try self.write(["method": "initialized", "params": [:]])
                            self.isReady = true
                            self.finishStartup(.success(()))
                        } catch {
                            self.finishStartup(.failure(error))
                        }
                    }
                }
            }
            try write([
                "method": "initialize",
                "id": initializeId,
                "params": [
                    "clientInfo": [
                        "name": "loop_harness",
                        "title": "Loop Harness",
                        "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
                    ]
                ]
            ])
        } catch {
            child.terminationHandler = nil
            if child.isRunning { child.terminate() }
            process = nil
            stdinHandle = nil
            finishStartup(.failure(error))
        }
    }

    private func write(_ object: JSONObject) throws {
        guard let stdinHandle else {
            throw CodexAppServerError.unavailable("Codex app-server is not connected.")
        }
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try stdinHandle.write(contentsOf: data)
    }

    private func consumeStdout(_ data: Data) {
        stdoutBuffer.append(data)
        while let newline = stdoutBuffer.firstIndex(of: 0x0A) {
            let line = stdoutBuffer[..<newline]
            stdoutBuffer.removeSubrange(...newline)
            guard !line.isEmpty,
                  let value = try? JSONSerialization.jsonObject(with: Data(line)),
                  let object = value as? JSONObject else { continue }
            handleMessage(object)
        }
    }

    private func handleMessage(_ object: JSONObject) {
        if let id = (object["id"] as? NSNumber)?.intValue,
           let callback = pending.removeValue(forKey: id) {
            if let error = object["error"] as? JSONObject {
                let result: Result<JSONObject, Error> = .failure(CodexAppServerError.server(
                    code: (error["code"] as? NSNumber)?.intValue,
                    message: error["message"] as? String ?? "Unknown error"
                ))
                DispatchQueue.main.async { callback(result) }
            } else if let result = object["result"] as? JSONObject {
                DispatchQueue.main.async { callback(.success(result)) }
            } else {
                let result: Result<JSONObject, Error> = .failure(CodexAppServerError.invalidResponse(
                    "Codex returned an invalid response for request \(id)."
                ))
                DispatchQueue.main.async { callback(result) }
            }
            return
        }
        if let method = object["method"] as? String, object["id"] == nil {
            let params = object["params"] as? JSONObject ?? [:]
            DispatchQueue.main.async { [weak self] in self?.onNotification?(method, params) }
            return
        }
        if let method = object["method"] as? String,
           let requestId = object["id"] {
            handleServerRequest(id: requestId,
                                method: method,
                                params: object["params"] as? JSONObject ?? [:])
        }
    }

    /// Loop-dispatched turns are unattended, so server-initiated prompts
    /// must never hang waiting for a hidden approval sheet. Stay inside the
    /// configured sandbox, decline escalations, and give request_user_input a
    /// deterministic best-judgment answer so the agent can finish or explain
    /// the limitation in its final response.
    private func handleServerRequest(id: Any,
                                     method: String,
                                     params: JSONObject) {
        let result: JSONObject
        switch method {
        case "item/commandExecution/requestApproval",
             "item/fileChange/requestApproval":
            result = ["decision": "decline"]
        case "item/permissions/requestApproval":
            result = ["permissions": [:], "scope": "turn"]
        case "mcpServer/elicitation/request":
            result = ["action": "decline", "content": NSNull()]
        case "item/tool/requestUserInput":
            var answers: JSONObject = [:]
            for question in params["questions"] as? [[String: Any]] ?? [] {
                guard let questionId = question["id"] as? String else { continue }
                let options = question["options"] as? [[String: Any]] ?? []
                let answer = (options.first?["label"] as? String)
                    ?? "Use your best judgment and continue without additional user input."
                answers[questionId] = ["answers": [answer]]
            }
            result = ["answers": answers]
        default:
            try? write([
                "id": id,
                "error": ["code": -32601, "message": "Loop does not support server request \(method)."]
            ])
            DispatchQueue.main.async { [weak self] in self?.onNotification?(method, params) }
            return
        }
        try? write(["id": id, "result": result])
        DispatchQueue.main.async { [weak self] in self?.onNotification?(method, params) }
    }

    private func finishStartup(_ result: Result<Void, Error>) {
        let callbacks = startupCallbacks
        startupCallbacks.removeAll()
        for callback in callbacks {
            DispatchQueue.main.async { callback(result) }
        }
    }

    private func failConnection(_ error: Error) {
        process = nil
        stdinHandle = nil
        isReady = false
        stdoutBuffer.removeAll(keepingCapacity: false)
        let callbacks = pending.values
        pending.removeAll()
        for callback in callbacks {
            DispatchQueue.main.async { callback(.failure(error)) }
        }
        finishStartup(.failure(error))
    }
}
