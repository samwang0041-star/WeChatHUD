import XCTest
import SQLite3
import CommonCrypto
@testable import WeChatHUD

final class ContactRecommendationScanSourceTests: XCTestCase {
    private enum ReadError: Error {
        case unavailable
    }

    private final class ReadTracker: @unchecked Sendable {
        private let lock = NSLock()
        private var usernames: [String] = []
        private var progressCount = 0

        func recordRead(_ username: String) {
            lock.lock()
            usernames.append(username)
            lock.unlock()
        }

        func recordProgress() {
            lock.lock()
            progressCount += 1
            lock.unlock()
        }

        func snapshot() -> (reads: [String], progressCount: Int) {
            lock.lock()
            defer { lock.unlock() }
            return (usernames, progressCount)
        }
    }

    @MainActor
    func testScanAggregatesPartialMessageFailuresAndReportsProgress() async throws {
        let candidates = [
            ContactRecommendationScanSource.Candidate(
                username: "ok", displayName: "可读联系人", isGroup: false, recentCount: 8
            ),
            ContactRecommendationScanSource.Candidate(
                username: "bad", displayName: "不可读联系人", isGroup: false, recentCount: 7
            ),
            ContactRecommendationScanSource.Candidate(
                username: "empty", displayName: "无消息联系人", isGroup: false, recentCount: 0
            )
        ]
        let source = ContactRecommendationScanSource(
            readCandidates: { _ in candidates },
            readMessages: { username, _ in
                switch username {
                case "ok": return [ContactRecommendationScanSource.Message(sender: "对方", body: "你好")]
                case "empty": return []
                default: throw ReadError.unavailable
                }
            }
        )
        var progress: [ContactRecommendationScanSource.Progress] = []

        let result = try await source.scan(limit: 10, messageLimit: 5) { progress.append($0) }

        XCTAssertEqual(result.candidates.count, 3)
        XCTAssertEqual(result.messageBundles.map(\.candidate.username), ["ok"])
        XCTAssertEqual(result.failures.map(\.candidate.username), ["bad"])
        XCTAssertEqual(result.emptyMessageCount, 1)
        XCTAssertEqual(result.completedCount, 3)
        XCTAssertEqual(result.failedCount, 1)
        XCTAssertEqual(progress.last?.completed, 3)
        XCTAssertEqual(progress.last?.failed, 1)
        XCTAssertEqual(progress.last?.empty, 1)
    }

    func testMissingMessageDatabaseSurfacesReaderError() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("recommendation-source-\(UUID().uuidString)")
        let keysURL = root.appendingPathComponent("keys.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let key = String(repeating: "00", count: 32)
        let keys: [String: [String: String]] = [
            "message/message_1.db": ["enc_key": key]
        ]
        let data = try JSONSerialization.data(withJSONObject: keys)
        try data.write(to: keysURL)

        let reader = WeChatReader(
            keysPath: keysURL.path,
            dbDir: root.appendingPathComponent("db").path,
            cacheStrategy: .memory
        )
        try reader.loadKeys()
        let source = ContactRecommendationScanSource(reader: reader)

        XCTAssertThrowsError(try source.readMessages(chatUsername: "wxid_missing", limit: 5)) { error in
            guard case ReaderError.dbNotFound = error else {
                return XCTFail("expected missing database error, got \(error)")
            }
        }
    }

    func testScanMissingKeysOrDatabaseDoesNotBecomeEmptyCandidates() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("recommendation-source-missing-\(UUID().uuidString)")
        let reader = WeChatReader(
            keysPath: root.appendingPathComponent("missing-keys.json").path,
            dbDir: root.appendingPathComponent("missing-db").path,
            cacheStrategy: .memory
        )
        let source = ContactRecommendationScanSource(reader: reader)

