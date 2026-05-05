import XCTest
@testable import WeChatHUD

final class AIJSONExtractorTests: XCTestCase {
    private struct Payload: Decodable, Equatable {
        let name: String
        let note: String
    }

    private struct Item: Decodable, Equatable {
        let index: Int
        let value: String
    }

    func testDecodesObjectWithTrailingProse() {
        let raw = #"{"name":"ok","note":"value"}\n说明文字"#

        let decoded = AIJSONExtractor.decodeFirstObject(from: raw, as: Payload.self)

        XCTAssertEqual(decoded, Payload(name: "ok", note: "value"))
    }

    func testSkipsNonMatchingBraceObjectBeforeValidJSON() {
        let raw = #"调试信息 {not json} {"name":"ok","note":"brace } inside string"} trailing"#

        let decoded = AIJSONExtractor.decodeFirstObject(from: raw, as: Payload.self)

        XCTAssertEqual(decoded, Payload(name: "ok", note: "brace } inside string"))
    }

    func testDecodesFencedJSON() {
        let raw = """
        ```json
        {"name":"ok","note":"fenced"}
        ```
        """

        let decoded = AIJSONExtractor.decodeFirstObject(from: raw, as: Payload.self)

        XCTAssertEqual(decoded, Payload(name: "ok", note: "fenced"))
    }

    func testDecodesArrayWithTrailingProse() {
        let raw = #"prefix [{"index":1,"value":"a]b"},{"index":2,"value":"c"}] trailing"#

        let decoded = AIJSONExtractor.decodeFirstArray(from: raw, as: Item.self)

        XCTAssertEqual(decoded, [Item(index: 1, value: "a]b"), Item(index: 2, value: "c")])
    }

    func testStripsThinkingBeforeDecoding() {
        let raw = #"<think>{"draft": true}</think> {"name":"ok","note":"visible"}"#

        let decoded = AIJSONExtractor.decodeFirstObject(from: raw, as: Payload.self)

        XCTAssertEqual(decoded, Payload(name: "ok", note: "visible"))
    }
}
