import Foundation

/// Pure utility functions shared across the monitoring pipeline.
/// Extracted from ChatMonitor to keep the coordinator small.
enum MessageHelpers {

    /// Check if a message text @-mentions the current user or @everyone.
    static func isAtMe(_ text: String, myUsername: String) -> Bool {
        if !myUsername.isEmpty, text.contains("@\(myUsername)") { return true }
        if text.contains("@所有人") { return true }
        if text.range(of: "@all", options: .caseInsensitive) != nil { return true }
        return false
    }

    /// Classify whether a message is from the user themselves.
    /// In group chats, WeChat DB sometimes stores senderUsername as a display
    /// name rather than wxid when the name2id lookup fails. Pass myDisplayName
    /// so we can catch that fallback case.
    static func isFromSelf(
        _ msg: MessageInfo,
        chatUsername: String,
        myUsername: String,
        myDisplayName: String = ""
    ) -> Bool {
        if !myUsername.isEmpty && msg.senderUsername == myUsername { return true }
        // Group chat fallback: senderUsername might be a display name instead of wxid
        if chatUsername.contains("@chatroom") && !myDisplayName.isEmpty {
            if msg.senderUsername == myDisplayName || msg.senderName == myDisplayName {
                return true
            }
        }
        if !chatUsername.contains("@chatroom") && !msg.senderUsername.isEmpty {
            if msg.senderUsername != chatUsername && msg.senderUsername != msg.chatUsername {
                return true
            }
        }
        return false
    }

    /// Derive the unread status from raw signals.
    static func unreadStatus(
        replied: Bool,
        timestamp: Date,
        isVIP: Bool,
        thresholds: UnreadThresholds
    ) -> UnreadStatus {
        if replied { return .answered }
        let minutes = isVIP ? thresholds.vipMinutes : thresholds.normalMinutes
        let age = Date().timeIntervalSince(timestamp) / 60
        return age >= Double(minutes) ? .overdue : .pending
    }

    /// Canonical sender identifier — delegates to HUDStore's static version.
    static func senderIdentifier(
        senderUsername: String,
        senderName: String
    ) -> String {
        HUDStore.senderIdentifier(senderUsername: senderUsername, senderName: senderName)
    }

    /// Check if a message's sender is in the ignored set for its chat.
    static func isIgnoredSender(
        _ msg: MessageInfo,
        ignoredSenderMap: [String: Set<String>]
    ) -> Bool {
        let identifier = senderIdentifier(
            senderUsername: msg.senderUsername,
            senderName: msg.senderName
        )
        return ignoredSenderMap[msg.chatUsername]?.contains(identifier) == true
    }

    /// Parse relative deadline strings like "+30m", "+2h", "+1d", "+1w"
    /// into an absolute Date. Returns nil for invalid input.
    static func resolveDeadline(_ relative: String) -> Date? {
        let cleaned = relative.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard cleaned.hasPrefix("+"), cleaned.count >= 3 else { return nil }
        let numStr = String(cleaned.dropFirst().dropLast())
        guard let num = Double(numStr), num > 0 else { return nil }
        let unit = cleaned.last
        let seconds: TimeInterval
        switch unit {
        case "m": seconds = num * 60
        case "h": seconds = num * 3600
        case "d": seconds = num * 86400
        case "w": seconds = num * 604800
        default: return nil
        }
        return Date().addingTimeInterval(seconds)
    }
}
