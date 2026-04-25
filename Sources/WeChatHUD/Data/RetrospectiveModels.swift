import Foundation

// MARK: - Run lifecycle

enum ReviewRunStatus: String, Sendable {
    case running, completed, partial, failed
}

struct ReviewRun: Identifiable, Sendable {
    let id: Int
    let rangeStart: Date
    let rangeEnd: Date
    let generatedAt: Date
    let summaryTop3: [SummaryItem]
    let summaryRisk: SummaryItem?
    let summaryMissed: SummaryItem?
    let chatCount: Int
    let progressChatCount: Int
    let msgCount: Int
    let failedChats: [String]
    let status: ReviewRunStatus
}

struct SummaryItem: Codable, Sendable {
    let text: String
    let evidenceHighlightIDs: [Int]
}

// MARK: - Highlights

enum HighlightCategory: String, Codable, Sendable {
    case decision, progress, discussion, risk
}

enum Relation: String, Codable, Sendable {
    case superior, peer, subordinate, client, friend, unknown
}

struct ReviewHighlight: Identifiable, Sendable {
    let id: Int
    let runID: Int
    let date: Date
    let summary: String
    let quotedSnippet: String?
    let involved: [String]
    let sourceChatUsername: String
    let sourceChatName: String
    let relation: Relation
    let sourceMsgIDs: [String]
    let confidence: Double
    let category: HighlightCategory
    let flaggedUncertain: Bool
}

// MARK: - Todos

enum TodoDirection: String, Codable, Sendable {
    case mine, theirs, unclear
}

enum TodoStatus: String, Sendable {
    case pending, completed, snoozed
    case notMine = "not_mine"
    case delegated, archived
}

struct ReviewTodo: Identifiable, Sendable {
    let id: Int
    let originRunID: Int
    let lastRunID: Int
    let content: String
    let deadline: Date?
    let direction: TodoDirection
    let involved: [String]
    let sourceChatUsername: String
    let sourceChatName: String
    let sourceMsgIDs: [String]
    let confidence: Double
    let status: TodoStatus
    let createdAt: Date
    let completedAt: Date?
    let snoozedTo: Date?
    let delegatedTo: String?
    let carryCount: Int
    let lastUserActionAt: Date?
}

// MARK: - Group scope

enum ScopeDecision: String, Sendable {
    case include, exclude
    case askEachTime = "ask_each_time"
}

enum ScopeSource: String, Sendable {
    case ai, user
}

struct GroupScopePolicy: Sendable {
    let chatUsername: String
    let decision: ScopeDecision
    let source: ScopeSource
    let decidedAt: Date
    let sampleHash: String?
    let userAuthorized: Bool
}

// MARK: - Ledger

enum LedgerPurpose: String, Sendable {
    case groupScreen = "group_screen"
    case chatAnalysis = "chat_analysis"
    case chatAnalysisFailed = "chat_analysis_failed"
    case summarySynth = "summary_synth"
}

struct AILedgerEntry: Sendable {
    let id: Int
    let ts: Date
    let provider: String
    let model: String
    let purpose: LedgerPurpose
    let chatCount: Int?
    let msgCount: Int?
    let byteCount: Int
    let tokenIn: Int?
    let tokenOut: Int?
    let redacted: Bool
}

// MARK: - Red banner

enum RedBannerAction: String, Sendable {
    case repliedExternally = "replied_externally"
    case aiWrong = "ai_wrong"
    case snoozed
}

struct RedBannerDismissal: Sendable {
    let id: Int
    let todoID: Int
    let action: RedBannerAction
    let reasonText: String?
    let snoozedTo: Date?
    let createdAt: Date
}

// MARK: - Undo

enum UndoOperation: String, Sendable {
    case statusChange = "status_change"
}

struct UndoEntry: Sendable {
    let id: Int
    let ts: Date
    let targetTable: String
    let targetID: Int
    let operation: UndoOperation
    let payloadBefore: String   // JSON
    let payloadAfter: String    // JSON
}

// MARK: - Notification (used by HUDStore +Retrospective writes)

extension Notification.Name {
    static let retrospectiveLiveUpdate = Notification.Name("retrospectiveLiveUpdate")
}
