import XCTest
@testable import WeChatHUD

final class ProductWorkspaceTests: XCTestCase {
    func testClassificationQueueSurvivesRestartAndRetriesWithoutLosingSource() throws {
        let path = NSTemporaryDirectory() + "workspace-\(UUID().uuidString).sqlite3"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = HUDStore(dbPath: path)
        try store.open()
        let message = MessageInfo(id: "chat:42", localId: 42, chatUsername: "chat", chatName: "测试", senderUsername: "peer", senderName: "对方", text: "请确认方案", baseType: 1, subType: 0, createTime: 100)
        try store.enqueueClassificationMessages([message, message])
        XCTAssertEqual(store.classificationQueueCount(), 1)
        store.close()
        try store.open()
        XCTAssertEqual(store.pendingClassificationMessages().first?.text, "请确认方案")
        try store.deferClassificationMessage(id: message.id)
        XCTAssertTrue(store.pendingClassificationMessages().isEmpty)
        XCTAssertEqual(store.classificationQueueCount(), 1)
        try store.retryClassificationMessages()
        XCTAssertEqual(store.pendingClassificationMessages().first?.localId, 42)
        try store.completeClassificationMessage(id: message.id)
        XCTAssertEqual(store.classificationQueueCount(), 0)
        store.close()
    }

    func testDraftScheduleDoesNotReadNumericReplyTextAsSendTime() throws {
        let store = HUDStore(dbPath: ":memory:")
        try store.open()
        defer { store.close() }
        try store.saveDraft(chatUsername: "a", chatName: "甲", text: "12345 是编号", sendAt: nil)
        try store.saveDraft(chatUsername: "b", chatName: "乙", text: "文字回复", sendAt: Date(timeIntervalSince1970: 9999))
        let drafts = store.loadDrafts()
        XCTAssertNil(drafts.first { $0.chatUsername == "a" }?.sendAt)
        XCTAssertEqual(drafts.first { $0.chatUsername == "b" }?.sendAt, Date(timeIntervalSince1970: 9999))
        let first = try XCTUnwrap(drafts.first { $0.chatUsername == "a" })
        try store.updateDraft(id: first.id, text: "修改后的回复")
        XCTAssertEqual(store.loadDrafts().first { $0.id == first.id }?.text, "修改后的回复")
        XCTAssertEqual(store.loadDrafts().count, 2)
    }

    func testContinuationUpdateRequiresOriginalIDAndChatIdentity() throws {
        let store = HUDStore(dbPath: ":memory:")
        try store.open()
        defer { store.close() }
        try store.saveDraft(chatUsername: "alice", chatName: "甲", text: "原稿", sendAt: nil)
        let draft = try XCTUnwrap(store.loadDrafts().first)

        try store.updateDraft(id: draft.id, chatUsername: "alice", text: "更新")
        XCTAssertEqual(store.loadDrafts().first?.text, "更新")
        XCTAssertThrowsError(try store.updateDraft(id: draft.id, chatUsername: "bob", text: "串会话"))

        XCTAssertEqual(store.executeUpdate(
            "CREATE TRIGGER reject_draft_update BEFORE UPDATE OF text ON reply_drafts BEGIN SELECT RAISE(ABORT, 'draft write rejected'); END;",
            bind: { _ in }
        ), 0)
        XCTAssertThrowsError(try store.updateDraft(id: draft.id, chatUsername: "alice", text: "被拒绝")) { error in
            guard case HUDStoreError.sqlError = error else {
                return XCTFail("trigger abort must remain a SQL error, not draftNotFound: \(error)")
            }
        }

        try store.deleteDraft(id: draft.id)
        XCTAssertThrowsError(try store.updateDraft(id: draft.id, chatUsername: "alice", text: "已删除"))
        XCTAssertTrue(store.loadDrafts().isEmpty)
    }

    func testTaskOwnershipHistoryAndSearchRemainSeparate() {
        let now = Date()
        func item(_ id: Int64, owner: DiscussionItemOwner, kind: DiscussionItemKind = .todo, status: DiscussionItemStatus = .pending) -> DiscussionItem {
            DiscussionItem(id: id, chatUsername: "chat", chatName: "项目群", kind: kind, owner: owner, content: "验收方案", detail: nil, anchorMsgUID: "\(id)", sourceTimestamp: 100, dueAt: nil, status: status, confidence: 0.9, promptVersion: "test", createdAt: now, updatedAt: now)
        }
        let items = [item(1, owner: .mine), item(2, owner: .theirs), item(3, owner: .theirs, kind: .info), item(4, owner: .mine, status: .done)]
        XCTAssertEqual(DiscussionPresentation.items(items, scope: .theirs, query: "项目", history: false).map(\.id), [2])
        XCTAssertEqual(DiscussionPresentation.items(items, scope: .notes, query: "", history: false).map(\.id), [3])
        XCTAssertEqual(DiscussionPresentation.items(items, scope: .mine, query: "", history: true).map(\.id), [4])
        XCTAssertTrue(DiscussionPresentation.items(items, scope: .all, query: "不存在", history: false).isEmpty)
    }

