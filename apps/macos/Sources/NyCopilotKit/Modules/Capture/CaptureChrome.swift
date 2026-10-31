import AppKit
import QuartzCore

/// The capture's moving parts, drawn by the GPU over the frozen screen: the dimming with its hole,
/// the outline or selection frame, and the handles. A full-screen view redraws all of itself on
/// current macOS however little changes, so these live in layers whose shapes change instead; the
/// capture view itself only redraws when annotations do. The label and magnifier are small views.
final class CaptureChrome: NSView {
    private let dim = CAShapeLayer()
    private let outline = CAShapeLayer()
    private let handles = (0..<8).map { _ in CAShapeLayer() }

    override init(frame: NSRect) {
        super.init(frame: frame)
        // Layer-hosting: these layers are ours to arrange.
        let root = CALayer()
        root.isGeometryFlipped = true
        layer = root
        wantsLayer = true
        dim.fillRule = .evenOdd
        outline.fillColor = nil
        outline.lineWidth = 1.5
        for shape in [dim, outline] + handles { root.addSublayer(shape) }
        for handle in handles { handle.fillColor = NSColor.white.cgColor }
    }

    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

    override var isFlipped: Bool { true }
    /// Clicks go to the capture view beneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Everything outside `focus` dimmed; `frame` outlined; handles as (center, growth 0…1).
    func show(dimming alpha: CGFloat, focus: CGRect?, frame: CGRect?, handles spots: [(CGPoint, CGFloat)]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let shade = CGMutablePath()
        shade.addRect(bounds)
        if let focus { shade.addRect(focus) }
        dim.path = shade
        dim.fillColor = NSColor.black.withAlphaComponent(alpha).cgColor
        let accent = NSColor.controlAccentColor.cgColor
        outline.strokeColor = accent
        outline.path = frame.map { CGPath(rect: $0.insetBy(dx: -0.5, dy: -0.5), transform: nil) }
        for (index, handle) in handles.enumerated() {
            guard index < spots.count else { handle.path = nil; continue }
            let (center, grown) = spots[index]
            handle.path = CGPath(ellipseIn: CGRect(center: center, size: 7 + 7 * grown), transform: nil)
            handle.strokeColor = accent
            handle.lineWidth = 1.5 + 0.5 * grown
        }
    }
}

/// The size label beside an outline or selection: redrawn only when its text changes.
final class CaptureLabel: NSView {
    static let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                                                             .foregroundColor: NSColor.white]
    var text = "" { didSet { if text != oldValue { needsDisplay = true } } }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.65).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
        (text as NSString).draw(at: CGPoint(x: 6, y: 3), withAttributes: Self.attributes)
    }
}

/// The magnifier, drawn by the capture view into this small view, which moves with the pointer.
final class MagnifierView: NSView {
    weak var owner: CaptureView?
    var pointer: CGPoint?

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let owner, let pointer, let context = NSGraphicsContext.current?.cgContext else { return }
        // The capture view's coordinates, shifted to this view.
        context.translateBy(x: -frame.minX, y: -frame.minY)
        owner.drawMagnifier(at: pointer)
    }
}
