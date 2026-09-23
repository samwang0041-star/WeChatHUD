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

    // MARK: - Deadline vocabulary

    func testPassedDeadlineIsCalledOneThingAcrossTheApp() throws {
        // A deadline that had passed used to be described by three different
        // words — 已超期, 已过期 and 已到期 — and one tab switch could put two
        // of them side by side (the island said 承诺已到期 while its own page
        // said 已超期). The plainest one wins, so the others are banned here.
        let root = try Self.repoRoot()
        let files = try FileManager.default.subpathsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix("Sources/") && ($0.hasSuffix(".swift") || $0.hasSuffix(".txt")) }
        XCTAssertGreaterThan(files.count, 100, "the scan found nothing to scan")

        var violations: [String] = []
        var unified = 0
        for file in files {
            let text = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            for line in text.split(separator: "\n") {
                if line.contains("已到期") || line.contains("前到期") { unified += 1 }
                // The ban is on copy a user can read. Prose that explains the
                // old words — which is what most of these lines do — has to be
                // allowed to name them, or every comment about this decision
                // trips the guard it is describing (a comment in
                // AutopilotService's `holdRowAcrossRestart` did exactly that).
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.starts(with: "//") || trimmed.starts(with: "*") { continue }
                guard line.contains("超期") || line.contains("过期") else { continue }
                // A login token running out is a different fact from a promise
                // coming due, so that one reading of 过期 survives.
                if file.contains("Codex"), line.contains("登录态") { continue }
                violations.append("\(file): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        XCTAssertEqual(violations, [], "A passed deadline is 已到期 everywhere.")
        XCTAssertGreaterThan(unified, 5, "the guard is only meaningful while 已到期 is the live word")
    }

    /// A windowed history list states its window; 「随时查看」claimed none.
    ///
    /// Both batch-clear dialogs promised permanence for 14-day lists —
    /// 承诺的「已完成」(`commitmentRelevantSinceClause`) and 待办的「看已处理的」
    /// (`DiscussionLiveWindow.historyDays`) — and each contradicted the window
    /// its own page prints elsewhere on the same screen.
    func testWindowedHistoryListsStateTheirWindowNotAlways() throws {
        let root = try Self.repoRoot()
        let files = try FileManager.default.subpathsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix("Sources/") && $0.hasSuffix(".swift") }
        XCTAssertGreaterThan(files.count, 100, "the scan found nothing to scan")

        var violations: [String] = []
        for file in files {
            let text = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            for line in text.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.starts(with: "//") || trimmed.starts(with: "*") { continue }
                guard line.contains("随时查看") || line.contains("很久没处理") else { continue }
                violations.append("\(file): \(trimmed)")
            }
        }
        XCTAssertEqual(
            violations, [],
            "「随时查看」lies about a 14-day window and 「很久没处理」hides one; write the number."
        )

        let commitment = try String(
            contentsOf: root.appendingPathComponent("Sources/WeChatHUD/Views/CommitmentTabView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(
            commitment.contains("14 天内可在「已完成」列表中查看和撤销"),
            "the 承诺 batch-clear dialog names its window"
        )
        let discussion = try String(
            contentsOf: root.appendingPathComponent("Sources/WeChatHUD/Views/DiscussionWorkspaceView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(
            discussion.contains("14 天内可在「看已处理的」中查看和恢复"),
            "the 待办 batch-clear dialog names its window"
        )
    }

    func testDurationBadgesUseSpacedWordsNotCompactUnits() throws {
        let detail = try ViewSource.load("Sources/WeChatHUD/Views/DetailPanelView.swift")
        XCTAssertTrue(detail.text.contains("overdueMinutes) 分钟"))
        XCTAssertFalse(detail.text.contains("overdueMinutes)分"))

        let contacts = try ViewSource.load("Sources/WeChatHUD/Views/Settings/ContactsSettingsView.swift")
        XCTAssertTrue(contacts.text.contains("replyWindowMinutes) 分钟"))
        XCTAssertFalse(contacts.text.contains("replyWindowMinutes)分"))

        let sync = try ViewSource.load("Sources/WeChatHUD/Views/Settings/SyncSettingsView.swift")
        XCTAssertTrue(sync.text.contains("recallDelaySeconds) 秒后撤回"))
        XCTAssertFalse(sync.text.contains("recallDelaySeconds)秒后撤回"))
    }

    func testDurationLabelUsesSpacedWords() {
        XCTAssertEqual(RelativeTimeFormatter.durationLabel(0), "--")
        XCTAssertEqual(RelativeTimeFormatter.durationLabel(12), "12 秒")
        XCTAssertEqual(RelativeTimeFormatter.durationLabel(120), "2 分钟")
        XCTAssertEqual(RelativeTimeFormatter.durationLabel(7200), "2.0 小时")
    }

    func testElapsedLabelKeepsHoursAndMinutesInChinese() {
        XCTAssertEqual(RelativeTimeFormatter.elapsedLabel(12), "12 秒")
        XCTAssertEqual(RelativeTimeFormatter.elapsedLabel(120), "2 分钟")
        XCTAssertEqual(RelativeTimeFormatter.elapsedLabel(3600), "1 小时")
        XCTAssertEqual(RelativeTimeFormatter.elapsedLabel(4500), "1 小时 15 分钟")
    }

    func testInsightAndSyncPickersDoNotKeepCompactDurationUnits() throws {
        let files = [
            "Sources/WeChatHUD/Views/Analytics/InsightKPIGrid.swift",
            "Sources/WeChatHUD/Views/Analytics/InsightOverviewDashboard.swift",
            "Sources/WeChatHUD/Views/Analytics/ChatInsightDetailView.swift",
            "Sources/WeChatHUD/Views/Settings/SyncSettingsView.swift",
        ]
        for relative in files {
            let source = try ViewSource.load(relative)
            XCTAssertFalse(source.text.contains(")秒\""), relative)
            XCTAssertFalse(source.text.contains(")分钟\""), relative)
            XCTAssertFalse(source.text.contains("formatResponseTime"), relative)
            XCTAssertFalse(source.text.contains("formatHoursShort"), relative)
        }
        let kpi = try ViewSource.load("Sources/WeChatHUD/Views/Analytics/InsightKPIGrid.swift")
        XCTAssertTrue(kpi.text.contains("RelativeTimeFormatter.durationLabel"))
        let sync = try ViewSource.load("Sources/WeChatHUD/Views/Settings/SyncSettingsView.swift")
        XCTAssertTrue(sync.text.contains(") 秒"))
        XCTAssertTrue(sync.text.contains(") 分钟"))
    }

    func testAutopilotSessionDurationIsNotEnglishUnits() throws {
        let settings = try ViewSource.load("Sources/WeChatHUD/Views/Settings/AutopilotSettingsView.swift")
        XCTAssertTrue(settings.text.contains("RelativeTimeFormatter.elapsedLabel"))
        XCTAssertFalse(settings.text.contains("/60)m"))
        let island = try ViewSource.load("Sources/WeChatHUD/Views/AutopilotIndicator.swift")
        XCTAssertTrue(island.text.contains("RelativeTimeFormatter.elapsedLabel"))
    }

    func testInsightCountsKeepASpaceBeforeTheUnit() throws {
        let overview = try ViewSource.load("Sources/WeChatHUD/Views/Analytics/InsightOverviewDashboard.swift")
        XCTAssertTrue(overview.text.contains("participantCount) 人参与"))
        XCTAssertFalse(overview.text.contains("participantCount)人参与"))
        XCTAssertTrue(overview.text.contains("messageCount) 条"))
        XCTAssertFalse(overview.text.contains("messageCount)条\""))

        let sidebar = try ViewSource.load("Sources/WeChatHUD/Views/Analytics/InsightSidebarView.swift")
        XCTAssertTrue(sidebar.text.contains("messageCount) 条消息"))
        XCTAssertTrue(sidebar.text.contains("participantCount) 人"))
        XCTAssertFalse(sidebar.text.contains("messageCount)条消息"))

        let radar = try ViewSource.load("Sources/WeChatHUD/Views/Analytics/RelationshipRadarView.swift")
        XCTAssertTrue(radar.text.contains("silenceDays) 天"))
        XCTAssertFalse(radar.text.contains("silenceDays)天"))
    }

    func testScanAndBuddyDurationsUseChineseUnits() throws {
        let scan = try ViewSource.load("Sources/WeChatHUD/Views/WhitelistScanView.swift")
        XCTAssertTrue(scan.text.contains("条 / 45 天"))
        XCTAssertFalse(scan.text.contains("条/45天"))

        let buddy = try ViewSource.load("Sources/WeChatHUD/Views/PixelBuddyView.swift")
        XCTAssertTrue(buddy.text.contains("elapsedLabel"))
        XCTAssertTrue(buddy.text.contains("%.1f 秒"))
        XCTAssertFalse(buddy.text.contains("%.1fs"))
        XCTAssertFalse(buddy.text.contains("m\\("))
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
        // they must not sit on the decorative steps. The island's status word
        // and its list label are the same kind of fact: `IslandInk.tertiary`
        // is ≈3.9:1 on the black body, under AA, and is documented as chrome
        // only — a sentence the user has to read to know what happened may not
        // live there.
        for literal in [
            "Text(\"正在同步\")", "Text(syncLabel(syncAt))", "Text(\"没有待处理\")",
            "Text(\"已处理 (\\(monitor.handledItems.count))\")",
            "Text(\"有急事要处理\")", "Text(\"等你回复\")", "Text(\"群里@了你\")",
            "Text(\"普通更新\")", "Text(\"待处理 (",
            "Text(showAllPassiveUpdates ? \"收起普通更新\"",
            "Text(\"+\\(hiddenTotalCount) 更多"
        ] {
            let range = try XCTUnwrap(inbox.text.range(of: literal), "missing " + literal)
            let tail = inbox.text[range.lowerBound...].prefix(400)
            XCTAssertTrue(tail.contains("IslandInk.meta") || tail.contains("IslandInk.secondary") || tail.contains("IslandInk.primary"),
                          literal + " must use meta or brighter")
        }
    }

    private static func repoRoot() throws -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
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
