import XCTest
@testable import WeChatHUD

final class InsightChatIdentityTests: XCTestCase {
    func testUsernamePassesThrough() {
        XCTAssertEqual(
            InsightChatIdentity.resolve("wxid_alice", names: ["wxid_alice": "Alice"]),
            "wxid_alice"
        )
    }

    func testUniqueDisplayNameMapsToUsername() {
        XCTAssertEqual(
            InsightChatIdentity.resolve("项目群", names: ["project@chatroom": "项目群"]),
            "project@chatroom"
        )
    }

    func testDuplicateDisplayNameDoesNotGuess() {
        XCTAssertNil(
            InsightChatIdentity.resolve(
                "张三",
                names: ["wxid_a": "张三", "wxid_b": "张三"]
            )
        )
    }

    func testUnknownOrBlankDoesNotInventAnID() {
        XCTAssertNil(InsightChatIdentity.resolve("不存在的人", names: ["wxid_alice": "Alice"]))
        XCTAssertNil(InsightChatIdentity.resolve("  ", names: ["wxid_alice": "Alice"]))
        XCTAssertNil(InsightChatIdentity.resolve("全局", names: [:]))
    }

    func testBriefingJSONDoesNotNeedAUsernameField() throws {
        let json = """
        {"source":"项目群","what":"确认周报口径","urgency":"高"}
        """.data(using: .utf8)!
        let item = try JSONDecoder().decode(ActionRequiredItem.self, from: json)
        XCTAssertEqual(item.source, "项目群")
        XCTAssertNil(item.chatUsername)
    }

    func testBindingChatUsernamesUsesUniqueDisplayName() {
        let briefing = GlobalBriefing(
            date: "2026-09-22",
            actionRequired: [
                ActionRequiredItem(source: "项目群", what: "确认周报口径", urgency: "高")
            ],
            headline: "有事项",
            stats: BriefingStats(
                totalMessages: 1, myMessages: 0, activeGroups: 1,
                totalGroups: 1, activePrivateChats: 0, workRatio: 0
            ),
            crossTopics: [],
            darkSignals: DarkSignals(headline: nil),
            overallMood: "紧张",
            blindSpots: [],
            topSuggestion: "先回项目群"
        )
        let bound = briefing.bindingChatUsernames(names: ["project@chatroom": "项目群"])
       XCTAssertEqual(bound.actionRequired.first?.chatUsername, "project@chatroom")
       XCTAssertEqual(bound.actionRequired.first?.source, "项目群")
   }

