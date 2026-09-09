import XCTest
import SQLite3
import CommonCrypto
import CryptoKit
@testable import WeChatHUD

final class HistoricalInsightReliabilityTests: XCTestCase {
    func testHistoricalDateFilterRunsBeforeLimitAndExcludesNextDay() throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(":memory:", &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE messages (local_id INTEGER PRIMARY KEY, create_time INTEGER)", nil, nil, nil), SQLITE_OK)
        // More than 500 later messages previously pushed this historical day
        // entirely out of the latest-message window.
        for id in 1...605 {
            let timestamp = id <= 5 ? 1000 + id : 2000 + id
            XCTAssertEqual(sqlite3_exec(db, "INSERT INTO messages VALUES (\(id), \(timestamp))", nil, nil, nil), SQLITE_OK)
        }
        XCTAssertEqual(sqlite3_exec(db, "INSERT INTO messages VALUES (606, 1006)", nil, nil, nil), SQLITE_OK)
        let sql = "SELECT local_id FROM messages" + WeChatReader.messageQuerySuffix(
            limit: 501, startTime: 1001, endTime: 1006)
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, sql, -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        var ids: [Int] = []
        while sqlite3_step(statement) == SQLITE_ROW { ids.append(Int(sqlite3_column_int64(statement, 0))) }
        XCTAssertEqual(ids, [5, 4, 3, 2, 1])
    }

    func testDateRangeSupportsCompositeCursorWithoutCrossingDayBoundary() throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(":memory:", &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE messages (local_id INTEGER PRIMARY KEY, create_time INTEGER)", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "INSERT INTO messages VALUES (1,1000),(2,1000),(3,1001),(4,2000)", nil, nil, nil), SQLITE_OK)
        let sql = "SELECT local_id FROM messages" + WeChatReader.messageQuerySuffix(
            limit: 500, afterCursor: (1000, 1), oldestFirst: true, startTime: 1000, endTime: 2000)
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, sql, -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        var ids: [Int] = []
        while sqlite3_step(statement) == SQLITE_ROW { ids.append(Int(sqlite3_column_int64(statement, 0))) }
        XCTAssertEqual(ids, [2, 3])
    }

