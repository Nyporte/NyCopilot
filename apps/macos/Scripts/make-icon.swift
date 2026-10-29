// Renders the NyCopilot app icon into an .iconset directory:
//   swift make-icon.swift <out.iconset> [--preview <preview.png>]
// The mark — one open loop that reads as "ny", with a spark in its opening — must match BrandGlyph
// in Interface/Components.swift.
import AppKit

/// Geometry on Apple's 1024 icon grid, in a 160-unit tile space (y down) for readability.
///
/// The stroke is a tall loop — stem up, arch over, leg down, round the bottom — left open at its
/// bottom-left corner. The spark sits in that opening on the loop's own path, so the stem points
/// down at it and the tail curls toward it.
enum Mark {
    static let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
    static let unit = 824.0 / 160.0
    static let tileRadius = 36.0
    static let stroke = 15.0
    static let dotRadius = 7.5
    /// The loop: stem x, leg x, arch centre y, bottom y, and the radius of its lower corners.
    static let (left, right, archY, bottom, corner) = (54.0, 106.0, 63.0, 123.0, 22.0)
    /// Centre-to-centre distance from the spark to each open end.
    static let reach = 24.0
    /// How far along the missing corner's radius the spark sits (1 = on the stroke's path);
    /// a little less draws it in toward the centre of the loop.
    static let dotPull = 0.75

    static func point(_ x: Double, _ y: Double) -> NSPoint { NSPoint(x: 100 + x * unit, y: 924 - y * unit) }

    /// On the diagonal of the missing bottom-left corner.
    static var dot: (x: Double, y: Double) {
        let offset = corner * dotPull * 0.7071
        return (left + corner - offset, bottom - corner + offset)
    }

    /// Where the stem stops above the spark.
    static var stemEnd: Double { dot.y - (reach * reach - pow(dot.x - left, 2)).squareRoot() }

    /// Angle (degrees, clockwise from the right) where the tail's arc comes within `reach` of the spark.
    static var tailAngle: Double {
        let (vx, vy) = (dot.x - (right - corner), dot.y - (bottom - corner))
        let distance = (vx * vx + vy * vy).squareRoot()
        let spread = acos((corner * corner + distance * distance - reach * reach) / (2 * corner * distance))
        return (atan2(vy, vx) - spread) * 180 / .pi
    }

    static func glyph() -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: point(left, stemEnd))
        path.line(to: point(left, archY))
        let archRadius = (right - left) / 2
        path.appendArc(withCenter: point(left + archRadius, archY), radius: archRadius * unit, startAngle: 180, endAngle: 0, clockwise: true)
        path.line(to: point(right, bottom - corner))
        path.appendArc(withCenter: point(right - corner, bottom - corner), radius: corner * unit,
                       startAngle: 0, endAngle: -tailAngle, clockwise: true)
        path.lineWidth = stroke * unit
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        return path
    }

    static var dotCenter: NSPoint { point(dot.x, dot.y) }
}

func render(_ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    let transform = NSAffineTransform()
    transform.scale(by: CGFloat(pixels) / 1024)
    transform.concat()

    let shape = NSBezierPath(roundedRect: Mark.tile, xRadius: Mark.tileRadius * Mark.unit, yRadius: Mark.tileRadius * Mark.unit)
    let dropShadow = NSShadow()
    dropShadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    dropShadow.shadowBlurRadius = 22
    dropShadow.shadowOffset = NSSize(width: 0, height: -10)
    NSGraphicsContext.saveGraphicsState()
    dropShadow.set()
    NSColor.black.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Cobalt tile, a touch lighter at the top, with a faint sheen for depth.
    NSGradient(starting: NSColor(srgbRed: 0.19, green: 0.33, blue: 0.92, alpha: 1),
               ending: NSColor(srgbRed: 0.10, green: 0.20, blue: 0.68, alpha: 1))!.draw(in: shape, angle: -90)
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    NSGradient(starting: NSColor.white.withAlphaComponent(0.16), ending: NSColor.white.withAlphaComponent(0))!
        .draw(in: NSRect(x: 100, y: 512, width: 824, height: 412), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    let markShadow = NSShadow()
    markShadow.shadowColor = NSColor(srgbRed: 0.03, green: 0.07, blue: 0.3, alpha: 0.4)
    markShadow.shadowBlurRadius = 18
    markShadow.shadowOffset = NSSize(width: 0, height: -8)
    NSGraphicsContext.saveGraphicsState()
    markShadow.set()
    let cream = NSColor(srgbRed: 0.965, green: 0.937, blue: 0.89, alpha: 1)
    cream.setStroke()
    Mark.glyph().stroke()
    let d = Mark.dotRadius * Mark.unit
    let center = Mark.dotCenter
    NSColor(srgbRed: 0.92, green: 0.48, blue: 0.28, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: center.x - d, y: center.y - d, width: d * 2, height: d * 2)).fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

var arguments = Array(CommandLine.arguments.dropFirst())
if let flag = arguments.firstIndex(of: "--preview"), flag + 1 < arguments.count {
    try render(1024).write(to: URL(fileURLWithPath: arguments[flag + 1]))
    arguments.removeSubrange(flag...flag + 1)
}
let output = URL(fileURLWithPath: arguments[0])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    try render(size).write(to: output.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(size * 2).write(to: output.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
