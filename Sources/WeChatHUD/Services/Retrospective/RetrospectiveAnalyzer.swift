import Foundation

/// Per-chat deep extraction: redact → call AI → parse → unredact →
/// build typed `[ReviewHighlight] + [ReviewTodo]`. Spec §6.2 step 4, §7.2.
///
/// Caller (RetrospectiveJob) is responsible for actually inserting the
/// returned highlights/todos into the DB — this actor stays focused on
/// the AI round-trip and does NOT side-effect on store writes.
actor RetrospectiveAnalyzer {
    private let store: HUDStore
    private let aiService: any AIServiceProtocol
    private let promptLoader: PromptLoader
    private let redactor: Redactor
    private let dataLedger: DataLedger

    init(
        store: HUDStore,
        aiService: any AIServiceProtocol,
        promptLoader: PromptLoader = PromptLoader(),
        redactor: Redactor,
        dataLedger: DataLedger
    ) {
        self.store = store
        self.aiService = aiService
        self.promptLoader = promptLoader
        self.redactor = redactor
        self.dataLedger = dataLedger
    }

    struct AnalysisResult: Sendable {
        let highlights: [ReviewHighlight]
        let todos: [ReviewTodo]
    }

    enum AnalyzerError: Error {
        case promptLoadFailed
        case parseFailed
    }

    func analyze(
        chat: ScopeCandidate,
        relation: Relation,
        messages: [MessageInfo],
        myUsername: String,
        myDisplayName: String,
        runID: Int
    ) async throws -> AnalysisResult {
        // 1. Codename + redact every message; format as transcript lines.
        let myCodename = await redactor.codenameFor(username: myUsername, displayName: myDisplayName)
        var lines: [String] = []
        // Iterate chronologically (caller passes newest-first per ChatAnalyzer convention)
        for msg in messages.reversed() {
            let senderCode = await redactor.codenameFor(username: msg.senderUsername, displayName: msg.senderName)
            let redactedText = await redactor.redactText(msg.text)
            let isoTs = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: TimeInterval(msg.createTime)))
            lines.append("[\(msg.id)] [\(isoTs)] \(senderCode): \(redactedText)")
        }
        let messagesStr = lines.joined(separator: "\n")

        // 2. Build prompt.
        let template: String
        do {
            template = try promptLoader.load(version: "retrospective_chat_analysis_v1")
        } catch {
            await ledgerFailed(messages: messages.count, byteCount: 0)
            throw AnalyzerError.promptLoadFailed
        }
        let userPrompt = template
            .replacingOccurrences(of: "{my_codename}", with: myCodename)
            .replacingOccurrences(of: "{chat_name}", with: chat.chatName)
            .replacingOccurrences(of: "{relation}", with: relation.rawValue)
            .replacingOccurrences(of: "{messages}", with: messagesStr)

        let byteCount = userPrompt.utf8.count

        // 3. AI call with one parse-failure retry (mirrors ChatAnalyzer pattern).
        let firstResult: AICompletionResult
        do {
            firstResult = try await aiService.completeWithMetadata(
                system: "你严格按 JSON Schema 输出。",
                user: userPrompt,
                options: CompleteOptions(timeout: 60, temperature: 0.2, maxTokens: 4096, responseFormatJSON: true)
            )
        } catch {
            await ledgerFailed(messages: messages.count, byteCount: byteCount)
            throw error
        }

        let parsed: ParsedAnalysis
        var actualProvider = firstResult.providerID
        var actualModel = firstResult.model
        if let p = parse(firstResult.text) {
            parsed = p
        } else {
            // Stricter retry — same prompt body + a "JSON only" reminder.
            let strict = userPrompt + "\n\n严格要求:只输出符合 schema 的 JSON 对象,不要任何其它文字或代码围栏。"
            let retry = try? await aiService.completeWithMetadata(
                system: "你严格按 JSON Schema 输出。",
                user: strict,
                options: CompleteOptions(timeout: 60, temperature: 0.2, maxTokens: 4096, responseFormatJSON: true)
            )
            guard let retry, let p2 = parse(retry.text) else {
                await ledgerFailed(
                    messages: messages.count,
                    byteCount: byteCount,
                    provider: retry?.providerID ?? firstResult.providerID,
                    model: retry?.model ?? firstResult.model
                )
                throw AnalyzerError.parseFailed
            }
            actualProvider = retry.providerID
            actualModel = retry.model
            parsed = p2
        }

        // 4. Ledger entry for the successful call.
        await dataLedger.recordBatch([AILedgerEntry(
            id: 0, ts: Date(),
            provider: actualProvider,
            model: actualModel,
            purpose: .chatAnalysis,
            chatCount: 1, msgCount: messages.count,
            byteCount: byteCount,
            tokenIn: nil, tokenOut: nil,
            redacted: true
        )])

        // 5. Convert parsed AI codenames back to display names for involved arrays.
        let highlights = await convertHighlights(parsed.highlights, chat: chat, relation: relation, runID: runID)
        let todos = await convertTodos(parsed.todos, chat: chat, runID: runID)
        return AnalysisResult(highlights: highlights, todos: todos)
    }

    // MARK: - Conversion (codename → display name)

    private func convertHighlights(
        _ ph: [ParsedHighlight],
        chat: ScopeCandidate,
        relation: Relation,
        runID: Int
    ) async -> [ReviewHighlight] {
        var out: [ReviewHighlight] = []
        for p in ph {
            var resolvedInvolved: [String] = []
            for code in p.involved {
                resolvedInvolved.append(await redactor.originalForCodename(code) ?? code)
            }
            let unredactedSummary = await redactor.unredactText(p.summary)
            let snippetResolved: String?
            if let raw = p.quoted_snippet {
                snippetResolved = await redactor.unredactText(raw)
            } else {
                snippetResolved = nil
            }
            let category = HighlightCategory(rawValue: p.category) ?? .discussion
            let flagged = p.confidence < 0.5
            out.append(ReviewHighlight(
                id: 0, runID: runID,
                date: Date(timeIntervalSince1970: TimeInterval(p.date)),
                summary: unredactedSummary,
                quotedSnippet: snippetResolved,
                involved: resolvedInvolved,
                sourceChatUsername: chat.chatUsername,
                sourceChatName: chat.chatName,
                relation: relation,
                sourceMsgIDs: p.source_msg_ids,
                confidence: p.confidence,
                category: category,
                flaggedUncertain: flagged
            ))
        }
        return out
    }

    private func convertTodos(
        _ pt: [ParsedTodo],
        chat: ScopeCandidate,
        runID: Int
    ) async -> [ReviewTodo] {
        var out: [ReviewTodo] = []
        for p in pt {
            var resolvedInvolved: [String] = []
            for code in p.involved {
                resolvedInvolved.append(await redactor.originalForCodename(code) ?? code)
            }
            let unredactedContent = await redactor.unredactText(p.content)
            let direction = TodoDirection(rawValue: p.direction) ?? .unclear
            out.append(ReviewTodo(
                id: 0, originRunID: runID, lastRunID: runID,
                content: unredactedContent,
                deadline: p.deadline.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                direction: direction,
                involved: resolvedInvolved,
                sourceChatUsername: chat.chatUsername,
                sourceChatName: chat.chatName,
                sourceMsgIDs: p.source_msg_ids,
                confidence: p.confidence,
                status: .pending,  // Spec §7.2: AI never sets status
                createdAt: Date(),
                completedAt: nil, snoozedTo: nil, delegatedTo: nil,
                carryCount: 0, lastUserActionAt: nil
            ))
        }
        return out
    }

    private func ledgerFailed(messages: Int, byteCount: Int, provider actualProvider: String? = nil, model actualModel: String? = nil) async {
        let cfg = await aiService.currentConfig()
        await dataLedger.recordBatch([AILedgerEntry(
            id: 0, ts: Date(),
            provider: actualProvider ?? cfg.primarySlot.providerID,
            model: actualModel ?? cfg.primarySlot.model,
            purpose: .chatAnalysisFailed,
            chatCount: 1, msgCount: messages,
            byteCount: byteCount,
            tokenIn: nil, tokenOut: nil, redacted: true
        )])
    }

    // MARK: - JSON parsing

    nonisolated func parse(_ raw: String) -> ParsedAnalysis? {
        AIJSONExtractor.decodeFirstObject(from: raw, as: ParsedAnalysis.self)
    }
}

// MARK: - Parsed AI output shape

struct ParsedAnalysis: Decodable, Sendable {
    let highlights: [ParsedHighlight]
    let todos: [ParsedTodo]
}

struct ParsedHighlight: Decodable, Sendable {
    let date: Int
    let summary: String
    let quoted_snippet: String?
    let involved: [String]
    let category: String
    let confidence: Double
    let source_msg_ids: [String]
}

struct ParsedTodo: Decodable, Sendable {
    let deadline: Int?
    let content: String
    let direction: String
    let involved: [String]
    let confidence: Double
    let source_msg_ids: [String]
}
