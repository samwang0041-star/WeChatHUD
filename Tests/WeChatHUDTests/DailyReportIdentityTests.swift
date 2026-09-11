import XCTest
import CryptoKit
@testable import WeChatHUD

/// Report row ids must be stable across launches.
///
/// Swift seeds `String.hashValue` per process, so ids derived from it changed on
/// every restart: a user's "忽略风险" was keyed by such an id, stopped matching
/// after a relaunch, and each restart left another orphan row behind in
/// `daily_report_state`.
final class DailyReportIdentityTests: XCTestCase {
    private func expectedDigest(_ value: String) -> String {
        String(
            SHA256.hash(data: Data(value.utf8))
                .map { String(format: "%02x", $0) }
                .joined()
                .prefix(16)
        )
    }

    func testRiskIdentifierIsStableAndContentDerived() {
        let description = "承诺「发报告」已到期"
        let risk = DailyReportRisk(type: .overdueCommitment, description: description, severity: .high)

        XCTAssertEqual(risk.id, "overdueCommitment-\(expectedDigest(description))")
        // A relaunch produces an equal id for equal content.
        XCTAssertEqual(
            risk.id,
            DailyReportRisk(type: .overdueCommitment, description: description, severity: .high).id
        )
        XCTAssertNotEqual(
            risk.id,
            DailyReportRisk(type: .overdueCommitment, description: "别的事", severity: .high).id
        )
        XCTAssertNotEqual(
            risk.id,
            DailyReportRisk(type: .overdueTodo, description: description, severity: .high).id
        )
    }

    func testHighlightIdentifierIsStableAndContentDerived() {
        let summary = "林总要求周五前给出报价"
        let highlight = DailyReportHighlight(
            summary: summary,
            category: .decision,
            sourceChatName: "客户群",
            sourceChatUsername: "room@chatroom",
            date: Date(timeIntervalSince1970: 1_000),
            confidence: 0.9
        )

        XCTAssertEqual(highlight.id, "room@chatroom-\(expectedDigest(summary))")
        XCTAssertEqual(
            highlight.id,
            DailyReportHighlight(
                summary: summary,
                category: .decision,
                sourceChatName: "客户群",
                sourceChatUsername: "room@chatroom",
                date: Date(timeIntervalSince1970: 9_999),
                confidence: 0.1
            ).id,
            "the id must not depend on volatile fields"
        )
    }

    func testExplicitIdentifierStillWins() {
        let risk = DailyReportRisk(id: "custom-id", type: .recalledMessage, description: "撤回", severity: .medium)
        XCTAssertEqual(risk.id, "custom-id")
    }
}
