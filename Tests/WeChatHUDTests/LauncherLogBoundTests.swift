import Foundation
import XCTest
@testable import WeChatHUD

/// The launcher's own log lives in `~/.wechat-hud/logs` with 0600, which fixed
/// the world-readable `/tmp` version but left two things behind: a 24/7 process
/// appends to it forever, and the lines it appends were AX dumps that quoted the
/// input box — which, right after a paste, holds the reply, i.e. the peer's
/// conversation text.
final class LauncherLogBoundTests: XCTestCase {

    private let cap = 8 * 1024

    private func endsWith(_ data: Data, _ tail: Data) -> Bool {
        data.count >= tail.count && data.suffix(tail.count) == tail
    }

    func testBelowTheCapNothingIsRewritten() {
        let small = Data(repeating: 0x41, count: cap / 2)
        XCTAssertNil(WeChatLauncher.logRewrite(
            existing: small, adding: Data("x\n".utf8), cap: cap),
                     "没到上限就不该整文件重写 —— 那是每次发送都付的代价")
    }

    func testLogStaysBoundedAcrossThousandsOfLines() {
        var current = Data()
        let line = Data(repeating: 0x42, count: 200)
        for _ in 0..<5_000 {
            current = WeChatLauncher.logRewrite(existing: current, adding: line, cap: cap)
                ?? current + line
            XCTAssertLessThanOrEqual(current.count, cap + line.count,
                                     "有界增长才是这条修复的内容，而不是「某一次调用变短了」")
        }
        XCTAssertTrue(endsWith(current, line), "截断要留尾部：被调试的永远是最近那次失败")
    }

    func testRewriteKeepsTheNewestLine() {
        let existing = Data(repeating: 0x41, count: cap * 2)
        let newest = Data("最后一条：发送失败\n".utf8)
        let kept = WeChatLauncher.logRewrite(existing: existing, adding: newest, cap: cap)
        XCTAssertNotNil(kept)
        XCTAssertTrue(kept.map { endsWith($0, newest) } ?? false)
        XCTAssertLessThanOrEqual(kept?.count ?? .max, cap / 2 + newest.count)
    }

    /// A log that grew far past the cap — a crash loop, or the cap being lowered
    /// under an existing file — has to come back down in one pass.
    func testOversizedLogComesBackDownInOnePass() {
        let huge = Data(repeating: 0x43, count: cap * 40)
        let kept = WeChatLauncher.logRewrite(existing: huge, adding: Data("x\n".utf8), cap: cap)
        XCTAssertLessThanOrEqual(kept?.count ?? .max, cap / 2 + 4,
                                 "只按 cap 的一半做减法时，越界的倍数会原样留在文件里")
    }

    /// The dump exists to locate a node, which needs role / identifier / title.
    /// Logging the value is the half that carries chat content.
    func testAXDumpRecordsValueLengthNotValue() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/WeChatHUD/Services/WeChatLauncher.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let body = (source.components(separatedBy: "static func dumpAX(").last ?? "")
            .components(separatedBy: "\n    }").first ?? ""
        XCTAssertFalse(body.isEmpty, "切片为空则这条判据什么都没看")
        XCTAssertTrue(body.contains("valLen=\\(valueStr.count)"),
                      "输入框里粘贴后就是 AI 草稿，日志只能记长度")
        XCTAssertFalse(body.contains("val=\\"),
                       "不许把 AX value 的内容写进日志")
        XCTAssertFalse(body.contains("prefix(40)"),
                       "「截一段」不是脱敏：40 个字符够把一句回复原文带出去")
    }
}
