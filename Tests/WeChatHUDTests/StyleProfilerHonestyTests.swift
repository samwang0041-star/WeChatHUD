import XCTest
@testable import WeChatHUD

final class StyleProfilerHonestyTests: XCTestCase {
    private var store: HUDStore!
    private var tmpPath: String!
    private var reader: WeChatReader!

    override func setUpWithError() throws {
        tmpPath = NSTemporaryDirectory() + "style-honesty-\(UUID().uuidString).sqlite3"
        store = HUDStore(dbPath: tmpPath)
        try store.open()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        reader = WeChatReader(dbDir: root.path, cacheStrategy: .memory)
    }

    override func tearDown() {
        store.close()
        try? FileManager.default.removeItem(atPath: tmpPath)
    }

    func testKnownBossKeepsReportingTone() async throws {
        try store.upsertContact(username: "peer", displayName: "老板",
                                attentionLevel: .vip, role: .boss, replyWindowMinutes: 15)
        let profile = await StyleProfiler(reader: reader, store: store).getProfile(chatUsername: "peer")
        XCTAssertEqual(profile.contactRole, .boss)
        XCTAssertTrue(profile.toneDescription.contains("汇报"), profile.toneDescription)
        XCTAssertFalse(profile.toneDescription.contains("礼貌客气"), profile.toneDescription)
    }

    func testUnknownContactIsAcquaintance() async throws {
        let profile = await StyleProfiler(reader: reader, store: store).getProfile(chatUsername: "nobody")
        XCTAssertEqual(profile.contactRole, .acquaintance)
    }

    func testUnreadableContactDoesNotBecomeAcquaintanceOrGetCached() async throws {
        try store.upsertContact(username: "peer", displayName: "老板",
                                attentionLevel: .vip, role: .boss, replyWindowMinutes: 15)
        try store.exec("ALTER TABLE contacts RENAME TO contacts_hidden")
        let profiler = StyleProfiler(reader: reader, store: store)
        let profile = await profiler.getProfile(chatUsername: "peer")
        XCTAssertNil(profile.contactRole, "读失败不能写成熟人")
       XCTAssertTrue(profile.toneDescription.contains("关系读不到"), profile.toneDescription)
       XCTAssertFalse(profile.toneDescription.contains("礼貌客气"), profile.toneDescription)
        let cached = await profiler.testingProfileCacheCount()
        XCTAssertEqual(cached, 0, "读失败的口吻不能缓存 30 分钟")

        try store.exec("ALTER TABLE contacts_hidden RENAME TO contacts")
        let restored = await profiler.getProfile(chatUsername: "peer")
        XCTAssertEqual(restored.contactRole, .boss)
        XCTAssertTrue(restored.toneDescription.contains("汇报"), restored.toneDescription)
    }

    func testProactiveOutreachDoesNotTreatUnreadableAsAcquaintance() {
        XCTAssertTrue(AutopilotService.allowsProactiveOutreach(role: .friend))
        XCTAssertTrue(AutopilotService.allowsProactiveOutreach(role: .family))
        XCTAssertFalse(AutopilotService.allowsProactiveOutreach(role: .acquaintance))
        XCTAssertFalse(AutopilotService.allowsProactiveOutreach(role: .boss))
        XCTAssertFalse(AutopilotService.allowsProactiveOutreach(role: nil),
                       "读不到不是熟人，更不是可以主动问候的朋友")
    }

    func testStyleProfilerDoesNotCollapseFailedContactReadIntoAcquaintance() throws {
        let style = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/WeChatHUD/Services/StyleProfiler.swift"),
            encoding: .utf8)
        XCTAssertFalse(style.contains("getContact(username: chatUsername)"))
        XCTAssertFalse(style.contains("? .acquaintance"))
        XCTAssertTrue(style.contains("resolvedSenderRole"))

        let autopilot = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/WeChatHUD/Services/AutopilotService.swift"),
            encoding: .utf8)
        XCTAssertFalse(autopilot.contains("? .acquaintance"))
        XCTAssertTrue(autopilot.contains("allowsProactiveOutreach"))
        XCTAssertTrue(autopilot.contains("resolvedSenderRole"))
    }
}
