import Foundation
import XCTest
@testable import WeChatHUD

/// Migration rules for AIConfig: legacy dual-slot (cloud/local + activeMode)
/// and single-provider JSON must decode into the single `provider` slot.
final class AIConfigMigrationTests: XCTestCase {
    private func decode(_ json: String) throws -> AIConfig {
        let data = try XCTUnwrap(json.data(using: .utf8))
        return try JSONDecoder().decode(AIConfig.self, from: data)
    }

    private func legacyDualSlotJSON(
        cloud: AIProviderSlot? = nil,
        local: AIProviderSlot? = nil,
        mode: String,
        autoCloudFirst: Bool? = nil
    ) -> String {
        var parts: [String] = []
        if let cloud {
            parts.append("""
                "cloudProvider": {
                    "providerID": "\(cloud.providerID)",
                    "baseURL": "\(cloud.baseURL)",
                    "model": "\(cloud.model)",
                    "apiKey": "\(cloud.apiKey)"
                }
            """)
        }
        if let local {
            parts.append("""
                "localProvider": {
                    "providerID": "\(local.providerID)",
                    "baseURL": "\(local.baseURL)",
                    "model": "\(local.model)",
                    "apiKey": "\(local.apiKey)"
                }
            """)
        }
        parts.append("\"activeMode\": \"\(mode)\"")
        if let autoCloudFirst {
            parts.append("\"autoCloudFirst\": \(autoCloudFirst)")
        }
        return "{ " + parts.joined(separator: ", ") + " }"
    }

    func testCloudPrimarySlotBecomesProvider() throws {
        let cfg = try decode(legacyDualSlotJSON(
            cloud: AIProviderSlot(providerID: "deepseek", baseURL: "https://api.deepseek.com", model: "deepseek-chat", apiKey: "k1"),
            local: AIProviderSlot(providerID: "custom", baseURL: "http://127.0.0.1:8000/v1", model: "local-model"),
            mode: "cloud"
        ))
        XCTAssertEqual(cfg.provider.providerID, "deepseek")
        XCTAssertEqual(cfg.provider.baseURL, "https://api.deepseek.com")
        XCTAssertEqual(cfg.provider.model, "deepseek-chat")
        XCTAssertEqual(cfg.provider.apiKey, "k1")
    }

    func testLocalPrimarySlotBecomesProvider() throws {
        let cfg = try decode(legacyDualSlotJSON(
            cloud: AIProviderSlot(providerID: "deepseek", baseURL: "https://api.deepseek.com", model: "deepseek-chat"),
            local: AIProviderSlot(providerID: "ollama", baseURL: "http://127.0.0.1:11434", model: "qwen2.5:14b"),
            mode: "local"
        ))
        XCTAssertEqual(cfg.provider.providerID, "ollama")
        XCTAssertEqual(cfg.provider.baseURL, "http://127.0.0.1:11434")
        XCTAssertEqual(cfg.provider.model, "qwen2.5:14b")
    }

    func testAutoModeWithCloudFirstPicksCloudSlot() throws {
        let cfg = try decode(legacyDualSlotJSON(
            cloud: AIProviderSlot(providerID: "deepseek", baseURL: "https://api.deepseek.com", model: "deepseek-chat"),
            local: AIProviderSlot(providerID: "ollama", baseURL: "http://127.0.0.1:11434", model: "qwen2.5:14b"),
            mode: "auto",
            autoCloudFirst: true
        ))
        XCTAssertEqual(cfg.provider.providerID, "deepseek")
    }

    func testAutoModeWithLocalFirstPicksLocalSlot() throws {
        let cfg = try decode(legacyDualSlotJSON(
            cloud: AIProviderSlot(providerID: "deepseek", baseURL: "https://api.deepseek.com", model: "deepseek-chat"),
            local: AIProviderSlot(providerID: "ollama", baseURL: "http://127.0.0.1:11434", model: "qwen2.5:14b"),
            mode: "auto",
            autoCloudFirst: false
        ))
        XCTAssertEqual(cfg.provider.providerID, "ollama")
    }

