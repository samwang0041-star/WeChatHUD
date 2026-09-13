import XCTest
@testable import WeChatHUD

final class LocalDataSettingsContractTests: XCTestCase {
    func testPageSaysHowManyRecordsWereKept() throws {
        let source = try LocalDataSettingsSource.load()
        let dataStart = try XCTUnwrap(source.text.range(of: "private var dataSection"))
        let exportStart = try XCTUnwrap(source.text.range(of: "private var exportReportSection"))
        let pane = String(source.text[dataStart.lowerBound..<exportStart.lowerBound])
        XCTAssertTrue(pane.contains("LocalDataCopy.statusLine"))
        XCTAssertTrue(pane.contains("workspaceTitle()"))
        XCTAssertTrue(source.text.contains("近两周"))
        XCTAssertTrue(source.text.contains("承诺"))
        XCTAssertEqual(LocalDataCopy.statusLine(count: 0), "近两周没有整理过的记录。")
        XCTAssertEqual(LocalDataCopy.statusLine(count: 3), "近两周整理过 3 件事。")
        XCTAssertEqual(SettingsView.Tab.localData.label, "本地资料")
    }

    func testExportWaitsBehindADisclosure() throws {
        let source = try LocalDataSettingsSource.load()
        let dataStart = try XCTUnwrap(source.text.range(of: "private var dataSection"))
        let exportStart = try XCTUnwrap(source.text.range(of: "private var exportReportSection"))
        let pane = String(source.text[dataStart.lowerBound..<exportStart.lowerBound])
        XCTAssertTrue(pane.contains("LocalDataCopy.exportDisclosure"))
        XCTAssertTrue(source.text.contains("还要导出"))
        XCTAssertTrue(pane.contains("DisclosureGroup"))
        let disclosureStart = try XCTUnwrap(pane.range(of: "DisclosureGroup"))
        let firstScreen = String(pane[..<disclosureStart.lowerBound])
        XCTAssertTrue(firstScreen.contains("statusLine"))
        XCTAssertTrue(firstScreen.contains("retrospectionSection"))
        XCTAssertFalse(firstScreen.contains("exportReportSection"))
        XCTAssertTrue(source.text.contains("近两周"))
        XCTAssertTrue(source.text.contains("承诺"))
        XCTAssertEqual(SettingsView.Tab.localData.label, "本地资料")
    }

    func testWindowCaptionSitsOnTheCanvasNotInsideTheCard() throws {
        let source = try LocalDataSettingsSource.load()
        let dataStart = try XCTUnwrap(source.text.range(of: "private var dataSection"))
        let exportStart = try XCTUnwrap(source.text.range(of: "private var exportReportSection"))
        let retroStart = try XCTUnwrap(source.text.range(of: "private var retrospectionSection"))
        let listsStart = try XCTUnwrap(source.text.range(of: "// MARK: - Data lists"))
        let canvas = String(source.text[dataStart.lowerBound..<exportStart.lowerBound])
        let card = String(source.text[retroStart.lowerBound..<listsStart.lowerBound])
        XCTAssertTrue(canvas.contains("windowCaption"))
        XCTAssertTrue(canvas.contains("workspaceMeta()"))
        XCTAssertFalse(card.contains("windowCaption"))
        XCTAssertFalse(card.contains("记录回溯"))
        XCTAssertFalse(card.contains("SettingsSection"))
        XCTAssertTrue(source.text.contains("近两周"))
        XCTAssertTrue(source.text.contains("承诺"))
        XCTAssertEqual(SettingsView.Tab.localData.label, "本地资料")
    }

    func testFilterCopySpeaksLikeAPerson() throws {
        XCTAssertEqual(SyncSettingsView.DataSection.pendingAsks.rawValue, "提问")
        XCTAssertEqual(LocalDataCopy.searchPlaceholder, "找人或内容")
        XCTAssertEqual(LocalDataRetrospection.emptyPendingAsks, "近两周没有记下的提问")
        XCTAssertFalse(LocalDataCopy.searchPlaceholder.contains("联系人"))
        XCTAssertFalse(LocalDataRetrospection.emptyPendingAsks.contains("未处理"))
        let source = try LocalDataSettingsSource.load()
        XCTAssertTrue(source.text.contains("近两周"))
        XCTAssertTrue(source.text.contains("承诺"))
        XCTAssertEqual(SettingsView.Tab.localData.label, "本地资料")
    }

