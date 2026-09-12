import Foundation

/// First-launch copy and empty-state policy. Views render this; tests lock
/// the new-user contract so a first install stays explainable in plain language.
enum FirstLaunchGuide {
    static let productName = CompanionProductCopy.brandName
    static let productPitch = "从你选的微信对话里整理待回和待办。数据在本机。"
    static let neverAutoSend = "不会自动发消息。草稿需确认后才发。"
    static let timeEstimate = "大约 3 分钟"
    static let finishCTA = "开始使用"
    static let skipCTA = "稍后设置"
    static let startCTA = "开始设置"
    static let nextCTA = "下一步"
    static let backCTA = "上一步"

    static let stepTitles = ["连接微信", "选择关注", "开始使用"]
    /// Two content pages; the third stepper label is the start CTA on page 2.
    static let contentPageCount = 2

    /// Labels the step indicator is allowed to draw.
    ///
    /// Only `contentPageCount` dots are rendered: the third label describes
    /// the start action that page 2's CTA performs, and drawing it as an
    /// unreachable dot made a finished setup look like it was missing a step.
    /// Derived from `stepTitles` so the two can never disagree.
    static var pageTitles: [String] {
        Array(stepTitles.prefix(contentPageCount))
    }

    /// Label for one rendered page. Returns the start CTA label rather than
    /// crashing if a caller ever asks past the last page.
    static func pageTitle(at index: Int) -> String {
        guard index >= 0, index < pageTitles.count else { return finishCTA }
        return pageTitles[index]
    }


    static func primaryCTA(forStep step: Int) -> String {
        step == 0 ? nextCTA : finishCTA
    }

    static let welcomeNeeds = [
        "这台 Mac 已安装并登录微信",
        "可选：一个 AI 服务的访问密钥，用来写摘要和回复草稿"
    ]

    static let welcomeCapabilities: [(icon: String, title: String, detail: String)] = [
        ("bubble.left.and.text.bubble.right", "群里有人 @ 你", "显示群聊摘要。"),
        ("checkmark.bubble", "有人让你办事", "记下待办和截止时间。"),
        ("square.and.pencil", "需要回复时", "起草回复，确认后发送。")
    ]

    static let finishRecipe: [(icon: String, title: String, detail: String)] = [
        ("sun.max", "先看「今天」", "待回和待办列在上面。"),
        ("text.bubble", "点开一条消息", "看摘要和原文。"),
        ("hand.raised", "发送前再确认一次", "不会自动发送。")
    ]

    /// Words a first-run screen must not show. Technical recovery stays in
    /// diagnostics, not in the guided path.
    static let forbiddenFirstRunJargon = [
        "解密密钥", "解密钥匙", "db_storage", "session.db", "HMAC",
        "codesign", "all_keys.json", "白名单", "工作台"
    ]

    // MARK: - Connection

    enum ConnectionState: Equatable {
        case applying
        case probing
        case syncing
        case connected
        case wechatNotInstalled
        case wechatNotRunning
        case preparingIdle
        case preparingWaitingRelogin
        case preparingExtracting
        case preparingFailed
        case readyToRestart
        case needsAccountSelection
        case syncFailed
        case idle
    }

    struct Checkpoint: Equatable {
        let title: String
        let complete: Bool
    }

    struct ConnectionCopy: Equatable {
        let title: String
        let detail: String
        let buttonTitle: String
        let checkpoints: [Checkpoint]
        let preparationCheckpoints: [Checkpoint]
        let consentTitle: String
        let consentMessage: String
        let pickerTitle: String
        let pickerMessage: String
        let pickerMiss: String
    }

    static let consentTitle = "需要一次本机准备"
    static let consentMessage = "需要一次本机读取准备，大约 1–2 分钟。微信可能会关闭，重新打开并登录即可。聊天记录不会改动。"
    static let pickerTitle = "允许读取这个微信账号"
    static let pickerMessage = "已找到微信资料。点「允许读取」。"
    static let pickerMiss = "这个文件夹里没有找到微信聊天。请先打开并登录微信，或回到微信账号资料再试。"

