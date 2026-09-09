import XCTest
@testable import WeChatHUD

final class AIConnectionEvidenceTests: XCTestCase {
    private var store: HUDStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        store = HUDStore(dbPath: ":memory:")
        try store.open()
    }

    override func tearDown() {
        store.close()
        super.tearDown()
    }

    func testEvidenceStoresOnlyFingerprintAndResultMetadata() throws {
        let fixture = "no-persist"
        let slot = AIProviderSlot(providerID: "custom", baseURL: "https://ai.example", model: "m1", apiKey: fixture)
        var evidence = AIConnectionEvidence()
        evidence.setResult(for: slot, succeeded: true, at: Date(timeIntervalSince1970: 100))
        try store.saveAIConnectionEvidence(evidence)

        let raw = try XCTUnwrap(store.getSetting(AIConnectionEvidence.settingKey))
        XCTAssertFalse(raw.contains(fixture))
        XCTAssertFalse(raw.contains(slot.baseURL + slot.model))
        XCTAssertEqual(store.loadAIConnectionEvidence().record(for: slot)?.testedAt, Date(timeIntervalSince1970: 100))
    }

    func testFingerprintIsStableAcrossIndependentEncoders() {
        let slot = AIProviderSlot(providerID: "custom", baseURL: "https://ai.example", model: "m1", apiKey: "secret")
        XCTAssertEqual(
            AIConnectionEvidence.fingerprint(for: slot),
            "cbcce143725254f5c4141c6401decbc073db2f8fe189f19573acd23f86715ef1"
        )
        XCTAssertEqual(AIConnectionEvidence.fingerprint(for: slot), AIConnectionEvidence.fingerprint(for: slot))
    }

    func testFingerprintChangeInvalidatesPreviousSuccess() throws {
        let original = AIProviderSlot(providerID: "custom", baseURL: "https://ai.example", model: "m1", apiKey: "secret-1")
        let changed = AIProviderSlot(providerID: "custom", baseURL: "https://ai.example", model: "m2", apiKey: "secret-1")
        var evidence = AIConnectionEvidence()
        evidence.setResult(for: original, succeeded: true)

        XCTAssertNotNil(evidence.record(for: original))
        XCTAssertNil(evidence.record(for: changed))
    }

    func testFailureReplacesEarlierSuccess() throws {
        let slot = AIProviderSlot(providerID: "custom", baseURL: "https://ai.example", model: "m1", apiKey: "secret")
        var evidence = AIConnectionEvidence()
        evidence.setResult(for: slot, succeeded: true, at: Date(timeIntervalSince1970: 100), requestStartedAt: Date(timeIntervalSince1970: 90))
        evidence.setResult(for: slot, succeeded: false, at: Date(timeIntervalSince1970: 200), requestStartedAt: Date(timeIntervalSince1970: 190))

        let result = try XCTUnwrap(evidence.record(for: slot))
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.testedAt, Date(timeIntervalSince1970: 200))
    }

    func testOlderRequestCompletionCannotOverwriteNewerResult() throws {
        let slot = AIProviderSlot(providerID: "custom", baseURL: "https://ai.example", model: "m1", apiKey: "secret")
        var evidence = AIConnectionEvidence()
        XCTAssertTrue(evidence.setResult(for: slot, succeeded: false,
                                         at: Date(timeIntervalSince1970: 210),
                                         requestStartedAt: Date(timeIntervalSince1970: 200)))
        XCTAssertFalse(evidence.setResult(for: slot, succeeded: true,
                                          at: Date(timeIntervalSince1970: 220),
                                          requestStartedAt: Date(timeIntervalSince1970: 100)))

        let result = try XCTUnwrap(evidence.record(for: slot))
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.requestStartedAt, Date(timeIntervalSince1970: 200))
    }

    func testLegacyDualSlotEvidenceRemainsReadable() throws {
        let cloud = AIProviderSlot(providerID: "custom", baseURL: "https://cloud.example", model: "cloud", apiKey: "c")
        var legacy = AIConnectionEvidence()
        legacy.cloud = AIConnectionEvidence.Record(
            fingerprint: AIConnectionEvidence.fingerprint(for: cloud),
            testedAt: Date(timeIntervalSince1970: 100),
            requestStartedAt: Date(timeIntervalSince1970: 90),
            succeeded: true
        )
        XCTAssertNotNil(legacy.record(for: cloud))

        // A new result writes the single provider key and drops legacy records.
        XCTAssertTrue(legacy.setResult(for: cloud, succeeded: false, at: Date(timeIntervalSince1970: 200)))
        XCTAssertNil(legacy.cloud)
        XCTAssertNotNil(legacy.provider)

        try store.saveAIConnectionEvidence(legacy)
        let raw = try XCTUnwrap(store.getSetting(AIConnectionEvidence.settingKey))
        XCTAssertTrue(raw.contains("\"provider\""))
        XCTAssertFalse(raw.contains("\"cloud\""))
        XCTAssertFalse(raw.contains("\"local\""))
    }

    func testNewInstallHasNoEvidence() throws {
        let evidence = store.loadAIConnectionEvidence()
        XCTAssertNil(evidence.provider)
        XCTAssertNil(evidence.cloud)
        XCTAssertNil(evidence.local)
    }
}
