// Draws DiskLens's app icon at every size macOS uses and writes DiskLens/AppIcon.icns.
// The icon is a magnifying lens holding a small treemap, on a blue gradient.
//
// Run it from the repository folder after changing the design:
//     swift Tools/make-icon.swift
import AppKit

let output = "DiskLens/AppIcon.icns"

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}

func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: locations)!
}

/// Draws the icon into a square context `side` pixels wide, in Apple's 1024-point icon grid.
func drawIcon(in ctx: CGContext, side: CGFloat) {
    let u = side / 1024

    // The body: a rounded square of 824 points centred in 1024, with a soft shadow.
    let body = CGRect(x: 100 * u, y: 100 * u, width: 824 * u, height: 824 * u)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 185 * u, cornerHeight: 185 * u, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12 * u), blur: 28 * u, color: rgb(0, 0, 0, 0.30))
    ctx.addPath(bodyPath)
    ctx.setFillColor(rgb(0.25, 0.35, 0.85))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    ctx.drawLinearGradient(gradient([rgb(0.31, 0.58, 1.00), rgb(0.24, 0.24, 0.78)], [0, 1]),
                           start: CGPoint(x: 0, y: 924 * u), end: CGPoint(x: 0, y: 100 * u), options: [])
    let glowCenter = CGPoint(x: 320 * u, y: 880 * u)
    ctx.drawRadialGradient(gradient([rgb(1, 1, 1, 0.28), rgb(1, 1, 1, 0)], [0, 1]),
                           startCenter: glowCenter, startRadius: 0, endCenter: glowCenter, endRadius: 560 * u,
                           options: [])

    // The lens.
    let center = CGPoint(x: 462 * u, y: 576 * u)
    let radius: CGFloat = 238 * u
    let lens = CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius)

    // Handle, drawn first so the ring covers its end.
    let angle = -CGFloat.pi / 4
    func onLine(_ distance: CGFloat) -> CGPoint {
        CGPoint(x: center.x + cos(angle) * distance, y: center.y + sin(angle) * distance)
    }
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6 * u), blur: 14 * u, color: rgb(0.05, 0.05, 0.25, 0.35))
    ctx.setLineCap(.round)
    ctx.setStrokeColor(rgb(1, 1, 1))
    ctx.setLineWidth(86 * u)
    ctx.move(to: onLine(radius + 10 * u))
    ctx.addLine(to: onLine(radius + 238 * u))
    ctx.strokePath()
    ctx.restoreGState()

    // Glass with a small treemap inside.
    ctx.saveGState()
    ctx.addEllipse(in: lens)
    ctx.clip()
    ctx.setFillColor(rgb(0.09, 0.12, 0.38, 0.65))
    ctx.fill(lens)
    // (x, y, width, height) as fractions of the lens box, y from the bottom.
    let tiles: [(CGFloat, CGFloat, CGFloat, CGFloat, CGColor)] = [
        (0.00, 0.42, 0.58, 0.58, rgb(0.98, 0.56, 0.27)),   // orange
        (0.58, 0.64, 0.42, 0.36, rgb(0.20, 0.72, 0.78)),   // teal
        (0.58, 0.42, 0.42, 0.22, rgb(0.93, 0.40, 0.52)),   // rose
        (0.00, 0.00, 0.38, 0.42, rgb(0.96, 0.78, 0.26)),   // amber
        (0.38, 0.00, 0.62, 0.42, rgb(0.30, 0.76, 0.54)),   // green
    ]
    let gap = 12 * u
    for (x, y, w, h, color) in tiles {
        let rect = CGRect(x: lens.minX + x * lens.width + gap / 2, y: lens.minY + y * lens.height + gap / 2,
                          width: w * lens.width - gap, height: h * lens.height - gap)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 18 * u, cornerHeight: 18 * u, transform: nil))
        ctx.setFillColor(color)
        ctx.fillPath()
    }
    // A sheen across the top of the glass.
    ctx.drawLinearGradient(gradient([rgb(1, 1, 1, 0.30), rgb(1, 1, 1, 0)], [0, 1]),
                           start: CGPoint(x: lens.minX, y: lens.maxY), end: CGPoint(x: lens.midX, y: lens.midY),
                           options: [])
    ctx.restoreGState()

    // The ring.
    ctx.setStrokeColor(rgb(1, 1, 1))
    ctx.setLineWidth(46 * u)
    ctx.strokeEllipse(in: lens)

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
