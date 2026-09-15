import XCTest
import SwiftUI
@testable import WeChatHUD

/// Source gates for the macOS control conventions that a screenshot cannot
/// show and a unit test of the data layer never reaches.
///
/// Every rule here was found by measuring the *running* app — an `AXUIElement`
/// walk of its own accessibility tree (see `AccessibilityAudit`, enabled with
/// `--preview-hig-audit=<seconds>`), plus pixel sampling of the captures. The
/// measurements are in `docs/qa/2026-09-15-macos-hig-pass.md`; these tests keep
/// the regressions from coming back.
final class ControlConventionTests: XCTestCase {

    private func viewSources() throws -> [(name: String, text: String)] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/WeChatHUD/Views")
        var files: [URL] = []
        if let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) {
            for case let url as URL in walker where url.pathExtension == "swift" {
                files.append(url)
            }
        }
        XCTAssertFalse(files.isEmpty, "no view sources found")
        return try files.map { ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8)) }
    }

    /// A push button is sized to its title.
    ///
    /// `Text("标记完成").frame(maxWidth: .infinity)` inside a `borderedProminent`
    /// rendered a 436pt × 28pt filled bar for a four-character label — the
    /// width came from the pane, not the word. A full-bleed filled button is
    /// the iOS primary-action pattern; on macOS the push button hugs its title
    /// and is placed at the leading or trailing edge of its row.
    ///
    /// The gate is narrow on purpose: a `Label`/`Text` with `maxWidth:
    /// .infinity` is only a defect when it is the *label of a prominent
    /// button*. Full-width rows, banners and tappable cards all legitimately
    /// stretch.
    func testProminentButtonLabelsDoNotStretchToTheAvailableWidth() throws {
        var offenders: [String] = []
        for file in try viewSources() {
            let lines = file.text.components(separatedBy: .newlines)
            for (index, line) in lines.enumerated() {
                // A comment that *describes* the old defect must not trip the
                // gate — that is exactly how a source scan certifies a bug it
                // cannot see (the menu-wiring gate shipped twice with that
                // flaw before it was run against the bug).
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("///") { continue }
                guard line.contains("frame(maxWidth: .infinity)") else { continue }
                // Is this line inside a `Button { … } label: { … }` body?
                // Scan the window back for the label's opening rather than
                // stopping at the first line, because the label's own content
                // (the `Text`) sits between the modifier and `label: {`.
                let before = lines[max(0, index - 20)...index]
                    .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                    .joined(separator: "\n")
                guard before.contains("label: {") || before.contains("Button {") else { continue }
                let after = lines[index...min(lines.count - 1, index + 10)].joined(separator: "\n")
                guard after.contains("buttonStyle(.borderedProminent)")
                        || after.contains("buttonStyle(CompanionGlowButtonStyle") else { continue }
                if before.contains("Label(") || before.contains("HStack") { continue }
                offenders.append("\(file.name):\(index + 1)")
            }
        }
        XCTAssertTrue(
            offenders.isEmpty,
            """
            a prominent button's label is stretched to the pane width \
            (macOS push buttons are sized to their title): \(offenders.joined(separator: ", "))
            """
        )
    }

    /// Two `.tertiary` sentences were the only unreadable text on their pages.
    ///
    /// `.tertiary` resolves to about #565656 in dark mode — **2.27:1** on the
    /// #1E1E1E canvas, against the 4.5:1 AA floor, while the same pages'
    /// `.secondary` measures 5.9–12.3:1. It is the right colour for chevrons
    /// and a ⌘F hint (affordances, not prose); it is the wrong colour for a
    /// sentence the user has to read.
    func testTertiaryIsNotUsedForProse() throws {
        var offenders: [String] = []
        for file in try viewSources() {
            let lines = file.text.components(separatedBy: .newlines)
            for (index, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix(".foregroundStyle(.tertiary)")
                        || trimmed.hasPrefix(".foregroundColor(.tertiary)") else { continue }
                // Walk back to the view this modifier is attached to.
                var target = ""
                var cursor = index - 1
                while cursor >= 0, index - cursor < 12 {
                    let candidate = lines[cursor].trimmingCharacters(in: .whitespaces)
                    if candidate.hasPrefix("Text(") || candidate.hasPrefix("Image(")
                        || candidate.hasPrefix("Label(") {
                        target = candidate
                        break
                    }
                    cursor -= 1
                }
                guard target.hasPrefix("Text(") else { continue }
                // A single glyph or a keyboard hint carries no prose.
                let isGlyph = target.contains("Text(\"·\")") || target.contains("⌘")
                // A literal that is a whole sentence is prose. Interpolated
                // strings are held to the same rule: they are the ones that
                // carried the two measured failures.
                let isShortChip = target.count < 24
                if !isGlyph && !isShortChip {
                    offenders.append("\(file.name):\(index + 1) \(target.prefix(40))")
                }
            }
        }
        XCTAssertTrue(
            offenders.isEmpty,
            """
            `.tertiary` (2.27:1 in dark mode) is carrying prose; use \
            `.secondary` (≈5.9:1) for anything the user must read: \
            \(offenders.joined(separator: " | "))
            """
        )
    }

    /// Destructive controls say so.
    ///
    /// 删除草稿 sat in a row of four identically grey-bordered buttons next to
    /// 复制, at the same weight and colour, for an action that cannot be undone
    /// from the list. macOS reserves red for destruction so the hand hesitates
    /// in the right place. (A confirmation dialog was already in place — the
    /// button simply was not telling the truth about what it did.)
    func testDeletingADraftIsMarkedDestructive() throws {
        guard let file = try viewSources().first(where: { $0.name == "ReplyDraftsView.swift" }) else {
            return XCTFail("ReplyDraftsView.swift is gone; this gate needs rewriting, not deleting")
        }
        for (index, line) in file.text.components(separatedBy: .newlines).enumerated() {
            guard line.contains("Button(\"删除草稿\"") else { continue }
            XCTAssertTrue(
                line.contains("role: .destructive"),
                "ReplyDraftsView.swift:\(index + 1) deletes a draft without role: .destructive"
            )
        }
    }

    /// A settings panel states a fact once.
    ///
    /// 关注级别 appeared twice under the identical label — a read-only `infoRow`
    /// in 整理范围 and the editable segmented control in 操作, two sections apart
    /// in one inspector. One of them has to go; the editable control owns the
    /// fact because it is the one the user can act on.
    func testTheContactInspectorStatesAttentionLevelOnce() throws {
        guard let file = try viewSources().first(where: { $0.name == "ContactsSettingsView.swift" }) else {
            return XCTFail("ContactsSettingsView.swift is gone")
        }
        let readOnlyRow = file.text.contains("infoRow(\"关注级别\"")
        let editableControl = file.text.contains("Picker(\"关注级别\"")
        XCTAssertTrue(editableControl, "the editable 关注级别 control is gone")
        XCTAssertFalse(
            readOnlyRow,
            "关注级别 is both a read-only row and an editable control in one inspector"
        )
    }
}
