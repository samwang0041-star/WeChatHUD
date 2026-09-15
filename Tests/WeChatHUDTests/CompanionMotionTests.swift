import XCTest
@testable import WeChatHUD

final class CompanionMotionTests: XCTestCase {

    override func tearDown() {
        CompanionMotion.reduceMotionProvider = {
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }
        CompanionMotion.reduceTransparencyProvider = {
            NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        }
        super.tearDown()
    }

    func testAllAnimationsNilWhenReduceMotion() {
        CompanionMotion.reduceMotionProvider = { true }
        XCTAssertTrue(CompanionMotion.reduceMotion)
        XCTAssertNil(CompanionMotion.ease(0.2))
        XCTAssertNil(CompanionMotion.ease())
        XCTAssertNil(CompanionMotion.easeIn(0.2))
        XCTAssertNil(CompanionMotion.easeOut(0.25))
        XCTAssertNil(CompanionMotion.spring)
        XCTAssertNil(CompanionMotion.springResponse(response: 0.6, dampingFraction: 0.8))
        XCTAssertNil(CompanionMotion.press())
        XCTAssertNil(CompanionMotion.systemDefault)
        XCTAssertNil(CompanionMotion.hover())
        XCTAssertNil(CompanionMotion.islandExpand())
        XCTAssertNil(CompanionMotion.islandCollapse())
        XCTAssertNil(CompanionMotion.openMorph)
        XCTAssertNil(CompanionMotion.closeMorph)
        XCTAssertNil(CompanionMotion.pageChange())
        XCTAssertNil(CompanionMotion.rowExpand())
        XCTAssertNil(CompanionMotion.drawer())
        XCTAssertNil(CompanionMotion.dialog())
        XCTAssertNil(CompanionMotion.complete())
        XCTAssertNil(CompanionMotion.saveReceipt())
    }

    func testAllAnimationsNonNilWhenMotionEnabled() {
        CompanionMotion.reduceMotionProvider = { false }
        XCTAssertFalse(CompanionMotion.reduceMotion)
        XCTAssertNotNil(CompanionMotion.ease(0.2))
        XCTAssertNotNil(CompanionMotion.ease())
        XCTAssertNotNil(CompanionMotion.easeIn(0.2))
        XCTAssertNotNil(CompanionMotion.easeOut(0.25))
        XCTAssertNotNil(CompanionMotion.spring)
        XCTAssertNotNil(CompanionMotion.springResponse(response: 0.6, dampingFraction: 0.8))
        XCTAssertNotNil(CompanionMotion.press())
        XCTAssertNotNil(CompanionMotion.systemDefault)
        XCTAssertNotNil(CompanionMotion.hover())
        XCTAssertNotNil(CompanionMotion.islandExpand())
        XCTAssertNotNil(CompanionMotion.islandCollapse())
        XCTAssertNotNil(CompanionMotion.openMorph)
        XCTAssertNotNil(CompanionMotion.closeMorph)
        XCTAssertNotNil(CompanionMotion.rowExpand())
        XCTAssertNotNil(CompanionMotion.drawer())
        XCTAssertNotNil(CompanionMotion.dialog())
        XCTAssertNotNil(CompanionMotion.complete())
        XCTAssertNotNil(CompanionMotion.saveReceipt())
        XCTAssertNotNil(CompanionMotion.pageChange())
    }

    func testIslandFrameTimingReportsSixtyHertzCadence() {
        IslandFrameTiming.begin()
        var t = 100.0
        IslandFrameTiming.tick(uptime: t)
        for _ in 0..<12 {
            t += 1.0 / 60.0
            IslandFrameTiming.tick(uptime: t)
        }
        IslandFrameTiming.finish(duration: 0.23)
        XCTAssertEqual(IslandFrameTiming.lastDuration, 0.23, accuracy: 0.001)
        XCTAssertGreaterThan(IslandFrameTiming.estimatedFPS, 58)
        XCTAssertLessThan(IslandFrameTiming.estimatedFPS, 62)
        IslandFrameTiming.recordInstant()
        XCTAssertTrue(IslandFrameTiming.lastWasInstant)
    }

    func testWithMotionRunsBodyWithoutAnimationWhenNil() {
        var executed = false
        withMotion(nil) { executed = true }
        XCTAssertTrue(executed)
    }

