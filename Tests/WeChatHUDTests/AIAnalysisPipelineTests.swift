import XCTest
@testable import WeChatHUD

/// The shared pipeline is where every AI-backed feature's failures land.
///
/// It used to collapse every error into `nil` plus the audit string "AI call
/// failed", and to treat any decodable JSON object as success — so an all-empty
/// answer was cached as a real analysis and the strict retry never ran.
final class AIAnalysisPipelineTests: XCTestCase {
    private struct Payload: Decodable, Equatable {
        let waiting: [String]
    }

    private struct Boom: Error, CustomStringConvertible {
        var description: String { "HTTP 429: quota exhausted" }
    }

    private func makeStore() throws -> HUDStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wchud-pipeline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = HUDStore(dbPath: dir.appendingPathComponent("hud.sqlite3").path)
        try store.open()
        return store
    }

    private func configuration() -> AIAnalysisPipeline.Configuration {
        AIAnalysisPipeline.Configuration(
            options: CompleteOptions(timeout: 5, temperature: 0.2, maxTokens: 64, responseFormatJSON: true),
            auditRole: .contextAnalyzer,
            promptVersion: "test_v1",
            inputSummary: "[test] pipeline",
            trackLabel: "测试"
        )
    }

    func testProviderErrorDetailReachesTheAuditRow() async throws {
        let store = try makeStore()
        defer { store.close() }
        let mock = MockAIService()
        await mock.setShouldThrow(Boom())
        let pipeline = AIAnalysisPipeline(aiService: mock, store: store)

        let result = await pipeline.execute(
            prompt: "hi", configuration: configuration(), decodeAs: Payload.self
        )

        XCTAssertNil(result)
        let audit = store.loadRecentAIAudit(limit: 5, promptVersionPrefix: "test_v1")
        XCTAssertEqual(audit.count, 1)
        XCTAssertEqual(audit.first?.status, .httpError)
        let message = try XCTUnwrap(audit.first?.errorMessage)
        XCTAssertTrue(
            message.contains("HTTP 429"),
            "the provider's own words are what make a failure actionable: \(message)"
        )
    }

    /// A reply that decodes but carries nothing is not a success: callers cache
    /// whatever comes back, so `{}` used to be stored as a valid analysis.
    func testEmptyPayloadIsNotAcceptedAsSuccess() async throws {
        let store = try makeStore()
        defer { store.close() }
        let mock = MockAIService()
        await mock.setDefaultResponse(#"{"waiting":[]}"#)
        let pipeline = AIAnalysisPipeline(aiService: mock, store: store)

        let result = await pipeline.execute(
            prompt: "hi",
            configuration: configuration(),
            decodeAs: Payload.self,
            isUsable: { !$0.waiting.isEmpty }
        )

        XCTAssertNil(result)
        let audit = store.loadRecentAIAudit(limit: 5, promptVersionPrefix: "test_v1")
        XCTAssertEqual(audit.first?.status, .parseError)
        XCTAssertEqual(audit.first?.errorMessage, "JSON parse failed after retry")
        let calls = await mock.calls.count
        XCTAssertEqual(calls, 2, "an empty answer must trigger the strict retry")
    }

    func testUsablePayloadIsReturnedAndAudited() async throws {
        let store = try makeStore()
        defer { store.close() }
        let mock = MockAIService()
        await mock.setDefaultResponse(#"{"waiting":["回林总"]}"#)
        let pipeline = AIAnalysisPipeline(aiService: mock, store: store)

        let result = await pipeline.execute(
            prompt: "hi",
            configuration: configuration(),
            decodeAs: Payload.self,
            isUsable: { !$0.waiting.isEmpty }
        )

        XCTAssertEqual(result?.value, Payload(waiting: ["回林总"]))
        let audit = store.loadRecentAIAudit(limit: 5, promptVersionPrefix: "test_v1")
        XCTAssertEqual(audit.first?.status, .ok)
    }
}
