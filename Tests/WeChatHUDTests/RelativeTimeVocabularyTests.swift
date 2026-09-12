import XCTest
@testable import WeChatHUD

/// One relative-time vocabulary for the panel: "x 分钟前 / x 小时前"
/// everywhere, with the caller's suffix as the only local variation. The
/// island also renders user-read state on the meta step or brighter,
/// because tertiary/quaternary are the chrome steps (see IslandInk's doc).
final class RelativeTimeVocabularyTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testSharedFormatterUsesMinutesAndHoursInWords() {
        XCTAssertEqual(RelativeTimeFormatter.relativeLabel(now, now: now), "刚刚")
        XCTAssertEqual(RelativeTimeFormatter.relativeLabel(now.addingTimeInterval(-59), now: now), "刚刚")
        XCTAssertEqual(RelativeTimeFormatter.relativeLabel(now.addingTimeInterval(-60), now: now), "1 分钟前")
        XCTAssertEqual(RelativeTimeFormatter.relativeLabel(now.addingTimeInterval(-9 * 60), now: now), "9 分钟前")
        XCTAssertEqual(RelativeTimeFormatter.relativeLabel(now.addingTimeInterval(-3599), now: now), "59 分钟前")
        XCTAssertEqual(RelativeTimeFormatter.relativeLabel(now.addingTimeInterval(-3600), now: now), "1 小时前")
        XCTAssertEqual(RelativeTimeFormatter.relativeLabel(now.addingTimeInterval(-3 * 3600), now: now), "3 小时前")
        XCTAssertEqual(RelativeTimeFormatter.relativeLabel(now.addingTimeInterval(-86400), now: now), "1 天前")
        XCTAssertEqual(RelativeTimeFormatter.relativeLabel(now.addingTimeInterval(-2 * 86400), now: now), "2 天前")
    }

    func testSuffixVariantKeepsTheSameVocabulary() {
        XCTAssertEqual(RelativeTimeFormatter.relativeLabel(now, suffix: "同步", now: now), "刚刚同步")
        XCTAssertEqual(RelativeTimeFormatter.relativeLabel(now.addingTimeInterval(-3 * 60), suffix: "同步", now: now), "3 分钟前同步")
        XCTAssertEqual(RelativeTimeFormatter.relativeLabel(now.addingTimeInterval(-2 * 3600), suffix: "同步", now: now), "2 小时前同步")
    }

    func testOldCompactSpellingsAreGone() throws {
        // The old forms were a digit directly followed by the unit. Matching
        // that shape avoids the false positive a plain contains check would
        // raise on the new spaced form.
        let compactMinute = try NSRegularExpression(pattern: #"[0-9]分前"#)
        let compactHour = try NSRegularExpression(pattern: #"[0-9]时前"#)
        for offset in [-60, -9 * 60, -3600, -3 * 3600] {
            let label = RelativeTimeFormatter.relativeLabel(now.addingTimeInterval(TimeInterval(offset)), now: now)
            let range = NSRange(label.startIndex..., in: label)
            XCTAssertNil(compactMinute.firstMatch(in: label, range: range), label + " used the old compact minute form")
            XCTAssertNil(compactHour.firstMatch(in: label, range: range), label + " used the old compact hour form")
        }
    }

    func testInboxRowHelperDelegatesToTheSharedFormatter() {
        // relativeTime(_:) is the row-level entry point; it must not carry its
        // own copy of the math (that duplication is what let the vocabulary
        // drift).
        // Near zero so a slow test run cannot change the minute bucket between
        // the two calls.
        let justNow = Date().addingTimeInterval(-1)
        XCTAssertEqual(relativeTime(justNow), RelativeTimeFormatter.relativeLabel(justNow))
    }

    func testBannerArrivalStampSharesTheVocabulary() {
        let calendar = Calendar(identifier: .gregorian)
        let fixedNow = calendar.date(from: DateComponents(year: 2026, month: 9, day: 9, hour: 14, minute: 32))!
        XCTAssertEqual(
            CompanionProductCopy.arrivalLabel(fixedNow.addingTimeInterval(-12 * 60), now: fixedNow, calendar: calendar),
            "12 分钟前"
        )
        XCTAssertEqual(
            CompanionProductCopy.arrivalLabel(fixedNow.addingTimeInterval(-3 * 3600), now: fixedNow, calendar: calendar),
            "3 小时前",
            "The banner used to switch to a clock after an hour, a second vocabulary."
        )
    }

    func testInboxSourcesUseTheOneFormatter() throws {
        let inbox = try ViewSource.load("Sources/WeChatHUD/Views/InboxView.swift")
        XCTAssertTrue(inbox.text.contains("RelativeTimeFormatter.relativeLabel(date, suffix: \"同步\")"))
        // The stamp must not re-derive the numbers or hard-code its own copy;
        // comments may still describe the old label.
        XCTAssertFalse(inbox.text.contains("seconds / 60"), "hand-rolled sync math")
        XCTAssertFalse(inbox.text.contains("return \"刚刚同步\""), "hand-rolled sync label")
        XCTAssertTrue(try ViewSource.load("Sources/WeChatHUD/Views/ViewHelpers.swift").text.contains("enum RelativeTimeFormatter"))
    }

    // MARK: - Island contrast budget

    func testIslandNeverUsesTheWeakestInkForContent() throws {
        let inbox = try ViewSource.load("Sources/WeChatHUD/Views/InboxView.swift")
        let violations = try Self.findContentOnQuaternary(inbox.text)
        XCTAssertEqual(
            violations,
            [],
            "IslandInk.quaternary (2.1:1) is the decorative step; content lines use meta or brighter."
        )
    }

    func testIslandSyncStateStaysReadable() throws {
        let inbox = try ViewSource.load("Sources/WeChatHUD/Views/InboxView.swift")
        // The sync state and the handled count are facts the user reads, so
        // they must not sit on the decorative steps.
        for literal in ["Text(\"同步中\")", "Text(syncLabel(syncAt))", "Text(\"一切正常\")", "Text(\"已处理 (\\(monitor.handledItems.count))\")"] {
            let range = try XCTUnwrap(inbox.text.range(of: literal), "missing " + literal)
            let tail = inbox.text[range.lowerBound...].prefix(400)
            XCTAssertTrue(tail.contains("IslandInk.meta") || tail.contains("IslandInk.secondary") || tail.contains("IslandInk.primary"),
                          literal + " must use meta or brighter")
        }
    }

    /// Content lines may not sit on IslandInk.quaternary. A quaternary line is
    /// allowed only when it belongs to a decorative glyph (a chevron or the
    /// empty-state sync mark), which is how the remaining uses read today.
    private static func findContentOnQuaternary(_ source: String) throws -> [String] {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var violations: [String] = []
        for (index, line) in lines.enumerated() where line.contains("IslandInk.quaternary") {
            let window = lines[max(0, index - 4)...index].joined(separator: "\n")
            let isDecoration = window.contains("Image(systemName:")
            if !isDecoration {
                violations.append(window.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").joined(separator: " / "))
            }
        }
        return violations
    }
}

private struct ViewSource {
    let text: String
    static func load(_ relativePath: String) throws -> ViewSource {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw XCTSkip(relativePath + " not found at " + url.path)
        }
        return ViewSource(text: text)
    }
}