    func testReduceTransparencyIsReadableIndependentlyOfMotion() {
        CompanionMotion.reduceTransparencyProvider = { true }
        XCTAssertTrue(CompanionMotion.reduceTransparency)
        CompanionMotion.reduceMotionProvider = { false }
        XCTAssertNotNil(CompanionMotion.pageChange())
        CompanionMotion.reduceTransparencyProvider = { false }
        XCTAssertFalse(CompanionMotion.reduceTransparency)
    }

    func testIslandExpandProgressPopsOutThenSettles() {
        XCTAssertEqual(IslandMotion.expandProgress(0), 0, accuracy: 0.01)
        XCTAssertEqual(IslandMotion.expandProgress(1), 1, accuracy: 0.02)
        XCTAssertGreaterThan(IslandMotion.expandProgress(0.62), 1.0)
        XCTAssertGreaterThan(IslandMotion.expandDuration, IslandMotion.collapseDuration)
        XCTAssertEqual(IslandChrome.expandedWidth, 560)
    }

    func testIslandCollapseProgressAcceleratesIntoTheNotch() {
        XCTAssertEqual(IslandMotion.collapseProgress(0), 0, accuracy: 0.001)
        XCTAssertEqual(IslandMotion.collapseProgress(1), 1, accuracy: 0.001)
        XCTAssertLessThan(IslandMotion.collapseProgress(0.5), 0.2)
        XCTAssertTrue(IslandMotion.isExpanding(
            from: NSRect(x: 0, y: 0, width: 200, height: 32),
            to: NSRect(x: 0, y: 0, width: 560, height: 320)
        ))
        XCTAssertFalse(IslandMotion.isExpanding(
            from: NSRect(x: 0, y: 0, width: 560, height: 320),
            to: NSRect(x: 0, y: 0, width: 200, height: 32)
        ))
    }

    func testWithMotionRunsBodyWithAnimationWhenProvided() {
        CompanionMotion.reduceMotionProvider = { false }
        var executed = false
        withMotion(CompanionMotion.ease(0.2)) { executed = true }
        XCTAssertTrue(executed)
    }

    func testRetargetToleranceIgnoresLayoutJitterMidFlight() {
        // At rest the panel hugs measurements tightly; mid-flight only a
        // genuine content change (row expand, snooze menu — all 50 pt+)
        // may bend the trajectory, never 1–3 pt of text-settling jitter.
        XCTAssertEqual(IslandMotion.retargetTolerance(isAnimating: false), 2)
        XCTAssertEqual(IslandMotion.retargetTolerance(isAnimating: true), 6)
        XCTAssertGreaterThan(IslandMotion.retargetTolerance(isAnimating: true), 3)
        XCTAssertLessThan(IslandMotion.retargetTolerance(isAnimating: true), 50)
    }

    func testMaskCornerRadiusCapsulesTheCompactBar() {
        XCTAssertEqual(IslandMotion.maskCornerRadius(width: 297, height: 32), 16)
        XCTAssertEqual(IslandMotion.maskCornerRadius(width: 560, height: 252), 22)
    }

    func testStrongEaseOutRespectsReduceMotion() {
        CompanionMotion.reduceMotionProvider = { false }
        XCTAssertNotNil(CompanionMotion.strongEaseOut())
        CompanionMotion.reduceMotionProvider = { true }
        XCTAssertNil(CompanionMotion.strongEaseOut())
    }

    /// A press has to be visible. 1.0 is a no-op and anything at or below
    /// 0.92 reads as rubber, so the token is pinned inside the usable band.
    func testPressScaleIsInsideTheVisibleButNotRubberyBand() {
        XCTAssertGreaterThanOrEqual(CompanionMotion.pressScale, 0.92)
        XCTAssertLessThanOrEqual(CompanionMotion.pressScale, 0.97)
        XCTAssertLessThan(CompanionMotion.pressScale, 1)
        XCTAssertGreaterThanOrEqual(CompanionMotion.pressDuration, 0.10)
        XCTAssertLessThanOrEqual(CompanionMotion.pressDuration, 0.14)
    }

