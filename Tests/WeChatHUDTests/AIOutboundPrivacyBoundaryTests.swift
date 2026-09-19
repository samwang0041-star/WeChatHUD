import XCTest
@testable import WeChatHUD

/// The outbound privacy boundary. `sanitizeForAI` is the per-service ingress
/// step, but an audit found seven live prompts that embedded raw chat text
/// without it — a phone number typed into a chat therefore reached the
/// configured AI endpoint unmasked. `AIService.completeWithMetadata` now masks
/// the rendered prompt itself, so the egress holds regardless of what a
/// service forgot.
final class AIOutboundPrivacyBoundaryTests: XCTestCase {

    override func setUp() {
        super.setUp()
        URLRequestRecorder.install()
    }

    override func tearDown() {
        URLRequestRecorder.uninstall()
        super.tearDown()
    }

    private func service() -> AIService {
        var cfg = AIConfig()
        cfg.provider = AIProviderSlot(
            providerID: "custom",
            baseURL: "http://localhost:9999",
            model: "test-model",
            apiKey: "sk-test"
        )
        return AIService(config: cfg)
    }

    /// Whatever the service layer passes in, the bytes that leave the machine
    /// must not contain a direct identifier.
    func testRenderedPromptNeverCarriesDirectIdentifiers() async throws {
        let raw = """
        收 13812345678 联系我
        卡号 6222021234567890123
        证件 110101199003074578
        邮箱 someone@example.com
        """

        _ = try? await service().complete(system: "sys", user: raw, options: .default)

        let body = try XCTUnwrap(sentBody())
        XCTAssertTrue(body.contains("[手机]"), "phone should be masked, got \(body)")
        XCTAssertTrue(body.contains("[卡号]"))
        XCTAssertTrue(body.contains("[证件]"))
        XCTAssertTrue(body.contains("[邮箱]"))
        for leak in ["13812345678", "6222021234567890123", "110101199003074578", "someone@example.com"] {
            XCTAssertFalse(body.contains(leak), "raw identifier \(leak) left the machine")
        }
    }

    /// The boundary must not eat the numbers the user actually asked about:
    /// money amounts, order numbers and verification codes stay intact.
    func testBoundaryDoesNotMaskTheNumbersUnderDiscussion() async throws {
        let raw = "转账 3200 元，订单 88991234，验证码 741258"
        _ = try? await service().complete(system: "sys", user: raw, options: .default)

        let body = try XCTUnwrap(sentBody())
        XCTAssertTrue(body.contains("3200"), "money must survive the boundary")
        XCTAssertTrue(body.contains("88991234"))
        XCTAssertTrue(body.contains("741258"))
    }

    /// The session ledger quotes the peer verbatim; it is rendered by a static
    /// helper, so mask it there rather than at each caller.
    func testSessionLedgerQuoteIsMasked() {
        let entry = LedgerEntry(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            outgoingText: "好的",
            peerLastMessage: "我的号 13812345678，你加一下",
            topic: nil
        )
        let text = AutoReplyGenerator.formatLedger([entry])
        XCTAssertTrue(text.contains("[手机]"), text)
        XCTAssertFalse(text.contains("13812345678"), text)
    }

    /// A peer quote that sanitizes down to nothing must not leave an empty
    /// 「对方: ""」 attribution in the ledger.
    func testEmptyLedgerQuoteDropsTheAttribution() {
        let entry = LedgerEntry(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            outgoingText: "好的",
            peerLastMessage: "[表情]",
            topic: nil
        )
        let text = AutoReplyGenerator.formatLedger([entry])
        XCTAssertFalse(text.contains("对方"), text)
        XCTAssertTrue(text.hasSuffix("→ 你回:「好的」"), text)
    }

    // MARK: - Helpers

    private func sentBody() -> String? {
        guard let req = URLRequestRecorder.capturedRequests.first else { return nil }
        if let data = req.httpBody { return String(data: data, encoding: .utf8) }
        guard let stream = req.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var buf = Data()
        var tmp = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&tmp, maxLength: 4096)
            if n <= 0 { break }
            buf.append(tmp, count: n)
        }
        return String(data: buf, encoding: .utf8)
    }
}
