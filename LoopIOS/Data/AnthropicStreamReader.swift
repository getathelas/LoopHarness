//
//  AnthropicStreamReader.swift
//  Loop
//
//  SSE stream reader for Anthropic's Messages API streaming format.
//  Anthropic uses typed events (message_start, content_block_start,
//  content_block_delta, content_block_stop, message_delta, message_stop)
//  rather than OpenAI's flat `data:` chunks.
//
//  Handles all current content-block types (text, tool_use, thinking,
//  signature) so extended-thinking Opus responses don't crash. A
//  `didFinish` flag prevents double-delivery of the completion handler
//  when an HTTP error triggers both `didReceive response:` and
//  `didCompleteWithError:`.
//

import Foundation

final class AnthropicStreamReader: NSObject, URLSessionDataDelegate {

    struct Result {
        let content: String
        let toolCalls: [FunctionCallStruct]
        let usage: TokenUsage?
    }

    private let completion: (Swift.Result<Result, Error>) -> Void
    private var metrics: InferenceMetrics
    /// Fired on the URLSession delegate queue with each text delta as it
    /// arrives. Held strongly — see `SSEStreamReader.onDelta`.
    private let onDelta: ((String) -> Void)?

    private var contentBuffer = ""
    private var inputTokens: Int = 0
    private var outputTokens: Int = 0
    private var cacheReadTokens: Int = 0
    private var cacheCreationTokens: Int = 0

    /// Each content block has an index; tool_use blocks accumulate name, id,
    /// and a JSON-arguments string across deltas.
    private struct ToolUseAccumulator {
        var id: String = ""
        var name: String = ""
        var inputJSON: String = ""
    }
    private var toolUseBlocks: [Int: ToolUseAccumulator] = [:]
    /// Track content block types by index so deltas can route correctly.
    private var blockTypes: [Int: String] = [:]

    private var lineBuffer = ""
    private var currentEventType = ""
    private var receivedFirstChunk = false

    /// Guard against delivering the completion handler more than once.
    /// When the HTTP status is >= 400 the reader calls `completion` in
    /// `didReceive response:` and cancels the task; the subsequent
    /// `didCompleteWithError:` would otherwise deliver a second (spurious)
    /// cancellation error.
    private var didFinish = false

    init(metrics: InferenceMetrics,
         onDelta: ((String) -> Void)? = nil,
         completion: @escaping (Swift.Result<Result, Error>) -> Void) {
        self.metrics = metrics
        self.onDelta = onDelta
        self.completion = completion
    }

    /// Deliver the result exactly once.
    private func finish(_ result: Swift.Result<Result, Error>) {
        guard !didFinish else { return }
        didFinish = true
        completion(result)
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            completionHandler(.cancel)
            finish(.failure(NSError(
                domain: "AnthropicStreamReader",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode) from Anthropic"])))
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive data: Data) {
        if !receivedFirstChunk {
            receivedFirstChunk = true
            metrics.didReceiveFirstChunk()
        }

        guard let chunk = String(data: data, encoding: .utf8) else { return }
        lineBuffer += chunk

        while let range = lineBuffer.range(of: "\n") {
            let line = String(lineBuffer[lineBuffer.startIndex..<range.lowerBound])
            lineBuffer = String(lineBuffer[range.upperBound...])
            processLine(line)
        }
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        if let error = error {
            finish(.failure(error))
            return
        }
        if !lineBuffer.isEmpty {
            processLine(lineBuffer)
            lineBuffer = ""
        }
        finalizeResult()
    }

    // MARK: - SSE parsing

    private func processLine(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        if trimmed.hasPrefix("event: ") {
            currentEventType = String(trimmed.dropFirst(7))
            return
        }

        guard trimmed.hasPrefix("data: ") else { return }
        let payload = String(trimmed.dropFirst(6))
        guard let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        switch currentEventType {
        case "message_start":
            if let msg = json["message"] as? [String: Any],
               let u = msg["usage"] as? [String: Any] {
                if let input = u["input_tokens"] as? Int {
                    inputTokens = input
                }
                if let cr = u["cache_read_input_tokens"] as? Int {
                    cacheReadTokens = cr
                }
                if let cc = u["cache_creation_input_tokens"] as? Int {
                    cacheCreationTokens = cc
                }
            }

        case "content_block_start":
            guard let idx = json["index"] as? Int,
                  let block = json["content_block"] as? [String: Any],
                  let type = block["type"] as? String else { return }
            blockTypes[idx] = type
            if type == "tool_use" {
                var acc = ToolUseAccumulator()
                if let id = block["id"] as? String { acc.id = id }
                if let name = block["name"] as? String { acc.name = name }
                toolUseBlocks[idx] = acc
            }
            // `thinking` and `signature` blocks are tracked in blockTypes
            // so their deltas route through the correct branch below.

        case "content_block_delta":
            guard let idx = json["index"] as? Int,
                  let delta = json["delta"] as? [String: Any],
                  let deltaType = delta["type"] as? String else { return }

            switch deltaType {
            case "text_delta":
                if let text = delta["text"] as? String {
                    contentBuffer += text
                    onDelta?(text)
                }
            case "input_json_delta":
                if let partial = delta["partial_json"] as? String {
                    toolUseBlocks[idx]?.inputJSON += partial
                }
            case "thinking_delta", "signature_delta":
                // Extended-thinking / response-signature deltas are
                // acknowledged but not surfaced to the user. Logging
                // them aids debugging without crashing.
                break
            default:
                print("[AnthropicStreamReader] unhandled delta type: \(deltaType)")
            }

        case "message_delta":
            if let u = json["usage"] as? [String: Any],
               let output = u["output_tokens"] as? Int {
                outputTokens = output
            }

        case "error":
            // Anthropic may send an `error` event mid-stream (e.g.
            // overloaded_error). Surface it rather than silently
            // producing a partial/empty response.
            let message: String
            if let err = json["error"] as? [String: Any],
               let msg = err["message"] as? String {
                message = msg
            } else {
                message = "Unknown streaming error from Anthropic"
            }
            finish(.failure(NSError(
                domain: "AnthropicStreamReader",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: message])))

        default:
            break
        }
    }

    // MARK: - Finalize

    private func finalizeResult() {
        let calls: [FunctionCallStruct] = toolUseBlocks
            .sorted { $0.key < $1.key }
            .map { (_, acc) in
                var argsDict: [String: Any] = [:]
                if let d = acc.inputJSON.data(using: .utf8),
                   let parsed = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                    argsDict = parsed
                }
                return FunctionCallStruct(
                    name: acc.name,
                    arguments: argsDict,
                    callId: acc.id.isEmpty ? nil : acc.id)
            }

        var usage: TokenUsage?
        if inputTokens > 0 || outputTokens > 0 {
            usage = TokenUsage(promptTokens: inputTokens,
                               completionTokens: outputTokens,
                               totalTokens: inputTokens + outputTokens)
        }
        let cached = (cacheReadTokens > 0) ? cacheReadTokens : nil
        metrics.didComplete(usage: usage, cachedTokens: cached)

        finish(.success(Result(
            content: contentBuffer,
            toolCalls: calls,
            usage: usage)))
    }
}
