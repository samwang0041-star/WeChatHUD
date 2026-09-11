import XCTest
import SwiftUI
import AppKit
@testable import WeChatHUD

/// Surfaces and the text drawn on them must resolve in the *same* appearance.
///
/// Reported as "夜间模式右边是白色的 啥都看不到": in dark mode the settings
/// sidebar was a #F3F5F4 slab with #FDFDFD labels — a measured 1.05:1, i.e.
/// invisible. The slab was a fixed light color while the labels used
/// `.primary`, which resolves to white in dark mode.
@MainActor
final class SurfaceColorSchemeTests: XCTestCase {

    private func resolve(_ color: Color, as name: NSAppearance.Name) -> NSColor {
        var resolved = NSColor.black
        let appearance = NSAppearance(named: name)!
        appearance.performAsCurrentDrawingAppearance {
            let dynamic = NSColor(color)
            resolved = dynamic.usingColorSpace(.sRGB)
                ?? NSColor(cgColor: dynamic.cgColor) ?? .black
        }
        return resolved
    }

    private func relativeLuminance(_ color: NSColor) -> Double {
        func linear(_ value: Double) -> Double {
            value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.redComponent)
            + 0.7152 * linear(color.greenComponent)
            + 0.0722 * linear(color.blueComponent)
    }

    private func contrast(_ lhs: NSColor, _ rhs: NSColor) -> Double {
        let a = relativeLuminance(lhs)
        let b = relativeLuminance(rhs)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// Every surface a pane paints behind scheme-aware text has to move with
    /// the scheme. A fixed light value here is what produced the white slab.
    func testSurfacesFollowTheColorScheme() {
        let surfaces: [(name: String, color: Color)] = [
            ("mist", CompanionPalette.mist),
            ("canvas", CompanionPalette.canvas),
            ("surface", CompanionPalette.surface)
        ]
        for surface in surfaces {
            let light = resolve(surface.color, as: .aqua)
            let dark = resolve(surface.color, as: .darkAqua)
            XCTAssertGreaterThan(
                relativeLuminance(light), relativeLuminance(dark),
                surface.name + " must be lighter in light mode than in dark mode"
            )
            XCTAssertGreaterThan(
                relativeLuminance(light) - relativeLuminance(dark), 0.2,
                surface.name + " barely changes between schemes"
            )
        }
    }

    /// The exact pairing from the report: the sidebar plate under .primary text.
    func testSidebarTextIsReadableInDarkMode() {
        let slab = resolve(CompanionPalette.mist, as: .darkAqua)
        let label = resolve(Color.primary, as: .darkAqua)
        let secondary = resolve(Color.secondary, as: .darkAqua)

        XCTAssertGreaterThan(
            contrast(slab, label), 7.0,
            "primary sidebar labels need AAA contrast on the dark slab"
        )
        XCTAssertGreaterThan(
            contrast(slab, secondary), 3.0,
            "secondary sidebar labels still have to be legible"
        )
    }

    /// The panes must stay distinguishable in dark mode: the sidebar is a few
    /// steps darker than the canvas, not the same plate.
    func testSidebarAndCanvasRemainDistinctInDarkMode() {
        let sidebar = relativeLuminance(resolve(CompanionPalette.mist, as: .darkAqua))
        let canvas = relativeLuminance(resolve(CompanionPalette.canvas, as: .darkAqua))
        XCTAssertLessThan(sidebar, canvas, "the sidebar sits behind the canvas in dark mode")
        XCTAssertGreaterThan(canvas - sidebar, 0.002, "the two panes collapsed into one plate")
    }

    /// The island's detail plate is a CALayer color. A dynamic NSColor resolves
    /// into one concrete CGColor at assignment and a layer never re-resolves it,
    /// so the plate has to be rewritten when the effective appearance changes —
    /// otherwise it keeps the scheme it was created in while the SwiftUI text
    /// follows the window.
    func testSettingsPlateReResolvesWhenAppearanceChanges() {
        let container = PillContainerView()
        container.appearance = NSAppearance(named: .aqua)
        container.plateColor = .windowBackgroundColor
        let lightPlate = assignment(of: container)

        container.appearance = NSAppearance(named: .darkAqua)
        container.viewDidChangeEffectiveAppearance()
        let darkPlate = assignment(of: container)

        XCTAssertGreaterThan(lightPlate.redComponent, 0.8, "light plate should be near-white")
        XCTAssertLessThan(darkPlate.redComponent, 0.3, "dark plate should be near-black")
    }

    /// Island states must stay transparent (IslandShape paints the notch
    /// silhouette), and an appearance change must not bring the plate back.
    func testIslandStateKeepsTheContainerTransparent() {
        let container = PillContainerView()
        container.plateColor = .windowBackgroundColor
        container.appearance = NSAppearance(named: .darkAqua)
        container.viewDidChangeEffectiveAppearance()
        XCTAssertGreaterThan(
            assignment(of: container).alphaComponent, 0.9,
            "the detail state paints an opaque plate"
        )

        container.plateColor = nil
        container.appearance = NSAppearance(named: .aqua)
        container.viewDidChangeEffectiveAppearance()
        XCTAssertEqual(
            assignment(of: container).alphaComponent, 0,
            "an appearance change resurrected the plate in an island state"
        )
    }

    /// A conversation pane keeps its dark plate in both system schemes, because
    /// its view paints white ink either way.
    func testConversationPlateStaysDarkInLightMode() {
        let container = PillContainerView()
        container.appearance = NSAppearance(named: .aqua)
        container.plateColor = NSColor(white: 0.11, alpha: 1)

        let lightModePlate = assignment(of: container)

        container.appearance = NSAppearance(named: .darkAqua)
        container.viewDidChangeEffectiveAppearance()
        let darkModePlate = assignment(of: container)

        for (name, plate) in [("light", lightModePlate), ("dark", darkModePlate)] {
            XCTAssertLessThan(plate.redComponent, 0.3, "conversation plate must be dark in \(name) mode")
            XCTAssertGreaterThan(
                contrast(plate, NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)), 7.0,
                "white conversation text needs contrast against the \(name)-mode plate"
            )
        }
    }

    private func assignment(of view: NSView) -> NSColor {
        guard let cg = view.layer?.backgroundColor else { return .clear }
        let raw = NSColor(cgColor: cg) ?? .clear
        // `.clear` is a gray-space color, so a failed conversion must not fall
        // back to it: reading redComponent off a gray color raises.
        return raw.usingColorSpace(.sRGB) ?? NSColor(srgbRed: -1, green: -1, blue: -1, alpha: -1)
    }
}
