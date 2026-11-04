import AppKit

/// One display's overlay, in the manner of Live Text: the screen dimmed a little except for its text,
/// each block (a paragraph's lines together) one glowing shape; the block under the pointer outlined;
/// and a glow along the screen's edges. Every click and scroll goes through to what's underneath.
@MainActor
final class TranslationOverlay: NSWindow {
    /// The lines of the block under the pointer, in this display's points (top-left).
    var hovered: [CGRect] = [] { didSet { if hovered != oldValue { canvas.hovered = hovered } } }
    let canvas: Canvas

    init(screen: NSScreen) {
        canvas = Canvas()
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        float(at: .screenOverlay, shadow: false, clickThrough: true, behavior: [.stationary, .ignoresCycle])
        contentView = canvas
        setFrame(screen.frame, display: false)
    }

    /// The blocks to highlight, each as its lines, in this display's points (top-left).
    func show(_ blocks: [[CGRect]]) { canvas.show(blocks) }

    final class Canvas: NSView {
        /// Each block's shape, keyed by where it is, and when it appeared — new blocks fade in.
        private var blocks: [(key: String, outline: NSBezierPath)] = []
        private var appeared: [String: CFTimeInterval] = [:]
        private var fading: Timer?
        private static let fadeIn: CFTimeInterval = 0.25
        var hovered: [CGRect] = [] { didSet { needsDisplay = true } }

        init() {
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("Use init()") }

        override var isFlipped: Bool { true }

        /// One shape around a block's lines: each line padded a little, neighbours meeting halfway between
        /// them, the left edge running down the lines' starts and the right edge back up their ends, every
        /// corner rounded (less on small steps). A single line is a rounded rectangle.
        static func outline(of lines: [CGRect]) -> NSBezierPath {
            let rows = smoothed(lines.map { $0.insetBy(dx: -3, dy: -2) }.sorted { $0.minY < $1.minY })
            guard let first = rows.first else { return NSBezierPath() }
            guard rows.count > 1 else { return NSBezierPath(roundedRect: first, xRadius: 4, yRadius: 4) }
            // Where each row starts and ends vertically, with no gaps between neighbours.
            var edges = [first.minY]
            for (upper, lower) in zip(rows, rows.dropFirst()) { edges.append((upper.maxY + lower.minY) / 2) }
            edges.append(rows.last!.maxY)
            // Around the shape clockwise (top-left origin): across the top, down the right, back along the
            // bottom, up the left.
            var corners = [CGPoint(x: first.minX, y: edges[0])]
            for (index, row) in rows.enumerated() {
                corners.append(CGPoint(x: row.maxX, y: edges[index]))
                corners.append(CGPoint(x: row.maxX, y: edges[index + 1]))
            }
            for (index, row) in rows.enumerated().reversed() {
                corners.append(CGPoint(x: row.minX, y: edges[index + 1]))
                corners.append(CGPoint(x: row.minX, y: edges[index]))
            }
            // Drop repeats and points in the middle of a straight run.
            var points: [CGPoint] = []
            for point in corners where points.last.map({ hypot($0.x - point.x, $0.y - point.y) > 0.5 }) ?? true { points.append(point) }
            if let last = points.last, hypot(last.x - points[0].x, last.y - points[0].y) <= 0.5 { points.removeLast() }
            points = points.indices.compactMap { index in
                let before = points[(index + points.count - 1) % points.count], point = points[index], after = points[(index + 1) % points.count]
                let straight = (abs(before.x - point.x) < 0.5 && abs(point.x - after.x) < 0.5) || (abs(before.y - point.y) < 0.5 && abs(point.y - after.y) < 0.5)
                return straight ? nil : point
            }
            guard points.count >= 3 else { return NSBezierPath(roundedRect: rows.reduce(first) { $0.union($1) }, xRadius: 4, yRadius: 4) }
            let path = NSBezierPath()
            let count = points.count
            func middle(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
            path.move(to: middle(points[count - 1], points[0]))
            for index in 0..<count {
                let point = points[index], before = points[(index + count - 1) % count], after = points[(index + 1) % count]
                let room = min(hypot(point.x - before.x, point.y - before.y), hypot(after.x - point.x, after.y - point.y)) / 2
                path.appendArc(from: point, to: middle(point, after), radius: min(4, room))
            }
            path.close()
            return path
        }

        /// Edges evened out: consecutive lines whose starts (or ends) lie within about two characters of
        /// each other share one edge, at the outermost of them so no text is cut — only real differences,
        /// like a short last line or an indent, make a step.
        static func smoothed(_ rows: [CGRect]) -> [CGRect] {
            guard rows.count > 1 else { return rows }
            let heights = rows.map(\.height).sorted()
            let tolerance = heights[heights.count / 2] * 1.4
            func even(_ values: [CGFloat], outermost: (CGFloat, CGFloat) -> CGFloat) -> [CGFloat] {
                var result = values, start = 0
                while start < values.count {
                    var end = start + 1, edge = values[start]
                    while end < values.count, abs(values[end] - edge) <= tolerance {
                        edge = outermost(edge, values[end])
                        end += 1
                    }
                    for index in start..<end { result[index] = edge }
                    start = end
                }
                return result
            }
            let starts = even(rows.map(\.minX), outermost: min), ends = even(rows.map(\.maxX), outermost: max)
            return rows.indices.map { CGRect(x: starts[$0], y: rows[$0].minY, width: ends[$0] - starts[$0], height: rows[$0].height) }
        }

        /// New blocks fade in; blocks still there keep their place in the fade; blocks gone are gone at once.
        func show(_ lines: [[CGRect]]) {
            let now = CACurrentMediaTime()
            blocks = lines.map { block in
                let box = block.reduce(block[0]) { $0.union($1) }
                return ("\(Int(box.minX)),\(Int(box.minY)),\(Int(box.width)),\(Int(box.height))", Self.outline(of: block))
            }
            appeared = Dictionary(blocks.map { ($0.key, appeared[$0.key] ?? now) }, uniquingKeysWith: { first, _ in first })
            needsDisplay = true
            guard fading == nil, appeared.values.contains(where: { now - $0 < Self.fadeIn }) else { return }
            fading = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
                MainActor.assumeIsolated {
                    guard let self else { return timer.invalidate() }
                    self.needsDisplay = true
                    if !self.appeared.values.contains(where: { CACurrentMediaTime() - $0 < Self.fadeIn }) {
                        timer.invalidate()
                        self.fading = nil
                    }
                }
            }
        }

