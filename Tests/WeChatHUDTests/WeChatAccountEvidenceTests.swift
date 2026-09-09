import XCTest
@testable import WeChatHUD

final class WeChatAccountEvidenceTests: XCTestCase {
    private let rootA = "/tmp/synthetic/xwechat_files/account-a/db_storage"
    private let rootB = "/tmp/synthetic/xwechat_files/account-b/db_storage"

    private func capture(_ fields: [String], succeeded: Bool = true, timedOut: Bool = false, exceededLimit: Bool = false) -> WeChatAccountEvidence.Capture {
        .init(data: Data((fields.joined(separator: "\0") + "\0\n").utf8), succeeded: succeeded, timedOut: timedOut, exceededLimit: exceededLimit)
    }

    func testUniqueMatchingOpenDatabaseFilesAuthorizeOnlyExpectedAccount() {
        let output = capture(["p42", "f3", "tREG", "n\(rootA)/session/session.db", "f4", "tREG", "n\(rootA)/message/message_0.db-wal"])
        XCTAssertEqual(WeChatAccountEvidence.evaluate(output, processID: 42, expectedRoot: rootA), .verified)
        XCTAssertEqual(WeChatAccountEvidence.evaluate(output, processID: 42, expectedRoot: rootB), .mismatch)
    }

    func testTwoAccountRootsAreAmbiguousEvenWhenOneMatches() {
        let output = capture(["p42", "f3", "tREG", "n\(rootA)/session/session.db", "f4", "tREG", "n\(rootB)/session/session.db"])
        XCTAssertEqual(WeChatAccountEvidence.evaluate(output, processID: 42, expectedRoot: rootA), .unverified)
    }

    func testMissingEvidenceSocketsAndCommentsNeverAuthorize() {
        for output in [
            capture(["p42", "f3", "tIPv4", "n127.0.0.1:443"]),
            capture(["p42", "f3", "tunix", "n\(rootA)/socket.db"]),
            capture(["p42", "f3", "tREG", "n\(rootA)/session/session.db (deleted)"]),
            capture(["p42", "f3", "tREG", "n\(rootA)/other.txt"]),
            capture(["p42"])
        ] {
            XCTAssertEqual(WeChatAccountEvidence.evaluate(output, processID: 42, expectedRoot: rootA), .unverified)
        }
    }

    func testDifferentPIDOrUnscopedNameCannotAuthorize() {
        for output in [
            capture(["p43", "f3", "tREG", "n\(rootA)/session/session.db"]),
            capture(["f3", "tREG", "n\(rootA)/session/session.db"]),
            capture(["p42", "n\(rootA)/session/session.db"]),
            capture(["p42", "f3", "tREG", "n\(rootA)/session/session.db", "p43"])
        ] {
            XCTAssertEqual(WeChatAccountEvidence.evaluate(output, processID: 42, expectedRoot: rootA), .unverified)
        }
    }

    func testObservedRootsRetainsOnlyUniqueDatabaseRootsAndRejectsWrongPID() {
        let output = capture([
            "p42", "f3", "tREG", "n\(rootA)/session/session.db",
            "f4", "tREG", "n\(rootA)/message/message_0.db"
        ])
        XCTAssertEqual(WeChatAccountEvidence.observedRoots(output, processID: 42), [rootA])

        let ambiguous = capture([
            "p42", "f3", "tREG", "n\(rootA)/session/session.db",
            "f4", "tREG", "n\(rootB)/session/session.db"
        ])
        XCTAssertEqual(WeChatAccountEvidence.observedRoots(ambiguous, processID: 42), [rootA, rootB])

        let wrongPID = capture(["p43", "f3", "tREG", "n\(rootA)/session/session.db"])
        XCTAssertNil(WeChatAccountEvidence.observedRoots(wrongPID, processID: 42))
    }

    func testTimeoutPartialFailureOrOutputCapCannotAuthorize() {
        let fields = ["p42", "f3", "tREG", "n\(rootA)/session/session.db"]
        for output in [capture(fields, succeeded: false), capture(fields, timedOut: true), capture(fields, exceededLimit: true)] {
            XCTAssertEqual(WeChatAccountEvidence.evaluate(output, processID: 42, expectedRoot: rootA), .unverified)
        }
        let truncated = WeChatAccountEvidence.Capture(data: Data(fields.joined(separator: "\0").utf8), succeeded: true, timedOut: false, exceededLimit: false)
        XCTAssertEqual(WeChatAccountEvidence.evaluate(truncated, processID: 42, expectedRoot: rootA), .unverified)
    }

    func testNULFieldParsingPreservesSpacesInAccountPath() {
        let spaced = "/tmp/synthetic test/xwechat_files/account a/db_storage"
        let output = capture(["p42", "f3", "tREG", "n\(spaced)/session/session.db"])
        XCTAssertEqual(WeChatAccountEvidence.evaluate(output, processID: 42, expectedRoot: spaced), .verified)
    }

    func testSamePIDWithDifferentLaunchDateIsRejected() {
        let launch = Date(timeIntervalSince1970: 100)
        XCTAssertTrue(WeChatAccountEvidence.processMatches(expectedPID: 42, expectedLaunch: launch, actualPID: 42, actualLaunch: launch, terminated: false))
        XCTAssertFalse(WeChatAccountEvidence.processMatches(expectedPID: 42, expectedLaunch: launch, actualPID: 42, actualLaunch: launch.addingTimeInterval(1), terminated: false))
        XCTAssertFalse(WeChatAccountEvidence.processMatches(expectedPID: 42, expectedLaunch: launch, actualPID: 43, actualLaunch: launch, terminated: false))
        XCTAssertFalse(WeChatAccountEvidence.processMatches(expectedPID: 42, expectedLaunch: launch, actualPID: 42, actualLaunch: launch, terminated: true))
        XCTAssertFalse(WeChatAccountEvidence.processMatches(expectedPID: 42, expectedLaunch: launch, actualPID: 42, actualLaunch: nil, terminated: false))
    }
    func testBoundedLsofProbeAgainstOnlySyntheticFileInThisTestProcess() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("account-proof-\(UUID())/db_storage")
        let directory = root.appendingPathComponent("session")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("session.db")
        try Data("synthetic test database placeholder".utf8).write(to: file)
        let handle = try FileHandle(forReadingFrom: file)
        defer {
            try? handle.close()
            try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
        }
        // Never inspect or operate a real WeChat process in tests.
        let verdict = await WeChatAccountEvidence.inspect(processID: getpid(), expectedRoot: root.path)
        XCTAssertEqual(verdict, .verified)
    }

}
