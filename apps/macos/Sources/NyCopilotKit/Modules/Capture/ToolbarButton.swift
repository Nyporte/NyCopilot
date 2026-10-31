import AppKit
import QuartzCore

/// An icon button for the capture toolbar that answers the pointer. A soft plate fades in behind it
/// and the symbol lifts a little; pressing sinks it, and it springs back. The selected tool keeps
/// a faint accent plate. Tint changes cross-fade, and `pop()` bounces the symbol and sends one ring
/// out, for news worth a glance (text found in the selection). With Reduce Motion, only fades.
@MainActor
final class ToolbarButton: NSButton, CALayerDelegate {
    private let plate = CALayer()
    private let icon = CALayer()
    private let ring = CAShapeLayer()
    private let symbol: NSImage
    private var hovering = false

    init(symbol name: String, tip: String) {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: tip) ?? NSImage()
        symbol = image.withSymbolConfiguration(.init(pointSize: 14, weight: .medium)) ?? image
        super.init(frame: NSRect(x: 0, y: 0, width: 28, height: 26))
        title = ""
        isBordered = false
        imagePosition = .imageOnly
        toolTip = tip
        setAccessibilityLabel(tip)
        wantsLayer = true
        plate.cornerRadius = 6
        plate.opacity = 0
        ring.fillColor = nil
        ring.lineWidth = 1.5
        ring.opacity = 0
        icon.delegate = self
        icon.needsDisplayOnBoundsChange = true
        for sublayer in [plate, ring, icon] { layer?.addSublayer(sublayer) }
        widthAnchor.constraint(equalToConstant: 28).isActive = true
        heightAnchor.constraint(equalToConstant: 26).isActive = true
        contentTintColor = .white
    }

    required init?(coder: NSCoder) { fatalError("Use init(symbol:tip:)") }

    private static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    // MARK: Look

    override var contentTintColor: NSColor? {
        didSet { if contentTintColor != oldValue { drawIcon(fading: window != nil) } }
    }

    override var state: NSControl.StateValue { didSet { showPlate() } }

    override var isEnabled: Bool {
        didSet {
            if !isEnabled { hovering = false }
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.15)
            icon.opacity = isEnabled ? 1 : 0.35
            CATransaction.commit()
            showPlate()
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        plate.frame = bounds.insetBy(dx: 1, dy: 1)
        let size = symbol.size
        icon.bounds = CGRect(origin: .zero, size: size)
        icon.position = CGPoint(x: bounds.midX, y: bounds.midY)
        let side = min(bounds.width, bounds.height)
        ring.frame = CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
        ring.path = CGPath(ellipseIn: ring.bounds.insetBy(dx: 2, dy: 2), transform: nil)
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        drawIcon(fading: false)
    }

    private func drawIcon(fading: Bool) {
        if fading {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.22
            icon.add(fade, forKey: "tint")
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        icon.contentsScale = window?.backingScaleFactor ?? 2
        icon.setNeedsDisplay()
        icon.displayIfNeeded()
        ring.strokeColor = (contentTintColor ?? .white).cgColor
        CATransaction.commit()
    }

    /// The symbol, drawn through AppKit so it's upright whichever way the layer tree is flipped.
    nonisolated func draw(_ layer: CALayer, in context: CGContext) {
        MainActor.assumeIsolated {
            let tinted = symbol.withSymbolConfiguration(.init(paletteColors: [contentTintColor ?? .white])) ?? symbol
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: layer.contentsAreFlipped())
            tinted.draw(in: layer.bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    /// Hover shows a plate; the selected tool keeps a faint accent one.
    private func showPlate() {
        let selected = state == .on
        let color: NSColor = selected ? .controlAccentColor.withAlphaComponent(hovering ? 0.32 : 0.22)
            : .white.withAlphaComponent(0.14)
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.15)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        plate.backgroundColor = color.cgColor
        plate.opacity = selected || (hovering && isEnabled) ? 1 : 0
        CATransaction.commit()
    }

    // MARK: Motion

    /// Springs the symbol to `value` times its size, from wherever it is now.
    private func scale(to value: CGFloat, from start: CGFloat? = nil, damping: CGFloat = 15) {
        guard !Self.reduceMotion else { return }
        let current = start ?? (icon.presentation()?.value(forKeyPath: "transform.scale") as? CGFloat ?? 1)
        let spring = CASpringAnimation(keyPath: "transform.scale")
        spring.fromValue = current
        spring.toValue = value
        spring.mass = 0.6
        spring.stiffness = 300
        spring.damping = damping
        spring.duration = spring.settlingDuration
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        icon.setValue(value, forKeyPath: "transform.scale")
        CATransaction.commit()
        icon.add(spring, forKey: "scale")
    }

    /// A bounce and one ring rippling out in the tint, to say "this just became useful".
    func pop() {
        scale(to: hovering ? 1.12 : 1, from: 1.38, damping: 9)
        guard !Self.reduceMotion else { return }
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.6
        grow.toValue = 1.5
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.9
        fade.toValue = 0
        let ripple = CAAnimationGroup()
        ripple.animations = [grow, fade]
        ripple.duration = 0.55
        ripple.timingFunction = CAMediaTimingFunction(name: .easeOut)
        ring.add(ripple, forKey: "ripple")
    }

    // MARK: Pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.filter { $0.owner === self }.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        guard isEnabled else { return }
        hovering = true
        showPlate()
        scale(to: 1.12)
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        showPlate()
        scale(to: 1)
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return super.mouseDown(with: event) }
        scale(to: 0.88)
        // Tracks the press until the button goes up, then acts.
        super.mouseDown(with: event)
        scale(to: hovering ? 1.12 : 1, damping: 11)
    }
}
