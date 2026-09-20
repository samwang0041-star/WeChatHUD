import XCTest
import SQLite3
@testable import WeChatHUD

/// §237: the three admission rule tables were read through `queryAll`, which collapses
/// a prepare/step error into `[]`. Downstream, `[]` means 「没人被静音」 (so a muted
/// person's message gets admitted, bannered and auto-replied) and 「没有关注任何群成员」
/// (so the classification worker *retires* — deletes — rows it was only unable to
/// classify, and the scan advances its watermark past them).
final class AdmissionRuleReadHonestyTests: XCTestCase {
    private var store: HUDStore!
    private var dbPath: String!

    override func setUpWithError() throws {
        dbPath = NSTemporaryDirectory() + "admission-rules-\(UUID()).sqlite3"
        store = HUDStore(dbPath: dbPath)
        try store.open()
        try store.addToWhitelist(username: "peer", displayName: "同事", isGroup: false,
                                 category: .work, attentionLevel: .watch)
    }

    override func tearDown() {
        store.close()
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: dbPath + suffix) }
        super.tearDown()
    }

    /// Positive control first: an empty-but-readable table really is 「没有规则」.
    func testReadableButEmptyTablesAreNotMarkedUnreadable() {
        let rules = AdmissionRules.load(store: store)
        XCTAssertFalse(rules.rulesUnreadable, "表是空的 ≠ 读不到；否则这条旗子会永久压住水位")
        XCTAssertFalse(rules.scopeUnreadable)
    }

    func testEachRuleTableReadFailureIsRecorded() throws {
        try store.exec("ALTER TABLE group_member_rules RENAME TO group_member_rules_hidden")
        let broken = AdmissionRules.load(store: store)
        XCTAssertTrue(broken.rulesUnreadable, "群成员关注表读不到时必须举旗")
        XCTAssertTrue(broken.scopeUnreadable)
        try store.exec("ALTER TABLE group_member_rules_hidden RENAME TO group_member_rules")

        try store.exec("ALTER TABLE ignored_senders RENAME TO ignored_senders_hidden")
        XCTAssertTrue(AdmissionRules.load(store: store).rulesUnreadable,
                      "静音规则表读不到时也必须举旗：空集会被当成「没人被静音」")
    }

    /// The mute itself, and the contract the destructive consumers rely on.
    func testMutedSenderIsSuppressedAndAFailedReadRefusesToRetire() throws {
        try store.ignoreSenderEverywhere(senderUsername: "wxid_boss", senderName: "老板")
        let readable = AdmissionRules.load(store: store)
        let verdict = readable.decide(chatUsername: "peer", isGroup: false,
                                      senderUsername: "wxid_boss", senderName: "老板",
                                      isAtMention: false)
        XCTAssertFalse(verdict.isAdmitted, "全局静音的人不该被放行")

        try store.exec("ALTER TABLE ignored_senders RENAME TO ignored_senders_hidden")
        let blind = AdmissionRules.load(store: store)
        XCTAssertTrue(blind.scopeUnreadable)
        XCTAssertEqual(
            ChatMonitor.dispositionForUnadmitted(followingUnreadable: blind.scopeUnreadable),
            .retry,
            "规则读不到时，未放行的那条既不是「不用管」，更不该被当作已处理删掉")
    }
}

/// The watermark half, end to end: a round whose rules could not be read may not
/// consume the messages it failed to judge.
final class AdmissionRuleWatermarkTests: XCTestCase {
    private let chat = "rules_peer"

    private func scan(_ reader: WeChatReader, store: HUDStore) async -> ScanEngine.ScanOutcome? {
        await ScanEngine.performScan(
            reader: reader,
            store: store,
            aiService: AIService(config: AIConfig()),
            changedRelPaths: nil,
            thresholds: UnreadThresholds(),
            replyDebtConfig: ReplyDebtConfig(),
            currentRecent: [],
            recentLimit: 10,
            autopilotActive: false
        )
    }

    func testUnreadableRulesDoNotAdvanceTheWhitelistWatermark() async throws {
        let fixture = try SyntheticShardedScanFixture(
            chatUsername: chat,
            shards: [0: [
                .init(localId: 1, createTime: 1_001, senderId: 1, text: "在吗"),
                .init(localId: 2, createTime: 1_002, senderId: 1, text: "结论呢")
            ]],
            unreadCount: 2)
        let store = try fixture.makeStore()
        defer { fixture.cleanup(); store.close() }
        try store.addToWhitelist(username: chat, displayName: "同事", isGroup: false,
                                 category: .work, attentionLevel: .watch)

        try store.exec("ALTER TABLE ignored_senders RENAME TO ignored_senders_hidden")
        _ = await scan(fixture.reader, store: store)

        try store.exec("ALTER TABLE ignored_senders_hidden RENAME TO ignored_senders")
        let healedOptional = await scan(fixture.reader, store: store)
        let healed = try XCTUnwrap(healedOptional)
        XCTAssertEqual(healed.newInboundForClassifier.filter { $0.chatUsername == chat }.count, 2,
                       "规则读不到那一轮之后，这两条还得送去分类 —— 水位被推过去就是永不再来")
    }
}
