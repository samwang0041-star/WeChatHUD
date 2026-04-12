import XCTest
@testable import WeChatHUD

/// Phase 0 tests for the ask classifier. Two layers:
///
/// 1. Pure unit tests on the JSON envelope cleanup, prompt interpolation,
///    and config decode paths — these never touch the network and always run.
///
/// 2. A live integration test that hits the local omlx endpoint and runs
///    the labeled fixture through the classifier, asserting F1 ≥ 0.85.
///    Skipped automatically if the endpoint is not reachable so CI on a
///    machine without omlx still passes.
///
/// See `docs/superpowers/plans/2026-04-12-wechathud-ai-subsystem.md`.
final class AIClassifierTests: XCTestCase {
    var tmpPath: String!
    var store: HUDStore!

    override func setUp() {
        tmpPath = NSTemporaryDirectory() + "hud_classifier_test_\(UUID().uuidString).sqlite3"
        store = HUDStore(dbPath: tmpPath)
        try! store.open()
    }

    override func tearDown() {
        store.close()
        try? FileManager.default.removeItem(atPath: tmpPath)
    }

    // MARK: - Config defaults

    func testClassifierConfigDefaults() {
        let cfg = AIClassifierConfig()
        XCTAssertEqual(cfg.baseURL, "http://127.0.0.1:8000/v1")
        XCTAssertEqual(cfg.model, "Qwen3.5-35B-A3B-4bit")
        XCTAssertEqual(cfg.promptVersion, "classifier_v1")
        XCTAssertLessThanOrEqual(cfg.temperature, 0.2)
    }

    // MARK: - Prompt loader

    func testPromptLoaderLoadsClassifierV1() throws {
        let loader = PromptLoader()
        let template = try loader.load(version: "classifier_v1")
        XCTAssertTrue(template.contains("{message_body}"), "prompt should contain message body placeholder")
        XCTAssertTrue(template.contains("{sender_name}"), "prompt should contain sender placeholder")
        XCTAssertTrue(template.contains("yes_no"), "prompt should declare ask types")
    }

    func testPromptLoaderUnknownVersionThrows() {
        let loader = PromptLoader()
        XCTAssertThrowsError(try loader.load(version: "classifier_does_not_exist"))
    }

    // MARK: - Audit log roundtrip

    func testAIAuditRoundTrip() throws {
        let entry = AIAuditEntry(
            id: 0,
            ts: Date(),
            role: .classifier,
            model: "test-model",
            promptVersion: "classifier_v1",
            inputText: "hello",
            outputText: "{\"is_ask\":false}",
            latencyMs: 123,
            status: .ok,
            errorMessage: nil
        )
        try store.writeAIAudit(entry)

        let recent = store.loadRecentAIAudit(limit: 10)
        XCTAssertEqual(recent.count, 1)
        XCTAssertEqual(recent[0].model, "test-model")
        XCTAssertEqual(recent[0].latencyMs, 123)
        XCTAssertEqual(recent[0].status, .ok)
    }

