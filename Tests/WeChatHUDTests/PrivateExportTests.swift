import XCTest
@testable import WeChatHUD

/// 导出 says 「文件权限设为只有本账户可读」, and that sentence is the only reason
/// a user leaves the file on a Desktop iCloud syncs by default.
///
/// `makeExportPrivate` was `try? FileManager.setAttributes(...)` with the result
/// discarded, and both export functions returned the URL regardless — so a failed
/// `chmod` produced a world-readable transcript of real conversations behind a
/// green 「已导出」. The mode is now read back rather than trusted, and a failure
/// to restrict deletes the file: leaving it behind is the half of the failure
/// the promise exists to prevent.
@MainActor
final class PrivateExportTests: XCTestCase {
    private func directory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wchud-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func mode(of url: URL) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return Int((attributes?[.posixPermissions] as? NSNumber)?.int16Value ?? -1)
    }

    func testExportComesBackOwnerOnly() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("report.md")
        let written = ChatMonitor.writePrivateExport("# 日报\n真实姓名与消息正文", to: target)
        XCTAssertEqual(written, target)
        XCTAssertEqual(mode(of: target), 0o600, "「只有本账户可读」要能在文件上看到")
    }

    /// The judge is the mode read back, not the `chmod` call returning. A path
    /// that is not there makes `setAttributes` throw, which is precisely what
    /// the discarded `try?` used to swallow on the way to a green 「已导出」.
    func testRestrictionIsVerifiedRatherThanAssumed() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertFalse(
            ChatMonitor.makeExportPrivate(
                url: root.appendingPathComponent("没有这个文件")),
            "文件不在的时候不能算作「已经保护好」")
    }

    func testUnwritableTargetReportsFailureInsteadOfAURL() throws {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wchud-no-such-dir-\(UUID().uuidString)")
            .appendingPathComponent("report.md")
        XCTAssertNil(ChatMonitor.writePrivateExport("x", to: missing))
    }

    /// One definition, one caller: an export path that hardens the file itself
    /// cannot also claim success on a failed `chmod`.
    func testNoExportPathBypassesTheVerifyingWriter() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/WeChatHUD/Services/ChatMonitor+DailyReport.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let writers = source.components(separatedBy: "writePrivateExport(").count - 1
        // The definition plus both export functions. Fewer than three means one
        // of them went back to writing the file by hand.
        XCTAssertGreaterThanOrEqual(writers, 3, "两处导出都要走同一个先写后验的路径")
        XCTAssertFalse(
            source.contains("try? md.write"),
            "写文件本身也不能再被 try? 吞掉")
        let helper = try XCTUnwrap(
            source.components(separatedBy: "static func makeExportPrivate").last,
            "锚点没了")
        let body = helper.components(separatedBy: "\n    }\n").first ?? ""
        XCTAssertFalse(body.contains("try? FileManager"), "setAttributes 的失败必须可见")
        XCTAssertTrue(body.contains("attributesOfItem"), "要读回来核对，而不是相信调用没抛错")
    }
}
