import XCTest
@testable import WeChatHUD

/// Unit tests for the pure helpers exposed on `ScanEngine` for the
/// cross-group VIP tracking feature. The full `performScan` pipeline
/// can't be unit-tested without a live encrypted WeChat DB + reader,
/// so the decision logic is factored into these small helpers.
final class ScanEngineTests: XCTestCase {

    // MARK: - Fixtures

    private func makeEntry(
        id: String,
        displayName: String = "Name",
        isGroup: Bool,
        level: WhitelistAttentionLevel
    ) -> WhitelistEntry {
        WhitelistEntry(
            id: id,
            displayName: displayName,
            isGroup: isGroup,
            category: .work,
            attentionLevel: level,
            addedAt: Date(),
            autoSuggested: false
        )
    }

    // MARK: - deriveVIPPersonUsernames

    func testDeriveVIPPersonUsernamesCollectsPrivateVIPOnly() {
        let whitelist: [WhitelistEntry] = [
            makeEntry(id: "wxid_boss", isGroup: false, level: .vip),
            makeEntry(id: "wxid_friend", isGroup: false, level: .watch),
            makeEntry(id: "12345@chatroom", isGroup: true, level: .vip),
            makeEntry(id: "67890@chatroom", isGroup: true, level: .watch),
        ]
        let persons = ScanEngine.deriveVIPPersonUsernames(whitelist: whitelist)
        XCTAssertEqual(persons, ["wxid_boss"])
    }

    func testDeriveVIPPersonUsernamesEmpty() {
        let persons = ScanEngine.deriveVIPPersonUsernames(whitelist: [])
        XCTAssertTrue(persons.isEmpty)
    }

    func testDeriveVIPPersonUsernamesMultiple() {
        let whitelist: [WhitelistEntry] = [
            makeEntry(id: "wxid_a", isGroup: false, level: .vip),
            makeEntry(id: "wxid_b", isGroup: false, level: .vip),
            makeEntry(id: "wxid_c", isGroup: false, level: .watch),
        ]
        let persons = ScanEngine.deriveVIPPersonUsernames(whitelist: whitelist)
        XCTAssertEqual(persons, ["wxid_a", "wxid_b"])
    }

    // MARK: - shouldAppendCrossGroupVIPTrace

    func testVIPPersonDetectedInWhitelistGroup() {
        // Whitelist contains: a watched group + a VIP private chat with "zhang".
        // A message from zhang inside the group → cross-group trace should fire.
        let whitelist: [WhitelistEntry] = [
            makeEntry(id: "wxid_zhang", isGroup: false, level: .vip),
            makeEntry(id: "room_a@chatroom", isGroup: true, level: .watch),
        ]
        let vipPersons = ScanEngine.deriveVIPPersonUsernames(whitelist: whitelist)

        XCTAssertTrue(
            ScanEngine.shouldAppendCrossGroupVIPTrace(
                entryID: "room_a@chatroom",
                entryLevel: .watch,
                senderUsername: "wxid_zhang",
                vipPersonUsernames: vipPersons
            ),
            "A VIP contact speaking in a whitelisted (non-VIP) group must trigger a cross-group trace."
        )
    }

    func testVIPPersonNotDoubleCountedWhenGroupIsAlsoVIP() {
        // Whitelist: a VIP group + a VIP private chat with zhang.
        // Message from zhang in the VIP group → cross-group path must NOT fire,
        // the existing entry.attentionLevel == .vip branch already appends one
        // trace; firing again would double-count.
        let whitelist: [WhitelistEntry] = [
            makeEntry(id: "wxid_zhang", isGroup: false, level: .vip),
            makeEntry(id: "room_vip@chatroom", isGroup: true, level: .vip),
        ]
        let vipPersons = ScanEngine.deriveVIPPersonUsernames(whitelist: whitelist)

        XCTAssertFalse(
            ScanEngine.shouldAppendCrossGroupVIPTrace(
                entryID: "room_vip@chatroom",
                entryLevel: .vip,
                senderUsername: "wxid_zhang",
                vipPersonUsernames: vipPersons
            ),
            "Group-is-VIP must not also fire the cross-group branch (would double-append)."
        )

        // Also: a non-VIP sender in the VIP group stays in the single-trace path.
        XCTAssertFalse(
            ScanEngine.shouldAppendCrossGroupVIPTrace(
                entryID: "room_vip@chatroom",
                entryLevel: .vip,
                senderUsername: "wxid_random",
                vipPersonUsernames: vipPersons
            )
        )
    }

    func testVIPPersonNotDetectedInNonWhitelistGroup() {
        // A message arrives from a VIP contact, but the chat is a private
        // thread (not a group). `shouldAppendCrossGroupVIPTrace` must
        // refuse — cross-group is a group-only signal. And if the group is
        // not in the whitelist at all, ScanEngine simply won't iterate it.
        let whitelist: [WhitelistEntry] = [
            makeEntry(id: "wxid_zhang", isGroup: false, level: .vip),
        ]
        let vipPersons = ScanEngine.deriveVIPPersonUsernames(whitelist: whitelist)

        // Private chat with the VIP: handled by the existing VIP branch, not
        // cross-group.
        XCTAssertFalse(
            ScanEngine.shouldAppendCrossGroupVIPTrace(
                entryID: "wxid_zhang",
                entryLevel: .vip,
                senderUsername: "wxid_zhang",
                vipPersonUsernames: vipPersons
            )
        )

        // Non-whitelisted group: even if someone happened to call this
        // helper with its id, the (unknown to the whitelist) group wouldn't
        // be iterated. Confirm the helper is still sound.
        XCTAssertFalse(
            ScanEngine.shouldAppendCrossGroupVIPTrace(
                entryID: "stranger_group@chatroom",
                entryLevel: .watch,
                senderUsername: "wxid_stranger",
                vipPersonUsernames: vipPersons
            ),
            "A sender that isn't in the VIP person set produces no cross-group trace."
        )
    }

    func testFirstScanFetchLimitCoversUnreadBacklog() {
        XCTAssertEqual(ScanEngine.firstScanFetchLimit(unreadCount: 0), 100)
        XCTAssertEqual(ScanEngine.firstScanFetchLimit(unreadCount: 40), 100)
        XCTAssertEqual(ScanEngine.firstScanFetchLimit(unreadCount: 150), 150)
        XCTAssertEqual(ScanEngine.firstScanFetchLimit(unreadCount: 800), 500)
        // A cursor does not make a backlog smaller: the page must still cover
        // the recorded unread count, or the watermark advances past messages
        // that were never classified.
        XCTAssertEqual(ScanEngine.whitelistFetchLimit(hasCursor: true, unreadCount: 150), 150)
        XCTAssertEqual(ScanEngine.whitelistFetchLimit(hasCursor: true, unreadCount: 0), 100)
        XCTAssertEqual(ScanEngine.whitelistFetchLimit(hasCursor: true, unreadCount: 900), 500)
        XCTAssertEqual(ScanEngine.whitelistFetchLimit(hasCursor: false, unreadCount: 150), 150)
        XCTAssertFalse(ScanEngine.shouldEnqueueAutopilotInbound(isFirstWhitelistScan: true))
        XCTAssertTrue(ScanEngine.shouldEnqueueAutopilotInbound(isFirstWhitelistScan: false))
        XCTAssertFalse(ScanEngine.shouldPersistFirstScanBaseline(sessionsAvailable: false))
        XCTAssertTrue(ScanEngine.shouldPersistFirstScanBaseline(sessionsAvailable: true))
    }
}
