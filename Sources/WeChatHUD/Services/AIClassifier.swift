import Foundation

/// Per-message ask classifier — Role 1 of the AI subsystem.
///
/// Wraps the existing `AIService` HTTP machinery and adds:
///   - independent config (separate model / temperature / endpoint)
///   - prompt loading from `Resources/prompts/` via `Bundle.module`
///   - JSON envelope cleanup (strips ```json fences, trims whitespace)
///   - one retry with a stricter "JSON only" reminder when parse fails
///   - audit log writes for every call (success and failure)
///
/// The classifier is a pure function of `ClassifierInput` — it does not
/// resolve `deadline_relative` to an absolute time, that conversion lives
/// at the call site so the classifier stays trivially testable.
///
/// See `docs/superpowers/plans/2026-04-12-wechathud-ai-subsystem.md`.
actor AIClassifier {
    private let store: HUDStore
    private let aiService: AIService
    private let promptLoader: PromptLoader
    private let promptVersion: String = "classifier_v1"

    init(store: HUDStore, aiService: AIService, promptLoader: PromptLoader = PromptLoader()) {
        self.store = store
        self.aiService = aiService
        self.promptLoader = promptLoader
    }

    /// Classify a single message. Returns nil only when the call could
    /// not produce a usable result after one retry — caller treats nil
    /// as "skip this message, will reattempt on the next scan."
    func classify(message: ClassifierInput) async -> ClassifierResult? {
        let started = Date()

        // Load + interpolate the prompt template. Failure here is a
        // build-time bug (missing resource), so we log loudly and bail.
        let template: String
        do {
            template = try promptLoader.load(version: promptVersion)
        } catch {
            print("[WCHUD] AIClassifier: prompt load failed: \(error)")
            return nil
        }

        let userPrompt = interpolate(template: template, with: message)

        // First attempt.
        let firstResponse = await callModel(userPrompt: userPrompt)
        if let parsed = parseResult(firstResponse.text) {
            await writeAudit(
                message: message,
                output: firstResponse.text,
                latencyMs: ms(since: started),
                status: .ok,
                error: nil,
                model: firstResponse.model
            )
            return parsed.with(promptVersion: promptVersion)
        }

        // First call yielded an HTTP / parse failure. Log it as parse_error
        // (or http_error if no body), then retry once with a stricter nudge.
        if firstResponse.text.isEmpty, let err = firstResponse.error {
            await writeAudit(
                message: message,
                output: "",
                latencyMs: ms(since: started),
                status: .httpError,
                error: err,
                model: firstResponse.model
            )
            return nil
        }

        let stricterPrompt = userPrompt + "\n\n严格要求：你的上一次输出无法被解析为 JSON。请只输出一个 JSON 对象，不要任何其它文字、markdown 围栏或解释。"
        let secondResponse = await callModel(userPrompt: stricterPrompt)
        if let parsed = parseResult(secondResponse.text) {
            await writeAudit(
                message: message,
                output: secondResponse.text,
                latencyMs: ms(since: started),
                status: .ok,
                error: "recovered after retry",
                model: secondResponse.model
            )
            return parsed.with(promptVersion: promptVersion)
        }

        await writeAudit(
            message: message,
            output: secondResponse.text,
            latencyMs: ms(since: started),
            status: .parseError,
            error: secondResponse.error ?? "could not parse JSON after retry",
            model: secondResponse.model
        )
        return nil
    }

    // MARK: - Model call

    private struct ModelResponse {
        let text: String
        let error: String?
        let model: String?
    }

    /// Chat completion routed through `AIService.complete` so the Codex /
    /// OpenAI-compatible provider selection is uniform. Preserves the
    /// `ModelResponse` contract so the retry / audit logic above stays
    /// untouched.
    private func callModel(userPrompt: String) async -> ModelResponse {
        let trackID = "classifier:\(UUID().uuidString.prefix(8))"
        AIActivityTracker.shared.begin(trackID, label: "消息分类")
        defer { AIActivityTracker.shared.end(trackID) }

        do {
            let result = try await aiService.completeWithMetadata(
                system: "你是一个微信消息分类器。严格按要求输出 JSON。",
                user: userPrompt,
                options: CompleteOptions(timeout: 30, temperature: 0.05, maxTokens: 256, responseFormatJSON: true)
            )
            return ModelResponse(text: result.text, error: nil, model: result.model)
        } catch {
            return ModelResponse(text: "", error: error.localizedDescription, model: nil)
        }
    }

    // MARK: - Parsing

    /// DTO that mirrors the prompt's JSON schema. We decode into this
    /// then translate to the public `ClassifierResult` to keep the wire
    /// shape decoupled from the runtime model.
    private struct ResultDTO: Decodable {
        let isAsk: Bool
        let type: String
        let summary: String
        let deadlineRelative: String?
        let confidence: Double

        enum CodingKeys: String, CodingKey {
            case isAsk = "is_ask"
            case type
            case summary
            case deadlineRelative = "deadline_relative"
            case confidence
        }
    }

    /// Try to extract a JSON object out of an arbitrary model response.
    /// Strategy: strip code fences → trim whitespace → if there's still
    /// junk around the JSON, find the first `{` and last `}` and slice.
    private func parseResult(_ raw: String) -> ClassifierResult? {
        guard let dto = AIJSONExtractor.decodeFirstObject(from: raw, as: ResultDTO.self) else {
            return nil
        }
        let askType = AskType(rawValue: dto.type) ?? .none
        let confidence = max(0, min(1, dto.confidence))
        return ClassifierResult(
            isAsk: dto.isAsk,
            type: askType,
            summary: dto.summary,
            deadlineRelative: (dto.deadlineRelative?.isEmpty == true) ? nil : dto.deadlineRelative,
            confidence: confidence,
            promptVersion: promptVersion
        )
    }

    // MARK: - Prompt interpolation

    private func interpolate(template: String, with message: ClassifierInput) -> String {
        let chatKind = message.isGroup ? "群聊" : "私聊"
        return template
            .replacingOccurrences(of: "{sender_name}", with: escape(message.senderName))
            .replacingOccurrences(of: "{chat_name}", with: escape(message.chatName))
            .replacingOccurrences(of: "{chat_kind}", with: chatKind)
            .replacingOccurrences(of: "{message_body}", with: escape(AIService.sanitizeForAI(message.text)))
    }

    /// Strip newlines / control characters from interpolated values so they
    /// can't break the prompt format. We don't escape JSON-style — the
    /// values land inside the prompt body as plain text, not JSON.
    private func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\n", with: " ")
         .replacingOccurrences(of: "\r", with: " ")
         .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Audit

    private func writeAudit(message: ClassifierInput, output: String, latencyMs: Int, status: AIAuditStatus, error: String?, model actualModel: String?) async {
        let model: String
        if let actualModel {
            model = actualModel
        } else {
            model = await aiService.currentConfig().model
        }
        let entry = AIAuditEntry(
            id: 0,
            ts: Date(),
            role: .classifier,
            model: model,
            promptVersion: promptVersion,
            inputText: "[\(message.senderName)@\(message.chatName)] \(message.text)",
            outputText: output,
            latencyMs: latencyMs,
            status: status,
            errorMessage: error
        )
        do {
            try store.writeAIAudit(entry)
        } catch {
            print("[WCHUD] AIClassifier: failed to write audit: \(error)")
        }
    }

    // MARK: - Helpers

    private func ms(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
    }
}

// MARK: - Result mutation helper

private extension ClassifierResult {
    func with(promptVersion: String) -> ClassifierResult {
        ClassifierResult(
            isAsk: isAsk,
            type: type,
            summary: summary,
            deadlineRelative: deadlineRelative,
            confidence: confidence,
            promptVersion: promptVersion
        )
    }
}

// MARK: - Prompt loader

/// Loads versioned prompt templates from the SPM resource bundle.
/// Caches them in memory after first read since prompts don't change at
/// runtime — bumping a version means deploying a new file.
final class PromptLoader {
    private var cache: [String: String] = [:]
    private let lock = NSLock()

    enum PromptError: Error {
        case notFound(String)
        case readFailed(String, underlying: Error)
    }

    func load(version: String) throws -> String {
        lock.lock()
        defer { lock.unlock() }

        if let cached = cache[version] { return cached }

        guard let url = Bundle.module.url(forResource: version, withExtension: "txt", subdirectory: "prompts") else {
            throw PromptError.notFound(version)
        }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            cache[version] = text
            return text
        } catch {
            throw PromptError.readFailed(version, underlying: error)
        }
    }
}
