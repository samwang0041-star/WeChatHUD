import Foundation

/// Generates a 3-5 sentence "what did I miss" summary for a noisy
/// group chat. Designed to be triggered manually from a group row's
/// context menu, or automatically when the user opens a group with
/// > N unread messages since their last visit.
///
/// Pure service. Reads its config from `loadAIConfig()` so
/// it tracks whatever model the user has set.
actor AIGroupCatchup {
    private let store: HUDStore
    private let aiService: AIService
    private let promptLoader: PromptLoader
    private let promptVersion: String

    init(
        store: HUDStore,
        aiService: AIService,
        promptLoader: PromptLoader = PromptLoader(),
        promptVersion: String = "group_catchup_v1"
    ) {
        self.store = store
        self.aiService = aiService
        self.promptLoader = promptLoader
        self.promptVersion = promptVersion
    }

    /// Output of one catchup call.
    struct Summary: Decodable {
        let headline: String
        let highlights: [String]
        let needsUserAction: Bool
        let actionSummary: String
        let skipSafe: Bool
        let noiseRatio: Double

        enum CodingKeys: String, CodingKey {
            case headline
            case highlights
            case needsUserAction = "needs_user_action"
            case actionSummary = "action_summary"
            case skipSafe = "skip_safe"
            case noiseRatio = "noise_ratio"
        }
    }

    /// Input bundle. `messages` should be most-recent-last (chronological).
    /// Each entry: (sender, body). Caller is responsible for filtering
    /// out non-text messages and trimming length.
    struct Input {
        let chatName: String
        let selfName: String
        let messages: [(sender: String, body: String)]
    }

    /// Returns the structured catchup, or nil on parse/HTTP failure.
    func summarize(_ input: Input) async -> Summary? {
        let started = Date()

        let template: String
        do {
            template = try promptLoader.load(version: promptVersion)
        } catch {
            print("[WCHUD] AIGroupCatchup: prompt load failed: \(error)")
            return nil
        }

        // Format messages compactly: [sender] body  (one per line)
        let formattedMessages = input.messages
            .map { "[\(clean($0.sender))] \(clean($0.body))" }
            .joined(separator: "\n")

        let userPrompt = template
            .replacingOccurrences(of: "{chat_name}", with: clean(input.chatName))
            .replacingOccurrences(of: "{self_name}", with: clean(input.selfName))
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

    // MARK: - Model call

    private struct ModelResponse {
        let text: String
        let error: String?
        let model: String?
    }

    private func call(_ userPrompt: String) async -> ModelResponse {
        let trackID = "catchup:\(UUID().uuidString.prefix(8))"
        AIActivityTracker.shared.begin(trackID, label: "群聊追赶")
        defer { AIActivityTracker.shared.end(trackID) }

        do {
            let result = try await aiService.completeWithMetadata(
                system: "你是一个群聊补课助手，严格按要求输出 JSON。",
                user: userPrompt,
                options: CompleteOptions(timeout: 60, temperature: 0.15, maxTokens: 512, responseFormatJSON: true)
            )
            return ModelResponse(text: result.text, error: nil, model: result.model)
        } catch {
            return ModelResponse(text: "", error: error.localizedDescription, model: nil)
        }
    }

    // MARK: - Parsing

    private func parse(_ raw: String) -> Summary? {
        AIJSONExtractor.decodeFirstObject(from: raw, as: Summary.self)
    }

    // MARK: - Audit

    private func audit(input: Input, output: String, latencyMs: Int, status: AIAuditStatus, error: String?, model actualModel: String?) async {
        let model: String
        if let actualModel {
            model = actualModel
        } else {
            model = await aiService.currentConfig().model
        }
        let firstFew = input.messages.prefix(3).map { "\($0.sender): \($0.body.prefix(20))" }.joined(separator: " | ")
        let entry = AIAuditEntry(
            id: 0,
            ts: Date(),
            role: .retrospector,
            model: model,
            promptVersion: promptVersion,
            inputText: "[\(input.chatName)|n=\(input.messages.count)] \(firstFew)",
            outputText: output,
            latencyMs: latencyMs,
            status: status,
            errorMessage: error
        )
        do { try store.writeAIAudit(entry) } catch {
            print("[WCHUD] AIGroupCatchup: failed to write audit: \(error)")
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
