import AppKit
import CoreImage

/// Drawing tools offered on a capture, in toolbar order; the number keys 1–8 pick them.
enum AnnotationTool: CaseIterable {
    case rectangle, ellipse, arrow, line, pen, marker, mosaic, text

    var title: String {
        switch self {
        case .rectangle: return L("Rectangle")
        case .ellipse: return L("Ellipse")
        case .arrow: return L("Arrow")
        case .line: return L("Line")
        case .pen: return L("Pen")
        case .marker: return L("Highlighter")
        case .mosaic: return L("Mosaic")
        case .text: return L("Text")
        }
    }

    var symbol: String {
        switch self {
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .arrow: return "arrow.up.right"
        case .line: return "line.diagonal"
        case .pen: return "scribble"
        case .marker: return "highlighter"
        case .mosaic: return "checkerboard.rectangle"
        case .text: return "textformat"
        }
    }

    /// Tools that draw a path through every point rather than between two corners.
    var isFreehand: Bool { self == .pen || self == .marker || self == .mosaic }
}

/// Shape and text options that persist between captures, mirroring the core's `capture.style`.
struct CaptureStyle: Codable, Equatable {
    var cornerRadius: CGFloat = 0
    var filled = false
    /// A font family name; empty means the system font.
    var font = ""
    var textSize: CGFloat = 20
    var bold = false
    var italic = false
    var underline = false
    var strikethrough = false

    enum CodingKeys: String, CodingKey {
        case cornerRadius = "corner_radius", filled, font, textSize = "text_size", bold, italic, underline, strikethrough
    }

    init() {}

    /// Missing keys keep their defaults, so older stored styles still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let base = CaptureStyle()
        cornerRadius = try c.decodeIfPresent(CGFloat.self, forKey: .cornerRadius) ?? base.cornerRadius
        filled = try c.decodeIfPresent(Bool.self, forKey: .filled) ?? base.filled
        font = try c.decodeIfPresent(String.self, forKey: .font) ?? base.font
        textSize = try c.decodeIfPresent(CGFloat.self, forKey: .textSize) ?? base.textSize
        bold = try c.decodeIfPresent(Bool.self, forKey: .bold) ?? base.bold
        italic = try c.decodeIfPresent(Bool.self, forKey: .italic) ?? base.italic
        underline = try c.decodeIfPresent(Bool.self, forKey: .underline) ?? base.underline
        strikethrough = try c.decodeIfPresent(Bool.self, forKey: .strikethrough) ?? base.strikethrough
    }

    var json: [String: Any] {
        ["corner_radius": Double(cornerRadius), "filled": filled, "font": font, "text_size": Double(textSize),
         "bold": bold, "italic": italic, "underline": underline, "strikethrough": strikethrough]
    }

    /// The chosen family with bold and italic applied where the family has them.
    var resolvedFont: NSFont {
        let manager = NSFontManager.shared
        var traits: NSFontTraitMask = []
        if bold { traits.insert(.boldFontMask) }
        if italic { traits.insert(.italicFontMask) }
        let base = font.isEmpty ? NSFont.systemFont(ofSize: textSize, weight: bold ? .bold : .medium)
            : manager.font(withFamily: font, traits: traits, weight: bold ? 9 : 5, size: textSize) ?? .systemFont(ofSize: textSize)
        return italic ? manager.convert(base, toHaveTrait: .italicFontMask) : base
    }

    func textAttributes(color: NSColor) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [.font: resolvedFont, .foregroundColor: color]
        if underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if strikethrough { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        return attributes
    }
}

/// One mark on a capture, in the capture view's coordinates (points, top-left origin).
struct Annotation {
    var tool: AnnotationTool
    var points: [CGPoint]
    var color: NSColor
    var width: CGFloat
    var style = CaptureStyle()
    var text = ""

    /// The rectangle spanned by the first and last point, for shape tools.
    var box: CGRect {
        guard let first = points.first, let last = points.last else { return .zero }
        return CGRect(x: min(first.x, last.x), y: min(first.y, last.y), width: abs(last.x - first.x), height: abs(last.y - first.y))
    }

    /// Mosaic needs the pixelated screen to reveal through its brush; everything else is plain paths.
    func draw(pixelated: CGImage?, imageFrame: CGRect) {
        color.setStroke()
        color.setFill()
        switch tool {
        case .rectangle:
            let radius = min(style.cornerRadius, box.width / 2, box.height / 2)
            let path = NSBezierPath(roundedRect: box, xRadius: radius, yRadius: radius)
            path.lineWidth = width
            path.lineJoinStyle = .round
            style.filled ? path.fill() : path.stroke()
        case .ellipse:
            let path = NSBezierPath(ovalIn: box)
            path.lineWidth = width
            style.filled ? path.fill() : path.stroke()
        case .line, .arrow:
            guard let start = points.first, let end = points.last else { return }
            let path = NSBezierPath()
            path.move(to: start)
            path.line(to: end)
            path.lineWidth = width
            path.lineCapStyle = .round
            if tool == .arrow { drawArrowhead(from: start, to: end) }
            path.stroke()
        case .pen:
            stroke(freehand(), width: width, alpha: 1)
        case .marker:
            stroke(freehand(), width: width * 5, alpha: 0.35)
        case .mosaic:
            guard let pixelated, let context = NSGraphicsContext.current?.cgContext else { return }
            let brush = freehand().cgPath.copy(strokingWithWidth: width * 6, lineCap: .round, lineJoin: .round, miterLimit: 1)
            context.saveGState()
            context.addPath(brush)
            context.clip()
            // The view is flipped; draw the image upright into the area it covers.
            context.translateBy(x: imageFrame.minX, y: imageFrame.maxY)
            context.scaleBy(x: 1, y: -1)
            context.draw(pixelated, in: CGRect(origin: .zero, size: imageFrame.size))
            context.restoreGState()
        case .text:
            guard let origin = points.first, !text.isEmpty else { return }
            NSAttributedString(string: text, attributes: style.textAttributes(color: color)).draw(at: origin)
        }
    }

