import Foundation

/// Generates a one-line summary (<=25 chars) for an inbox item,
/// telling the user "what does this person want from you?"
///
/// Examples:
///   "红字为修改部分请查收" → "等你确认方案修改稿"
///   "@你 方案定了吗"       → "张总问你方案排期"
///
/// Follows the same actor + HTTP + audit pattern as AIReplySuggester.
actor AIInboxSummarizer {
    private let store: HUDStore
    private let aiService: AIService
    private let promptLoader: PromptLoader
    private let promptVersion: String

    init(
        store: HUDStore,
        aiService: AIService,
        promptLoader: PromptLoader = PromptLoader(),
        promptVersion: String = "inbox_summary_v1"
    ) {
        self.store = store
        self.aiService = aiService
        self.promptLoader = promptLoader
        self.promptVersion = promptVersion
    }

    /// Generate a one-line summary for an inbox item.
    /// Returns nil on failure (caller should fall back to raw preview).
    func summarize(_ context: InboxContext) async -> String? {
        guard await aiService.currentConfig().summaryEnabled else { return nil }
        let started = Date()
        if context.mediaType == nil,
           !MessageHelpers.isReadableAIContent(context.triggerMessageText, allowMediaPlaceholder: false) {
            let summary = "暂无可读内容"
            await audit(input: context.triggerMessageText, output: summary, latencyMs: 0, status: .ok, error: nil, model: nil)
            return summary
        }

        let template: String
        do {
            template = try promptLoader.load(version: promptVersion)
        } catch {
            print("[WCHUD] AIInboxSummarizer: prompt load failed: \(error)")
            return nil
        }

        // Use the pre-tagged transcript from InboxContextBuilder. It
        // labels each line as "我: ..." for user-outbound messages
        // and "{senderName}: ..." for peer messages — without this,
        // the model can't tell the user's own "收到" from a peer
        // reply and has produced summaries like "对方仅回复收到"
        // for messages the user actually sent.
        //
        // We deliberately do NOT pass pendingCommitments /
        // pendingAsks — they previously polluted summaries with
        // unrelated old tasks. Example: a @华武 ask from 3 days ago
        // about "费率谈判材料" got blended into a completely
        // different trigger message about 微银通, producing
        // "发材料、交计划、准备会议" when none of those appeared
        // in the actual message. ChatAnalyzer (which has a richer
        // reasoning loop) is the right place to cross-reference
        // pending items; the inbox summarizer's single job is
        // "what does THIS message ask".
        let contextStr = context.taggedTranscript

        let userPrompt = template
            .replacingOccurrences(of: "{sender_name}", with: context.triggerMessage.senderName)
            .replacingOccurrences(of: "{sender_role}", with: context.senderRole.rawValue)
            .replacingOccurrences(of: "{chat_name}", with: context.triggerMessage.chatName)
            .replacingOccurrences(of: "{chat_kind}", with: context.isGroupChat ? "群聊" : "私聊")
            .replacingOccurrences(of: "{message_body}", with: renderMessageBody(context))
            .replacingOccurrences(of: "{context_messages}", with: AIService.sanitizeForAI(contextStr))
            .replacingOccurrences(of: "{my_last_reply}", with: AIService.sanitizeForAI(context.myLastReplyText ?? "无"))

        let result = await call(userPrompt)
        let latencyMs = Int(Date().timeIntervalSince(started) * 1000)

        if let text = result.text, !text.isEmpty {
            // Clean: remove quotes, trim, cap at 25 chars to match prompt.
            let cleaned = text
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\"", with: "")
                .replacingOccurrences(of: "\u{201C}", with: "")
                .replacingOccurrences(of: "\u{201D}", with: "")
            let summary = String(cleaned.prefix(25))
            let finalSummary = replacementForOverGenericSummary(summary, context: context) ?? summary
            await audit(input: context.triggerMessageText, output: finalSummary, latencyMs: latencyMs, status: .ok, error: nil, model: result.model)
            return finalSummary
        }

        await audit(
            input: context.triggerMessageText,
            output: "",
            latencyMs: latencyMs,
            status: result.error != nil ? .httpError : .parseError,
            error: result.error,
            model: result.model
        )
        return nil
    }

    // MARK: - HTTP call

    private struct CallResult {
        let text: String?
        let error: String?
        let model: String?
    }

    private func call(_ userPrompt: String) async -> CallResult {
        let trackID = "inbox:\(UUID().uuidString.prefix(8))"
        AIActivityTracker.shared.begin(trackID, label: "收件摘要")
        defer { AIActivityTracker.shared.end(trackID) }

        do {
            let result = try await aiService.completeWithMetadata(
                system: "你是用户的微信消息管家。只输出摘要文本，不要任何其他内容。",
                user: userPrompt,
                options: CompleteOptions(timeout: 30, temperature: 0.1, maxTokens: 2048)
            )
            return CallResult(text: result.text, error: nil, model: result.model)
        } catch {
            return CallResult(text: nil, error: error.localizedDescription, model: nil)
        }
    }

    private func renderMessageBody(_ context: InboxContext) -> String {
        let sanitized = AIService.sanitizeForAI(context.triggerMessageText)
        if let mediaType = context.mediaType, isMediaPlaceholder(sanitized) {
            return renderMediaBody(mediaType, context: context)
        }
        if MessageHelpers.isReadableAIContent(sanitized, allowMediaPlaceholder: false) {
            return sanitized
        }
        guard let mediaType = context.mediaType else { return "发来一条消息要你看" }
        return renderMediaBody(mediaType, context: context)
    }

    private func renderMediaBody(_ mediaType: MediaContentType, context: InboxContext) -> String {
        switch mediaType {
        case .image:
            if let mediaAnalysis = context.mediaAnalysisText, !mediaAnalysis.isEmpty {
                return "发来一张图片。\n\(AIService.sanitizeForAI(mediaAnalysis))"
            }
            return "发来一张图片"
        case .voice: return "发来一段语音"
        case .video: return "发来一段视频"
        case .file: return "发来一个文件"
        case .link:
            if let title = context.linkTitle, !title.isEmpty {
                return "分享链接: \(title)"
            }
            return "分享了一个链接"
        case .sticker: return "发来一个表情"
        case .location: return "发来一个位置"
        }
    }

    private func isMediaPlaceholder(_ text: String) -> Bool {
        ["[图片]", "[语音]", "[视频]", "[文件]", "[表情]", "[动画表情]", "[位置]"].contains(text)
    }

    private func replacementForOverGenericSummary(_ summary: String, context: InboxContext) -> String? {
        let normalized = summary
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "，", with: "")
            .replacingOccurrences(of: "。", with: "")
        let generic: Set<String> = [
            "发来一条消息要你看",
            "发来一条消息",
            "发来一条信息",
            "发来一条状态消息",
            "发来消息"
        ]
        guard generic.contains(normalized) else { return nil }
        return deterministicFallbackSummary(context)
    }

    private func deterministicFallbackSummary(_ context: InboxContext) -> String? {
        let text = AIService.sanitizeForAI(context.triggerMessageText)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if MessageHelpers.isReadableAIContent(text, allowMediaPlaceholder: false), !isMediaPlaceholder(text) {
            return String(text.prefix(25))
        }

        guard let mediaType = context.mediaType else { return nil }
        switch mediaType {
        case .image:
            if let analysis = context.mediaAnalysisText,
               let ocrText = analysis.split(separator: "：").last,
               !ocrText.isEmpty,
               !analysis.contains("不能判断图片具体内容") {
                return String("图片文字: \(ocrText)".prefix(25))
            }
            return "发来一张图片"
        case .voice: return "发来一段语音"
        case .video: return "发来一段视频"
        case .file: return "发来一个文件"
        case .link:
            if let title = context.linkTitle, !title.isEmpty {
                return String("分享链接: \(title)".prefix(25))
            }
            return "分享了一个链接"
        case .sticker: return "发来一个表情"
        case .location: return "发来一个位置"
        }
    }

    // MARK: - Audit

    private func audit(input: String, output: String, latencyMs: Int, status: AIAuditStatus, error: String?, model actualModel: String?) async {
        let model: String
        if let actualModel {
            model = actualModel
        } else {
            model = await aiService.currentConfig().model
        }
        let entry = AIAuditEntry(
            id: 0,
            ts: Date(),
            role: .summarizer,
            model: model,
            promptVersion: promptVersion,
            inputText: String(input.prefix(100)),
            outputText: output,
            latencyMs: latencyMs,
            status: status,
            errorMessage: error
        )
        do { try store.writeAIAudit(entry) } catch {
            print("[WCHUD] AIInboxSummarizer: audit write failed: \(error)")
        }
    }
}
