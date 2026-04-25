import Testing
import Foundation
@testable import WeChatHUD

@Suite("RetrospectiveAnalyzer")
struct RetrospectiveAnalyzerTests {

    private func tempStore() throws -> HUDStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wchud-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("hud.sqlite3").path
        let store = HUDStore(dbPath: path)
        try store.open()
        return store
    }

    private func makeMessages(count: Int = 3) -> [MessageInfo] {
        (0..<count).map { i in
            MessageInfo(
                id: "msg-\(i)",
                chatUsername: "wxid_chat",
                chatName: "AI项目群",
                senderUsername: "wxid_other",
                senderName: "张总",
                text: "discussion content \(i)",
                baseType: 1,
                subType: 0,
                createTime: Int(Date().timeIntervalSince1970 - TimeInterval(i * 60))
            )
        }
    }

    @Test("Successful analysis returns highlights + todos with codenames resolved")
    func happyPath() async throws {
        let store = try tempStore()
        let mock = MockAIService()
        // Codename allocation order in analyzer: my_codename first (A1=我),
        // then other senders in iteration order (A2=张总).
        let aiResponse = """
        {
          "highlights": [
            {"date": 1234567890, "summary": "A2 决定上线", "quoted_snippet": "上线",
             "involved": ["A2"], "category": "decision", "confidence": 0.9,
             "source_msg_ids": ["msg-0"]}
          ],
          "todos": [
            {"deadline": 1234600000, "content": "A2 给报价", "direction": "theirs",
             "involved": ["A2"], "confidence": 0.85, "source_msg_ids": ["msg-1"]}
          ]
        }
        """
        await mock.setDefaultResponse(aiResponse)
        let ledger = DataLedger(store: store)
        let redactor = Redactor()
        let analyzer = RetrospectiveAnalyzer(
            store: store, aiService: mock, redactor: redactor, dataLedger: ledger
        )

        let runID = store.insertReviewRun(rangeStart: Date(), rangeEnd: Date(), chatCount: 1)!
        let chat = ScopeCandidate(
            chatUsername: "wxid_chat", chatName: "AI项目群",
            isGroup: true, msgCountInRange: 3, myMsgCountInRange: 0
        )
        let result = try await analyzer.analyze(
            chat: chat, relation: .superior, messages: makeMessages(),
            myUsername: "wxid_self", myDisplayName: "我", runID: runID
        )

        #expect(result.highlights.count == 1)
        #expect(result.highlights.first?.category == .decision)
        #expect(result.highlights.first?.runID == runID)
        // codename A1 was registered for "wxid_other / 张总" → unredact replaces A1 with "张总"
        #expect(result.highlights.first?.summary.contains("张总") == true)
        #expect(result.highlights.first?.involved == ["张总"])

        #expect(result.todos.count == 1)
        #expect(result.todos.first?.direction == .theirs)
        #expect(result.todos.first?.status == .pending)
        #expect(result.todos.first?.content.contains("张总") == true)
    }

    @Test("Parse failure triggers retry; retry success returns parsed result")
    func parseRetry() async throws {
        let store = try tempStore()
        let mock = MockAIService()
        // Default response is invalid; on second try (which contains "严格要求")
        // we route to a valid response via needle match.
        await mock.setDefaultResponse("garbage not json")
        let valid = """
        {"highlights": [], "todos": []}
        """
        await mock.setRoute(needle: "严格要求", response: valid)
        let ledger = DataLedger(store: store)
        let redactor = Redactor()
        let analyzer = RetrospectiveAnalyzer(
            store: store, aiService: mock, redactor: redactor, dataLedger: ledger
        )

        let runID = store.insertReviewRun(rangeStart: Date(), rangeEnd: Date(), chatCount: 1)!
        let chat = ScopeCandidate(
            chatUsername: "wxid_chat", chatName: "test", isGroup: false,
            msgCountInRange: 1, myMsgCountInRange: 0
        )
        let result = try await analyzer.analyze(
            chat: chat, relation: .peer, messages: makeMessages(count: 1),
            myUsername: "wxid_self", myDisplayName: "我", runID: runID
        )
        #expect(result.highlights.isEmpty)
        #expect(result.todos.isEmpty)
    }

    @Test("AI throw bubbles + writes failed ledger entry")
    func aiThrows() async throws {
        let store = try tempStore()
        let mock = MockAIService()
        struct E: Error {}
        await mock.setShouldThrow(E())
        let ledger = DataLedger(store: store)
        let redactor = Redactor()
        let analyzer = RetrospectiveAnalyzer(
            store: store, aiService: mock, redactor: redactor, dataLedger: ledger
        )

        let runID = store.insertReviewRun(rangeStart: Date(), rangeEnd: Date(), chatCount: 1)!
        let chat = ScopeCandidate(
            chatUsername: "wxid_chat", chatName: "test", isGroup: false,
            msgCountInRange: 1, myMsgCountInRange: 0
        )

        do {
            _ = try await analyzer.analyze(
                chat: chat, relation: .peer, messages: makeMessages(count: 1),
                myUsername: "wxid_self", myDisplayName: "me", runID: runID
            )
            Issue.record("Expected throw")
        } catch {
            // Expected — verify ledger has a failed entry
            let recent = await ledger.recent(days: 1)
            #expect(recent.contains { $0.purpose == .chatAnalysisFailed })
        }
    }

    @Test("Low confidence highlight is flaggedUncertain")
    func lowConfidenceFlagged() async throws {
        let store = try tempStore()
        let mock = MockAIService()
        await mock.setDefaultResponse("""
        {"highlights": [
          {"date": 1, "summary": "maybe", "involved": [], "category": "discussion",
           "confidence": 0.3, "source_msg_ids": []}
        ], "todos": []}
        """)
        let ledger = DataLedger(store: store)
        let redactor = Redactor()
        let analyzer = RetrospectiveAnalyzer(
            store: store, aiService: mock, redactor: redactor, dataLedger: ledger
        )

        let runID = store.insertReviewRun(rangeStart: Date(), rangeEnd: Date(), chatCount: 1)!
        let chat = ScopeCandidate(
            chatUsername: "wxid_chat", chatName: "test", isGroup: false,
            msgCountInRange: 1, myMsgCountInRange: 0
        )
        let result = try await analyzer.analyze(
            chat: chat, relation: .peer, messages: makeMessages(count: 1),
            myUsername: "wxid_self", myDisplayName: "me", runID: runID
        )
        #expect(result.highlights.first?.flaggedUncertain == true)
    }
}

