//
//  TogetherChat.swift
//  Loop
//
//  Direct client-side Together AI inference path. Together's chat endpoint
//  is OpenAI-compatible, so message mapping, tool schemas, streaming, and
//  tool-call assembly reuse the same helpers as OpenAIChat.
//

import Foundation

final class TogetherChat {

    static let shared = TogetherChat()
    private init() {}

    static let endpoint = URL(string: "https://api.together.xyz/v1/chat/completions")!
    static let defaultModelID = "deepseek-ai/DeepSeek-V4-Flash-0731"
    static let maxTokens = 16_384

    private lazy var streamingSessionDelegate = StreamingSessionDelegateRouter()
    private lazy var streamingSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 180
        config.waitsForConnectivity = true
        return URLSession(configuration: config,
                          delegate: streamingSessionDelegate,
                          delegateQueue: nil)
    }()

    static func requestBody(messages: [MessageStruct],
                            tools: [[String: Any]]?,
                            modelID: String) -> [String: Any] {
        var body: [String: Any] = [
            "model": modelID,
            "messages": OpenAIChat.wireMessages(from: messages),
            "max_tokens": maxTokens,
            "stream": true,
            "stream_options": ["include_usage": true],
        ]
        if let tools, !tools.isEmpty {
            body["tools"] = tools
            body["tool_choice"] = "auto"
        }
        return body
    }

    func chat(messages: [MessageStruct],
              tools: [[String: Any]]? = nil,
              modelIDOverride: String? = nil,
              modelStampOverride: String? = nil,
              onPartial: ((String) -> Void)? = nil,
              completion: @escaping (MessageStruct?, Error?) -> Void) {
        guard let apiKey = KeyStore.shared.value(for: .together),
              !apiKey.isEmpty else {
            completion(nil, Self.error(
                "Together AI is selected but no Together AI key is set. Add TOGETHER_API_KEY in Settings ▸ Keys, or switch the model in Settings ▸ Model."))
            return
        }

        let modelID = modelIDOverride
            ?? ModelSelectionStore.current.apiModelID
            ?? Self.defaultModelID
        let body = Self.requestBody(messages: messages, tools: tools, modelID: modelID)

        guard let payload = try? JSONSerialization.data(withJSONObject: body) else {
            completion(nil, Self.error("Failed to encode the Together AI request body."))
            return
        }

        var metrics = InferenceMetrics(provider: "Together AI",
                                       model: modelID,
                                       toolCount: (tools ?? []).count)
        metrics.didBuildPayload(bytes: payload.count)

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = payload
        request.timeoutInterval = 120

        metrics.willSendRequest()

        let reader = SSEStreamReader(metrics: metrics, onDelta: onPartial) { result in
            switch result {
            case .success(let response):
                let message = MessageStruct(
                    role: "assistant",
                    content: response.content,
                    model: modelStampOverride ?? ModelSelectionStore.current.stampedMessageModel,
                    functions: response.toolCalls,
                    reasoningContent: response.reasoningContent,
                    tokenUsage: response.usage,
                    ttft: response.ttft)
                completion(message, nil)
            case .failure(let error):
                completion(nil, Self.error(
                    "Together AI streaming error: \(error.localizedDescription)"))
            }
        }

        let task = streamingSession.dataTask(with: request)
        streamingSessionDelegate.register(task: task, reader: reader)
        LocalInferenceController.shared.track(task)
        task.resume()
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "TogetherChat", code: -1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}
