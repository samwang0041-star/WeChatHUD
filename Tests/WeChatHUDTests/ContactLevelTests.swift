import XCTest
@testable import WeChatHUD

final class ContactLevelTests: XCTestCase {

    func testAttentionLevelOrdering() {
        let levels: [AttentionLevel] = [.stranger, .greylist, .whitelist, .vip]
        XCTAssertEqual(levels.sorted(by: { $0.rank < $1.rank }),
                       [.vip, .whitelist, .greylist, .stranger])
    }

    func testContactRoleDefaultReplyWindow() {
        XCTAssertEqual(ContactRole.boss.defaultReplyWindowMinutes, 30)
        XCTAssertEqual(ContactRole.keyClient.defaultReplyWindowMinutes, 60)
        XCTAssertEqual(ContactRole.colleague.defaultReplyWindowMinutes, 240)
        XCTAssertEqual(ContactRole.family.defaultReplyWindowMinutes, 120)
        XCTAssertEqual(ContactRole.supplier.defaultReplyWindowMinutes, 480)
        XCTAssertEqual(ContactRole.acquaintance.defaultReplyWindowMinutes, 0)
    }

    func testContactRoleNotifyLevel() {
        XCTAssertEqual(ContactRole.boss.defaultNotifyLevel, .strong)
        XCTAssertEqual(ContactRole.colleague.defaultNotifyLevel, .standard)
        XCTAssertEqual(ContactRole.acquaintance.defaultNotifyLevel, .light)
    }

    func testContactRoleReplyTone() {
        XCTAssertEqual(ContactRole.boss.defaultReplyTone, .reporting)
        XCTAssertEqual(ContactRole.keyClient.defaultReplyTone, .professional)
        XCTAssertEqual(ContactRole.friend.defaultReplyTone, .casual)
    }

    func testContactRoleRoleDescription() {
        XCTAssertFalse(ContactRole.boss.roleDescription.isEmpty)
        for role in ContactRole.allCases {
            XCTAssertFalse(role.roleDescription.isEmpty, "\(role) missing description")
        }
    }

    func testContactRoleVIPTrackDimensions() {
        XCTAssertTrue(ContactRole.boss.vipTrackDimensions.contains("decisions"))
        XCTAssertTrue(ContactRole.keyClient.vipTrackDimensions.contains("complaints"))
        XCTAssertTrue(ContactRole.family.vipTrackDimensions.contains("health"))
    }
}
