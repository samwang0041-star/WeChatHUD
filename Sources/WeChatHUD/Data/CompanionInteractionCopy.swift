import Foundation

/// The words the app uses *while the user is doing something*.
///
/// `CompanionProductCopy` holds chrome (labels, dialog titles, receipts) —
/// what a thing is called. This file holds the interaction layer: what a
/// control promises on hover, what the app says while it works, and what it
/// offers after a state change. The difference matters because the two have
/// different failure modes. Bad chrome is confusing; bad interaction copy is
/// the reason a user stops trusting a button — a control that says nothing on
/// hover is a control you have to click to understand, and a progress state
/// that says nothing reads as a hang.
///
/// Three rules hold everywhere in here:
///
///   1. **Say what happens, not how it is implemented.** "读取这台 Mac 上已
///      登录的微信" beats "初始化数据库连接".
///   2. **Every wait gets a promise.** If a state can last more than ~400 ms,
///      it says what is being waited on and what the user can do meanwhile.
///   3. **Every failure gets a next step.** Never a bare "失败".
enum CompanionInteractionCopy {

    // MARK: - Hover promises

    /// What a sidebar row promises before you commit to clicking it.
    ///
    /// These are read by the tooltip and by VoiceOver, so they are written as
    /// complete sentences about the *destination*, not restatements of the
    /// label. The label already says "待办"; the hint has to say what 待办 is
    /// for, or it is just the label twice.
    static func pageHint(for tab: String) -> String {
        switch tab {
        case "today": return "今天要回的和要做的事，都在这页"
        case "tasks": return "从聊天里认出来的事，按谁来做分开"
        case "commitments": return "你答应过别人的话，带着原话和期限"
        case "drafts": return "写好了还没发出去的回复"
        case "insight": return "按天翻聊天，看这段时间聊出了什么"
        case "dailyReport": return "一天做过什么、还剩什么"
        case "relationshipRadar": return "谁常联系你、谁在冷下来"
        case "autopilotDashboard": return "AI 写好的回复，等你点头才发"
        case "contacts": return "决定哪些对话需要你关注"
        case "aiButler": return "摘要和回复建议用哪种 AI 来写"
        case "notifications": return "什么消息值得弹到屏幕顶上"
        case "aiService": return "摘要和草稿交给哪个服务写"
        case "autopilot": return "自动回复做什么、不做什么"
        case "system": return "这台 Mac 上的微信读得到读不到"
        case "preferences": return "浮窗位置和动效偏好"
        case "localData": return "导出的报告和最近的整理记录"
        case "guide": return "三步上手，以及常见问题的答案"
        default: return "打开这一页"
        }
    }

    static let missedRepliesHint = "按你选的时间，找出私聊和群 @ 里还没回的"
    static let readingMissedReplies = "正在按时间翻私聊和群 @，看哪些还没回"
    static let missedRepliesEmpty = "这段时间里，关注的私聊和点名你的群消息都回过了。"
    static let missedRepliesFailed = "刚才没读完聊天。可以再试一次，或先检查微信连接。"
    static let missedRepliesNeedConnection = "先连上微信，才能按时间找出还没回的消息。"

    /// What the walk did *not* cover. The empty page is a claim about "nothing
    /// left unanswered", so a truncated or partially failed scan has to say so
    /// in the same breath — otherwise silence reads as a clean bill of health.
    static func missedRepliesUnread(_ count: Int) -> String { "另有 \(count) 个对话没读到" }
    static let missedRepliesGroupsUnreadable = "群会话列表没读到"
    static func missedRepliesIncomplete(_ holes: String) -> String {
        "\(holes)，这里可能不全。"
    }
    /// Empty-page headlines: the all-clear one only when the scan was complete.
    static let missedRepliesAllClear = "没有遗漏"
    static let missedRepliesPartial = "没查全"

    /// Row-level hover promise in the message list: what opening this row
    /// actually gives you.
    static let openConversationHint = "展开这条，看原文、AI 解读和可以回的话"
    static let reopenConversationHint = "收起这一条"

    // MARK: - Waiting states

    /// Long-running reads. Each one names the object being read, because
    /// "正在处理…" tells the user nothing they did not already know.
    static func readingChats(_ count: Int) -> String {
        count > 0 ? "正在读这 \(count) 个对话的新消息" : "正在读你关注的对话"
    }
    static let firstScan = "第一次读，先把最近的聊天过一遍"
    static let waitingForWeChat = "微信还没启动，启动后会自动接上"
    static let aiThinking = "AI 正在看这段话，写好就出现在这里"
    static let aiSummarizing = "正在写摘要"
    static let draftingReply = "正在按你的语气起草"
    static let exportingReport = "正在整理成报告"
    static let checkingConnection = "正在确认还能不能读到"