    static func connection(
        state: ConnectionState,
        wechatRunning: Bool,
        accessReady: Bool,
        connected: Bool,
        preparationSigned: Bool = false,
        preparationReloginComplete: Bool = false,
        preparationExtractComplete: Bool = false,
        failureReason: String? = nil
    ) -> ConnectionCopy {
        let title: String
        let detail: String
        let buttonTitle: String
        switch state {
        case .applying:
            title = "正在应用连接"
            detail = "WeChatHUD 会重新打开，然后继续检查能不能读到聊天。"
            buttonTitle = "正在应用…"
        case .probing:
            title = "正在检查微信"
            detail = "请稍等，正在确认当前登录的微信账号。"
            buttonTitle = "正在检查微信…"
        case .syncing:
            title = "正在读取你的聊天"
            detail = "请稍等，读完后会自动更新。"
            buttonTitle = "正在读取…"
        case .connected:
            title = "微信已连接"
            detail = "下一步：选择要整理的对话。"
            buttonTitle = "检查更新"
        case .wechatNotInstalled:
            title = "先在这台 Mac 安装微信"
            detail = "安装并登录后，回到这里继续连接。"
            buttonTitle = "下载微信"
        case .wechatNotRunning:
            title = "请先打开并登录微信"
            detail = "打开微信并完成登录后，再回到这里点一次连接。"
            buttonTitle = "打开微信"
        case .preparingIdle:
            title = "还差一次本机准备"
            detail = "需要做一次读取准备，大约 1–2 分钟。微信可能会关闭，你再打开并登录即可。聊天记录不会被改动。"
            buttonTitle = "开始准备"
        case .preparingWaitingRelogin:
            title = "请重新打开微信并登录"
            detail = "本机准备已经开始。请打开微信并登录，完成后会自动继续。"
            buttonTitle = "开始准备"
        case .preparingExtracting:
            title = "正在完成本机读取准备"
            detail = "请稍等，完成后会自动更新。聊天记录不会被改动。"
            buttonTitle = "开始准备"
        case .preparingFailed:
            title = "准备没有完成"
            detail = "没有成功：\(userFacingPreparationError(failureReason ?? ""))可以重试，或稍后再试。"
            buttonTitle = "重试准备"
        case .readyToRestart:
            title = "准备好了，继续完成连接"
            detail = "点继续后，WeChatHUD 会重新打开并确认能读到聊天。"
            buttonTitle = "继续连接"
        case .needsAccountSelection:
            title = "需要重新选择微信账号"
            detail = "之前选择的微信账号已经读不到了。请选择当前登录的账号；不会自动换号。"
            buttonTitle = "选择微信账号"
        case .syncFailed:
            title = "暂时未能连接微信"
            detail = "请确认微信已经登录，再试一次。已保存的设置和关注范围都会保留。"
            buttonTitle = "重试连接"
        case .idle:
            title = "连接你的微信"
            detail = "先在这台 Mac 打开并登录微信。点连接后，按提示允许读取即可。"
            buttonTitle = "连接微信"
        }

        return ConnectionCopy(
            title: title,
            detail: detail,
            buttonTitle: buttonTitle,
            checkpoints: [
                Checkpoint(title: "打开并登录微信", complete: wechatRunning || connected),
                Checkpoint(title: "允许读取聊天", complete: accessReady || connected),
                Checkpoint(title: "确认能读到消息", complete: connected)
            ],
            preparationCheckpoints: [
                Checkpoint(title: "准备本机读取", complete: preparationSigned || preparationExtractComplete),
                Checkpoint(title: "重新打开微信并登录", complete: preparationReloginComplete || preparationExtractComplete),
                Checkpoint(title: "完成读取检查", complete: preparationExtractComplete)
            ],
            consentTitle: consentTitle,
            consentMessage: consentMessage,
            pickerTitle: pickerTitle,
            pickerMessage: pickerMessage,
            pickerMiss: pickerMiss
        )
    }

