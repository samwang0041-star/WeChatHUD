import XCTest
@testable import WeChatHUD

final class ContactIdentityIndexTests: XCTestCase {
    func testNicknameAndRemarkResolveToSameCanonicalContact() {
        let index = ContactIdentityIndex.build(records: [
            .init(username: "wxid_ponge", nickName: "ponge", remark: "S 琪婷婷")
        ])

        XCTAssertEqual(index.canonicalUsername(for: "ponge"), "wxid_ponge")
        XCTAssertEqual(index.canonicalUsername(for: "S琪婷婷"), "wxid_ponge")
        XCTAssertEqual(index.canonicalUsername(for: "S 琪婷婷"), "wxid_ponge")
        XCTAssertEqual(index.displayName(for: "ponge"), "S 琪婷婷")
        XCTAssertEqual(index.displayName(for: "wxid_ponge"), "S 琪婷婷")
        XCTAssertEqual(index.normalizeMentions(in: "@ponge 你看下"), "@S 琪婷婷 你看下")
    }

    func testAmbiguousNicknameDoesNotResolveAcrossContacts() {
        let index = ContactIdentityIndex.build(records: [
            .init(username: "wxid_a", nickName: "Alex", remark: "客户 Alex"),
            .init(username: "wxid_b", nickName: "Alex", remark: "同学 Alex")
        ])

        XCTAssertNil(index.canonicalUsername(for: "Alex"))
        XCTAssertEqual(index.displayName(for: "wxid_a"), "客户 Alex")
        XCTAssertEqual(index.displayName(for: "wxid_b"), "同学 Alex")
    }

    func testLegacyShortUsernameAliasResolvesToFullUsername() {
        let index = ContactIdentityIndex.build(records: [
            .init(username: "yuriwong_06a2", nickName: "哆啦", remark: "")
        ])

        XCTAssertEqual(index.canonicalUsername(for: "yuriwong"), "yuriwong_06a2")
        XCTAssertEqual(index.displayName(for: "yuriwong"), "哆啦")
    }
}
