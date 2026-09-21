import XCTest
@testable import WeChatHUD

/// 「读不到关注名单」在四个出口上都不许变成一句事实。
///
/// `getWhitelist()` 用 `[]` 同时回答「没人被关注」和「这次没读到」，那种空数组
/// 在这四处会直接变成用户看得见的一句话：管理页的静音清单印出 wxid、诊断写
/// 「关注 0」、导出件写「关注对象 (0)」、没回那一页打印「都回过了」。四句都是
/// 关于完整性的断言，而这次根本没看到名单。
@MainActor
final class WhitelistScopeHonestyTests: XCTestCase {

    private var root: String!
    private var store: HUDStore!
    private var monitor: ChatMonitor!

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "wl-scope-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        store = HUDStore(dbPath: root + "/hud.sqlite3")
        try store.open()
        let reader = WeChatReader(keysPath: root + "/absent-keys.json",
                                  dbDir: root + "/synthetic/db_storage",
                                  cacheStrategy: .memory)
        monitor = ChatMonitor(reader: reader, store: store, aiService: AIService(config: AIConfig()))
    }

    override func tearDown() {
        store.close()
        try? FileManager.default.removeItem(atPath: root)
    }

    /// 永久静音在库里存成「十年后的水位」；这里比那个再晚一点，
    /// 免得测试跟着 `permanentSilenceBufferSeconds` 的口径漂。
    private func silencePermanently(_ username: String) throws {
        try store.silenceChat(
            chatUsername: username,
            silencedAt: Int(Date().timeIntervalSince1970) + 400 * 86400
        )
    }

    /// 常见情形：静音的正是被关注的群，名单里的名字就该用上。
    func testSilencedListUsesTheFollowName() throws {
        try store.addToWhitelist(username: "team@chatroom", displayName: "供应链周会",
                                 isGroup: true, category: .work)
        try silencePermanently("team@chatroom")

        let list = try XCTUnwrap(monitor.silencedConversationsRead)
        XCTAssertEqual(list.map(\.displayName), ["供应链周会"])
    }

    /// 名字读不到时，静音清单不能把账号 id 印出来 —— 原来的收尾是
    /// `names[key] ?? key`，而静音的常常正是没被关注的群，白名单里没有它。
    func testSilencedListSaysUnreadableRatherThanPrintingTheAccountId() throws {
        try store.addToWhitelist(username: "wxid_quietbot", displayName: "安静的人",
                                 isGroup: false, category: .work)
        try silencePermanently("wxid_quietbot")

        // 正对照：读得到的时候用的是真名字，所以下面那句不是「永远说读不到」。
        let healthy = try XCTUnwrap(monitor.silencedConversationsRead)
        XCTAssertEqual(healthy.map(\.displayName), ["安静的人"])

        // 两份名字来源一起读不到，才是最坏情形。
        try store.exec("ALTER TABLE whitelist RENAME TO whitelist_hidden")
        try store.exec("ALTER TABLE contacts RENAME TO contacts_hidden")

        let list = try XCTUnwrap(monitor.silencedConversationsRead)
        XCTAssertEqual(list.map(\.displayName), [ContactIdentityIndex.unreadableNamePlaceholder])
        XCTAssertFalse(list.contains { $0.displayName == "wxid_quietbot" },
                       "账号 id 不是名字")
    }

    /// 导出件是会被存档的：写「关注对象 (0)」等于留了一份看起来像
    /// 「你把关注全清了」的记录。
    func testDailyExportDoesNotArchiveZeroFollowedWhenTheListCannotBeRead() throws {
        try store.addToWhitelist(username: "wxid_boss", displayName: "老板",
                                 isGroup: false, category: .work, attentionLevel: .vip)
        let out = URL(fileURLWithPath: root).appendingPathComponent("export")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        // 正对照：读得到时导出的就是真数字。
        let healthy = try XCTUnwrap(monitor.exportReport(into: out))
        let healthyText = try String(contentsOf: healthy, encoding: .utf8)
        XCTAssertTrue(healthyText.contains("## 关注对象 (1)"),
                      "读得到时还是要有真数字，否则这条门只是「永远说读不到」")

        try store.exec("ALTER TABLE whitelist RENAME TO whitelist_hidden")
        let degraded = try XCTUnwrap(monitor.exportReport(into: out))
        let degradedText = try String(contentsOf: degraded, encoding: .utf8)
        XCTAssertFalse(degradedText.contains("关注对象 (0)"),
                       "0 会被读成「你把关注全清了」")
        XCTAssertTrue(degradedText.contains("这次没能读到关注名单"),
                      "缺数字的那一节要自己说明为什么缺")
    }

    /// 没回那一页的空态是「关注的私聊和群 @ 都回过了」—— 一句关于完整性的
    /// 断言。名单都没读到，就没资格说这句话。
    func testMissedRepliesRefusesToClaimAllClearWhenTheListCannotBeRead() throws {
        try store.exec("ALTER TABLE whitelist RENAME TO whitelist_hidden")

        monitor.refreshMissedReplies(
            start: Date().addingTimeInterval(-86_400),
            end: Date()
        )

        XCTAssertEqual(monitor.missedReplyError,
                       CompanionInteractionCopy.followListUnreadableMissedReplies)
        XCTAssertTrue(monitor.missedReplies.isEmpty)
        XCTAssertFalse(monitor.missedReplyLoading)
    }

    /// `countSummary` 是视图里的私有计算属性，没有行为接缝，所以钉形状：
    /// 它必须走那份能回答「读不到」的读法。
    func testDiagnosticsCountSummaryReadsTheThreeStateWhitelist() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/WeChatHUD/Views/Settings/SupportDiagnosticsView.swift"),
            encoding: .utf8)
        let summary = try XCTUnwrap(
            source.components(separatedBy: "private var countSummary: String {").last
        ).components(separatedBy: "\n    }").first ?? ""
        XCTAssertFalse(summary.isEmpty, "countSummary 不见了，门禁要跟着搬")
        XCTAssertTrue(summary.contains("whitelistAllRead"),
                      "诊断页正是用户来问「到底怎么了」的地方，写「关注 0」会让人以为名单被清空")
        XCTAssertFalse(summary.contains("getWhitelist"),
                       "两态读法在这里会把「读不到」印成 0")
    }
}

