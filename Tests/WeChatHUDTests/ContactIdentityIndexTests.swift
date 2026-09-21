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
            .init(username: "lilei_06a2", nickName: "李雷", remark: "")
        ])

       XCTAssertEqual(index.canonicalUsername(for: "lilei"), "lilei_06a2")
       XCTAssertEqual(index.displayName(for: "lilei"), "李雷")
   }

    func testVisibleNameDoesNotPrintWxidWhenStoreIsUnreadable() {
        XCTAssertEqual(
            ContactIdentityIndex.visibleName(
                username: "wxid_boss", stored: .value("老板")),
            "老板")
        XCTAssertEqual(
            ContactIdentityIndex.visibleName(
                username: "wxid_boss", stored: .unreadable),
            ContactIdentityIndex.unreadableNamePlaceholder)
        XCTAssertEqual(
            ContactIdentityIndex.visibleName(
                username: "wxid_boss", stored: .absent),
            ContactIdentityIndex.unnamedContactPlaceholder)
        XCTAssertEqual(
            ContactIdentityIndex.visibleName(
                username: "wxid_boss", stored: .absent, readerName: "wxid_boss"),
            ContactIdentityIndex.unnamedContactPlaceholder,
            "reader echoing the username is not a name")
        XCTAssertEqual(
            ContactIdentityIndex.visibleName(
                username: "zhangsan2024", stored: .absent),
            "zhangsan2024")
        XCTAssertEqual(
            ContactIdentityIndex.visibleName(
               username: "wxid_boss", stored: .absent, alias: "张总"),
           "张总")
   }

    func testAvatarMonogramDoesNotUseWxidOrPlaceholderLetters() {
        XCTAssertEqual(ContactIdentityIndex.avatarMonogram(from: "老板"), "老")
        XCTAssertNil(ContactIdentityIndex.avatarMonogram(from: "wxid_boss"))
        XCTAssertNil(ContactIdentityIndex.avatarMonogram(from: ContactIdentityIndex.unreadableNamePlaceholder))
        XCTAssertNil(ContactIdentityIndex.avatarMonogram(from: ContactIdentityIndex.unnamedContactPlaceholder))
        XCTAssertNil(ContactIdentityIndex.avatarMonogram(from: ContactIdentityIndex.unnamedGroupPlaceholder))
    }
}
