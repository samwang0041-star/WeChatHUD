// Sources/WeChatHUD/Views/PixelBuddyView.swift
import SwiftUI

// MARK: - Pixel Color Palette

enum PixelColor: UInt32 {
    case clear  = 0x00000000
    case skin   = 0xFFD4A574
    case hair   = 0xFF2C2C2C
    case shirt  = 0xFF4A90D9
    case pants  = 0xFF3C3C3C
    case eye    = 0xFF1A1A1A
    case accent = 0xFFFF6B6B

    var swiftUIColor: Color {
        if self == .clear { return .clear }
        let r = Double((rawValue >> 16) & 0xFF) / 255.0
        let g = Double((rawValue >> 8) & 0xFF) / 255.0
        let b = Double(rawValue & 0xFF) / 255.0
        return Color(red: r, green: g, blue: b)
    }
}

// MARK: - Buddy Mood

enum BuddyMood: CaseIterable, Equatable {
    case idle
    case scanning
    case pending
    case urgent
    case error
    case sleepy
    case browsing
    case analyzing
    case celebrating
}

// MARK: - Mood Derivation (pure function for testability)

/// Derive compact-bar mood from sync status and inbox items.
/// Priority: syncing > error > urgent > pending > idle
func deriveCompactMood(syncStatus: SyncStatus, hasUrgent: Bool, hasPending: Bool, idleMinutes: Int) -> BuddyMood {
    switch syncStatus {
    case .syncing:
        return .scanning
    case .stale, .waitingForWeChat, .error:
        return .error
    default:
        break
    }
    if hasUrgent { return .urgent }
    if hasPending { return .pending }
    if idleMinutes >= 5 { return .sleepy }
    return .idle
}

/// Derive extended-inbox mood from inbox state and AI activity.
func deriveExtendedMood(actionItemCount: Int, isAIProcessing: Bool) -> BuddyMood {
    if actionItemCount == 0 { return .celebrating }
    if isAIProcessing { return .analyzing }
    return .browsing
}
