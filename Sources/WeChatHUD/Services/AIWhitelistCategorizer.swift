import Foundation

/// Suggests a whitelist category (work / life / other) for a contact
/// based on their recent message history. Designed to drive an
/// "auto-fill category" button in the whitelist add/edit UI, and to
/// power batch suggestions when the user opens settings for the first
/// time.
///
/// Pure service. Reads its config from `loadAIConfig()` so
/// it tracks whatever model the user has set.
actor AIWhitelistCategorizer {
    private let store: HUDStore
    private let aiService: AIService
    private let promptLoader: PromptLoader
    private let promptVersion: String

    init(
        store: HUDStore,
        aiService: AIService,
        promptLoader: PromptLoader = PromptLoader(),
        promptVersion: String = "whitelist_categorizer_v1"
    ) {
        self.store = store
        self.aiService = aiService
        self.promptLoader = promptLoader
        self.promptVersion = promptVersion
    }

    /// Output of one categorization call.
    struct Suggestion: Decodable {
        let category: String          // "work" | "life" | "other"
        let confidence: Double
        let reason: String
        let signalKeywords: [String]
        let isGroup: Bool
        let shouldWhitelist: Bool

        enum CodingKeys: String, CodingKey {
            case category
            case confidence
            case reason
            case signalKeywords = "signal_keywords"
            case isGroup = "is_group"
            case shouldWhitelist = "should_whitelist"
        }

        /// Map the AI's string category back to the strongly-typed
        /// `WhitelistCategory` for use with HUDStore.addToWhitelist.
        var whitelistCategory: WhitelistCategory {
            switch category.lowercased() {
            case "work": return .work
            case "life": return .life
            default:     return .other
            }
        }
    }

    /// Input bundle. `messages` should be most-recent-last (chronological).
    struct Input {
        let contactName: String
        let isGroup: Bool
        let messages: [(sender: String, body: String)]
    }

    func categorize(_ input: Input) async -> Suggestion? {
        let started = Date()

        let template: String
        do {
            template = try promptLoader.load(version: promptVersion)
        } catch {
            print("[WCHUD] AIWhitelistCategorizer: prompt load failed: \(error)")
            return nil
        }

        let formattedMessages = input.messages
            .map { "[\(clean($0.sender))] \(clean($0.body))" }
            .joined(separator: "\n")

        let userPrompt = template
            .replacingOccurrences(of: "{contact_name}", with: clean(input.contactName))
            .replacingOccurrences(of: "{is_group}", with: input.isGroup ? "true" : "false")
            .replacingOccurrences(of: "{message_count}", with: "\(input.messages.count)")
            .replacingOccurrences(of: "{messages}", with: formattedMessages)

        let first = await call(userPrompt)
        if let parsed = parse(first.text) {
            await audit(input: input, output: first.text, latencyMs: ms(since: started), status: .ok, error: nil, model: first.model)
            return parsed
        }
        if first.text.isEmpty, let err = first.error {
            await audit(input: input, output: "", latencyMs: ms(since: started), status: .httpError, error: err, model: first.model)
            return nil
        }

        let strict = userPrompt + "\n\n严格要求：上一次输出无法解析为 JSON。只输出符合 schema 的 JSON 对象。"
        let second = await call(strict)
        if let parsed = parse(second.text) {
            await audit(input: input, output: second.text, latencyMs: ms(since: started), status: .ok, error: "recovered after retry", model: second.model)
            return parsed
        }

        await audit(input: input, output: second.text, latencyMs: ms(since: started), status: .parseError, error: second.error ?? "JSON parse failed after retry", model: second.model)
        return nil
    }

    // MARK: - Batch categorization

    struct BatchItem {
        let index: Int
        let contactName: String
        let isGroup: Bool
        let recentCount: Int
        let messages: [(sender: String, body: String)]
    }

    struct BatchResult: Decodable {
        let index: Int
        let category: String
        let shouldWhitelist: Bool
        let reason: String

        enum CodingKeys: String, CodingKey {
            case index, category, reason
            case shouldWhitelist = "should_whitelist"
        }
    }

    /// Batch outcome used by the settings UI to distinguish a genuine empty
    /// recommendation set from a failed or partially failed AI run. The
    /// legacy `categorizeBatch` method below still returns only parsed rows
    /// for existing callers.
    struct BatchCategorizationResult {
        let results: [BatchResult]
        let attemptedChunks: Int
        let failedChunks: Int

        var succeededChunks: Int { attemptedChunks - failedChunks }
    }

    private struct BatchResultEnvelope: Decodable {
        let items: [BatchResult]
    }

    /// Max candidates per AI call. Empirically safe for a 32k-token
    /// context window: 5 messages × ~25 candidates ≈ 125 message stubs,
    /// leaves headroom for the prompt skeleton + output. Larger batches
    /// were sporadically failing (HTTP 413 / empty response) on
    /// accounts with 500+ contacts, silently dropping categorization.
    private static let batchChunkSize = 25

    func categorizeBatch(_ items: [BatchItem]) async -> [BatchResult] {
        await categorizeBatchWithStatus(items).results
    }

    func categorizeBatchWithStatus(_ items: [BatchItem]) async -> BatchCategorizationResult {
        guard !items.isEmpty else {
            return BatchCategorizationResult(results: [], attemptedChunks: 0, failedChunks: 0)
        }

        let template: String
        do {
            template = try promptLoader.load(version: "whitelist_batch_v1")
        } catch {
            print("[WCHUD] AIWhitelistCategorizer: batch prompt load failed: \(error)")
            let attempted = Int(ceil(Double(items.count) / Double(Self.batchChunkSize)))
            return BatchCategorizationResult(results: [], attemptedChunks: attempted, failedChunks: attempted)
        }

        // Chunk to avoid overflowing the model's context window.
        var merged: [BatchResult] = []
        var cursor = 0
        var attemptedChunks = 0
        var failedChunks = 0
        while cursor < items.count {
            let end = min(cursor + Self.batchChunkSize, items.count)
            let chunk = Array(items[cursor..<end])
            attemptedChunks += 1
            let outcome = await categorizeChunkWithStatus(chunk, template: template)
            merged.append(contentsOf: outcome.results)
            if !outcome.succeeded { failedChunks += 1 }
            cursor = end
        }
        return BatchCategorizationResult(
            results: merged,
            attemptedChunks: attemptedChunks,
            failedChunks: failedChunks
        )
    }

    /// Single AI call for one chunk. Each `BatchResult.index` is the
    /// caller's original index (not re-numbered), so the merged output
    /// still aligns with the caller's input positions.
    private func categorizeChunk(_ items: [BatchItem], template: String) async -> [BatchResult] {
        await categorizeChunkWithStatus(items, template: template).results
    }

    private struct ChunkCategorizationResult {
        let results: [BatchResult]
        let succeeded: Bool
    }

    private func categorizeChunkWithStatus(_ items: [BatchItem], template: String) async -> ChunkCategorizationResult {
        let candidatesText = items.map { item in
            let msgs = item.messages.prefix(5)
                .map { "[\(clean($0.sender))] \(clean($0.body))" }
                .joined(separator: "\n")
            let groupLabel = item.isGroup ? "群聊" : "个人"
            return """
            \(item.index). \(clean(item.contactName)) (\(groupLabel), 近45天\(item.recentCount)条)
            最近消息:
            \(msgs)
            """
        }.joined(separator: "\n---\n")

        let userPrompt = template
            .replacingOccurrences(of: "{candidates}", with: candidatesText)

        let response = await call(userPrompt)
        guard !response.text.isEmpty else {
            return ChunkCategorizationResult(results: [], succeeded: false)
        }
        guard let results = parseBatch(response.text) else {
            return ChunkCategorizationResult(results: [], succeeded: false)
        }
        // An explicitly valid empty array means the model found no useful
        // recommendations; it is different from an empty/invalid response.
        return ChunkCategorizationResult(results: results, succeeded: true)
    }

    private func parseBatch(_ raw: String) -> [BatchResult]? {
        if let envelope = AIJSONExtractor.decodeFirstObject(from: raw, as: BatchResultEnvelope.self) {
            return envelope.items
        }
        return AIJSONExtractor.decodeFirstArray(from: raw, as: BatchResult.self)
    }

    // MARK: - Model call

    private struct ModelResponse {
        let text: String
        let error: String?
        let model: String?
    }

    private func call(_ userPrompt: String) async -> ModelResponse {
        let trackID = "categorizer:\(UUID().uuidString.prefix(8))"
        AIActivityTracker.shared.begin(trackID, label: "关注建议")
        defer { AIActivityTracker.shared.end(trackID) }

        do {
            let result = try await aiService.completeWithMetadata(
                system: "你是一个联系人分类助手，严格按要求输出 JSON。",
                user: userPrompt,
                options: CompleteOptions(timeout: 60, temperature: 0.05, maxTokens: 384, responseFormatJSON: true)
            )
            return ModelResponse(text: result.text, error: nil, model: result.model)
        } catch {
            return ModelResponse(text: "", error: error.localizedDescription, model: nil)
        }
    }

    // MARK: - Parsing

    private func parse(_ raw: String) -> Suggestion? {
        AIJSONExtractor.decodeFirstObject(from: raw, as: Suggestion.self)
    }

    // MARK: - Audit

    private func audit(input: Input, output: String, latencyMs: Int, status: AIAuditStatus, error: String?, model actualModel: String?) async {
        let model: String
        if let actualModel {
            model = actualModel
        } else {
            model = await aiService.currentConfig().model
        }
        let entry = AIAuditEntry(
            id: 0,
            ts: Date(),
            role: .ranker,
            model: model,
            promptVersion: promptVersion,
            inputText: "[contact:\(input.contactName)|n=\(input.messages.count)|group:\(input.isGroup)]",
            outputText: output,
            latencyMs: latencyMs,
            status: status,
            errorMessage: error
        )
        do { try store.writeAIAudit(entry) } catch {
            print("[WCHUD] AIWhitelistCategorizer: failed to write audit: \(error)")
        }
    }

    // MARK: - Helpers

    private func clean(_ s: String) -> String {
        AIService.sanitizeForAI(
            s.replacingOccurrences(of: "\n", with: " ")
             .replacingOccurrences(of: "\r", with: " ")
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func ms(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
    }
}
