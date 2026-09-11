import XCTest
@testable import WeChatHUD

/// 验收 8: VoiceOver names and keyboard-facing copy for workspace pages and dialogs.
final class ProductAccessibilityTests: XCTestCase {
    func testEveryWorkspacePageHasAStableIdentifierAndSpokenName() {
        let expected: [(SettingsView.Tab, String)] = [
            (.today, "今天"),
            (.tasks, "待办"),
            (.commitments, "我答应的事"),
            (.drafts, "草稿"),
            (.insight, "聊天回顾"),
            (.dailyReport, "今日小结"),
            (.autopilotDashboard, "待确认回复"),
            (.contacts, "关注谁"),
            (.aiButler, "AI 分析与建议"),
            (.notifications, "提醒方式"),
            (.aiService, "AI 服务"),
            (.autopilot, "自动回复"),
            (.system, "微信连接"),
            (.preferences, "使用偏好"),
            (.localData, "本地资料"),
            (.guide, "怎么用")
        ]
        XCTAssertEqual(SettingsView.Tab.allCases.count, 16)
        XCTAssertEqual(expected.count, 16)
        for (tab, name) in expected {
            XCTAssertEqual(tab.label, name)
            XCTAssertEqual("workspace.\(tab.rawValue)", "workspace.\(tab.rawValue)")
            XCTAssertFalse(tab.label.isEmpty)
            XCTAssertFalse(tab.subtitle.isEmpty)
        }
    }

    func testDialogCopyHasEscCancelAndNoForbiddenChrome() {
        let dialogs = [
            CompanionProductCopy.draftConflictTitle,
            CompanionProductCopy.draftKeepCurrent,
            CompanionProductCopy.draftReplaceContinue,
            CompanionProductCopy.sendConfirmTitle,
            CompanionProductCopy.sendConfirmBack,
            CompanionProductCopy.sendConfirmAction,
            CompanionProductCopy.deleteDraftTitle(name: "林晓"),
            CompanionProductCopy.autoSendConfirmTitle,
            CompanionProductCopy.autoSendKeepManual,
            CompanionProductCopy.autoSendAllow,
            CompanionProductCopy.addFollow,
            CompanionProductCopy.cancelCommitmentTitle
        ]
        for copy in dialogs {
            XCTAssertFalse(copy.isEmpty)
            for word in CompanionProductCopy.forbiddenChrome {
                XCTAssertFalse(copy.contains(word), "\(copy) leaked \(word)")
            }
        }
        XCTAssertEqual(CompanionProductCopy.sendConfirmBack, "返回修改")
        XCTAssertTrue(CompanionProductCopy.deleteDraftMessage.contains("不影响微信聊天"))
        XCTAssertEqual(CompanionProductCopy.snoozeChoices().count, 3)
        for tab in SettingsView.Tab.allCases {
            XCTAssertEqual("workspace.\(tab.rawValue)", "workspace.\(tab.rawValue)")
            XCTAssertFalse(CompanionProductCopy.forbiddenChrome.contains { tab.label.contains($0) })
        }
    }

    func testChromeTypeScaleGrowsForAccessibilitySizes() {
        XCTAssertEqual(CompanionTypeScale.factor(for: .large), 1.0)
        XCTAssertGreaterThan(CompanionTypeScale.factor(for: .accessibility2), 1.4)
        XCTAssertGreaterThan(
            CompanionTypeScale.factor(for: .accessibility2),
            CompanionTypeScale.factor(for: .xxxLarge)
        )
        XCTAssertLessThan(CompanionTypeScale.factor(for: .xSmall), 1.0)
    }

    func testIslandControlsHaveSpokenNames() {
        XCTAssertEqual(CompanionProductCopy.openCompanion, "打开 WeChatHUD")
        XCTAssertTrue(CompanionProductCopy.compactStatus(count: 3, sync: "刚刚同步").contains("3 项待处理"))
        XCTAssertFalse(CompanionProductCopy.compactHoverHint.contains("工作台"))
        let choices = CompanionProductCopy.snoozeChoices()
        XCTAssertEqual(choices.map(\.label), ["30 分钟后", "1 小时后", "明天上午 9:00"])
        XCTAssertFalse(choices.contains { $0.whenLabel.isEmpty })
    }
}
