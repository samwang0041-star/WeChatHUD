import XCTest
import SwiftUI
import AppKit
@testable import WeChatHUD

/// Renders the surfaces these switches actually change and compares pixels.
///
/// The token-level tests in `CompanionAccessibilityTests` prove the *numbers*
/// move. They cannot prove the numbers reach the screen: the contrast palette
/// is a set of statics, and a view that reads one inside `body` establishes no
/// SwiftUI dependency on it, so the whole feature can be correct in isolation
/// and still never redraw. These render the view and look at the result.
@MainActor
final class CompanionAccessibilityRenderTests: XCTestCase {

    private var savedContrast: (() -> Bool)!
    private var savedColour: (() -> Bool)!

    override func setUp() {
        super.setUp()
        savedContrast = CompanionAccessibility.increaseContrastProvider
        savedColour = CompanionAccessibility.differentiateWithoutColorProvider
    }

    override func tearDown() {
        CompanionAccessibility.increaseContrastProvider = savedContrast
        CompanionAccessibility.differentiateWithoutColorProvider = savedColour
        super.tearDown()
    }

    /// Rasterise a view at a fixed size and return its pixels.
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

    /// How many pixels differ between two equally sized bitmaps.
    private func changedPixels(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Int {
        guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh else {
            return Int.max
        }
        var count = 0
        for y in 0..<a.pixelsHigh {
            for x in 0..<a.pixelsWide {
                guard let pa = a.colorAt(x: x, y: y), let pb = b.colorAt(x: x, y: y) else { continue }
                let delta = abs(pa.redComponent - pb.redComponent)
                    + abs(pa.greenComponent - pb.greenComponent)
                    + abs(pa.blueComponent - pb.blueComponent)
                if delta > 0.02 { count += 1 }
            }
        }
        return count
    }

    // MARK: - Status light

    private func dot(_ level: CompanionStatusDot.Level) -> some View {
        CompanionStatusDot(tint: CompanionPalette.jade, level: level, size: 14)
            .padding(10)
            .background(Color.black)
    }

    /// The switch has to change what is drawn. If it did not, the app would be
    /// claiming HIG compliance it does not have.
    func testDifferentiateWithoutColorActuallyChangesTheRenderedDot() throws {
        let off = try render(dot(.attention), size: CGSize(width: 60, height: 60))
        CompanionAccessibility.differentiateWithoutColorProvider = { true }
        let on = try render(dot(.attention), size: CGSize(width: 60, height: 60))

        XCTAssertGreaterThan(
            changedPixels(off, on), 40,
            "the attention light must render as a different silhouette, not the same disc"
        )
    }

    /// And with the switch off it must render *identically* to the pre-existing
    /// design — this is the promise that the screenshots and WCAG measurements
    /// still describe the app everyone else sees.
    func testEveryLevelRendersTheSameShapeWhenTheSwitchIsOff() throws {
        CompanionAccessibility.differentiateWithoutColorProvider = { false }
        let ok = try render(dot(.ok), size: CGSize(width: 60, height: 60))
        let working = try render(dot(.working), size: CGSize(width: 60, height: 60))
        let attention = try render(dot(.attention), size: CGSize(width: 60, height: 60))

        XCTAssertEqual(changedPixels(ok, working), 0, "levels must not differ by shape by default")
        XCTAssertEqual(changedPixels(ok, attention), 0, "levels must not differ by shape by default")
    }

    /// Three levels, three genuinely different pictures. Checked pairwise so a
    /// two-way collision cannot hide behind a third that happens to differ.
    func testAllThreeLevelsRenderDifferentlyUnderTheSwitch() throws {
        CompanionAccessibility.differentiateWithoutColorProvider = { true }
        let ok = try render(dot(.ok), size: CGSize(width: 60, height: 60))
        let working = try render(dot(.working), size: CGSize(width: 60, height: 60))
        let attention = try render(dot(.attention), size: CGSize(width: 60, height: 60))

        XCTAssertGreaterThan(changedPixels(ok, working), 20, "ok and working render the same")
        XCTAssertGreaterThan(changedPixels(ok, attention), 20, "ok and attention render the same")
        XCTAssertGreaterThan(changedPixels(working, attention), 20, "working and attention render the same")
    }

    // MARK: - Card outline

    /// A card is the app's most repeated surface. Its outline is the thing
    /// Increase Contrast is asked to strengthen, so the rendered edge has to
    /// change — this is the assertion that would have caught reading a static
    /// inside a body that never re-runs.
    func testIncreaseContrastChangesTheRenderedCardEdge() throws {
        let card = VStack {
            Text("卡片").font(.system(size: 13))
        }
        .frame(width: 160, height: 60)
        .companionCardFace(padding: 12)

        CompanionAccessibility.increaseContrastProvider = { false }
        let normal = try render(card, size: CGSize(width: 200, height: 100))
        CompanionAccessibility.increaseContrastProvider = { true }
        let strong = try render(card, size: CGSize(width: 200, height: 100))

        XCTAssertGreaterThan(
            changedPixels(normal, strong), 30,
            "the card outline must draw heavier under Increase Contrast"
        )
    }

    /// Off is the default state and may not drift.
    func testCardRendersTheSameAcrossRepeatedRendersWhenTheSwitchIsOff() throws {
        CompanionAccessibility.increaseContrastProvider = { false }
        let first = try render(
            Text("卡片").font(.system(size: 13)).frame(width: 160, height: 60).companionCardFace(padding: 12),
            size: CGSize(width: 200, height: 100)
        )
        let second = try render(
            Text("卡片").font(.system(size: 13)).frame(width: 160, height: 60).companionCardFace(padding: 12),
            size: CGSize(width: 200, height: 100)
        )
        XCTAssertEqual(changedPixels(first, second), 0, "rendering must be deterministic")
    }
}
