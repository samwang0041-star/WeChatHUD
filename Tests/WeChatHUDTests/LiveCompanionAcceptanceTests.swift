import Foundation
import XCTest
@testable import WeChatHUD

/// Opt-in, synthetic end-to-end checks for the configured AI provider.
///
/// These tests never read the WeChat database or the production HUD store. They
/// only run when WCHUD_LIVE_COMPANION_AI=1 is explicitly supplied, and they
/// load the provider configuration from the device settings file without ever
/// printing its contents. The inputs are fictional project-chat messages.
final class LiveCompanionAcceptanceTests: XCTestCase {
    private var store: HUDStore!
    private var temporaryDirectoryURL: URL!
    private var temporaryDatabaseURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wechathud-live-companion-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        temporaryDatabaseURL = temporaryDirectoryURL.appendingPathComponent("hud.sqlite3")
        store = HUDStore(dbPath: temporaryDatabaseURL.path)
        try store.open()
    }

    override func tearDown() {
        store.close()
        try? FileManager.default.removeItem(at: temporaryDirectoryURL)
        super.tearDown()
    }

    func testSingleReadableMessageIsNotReportedAsNoContent() async throws {
        guard ProcessInfo.processInfo.environment["WCHUD_LIVE_COMPANION_AI"] == "1" else {
            throw XCTSkip("opt-in only: calls the configured provider")
        }
        let config = try loadConfiguredAI()
        guard isUsable(config) else { throw XCTSkip("device AI configuration is incomplete") }
        try store.setSettingJSON("ai", value: config)
        let analyzer = AIChatInsight(store: store, aiService: AIService(config: config))
        let result = await analyzer.analyzeChat(
            chatUsername: "synthetic-sparse-chat", chatName: "测试号", chatType: "private",
            category: "other", selfName: "我", selfAliases: ["我"], timeRange: "2026-09-08",
            messages: [(sender: "我", body: "WeChatHUD 发送测试，请忽略。", time: 1_788_842_400)],
            recalledMessages: [], memory: ""
        )
        let insight = try XCTUnwrap(result)
        XCTAssertFalse(insight.headline.contains("暂无可读内容"))
        XCTAssertFalse(insight.insight.contains("暂无可读内容"), insight.insight)
        XCTAssertTrue((insight.headline + insight.insight).contains("测试"))
        XCTAssertTrue(insight.myCommitments.isEmpty)
        XCTAssertTrue(insight.waitingForMe.isEmpty)
        XCTAssertFalse(insight.needsMyAttention)
    }

    func testSyntheticGroupAnalysisAnchorsMyActionToTriggeredMention() async throws {
        guard ProcessInfo.processInfo.environment["WCHUD_LIVE_COMPANION_AI"] == "1" else {
            throw XCTSkip("opt-in only: set WCHUD_LIVE_COMPANION_AI=1 to call the configured provider")
        }

        let config = try loadConfiguredAI()
        guard isUsable(config) else {
            throw XCTSkip("device AI configuration is absent or incomplete")
        }
        try store.setSettingJSON("ai", value: config)

        let trigger = MessageInfo(
            id: "synthetic-budget-trigger-001",
            chatUsername: "synthetic-budget-group",
            chatName: "预算协作群（合成锚点验收）",
            senderUsername: "synthetic-linxiao",
            senderName: "林晓",
            text: "@我 请核对本月预算，今天下班前给我结论",
            baseType: 1,
            subType: 0,
            createTime: 1_788_842_403
        )
        // ChatAnalyzer expects newest-first input. The later meeting request and
        // claim must not steal the action from the explicitly triggered @我 item.
        let messages = [
            MessageInfo(
                id: "synthetic-meeting-claim-003",
                chatUsername: "synthetic-budget-group",
                chatName: "预算协作群（合成锚点验收）",
                senderUsername: "synthetic-xiaocheng",
                senderName: "小陈",
                text: "已认领，我来订明天10点的会议室。",
                baseType: 1,
                subType: 0,
                createTime: 1_788_842_405
            ),
            MessageInfo(
                id: "synthetic-meeting-request-002",
                chatUsername: "synthetic-budget-group",
                chatName: "预算协作群（合成锚点验收）",
                senderUsername: "synthetic-zhouning",
                senderName: "周宁",
                text: "@小陈，麻烦你订一下明天10点的会议室。",
                baseType: 1,
                subType: 0,
                createTime: 1_788_842_404
            ),
            trigger
        ]

        let analyzer = ChatAnalyzer(store: store, aiService: AIService(config: config))
        let (result, error) = await analyzer.analyzeGroup(
            chatUsername: "synthetic-budget-group",
            chatName: "预算协作群（合成锚点验收）",
            messages: messages,
            myUsername: "synthetic-me",
            myName: "我",
            myDisplayName: "我",
            mySelfNames: ["我", "小王"],
            triggerMessage: trigger
        )

        XCTAssertNil(error, error ?? "ChatAnalyzer returned an error")
        let analysis = try XCTUnwrap(result)
        let action = analysis.my_action_items ?? ""
        let oneLiner = analysis.one_liner
        let combined = action + " " + oneLiner
        print("[WCHUD] synthetic group anchor result: my_action_items=\(clipped(action)); one_liner=\(clipped(oneLiner)); status=\(analysis.status)")

        XCTAssertTrue(combined.contains("预算"), "triggered @我 request must remain visible in action or one-liner: \(combined)")
        XCTAssertFalse(action.contains("会议室") || action.contains("订会议") || action.contains("预订"),
                       "meeting-room task claimed by 小陈 must not be assigned to 我: \(action)")
        XCTAssertFalse(action.contains("小陈"), "another colleague's claimed task must not become my action: \(action)")
        XCTAssertFalse(combined.contains("我订会议室") || combined.contains("我来订") || combined.contains("由我订"),
                       "meeting-room task must not be attributed to 我 in the summary: \(combined)")
    }

    func testSyntheticCompanionAIFlow() async throws {
        guard ProcessInfo.processInfo.environment["WCHUD_LIVE_COMPANION_AI"] == "1" else {
            throw XCTSkip("opt-in only: set WCHUD_LIVE_COMPANION_AI=1 to call the configured provider")
        }

        let config = try loadConfiguredAI()
        guard isUsable(config) else {
            throw XCTSkip("device AI configuration is absent or incomplete")
        }
        // Keep the real provider configuration in the temporary store only;
        // no production HUD database is opened or modified by this test.
        try store.setSettingJSON("ai", value: config)
        let service = AIService(config: config)
        let provider = config.provider.providerID
        let model = config.provider.model
        var evidence = Evidence(providerID: provider, model: model)
        defer { writeEvidence(evidence) }

        let classifier = AIClassifier(store: store, aiService: service)
        let classified = await classifier.classify(
            message: ClassifierInput(
                msgUID: "synthetic-group-at-001",
                text: "@我 请在今天17:00前把风险清单发到项目群，收到后回复一下",
                senderName: "林晓",
                chatName: "项目协作群（合成验收）",
                isGroup: true
            ),
            recipientContext: .init(
                myUsername: "synthetic-me",
                myDisplayName: "我",
                mySelfNames: ["我", "小王"],
                precedingMessages: "林晓：客户今晚要看风险清单。\n我：我先整理。"
            )
        )
        if let classified {
            evidence.classifier = .init(
                status: "returned",
                isAsk: classified.isAsk,
                type: classified.type.rawValue,
                confidence: classified.confidence,
                summary: clipped(classified.summary),
                deadlinePresent: classified.deadlineRelative != nil
            )
            XCTAssertTrue(classified.isAsk, "group @me request should be recognized as an ask")
            XCTAssertNotEqual(classified.type, .none, "an explicit delivery request needs an action type")
            XCTAssertGreaterThan(classified.confidence, 0.4)
            XCTAssertFalse(classified.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            XCTAssertTrue(classified.summary.contains("风险清单"), "classifier summary must retain the requested deliverable")
            XCTAssertNotNil(classified.deadlineRelative, "classifier must extract the explicit deadline")
        } else {
            evidence.classifier = .failed
            XCTFail("AIClassifier returned nil after its bounded retry")
        }

        let catchup = AIGroupCatchup(store: store, aiService: service)
        let catchupResult = await catchup.summarize(.init(
            chatName: "项目协作群（合成验收）",
            selfName: "我",
            messages: [
                (sender: "林晓", body: "客户今晚要看风险清单"),
                (sender: "周宁", body: "我把接口异常日志补上了"),
                (sender: "林晓", body: "@我 请在今天17:00前把风险清单发到群里"),
                (sender: "我", body: "好的，我整理完发"),
                (sender: "周宁", body: "收到后我们再一起过一遍")
            ]
        ))
        if let catchupResult {
            evidence.groupCatchup = .init(
                status: "returned",
                headline: clipped(catchupResult.headline),
                highlightCount: catchupResult.highlights.count,
                needsUserAction: catchupResult.needsUserAction,
                actionSummary: clipped(catchupResult.actionSummary),
                skipSafe: catchupResult.skipSafe
            )
            XCTAssertFalse(catchupResult.headline.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            XCTAssertFalse(catchupResult.highlights.isEmpty, "catch-up should retain concrete group highlights")
            XCTAssertTrue(catchupResult.needsUserAction, "explicit @me delivery request needs user action")
            XCTAssertFalse(catchupResult.actionSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            XCTAssertTrue(catchupResult.actionSummary.contains("风险清单"), "catch-up action must retain the requested deliverable")
        } else {
            evidence.groupCatchup = .failed
            XCTFail("AIGroupCatchup returned nil after its bounded retry")
        }

        let chatInsight = AIChatInsight(store: store, aiService: service)
        let insightResult = await chatInsight.analyzeChat(
            chatUsername: "synthetic-project-group",
            chatName: "项目协作群（合成验收）",
            chatType: "group",
            category: "work",
            selfName: "我",
            selfAliases: ["我", "小王"],
            timeRange: "今天",
            messages: [
                (sender: "林晓", body: "客户今晚要看风险清单", time: 1_700_000_001),
                (sender: "周宁", body: "我把接口异常日志补上了", time: 1_700_000_002),
                (sender: "林晓", body: "@我 请在今天17:00前把风险清单发到群里", time: 1_700_000_003),
                (sender: "我", body: "好的，我今天17:00前发最终风险清单", time: 1_700_000_004)
            ],
            recalledMessages: [],
            memory: "项目群正在推进风险清单交付。",
            recentContext: "昨天只讨论了接口日志，今天新增风险清单交付。"
        )
        if let insightResult {
            let actionOwners = insightResult.actionItems.map(\.who)
            let commitmentTexts = insightResult.myCommitments
            evidence.chatInsight = .init(
                status: "returned",
                headline: clipped(insightResult.headline),
                insight: clipped(insightResult.insight),
                suggestion: clipped(insightResult.suggestion),
                mentionsMe: insightResult.mentionsMe,
                actionItemCount: insightResult.actionItems.count,
                actionOwners: actionOwners,
                commitments: commitmentTexts.map { clipped($0) },
                needsMyAttention: insightResult.needsMyAttention
            )
            XCTAssertFalse(insightResult.headline.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            XCTAssertFalse(insightResult.insight.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            XCTAssertFalse(insightResult.suggestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            XCTAssertGreaterThanOrEqual(insightResult.mentionsMe, 1)
            XCTAssertTrue(insightResult.actionItems.contains { item in
                item.who == "我" && item.what.contains("风险清单")
            }, "chat insight must attribute the risk-list action to 我")
            XCTAssertTrue(commitmentTexts.contains { $0.contains("风险清单") }, "chat insight must retain the self-commitment")
            XCTAssertFalse(insightResult.headline.contains("已完成"), "input contains a promise, not evidence of completion")
        } else {
            evidence.chatInsight = .failed
            XCTFail("AIChatInsight returned nil after its bounded retry")
        }

        let replySuggester = AIReplySuggester(store: store, aiService: service)
        let suggestions = await replySuggester.suggest(.init(
            messageBody: "@我 今天17:00前把风险清单发群里，可以吗？",
            senderName: "林晓",
            chatName: "项目协作群（合成验收）",
            isGroup: true,
            askType: .sendFile,
            relationship: "work",
            contextWindow: "林晓：客户今晚要看风险清单\n我：我整理完发",
            myLastReply: "我整理完发",
            analysisSummary: "群聊中直接@我，要求今天17:00前发送风险清单",
            knownConstraints: "发送前需要确认最终版本"
        ))
        if let suggestions {
            evidence.replySuggestions = .init(
                status: "returned",
                count: suggestions.count,
                texts: suggestions.map { clipped($0.text) },
                tones: suggestions.map(\.tone),
                safeToSend: suggestions.map(\.safeToSend)
            )
            XCTAssertGreaterThanOrEqual(suggestions.count, 1)
            XCTAssertTrue(suggestions.allSatisfy { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            XCTAssertTrue(suggestions.allSatisfy { !$0.tone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        } else {
            evidence.replySuggestions = .failed
            XCTFail("AIReplySuggester returned nil after its bounded retry")
        }

        let autoReply = AutoReplyGenerator(store: store, aiService: service)
        let decision = await autoReply.generate(.init(
            messageBody: "@我 风险清单今天17:00前发群里，收到后说一声",
            senderName: "林晓",
            chatName: "项目协作群（合成验收）",
            chatUsername: "synthetic-project-group",
            contactRole: .colleague,
            attentionLevel: .vip,
            contextWindow: "林晓：客户今晚要看风险清单\n我：我整理完发",
            styleDescription: "简洁、明确、合作语气",
            fewShotExamples: ["收到，我在整理，17:00前发群里。"],
            frequentPhrases: ["收到", "我来处理"],
            messagePairs: [(question: "客户今晚要看风险清单", answer: "我整理完发")],
            contactStyleHint: "工作协作，直接说明进度",
            conversationMemory: "当前待交付风险清单，发送前需确认最终版本"
        ))
        if let decision {
            let action = decision.action ?? "legacy"
            evidence.autoReply = .init(
                status: "returned",
                action: action,
                confidence: decision.confidence,
                risk: decision.risk,
                reply: clipped(decision.reply ?? ""),
                reasoning: clipped(decision.reasoning)
            )
            XCTAssertTrue(["send", "stall", "read_no_reply", "skip", "pending", "legacy"].contains(action))
            XCTAssertGreaterThanOrEqual(decision.confidence, 0)
            XCTAssertLessThanOrEqual(decision.confidence, 1)
            XCTAssertFalse(decision.reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } else {
            evidence.autoReply = .failed
            XCTFail("AutoReplyGenerator returned nil after its bounded retry")
        }

        let tracker = CommitmentTracker(store: store, aiService: service)
        let commitmentMessage = MessageInfo(
            id: "synthetic-self-commitment-001",
            chatUsername: "synthetic-project-group",
            chatName: "项目协作群（合成验收）",
            senderUsername: "synthetic-me",
            senderName: "我",
            text: "好的，我今天17:00前把最终风险清单发到群里，林晓收到后告诉我",
            baseType: 1,
            subType: 0,
            createTime: Int(Date().timeIntervalSince1970)
        )
        let commitment = await tracker.analyze(
            yourMessage: commitmentMessage,
            contextMessages: [],
            recipientName: "林晓",
            recipientRole: .colleague
        )
        if let commitment {
            evidence.commitment = .init(
                status: "returned",
                isCommitment: commitment.isCommitment,
                content: clipped(commitment.content),
                commitTo: clipped(commitment.commitTo),
                confidence: commitment.confidence,
                deadlineLabel: clipped(commitment.deadlineLabel),
                kind: commitment.commitmentKind
            )
            XCTAssertTrue(commitment.isCommitment, "explicit self-promise should be captured")
            XCTAssertFalse(commitment.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            XCTAssertFalse(commitment.commitTo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            XCTAssertGreaterThan(commitment.confidence, 0.4)
            XCTAssertTrue(commitment.content.contains("风险清单"), "commitment content must retain the promised deliverable")
            XCTAssertTrue(commitment.deadlineExtracted.contains("17:00") || commitment.deadlineLabel.contains("17:00") || commitment.deadlineLabel.contains("今天"), "commitment must retain the explicit deadline")
            XCTAssertFalse(commitment.content.contains("告知林晓") || commitment.content.contains("通知林晓") || commitment.content.contains("告诉林晓"), "commitment content must not reverse the other person's receipt action")
            XCTAssertFalse(commitment.nextStep.contains("告知林晓") || commitment.nextStep.contains("通知林晓") || commitment.nextStep.contains("告诉林晓"), "commitment next step must not reverse the other person's receipt action")

            // `analyze` is extraction only. Exercise the same persistence
            // entry used by ChatMonitor, then verify the temporary store.
            let messageDate = Date(timeIntervalSince1970: Double(commitmentMessage.createTime))
            let expectedCalendar = Calendar.current
            var expectedComponents = expectedCalendar.dateComponents([.year, .month, .day], from: messageDate)
            expectedComponents.hour = 17
            expectedComponents.minute = 0
            expectedComponents.second = 0
            let expectedDeadline = expectedCalendar.date(from: expectedComponents)
            let resolvedDeadline = CommitmentDeadlineResolver.resolve(
                extracted: commitment.deadlineExtracted,
                label: commitment.deadlineLabel,
                sourceText: commitment.sourceText,
                messageDate: messageDate,
                calendar: expectedCalendar
            )
            XCTAssertNotNil(resolvedDeadline, "natural-language deadline must resolve to a Date")
            guard let resolvedDeadline, let expectedDeadline else {
                XCTFail("deadline resolver returned no anchored date")
                return
            }
            XCTAssertEqual(resolvedDeadline.timeIntervalSince1970, expectedDeadline.timeIntervalSince1970, accuracy: 1)
            try store.upsertCommitment(
                msgUID: commitmentMessage.id,
                chatUsername: commitmentMessage.chatUsername,
                chatName: commitmentMessage.chatName,
                content: commitment.content,
                commitTo: commitment.commitTo,
                deadlineAt: resolvedDeadline,
                confidence: commitment.confidence,
                promptVersion: "commitment_v1",
                sourceText: commitment.sourceText.isEmpty ? commitmentMessage.text : commitment.sourceText,
                contextText: commitment.contextText,
                captureReason: commitment.captureReason,
                nextStep: commitment.nextStep,
                deadlineLabel: commitment.deadlineLabel,
                commitmentKind: commitment.commitmentKind,
                createdAt: messageDate
            )
            let savedCommitment = store.loadCommitments().first { $0.msgUID == commitmentMessage.id }
            evidence.commitment.persisted = savedCommitment != nil
            XCTAssertEqual(savedCommitment?.content, commitment.content)
            XCTAssertEqual(savedCommitment?.commitTo, commitment.commitTo)
            XCTAssertTrue(savedCommitment?.content.contains("风险清单") == true)
            guard let savedDeadline = savedCommitment?.deadlineAt else {
                XCTFail("persisted commitment lost its resolved deadline")
                return
            }
            XCTAssertEqual(savedDeadline.timeIntervalSince1970, expectedDeadline.timeIntervalSince1970, accuracy: 1)

            let otherPersonAction = await tracker.analyze(
                yourMessage: MessageInfo(
                    id: "synthetic-other-action-001",
                    chatUsername: commitmentMessage.chatUsername,
                    chatName: commitmentMessage.chatName,
                    senderUsername: commitmentMessage.senderUsername,
                    senderName: commitmentMessage.senderName,
                    text: "林晓收到后告诉我",
                    baseType: 1,
                    subType: 0,
                    createTime: commitmentMessage.createTime + 1
                ),
                contextMessages: [],
                recipientName: "林晓",
                recipientRole: .colleague
            )
            evidence.otherPersonAction = otherPersonAction.map {
                OtherActionEvidence(status: "returned", isCommitment: $0.isCommitment, content: clipped($0.content))
            } ?? .failed
            XCTAssertNotNil(otherPersonAction, "negative semantic case must return a parseable result")
            XCTAssertFalse(otherPersonAction?.isCommitment ?? true, "a promise made by 林晓 is not the user's commitment")
        } else {
            evidence.commitment = .failed
            XCTFail("CommitmentTracker returned nil after its bounded retry")
        }

        let audits = store.loadRecentAIAudit(limit: 100)
        evidence.auditCount = audits.count
        evidence.auditModels = Array(Set(audits.map(\.model))).sorted()
        evidence.auditStatuses = audits.map { $0.status.rawValue }
        XCTAssertGreaterThanOrEqual(audits.count, 6, "each exercised service should leave an audit row")
        XCTAssertTrue(audits.allSatisfy { !$0.model.isEmpty }, "audit rows must retain the provider-returned/configured model")
    }

    private func loadConfiguredAI() throws -> AIConfig {
        let path = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".wechat-hud/device-settings.json")
        let device = try DeviceSettingsStore(path: path)
        guard let raw = device.get("ai"), let data = raw.data(using: .utf8) else {
            throw NSError(domain: "LiveCompanionAcceptanceTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "missing device AI settings"])
        }
        var config = try JSONDecoder().decode(AIConfig.self, from: data)
        config.migrateIfNeeded()
        return config
    }

    private func isUsable(_ config: AIConfig) -> Bool {
        let slot = config.provider
        return !slot.providerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !slot.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (slot.providerID == "openai-codex" || !slot.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private static let evidencePath = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("docs/qa/2026-09-08/synthetic-companion-ai.md")

    private func writeEvidence(_ evidence: Evidence) {
        let text = evidence.markdown
        do {
            try FileManager.default.createDirectory(at: Self.evidencePath.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: Self.evidencePath, atomically: true, encoding: .utf8)
        } catch {
            XCTFail("could not write synthetic AI evidence: \(error.localizedDescription)")
        }
    }

    private func clipped(_ value: String, limit: Int = 240) -> String {
        let singleLine = value.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(singleLine.prefix(limit))
    }
}

private struct Evidence {
    let providerID: String
    let model: String
    var classifier: ClassifierEvidence = .notRun
    var groupCatchup: GroupEvidence = .notRun
    var chatInsight: ChatInsightEvidence = .notRun
    var replySuggestions: ReplyEvidence = .notRun
    var autoReply: AutoReplyEvidence = .notRun
    var commitment: CommitmentEvidence = .notRun
    var otherPersonAction: OtherActionEvidence = .notRun
    var auditCount = 0
    var auditModels: [String] = []
    var auditStatuses: [String] = []

    var markdown: String {
        let generated = ISO8601DateFormatter().string(from: Date())
        return """
        # Synthetic companion AI acceptance — 2026-09-08

        This evidence came from fictional project-chat inputs and a temporary HUDStore. It does not include the device API key, endpoint, prompts, real chat rows, or real contact names. A passing test means the configured provider returned parseable results that satisfied the assertions below; it does not prove delivery or autonomous sending.

        - Generated at: `\(generated)`
        - Provider: `\(providerID)`
        - Configured model: `\(model)`
        - Opt-in: `WCHUD_LIVE_COMPANION_AI=1`

        ## AIClassifier — synthetic group @ context

        Input: fictional `@我` request to send a risk list before 17:00.

        \(classifier.markdown)

        ## AIGroupCatchup — synthetic group context summary

        \(groupCatchup.markdown)

        ## AIChatInsight — synthetic chat insight

        \(chatInsight.markdown)

        ## AIReplySuggester — synthetic reply candidates

        \(replySuggestions.markdown)

        ## AutoReplyGenerator — synthetic guarded decision

        \(autoReply.markdown)

        ## CommitmentTracker — synthetic self-promise

        \(commitment.markdown)

        ## CommitmentTracker — negative other-person action

        \(otherPersonAction.markdown)

        ## Prior live semantic finding

        The first live run exposed a real directionality defect: the model returned `并告知林晓` for the synthetic phrase `林晓收到后告诉我`, reversing who should report to whom. The final run keeps that failure visible and asserts that the corrected prompt no longer returns that inverted action.

        ## Temporary-store AI audit

        auditCount=\(auditCount), auditModels=\(auditModels), auditStatuses=\(auditStatuses)

        ## Boundary

        No message was sent to WeChat. No real WeChat database or production HUD SQLite file was opened. The test uses bounded service timeouts and each service's existing single strict-JSON retry.
        """
    }
}

private struct ClassifierEvidence {
    var status: String
    var isAsk: Bool = false
    var type: String = ""
    var confidence: Double = 0
    var summary: String = ""
    var deadlinePresent = false
    static let notRun = ClassifierEvidence(status: "not_run")
    static let failed = ClassifierEvidence(status: "failed")
    var markdown: String { "status=\(status), isAsk=\(isAsk), type=\(type), confidence=\(confidence), deadlinePresent=\(deadlinePresent), summary=\(summary)" }
}

private struct GroupEvidence {
    var status: String
    var headline: String = ""
    var highlightCount = 0
    var needsUserAction = false
    var actionSummary: String = ""
    var skipSafe = false
    static let notRun = GroupEvidence(status: "not_run")
    static let failed = GroupEvidence(status: "failed")
    var markdown: String { "status=\(status), needsUserAction=\(needsUserAction), highlightCount=\(highlightCount), skipSafe=\(skipSafe), headline=\(headline), actionSummary=\(actionSummary)" }
}

private struct ChatInsightEvidence {
    var status: String
    var headline: String = ""
    var insight: String = ""
    var suggestion: String = ""
    var mentionsMe = 0
    var actionItemCount = 0
    var actionOwners: [String] = []
    var commitments: [String] = []
    var needsMyAttention = false
    static let notRun = ChatInsightEvidence(status: "not_run")
    static let failed = ChatInsightEvidence(status: "failed")
    var markdown: String {
        "status=\(status), mentionsMe=\(mentionsMe), actionItemCount=\(actionItemCount), actionOwners=\(actionOwners), needsMyAttention=\(needsMyAttention), headline=\(headline), insight=\(insight), suggestion=\(suggestion), commitments=\(commitments)"
    }
}

private struct ReplyEvidence {
    var status: String
    var count = 0
    var texts: [String] = []
    var tones: [String] = []
    var safeToSend: [Bool] = []
    static let notRun = ReplyEvidence(status: "not_run")
    static let failed = ReplyEvidence(status: "failed")
    var markdown: String { "status=\(status), count=\(count), tones=\(tones), safeToSend=\(safeToSend), texts=\(texts)" }
}

private struct AutoReplyEvidence {
    var status: String
    var action: String = ""
    var confidence = 0.0
    var risk: String = ""
    var reply: String = ""
    var reasoning: String = ""
    static let notRun = AutoReplyEvidence(status: "not_run")
    static let failed = AutoReplyEvidence(status: "failed")
    var markdown: String { "status=\(status), action=\(action), confidence=\(confidence), risk=\(risk), reply=\(reply), reasoning=\(reasoning)" }
}

private struct CommitmentEvidence {
    var status: String
    var isCommitment = false
    var content: String = ""
    var commitTo: String = ""
    var confidence = 0.0
    var deadlineLabel: String = ""
    var kind: String = ""
    var persisted = false
    static let notRun = CommitmentEvidence(status: "not_run")
    static let failed = CommitmentEvidence(status: "failed")
    var markdown: String { "status=\(status), isCommitment=\(isCommitment), confidence=\(confidence), content=\(content), commitTo=\(commitTo), deadlineLabel=\(deadlineLabel), kind=\(kind), persisted=\(persisted)" }
}

private struct OtherActionEvidence {
    var status: String
    var isCommitment = false
    var content = ""
    static let notRun = OtherActionEvidence(status: "not_run")
    static let failed = OtherActionEvidence(status: "failed")
    var markdown: String { "status=\(status), isCommitment=\(isCommitment), content=\(content)" }
}
