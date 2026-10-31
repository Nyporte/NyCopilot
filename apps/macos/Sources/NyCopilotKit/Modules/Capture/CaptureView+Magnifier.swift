import AppKit

/// The magnifier beside the pointer: a pixel grid, the position, the selection's size, and the color.
extension CaptureView {
    static let magnifierZoom: CGFloat = 8, magnifierSpan: CGFloat = 17

    /// The magnifier's lines and the size of the panel under the zoom.
    func magnifierLines(at point: CGPoint) -> (lines: [(text: NSAttributedString, swatch: NSColor?)], panel: CGSize) {
        let zoom = Self.magnifierZoom, span = Self.magnifierSpan
        let box = CGSize(width: span * zoom, height: span * zoom)
        let scale = frozen.scale
        // Whole pixels around the pointer, so every cell in the grid is exactly one screen pixel.
        let center = CGPoint(x: floor(point.x * scale), y: floor(point.y * scale))

        // The lines under the zoom, measured first so the panel fits the longest one.
        let mono = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        let bold = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        let small = NSFont.systemFont(ofSize: 10.5), smallBold = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
        let dim = NSColor.white.withAlphaComponent(0.55)
        func text(_ parts: [(String, NSFont, NSColor)]) -> NSAttributedString {
            let line = NSMutableAttributedString()
            for (string, font, color) in parts { line.append(NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color])) }
            return line
        }
        var lines: [(text: NSAttributedString, swatch: NSColor?)] = []
        lines.append((text([("X \(Int(center.x))   Y \(Int(center.y))", mono, .white)]), nil))
        if isSizing, let selection {
            lines.append((text([("\(Int((selection.width * scale).rounded())) × \(Int((selection.height * scale).rounded())) px", mono, .white)]), nil))
        }
        let swatch = color(at: point)
        if let swatch {
            lines.append((text([(swatch.hexString, copiesHex ? bold : mono, copiesHex ? .white : dim)]), swatch))
            lines.append((text([(Self.rgb(swatch), copiesHex ? mono : bold, copiesHex ? dim : .white)]), nil))
        }
        if let copiedFlash {
            lines.append((text([(copiedFlash, smallBold, .systemGreen)]), nil))
        } else {
            lines.append((text([("C", smallBold, .white), (L(" copy  ·  "), small, dim), ("⇧", smallBold, .white), (L(" switch format"), small, dim)]), nil))
        }
        // While hovering: what's being outlined, and how to switch.
        if selection == nil {
            lines.append((text([(Self.detectsWindows ? L("Windows") : L("Elements"), smallBold, .white),
                                ("  ·  ", small, dim), ("Tab", smallBold, .white),
                                (Self.detectsWindows ? L(" for elements") : L(" for windows"), small, dim)]), nil))
            if Self.showsKeysTip {
                lines.append((text([("?", smallBold, .white), (L(" all keys  ·  then "), small, dim), ("A", smallBold, .white), (L(" asks AI"), small, dim)]), nil))
            }
        }
        let textWidth = lines.map { $0.text.size().width + ($0.swatch == nil ? 0 : Self.swatchIndent) }.max() ?? 0
        let panel = CGSize(width: max(box.width, ceil(textWidth) + Self.padding * 2), height: CGFloat(lines.count) * Self.lineHeight + 12)
        return (lines, panel)
    }

    static let padding: CGFloat = 9, swatchIndent: CGFloat = 17, lineHeight: CGFloat = 15

    /// Beside the pointer, flipped to the other side near a screen edge: the zoom and the panel under it.
    func magnifierFrame(at point: CGPoint, panel: CGSize? = nil) -> CGRect {
        let side = Self.magnifierSpan * Self.magnifierZoom
        let panel = panel ?? magnifierLines(at: point).panel
        let width = max(side, panel.width), height = side + 4 + panel.height
        var origin = CGPoint(x: point.x + 20, y: point.y + 20)
        if origin.x + width > bounds.maxX - 8 { origin.x = point.x - 20 - width }
        if origin.y + height > bounds.maxY - 8 { origin.y = point.y - 20 - height }
        origin.x = max(origin.x, bounds.minX + 8)
        return CGRect(origin: origin, size: CGSize(width: width, height: height))
    }

    /// Draws the magnifier where `magnifierFrame` puts it, in this view's coordinates.
    func drawMagnifier(at point: CGPoint) {
        let zoom = Self.magnifierZoom, span = Self.magnifierSpan
        let box = CGSize(width: span * zoom, height: span * zoom)
        let scale = frozen.scale
        let center = CGPoint(x: floor(point.x * scale), y: floor(point.y * scale))
        let (lines, panel) = magnifierLines(at: point)
        let padding = Self.padding, swatchIndent = Self.swatchIndent, lineHeight = Self.lineHeight
        let frame = CGRect(origin: magnifierFrame(at: point, panel: panel).origin, size: box)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let half = floor(span / 2)
        let source = CGRect(x: center.x - half, y: center.y - half, width: span, height: span)
        context.saveGState()
        NSBezierPath(roundedRect: frame, xRadius: 8, yRadius: 8).addClip()
        NSColor.black.setFill()
        frame.fill()
        if let crop = frozen.image.cropping(to: source) {
            context.interpolationQuality = .none
            context.translateBy(x: frame.minX, y: frame.maxY)
            context.scaleBy(x: 1, y: -1)
            context.draw(crop, in: CGRect(origin: .zero, size: box))
            context.scaleBy(x: 1, y: -1)
            context.translateBy(x: -frame.minX, y: -frame.maxY)
        }
        NSColor.white.withAlphaComponent(0.08).setFill()
        for index in 1..<Int(span) {
            let offset = CGFloat(index) * zoom
            CGRect(x: frame.minX + offset, y: frame.minY, width: 0.5, height: frame.height).fill(using: .sourceOver)
            CGRect(x: frame.minX, y: frame.minY + offset, width: frame.width, height: 0.5).fill(using: .sourceOver)
        }
        context.restoreGState()
        // The pixel the pointer is on, outlined.
        let cell = CGRect(x: frame.minX + half * zoom, y: frame.minY + half * zoom, width: zoom, height: zoom)
        NSColor.white.setStroke()
        NSBezierPath(rect: cell.insetBy(dx: -0.5, dy: -0.5)).stroke()
        NSColor.white.withAlphaComponent(0.9).setStroke()
        let ring = NSBezierPath(roundedRect: frame, xRadius: 8, yRadius: 8)
        ring.lineWidth = 2
        ring.stroke()

        let plate = CGRect(origin: CGPoint(x: frame.minX, y: frame.maxY + 4), size: panel)
        NSColor.black.withAlphaComponent(0.78).setFill()
        NSBezierPath(roundedRect: plate, xRadius: 7, yRadius: 7).fill()
        var y = plate.minY + 6
        for line in lines {
            var x = plate.minX + padding
            if let swatch = line.swatch {
                swatch.setFill()
                NSBezierPath(roundedRect: CGRect(x: x, y: y + 2, width: 11, height: 11), xRadius: 2, yRadius: 2).fill()
                x += swatchIndent
            }
            line.text.draw(at: CGPoint(x: x, y: y))
            y += lineHeight
        }
    }

    /// Dragging out or resizing a selection: the magnifier also shows its size.
    var isSizing: Bool {
        switch drag {
        case .creating, .resizing: return true
        default: return false
        }
    }

    static func rgb(_ color: NSColor) -> String {
        "RGB \(Int(round(color.redComponent * 255))), \(Int(round(color.greenComponent * 255))), \(Int(round(color.blueComponent * 255)))"
    }

    // MARK: Pixels

    func color(at point: CGPoint) -> NSColor? {
        let scale = frozen.scale
        let pixel = CGRect(x: floor(point.x * scale), y: floor(point.y * scale), width: 1, height: 1)
        guard let crop = frozen.image.cropping(to: pixel), let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var bytes = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return NSColor(srgbRed: CGFloat(bytes[0]) / 255, green: CGFloat(bytes[1]) / 255, blue: CGFloat(bytes[2]) / 255, alpha: 1)
    }
}
