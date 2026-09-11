import XCTest
@testable import WeChatHUD

final class CompanionProductCopyTests: XCTestCase {
    func testChromeReadsLikeACompanionNotAConsole() {
        XCTAssertEqual(CompanionProductCopy.brandName, "WeChatHUD")
        XCTAssertTrue(CompanionProductCopy.brandPromise.isEmpty)
        XCTAssertEqual(CompanionProductCopy.openCompanion, "打开 WeChatHUD")
        XCTAssertEqual(CompanionProductCopy.collapseCompanion, "收起 WeChatHUD")
        XCTAssertEqual(CompanionProductCopy.checkNewMessages, "查看新消息")
        XCTAssertEqual(CompanionProductCopy.quitCompanion, "退出 WeChatHUD")
        XCTAssertEqual(CompanionProductCopy.sidebarFooter, "本机数据")
        for word in CompanionProductCopy.forbiddenChrome {
            XCTAssertFalse(CompanionProductCopy.brandName.contains(word))
            XCTAssertFalse(CompanionProductCopy.brandPromise.contains(word))
            XCTAssertFalse(CompanionProductCopy.sidebarFooter.contains(word))
        }
        for tab in SettingsView.Tab.allCases {
            for word in CompanionProductCopy.forbiddenChrome {
                XCTAssertFalse(tab.label.contains(word), "\(tab.rawValue) label leaked \(word)")
                XCTAssertFalse(tab.subtitle.contains(word), "\(tab.rawValue) subtitle leaked \(word)")
            }
            XCTAssertFalse(tab.subtitle.isEmpty)
        }
        XCTAssertEqual(SettingsView.Tab.today.label, "今天")
        XCTAssertEqual(SettingsView.Tab.tasks.label, "待办")
        XCTAssertEqual(SettingsView.Tab.commitments.label, "我答应的事")
        XCTAssertEqual(SettingsView.Tab.drafts.label, "草稿")
        XCTAssertEqual(SettingsView.Tab.insight.label, "聊天回顾")
        XCTAssertEqual(SettingsView.Tab.dailyReport.label, "今日小结")
        XCTAssertEqual(SettingsView.Tab.contacts.label, "关注谁")
        XCTAssertEqual(SettingsView.Tab.autopilotDashboard.label, "待确认回复")
        XCTAssertEqual(SettingsView.Tab.guide.label, "怎么用")
        XCTAssertEqual(CompanionProductCopy.deleteDraftTitle(name: "林舟"), "删除给林舟的这条草稿？")
        XCTAssertTrue(CompanionProductCopy.deleteDraftMessage.contains("不影响微信聊天"))
        XCTAssertEqual(CompanionProductCopy.draftKeepCurrent, "保留当前")
        XCTAssertEqual(CompanionProductCopy.draftReplaceContinue, "替换并继续")
        XCTAssertEqual(CompanionProductCopy.sendSuccess(name: "林舟"), "已发送给林舟；已在微信中核对到这条消息")
        XCTAssertTrue(CompanionProductCopy.sendUncertain.contains("待核对"))
        XCTAssertTrue(CompanionProductCopy.autoSendConfirmMessage.contains("待确认回复"))
        let calendar = Calendar(identifier: .gregorian)
        var components = DateComponents(year: 2026, month: 9, day: 9, hour: 11, minute: 0)
        let now = calendar.date(from: components)!
        components.hour = 11
        let today = calendar.date(from: components)!
        XCTAssertEqual(CompanionProductCopy.snoozeReceipt(until: today, now: now, calendar: calendar), "已安排在今天 11:00 提醒")
        let choices = CompanionProductCopy.snoozeChoices(now: now, calendar: calendar)
        XCTAssertEqual(choices.map(\.label), ["30 分钟后", "1 小时后", "明天上午 9:00"])
        XCTAssertEqual(choices[0].whenLabel, "今天 11:30")
        XCTAssertEqual(choices[1].whenLabel, "今天 12:00")
        XCTAssertEqual(choices[2].whenLabel, "明天 09:00")
        XCTAssertTrue(CompanionProductCopy.compactHoverHint.contains("移入查看"))
    }

    func testMenuBarBadgeIsReadableChinese() {
        XCTAssertEqual(CompanionProductCopy.menuBarBadge(pendingCount: 0, longestWait: .none), "")
        XCTAssertEqual(CompanionProductCopy.menuBarBadge(pendingCount: 3, longestWait: .none), " 3 待办")
        XCTAssertEqual(CompanionProductCopy.menuBarBadge(pendingCount: 10, longestWait: .none), " 9+")
        // Below T2 escalation the badge stays a plain count.
        XCTAssertEqual(CompanionProductCopy.menuBarBadge(pendingCount: 3, longestWait: .t1), " 3 待办")
        // Escalated: count + how long the VIP has been waiting.
        XCTAssertEqual(CompanionProductCopy.menuBarBadge(pendingCount: 3, longestWait: .t4), " 3 待办 · 等 4h+")
        XCTAssertEqual(CompanionProductCopy.menuBarBadge(pendingCount: 0, longestWait: .t3), " 等 2h")
    }
}
