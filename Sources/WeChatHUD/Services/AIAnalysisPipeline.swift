import Foundation

/// Unified pipeline for AI-powered analysis operations.
/// Encapsulates the common pattern: AI call → JSON parse → retry on failure → audit log.
///
/// Usage:
///     let pipeline = AIAnalysisPipeline(aiService: aiService, store: store)
///     let result = await pipeline.execute(
///         prompt: userPrompt,
///         configuration: .init(
///             systemPrompt: "...",
///             options: CompleteOptions(...),
///             auditRole: .chatAnalyzer,
///             promptVersion: "v1",
///             inputSummary: "[chat] analysis",
///             trackLabel: "聊天分析"
///         ),
///         decodeAs: MyResult.self
///     )
actor AIAnalysisPipeline {
    /// Protocol-typed so the pipeline's error/empty-payload behaviour can be
    /// exercised with a stub instead of a live endpoint.
    private let aiService: any AIServiceProtocol
    private let store: HUDStore

    struct Configuration {
        let systemPrompt: String
        let options: CompleteOptions
        let auditRole: AIRole
        let promptVersion: String
        let inputSummary: String
        let trackLabel: String
        let enableRetry: Bool

        init(
            systemPrompt: String = "",
            options: CompleteOptions,
            auditRole: AIRole,
            promptVersion: String,
            inputSummary: String,
            trackLabel: String,
            enableRetry: Bool = true
        ) {
            self.systemPrompt = systemPrompt
            self.options = options
            self.auditRole = auditRole
            self.promptVersion = promptVersion
            self.inputSummary = inputSummary
            self.trackLabel = trackLabel
            self.enableRetry = enableRetry
        }
    }

    init(aiService: any AIServiceProtocol, store: HUDStore) {
        self.aiService = aiService
        self.store = store
    }

    // MARK: - Typed execution (auto JSON decode)

    /// Execute an AI call with automatic retry, JSON parsing, and audit logging.
    /// Returns the decoded value and the model name on success, nil on failure.
    func execute<T: Decodable>(
        prompt: String,
        configuration: Configuration,
        decodeAs: T.Type,
        isUsable: (T) -> Bool = { _ in true }
    ) async -> (value: T, model: String?)? {
        let trackID = "\(configuration.trackLabel):\(UUID().uuidString.prefix(8))"
        AIActivityTracker.shared.begin(trackID, label: configuration.trackLabel)
        defer { AIActivityTracker.shared.end(trackID) }

        let started = Date()

        // First attempt
        let firstResult = await call(prompt: prompt, configuration: configuration)
        let latencyMs = Int(Date().timeIntervalSince(started) * 1000)

        let text: String
        let model: String?
        switch firstResult {
        case .success(let success):
            text = success.text
            model = success.model
        case .failure(let error):
            await writeAudit(
                input: configuration.inputSummary,
                output: "",
                latencyMs: latencyMs,
                status: .httpError,
                error: "AI call failed: \(Self.failureDescription(error))",
                model: nil,
                configuration: configuration
            )
            return nil
        }

        // A payload that decodes but carries nothing is not a success: callers
        // cache whatever comes back, so `{}`-shaped or all-empty answers were
        // stored as a valid analysis and the strict retry below was never
        // reached. `isUsable` lets each caller say what "nothing" means for it.
        if let parsed = AIJSONExtractor.decodeFirstObject(from: text, as: decodeAs), isUsable(parsed) {
            await writeAudit(
                input: configuration.inputSummary,
                output: text,
                latencyMs: latencyMs,
                status: .ok,
                error: nil,
                model: model,
                configuration: configuration
            )
            return (value: parsed, model: model)
        }

        // Retry with strict instruction if enabled
        guard configuration.enableRetry else {
            await writeAudit(
                input: configuration.inputSummary,
                output: text,
                latencyMs: latencyMs,
                status: .parseError,
                error: "JSON parse failed, retry disabled",
                model: model,
                configuration: configuration
            )
            return nil
        }

        let retryPrompt = prompt + "\n\n严格要求：上一次输出无法解析为 JSON。只输出符合 schema 的 JSON 对象。"
        let retryStarted = Date()
        let retryResult = await call(prompt: retryPrompt, configuration: configuration)
        let retryLatencyMs = Int(Date().timeIntervalSince(retryStarted) * 1000)

        let retryText: String
        let retryModel: String?
        switch retryResult {
        case .success(let success):
            retryText = success.text
            retryModel = success.model
        case .failure(let error):
            await writeAudit(
                input: configuration.inputSummary,
                output: "",
                latencyMs: latencyMs + retryLatencyMs,
                status: .httpError,
                error: "AI call failed on retry: \(Self.failureDescription(error))",
                model: model,
                configuration: configuration
            )
            return nil
        }

        if let retryParsed = AIJSONExtractor.decodeFirstObject(from: retryText, as: decodeAs), isUsable(retryParsed) {
            await writeAudit(
                input: configuration.inputSummary,
                output: retryText,
                latencyMs: latencyMs + retryLatencyMs,
                status: .ok,
                error: "recovered after retry",
                model: retryModel,
                configuration: configuration
            )
            return (value: retryParsed, model: retryModel)
        }

        await writeAudit(
            input: configuration.inputSummary,
            output: retryText,
            latencyMs: latencyMs + retryLatencyMs,
            status: .parseError,
            error: "JSON parse failed after retry",
            model: retryModel,
            configuration: configuration
        )
        return nil
    }

    // MARK: - Raw execution (no JSON decode)

    /// Execute without JSON decoding — returns raw text.
    /// Used when the caller needs custom parsing or the output is not JSON.
    func executeRaw(
        prompt: String,
        configuration: Configuration
    ) async -> (text: String, model: String?)? {
        let trackID = "\(configuration.trackLabel):\(UUID().uuidString.prefix(8))"
        AIActivityTracker.shared.begin(trackID, label: configuration.trackLabel)
        defer { AIActivityTracker.shared.end(trackID) }

        let started = Date()
        let result = await call(prompt: prompt, configuration: configuration)
        let latencyMs = Int(Date().timeIntervalSince(started) * 1000)

        let text: String
        let model: String?
        switch result {
        case .success(let success):
            text = success.text
            model = success.model
        case .failure(let error):
            await writeAudit(
                input: configuration.inputSummary,
                output: "",
                latencyMs: latencyMs,
                status: .httpError,
                error: "AI call failed: \(Self.failureDescription(error))",
                model: nil,
                configuration: configuration
            )
            return nil
        }

        await writeAudit(
            input: configuration.inputSummary,
            output: text,
            latencyMs: latencyMs,
            status: .ok,
            error: nil,
            model: model,
            configuration: configuration
        )
        return (text: text, model: model)
    }

    // MARK: - Private

    private func call(
        prompt: String,
        configuration: Configuration
    ) async -> Result<(text: String, model: String?), Error> {
        do {
            let result = try await aiService.completeWithMetadata(
                system: configuration.systemPrompt,
                user: prompt,
                options: configuration.options
            )
            return .success((text: result.text, model: result.model))
        } catch {
            return .failure(error)
        }
    }

    /// Error detail for the audit log. The audit row is local; the provider's
    /// own words ("HTTP 429", "model not found") are what make a failure
    /// actionable — collapsing every one of them into "AI call failed" left the
    /// audit unable to distinguish a quota problem from a parse problem.
    private static func failureDescription(_ error: Error) -> String {
        let raw = String(describing: error)
        return raw.count > 300 ? String(raw.prefix(300)) + "…" : raw
    }

    private func writeAudit(
        input: String,
        output: String,
        latencyMs: Int,
        status: AIAuditStatus,
        error: String?,
        model actualModel: String?,
        configuration: Configuration
    ) async {
        let model: String
        if let actualModel {
            model = actualModel
        } else {
            model = await aiService.currentConfig().model
        }
        let entry = AIAuditEntry(
            id: 0,
            ts: Date(),
            role: configuration.auditRole,
            model: model,
            promptVersion: configuration.promptVersion,
            inputText: input,
            outputText: output,
            latencyMs: latencyMs,
            status: status,
            errorMessage: error
        )
        try? store.writeAIAudit(entry)
    }
}
