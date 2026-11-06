// Draws the app icon (a lowercase "b" whose bowl is a clock face) and writes
// Support/AppIcon.icns. Run: swift scripts/make-icon.swift
import AppKit

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: CGFloat(px) / 1024, y: CGFloat(px) / 1024)  // draw on a 1024 grid, y up

    // Background: macOS-style rounded square (824pt body, Big Sur grid), bamboo-green gradient.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: NSColor.black.withAlphaComponent(0.3).cgColor)
    ctx.addPath(shape); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    let green = CGGradient(colorsSpace: nil, colors: [
        NSColor(red: 0.55, green: 0.80, blue: 0.30, alpha: 1).cgColor,
        NSColor(red: 0.18, green: 0.52, blue: 0.27, alpha: 1).cgColor,
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(green, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    ctx.restoreGState()

    // The "b": stem + round bowl, white with a soft shadow.
    let cx: CGFloat = 512, cy: CGFloat = 422, r: CGFloat = 210, stemW: CGFloat = 84
    let stem = CGRect(x: cx - r, y: cy, width: stemW, height: 812 - cy)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: NSColor.black.withAlphaComponent(0.25).cgColor)
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    ctx.addPath(CGPath(roundedRect: stem, cornerWidth: stemW / 2, cornerHeight: stemW / 2, transform: nil))
    ctx.fillPath()
    ctx.fill(CGRect(x: stem.minX, y: cy, width: stemW, height: stemW))  // square bottom joining the bowl
    ctx.fillEllipse(in: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r))
    ctx.endTransparencyLayer()
    ctx.restoreGState()

    // Clock face inside the bowl.
    let ink = NSColor(red: 0.16, green: 0.45, blue: 0.24, alpha: 1).cgColor
    ctx.setStrokeColor(ink); ctx.setFillColor(ink); ctx.setLineCap(.round)
    for i in 0..<12 {
        let a = CGFloat(i) * .pi / 6
        let (outer, inner, w): (CGFloat, CGFloat, CGFloat) = i % 3 == 0 ? (170, 132, 18) : (170, 152, 10)
        ctx.setLineWidth(w)
        ctx.move(to: CGPoint(x: cx + sin(a) * inner, y: cy + cos(a) * inner))
        ctx.addLine(to: CGPoint(x: cx + sin(a) * outer, y: cy + cos(a) * outer))
        ctx.strokePath()
    }
    func hand(_ angle: CGFloat, _ length: CGFloat, _ width: CGFloat) {
        ctx.setLineWidth(width)
        ctx.move(to: CGPoint(x: cx, y: cy))
        ctx.addLine(to: CGPoint(x: cx + sin(angle) * length, y: cy + cos(angle) * length))
        ctx.strokePath()
    }
    hand(-.pi / 3, 92, 26)   // hour hand → 10
    hand(.pi / 3, 128, 18)   // minute hand → 10 past
    ctx.fillEllipse(in: CGRect(x: cx - 20, y: cy - 20, width: 40, height: 40))

    NSGraphicsContext.current = nil
    return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    try render(size).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(size * 2).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Support/AppIcon.icns").path]
try iconutil.run(); iconutil.waitUntilExit()
print("wrote Support/AppIcon.icns")