    func testTaskGroupsAndDueLabelsStayCalendarHonest() {
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 9, hour: 10))!
        let today = calendar.date(byAdding: .hour, value: 5, to: now)!
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now)!
        let later = calendar.date(byAdding: .day, value: 10, to: now)!
        func item(_ id: Int64, due: Date?) -> DiscussionItem {
            DiscussionItem(id: id, chatUsername: "chat", chatName: "项目群", kind: .todo, owner: .mine, content: "事项\(id)", detail: nil, anchorMsgUID: "\(id)", sourceTimestamp: 100, dueAt: due, status: .pending, confidence: 0.9, promptVersion: "test", createdAt: now, updatedAt: now)
        }
        let groups = DiscussionPresentation.groups([item(1, due: today), item(2, due: tomorrow), item(3, due: later), item(4, due: nil)], now: now, calendar: calendar)
        XCTAssertEqual(groups.map(\.title), ["今天", "明天", "之后", "无期限"])
        XCTAssertTrue(DiscussionPresentation.dueLabel(today, now: now, calendar: calendar).contains("今天"))
        XCTAssertTrue(DiscussionPresentation.dueLabel(tomorrow, now: now, calendar: calendar).contains("明天"))
        XCTAssertEqual(DiscussionPresentation.dueLabel(nil), "无期限")
        XCTAssertEqual(DiscussionItemOwner.mine.workspaceLabel, "我来做")
    }

    func testCommitmentGroupsTreatPastDeadlinesAsOverdue() {
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 9, hour: 10))!
        let past = calendar.date(byAdding: .day, value: -1, to: now)!
        let today = calendar.date(byAdding: .hour, value: 2, to: now)!
        func commitment(_ id: Int64, deadline: Date?, status: CommitmentStatus = .pending) -> Commitment {
            Commitment(id: id, msgUID: "\(id)", chatUsername: "chat", chatName: "林舟", content: "确认时间", commitTo: "林舟", deadlineAt: deadline, confidence: 0.9, status: status, promptVersion: "t", createdAt: now, updatedAt: now)
        }
        XCTAssertTrue(CommitmentPresentation.isOverdue(commitment(1, deadline: past), now: now))
        XCTAssertFalse(CommitmentPresentation.isOverdue(commitment(2, deadline: today), now: now))
        let groups = CommitmentPresentation.groups([commitment(1, deadline: past), commitment(2, deadline: today), commitment(3, deadline: nil)], now: now, calendar: calendar)
        XCTAssertEqual(groups.map(\.title).first, "已过期")
        XCTAssertTrue(groups.contains { $0.title.hasPrefix("今天") })
        XCTAssertTrue(groups.contains { $0.title == "无期限" })
    }

    func testReviewFollowUpsUseTheSamePendingTasksAndDropCompletedOnes() {
        let now = Date()
        func item(_ id: Int64, chat: String, status: DiscussionItemStatus, owner: DiscussionItemOwner = .mine, kind: DiscussionItemKind = .todo) -> DiscussionItem {
            DiscussionItem(id: id, chatUsername: chat, chatName: "林晓", kind: kind, owner: owner, content: "确认评审时间", detail: nil, anchorMsgUID: "\(id)", sourceTimestamp: 1, dueAt: now, status: status, confidence: 0.9, promptVersion: "t", createdAt: now, updatedAt: now)
        }
        let pending = [item(1, chat: "preview-colleague", status: .pending), item(2, chat: "preview-project", status: .pending), item(3, chat: "preview-colleague", status: .done), item(4, chat: "preview-colleague", status: .pending, kind: .info)]
        let follow = ChatReviewFollowUps.items(chatUsername: "preview-colleague", discussion: pending)
        XCTAssertEqual(follow.map(\.title), ["确认评审时间"])
        XCTAssertEqual(follow.first?.owner, "我来做")
        XCTAssertEqual(follow.first?.chatUsername, "preview-colleague")
        XCTAssertTrue(ChatReviewFollowUps.items(chatUsername: "preview-colleague", discussion: pending.map {
            $0.id == 1 ? item(1, chat: "preview-colleague", status: .done) : $0
        }).isEmpty)
    }
}
