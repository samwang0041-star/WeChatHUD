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

    // MARK: - Dimmed text: the half the border ramp never reached

    /// The canvas the island-detail and retrospective panels composite onto.
    /// Their own fill is `Color.black.opacity(0.94…0.96)` over a lightened
    /// panel material, so ~6 % white is the honest worst case — a darker guess
    /// would flatter every caption in this file.
    private static let darkCanvas = 0.06

    private func relativeLuminance(_ channel: Double) -> Double {
        let c = max(0, min(1, channel))
        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    /// WCAG contrast ratio for `Color.white.opacity(alpha)` over `canvas`.
    private func contrastRatio(whiteAlpha: Double) -> Double {
        let canvas = Self.darkCanvas
        let foreground = relativeLuminance(canvas + whiteAlpha * (1 - canvas))
        let background = relativeLuminance(canvas)
        return (max(foreground, background) + 0.05) / (min(foreground, background) + 0.05)
    }

    /// The defect in numbers: the dimmest caption the app shipped sat at 2.7:1,
    /// well under the 4.5:1 that WCAG calls the floor for body text. Pinning the
    /// *un-ramped* value keeps the fix from being argued away as cosmetics.
    func testUnrampedCaptionsReallyDidFailLegibility() {
        setIncreaseContrast(false)
        XCTAssertLessThan(
            contrastRatio(whiteAlpha: CompanionAccessibility.foregroundOpacity(0.35)), 4.5,
            "if 0.35 ever stops failing, the ramp below is solving a problem that is gone"
        )
    }

    /// Every opacity actually written into a view must clear AA once the switch
    /// is on. Scanning the shipped source rather than a hand-picked list is the
    /// point: a new `companionDimmedForeground(0.1)` added next month fails here.
    func testEveryShippedDimmedCaptionClearsWCAGAAUnderIncreaseContrast() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/WeChatHUD")

        var found: [(file: String, nominal: Double)] = []
        var files: [URL] = []
        if let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) {
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                files.append(url)
            }
        }
        for url in files {
            let text = try String(contentsOf: url, encoding: .utf8)
            for chunk in text.components(separatedBy: "companionDimmedForeground(").dropFirst() {
                guard let close = chunk.firstIndex(of: ")") else { continue }
                let literal = String(chunk[..<close]).trimmingCharacters(in: .whitespaces)
                guard let nominal = Double(literal) else { continue }
                found.append((url.lastPathComponent, nominal))
            }
        }
        XCTAssertGreaterThanOrEqual(
            found.count, 20,
            "the scan found \(found.count) call sites — the ramp is applied at 35, so a drop this large means the scan broke, not the app"
        )

        setIncreaseContrast(true)
        for site in found {
            let ramped = CompanionAccessibility.foregroundOpacity(site.nominal)
            XCTAssertGreaterThanOrEqual(
                contrastRatio(whiteAlpha: ramped), 4.5,
                "\(site.file)'s \(site.nominal) caption lifts to \(ramped) under Increase Contrast, which is still \(String(format: "%.1f", contrastRatio(whiteAlpha: ramped))):1"
            )
        }
    }

    /// Off, nothing moves: these are the exact values every screenshot and
    /// WCAG measurement in the QA log was taken against.
    func testDimmedForegroundIsExactlyTheDesignedOpacityWhenTheSwitchIsOff() {
        setIncreaseContrast(false)
        for nominal in [0.3, 0.35, 0.45, 0.56, 0.82, 0.94] {
            XCTAssertEqual(
                CompanionAccessibility.foregroundOpacity(nominal), nominal,
                accuracy: 0.0001,
                "a user who never opened 辅助功能 must see the app that was measured"
            )
        }
    }

    /// The ramp may only add legibility, never reorder the hierarchy: a caption
    /// that was quieter than its title has to stay quieter, and primary text is
    /// already loud enough to leave alone.
    func testRampLiftsMonotonicallyAndLeavesPrimaryTextAlone() {
        setIncreaseContrast(true)
        var previous = 0.0
        for nominal in stride(from: 0.2, through: 1.0, by: 0.02) {
            let ramped = CompanionAccessibility.foregroundOpacity(nominal)
            XCTAssertGreaterThanOrEqual(ramped, previous - 0.0001, "hierarchy reordered at \(nominal)")
            XCTAssertGreaterThanOrEqual(ramped, nominal, "the switch may not dim anything")
            previous = ramped
        }
        for primary in [0.88, 0.9, 0.92, 0.94, 1.0] {
            XCTAssertEqual(
                CompanionAccessibility.foregroundOpacity(primary), primary, accuracy: 0.0001,
                "primary text is the loudest thing on the surface already"
            )
        }
    }
}