    func testInsightLoaderDoesNotTreatAnUnreadableFollowListAsNobody() throws {
        let loader = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/WeChatHUD/Services/Insight/InsightDataLoader.swift"),
            encoding: .utf8)
        XCTAssertTrue(loader.contains("whitelistAllRead"))
        XCTAssertTrue(loader.contains("storedDisplayName"))
        XCTAssertTrue(loader.contains("visibleName"))
       XCTAssertFalse(loader.contains("store.getWhitelist()"))
   }

    func testRadarAndInsightViewsDoNotEchoUsernameWhenTheNameMapMisses() throws {
        let radar = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/WeChatHUD/Services/Insight/InsightRadar.swift"),
            encoding: .utf8)
        XCTAssertFalse(radar.contains("names[username] ?? username"))
        XCTAssertTrue(radar.contains("visibleName"))

        let sidebar = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/WeChatHUD/Views/Analytics/InsightSidebarView.swift"),
            encoding: .utf8)
       XCTAssertTrue(sidebar.contains("暂时读不到关注名单"))
       XCTAssertTrue(sidebar.contains("isFollowListUnreadable"))
        XCTAssertTrue(sidebar.contains("whitelistAllRead"))
        XCTAssertFalse(sidebar.contains("getWhitelist()"))
        XCTAssertTrue(sidebar.contains("avatarMonogram"))
        XCTAssertTrue(sidebar.contains("visibleTitle"))
       XCTAssertFalse(sidebar.contains("entry.displayName.prefix(1)"))
   }

    @MainActor
    func testAnalyzeOneChatDoesNotCallAFollowedChatUnfollowedWhenTheListIsUnreadable() async throws {
        let path = NSTemporaryDirectory() + "insight-follow-\(UUID().uuidString).sqlite3"
        let store = HUDStore(dbPath: path)
        try store.open()
        defer {
            store.close()
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
        }
        try store.addToWhitelist(username: "wxid_boss", displayName: "老板",
                                 isGroup: false, category: .work)
        let reader = WeChatReader(dbDir: "/tmp/insight-follow-\(UUID().uuidString)", cacheStrategy: .memory)
        let coordinator = InsightCoordinator(reader: reader, store: store, aiService: AIService())
        try store.exec("ALTER TABLE whitelist RENAME TO whitelist_hidden")
        await coordinator.analyzeOneChat(chatUsername: "wxid_boss")
        let error = coordinator.chatInsightErrors["wxid_boss"]
       XCTAssertEqual(error, CompanionInteractionCopy.followListUnreadableAnalysis)
      XCTAssertFalse(error?.contains("不在关注") ?? true)
       XCTAssertFalse(coordinator.chatInsightLoading.contains("wxid_boss"),
                      "名单读失败不能进「正在分析…」忙碌态")
  }

    @MainActor
    func testDateChangeDoesNotWipeYesterdayToReprintTheFollowListError() async throws {
        let path = NSTemporaryDirectory() + "insight-date-\(UUID().uuidString).sqlite3"
        let store = HUDStore(dbPath: path)
        try store.open()
        defer {
            store.close()
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
        }
        try store.addToWhitelist(username: "wxid_boss", displayName: "老板",
                                 isGroup: false, category: .work)
        let reader = WeChatReader(dbDir: "/tmp/insight-date-\(UUID().uuidString)", cacheStrategy: .memory)
        let coordinator = InsightCoordinator(reader: reader, store: store, aiService: AIService())
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        coordinator.seedPreviewResult(chatUsername: "wxid_boss", date: yesterday, result: Self.sampleInsight(headline: "昨天的分析"))
        try store.exec("ALTER TABLE whitelist RENAME TO whitelist_hidden")
        await coordinator.analyzeOneChatOnDateChange(chatUsername: "wxid_boss", date: Date())
        XCTAssertEqual(coordinator.chatInsightErrors["wxid_boss"],
                       CompanionInteractionCopy.followListUnreadableAnalysis)
        XCTAssertFalse(coordinator.chatInsightLoading.contains("wxid_boss"))
        XCTAssertEqual(coordinator.result(for: "wxid_boss", date: yesterday)?.headline, "昨天的分析",
                       "换日期读失败不能把昨天已经出的分析清掉")
       XCTAssertNil(coordinator.result(for: "wxid_boss", date: Date()))
   }

    @MainActor
    func testSelectingAnotherChatDoesNotStartAnalysisWhenFollowListIsUnreadable() async throws {
        let path = NSTemporaryDirectory() + "insight-switch-\(UUID().uuidString).sqlite3"
        let store = HUDStore(dbPath: path)
        try store.open()
        defer {
            store.close()
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
        }
        try store.addToWhitelist(username: "wxid_peer", displayName: "同事",
                                 isGroup: false, category: .work)
        let reader = WeChatReader(dbDir: "/tmp/insight-switch-\(UUID().uuidString)", cacheStrategy: .memory)
        let coordinator = InsightCoordinator(reader: reader, store: store, aiService: AIService())
        coordinator.seedPreviewResult(chatUsername: "wxid_peer", date: Date(), result: Self.sampleInsight(headline: "已有的分析"))
        try store.exec("ALTER TABLE whitelist RENAME TO whitelist_hidden")
        await coordinator.analyzeOneChatIfFollowed(chatUsername: "wxid_peer", date: Date())
        XCTAssertEqual(coordinator.chatInsightErrors["wxid_peer"],
                       CompanionInteractionCopy.followListUnreadableAnalysis)
        XCTAssertFalse(coordinator.chatInsightLoading.contains("wxid_peer"))
        XCTAssertEqual(coordinator.result(for: "wxid_peer", date: Date())?.headline, "已有的分析",
                      "侧栏切人读失败不能把已经出的分析清掉")
   }

    @MainActor
    func testResumeAfterFollowDoesNotKeepTheNotFollowedError() async throws {
        let path = NSTemporaryDirectory() + "insight-resume-\(UUID().uuidString).sqlite3"
        let store = HUDStore(dbPath: path)
        try store.open()
        defer {
            store.close()
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
        }
        let reader = WeChatReader(dbDir: "/tmp/insight-resume-\(UUID().uuidString)", cacheStrategy: .memory)
        let coordinator = InsightCoordinator(reader: reader, store: store, aiService: AIService())
        await coordinator.analyzeOneChatIfFollowed(chatUsername: "wxid_new", date: Date())
        XCTAssertEqual(coordinator.chatInsightErrors["wxid_new"], CompanionInteractionCopy.notOnFollowList)
        try store.addToWhitelist(username: "wxid_new", displayName: "新同事",
                                 isGroup: false, category: .work)
        await coordinator.resumeInsightChatIfNeeded(chatUsername: "wxid_new", date: Date())
        XCTAssertNotEqual(coordinator.chatInsightErrors["wxid_new"], CompanionInteractionCopy.notOnFollowList,
                          "加完关注回到洞察时，不能还停在「不在关注列表中」")
        XCTAssertFalse(coordinator.chatInsightLoading.contains("wxid_new"))
    }

    @MainActor
    func testResumeKeepsAnExistingResult() async throws {
        let path = NSTemporaryDirectory() + "insight-resume-keep-\(UUID().uuidString).sqlite3"
        let store = HUDStore(dbPath: path)
        try store.open()
        defer {
            store.close()
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
        }
        try store.addToWhitelist(username: "wxid_peer", displayName: "同事",
                                 isGroup: false, category: .work)
        let reader = WeChatReader(dbDir: "/tmp/insight-resume-keep-\(UUID().uuidString)", cacheStrategy: .memory)
        let coordinator = InsightCoordinator(reader: reader, store: store, aiService: AIService())
        coordinator.seedPreviewResult(chatUsername: "wxid_peer", date: Date(), result: Self.sampleInsight(headline: "留下"))
        await coordinator.resumeInsightChatIfNeeded(chatUsername: "wxid_peer", date: Date())
        XCTAssertEqual(coordinator.result(for: "wxid_peer", date: Date())?.headline, "留下")
        XCTAssertFalse(coordinator.chatInsightLoading.contains("wxid_peer"))
    }

  private static func sampleInsight(headline: String) -> ChatInsightResult {
        ChatInsightResult(
            headline: headline, topics: [], decisions: [], actionItems: [],
            mentionsMe: 0, waitingForMe: [], myCommitments: [], needsMyAttention: false,
            overallMood: "正常", signalNoiseRatio: 0.8, decisionEfficiency: "正常",
            importanceToMe: ImportanceLevel(level: "中", reason: "测试"),
            crossChatTopics: nil, insight: "测试", suggestion: "测试"
        )
    }

    func testCoordinatorDoesNotTreatAnUnreadableFollowListAsNobody() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/WeChatHUD/Services/Insight/InsightCoordinator.swift"),
            encoding: .utf8)
        XCTAssertFalse(source.contains("store.getWhitelist()"))
        XCTAssertTrue(source.contains("whitelistEntryRead"))
       XCTAssertTrue(source.contains("whitelistAllRead"))
      XCTAssertTrue(source.contains("followListUnreadableAnalysis"))
        let analyze = source.components(separatedBy: "func analyzeOneChat").last ?? ""
        let beforeLoading = analyze.components(separatedBy: "chatInsightLoading.insert").first ?? ""
       XCTAssertTrue(beforeLoading.contains("whitelistEntryRead"),
                     "busy/loading must not start before the follow-list read")
        XCTAssertTrue(source.contains("analyzeOneChatOnDateChange"))
   }

    func testInsightDetailRetryMatchesTheFollowListError() throws {
        let detail = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/WeChatHUD/Views/Analytics/ChatInsightDetailView.swift"),
            encoding: .utf8)
        XCTAssertTrue(detail.contains("followListUnreadableAnalysis"))
        XCTAssertTrue(detail.contains("return \"再试一次\""))
        XCTAssertTrue(detail.contains("先重读关注名单，再分析这段聊天"))
        XCTAssertTrue(detail.contains("notOnFollowList"))
       XCTAssertTrue(detail.contains("去关注谁"))
       XCTAssertTrue(detail.contains("analyzeActionTitle"))
        XCTAssertTrue(detail.contains("analyzeActionIsPrimary"))
       XCTAssertTrue(detail.contains("headerAnalyzeButton"))
       XCTAssertTrue(detail.contains("CompanionPressStyle()"))
       XCTAssertTrue(detail.contains("insightSelectedChatUsername"))
       XCTAssertTrue(detail.contains("pendingSettingsTab = \"contacts\""))
        let originalChunks = detail.components(separatedBy: "Button(\"查看原文\")")
        XCTAssertGreaterThanOrEqual(originalChunks.count - 1, 3)
        for chunk in originalChunks.dropFirst() {
            let window = String(chunk.prefix(220))
            XCTAssertTrue(window.contains("CompanionPressStyle()"), window)
            XCTAssertFalse(window.contains("buttonStyle(.plain)"), window)
        }
   }

    func testDateChangeDoesNotClearInsightsBeforeRereadingTheFollowList() throws {
        let page = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/WeChatHUD/Views/Analytics/ChatInsightView.swift"),
            encoding: .utf8)
       let onDate = page.components(separatedBy: "onChange(of: selectedDate)").last ?? ""
       XCTAssertFalse(onDate.contains("chatInsights.removeValue"))
       XCTAssertTrue(onDate.contains("analyzeOneChatOnDateChange"))
        let onSelect = page.components(separatedBy: "onAnalyzeChat:").last ?? ""
       XCTAssertTrue(onSelect.contains("analyzeOneChatIfFollowed"))
       XCTAssertFalse(onSelect.contains("monitor.analyzeOneChat(chatUsername"))
       XCTAssertTrue(page.contains("insightSelectedChatUsername"))
       XCTAssertTrue(page.contains("resumeInsightChatIfNeeded"))
   }

    @MainActor
    func testFollowingTheResumeChatReturnsToInsight() {
        let state = PanelState()
        state.insightSelectedChatUsername = "wxid_new"
        state.returnToInsightIfResuming("wxid_other", receipt: "已添加关注：别人")
        XCTAssertNil(state.pendingSettingsTab, "加别人的关注不该把人拽回洞察")
        XCTAssertNil(state.toastMessage, "别人的回执不该出现")
        state.returnToInsightIfResuming("wxid_new", receipt: "已添加关注：新同事")
        XCTAssertEqual(state.pendingSettingsTab, "insight")
        XCTAssertEqual(state.toastMessage, "已添加关注：新同事")
    }

    func testContactsSaveReturnsToInsightWhenResuming() throws {
        let contacts = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/WeChatHUD/Views/Settings/ContactsSettingsView.swift"),
            encoding: .utf8)
        XCTAssertTrue(contacts.contains("returnToInsightIfResuming"))
        XCTAssertTrue(contacts.contains("receipt:"))
        XCTAssertTrue(contacts.contains("已添加关注："))
        XCTAssertTrue(contacts.contains("CompanionInteractionCopy.followLevelChanged"))
        XCTAssertTrue(contacts.contains("announce: true"))
        let saveFn = contacts.components(separatedBy: "func saveContact").last ?? ""
        let saveOnly = saveFn.components(separatedBy: "func deleteContact").first ?? saveFn
        XCTAssertTrue(saveOnly.contains("receipt:"))
        XCTAssertFalse(saveOnly.contains("已添加关注"), "级别变更不得复用添加关注回执")
        let editor = contacts.components(separatedBy: "struct ContactEditSheet").last ?? ""
        XCTAssertTrue(editor.contains("CompanionInteractionCopy.contactSettingsSaved"))
        XCTAssertTrue(editor.contains("saveError"))
        XCTAssertTrue(editor.contains("showToast(receipt)"))
        XCTAssertFalse(editor.contains("已添加关注"), "编辑保存回跳不得复用添加关注回执")
        let scan = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/WeChatHUD/Views/WhitelistScanView.swift"),
            encoding: .utf8)
        XCTAssertTrue(scan.contains("returnToInsightIfResuming"))
        XCTAssertTrue(scan.contains("receipt:"))
        XCTAssertTrue(scan.contains("已添加关注："))
        XCTAssertTrue(scan.contains("已从忽略列表添加关注："))
    }

    func testOtherRecentChatsUseTheSameFollowListGate() throws {
        let sidebar = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/WeChatHUD/Views/Analytics/InsightSidebarView.swift"),
            encoding: .utf8)
        let otherRow = sidebar.components(separatedBy: "private func otherSessionRow").last ?? ""
        XCTAssertTrue(otherRow.contains("onAnalyzeChat(session.id)"),
                      "其他最近聊天 must not skip the follow-list gate")
        let page = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/WeChatHUD/Views/Analytics/ChatInsightView.swift"),
            encoding: .utf8)
       let detailChat = page.components(separatedBy: "private var detailChat").last ?? ""
        let resolver = detailChat.components(separatedBy: "func visibleTitle").first ?? ""
        XCTAssertTrue(resolver.contains("case .unreadable:"))
        XCTAssertTrue(resolver.contains("otherActiveSessions"),
                     "名单读失败时，其他最近聊天仍要用会话自己的名字")
    }
}