        /// How far a block has faded in, eased.
        private func opacity(_ key: String, at now: CFTimeInterval) -> CGFloat {
            let progress = min(1, max(0, (now - (appeared[key] ?? 0)) / Self.fadeIn))
            return CGFloat(progress * progress * (3 - 2 * progress))
        }

        override func draw(_ dirtyRect: NSRect) {
            guard let context = NSGraphicsContext.current?.cgContext else { return }
            let now = CACurrentMediaTime()
            // Dim the screen, then cut every block back out, so the text stands out as with Live Text.
            NSColor.black.withAlphaComponent(0.2).setFill()
            bounds.fill()
            context.setBlendMode(.destinationOut)
            for block in blocks {
                NSColor.black.withAlphaComponent(opacity(block.key, at: now)).setFill()
                block.outline.fill()
            }
            context.setBlendMode(.normal)
            // A soft white glow along each block's edge.
            for block in blocks {
                let shown = opacity(block.key, at: now)
                NSGraphicsContext.saveGraphicsState()
                let glow = NSShadow()
                glow.shadowColor = NSColor.white.withAlphaComponent(0.9 * shown)
                glow.shadowBlurRadius = 5
                glow.set()
                NSColor.white.withAlphaComponent(0.75 * shown).setStroke()
                block.outline.lineWidth = 1
                block.outline.stroke()
                NSGraphicsContext.restoreGraphicsState()
            }
            // The block under the pointer, outlined.
            if !hovered.isEmpty {
                let outline = Self.outline(of: hovered)
                NSColor.controlAccentColor.setStroke()
                outline.lineWidth = 2
                outline.stroke()
            }
            drawEdges()
        }

        /// A soft accent glow fading in from every edge: the screen is being translated.
        private func drawEdges() {
            let accent = NSColor.controlAccentColor
            for inset in 0..<6 {
                accent.withAlphaComponent(0.42 - CGFloat(inset) * 0.07).setStroke()
                let path = NSBezierPath(rect: bounds.insetBy(dx: CGFloat(inset) + 0.5, dy: CGFloat(inset) + 0.5))
                path.lineWidth = 1
                path.stroke()
            }
        }
    }
}
