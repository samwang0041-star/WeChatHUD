import XCTest
@testable import WeChatHUD

/// The 「没回的」 page states a negative: nothing is left unanswered. That is
/// only true if the walk actually covered the corpus, so the scan reports what
/// it did not read and the page says so.
final class MissedReplyCoverageTests: XCTestCase {

    private var root: URL!
    private var keysURL: URL!
    private var dbDir: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("missed-coverage-" + UUID().uuidString)
        dbDir = root.appendingPathComponent("acct/db_storage", isDirectory: true)
        keysURL = root.appendingPathComponent("all_keys.json")
        try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A reader over an empty database directory: every chat reads back as "no
    /// messages", so the scan's own accounting is the only thing left to check.
    private func makeReader() -> WeChatReader {
        try! JSONSerialization.data(withJSONObject: [:] as [String: String])
            .write(to: keysURL)
        return WeChatReader(keysPath: keysURL.path, dbDir: dbDir.path, cacheStrategy: .memory)
    }

    private func whitelist(_ count: Int) -> [WhitelistEntry] {
        (0..<count).map {
            WhitelistEntry(
                id: "peer\($0)",
                displayName: "联系人\($0)",
                isGroup: false,
                category: .work,
                attentionLevel: .vip,
                addedAt: Date(),
                autoSuggested: false
            )
        }
    }

    private func scan(
        reader: WeChatReader,
        chats: Int,
        maxChats: Int
    ) -> (items: [MissedReplyFinder.Item], coverage: MissedReplyFinder.Coverage) {
        let now = Date()
        return ScanEngine.buildMissedReplyItems(
            reader: reader,
            admissionRules: AdmissionRules(
                config: AdmissionConfig(),
                followedChats: Set((0..<chats).map { "peer\($0)" }),
                vipChats: [],
                vipPeople: [],
                watchedMembers: [:],
                perChatMuted: [:],
                globalMuted: []
            ),
            whitelist: whitelist(chats),
            myUsername: "me",
            myDisplayName: "我",
            mySelfNames: [],
            rangeStart: now.addingTimeInterval(-86_400),
            rangeEnd: now,
            now: now,
            maxChats: maxChats
        )
    }

    // MARK: - The walk reports its own holes

    func testChatsBeyondTheCapAreReportedAsNeverExamined() {
        let result = scan(reader: makeReader(), chats: 5, maxChats: 2)
        XCTAssertEqual(result.coverage.examinedChats, 2)
        XCTAssertEqual(result.coverage.unexaminedChats, 3)
        XCTAssertFalse(result.coverage.isComplete)
        XCTAssertTrue(result.items.isEmpty)
    }

    func testAScanWithRoomForEveryChatClaimsNothingMissing() {
        let result = scan(reader: makeReader(), chats: 5, maxChats: 20)
        XCTAssertEqual(result.coverage.unexaminedChats, 0)
        XCTAssertEqual(result.coverage.examinedChats, 5)
        XCTAssertNil(result.coverage.caveat)
    }

    // MARK: - The disclosure itself

    func testCompleteCoverageCarriesNoCaveat() {
        let coverage = MissedReplyFinder.Coverage(examinedChats: 7)
        XCTAssertTrue(coverage.isComplete)
        XCTAssertNil(coverage.caveat)
    }

    func testBothKindsOfHoleAddUp() {
        let coverage = MissedReplyFinder.Coverage(
            examinedChats: 7, unreadableChats: 2, unexaminedChats: 3
        )
        XCTAssertEqual(coverage.missingChats, 5)
        XCTAssertEqual(
            coverage.caveat,
            "另有 5 个对话没读到，这里可能不全。"
        )
    }

    func testEveryHoleAppearsInTheSameLine() throws {
        let coverage = MissedReplyFinder.Coverage(
            examinedChats: 7, unreadableChats: 2, unexaminedChats: 3,
            groupSessionsUnavailable: true
        )
        let caveat = try XCTUnwrap(coverage.caveat)
        XCTAssertTrue(caveat.contains("另有 5 个对话没读到"), caveat)
        XCTAssertTrue(caveat.contains("群会话列表没读到"), caveat)
    }

    /// The all-clear headline must be reachable only from complete coverage —
    /// a nil `caveat` is what the view keys on.
    func testOnlyCompleteCoverageCanUseTheAllClearHeadline() {
        XCTAssertNil(MissedReplyFinder.Coverage(examinedChats: 4).caveat)
        XCTAssertNotNil(MissedReplyFinder.Coverage(examinedChats: 4, unexaminedChats: 1).caveat)
        XCTAssertNotNil(MissedReplyFinder.Coverage(examinedChats: 4, unreadableChats: 1).caveat)
        XCTAssertNotNil(
            MissedReplyFinder.Coverage(examinedChats: 4, groupSessionsUnavailable: true).caveat
        )
    }

    func testHeadlineGatesOnTheCaveatNotOnTheCount() throws {
        let view = try readSource("Views/MissedReplyFeed.swift")
        XCTAssertTrue(view.contains("missedRepliesAllClear"))
        XCTAssertTrue(view.contains("missedRepliesPartial"))
        XCTAssertFalse(
            view.contains("没有没回的消息"),
            "the double-negative completeness claim is back"
        )
    }

    private func readSource(_ relativePath: String) throws -> String {
        let base = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(
            contentsOf: base.appendingPathComponent("Sources/WeChatHUD/\(relativePath)"),
            encoding: .utf8
        )
    }
}
