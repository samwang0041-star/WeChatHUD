import XCTest
@testable import WeChatHUD

final class AutopilotSafetyTests: XCTestCase {

    // MARK: - AutopilotConfig defaults

    func testDefaultConfigValues() {
        let config = AutopilotConfig()
        XCTAssertEqual(config.maxSendsPerSession, 50)
        XCTAssertFalse(config.sensitiveKeywords.isEmpty)
        XCTAssertEqual(config.confidenceThreshold, 0.8)
        XCTAssertEqual(config.maxRepliesPerHour, 20)
        XCTAssertFalse(config.handleGroupAt)
        XCTAssertTrue(config.vipAutoNotify)
        XCTAssertFalse(config.autoSendEnabled)
    }

    func testGroupAtSettingIsTheQueueGate() {
        var off = AutopilotConfig()
        off.handleGroupAt = false
        XCTAssertTrue(off.shouldQueue(isGroup: false, isAtMention: false))
        XCTAssertFalse(off.shouldQueue(isGroup: true, isAtMention: true))
        XCTAssertFalse(off.shouldQueue(isGroup: true, isAtMention: false))

        var on = AutopilotConfig()
        on.handleGroupAt = true
        XCTAssertTrue(on.shouldQueue(isGroup: true, isAtMention: true))
        XCTAssertFalse(on.shouldQueue(isGroup: true, isAtMention: false))
    }

    func testDefaultSensitiveKeywordsContainFinancialTerms() {
        let config = AutopilotConfig()
        XCTAssertTrue(config.sensitiveKeywords.contains("转账"))
        XCTAssertTrue(config.sensitiveKeywords.contains("密码"))
        XCTAssertTrue(config.sensitiveKeywords.contains("银行卡"))
    }

    func testDefaultSensitiveKeywordsContainProfanity() {
        let config = AutopilotConfig()
        XCTAssertTrue(config.sensitiveKeywords.contains("骂"))
    }

    func testDefaultSensitiveKeywordsContainHRTerms() {
        let config = AutopilotConfig()
        XCTAssertTrue(config.sensitiveKeywords.contains("辞职"))
        XCTAssertTrue(config.sensitiveKeywords.contains("合同"))
    }

    // MARK: - Sensitive keyword detection (production rule)
    //
    // These used to re-implement the matching loop locally, with semantics that
    // differed from production (case-sensitive, reply text only), so the real
    // guardrail could have been deleted while all four stayed green.

    func testInboundTriggerTextHitsSensitiveKeywords() {
        let hold = AutopilotService.autopilotSafetyHoldReason(
            triggerText: "帮我转账 5000 给供应商",
            replyText: nil,
            risk: .low,
            reasonCode: nil,
            sensitiveKeywords: ["转账", "密码"]
        )
        XCTAssertEqual(hold, "命中敏感词「转账」")
    }

    func testKeywordMatchIsCaseInsensitive() {
        XCTAssertEqual(
            AutopilotService.autopilotSafetyHoldReason(
                triggerText: "send me the PASSWORD",
                replyText: nil,
                risk: .low,
                reasonCode: nil,
                sensitiveKeywords: ["password"]
            ),
            "命中敏感词「password」"
        )
    }

    func testKeywordScanCoversTheReplyToo() {
        XCTAssertEqual(
            AutopilotService.autopilotSafetyHoldReason(
                triggerText: "在吗", replyText: "我把密码发你", risk: .low,
                reasonCode: nil, sensitiveKeywords: ["密码"]
            ),
            "命中敏感词「密码」"
        )
    }

    func testTraditionalVariantStillHitsSimplifiedKeyword() {
        // 轉賬 must match the 转账 keyword: without Hant→Hans folding a
        // one-character variant swaps the whole safety decision.
        XCTAssertEqual(
            AutopilotService.autopilotSafetyHoldReason(
                triggerText: "幫我轉賬 5000", replyText: nil, risk: .low,
                reasonCode: nil, sensitiveKeywords: ["转账"]
            ),
            "命中敏感词「转账」"
        )
    }

