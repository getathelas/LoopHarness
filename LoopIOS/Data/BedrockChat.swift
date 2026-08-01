//
//  BedrockChat.swift
//  Loop
//
//  Amazon Bedrock client for Claude models. Bedrock Mantle exposes the native
//  Anthropic Messages API, so this path deliberately shares AnthropicChat's
//  message/tool mapping and AnthropicStreamReader. The only provider-specific
//  pieces are the regional endpoint, Bedrock model IDs, and API key.
//

import Foundation

final class BedrockChat {

    static let shared = BedrockChat()
    static let defaultRegion = "us-east-1"

    private init() {}

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

    private let anthropicVersion = "2023-06-01"
    private let maxTokens = 4096

    func chat(messages: [MessageStruct],
              tools: [[String: Any]]? = nil,
              modelIDOverride: String? = nil,
              modelStampOverride: String? = nil,
              onPartial: ((String) -> Void)? = nil,
              completion: @escaping (MessageStruct?, Error?) -> Void) {

        guard let apiKey = KeyStore.shared.value(for: .bedrock),
              !apiKey.isEmpty else {
            completion(nil, Self.error(
                "Amazon Bedrock is selected but no Bedrock API key is set. Add AWS_BEARER_TOKEN_BEDROCK in Settings ▸ Keys, or switch the model in Settings ▸ Model."))
            return
        }

        let configuredRegion = KeyStore.shared.value(for: .bedrockRegion)
        guard configuredRegion?.isEmpty != false || Self.normalizedRegion(configuredRegion) != nil else {
            completion(nil, Self.error(
                "The Amazon Bedrock region is invalid. Use an AWS region such as us-east-1 in Settings ▸ Keys ▸ Amazon Bedrock."))
            return
        }
        let region = Self.normalizedRegion(configuredRegion) ?? Self.defaultRegion
        guard let endpoint = Self.endpoint(for: region) else {
            completion(nil, Self.error("Failed to build the Amazon Bedrock endpoint."))
            return
        }

        let modelID = modelIDOverride
            ?? ModelSelectionStore.current.apiModelID
            ?? "anthropic.claude-opus-4-8"
        let body = Self.requestBody(messages: messages, tools: tools, modelID: modelID,
                                    maxTokens: maxTokens)
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else {
            completion(nil, Self.error("Failed to encode the Amazon Bedrock request body."))
            return
        }

        var metrics = InferenceMetrics(provider: "Amazon Bedrock",
                                       model: modelID,
                                       toolCount: (tools ?? []).count)
        metrics.didBuildPayload(bytes: payload.count)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = payload
        request.timeoutInterval = 120

        metrics.willSendRequest()

        let reader = AnthropicStreamReader(
            metrics: metrics,
            serviceName: "Amazon Bedrock",
            onDelta: onPartial
        ) { result in
            switch result {
            case .success(let response):
                completion(MessageStruct(
                    role: "assistant",
                    content: response.content,
                    model: modelStampOverride ?? ModelSelectionStore.current.stampedMessageModel,
                    functions: response.toolCalls,
                    tokenUsage: response.usage,
                    ttft: response.ttft), nil)
            case .failure(let error):
                completion(nil, Self.error(
                    "Amazon Bedrock streaming error: \(error.localizedDescription)"))
            }
        }

        let task = streamingSession.dataTask(with: request)
        streamingSessionDelegate.register(task: task, reader: reader)
        LocalInferenceController.shared.track(task)
        task.resume()
    }

    static func requestBody(messages: [MessageStruct],
                            tools: [[String: Any]]?,
                            modelID: String,
                            maxTokens: Int = 4096) -> [String: Any] {
        let (system, wireMessages) = AnthropicChat.wirePayload(from: messages)
        var body: [String: Any] = [
            "model": modelID,
            "max_tokens": maxTokens,
            "messages": wireMessages,
            "stream": true,
        ]
        if let system, !system.isEmpty {
            body["system"] = system
        }
        if let tools, !tools.isEmpty {
            body["tools"] = AnthropicChat.anthropicTools(from: tools)
            body["tool_choice"] = ["type": "auto"]
        }
        return body
    }

    /// Keep the region constrained to a hostname-safe AWS region token. The
    /// endpoint host is always owned by AWS; a stored value cannot redirect
    /// requests (and the API key) to another domain.
    static func normalizedRegion(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !value.isEmpty,
              value.count <= 32,
              value.first != "-",
              value.last != "-",
              value.allSatisfy({ $0.isLowercase || $0.isNumber || $0 == "-" }) else {
            return nil
        }
        return value
    }

    static func endpoint(for region: String) -> URL? {
        guard let safeRegion = normalizedRegion(region) else { return nil }
        return URL(string: "https://bedrock-mantle.\(safeRegion).api.aws/anthropic/v1/messages")
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "BedrockChat", code: -1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}
