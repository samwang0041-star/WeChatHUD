import XCTest
@testable import WeChatHUD

/// The `.temporary` cache strategy keeps a decrypted, plaintext copy of WeChat's
/// whole message store under `$TMPDIR`. That is the point of the strategy — it
/// amortizes a re-decrypt across scans — but a run that is killed reaches
/// neither `applicationWillTerminate` nor `deinit`, and macOS only prunes the
/// directory after days of non-access. So the copies need an owner, and an
/// orphan needs a collector.
final class SnapshotReclaimTests: XCTestCase {

    private func tempRoot() -> String {
        let dir = NSTemporaryDirectory() + "wchud-reclaim-\(UUID().uuidString)/"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private func touch(_ root: String, _ name: String) {
        try? FileManager.default.createDirectory(atPath: root + name, withIntermediateDirectories: true)
    }

    func testTemporarySnapshotsAreAttributedToTheirProcess() {
        let dir = WeChatReader.cacheDir(for: .temporary)
        XCTAssertTrue(dir.hasPrefix(NSTemporaryDirectory()),
                      "共享 /tmp 是可预测目录，谁先建谁做主")
        XCTAssertTrue(dir.contains(WeChatReader.temporaryCachePrefix),
                      "共享目录没有主人，扫描器就无法区分「上一次留下的」和「正在用的」")
        XCTAssertTrue(dir.contains("\(getpid())"),
                      "目录要带 pid，否则回收只能靠时间猜")
    }

    func testOnlyDeadOwnersAreCollected() {
        let mine = WeChatReader.temporaryCachePrefix + "\(getpid())"
        XCTAssertFalse(WeChatReader.shouldRemoveSnapshotDirectory(
            named: mine, nowPid: getpid(), ownerIsAlive: { _ in true }),
                       "自己这一轮正在写的快照不许删")
        XCTAssertFalse(WeChatReader.shouldRemoveSnapshotDirectory(
            named: mine, nowPid: getpid(), ownerIsAlive: { _ in false }),
                       "正例不成立说明 pid 归属根本没参与判断")

        let other = WeChatReader.temporaryCachePrefix + "987654"
        XCTAssertTrue(WeChatReader.shouldRemoveSnapshotDirectory(
            named: other, nowPid: getpid(), ownerIsAlive: { _ in false }),
                      "上一次被 kill 的运行留下的整库明文，必须在这次启动时收掉")
        XCTAssertFalse(WeChatReader.shouldRemoveSnapshotDirectory(
            named: other, nowPid: getpid(), ownerIsAlive: { _ in true }),
                       "另一个还活着的实例（预览版与正式版并行）的快照不是垃圾")

        XCTAssertTrue(WeChatReader.shouldRemoveSnapshotDirectory(
            named: WeChatReader.legacyTemporaryCacheDir, nowPid: getpid(), ownerIsAlive: { _ in true }),
                      "升级前那个不带 pid 的目录再没人写，留着就是永久残留")
        XCTAssertFalse(WeChatReader.shouldRemoveSnapshotDirectory(
            named: "com.apple.foundation.something", nowPid: getpid(), ownerIsAlive: { _ in false }),
                       "回收不许碰别人的临时目录")
    }

    func testEphemeralDirectoriesAreSweptToo() {
        XCTAssertTrue(WeChatReader.isSnapshotDirectoryName(WeChatReader.ephemeralCachePrefix + "4242"))
        XCTAssertTrue(WeChatReader.shouldRemoveSnapshotDirectory(
            named: WeChatReader.ephemeralCachePrefix + "987654",
            nowPid: getpid(), ownerIsAlive: { _ in false }))
    }

    func testSweepDeletesExactlyTheOrphans() {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let mine = WeChatReader.temporaryCachePrefix + "\(getpid())"
        let dead = WeChatReader.temporaryCachePrefix + "987654"
        let alive = WeChatReader.temporaryCachePrefix + "987655"
        let legacy = WeChatReader.legacyTemporaryCacheDir
        let stranger = "not-ours"
        for name in [mine, dead, alive, legacy, stranger] { touch(root, name) }

        WeChatReader.removeOrphanedSnapshotDirectories(
            in: root, nowPid: getpid(), ownerIsAlive: { $0 == 987655 })

        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: root + mine), "自己的快照被删了 = 每次扫描都要重新解密")
        XCTAssertTrue(fm.fileExists(atPath: root + alive), "活着的另一个实例的快照不许删")
        XCTAssertTrue(fm.fileExists(atPath: root + stranger), "别人的临时目录不许碰")
        XCTAssertFalse(fm.fileExists(atPath: root + dead), "死进程的整库明文残留没人收，这就是本次修复的对象")
        XCTAssertFalse(fm.fileExists(atPath: root + legacy))
    }

    func testOwnDirectoriesGoOnTheWayOut() {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let mine = WeChatReader.temporaryCachePrefix + "\(getpid())"
        let ephemeral = WeChatReader.ephemeralCachePrefix + "\(getpid())"
        let other = WeChatReader.temporaryCachePrefix + "987654"
        for name in [mine, ephemeral, other] { touch(root, name) }

        WeChatReader.removeOwnSnapshotDirectories(in: root, nowPid: getpid())

        let fm = FileManager.default
        XCTAssertFalse(fm.fileExists(atPath: root + mine))
        XCTAssertFalse(fm.fileExists(atPath: root + ephemeral),
                       "「无明文落盘」这一档退出时同样要清")
        XCTAssertTrue(fm.fileExists(atPath: root + other),
                      "退出只清自己的；别人的要等它自己那次启动的孤儿扫描")
    }
}