    func testNonHanziMoneyCuesHoldWithoutKeywords() {
        // Emoji and pinyin spellings cannot live in the keyword list as
        // Hanzi, so they are built-in tripwires on the incoming text.
        XCTAssertEqual(
            AutopilotService.autopilotSafetyHoldReason(
                triggerText: "给你发了个🧧快收", replyText: "好", risk: .low,
                reasonCode: nil, sensitiveKeywords: []
            ),
            "疑似资金往来「🧧」，需本人处理"
        )
        XCTAssertEqual(
            AutopilotService.autopilotSafetyHoldReason(
                triggerText: "wo zhuanzhang gei ni le", replyText: "好", risk: .low,
                reasonCode: nil, sensitiveKeywords: []
            ),
            "疑似资金往来「zhuanzhang」，需本人处理"
        )
    }

    func testDefaultKeywordsCoverRedPacketAndSettlement() {
        let config = AutopilotConfig()
        XCTAssertTrue(config.sensitiveKeywords.contains("红包"))
        XCTAssertTrue(config.sensitiveKeywords.contains("到账"))
    }

    func testNegativeSendCapFallsBackToDefault() throws {
        // The send path treats <= 0 as unlimited, so a corrupted negative
        // must not silently lift the per-session cap.
        let data = #"{"maxSendsPerSession":-5}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AutopilotConfig.self, from: data)
        XCTAssertEqual(decoded.maxSendsPerSession, AutopilotConfig().maxSendsPerSession)
    }

    func testEmptyKeywordListReliesOnRiskAndReasonCode() {
        XCTAssertNil(
            AutopilotService.autopilotSafetyHoldReason(
                triggerText: "转账密码是123456", replyText: "好", risk: .low,
                reasonCode: nil, sensitiveKeywords: []
            )
        )
        XCTAssertEqual(
            AutopilotService.autopilotSafetyHoldReason(
                triggerText: "在吗", replyText: "好", risk: .low,
                reasonCode: "money", sensitiveKeywords: []
            ),
            "涉及转账或金钱内容"
        )
    }

    // MARK: - Session send limit (production rule)

    func testSessionLimitReachedSkipsTheSend() {
        let result = defaultDowngradeInput(sessionSent: 50, maxSendsPerSession: 50)
        XCTAssertEqual(result.action, .skipped)
        XCTAssertTrue(result.reasoning.contains("上限 50"))
    }

    func testSessionLimitNotReachedSends() {
        XCTAssertEqual(defaultDowngradeInput(sessionSent: 49, maxSendsPerSession: 50).action, .sent)
    }

    func testSessionLimitZeroMeansUnlimited() {
        XCTAssertEqual(defaultDowngradeInput(sessionSent: 10_000, maxSendsPerSession: 0).action, .sent)
    }

    // MARK: - AutopilotConfig Codable roundtrip

    func testAutopilotConfigCodable() throws {
        var config = AutopilotConfig()
        config.maxSendsPerSession = 100
        config.sensitiveKeywords = ["custom"]
        config.confidenceThreshold = 0.9
        config.autoSendEnabled = true

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AutopilotConfig.self, from: data)

