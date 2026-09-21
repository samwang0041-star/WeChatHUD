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
                XCTAssertFalse(tab.subtitle?.contains(word) ?? false, "\(tab.rawValue) subtitle leaked \(word)")
            }
            XCTAssertFalse(tab.subtitle?.isEmpty ?? false)
        }
        XCTAssertEqual(SettingsView.Tab.today.label, "今天")
        XCTAssertEqual(SettingsView.Tab.tasks.label, "待办")
        XCTAssertEqual(SettingsView.Tab.commitments.label, "我答应的事")
        XCTAssertEqual(SettingsView.Tab.drafts.label, "草稿")
        XCTAssertEqual(SettingsView.Tab.insight.label, "聊天回顾")
        XCTAssertEqual(SettingsView.Tab.dailyReport.label, "今日小结")
        XCTAssertEqual(SettingsView.Tab.relationshipRadar.label, "关系雷达")
        XCTAssertEqual(SettingsView.Tab.contacts.label, "关注谁")
        XCTAssertEqual(SettingsView.Tab.autopilotDashboard.label, "待确认回复")
        XCTAssertEqual(SettingsView.Tab.guide.label, "怎么用")
        XCTAssertEqual(SettingsView.Tab.dailyReport.subtitle, "做过和剩下的")
        // The commitments page keeps its one explanatory line in the page body;
        // the header gloss said the title over again.
        XCTAssertNil(SettingsView.Tab.commitments.subtitle)
        XCTAssertEqual(SettingsView.Tab.aiService.subtitle, "摘要用哪家")
        XCTAssertEqual(SettingsView.Tab.autopilot.subtitle, "怎么自动回")
        XCTAssertEqual(AttentionLevel.whitelist.label, "关注")
        XCTAssertEqual(WhitelistAttentionLevel.watch.label, "关注")
        XCTAssertEqual(CompanionProductCopy.deleteDraftTitle(name: "林舟"), "删除给林舟的这条草稿？")
        XCTAssertTrue(CompanionProductCopy.deleteDraftMessage.contains("不影响微信聊天"))
        XCTAssertEqual(CompanionProductCopy.draftKeepCurrent, "保留当前")
        XCTAssertEqual(CompanionProductCopy.draftReplaceContinue, "替换并继续")
        XCTAssertEqual(CompanionProductCopy.sendSuccess(name: "林舟"), "已发送给林舟；已在微信中核对到这条消息")
        XCTAssertTrue(CompanionProductCopy.sendUncertain.contains("待核对"))
        XCTAssertFalse(CompanionProductCopy.sendUncertain.contains("数据库"))
        XCTAssertTrue(CompanionProductCopy.autoSendConfirmMessage.contains("待确认回复"))
        let calendar = Calendar(identifier: .gregorian)
        var components = DateComponents(year: 2026, month: 9, day: 9, hour: 11, minute: 0)
        let now = calendar.date(from: components)!
        components.hour = 11
        let today = calendar.date(from: components)!
        XCTAssertEqual(CompanionProductCopy.snoozeReceipt(until: today, now: now, calendar: calendar), "今天 11:00 后回到收件箱")
        let choices = CompanionProductCopy.snoozeChoices(now: now, calendar: calendar)
        XCTAssertEqual(choices.map(\.label), ["30 分钟后", "1 小时后", "明天上午 9:00"])
        XCTAssertEqual(choices[0].whenLabel, "今天 11:30")
        XCTAssertEqual(choices[1].whenLabel, "今天 12:00")
        XCTAssertEqual(choices[2].whenLabel, "明天 09:00")
    }

    /// 「已安排在X提醒」 promised a scheduled notification the app never
    /// schedules — every `UNNotificationRequest` here is `trigger: nil`, so the
    /// only thing that happens at X is the row coming back on the next scan.
    /// The receipt now says that, and must not slide back into promising a
    /// reminder.
    func testSnoozeReceiptDescribesTheResurfacingNotAReminder() {
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 9, hour: 11))!
        let receipt = CompanionProductCopy.snoozeReceipt(
            until: now.addingTimeInterval(1800), now: now, calendar: calendar
        )
        XCTAssertTrue(receipt.contains("回到收件箱"), receipt)
        XCTAssertFalse(receipt.contains("提醒"), receipt)
    }

    /// The 弹出 switches gate the floating panel only; the proactive rules post
    /// macOS notifications the switches cannot silence. The page header carries
    /// the scope ("只管顶部浮窗") and the footer has to name every family the
    /// engine can actually post — a new rule with a new title fails here.
    func testNotificationSettingsScopeLineCoversEveryAlertTitle() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/WeChatHUD")

        let engine = try String(
            contentsOf: root.appendingPathComponent("Services/ProactiveAlertEngine.swift"),
            encoding: .utf8
        )
        var stems: [String] = []
        for marker in ["title: \"", "title = \""] {
            for chunk in engine.components(separatedBy: marker).dropFirst() {
                guard let quote = chunk.firstIndex(of: "\"") else { continue }
                stems.append(String(chunk[..<quote]))
            }
        }
        XCTAssertGreaterThanOrEqual(stems.count, 6, "the engine's titles stopped looking like titles: \(stems)")

        let families = ["VIP", "承诺", "多条未回", "紧急待回复"]
        for stem in stems {
            XCTAssertTrue(
                families.contains { stem.hasPrefix($0) },
                "alert title 「\(stem)」 is a family the settings page has never heard of"
            )
        }

        let settings = try String(
            contentsOf: root.appendingPathComponent("Views/Settings/NotificationSettingsView.swift"),
            encoding: .utf8
        )
        let line = settings.components(separatedBy: "\n")
            .first { $0.contains("macOS 的通知设置") }
        let scope = try XCTUnwrap(line, "the settings page no longer scopes the 弹出 switches")
        for family in families {
            XCTAssertTrue(scope.contains(family), "the scope line omits \(family)")
        }
        // What the switches *do* govern is stated once, in the page header —
        // the footer repeating it would be the same sentence twice on one screen.
        XCTAssertEqual(SettingsView.Tab.notifications.subtitle, "只管顶部浮窗")
    }

    /// The banner shares the panel's relative vocabulary ("12 分钟前" /
    /// "2 小时前") instead of switching to a clock after an hour, which read
    /// as a second time format next to the island's sync stamp. Only past a
    /// day does elapsed time stop being a useful unit and the stamp becomes
    /// an absolute time (the only form that can carry a date).
    func testArrivalLabelSharesThePanelsRelativeVocabulary() {
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 9, hour: 14, minute: 32))!

        XCTAssertEqual(CompanionProductCopy.arrivalLabel(now, now: now, calendar: calendar), "刚刚")
        XCTAssertEqual(
            CompanionProductCopy.arrivalLabel(now.addingTimeInterval(-59), now: now, calendar: calendar),
            "刚刚"
        )
        XCTAssertEqual(
            CompanionProductCopy.arrivalLabel(now.addingTimeInterval(-60), now: now, calendar: calendar),
            "1 分钟前"
        )
        XCTAssertEqual(
            CompanionProductCopy.arrivalLabel(now.addingTimeInterval(-12 * 60), now: now, calendar: calendar),
            "12 分钟前"
        )
        XCTAssertEqual(
            CompanionProductCopy.arrivalLabel(now.addingTimeInterval(-59 * 60), now: now, calendar: calendar),
            "59 分钟前"
        )
        XCTAssertEqual(
            CompanionProductCopy.arrivalLabel(now.addingTimeInterval(-3600), now: now, calendar: calendar),
            "1 小时前"
        )
        XCTAssertEqual(
            CompanionProductCopy.arrivalLabel(now.addingTimeInterval(-5 * 3600), now: now, calendar: calendar),
            "5 小时前"
        )
        XCTAssertEqual(
            CompanionProductCopy.arrivalLabel(now.addingTimeInterval(-86_399), now: now, calendar: calendar),
            "23 小时前",
            "Still inside the day, so still relative."
        )
        // Past a day the stamp becomes absolute, which is the only form that
        // can carry a date.
        XCTAssertEqual(
            CompanionProductCopy.arrivalLabel(
                calendar.date(from: DateComponents(year: 2026, month: 9, day: 7, hour: 22, minute: 10))!,
                now: now, calendar: calendar
            ),
            "9月7日 22:10"
        )
    }

    func testMenuBarBadgeIsReadableChinese() {
        XCTAssertEqual(CompanionProductCopy.menuBarBadge(pendingCount: 0, longestWait: .none), "")
        XCTAssertEqual(CompanionProductCopy.menuBarBadge(pendingCount: 3, longestWait: .none), " 3 待办")
        XCTAssertEqual(CompanionProductCopy.menuBarBadge(pendingCount: 10, longestWait: .none), " 9+")
        // Below T2 escalation the badge stays a plain count.
        XCTAssertEqual(CompanionProductCopy.menuBarBadge(pendingCount: 3, longestWait: .t1), " 3 待办")
        // Escalated: count + how long the VIP has been waiting.
        XCTAssertEqual(CompanionProductCopy.menuBarBadge(pendingCount: 3, longestWait: .t4), " 3 待办 · 等 4 小时+")
       XCTAssertEqual(CompanionProductCopy.menuBarBadge(pendingCount: 0, longestWait: .t3), " 等 2 小时")
   }

    func testAnalysisFailureCopyNamesTheResultNotThePipeline() {
        XCTAssertTrue(CompanionInteractionCopy.analysisUnavailable.contains("再试"))
        XCTAssertFalse(CompanionInteractionCopy.analysisUnavailable.contains("解析"))
        XCTAssertFalse(CompanionInteractionCopy.analysisUnavailable.contains("HTTP"))
        XCTAssertEqual(
            CompanionInteractionCopy.displayableAnalysisFailure(nil),
            CompanionInteractionCopy.analysisUnavailable
        )
        XCTAssertEqual(
            CompanionInteractionCopy.displayableAnalysisFailure("读取消息失败: disk I/O error"),
            CompanionInteractionCopy.analysisReadFailed
        )
        XCTAssertFalse(CompanionInteractionCopy.displayableAnalysisFailure("读取消息失败: disk I/O error").contains("disk"))
        XCTAssertEqual(
            CompanionInteractionCopy.displayableAnalysisFailure("AI 返回空内容或解析失败"),
            CompanionInteractionCopy.analysisUnavailable
        )
        XCTAssertEqual(
            CompanionInteractionCopy.displayableAnalysisFailure("加载群聊分析 Prompt 失败: missing"),
            CompanionInteractionCopy.analysisUnavailable
        )
        XCTAssertEqual(
            CompanionInteractionCopy.displayableAnalysisFailure("找不到这条 @ 消息，未使用其他消息替代"),
            CompanionInteractionCopy.analysisMissingMention
        )
        XCTAssertEqual(
            CompanionInteractionCopy.displayableAnalysisFailure(CompanionInteractionCopy.analysisReadFailed),
            CompanionInteractionCopy.analysisReadFailed
        )
       XCTAssertTrue(CompanionInteractionCopy.replySuggestionsFailed.contains("没写出来"))
       XCTAssertFalse(CompanionInteractionCopy.replySuggestionsFailed.contains("失败"))
   }

    func testAccountSwitchCopyDoesNotNameTheFolder() {
        XCTAssertTrue(CompanionInteractionCopy.accountSwitched.contains("换了微信账号"))
        XCTAssertFalse(CompanionInteractionCopy.accountSwitched.contains("数据目录"))
        XCTAssertTrue(CompanionInteractionCopy.accountSwitchedEmpty.contains("连接设置"))
        XCTAssertFalse(CompanionInteractionCopy.contactsIndexFailed.contains("索引"))
        XCTAssertFalse(CompanionInteractionCopy.contactsIndexFailed.contains("数据目录"))
        XCTAssertFalse(CompanionInteractionCopy.discussionSourceReadFailed.contains("访问材料"))
       XCTAssertTrue(CompanionInteractionCopy.discussionSourceReadFailed.contains("账号资料"))
   }

    func testRetrospectiveFailureCopyNamesTheResultAndTheNextMove() {
        XCTAssertTrue(CompanionInteractionCopy.retrospectiveUnavailable.contains("再试"))
        XCTAssertFalse(CompanionInteractionCopy.retrospectiveUnavailable.contains("cancelled"))
        XCTAssertTrue(CompanionInteractionCopy.retrospectiveTodoCompleteFailed.contains("待办"))
        XCTAssertTrue(CompanionInteractionCopy.retrospectiveTodoCompleteFailed.contains("重试"))
        XCTAssertTrue(CompanionInteractionCopy.retrospectiveTodoCompleteFailed.contains("保留"))
        XCTAssertFalse(CompanionInteractionCopy.retrospectiveTodoCompleteFailed.contains("失败"))
        XCTAssertTrue(CompanionInteractionCopy.inboxRestoreFailed.contains("恢复"))
        XCTAssertTrue(CompanionInteractionCopy.untrackFailed.contains("取消关注"))
        XCTAssertTrue(CompanionInteractionCopy.followLevelFailed.contains("关注档位"))
        XCTAssertTrue(CompanionInteractionCopy.followLevelFailed.contains("重试"))
        XCTAssertEqual(
            CompanionInteractionCopy.followLevelChanged(levelTitle: "关注", name: "新同事"),
            "已改为关注：新同事"
        )
        XCTAssertFalse(
            CompanionInteractionCopy.followLevelChanged(levelTitle: "关注", name: "新同事")
                .contains("已添加关注")
        )
        XCTAssertEqual(
            CompanionInteractionCopy.contactSettingsSaved(name: "新同事"),
            "已保存关注设置：新同事"
        )
        XCTAssertEqual(
            CompanionInteractionCopy.chatRenamed("供应链周会"),
            "已改名为：供应链周会"
        )
        XCTAssertEqual(CompanionInteractionCopy.chatNameRestored, "已恢复微信原名")
        XCTAssertEqual(
            CompanionInteractionCopy.contactRemoved(name: "新同事"),
            "已删除关注：新同事"
        )
        XCTAssertFalse(CompanionInteractionCopy.contactSettingsSaved(name: "新同事").contains("已添加关注"))
        XCTAssertEqual(
            CompanionInteractionCopy.watchedMemberAdded(name: "主管"),
            "已添加重点成员：主管"
        )
        XCTAssertEqual(
            CompanionInteractionCopy.quietGroupSilenced(name: "行业交流大群"),
            "已设为不弹出：行业交流大群"
        )
        XCTAssertEqual(
            CompanionInteractionCopy.mutedPersonAdded(name: "推广号"),
            "已设为不提醒：推广号"
        )
        XCTAssertTrue(CompanionInteractionCopy.followListUnreadableAdmission.contains("再试一次"))
        XCTAssertTrue(CompanionInteractionCopy.followListUnreadableAdmission.contains("先不要改"))
        XCTAssertTrue(CompanionInteractionCopy.untrackFailed.contains("重试"))
        XCTAssertTrue(CompanionInteractionCopy.inboxRestoreFailed.contains("重试"))
        XCTAssertTrue(CompanionInteractionCopy.inboxRestoreFailed.contains("保留"))
        XCTAssertFalse(CompanionInteractionCopy.inboxRestoreFailed.contains("失败"))
        XCTAssertEqual(
            CompanionInteractionCopy.displayableRetrospectiveFailure("cancelled: after screen"),
            CompanionInteractionCopy.retrospectiveCancelled
        )
        XCTAssertEqual(
            CompanionInteractionCopy.displayableRetrospectiveFailure("Could not create run row"),
            CompanionInteractionCopy.retrospectiveCouldNotStart
        )
        XCTAssertFalse(CompanionInteractionCopy.displayableRetrospectiveFailure("Could not create run row").contains("row"))
        let partial = CompanionInteractionCopy.retrospectivePartial(["林舟", "产品群"])
        XCTAssertTrue(partial.contains("林舟"))
        XCTAssertTrue(partial.contains("再试"))
       XCTAssertFalse(partial.contains("分析失败"))
   }

    func testExportFailureCopyDoesNotNamePermissions() {
        XCTAssertFalse(CompanionInteractionCopy.exportToDesktopFailed.contains("写入权限"))
        XCTAssertFalse(CompanionInteractionCopy.dailyExportFailed.contains("写入权限"))
        XCTAssertTrue(CompanionInteractionCopy.exportToDesktopFailed.contains("桌面"))
        XCTAssertTrue(CompanionInteractionCopy.dailyExportFailed.contains("再导出"))
        XCTAssertFalse(CompanionInteractionCopy.legacyBindFailed.contains("目录"))
       XCTAssertTrue(CompanionInteractionCopy.legacyBindFailed.contains("账号资料"))
   }

    func testUpdateFailureCopyNamesThePublisherNotTheChecksum() {
        XCTAssertFalse(AppUpdateError.unsignedArchive.userMessage.contains("代码签名"))
        XCTAssertFalse(AppUpdateError.checksumMismatch.userMessage.contains("校验"))
        XCTAssertTrue(AppUpdateError.unsignedArchive.userMessage.contains("发布页"))
        XCTAssertTrue(AppUpdateError.checksumMismatch.userMessage.contains("发布页"))
        XCTAssertTrue(AppUpdateError.currentVersionUnknown.userMessage.contains("发布页"))
        XCTAssertTrue(AppUpdateError.httpStatus(500).userMessage.contains("发布页"))
        XCTAssertFalse(AppUpdateError.httpStatus(500).userMessage.contains("HTTP"))
        XCTAssertFalse(AppUpdateError.httpStatus(500).userMessage.contains("500"))
    }
}