    // MARK: - Receipts and undo

    /// After a state change the user cannot see the result of directly.
    static func snoozedHint(_ whenLabel: String) -> String {
        "\(whenLabel)再提醒你，这条先收起来"
    }
    static let markedHandled = "记下了，这条不会再提醒你"
    static let undoAvailable = "撤回到刚才"
    static let draftSavedLocally = "草稿存在这台 Mac 上，发之前你还能改"

    // MARK: - Failure next steps

    /// Clipboard writes have no on-screen artifact of their own. The control
    /// that was pressed has to say that the pasteboard changed — or that it
    /// did not, with a next step.
    static let copied = "已复制"
    static let copyFailed = "复制失败，请重试。"
    static let dailyReportCompleteFailed = "没能标记完成，原事项仍保留。请重试。"
    static let dailyReportDismissFailed = "没能忽略这条风险，原条目仍保留。请重试。"
    static let retrospectiveTodoCompleteFailed = "没能标记完成，原待办仍保留。请重试。"
    static let inboxRestoreFailed = "没能恢复这条消息，原处理结果仍保留。请重试。"
    static let untrackFailed = "取消关注没有保存，这条对话还在关注名单里。请重试。"
   static let followLevelUnreadable = "暂时读不到关注名单，这次没有改档位。请稍后再试一次。"
   static let followListUnreadableAnalysis = "暂时读不到关注名单，这次没有分析。请稍后再试一次。"
    static let notOnFollowList = "不在关注列表中"
   static let followLevelFailed = "关注档位没有保存，原来的设置仍保留。请重试。"
    /// Context menus vanish on click, and a tab jump destroys the inspector
    /// picker — both need a receipt that is not 「已添加关注」.
   static func followLevelChanged(levelTitle: String, name: String) -> String {
       "已改为\(levelTitle)：\(name)"
   }
    static func contactSettingsSaved(name: String) -> String {
        "已保存关注设置：\(name)"
    }
    static func chatRenamed(_ name: String) -> String {
        "已改名为：\(name)"
    }
    static let chatNameRestored = "已恢复微信原名"
   static func contactRemoved(name: String) -> String {
       "已删除关注：\(name)"
   }
   static let followListUnreadableAdmission = "暂时读不到关注名单，这一页的范围先不要改。请再试一次。"
    static let followListUnreadableEdit = "暂时读不到关注名单，这次没有改关注。请稍后再试一次。"
    static let followListUnreadableMissedReplies = "暂时读不到关注名单，这次没找出没回的消息。请稍后再试一次。"
    static func watchedMemberAdded(name: String) -> String {
        "已添加重点成员：\(name)"
    }
    static func watchedMemberRemoved(name: String) -> String {
        "已移除重点成员：\(name)"
    }
    static func quietGroupSilenced(name: String) -> String {
        "已设为不弹出：\(name)"
    }
    static func quietGroupRestored(name: String) -> String {
        "已恢复弹出：\(name)"
    }
    static func mutedPersonAdded(name: String) -> String {
        "已设为不提醒：\(name)"
    }
    static func mutedPersonRestored(name: String) -> String {
        "已恢复提醒：\(name)"
    }
    static let replyCopied = "回复已复制，发送前请核对收件人。"

