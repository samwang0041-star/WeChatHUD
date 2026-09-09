import XCTest
@testable import WeChatHUD

final class ClassifierCLITests: XCTestCase {
    func testClassifyRealOutputRejectsFixturesPath() {
        XCTAssertTrue(ClassifierCLI.isUnsafeClassifyRealOutputPath(
            "Tests/Fixtures/labeled_messages_private.json",
            currentDirectory: "/tmp/WeChatHUD"
        ))
    }

    func testClassifyRealOutputRejectsPackagePath() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wchud-cli-path-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("// package marker\n".utf8).write(to: root.appendingPathComponent("Package.swift"))

        let out = root.appendingPathComponent("scratch/raw_messages.json").path

        XCTAssertTrue(ClassifierCLI.isUnsafeClassifyRealOutputPath(out, currentDirectory: "/tmp"))
    }

    func testClassifyRealOutputAllowsTmpPathOutsidePackage() {
        let out = "/tmp/wchud_classify_real_\(UUID().uuidString).json"

        XCTAssertFalse(ClassifierCLI.isUnsafeClassifyRealOutputPath(out, currentDirectory: "/tmp"))
    }
    func testCLIUsesDeviceSelectionAndMatchingReaderInsteadOfLegacyStore() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent("support")
        let firstAccount = root.appendingPathComponent("alice/db_storage").path
        let secondAccount = root.appendingPathComponent("bob/db_storage").path
        for path in [firstAccount, secondAccount] {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
        let legacy = HUDStore(dbPath: support.appendingPathComponent("hud.sqlite3").path)
        try legacy.open()
        var sync = SyncConfig()
        sync.wechatDBPath = firstAccount
        try legacy.setSettingJSON("sync", value: sync)
        try legacy.addToWhitelist(username: "legacy-person", displayName: "Legacy", isGroup: false, category: .work)
        legacy.close()
        let gui = try AccountStoreCoordinator(supportDirectory: support).bootstrap(databaseCandidates: [firstAccount, secondAccount])
        sync.wechatDBPath = secondAccount
        try gui.store.setSettingJSON("sync", value: sync)
        var ai = AIConfig()
        ai.provider.model = "latest-device-setting"
        try gui.store.setSettingJSON("ai", value: ai)
        gui.store.close()
        let cli = try ClassifierCLI.accountContext(supportDirectory: support, databaseCandidates: [firstAccount, secondAccount])
        defer { cli.store.close() }
        XCTAssertTrue(cli.store.getWhitelist().isEmpty)
        XCTAssertEqual(cli.databaseRoot, secondAccount)
        XCTAssertEqual(try ClassifierCLI.readerForAccount(cli).dbDir, secondAccount)
        XCTAssertEqual(cli.store.loadAIConfig().provider.model, "latest-device-setting")
    }

    func testCLIRefusesReaderWhenAccountSelectionIsAmbiguous() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cli = try ClassifierCLI.accountContext(supportDirectory: root, databaseCandidates: ["/fixture/alice", "/fixture/bob"])
        defer { cli.store.close() }
        XCTAssertNil(cli.databaseRoot)
        XCTAssertThrowsError(try ClassifierCLI.readerForAccount(cli))
        XCTAssertTrue(cli.store.getWhitelist().isEmpty)
    }

}
