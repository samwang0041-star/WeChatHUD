import XCTest
@testable import WeChatHUD

final class FirstLaunchGuideTests: XCTestCase {
    func testWelcomeTellsANewUserWhatTheProductDoesAndWillNotDo() {
        XCTAssertEqual(FirstLaunchGuide.productName, "WeChatHUD")
        XCTAssertTrue(FirstLaunchGuide.productPitch.contains("待回"))
        XCTAssertTrue(FirstLaunchGuide.productPitch.contains("本机"))
        XCTAssertTrue(FirstLaunchGuide.neverAutoSend.contains("不会自动发消息"))
        XCTAssertTrue(FirstLaunchGuide.welcomeNeeds.contains { $0.contains("登录微信") })
        XCTAssertEqual(FirstLaunchGuide.welcomeCapabilities.count, 3)
        XCTAssertEqual(FirstLaunchGuide.stepTitles, ["连接微信", "选择关注", "开始使用"])
        XCTAssertEqual(FirstLaunchGuide.contentPageCount, 2)
        XCTAssertEqual(FirstLaunchGuide.primaryCTA(forStep: 0), "下一步")
        XCTAssertEqual(FirstLaunchGuide.primaryCTA(forStep: 1), "开始使用")
        XCTAssertEqual(FirstLaunchGuide.finishCTA, "开始使用")
        XCTAssertEqual(FirstLaunchGuide.skipCTA, "稍后设置")
        assertNoFirstRunJargon(FirstLaunchGuide.productPitch)
        assertNoFirstRunJargon(FirstLaunchGuide.neverAutoSend)
        for capability in FirstLaunchGuide.welcomeCapabilities {
            assertNoFirstRunJargon(capability.title)
            assertNoFirstRunJargon(capability.detail)
        }
    }

    func testConnectionCopyStaysInPlainLanguageAndKeepsASingleNextStep() {
        let idle = FirstLaunchGuide.connection(
            state: .idle, wechatRunning: true, accessReady: false, connected: false
        )
        XCTAssertEqual(idle.buttonTitle, "连接微信")
        XCTAssertTrue(idle.detail.contains("登录微信"))
        XCTAssertEqual(idle.checkpoints.map(\.title), ["打开并登录微信", "允许读取聊天", "确认能读到消息"])
        XCTAssertEqual(idle.checkpoints.map(\.complete), [true, false, false])

        let preparing = FirstLaunchGuide.connection(
            state: .preparingIdle, wechatRunning: true, accessReady: true, connected: false
        )
        XCTAssertTrue(preparing.detail.contains("重新打开并登录") || preparing.detail.contains("再打开并登录"))
        XCTAssertFalse(preparing.detail.contains("签名"))
        XCTAssertEqual(preparing.buttonTitle, "开始准备")

        let failed = FirstLaunchGuide.connection(
            state: .preparingFailed, wechatRunning: true, accessReady: true, connected: false,
            failureReason: "提取的密钥均未通过数据库页 HMAC 校验"
        )
        XCTAssertFalse(failed.detail.contains("HMAC"))
        XCTAssertFalse(failed.detail.contains("密钥"))
        XCTAssertEqual(failed.buttonTitle, "重试准备")

        let states: [FirstLaunchGuide.ConnectionState] = [
            .applying, .probing, .syncing, .connected, .wechatNotInstalled, .wechatNotRunning,
            .preparingIdle, .preparingWaitingRelogin, .preparingExtracting, .preparingFailed,
            .readyToRestart, .needsAccountSelection, .syncFailed, .idle
        ]
        for state in states {
            let copy = FirstLaunchGuide.connection(
                state: state, wechatRunning: true, accessReady: true, connected: state == .connected,
                failureReason: "微信重签失败: denied"
            )
            assertNoFirstRunJargon(copy.title)
            assertNoFirstRunJargon(copy.detail)
            assertNoFirstRunJargon(copy.buttonTitle)
            for checkpoint in copy.checkpoints + copy.preparationCheckpoints {
                assertNoFirstRunJargon(checkpoint.title)
            }
        }
        assertNoFirstRunJargon(FirstLaunchGuide.consentMessage)
        assertNoFirstRunJargon(FirstLaunchGuide.pickerMiss)
    }

    func testPreparationErrorsAreMappedToSomethingACustomerCanDo() {
        XCTAssertEqual(
            FirstLaunchGuide.userFacingPreparationError("密钥提取工具不存在: /tmp/tool"),
            "这次安装不完整，请重新安装 WeChatHUD 后再试。"
        )
        XCTAssertEqual(
            FirstLaunchGuide.userFacingPreparationError("提取的密钥均未通过数据库页 HMAC 校验"),
            "这次准备没有通过验证，请重试。"
        )
        XCTAssertEqual(
            FirstLaunchGuide.userFacingPreparationError("微信重签失败: codesign denied"),
            "本机准备没有完成。如果刚刚拒绝了系统提示，请允许后再试。"
        )
        XCTAssertFalse(FirstLaunchGuide.userFacingPreparationError("密钥提取失败: timeout").contains("密钥"))
    }

