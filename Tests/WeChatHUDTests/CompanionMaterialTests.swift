import XCTest
import SwiftUI
@testable import WeChatHUD

/// Gates for the depth/light language and the interaction-copy layer.
///
/// The material system is easy to erode: one call site adds a hard shadow,
/// another invents its own card fill, and a year later the app has four
/// notions of "raised". These assert the tokens themselves — the numbers a
/// future edit would have to break on purpose — plus the rules the copy
/// layer is written to hold.
final class CompanionMaterialTests: XCTestCase {

    // MARK: - Elevation

    /// A card has to be lighter at the top than at the bottom, otherwise the
    /// surface does not read as lit from above and the whole language
    /// collapses into a flat rectangle with a border.
    func testTopHighlightIsBrighterThanTheBottomEdge() {
        let top = CompanionElevation.topHighlightOpacity
        let bottom = CompanionElevation.bottomShadeOpacity
        XCTAssertGreaterThan(top, 0, "a card with no top highlight reads as a plain rectangle")
        XCTAssertGreaterThan(
            top, bottom,
            "the face must be lit from above: top highlight has to outrank the bottom shade"
        )
    }

    /// Hover elevation is a nudge, not a jump. The band keeps a hover state
    /// from becoming the most noticeable event on a dense page.
    func testHoverLiftStaysSubtle() {
        XCTAssertGreaterThan(CompanionElevation.hoverLift, 0)
        XCTAssertLessThanOrEqual(
            CompanionElevation.hoverLift, 2,
            "a card that moves more than ~2pt on hover reads as a twitch at list density"
        )
        XCTAssertGreaterThan(
            CompanionElevation.hoverShadowRadius, CompanionElevation.cardShadowRadius,
            "hover should spread the shadow rather than keeping it identical"
        )
    }
    /// Every module has to render a wash in **both** appearances.
    ///
    /// The bug this locks: the first luminance model only ever *brightened*
    /// the ground and guarded on `luminance(tint) > luminance(canvas)`, which is
    /// false for every accent against a near-white canvas. The wash therefore
    /// resolved to alpha 0 in light appearance and the feature was silently
    /// absent in half the app. The loop below is over appearances, not just
    /// modules, because a per-module test would not have caught it.
    func testEveryModuleRendersAWashInBothAppearances() {
        for appearance: Appearance in [.dark, .light] {
            for tab in SettingsView.Tab.allCases {
                let alpha = CompanionElevation.ambientAlpha(
                    for: tab.accentColor, intensity: 1, appearance: appearance
                )
                XCTAssertGreaterThan(
                    alpha, 0,
                    "\(tab.rawValue) has no wash in \(appearance)"
                )
            }
        }
    }

    /// The wash must be perceptible, not merely non-zero.
    func testEveryModuleWashIsPerceptiblyStrong() {
        for appearance: Appearance in [.dark, .light] {
            for tab in SettingsView.Tab.allCases {
                let spread = washSpread(tab.accentColor, appearance: appearance, intensity: 1)
                XCTAssertGreaterThanOrEqual(
                    spread, 5.0,
                    "\(tab.rawValue) renders \(spread)/255 of channel spread in \(appearance)"
                )
            }
        }
    }

    /// The strongest module may not run away from the weakest — the whole point
    /// of normalising by the accent’s own channel spread.
    func testModuleWashesAreNormalisedWithinEachAppearance() {
        for appearance: Appearance in [.dark, .light] {
            let strengths = SettingsView.Tab.allCases.map {
                washSpread($0.accentColor, appearance: appearance, intensity: 1)
            }
            guard let lo = strengths.min(), let hi = strengths.max(), lo > 0 else {
                return XCTFail("no module rendered a wash in \(appearance)")
            }
            XCTAssertLessThanOrEqual(
                hi / lo, 4.0,
                "in \(appearance) the strongest module reads a factor of \(hi / lo) over the weakest"
            )
        }
    }

    /// The wash is a readability budget, not a taste call.
    ///
    /// The page header sits in the band where the wash peaks, and its subtitle
    /// uses the brighter on-wash step in dark appearance. At the strongest
    /// module tint the composited ground still has to keep that step at WCAG AA.
    func testStrongestModuleTintKeepsOnWashTextAtAA() {
        // 1.5 is the strongest intensity any surface passes (guide, onboarding).
        let worstIntensity = 1.5
        for tab in SettingsView.Tab.allCases {
            let ground = washedGround(tab.accentColor, appearance: .dark, intensity: worstIntensity)
            let text = [Double](repeating: CompanionElevation.onWashTextOpacity, count: 3)
            let ratio = CompanionElevation.contrastRatio(ground, text)
            XCTAssertGreaterThanOrEqual(
                ratio, CompanionElevation.aaNormalText,
                "\(tab.rawValue) tints its ground to a \(ratio):1 ratio for on-wash text"
            )
        }
    }

