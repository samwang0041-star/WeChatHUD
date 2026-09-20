import XCTest
@testable import WeChatHUD

/// 「静音此对话」 has to mean the assistant leaves that conversation alone.
///
/// The mute was honored by two of the three surfaces that act on a message and
/// ignored by the third: `ScanEngine` hid the inbox row and suppressed the
/// banner from `silencedAt`, but both feeds into the unattended reply pipeline
/// (:727 and :978) consulted neither. So muting someone removed the only place
/// the incoming message was ever visible, while the AI kept drafting — and
/// with 自动发出去 on, kept sending — replies to that same peer.
///
/// The three cases below are the whole contract: permanent mute blocks the
/// feed, no mute produces it, and an *expired* mute must not (that half is what
/// keeps a snooze-shaped `silencedAt` from silently becoming a permanent one).
final class SilenceStopsUnattendedReplyTests: XCTestCase {
    private let chat = "muted_peer"

    private func scan(_ reader: WeChatReader, store: HUDStore) async throws -> ScanEngine.ScanOutcome? {
        await ScanEngine.performScan(
            reader: reader,
            store: store,
            aiService: AIService(config: AIConfig()),
            changedRelPaths: nil,
            thresholds: UnreadThresholds(),
            replyDebtConfig: ReplyDebtConfig(),
            currentRecent: [],
            recentLimit: 10,
            autopilotActive: true
        )
    }

    private func makeStore(
        rows: [SyntheticShardedScanFixture.MessageRow],
        unreadCount: Int
    ) throws -> (SyntheticShardedScanFixture, HUDStore) {
        let fixture = try SyntheticShardedScanFixture(
            chatUsername: chat, shards: [0: rows], unreadCount: unreadCount
        )
        let store = try fixture.makeStore()
        try store.addToWhitelist(
            username: chat, displayName: "同事甲", isGroup: false,
            category: .work, attentionLevel: .watch
        )
        return (fixture, store)
    }

    /// senderId 1 = the peer, 2 = this account.
    private func inbound(_ id: Int, at time: Int, text: String) -> SyntheticShardedScanFixture.MessageRow {
        .init(localId: id, createTime: time, senderId: 1, text: text)
    }

    /// The first whitelist scan deliberately queues nothing (a backlog is not a
    /// conversation starter), so the control needs two scans before the mute
    /// assertion can mean anything. Same store throughout: the cursor from scan
    /// one is what makes scan two a "new message" round.
    private func feedAfterTwoScans(
        silence: ((HUDStore) -> Void)? = nil
    ) async throws -> [AutopilotService.InboundMessage] {
        let base = 1_800_000_000
        let (fixture, store) = try makeStore(
            rows: [inbound(1, at: base, text: "第一句")], unreadCount: 1
        )
        defer { fixture.cleanup(); store.close() }
        _ = try await scan(fixture.reader, store: store)

        try fixture.rewriteShard(0, rows: [
            inbound(1, at: base, text: "第一句"),
            inbound(2, at: base + 60, text: "第二句"),
        ])
        silence?(store)
        let outcome = try await scan(fixture.reader, store: store)
        return try XCTUnwrap(outcome).newInboundMessages.filter { $0.chatUsername == chat }
    }

    /// Control: the same fixture without a mute does reach the feed, so the
    /// assertion below is not just "nothing ever arrives here".
    ///
    /// Coverage note for whoever extends this: a whitelisted private chat
    /// arrives through the whitelist feed (`:727`), which is what these three
    /// cases exercise. The second feed — the contact-based one at `:978`, which
    /// had no mute check at all — is held by
    /// `testEveryAutopilotFeedChecksTheMute` rather than by a scan here, because
    /// reaching it needs a non-whitelisted contact fixture.
    func testUnmutedPeerReachesTheUnattendedReplyFeed() async throws {
        let feed = try await feedAfterTwoScans()
        XCTAssertFalse(feed.isEmpty, "对照组必须是通的，否则下面的断言是空的")
    }

    func testPermanentlySilencedPeerNeverReachesThatFeed() async throws {
        let farFuture = Int(Date().timeIntervalSince1970) + 10 * 365 * 24 * 3600
        let feed = try await feedAfterTwoScans { store in
            try? store.silenceChat(chatUsername: self.chat, silencedAt: farFuture)
        }
        XCTAssertTrue(feed.isEmpty, "静音之后仍然把这条对话交给无人值守回复管线")
    }

    func testExpiredSilenceDoesNotBlockTheFeed() async throws {
        let past = Int(Date().timeIntervalSince1970) - 3600
        let feed = try await feedAfterTwoScans { store in
            try? store.silenceChat(chatUsername: self.chat, silencedAt: past)
        }
        XCTAssertFalse(feed.isEmpty, "过期的 silencedAt 不能当成长期静音用")
    }

