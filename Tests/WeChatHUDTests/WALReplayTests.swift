import XCTest
import SQLite3
@testable import WeChatHUD

final class WALReplayTests: XCTestCase {
    private let pageSize = 4096

    private func word(_ value: UInt32) -> Data {
        var big = value.bigEndian
        return withUnsafeBytes(of: &big) { Data($0) }
    }

    private func checksum(_ bytes: Data, _ seed: (UInt32, UInt32), big: Bool) -> (UInt32, UInt32) {
        var values: [UInt32] = []
        for i in stride(from: 0, to: bytes.count, by: 4) {
            let b = Array(bytes[i..<i + 4])
            values.append(big ? UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
                              : UInt32(b[3]) << 24 | UInt32(b[2]) << 16 | UInt32(b[1]) << 8 | UInt32(b[0]))
        }
        var (a, b) = seed
        for i in stride(from: 0, to: values.count, by: 2) {
            a = a &+ values[i] &+ b
            b = b &+ values[i + 1] &+ a
        }
        return (a, b)
    }

    private func wal(_ frames: [(page: UInt32, commit: UInt32)], big: Bool = false) -> Data {
        var data = word(big ? 0x377f0683 : 0x377f0682) + word(3_007_000) + word(UInt32(pageSize)) + word(0) + word(11) + word(22)
        var sum = checksum(data, (0, 0), big: big)
        data += word(sum.0) + word(sum.1)
        for frame in frames {
            let prefix = word(frame.page) + word(frame.commit)
            let page = Data(repeating: UInt8(truncatingIfNeeded: frame.page), count: pageSize)
            sum = checksum(prefix + page, sum, big: big)
            data += prefix + word(11) + word(22) + word(sum.0) + word(sum.1) + page
        }
        return data
    }

    func testOnlyCommittedPrefixIsReplayed() throws {
        let plan = try WALReplay.plan(wal([(1, 0), (2, 2), (1, 0)]), expectedPageSize: pageSize)
        XCTAssertEqual(plan.frames.map(\.pageNumber), [1, 2])
        XCTAssertEqual(plan.databasePageCount, 2)
    }

    func testUncommittedTransactionProducesNoChanges() throws {
        let plan = try WALReplay.plan(wal([(1, 0), (2, 0)]), expectedPageSize: pageSize)
        XCTAssertTrue(plan.frames.isEmpty)
        XCTAssertNil(plan.databasePageCount)
    }

    func testChecksumFailureStopsAtLastCommit() throws {
        var data = wal([(1, 1), (2, 2), (3, 3)])
        data[32 + 24 + pageSize + 24 + 4] ^= 0xff
        let plan = try WALReplay.plan(data, expectedPageSize: pageSize)
        XCTAssertEqual(plan.frames.map(\.pageNumber), [1])
        XCTAssertEqual(plan.databasePageCount, 1)
    }

    func testSaltChangeStopsRatherThanSkippingToLaterFrames() throws {
        var data = wal([(1, 1), (2, 2), (3, 3)])
        data[32 + 24 + pageSize + 8] ^= 1
        XCTAssertEqual(try WALReplay.plan(data, expectedPageSize: pageSize).frames.map(\.pageNumber), [1])
    }

    func testZeroPageAndPartialFrameNeverReplay() throws {
        XCTAssertTrue(try WALReplay.plan(wal([(0, 1)]), expectedPageSize: pageSize).frames.isEmpty)
        let data = wal([(1, 1), (2, 2)]).dropLast(10)
        XCTAssertEqual(try WALReplay.plan(Data(data), expectedPageSize: pageSize).frames.map(\.pageNumber), [1])
    }

    func testBothChecksumByteOrdersAndHeaderValidation() throws {
        for big in [false, true] {
            XCTAssertEqual(try WALReplay.plan(wal([(1, 1)], big: big), expectedPageSize: pageSize).databasePageCount, 1)
        }
        var invalid = wal([(1, 1)])
        invalid[24] ^= 1
        XCTAssertThrowsError(try WALReplay.plan(invalid, expectedPageSize: pageSize))
        XCTAssertThrowsError(try WALReplay.plan(Data([1, 2]), expectedPageSize: pageSize))
        XCTAssertThrowsError(try WALReplay.plan(wal([(1, 1)]), expectedPageSize: 512))
    }

    func testReplayGrowsAndShrinksCacheAtomically() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("cache.db")
        let source = root.appendingPathComponent("source-wal")
        try Data(repeating: 0, count: pageSize).write(to: database)
        let key = Data(repeating: 1, count: 32)
        try wal([(2, 2)]).write(to: source)
        try WeChatDecryptor.applyWAL(dbPath: database.path, walPath: source.path, key: key)
        let grown = try Data(contentsOf: database)
        XCTAssertEqual(grown.count, pageSize * 2)
        let expected = try WeChatDecryptor.decryptPage(Data(repeating: 2, count: pageSize), key: key, isFirstPage: false)
        XCTAssertEqual(Data(grown.suffix(pageSize)), expected)
        try wal([(1, 1)]).write(to: source)
        try WeChatDecryptor.applyWAL(dbPath: database.path, walPath: source.path, key: key)
        XCTAssertEqual(try Data(contentsOf: database).count, pageSize)
    }

    func testAuthenticSQLiteWALPassesChecksumValidation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("real.db").path
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "PRAGMA page_size=4096; PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; CREATE TABLE t(x); INSERT INTO t VALUES(42)", nil, nil, nil), SQLITE_OK)
        let data = try Data(contentsOf: URL(fileURLWithPath: path + "-wal"))
        let plan = try WALReplay.plan(data, expectedPageSize: pageSize)
        XCTAssertFalse(plan.frames.isEmpty)
        XCTAssertEqual(plan.databasePageCount, 2)
    }
}