@Suite("SummarySynthesizer")
struct SummarySynthesizerTests {

    private func tempStore() throws -> HUDStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wchud-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("hud.sqlite3").path
        let store = HUDStore(dbPath: path)
        try store.open()
        return store
    }

    @Test("Empty input returns empty summary")
    func emptyInput() async throws {
        let store = try tempStore()
        let mock = MockAIService()
        let ledger = DataLedger(store: store)
        let synth = SummarySynthesizer(store: store, aiService: mock, dataLedger: ledger)
        let runID = store.insertReviewRun(rangeStart: Date(), rangeEnd: Date(), chatCount: 1)!
        let result = await synth.synthesize(runID: runID)
        #expect(result.top3.isEmpty)
        #expect(result.risk == nil)
    }

    @Test("Successful AI parse returns top3 + risk + missed")
    func happyPath() async throws {
        let store = try tempStore()
        let runID = store.insertReviewRun(rangeStart: Date(), rangeEnd: Date(), chatCount: 1)!
        // Insert a highlight so synth has aggregated data
        let h = ReviewHighlight(
            id: 0, runID: runID, date: Date(), summary: "decision X",
            quotedSnippet: nil, involved: ["A"], sourceChatUsername: "u",
            sourceChatName: "c", relation: .peer, sourceMsgIDs: ["m1"],
            confidence: 0.8, category: .decision, flaggedUncertain: false
        )
        store.insertReviewHighlight(h)

        let mock = MockAIService()
        await mock.setDefaultResponse("""
        {
          "top3": [{"text": "Top one", "evidence_highlight_ids": [1]}],
          "risk": {"text": "watch out", "evidence_highlight_ids": []},
          "missed": null
        }
        """)
        let ledger = DataLedger(store: store)
        let synth = SummarySynthesizer(store: store, aiService: mock, dataLedger: ledger)
        let result = await synth.synthesize(runID: runID)
        #expect(result.top3.count == 1)
        #expect(result.top3.first?.text == "Top one")
        #expect(result.risk?.text == "watch out")
        #expect(result.missed == nil)
    }

    @Test("AI failure falls back to top-confidence highlights")
    func fallbackOnAIFailure() async throws {
        let store = try tempStore()
        let runID = store.insertReviewRun(rangeStart: Date(), rangeEnd: Date(), chatCount: 1)!
        for i in 0..<5 {
            let h = ReviewHighlight(
                id: 0, runID: runID, date: Date(), summary: "highlight \(i)",
                quotedSnippet: nil, involved: [], sourceChatUsername: "u",
                sourceChatName: "c", relation: .peer, sourceMsgIDs: [],
                confidence: Double(i) / 10.0, category: .discussion, flaggedUncertain: false
            )
            store.insertReviewHighlight(h)
        }
        let mock = MockAIService()
        struct E: Error {}
        await mock.setShouldThrow(E())
        let ledger = DataLedger(store: store)
        let synth = SummarySynthesizer(store: store, aiService: mock, dataLedger: ledger)
        let result = await synth.synthesize(runID: runID)
        #expect(result.top3.count == 3)  // top 3 by confidence
    }
}
