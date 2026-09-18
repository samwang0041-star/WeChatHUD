import XCTest

/// `.buttonStyle(.borderedProminent)` only paints the brand fill when the
/// `.tint()` modifier is applied *before* it. Measured, not guessed: on the same
/// page, in the same window, with the same capture flags, `标记完成` rendered as a
/// grey capsule identical to its bordered neighbours with the tint after the
/// style, and as a filled accent capsule with the tint before it — at both
/// `.controlSize(.large)` and `.controlSize(.regular)`.
///
/// That is the app's primary-action hierarchy silently disappearing: a page's
/// one filled button becomes visually indistinguishable from "复制".
final class PrimaryActionStyleTests: XCTestCase {

    func testEveryProminentButtonTintsBeforeApplyingTheStyle() throws {
        let root = try XCTUnwrap(
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("Sources").path
                as String?,
            "Sources/ not found"
        )
        let files = try FileManager.default.subpathsOfDirectory(atPath: root)
            .filter { $0.hasSuffix(".swift") }
        XCTAssertGreaterThan(files.count, 100, "the scan found nothing to scan")

        var violations: [String] = []
        var checked = 0
        for file in files {
            let text = try String(contentsOfFile: root + "/" + file, encoding: .utf8)
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            for (index, line) in lines.enumerated() where line.contains(".buttonStyle(.borderedProminent)") {
                checked += 1
                // Same-line `.buttonStyle(...).tint(...)` still puts the tint
                // after the style, so it does not count.
                let sameLineTintBeforeStyle =
                    line.range(of: ".tint(").map { $0.lowerBound < line.range(of: ".buttonStyle(.borderedProminent)")!.lowerBound } ?? false
                if sameLineTintBeforeStyle { continue }
                var previous = index - 1
                while previous >= 0, lines[previous].trimmingCharacters(in: .whitespaces).isEmpty { previous -= 1 }
                let guarded = previous >= 0 && lines[previous].trimmingCharacters(in: .whitespaces).hasPrefix(".tint(")
                if !guarded {
                    violations.append("\(file):\(index + 1) → \(lines[index].trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        XCTAssertGreaterThan(checked, 20, "no prominent buttons were scanned")
        XCTAssertEqual(violations, [], "Tint the prominent buttons before the style, or they render grey.")
    }
}