    func testEmptyPrimarySlotFallsBackToOtherConfiguredSlot() throws {
        let cfg = try decode(legacyDualSlotJSON(
            cloud: AIProviderSlot(providerID: "deepseek", baseURL: "", model: ""),
            local: AIProviderSlot(providerID: "custom", baseURL: "http://127.0.0.1:8000/v1", model: "local-model"),
            mode: "cloud"
        ))
        XCTAssertEqual(cfg.provider.providerID, "custom")
        XCTAssertEqual(cfg.provider.baseURL, "http://127.0.0.1:8000/v1")
    }

    func testCodexSlotCountsAsConfiguredDespiteEmptyBaseURL() throws {
        let cfg = try decode(legacyDualSlotJSON(
            cloud: AIProviderSlot(providerID: "openai-codex", baseURL: "", model: "gpt-5.4"),
            mode: "cloud"
        ))
        XCTAssertEqual(cfg.provider.providerID, "openai-codex")
        XCTAssertEqual(cfg.provider.model, "gpt-5.4")
    }

    func testLegacySingleProviderFieldsMigrateIntoProvider() throws {
        let cfg = try decode("""
        {
            "baseURL": "http://127.0.0.1:8000/v1",
            "model": "Qwen3.5-27B-6bit",
            "apiKey": "legacy-secret",
            "providerID": "custom"
        }
        """)
        XCTAssertEqual(cfg.provider.providerID, "custom")
        XCTAssertEqual(cfg.provider.baseURL, "http://127.0.0.1:8000/v1")
        XCTAssertEqual(cfg.provider.model, "Qwen3.5-27B-6bit")
        XCTAssertEqual(cfg.provider.apiKey, "legacy-secret")
    }

    func testUnreadableActiveModeFallsBackToLocalSlot() throws {
        let cfg = try decode(legacyDualSlotJSON(
            cloud: AIProviderSlot(providerID: "deepseek", baseURL: "https://api.deepseek.com", model: "deepseek-chat"),
            local: AIProviderSlot(providerID: "ollama", baseURL: "http://127.0.0.1:11434", model: "qwen2.5:14b"),
            mode: "corrupted-mode-value"
        ))
        XCTAssertEqual(cfg.provider.providerID, "ollama")
        XCTAssertEqual(cfg.provider.baseURL, "http://127.0.0.1:11434")
    }

    func testEncodingWritesOnlyNewProviderKey() throws {
        let cfg = try decode(legacyDualSlotJSON(
            cloud: AIProviderSlot(providerID: "deepseek", baseURL: "https://api.deepseek.com", model: "deepseek-chat"),
            local: AIProviderSlot(providerID: "ollama", baseURL: "http://127.0.0.1:11434", model: "qwen2.5:14b"),
            mode: "cloud"
        ))
        let data = try JSONEncoder().encode(cfg)
        let roundTrip = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(roundTrip["provider"])
        for legacyKey in ["cloudProvider", "localProvider", "activeMode", "autoCloudFirst", "baseURL", "model", "apiKey", "providerID"] {
            XCTAssertNil(roundTrip[legacyKey], "legacy key \(legacyKey) must not be written")
        }

        // The re-encoded config decodes to the same provider.
        let decoded = try JSONDecoder().decode(AIConfig.self, from: data)
        XCTAssertEqual(decoded.provider, cfg.provider)
    }

    func testNewConfigRoundTripKeepsProviderAndCapabilities() throws {
        var cfg = AIConfig()
        cfg.provider = AIProviderSlot(providerID: "kimicode", baseURL: "https://api.kimi.com/coding/v1", model: "kimi-for-coding", apiKey: "k")
        cfg.thinkingEnabled = true
        cfg.maxTokens = 4096
        let data = try JSONEncoder().encode(cfg)
        let decoded = try JSONDecoder().decode(AIConfig.self, from: data)
        XCTAssertEqual(decoded.provider, cfg.provider)
        XCTAssertTrue(decoded.thinkingEnabled)
        XCTAssertEqual(decoded.maxTokens, 4096)
        XCTAssertEqual(decoded.baseURL, "https://api.kimi.com/coding/v1")
        XCTAssertEqual(decoded.model, "kimi-for-coding")
    }
}
