import XCTest
@testable import WeChatHUD

final class CompanionClipboardTests: XCTestCase {
    func testSanitizedURLPasteExtractsAddressAndStripsQuotes() {
        XCTAssertEqual(
            CompanionClipboard.sanitizedPaste("  \"https://api.deepseek.com/v1\" \n", kind: .url),
            "https://api.deepseek.com/v1"
        )
        XCTAssertEqual(
            CompanionClipboard.sanitizedPaste("接口地址：https://api.kimi.com/coding/v1 备用", kind: .url),
            "https://api.kimi.com/coding/v1"
        )
    }

    func testSanitizedSecretPasteStripsBearerAndLabel() {
        XCTAssertEqual(
            CompanionClipboard.sanitizedPaste("Bearer sk-test-key-123456", kind: .secret),
            "sk-test-key-123456"
        )
        XCTAssertEqual(
            CompanionClipboard.sanitizedPaste("API Key: sk-live-abcdefg", kind: .secret),
            "sk-live-abcdefg"
        )
    }

    func testSanitizedSecretPastePrefersKeyOnSecondLine() {
        XCTAssertEqual(
            CompanionClipboard.sanitizedPaste("API Key\nsk-proj-real-secret-value", kind: .secret),
            "sk-proj-real-secret-value"
        )
        XCTAssertEqual(
            CompanionClipboard.sanitizedPaste("Password\ngh p_not_this\nghp_githubtokenvalue1", kind: .secret),
            "ghp_githubtokenvalue1"
        )
    }

    func testSecureFieldMenuOmitsCopyAndCut() {
        let items = CompanionClipboard.menuItems(
            fieldText: "sk-secret",
            clipboard: "sk-other",
            writable: true,
            secure: true
        )
        XCTAssertEqual(items.map(\.action), [.paste])
    }

    func testSanitizedModelPasteTakesFirstLine() {
        XCTAssertEqual(
            CompanionClipboard.sanitizedPaste("kimi-for-coding\nolder-model", kind: .model),
            "kimi-for-coding"
        )
    }

    func testMenuShowsPasteFirstWhenWritableAndClipboardHasText() {
        let items = CompanionClipboard.menuItems(
            fieldText: "https://old.example",
            clipboard: "https://new.example",
            writable: true
        )
        XCTAssertEqual(items.map(\.action), [.paste, .copy, .cut])
        XCTAssertTrue(items.allSatisfy(\.enabled))
    }

    func testReadOnlyMenuIsCopyOnly() {
        let items = CompanionClipboard.menuItems(
            fieldText: "https://api.deepseek.com",
            clipboard: "ignored",
            writable: false
        )
        XCTAssertEqual(items.map(\.action), [.copy])
        XCTAssertTrue(items[0].enabled)
    }

    func testEmptyFieldDisablesCopyAndEmptyClipboardDisablesPaste() {
        let items = CompanionClipboard.menuItems(fieldText: "", clipboard: "  ", writable: true)
        XCTAssertEqual(items.first(where: { $0.action == .paste })?.enabled, false)
        XCTAssertEqual(items.first(where: { $0.action == .copy })?.enabled, false)
        XCTAssertEqual(items.first(where: { $0.action == .cut })?.enabled, false)
    }

    func testApplyPasteReplacesFieldWithSanitizedClipboard() {
        let next = CompanionClipboard.apply(
            .paste,
            fieldText: "old",
            clipboard: "Bearer sk-pasted-key-999",
            kind: .secret
        )
        XCTAssertEqual(next, "sk-pasted-key-999")
        XCTAssertEqual(CompanionClipboard.apply(.cut, fieldText: "old", clipboard: nil, kind: .plain), "")
    }
}
