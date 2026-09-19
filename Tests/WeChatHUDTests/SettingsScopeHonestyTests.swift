import XCTest
@testable import WeChatHUD

/// The AI generation sliders and the auto-install switch both describe a
/// scope wider than the code implements. These gates hold the copy and the
/// call sites together: if someone later wires `maxTokens`/`temperature`
/// through to 摘要 and 草稿, the second test goes red and forces the label to
/// be re-read — which is the point, because right now the label is only true
/// of the tasks that pass no options at all.
final class SettingsScopeHonestyTests: XCTestCase {
    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    func testGenerationSlidersDoNotClaimToShapeSummariesAndDrafts() throws {
        let view = try source("Sources/WeChatHUD/Views/Settings/AISettingsView.swift")
        XCTAssertFalse(
            view.contains("这是平时写摘要和草稿的习惯"),
            "旧文案把两个滑杆说成摘要与草稿的习惯，而这两条路径都传了固定参数")
        XCTAssertTrue(view.contains("摘要和草稿各有固定写法"),
                      "必须点名哪两条不受影响")
        XCTAssertFalse(
            view.contains("写摘要和草稿时多想一会儿"),
            "思考开关对要 JSON 输出的草稿是强制关闭的，不能再说草稿")
    }

    /// The other half of the same promise: the copy is only honest while those
    /// two call sites really do pass literals.
    func testSummaryAndDraftStillPinTheirOwnGenerationOptions() throws {
        let summarizer = try source("Sources/WeChatHUD/Services/AIInboxSummarizer.swift")
        let suggester = try source("Sources/WeChatHUD/Services/AIReplySuggester.swift")
        XCTAssertTrue(summarizer.contains("temperature: 0.1"),
                      "摘要不再固定参数 ⇒ 上面的文案要重写，而不是让这条测试静默过期")
        XCTAssertTrue(suggester.contains("temperature: 0.4"),
                      "草稿不再固定参数 ⇒ 同上")
        XCTAssertTrue(suggester.contains("responseFormatJSON: true"),
                      "草稿靠 JSON 格式强制关闭思考，思考开关的文案以此为前提")
    }

    /// 「不是聊天原文」 was false: the same function writes each 待回复 row's
    /// preview and the first 50 characters of a message the peer retracted. A
    /// caption that denies what the file contains is worse than no caption — it
    /// is the sentence the user relies on when deciding to leave the file on a
    /// shared machine.
    func testExportCaptionMatchesWhatTheFileHolds() throws {
        XCTAssertTrue(LocalDataRetrospection.exportCaption.contains("原文片段"),
                      LocalDataRetrospection.exportCaption)
        XCTAssertFalse(LocalDataRetrospection.exportCaption.contains("不是聊天原文"))
        let report = try source("Sources/WeChatHUD/Services/ChatMonitor+DailyReport.swift")
        XCTAssertTrue(report.contains("item.preview"), "caption promises previews; the export must still write them")
        XCTAssertTrue(report.contains("r.originalText.prefix(50)"), "same for the retracted-text line")
    }

