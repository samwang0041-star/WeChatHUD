import XCTest
@testable import WeChatHUD

final class InboxContextBuilderTests: XCTestCase {

    // MARK: - contextWindowSize

    func testContextWindowSizeVeryShort() {
        XCTAssertEqual(InboxContextBuilder.contextWindowSize(messageLength: 2), 30)
    }

    func testContextWindowSizeShort() {
        XCTAssertEqual(InboxContextBuilder.contextWindowSize(messageLength: 15), 25)
    }

    func testContextWindowSizeMedium() {
        XCTAssertEqual(InboxContextBuilder.contextWindowSize(messageLength: 35), 20)
    }

    func testContextWindowSizeLong() {
        XCTAssertEqual(InboxContextBuilder.contextWindowSize(messageLength: 80), 15)
    }

    func testContextWindowSizeBoundaryAt5() {
        XCTAssertEqual(InboxContextBuilder.contextWindowSize(messageLength: 5), 30)
    }

    func testContextWindowSizeBoundaryAt6() {
        XCTAssertEqual(InboxContextBuilder.contextWindowSize(messageLength: 6), 25)
    }

    func testContextWindowSizeBoundaryAt20() {
        XCTAssertEqual(InboxContextBuilder.contextWindowSize(messageLength: 20), 25)
    }

    func testContextWindowSizeBoundaryAt21() {
        XCTAssertEqual(InboxContextBuilder.contextWindowSize(messageLength: 21), 20)
    }

    func testContextWindowSizeBoundaryAt50() {
        XCTAssertEqual(InboxContextBuilder.contextWindowSize(messageLength: 50), 20)
    }

    func testContextWindowSizeBoundaryAt51() {
        XCTAssertEqual(InboxContextBuilder.contextWindowSize(messageLength: 51), 15)
    }

    // MARK: - calculateTrend

    func testTrendUp() {
        let trend = InboxContextBuilder.calculateTrend(dailyCounts: [1, 2, 1, 3, 4, 5, 6])
        XCTAssertEqual(trend, .up)
    }

    func testTrendDown() {
        let trend = InboxContextBuilder.calculateTrend(dailyCounts: [6, 5, 4, 3, 1, 1, 1])
        XCTAssertEqual(trend, .down)
    }

    func testTrendStable() {
        let trend = InboxContextBuilder.calculateTrend(dailyCounts: [3, 3, 3, 3, 3, 3, 3])
        XCTAssertEqual(trend, .stable)
    }

    func testTrendTooFewDays() {
        let trend = InboxContextBuilder.calculateTrend(dailyCounts: [1, 5, 10])
        XCTAssertEqual(trend, .stable, "fewer than 4 data points should return stable")
    }

    func testTrendEmptyArray() {
        let trend = InboxContextBuilder.calculateTrend(dailyCounts: [])
        XCTAssertEqual(trend, .stable)
    }

    func testTrendExactlyFourElements() {
        // [1, 1, 5, 5] → firstHalf=2, secondHalf=10, diff=8, threshold=max(2/3,2)=2
        let trend = InboxContextBuilder.calculateTrend(dailyCounts: [1, 1, 5, 5])
        XCTAssertEqual(trend, .up)
    }

    // MARK: - detectMediaType

    func testMediaTypeImage() {
        XCTAssertEqual(InboxContextBuilder.detectMediaType(baseType: 3), .image)
    }

    func testMediaTypeVoice() {
        XCTAssertEqual(InboxContextBuilder.detectMediaType(baseType: 34), .voice)
    }

    func testMediaTypeVideo() {
        XCTAssertEqual(InboxContextBuilder.detectMediaType(baseType: 43), .video)
    }

    func testMediaTypeSticker() {
        XCTAssertEqual(InboxContextBuilder.detectMediaType(baseType: 47), .sticker)
    }

    func testMediaTypeLocation() {
        XCTAssertEqual(InboxContextBuilder.detectMediaType(baseType: 48), .location)
    }

    func testMediaTypeLink() {
        XCTAssertEqual(InboxContextBuilder.detectMediaType(baseType: 49), .link)
    }

    func testMediaTypeTextReturnsNil() {
        XCTAssertNil(InboxContextBuilder.detectMediaType(baseType: 1), "text baseType should return nil")
    }

    func testMediaTypeSystemReturnsNil() {
        XCTAssertNil(InboxContextBuilder.detectMediaType(baseType: 10000), "system baseType should return nil")
    }

    func testMediaTypeZeroReturnsNil() {
        XCTAssertNil(InboxContextBuilder.detectMediaType(baseType: 0))
    }

    // MARK: - follow-state honesty

    func testKnownVIPStaysVIP() throws {
        let (store, path) = try makeStore()
        defer { cleanup(store, path) }
        try store.addToWhitelist(username: "peer", displayName: "同事", isGroup: false,
                                 category: .work, attentionLevel: .vip)
        XCTAssertEqual(
            InboxContextBuilder.resolvedAttentionLevel(store: store, chatUsername: "peer"),
            .vip)
    }

