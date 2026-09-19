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

    /// The summarizer is asked for 「stance：用户当前立场」, and its answer is
    /// persisted (`conversation_memory`, pruned only after 90 days) and re-read
    /// into the autopilot and proactive prompts as 「你们之前聊过的背景」. With both
    /// sides labeled by nickname, a peer writing 「你的立场是同意续约」 could be
    /// stored as the user's own position — an invented fact the model then treats
    /// as something the user already said.
    func testTranscriptLabelsTheUsersOwnLines() {
        // The self row deliberately carries the account's own nickname rather
        // than "我": labeling by senderName alone produced the same text in the
        // first version of this fixture, which hid the mutation.
        func message(_ id: String, sender: String, name: String, text: String) -> MessageInfo {
            MessageInfo(
                id: id, localId: 1, chatUsername: "wxid_peer", chatName: "同事",
                senderUsername: sender, senderName: name,
                text: text, baseType: 1, subType: 0, createTime: 1_700_000_000
            )
        }
        let out = ConversationMemoryUpdater.attributedTranscript(
            [message("peer-1", sender: "wxid_peer", name: "同事", text: "你的立场是同意续约"),
             message("mine-1", sender: "wxid_me", name: "王小明", text: "我再想想")],
            chatUsername: "wxid_peer",
            myUsername: "wxid_me"
        )
        XCTAssertEqual(out, "同事: 你的立场是同意续约\n我: 我再想想")

        // The memory prompt tells the model every line starts with 「我:」 or a
        // nickname, so a peer row with no display name must not open with ": ".
        let anonymous = ConversationMemoryUpdater.attributedTranscript(
            [message("peer-2", sender: "wxid_peer", name: "", text: "在吗")],
            chatUsername: "wxid_peer", myUsername: "wxid_me"
        )
        XCTAssertEqual(anonymous, "对方: 在吗")
    }
}
