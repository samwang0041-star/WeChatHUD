import XCTest
import SwiftUI
@testable import WeChatHUD

/// Drift guard for the external HUD's type and spacing tokens.
///
/// The island surfaces had grown to 24pt bold headlines and 36pt avatars on a
/// 560pt-wide panel, which is what made the HUD read as a phone app for a
/// much smaller screen. These assertions are deliberately about *bounds*
/// rather than exact values: the numbers may be tuned, but they must stay in
/// macOS-native territory and the height estimate must agree with the rows it
/// estimates.
final class IslandStyleTests: XCTestCase {

    // MARK: - Type stays in a native range

    func testTypeTokensStayWithinNativeMacOSRange() {
        // macOS UI text for a panel this size lives at 11-13pt; the largest
        // thing the island draws (a count headline or a quoted message) may
        // reach 15-16 but no further.
        XCTAssertLessThanOrEqual(IslandType.display, 16)
        XCTAssertLessThanOrEqual(IslandType.brand, 14)
        XCTAssertLessThanOrEqual(IslandType.rowTitle, 13.5)
        XCTAssertLessThanOrEqual(IslandType.rowBody, 13)
        XCTAssertLessThanOrEqual(IslandType.button, 13)
        XCTAssertLessThanOrEqual(IslandType.section, 12)
        XCTAssertLessThanOrEqual(IslandType.meta, 11.5)
        XCTAssertLessThanOrEqual(IslandType.micro, 11)
    }

    func testTypeRampIsOrdered() {
        XCTAssertGreaterThan(IslandType.display, IslandType.rowTitle)
        XCTAssertGreaterThan(IslandType.rowTitle, IslandType.rowBody)
        XCTAssertGreaterThanOrEqual(IslandType.rowBody, IslandType.button)
        XCTAssertGreaterThan(IslandType.rowBody, IslandType.meta)
        XCTAssertGreaterThan(IslandType.meta, IslandType.micro)
    }

    /// No text may go below 10pt, which is the floor `companionFont` already
    /// enforces at the default Dynamic Type size.
    func testTypeRampRespectsReadabilityFloor() {
        for size in [IslandType.display, IslandType.brand, IslandType.rowTitle, IslandType.rowBody,
                     IslandType.button, IslandType.section, IslandType.meta, IslandType.micro] {
            XCTAssertGreaterThanOrEqual(size, 10)
        }
    }

    // MARK: - Row geometry agrees with the size estimate

    func testRowHeightFitsItsOwnContents() {
        // A row cannot be shorter than the avatar it centres plus its padding.
        XCTAssertGreaterThanOrEqual(IslandMetrics.rowHeight, IslandMetrics.avatar + 2 * IslandMetrics.rowPadding)
        XCTAssertLessThan(IslandMetrics.rowHeight, IslandMetrics.avatar + 2 * IslandMetrics.rowPadding + 16,
                          "a row taller than avatar + padding + slack means the estimate and the layout have drifted apart")
    }

    func testInboxSizeEstimateAccountsForEveryRow() {
        let (_, height) = inboxSize(actionCount: 3, hasHandled: false)
        let (_, fourRows) = inboxSize(actionCount: 4, hasHandled: false)
        XCTAssertGreaterThan(height, 3 * IslandMetrics.rowHeight,
                             "the estimate must leave room for the rows plus the chrome around them")
        XCTAssertEqual(fourRows - height, IslandMetrics.rowHeight, accuracy: 0.001,
                       "an extra row must add exactly one row height")
    }

    func testInboxSizeEstimateLeavesRoomForBottomBar() {
        let (_, height) = inboxSize(actionCount: 1, hasHandled: false)
        XCTAssertGreaterThan(height, IslandMetrics.rowHeight + IslandMetrics.buttonHeight,
                             "one row plus the bottom bar must fit in the estimate")
    }

    func testHandledFooterAddsSpaceAndEmptyStateStaysCompact() {
        let (_, without) = inboxSize(actionCount: 2, hasHandled: false)
        let (_, with) = inboxSize(actionCount: 2, hasHandled: true)
        XCTAssertGreaterThan(with, without, "the handled footer needs its own band")

        let (_, empty) = inboxSize(actionCount: 0, hasHandled: false)
        XCTAssertLessThan(empty, 300, "the empty state must not open a tall empty panel")
    }

    // MARK: - Ink ramp

    func testInkRampIsMonotonicAndOrdered() {
        // White alphas: primary is the most present, quaternary the faintest.
        let ramp = [IslandInk.primary, IslandInk.secondary, IslandInk.tertiary, IslandInk.quaternary]
        let alphas: [CGFloat] = ramp.map { c in c.opacityValue }
        for (a, b) in zip(alphas, alphas.dropFirst()) {
            XCTAssertGreaterThan(a, b, "the ink ramp must descend; found \(a) then \(b)")
        }
        XCTAssertLessThanOrEqual(alphas.first! , 1)
        // Dividers and washes sit below text so they never compete with it.
        XCTAssertLessThan(IslandInk.divider.opacityValue, alphas.last!)
        XCTAssertLessThan(IslandInk.hover.opacityValue, IslandInk.chip.opacityValue)
        XCTAssertLessThan(IslandInk.chip.opacityValue, IslandInk.chipStrong.opacityValue)
        XCTAssertLessThanOrEqual(IslandInk.chipStrong.opacityValue, 1,
                                 "chip washes must be literal alphas, not multiples that clamp")
    }
}

private extension Color {
    /// Alpha of a colour built from `Color.white.opacity(_:)`. Resolving
    /// through NSColor is the only public route back to the component.
    var opacityValue: CGFloat {
        CGFloat(NSColor(self).alphaComponent)
    }
}
