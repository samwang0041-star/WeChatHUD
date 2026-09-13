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
        XCTAssertTrue(source.text.contains("记录回溯"))
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
        XCTAssertTrue(source.text.contains("记录回溯"))
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