    func testSearchWaitsBehindADisclosure() throws {
        let source = try LocalDataSettingsSource.load()
        let retroStart = try XCTUnwrap(source.text.range(of: "private var retrospectionSection"))
        let listsStart = try XCTUnwrap(source.text.range(of: "// MARK: - Data lists"))
        let card = String(source.text[retroStart.lowerBound..<listsStart.lowerBound])
        XCTAssertTrue(source.text.contains("还要找"))
        XCTAssertTrue(card.contains("LocalDataCopy.findDisclosure"))
        let disclosureStart = try XCTUnwrap(card.range(of: "DisclosureGroup"))
        let firstScreen = String(card[..<disclosureStart.lowerBound])
        XCTAssertTrue(firstScreen.contains("CompanionFilterPill"))
        XCTAssertFalse(firstScreen.contains("CompanionClipboardField"))
        XCTAssertTrue(source.text.contains("近两周"))
        XCTAssertTrue(source.text.contains("承诺"))
        XCTAssertEqual(SettingsView.Tab.localData.label, "本地资料")
    }

    func testRecordActionsPressQuietly() throws {
        let source = try LocalDataSettingsSource.load()
        let listsStart = try XCTUnwrap(source.text.range(of: "// MARK: - Data lists"))
        let helpersStart = try XCTUnwrap(source.text.range(of: "// MARK: - Helpers"))
        let lists = String(source.text[listsStart.lowerBound..<helpersStart.lowerBound])
        XCTAssertTrue(lists.contains("Button(\"完成\")"))
        XCTAssertTrue(lists.contains("CompanionPressStyle()"))
        XCTAssertFalse(lists.contains(".controlSize(.mini)"))
        XCTAssertFalse(lists.contains(".bordered"))
        XCTAssertTrue(source.text.contains("近两周"))
        XCTAssertTrue(source.text.contains("承诺"))
        XCTAssertEqual(SettingsView.Tab.localData.label, "本地资料")
    }

    func testRecordSaveFailureIsAWorkspaceReceipt() throws {
        let source = try LocalDataSettingsSource.load()
        let dataStart = try XCTUnwrap(source.text.range(of: "private var dataSection"))
        let exportStart = try XCTUnwrap(source.text.range(of: "private var exportReportSection"))
        let pane = String(source.text[dataStart.lowerBound..<exportStart.lowerBound])
        XCTAssertTrue(pane.contains("LocalDataCopy.saveFailed"))
        XCTAssertTrue(source.text.contains("刚才没记上。"))
        XCTAssertFalse(pane.contains("foregroundColor(.red)"))
        XCTAssertFalse(pane.contains("重试保存设置"))
        XCTAssertFalse(source.text.contains("操作未保存，请重试"))
        XCTAssertEqual(LocalDataCopy.saveFailed, "刚才没记上。")
        XCTAssertTrue(source.text.contains("近两周"))
        XCTAssertTrue(source.text.contains("承诺"))
        XCTAssertEqual(SettingsView.Tab.localData.label, "本地资料")
    }

    func testEmptyRecordsSpeakANextStep() throws {
        XCTAssertEqual(LocalDataCopy.openTasks, "去待办里看")
        let source = try LocalDataSettingsSource.load()
        XCTAssertTrue(source.text.contains("emptyCommitments"))
        XCTAssertTrue(source.text.contains("LocalDataCopy.openTasks"))
        XCTAssertTrue(source.text.contains("object: \"tasks\""))
        XCTAssertTrue(source.text.contains("近两周"))
        XCTAssertTrue(source.text.contains("承诺"))
        XCTAssertEqual(SettingsView.Tab.localData.label, "本地资料")
    }

    func testAskRowsDoNotDumpTypePills() throws {
        let source = try LocalDataSettingsSource.load()
        let asksStart = try XCTUnwrap(source.text.range(of: "private var pendingAsksList"))
        let helpersStart = try XCTUnwrap(source.text.range(of: "// MARK: - Helpers"))
        let asks = String(source.text[asksStart.lowerBound..<helpersStart.lowerBound])
        XCTAssertFalse(asks.contains("pill("))
        XCTAssertFalse(asks.contains("%.0f%%"))
        XCTAssertFalse(asks.contains("askType.label"))
        XCTAssertTrue(source.text.contains("近两周"))
        XCTAssertTrue(source.text.contains("承诺"))
        XCTAssertTrue(source.text.contains("提问"))
        XCTAssertEqual(SettingsView.Tab.localData.label, "本地资料")
    }
}

private struct LocalDataSettingsSource {
    let text: String

    static func load() throws -> LocalDataSettingsSource {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/WeChatHUD/Views/Settings/SyncSettingsView.swift")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw XCTSkip("SyncSettingsView.swift not found at \(url.path)")
        }
        return LocalDataSettingsSource(text: text)
    }
}
