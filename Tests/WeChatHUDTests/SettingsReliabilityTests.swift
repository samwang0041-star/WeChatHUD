import XCTest
import SQLite3
@testable import WeChatHUD

/// Regression coverage for settings paths that previously collapsed a failed
/// AI or persistence operation into an apparently successful empty state.
final class SettingsReliabilityTests: XCTestCase {
    private var store: HUDStore!
    private var dbPath: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        URLRequestRecorder.install()
        dbPath = NSTemporaryDirectory() + "hud_settings_reliability_\(UUID().uuidString).sqlite3"
        store = HUDStore(dbPath: dbPath)
        try store.open()
    }

    override func tearDown() {
        store.close()
        try? FileManager.default.removeItem(atPath: dbPath)
        URLRequestRecorder.uninstall()
        super.tearDown()
    }

    func testCategorizeBatchWithStatusTreatsValidEmptyArrayAsSuccessful() async throws {
        URLRequestRecorder.stubbedResponse = chatResponse(content: #"{"items":[]}"#)

        let result = await categorizer().categorizeBatchWithStatus(batchItems(count: 1))

        XCTAssertEqual(result.attemptedChunks, 1)
        XCTAssertEqual(result.failedChunks, 0)
        XCTAssertEqual(result.succeededChunks, 1)
        XCTAssertTrue(result.results.isEmpty)
    }

    func testCategorizeBatchWithStatusMarksInvalidJSONAsFailed() async throws {
        URLRequestRecorder.stubbedResponse = chatResponse(content: "not-json")

        let result = await categorizer().categorizeBatchWithStatus(batchItems(count: 1))

        XCTAssertEqual(result.attemptedChunks, 1)
        XCTAssertEqual(result.failedChunks, 1)
        XCTAssertEqual(result.succeededChunks, 0)
        XCTAssertTrue(result.results.isEmpty)
    }

    func testCategorizeBatchWithStatusMarksHTTPFailureAsFailed() async throws {
        URLRequestRecorder.stubbedResponse = chatResponse(
            content: "provider unavailable",
            statusCode: 503
        )

        let result = await categorizer().categorizeBatchWithStatus(batchItems(count: 1))

        XCTAssertEqual(result.attemptedChunks, 1)
        XCTAssertEqual(result.failedChunks, 1)
        XCTAssertEqual(result.succeededChunks, 0)
        XCTAssertTrue(result.results.isEmpty)
    }

    func testCategorizeBatchWithStatusReportsPartialSuccessAcrossChunks() async throws {
        let first = #"{"items":[{"index":1,"category":"work","should_whitelist":true,"reason":"work context"}]}"#
        // 26 items force the categorizer's 25-item chunk boundary.
        URLRequestRecorder.stubbedResponses = [
            chatResponse(content: first),
            chatResponse(content: "invalid second chunk")
        ]

        let result = await categorizer().categorizeBatchWithStatus(batchItems(count: 26))

        XCTAssertEqual(result.attemptedChunks, 2)
        XCTAssertEqual(result.failedChunks, 1)
        XCTAssertEqual(result.succeededChunks, 1)
        XCTAssertEqual(result.results.count, 1)
        XCTAssertEqual(result.results.first?.index, 1)
    }

    func testRelationshipInferenceReturnsNilAndKeepsOldProfileWhenDBWriteFails() async throws {
        let old = RelationshipProfile(
            username: "wxid_old",
            displayName: "旧联系人",
            relationship: "同事",
            hierarchy: .peer,
            tonePreference: .formal,
            context: "旧画像",
            confidence: 0.42,
            userNote: "用户备注",
            userEdited: false,
            inferredAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        try store.upsertRelationshipProfile(old)
        XCTAssertEqual(sqlite3_exec(
            store.rawDB,
            "CREATE TRIGGER reject_relationship_write BEFORE INSERT ON relationship_profiles BEGIN SELECT RAISE(ABORT, 'settings test write blocked'); END",
            nil,
            nil,
            nil
        ), SQLITE_OK)

        URLRequestRecorder.stubbedResponse = chatResponse(content: #"{"relationship":"直属领导","hierarchy":"superior","tone_preference":"brief","context":"新画像","confidence":0.95}"#)

        let result = await RelationshipInferrer(store: store, config: aiConfig()).infer(
            contactUsername: "wxid_old",
            contactName: "旧联系人",
            isGroup: false,
            messages: [MessageInfo(
                id: "m1",
                chatUsername: "wxid_old",
                chatName: "旧联系人",
                senderUsername: "wxid_old",
                senderName: "旧联系人",
                text: "请看一下方案",
                baseType: 1,
                subType: 0,
                createTime: 200
            )],
            myUsername: "me"
        )

        XCTAssertNil(result)
        let retained = try XCTUnwrap(store.getRelationshipProfile(username: "wxid_old"))
        XCTAssertEqual(retained.relationship, old.relationship)
        XCTAssertEqual(retained.hierarchy, old.hierarchy)
        XCTAssertEqual(retained.tonePreference, old.tonePreference)
        XCTAssertEqual(retained.context, old.context)
        XCTAssertEqual(retained.confidence, old.confidence)
        XCTAssertEqual(retained.userNote, old.userNote)
    }

    func testContactAndProfileEditRollsBackTogetherWhenProfileUpdateAborts() throws {
        try store.saveContactTracking(
            username: "wxid_contact",
            displayName: "旧姓名",
            isGroup: false,
            category: .work,
            attentionLevel: .whitelist,
            role: .colleague,
            roleNote: "旧备注",
            replyWindowMinutes: 30
        )
        let oldProfile = RelationshipProfile(
            username: "wxid_contact",
            displayName: "旧姓名",
            relationship: "同事",
            hierarchy: .peer,
            tonePreference: .formal,
            context: "旧上下文",
            confidence: 0.5,
            userNote: "旧画像备注",
            userEdited: false,
            inferredAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        try store.upsertRelationshipProfile(oldProfile)
        XCTAssertEqual(sqlite3_exec(
            store.rawDB,
            "CREATE TRIGGER reject_contact_profile_update BEFORE UPDATE ON relationship_profiles WHEN NEW.username = 'wxid_contact' BEGIN SELECT RAISE(ABORT, 'profile edit blocked'); END",
            nil,
            nil,
            nil
        ), SQLITE_OK)

        XCTAssertThrowsError(try store.withTransaction {
            try store.saveContactTracking(
                username: "wxid_contact",
                displayName: "新姓名",
                isGroup: false,
                category: .life,
                attentionLevel: .vip,
                role: .boss,
                roleNote: "新备注",
                replyWindowMinutes: 15
            )
            try store.updateRelationshipProfileUserFields(
                username: "wxid_contact",
                relationship: "直属领导",
                hierarchy: .superior,
                tonePreference: .brief,
                userNote: "新画像备注"
            )
        })

        let contact = try XCTUnwrap(store.getContact(username: "wxid_contact"))
        XCTAssertEqual(contact.displayName, "旧姓名")
        XCTAssertEqual(contact.attentionLevel, .whitelist)
        XCTAssertEqual(contact.role, .colleague)
        XCTAssertEqual(contact.roleNote, "旧备注")
        XCTAssertEqual(contact.replyWindowMinutes, 30)
        let whitelist = try XCTUnwrap(store.getWhitelistEntry(username: "wxid_contact"))
        XCTAssertEqual(whitelist.displayName, "旧姓名")
        XCTAssertEqual(whitelist.category, .work)
        let profile = try XCTUnwrap(store.getRelationshipProfile(username: "wxid_contact"))
        XCTAssertEqual(profile.relationship, oldProfile.relationship)
        XCTAssertEqual(profile.hierarchy, oldProfile.hierarchy)
        XCTAssertEqual(profile.tonePreference, oldProfile.tonePreference)
        XCTAssertEqual(profile.userNote, oldProfile.userNote)
    }

    private func categorizer() -> AIWhitelistCategorizer {
        AIWhitelistCategorizer(store: store, aiService: AIService(config: aiConfig()))
    }

    private func aiConfig() -> AIConfig {
        var config = AIConfig()
        config.provider = AIProviderSlot(
            providerID: "custom",
            baseURL: "http://settings-reliability.test",
            model: "settings-test-model",
            apiKey: ""
        )
        return config
    }

    private func batchItems(count: Int) -> [AIWhitelistCategorizer.BatchItem] {
        (0..<count).map { index in
            AIWhitelistCategorizer.BatchItem(
                index: index + 1,
                contactName: "联系人\(index + 1)",
                isGroup: false,
                recentCount: 1,
                messages: [(sender: "联系人\(index + 1)", body: "测试消息")]
            )
        }
    }

    private func chatResponse(
        content: String,
        statusCode: Int = 200
    ) -> (Data, URLResponse) {
        let body = try! JSONSerialization.data(withJSONObject: [
            "choices": [["message": ["role": "assistant", "content": content]]]
        ])
        let response = HTTPURLResponse(
            url: URL(string: "http://settings-reliability.test/chat/completions")!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (body, response)
    }
}
