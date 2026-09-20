import XCTest
@testable import WeChatHUD

/// §243: `getSettingJSON(key) ?? Defaults()` handed to `setSettingJSON(key)` is a whole-row
/// rewrite, so a failed read wrote factory values over the user's account root, keys path
/// and display preferences — and the UI said 「已保存」.
final class SettingsMergeWriteTests: XCTestCase {
    private var store: HUDStore!
    private var dbPath: String!

    override func setUpWithError() throws {
        dbPath = NSTemporaryDirectory() + "settings-merge-\(UUID()).sqlite3"
        store = HUDStore(dbPath: dbPath)
        try store.open()
    }

    override func tearDown() {
        store.close()
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: dbPath + suffix) }
        super.tearDown()
    }

    private func plant() throws {
        try store.setSettingJSON("sync", value: SyncConfig(
            intervalSeconds: 900, wechatDBPath: "/users/me/wechat",
            keysFilePath: "/users/me/keys.json", cacheStrategy: .memory,
            displayScreen: .builtIn))
    }

    func testMergeKeepsTheFieldsTheCallerNeverTouched() throws {
        try plant()
        let written = try store.updatingSettingJSON("sync", as: SyncConfig.self,
                                                    fallback: { SyncConfig() }) { latest in
            latest.wechatDBPath = "/Volumes/Other/wechat"
        }
        XCTAssertEqual(written?.intervalSeconds, 900)
        XCTAssertEqual(written?.keysFilePath, "/users/me/keys.json")
        XCTAssertEqual(store.getSettingJSON("sync", as: SyncConfig.self)?.wechatDBPath,
                       "/Volumes/Other/wechat")
    }

    func testUnreadableRecordRefusesTheWriteAndTouchesNothing() throws {
        try plant()
        try store.exec("ALTER TABLE settings RENAME TO settings_hidden")
        let written = try store.updatingSettingJSON("sync", as: SyncConfig.self,
                                                    fallback: { SyncConfig() }) { latest in
            latest.wechatDBPath = "/should/not/land"
            latest.intervalSeconds = 3600
        }
        XCTAssertNil(written, "读不到旧值时必须一个字节都不写")
        try store.exec("ALTER TABLE settings_hidden RENAME TO settings")
        let kept = try XCTUnwrap(store.getSettingJSON("sync", as: SyncConfig.self))
        XCTAssertEqual(kept.wechatDBPath, "/users/me/wechat",
                       "「读不到」不能变成「用默认值覆盖用户的账号根目录」")
        XCTAssertEqual(kept.intervalSeconds, 900)
    }

    func testAbsentRecordStillSavesFromDefaults() throws {
        let written = try store.updatingSettingJSON("sync", as: SyncConfig.self,
                                                    fallback: { SyncConfig() }) { latest in
            latest.keysFilePath = "/fresh/keys.json"
        }
        XCTAssertEqual(written?.keysFilePath, "/fresh/keys.json",
                       "第一次安装时没有旧值可读，这条路径不能被旗标挡住")
    }

    /// Anti-regression: the *read-modify-then-whole-row-write* shape is what let a
    /// transient error reset 同步设置. Read-only `?? SyncConfig()` for a form's initial
    /// values is fine, so this scans for the pair within one function body rather than
    /// for the reader itself. Behaviour lives in the three tests above.
    func testNoWholeRowRewriteFollowsADefaultingReader() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let files = ["Sources/WeChatHUD/Views/WeChatConnectionSetupView.swift",
                     "Sources/WeChatHUD/Views/Settings/SyncSettingsView.swift",
                     "Sources/WeChatHUD/App/PreviewRuntime.swift",
                     "Sources/WeChatHUD/Data/HUDStore.swift"]
        for file in files {
            let text = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            let lines = text.split(separator: "\n").map(String.init)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            for (index, line) in lines.enumerated() where line.contains("getSettingJSON(\"sync\"")
                && line.contains("?? SyncConfig()") {
                let window = lines[index..<min(index + 5, lines.count)].joined(separator: "\n")
                XCTAssertFalse(window.contains("setSettingJSON(\"sync\""),
                               "\\(file):\(index + 1) 读不到就整行覆盖回默认值")
            }
        }
    }
}
