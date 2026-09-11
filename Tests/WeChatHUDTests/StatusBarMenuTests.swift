import XCTest
@testable import WeChatHUD

final class StatusBarMenuTests: XCTestCase {
    func testMenuGroupsDailyActionsThenReviewThenQuit() {
        let titles = StatusBarMenuSpec.rows(companionOpen: false, updateVersion: nil).map { row -> String in
            switch row.kind {
            case .separator: return "—"
            case .command(let title, _): return title
            }
        }
        XCTAssertEqual(titles, [
            "打开 WeChatHUD",
            "查看新消息",
            "—",
            "按时间回顾",
            "怎么用",
            "检查更新…",
            "—",
            "退出 WeChatHUD"
        ])
        XCTAssertEqual(StatusBarMenuSpec.actions(), [
            .toggleCompanion, .refresh, nil, .timeReview, .guide, .updates, nil, .quit
        ])
    }

    func testOpenTitleTogglesAndUpdateShowsVersion() {
        XCTAssertEqual(CompanionProductCopy.companionToggleTitle(isOpen: false), "打开 WeChatHUD")
        XCTAssertEqual(CompanionProductCopy.companionToggleTitle(isOpen: true), "收起 WeChatHUD")
        XCTAssertEqual(StatusBarMenuSpec.updateTitle("1.2.1"), "查看更新 1.2.1…")
        XCTAssertEqual(StatusBarMenuSpec.updateTitle(nil), "检查更新…")
    }

    func testMenuCopyStaysInCompanionLanguage() {
        let leaked = ["浮窗", "复盘", "刷新", "工作台", "洞察", "简报", "白名单"]
        let rows = StatusBarMenuSpec.rows(companionOpen: false, updateVersion: "1.2.1")
            + StatusBarMenuSpec.rows(companionOpen: true, updateVersion: nil)
        for row in rows {
            guard case .command(let title, _) = row.kind else { continue }
            for word in leaked + CompanionProductCopy.forbiddenChrome {
                XCTAssertFalse(title.contains(word), "\(title) leaked \(word)")
            }
        }
        XCTAssertEqual(CompanionProductCopy.howToUse, SettingsView.Tab.guide.label)
        XCTAssertEqual(CompanionProductCopy.timeReview, "按时间回顾")
    }

    @MainActor
    func testBuiltMenuMatchesSpecAndHasNoSettingsGearShortcut() {
        let menu = StatusBarMenuBuilder.makeMenu(target: nil)
        XCTAssertEqual(menu.items.count, 8)
        XCTAssertTrue(menu.items[2].isSeparatorItem)
        XCTAssertTrue(menu.items[6].isSeparatorItem)
        XCTAssertEqual(menu.items[0].title, CompanionProductCopy.openCompanion)
        XCTAssertEqual(menu.items[0].keyEquivalent, "1")
        XCTAssertEqual(menu.items[1].title, CompanionProductCopy.checkNewMessages)
        XCTAssertEqual(menu.items[1].keyEquivalent, "r")
        XCTAssertEqual(menu.items[3].title, CompanionProductCopy.timeReview)
        XCTAssertEqual(menu.items[3].keyEquivalent, "R")
        XCTAssertEqual(menu.items[7].title, CompanionProductCopy.quitCompanion)
        XCTAssertNotEqual(menu.items[0].keyEquivalent, ",")
    }
}
