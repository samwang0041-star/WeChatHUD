import XCTest
@testable import WeChatHUD

final class AISettingsValidationTests: XCTestCase {
    func testCustomLocalServiceNeedsNoKey() {
        let slot = AIProviderSlot(baseURL: "http://127.0.0.1:11434/v1", model: "local-model")
        XCTAssertNil(AISettingsValidation.connectionError(slot, requireModel: true))
    }

    func testConnectionRequiresModelButDiscoveryDoesNot() {
        let slot = AIProviderSlot(baseURL: "http://localhost:8000")
        XCTAssertNotNil(AISettingsValidation.connectionError(slot, requireModel: true))
        XCTAssertNil(AISettingsValidation.connectionError(slot, requireModel: false))
    }

    func testRejectsNonHTTPAndCredentialURLs() {
        for address in ["file:///tmp/model", "localhost:8000", "https://key:secret@example.com"] {
            let slot = AIProviderSlot(baseURL: address, model: "model")
            XCTAssertNotNil(AISettingsValidation.connectionError(slot, requireModel: true))
        }
    }

    func testBuiltInCloudRequiresKeyAndCodexUsesLogin() {
        let cloud = AIProviderSlot(providerID: "deepseek", baseURL: "https://api.deepseek.com", model: "deepseek-chat")
        XCTAssertNotNil(AISettingsValidation.connectionError(cloud, requireModel: true))
        let codex = AIProviderSlot(providerID: "openai-codex", model: "gpt-5.4")
        XCTAssertNil(AISettingsValidation.connectionError(codex, requireModel: true))
    }

    func testBackendErrorBodiesNeverLeakCredentials() {
        let fixture = "private-key"
        for error: Error in [AIError.requestFailed(fixture), AIError.parseFailed(fixture), CodexError.backendError(fixture), CodexError.authRefreshFailed(fixture)] {
            let result = AISettingsValidation.connectionFailure(error)
            XCTAssertFalse(result.contains(fixture))
            XCTAssertFalse(result.isEmpty)
        }
    }

    func testNetworkFailureGivesRecoveryAction() {
        XCTAssertTrue(AISettingsValidation.connectionFailure(URLError(.cannotConnectToHost)).contains("本地服务"))
        XCTAssertTrue(AISettingsValidation.connectionFailure(URLError(.timedOut)).contains("超时"))
    }

    /// Every server rejection used to be reported as "check your API Key",
    /// which contradicted the credential check that had just passed. The
    /// guidance is now chosen from the HTTP status, without echoing the body.
    func testRequestFailureGuidanceDistinguishesStatusCodes() {
        let modelNotFound = AISettingsValidation.requestFailureGuidance(
            #"HTTP 404: {"error":{"message":"model not found"}}"#
        )
        XCTAssertTrue(modelNotFound.contains("404"))
        XCTAssertFalse(modelNotFound.contains("API Key"), "a wrong model name is not a credential problem")

        XCTAssertTrue(AISettingsValidation.requestFailureGuidance("HTTP 429: slow down").contains("429"))
        XCTAssertTrue(AISettingsValidation.requestFailureGuidance("HTTP 401: unauthorized").contains("API Key"))
        XCTAssertTrue(AISettingsValidation.requestFailureGuidance("HTTP 500: oops").contains("500"))
        XCTAssertFalse(
            AISettingsValidation.requestFailureGuidance(#"HTTP 400: {"error":"bad params"}"#).contains("bad params"),
            "server bodies must not be echoed — they can carry credentials or message text"
        )
        XCTAssertEqual(
            AISettingsValidation.requestFailureGuidance("AI model is empty for provider deepseek"),
            "请选择一个模型。"
        )
        XCTAssertTrue(
            AISettingsValidation.requestFailureGuidance("something unexpected").contains("服务返回错误")
        )
    }
}