        XCTAssertEqual(decoded.maxSendsPerSession, 100)
        XCTAssertEqual(decoded.sensitiveKeywords, ["custom"])
        XCTAssertEqual(decoded.confidenceThreshold, 0.9)
        XCTAssertTrue(decoded.autoSendEnabled)
    }

    // MARK: - Tolerant decoding

    func testConfigDecodesFromPartialJSONWithDefaults() throws {
        // A real stored row on this machine had 17 keys and no
        // `autoSendEnabled`. The synthesized decoder rejected the whole object,
        // `getSettingJSON` turned that into nil, every caller saw a fresh
        // default config, and the next save wrote those defaults over the
        // user's guardrails.
        let json = #"{"confidenceThreshold":0.65,"maxSendsPerSession":12}"#
        let decoded = try JSONDecoder().decode(AutopilotConfig.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.confidenceThreshold, 0.65)
        XCTAssertEqual(decoded.maxSendsPerSession, 12)
        XCTAssertFalse(decoded.autoSendEnabled)
        XCTAssertEqual(decoded.sensitiveKeywords, AutopilotConfig().sensitiveKeywords)
        XCTAssertEqual(decoded.sendKey, .cmdEnter)
    }

    func testConfigClampsOutOfRangeRatios() throws {
        // A hand-edited or corrupted row must not push the threshold outside
        // [0, 1]: a negative threshold would auto-send everything.
        let json = #"{"confidenceThreshold":-3,"silentNightThreshold":9}"#
        let decoded = try JSONDecoder().decode(AutopilotConfig.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.confidenceThreshold, 0)
        XCTAssertEqual(decoded.silentNightThreshold, 1)
    }

    // MARK: - Media confidence decay

    func testMediaDecayFactorIsApplied() {
        XCTAssertEqual(AutopilotService.effectiveConfidence(base: 0.9, hasMedia: true), 0.63, accuracy: 0.0001)
        XCTAssertEqual(AutopilotService.effectiveConfidence(base: 0.9, hasMedia: false), 0.9, accuracy: 0.0001)
    }

    /// A media reply at 0.9 sends on its own but must fall below the 0.8
    /// threshold once decayed. Deleting the decay, changing the factor, or
    /// swapping the two confidence inputs flips this test — the old suite could
    /// not see any of that because every downgrade test passed
    /// `confidence == originalConfidence`.
    func testMediaDecayCrossesTheSendThreshold() {
        let decayed = AutopilotService.effectiveConfidence(base: 0.9, hasMedia: true)
        let downgraded = defaultDowngradeInput(confidence: decayed, originalConfidence: 0.9)
        XCTAssertEqual(downgraded.action, .stall)
        XCTAssertTrue(downgraded.reasoning.contains("信心偏低"))
        XCTAssertEqual(defaultDowngradeInput(confidence: 0.9, originalConfidence: 0.9).action, .sent)
    }

    /// "群聊不自动发" (README) is enforced at the send gate, not only at the
    /// queue gate: an @-mention in a group can be drafted, but never sent
    /// unattended.
    func testGroupReplyAlwaysRequiresManualConfirmation() {
        XCTAssertEqual(
            AutopilotService.automaticSendHoldReason(
                safetyHold: nil,
                replyText: "收到，我看下",
                sensitiveKeywords: [],
                isGroup: true
            ),
            "群聊消息，请人工确认后发送"
        )
        XCTAssertNil(
            AutopilotService.automaticSendHoldReason(
                safetyHold: nil,
                replyText: "收到，我看下",
                sensitiveKeywords: [],
                isGroup: false
            )
        )
    }

    // MARK: - AutopilotAction and AutopilotRisk enums

    func testAutopilotActionRawValues() {
        XCTAssertEqual(AutopilotAction.sent.rawValue, "sent")
        XCTAssertEqual(AutopilotAction.pending.rawValue, "pending")
        XCTAssertEqual(AutopilotAction.queued.rawValue, "queued")
        XCTAssertEqual(AutopilotAction.skipped.rawValue, "skipped")
        XCTAssertEqual(AutopilotAction.vipNotified.rawValue, "vipNotified")
        XCTAssertEqual(AutopilotAction.failed.rawValue, "failed")
        XCTAssertEqual(AutopilotAction.groupLogged.rawValue, "groupLogged")
    }

    func testAutopilotRiskRawValues() {
        XCTAssertEqual(AutopilotRisk.low.rawValue, "low")
        XCTAssertEqual(AutopilotRisk.medium.rawValue, "medium")
        XCTAssertEqual(AutopilotRisk.high.rawValue, "high")
    }

    func testUnknownAutopilotActionForcesPending() throws {
        let json = """
        {"action":"something_else","reply":"我直接答应","confidence":0.95,"risk":"low","reasoning":"bad mixed schema","pending":false}
        """
        let decision = try JSONDecoder().decode(AutoReplyGenerator.Decision.self, from: Data(json.utf8))
        XCTAssertEqual(decision.action, "something_else")
        XCTAssertEqual(decision.pending, true)
        XCTAssertEqual(decision.skip, false)
        XCTAssertEqual(decision.readNoReply, false)
    }

    func testAutopilotActionPendingOverridesLegacyFalse() throws {
        let json = """
        {"action":"pending","reply":"我直接答应","confidence":0.95,"risk":"low","reasoning":"bad mixed schema","pending":false}
        """
        let decision = try JSONDecoder().decode(AutoReplyGenerator.Decision.self, from: Data(json.utf8))
        XCTAssertEqual(decision.pending, true)
        XCTAssertEqual(decision.skip, false)
        XCTAssertEqual(decision.readNoReply, false)
    }

    func testAutopilotActionSkipOverridesLegacyFalse() throws {
        let json = """
        {"action":"skip","reply":"我直接答应","confidence":0.95,"risk":"low","reasoning":"bad mixed schema","skip":false}
        """
        let decision = try JSONDecoder().decode(AutoReplyGenerator.Decision.self, from: Data(json.utf8))
        XCTAssertEqual(decision.pending, false)
        XCTAssertEqual(decision.skip, true)
        XCTAssertEqual(decision.readNoReply, false)
    }

    func testAutopilotActionReadNoReplyOverridesLegacyFalse() throws {
        let json = """
        {"action":"read_no_reply","reply":"我直接答应","confidence":0.95,"risk":"low","reasoning":"bad mixed schema","read_no_reply":false}
        """
        let decision = try JSONDecoder().decode(AutoReplyGenerator.Decision.self, from: Data(json.utf8))
        XCTAssertEqual(decision.pending, false)
        XCTAssertEqual(decision.skip, false)
        XCTAssertEqual(decision.readNoReply, true)
    }

    func testAutopilotRiskNormalizesCaseAndWhitespace() throws {
        let json = """
        {"action":"send","reply":"收到","confidence":0.95,"risk":" High ","reasoning":"case variant"}
        """
        let decision = try JSONDecoder().decode(AutoReplyGenerator.Decision.self, from: Data(json.utf8))
        XCTAssertEqual(decision.risk, "high")
    }

    func testUnknownAutopilotRiskFailsClosedHigh() throws {
        let json = """
        {"action":"send","reply":"收到","confidence":0.95,"risk":"safe","reasoning":"bad risk"}
        """
        let decision = try JSONDecoder().decode(AutoReplyGenerator.Decision.self, from: Data(json.utf8))
        XCTAssertEqual(decision.risk, "high")
    }

    // MARK: - AutopilotReplyStyle

    func testReplyStylePromptFragment() {
        XCTAssertTrue(AutopilotReplyStyle.auto.promptFragment.isEmpty)
        XCTAssertFalse(AutopilotReplyStyle.brief.promptFragment.isEmpty)
        XCTAssertFalse(AutopilotReplyStyle.detailed.promptFragment.isEmpty)
    }

    // MARK: - Session ledger (capacity + reset)

    /// Appending 25 entries must leave exactly 20 — oldest-first eviction.
    func testAppendLedgerEntryCapsAt20() {
        var ledger: [String: [LedgerEntry]] = [:]
        let chat = "wxid_test"
        for i in 0..<25 {
            let entry = LedgerEntry(
                timestamp: Date(timeIntervalSince1970: TimeInterval(i)),
                outgoingText: "msg \(i)",
                peerLastMessage: nil,
                topic: nil
            )
            ledger = ChatMonitor.ledgerByAppending(entry, to: ledger, for: chat)
        }
        let list = ledger[chat] ?? []
        XCTAssertEqual(list.count, 20, "ledger must cap at 20 entries per chat")
        // The first 5 entries (indices 0-4) should have been evicted;
        // the oldest remaining is index 5.
        XCTAssertEqual(list.first?.outgoingText, "msg 5")
        XCTAssertEqual(list.last?.outgoingText, "msg 24")
    }

    /// Resetting the ledger must clear every chat, not just one.
    func testResetSessionLedgerClearsAllChats() {
        var ledger: [String: [LedgerEntry]] = [:]
        let entryA = LedgerEntry(timestamp: Date(), outgoingText: "a", peerLastMessage: nil, topic: nil)
        let entryB = LedgerEntry(timestamp: Date(), outgoingText: "b", peerLastMessage: nil, topic: nil)
        ledger = ChatMonitor.ledgerByAppending(entryA, to: ledger, for: "chat_a")
        ledger = ChatMonitor.ledgerByAppending(entryB, to: ledger, for: "chat_b")
        XCTAssertEqual(ledger.count, 2)
        let cleared = ChatMonitor.ledgerByResetting(ledger)
        XCTAssertTrue(cleared.isEmpty, "reset must drop every chat's entries")
        XCTAssertNil(cleared["chat_a"])
        XCTAssertNil(cleared["chat_b"])
    }

    /// Prompt v3 must ship with every placeholder AutoReplyGenerator
    /// substitutes. If any go missing the reply will contain literal
    /// `{session_ledger}` style braces and the model will choke.
    func testPromptV4FileLoadsAndContainsPlaceholders() throws {
        let loader = PromptLoader()
        let template = try loader.load(version: "autopilot_reply_v4")
        for placeholder in [
            "{session_ledger}",
            "{conversation_memory}",
            "{context_window}",
            "{sender_name}",
            "{message_body}"
        ] {
            XCTAssertTrue(
                template.contains(placeholder),
                "autopilot_reply_v4 missing placeholder \(placeholder)"
            )
        }
    }

    // MARK: - applySafetyDowngrades

    private func defaultDowngradeInput(
        replyText: String = "好的，收到了",
        confidence: Double = 0.9,
        originalConfidence: Double = 0.9,
        risk: AutopilotRisk = .low,
        aiReasoning: String = "AI reasoning",
        attentionLevel: AttentionLevel = .whitelist,
        confidenceThreshold: Double = 0.8,
        sessionSent: Int = 0,
        maxSendsPerSession: Int = 50,
        sensitiveKeywords: [String] = [],
        styleScore: Int = 80,
        safetyHold: String? = nil
    ) -> (action: AutopilotAction, reasoning: String) {
        AutopilotService.applySafetyDowngrades(
            replyText: replyText,
            confidence: confidence,
            originalConfidence: originalConfidence,
            risk: risk,
            aiReasoning: aiReasoning,
            attentionLevel: attentionLevel,
            confidenceThreshold: confidenceThreshold,
            sessionSent: sessionSent,
            maxSendsPerSession: maxSendsPerSession,
            sensitiveKeywords: sensitiveKeywords,
            styleScore: styleScore,
            safetyHold: safetyHold
        )
    }

    func testDowngradeAllClearReturnsSent() {
        let result = defaultDowngradeInput()
        XCTAssertEqual(result.action, .sent)
        XCTAssertEqual(result.reasoning, "AI reasoning")
    }

    func testDowngradeVIPReturnsStall() {
        let result = defaultDowngradeInput(attentionLevel: .vip)
        XCTAssertEqual(result.action, .stall)
        XCTAssertTrue(result.reasoning.contains("VIP"))
    }

    func testDowngradeSafetyHoldReturnsStall() {
        let result = defaultDowngradeInput(safetyHold: "包含敏感请求")
        XCTAssertEqual(result.action, .stall)
        XCTAssertTrue(result.reasoning.contains("安全检查降级"))
    }

    func testDowngradeLowConfidenceReturnsStall() {
        let result = defaultDowngradeInput(confidence: 0.6, originalConfidence: 0.6)
        XCTAssertEqual(result.action, .stall)
        XCTAssertTrue(result.reasoning.contains("信心偏低"))
        XCTAssertTrue(result.reasoning.contains("60%"))
    }

    func testDowngradeMediumRiskReturnsStall() {
        let result = defaultDowngradeInput(risk: .medium)
        XCTAssertEqual(result.action, .stall)
        XCTAssertTrue(result.reasoning.contains("风险非低"))
    }

    func testDowngradeHighRiskReturnsStall() {
        let result = defaultDowngradeInput(risk: .high)
        XCTAssertEqual(result.action, .stall)
        XCTAssertTrue(result.reasoning.contains("风险非低"))
    }

    func testDowngradeSensitiveKeywordReturnsStall() {
        let result = defaultDowngradeInput(
            replyText: "我把密码发给你",
            sensitiveKeywords: ["密码", "转账"]
        )
        XCTAssertEqual(result.action, .stall)
        XCTAssertTrue(result.reasoning.contains("敏感词"))
        XCTAssertTrue(result.reasoning.contains("密码"))
    }

    func testSensitiveReplyIsHeldForManualConfirmation() {
        XCTAssertEqual(
            AutopilotService.automaticSendHoldReason(
                safetyHold: nil,
                replyText: "我把密码发给你",
                sensitiveKeywords: ["密码"]
            ),
            "回复含敏感词「密码」，请人工确认"
        )
        XCTAssertEqual(
            AutopilotService.automaticSendHoldReason(
                safetyHold: "命中敏感词「转账」",
                replyText: "好的",
                sensitiveKeywords: ["转账"]
            ),
            "安全检查：命中敏感词「转账」"
        )
        XCTAssertNil(
            AutopilotService.automaticSendHoldReason(
                safetyHold: nil,
                replyText: "好的，收到了",
                sensitiveKeywords: ["密码"]
            )
        )
        XCTAssertEqual(
            AutopilotService.automaticSendHoldReason(
                safetyHold: nil,
                replyText: "好的，我下午给你方案",
                sensitiveKeywords: ["密码"],
                downgradedAction: .stall
            ),
            "安全策略要求人工确认后再发送"
        )
        XCTAssertNil(
            AutopilotService.automaticSendHoldReason(
                safetyHold: nil,
                replyText: "先记下，回头回你",
                sensitiveKeywords: ["密码"],
                downgradedAction: .sent
            )
        )
    }

    func testHeldPendingSendIsNotEligibleForAutomaticSend() {
        let hold = AutopilotService.automaticSendHoldReason(
            safetyHold: nil,
            replyText: "我把密码发给你",
            sensitiveKeywords: ["密码"]
        )
        let item = PendingSend(
            chatUsername: "wxid_a",
            chatName: "A",
            senderName: "A",
            replyText: "我把密码发给你",
            confidence: 0.9,
            risk: .low,
            reasoning: "ok",
            styleScore: 80,
            scheduledSendTime: Date().addingTimeInterval(-1),
            manualOnlyReason: hold
        )
        XCTAssertNotNil(hold)
        XCTAssertFalse(AutopilotService.isEligibleForAutomaticSend(item, now: Date()))
        let clear = PendingSend(
            chatUsername: "wxid_a",
            chatName: "A",
            senderName: "A",
            replyText: "好的",
            confidence: 0.9,
            risk: .low,
            reasoning: "ok",
            styleScore: 80,
            scheduledSendTime: Date().addingTimeInterval(-1)
        )
        XCTAssertTrue(AutopilotService.isEligibleForAutomaticSend(clear, now: Date()))
        XCTAssertTrue(AutopilotService.isRetryableSendBusy("已有发送正在进行"))
        XCTAssertFalse(AutopilotService.isRetryableSendBusy("发送结果无法确认"))
        let busy = PendingSend(
            chatUsername: "wxid_a",
            chatName: "A",
            senderName: "A",
            replyText: "好的",
            confidence: 0.9,
            risk: .low,
            reasoning: "ok",
            styleScore: 80,
            scheduledSendTime: Date().addingTimeInterval(-1)
        )
        XCTAssertTrue(AutopilotService.isEligibleForAutomaticSend(busy, now: Date()))
    }

    func testDowngradeSensitiveKeywordEmptyReplyIsSafe() {
        let result = defaultDowngradeInput(
            replyText: "",
            sensitiveKeywords: ["密码"]
        )
        XCTAssertEqual(result.action, .sent)
    }

    func testDowngradeSensitiveKeywordNoMatchIsSafe() {
        let result = defaultDowngradeInput(
            replyText: "好的，收到了",
            sensitiveKeywords: ["密码"]
        )
        XCTAssertEqual(result.action, .sent)
    }

    func testDowngradeSessionCapReturnsSkipped() {
        let result = defaultDowngradeInput(sessionSent: 50, maxSendsPerSession: 50)
        XCTAssertEqual(result.action, .skipped)
        XCTAssertTrue(result.reasoning.contains("上限"))
    }

    func testDowngradeSessionCapZeroMeansUnlimited() {
        let result = defaultDowngradeInput(sessionSent: 999, maxSendsPerSession: 0)
        XCTAssertEqual(result.action, .sent)
    }

    func testDowngradeBadStyleScoreReturnsStall() {
        let result = defaultDowngradeInput(styleScore: 30)
        XCTAssertEqual(result.action, .stall)
        XCTAssertTrue(result.reasoning.contains("风格偏差"))
    }

    func testDowngradeStyleScoreExactly50IsSafe() {
        let result = defaultDowngradeInput(styleScore: 50)
        XCTAssertEqual(result.action, .sent)
    }

    /// When multiple rules trigger, the last one in order wins (matches original behavior).
    func testDowngradeMultipleRulesLastOneWins() {
        // VIP + safetyHold + low confidence: confidence is checked after safetyHold,
        // so confidence wins.
        let result = defaultDowngradeInput(
            confidence: 0.6,
            originalConfidence: 0.6,
            attentionLevel: .vip,
            safetyHold: "hold"
        )
        XCTAssertEqual(result.action, .stall)
        XCTAssertTrue(result.reasoning.contains("信心偏低"))
    }

    /// Session cap is checked after sensitive keywords but before style score.
    /// When cap is reached, it returns .skipped even if style is also bad.
    func testDowngradeSessionCapOverridesStyleStall() {
        let result = defaultDowngradeInput(
            sessionSent: 50,
            maxSendsPerSession: 50,
            styleScore: 30
        )
        XCTAssertEqual(result.action, .skipped)
    }

    // MARK: - Display labels

    /// The UI must never render rawValue ("high"/"medium") — `label`
    /// is the user-facing Chinese form.
    func testRiskLabelIsChinese() {
        XCTAssertEqual(AutopilotRisk.low.label, "低")
        XCTAssertEqual(AutopilotRisk.medium.label, "中")
        XCTAssertEqual(AutopilotRisk.high.label, "高")
        for risk in [AutopilotRisk.low, .medium, .high] {
            XCTAssertNotEqual(risk.label, risk.rawValue)
        }
    }

    // MARK: - Read-receipt open-chat gate (P1-2)

    /// Opening a WeChat window to leave a read receipt is an outward action,
    /// so it is gated exactly like a send: only full-auto private chats may
    /// open unattended. Group chats and disabled autopilot both decline.
    func testReadReceiptOpenChatGate() {
        XCTAssertTrue(
            AutopilotService.shouldOpenChatForReadReceipt(autoSendEnabled: true, isGroup: false),
            "full-auto private chat is the only case that may open the window"
        )
        XCTAssertFalse(
            AutopilotService.shouldOpenChatForReadReceipt(autoSendEnabled: true, isGroup: true),
            "a group chat must never be opened just to fake-read a message"
        )
        XCTAssertFalse(
            AutopilotService.shouldOpenChatForReadReceipt(autoSendEnabled: false, isGroup: false),
            "with autopilot off, read-no-reply is a human decision"
        )
        XCTAssertFalse(
            AutopilotService.shouldOpenChatForReadReceipt(autoSendEnabled: false, isGroup: true)
        )
    }

    /// The two decline reasons are what the autopilot log shows; pin the exact
    /// strings the branches log so they cannot silently change.
    func testReadReceiptHoldReasonStrings() {
        XCTAssertEqual(AutopilotService.readReceiptHoldReason(isGroup: true), "群聊消息，请人工确认")
        XCTAssertEqual(
            AutopilotService.readReceiptHoldReason(isGroup: false),
            "未开启自动发送，已读不回需人工确认"
        )
    }
}