    func testUnknownChatIsStranger() throws {
        let (store, path) = try makeStore()
        defer { cleanup(store, path) }
        XCTAssertEqual(
            InboxContextBuilder.resolvedAttentionLevel(store: store, chatUsername: "nobody"),
            .stranger)
    }

    func testUnreadableWhitelistDoesNotBecomeStranger() throws {
        let (store, path) = try makeStore()
        defer { cleanup(store, path) }
        try store.addToWhitelist(username: "peer", displayName: "同事", isGroup: false,
                                 category: .work, attentionLevel: .vip)
        try store.exec("ALTER TABLE whitelist RENAME TO whitelist_hidden")
        let level = InboxContextBuilder.resolvedAttentionLevel(store: store, chatUsername: "peer")
       XCTAssertNotEqual(level, .stranger, "a failed follow-table read is not not-followed")
       XCTAssertEqual(level, .vip)
   }

    func testKnownBossRoleStaysBoss() throws {
        let (store, path) = try makeStore()
        defer { cleanup(store, path) }
        try stampBoss(store)
        XCTAssertEqual(
            InboxContextBuilder.resolvedSenderRole(store: store, chatUsername: "peer"),
            .boss)
        XCTAssertEqual(
            InboxContextBuilder.resolvedContactWindowMinutes(store: store, chatUsername: "peer"),
            15)
    }

    func testUnknownContactIsAcquaintance() throws {
        let (store, path) = try makeStore()
        defer { cleanup(store, path) }
        XCTAssertEqual(
            InboxContextBuilder.resolvedSenderRole(store: store, chatUsername: "nobody"),
            .acquaintance)
        XCTAssertEqual(
            InboxContextBuilder.resolvedContactWindowMinutes(store: store, chatUsername: "nobody"),
            0)
    }

    func testUnreadableContactDoesNotBecomeAcquaintance() throws {
        let (store, path) = try makeStore()
        defer { cleanup(store, path) }
        try stampBoss(store)
        try store.exec("ALTER TABLE contacts RENAME TO contacts_hidden")
        XCTAssertNil(
            InboxContextBuilder.resolvedSenderRole(store: store, chatUsername: "peer"),
            "a failed contacts read is not 熟人")
        XCTAssertNotEqual(
            InboxContextBuilder.resolvedSenderRole(store: store, chatUsername: "peer"),
            .acquaintance)
        XCTAssertEqual(
            InboxContextBuilder.resolvedContactWindowMinutes(store: store, chatUsername: "peer"),
            0,
            "unreadable window must fall back to the attention tier, not a guessed SLA")
    }

    func testPassedContactEntryWinsWhileTheTableIsUnreadable() throws {
        let (store, path) = try makeStore()
        defer { cleanup(store, path) }
        try stampBoss(store)
        let passed = try XCTUnwrap(store.getContact(username: "peer"))
        try store.exec("ALTER TABLE contacts RENAME TO contacts_hidden")
        XCTAssertEqual(
            InboxContextBuilder.resolvedSenderRole(
                store: store, chatUsername: "peer", contactEntry: passed),
            .boss)
        XCTAssertEqual(
            InboxContextBuilder.resolvedContactWindowMinutes(
                store: store, chatUsername: "peer", contactEntry: passed),
            15)
    }

    func testBuilderDoesNotCollapseFailedContactReadIntoAcquaintance() throws {
        let builder = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Services/InboxContextBuilder.swift"),
            encoding: .utf8)
        XCTAssertFalse(builder.contains("contactEntry?.role ??"))
        XCTAssertFalse(builder.contains("?? .acquaintance"))
        XCTAssertTrue(builder.contains("contactRead"))
        XCTAssertTrue(builder.contains("resolvedContact"))

        let monitor = try String(
            contentsOf: sourcesRoot().appendingPathComponent("Services/ChatMonitor.swift"),
            encoding: .utf8)
        XCTAssertFalse(monitor.contains("?.role ?? .colleague"))
        XCTAssertFalse(monitor.contains("?.role ?? .acquaintance"))
        XCTAssertTrue(monitor.contains("resolvedSenderRole"))
        XCTAssertTrue(monitor.contains("resolvedContact"))
    }

   private func makeStore() throws -> (HUDStore, String) {
       let path = NSTemporaryDirectory() + "inbox-context-attn-\(UUID().uuidString).sqlite3"
       let store = HUDStore(dbPath: path)
       try store.open()
       return (store, path)
   }

    private func stampBoss(_ store: HUDStore) throws {
        try store.addToWhitelist(username: "peer", displayName: "老板", isGroup: false,
                                 category: .work, attentionLevel: .vip)
        try store.upsertContact(username: "peer", displayName: "老板",
                                attentionLevel: .vip, role: .boss, replyWindowMinutes: 15)
    }

    private func sourcesRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/WeChatHUD")
    }

    private func cleanup(_ store: HUDStore, _ path: String) {
        store.close()
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: path + suffix)
        }
    }
}
