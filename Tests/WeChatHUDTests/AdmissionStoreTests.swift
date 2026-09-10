import XCTest
@testable import WeChatHUD

/// Persistence for the admission rules.
///
/// These matter more than usual: a rule the user set is invisible until the
/// next scan, so a silent write failure would look like the setting was simply
/// ignored. The migration test guards upgrades — an existing install already
/// has an `ignored_senders` table without a scope column.
final class AdmissionStoreTests: XCTestCase {
    var store: HUDStore!
    var tmpPath: String!

    override func setUp() {
        tmpPath = NSTemporaryDirectory() + "hud_admission_\(UUID().uuidString).sqlite3"
        store = HUDStore(dbPath: tmpPath)
        try! store.open()
    }

    override func tearDown() {
        store.close()
        try? FileManager.default.removeItem(atPath: tmpPath)
    }

    func testAdmissionConfigRoundTripsThroughStore() throws {
        try store.saveAdmissionConfig(AdmissionConfig(mode: .all, atMutedGroups: ["g@chatroom"]))

        let loaded = store.loadAdmissionConfig()
        XCTAssertEqual(loaded.mode, .all)
        XCTAssertEqual(loaded.atMutedGroups, ["g@chatroom"])
    }

    func testMissingAdmissionConfigFallsBackToTheNarrowDefault() {
        XCTAssertEqual(store.loadAdmissionConfig().mode, .whitelistOnly)
    }

    /// A rule created inside one conversation keeps its narrow meaning, and must
    /// not leak into the global mute set.
    func testPerChatIgnoreStaysScopedToThatChat() throws {
        try store.ignoreSender(
            chatUsername: "team@chatroom",
            chatName: "小组",
            senderUsername: "noisy",
            senderName: "吵的人"
        )

        let rules = store.loadIgnoredSenders()
        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(rules.first?.scope, .chat)
        XCTAssertTrue(store.loadGlobalIgnoredSenders().isEmpty)
        XCTAssertEqual(store.loadIgnoredSenderMap()["team@chatroom"]?.count, 1)
    }

    func testGlobalIgnoreFollowsThePersonAcrossChats() throws {
        try store.ignoreSenderEverywhere(senderUsername: "loud", senderName: "很吵")

        XCTAssertEqual(store.loadGlobalIgnoredSenders().count, 1)
        XCTAssertTrue(store.loadIgnoredSenders().first?.scope == .global)
        // Chat-scoped lookups stay empty; the global set is what carries it.
        XCTAssertTrue(store.loadIgnoredSenderMap().isEmpty)

        let rules = AdmissionRules.load(store: store)
        XCTAssertTrue(
            rules.isMuted(chatUsername: "any@chatroom", senderUsername: "loud", senderName: "很吵"),
            "a global mute has to apply in a conversation it was never created in"
        )
    }

    func testGlobalAndScopedRulesCoexistForTheSamePerson() throws {
        try store.ignoreSender(
            chatUsername: "team@chatroom",
            chatName: "小组",
            senderUsername: "loud",
            senderName: "很吵"
        )
        try store.ignoreSenderEverywhere(senderUsername: "loud", senderName: "很吵")

        XCTAssertEqual(store.loadIgnoredSenders().count, 2)
        XCTAssertEqual(store.loadGlobalIgnoredSenders().count, 1)
        XCTAssertEqual(store.loadIgnoredSenderMap()["team@chatroom"]?.count, 1)
    }

    func testRemovingAGlobalIgnoreStopsMuting() throws {
        try store.ignoreSenderEverywhere(senderUsername: "loud", senderName: "很吵")
        try store.unignoreSender(
            chatUsername: HUDStore.globalIgnoreScopeKey,
            senderUsername: "loud",
            senderName: "很吵"
        )

        XCTAssertTrue(store.loadGlobalIgnoredSenders().isEmpty)
        XCTAssertFalse(
            AdmissionRules.load(store: store)
                .isMuted(chatUsername: "any", senderUsername: "loud", senderName: "很吵")
        )
    }

    // MARK: - Group members

    func testGroupMemberRulesRoundTrip() throws {
        try store.addGroupMemberRule(
            chatUsername: "team@chatroom",
            chatName: "小组",
            senderUsername: "boss",
            senderName: "老板"
        )

        let rules = store.loadGroupMemberRules()
        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(rules.first?.senderName, "老板")
        XCTAssertEqual(store.loadGroupMemberMap()["team@chatroom"], ["boss"])
    }

    /// Adding the same person twice must not create a duplicate row that the
    /// settings list would then show twice.
    func testAddingTheSameMemberTwiceIsIdempotent() throws {
        for _ in 0..<2 {
            try store.addGroupMemberRule(
                chatUsername: "team@chatroom",
                chatName: "小组",
                senderUsername: "boss",
                senderName: "老板"
            )
        }

        XCTAssertEqual(store.loadGroupMemberRules().count, 1)
    }

    func testRemovingAGroupMemberRule() throws {
        try store.addGroupMemberRule(
            chatUsername: "team@chatroom",
            chatName: "小组",
            senderUsername: "boss",
            senderName: "老板"
        )
        try store.removeGroupMemberRule(chatUsername: "team@chatroom", senderUsername: "boss")

        XCTAssertTrue(store.loadGroupMemberRules().isEmpty)
    }

    /// The watched member must be recognised as such through the rules snapshot,
    /// which is what the scan actually consults.
    func testRulesSnapshotResolvesWatchedMemberAndVIP() throws {
        try store.addToWhitelist(
            username: "team@chatroom", displayName: "小组",
            isGroup: true, category: .work
        )
        try store.addToWhitelist(
            username: "chief", displayName: "主管",
            isGroup: false, category: .work, attentionLevel: .vip
        )
        try store.addGroupMemberRule(
            chatUsername: "team@chatroom", chatName: "小组",
            senderUsername: "boss", senderName: "老板"
        )

        let rules = AdmissionRules.load(store: store)
        XCTAssertTrue(rules.followedChats.contains("team@chatroom"))
        XCTAssertTrue(rules.vipPeople.contains("chief"))

        // The reason must be specific, not merely "followed".
        XCTAssertEqual(
            rules.decide(
                chatUsername: "team@chatroom", isGroup: true,
                senderUsername: "boss", senderName: "老板", isAtMention: false
            ),
            .admit(.watchedMember)
        )
        // A VIP person is admitted even in a group they merely appear in.
        XCTAssertEqual(
            rules.decide(
                chatUsername: "other@chatroom", isGroup: true,
                senderUsername: "chief", senderName: "主管", isAtMention: false
            ),
            .admit(.vip)
        )
    }
}
