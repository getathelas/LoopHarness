//
//  MessageVariantTests.swift
//  LoopIOSTests
//
//  Tests for the alternate-variant data model: MessageAlternate,
//  SimpleAlternate serialization, and the activeContent / activeModel
//  computed properties on MessageStruct.
//

import XCTest
@testable import Loop

final class MessageAlternateTests: XCTestCase {

    // MARK: - MessageStruct defaults

    func testNewMessageHasNoAlternates() {
        let msg = MessageStruct(role: "assistant", content: "Hello")
        XCTAssertTrue(msg.alternates.isEmpty)
        XCTAssertNil(msg.selectedAlternateIndex)
    }

    func testActiveContentReturnsOriginalWhenNoSelection() {
        let msg = MessageStruct(role: "assistant", content: "Original")
        XCTAssertEqual(msg.activeContent, "Original")
        XCTAssertEqual(msg.activeModel, "GPT 5.5 Instant")
    }

    func testActiveContentReturnsOriginalWhenIndexZero() {
        var msg = MessageStruct(role: "assistant", content: "Original")
        msg.alternates = [MessageAlternate(content: "Alt", model: "Claude")]
        msg.selectedAlternateIndex = 0
        XCTAssertEqual(msg.activeContent, "Original")
    }

    func testActiveContentReturnsAlternate() {
        var msg = MessageStruct(role: "assistant", content: "Original")
        msg.alternates = [
            MessageAlternate(content: "Alt1", model: "Claude"),
            MessageAlternate(content: "Alt2", model: "GPT 4o"),
        ]
        msg.selectedAlternateIndex = 2
        XCTAssertEqual(msg.activeContent, "Alt2")
        XCTAssertEqual(msg.activeModel, "GPT 4o")
    }

    func testActiveContentFallsBackForOutOfBoundsIndex() {
        var msg = MessageStruct(role: "assistant", content: "Original")
        msg.alternates = [MessageAlternate(content: "Alt", model: "Claude")]
        msg.selectedAlternateIndex = 99
        XCTAssertEqual(msg.activeContent, "Original")
    }

    // MARK: - SimpleAlternate round-trip

    func testSimpleAlternateRoundTrip() throws {
        let original = SimpleAlternate(id: "test-id", content: "Hello", model: "Claude", createdAt: Date(timeIntervalSince1970: 1000))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SimpleAlternate.self, from: data)
        XCTAssertEqual(decoded.id, "test-id")
        XCTAssertEqual(decoded.content, "Hello")
        XCTAssertEqual(decoded.model, "Claude")
    }

    func testSimpleAlternateArrayRoundTrip() throws {
        let alts = [
            SimpleAlternate(id: "a", content: "One", model: "M1", createdAt: Date()),
            SimpleAlternate(id: "b", content: "Two", model: "M2", createdAt: Date()),
        ]
        let data = try JSONEncoder().encode(alts)
        let json = String(data: data, encoding: .utf8)!
        let decoded = try JSONDecoder().decode([SimpleAlternate].self, from: json.data(using: .utf8)!)
        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[0].content, "One")
        XCTAssertEqual(decoded[1].model, "M2")
    }

    // MARK: - SimpleMessage backward compatibility

    func testSimpleMessageWithoutAlternatesDecodesCleanly() throws {
        // Simulate an old NDJSON row that has no alternates or selectedAlternateIndex fields.
        let json = """
        {"id":"old","role":"assistant","content":"Hi","createdAt":0}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let msg = try decoder.decode(SimpleMessage.self, from: json.data(using: .utf8)!)
        XCTAssertNil(msg.alternates)
        XCTAssertNil(msg.selectedAlternateIndex)
    }
}
