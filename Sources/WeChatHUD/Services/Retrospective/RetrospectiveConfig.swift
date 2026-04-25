import Foundation

/// Tunables for the retrospective pipeline (Spec §6.4, §11). Conservative
/// defaults — UI can surface these in Preferences later.
struct RetrospectiveConfig: Sendable {
    var maxConcurrentChats: Int = 4
    var perChatTimeoutSeconds: TimeInterval = 60
    var totalTimeoutSeconds: TimeInterval = 30 * 60
    var maxChatsPerRun: Int = 20
    var maxMessagesPerChat: Int = 200
    var totalMessageHardCap: Int = 4000
    var redactorEnabled: Bool = true
    var ledgerRetentionDays: Int = 90
    var carryArchiveWeekThreshold: Int = 4

    static let `default` = RetrospectiveConfig()
}
