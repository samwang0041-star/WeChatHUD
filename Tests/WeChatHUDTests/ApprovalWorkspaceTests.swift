import XCTest
@testable import WeChatHUD

final class ApprovalWorkspaceTests: XCTestCase {
    func testCanApproveWithoutRunningSession() {
        XCTAssertTrue(ChatMonitor.canApproveWithoutRunningSession())
    }

    func testPendingSendsNeedingHumanWhenAutoSendOffShowsEntireQueue() {
        let ready = pendingSend(id: UUID(), reason: nil)
        let held = pendingSend(id: UUID(), reason: "需人工确认")
        let shown = ApprovalWorkspacePolicy.pendingSendsNeedingHuman(
            [ready, held],
            autoSendEnabled: false
        )
        XCTAssertEqual(shown.map(\.id), [ready.id, held.id])
    }

    func testPendingSendsNeedingHumanWhenAutoSendOnShowsOnlyManualHolds() {
        let ready = pendingSend(id: UUID(), reason: nil)
        let held = pendingSend(id: UUID(), reason: "回复含敏感词「密码」，请人工确认")
        let shown = ApprovalWorkspacePolicy.pendingSendsNeedingHuman(
            [ready, held],
            autoSendEnabled: true
        )
        XCTAssertEqual(shown.map(\.id), [held.id])
    }

    func testAutopilotLogEntryIdentityUsesDatabaseIdNotTriggerUID() {
        let first = logEntry(id: 11, triggerMsgUID: "proactive")
        let second = logEntry(id: 12, triggerMsgUID: "proactive")
        XCTAssertEqual(first.id, 11)
        XCTAssertEqual(second.id, 12)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(first.triggerMsgUID, second.triggerMsgUID)
    }

    /// The row still being shown is the only one a receipt may land on.
    func testReceiptBelongsToTheRowOnScreen() {
        XCTAssertTrue(ApprovalWorkspacePolicy.receiptStillOnScreen(actionedRowID: 7, displayedRowID: 7))
        XCTAssertFalse(ApprovalWorkspacePolicy.receiptStillOnScreen(actionedRowID: 7, displayedRowID: 8),
                       "换行了还挂旧回执 = 在 B 的详情下打勾说「本条已取消」")
        XCTAssertFalse(ApprovalWorkspacePolicy.receiptStillOnScreen(actionedRowID: 7, displayedRowID: nil),
                       "这一栏已经空了，回执没有归属")
    }

    /// The detail pane shows `entries.first` whenever the stored selection has
    /// left the list — which is exactly what a successful cancel does to its own
    /// row. So the gate has to be handed the *displayed* row; the stored
    /// `selectedID` still names the vanished one and would post under a stranger.
    func testReceiptGateReadsTheDisplayedRowNotTheStoredSelection() throws {
        let view = try String(contentsOf: sourceRoot.appendingPathComponent(
            "Views/ApprovalWorkspaceView.swift"), encoding: .utf8)
        let definitionStart = try XCTUnwrap(view.range(of: "private func postReceipt(")).lowerBound
        let body = view[definitionStart...]
            .components(separatedBy: "\n    }\n").first ?? ""
        XCTAssertTrue(body.contains("displayedRowID: selected?.id"),
                      "串位守卫要的是详情窗此刻显示的那一行")
        XCTAssertFalse(body.contains("displayedRowID: selectedID"),
                       "又去读那个存着的选中 id：它指着一行已经不存在的旧选中")

        for dead in ["receipt = .done(\"已保存草稿\")",
                     "receipt = .problem(\"草稿没有保存，请重试。\")",
                     "receipt = .done(\"已取消本条，对应的待发草稿已一并移除。\")",
                     "receipt = .done(CompanionProductCopy.sendSuccess(name: selected.chatName)",
                     "receipt = .problem(CompanionProductCopy.sendUncertain)"] {
            XCTAssertFalse(view.contains(dead), "绕过守卫的直写回来了：\(dead)")
        }
        XCTAssertEqual(view.components(separatedBy: "postReceipt(").count - 1, 8,
                       "详情窗的每一次回执都要过守卫（1 处定义 + 7 处调用）")
    }