    /// Light appearance must not wash the ground *down* into unreadable text.
    func testLightAppearanceWashKeepsItsGroundAboveTheFloor() {
        let floor = CompanionElevation.lightAppearanceGroundFloor
        for tab in SettingsView.Tab.allCases {
            let ground = washedGround(tab.accentColor, appearance: .light, intensity: 1.5)
            XCTAssertGreaterThanOrEqual(
                CompanionElevation.relativeLuminance(ground), floor,
                "\(tab.rawValue) darkens the light ground below the readable floor"
            )
        }
    }

    /// The two appearances read the same amount of change.
    ///
    /// A tint over near-white is far more visible than over near-black, so the
    /// light wash is deliberately scaled down. This is the balance being kept.
    func testLightWashIsWeakerThanTheDarkOne() {
        let dark = washedGround(CompanionPalette.jade, appearance: .dark, intensity: 1)
        let light = washedGround(CompanionPalette.jade, appearance: .light, intensity: 1)
        guard let dHi = dark.max(), let dLo = dark.min(),
              let lHi = light.max(), let lLo = light.min() else {
            return XCTFail("ground composites produced no components")
        }
        let darkSpread = (dHi - dLo) * 255
        let lightSpread = (lHi - lLo) * 255
        XCTAssertLessThan(
            lightSpread, darkSpread,
            "a tint on a near-white ground must be scaled down, not matched"
        )
        XCTAssertGreaterThan(lightSpread, 0)
    }

    /// The request band is sane, and the ceiling is derived rather than guessed.
    func testAmbientTintRequestStaysSane() {
        XCTAssertGreaterThan(CompanionElevation.ambientTint, 0)
        XCTAssertLessThanOrEqual(CompanionElevation.ambientTint, 0.60)
        XCTAssertGreaterThan(CompanionElevation.ambientPeakGroundLuminance, 0)
        XCTAssertLessThanOrEqual(
            CompanionElevation.ambientPeakGroundLuminance,
            CompanionElevation.ambientLuminanceCeiling,
            "the target ground is brighter than on-wash text can read on"
        )
    }

    private typealias Appearance = CompanionElevation.CompanionAppearance

    /// Channel spread (max - min, in 0...255) of the washed ground for a tint.
    private func washSpread(
        _ tint: Color,
        appearance: CompanionElevation.CompanionAppearance,
        intensity: Double
    ) -> Double {
        let ground = washedGround(tint, appearance: appearance, intensity: intensity)
        guard let hi = ground.max(), let lo = ground.min() else { return 0 }
        return (hi - lo) * 255
    }

    /// Composite `tint` over the canvas at the alpha the system picks.
    private func washedGround(
        _ tint: Color,
        appearance: CompanionElevation.CompanionAppearance,
        intensity: Double
    ) -> [Double] {
        let base = CompanionElevation.canvasRGB(for: appearance)
        let top = CompanionElevation.resolveRGB(tint)
        let alpha = CompanionElevation.ambientAlpha(
            for: tint, intensity: intensity, appearance: appearance
        )
        return zip(base, top).map { $0 * (1 - alpha) + $1 * alpha }
    }

    func testCardRadiusOutranksInsetRadius() {
        XCTAssertGreaterThan(
            CompanionElevation.cardRadius, CompanionElevation.insetRadius,
            "a nested well must have a tighter radius than the card holding it"
        )
    }

    // MARK: - Stagger

    /// The stagger budget is the whole point: long enough to feel ordered,
    /// short enough that a tab switch does not read as a slow app.
    func testStaggerSpanStaysWithinAPerceptibleButQuickWindow() {
        XCTAssertGreaterThanOrEqual(
            CompanionMotion.staggerSpan, 0.15,
            "below ~150ms the group reads as arriving at once"
        )
        XCTAssertLessThanOrEqual(
            CompanionMotion.staggerSpan, 0.40,
            "above ~400ms the page reads as still loading"
        )
    }

    /// The delay is capped, so a long list does not leave its last row
    /// waiting behind rows that will never arrive.
    func testStaggerDelayIsCappedForLongLists() {
        XCTAssertEqual(
            CompanionMotion.staggerDelay(index: 40),
            CompanionMotion.staggerDelay(index: 6),
            "index 40 must not wait longer than the cap"
        )
    }

    func testStaggerRiseStaysSmall() {
        XCTAssertLessThanOrEqual(
            CompanionMotion.staggerRise, 8,
            "a large rise turns a page load into an animation the user waits out"
        )
    }