        do {
            _ = try await source.scan(limit: 10, messageLimit: 5)
            XCTFail("missing keys/database must fail candidate loading")
        } catch is ReaderError {
            // Expected: the strict candidate source preserves the reader failure.
        }
    }

    func testScanWithValidEmptyContactDatabaseReturnsEmptyCandidates() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("recommendation-source-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("contact"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let plain = root.appendingPathComponent("contact-plain.sqlite")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(plain.path, &db), SQLITE_OK)
        var reserve: Int32 = 80
        XCTAssertEqual(sqlite3_file_control(db, nil, SQLITE_FCNTL_RESERVE_BYTES, &reserve), SQLITE_OK)
        XCTAssertEqual(
            sqlite3_exec(
                db,
                "PRAGMA page_size=4096; VACUUM; CREATE TABLE contact(username TEXT, nick_name TEXT, remark TEXT)",
                nil,
                nil,
                nil
            ),
            SQLITE_OK
        )
        sqlite3_close(db)

        let key = Data(repeating: 0x44, count: 32)
        let encrypted = root.appendingPathComponent("contact/contact.db")
        let keysURL = root.appendingPathComponent("keys.json")
        try encrypt(plain, to: encrypted, key: key)
        let keyJSON = [
            "contact/contact.db": ["enc_key": key.map { String(format: "%02x", $0) }.joined()]
        ]
        try JSONSerialization.data(withJSONObject: keyJSON).write(to: keysURL)

        let reader = WeChatReader(keysPath: keysURL.path, dbDir: root.path, cacheStrategy: .memory)
        let source = ContactRecommendationScanSource(reader: reader)
        let result = try await source.scan(limit: 10, messageLimit: 5)

        XCTAssertTrue(result.candidates.isEmpty)
        XCTAssertTrue(result.messageBundles.isEmpty)
        XCTAssertTrue(result.failures.isEmpty)
    }

    func testCancellationStopsReadingLaterMessagesAndProgress() async throws {
        let candidates = (0..<20).map { index in
            ContactRecommendationScanSource.Candidate(
                username: "chat_\(index)", displayName: "联系人\(index)", isGroup: false, recentCount: 1
            )
        }
        let firstRead = expectation(description: "first message read")
        let firstProgress = expectation(description: "first progress")
        let progressGate = DispatchSemaphore(value: 0)
        let tracker = ReadTracker()
        let source = ContactRecommendationScanSource(
            readCandidates: { _ in candidates },
            readMessages: { username, _ in
                tracker.recordRead(username)
                if username == "chat_0" { firstRead.fulfill() }
                Thread.sleep(forTimeInterval: 0.01)
                return [ContactRecommendationScanSource.Message(sender: "对方", body: "消息")]
            }
        )
        let task = Task {
            try await source.scan(limit: 20, messageLimit: 5) { progress in
                tracker.recordProgress()
                if progress.completed == 1 {
                    firstProgress.fulfill()
                    progressGate.wait()
                }
            }
        }

        await fulfillment(of: [firstRead, firstProgress], timeout: 1)
        let beforeCancel = tracker.snapshot()
        task.cancel()
        progressGate.signal()

        do {
            _ = try await task.value
            XCTFail("cancelled scan should not return a result")
        } catch is CancellationError {
            // Expected: the detached worker propagates cancellation.
        }
        let afterCancel = tracker.snapshot()
        XCTAssertEqual(beforeCancel.reads, ["chat_0"])
        XCTAssertEqual(afterCancel.reads, beforeCancel.reads)
        XCTAssertEqual(afterCancel.progressCount, beforeCancel.progressCount)
    }

    private func encrypt(_ plain: URL, to encrypted: URL, key: Data) throws {
        let data = try Data(contentsOf: plain)
        XCTAssertEqual(data[20], 80)
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
                                CCOperation(kCCEncrypt),
                                CCAlgorithm(kCCAlgorithmAES),
                                0,
                                keyBytes.baseAddress,
                                32,
                                vector.baseAddress,
                                source.baseAddress,
                                bytes.count,
                                destination.baseAddress,
                                bytes.count,
                                &written
                            )
                        }
                    }
                }
            }
            XCTAssertEqual(status, CCCryptorStatus(kCCSuccess))
            if first { output += Data(repeating: 0x11, count: 16) }
            output += cipher + iv + Data(count: 64)
        }
        try output.write(to: encrypted, options: .atomic)
    }
}
