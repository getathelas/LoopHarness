//
//  BedrockChatTests.swift
//  LoopIOSTests
//

import XCTest
@testable import Loop

final class BedrockChatTests: XCTestCase {

    func testRegionNormalizationAndEndpoint() {
        XCTAssertEqual(BedrockChat.normalizedRegion(" US-WEST-2 "), "us-west-2")
        XCTAssertNil(BedrockChat.normalizedRegion("us-east-1.example.com"))
        XCTAssertNil(BedrockChat.normalizedRegion("-us-east-1"))
        XCTAssertEqual(
            BedrockChat.endpoint(for: "us-east-1")?.absoluteString,
            "https://bedrock-mantle.us-east-1.api.aws/anthropic/v1/messages")
    }

    func testRequestBodyUsesAnthropicMessagesAndToolsShape() throws {
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

        let body = BedrockChat.requestBody(
            messages: messages,
            tools: tools,
            modelID: "anthropic.claude-opus-4-8")

        XCTAssertEqual(body["model"] as? String, "anthropic.claude-opus-4-8")
        XCTAssertEqual(body["system"] as? String, "Be concise.")
        XCTAssertEqual(body["stream"] as? Bool, true)

        let wireMessages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(wireMessages.first?["role"] as? String, "user")
        let bedrockTools = try XCTUnwrap(body["tools"] as? [[String: Any]])
        XCTAssertEqual(bedrockTools.first?["name"] as? String, "weather")
        XCTAssertNotNil(bedrockTools.first?["input_schema"])
    }

    func testOpusModelsUseBedrockKeyAndOfficialModelIDs() {
        let expected: [(ModelSelection, String)] = [
            (.bedrockOpus48, "anthropic.claude-opus-4-8"),
            (.bedrockOpus47, "anthropic.claude-opus-4-7"),
        ]

        for (model, modelID) in expected {
            XCTAssertEqual(model.provider, .bedrock)
            XCTAssertEqual(model.requiredKey, .bedrock)
            XCTAssertEqual(model.apiModelID, modelID)
            XCTAssertTrue(model.supportsVision)
            XCTAssertEqual(model.contextWindowSize, 1_048_576)
            XCTAssertTrue(model.stampedMessageModel.hasSuffix("via Bedrock"))
            XCTAssertEqual(ModelSelection.contextWindowSize(forStamp: model.stampedMessageModel),
                           1_048_576)
        }
    }
}
