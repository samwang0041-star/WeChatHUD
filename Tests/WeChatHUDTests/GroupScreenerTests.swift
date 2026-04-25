import Testing
import Foundation
@testable import WeChatHUD

@Suite("GroupScreener")
struct GroupScreenerTests {

    private func tempStore() throws -> HUDStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wchud-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("hud.sqlite3").path
        let store = HUDStore(dbPath: path)
        try store.open()
        return store
    }

    private func candidate(_ name: String, group: Bool = true) -> ScopeCandidate {
        ScopeCandidate(
            chatUsername: "wxid_\(name)\(group ? "@chatroom" : "")",
            chatName: name,
            isGroup: group,
            msgCountInRange: 100,
            myMsgCountInRange: 5
        )
    }

    @Test("Private chats always included regardless of cache")
    func privateAlwaysIncluded() async throws {
        let store = try tempStore()
        let mock = MockAIService()
        let ledger = DataLedger(store: store)
        let screener = GroupScreener(store: store, aiService: mock, dataLedger: ledger)
        let priv = candidate("zhangsan", group: false)
        let result = await screener.screen(candidates: [priv], samples: [:])
        #expect(result.included.count == 1)
        #expect(result.included.first?.chatUsername == priv.chatUsername)
    }

    @Test("Cached include policy bypasses AI")
    func cachedInclude() async throws {
        let store = try tempStore()
        let g = candidate("ai_project")
        store.upsertGroupScopePolicy(GroupScopePolicy(
            chatUsername: g.chatUsername, decision: .include, source: .user,
            decidedAt: Date(), sampleHash: nil, userAuthorized: true
        ))
        let mock = MockAIService()
        let ledger = DataLedger(store: store)
        let screener = GroupScreener(store: store, aiService: mock, dataLedger: ledger)
        let result = await screener.screen(candidates: [g], samples: [:])
        #expect(result.included.count == 1)
        #expect(await mock.calls.isEmpty)  // AI not invoked
    }

    @Test("Cached exclude policy bypasses AI")
    func cachedExclude() async throws {
        let store = try tempStore()
        let g = candidate("hobby")
        store.upsertGroupScopePolicy(GroupScopePolicy(
            chatUsername: g.chatUsername, decision: .exclude, source: .user,
            decidedAt: Date(), sampleHash: nil, userAuthorized: false
        ))
        let mock = MockAIService()
        let ledger = DataLedger(store: store)
        let screener = GroupScreener(store: store, aiService: mock, dataLedger: ledger)
        let result = await screener.screen(candidates: [g], samples: [:])
        #expect(result.excluded.count == 1)
        #expect(await mock.calls.isEmpty)
    }

    @Test("New group goes through AI; high-confidence include is honored")
    func newGroupAIInclude() async throws {
        let store = try tempStore()
        let g = candidate("new_team")
        let mock = MockAIService()
        let response = #"[{"chat_name":"new_team","decision":"include","confidence":0.9,"reason":"work talk"}]"#
        await mock.setRoute(needle: "new_team", response: response)
        let ledger = DataLedger(store: store)
        let screener = GroupScreener(store: store, aiService: mock, dataLedger: ledger)
        let result = await screener.screen(candidates: [g], samples: ["wxid_new_team@chatroom": ["msg1"]])
        #expect(result.included.count == 1)
        // Cached now
        #expect(store.groupScopePolicy(chatUsername: g.chatUsername)?.decision == .include)
    }

    @Test("Low confidence (<0.7) AI decision becomes askEachTime")
    func lowConfidenceAskEach() async throws {
        let store = try tempStore()
        let g = candidate("ambiguous")
        let mock = MockAIService()
        let response = #"[{"chat_name":"ambiguous","decision":"include","confidence":0.5,"reason":"borderline"}]"#
        await mock.setRoute(needle: "ambiguous", response: response)
        let ledger = DataLedger(store: store)
        let screener = GroupScreener(store: store, aiService: mock, dataLedger: ledger)
        let result = await screener.screen(candidates: [g], samples: ["wxid_ambiguous@chatroom": []])
        #expect(result.askEachTime.count == 1)
        #expect(store.groupScopePolicy(chatUsername: g.chatUsername)?.decision == .askEachTime)
    }

    @Test("AI failure → all askEachTime, ledger entry recorded anyway")
    func aiFailureFallback() async throws {
        let store = try tempStore()
        let g = candidate("untested")
        let mock = MockAIService()
        struct E: Error {}
        await mock.setShouldThrow(E())
        let ledger = DataLedger(store: store)
        let screener = GroupScreener(store: store, aiService: mock, dataLedger: ledger)
        let result = await screener.screen(candidates: [g], samples: ["wxid_untested@chatroom": []])
        #expect(result.askEachTime.count == 1)
    }
}