    /// Failures always pair the fact with the move. The caller supplies the
    /// reason; this supplies the sentence shape so no surface invents its own.
    static func failedButRecoverable(_ what: String, next: String) -> String {
        "\(what)。\(next)"
    }
    static let retryOrOpenWeChat = "可以重试；也可以先到微信里核对"
    static let needAccessibility = "到「使用偏好」里打开辅助功能权限，发送才能用"
    static let needAIService = "到「AI 服务」里填好服务和访问凭据，再测试一次"
   static let needWeChatRunning = "打开这台 Mac 上的微信，再回到这里点「查看新消息」"
    static let wechatUnreadable = "暂时读不到新消息，微信可能没开着或没登录。"
    static let wechatUnreadableEmpty = "暂时读不到新消息。请确认微信已经打开并登录。"
    static let accountSwitched = "换了微信账号，之前的记录已经读不到了"
    static let accountSwitchedEmpty = "换了微信账号，之前的记录已经读不到了。请到连接设置选定当前这个账号。"
    static let accountSwitchedShort = "换了微信账号"
    static let contactsIndexFailed = "没能读到联系人名单。请确认微信已连接后再试。"
    static let contactsSessionsFailed = "没能读到最近会话。已显示已有的联系人，可再试一次。"
  static let discussionSourceReadFailed = "没能读到这条事项的原文。请到连接设置核对账号资料，然后重试。"
    static let exportToDesktopFailed = "没能保存到桌面。请确认桌面可以放入文件，再导出一次。"
    static let dailyExportFailed = "小结没能保存到桌面。请确认桌面可以放入文件，再导出一次。"
    static let legacyBindFailed = "旧版资料没能接上。请先备份，再确认当前账号资料后重试。"
    static let retrospectiveUnavailable = "这次回顾没能完成。请再试一次。"
    static let retrospectiveCancelled = "这次回顾已停住。可以再生成一次。"
    static let retrospectiveCouldNotStart = "这次回顾没能开始。请重试。"
    static let retrospectiveScopeUnreadable = "暂时读不到关注名单，这次回顾没有开始。请稍后再试一次。"

    static func retrospectivePartial(_ names: [String]) -> String {
        let shown = names.prefix(3).joined(separator: "、")
        if shown.isEmpty { return "有些对话没能整理出来。可以再试一次。" }
        return "有些对话没能整理出来：\(shown)。可以再试一次。"
    }

    static func displayableRetrospectiveFailure(_ raw: String?) -> String {
        let text = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return retrospectiveUnavailable }
        if text.localizedCaseInsensitiveContains("cancelled") {
            return retrospectiveCancelled
        }
        if text.localizedCaseInsensitiveContains("could not create") {
            return retrospectiveCouldNotStart
        }
        if text.contains("再试") || text.contains("再生成") || text.contains("请重试") {
            return text
        }
        return retrospectiveUnavailable
    }

   // MARK: - Empty states

    /// An empty list is only ever a message *and* a next step. These are the
    /// message halves; the views pair them with a button.
    static let noReplyNeeded = "暂时没有等你回的话"
    static let noReplyNeededNext = "有新消息时，这里会先出现"
    static let noTasksDetected = "还没从聊天里认出要做的事"
    static let noTasksDetectedNext = "聊到明确的事，会自动归到这里"
    static let noDrafts = "还没有写好的回复"
    static let noDraftsNext = "从一条消息点「理解上下文与回复」开始写"
   static let noPendingReplies = "没有等确认的回复"
   static let noPendingRepliesNext = "AI 写好的回复会先停在这里等你点头"

    // MARK: - Island analysis

    static let analysisUnavailable = "这次没能整理出重点。请检查 AI 连接后再试。"
    static let analysisMissingMention = "找不到这条 @ 消息，没有用别的聊天代替。可再试一次，或到微信核对。"
    static let analysisNoMessages = "这段对话暂时没有可读的消息。"
    static let analysisReadFailed = "没能读到这段聊天。请确认微信已连接后再试。"
    static let replySuggestionsFailed = "回复建议没写出来"

    /// Last-mile filter for the island headline. Analyzer leftovers
    /// ("Prompt", "解析失败", localizedDescription) never paint.
    static func displayableAnalysisFailure(_ raw: String?) -> String {
        let text = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return analysisUnavailable }
        if text.contains("找不到这条") || (text.contains("@") && text.contains("找不到")) {
            return analysisMissingMention
        }
        if text.contains("没有找到消息") || text.contains("没有可读的消息") {
            return analysisNoMessages
        }
        if text.contains("读取消息") || text.contains("读不到这段聊天") {
            return analysisReadFailed
        }
        if text.contains("解析")
            || text.localizedCaseInsensitiveContains("prompt")
            || text.contains("HTTP")
            || text.contains("超时")
            || text.contains("localizedDescription") {
            return analysisUnavailable
        }
        if text.contains("再试") || text.contains("核对") {
            return text
        }
        return analysisUnavailable
    }

   // MARK: - Momentum

    /// The count work is *finished*, which is the number that actually feels
    /// good. A list that only ever shows what is left reads as a treadmill.
    static func handledToday(_ count: Int) -> String {
        count <= 0 ? "今天还没处理过消息" : "今天已经处理了 \(count) 条"
    }
    static func waitingOnOthers(_ count: Int) -> String {
        count <= 0 ? "没有在等别人回话" : "\(count) 件事在等对方"
    }
}
