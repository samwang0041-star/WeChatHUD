import XCTest
import SwiftUI
import AppKit
@testable import WeChatHUD

/// Diagnostics for offscreen rendering.
///
/// The first version of the settings render test produced a blank image and
/// still passed, so these probes establish what actually renders under
/// `ImageRenderer` before trusting any layout screenshot.
@MainActor
final class RenderProbeTests: XCTestCase {

    /// Fraction of pixels that differ from the corner pixel, which stands in for
    /// the background. A blank render scores ~0.
    private func inkRatio(_ rep: NSBitmapImageRep) -> Double {
        let width = rep.pixelsWide
        let height = rep.pixelsHigh
        guard width > 0, height > 0 else { return 0 }
        let background = rep.colorAt(x: 0, y: 0)
        var ink = 0
        var total = 0
        for y in stride(from: 0, to: height, by: 4) {
            for x in stride(from: 0, to: width, by: 4) {
                total += 1
                guard let pixel = rep.colorAt(x: x, y: y) else { continue }
                let dr = abs(pixel.redComponent - (background?.redComponent ?? 0))
                let dg = abs(pixel.greenComponent - (background?.greenComponent ?? 0))
                let db = abs(pixel.blueComponent - (background?.blueComponent ?? 0))
                if dr + dg + db > 0.06 { ink += 1 }
            }
        }
        return total == 0 ? 0 : Double(ink) / Double(total)
    }

    private func render(_ view: some View, name: String) -> NSBitmapImageRep? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        let ratio = inkRatio(rep)
        print("[probe] \(name): \(rep.pixelsWide)x\(rep.pixelsHigh) ink=\(String(format: "%.4f", ratio))")
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: "/tmp/probe-\(name).png"))
        }
        return rep
    }

    func testPlainTextRenders() {
        let rep = render(
            Text("你好").font(.system(size: 40)).padding(40)
                .background(Color.white),
            name: "text"
        )
        XCTAssertNotNil(rep)
        XCTAssertGreaterThan(inkRatio(rep!), 0.005, "plain text should leave ink")
    }

    func testSettingsSectionRenders() {
        let store = HUDStore(dbPath: NSTemporaryDirectory() + "probe-\(UUID().uuidString).sqlite3")
        try? store.open()
        defer { store.close() }

        let rep = render(
            VStack(alignment: .leading) {
                SettingsSection("提醒范围") {
                    SettingsRow("只提醒我关注的人", subtitle: "只有关注的人会进来。", icon: "person.crop.circle") {
                        EmptyView()
                    }
                }
            }
            .padding(20)
            .frame(width: 600, alignment: .topLeading)
            .background(Color.white),
            name: "section"
        )
        XCTAssertNotNil(rep)
        XCTAssertGreaterThan(inkRatio(rep!), 0.01, "a settings section should leave ink")
    }

    /// Pins the reason `AdmissionSettingsView.content` exists as a separate
    /// property.
    ///
    /// `ImageRenderer` draws a `ScrollView` as an empty image. A screenshot
    /// test of a scroll-wrapped screen therefore passes while showing nothing —
    /// which is exactly how the first version of the settings render test
    /// "passed" against a blank picture. If a future OS renders ScrollView
    /// content offscreen, this test fails and the workaround can be dropped.
    func testScrollViewRendersBlankOffscreen() {
        let sameContent = VStack(alignment: .leading, spacing: 10) {
            ForEach(0..<12, id: \.self) { index in
                Text("第 \(index) 行内容").font(.system(size: 14))
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white)

        let bare = render(sameContent.frame(width: 600, height: 400), name: "scroll-flat")
        XCTAssertGreaterThan(
            inkRatio(bare!), 0.005,
            "the same content drawn without a ScrollView must produce ink"
        )

        let wrapped = render(
            ScrollView { sameContent }
                .frame(width: 600, height: 400),
            name: "scroll-wrapped"
        )
        XCTAssertNotNil(wrapped)
        XCTAssertEqual(
            inkRatio(wrapped!), 0, accuracy: 0.001,
            "ScrollView currently renders blank offscreen; if this changed, drop the content split"
        )
    }
}
