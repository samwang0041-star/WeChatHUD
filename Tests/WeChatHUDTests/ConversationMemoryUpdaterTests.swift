import XCTest
@testable import WeChatHUD

/// Conversation memories must eventually cover the whole whitelist.
///
/// `updateStaleMemories` truncated the whitelist with `prefix(maxChats)`
/// *before* the staleness check inside `updateMemoryIfNeeded`, so the 6th entry
/// onward could never be selected while the first five stayed fresh. Autopilot's
/// proactive path requires a memory, so proactive outreach was silently dead for
/// every chat past the fifth.
final class ConversationMemoryUpdaterTests: XCTestCase {
    private func entry(_ id: String) -> WhitelistEntry {
        WhitelistEntry(
            id: id,
            displayName: id,
            isGroup: false,
            category: .work,
            attentionLevel: .watch,
            addedAt: Date(timeIntervalSince1970: 0),
            autoSuggested: false
        )
    }

    func testStaleChatsBeyondTheFirstPageAreStillSelected() {
        let whitelist = (1...8).map { entry("chat_\($0)") }
        let now = Date(timeIntervalSince1970: 100_000)
        // The first five are fresh; the 6th–8th were never refreshed.
        let refreshed: [String: Date] = [
            "chat_1": now, "chat_2": now, "chat_3": now, "chat_4": now, "chat_5": now
        ]

        let selected = ConversationMemoryUpdater.staleChats(
            whitelist: whitelist,
            lastUpdated: { refreshed[$0] },
            now: now,
            maxChats: 3,
            stalenessSeconds: 1_800
        )

        XCTAssertEqual(selected.map(\.id), ["chat_6", "chat_7", "chat_8"])
    }

    func testStalestChatsComeFirst() {
        let whitelist = (1...3).map { entry("chat_\($0)") }
        let now = Date(timeIntervalSince1970: 100_000)
        let updated: [String: Date] = [
            "chat_1": now.addingTimeInterval(-100),
            "chat_2": now.addingTimeInterval(-10_000),
            "chat_3": now.addingTimeInterval(-5_000)
        ]

        let selected = ConversationMemoryUpdater.staleChats(
            whitelist: whitelist,
            lastUpdated: { updated[$0] },
            now: now,
            maxChats: 2,
            stalenessSeconds: 1_800
        )

        XCTAssertEqual(selected.map(\.id), ["chat_2", "chat_3"])
    }

    func testFreshAndUnknownChatsAreHandledSeparately() {
        let whitelist = [entry("fresh"), entry("never_built"), entry("stale")]
        let now = Date(timeIntervalSince1970: 100_000)
        let updated: [String: Date] = [
            "fresh": now,
            "stale": now.addingTimeInterval(-3_600)
        ]

        let selected = ConversationMemoryUpdater.staleChats(
            whitelist: whitelist,
            lastUpdated: { updated[$0] },
            now: now,
            maxChats: 5,
            stalenessSeconds: 1_800
        )

        // A chat with no memory yet counts as stale — it is what autopilot's
        // proactive path is waiting for.
        XCTAssertEqual(Set(selected.map(\.id)), ["never_built", "stale"])
    }
}
