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

    /// The fence stripper used to delete everything outside the first fence, so
    /// JSON that followed prose or a non-JSON fence was lost entirely.
    func testDecodesJSONThatFollowsANonJSONFence() {
        let raw = """
        Here is my reasoning:
        ```
        step one: ignore the braces { in this paragraph
        ```
        and the answer:
        {"name":"ok","note":"after fence"}
        """

        let decoded = AIJSONExtractor.decodeFirstObject(from: raw, as: Payload.self)

        XCTAssertEqual(decoded, Payload(name: "ok", note: "after fence"))
    }

    func testDecodesJSONInsideTheSecondFence() {
        let raw = """
        ```
        prose only
        ```
        ```json
        {"name":"ok","note":"second fence"}
        ```
        """

        let decoded = AIJSONExtractor.decodeFirstObject(from: raw, as: Payload.self)

        XCTAssertEqual(decoded, Payload(name: "ok", note: "second fence"))
    }

    /// A long run of unclosed braces used to walk to the end of the text once
    /// per brace (quadratic). The scan budget must keep this bounded and still
    /// return nothing rather than hanging.
    func testUnbalancedBraceFloodStaysBounded() {
        let raw = String(repeating: "{", count: 200_000) + "{\"name\":\"ok\",\"note\":\"late\"}"

        let started = Date()
        _ = AIJSONExtractor.decodeFirstObject(from: raw, as: Payload.self)

        XCTAssertLessThan(Date().timeIntervalSince(started), 20, "the scan must not be quadratic")
    }

    func testOversizedResponseIsTruncatedToTheScanLimit() {
        let filler = String(repeating: "x", count: AIJSONExtractor.maxScanLength + 1_000)
        let raw = filler + #"{"name":"ok","note":"too late"}"#

        XCTAssertNil(
            AIJSONExtractor.decodeFirstObject(from: raw, as: Payload.self),
            "content past the scan limit is a runaway response, not a payload"
        )
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
