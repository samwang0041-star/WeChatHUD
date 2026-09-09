#!/usr/bin/env swift

import AppKit
import CoreGraphics
import Foundation

let scriptURL = URL(fileURLWithPath: #filePath)
let repoRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let resourcesURL = repoRoot.appendingPathComponent("Resources", isDirectory: true)
let defaultOutputURL = repoRoot.appendingPathComponent(".build/app-icon", isDirectory: true)

func option(_ name: String) -> URL? {
    guard let index = CommandLine.arguments.firstIndex(of: name),
          index + 1 < CommandLine.arguments.count else { return nil }
    return URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
}

let outputURL = option("--output-root") ?? defaultOutputURL
let iconsetURL = outputURL.appendingPathComponent("AppIcon.iconset", isDirectory: true)
let iconURL = resourcesURL.appendingPathComponent("AppIcon.icns")

try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

let canvas: CGFloat = 1024

func rgb(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
    NSColor(red: red, green: green, blue: blue, alpha: alpha)
        .usingColorSpace(.deviceRGB)!
        .cgColor
}

func roundedRect(_ rect: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func fill(_ path: CGPath, color: CGColor, in context: CGContext) {
    context.addPath(path)
    context.setFillColor(color)
    context.fillPath()
}

func stroke(_ path: CGPath, color: CGColor, width: CGFloat, in context: CGContext) {
    context.addPath(path)
    context.setStrokeColor(color)
    context.setLineWidth(width)
    context.strokePath()
}

func drawIcon(pixelSize: Int) -> NSBitmapImageRep {
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bitmapFormat: [],
        bytesPerRow: 0,
        bitsPerPixel: 32
    )!
    let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphicsContext
    let context = graphicsContext.cgContext

    context.saveGState()
    let scale = CGFloat(pixelSize) / canvas
    context.scaleBy(x: scale, y: scale)
    context.setShouldAntialias(true)
    context.interpolationQuality = CGInterpolationQuality.high

    let base = roundedRect(CGRect(x: 32, y: 32, width: 960, height: 960), radius: 220)
    context.saveGState()
    context.addPath(base)
    context.clip()
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let gradient = CGGradient(
        colorsSpace: colorSpace,
        colors: [rgb(0.027, 0.306, 0.333), rgb(0.400, 0.831, 0.718)] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: 32, y: 992),
        end: CGPoint(x: 992, y: 32),
        options: []
    )
    context.restoreGState()
    stroke(base, color: rgb(0.78, 1, 0.94, 0.16), width: 8, in: context)

    // The smaller mint bubble sits behind the companion bubble.
    let smallBubble = roundedRect(CGRect(x: 690, y: 400, width: 260, height: 180), radius: 80)
    let smallTail = CGMutablePath()
    smallTail.move(to: CGPoint(x: 716, y: 404))
    smallTail.addLine(to: CGPoint(x: 644, y: 334))
    smallTail.addLine(to: CGPoint(x: 746, y: 404))
    smallTail.closeSubpath()
    fill(smallTail, color: rgb(0.718, 0.941, 0.831), in: context)
    fill(smallBubble, color: rgb(0.718, 0.941, 0.831), in: context)
    stroke(smallBubble, color: rgb(0.388, 0.788, 0.667), width: 10, in: context)

    // Main white bubble with a soft, short tail.
    let mainTail = CGMutablePath()
    mainTail.move(to: CGPoint(x: 522, y: 566))
    mainTail.addLine(to: CGPoint(x: 434, y: 462))
    mainTail.addLine(to: CGPoint(x: 566, y: 566))
    mainTail.closeSubpath()
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -14), blur: 22, color: rgb(0.02, 0.23, 0.25, 0.22))
    fill(mainTail, color: rgb(0.985, 1, 0.995), in: context)
    let mainBubble = roundedRect(CGRect(x: 216, y: 382, width: 592, height: 400), radius: 150)
    let mainGradient = CGGradient(
        colorsSpace: colorSpace,
        colors: [rgb(1, 1, 1), rgb(0.91, 1, 0.97)] as CFArray,
        locations: [0, 1]
    )!
    context.saveGState()
    context.addPath(mainBubble)
    context.clip()
    context.drawLinearGradient(mainGradient, start: CGPoint(x: 512, y: 782), end: CGPoint(x: 512, y: 382), options: [])
    context.restoreGState()
    context.restoreGState()

    let eyeColor = rgb(0.043, 0.349, 0.376)
    fill(CGPath(ellipseIn: CGRect(x: 408, y: 464, width: 48, height: 48), transform: nil), color: eyeColor, in: context)
    fill(CGPath(ellipseIn: CGRect(x: 568, y: 464, width: 48, height: 48), transform: nil), color: eyeColor, in: context)

    let smile = CGMutablePath()
    smile.move(to: CGPoint(x: 480, y: 430))
    smile.addCurve(to: CGPoint(x: 544, y: 430), control1: CGPoint(x: 496, y: 398), control2: CGPoint(x: 528, y: 398))
    context.addPath(smile)
    context.setStrokeColor(eyeColor)
    context.setLineWidth(14)
    context.setLineCap(CGLineCap.round)
    context.strokePath()

    context.restoreGState()
    NSGraphicsContext.restoreGraphicsState()
    return bitmap
}

func writePNG(_ bitmap: NSBitmapImageRep, to url: URL) throws {
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "WeChatHUD.AppIcon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not encode PNG at \(url.path)"])
    }
    try png.write(to: url, options: .atomic)
}

let iconSizes: [(Int, String)] = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png")
]

for (size, filename) in iconSizes {
    try writePNG(drawIcon(pixelSize: size), to: iconsetURL.appendingPathComponent(filename))
}

let preview512 = outputURL.appendingPathComponent("AppIcon-512.png")
let preview1024 = outputURL.appendingPathComponent("AppIcon-1024.png")
try writePNG(drawIcon(pixelSize: 512), to: preview512)
try writePNG(drawIcon(pixelSize: 1024), to: preview1024)

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconsetURL.path, "-o", iconURL.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    throw NSError(domain: "WeChatHUD.AppIcon", code: Int(iconutil.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "iconutil failed"])
}

print("Generated \(iconURL.path)")
print("Preview 512: \(preview512.path)")
print("Preview 1024: \(preview1024.path)")
