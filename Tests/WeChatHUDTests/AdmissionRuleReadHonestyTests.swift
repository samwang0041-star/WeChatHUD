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

    /// §241: the admission config is a fourth input to the same snapshot, and its
    /// defaults un-mute every 「@ 提醒静默」 group and can widen the mode.
    func testUnreadableAdmissionConfigIsFlaggedToo() throws {
        XCTAssertFalse(AdmissionRules.load(store: store).rulesUnreadable,
                       "正对照：没设过准入配置 ≠ 读不到，否则水位会被永久压住")
        try store.saveAdmissionConfig(AdmissionConfig(mode: .all, atMutedGroups: ["g@chatroom"]))
        XCTAssertFalse(AdmissionRules.load(store: store).rulesUnreadable)
        XCTAssertTrue(AdmissionRules.load(store: store).config.atMutedGroups.contains("g@chatroom"))

        try store.exec("ALTER TABLE settings RENAME TO settings_hidden")
        XCTAssertTrue(AdmissionRules.load(store: store).rulesUnreadable,
                      "准入设置读不到时，默认值会顺手把用户设的 @ 静默与模式解掉")
        try store.exec("ALTER TABLE settings_hidden RENAME TO settings")
        XCTAssertFalse(AdmissionRules.load(store: store).rulesUnreadable,
                       "读恢复之后旗标要落下，不能一次失败永久钉住")
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

    /// The outward half of the same widening: the mute sets arrive empty when the
    /// tables cannot be read, so a person the user switched off starts popping
    /// banners again for the duration of the failure.
    func testUnreadableRulesSilenceTheBannerInsteadOfHonoringNothing() {
        let admitted = AdmissionPolicy.decide(AdmissionPolicy.Context(
            mode: .whitelistOnly, isGroup: false, chatIsFollowed: true, chatIsVIP: false,
            senderIsVIP: false, senderIsWatchedMember: false, senderIsMuted: false,
            isAtMention: false))
        XCTAssertTrue(admitted.isAdmitted)
        XCTAssertTrue(
            AdmissionPolicy.shouldRaiseBanner(
                decision: admitted, chatUsername: "peer", isAtMention: false,
                atMutedGroups: [], rulesUnreadable: false),
            "正对照：规则读得到的时候不许把横幅压掉")
        XCTAssertFalse(
            AdmissionPolicy.shouldRaiseBanner(
                decision: admitted, chatUsername: "peer", isAtMention: false,
                atMutedGroups: [], rulesUnreadable: true),
            "读不到静音名单时，「不要打扰我」是唯一还能守得住的那半")
    }
}

/// The other end of the same setting: 提醒方式 writes the whole ``AdmissionConfig``
/// back, so a read that came up empty has to stop the write instead of offering a
/// defaulted form.
final class AdmissionConfigWriteGateTests: XCTestCase {
    private var store: HUDStore!
    private var dbPath: String!

    override func setUpWithError() throws {
        dbPath = NSTemporaryDirectory() + "admission-write-\(UUID()).sqlite3"
        store = HUDStore(dbPath: dbPath)
        try store.open()
    }

    override func tearDown() {
        store.close()
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: dbPath + suffix) }
        super.tearDown()
    }

    func testOnlyAReadableOrAbsentConfigMayBeWrittenOver() throws {
        // Nothing stored yet ≠ 读不到：这一页还得能存下第一次。
        let fresh = AdmissionSettingsView.LoadDecision(.absent)
        XCTAssertTrue(fresh.acceptsEdits)
        XCTAssertEqual(fresh, .hydrate(AdmissionConfig()))

        try store.saveAdmissionConfig(AdmissionConfig(mode: .all, atMutedGroups: ["g@chatroom"]))
        XCTAssertEqual(AdmissionSettingsView.LoadDecision(store.admissionConfigRead()),
                       .hydrate(AdmissionConfig(mode: .all, atMutedGroups: ["g@chatroom"])))

        try store.exec("ALTER TABLE settings RENAME TO settings_hidden")
        let blind = AdmissionSettingsView.LoadDecision(store.admissionConfigRead())
        XCTAssertFalse(blind.acceptsEdits,
                       "读不到还让用户编辑：下一次点击把默认值整份盖上去")
        if case .frozen(let notice, let overwrite) = blind {
            XCTAssertFalse(notice.isEmpty, "冻住这一页的时候得有话可说")
            XCTAssertFalse(overwrite, "读不到是可以重读的，不该递上「覆盖成默认值」那颗 destructive 按钮")
        } else {
            XCTFail("读失败必须落进 frozen 分支，不能当「没设过」")
        }
        try store.exec("ALTER TABLE settings_hidden RENAME TO settings")

        try store.setSetting("admission", value: "{oops")
        let garbled = AdmissionSettingsView.LoadDecision(store.admissionConfigRead())
        XCTAssertFalse(garbled.acceptsEdits, "读不懂的存量同样不许被静默覆盖")
        if case .frozen(_, let overwrite) = garbled {
            XCTAssertTrue(overwrite, "读不懂的重试不来，唯一的出路是显式覆盖")
        } else {
            XCTFail("半写的行不是「没设过」")
        }
    }


    /// The page must go through the three-state read, and `save()` has to be
    /// gated on the flag that read sets.
    func testPageUsesTheHonestReadAndGatesItsWrite() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/WeChatHUD/Views/Settings/AdmissionSettingsView.swift")
        let view = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(view.contains("LoadDecision(store.admissionConfigRead())"),
                      "reload 必须吃这份判据，否则被测的分类只是界面上的死代码")
        XCTAssertFalse(view.contains("config = store.loadAdmissionConfig()"),
                       "整份覆盖的页不许再用默认值兜底 hydrate")
        XCTAssertFalse(view.contains("followed = store.getWhitelist()"),
                       "关注名单读不到时不许被写成空名单")
        XCTAssertTrue(view.contains("whitelistAllRead"))
        XCTAssertTrue(view.contains("followListUnreadable"))
        XCTAssertTrue(view.contains("CompanionInteractionCopy.followListUnreadableAdmission"))
        let body = view.components(separatedBy: "private func save() {").last ?? ""
        XCTAssertTrue(body.split(separator: "\n").prefix(3).joined()
            .contains("guard loaded, loadError == nil else { return }"),
                      "保存的门不见了：读失败的那一帧之后每次点击都在写默认值")

        // 判据有门不代表扫的那条路接上了：横幅那一半要由扫描把旗子递进去。
        let scan = try String(contentsOf: URL(
            fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/WeChatHUD/Services/ScanEngine.swift"), encoding: .utf8)
        let bannerCall = scan.components(separatedBy: "AdmissionPolicy.shouldRaiseBanner(").last ?? ""
            .components(separatedBy: ")").first ?? ""
        XCTAssertTrue(bannerCall.contains("rulesUnreadable: admissionRules.rulesUnreadable"),
                      "扫描没把旗子传进去，静音名单读不到时照样弹")
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
