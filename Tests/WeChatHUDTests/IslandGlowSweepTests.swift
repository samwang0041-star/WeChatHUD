import XCTest
import SwiftUI
@testable import WeChatHUD

final class IslandGlowSweepTests: XCTestCase {
    @MainActor
    func testIslandShapePathPerimeterContinuity() throws {
        let shape = IslandShape(
            notchWidth: 200,
            notchHeight: 32,
            pillCornerRadius: 22,
            notchCornerRadius: 10,
            topCornerRadius: 16
        )
        let rect = CGRect(x: 0, y: 0, width: 312, height: 32)
        let path = shape.path(in: rect)
        XCTAssertFalse(path.isEmpty, "IslandShape path must not be empty")

        for frac in [0.0, 0.25, 0.5, 0.75, 0.99] {
            let trimmed = path.trimmedPath(from: CGFloat(frac), to: CGFloat(min(1.0, frac + 0.05)))
            let bounds = trimmed.boundingRect
            XCTAssertFalse(bounds.origin.x.isNaN, "Trimmed segment at \(frac) must have valid x")
            XCTAssertFalse(bounds.origin.y.isNaN, "Trimmed segment at \(frac) must have valid y")
        }
    }

    @MainActor
    func testIslandSweepFramesCycleContinuously() throws {
        for step in 0..<5 {
            let progress = CGFloat(step) / 5.0
            let view = ZStack {
                Color.black
                IslandShape(notchWidth: 200, notchHeight: 32, pillCornerRadius: 22, notchCornerRadius: 10, topCornerRadius: 16)
                    .fill(Color(white: 0.08))

                IslandSweepTestRig(
                    progress: progress,
                    notchWidth: 200,
                    notchHeight: 32,
                    radii: IslandChrome.SilhouetteRadii(pill: 22, notch: 10, top: 16)
                )
            }
            .frame(width: 312, height: 32)

            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard let image = renderer.nsImage,
                  let rep = NSBitmapImageRep(data: image.tiffRepresentation ?? Data()),
                  let png = rep.representation(using: NSBitmapImageRep.FileType.png, properties: [:]) else {
                XCTFail("Failed to render frame \(step)")
                continue
            }
            let url = URL(fileURLWithPath: "/tmp/test_sweep_cycle_frame_\(step).png")
            try png.write(to: url)
        }
    }

    @ViewBuilder
    private func IslandSweepTestRig(
        progress: CGFloat,
        notchWidth: CGFloat,
        notchHeight: CGFloat,
        radii: IslandChrome.SilhouetteRadii
    ) -> some View {
        let beamLength: CGFloat = 0.16
        let tailSteps = 14
        let stepLen = beamLength / CGFloat(tailSteps)
        let tint = CompanionPalette.islandMint

        ZStack {
            ForEach(0..<tailSteps, id: \.self) { i in
                let fraction = CGFloat(tailSteps - i) / CGFloat(tailSteps)
                let rawCenter = progress - CGFloat(i) * stepLen * 0.92
                let center = rawCenter < 0 ? rawCenter + 1.0 : (rawCenter > 1.0 ? rawCenter - 1.0 : rawCenter)
                let opacity = pow(fraction, 1.6)
                let isHead = i == 0
                let strokeColor = isHead ? Color.white.opacity(0.95) : tint.opacity(opacity * 0.88)
                let lineWidth: CGFloat = isHead ? 3.5 : (1.8 + fraction * 1.6)
                let blurRadius: CGFloat = isHead ? 0.6 : (0.8 + (1.0 - fraction) * 2.2)

                let half = (stepLen * 1.5) / 2
                let start = center - half
                let end = center + half
                let shape = IslandShape(
                    notchWidth: notchWidth,
                    notchHeight: notchHeight,
                    pillCornerRadius: radii.pill,
                    notchCornerRadius: radii.notch,
                    topCornerRadius: radii.top
                )
                let style = StrokeStyle(lineWidth: lineWidth, lineCap: .round)

                if start < 0 {
                    shape.trim(from: start + 1.0, to: 1.0).stroke(strokeColor, style: style).blur(radius: blurRadius)
                    shape.trim(from: 0.0, to: end).stroke(strokeColor, style: style).blur(radius: blurRadius)
                } else if end > 1.0 {
                    shape.trim(from: start, to: 1.0).stroke(strokeColor, style: style).blur(radius: blurRadius)
                    shape.trim(from: 0.0, to: end - 1.0).stroke(strokeColor, style: style).blur(radius: blurRadius)
                } else {
                    shape.trim(from: start, to: end).stroke(strokeColor, style: style).blur(radius: blurRadius)
                }
            }
        }
    }
}
