import XCTest
@testable import WeChatHUD

final class ConnectionSetupPolicyTests: XCTestCase {
    func testAccountSelectionNeededWhenConfiguredReaderRootIsAccountSwitched() {
        XCTAssertTrue(ConnectionSetupPolicy.needsAccountSelection(
            selectedRoot: "/wechat/account-a/db_storage",
            readerRoot: "/wechat/account-a/./db_storage",
            syncStatus: .accountSwitched
        ))
    }

    func testNewlyChosenRootDoesNotInheritStaleAccountSwitchedStatus() {
        XCTAssertFalse(ConnectionSetupPolicy.needsAccountSelection(
            selectedRoot: "/wechat/account-b/db_storage",
            readerRoot: "/wechat/account-a/db_storage",
            syncStatus: .accountSwitched
        ))
    }

    func testNormalErrorDoesNotMasqueradeAsAccountSwitch() {
        XCTAssertFalse(ConnectionSetupPolicy.needsAccountSelection(
            selectedRoot: "/wechat/account-a/db_storage",
            readerRoot: "/wechat/account-a/db_storage",
            syncStatus: .error("scan failed")
        ))
    }

    func testUpdatingRootPreservesLatestSyncPreferences() {
        var latest = SyncConfig()
        latest.intervalSeconds = 300
        latest.keysFilePath = "/tmp/keys.json"
        latest.cacheStrategy = .persistent
        latest.displayScreen = .external

        let updated = ConnectionSetupFlow.configurationUpdatingRoot(
            "/wechat/account-b/db_storage", from: latest
        )

        XCTAssertEqual(updated.wechatDBPath, "/wechat/account-b/db_storage")
        XCTAssertEqual(updated.intervalSeconds, latest.intervalSeconds)
        XCTAssertEqual(updated.keysFilePath, latest.keysFilePath)
        XCTAssertEqual(updated.cacheStrategy, latest.cacheStrategy)
        XCTAssertEqual(updated.displayScreen, latest.displayScreen)
    }

    func testExplicitRootWinsOverProcessEvidenceAndCandidates() {
        let result = ConnectionSetupPolicy.resolve(
            configuredRoot: "~/wechat/account-a/../account-a/db_storage",
            candidateRoots: ["/wechat/account-b/db_storage"],
            processRoots: ["/wechat/account-b/db_storage"]
        )

        XCTAssertEqual(result, .useConfiguredRoot("/Users/yuriwong/wechat/account-a/db_storage"))
    }

    func testSingleProcessRootIsSelectedOnlyWhenItMatchesCandidate() {
        let result = ConnectionSetupPolicy.resolve(
            configuredRoot: nil,
            candidateRoots: ["/wechat/account-a/db_storage", "/wechat/account-b/db_storage"],
            processRoots: ["/wechat/account-b/./db_storage"]
        )

        XCTAssertEqual(result, .useProcessEvidence("/wechat/account-b/db_storage"))
    }

    func testUniqueCandidateIsSelectedWhenProcessEvidenceIsAmbiguous() {
        let result = ConnectionSetupPolicy.resolve(
            configuredRoot: "auto",
            candidateRoots: ["/wechat/account-a/db_storage"],
            processRoots: ["/wechat/account-a/db_storage", "/wechat/account-b/db_storage"]
        )

        XCTAssertEqual(result, .useUniqueCandidate("/wechat/account-a/db_storage"))
    }

    func testMultipleCandidatesRequireUserSelection() {
        let result = ConnectionSetupPolicy.resolve(
            configuredRoot: "",
            candidateRoots: ["/wechat/account-b/db_storage", "/wechat/account-a/db_storage", "/wechat/account-a/db_storage"],
            processRoots: []
        )

        XCTAssertEqual(result, .needsUserSelection([
            "/wechat/account-a/db_storage",
            "/wechat/account-b/db_storage"
        ]))
    }

    func testNoCandidatesRequireWeChatAccess() {
        let result = ConnectionSetupPolicy.resolve(
            configuredRoot: nil,
            candidateRoots: [],
            processRoots: ["/wechat/account-a/db_storage"]
        )

        XCTAssertEqual(result, .needsWeChatAccess)
    }

    func testProcessEvidenceOutsideCandidatesNeverGetsSelected() {
        let result = ConnectionSetupPolicy.resolve(
            configuredRoot: nil,
            candidateRoots: ["/wechat/account-a/db_storage", "/wechat/account-b/db_storage"],
            processRoots: ["/wechat/unknown/db_storage"]
        )

        XCTAssertEqual(result, .needsUserSelection([
            "/wechat/account-a/db_storage",
            "/wechat/account-b/db_storage"
        ]))
    }

    @MainActor
    func testPrimaryFlowWaitsForVerifiedProcessRootAndPersistsIt() async throws {
        let rootA = "/wechat/account-a/db_storage"
        let rootB = "/wechat/account-b/db_storage"
        var persisted: String?
        var probeFinished = false

        let result = try await ConnectionSetupFlow.prepareRoot(
            configuredRoot: nil,
            candidateRoots: [rootA, rootB],
            processProbe: {
                probeFinished = true
                return [rootB]
            },
            persist: { root in
                XCTAssertTrue(probeFinished)
                persisted = root
            }
        )

        XCTAssertEqual(result, rootB)
        XCTAssertEqual(persisted, rootB)
    }

    @MainActor
    func testPrimaryFlowKeepsExplicitChoiceAndSkipsProcessProbe() async throws {
        var probeCalled = false
        var persistCalled = false

        let result = try await ConnectionSetupFlow.prepareRoot(
            configuredRoot: "~/wechat/account-a/db_storage",
            candidateRoots: ["/wechat/account-b/db_storage"],
            processProbe: {
                probeCalled = true
                return ["/wechat/account-b/db_storage"]
            },
            persist: { _ in persistCalled = true }
        )

        XCTAssertEqual(result, "/Users/yuriwong/wechat/account-a/db_storage")
        XCTAssertFalse(probeCalled)
        XCTAssertFalse(persistCalled)
    }

    @MainActor
    func testPrimaryFlowDoesNotPersistMissingOrAmbiguousEvidence() async throws {
        for observed in [[], ["/wechat/account-a/db_storage", "/wechat/account-b/db_storage"], ["/wechat/unknown/db_storage"]] {
            var persistCalled = false
            let result = try await ConnectionSetupFlow.prepareRoot(
                configuredRoot: nil,
                candidateRoots: ["/wechat/account-a/db_storage", "/wechat/account-b/db_storage"],
                processProbe: { observed },
                persist: { _ in persistCalled = true }
            )
            XCTAssertNil(result)
            XCTAssertFalse(persistCalled)
        }
    }

    @MainActor
    func testPrimaryFlowPropagatesPersistenceFailureBeforeAnyRestartDecision() async {
        enum SaveError: Error { case failed }
        do {
            _ = try await ConnectionSetupFlow.prepareRoot(
                configuredRoot: nil,
                candidateRoots: ["/wechat/account-a/db_storage"],
                processProbe: { ["/wechat/account-a/db_storage"] },
                persist: { _ in throw SaveError.failed }
            )
            XCTFail("Expected persistence failure")
        } catch is SaveError {
            // The caller must stop before attempting the restart.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
