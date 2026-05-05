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
    private let aiService: AIService
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

    init(aiService: AIService, store: HUDStore) {
        self.aiService = aiService
        self.store = store
    }

    // MARK: - Typed execution (auto JSON decode)

    /// Execute an AI call with automatic retry, JSON parsing, and audit logging.
    /// Returns the decoded value and the model name on success, nil on failure.
    func execute<T: Decodable>(
        prompt: String,
        configuration: Configuration,
        decodeAs: T.Type
    ) async -> (value: T, model: String?)? {
        let trackID = "\(configuration.trackLabel):\(UUID().uuidString.prefix(8))"
        AIActivityTracker.shared.begin(trackID, label: configuration.trackLabel)
        defer { AIActivityTracker.shared.end(trackID) }

        let started = Date()

        // First attempt
        let firstResult = await call(prompt: prompt, configuration: configuration)
        let latencyMs = Int(Date().timeIntervalSince(started) * 1000)

        guard let (text, model) = firstResult else {
            await writeAudit(
                input: configuration.inputSummary,
                output: "",
                latencyMs: latencyMs,
                status: .httpError,
                error: "AI call failed",
                model: nil,
                configuration: configuration
            )
            return nil
        }

        if let parsed = AIJSONExtractor.decodeFirstObject(from: text, as: decodeAs) {
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

        guard let (retryText, retryModel) = retryResult else {
            await writeAudit(
                input: configuration.inputSummary,
                output: "",
                latencyMs: latencyMs + retryLatencyMs,
                status: .httpError,
                error: "AI call failed on retry",
                model: model,
                configuration: configuration
            )
            return nil
        }

        if let retryParsed = AIJSONExtractor.decodeFirstObject(from: retryText, as: decodeAs) {
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

        guard let (text, model) = result else {
            await writeAudit(
                input: configuration.inputSummary,
                output: "",
                latencyMs: latencyMs,
                status: .httpError,
                error: "AI call failed",
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
    ) async -> (text: String, model: String?)? {
        do {
            let result = try await aiService.completeWithMetadata(
                system: configuration.systemPrompt,
                user: prompt,
                options: configuration.options
            )
            return (text: result.text, model: result.model)
        } catch {
            return nil
        }
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