    func testTodayEmptyDoesNotPretendTheInboxIsWorkingBeforeSetup() {
        let disconnected = FirstLaunchGuide.todayEmpty(
            wechatConnected: false, hasTrackedConversations: false,
            aiConfigured: false, aiTested: false, searching: false
        )
        XCTAssertEqual(disconnected.title, "还不能整理消息")
        XCTAssertFalse(disconnected.title.contains("暂时没有需要处理"))

        let noScope = FirstLaunchGuide.todayEmpty(
            wechatConnected: true, hasTrackedConversations: false,
            aiConfigured: true, aiTested: true, searching: false
        )
        XCTAssertEqual(noScope.title, "还没有关注的对话")

        let noAI = FirstLaunchGuide.todayEmpty(
            wechatConnected: true, hasTrackedConversations: true,
            aiConfigured: false, aiTested: false, searching: false
        )
        XCTAssertEqual(noAI.title, "摘要和草稿还没准备好")
        XCTAssertFalse(noAI.title.contains("暂时没有需要处理"))
        XCTAssertTrue(noAI.detail.contains("原文"))
        XCTAssertTrue(noAI.detail.contains("AI"))

        XCTAssertEqual(FirstLaunchGuide.compactEmpty(wechatConnected: false, hasTrackedConversations: false), "还没连接微信")
        XCTAssertEqual(FirstLaunchGuide.compactEmpty(wechatConnected: true, hasTrackedConversations: false), "还没选择对话")
        XCTAssertEqual(FirstLaunchGuide.compactEmpty(wechatConnected: true, hasTrackedConversations: true), "没有待处理的事")
    }

    func testTodayEmptyDoesNotHideOpenTasksBehindNoWorkCopy() {
        let empty = FirstLaunchGuide.todayEmpty(
            wechatConnected: true, hasTrackedConversations: true,
            aiConfigured: true, aiTested: true, searching: false, hasOpenTasks: true
        )
        XCTAssertEqual(empty.title, "没有需要回复的消息")
        XCTAssertTrue(empty.detail.contains("我要做"))
        XCTAssertTrue(empty.detail.contains("等对方"))
        XCTAssertFalse(empty.title.contains("没有需要你处理的事"))
    }

    func testTodayEmptyDoesNotPretendAIIsWorkingWhenOnlyConfigured() {
        let untested = FirstLaunchGuide.todayEmpty(
            wechatConnected: true, hasTrackedConversations: true,
            aiConfigured: true, aiTested: false, searching: false
        )
        XCTAssertEqual(untested.title, "还差一次 AI 连接测试")
        XCTAssertTrue(untested.detail.contains("测通"))
        XCTAssertFalse(untested.title.contains("暂时没有需要处理"))
        XCTAssertFalse(untested.detail.contains("原文已经可以查看"))
    }

    func testTodayEmptyPointsAtAllUpdatesWhenReplyQueueIsEmpty() {
        let empty = FirstLaunchGuide.todayEmpty(
            wechatConnected: true, hasTrackedConversations: true,
            aiConfigured: true, aiTested: true, searching: false,
            hasOpenTasks: false, hasOtherInboxItems: true
        )
        XCTAssertEqual(empty.title, "没有需要回复的消息")
        XCTAssertTrue(empty.detail.contains("全部"))
        XCTAssertTrue(empty.detail.contains("知会"))
        XCTAssertFalse(empty.title.contains("没有需要你处理的事"))
    }

    func testSuggestedConversationsHideOfficialAccountsAndKeepRecentChats() {
        let sessions = [
            SessionInfo(username: "gh_official", isGroup: false, unreadCount: 3, lastTimestamp: 90),
            SessionInfo(username: "filehelper", isGroup: false, unreadCount: 1, lastTimestamp: 80),
            SessionInfo(username: "alice", isGroup: false, unreadCount: 2, lastTimestamp: 50),
            SessionInfo(username: "project@chatroom", isGroup: true, unreadCount: 4, lastTimestamp: 70),
            SessionInfo(username: "bob", isGroup: false, unreadCount: 0, lastTimestamp: 40)
        ]
        let suggested = FirstLaunchGuide.suggestedConversations(
            from: sessions, excluding: ["bob"], limit: 10
        )
        XCTAssertEqual(suggested.map(\.username), ["project@chatroom", "alice"])
        XCTAssertTrue(FirstLaunchGuide.isSkippableUsername("gh_news"))
        XCTAssertFalse(FirstLaunchGuide.isSkippableUsername("alice"))
    }

    func testRemainingActionsStayActionableInPlainLanguage() {
        for action in OnboardingReadinessAction.allCases {
            assertNoFirstRunJargon(action.title)
            assertNoFirstRunJargon(action.detail)
            assertNoFirstRunJargon(FirstLaunchGuide.setupStepDetail(action))
        }
        XCTAssertEqual(
            OnboardingReadinessAction.wechatConnection.detail,
            "回到上一步，打开微信并允许读取。"
        )
    }

    private func assertNoFirstRunJargon(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        for word in FirstLaunchGuide.forbiddenFirstRunJargon {
            XCTAssertFalse(text.contains(word), "first-run copy leaked \(word): \(text)", file: file, line: line)
        }
    }
}