    func testAIAuditPrune() throws {
        // Old entry — manually backdate via direct insert by bypassing
        // the convenience init's "now" default. We construct with a
        // 30-day-old timestamp.
        let old = AIAuditEntry(
            id: 0,
            ts: Date(timeIntervalSinceNow: -30 * 86400),
            role: .classifier,
            model: "old",
            promptVersion: "v0",
            inputText: "old",
            outputText: "old",
            latencyMs: 1,
            status: .ok,
            errorMessage: nil
        )
        try store.writeAIAudit(old)
        try store.writeAIAudit(AIAuditEntry(
            id: 0, ts: Date(), role: .classifier, model: "new",
            promptVersion: "v1", inputText: "new", outputText: "new",
            latencyMs: 1, status: .ok, errorMessage: nil
        ))

        try store.pruneAIAudit(olderThanDays: 14)
        let remaining = store.loadRecentAIAudit(limit: 10)
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining[0].model, "new")
    }

    // MARK: - Pending asks roundtrip

    func testPendingAskUpsert() throws {
        let now = Date()
        let ask = PendingAsk(
            id: 0,
            msgUID: "msg-1",
            chatUsername: "wxid_test",
            chatName: "测试聊天",
            senderName: "林总",
            rawText: "明天发预算单",
            summary: "发送预算单",
            askType: .sendFile,
            deadlineAt: now.addingTimeInterval(86400),
            confidence: 0.92,
            bucket: .main,
            status: .pending,
            promptVersion: "classifier_v1",
            createdAt: now,
            updatedAt: now,
            senderLevel: nil,
            senderRole: nil,
            urgency: nil
        )
        try store.upsertPendingAsk(ask)
        XCTAssertTrue(store.hasPendingAsk(msgUID: "msg-1"))

        let loaded = store.loadPendingAsks()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].msgUID, "msg-1")
        XCTAssertEqual(loaded[0].askType, .sendFile)
        XCTAssertEqual(loaded[0].bucket, .main)
        XCTAssertEqual(loaded[0].status, .pending)

        try store.dismissPendingAsk(msgUID: "msg-1")
        let dismissed = store.loadPendingAsks(status: .dismissed)
        XCTAssertEqual(dismissed.count, 1)
    }

    // MARK: - Live integration (gated on endpoint reachability)

    /// Run the labeled fixture through the live classifier and assert
    /// F1 ≥ 0.85. Skipped if the omlx endpoint at the configured URL
    /// cannot actually serve a chat completion, so this test stays
    /// green on machines that don't have a healthy local model server.
    func testClassifierAgainstFixturesLive() async throws {
        let cfg = AIClassifierConfig()
        let availability = await probeClassifierAvailability(config: cfg)
        guard availability.isUsable else {
            throw XCTSkip("omlx endpoint \(cfg.baseURL) unavailable for live classifier test: \(availability.reason)")
        }

        let cases = try loadFixtureCases()
        guard cases.count >= 5 else {
            throw XCTSkip("fixture has < 5 cases (\(cases.count)); skipping until test set is grown")
        }

        let classifier = AIClassifier(store: store, config: cfg)

        var tp = 0, fp = 0, tn = 0, fn = 0
        for c in cases {
            let input = ClassifierInput(
                msgUID: c.msgID,
                text: c.text,
                senderName: c.senderName ?? "<unknown>",
                chatName: "<fixture>",
                isGroup: c.chatKind == "group"
            )
            guard let r = await classifier.classify(message: input) else {
                XCTFail("\(c.msgID): classifier returned nil for '\(c.text)'")
                continue
            }
            switch (c.expected.isAsk, r.isAsk) {
            case (true, true):   tp += 1
            case (true, false):  fn += 1
            case (false, true):  fp += 1
            case (false, false): tn += 1
            }
        }

        let precision = (tp + fp) > 0 ? Double(tp) / Double(tp + fp) : 0
        let recall    = (tp + fn) > 0 ? Double(tp) / Double(tp + fn) : 0
        let f1        = (precision + recall) > 0 ? 2 * precision * recall / (precision + recall) : 0

        print("[AIClassifierTests] live fixture: TP=\(tp) FP=\(fp) TN=\(tn) FN=\(fn) " +
              "P=\(String(format: "%.3f", precision)) R=\(String(format: "%.3f", recall)) F1=\(String(format: "%.3f", f1))")

        XCTAssertGreaterThanOrEqual(f1, 0.85, "Classifier F1 below the 0.85 hard gate")
    }

    // MARK: - Fixture loading

    private struct LabeledExpected: Decodable {
        let isAsk: Bool
        let type: String?
        let summary: String?
        let deadlineRelative: String?

        enum CodingKeys: String, CodingKey {
            case isAsk = "is_ask"
            case type
            case summary
            case deadlineRelative = "deadline_relative"
        }
    }

    private struct LabeledCase: Decodable {
        let msgID: String
        let text: String
        let senderName: String?
        let chatKind: String?
        let expected: LabeledExpected

        enum CodingKeys: String, CodingKey {
            case msgID = "msg_id"
            case text
            case senderName = "sender_name"
            case chatKind = "chat_kind"
            case expected
        }
    }

    /// Walk up from the test source location to find the fixture file.
    /// SPM doesn't expose `Tests/Fixtures` as a bundle resource, so we
    /// resolve via `#filePath` instead.
    ///
    /// Two files are loaded if present:
    ///   - `labeled_messages.json`         — committed, synthetic seed cases
    ///   - `labeled_messages_private.json` — gitignored, grown from real
    ///                                       WeChat data via `classify-real`
    ///
    /// The private file is optional and only filtered to entries whose
    /// `expected.is_ask` field has been hand-set (the file as written
    /// by `classify-real` has `expected: null` until reviewed).
    private func loadFixtureCases() throws -> [LabeledCase] {
        let here = URL(fileURLWithPath: #filePath)
        let fixturesDir = here
            .deletingLastPathComponent()           // WeChatHUDTests
            .deletingLastPathComponent()           // Tests
            .appendingPathComponent("Fixtures")

        var cases: [LabeledCase] = []
        let publicURL = fixturesDir.appendingPathComponent("labeled_messages.json")
        let privateURL = fixturesDir.appendingPathComponent("labeled_messages_private.json")

        if FileManager.default.fileExists(atPath: publicURL.path) {
            let data = try Data(contentsOf: publicURL)
            cases.append(contentsOf: try JSONDecoder().decode([LabeledCase].self, from: data))
        }

        if FileManager.default.fileExists(atPath: privateURL.path) {
            let data = try Data(contentsOf: privateURL)
            // Private fixture allows null expected (unlabeled) — skip those.
            if let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                let labeled = raw.filter { ($0["expected"] as? [String: Any])?["is_ask"] != nil }
                if !labeled.isEmpty,
                   let labeledData = try? JSONSerialization.data(withJSONObject: labeled) {
                    let extras = (try? JSONDecoder().decode([LabeledCase].self, from: labeledData)) ?? []
                    cases.append(contentsOf: extras)
                }
            }
        }

        return cases
    }

    /// Stronger availability probe than `GET /models`: require the local
    /// model server to successfully serve one tiny completion. This keeps
    /// the live fixture test out of the way when the endpoint is up but
    /// out of storage, out of memory, mis-keyed, or otherwise unable to
    /// execute a real request.
    private func probeClassifierAvailability(config: AIClassifierConfig) async -> (isUsable: Bool, reason: String) {
        var url = config.baseURL
        while url.hasSuffix("/") { url.removeLast() }
        if !url.hasSuffix("/v1") { url += "/v1" }
        guard let completionURL = URL(string: "\(url)/chat/completions") else {
            return (false, "invalid url")
        }

        var req = URLRequest(url: completionURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !config.apiKey.isEmpty {
            req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        }
        req.timeoutInterval = 5

        let body: [String: Any] = [
            "model": config.model,
            "messages": [
                ["role": "system", "content": "Reply with compact JSON only."],
                ["role": "user", "content": "{\"ok\":true}"]
            ],
            "temperature": 0.0,
            "max_tokens": 32,
            "stream": false
        ]

        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                return (false, "no http response")
            }
            guard http.statusCode == 200 else {
                let body = String(data: data, encoding: .utf8) ?? ""
                return (false, "HTTP \(http.statusCode): \(body.prefix(120))")
            }
            return (true, "ok")
        } catch {
            return (false, error.localizedDescription)
        }
    }
}
