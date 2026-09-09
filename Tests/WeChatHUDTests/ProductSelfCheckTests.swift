import XCTest
@testable import WeChatHUD

final class ProductSelfCheckTests: XCTestCase {
    func testAICheckUsesConfiguredPrimarySlotAndDoesNotExposeSecrets() {
        var config = AIConfig()
        config.provider = AIProviderSlot(
            providerID: "local-provider",
            baseURL: "http://local.invalid",
            model: "local-model",
            apiKey: "local-key"
        )
        var tested: AIProviderSlot?
        let result = ProductSelfCheck.aiCheck(config: config, timeout: 1) { slot in
            tested = slot
            return "OK"
        }

        XCTAssertEqual(tested?.providerID, "local-provider")
        XCTAssertEqual(result["mode"] as? String, "synthetic-ai-check")
        XCTAssertEqual(result["result"] as? String, "success")
        XCTAssertEqual(result["providerID"] as? String, "local-provider")
        XCTAssertNil(result["category"])
        XCTAssertNil(result["apiKey"])
        XCTAssertNil(result["baseURL"])
        XCTAssertNil(result["error"])
    }

    func testAICheckFailureUsesGenericNextStep() {
        var config = AIConfig()
        config.provider = AIProviderSlot(
            providerID: "local-provider",
            baseURL: "http://local.invalid",
            model: "local-model",
            apiKey: "secret"
        )
        let result = ProductSelfCheck.aiCheck(config: config, timeout: 1) { _ in
            throw NSError(domain: "private-provider-error", code: 7)
        }

        XCTAssertEqual(result["result"] as? String, "failed")
        XCTAssertEqual(result["category"] as? String, "unknown")
        XCTAssertNotNil(result["next_step"] as? String)
        XCTAssertNil(result["error"])
        XCTAssertNil(result["apiKey"])
        XCTAssertNil(result["baseURL"])
    }

    func testAICheckHasBoundedTimeoutAndReturnsWithoutProviderError() {
        var config = AIConfig()
        config.provider = AIProviderSlot(
            providerID: "local-provider",
            baseURL: "http://local.invalid",
            model: "local-model"
        )
        let started = Date()
        let result = ProductSelfCheck.aiCheck(config: config, timeout: 0.05) { _ in
            try await Task.sleep(nanoseconds: 10_000_000_000)
            return "late"
        }

        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        XCTAssertEqual(result["result"] as? String, "timeout")
        XCTAssertEqual(result["category"] as? String, "timeout")
        XCTAssertNotNil(result["next_step"] as? String)
        XCTAssertNil(result["error"])
    }

    func testAICheckCategorizesAuthenticationModelAndNetworkWithoutRawError() {
        var config = AIConfig()
        config.provider = AIProviderSlot(providerID: "local", baseURL: "http://local.invalid", model: "model")

        let cases: [(String, Error)] = [
            ("authentication", AIError.requestFailed("HTTP 401: secret payload")),
            ("model", AIError.requestFailed("HTTP 404: model not found")),
            ("network", URLError(.cannotConnectToHost))
        ]
        for (expected, error) in cases {
            let result = ProductSelfCheck.aiCheck(config: config, timeout: 1) { _ in throw error }
            XCTAssertEqual(result["category"] as? String, expected)
            XCTAssertNil(result["error"])
            XCTAssertNil(result["apiKey"])
            XCTAssertNil(result["baseURL"])
        }
    }

    func testDiagnosticSessionCandidatesSkipSystemRowsPrioritizeTrackedAndCapAt100() {
        let sessions = (0..<130).map { index in
            SessionInfo(username: "wxid_\(index)", isGroup: false, unreadCount: 0, lastTimestamp: 0)
        } + [
            SessionInfo(username: "weixin", isGroup: false, unreadCount: 0, lastTimestamp: 9_999),
            SessionInfo(username: "gh_official", isGroup: false, unreadCount: 0, lastTimestamp: 9_998),
            SessionInfo(username: "wxid_0", isGroup: false, unreadCount: 0, lastTimestamp: 1)
        ]

        let candidates = ProductSelfCheck.diagnosticSessionCandidates(
            sessions,
            trackedUsernames: ["wxid_129"]
        )

        XCTAssertEqual(candidates.count, 100)
        XCTAssertEqual(candidates.first?.username, "wxid_129")
        XCTAssertFalse(candidates.contains { $0.username == "weixin" || $0.username == "gh_official" })
        XCTAssertEqual(Set(candidates.map(\.username)).count, candidates.count)
    }
}