    func testHoverIsAShortEaseOutAttack() {
        XCTAssertEqual(CompanionMotion.hoverDuration, 0.10, accuracy: 0.001)
        XCTAssertLessThan(CompanionMotion.hoverDuration, CompanionMotion.easeDuration)
    }

    func testPageChangeIsLongerThanInPlaceDisclosure() {
        XCTAssertGreaterThan(CompanionMotion.pageChangeDuration, CompanionMotion.easeDuration)
        XCTAssertLessThanOrEqual(CompanionMotion.pageChangeDuration, 0.28)
    }

    func testExpandMorphIsSlowerAndPoppierThanCollapse() {
        XCTAssertGreaterThan(CompanionMotion.morphExpandResponse, CompanionMotion.morphCollapseResponse)
        XCTAssertLessThan(CompanionMotion.morphExpandDamping, CompanionMotion.morphCollapseDamping)
        XCTAssertLessThan(CompanionMotion.morphExpandDamping, 1.0)
        XCTAssertGreaterThanOrEqual(CompanionMotion.morphCollapseDamping, 0.85)
        XCTAssertEqual(CompanionMotion.morphExpandResponse, 0.42, accuracy: 0.001)
        XCTAssertEqual(CompanionMotion.morphCollapseResponse, 0.30, accuracy: 0.001)
    }

    func testIslandFrameExpandIsUnderdampedAndCollapseIsCritical() {
        let expand = IslandMotion.spring(expanding: true, distance: 120)
        let collapse = IslandMotion.spring(expanding: false, distance: 120)
        XCTAssertGreaterThan(collapse.stiffness, expand.stiffness, "collapse must be snappier")
        XCTAssertGreaterThan(collapse.damping, expand.damping)
    }

    // MARK: - Island silhouette

    /// The silhouette has to *reshape*, not just resize.
    ///
    /// Before this, all three radii were hardcoded literals (22 / 10 / 16) at
    /// every call site and identical in every state, so an opening island could
    /// only stretch — its corners stayed pinned to a 32pt pill while the body
    /// grew to 250pt. That is the difference between "a window got taller" and
    /// "the island opened", and it is not visible in a screenshot of either end
    /// state. This asserts the ends actually differ.
    func testSilhouetteRadiiDifferBetweenClosedAndOpen() {
        let closed = IslandChrome.radii(for: .compact)
        let open = IslandChrome.radii(for: .extended)
        XCTAssertNotEqual(
            closed, open,
            "a silhouette with identical radii in both states can only scale, not unfold"
        )
        XCTAssertNotEqual(closed.pill, open.pill)
    }

    /// Peek is the pill shape — the same geometry as compact, because it *is*
    /// the compact pill widening. Giving it the open radii would make the hover
    /// state reshape before the island has actually opened.
    func testPeekSharesTheCompactPillGeometry() {
        XCTAssertEqual(IslandChrome.radii(for: .peek), IslandChrome.radii(for: .compact))
    }

    /// Every state that draws a body uses the open radii, so the silhouette
    /// cannot differ between an inbox, a banner and the detail surface.
    func testEveryBodyStateSharesOneGeometry() {
        let extended = IslandChrome.radii(for: .extended)
        XCTAssertEqual(IslandChrome.radii(for: .notification), extended)
        XCTAssertEqual(IslandChrome.radii(for: .detail), extended)
    }

    /// The radii must be *animatable*, or the reshape above still snaps.
    ///
    /// This is the part that is easy to get wrong: the shape is rebuilt every
    /// frame from `presentedState`, so without `animatableData` SwiftUI has no
    /// way to interpolate between the two radius sets and the corners jump.
    func testSilhouetteRadiiAreAnimatable() {
        var shape = IslandShape(
            notchWidth: 185, notchHeight: 32,
            pillCornerRadius: IslandChrome.pillRadiusClosed,
            notchCornerRadius: IslandChrome.notchRadiusClosed,
            topCornerRadius: IslandChrome.topRadiusClosed
        )
        let closed = shape.animatableData
        shape.animatableData = .init(
            .init(IslandChrome.pillRadiusOpen, IslandChrome.notchRadiusOpen),
            IslandChrome.topRadiusOpen
        )
        XCTAssertEqual(shape.pillCornerRadius, IslandChrome.pillRadiusOpen)
        XCTAssertEqual(shape.notchCornerRadius, IslandChrome.notchRadiusOpen)
        XCTAssertEqual(shape.topCornerRadius, IslandChrome.topRadiusOpen)
        XCTAssertNotEqual(closed, shape.animatableData)
    }

