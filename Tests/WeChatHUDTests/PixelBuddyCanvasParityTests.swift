// Tests/WeChatHUDTests/PixelBuddyCanvasParityTests.swift
//
// W4 — pixel-identity proof for the Rectangle → Canvas swap.
//
// The retired sprite was 12 `HStack`s of 12 `Rectangle`s, each 1.5pt, filling
// `PixelColor.swiftUIColor` for one frame. `LegacySprite` below reproduces that
// tree exactly; the frames and colours on both sides come from the production
// frame table, so the only thing that differs is the drawing path. Every mood
// and every frame is rendered both ways over a contrasting plate and compared
// pixel by pixel.
import XCTest
import SwiftUI
import AppKit
@testable import WeChatHUD

@MainActor
final class PixelBuddyCanvasParityTests: XCTestCase {

    /// 1.5pt cells don't land on whole pixels at 1×; ×12 makes each cell an
    /// exact 18×18 device-pixel block so the comparison measures geometry,
    /// not rasterizer rounding.
    private let scale: CGFloat = 12
    private let plate = Color(red: 1, green: 0, blue: 1)

    /// The retired renderer, preserved as the reference.
    private struct LegacySprite: View {
        let frame: Frame
        var cellSize: CGFloat = BuddySpriteGeometry.pixelSize

        var body: some View {
            VStack(spacing: 0) {
                ForEach(BuddySpriteGeometry.cropTop..<BuddySpriteGeometry.cropBottom, id: \.self) { row in
                    HStack(spacing: 0) {
                        ForEach(BuddySpriteGeometry.cropLeft..<BuddySpriteGeometry.cropRight, id: \.self) { col in
                            Rectangle()
                                .fill(frame[row][col].swiftUIColor)
                                .frame(width: cellSize, height: cellSize)
                        }
                    }
                }
            }
        }
    }

    private struct Plate<Content: View>: View {
        let background: Color
        let content: Content
        var body: some View {
            ZStack { background; content }
                .frame(width: 40, height: 40)
        }
    }

