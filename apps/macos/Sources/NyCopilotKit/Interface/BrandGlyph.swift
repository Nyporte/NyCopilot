import AppKit

/// The NyCopilot mark: a tall open loop that reads as "ny", with a spark in its opening — the stem
/// points down at the spark and the tail curls toward it. Same construction as
/// Scripts/make-icon.swift, in that script's 160-unit tile space (y down).
enum BrandGlyph {
    private static let stroke: CGFloat = 15
    private static let dotRadius: CGFloat = 7.5
    private static let (left, right, archY, bottom, corner): (CGFloat, CGFloat, CGFloat, CGFloat, CGFloat) = (54, 106, 63, 123, 22)
    private static let reach: CGFloat = 24
    private static let dotPull: CGFloat = 0.88
    private static let dot: NSPoint = {
        let offset: CGFloat = corner * dotPull * 0.7071
        return NSPoint(x: left + corner - offset, y: bottom - corner + offset)
    }()
    private static let stemEnd: CGFloat = {
        let dx: CGFloat = dot.x - left
        return dot.y - (reach * reach - dx * dx).squareRoot()
    }()
    private static let tailAngle: CGFloat = {
        let vx: CGFloat = dot.x - (right - corner)
        let vy: CGFloat = dot.y - (bottom - corner)
        let distance: CGFloat = (vx * vx + vy * vy).squareRoot()
        let cosine: CGFloat = (corner * corner + distance * distance - reach * reach) / (2 * corner * distance)
        return (atan2(vy, vx) - acos(cosine)) * 180 / .pi
    }()
    /// The mark's extent in tile units, including stroke width.
    private static let bounds = NSRect(x: left - stroke / 2, y: archY - (right - left) / 2 - stroke / 2,
                                       width: right - left + stroke, height: bottom - archY + (right - left) / 2 + stroke)

    /// The stroke (to be stroked) and the spark (to be filled), fitted and centred in `rect`.
    static func mark(in rect: NSRect) -> (stroke: NSBezierPath, spark: NSBezierPath) {
        let scale = min(rect.width / bounds.width, rect.height / bounds.height)
        let origin = NSPoint(x: rect.midX - bounds.width * scale / 2, y: rect.midY + bounds.height * scale / 2)
        func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: origin.x + (x - bounds.minX) * scale, y: origin.y - (y - bounds.minY) * scale)
        }
        let archRadius = (right - left) / 2
        let path = NSBezierPath()
        path.move(to: point(left, stemEnd))
        path.line(to: point(left, archY))
        path.appendArc(withCenter: point(left + archRadius, archY), radius: archRadius * scale, startAngle: 180, endAngle: 0, clockwise: true)
        path.line(to: point(right, bottom - corner))
        path.appendArc(withCenter: point(right - corner, bottom - corner), radius: corner * scale,
                       startAngle: 0, endAngle: -tailAngle, clockwise: true)
        path.lineWidth = stroke * scale
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        let center = point(dot.x, dot.y)
        let r = dotRadius * scale
        return (path, NSBezierPath(ovalIn: NSRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)))
    }

    /// Template image for the menu bar, so macOS tints it for light, dark, and highlighted states.
    static func menuBarImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let (stroke, spark) = mark(in: rect.insetBy(dx: 1, dy: 1))
            NSColor.black.set()
            stroke.stroke()
            spark.fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "NyCopilot"
        return image
    }
}
