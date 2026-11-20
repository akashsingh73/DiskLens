// Draws DiskLens's app icon at every size macOS uses and writes DiskLens/AppIcon.icns.
// The icon is a camera lens seen front-on, on graphite, with a small treemap in its glass.
//
// Run it from the repository folder after changing the design:
//     swift Tools/make-icon.swift
import AppKit
import SwiftUI

let output = "DiskLens/AppIcon.icns"

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}

func hsb(_ h: CGFloat, _ s: CGFloat, _ b: CGFloat) -> CGColor {
    NSColor(colorSpace: .sRGB, hue: h, saturation: s, brightness: b, alpha: 1).cgColor
}

func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: locations)!
}

func circle(_ center: CGPoint, _ radius: CGFloat) -> CGRect {
    CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius)
}

/// Fills a circle with a gradient running from its top to its bottom.
func fillCircle(_ ctx: CGContext, _ center: CGPoint, _ radius: CGFloat, top: CGColor, bottom: CGColor) {
    ctx.saveGState()
    ctx.addEllipse(in: circle(center, radius))
    ctx.clip()
    ctx.drawLinearGradient(gradient([top, bottom], [0, 1]), start: CGPoint(x: 0, y: center.y + radius),
                           end: CGPoint(x: 0, y: center.y - radius), options: [])
    ctx.restoreGState()
}

/// Draws the icon into a square context `side` pixels wide, in Apple's 1024-point icon grid.
func drawIcon(in ctx: CGContext, side: CGFloat) {
    let u = side / 1024

    // The body: a rounded square of 824 points centred in 1024, with a soft shadow.
    let body = CGRect(x: 100 * u, y: 100 * u, width: 824 * u, height: 824 * u)
    let bodyPath = Path(roundedRect: body, cornerRadius: 185 * u, style: .continuous).cgPath
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12 * u), blur: 28 * u, color: rgb(0, 0, 0, 0.30))
    ctx.addPath(bodyPath)
    ctx.setFillColor(rgb(0.12, 0.12, 0.15))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    ctx.drawLinearGradient(gradient([rgb(0.28, 0.29, 0.35), rgb(0.09, 0.09, 0.12)], [0, 1]),
                           start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])

    // The barrel: rings lit from above, each one step further in.
    let center = CGPoint(x: 512 * u, y: 512 * u)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -18 * u), blur: 44 * u, color: rgb(0, 0, 0, 0.65))
    ctx.setFillColor(rgb(0.10, 0.10, 0.12))
    ctx.fillEllipse(in: circle(center, 334 * u))
    ctx.restoreGState()
    fillCircle(ctx, center, 336 * u, top: rgb(0.66, 0.68, 0.76), bottom: rgb(0.14, 0.15, 0.18))   // bright edge
    fillCircle(ctx, center, 322 * u, top: rgb(0.34, 0.35, 0.41), bottom: rgb(0.11, 0.11, 0.14))   // front face
    fillCircle(ctx, center, 296 * u, top: rgb(0.07, 0.07, 0.09), bottom: rgb(0.28, 0.29, 0.34))   // inner bevel
    fillCircle(ctx, center, 282 * u, top: rgb(0.05, 0.05, 0.07), bottom: rgb(0.08, 0.08, 0.10))   // recess
    ctx.setStrokeColor(rgb(1, 1, 1, 0.22))
    ctx.setLineWidth(5 * u)
    ctx.strokeEllipse(in: circle(center, 260 * u))

    // The glass, with a small treemap inside.
    let radius = 238 * u
    let glass = circle(center, radius)
    ctx.saveGState()
    ctx.addEllipse(in: glass)
    ctx.clip()
    ctx.setFillColor(rgb(0.04, 0.04, 0.07))
    ctx.fill(glass)
    // (x, y, width, height) as fractions of the glass's box, y from the bottom, then hue, saturation
    // and brightness. The hues are the first ones in Theme.swift.
    let tiles: [(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)] = [
        (0.00, 0.42, 0.50, 0.58, 0.08, 0.72, 0.97),   // orange
        (0.50, 0.64, 0.50, 0.36, 0.51, 0.72, 0.80),   // teal
        (0.50, 0.42, 0.27, 0.22, 0.96, 0.58, 0.94),   // rose
        (0.77, 0.42, 0.23, 0.22, 0.74, 0.50, 0.90),   // violet
        (0.00, 0.00, 0.32, 0.42, 0.13, 0.74, 0.97),   // amber
        (0.32, 0.00, 0.38, 0.42, 0.43, 0.62, 0.78),   // green
        (0.70, 0.00, 0.30, 0.42, 0.60, 0.68, 0.95),   // blue
    ]
    let box = glass.insetBy(dx: -6 * u, dy: -6 * u)
    let gap = 13 * u
    for (x, y, w, h, hue, saturation, brightness) in tiles {
        let rect = CGRect(x: box.minX + x * box.width + gap / 2, y: box.minY + y * box.height + gap / 2,
                          width: w * box.width - gap, height: h * box.height - gap)
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 20 * u, cornerHeight: 20 * u, transform: nil))
        ctx.clip()
        // Each tile is a little lighter at the top.
        ctx.drawLinearGradient(gradient([hsb(hue, saturation * 0.82, min(1, brightness * 1.06)),
                                         hsb(hue, min(1, saturation * 1.08), brightness * 0.92)], [0, 1]),
                               start: CGPoint(x: 0, y: rect.maxY), end: CGPoint(x: 0, y: rect.minY), options: [])
        ctx.restoreGState()
    }
    // A sheen across the top left, and the glass darkening towards its edge.
    ctx.drawLinearGradient(gradient([rgb(1, 1, 1, 0.26), rgb(1, 1, 1, 0)], [0, 1]),
                           start: CGPoint(x: glass.minX, y: glass.maxY), end: center, options: [])
    ctx.drawRadialGradient(gradient([rgb(0, 0, 0, 0), rgb(0, 0, 0, 0.38)], [0.76, 1]),
                           startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
    // A reflection: the crescent between the glass's edge and the same circle moved down and right.
    ctx.addRect(glass.insetBy(dx: -radius, dy: -radius))
    ctx.addEllipse(in: glass.offsetBy(dx: 40 * u, dy: -52 * u))
    ctx.clip(using: .evenOdd)
    ctx.drawLinearGradient(gradient([rgb(1, 1, 1, 0.34), rgb(1, 1, 1, 0)], [0, 1]),
                           start: CGPoint(x: center.x - radius * 0.7, y: center.y + radius * 0.7),
                           end: CGPoint(x: center.x + radius * 0.5, y: center.y + radius * 0.2), options: [])
    ctx.restoreGState()

    ctx.restoreGState()
}

func png(side: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    drawIcon(in: context.cgContext, side: CGFloat(side))
    context.flushGraphics()
    return rep.representation(using: .png, properties: [:])!
}

let iconset = FileManager.default.temporaryDirectory
    .appendingPathComponent("DiskLensIcon-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }

let variants: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, side) in variants {
    try png(side: side).write(to: iconset.appendingPathComponent(name + ".png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    print("iconutil failed")
    exit(1)
}
print("Wrote \(output)")
