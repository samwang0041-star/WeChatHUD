import XCTest
@testable import WeChatHUD

final class OnboardingReadinessTests: XCTestCase {
    func testReadableKeysAndConfiguredAIDoNotProveSuccessfulSync() {
        let readiness = OnboardingReadiness(directoryReady: true, keyFileReadable: true, hasSuccessfulSync: false,
                                            aiConfigurationValid: true, trackedConversationCount: 1)
        XCTAssertEqual(readiness.remainingActions, [.wechatConnection, .testAI])
        XCTAssertEqual(readiness.remainingSteps, ["完成微信连接", "测试 AI 连接"])
    }

    func testNewInstallShowsEveryMissingDependency() {
        let readiness = OnboardingReadiness(directoryReady: false, keyFileReadable: false, hasSuccessfulSync: false,
                                            aiConfigurationValid: false, trackedConversationCount: 0)
        XCTAssertEqual(readiness.remainingActions, [.wechatConnection, .configureAI, .chooseContacts])
        XCTAssertEqual(readiness.remainingSteps, ["完成微信连接", "设置 AI 服务", "选择关注的对话"])
    }

    func testSuccessfulSyncDoesNotConcealMissingAIOrScope() {
        let readiness = OnboardingReadiness(directoryReady: true, keyFileReadable: true, hasSuccessfulSync: true,
                                            aiConfigurationValid: false, trackedConversationCount: 0)
        XCTAssertEqual(readiness.remainingActions, [.configureAI, .chooseContacts])
        XCTAssertEqual(readiness.remainingSteps, ["设置 AI 服务", "选择关注的对话"])
    }

    func testSuccessfulAIConnectionRemovesOnlyTheTestStep() {
        let readiness = OnboardingReadiness(directoryReady: true, keyFileReadable: true, hasSuccessfulSync: true,
                                            aiConfigurationValid: true, aiConnectionTested: true, trackedConversationCount: 1)
        XCTAssertTrue(readiness.remainingActions.isEmpty)
        XCTAssertTrue(readiness.remainingSteps.isEmpty)
    }
}
