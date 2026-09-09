import XCTest
@testable import WeChatHUD

final class AICapabilityPersistenceTests: XCTestCase {
    func testDisabledDailyReportInsightsSurvivePersistence() throws {
        let store = HUDStore(dbPath: ":memory:")
        try store.open()
        defer { store.close() }
        var config = store.loadAIConfig()
        config.dailyReportActionInsightsEnabled = false
        config.moodDetectionEnabled = false
        try store.setSettingJSON("ai", value: config)
        let restored = store.loadAIConfig()
        XCTAssertFalse(restored.dailyReportActionInsightsEnabled)
        XCTAssertFalse(restored.moodDetectionEnabled)
    }

    func testOlderConfigurationRetainsDefaultDailyReportCapability() throws {
        let config = try JSONDecoder().decode(AIConfig.self, from: Data("{}".utf8))
        XCTAssertTrue(config.dailyReportActionInsightsEnabled)
    }
}
