import XCTest
import SwiftUI
import AppKit
@testable import WeChatHUD

/// The island's compact chrome is a fixed 320×32 window (`FloatingPanel`'s
/// `contentRect`) with the physical notch sitting on top of it, so wiring the
/// island's text to Dynamic Type is only half of the job. The other half is
/// proving the largest supported step still fits inside those 32 points — a
/// unread badge that grows out of the bar is worse for the low-vision user than
/// one that never grew at all.
///
/// These render real pixels rather than recomputing the ramp, because the
/// failure mode being guarded (clipped glyphs) is a layout outcome, not an
/// arithmetic one.
@MainActor
final class IslandTypeScaleTests: XCTestCase {

    /// Ink bounding box of a white-on-black render, in points.
    private struct InkBox {
        var width: CGFloat
        var height: CGFloat
    }

    private func render<V: View>(_ view: V, size: CGSize) throws -> NSBitmapImageRep {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let data = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: data) else {
            throw XCTSkip("ImageRenderer produced no bitmap on this host")
        }
        return rep
    }

    private func inkBox<V: View>(_ view: V) throws -> InkBox {
        let rep = try render(view.background(Color.black), size: CGSize(width: 220, height: 90))
        var minX = Int.max, maxX = -1, minY = Int.max, maxY = -1
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                let luminance = Double(c.redComponent + c.greenComponent + c.blueComponent) / 3
                guard luminance > 0.25 else { continue }
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX else {
            XCTFail("nothing was drawn")
            return InkBox(width: 0, height: 0)
        }
        return InkBox(
            width: CGFloat(maxX - minX + 1) / 2,
            height: CGFloat(maxY - minY + 1) / 2
        )
    }

    private func badge(_ text: String, at size: DynamicTypeSize) -> some View {
        Text(text)
            .companionFont(size: CompactInboxMetrics.badgeSize, weight: .semibold)
            .monospacedDigit()
            .foregroundColor(.white)
            .fixedSize()
            .environment(\.dynamicTypeSize, size)
    }

    /// The compact bar's own height, read out of the shipped panel source so
    /// this test and `FloatingPanel` cannot drift apart.
    private func compactBarHeight() throws -> CGFloat {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/WeChatHUD/App/FloatingPanel.swift")
        let text = try String(contentsOf: url, encoding: .utf8)
        for line in text.components(separatedBy: .newlines) where line.contains("contentRect") {
            guard let range = line.range(of: "height: ") else { continue }
            let tail = line[range.upperBound...]
            let digits = tail.prefix { $0.isNumber }
            if let height = Double(digits) { return CGFloat(height) }
        }
        XCTFail("could not read the compact contentRect out of FloatingPanel.swift")
        return 0
    }

    // MARK: - The scale reaches the island

    func testUnreadBadgeGrowsWithTheTypeScale() throws {
        let standard = try inkBox(badge("9+", at: .large))
        let largest = try inkBox(badge("9+", at: CompanionTypeScale.range.upperBound))

        XCTAssertGreaterThan(
            largest.height, standard.height,
            "the badge is the one number a low-vision user needs bigger; if it does not grow, the wiring is decorative"
        )
        XCTAssertGreaterThan(largest.width, standard.width)
    }

    func testLargestBadgeStillFitsTheCompactBar() throws {
        let budget = try compactBarHeight()
        let box = try inkBox(badge("9+", at: CompanionTypeScale.range.upperBound))

        XCTAssertLessThanOrEqual(
            box.height, budget,
            "a \(box.height)pt badge inside a \(budget)pt bar: the glyph would be clipped by the notch chrome"
        )
        XCTAssertLessThanOrEqual(
            box.width, CompactInboxMetrics.wingWidth,
            "the left wing is \(CompactInboxMetrics.wingWidth)pt wide"
        )
    }

    /// The band is capped at `.accessibility2`, and it is worth recording which
    /// surface that cap is actually for. Measured here: the island's badge has
    /// plenty of room left at the step *above* the cap, so the compact bar is
    /// not what stops the band from going higher — the two-column workspace
    /// pages are (`CompanionTypeScale.range`'s own comment says the same).
    /// Asserting the headroom keeps that reasoning from quietly turning into
    /// "the island needs the cap".
    func testTheCompactBarIsNotWhatCapsTheTypeBand() throws {
        let budget = try compactBarHeight()
        let aboveTheCap = try inkBox(badge("9+", at: .accessibility3))

        XCTAssertLessThan(
            aboveTheCap.height, budget,
            "the island bar has headroom above the cap; if this ever fails, the cap's justification moves to this surface"
        )
    }

    // MARK: - The wiring may not regress

    /// Every `Text` on the island's detail surface has to go through the scale.
    /// This is the defect these tests exist for: 24 raw `.font(.system(size:))`
    /// calls made the whole page pixel-identical at 大字号, so the setting was
    /// ignored by the one surface that carries sentences.
    func testIslandDetailHasNoRawTextFontsLeft() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/WeChatHUD/Views/ConversationDetailView.swift")
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(
            text.contains(".font(.system(size:"),
            "raw fixed sizes on this surface re-appear as a page that ignores 文字大小"
        )
        XCTAssertGreaterThan(
            text.components(separatedBy: ".companionFont(size:").count - 1, 20,
            "the detail surface scales through companionFont; a drop here means the wiring was replaced by something else"
        )
    }
}
