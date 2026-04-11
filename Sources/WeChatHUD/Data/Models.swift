import Foundation

// MARK: - Panel State

enum HUDState {
    case compact
    case notification
    case detail
}

// MARK: - Stats (CompactBar)

struct HUDStats {
    var unreadCount: Int = 0
    var atMentionCount: Int = 0
    var importantCount: Int = 0
    var syncStatus: SyncStatus = .idle
    var lastSyncAt: Date? = nil
}

enum SyncStatus {
    case idle
    case syncing
    case ok
    case stale       // >5 min since last sync
    case error(String)

    var dotColor: String {
        switch self {
        case .idle, .syncing: return "yellow"
        case .ok: return "green"
        case .stale: return "yellow"
        case .error: return "red"
        }
    }
}

// MARK: - Chat & Messages

struct ChatInfo: Identifiable, Hashable {
    let id: String           // username
    let displayName: String
    let isGroup: Bool

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: ChatInfo, rhs: ChatInfo) -> Bool { lhs.id == rhs.id }
}

struct MessageInfo: Identifiable {
    let id: String           // message UID
    let chatUsername: String
    let chatName: String
    let senderUsername: String
    let senderName: String
    let text: String
    let baseType: Int
    let subType: Int
    let createTime: Int      // unix timestamp

    var isAtMention: Bool { text.contains("@") }
    var relativeTime: String { Self.formatRelative(createTime) }

    static func formatRelative(_ ts: Int) -> String {
        let now = Int(Date().timeIntervalSince1970)
        let diff = now - ts
        if diff < 60 { return "刚刚" }
        if diff < 3600 { return "\(diff / 60)分钟前" }
        if diff < 86400 { return "\(diff / 3600)小时前" }
        if diff < 172800 { return "昨天" }
        if diff < 604800 { return "\(diff / 86400)天前" }
        let date = Date(timeIntervalSince1970: Double(ts))
        let fmt = DateFormatter()
        fmt.dateFormat = "MM-dd"
        return fmt.string(from: date)
    }
}

// MARK: - Notification

struct HUDNotification: Identifiable {
    let id = UUID()
    let chatName: String
    let senderName: String
    let snippet: String
    let isAtMention: Bool
    let timestamp: Date
}

// MARK: - Whitelist

struct WhitelistEntry: Identifiable {
    let id: String           // username
    let displayName: String
    let isGroup: Bool
    let category: WhitelistCategory
    let addedAt: Date
    let autoSuggested: Bool
}

enum WhitelistCategory: String, CaseIterable {
    case work
    case life
    case other

    var label: String {
        switch self {
        case .work: return "工作"
        case .life: return "生活"
        case .other: return "其他"
        }
    }
}

// MARK: - Settings

struct AIConfig: Codable {
    var baseURL: String = "http://127.0.0.1:11434/v1"
    var model: String = "qwen2.5:14b"
    var apiKey: String = ""
    var maxTokens: Int = 2048
    var temperature: Double = 0.3
}

struct SyncConfig: Codable {
    var intervalSeconds: Int = 30
    var wechatDBPath: String = "auto"
}

struct NotificationConfig: Codable {
    var atMention: Bool = true
    var important: Bool = true
    var allWhitelist: Bool = false
    var durationSeconds: Int = 3
}

// MARK: - DB Key

struct DBKey {
    let relativePath: String
    let encKey: Data         // 32 bytes
}
