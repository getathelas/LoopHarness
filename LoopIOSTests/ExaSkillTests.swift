//
//  ExaSkillTests.swift
//  LoopIOSTests
//
//  Covers the input coercion in front of exa_get_contents. The network paths
//  need a live Exa key, so these tests exercise the argument normalization
//  that decides whether we call Exa at all.
//

import XCTest
@testable import Loop

final class ExaSkillTests: XCTestCase {

    // MARK: - Proper array input

    func testArrayOfStringsPassesThroughUnchanged() {
        let urls = ["https://example.com", "https://example.org/a?b=c"]
        XCTAssertEqual(ExaSkill.coerceStringList(urls), urls)
    }

    func testArrayEntriesAreTrimmedAndEmptiesDropped() {
        let input = ["  https://example.com  ", "", "   "]
        XCTAssertEqual(ExaSkill.coerceStringList(input), ["https://example.com"])
    }

    // MARK: - Bare string input

    func testBareStringURLIsWrappedInArray() {
        XCTAssertEqual(ExaSkill.coerceStringList("https://example.com"),
                       ["https://example.com"])
    }

    func testBareStringURLIsTrimmed() {
        XCTAssertEqual(ExaSkill.coerceStringList("\n https://example.com "),
                       ["https://example.com"])
    }

    // MARK: - Stringified JSON input

    func testStringifiedJSONArrayIsParsed() {
        let raw = "[\"https://example.com\", \"https://example.org\"]"
        XCTAssertEqual(ExaSkill.coerceStringList(raw),
                       ["https://example.com", "https://example.org"])
    }

    func testStringifiedJSONStringIsUnwrapped() {
        XCTAssertEqual(ExaSkill.coerceStringList("\"https://example.com\""),
                       ["https://example.com"])
    }

    func testStringifiedJSONEmptyArrayYieldsNothing() {
        XCTAssertEqual(ExaSkill.coerceStringList("[]"), [])
    }

    // MARK: - Invalid input

    func testNilAndNonStringInputsYieldNothing() {
        XCTAssertEqual(ExaSkill.coerceStringList(nil), [])
        XCTAssertEqual(ExaSkill.coerceStringList(""), [])
        XCTAssertEqual(ExaSkill.coerceStringList(42), [])
        XCTAssertEqual(ExaSkill.coerceStringList(["a": "b"]), [])
        XCTAssertEqual(ExaSkill.coerceStringList([1, 2]), [])
    }

    func testMalformedJSONArrayFallsBackToRawString() {
        // A truncated JSON array isn't parseable — treat it as a single value
        // rather than throwing the whole call away.
        XCTAssertEqual(ExaSkill.coerceStringList("[\"https://example.com\""),
                       ["[\"https://example.com\""])
    }

    // MARK: - URL validation

    func testLooksLikeHTTPURLAcceptsHTTPAndHTTPS() {
        XCTAssertTrue(ExaSkill.looksLikeHTTPURL("https://example.com"))
        XCTAssertTrue(ExaSkill.looksLikeHTTPURL("http://example.com/path?q=1"))
        XCTAssertTrue(ExaSkill.looksLikeHTTPURL("HTTPS://Example.com"))
    }

    func testLooksLikeHTTPURLRejectsNonURLs() {
        XCTAssertFalse(ExaSkill.looksLikeHTTPURL("example.com"))
        XCTAssertFalse(ExaSkill.looksLikeHTTPURL("ftp://example.com"))
        XCTAssertFalse(ExaSkill.looksLikeHTTPURL("https://"))
        XCTAssertFalse(ExaSkill.looksLikeHTTPURL("not a url"))
    }

    // MARK: - Status text uses the coerced value

    func testStatusTextHandlesStringifiedJSONArray() {
        let call = FunctionCallStruct(name: "exa_get_contents",
                                     arguments: ["urls": "[\"https://example.com/page\"]"])
        XCTAssertEqual(ExaSkill.shared.statusText(for: call), "reading example.com")
    }

    func testStatusTextHandlesBareStringURL() {
        let call = FunctionCallStruct(name: "exa_get_contents",
                                     arguments: ["urls": "https://example.com/page"])
        XCTAssertEqual(ExaSkill.shared.statusText(for: call), "reading example.com")
    }
}
