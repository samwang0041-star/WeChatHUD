import Foundation

protocol GroupContextLLMClient: Sendable {
    func complete(system: String, user: String) async throws -> String
    func complete(system: String, user: String, options: CompleteOptions) async throws -> String
    func completeWithMetadata(system: String, user: String, options: CompleteOptions) async throws -> AICompletionResult
    func isConfigured() async -> Bool
    func currentConfig() async -> AIConfig
}

extension AIService: GroupContextLLMClient {}

protocol GroupContextMessageProvider {
    func getMessages(chatUsername: String, limit: Int, sinceLocalId: Int?) throws -> [MessageInfo]
}

extension WeChatReader: GroupContextMessageProvider {}

struct GroupContextBriefingResult {
    let briefing: GroupContextBriefing
    let errorMessage: String?
}

actor GroupContextBriefingService {
    private let reader: any GroupContextMessageProvider
    private let store: HUDStore?
    private let client: (any GroupContextLLMClient)?
    private let promptLoader: PromptLoader
    private let promptVersion: String
    private let cacheTTLHours: Int

    init(
        reader: any GroupContextMessageProvider,
        store: HUDStore?,
        client: (any GroupContextLLMClient)?,
        promptLoader: PromptLoader = PromptLoader(),
        promptVersion: String = "group_context_briefing_v1",
        cacheTTLHours: Int = 72
    ) {
        self.reader = reader
        self.store = store
        self.client = client
        self.promptLoader = promptLoader
        self.promptVersion = promptVersion
        self.cacheTTLHours = cacheTTLHours
    }

    func explain(
        notification: HUDNotification,
        forceRefresh: Bool = false
    ) async -> GroupContextBriefingResult {
        let analysisType = promptVersion
        let cacheKey = notification.briefingKey

        if !forceRefresh,
           let cached = store?.loadAnalysisCache(
                chatUsername: notification.chatUsername,
                analysisType: analysisType,
                inputHash: cacheKey
           ),
           let briefing = parseStoredBriefing(cached) {
            return GroupContextBriefingResult(
                briefing: briefing,
                errorMessage: nil
            )
        }

        let contextMessages = (try? reader.getMessages(
            chatUsername: notification.chatUsername,
            limit: 24,
            sinceLocalId: nil
        )) ?? []
        let contextWindow = Self.contextWindow(
            messages: contextMessages,
            notification: notification
        )

        guard let client else {
            return GroupContextBriefingResult(
                briefing: fallbackBriefing(notification: notification, contextMessages: contextWindow),
                errorMessage: "AI 未配置，使用本地兜底判断"
            )
        }
        guard await client.isConfigured() else {
            return GroupContextBriefingResult(
                briefing: fallbackBriefing(notification: notification, contextMessages: contextWindow),
                errorMessage: "AI 未配置，使用本地兜底判断"
            )
        }

        let template: String
        do {
            template = try promptLoader.load(version: promptVersion)
        } catch {
            return GroupContextBriefingResult(
                briefing: fallbackBriefing(notification: notification, contextMessages: contextWindow),
                errorMessage: "上下文提示词缺失，使用本地兜底判断"
            )
        }

        let payload: String
        do {
            payload = try makePayload(notification: notification, contextMessages: contextWindow)
        } catch {
            return GroupContextBriefingResult(
                briefing: fallbackBriefing(notification: notification, contextMessages: contextWindow),
                errorMessage: "上下文打包失败，使用本地兜底判断"
            )
        }

        let userPrompt = template
            .replacingOccurrences(of: "{chat_name}", with: escape(notification.chatName))
            .replacingOccurrences(of: "{sender_name}", with: escape(notification.senderName))
            .replacingOccurrences(of: "{target_text}", with: escape(AIService.sanitizeForAI(notification.rawText)))
            .replacingOccurrences(of: "{context_json}", with: payload)

        let started = Date()
        let initialModel = await client.currentConfig().model

        let firstResponse = await request(client: client, userPrompt: userPrompt)
        if let briefing = parseBriefing(firstResponse.text) {
            let final = finalize(briefing: briefing, source: .ai)
            writeAudit(
                model: firstResponse.model ?? initialModel,
                inputText: payload,
                outputText: firstResponse.text,
                latencyMs: ms(since: started),
                status: .ok,
                errorMessage: nil
            )
            cache(final, notification: notification, analysisType: analysisType, cacheKey: cacheKey)
            return GroupContextBriefingResult(briefing: final, errorMessage: nil)
        }

        if firstResponse.text.isEmpty, let error = firstResponse.error {
            writeAudit(
                model: firstResponse.model ?? initialModel,
                inputText: payload,
                outputText: "",
                latencyMs: ms(since: started),
                status: status(for: error),
                errorMessage: error
            )
            return GroupContextBriefingResult(
                briefing: fallbackBriefing(notification: notification, contextMessages: contextWindow),
                errorMessage: "AI 请求失败，使用本地兜底判断"
            )
        }

        let stricterPrompt = userPrompt + "\n\n严格要求：只输出一个 JSON 对象，不要任何解释、markdown 代码块或额外文字。"
        let secondResponse = await request(client: client, userPrompt: stricterPrompt)
        if let briefing = parseBriefing(secondResponse.text) {
            let final = finalize(briefing: briefing, source: .ai)
            writeAudit(
                model: secondResponse.model ?? initialModel,
                inputText: payload,
                outputText: secondResponse.text,
                latencyMs: ms(since: started),
                status: .ok,
                errorMessage: "recovered after retry"
            )
            cache(final, notification: notification, analysisType: analysisType, cacheKey: cacheKey)
            return GroupContextBriefingResult(briefing: final, errorMessage: nil)
        }

        writeAudit(
            model: secondResponse.model ?? initialModel,
            inputText: payload,
            outputText: secondResponse.text,
            latencyMs: ms(since: started),
            status: .parseError,
            errorMessage: secondResponse.error ?? "could not parse JSON after retry"
        )
        return GroupContextBriefingResult(
            briefing: fallbackBriefing(notification: notification, contextMessages: contextWindow),
            errorMessage: "AI 输出不可解析，使用本地兜底判断"
        )
    }

    private func parseStoredBriefing(_ raw: String) -> GroupContextBriefing? {
        guard let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(GroupContextBriefing.self, from: data)
    }

    private func cache(
        _ briefing: GroupContextBriefing,
        notification: HUDNotification,
        analysisType: String,
        cacheKey: String
    ) {
        guard let store else { return }
        guard let data = try? JSONEncoder().encode(briefing),
              let raw = String(data: data, encoding: .utf8) else { return }
        try? store.writeAnalysisCache(
            chatUsername: notification.chatUsername,
            analysisType: analysisType,
            inputHash: cacheKey,
            result: raw,
            ttlHours: cacheTTLHours
        )
    }

    private func finalize(
        briefing: GroupContextBriefing,
        source: GroupContextBriefingSource
    ) -> GroupContextBriefing {
        GroupContextBriefing(
            situation: trim(briefing.situation, limit: 90),
            whyMentioned: trim(briefing.whyMentioned, limit: 70),
            currentStatus: trim(briefing.currentStatus, limit: 70),
            nextStep: trim(briefing.nextStep, limit: 70),
            participants: Array(briefing.participants.map { trim($0, limit: 18) }.filter { !$0.isEmpty }.prefix(4)),
            confidence: max(0, min(1, briefing.confidence)),
            source: source,
            generatedAt: Date()
        )
    }

    private func fallbackBriefing(
        notification: HUDNotification,
        contextMessages: [MessageInfo]
    ) -> GroupContextBriefing {
        let participants = Array(Set(contextMessages.map(\.senderName).filter { !$0.isEmpty })).sorted().prefix(4)
        let latestLines = contextMessages
            .suffix(3)
            .map { trim($0.text, limit: 26) }
            .filter { !$0.isEmpty }
        let topic = latestLines.isEmpty
            ? trim(notification.snippet, limit: 28)
            : latestLines.joined(separator: " / ")
        let needsDecision = containsAskSignal(notification.rawText)
        let situation = "群里最近在围绕“\(topic)”推进，最后 \(notification.senderName) 直接 @ 了你。"
        let whyMentioned = needsDecision
            ? "这条 @ 更像是在向你要确认、判断或补充信息。"
            : "这条 @ 更像是在把相关讨论同步给你。"
        let currentStatus = containsUrgentSignal(notification.rawText)
            ? "当前语气偏着急，建议先看上下文再决定是否回应。"
            : "目前没有明确要你拍板或回复的信号。"
        let nextStep = needsDecision
            ? "先回这条 @，给一个明确判断或时间点。"
            : "先打开上下文确认讨论与你的关系。"
        return GroupContextBriefing(
            situation: trim(situation, limit: 90),
            whyMentioned: trim(whyMentioned, limit: 70),
            currentStatus: trim(currentStatus, limit: 70),
            nextStep: trim(nextStep, limit: 70),
            participants: Array(participants),
            confidence: 0.45,
            source: .fallback,
            generatedAt: Date()
        )
    }

    private struct PromptPayload: Encodable {
        let chatName: String
        let targetSender: String
        let targetMessage: String
        let contextMessages: [PromptMessage]
    }

    private struct PromptMessage: Encodable {
        let timestamp: Int
        let sender: String
        let text: String
        let isTarget: Bool
    }

    private struct ModelResponse {
        let text: String
        let error: String?
        let model: String?
    }

    private struct BriefingDTO: Decodable {
        let situation: String
        let whyMentioned: String
        let currentStatus: String
        let nextStep: String
        let participants: [String]
        let confidence: Double

        enum CodingKeys: String, CodingKey {
            case situation
            case whyMentioned = "why_mentioned"
            case currentStatus = "current_status"
            case nextStep = "next_step"
            case participants
            case confidence
        }
    }

    private func makePayload(
        notification: HUDNotification,
        contextMessages: [MessageInfo]
    ) throws -> String {
        let payload = PromptPayload(
            chatName: notification.chatName,
            targetSender: notification.senderName,
            targetMessage: notification.rawText,
            contextMessages: contextMessages.map { msg in
                PromptMessage(
                    timestamp: msg.createTime,
                    sender: msg.senderName,
                    text: trim(AIService.sanitizeForAI(msg.text), limit: 140),
                    isTarget: msg.id == notification.messageID
                )
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(payload)
        guard let json = String(data: data, encoding: .utf8) else {
            throw GroupContextBriefingError.invalidPayloadEncoding
        }
        return json
    }

    private func request(
        client: any GroupContextLLMClient,
        userPrompt: String
    ) async -> ModelResponse {
        do {
            let result = try await client.completeWithMetadata(
                system: "你是一个微信群聊上下文解释器。严格按要求输出 JSON。",
                user: userPrompt,
                options: CompleteOptions(timeout: 60, temperature: 0.15, maxTokens: 512, responseFormatJSON: true)
            )
            return ModelResponse(text: result.text, error: nil, model: result.model)
        } catch {
            return ModelResponse(text: "", error: String(describing: error), model: nil)
        }
    }

    private func parseBriefing(_ raw: String) -> GroupContextBriefing? {
        guard let jsonText = extractJSONObject(from: raw),
              let data = jsonText.data(using: .utf8),
              let dto = try? JSONDecoder().decode(BriefingDTO.self, from: data) else {
            return nil
        }
        return GroupContextBriefing(
            situation: dto.situation,
            whyMentioned: dto.whyMentioned,
            currentStatus: dto.currentStatus,
            nextStep: dto.nextStep,
            participants: dto.participants,
            confidence: dto.confidence,
            source: .ai,
            generatedAt: Date()
        )
    }

    private func extractJSONObject(from raw: String) -> String? {
        AIJSONExtractor.firstObjectString(from: raw)
    }

    private func writeAudit(
        model: String,
        inputText: String,
        outputText: String,
        latencyMs: Int,
        status: AIAuditStatus,
        errorMessage: String?
    ) {
        guard let store else { return }
        let entry = AIAuditEntry(
            id: 0,
            ts: Date(),
            role: .retrospector,
            model: model,
            promptVersion: promptVersion,
            inputText: inputText,
            outputText: outputText,
            latencyMs: latencyMs,
            status: status,
            errorMessage: errorMessage
        )
        try? store.writeAIAudit(entry)
    }

    private func status(for error: String) -> AIAuditStatus {
        let lower = error.lowercased()
        if lower.contains("timed out") {
            return .timeout
        }
        return .httpError
    }

    private func ms(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
    }

    private func trim(_ text: String, limit: Int) -> String {
        let normalized = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(normalized.prefix(max(1, limit)))
    }

    private func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func containsAskSignal(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return text.contains("？")
            || text.contains("?")
            || text.contains("看下")
            || text.contains("确认")
            || text.contains("帮")
            || lowered.contains("can you")
    }

    private func containsUrgentSignal(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return ["紧急", "尽快", "马上", "立即", "截止"].contains(where: text.contains)
            || lowered.contains("asap")
            || lowered.contains("urgent")
    }

    static func contextWindow(
        messages: [MessageInfo],
        notification: HUDNotification,
        historyCount: Int = 8,
        futureCount: Int = 3
    ) -> [MessageInfo] {
        let chronological = messages.sorted { $0.createTime < $1.createTime }
        guard !chronological.isEmpty else { return [] }

        let targetTs = Int(notification.timestamp.timeIntervalSince1970)
        let anchorIndex = chronological.firstIndex {
            $0.id == notification.messageID
        } ?? chronological.lastIndex {
            $0.createTime == targetTs
                && $0.senderName == notification.senderName
        } ?? max(0, chronological.count - 1)

        let start = max(0, anchorIndex - historyCount)
        let end = min(chronological.count - 1, anchorIndex + futureCount)
        return Array(chronological[start...end])
    }
}

enum GroupContextBriefingError: Error {
    case invalidPayloadEncoding
}
