import XCTest
import SwiftUI
import AppKit
@testable import WeChatHUD

/// The scroll-edge wash is a visual claim ("content fades into its chrome")
/// that token tests cannot prove. This rasterises the modifier over a solid
/// content plate and checks the wash actually covers, actually releases and
/// never hard-cuts.
@MainActor
final class CompanionScrollEdgeRenderTests: XCTestCase {

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

    /// Red plate washed by a black ground: red-channel value reads as "how
    /// much of the content survived the wash" (0 = fully covered).
    private func redPlate() -> some View {
        Color.red.companionScrollEdgeFade(.black)
    }

    func testWashCoversTheCutAndReleasesBelowIt() throws {
        let rep = try render(redPlate(), size: CGSize(width: 40, height: 60))
        let scale = CGFloat(rep.pixelsHigh) / 60.0
        let top = rep.colorAt(x: rep.pixelsWide / 2, y: 0)
        XCTAssertNotNil(top)
        XCTAssertLessThan(
            top!.redComponent, 0.25,
            "the top row must read as ground: content is supposed to fade in, not be cut"
        )
        let clearY = Int((CompanionScrollEdge.fadeHeight + 2) * scale)
        let clear = rep.colorAt(x: rep.pixelsWide / 2, y: clearY)
        XCTAssertNotNil(clear)
        XCTAssertGreaterThan(
            clear!.redComponent, 0.9,
            "below the wash the content must be fully itself again"
        )
    }

    func testWashIsMonotonicNotABand() throws {
        let rep = try render(redPlate(), size: CGSize(width: 40, height: 60))
        let scale = CGFloat(rep.pixelsHigh) / 60.0
        let x = rep.pixelsWide / 2
        var previous = CGFloat(-1)
        for step in 0...Int(CompanionScrollEdge.fadeHeight * scale) {
            guard let c = rep.colorAt(x: x, y: step) else { continue }
            XCTAssertGreaterThanOrEqual(
                c.redComponent, previous - 0.03,
                "the wash must release smoothly; a step at y=\(step) reads as a band"
            )
            previous = c.redComponent
        }
    }

    func testBottomEdgeMirrorsTheTop() throws {
        let rep = try render(redPlate(), size: CGSize(width: 40, height: 60))
        let bottom = rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh - 1)
        XCTAssertNotNil(bottom)
        XCTAssertLessThan(
            bottom!.redComponent, 0.25,
            "the bottom cut fades the same way the top does"
        )
    }

    /// The wash is paired with a content margin so a page that fits in one
    /// screen does not wash its own first row. The pairing is one rule — "the
    /// wash never covers content" — so both must read the same constant.
    /// ImageRenderer cannot lay out a ScrollView off-window (its content never
    /// paints), so the margin's real-world effect is verified on app
    /// screenshots (QA §130), while this locks the two halves from drifting.
    func testContentMarginIsPairedWithTheWash() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/WeChatHUD/Views/CompanionMaterial.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(
            source.contains("contentMargins(.vertical, CompanionScrollEdge.fadeHeight, for: .scrollContent)"),
            "the content margin must be the wash height — same constant, or short pages wash their own rows"
        )
    }
}
