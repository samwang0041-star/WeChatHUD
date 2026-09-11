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
        XCTAssertEqual(store.draftCount(), 2)
    }

    func testWorkspaceDraftsIncludeInProgressComposerText() throws {
        let store = HUDStore(dbPath: ":memory:")
        try store.open()
        defer { store.close() }
        try store.setSetting("composer_draft:wxid_dan", value: "来吧")
        XCTAssertEqual(store.draftCount(), 0)
        XCTAssertEqual(store.workspaceDraftCount(), 1)
        XCTAssertEqual(store.loadWorkspaceDrafts().first?.text, "来吧")
        XCTAssertEqual(store.loadWorkspaceDrafts().first?.isComposerOnly, true)

        try store.saveDraft(chatUsername: "wxid_dan", chatName: "王丹", text: "来吧", sendAt: nil)
        XCTAssertEqual(store.workspaceDraftCount(), 1)
        XCTAssertEqual(store.loadWorkspaceDrafts().first?.isComposerOnly, false)

        try store.setSetting("composer_draft:wxid_dan", value: "改过的")
        XCTAssertEqual(store.workspaceDraftCount(), 2)
        try store.clearComposerDraft(chatUsername: "wxid_dan")
        XCTAssertEqual(store.workspaceDraftCount(), 1)
    }

    func testWorkspaceDraftsIgnoreEmptyComposerText() throws {
        let store = HUDStore(dbPath: ":memory:")
        try store.open()
        defer { store.close() }

        try store.setSetting("composer_draft:wxid_empty", value: "")
        try store.setSetting("composer_draft:wxid_space", value: "  \n\t")
        XCTAssertEqual(store.workspaceDraftCount(), 0)
        XCTAssertTrue(store.loadWorkspaceDrafts().isEmpty)

        try store.saveDraft(chatUsername: "wxid_dan", chatName: "王丹", text: "来吧", sendAt: nil)
        try store.setSetting("composer_draft:wxid_dan", value: "")
        XCTAssertEqual(store.workspaceDraftCount(), 1)
        XCTAssertEqual(store.loadWorkspaceDrafts().map(\.isComposerOnly), [false])
    }

    func testWorkspaceDraftsKeepSeparateRowsWhenSavedAndComposerTextDiffer() throws {
        let store = HUDStore(dbPath: ":memory:")
        try store.open()
        defer { store.close() }

        try store.saveDraft(chatUsername: "wxid_dan", chatName: "王丹", text: "存好的", sendAt: nil)
        try store.setSetting("composer_draft:wxid_dan", value: "正在写")
        let rows = store.loadWorkspaceDrafts()
        XCTAssertEqual(store.workspaceDraftCount(), 2)
        XCTAssertEqual(rows.filter { $0.chatUsername == "wxid_dan" }.count, 2)
        XCTAssertEqual(Set(rows.map(\.text)), ["存好的", "正在写"])
        XCTAssertEqual(rows.filter(\.isComposerOnly).map(\.text), ["正在写"])
        XCTAssertEqual(rows.filter { !$0.isComposerOnly }.map(\.text), ["存好的"])

        try store.clearComposerDraft(chatUsername: "wxid_dan")
        XCTAssertEqual(store.workspaceDraftCount(), 1)
        XCTAssertEqual(store.loadWorkspaceDrafts().first?.isComposerOnly, false)
    }

    func testWorkspaceDraftsSurviveMultipleSavedRowsForSameChat() throws {
        let store = HUDStore(dbPath: ":memory:")
        try store.open()
        defer { store.close() }

        try store.saveDraft(chatUsername: "wxid_dan", chatName: "王丹", text: "第一版", sendAt: nil)
        try store.saveDraft(chatUsername: "wxid_dan", chatName: "王丹", text: "第二版", sendAt: nil)
        XCTAssertEqual(store.workspaceDraftCount(), 2)
        XCTAssertEqual(Set(store.loadWorkspaceDrafts().map(\.text)), ["第一版", "第二版"])

        try store.setSetting("composer_draft:wxid_dan", value: "第一版")
        XCTAssertEqual(store.workspaceDraftCount(), 2)
        XCTAssertFalse(store.loadWorkspaceDrafts().contains(where: \.isComposerOnly))

        try store.setSetting("composer_draft:wxid_dan", value: "正在写的")
        let rows = store.loadWorkspaceDrafts()
        XCTAssertEqual(store.workspaceDraftCount(), 3)
        XCTAssertEqual(rows.filter(\.isComposerOnly).count, 1)
        XCTAssertEqual(rows.filter(\.isComposerOnly).first?.text, "正在写的")
    }

    func testComposerOnlyContinuationDoesNotClaimASavedDraftRow() {
        let composerID = HUDStore.composerDraftID("wxid_dan")
        XCTAssertLessThan(composerID, 0)
        let composer = ReplyDraftsView.Draft(
            id: composerID,
            chatUsername: "wxid_dan",
            chatName: "王丹",
            text: "来吧",
            createdAt: Date(),
            isComposerOnly: true
        )
        XCTAssertNil(composer.continuationSavedDraftID)

        let saved = ReplyDraftsView.Draft(
            id: 7,
            chatUsername: "wxid_dan",
            chatName: "王丹",
            text: "存好的",
            createdAt: Date(),
            isComposerOnly: false
        )
        XCTAssertEqual(saved.continuationSavedDraftID, 7)
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
        XCTAssertEqual(WorkspaceBadgeCounts.taskCount(items), 1,
                       "sidebar 待办 badge is 我要做, not every pending row")
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
        let overdue = item(5, due: calendar.date(byAdding: .day, value: -2, to: now))
        XCTAssertEqual(
            DiscussionPresentation.groups([overdue, item(1, due: today), item(4, due: nil)], now: now, calendar: calendar).map(\.title),
            ["今天", "已过期", "无期限"]
        )
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

    func testReviewFollowUpHeadingDoesNotClaimTheSelectedDay() {
        let now = Date(timeIntervalSince1970: 1_778_000_000)
        XCTAssertEqual(ChatReviewFollowUps.heading(selectedDate: now, now: now), "当前待办")
        let yesterday = now.addingTimeInterval(-86_400)
        XCTAssertEqual(ChatReviewFollowUps.heading(selectedDate: yesterday, now: now), "现在的待办（与所选日期无关）")
    }

    func testLocalDataRetrospectionUsesFourteenDayWindow() {
        XCTAssertEqual(LocalDataRetrospection.windowDays, 14)
        XCTAssertTrue(LocalDataRetrospection.exportCaption.contains("不是聊天原文"))
        XCTAssertTrue(LocalDataRetrospection.windowCaption.contains("14"))
        XCTAssertTrue(LocalDataRetrospection.emptyPendingAsks.contains("近两周"))
        XCTAssertTrue(LocalDataRetrospection.emptyRecalls.contains("近两周"))
    }

    func testLiveListPatchesPendingRowsWithoutKeepingCompletedHistory() {
        let now = Date()
        func item(_ id: Int64, status: DiscussionItemStatus, content: String = "确认方案") -> DiscussionItem {
            DiscussionItem(id: id, chatUsername: "chat", chatName: "项目群", kind: .todo, owner: .mine, content: content, detail: nil, anchorMsgUID: "\(id)", sourceTimestamp: 100, dueAt: nil, status: status, confidence: 0.9, promptVersion: "test", createdAt: now, updatedAt: now)
        }
        let pending = [item(1, status: .pending), item(2, status: .pending)]
        XCTAssertEqual(DiscussionLiveList.applying(pending, replacement: item(1, status: .done)).map(\.id), [2])
        XCTAssertEqual(DiscussionLiveList.applying(pending, replacement: item(1, status: .pending, content: "改过的方案")).map(\.content), ["改过的方案", "确认方案"])
        XCTAssertEqual(DiscussionLiveList.applying([item(2, status: .pending)], replacement: item(3, status: .pending)).map(\.id), [3, 2])
        XCTAssertEqual(item(1, status: .pending), item(1, status: .pending))
    }

    func testDiscussionLoadKeepsPendingLiveListSeparateFromHistory() throws {
        let store = HUDStore(dbPath: ":memory:")
        try store.open()
        defer { store.close() }
        XCTAssertTrue(try store.insertDiscussionItem(
            chatUsername: "chat", chatName: "项目群", kind: .todo, owner: .mine,
            content: "未完成", detail: nil, anchorMsgUID: "p1", sourceTimestamp: 200,
            dueAt: nil, confidence: 0.9, promptVersion: "test"
        ))
        XCTAssertTrue(try store.insertDiscussionItem(
            chatUsername: "chat", chatName: "项目群", kind: .todo, owner: .mine,
            content: "已完成", detail: nil, anchorMsgUID: "d1", sourceTimestamp: 100,
            dueAt: nil, confidence: 0.9, promptVersion: "test"
        ))
        let doneID = try XCTUnwrap(store.loadDiscussionItems().first { $0.content == "已完成" }?.id)
        try store.updateDiscussionItemStatus(id: doneID, status: .done)
        XCTAssertEqual(store.loadDiscussionItems(status: .pending).map(\.content), ["未完成"])
        XCTAssertEqual(store.loadDiscussionItems(excludingStatus: .pending).map(\.content), ["已完成"])
        XCTAssertEqual(store.loadDiscussionItem(id: doneID)?.status, .done)
    }

    func testLiveWindowKeepsOpenItemsAndDropsStaleFinishedOnes() throws {
        let now = Date(timeIntervalSince1970: 1_778_000_000)
        let cutoff = DiscussionLiveWindow.cutoff(days: 14, now: now)
        func item(_ id: Int64, sourceOffset: Int, dueOffset: Int?) -> DiscussionItem {
            DiscussionItem(
                id: id, chatUsername: "chat", chatName: "项目群", kind: .todo, owner: .mine,
                content: "事项\(id)", detail: nil, anchorMsgUID: "\(id)",
                sourceTimestamp: cutoff + sourceOffset,
                dueAt: dueOffset.map { Date(timeIntervalSince1970: TimeInterval(cutoff + $0)) },
                status: .pending, confidence: 0.9, promptVersion: "test", createdAt: now, updatedAt: now
            )
        }
        XCTAssertTrue(DiscussionLiveWindow.contains(item(1, sourceOffset: 3_600, dueOffset: nil), cutoff: cutoff))
        XCTAssertFalse(DiscussionLiveWindow.contains(item(2, sourceOffset: -20 * 86_400, dueOffset: nil), cutoff: cutoff))
        XCTAssertTrue(DiscussionLiveWindow.contains(item(3, sourceOffset: -20 * 86_400, dueOffset: 86_400), cutoff: cutoff))
        func finished(_ id: Int64, status: DiscussionItemStatus, sourceOffset: Int, dueOffset: Int?, updatedOffset: Int) -> DiscussionItem {
            let base = item(id, sourceOffset: sourceOffset, dueOffset: dueOffset)
            return DiscussionItem(
                id: base.id, chatUsername: base.chatUsername, chatName: base.chatName,
                kind: base.kind, owner: base.owner, content: base.content, detail: base.detail,
                anchorMsgUID: base.anchorMsgUID, sourceTimestamp: base.sourceTimestamp, dueAt: base.dueAt,
                status: status, confidence: base.confidence, promptVersion: base.promptVersion,
                createdAt: now, updatedAt: Date(timeIntervalSince1970: TimeInterval(cutoff + updatedOffset))
            )
        }
        XCTAssertFalse(DiscussionLiveWindow.contains(
            finished(4, status: .done, sourceOffset: -20 * 86_400, dueOffset: -15 * 86_400, updatedOffset: -20 * 86_400),
            cutoff: cutoff))
        XCTAssertTrue(DiscussionLiveWindow.contains(
            finished(5, status: .archived, sourceOffset: -20 * 86_400, dueOffset: nil, updatedOffset: 0),
            cutoff: cutoff))

        let store = HUDStore(dbPath: ":memory:")
        try store.open()
        defer { store.close() }
        XCTAssertTrue(try store.insertDiscussionItem(
            chatUsername: "chat", chatName: "项目群", kind: .todo, owner: .mine,
            content: "旧的无期限", detail: nil, anchorMsgUID: "old",
            sourceTimestamp: cutoff - 20 * 86_400, dueAt: nil, confidence: 0.9, promptVersion: "test"
        ))
        XCTAssertTrue(try store.insertDiscussionItem(
            chatUsername: "chat", chatName: "项目群", kind: .todo, owner: .mine,
            content: "旧的但未到期", detail: nil, anchorMsgUID: "due",
            sourceTimestamp: cutoff - 20 * 86_400,
            dueAt: Date(timeIntervalSince1970: TimeInterval(cutoff + 86_400)),
            confidence: 0.9, promptVersion: "test"
        ))
        XCTAssertTrue(try store.insertDiscussionItem(
            chatUsername: "chat", chatName: "项目群", kind: .todo, owner: .mine,
            content: "刚出现", detail: nil, anchorMsgUID: "new",
            sourceTimestamp: cutoff + 3_600, dueAt: nil, confidence: 0.9, promptVersion: "test"
        ))
        XCTAssertEqual(
            store.loadDiscussionItems(status: .pending, relevantSince: cutoff).map(\.content).sorted(),
            ["刚出现", "旧的但未到期"]
        )
        XCTAssertEqual(try store.archiveStalePendingDiscussionItems(cutoff: cutoff, now: now), 1)
        XCTAssertEqual(
            store.loadDiscussionItems(status: .pending, relevantSince: cutoff).map(\.content).sorted(),
            ["刚出现", "旧的但未到期"]
        )
        XCTAssertEqual(
            store.loadDiscussionItems(excludingStatus: .pending, relevantSince: cutoff).map(\.content),
            ["旧的无期限"]
        )
        XCTAssertEqual(
            store.loadDiscussionItems(excludingStatus: .pending, relevantSince: cutoff).first?.status,
            .archived
        )
    }

    func testLiveRankPutsUpcomingBeforeAncientOverdueAndUndated() {
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 10, hour: 16))!
        func item(_ id: Int64, owner: DiscussionItemOwner = .mine, kind: DiscussionItemKind = .todo,
                  sourceOffset: TimeInterval, dueOffset: TimeInterval?) -> DiscussionItem {
            DiscussionItem(
                id: id, chatUsername: "chat", chatName: "项目群", kind: kind, owner: owner,
                content: "事项\(id)", detail: nil, anchorMsgUID: "\(id)",
                sourceTimestamp: Int(now.timeIntervalSince1970 + sourceOffset),
                dueAt: dueOffset.map { now.addingTimeInterval($0) },
                status: .pending, confidence: 0.9, promptVersion: "test", createdAt: now, updatedAt: now
            )
        }
        let ancientOverdue = item(1, sourceOffset: -150 * 86_400, dueOffset: -145 * 86_400)
        let recentOverdue = item(2, sourceOffset: -3 * 86_400, dueOffset: -2 * 86_400)
        let tomorrow = item(3, sourceOffset: -3600, dueOffset: 18 * 3600)
        let nextWeek = item(4, sourceOffset: -7200, dueOffset: 6 * 86_400)
        let undatedRecent = item(5, sourceOffset: -1800, dueOffset: nil)
        let undatedOld = item(6, sourceOffset: -10 * 86_400, dueOffset: nil)
        let todayMissed = item(7, sourceOffset: -900, dueOffset: -3600)
        let ranked = DiscussionPresentation.items(
            [ancientOverdue, recentOverdue, tomorrow, nextWeek, undatedRecent, undatedOld, todayMissed],
            scope: .mine, query: "", history: false, now: now, calendar: calendar
        )
        XCTAssertEqual(ranked.map(\.id), [3, 4, 7, 2, 1, 5, 6])
        XCTAssertEqual(Array(ranked.prefix(4)).map(\.id), [3, 4, 7, 2])
    }

    func testHistoryGroupsKeepAutoArchiveOutOfCompleted() {
        let now = Date()
        func item(_ id: Int64, status: DiscussionItemStatus) -> DiscussionItem {
            DiscussionItem(
                id: id, chatUsername: "chat", chatName: "项目群", kind: .todo, owner: .mine,
                content: "事项\(id)", detail: nil, anchorMsgUID: "\(id)", sourceTimestamp: 1,
                dueAt: nil, status: status, confidence: 0.9, promptVersion: "test",
                createdAt: now, updatedAt: now
            )
        }
        let groups = DiscussionPresentation.groups(
            [item(1, status: .archived), item(2, status: .done), item(3, status: .dismissed)],
            now: now, history: true
        )
        XCTAssertEqual(groups.map(\.title), ["已完成", "已忽略", DiscussionPresentation.archivedGroupTitle])
        XCTAssertEqual(groups[0].items.map(\.id), [2])
        XCTAssertEqual(groups[2].items.map(\.id), [1])
    }

    func testLivePipelineArchivesStaleThenFillsHUDFromUpcoming() throws {
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 10, hour: 16))!
        let cutoff = DiscussionLiveWindow.cutoff(days: 14, now: now)
        let store = HUDStore(dbPath: ":memory:")
        try store.open()
        defer { store.close() }
        XCTAssertTrue(try store.insertDiscussionItem(
            chatUsername: "chat", chatName: "项目群", kind: .todo, owner: .mine,
            content: "拉群询问接口对接事宜", detail: nil, anchorMsgUID: "old",
            sourceTimestamp: cutoff - 150 * 86_400,
            dueAt: Date(timeIntervalSince1970: TimeInterval(cutoff - 145 * 86_400)),
            confidence: 0.9, promptVersion: "test"
        ))
        XCTAssertTrue(try store.insertDiscussionItem(
            chatUsername: "chat", chatName: "项目群", kind: .todo, owner: .mine,
            content: "填写课后服务自主作业报名收集表", detail: nil, anchorMsgUID: "soon",
            sourceTimestamp: Int(now.timeIntervalSince1970),
            dueAt: now.addingTimeInterval(18 * 3600),
            confidence: 0.9, promptVersion: "test"
        ))
        XCTAssertTrue(try store.insertDiscussionItem(
            chatUsername: "chat", chatName: "项目群", kind: .todo, owner: .mine,
            content: "补订硬皮本", detail: nil, anchorMsgUID: "undated",
            sourceTimestamp: Int(now.timeIntervalSince1970),
            dueAt: nil, confidence: 0.9, promptVersion: "test"
        ))
        XCTAssertEqual(try store.archiveStalePendingDiscussionItems(cutoff: cutoff, now: now), 1)
        let live = store.loadDiscussionItems(status: .pending, relevantSince: cutoff)
        let ranked = DiscussionPresentation.items(live, scope: .mine, query: "", history: false, now: now, calendar: calendar)
        XCTAssertEqual(ranked.map(\.content), ["填写课后服务自主作业报名收集表", "补订硬皮本"])
        XCTAssertEqual(Array(ranked.prefix(4)).map(\.content).first, "填写课后服务自主作业报名收集表")
        let history = store.loadDiscussionItems(excludingStatus: .pending, relevantSince: cutoff)
        XCTAssertEqual(history.map(\.content), ["拉群询问接口对接事宜"])
        XCTAssertEqual(history.first?.status, .archived)
        XCTAssertEqual(
            DiscussionPresentation.groups(history, now: now, calendar: calendar, history: true).map(\.title),
            [DiscussionPresentation.archivedGroupTitle]
        )
    }

    func testCommitmentLoadKeepsDueItemsInsideTheSameWindow() throws {
        let now = Date(timeIntervalSince1970: 1_778_000_000)
        let cutoff = DiscussionLiveWindow.cutoff(days: 14, now: now)
        let store = HUDStore(dbPath: ":memory:")
        try store.open()
        defer { store.close() }
        try store.upsertCommitment(
            msgUID: "old", chatUsername: "chat", chatName: "项目群",
            content: "旧的无期限", commitTo: "林晓",
            deadlineAt: nil, confidence: 0.9, promptVersion: "test",
            createdAt: Date(timeIntervalSince1970: TimeInterval(cutoff - 20 * 86_400))
        )
        try store.upsertCommitment(
            msgUID: "due", chatUsername: "chat", chatName: "项目群",
            content: "旧的但未到期", commitTo: "林晓",
            deadlineAt: Date(timeIntervalSince1970: TimeInterval(cutoff + 86_400)),
            confidence: 0.9, promptVersion: "test",
            createdAt: Date(timeIntervalSince1970: TimeInterval(cutoff - 20 * 86_400))
        )
        try store.upsertCommitment(
            msgUID: "new", chatUsername: "chat", chatName: "项目群",
            content: "刚答应", commitTo: "林晓",
            deadlineAt: nil, confidence: 0.9, promptVersion: "test",
            createdAt: Date(timeIntervalSince1970: TimeInterval(cutoff + 3_600))
        )
        try store.upsertCommitment(
            msgUID: "overdue", chatUsername: "chat", chatName: "项目群",
            content: "逾期很久", commitTo: "林晓",
            deadlineAt: Date(timeIntervalSince1970: TimeInterval(cutoff - 15 * 86_400)),
            confidence: 0.9, promptVersion: "test",
            createdAt: Date(timeIntervalSince1970: TimeInterval(cutoff - 20 * 86_400))
        )
        try store.updateCommitmentStatus(msgUID: "overdue", status: .overdue)
        try store.upsertCommitment(
            msgUID: "done", chatUsername: "chat", chatName: "项目群",
            content: "很久以前做完", commitTo: "林晓",
            deadlineAt: Date(timeIntervalSince1970: TimeInterval(cutoff - 15 * 86_400)),
            confidence: 0.9, promptVersion: "test",
            createdAt: Date(timeIntervalSince1970: TimeInterval(cutoff - 20 * 86_400))
        )
        try store.updateCommitmentStatus(msgUID: "done", status: .fulfilled)
        XCTAssertEqual(
            store.loadCommitments(relevantSince: cutoff).map(\.content).sorted(),
            ["刚答应", "很久以前做完", "旧的但未到期", "旧的无期限", "逾期很久"]
        )
    }

    @MainActor
    func testIslandPresentationIgnoresIdenticalLiveInput() {
        let chrome = IslandPresentation()
        let first = IslandLiveInput(sync: .ok, actions: [], noticeCount: 1, autopilotActive: false, vipGlowTier: .none)
        chrome.publish(first)
        XCTAssertEqual(chrome.live.noticeCount, 1)
        chrome.publish(first)
        XCTAssertEqual(chrome.live.noticeCount, 1)
        chrome.publish(IslandLiveInput(sync: .ok, actions: [], noticeCount: 2, autopilotActive: false, vipGlowTier: .none))
        XCTAssertEqual(chrome.live.noticeCount, 2)
        chrome.publish(IslandLiveInput(sync: .syncing, actions: [], noticeCount: 2, autopilotActive: false, vipGlowTier: .none))
        XCTAssertEqual(chrome.live.sync, .ok)
        XCTAssertEqual(chrome.live.noticeCount, 2)
    }

    func testInboxItemEqualityIgnoresNotificationIdentityNoise() {
        let now = Date(timeIntervalSince1970: 100)
        func note() -> HUDNotification {
            HUDNotification(
                chatUsername: "chat", chatName: "林晓", senderUsername: "peer", senderName: "林晓",
                attentionLevel: .vip, messageID: "m1", rawText: "确认一下", snippet: "确认一下",
                isAtMention: false, timestamp: now, kind: .privateChat
            )
        }
        func item(_ summary: String?) -> InboxItem {
            InboxItem(
                id: "chat", chatUsername: "chat", chatName: "林晓", senderName: "林晓",
                preview: "确认一下", isGroup: false, timestamp: now, actionRequired: true,
                priority: .p1, isVIP: true, isWhitelisted: true, unreadCount: 1,
                isAtMention: false, askType: .none, reasons: [], suggestedReplyMinutes: 60,
                status: .active, dismissedAtMsgId: nil, aiSummary: summary, moodEmoji: nil,
                contextNotification: note()
            )
        }
        XCTAssertEqual(item("摘要"), item("摘要"))
        XCTAssertNotEqual(item("摘要"), item("另一份"))
    }

    func testInsightTodayWindowIsOneDayNotTwentyFour() {
        XCTAssertEqual(InsightTimeWindow.today.dayCount, 1)
        XCTAssertEqual(InsightTimeWindow.today.seconds, 86400)
        XCTAssertEqual(InsightTimeWindow.week.dayCount, 7)
        XCTAssertNil(InsightTimeWindow.all.seconds)
    }

    func testCommitmentTimeLabelKeepsTheDateWhenItIsNotToday() {
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 10, hour: 16))!
        let today = calendar.date(from: DateComponents(year: 2026, month: 9, day: 10, hour: 9, minute: 30))!
        let yesterday = calendar.date(from: DateComponents(year: 2026, month: 9, day: 9, hour: 15, minute: 0))!
        XCTAssertEqual(CommitmentPresentation.timeLabel(nil), "无期限")
        XCTAssertEqual(
            CommitmentPresentation.timeLabel(today, now: now, calendar: calendar),
            today.formatted(date: .omitted, time: .shortened)
        )
        let pastLabel = CommitmentPresentation.timeLabel(yesterday, now: now, calendar: calendar)
        XCTAssertNotEqual(pastLabel, yesterday.formatted(date: .omitted, time: .shortened))
    }

    func testCancelledCommitmentsDoNotSitInTheOverdueGroup() {
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 10, hour: 16))!
        let past = calendar.date(byAdding: .day, value: -2, to: now)!
        let cancelled = Commitment(
            id: 1, msgUID: "1", chatUsername: "chat", chatName: "林晓",
            content: "吃饭", commitTo: "林晓", deadlineAt: past, confidence: 0.9,
            status: .cancelled, promptVersion: "t", createdAt: now, updatedAt: now
        )
        XCTAssertEqual(CommitmentPresentation.sectionTitle(for: cancelled, now: now, calendar: calendar), "已取消")
        XCTAssertEqual(CommitmentPresentation.groups([cancelled], now: now, calendar: calendar).map(\.title), ["已取消"])
        XCTAssertFalse(CommitmentPresentation.isOverdue(cancelled, now: now))
        XCTAssertFalse(CommitmentPresentation.matches(cancelled, filter: .active))
        XCTAssertFalse(CommitmentPresentation.matches(cancelled, filter: .overdue, now: now))
        XCTAssertEqual(CommitmentPresentation.overdueCount([cancelled], now: now), 0)
    }

    func testCommitmentActiveCountMatchesPendingOrOverdueStatusNotDoubleCounted() {
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 10, hour: 16))!
        let past = calendar.date(byAdding: .day, value: -1, to: now)!
        let later = calendar.date(byAdding: .day, value: 1, to: now)!
        let pendingFuture = workspaceCommitment(id: 1, deadline: later, created: now)
        let pendingPast = workspaceCommitment(id: 2, deadline: past, created: now)
        let overdueStatus = workspaceCommitment(id: 3, deadline: past, status: .overdue, created: now)
        let fulfilled = workspaceCommitment(id: 4, deadline: past, status: .fulfilled, created: now)
        let cancelled = workspaceCommitment(id: 5, deadline: past, status: .cancelled, created: now)
        let items = [pendingFuture, pendingPast, overdueStatus, fulfilled, cancelled]

        XCTAssertEqual(CommitmentPresentation.activeCount(items), 3)
        XCTAssertEqual(
            CommitmentPresentation.activeCount(items),
            items.filter { $0.status == .pending || $0.status == .overdue }.count
        )
        XCTAssertEqual(CommitmentPresentation.overdueCount(items, now: now), 2)
        XCTAssertNotEqual(
            CommitmentPresentation.activeCount(items),
            items.filter { $0.status == .pending }.count + CommitmentPresentation.overdueCount(items, now: now)
        )
        XCTAssertTrue(CommitmentPresentation.matches(pendingPast, filter: .active))
        XCTAssertTrue(CommitmentPresentation.matches(pendingPast, filter: .overdue, now: now))
        XCTAssertTrue(CommitmentPresentation.matches(overdueStatus, filter: .active))
        XCTAssertFalse(CommitmentPresentation.matches(fulfilled, filter: .active))
        XCTAssertEqual(CommitmentPresentation.emptyTitle(for: .all), "没有正在跟进的承诺")
        XCTAssertTrue(CommitmentPresentation.emptyDescription(for: .all).contains("还在本地"))
    }

    func testCommitmentDeadlineTextUsesStoredLabelWhenDateIsMissing() {
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 10, hour: 19))!
        let dated = calendar.date(from: DateComponents(year: 2026, month: 9, day: 10, hour: 18))!
        XCTAssertEqual(
            CommitmentPresentation.deadlineText(
                for: workspaceCommitment(id: 1, label: "临时通知，尽快", created: now),
                now: now,
                calendar: calendar
            ),
            "临时通知，尽快"
        )
        XCTAssertEqual(
            CommitmentPresentation.deadlineText(
                for: workspaceCommitment(id: 2, label: "无明确时间", source: "写 ppt", created: now),
                now: now,
                calendar: calendar
            ),
            "无明确时间"
        )
        XCTAssertEqual(
            CommitmentPresentation.deadlineText(for: workspaceCommitment(id: 3, created: now), now: now, calendar: calendar),
            "无期限"
        )
        XCTAssertEqual(
            CommitmentPresentation.deadlineText(
                for: workspaceCommitment(id: 4, deadline: dated, label: "今天下午", created: now),
                now: now,
                calendar: calendar
            ),
            CommitmentPresentation.timeLabel(dated, now: now, calendar: calendar)
        )
        XCTAssertEqual(
            CommitmentPresentation.deadlineText(
                for: workspaceCommitment(id: 5, label: "vague_soon", created: now),
                now: now,
                calendar: calendar
            ),
            "无期限"
        )
    }

    func testLiveWindowKeepsTodaysPendingCommitmentsWithoutDeadline() throws {
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 10, hour: 19, minute: 30))!
        let cutoff = DiscussionLiveWindow.cutoff(days: 14, now: now)
        let store = HUDStore(dbPath: ":memory:")
        try store.open()
        defer { store.close() }
        try store.upsertCommitment(
            msgUID: "ponge-ppt", chatUsername: "wxid_ponge", chatName: "ponge",
            content: "写汇报用的PPT，把哆啦提供的内容整理进去", commitTo: "哆啦",
            deadlineAt: nil, confidence: 0.9, promptVersion: "test",
            sourceText: "写 ppt", deadlineLabel: "无明确时间",
            createdAt: now
        )
        try store.upsertCommitment(
            msgUID: "ponge-report", chatUsername: "wxid_ponge", chatName: "ponge",
            content: "把自己那份内容加进对方的工作汇报里", commitTo: "哆啦（分行汇报相关方）",
            deadlineAt: nil, confidence: 0.9, promptVersion: "test",
            sourceText: "然后呢，临时说要我把我这份内容加到他的工作汇报里去",
            deadlineLabel: "临时通知，尽快",
            createdAt: now.addingTimeInterval(-160)
        )
        let loaded = store.loadCommitments(relevantSince: cutoff)
        XCTAssertEqual(loaded.map(\.msgUID).sorted(), ["ponge-ppt", "ponge-report"])
        XCTAssertTrue(loaded.allSatisfy { DiscussionLiveWindow.contains($0, cutoff: cutoff) })
        XCTAssertEqual(CommitmentPresentation.activeCount(loaded), 2)
        XCTAssertEqual(CommitmentPresentation.overdueCount(loaded, now: now), 0)
        XCTAssertEqual(
            loaded.map { CommitmentPresentation.deadlineText(for: $0, now: now, calendar: calendar) }.sorted(),
            ["临时通知，尽快", "无明确时间"]
        )
        XCTAssertEqual(loaded.first { $0.msgUID == "ponge-ppt" }?.sourceText, "写 ppt")
        XCTAssertEqual(
            loaded.first { $0.msgUID == "ponge-report" }?.sourceText,
            "然后呢，临时说要我把我这份内容加到他的工作汇报里去"
        )
        XCTAssertNotEqual(CommitmentPresentation.emptyTitle(for: .active), "还没有记下你答应过的事")
    }

    func testCompletingOrCancellingACommitmentLeavesTheActiveFilterAndUndoRestoresIt() throws {
        let now = Date()
        let cutoff = DiscussionLiveWindow.cutoff(days: 14, now: now)
        let store = HUDStore(dbPath: ":memory:")
        try store.open()
        defer { store.close() }
        try store.upsertCommitment(
            msgUID: "keep", chatUsername: "chat", chatName: "ponge",
            content: "留下的", commitTo: "哆啦", deadlineAt: nil, confidence: 0.9,
            promptVersion: "test", createdAt: now
        )
        try store.upsertCommitment(
            msgUID: "done", chatUsername: "chat", chatName: "ponge",
            content: "做完的", commitTo: "哆啦", deadlineAt: nil, confidence: 0.9,
            promptVersion: "test", createdAt: now
        )
        try store.upsertCommitment(
            msgUID: "cancel", chatUsername: "chat", chatName: "ponge",
            content: "取消的", commitTo: "哆啦",
            deadlineAt: now.addingTimeInterval(-86_400), confidence: 0.9,
            promptVersion: "test", createdAt: now
        )

        try store.updateCommitmentStatus(msgUID: "done", status: .fulfilled)
        try store.updateCommitmentStatus(msgUID: "cancel", status: .cancelled)
        let after = store.loadCommitments(relevantSince: cutoff)
        let active = after.filter { CommitmentPresentation.matches($0, filter: .active) }
        XCTAssertEqual(active.map(\.msgUID), ["keep"])
        XCTAssertEqual(after.first { $0.msgUID == "done" }?.status, .fulfilled)
        XCTAssertTrue(CommitmentPresentation.matches(after.first { $0.msgUID == "done" }!, filter: .fulfilled))
        let cancelled = try XCTUnwrap(after.first { $0.msgUID == "cancel" })
        XCTAssertFalse(CommitmentPresentation.isOverdue(cancelled, now: now))
        XCTAssertFalse(CommitmentPresentation.matches(cancelled, filter: .overdue, now: now))

        try store.updateCommitmentStatus(msgUID: "done", status: .pending)
        try store.updateCommitmentStatus(msgUID: "cancel", status: .pending)
        let undone = store.loadCommitments(relevantSince: cutoff)
        XCTAssertEqual(
            undone.filter { CommitmentPresentation.matches($0, filter: .active) }.map(\.msgUID).sorted(),
            ["cancel", "done", "keep"]
        )
    }

    func testPendingAskLiveWindowMatchesDiscussionSourceOrDue() {
        let now = Date(timeIntervalSince1970: 1_778_000_000)
        let cutoff = DiscussionLiveWindow.cutoff(days: 14, now: now)
        func ask(createdOffset: Int, dueOffset: Int?) -> PendingAsk {
            PendingAsk(
                id: 0, msgUID: "a", chatUsername: "c", chatName: "C", senderName: "S",
                rawText: "x", summary: "x", askType: .none,
                deadlineAt: dueOffset.map { Date(timeIntervalSince1970: TimeInterval(cutoff + $0)) },
                confidence: 0.9, bucket: .main, status: .pending, promptVersion: "t",
                createdAt: Date(timeIntervalSince1970: TimeInterval(cutoff + createdOffset)),
                updatedAt: now, senderLevel: nil, senderRole: nil, urgency: nil
            )
        }
        XCTAssertTrue(DiscussionLiveWindow.contains(ask(createdOffset: 3600, dueOffset: nil), cutoff: cutoff))
        XCTAssertFalse(DiscussionLiveWindow.contains(ask(createdOffset: -20 * 86_400, dueOffset: nil), cutoff: cutoff))
       XCTAssertTrue(DiscussionLiveWindow.contains(ask(createdOffset: -20 * 86_400, dueOffset: 86_400), cutoff: cutoff))
   }
    func testTodayFeedCountsMatchReplyQueueAndLiveTodosNotFYIOrHandled() {
        func inbox(
            _ id: String,
            actionRequired: Bool,
            isGroup: Bool = false,
            isAtMention: Bool = false,
            isVIP: Bool = false,
            status: InboxStatus = .active
        ) -> InboxItem {
            var item = InboxItem(
                id: id, chatUsername: id, chatName: id, senderName: "对方",
                preview: "请确认", isGroup: isGroup, timestamp: Date(),
                actionRequired: actionRequired, priority: .p1, isVIP: isVIP,
                isWhitelisted: true, unreadCount: 1, isAtMention: isAtMention,
                askType: .none, reasons: [], suggestedReplyMinutes: 60,
                status: status, dismissedAtMsgId: nil
            )
            if status != .active { item.replied = status == .dismissed }
            return item
        }
        let action = inbox("alice", actionRequired: true)
        let fyi = inbox("room@chatroom", actionRequired: false, isGroup: true, isAtMention: true)
        let passive = inbox("bob", actionRequired: false)
        var handled = inbox("done", actionRequired: true, status: .dismissed)
        handled.status = .dismissed
        handled.silenced = true
        var snoozed = inbox("later", actionRequired: true, status: .snoozed)
        snoozed.status = .snoozed

        XCTAssertEqual(fyi.messageType, .groupMentionFYI)
        XCTAssertFalse(fyi.participatesInActionQueue)
        XCTAssertEqual(TodayFeed.needsReply([action, fyi, passive, handled, snoozed]).map(\.id), ["alice"])
        XCTAssertEqual(TodayFeed.allUpdatesCount([action, fyi, passive]), 3)
        XCTAssertTrue(TodayFeed.hasNonReplyUpdates([action, fyi, passive]))
        XCTAssertFalse(TodayFeed.hasNonReplyUpdates([action]))

        let now = Date()
        func task(_ id: Int64, owner: DiscussionItemOwner, kind: DiscussionItemKind = .todo, status: DiscussionItemStatus = .pending) -> DiscussionItem {
            DiscussionItem(id: id, chatUsername: "chat", chatName: "项目群", kind: kind, owner: owner, content: "验收", detail: nil, anchorMsgUID: "\(id)", sourceTimestamp: 100, dueAt: nil, status: status, confidence: 0.9, promptVersion: "test", createdAt: now, updatedAt: now)
        }
        let discussions = [
            task(1, owner: .mine),
            task(2, owner: .theirs),
            task(3, owner: .shared),
            task(4, owner: .mine, kind: .info),
            task(5, owner: .mine, status: .done),
            task(6, owner: .theirs, status: .archived)
        ]
        XCTAssertEqual(TodayFeed.mineTasks(discussions).map(\.id), [1])
        XCTAssertEqual(TodayFeed.waitingTasks(discussions).map(\.id), [2])
        XCTAssertEqual(TodayFeed.mineTasks(discussions).count, WorkspaceBadgeCounts.taskCount(discussions))
        XCTAssertTrue(TodayFeed.hasOpenWork(mine: [], waiting: TodayFeed.waitingTasks(discussions), upcoming: []))
        XCTAssertFalse(TodayFeed.hasOpenWork(mine: [], waiting: [], upcoming: []))
    }

    private func workspaceCommitment(
        id: Int64,
        content: String = "确认时间",
        deadline: Date? = nil,
        status: CommitmentStatus = .pending,
        label: String = "",
        source: String = "",
        created: Date
    ) -> Commitment {
        Commitment(
            id: id,
            msgUID: "\(id)",
            chatUsername: "chat",
            chatName: "ponge",
            content: content,
            commitTo: "哆啦",
            deadlineAt: deadline,
            confidence: 0.9,
            status: status,
            promptVersion: "t",
            createdAt: created,
            updatedAt: created,
            sourceText: source,
            deadlineLabel: label
        )
    }
}
