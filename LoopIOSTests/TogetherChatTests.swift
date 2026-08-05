//
//  TogetherChatTests.swift
//  LoopIOSTests
//

import XCTest
@testable import Loop

final class TogetherChatTests: XCTestCase {

    func testDeepSeekModelSelectionUsesTogetherContract() {
        let model = ModelSelection.togetherDeepSeekV4Flash0731

        XCTAssertEqual(model.provider, .together)
        XCTAssertEqual(model.requiredKey, .together)
        XCTAssertEqual(model.displayName, "DeepSeek V4 Flash 0731")
        XCTAssertEqual(model.apiModelID, "deepseek-ai/DeepSeek-V4-Flash-0731")
        XCTAssertEqual(model.contextWindowSize, 1_048_576)
        XCTAssertFalse(model.supportsVision)
        XCTAssertEqual(model.stampedMessageModel, "DeepSeek V4 Flash 0731 via Together")
        XCTAssertEqual(ModelSelection.contextWindowSize(forStamp: model.stampedMessageModel),
                       1_048_576)
    }

    func testRequestBodyUsesTogetherChatCompletionsShape() throws {
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

        let body = TogetherChat.requestBody(
            messages: messages,
            tools: tools,
            modelID: TogetherChat.defaultModelID)

        XCTAssertEqual(TogetherChat.endpoint.absoluteString,
                       "https://api.together.xyz/v1/chat/completions")
        XCTAssertEqual(body["model"] as? String,
                       "deepseek-ai/DeepSeek-V4-Flash-0731")
        XCTAssertEqual(body["max_tokens"] as? Int, 16_384)
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual(body["tool_choice"] as? String, "auto")
        XCTAssertNotNil(body["messages"] as? [[String: Any]])
        XCTAssertNotNil(body["tools"] as? [[String: Any]])
    }
}
