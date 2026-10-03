//
//  DeepInfraChatTests.swift
//  LoopIOSTests
//

import XCTest
@testable import Loop

final class DeepInfraChatTests: XCTestCase {

    func testDeepSeekModelSelectionUsesDeepInfraContract() {
        let model = ModelSelection.deepInfraDeepSeekV4Flash0731

        XCTAssertEqual(model.provider, .deepInfra)
        XCTAssertEqual(model.requiredKey, .deepInfra)
        XCTAssertEqual(model.displayName, "DeepSeek V4 Flash 0731")
        XCTAssertEqual(model.apiModelID, "deepseek-ai/DeepSeek-V4-Flash-0731")
        XCTAssertEqual(model.contextWindowSize, 1_048_576)
        XCTAssertFalse(model.supportsVision)
        XCTAssertEqual(model.stampedMessageModel, "DeepSeek V4 Flash 0731 via DeepInfra")
        XCTAssertEqual(ModelSelection.contextWindowSize(forStamp: model.stampedMessageModel),
                       1_048_576)
    }

    func testRequestBodyUsesDeepInfraChatCompletionsShape() throws {
        let messages = [
            MessageStruct(role: "system", content: "Be concise."),
            MessageStruct(role: "user", content: "Check the weather."),
        ]
        let tools: [[String: Any]] = [[
            "type": "function",
            "function": [
                "name": "weather",
                "description": "Get weather",
                "parameters": [
                    "type": "object",
                    "properties": ["city": ["type": "string"]],
                ] as [String: Any],
            ] as [String: Any],
        ]]

        let body = DeepInfraChat.requestBody(
            messages: messages,
            tools: tools,
            modelID: DeepInfraChat.defaultModelID)

        XCTAssertEqual(DeepInfraChat.endpoint.absoluteString,
                       "https://api.deepinfra.com/v1/openai/chat/completions")
        XCTAssertEqual(body["model"] as? String,
                       "deepseek-ai/DeepSeek-V4-Flash-0731")
        XCTAssertEqual(body["max_tokens"] as? Int, 16_384)
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual(body["tool_choice"] as? String, "auto")
        XCTAssertNotNil(body["messages"] as? [[String: Any]])
        XCTAssertNotNil(body["tools"] as? [[String: Any]])
    }
}
