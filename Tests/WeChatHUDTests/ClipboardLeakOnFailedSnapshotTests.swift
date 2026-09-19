import AppKit
import XCTest
@testable import WeChatHUD

/// The pasteboard is the one place this app writes another person's words where
/// a screenshot cannot see it: any clipboard manager reads the general
/// pasteboard, and Universal Clipboard syncs it to the user's other devices.
///
/// `restore` used to bail out entirely when the pre-send snapshot came back
/// empty (promised file/image items expose no readable data), under the stated
/// belief that wiping would destroy irreplaceable user content. By that line the
/// caller's own `clearContents()` had already destroyed it, so the branch
/// protected nothing while leaving the AI draft — which quotes the peer's
/// message — sitting on the pasteboard for good.
///
/// Driven against a private `NSPasteboard` rather than the general one, so the
/// assertions are about behaviour and not about source text.
@MainActor
final class ClipboardLeakOnFailedSnapshotTests: XCTestCase {

    private func makePasteboard() -> NSPasteboard {
        let pb = NSPasteboard(name: NSPasteboard.Name("com.wechathud.qa.\(UUID().uuidString)"))
        pb.clearContents()
        return pb
    }

    /// A snapshot that came back empty while the pasteboard had something on it.
    private func failedSnapshot(before changeCount: Int) -> ClipboardGuard.SavedState {
        ClipboardGuard.SavedState(items: nil, changeCount: changeCount, hadContent: true)
    }

    func testFailedSnapshotErasesTheDraftWeWrote() {
        let pb = makePasteboard()
        pb.setString("用户原本复制的东西", forType: .string)
        let state = failedSnapshot(before: pb.changeCount)

        let draft = "好的，我看完你发的截图了，晚上给你。"
        pb.clearContents()
        XCTAssertNotEqual(pb.changeCount, state.changeCount, "夹具没生效：changeCount 没动，restore 会直接早退")
        pb.setString(draft, forType: .string)

        ClipboardGuard.restore(state, pastedText: draft, on: pb)

        XCTAssertNil(pb.string(forType: .string),
                     "快照失败时我们的草稿必须被抹掉 —— 它含对方原文，正躺在跨设备同步的剪贴板上")
    }

    func testFailedSnapshotDoesNotEraseSomethingCopiedAfterwards() {
        let pb = makePasteboard()
        pb.setString("用户原本复制的东西", forType: .string)
        let state = failedSnapshot(before: pb.changeCount)

        // Someone else (or the user, after the send) owns the pasteboard now.
        // That content is recoverable by them and is not ours to destroy.
        pb.clearContents()
        pb.setString("刚刚别人复制的", forType: .string)

        ClipboardGuard.restore(state, pastedText: "我们写进去的那句", on: pb)

        XCTAssertEqual(pb.string(forType: .string), "刚刚别人复制的",
                       "认不出是自己的草稿时不许顺手清空：那会把可恢复的数据变成不可恢复")
    }

    func testFailedSnapshotWithoutTheWrittenTextCannotErase() {
        let pb = makePasteboard()
        pb.setString("用户原本复制的东西", forType: .string)
        let state = failedSnapshot(before: pb.changeCount)
        pb.clearContents()
        pb.setString("我们的草稿", forType: .string)

        ClipboardGuard.restore(state, pastedText: nil, on: pb)

        // Documents the residual: a caller that never says what it wrote leaves
        // no way to tell our draft from a third party's. Every send site passes
        // the text; this test exists so that stays the only option that works.
        XCTAssertEqual(pb.string(forType: .string), "我们的草稿")
    }

    func testEmptyOriginalPasteboardIsLeftEmpty() {
        let pb = makePasteboard()
        // Nothing was on it before the send, so there is nothing to protect.
        let state = ClipboardGuard.SavedState(items: nil, changeCount: pb.changeCount, hadContent: false)
        pb.clearContents()
        pb.setString("我们的草稿", forType: .string)

        ClipboardGuard.restore(state, pastedText: "我们的草稿", on: pb)

        XCTAssertNil(pb.string(forType: .string),
                     "原本就是空 → 直接清空，这条路径以前就是对的，别被新分支带回去")
    }

    func testSuccessfulSnapshotStillRestoresTheOriginal() {
        let pb = makePasteboard()
        pb.setString("用户原本复制的东西", forType: .string)
        let item = NSPasteboardItem()
        item.setData("用户原本复制的东西".data(using: .utf8)!, forType: .string)
        let state = ClipboardGuard.SavedState(
            items: [item], changeCount: pb.changeCount - 1, hadContent: true)

        pb.clearContents()
        pb.setString("我们的草稿", forType: .string)
        ClipboardGuard.restore(state, pastedText: "我们的草稿", on: pb)

        XCTAssertEqual(pb.string(forType: .string), "用户原本复制的东西",
                       "能还原的时候必须还原，正例不成立就说明上面的分支吃掉了这条")
    }
}