    /// Both feeds are separate `if` blocks over separate loops, so one of them
    /// being guarded is not evidence the other is. A third feed added later
    /// fails this floor by construction: it counts appends, not guards.
    ///
    /// This used to count the *text* `silencedAt ?? 0) > nowEpoch`, which scored
    /// nothing but the spelling: it was satisfied by a comparison in a dead
    /// branch, and — worse — went RED when a feed was migrated onto the shared
    /// sentinel, i.e. it pinned the duplication it claimed to police.
    func testEveryAutopilotFeedChecksTheMute() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/WeChatHUD")
        let source = try String(
            contentsOf: root.appendingPathComponent("Services/ScanEngine.swift"), encoding: .utf8)
        let appends = source.components(separatedBy: "autopilotInbound.append(inbound)").count - 1
        XCTAssertGreaterThanOrEqual(appends, 2, "锚点：两处投递都要被数到")
        let guards = source.components(separatedBy: "isPermanentlySilenced(nowEpoch: nowEpoch)").count - 1
        XCTAssertGreaterThanOrEqual(guards, appends,
                                    "投递点比静音判据多：有一处投递没查静音")
        XCTAssertFalse(source.contains("silencedAt ?? 0) >"),
                       "又自己拼了一次「现在算不算静音」，两处判据会漂移")
        XCTAssertFalse(source.contains("silencedAt ?? 0) <="),
                       "同上：反向拼写也算第二处实现")
    }

    /// One sentinel, read one way. The 「永久」 watermark is `now + 10 years`, so
    /// "is this chat muted" is only answerable against a moment — and it must be
    /// the same moment-rule for all four readers.
    ///
    /// The rule itself used to be two different things: the feeds and the send
    /// gate asked `silencedAt > now`, the inbox hydration asked
    /// `silencedAt > now + 1 year`. Because `silencedAt` doubles as the ordinary
    /// 「隐藏此对话」 watermark — which is written as the newest message's own
    /// time — a peer whose clock runs a few seconds ahead produced a future
    /// watermark, and the stricter rule silently promoted a one-off dismiss into
    /// a mute that starved the conversation of replies until the sentinel list
    /// was opened.
    func testPermanentSilenceSentinelHasOneReader() {
        let now = 1_800_000_000
        func state(_ silencedAt: Int) -> HUDStore.ChatActionState {
            HUDStore.ChatActionState(silencedAt: silencedAt, snoozedUntil: 0)
        }
        XCTAssertFalse(state(now - 1).isPermanentlySilenced(nowEpoch: now), "过期水印不是静音")
        XCTAssertFalse(state(now).isPermanentlySilenced(nowEpoch: now), "正好等于现在也不算")
        XCTAssertTrue(state(now + 10 * 365 * 24 * 3600).isPermanentlySilenced(nowEpoch: now))
        // The discriminator between the two meanings of the same column.
        XCTAssertFalse(state(now + 30).isPermanentlySilenced(nowEpoch: now),
                       "对方时钟快了 30 秒，不该把「隐藏此对话」变成永久静音")
        XCTAssertFalse(state(now + 30 * 24 * 3600).isPermanentlySilenced(nowEpoch: now),
                       "30 天也不是永久")
        XCTAssertTrue(state(now + 2 * 365 * 24 * 3600).isPermanentlySilenced(nowEpoch: now),
                      "越过一年缓冲才算哨兵，和收件箱那侧同一条线")
    }

    /// Wiring for the rule above: the inbox hydration used to keep its own copy
    /// of the threshold, so the two sides could disagree about whether a chat is
    /// muted — one of them showing it in 「已静音的对话」 while the other kept
    /// handing it to the reply pipeline.
    func testInboxHydrationUsesTheSameSentinel() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/WeChatHUD")
        let monitor = try String(
            contentsOf: root.appendingPathComponent("Services/ChatMonitor.swift"), encoding: .utf8)
        let hydrate = (monitor.components(separatedBy: "dismissedInbox.removeAll(keepingCapacity: true)").last ?? "")
            .components(separatedBy: "/// Dismiss an inbox item").first ?? ""
        XCTAssertFalse(hydrate.isEmpty, "切片为空则这条判据什么都没看")
        XCTAssertTrue(hydrate.contains("action.isPermanentlySilenced(nowEpoch: nowEpoch)"),
                      "收件箱那侧要读同一条判据")
        XCTAssertFalse(hydrate.contains("permanentThreshold"),
                      "阈值不许在这一处再算一遍")
        XCTAssertFalse(monitor.contains("silencedAt > nowEpoch"),
                       "ChatMonitor 里不许留第三种拼写")
    }

    /// The escape hatch has to be durable. The list used to be
    /// `monitor.silencedItems`, i.e. rows the InboxBuilder could only produce from
    /// the ~20-item notification ring — so a mute stayed in the database while the
    /// only 取消静音 button scrolled out of existence.
    func testUnmuteListReadsTheDurableTable() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/WeChatHUD")
        let view = try String(
            contentsOf: root.appendingPathComponent("Views/Settings/ContactsSettingsView.swift"),
            encoding: .utf8)
        XCTAssertTrue(view.contains("monitor.silencedConversations"),
                      "静音清单要读持久状态")
        XCTAssertTrue(view.contains("monitor.silencedConversationsRead"),
                      "管理页要拿得到第三种答案")
        XCTAssertTrue(view.contains("暂时读不到静音名单"),
                      "读不到那一支不许退回「没有静音的对话」：那句话会拿走它自己叫用户去按的按钮")
        XCTAssertFalse(view.contains("monitor.silencedItems"),
                       "读回收件箱行 = 那个行一消失，用户就没法取消静音了")

        let monitor = try String(
            contentsOf: root.appendingPathComponent("Services/ChatMonitor.swift"),
            encoding: .utf8)
        let list = try XCTUnwrap(
            monitor.components(separatedBy: "var silencedConversationsRead:").last
        ).components(separatedBy: "\n    }\n").first ?? ""
        XCTAssertTrue(list.contains("chatActionsRead"),
                      "清单要读那份能回答「读不到」的读法：空字典不是「没人被静音」")
        XCTAssertTrue(list.contains("isPermanentlySilenced"),
                      "要用那一条共用的静音判据，而不是第六种写法")
        let unmute = try XCTUnwrap(
            monitor.components(separatedBy: "func unsilenceConversation(username:").last
        ).components(separatedBy: "\n    }\n").first ?? ""
        XCTAssertTrue(unmute.contains("clearChatAction(chatUsername: username)"),
                      "取消要真的把那行持久状态清掉")
    }
}
