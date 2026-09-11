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
