import XCTest
import SwiftUI
@testable import WeChatHUD

/// Gates for the two macOS accessibility switches that change how chrome is
/// drawn: **Increase Contrast** and **Differentiate Without Color**.
///
/// The important property these protect is the *default is untouched* one. A
/// user who has never opened 辅助功能 must see exactly the app that was
/// measured and screenshotted; the switches may only add definition on top.
/// Every test here therefore states both halves.
final class CompanionAccessibilityTests: XCTestCase {

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

    private func setIncreaseContrast(_ on: Bool) {
        CompanionAccessibility.increaseContrastProvider = { on }
    }

    private func setDifferentiateWithoutColor(_ on: Bool) {
        CompanionAccessibility.differentiateWithoutColorProvider = { on }
    }

    // MARK: - The default must not move

    func testSwitchesOffLeaveEveryTokenAtItsDesignedValue() {
        setIncreaseContrast(false)
        setDifferentiateWithoutColor(false)

        XCTAssertFalse(CompanionAccessibility.increaseContrast)
        XCTAssertFalse(CompanionAccessibility.differentiateWithoutColor)
        XCTAssertEqual(CompanionAccessibility.borderOpacityScale, 1)
        XCTAssertEqual(CompanionAccessibility.hairlineWidth, 0.5)
        XCTAssertEqual(CompanionAccessibility.cardEdgeWidth, 1)
        XCTAssertEqual(CompanionAccessibility.contrastAdjusted(0.075), 0.075)
    }

    // MARK: - Increase Contrast

    func testIncreaseContrastThickensHairlinesAndCardEdges() {
        setIncreaseContrast(true)

        XCTAssertTrue(CompanionAccessibility.increaseContrast)
        XCTAssertEqual(CompanionAccessibility.hairlineWidth, 1)
        XCTAssertGreaterThan(
            CompanionAccessibility.cardEdgeWidth, 1,
            "a 1pt card edge is exactly what the switch exists to strengthen"
        )
        XCTAssertLessThanOrEqual(
            CompanionAccessibility.cardEdgeWidth, 1.5,
            "past ~1.5pt an outline reads as a box drawn around the card"
        )
    }

    /// The separator has to actually get heavier, not merely different.
    func testCardBorderGetsHeavierUnderIncreaseContrast() {
        setIncreaseContrast(false)
        let normal = CompanionAccessibility.contrastAdjusted(0.075)
        setIncreaseContrast(true)
        let strong = CompanionAccessibility.contrastAdjusted(0.075)

        XCTAssertGreaterThan(strong, normal, "the switch must deepen the card outline")
        XCTAssertGreaterThanOrEqual(
            strong, 0.15,
            "below ~0.15 the outline is still fainter than NSColor.separatorColor's increased variant"
        )
    }

    /// Decorative washes are exempt. An ambient tint or a hover layer scaled by
    /// 2.4 would turn into an edge, which is a different (and wrong) change.
    func testDecorativeOpacitiesAreClampedRatherThanAmplifiedForever() {
        setIncreaseContrast(true)
        XCTAssertLessThanOrEqual(
            CompanionAccessibility.contrastAdjusted(1.0), 0.32,
            "no opacity may be amplified into a solid edge"
        )
        XCTAssertEqual(
            CompanionAccessibility.contrastAdjusted(0.5),
            CompanionAccessibility.contrastAdjusted(1.0),
            "both are past the clamp and must land on the same ceiling"
        )
    }

    /// The elevation ramp keeps its shape — light from above — while every
    /// non-zero stop scales. A ramp that reordered its stops would flip the
    /// light source, which is the one thing the material language forbids.
    func testEdgeRampKeepsItsDirectionUnderIncreaseContrast() {
        // The ramp reads the drawing appearance, so both branches are checked
        // through the same resolved-alpha path the view uses.
        setIncreaseContrast(false)
        let normal = CompanionElevation.edgeRamp.map(alpha)
        setIncreaseContrast(true)
        let strong = CompanionElevation.edgeRamp.map(alpha)

        XCTAssertEqual(normal.count, strong.count)
        for (index, pair) in zip(normal, strong).enumerated() {
            if pair.0 > 0.0001 {
                XCTAssertGreaterThan(
                    pair.1, pair.0,
                    "stop \(index) was already visible and must deepen under the switch"
                )
            } else {
                XCTAssertEqual(
                    pair.1, pair.0, accuracy: 0.0001,
                    "stop \(index) is deliberately clear and must stay clear"
                )
            }
        }
    }

    private func alpha(_ color: Color) -> Double {
        Double(NSColor(color).alphaComponent)
    }

    // MARK: - Differentiate Without Color

    /// The dot has three levels and the app draws them as three hues. With the
    /// switch on, three hues become three silhouettes — otherwise a red/green
    /// colour-blind user, roughly 8 % of men, reads one grey dot in three
    /// positions.
    func testStatusDotHasThreeDistinctShapesUnderDifferentiateWithoutColor() {
        setDifferentiateWithoutColor(true)
        let silhouettes = Set(CompanionStatusDot.Level.allCases.map(\.silhouette))
        XCTAssertEqual(
            silhouettes.count, CompanionStatusDot.Level.allCases.count,
            "two levels would render identically — the switch would do nothing"
        )
    }

    /// With the switch off every level is the same circle, which is what the
    /// screenshots and the WCAG measurements were taken against.
    func testStatusDotIsTheSameShapeWhenTheSwitchIsOff() {
        setDifferentiateWithoutColor(false)
        let silhouettes = Set(CompanionStatusDot.Level.allCases.map(\.silhouette))
        XCTAssertEqual(silhouettes, [.disc], "the default look must not change")
    }
}
