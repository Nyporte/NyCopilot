import AppKit

final class CaptureWindow: NSPanel {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = true
        hasShadow = false
        backgroundColor = .black
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// A cubic Bézier timing curve from (0, 0) to (1, 1), as in CSS `cubic-bezier()`: the outline's
/// glide and the handles' growth follow these.
struct BezierCurve {
    let x1, y1, x2, y2: Double

    /// Quick to leave, gentle to arrive.
    static let easeOut = BezierCurve(x1: 0.33, y1: 1, x2: 0.68, y2: 1)
    /// Goes a little past the end and settles back.
    static let overshoot = BezierCurve(x1: 0.34, y1: 1.45, x2: 0.64, y2: 1)

    /// Progress at time `t` (0…1, clamped): the curve's y where its x is `t`.
    func value(at t: Double) -> CGFloat {
        let t = min(max(t, 0), 1)
        func bezier(_ a: Double, _ b: Double, _ s: Double) -> Double { 3 * a * s * (1 - s) * (1 - s) + 3 * b * s * s * (1 - s) + s * s * s }
        // Solve x(s) = t: a few Newton steps, then bisection if the slope is too flat.
        var s = t
        for _ in 0..<6 {
            let x = bezier(x1, x2, s) - t
            let slope = 3 * x1 * (1 - s) * (1 - s) + 6 * (x2 - x1) * s * (1 - s) + 3 * (1 - x2) * s * s
            if abs(x) < 1e-5 { break }
            guard abs(slope) > 1e-6 else { break }
            s = min(max(s - x / slope, 0), 1)
        }
        if abs(bezier(x1, x2, s) - t) > 1e-3 {
            var low = 0.0, high = 1.0
            for _ in 0..<30 {
                s = (low + high) / 2
                if bezier(x1, x2, s) < t { low = s } else { high = s }
            }
        }
        return CGFloat(bezier(y1, y2, s))
    }
}

extension CGRect {
    init(center: CGPoint, size: CGFloat) {
        self.init(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)
    }

    init(corners a: CGPoint, _ b: CGPoint) {
        self.init(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }
}

/// The live text box of the text tool. No padding or insets, so its origin is where the committed
/// annotation draws its first line.
@MainActor
final class TextAnnotationEditor: NSTextView {
    init(origin: CGPoint) {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        layout.addTextContainer(container)
        super.init(frame: CGRect(origin: origin, size: CGSize(width: 2, height: 20)), textContainer: container)
        textContainerInset = .zero
        drawsBackground = false
        isRichText = false
        allowsUndo = true
        isHorizontallyResizable = true
        isVerticallyResizable = true
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        focusRingType = .none
    }

    override init(frame: NSRect, textContainer: NSTextContainer?) { super.init(frame: frame, textContainer: textContainer) }
    required init?(coder: NSCoder) { fatalError("Use init(origin:)") }

    /// Restyles everything typed so far and what comes next.
    func apply(_ style: CaptureStyle, color: NSColor) {
        let attributes = style.textAttributes(color: color)
        typingAttributes = attributes
        insertionPointColor = color
        if let storage = textStorage, storage.length > 0 {
            storage.setAttributes(attributes, range: NSRange(location: 0, length: storage.length))
        }
        fitToText()
    }

    /// Grows with the text; never narrower than the caret, never shorter than one line.
    func fitToText() {
        guard let layout = layoutManager, let container = textContainer else { return }
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        let font = typingAttributes[.font] as? NSFont ?? .systemFont(ofSize: 20)
        let lineHeight = layout.defaultLineHeight(for: font)
        setFrameSize(CGSize(width: ceil(max(used.width, 1)) + 2, height: ceil(max(used.height, lineHeight))))
        superview?.needsDisplay = true
    }
}
