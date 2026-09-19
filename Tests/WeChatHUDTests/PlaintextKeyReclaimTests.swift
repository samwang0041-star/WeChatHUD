import Foundation
import XCTest
@testable import WeChatHUD

/// `migratePlaintextAPIKeysToKeychain` moves an API key out of the settings row,
/// and the page then reads back clean. That is not the same as the bytes being
/// gone: SQLite leaves the previous payload in a freed page of the main file and
/// in the write-ahead log until the next checkpoint, so `strings hud.sqlite3`
/// still yields a key the user was told had been cleaned up.
///
/// Under XCTest `HUDStore` swaps in `InMemorySecretStore`, so the migration
/// completes without touching the real Keychain and the only thing left to
/// observe is the file.
final class PlaintextKeyReclaimTests: XCTestCase {

    /// Random per test, so a leftover file from an earlier run can never make
    /// the "it is gone" assertion pass by accident.
    private let canary = "wchud-reclaim-canary-" + UUID().uuidString

    private func makeStore() throws -> (HUDStore, String) {
        let path = NSTemporaryDirectory() + "wchud-keyreclaim-\(UUID().uuidString)/hud.sqlite3"
        let store = HUDStore(dbPath: path)
        try store.open()
        return (store, path)
    }

    /// The database file plus its WAL sidecars — everything a `strings` over the
    /// on-disk state can read.
    private func onDiskBytes(at path: String) -> Data {
        var all = Data()
        for suffix in ["", "-wal", "-shm"] {
            if let chunk = try? Data(contentsOf: URL(fileURLWithPath: path + suffix)) {
                all.append(chunk)
            }
        }
        return all
    }

    private func containsCanary(_ data: Data) -> Bool {
        data.range(of: Data(canary.utf8)) != nil
    }

    private func seedPlaintextRow(_ store: HUDStore) throws {
        var cfg = AIConfig()
        cfg.provider = AIProviderSlot(
            providerID: "custom", baseURL: "https://example.invalid/v1",
            model: "some-model", apiKey: canary)
        // Written raw, exactly the way a pre-Keychain build stored it.
        let data = try JSONEncoder().encode(cfg)
        try store.setSetting("ai", value: String(data: data, encoding: .utf8)!)
    }

    func testMigrationShredsTheBytesItMovedOutOfTheRow() throws {
        let (store, path) = try makeStore()
        defer { store.close(); try? FileManager.default.removeItem(atPath: path) }
        try seedPlaintextRow(store)

        XCTAssertTrue(containsCanary(onDiskBytes(at: path)),
                      "夹具没建立泄漏：迁移前文件里就该读得到这串 key")
        XCTAssertTrue(store.migratePlaintextAPIKeysToKeychain())
        XCTAssertFalse(containsCanary(onDiskBytes(at: path)),
                       "行里的明文换掉了，但被释放的页和 WAL 还留着同一串 key")
    }

    func testMigrationWithoutAKeyDoesNotRewriteTheFile() throws {
        let (store, path) = try makeStore()
        defer { store.close(); try? FileManager.default.removeItem(atPath: path) }
        let before = try Data(contentsOf: URL(fileURLWithPath: path))
        XCTAssertTrue(store.migratePlaintextAPIKeysToKeychain(),
                      "没有可迁移的 key 时这条要报告成功，而不是把 VACUUM 的失败冒出来")
        let after = try Data(contentsOf: URL(fileURLWithPath: path))
        XCTAssertEqual(before.count, after.count,
                       "每次启动都白重写一遍整库，代价要落在真正搬走过秘密的那一次")
    }
}