    static func userFacingPreparationError(_ reason: String) -> String {
        let text = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return "这次准备没有完成，请重试。" }
        if text.contains("密钥提取工具不存在") || text.contains("准备组件没有随应用安装") {
            return "这次安装不完整，请重新安装 WeChatHUD 后再试。"
        }
        if text.contains("微信数据目录不存在") || text.contains("还没有选定微信账号") {
            return "找不到当前微信账号资料，请重新选择账号。"
        }
        if text.contains("没有找到微信") {
            return "没有找到微信，请先安装并登录微信。"
        }
        if text.contains("提取输出中没有可用") || text.contains("没有可用的数据库密钥") {
            return "没有读取到可用的准备结果。请重新打开微信并登录后再试。"
        }
        if text.contains("HMAC") || text.contains("未通过数据库") {
            return "这次准备没有通过验证，请重试。"
        }
        if text.contains("重签") || text.contains("签名") {
            return "本机准备没有完成。如果刚刚拒绝了系统提示，请允许后再试。"
        }
        if text.contains("密钥提取失败") || text.contains("提取") {
            return "这次准备没有完成，请重试。"
        }
        if forbiddenFirstRunJargon.contains(where: { text.contains($0) }) {
            return "这次准备没有完成，请重试。"
        }
        return text.hasSuffix("。") ? text : text + "。"
    }

    // MARK: - AI / contacts

    static let aiTitle = "AI 分析"
    static let aiSubtitle = "没有 AI 也能看微信原文。摘要、@你的原因和回复草稿，需要一个可用的 AI 服务。"
    static let aiPrivacy = "相关聊天片段会发送给这个服务。连接测试只发送测试文本，不含聊天记录。"
    static let aiSkipHint = "可以先跳过，稍后再设。"

    static let contactsTitle = "从一个人或一个群开始"
    static let contactsSubtitle = "选择要整理的对话。"
    static let contactsSkipHint = "可以先跳过，稍后在「今天」里添加。"
    static let contactsFooter = "只整理你选中的对话，之后可以随时调整。AI 可选，不影响开始使用。"
    static let islandConnectTitle = "先连接微信"
    static let islandConnectDetail = "登录这台 Mac 的微信。"
    static let islandConnectPrivacy = ["只整理你关注的对话。", "自动回复默认关闭。"]

    static func remainingActionDetail(_ action: OnboardingReadinessAction) -> String {
        switch action {
        case .wechatConnection: return "回到上一步，打开微信并允许读取。"
        case .configureAI: return "选一个服务，填入密钥，点测试连接。"
        case .testAI: return "设置已保存，还差一次测试。"
        case .chooseContacts: return "先加一个人或一个群。"
        }
    }

    // MARK: - Workspace empty states

    struct EmptyCopy: Equatable {
        let title: String
        let detail: String
    }

    static func todayEmpty(
        wechatConnected: Bool,
        hasTrackedConversations: Bool,
        aiConfigured: Bool,
        aiTested: Bool,
        searching: Bool,
        hasOpenTasks: Bool = false,
        hasOtherInboxItems: Bool = false
    ) -> EmptyCopy {
        if searching {
            return EmptyCopy(title: "没有匹配的消息", detail: "试试联系人姓名或消息里的关键词。")
        }
        if !wechatConnected {
            return EmptyCopy(
                title: "还不能整理消息",
                detail: "先完成微信连接。连上以后从关注的对话里找待办。"
            )
        }
        if !hasTrackedConversations {
            return EmptyCopy(
                title: "还没有关注的对话",
                detail: "先选一个联系人或群聊。只整理你选中的对话。"
            )
        }
        if hasOpenTasks || hasOtherInboxItems {
            var sentences: [String] = []
            if hasOpenTasks {
                sentences.append("待办还在「我要做」和「等对方」里，答应过的事在右侧。")
            }
            if hasOtherInboxItems {
                sentences.append("点「全部」可查看普通更新；知会类消息不算必须回复。")
            } else {
                sentences.append("点过去处理，不必等新消息。")
            }
            return EmptyCopy(
                title: "没有需要回复的消息",
                detail: sentences.joined()
            )
        }
        if !aiConfigured {
            return EmptyCopy(
                title: "摘要和草稿还没准备好",
                detail: "没有 AI 也能看微信原文。选一个服务并测试连接后，今天才会出现摘要和回复建议。"
            )
        }
        if !aiTested {
            return EmptyCopy(
                title: "还差一次 AI 连接测试",
                detail: "配置已填写。测通后才会出现摘要和回复草稿。"
            )
        }
        return EmptyCopy(
            title: "没有待处理的事",
            detail: "没有新消息。"
        )
    }

    static func compactEmpty(wechatConnected: Bool, hasTrackedConversations: Bool) -> String {
        if !wechatConnected { return "还没连接微信" }
        if !hasTrackedConversations { return "还没选择对话" }
        return "没有待处理的事"
    }

    static let setupCardTitle = "还差几步就能开始"
    static let setupCardSubtitle = "按顺序完成。"

    static func setupStepDetail(_ action: OnboardingReadinessAction) -> String {
        switch action {
        case .wechatConnection: return "打开微信并允许读取。有时需要重新登录一次微信，聊天不会被改动。"
        case .configureAI: return "选一个服务，填入密钥，再点测试连接。"
        case .testAI: return "配置已填写，还差一次明确的连接测试。"
        case .chooseContacts: return "先加一个人或一个群。"
        }
    }

    // MARK: - Conversation suggestions

    private static let noisePrefixes: [String] = [
        "gh_", "fmessage", "medianote", "newsapp", "notification_", "notifymessage",
        "floatbottle", "qqmail", "brandsessionholder", "masssend", "officialaccounts", "tmessage"
    ]
    private static let noiseExact: Set<String> = [
        "weixin", "filehelper", "voip", "voipapp", "qqsync", "qqsafe", "facebook", "feedsapp"
    ]

    static func isSkippableUsername(_ username: String) -> Bool {
        if noiseExact.contains(username) { return true }
        if username.contains("@openim") || username.contains("@im.chatroom") { return true }
        return noisePrefixes.contains { username.hasPrefix($0) }
    }

    static func suggestedConversations(
        from sessions: [SessionInfo],
        excluding: Set<String>,
        limit: Int = 20
    ) -> [SessionInfo] {
        sessions
            .filter { !excluding.contains($0.username) }
            .filter { !isSkippableUsername($0.username) }
            .sorted {
                if $0.lastTimestamp != $1.lastTimestamp { return $0.lastTimestamp > $1.lastTimestamp }
                return $0.username < $1.username
            }
            .prefix(limit)
            .map { $0 }
    }
}

extension OnboardingReadinessAction {
    var detail: String { FirstLaunchGuide.remainingActionDetail(self) }
}
