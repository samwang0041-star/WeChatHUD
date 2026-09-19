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

    /// The four regexes only ever matched a *contiguous ASCII* digit run, which
    /// is not how a number is typed into chat: grouped in 4s, full-width from
    /// the 全角 keyboard, prefixed with the country code, or carrying the
    /// zero-width characters that survive a copy-paste from another app. Each
    /// of those walked out of the machine unmasked — and `sanitizeForAI` calls
    /// the same function, so there was no second net either.
    func testGroupedFullwidthAndPrefixedNumbersNeverLeave() async throws {
        let shapes: [(raw: String, label: String)] = [
            ("138 0013 8000", "[手机]"),
            ("１３８００１３８０００", "[手机]"),
            ("+8613800138000", "[手机]"),
            ("86 138 0013 8000", "[手机]"),
            ("6222 0202 1234 5678", "[卡号]"),
            ("11010119900307457X", "[证件]"),
            ("someone@example.com", "[邮箱]")
        ]
        let raw = shapes.map { $0.raw }.joined(separator: "\n")
        _ = try? await service().complete(system: "sys", user: raw, options: .default)
        let body = try XCTUnwrap(sentBody())
        for shape in shapes {
            XCTAssertTrue(body.contains(shape.label), "\(shape.raw) was not masked, got \(body)")
        }
        for shape in shapes {
            XCTAssertFalse(body.contains(shape.raw), "\(shape.raw) left the machine unmasked")
        }
    }

    /// The same table at the function that decides it, so a failure names the
    /// shape rather than the transport.
    func testMaskCoversEveryGroupedAndEvadedShape() {
        let cases: [(raw: String, label: String)] = [
            ("138 0013 8000", "[手机]"),
            ("138-0013-8000", "[手机]"),
            ("１３８００１３８０００", "[手机]"),
            ("+8613800138000", "[手机]"),
            ("86 138 0013 8000", "[手机]"),
            ("1380\u{200B}0138000", "[手机]"),
            ("6222 0202 1234 5678", "[卡号]"),
            ("6222\u{3000}0202\u{3000}1234\u{3000}5678", "[卡号]"),
            ("someone\u{FEFF}@example.com", "[邮箱]"),
            ("11010119900307457X", "[证件]"),
            ("我的号 13800138000 单号 8899123456789012", "[手机]")
        ]
        for shape in cases {
            let masked = AIService.maskDirectIdentifiers(shape.raw)
            XCTAssertTrue(masked.contains(shape.label), "\(shape.raw) → \(masked)")
            let digits = String(shape.raw.unicodeScalars.filter { ("0"..."9").contains(Character($0)) })
            XCTAssertFalse(
                digits.count >= 11 && masked.contains(digits),
                "\(shape.raw) survived as \(masked)"
            )
        }
    }

    /// Grouping is what tells a phone number from a date range, so the shapes
    /// the user is actually asking about must still arrive intact: an amount
    /// with a thousands separator, a 13-digit millisecond timestamp, a dashed
    /// date range (16 digits), a short order number.
    func testGroupingRuleLeavesAmountsDatesAndTimestampsIntact() {
        let survivors = [
            "转账 3200 元",
            "总价 1,380,013,800 元",
            "报价 1.3800138000",
            "会议 2026-09-19 2026-09-20",
            "时间戳 1695000000000",
            "订单 88991234，验证码 741258",
            "编号 123456789012"
        ]
        for text in survivors {
            XCTAssertEqual(AIService.maskDirectIdentifiers(text), text, "\(text) was eaten")
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
