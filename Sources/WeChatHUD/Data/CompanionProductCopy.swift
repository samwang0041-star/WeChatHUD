import Foundation

extension Notification.Name {
    static let hudShowOnboarding = Notification.Name("WeChatHUD.ShowOnboarding")
    static let hudPreviewAITestFailure = Notification.Name("WeChatHUD.PreviewAITestFailure")
    static let hudPreviewAutoSendConfirm = Notification.Name("WeChatHUD.PreviewAutoSendConfirm")
    static let hudOnboardingAdvance = Notification.Name("WeChatHUD.OnboardingAdvance")
    static let hudPreviewCaptureSurfaces = Notification.Name("WeChatHUD.PreviewCaptureSurfaces")
    static let hudPreviewCaptureChrome = Notification.Name("WeChatHUD.PreviewCaptureChrome")
    static let hudIslandNeedsResize = Notification.Name("WeChatHUD.IslandNeedsResize")
}

/// Customer-facing chrome. Keep labels short; no slogans.
enum CompanionProductCopy {
    static let brandName = "WeChatHUD"
    /// Intentionally empty. The product name is enough; no slogan under it.
    static let brandPromise = ""
    static let sidebarFooter = "本机数据"
    static var openCompanion: String { "打开 \(brandName)" }
    static var collapseCompanion: String { "收起 \(brandName)" }
    static let checkNewMessages = "查看新消息"
    static let timeReview = "按时间回顾"
    static let howToUse = "怎么用"
    static let checkUpdates = "检查更新…"
    static var quitCompanion: String { "退出 \(brandName)" }

    static func companionToggleTitle(isOpen: Bool) -> String {
        isOpen ? collapseCompanion : openCompanion
    }

    static func viewUpdate(_ version: String) -> String {
        "查看更新 \(version)…"
    }

    static let sectionHandle = "处理"
    static let sectionReview = "回顾"
    static let sectionReply = "代回复"
    static let sectionSettings = "设置"
    static let addFollow = "添加关注"
    static let draftConflictTitle = "回复内容冲突"
    static let draftKeepCurrent = "保留当前"
    static let draftReplaceContinue = "替换并继续"
    static let draftConflictMessage = "回复框里已有其他内容。未确认不会覆盖；保存的旧草稿仍保留。"
    static let deleteDraftMessage = "删除后无法从草稿列表恢复，不影响微信聊天。"
    static let sendConfirmTitle = "确认发送"
    static let sendConfirmBack = "返回修改"
    static let sendConfirmAction = "确认发送"
    static let sendUncertain = "发送结果待核对；请先到微信查看，避免重复发送"
    static let cancelCommitmentTitle = "取消这条承诺？"
    static let cancelCommitmentMessage = "取消后它不再出现在进行中。聊天原文不会改变。"
    static let autoSendConfirmTitle = "开启自动发送？"
    static let autoSendKeepManual = "保持手动"
    static let autoSendAllow = "允许发送"
    static let autoSendConfirmMessage = "只修改设置，不会马上发出去。写好的回复仍先出现在「待确认回复」。"

    static func deleteDraftTitle(name: String) -> String {
        "删除给\(name)的这条草稿？"
    }

    static func sendConfirmMessage(name: String, text: String) -> String {
        "将发给 \(name)：\n\n\(text)"
    }

    static func sendSuccess(name: String) -> String {
        "已发送给\(name)；已在微信中核对到这条消息"
    }

    struct SnoozeChoice: Identifiable {
        let label: String
        let until: Date
        let whenLabel: String
        var id: String { label }
    }

    static func snoozeChoices(now: Date = Date(), calendar: Calendar = .current) -> [SnoozeChoice] {
        let thirty = now.addingTimeInterval(30 * 60)
        let hour = now.addingTimeInterval(60 * 60)
        let tomorrowMorning = calendar.date(
            byAdding: .day, value: 1,
            to: calendar.startOfDay(for: now)
        )?.addingTimeInterval(9 * 3600) ?? now.addingTimeInterval(86400)
        return [
            SnoozeChoice(label: "30 分钟后", until: thirty, whenLabel: clockLabel(thirty, now: now, calendar: calendar)),
            SnoozeChoice(label: "1 小时后", until: hour, whenLabel: clockLabel(hour, now: now, calendar: calendar)),
            SnoozeChoice(label: "明天上午 9:00", until: tomorrowMorning, whenLabel: clockLabel(tomorrowMorning, now: now, calendar: calendar))
        ]
    }

    static func clockLabel(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        // Compare against the injected reference time, not the wall clock.
        // isDateInToday reads Date() internally, which made the now parameter
        // inert: a caller passing a reference time still got labels resolved
        // against whenever the code happened to run.
        if calendar.isDate(date, inSameDayAs: now) {
            formatter.dateFormat = "HH:mm"
            return "今天 \(formatter.string(from: date))"
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(date, inSameDayAs: tomorrow) {
            formatter.dateFormat = "HH:mm"
            return "明天 \(formatter.string(from: date))"
        }
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter.string(from: date)
    }

    static func snoozeReceipt(until: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        "已安排在\(clockLabel(until, now: now, calendar: calendar)) 提醒"
    }

    static let compactHoverHint = "移入查看。"
    static let forbiddenChrome = ["工作台", "洞察", "简报", "白名单", "db_storage"]

    static func compactStatus(count: Int, sync: String) -> String {
        "收起 · \(count) 项待处理。\(compactHoverHint) \(sync)"
    }

    /// Menu-bar badge next to the icon. Read aloud it should make sense:
    /// "3 待办" = three things waiting on you; "等 4h+" = a VIP has been
    /// waiting that long. Empty string = nothing needs attention.
    static func menuBarBadge(pendingCount: Int, longestWait: VIPAlertTier) -> String {
        switch longestWait {
        case .t2, .t3, .t4:
            let wait = "等 \(longestWait.agingLabel)"
            return pendingCount > 0 ? " \(pendingCount) 待办 · \(wait)" : " \(wait)"
        case .none, .t1:
            if pendingCount > 9 { return " 9+" }
            return pendingCount > 0 ? " \(pendingCount) 待办" : ""
        }
    }
}