    /// The 0600 rule was stated in one export function's comment and broken by
    /// its sibling two lines away — the 日报 page's own button wrote 0644.
    ///
    /// This test existed and was green while `makeExportPrivate` was
    /// `try? setAttributes(...)` with the result thrown away and both callers
    /// returned the URL regardless: the assertion below only ever proved the
    /// success path on this machine, never that a *failed* chmod is reported.
    /// `PrivateExportTests` carries the failure half now.
    @MainActor
    func testBothExportPathsMakeTheFilePrivate() throws {
        let report = try source("Sources/WeChatHUD/Services/ChatMonitor+DailyReport.swift")
        XCTAssertEqual(
            report.components(separatedBy: "Self.writePrivateExport(").count - 1, 2,
            "两个导出函数各自都要走先写后收紧的那一个入口（日报页是 exportDailyReport）"
        )

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wchud-export-perm-\(UUID().uuidString).md")
        try "x".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(ChatMonitor.makeExportPrivate(url: url),
                      "收紧成功要由读回来的权限说话，不是由调用没抛错说话")
        let mode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        ).uint16Value
        XCTAssertEqual(mode & 0o777, 0o600, String(format: "0%o", mode))
    }

    /// The island's empty state borrowed the 今日 page's sentence, which points
    /// at a layout that only exists there (「答应过的事在右侧」、两个 tab 名), and it
    /// hardcoded the two AI flags plus the open-work flags, so three of
    /// `todayEmpty`'s branches were unreachable from the island.
    func testIslandEmptyStateSaysOnlyWhatTheIslandCanSee() throws {
        let view = try source("Sources/WeChatHUD/Views/InboxView.swift")
        let detail = try XCTUnwrap(
            view.range(of: "private var islandEmptyDetail: String?").map { view[$0.lowerBound...] }
        ).components(separatedBy: "private var islandStatusBannerShowsCopy").first ?? ""
        XCTAssertFalse(detail.contains("FirstLaunchGuide.todayEmpty"), "岛又去借今日页那句话了")
        XCTAssertFalse(detail.contains("右侧"), "岛上没有左右栏")
        XCTAssertFalse(detail.contains("我要做"), "那是待办页的 tab 名")
        XCTAssertFalse(detail.contains("aiConfigured: true") || detail.contains("aiTested: true"))
        XCTAssertTrue(detail.contains("hasOpenWorkForIsland"), "有待办时不能再报『没有待处理的事』")
        XCTAssertTrue(detail.contains("aiReadiness"), "AI 未配置要在岛上说得出")
    }

    func testAutoInstallStatesWhenItCanFire() throws {
        let view = try source("Sources/WeChatHUD/Views/Settings/AppUpdateSettingsView.swift")
        let controller = try source("Sources/WeChatHUD/Services/AppUpdateController.swift")
        // The only `installIfEnabled: true` call is the launch check, and that
        // one is behind `autoCheckEnabled`.
        let launchOnly = controller.components(separatedBy: "installIfEnabled: true").count - 1
        XCTAssertEqual(launchOnly, 1, "自动安装多了一个入口，就要重新核对面上的说法")
        XCTAssertTrue(view.contains("启动时的自动检查"),
                      "「发现后自动安装」不说明只在启动检查生效，用户点手动检查会以为它坏了")
    }

    /// 「接收待办提醒与重要更新。」 is a promise this app cannot keep on its own,
    /// and it stayed on the page while macOS had notifications denied. The
    /// status-specific sentence already existed on the same page
    /// (`notificationExplanation`) and nothing rendered it.
    func testNotificationRowSaysWhatTheSystemAllows() throws {
        let view = try source("Sources/WeChatHUD/Views/Settings/MacExperienceSettingsView.swift")
        let scope = view.components(separatedBy: "SettingsRow(\"系统通知\"").last?
            .components(separatedBy: "SettingsRowDivider()").first ?? ""
        XCTAssertFalse(scope.isEmpty, "找不到系统通知那一行，这条判据不能零命中")
        XCTAssertTrue(scope.contains("subtitle: notificationExplanation"),
                      "这一行要跟着真实授权状态说，不能只说好处")
        XCTAssertFalse(scope.contains("接收待办提醒与重要更新"), "被拒时这句话是假的")
        XCTAssertEqual(view.components(separatedBy: "notificationExplanation").count - 1, 2,
                       "一处定义、一处渲染；少一处就说明它又变回了死代码")
        let denied = view.components(separatedBy: "case .denied: return").last?
            .components(separatedBy: "\n").first ?? ""
        XCTAssertTrue(denied.contains("未获允许"), denied)
    }

    /// Both pages write the same record, and both used to do it by reading with
    /// `?? AutopilotConfig()` and writing the whole thing back. The store now
    /// owns that merge, so a page that writes the key itself is a regression of
    /// the exact defect — which is why this is a gate and not a code review note.
    func testAutopilotConfigIsOnlyEverWrittenThroughTheMergingHelper() throws {
        for file in ["Sources/WeChatHUD/Views/Settings/AutopilotSettingsView.swift",
                     "Sources/WeChatHUD/Views/Settings/SettingsView.swift"] {
            let view = try source(file)
            XCTAssertEqual(view.components(separatedBy: "setSettingJSON(\"autopilot\"").count - 1, 0,
                           "\(file) 自己在整条写回托管配置：读失败时会拿默认值盖掉这页没显示的护栏")
            XCTAssertEqual(view.components(separatedBy: "setSetting(\"autopilot\"").count - 1, 0,
                           "\(file) 换了个拼写绕过合并入口，同上")
            XCTAssertGreaterThanOrEqual(
                view.components(separatedBy: "store.updateAutopilotConfig").count - 1, 1,
                "\(file) 一处都没走合并入口，判据不能零命中")
        }
    }

    /// §164 only closed half of it if 载入 still paints defaults: the eight
    /// fields hydrated on appear are the eight `save()` writes back over the
    /// stored record, so a BUSY at onAppear followed by any edit pushes defaults
    /// onto disk — `excludedContacts` emptied, and 自动发送 re-enabled by someone
    /// reading a screen that lied about its own state.
    func testAutopilotPageNeverHydratesFromDefaultsItCouldThenSave() throws {
        let view = try source("Sources/WeChatHUD/Views/Settings/AutopilotSettingsView.swift")
        XCTAssertFalse(view.contains("getSettingJSON(\"autopilot\""),
                       "载入也走三态读：读不到时这一页必须不接受改动")
        XCTAssertTrue(view.contains("loadError = \"读不到"),
                      "三分支里 unreadable 那臂必须真的把页面钉住，光有个 loadError 变量不算")
        XCTAssertTrue(view.contains("guard didLoad, !isHydrating, loadError == nil"),
                      "载入失败之后 save() 必须被挡住，否则合并写只是把屏上的默认值盖回盘")
        XCTAssertTrue(view.contains("重新读取设置"),
                      "拒绝保存要给出出口，不然这一页就卡死了")
    }
}
