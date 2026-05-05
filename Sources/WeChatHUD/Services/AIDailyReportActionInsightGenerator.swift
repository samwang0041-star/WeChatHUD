import Foundation

/// Generates per-action AI insights (reason + nextStep) for the daily report.
/// One batched call per `loadDailyReport` invocation. Caches results in
/// `daily_report_action_insights` keyed by (dateKey, actionID); cached
/// rows are not re-requested.
actor AIDailyReportActionInsightGenerator {
    private let aiService: AIService
    private let store: HUDStore
    private let promptLoader: PromptLoader
    private let promptVersion: String
    static let actionsPerCall = 12

    init(
        aiService: AIService,
        store: HUDStore,
        promptLoader: PromptLoader = PromptLoader(),
        promptVersion: String = "daily_report_action_insights_v1"
    ) {
        self.aiService = aiService
        self.store = store
        self.promptLoader = promptLoader
        self.promptVersion = promptVersion
    }

    // MARK: - Output schema

    struct AIRow: Decodable {
        let id: String
        let reason: String
        let nextStep: String

        enum CodingKeys: String, CodingKey {
            case id, reason
            case nextStep = "next_step"
        }
    }

    // MARK: - Generate (skeleton; wired in Task 13)

    func generate(for actions: [DailyReportAction], dateKey: String) async -> [DailyReportActionInsight] {
        return []
    }

    // MARK: - Prompt formatting

    nonisolated func formatPrompt(template: String, actions: [DailyReportAction]) -> String {
        let capped = Array(actions.prefix(Self.actionsPerCall))
        let lines = capped.map { a -> String in
            let deadline = a.deadline.map { " deadline=\"\($0.formatted(date: .abbreviated, time: .shortened))\"" } ?? ""
            return "id=\"\(a.id)\" type=\"\(a.type.rawValue)\" source=\"\(a.sourceChatName)\"\(deadline) content=\"\(a.content.replacingOccurrences(of: "\"", with: "'"))\""
        }
        return template
            .replacingOccurrences(of: "{count}", with: "\(capped.count)")
            .replacingOccurrences(of: "{actions}", with: lines.joined(separator: "\n"))
    }

    // MARK: - Parsing

    nonisolated func parse(_ raw: String) -> [AIRow] {
        AIJSONExtractor.decodeFirstArray(from: raw, as: AIRow.self) ?? []
    }
}