    private func freehand() -> NSBezierPath {
        let path = NSBezierPath()
        guard let first = points.first else { return path }
        path.move(to: first)
        // Midpoint quadratic smoothing turns jittery mouse samples into a calm curve.
        for index in 1..<max(points.count, 1) {
            let previous = points[index - 1], current = points[index]
            let mid = CGPoint(x: (previous.x + current.x) / 2, y: (previous.y + current.y) / 2)
            path.curve(to: mid, controlPoint1: previous, controlPoint2: previous)
        }
        if let last = points.last { path.line(to: last) }
        return path
    }

    private func stroke(_ path: NSBezierPath, width: CGFloat, alpha: CGFloat) {
        color.withAlphaComponent(alpha).setStroke()
        path.lineWidth = width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()
    }

    private func drawArrowhead(from start: CGPoint, to end: CGPoint) {
        let angle = atan2(end.y - start.y, end.x - start.x)
        let length = max(12, width * 4.5), spread = CGFloat.pi / 7
        let head = NSBezierPath()
        head.move(to: end)
        head.line(to: CGPoint(x: end.x - length * cos(angle - spread), y: end.y - length * sin(angle - spread)))
        head.line(to: CGPoint(x: end.x - length * cos(angle + spread), y: end.y - length * sin(angle + spread)))
        head.close()
        head.fill()
    }
}

extension NSBezierPath {
    /// AppKit paths as Core Graphics paths, for stroking outlines (mosaic brushes).
    var cgPath: CGPath {
        let path = CGMutablePath()
        var points = [NSPoint](repeating: .zero, count: 3)
        for index in 0..<elementCount {
            switch element(at: index, associatedPoints: &points) {
            case .moveTo: path.move(to: points[0])
            case .lineTo: path.addLine(to: points[0])
            case .curveTo, .cubicCurveTo: path.addCurve(to: points[2], control1: points[0], control2: points[1])
            case .quadraticCurveTo: path.addQuadCurve(to: points[1], control: points[0])
            case .closePath: path.closeSubpath()
            @unknown default: break
            }
        }
        return path
    }
}

enum CaptureRenderer {
    /// A blocky version of the whole frozen screen, revealed by the mosaic brush.
    static func pixelate(_ image: CGImage, blockSize: CGFloat) -> CGImage? {
        let input = CIImage(cgImage: image)
        guard let filter = CIFilter(name: "CIPixellate") else { return nil }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(blockSize, forKey: kCIInputScaleKey)
        filter.setValue(CIVector(x: 0, y: 0), forKey: kCIInputCenterKey)
        guard let output = filter.outputImage?.cropped(to: input.extent) else { return nil }
        return CIContext(options: [.useSoftwareRenderer: false]).createCGImage(output, from: input.extent)
    }

    /// The selection at full pixel resolution with every annotation drawn on top — what is copied,
    /// saved, and pinned.
    static func render(_ frozen: FrozenScreen, selection: CGRect, annotations: [Annotation], pixelated: CGImage?) -> NSImage? {
        let scale = frozen.scale
        let pixels = CGRect(x: selection.minX * scale, y: selection.minY * scale,
                            width: selection.width * scale, height: selection.height * scale).integral
        guard pixels.width >= 1, pixels.height >= 1,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: Int(pixels.width), height: Int(pixels.height), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Work in the capture view's flipped point coordinates, so annotations draw exactly as on screen.
        context.translateBy(x: 0, y: pixels.height)
        context.scaleBy(x: scale, y: -scale)
        context.translateBy(x: -selection.minX, y: -selection.minY)
        let screenFrame = CGRect(origin: .zero, size: frozen.screen.frame.size)
        context.saveGState()
        context.translateBy(x: 0, y: screenFrame.height)
        context.scaleBy(x: 1, y: -1)
        context.draw(frozen.image, in: screenFrame)
        context.restoreGState()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        for annotation in annotations { annotation.draw(pixelated: pixelated, imageFrame: screenFrame) }
        NSGraphicsContext.restoreGraphicsState()
        guard let output = context.makeImage() else { return nil }
        return NSImage(cgImage: output, size: selection.size)
    }

    /// PNG or JPEG bytes for saving and the clipboard.
    static func encode(_ image: NSImage, format: String) -> Data? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        rep.size = image.size
        return format == "jpg" ? rep.representation(using: .jpeg, properties: [.compressionFactor: 0.92])
                               : rep.representation(using: .png, properties: [:])
    }
}
