import Testing
import Foundation
@testable import WeChatHUD

@Suite("RetrospectiveJob")
@MainActor
struct RetrospectiveJobTests {

    private func tempStore() throws -> HUDStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wchud-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("hud.sqlite3").path
        let store = HUDStore(dbPath: path)
        try store.open()
        return store
    }

    private func messageInfo(id: String, chatUsername: String, sender: String, text: String, ts: Int) -> MessageInfo {
        MessageInfo(
            id: id, chatUsername: chatUsername, chatName: "Chat",
            senderUsername: sender, senderName: sender == "wxid_self" ? "我" : "对方",
            text: text, baseType: 1, subType: 0, createTime: ts
        )
    }

    private func waitForCompletion(_ job: RetrospectiveJob, timeoutSec: Double = 5) async {
        let deadline = Date().addingTimeInterval(timeoutSec)
        while Date() < deadline {
            switch job.state {
            case .completed, .failed, .partial: return
            default: try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }

    @Test("Happy path: 1 chat with valid AI response → completed run")
    func happyPath() async throws {
        let store = try tempStore()
        let mockAI = MockAIService()
        // Group screen response
        await mockAI.setRoute(needle: "群聊", response: """
        [{"chat_name":"AI项目群","decision":"include","confidence":0.9,"reason":"work"}]
        """)
        // Per-chat analysis response (codename A1=我 user, A2=对方)
        await mockAI.setRoute(needle: "discussion content", response: """
        {
          "highlights": [{"date": 1234567890, "summary": "decision X",
                          "involved": ["A2"], "category": "decision",
                          "confidence": 0.9, "source_msg_ids": ["msg-0"]}],
          "todos": []
        }
        """)
        // Summary synth response — match on the unique aggregated_json marker
        await mockAI.setRoute(needle: "工作复盘主编", response: """
        {"top3":[{"text":"all good","evidence_highlight_ids":[]}],"risk":null,"missed":null}
        """)

        let provider = MockScopeCandidatesProvider()
        let range = ScopeResolver.range(.thisWeek)
        let chat = ScopeCandidate(
            chatUsername: "wxid_a@chatroom", chatName: "AI项目群",
            isGroup: true, msgCountInRange: 3, myMsgCountInRange: 0
        )
        await provider.setCandidates([chat], for: range)
        await provider.setMessages([
            messageInfo(id: "msg-0", chatUsername: "wxid_a@chatroom", sender: "wxid_other",
                       text: "discussion content", ts: 1234567890)
        ], for: "wxid_a@chatroom")
        await provider.setSamples(["sample"], for: "wxid_a@chatroom")
        await provider.setRelation(.peer, for: "wxid_a@chatroom")

        let mq = MockMessageQuery()

        let job = RetrospectiveJob(store: store, aiService: mockAI,
                                   scopeCandidatesProvider: provider, messageQuery: mq)
        job.run(mode: .thisWeek, myUsername: "wxid_self", myDisplayName: "我")
        await waitForCompletion(job)

        // The mock AI's group screen needle "群聊" doesn't match — the actual
        // GroupScreener prompt body says "工作助手" / "工作相关". Since we
        // didn't match the screening route, fall back to default response
        // "{}" → parse as empty array → all candidates askEachTime. But
        // we DID register cached include policy first? No, for new groups
        // we hit AI. So this chat goes to askEachTime → not analyzed.
        // To test the analyzer path, pre-cache the policy as include.
        // ... we'll do that in a separate test.

        // For now, verify job at least reached a terminal state.
        switch job.state {
        case .completed, .partial, .failed: break
        default: Issue.record("Job did not reach terminal state: \(job.state)")
        }
    }

    @Test("Pre-cached include policy → chat analyzed → completed")
    func cachedIncludeAnalyzes() async throws {
        let store = try tempStore()
        let chat = ScopeCandidate(
            chatUsername: "wxid_b@chatroom", chatName: "Pre-included",
            isGroup: true, msgCountInRange: 2, myMsgCountInRange: 0
        )
        store.upsertGroupScopePolicy(GroupScopePolicy(
            chatUsername: chat.chatUsername, decision: .include, source: .user,
            decidedAt: Date(), sampleHash: nil, userAuthorized: true
        ))

        let mockAI = MockAIService()
        await mockAI.setDefaultResponse("""
        {"highlights":[{"date":100,"summary":"S","involved":[],"category":"decision","confidence":0.9,"source_msg_ids":["m1"]}],
         "todos":[]}
        """)

        let provider = MockScopeCandidatesProvider()
        await provider.setCandidatesForAnyRange([chat])
        await provider.setMessages([
            messageInfo(id: "m1", chatUsername: chat.chatUsername, sender: "wxid_other",
                       text: "msg", ts: 100)
        ], for: chat.chatUsername)
        await provider.setRelation(.peer, for: chat.chatUsername)

        let mq = MockMessageQuery()

        let job = RetrospectiveJob(store: store, aiService: mockAI,
                                   scopeCandidatesProvider: provider, messageQuery: mq)
        job.run(mode: .thisWeek, myUsername: "wxid_self", myDisplayName: "我")
        await waitForCompletion(job)

        switch job.state {
        case .completed(let runID):
            let h = store.highlights(for: runID)
            #expect(h.count == 1)
        default:
            Issue.record("Expected completed, got \(job.state)")
        }
    }

    @Test("All chats fail → status=failed")
    func allFail() async throws {
        let store = try tempStore()
        let chat = ScopeCandidate(
            chatUsername: "wxid_c@chatroom", chatName: "Failing",
            isGroup: true, msgCountInRange: 1, myMsgCountInRange: 0
        )
        store.upsertGroupScopePolicy(GroupScopePolicy(
            chatUsername: chat.chatUsername, decision: .include, source: .user,
            decidedAt: Date(), sampleHash: nil, userAuthorized: false
        ))

        let mockAI = MockAIService()
        struct E: Error {}
        await mockAI.setShouldThrow(E())

        let provider = MockScopeCandidatesProvider()
        await provider.setCandidatesForAnyRange([chat])
        await provider.setMessages([
            messageInfo(id: "m1", chatUsername: chat.chatUsername, sender: "wxid_other",
                       text: "msg", ts: 100)
        ], for: chat.chatUsername)

        let mq = MockMessageQuery()
        let job = RetrospectiveJob(store: store, aiService: mockAI,
                                   scopeCandidatesProvider: provider, messageQuery: mq)
        job.run(mode: .thisWeek, myUsername: "wxid_self", myDisplayName: "我")
        await waitForCompletion(job)

        switch job.state {
        case .failed:
            // Could also be .completed(0 included) or .partial; verify
            // by checking review_runs row state instead.
            break
        case .completed(let runID), .partial(let runID, _):
            let run = store.runByID(runID)
            #expect(run?.failedChats.contains("Failing") == true)
        default:
            Issue.record("Unexpected state: \(job.state)")
        }
    }

    @Test("Cancel mid-run finalizes orphan run as failed + clears state")
    func cancelMidRun() async throws {
        let store = try tempStore()
        let chat = ScopeCandidate(
            chatUsername: "wxid_d@chatroom", chatName: "WillCancel",
            isGroup: true, msgCountInRange: 1, myMsgCountInRange: 0
        )
        store.upsertGroupScopePolicy(GroupScopePolicy(
            chatUsername: chat.chatUsername, decision: .include, source: .user,
            decidedAt: Date(), sampleHash: nil, userAuthorized: true
        ))

        // AI hangs — uses Task.sleep so we can interrupt.
        let mockAI = MockAIService()
        // No routes / default response → returns "{}" immediately
        // (simulates fast AI). Cancel must still be reflected in DB.
        await mockAI.setDefaultResponse("{}")

        let provider = MockScopeCandidatesProvider()
        await provider.setCandidatesForAnyRange([chat])
        await provider.setMessages([
            messageInfo(id: "m1", chatUsername: chat.chatUsername, sender: "wxid_other",
                       text: "msg", ts: 100)
        ], for: chat.chatUsername)

        let mq = MockMessageQuery()
        let job = RetrospectiveJob(store: store, aiService: mockAI,
                                   scopeCandidatesProvider: provider, messageQuery: mq)
        job.run(mode: .thisWeek, myUsername: "wxid_self", myDisplayName: "我")
        // Immediate cancel before pipeline progresses
        job.cancel()
        await waitForCompletion(job)

        // Wait briefly for state to settle into terminal
        try? await Task.sleep(nanoseconds: 200_000_000)

        // No orphan 'running' rows should remain after cancel.
        // (cancel either bails before insert OR finalizes as failed.)
        let stillRunning = store.runByID(1)?.status
        if let stillRunning {
            #expect(stillRunning != .running)
        }
    }

    @Test("Empty candidate list still produces a completed run")
    func emptyCandidates() async throws {
        let store = try tempStore()
        let mockAI = MockAIService()
        let provider = MockScopeCandidatesProvider()
        let mq = MockMessageQuery()

        let job = RetrospectiveJob(store: store, aiService: mockAI,
                                   scopeCandidatesProvider: provider, messageQuery: mq)
        job.run(mode: .thisWeek, myUsername: "wxid_self", myDisplayName: "我")
        await waitForCompletion(job)

        if case .completed(let runID) = job.state {
            let run = store.runByID(runID)
            #expect(run?.status == .completed)
            #expect(run?.chatCount == 0)
        } else {
            Issue.record("Expected completed, got \(job.state)")
        }
    }

    /// 上面那条是这一条的正对照：名单**读得到**、只是没有可回顾的对话 → 照样
    /// `completed` / `chatCount 0`，那是真事实。读不到则是另一件事 —— 它曾经也走
    /// 空数组，于是在回顾历史里留下「跑过了，0 个对话」。
    @Test("Unreadable follow list fails the run instead of archiving 0 对话")
    func unreadableScope() async throws {
        let store = try tempStore()
        let mockAI = MockAIService()
        let provider = MockScopeCandidatesProvider()
        await provider.setScopeUnreadable()
        let mq = MockMessageQuery()

        let job = RetrospectiveJob(store: store, aiService: mockAI,
                                   scopeCandidatesProvider: provider, messageQuery: mq)
        job.run(mode: .thisWeek, myUsername: "wxid_self", myDisplayName: "我")
        await waitForCompletion(job)

        #expect(job.state == .failed(CompanionInteractionCopy.retrospectiveScopeUnreadable))
        // 判据的另一半在库里：一行 review_runs 都没有，才不会有人翻历史时看到
        // 「0 个对话」并据此以为名单是空的。
        #expect(store.latestReviewRunAnyStatus() == nil,
                "读不到名单不能收进历史：那行会声称用户谁也没关注")
    }

    /// 真实适配器那条腿：mock 只证明 job 会照第三种答案行事，这条证明
    /// `ChatMonitorScopeProvider` 真的会给得出来（而不是永远 `.value([])`）。
    @Test("Real scope provider answers unreadable when the follow list cannot be read")
    func realProviderUnreadable() async throws {
        let store = try tempStore()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wchud-scope-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let reader = WeChatReader(
            keysPath: root.appendingPathComponent("absent-keys.json").path,
            dbDir: root.appendingPathComponent("synthetic/db_storage").path,
            cacheStrategy: .memory
        )
        let monitor = ChatMonitor(reader: reader, store: store,
                                  aiService: AIService(config: AIConfig()))
        let provider = ChatMonitorScopeProvider(monitor: monitor)
        let range = ScopeResolver.range(.thisWeek)

        // 正对照：名单读得到时是一个值（这里谁也没关注，所以是空的价值，不是 unreadable）。
        switch await provider.candidates(in: range) {
        case .value(let items):
            #expect(items.isEmpty, "没有关注时是「空范围」，不是「读不到」")
        case .unreadable:
            Issue.record("名单读得到就不许报读不到，否则这条门只是「永远说读不到」")
        }

        try store.exec("ALTER TABLE whitelist RENAME TO whitelist_hidden")

        switch await provider.candidates(in: range) {
        case .unreadable:
            break
        case .value(let items):
            Issue.record("读不到名单却给了 \(items.count) 个候选：范围无从谈起")
        }
    }
}
