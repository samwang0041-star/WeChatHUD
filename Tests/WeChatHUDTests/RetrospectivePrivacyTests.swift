import XCTest
@testable import WeChatHUD

/// Privacy and reliability behaviour of the retrospective pipeline.
///
/// Three findings from the adversarial audit live here:
/// * a name mentioned *before* its owner speaks was sent to the model in
///   plaintext (registration happened per transcript line),
/// * a transient AI failure in the group screen was persisted as a permanent
///   `ask_each_time` policy,
/// * the summary pass recorded `redacted: true` in its ledger while sending
///   real names and chat names verbatim.
final class RetrospectivePrivacyTests: XCTestCase {

    private func makeStore() throws -> HUDStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wchud-privacy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = HUDStore(dbPath: dir.appendingPathComponent("hud.sqlite3").path)
        try store.open()
        return store
    }

    private func message(
        id: String, sender: String, name: String, text: String, at: Int
    ) -> MessageInfo {
        MessageInfo(
            id: id,
            chatUsername: "room@chatroom",
            chatName: "项目群",
            senderUsername: sender,
            senderName: name,
            text: text,
            baseType: 1,
            subType: 0,
            createTime: at
        )
    }

    // MARK: - Analyzer redaction order

    func testNameMentionedBeforeItsOwnerSpeaksIsRedacted() async throws {
        let store = try makeStore()
        defer { store.close() }
        let mock = MockAIService()
        await mock.setDefaultResponse(#"{"highlights":[],"todos":[]}"#)
        let analyzer = RetrospectiveAnalyzer(
            store: store, aiService: mock, redactor: Redactor(),
            dataLedger: DataLedger(store: store)
        )
        let runID = try XCTUnwrap(store.insertReviewRun(rangeStart: Date(), rangeEnd: Date(), chatCount: 1))
        let chat = ScopeCandidate(
            chatUsername: "room@chatroom", chatName: "项目群", isGroup: true,
            msgCountInRange: 2, myMsgCountInRange: 0
        )

        _ = try await analyzer.analyze(
            chat: chat,
            relation: .peer,
            // Newest first, as ChatAnalyzer hands them over.
            messages: [
                message(id: "m2", sender: "wxid_later", name: "王工", text: "好的", at: 2_000),
                message(id: "m1", sender: "wxid_first", name: "张总", text: "请王工先看下方案", at: 1_000)
            ],
            myUsername: "wxid_me",
            myDisplayName: "我",
            runID: runID
        )

        let lastCall = await mock.calls.last
        let prompt = try XCTUnwrap(lastCall?.user)
        XCTAssertFalse(prompt.contains("王工"), "a name mentioned before its owner spoke leaked to the model")
        XCTAssertFalse(prompt.contains("张总"))
        XCTAssertTrue(
            prompt.contains("请A2先看下方案"),
            "the mention should carry the speaker's codename instead: \(prompt.prefix(400))"
        )
    }

    // MARK: - Group screen: no caching of a transient failure

    func testChatNameAndMentionedNonSpeakerStayOutOfThePrompt() async throws {
        let store = try makeStore()
        defer { store.close() }
        let mock = MockAIService()
        await mock.setDefaultResponse(#"{"highlights":[],"todos":[]}"#)
        let analyzer = RetrospectiveAnalyzer(
            store: store, aiService: mock, redactor: Redactor(),
            dataLedger: DataLedger(store: store)
        )
        let runID = try XCTUnwrap(store.insertReviewRun(rangeStart: Date(), rangeEnd: Date(), chatCount: 1))
        let chat = ScopeCandidate(
            chatUsername: "room@chatroom", chatName: "项目群", isGroup: true,
            msgCountInRange: 2, myMsgCountInRange: 0
        )
        _ = try await analyzer.analyze(
            chat: chat,
            relation: .peer,
            messages: [
                message(id: "m2", sender: "wxid_a", name: "张总", text: "@李四 记得带合同", at: 2_000),
                message(id: "m1", sender: "wxid_b", name: "王工", text: "收到", at: 1_000),
            ],
            myUsername: "wxid_me",
            myDisplayName: "我",
            runID: runID
        )
        let lastCall = await mock.calls.last
        let prompt = try XCTUnwrap(lastCall?.user)
        XCTAssertFalse(prompt.contains("项目群"), "the group name must travel as a codename, not plaintext")
        XCTAssertFalse(prompt.contains("李四"), "a mentioned non-speaker must not travel in plaintext")
    }

    func testRepeatedScreenFailuresCoolDownThenRecover() async throws {
        let store = try makeStore()
        defer { store.close() }
        let mock = MockAIService()
        struct Boom: Error {}
        await mock.setShouldThrow(Boom())
        let screener = GroupScreener(store: store, aiService: mock, dataLedger: DataLedger(store: store))
        let candidate = ScopeCandidate(
            chatUsername: "room@chatroom", chatName: "项目群", isGroup: true,
            msgCountInRange: 5, myMsgCountInRange: 1
        )
        let samples = ["room@chatroom": ["明天开会确认预算"]]
        // First failure retries immediately next run (transient blip).
        _ = await screener.screen(candidates: [candidate], samples: samples)
        let callsAfterFirst = await mock.calls.count
        _ = await screener.screen(candidates: [candidate], samples: samples)
        let callsAfterSecond = await mock.calls.count
        XCTAssertGreaterThan(callsAfterSecond, callsAfterFirst, "the first failure must retry without a cooldown")
        // From the second consecutive failure on, the screen cools down
        // instead of re-sending full samples on every run.
        _ = await screener.screen(candidates: [candidate], samples: samples)
        let callsAfterThird = await mock.calls.count
        XCTAssertEqual(callsAfterThird, callsAfterSecond, "an extended outage must not re-send samples every run")
    }

    /// The group screen used to send the group's display name and raw sample
    /// text to the model, and recorded `redacted: false`. Now the name travels
    /// as a codename, sample text is masked, and the decision is still matched
    /// back because `chat_username` (the only channel the fake name could
    /// collide on) stays a real id.
    func testGroupScreenPromptRedactsNameAndPhoneButKeepsUsernameKey() async throws {
        let store = try makeStore()
        defer { store.close() }
        let mock = MockAIService()
        await mock.setDefaultResponse(
            #"{"items":[{"chat_username":"room@chatroom","decision":"include","confidence":0.9}]}"#
        )
        let ledger = DataLedger(store: store)
        let screener = GroupScreener(store: store, aiService: mock, dataLedger: ledger)
        let candidate = ScopeCandidate(
            chatUsername: "room@chatroom", chatName: "项目群", isGroup: true,
            msgCountInRange: 5, myMsgCountInRange: 1
        )

        let result = await screener.screen(
            candidates: [candidate],
            samples: [
                "room@chatroom": [
                    // The group name appears inside a sample too, not just in the
                    // chat_name field — both must be redacted.
                    "项目群通知：张总的手机号是 13800138000",
                    "明天开会确认预算"
                ]
            ]
        )

        let lastCall = await mock.calls.last
        let prompt = try XCTUnwrap(lastCall?.user)
        XCTAssertFalse(prompt.contains("项目群"), "the group name reached the model in plaintext")
        XCTAssertFalse(prompt.contains("13800138000"), "a phone number in a sample reached the model")
        XCTAssertTrue(
            prompt.contains("room@chatroom"),
            "chat_username must stay the real id so parse can match the decision"
        )
        XCTAssertEqual(
            result.included.map(\.chatUsername), ["room@chatroom"],
            "a decision matched on chat_username still has to resolve"
        )

        let entries = await ledger.recent(days: 1)
        XCTAssertEqual(entries.first?.purpose, .groupScreen)
        XCTAssertEqual(entries.first?.redacted, true, "the ledger must not claim a plaintext screen")
    }

    func testScreenerDoesNotCachePoliciesWhenTheAICallFails() async throws {
        let store = try makeStore()
        defer { store.close() }
        let mock = MockAIService()
        struct Boom: Error {}
        await mock.setShouldThrow(Boom())
        let screener = GroupScreener(store: store, aiService: mock, dataLedger: DataLedger(store: store))
        let candidate = ScopeCandidate(
            chatUsername: "room@chatroom", chatName: "项目群", isGroup: true,
            msgCountInRange: 5, myMsgCountInRange: 1
        )

        let result = await screener.screen(
            candidates: [candidate],
            samples: ["room@chatroom": ["明天开会确认预算"]]
        )

        XCTAssertEqual(result.askEachTime.map(\.chatUsername), ["room@chatroom"])
        XCTAssertTrue(result.included.isEmpty)
        XCTAssertNil(
            store.groupScopePolicy(chatUsername: "room@chatroom"),
            "a transient AI failure must not become a permanent policy"
        )

        // The next run can still decide, and then the decision is cached.
        await mock.clearShouldThrow()
        await mock.setDefaultResponse(#"{"items":[{"chat_username":"room@chatroom","chat_name":"项目群","decision":"include","confidence":0.9}]}"#)
        let second = await screener.screen(
            candidates: [candidate],
            samples: ["room@chatroom": ["明天开会确认预算"]]
        )
        XCTAssertEqual(second.included.map(\.chatUsername), ["room@chatroom"])
        XCTAssertEqual(store.groupScopePolicy(chatUsername: "room@chatroom")?.decision, .include)
    }

    // MARK: - Group screen: same display name must not share a decision

    func testSameNamedGroupsAreMatchedByUsername() {
        let a = ScopeCandidate(
            chatUsername: "room_a@chatroom", chatName: "项目群", isGroup: true,
            msgCountInRange: 1, myMsgCountInRange: 0
        )
        let b = ScopeCandidate(
            chatUsername: "room_b@chatroom", chatName: "项目群", isGroup: true,
            msgCountInRange: 1, myMsgCountInRange: 0
        )
        let raw = #"""
        {"items":[{"chat_username":"room_a@chatroom","chat_name":"项目群","decision":"include","confidence":0.9}]}
        """#

        let decisions = GroupScreener.parse(raw, candidates: [a, b])

        XCTAssertEqual(decisions.count, 1, "the second same-named group must not inherit the first one's decision")
        XCTAssertEqual(decisions.first?.0.chatUsername, "room_a@chatroom")
        XCTAssertEqual(decisions.first?.1, .include)
    }

    func testLegacyRepliesWithoutUsernameStillMatchByName() {
        let a = ScopeCandidate(
            chatUsername: "room_a@chatroom", chatName: "项目群", isGroup: true,
            msgCountInRange: 1, myMsgCountInRange: 0
        )
        let raw = #"{"items":[{"chat_name":"项目群","decision":"exclude","confidence":0.8}]}"#

        let decisions = GroupScreener.parse(raw, candidates: [a])

        XCTAssertEqual(decisions.count, 1)
        XCTAssertEqual(decisions.first?.1, .exclude)
    }

    func testUnparseableReplyYieldsNoDecisions() {
        let a = ScopeCandidate(
            chatUsername: "room_a@chatroom", chatName: "项目群", isGroup: true,
            msgCountInRange: 1, myMsgCountInRange: 0
        )
        XCTAssertTrue(GroupScreener.parse("not json at all", candidates: [a]).isEmpty)
    }

    // MARK: - Summary synthesizer redaction

    func testSummarySynthRedactsNamesBeforeSending() async throws {
        let store = try makeStore()
        defer { store.close() }
        let runID = try XCTUnwrap(store.insertReviewRun(rangeStart: Date(), rangeEnd: Date(), chatCount: 1))
        store.insertReviewHighlight(ReviewHighlight(
            id: 0, runID: runID, date: Date(),
            summary: "张总决定采用赖豪的方案",
            quotedSnippet: "可以打 13800138000 找我",
            involved: ["张总", "赖豪"],
            sourceChatUsername: "room@chatroom",
            sourceChatName: "供应链群",
            relation: .peer,
            sourceMsgIDs: ["m1"],
            confidence: 0.9,
            category: .decision,
            flaggedUncertain: false
        ))
        let mock = MockAIService()
        await mock.setDefaultResponse(#"{"top3":[],"risk":null,"missed":null}"#)
        let synth = SummarySynthesizer(
            store: store, aiService: mock, dataLedger: DataLedger(store: store)
        )

        _ = await synth.synthesize(runID: runID)

        let lastCall = await mock.calls.last
        let prompt = try XCTUnwrap(lastCall?.user)
        XCTAssertFalse(prompt.contains("张总"), "an involved name reached the model in plaintext")
        XCTAssertFalse(prompt.contains("赖豪"))
        XCTAssertFalse(prompt.contains("供应链群"), "the group name reached the model in plaintext")
        // Proof that the redacted payload (and not an empty placeholder) is what
        // the name assertions above are judging.
        XCTAssertTrue(prompt.contains(#""involved""#), "the highlight payload must actually be in the prompt")
        XCTAssertEqual(
            Redactor.applyMasks("可以打 13800138000 找我"), "可以打 [手机] 找我",
            "phone/email/money masking stays part of redaction"
        )
    }

    func testSummarySynthRestoresNamesInTheResult() async throws {
        let store = try makeStore()
        defer { store.close() }
        let runID = try XCTUnwrap(store.insertReviewRun(rangeStart: Date(), rangeEnd: Date(), chatCount: 1))
        store.insertReviewHighlight(ReviewHighlight(
            id: 0, runID: runID, date: Date(), summary: "张总决定采用方案",
            quotedSnippet: nil, involved: ["张总"], sourceChatUsername: "room@chatroom",
            sourceChatName: "供应链群", relation: .peer, sourceMsgIDs: [], confidence: 0.9,
            category: .decision, flaggedUncertain: false
        ))
        let mock = MockAIService()
        // The model answers with the codename it was given.
        await mock.setDefaultResponse(#"{"top3":[{"text":"A2 已拍板","evidence_highlight_ids":[]}],"risk":null,"missed":null}"#)
        let synth = SummarySynthesizer(
            store: store, aiService: mock, dataLedger: DataLedger(store: store)
        )

        let summary = await synth.synthesize(runID: runID)
        let lastCall = await mock.calls.last
        let prompt = try XCTUnwrap(lastCall?.user)
        XCTAssertTrue(prompt.contains("A2"), "the payload should carry a codename for 张总")

        // Whatever the codename was, the stored summary must read with the real
        // name rather than a placeholder.
        let text = try XCTUnwrap(summary.top3.first?.text)
        XCTAssertFalse(text.contains("A1"))
        XCTAssertFalse(text.contains("A2"))
    }

    func testSummarySynthRedactsNamesOutsideInvolved() async throws {
        let store = try makeStore()
        defer { store.close() }
        let runID = try XCTUnwrap(store.insertReviewRun(rangeStart: Date(), rangeEnd: Date(), chatCount: 1))
        store.insertReviewHighlight(ReviewHighlight(
            id: 0, runID: runID, date: Date(), summary: "张总让@李四带合同",
            quotedSnippet: nil, involved: ["张总"], sourceChatUsername: "room@chatroom",
            sourceChatName: "供应链群", relation: .peer, sourceMsgIDs: [], confidence: 0.9,
            category: .decision, flaggedUncertain: false
        ))
        let mock = MockAIService()
        await mock.setDefaultResponse(#"{"top3":[],"risk":null,"missed":null}"#)
        let synth = SummarySynthesizer(
            store: store, aiService: mock, dataLedger: DataLedger(store: store)
        )
        _ = await synth.synthesize(runID: runID)
        let lastCall = await mock.calls.last
        let prompt = try XCTUnwrap(lastCall?.user)
        XCTAssertFalse(prompt.contains("李四"), "a name outside involved must not travel in plaintext")
        XCTAssertFalse(prompt.contains("供应链群"))
    }
}