    func testDetailDayRangeUsesSelectedDayAndCalendarMidnight() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let selected = calendar.date(from: DateComponents(year: 2026, month: 8, day: 12, hour: 18))!
        let range = InsightDataLoader.dayRange(for: selected, calendar: calendar)
        XCTAssertEqual(range.start, Int(calendar.date(from: DateComponents(year: 2026, month: 8, day: 12))!.timeIntervalSince1970))
        XCTAssertEqual(range.end - range.start, 86400)
        XCTAssertLessThan(range.start, Int(selected.timeIntervalSince1970))
    }

    func testDetailDayRangeHandlesDaylightSavingWithoutIncludingNextDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let selected = calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 12))!
        let range = InsightDataLoader.dayRange(for: selected, calendar: calendar)
        XCTAssertEqual(range.end - range.start, 23 * 3600)
        XCTAssertEqual(calendar.component(.day, from: Date(timeIntervalSince1970: Double(range.end))), 9)
        XCTAssertEqual(calendar.component(.hour, from: Date(timeIntervalSince1970: Double(range.end))), 0)
    }

    private func memory(updated: Date) -> ConversationMemory {
        ConversationMemory(chatUsername: "peer", summary: "后来决定改用方案B", keyTopics: [],
                           pendingItems: [], sharedContext: [], communicationNotes: [], moodTrend: "",
                           conversationPhase: "决策", stance: "支持B", messageCount7d: 10, lastUpdated: updated)
    }

    func testFutureMemoryIsExcludedFromHistoricalDay() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let end = start.addingTimeInterval(86400)
        XCTAssertNil(ChatInsightService.memoryForAnalysis(memory(updated: end), dayStart: start, dayEnd: end))
        XCTAssertNil(ChatInsightService.memoryForAnalysis(memory(updated: end.addingTimeInterval(86400)), dayStart: start, dayEnd: end))
        XCTAssertNotNil(ChatInsightService.memoryForAnalysis(memory(updated: end.addingTimeInterval(-1)), dayStart: start, dayEnd: end))
    }

    func testStaleMemoryIsNotPresentedAsLastSevenDays() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertNil(ChatInsightService.memoryForAnalysis(memory(updated: start.addingTimeInterval(-8 * 86400)),
                                                         dayStart: start, dayEnd: start.addingTimeInterval(86400)))
    }

    func testCoverageNoticeDisclosesTruncationAndMediaLimits() {
        let partial = ChatInsightService.coverageNotice(analyzedCount: 420, isTruncated: true)
        XCTAssertTrue(partial.contains("最后 500 条"))
        XCTAssertTrue(partial.contains("420"))
        XCTAssertTrue(partial.contains("更早内容未覆盖"))
        let full = ChatInsightService.coverageNotice(analyzedCount: 25, isTruncated: false)
        XCTAssertTrue(full.contains("25"))
        XCTAssertTrue(full.contains("媒体内容未纳入"))
    }

    func testStatsForDayReadsOnlyTheSelectedCalendarDayFromReader() throws {
        let fixture = try InsightReaderFixture(messages: [
            .init(localID: 1, timestampOffset: -1, text: "前一天"),
            .init(localID: 2, timestampOffset: 1, text: "当天第一条"),
            .init(localID: 3, timestampOffset: 86_399, text: "当天最后一条"),
            .init(localID: 4, timestampOffset: 86_400, text: "下一天")
        ])
        defer { fixture.cleanup() }

        let selectedDay = fixture.selectedDay
        do {
            let raw = try fixture.reader.getMessages(chatUsername: fixture.chatUsername, limit: Int.max)
            XCTAssertEqual(raw.count, 4)
        } catch {
            XCTFail("synthetic reader fixture could not be read: \(error)")
        }
        let stats = InsightDataLoader().statsForDay(
            chatUsername: fixture.chatUsername,
            chatName: "合成对话",
            isGroup: false,
            category: .work,
            date: selectedDay,
            reader: fixture.reader
        )

        XCTAssertEqual(stats?.messageCount, 2)
        XCTAssertEqual(stats?.myMessageCount, 2)
        XCTAssertEqual(stats?.messagesByHour.reduce(0, +), 2)
    }

    @MainActor
    func testLaterDateRequestWinsWhenEarlierInsightFinishesLast() async throws {
        let fixture = try InsightReaderFixture(messages: [
            .init(localID: 1, timestampOffset: 1, text: "旧日期消息"),
            .init(localID: 2, timestampOffset: 86_401, text: "新日期消息")
        ])
        defer { fixture.cleanup() }

        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("historical-insight-store-" + UUID().uuidString + ".sqlite3")
        let store = HUDStore(dbPath: databaseURL.path)
        try store.open()
        defer {
            store.close()
            try? FileManager.default.removeItem(at: databaseURL)
        }
        try store.addToWhitelist(
            username: fixture.chatUsername,
            displayName: "合成对话",
            isGroup: false,
            category: .work
        )

        var config = AIConfig()
        config.provider = AIProviderSlot(
            providerID: "custom", baseURL: "http://insight-test.local", model: "test-model", apiKey: "test"
        )
        InsightDelayedURLProtocol.install(
            firstResponse: InsightDelayedURLProtocol.response(headline: "旧日期结果"),
            laterResponse: InsightDelayedURLProtocol.response(headline: "新日期结果")
        )
        defer { InsightDelayedURLProtocol.uninstall() }

        let coordinator = InsightCoordinator(
            reader: fixture.reader,
            store: store,
            aiService: AIService(config: config)
        )
        let oldTask = Task { await coordinator.analyzeOneChat(chatUsername: fixture.chatUsername, date: fixture.selectedDay) }
        let firstStarted = await InsightDelayedURLProtocol.waitForFirstRequest()
        XCTAssertTrue(firstStarted, "the first AI request should start")
        let newTask = Task {
            await coordinator.analyzeOneChat(
                chatUsername: fixture.chatUsername,
                date: fixture.selectedDay.addingTimeInterval(86_400)
            )
        }
        let laterStarted = await InsightDelayedURLProtocol.waitForLaterRequest()
        XCTAssertTrue(laterStarted, "the newer AI request should start before the old response is released")
        InsightDelayedURLProtocol.releaseFirstRequest()
        await oldTask.value
        await newTask.value

        XCTAssertEqual(
            coordinator.result(for: fixture.chatUsername, date: fixture.selectedDay)?.headline,
            nil,
            "the late old response must not become the selected result"
        )
        XCTAssertEqual(
            coordinator.result(for: fixture.chatUsername, date: fixture.selectedDay.addingTimeInterval(86_400))?.headline,
            "新日期结果"
        )
    }

    private struct InsightFixtureMessage {
        let localID: Int
        let timestampOffset: Int
        let text: String
    }

    private final class InsightReaderFixture {
        let root: URL
        let reader: WeChatReader
        let chatUsername = "insight-peer"
        let selectedDay: Date
        let dayStart: Int

        init(messages: [InsightFixtureMessage]) throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("historical-insight-reader-" + UUID().uuidString)
            let dbDir = root.appendingPathComponent("xwechat_files/wxid_me/db_storage")
            try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
            let calendar = Calendar.current
            selectedDay = calendar.date(byAdding: .day, value: -2, to: calendar.startOfDay(for: Date()))!
            dayStart = Int(selectedDay.timeIntervalSince1970)

            let plainURL = root.appendingPathComponent("message-plain.sqlite")
            var db: OpaquePointer?
            guard sqlite3_open(plainURL.path, &db) == SQLITE_OK else {
                throw NSError(domain: "InsightReaderFixture", code: 1)
            }
            var reserveBytes: Int32 = 80
            guard sqlite3_file_control(db, nil, SQLITE_FCNTL_RESERVE_BYTES, &reserveBytes) == SQLITE_OK else {
                throw NSError(domain: "InsightReaderFixture", code: 5)
            }
            let table = "Msg_" + Self.md5Hex(chatUsername)
            let schema = """
                PRAGMA page_size=4096;
                PRAGMA auto_vacuum=0;
                VACUUM;
                CREATE TABLE Name2Id (user_name TEXT);
                INSERT INTO Name2Id(user_name) VALUES ('wxid_me');
                CREATE TABLE [__TABLE__] (
                    local_id INTEGER PRIMARY KEY,
                    local_type INTEGER,
                    create_time INTEGER,
                    real_sender_id INTEGER,
                    message_content TEXT,
                    WCDB_CT_message_content INTEGER
                );
            """.replacingOccurrences(of: "__TABLE__", with: table)
            guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK else {
                throw NSError(domain: "InsightReaderFixture", code: 2)
            }
            for message in messages {
                let timestamp = dayStart + message.timestampOffset
                let escaped = message.text.replacingOccurrences(of: "'", with: "''")
                let sql = "INSERT INTO [" + table + "] VALUES (" + String(message.localID) + ", 1, " + String(timestamp) + ", 1, '" + escaped + "', 0);"
                guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
                    throw NSError(domain: "InsightReaderFixture", code: 3)
                }
            }
            sqlite3_close(db)

            let key = Data(repeating: 0x42, count: 32)
            let encryptedURL = dbDir.appendingPathComponent("message/message_0.db")
            try FileManager.default.createDirectory(at: encryptedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.encrypt(plainURL, to: encryptedURL, key: key)
            let keysURL = root.appendingPathComponent("keys.json")
            let keys = ["message/message_0.db": ["enc_key": key.map { String(format: "%02x", $0) }.joined()]]
            try JSONSerialization.data(withJSONObject: keys).write(to: keysURL)
            reader = WeChatReader(keysPath: keysURL.path, dbDir: dbDir.path, cacheStrategy: .memory)
            try reader.loadKeys()
        }

        func cleanup() { try? FileManager.default.removeItem(at: root) }

        private static func md5Hex(_ value: String) -> String {
            Insecure.MD5.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
        }

        private static func encrypt(_ plain: URL, to encrypted: URL, key: Data) throws {
            let data = try Data(contentsOf: plain)
            var output = Data()
            let iv = Data(repeating: 0x22, count: 16)
            for start in stride(from: 0, to: data.count, by: 4096) {
                let first = start == 0
                let bytes = data.subdata(in: start + (first ? 16 : 0)..<start + 4016)
                var cipher = Data(count: bytes.count)
                var written = 0
                let status = cipher.withUnsafeMutableBytes { destination in
                    bytes.withUnsafeBytes { source in
                        key.withUnsafeBytes { keyBytes in
                            iv.withUnsafeBytes { vector in
                                CCCrypt(
                                    CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), 0,
                                    keyBytes.baseAddress, 32, vector.baseAddress,
                                    source.baseAddress, bytes.count,
                                    destination.baseAddress, bytes.count, &written
                                )
                            }
                        }
                    }
                }
                guard status == CCCryptorStatus(kCCSuccess) else {
                    throw NSError(domain: "InsightReaderFixture", code: 4)
                }
                if first { output += Data(repeating: 0x11, count: 16) }
                output += cipher + iv + Data(count: 64)
            }
            try output.write(to: encrypted, options: .atomic)
        }
    }
}