    /// Reduce Motion removes the movement rather than the delay. A caller
    /// must get no animation at all, so content is simply present.
    func testStaggerIsDisabledUnderReduceMotion() {
        let original = CompanionMotion.reduceMotionProvider
        defer { CompanionMotion.reduceMotionProvider = original }
        CompanionMotion.reduceMotionProvider = { true }
        XCTAssertNil(CompanionMotion.staggerEntrance(index: 2))
        XCTAssertNil(CompanionMotion.pulse())
        XCTAssertNil(CompanionMotion.cardHover())
        XCTAssertNil(CompanionMotion.sidebarSelection())
    }

    // MARK: - Interaction copy

    /// Every page hint has to say something the label does not. A hint that
    /// repeats the label is dead weight in the tooltip and noise in
    /// VoiceOver.
    func testEveryPageHintSaysMoreThanItsLabel() {
        for tab in SettingsView.Tab.allCases {
            let hint = CompanionInteractionCopy.pageHint(for: tab.rawValue)
            XCTAssertFalse(hint.isEmpty, "\(tab.rawValue) has no hover promise")
            XCTAssertNotEqual(
                hint, tab.label,
                "\(tab.rawValue) hint just repeats the label"
            )
        }
    }

    /// Unknown tabs fall back rather than producing an empty tooltip.
    func testUnknownPageHintFallsBack() {
        XCTAssertFalse(CompanionInteractionCopy.pageHint(for: "nope").isEmpty)
    }

    /// A failure sentence always carries a next step. This is the rule the
    /// copy layer exists for: never a bare failure.
    func testFailureCopyAlwaysCarriesANextStep() {
        for next in [
            CompanionInteractionCopy.retryOrOpenWeChat,
            CompanionInteractionCopy.needAccessibility,
            CompanionInteractionCopy.needAIService,
            CompanionInteractionCopy.needWeChatRunning
        ] {
            XCTAssertFalse(next.isEmpty)
            XCTAssertGreaterThan(next.count, 6, "a next step has to be actionable: \(next)")
        }
    }

    /// Empty states are a message and a move. The views pair these with a
    /// button, so the strings themselves must not be a dead end.
    func testEmptyStatesAreNotDeadEnds() {
        XCTAssertFalse(CompanionInteractionCopy.noReplyNeeded.isEmpty)
        XCTAssertFalse(CompanionInteractionCopy.noReplyNeededNext.isEmpty)
        XCTAssertFalse(CompanionInteractionCopy.noTasksDetectedNext.isEmpty)
        XCTAssertFalse(CompanionInteractionCopy.noDraftsNext.isEmpty)
        XCTAssertFalse(CompanionInteractionCopy.noPendingRepliesNext.isEmpty)
    }

    /// Counts read as sentences, including at zero.
    func testMomentumCountsReadAtZeroAndAtN() {
        XCTAssertTrue(CompanionInteractionCopy.handledToday(0).contains("还没"))
        XCTAssertTrue(CompanionInteractionCopy.handledToday(3).contains("3"))
        XCTAssertTrue(CompanionInteractionCopy.waitingOnOthers(0).contains("没有"))
        XCTAssertTrue(CompanionInteractionCopy.waitingOnOthers(2).contains("2"))
    }

    /// Every module owns a colour, and they are not all the same one — the
    /// point of the tile is that a sidebar can be scanned by shape.
    func testEveryModuleHasItsOwnAccent() {
        let accents = SettingsView.Tab.allCases.map { "\($0.accentColor)" }
        XCTAssertEqual(accents.count, SettingsView.Tab.allCases.count)
        XCTAssertGreaterThan(
            Set(accents).count, 4,
            "the sidebar relies on distinct module colours"
        )
    }

    /// A settings group whose header repeats the title of the row beneath it
    /// prints the same sentence twice in a row, which reads as a rendering
    /// fault. This caught 自动回复 / 使用偏好 / AI 服务 doing exactly that.
    func testSettingsSectionsDoNotRepeatTheirOnlyRowsTitle() throws {
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

        let pattern = try NSRegularExpression(
            pattern: "SettingsSection\\(([^)\\n]+)\\)\\s*\\{\\s*\\n\\s*(?:if[^\\n]*\\{\\s*\\n\\s*)?SettingsRow\\(([^,\\n]+)",
            options: []
        )
        var offenders: [String] = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in pattern.matches(in: text, range: range) {
                guard let a = Range(match.range(at: 1), in: text),
                      let b = Range(match.range(at: 2), in: text) else { continue }
                let header = text[a].trimmingCharacters(in: .whitespaces)
                let row = text[b].trimmingCharacters(in: .whitespaces)
                if header == row {
                    offenders.append("\(file.lastPathComponent): \(header)")
                }
            }
        }
        XCTAssertTrue(
            offenders.isEmpty,
            "a settings header repeats its only row title: \(offenders.joined(separator: ", "))"
        )
    }
}