    /// 「取消本条」 used to have no latch at all, so a double tap started two
    /// cancels over the same row — unlike 确认发送, which guards on `isSending`.
    func testCancelButtonLatchesLikeConfirmSendDoes() throws {
        let view = try String(contentsOf: sourceRoot.appendingPathComponent(
            "Views/ApprovalWorkspaceView.swift"), encoding: .utf8)
        let buttonStart = try XCTUnwrap(view.range(of: "Button(\"取消本条\")")).lowerBound
        let pieces = view[buttonStart...].components(separatedBy: ".buttonStyle(.bordered)")
        let button = pieces.first ?? ""
        XCTAssertTrue(button.contains("guard !isCancelling else { return }"))
        XCTAssertTrue(button.contains("isCancelling = true"))
        XCTAssertTrue(button.contains("defer { isCancelling = false }"),
                      "闩只在任务开始时放、不在结束时收，等于第二次永远点不动")
        let afterStyle = pieces.count > 1 ? pieces[1] : ""
        XCTAssertTrue(afterStyle.prefix(80).contains(".disabled(isCancelling)"),
                      "闩没有接到这颗按钮上：点下去以后还是能再点一次")
    }

    private var sourceRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/WeChatHUD")
    }

    @MainActor
    func testEnsureAutopilotReadyForSendCreatesServiceWithoutEnablingAutoSend() async throws {
        let root = NSTemporaryDirectory() + "approval-workspace-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let store = HUDStore(dbPath: root + "/hud.sqlite3")
        try store.open()
        let reader = WeChatReader(
            keysPath: root + "/absent-keys.json",
            dbDir: root + "/synthetic/db_storage",
            cacheStrategy: .memory
        )
        let monitor = ChatMonitor(reader: reader, store: store, aiService: AIService(config: AIConfig()))
        defer {
            monitor.stopAutopilot()
            store.close()
            try? FileManager.default.removeItem(atPath: root)
        }

        XCTAssertNil(monitor.autopilotService)
        XCTAssertFalse(monitor.autopilotActive)
        XCTAssertFalse((store.getSettingJSON("autopilot", as: AutopilotConfig.self) ?? AutopilotConfig()).autoSendEnabled)

        let service = await monitor.ensureAutopilotReadyForSend()
        XCTAssertNotNil(service, "确认发送 must prepare a service when autopilot was never started")
        let prepared = try XCTUnwrap(service)
        let becameActive = await prepared.isActive
        XCTAssertTrue(becameActive)
        XCTAssertTrue(monitor.autopilotActive)
        XCTAssertFalse((store.getSettingJSON("autopilot", as: AutopilotConfig.self) ?? AutopilotConfig()).autoSendEnabled)

        let firstSession = store.currentAutopilotSession()?.id
        let again = await monitor.ensureAutopilotReadyForSend()
        XCTAssertNotNil(again)
        XCTAssertEqual(store.currentAutopilotSession()?.id, firstSession)
        XCTAssertFalse((store.getSettingJSON("autopilot", as: AutopilotConfig.self) ?? AutopilotConfig()).autoSendEnabled)
    }

    private func pendingSend(id: UUID, reason: String?) -> PendingSend {
        PendingSend(
            id: id,
            chatUsername: "wxid_a",
            chatName: "A",
            senderName: "A",
            replyText: "好的",
            confidence: 0.9,
            risk: .low,
            reasoning: "ok",
            styleScore: 80,
            scheduledSendTime: Date().addingTimeInterval(30),
            manualOnlyReason: reason
        )
    }

    private func logEntry(id: Int64, triggerMsgUID: String) -> AutopilotLogEntry {
        AutopilotLogEntry(
            id: id,
            sessionId: 1,
            chatUsername: "wxid_a",
            chatName: "A",
            senderUsername: "wxid_b",
            senderName: "B",
            triggerMsgUID: triggerMsgUID,
            triggerText: "在吗",
            generatedReply: "稍等",
            confidence: 0.8,
            riskLevel: .low,
            action: .pending,
            aiReasoning: "proactive",
            sentAt: nil,
            createdAt: Date()
        )
    }
}