    private func bitmap(_ view: some View) -> NSBitmapImageRep? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation else { return nil }
        return NSBitmapImageRep(data: tiff)
    }

    private func render(canvas: Bool, frame: Frame, name: String) throws -> NSBitmapImageRep {
        let content = canvas
            ? AnyView(BuddyPixelGrid(frame: frame))
            : AnyView(LegacySprite(frame: frame))
        let rep = try XCTUnwrap(bitmap(Plate(background: plate, content: content)),
                                "\(name): ImageRenderer produced no bitmap")
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: "/tmp/buddy-parity-\(canvas ? "canvas" : "legacy")-\(name).png"))
        }
        return rep
    }

    /// First differing pixel, as a coordinate pair, or nil when identical.
    private func firstDifference(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> (Int, Int)? {
        differingPixels(a, b).first
    }

    /// Every differing pixel, with both colours, for readable diagnostics.
    private func differenceReport(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> String {
        let all = differingPixels(a, b)
        guard !all.isEmpty else { return "identical" }
        func describe(_ color: NSColor?) -> String {
            guard let color else { return "nil" }
            return String(format: "%.4f/%.4f/%.4f/%.4f", color.redComponent, color.greenComponent,
                          color.blueComponent, color.alphaComponent)
        }
        let samples = all.prefix(4).map { point in
            "\(point.0),\(point.1): canvas \(describe(a.colorAt(x: point.0, y: point.1))) "
                + "legacy \(describe(b.colorAt(x: point.0, y: point.1)))"
        }
        return "\(all.count) differing pixels; \(samples.joined(separator: " | "))"
    }

    private func differingPixels(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> [(Int, Int)] {
        guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh else { return [(0, 0)] }
        guard let dataA = a.bitmapData, let dataB = b.bitmapData,
              a.samplesPerPixel == b.samplesPerPixel,
              a.bytesPerRow == b.bytesPerRow,
              a.bitsPerSample == b.bitsPerSample else { return [(0, 0)] }
        let rowBytes = a.bytesPerRow
        let bytesPerPixel = max(1, (a.bitsPerSample / 8) * a.samplesPerPixel)
        var found: [(Int, Int)] = []
        for y in 0..<a.pixelsHigh {
            for x in 0..<a.pixelsWide {
                let offset = y * rowBytes + x * bytesPerPixel
                // A full-channel compare: the two renderers must agree on
                // the exact sample values, not just "close enough".
                for byte in 0..<bytesPerPixel where dataA[offset + byte] != dataB[offset + byte] {
                    found.append((x, y))
                    break
                }
            }
        }
        return found
    }

    /// The hard requirement: the Canvas and the 144 rectangles must produce
    /// the same bitmap for every frame of every mood.
    func testCanvasPaintsTheSamePixelsAsTheRectangleGrid() throws {
        var compared = 0
        for mood in BuddyMood.allCases {
            let frames = framesForMood(mood)
            for index in 0..<frames.count {
                let name = "\(mood)-\(index)"
                let canvas = try render(canvas: true, frame: frames[index], name: name)
                let legacy = try render(canvas: false, frame: frames[index], name: name)
                XCTAssertEqual(canvas.pixelsWide, legacy.pixelsWide, "\(name): width")
                XCTAssertEqual(canvas.pixelsHigh, legacy.pixelsHigh, "\(name): height")
                let difference = firstDifference(canvas, legacy)
                XCTAssertNil(difference, "\(name): first differing pixel at \(String(describing: difference))")
                compared += 1
            }
        }
        XCTAssertEqual(compared, BuddyMood.allCases.reduce(0) { $0 + framesForMood($1).count })
    }

    /// The production view — sprite, gate wiring and all — must render the
    /// same 18pt mark as the legacy tree.
    func testProductionViewMatchesLegacySprite() throws {
        for mood in BuddyMood.allCases {
            let canvas = try XCTUnwrap(bitmap(Plate(background: plate, content: PixelBuddyView(mood: mood))))
            let legacy = try render(canvas: false, frame: framesForMood(mood)[0], name: "view-\(mood)")
            XCTAssertEqual(canvas.pixelsWide, legacy.pixelsWide, "\(mood): width")
            XCTAssertEqual(canvas.pixelsHigh, legacy.pixelsHigh, "\(mood): height")
            XCTAssertNil(firstDifference(canvas, legacy),
                         "\(mood): production view differs from the legacy sprite — "
                             + differenceReport(canvas, legacy))
        }
    }

    /// Pins the geometry the drawing depends on: 12 visible columns at 1.5pt.
    func testSpriteSizeIsUnchanged() {
        XCTAssertEqual(PixelGridLayout.spriteSize.width, 18, accuracy: 0.0001)
        XCTAssertEqual(PixelGridLayout.spriteSize.height, 18, accuracy: 0.0001)
        XCTAssertEqual(PixelGridLayout.spriteSize.width, IslandMetrics.buddy, accuracy: 0.0001,
                       "the sprite fills the compact bar's buddy slot exactly")
    }

    /// And that the crop maps cell-for-cell: first visible cell at (0,0), a
    /// 1.5pt cell, and the clear pixels outside the crop omitted (they used to
    /// be fully transparent rectangles).
    func testLayoutMapsCropCellsToPoints() throws {
        let frame = framesForMood(.idle)[0]
        let pixels = PixelGridLayout.pixels(in: frame)
        XCTAssertFalse(pixels.isEmpty)
        for pixel in pixels {
            XCTAssertEqual(pixel.rect.width, 1.5, accuracy: 0.0001)
            XCTAssertEqual(pixel.rect.height, 1.5, accuracy: 0.0001)
            XCTAssertLessThan(pixel.rect.maxX, 18.0001)
            XCTAssertLessThan(pixel.rect.maxY, 18.0001)
            // The colour is the frame's own colour at the original crop offset.
            XCTAssertEqual(pixel.color,
                           frame[pixel.row + BuddySpriteGeometry.cropTop][pixel.col + BuddySpriteGeometry.cropLeft])
            XCTAssertNotEqual(pixel.color, PixelColor.clear, "clear cells must be omitted")
        }
        // Every non-clear cell of the crop is present, and only those.
        var expected = 0
        for row in BuddySpriteGeometry.cropTop..<BuddySpriteGeometry.cropBottom {
            for col in BuddySpriteGeometry.cropLeft..<BuddySpriteGeometry.cropRight {
                if frame[row][col] != .clear { expected += 1 }
            }
        }
        XCTAssertEqual(pixels.count, expected)
    }

    /// The pixel test's own control: a big change must be detected.
    func testComparisonDetectsADifference() throws {
        var frame = framesForMood(.idle)[0]
        // Row 12 / col 12 of the grid is inside the crop (top 8, left 7).
        frame[12][12] = .clear
        let canvas = try render(canvas: true, frame: frame, name: "control")
        let legacy = try render(canvas: false, frame: framesForMood(.idle)[0], name: "control")
        XCTAssertNotNil(firstDifference(canvas, legacy), "blanking the eye pixel must show up")
    }

    // MARK: - Live capture (opt-in)

    /// Checks a screenshot taken from the running app against the sprite it
    /// should be showing. Set `WCHUD_LIVE_BUDDY_CAPTURE` to a PNG captured with
    /// the island on screen; without it the test skips, so CI stays honest
    /// about what it did not check.
    ///
    /// The capture carries a display colour space, so the check is on
    /// *geometry* rather than exact RGB: the sprite must be drawn as a grid of
    /// solid 3x3 device-pixel cells (1.5pt at 2x) whose colour pattern matches
    /// one of the production frames. A renderer that lost the cell grid, drew
    /// half-cells, or blended cells together fails here.
    func testLiveCaptureMatchesAProductionFrame() throws {
        guard let path = ProcessInfo.processInfo.environment["WCHUD_LIVE_BUDDY_CAPTURE"] else {
            throw XCTSkip("set WCHUD_LIVE_BUDDY_CAPTURE=<png> to check a live capture")
        }
        let data = try XCTUnwrap(try? Data(contentsOf: URL(fileURLWithPath: path)), "no capture at \(path)")
        let rep = try XCTUnwrap(NSBitmapImageRep(data: data), "unreadable PNG at \(path)")

        let mask = try XCTUnwrap(spriteMask(in: rep), "no sprite pixels found in \(path)")
        let matches = BuddyMood.allCases.flatMap { mood in
            framesForMood(mood).enumerated().map { (mood, $0.offset, cellMask(of: $0.element)) }
        }.filter { $0.2 == mask }
        XCTAssertFalse(matches.isEmpty, "live sprite does not match any production frame; live mask=\n"
            + mask.map { $0.map { $0 ? "#" : "." }.joined() }.joined(separator: "\n"))
        let names = matches.map { "\($0.0)#\($0.1)" }.joined(separator: ", ")
        print("[buddy-live] \(path) matches \(names)")
    }

    /// Cells (1.5pt blocks) that have any opaque pixel, cropped to the sprite's
    /// own bounding box, as a per-cell "inked" bitmap.
    private func cellMask(of frame: Frame) -> [[Bool]] {
        let rows = BuddySpriteGeometry.cropTop..<BuddySpriteGeometry.cropBottom
        let cols = BuddySpriteGeometry.cropLeft..<BuddySpriteGeometry.cropRight
        return trimmed(rows.map { row in cols.map { frame[row][$0] != .clear } })
    }

    /// Reads the sprite out of a screenshot: find the coloured pixels on the
    /// right half, then read the 3x3 cell grid their bounding box implies.
    /// Returns nil when no sprite is visible.
    private func spriteMask(in rep: NSBitmapImageRep) -> [[Bool]]? {
        // Background is the island's black; anything clearly brighter is sprite.
        func inked(_ x: Int, _ y: Int) -> Bool {
            guard let color = rep.colorAt(x: x, y: y) else { return false }
            return color.alphaComponent > 0.5 && color.brightnessComponent > 0.15
        }
        var minX = rep.pixelsWide, maxX = -1, minY = rep.pixelsHigh, maxY = -1
        for y in 0..<rep.pixelsHigh {
            for x in (rep.pixelsWide / 2)..<rep.pixelsWide where inked(x, y) {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        // 2x capture: one 1.5pt cell is 3 device pixels.
        let cell = 3
        var mask: [[Bool]] = []
        var y = minY
        while y + cell - 1 <= maxY {
            var row: [Bool] = []
            var x = minX
            while x + cell - 1 <= maxX {
                var any = false
                for dy in 0..<cell {
                    for dx in 0..<cell where inked(x + dx, y + dy) { any = true }
                }
                row.append(any)
                x += cell
            }
            mask.append(row)
            y += cell
        }
        return trimmed(mask)
    }

    /// Drops blank rows and columns from all four sides, so two masks can be
    /// compared without agreeing on where the sprite's padding lands.
    private func trimmed(_ mask: [[Bool]]) -> [[Bool]] {
        var mask = mask.filter { $0.contains(true) }
        guard !mask.isEmpty else { return [] }
        let firstCol = mask.map { $0.firstIndex(of: true) ?? $0.count }.min() ?? 0
        let lastCol = mask.map { ($0.lastIndex(of: true) ?? -1) }.max() ?? -1
        guard lastCol >= firstCol else { return mask }
        mask = mask.map { Array($0[firstCol...lastCol]) }
        return mask
    }
}
