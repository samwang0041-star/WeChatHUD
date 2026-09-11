import Foundation

/// First-launch copy and empty-state policy. Views render this; tests lock
/// the new-user contract so a first install stays explainable in plain language.
enum FirstLaunchGuide {
    static let finishCTA = "开始使用"
    static let skipCTA = "稍后设置"
    static let nextCTA = "下一步"
    static let backCTA = "上一步"

    /// Two content pages (连接微信 / 选择关注); the third stepper label is
    /// the start CTA on page 2.
    static let stepTitles = ["连接微信", "选择关注", "开始使用"]

    static func primaryCTA(forStep step: Int) -> String {
        step == 0 ? nextCTA : finishCTA
    }

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
    static let consentMessage = "助手会在这台 Mac 上做一次读取准备，大约 1–2 分钟。微信可能会关闭，你需要重新打开并登录。聊天记录不会被改动，也可以随时取消。"
    static let pickerTitle = "允许读取这个微信账号"
    static let pickerMessage = "已帮你找到微信资料位置。直接点「允许读取」即可，不用自己找文件夹。"
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
            detail = "助手会重新打开，然后继续检查能不能读到聊天。"
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
            detail = "新消息会自动更新。下一步选出真正需要帮忙的对话。"
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
            detail = "点继续后，助手会重新打开并确认能读到聊天。"
            buttonTitle = "继续连接"
        case .needsAccountSelection:
            title = "需要重新选择微信账号"
            detail = "之前选择的微信账号已经读不到了。请选择当前登录的账号；助手不会自动换号。"
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
            return "这次安装不完整，请重新安装助手后再试。"
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

    static let contactsTitle = "从一个人或一个群开始"
    static let contactsSubtitle = "先选择你想让不漏事帮你整理的对话，之后可以随时调整。"
    static let contactsSkipHint = "可以先跳过，稍后在「今天」里添加。"
    static let contactsFooter = "只整理你选中的对话，之后可以随时调整。AI 可选，不影响开始使用。"
    static let islandConnectTitle = "先连接微信，重要的事才不会漏。"
    static let islandConnectDetail = "登录这台 Mac 的微信后，就可以开始。"
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
        searching: Bool
    ) -> EmptyCopy {
        if searching {
            return EmptyCopy(title: "没有匹配的消息", detail: "试试联系人姓名或消息里的关键词。")
        }
        if !wechatConnected {
            return EmptyCopy(
                title: "还不能整理消息",
                detail: "先完成微信连接。连上以后，助手会从你关注的对话里找出该处理的事。"
            )
        }
        if !hasTrackedConversations {
            return EmptyCopy(
                title: "还没有关注的对话",
                detail: "先选一个联系人或群聊。助手只整理你选中的对话，不会查看全部微信。"
            )
        }
        if !aiConfigured || !aiTested {
            return EmptyCopy(
                title: "暂时没有需要处理的消息",
                detail: "原文已经可以查看。设置并测试 AI 后，才会出现摘要和回复草稿。"
            )
        }
        return EmptyCopy(
            title: "现在没有需要你处理的事。",
            detail: "有重要消息时，我会提醒你。"
        )
    }

    static func compactEmpty(wechatConnected: Bool, hasTrackedConversations: Bool) -> String {
        if !wechatConnected { return "还没连接微信" }
        if !hasTrackedConversations { return "还没选择对话" }
        return "现在没有需要你处理的事。"
    }

    static let setupCardTitle = "还差几步就能开始"
    static let setupCardSubtitle = "按顺序点下去即可。没做完时，今天页不会假装已经在工作。"

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