    /// Hardware geometry must NOT animate. The notch cutout is measured from
    /// the real display; interpolating it would slide the cutout off the
    /// physical notch for the length of every transition.
    func testNotchGeometryIsNotPartOfAnimatableData() {
        var shape = IslandShape(
            notchWidth: 185, notchHeight: 32,
            pillCornerRadius: 22, notchCornerRadius: 10, topCornerRadius: 16
        )
        shape.animatableData = .init(.init(16, 12), 20)
        XCTAssertEqual(shape.notchWidth, 185, "the cutout must stay on the hardware notch")
        XCTAssertEqual(shape.notchHeight, 32)
    }

    /// The silhouette spring matches the frame spring, not the content morph.
    /// A mismatch here makes the corners lead or lag the edges.
    func testSilhouetteSpringMatchesTheFrameSpring() {
        let expand = CompanionMotion.islandSilhouette(expanding: true)
        let collapse = CompanionMotion.islandSilhouette(expanding: false)
        XCTAssertNotNil(expand)
        XCTAssertNotNil(collapse)
        // The window-frame spring is response 0.42 / damping 0.82 out and
        // 0.26 / 1.0 back. The content morph’s 0.30 / 0.88 is a different
        // pair on purpose, so the two must not be the same value.
        XCTAssertNotEqual(
            collapse, CompanionMotion.closeMorph,
            "the silhouette must ride the frame spring, not the content morph"
        )
    }

    /// Reduce Motion removes the reshape rather than delaying it.
    func testSilhouetteAnimationIsDisabledUnderReduceMotion() {
        let original = CompanionMotion.reduceMotionProvider
        defer { CompanionMotion.reduceMotionProvider = original }
        CompanionMotion.reduceMotionProvider = { true }
        XCTAssertNil(CompanionMotion.islandSilhouette(expanding: true))
        XCTAssertNil(CompanionMotion.islandSilhouette(expanding: false))
    }

    /// No call site may hardcode the silhouette radii.
    ///
    /// The bug this prevents is specific and was live: three call sites each
    /// passed 22 / 10 / 16 as literals, and one of them (the content chrome’s
    /// UnevenRoundedRectangle) was pinned at 22. Once the radii became
    /// state-driven, every literal was a place the silhouette could silently
    /// stop matching the shape it is supposed to be drawing.
    func testSilhouetteRadiiAreNotHardcodedAtCallSites() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/WeChatHUD")
        var files: [URL] = []
        if let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) {
            for case let url as URL in walker where url.pathExtension == "swift" {
                files.append(url)
            }
        }
        XCTAssertFalse(files.isEmpty)

        var offenders: [String] = []
        for file in files {
            // IslandShape defines the properties; CompanionMotion defines the
            // values. Everywhere else must read them from IslandChrome.
            guard file.lastPathComponent != "IslandShape.swift",
                  file.lastPathComponent != "CompanionMaterial.swift",
                  file.lastPathComponent != "CompanionMotion.swift" else { continue }
            let text = try String(contentsOf: file, encoding: .utf8)
            for (index, line) in text.components(separatedBy: .newlines).enumerated() {
                for key in ["pillCornerRadius:", "notchCornerRadius:", "topCornerRadius:", "bottomLeading:", "bottomTrailing:"] {
                    guard let range = line.range(of: key) else { continue }
                    let tail = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
                    // Reading from the shared source is the only allowed form.
                    if !tail.hasPrefix("radii.")
                        && !tail.hasPrefix("chromeRadii.")
                        && !tail.hasPrefix("IslandChrome.")
                        && !tail.hasPrefix("self.") {
                        offenders.append("\(file.lastPathComponent):\(index + 1) \(line.trimmingCharacters(in: .whitespaces))")
                    }
                }
            }
        }
        XCTAssertTrue(
            offenders.isEmpty,
            "silhouette radii hardcoded instead of read from IslandChrome: \(offenders.joined(separator: " | "))"
        )
    }
}
