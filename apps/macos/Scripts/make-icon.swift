// Renders the NyCopilot app icon into an .iconset directory: `swift make-icon.swift <out.iconset>`.
// The mark matches BrandGlyph in the app, so icon, menu bar, and onboarding share one shape.
import AppKit

func sparkle(center: NSPoint, radius: CGFloat, pinch: CGFloat = 0.16) -> NSBezierPath {
    let path = NSBezierPath()
    let points = [NSPoint(x: 0, y: 1), NSPoint(x: 1, y: 0), NSPoint(x: 0, y: -1), NSPoint(x: -1, y: 0)]
    path.move(to: NSPoint(x: center.x, y: center.y + radius))
    for index in 0..<4 {
        let from = points[index], to = points[(index + 1) % 4]
        let control = NSPoint(x: center.x + (from.x + to.x) * radius * pinch, y: center.y + (from.y + to.y) * radius * pinch)
        path.curve(to: NSPoint(x: center.x + to.x * radius, y: center.y + to.y * radius), controlPoint1: control, controlPoint2: control)
    }
    path.close()
    return path
}

func render(_ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(pixels) / 1024
    // Apple's icon grid: an 824-pt rounded square centred on a 1024 canvas.
    let tile = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let shape = NSBezierPath(roundedRect: tile, xRadius: 185 * s, yRadius: 185 * s)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = 24 * s
    shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSColor.black.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [NSColor(srgbRed: 0.33, green: 0.30, blue: 0.96, alpha: 1),
                        NSColor(srgbRed: 0.56, green: 0.29, blue: 0.93, alpha: 1),
                        NSColor(srgbRed: 0.93, green: 0.36, blue: 0.62, alpha: 1)],
               atLocations: [0, 0.6, 1], colorSpace: .sRGB)!.draw(in: shape, angle: -55)
    // A soft top sheen gives the tile depth without a busy texture.
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    NSGradient(starting: NSColor.white.withAlphaComponent(0.22), ending: NSColor.white.withAlphaComponent(0))!
        .draw(in: NSRect(x: tile.minX, y: tile.midY, width: tile.width, height: tile.height / 2), angle: -90)
    NSGraphicsContext.restoreGraphicsState()
    let glow = NSShadow()
    glow.shadowColor = NSColor(srgbRed: 0.2, green: 0.1, blue: 0.5, alpha: 0.45)
    glow.shadowBlurRadius = 30 * s
    glow.shadowOffset = NSSize(width: 0, height: -8 * s)
    NSGraphicsContext.saveGraphicsState()
    glow.set()
    NSColor.white.setFill()
    sparkle(center: NSPoint(x: 470 * s, y: 470 * s), radius: 250 * s).fill()
    NSColor.white.withAlphaComponent(0.9).setFill()
    sparkle(center: NSPoint(x: 708 * s, y: 712 * s), radius: 104 * s).fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let output = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    try render(size).write(to: output.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(size * 2).write(to: output.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