private final class InsightDelayedURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var firstResponse: (Data, URLResponse)!
    private static var laterResponse: (Data, URLResponse)!
    private static var firstStarted = DispatchSemaphore(value: 0)
    private static var laterStarted = DispatchSemaphore(value: 0)
    private static var releaseFirst = DispatchSemaphore(value: 0)
    private static var requestCount = 0
    private static var installed = false

    static func install(firstResponse: (Data, URLResponse), laterResponse: (Data, URLResponse)) {
        lock.lock()
        self.firstResponse = firstResponse
        self.laterResponse = laterResponse
        firstStarted = DispatchSemaphore(value: 0)
        laterStarted = DispatchSemaphore(value: 0)
        releaseFirst = DispatchSemaphore(value: 0)
        requestCount = 0
        installed = true
        lock.unlock()
        URLProtocol.registerClass(self)
    }

    static func uninstall() {
        URLProtocol.unregisterClass(self)
        lock.lock()
        installed = false
        lock.unlock()
    }

    static func response(headline: String) -> (Data, URLResponse) {
        let content = """
        {"headline":"\(headline)","topics":[],"decisions":[],"action_items":[],"mentions_me":0,"waiting_for_me":[],"my_commitments":[],"needs_my_attention":false,"overall_mood":"","signal_noise_ratio":0,"decision_efficiency":"","importance_to_me":{"level":"","reason":""},"cross_chat_topics":[],"insight":"\(headline)","suggestion":""}
        """
        return URLRequestRecorder.makeChatCompletionsResponse(content: content, urlString: "http://insight-test.local/chat/completions")
    }

    static func waitForFirstRequest() async -> Bool {
        await waitForRequestCount(atLeast: 1)
    }

    static func waitForLaterRequest() async -> Bool {
        await waitForRequestCount(atLeast: 2)
    }

    private static func waitForRequestCount(atLeast target: Int) async -> Bool {
        for _ in 0..<300 {
            if hasRequestCount(atLeast: target) { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    private static func hasRequestCount(atLeast target: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return requestCount >= target
    }

    static func releaseFirstRequest() { releaseFirst.signal() }

    override class func canInit(with request: URLRequest) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return installed && request.url?.host == "insight-test.local"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.requestCount += 1
        let requestNumber = Self.requestCount
        let response = requestNumber == 1 ? Self.firstResponse! : Self.laterResponse!
        Self.lock.unlock()

        if requestNumber == 1 {
            Self.firstStarted.signal()
            DispatchQueue.global().async { [self] in
                Self.releaseFirst.wait()
                finish(response)
            }
        } else {
            Self.laterStarted.signal()
            finish(response)
        }
    }

    private func finish(_ response: (Data, URLResponse)) {
        client?.urlProtocol(self, didReceive: response.1, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.0)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
