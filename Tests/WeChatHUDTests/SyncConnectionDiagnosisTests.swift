import XCTest
@testable import WeChatHUD

final class SyncConnectionDiagnosisTests: XCTestCase {
    private func diagnosis(_ path: String, candidates: [String], exists: Bool = true, readable: Bool = true, containsDatabase: Bool = true) -> SyncConnectionDiagnosis {
        SyncConnectionDiagnosis.evaluate(configuredPath: path, candidates: candidates,
                                         exists: { _ in exists }, readable: { _ in readable }, containsDatabase: { _ in containsDatabase })
    }

    func testMultipleDirectoriesNeverSelectAnAccountAutomatically() {
        XCTAssertEqual(diagnosis("auto", candidates: ["/account-a/db_storage", "/account-b/db_storage"]), .needsAccountSelection(2))
        XCTAssertEqual(diagnosis("", candidates: ["/account-a/db_storage", "/account-b/db_storage"]), .needsAccountSelection(2))
    }

    func testExplicitSelectionWinsOverDiscoveryOrder() {
        let selected = "/account-b/db_storage"
        XCTAssertEqual(diagnosis(selected, candidates: ["/account-a/db_storage", selected]), .ready(selected))
        XCTAssertEqual(diagnosis(selected, candidates: [selected, "/account-a/db_storage"]), .ready(selected))
    }

    func testMissingConfiguredDirectoryNeverFallsBackToAnotherAccount() {
        XCTAssertEqual(diagnosis("/missing/db_storage", candidates: ["/other/db_storage"], exists: false), .directoryMissing)
    }

    func testOnlyUniqueCandidateCanAutoConnect() {
        XCTAssertEqual(diagnosis("auto", candidates: []), .noCandidate)
        XCTAssertEqual(diagnosis("auto", candidates: ["/only/db_storage"]), .ready("/only/db_storage"))
    }

    func testUnreadableDirectoryAndWrongFolderHaveDifferentGuidance() {
        XCTAssertEqual(diagnosis("/account/db_storage", candidates: [], readable: false), .directoryUnreadable)
        XCTAssertEqual(diagnosis("/account", candidates: [], containsDatabase: false), .noDatabaseFiles)
    }

    func testCustomerMessagesAvoidInternalFolderNames() {
        let messages = [
            SyncConnectionDiagnosis.noCandidate.message,
            SyncConnectionDiagnosis.needsAccountSelection(2).message,
            SyncConnectionDiagnosis.directoryMissing.message,
            SyncConnectionDiagnosis.directoryUnreadable.message,
            SyncConnectionDiagnosis.noDatabaseFiles.message,
            SyncConnectionDiagnosis.ready("/account").message
        ]
        for message in messages {
            XCTAssertFalse(message.contains("db_storage"), message)
            XCTAssertFalse(message.contains("白名单"), message)
        }
    }
}
