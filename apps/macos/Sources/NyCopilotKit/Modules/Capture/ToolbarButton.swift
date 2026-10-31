import AppKit
import QuartzCore

/// An icon button for the capture toolbar that answers the pointer with light, not size: icons
/// rest a little dimmed, and the one under the pointer brightens as a soft plate fades in behind
/// it; pressing dims it, as if pushed in. The selected tool keeps a faint accent plate. Tint
/// changes blend from one color to the next, and `pop()` sends one ring out, for news worth a
/// glance (text found in the selection).
///
/// The symbol is one bitmap, drawn once at the screen's resolution on the pixel grid, filled with
/// the tint through a mask. It never changes size, so it is always as sharp as AppKit's own icons:
/// a scaled bitmap goes soft, and redrawing at every size jitters between pixels.
@MainActor
final class ToolbarButton: NSButton, CALayerDelegate {
    private let plate = CALayer()
    private let icon = CALayer()
    private let glyph = CALayer()
    private let ring = CAShapeLayer()
    private let symbol: NSImage
    private var hovering = false
    /// Whether it shows the hovered look now.
    var isHovered: Bool { hovering }
    /// Whether the plate behind it shows (once any fade ends).
    var showsPlate: Bool { plate.opacity > 0 }

    /// How bright the icon is: resting, under the pointer, and pressed.
    private static let resting: Float = 0.8, lit: Float = 1, pressed: Float = 0.55

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
        icon.opacity = Self.resting
        glyph.delegate = self
        glyph.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        icon.mask = glyph
        for sublayer in [plate, ring, icon] { layer?.addSublayer(sublayer) }
        widthAnchor.constraint(equalToConstant: 28).isActive = true
        heightAnchor.constraint(equalToConstant: 26).isActive = true
        contentTintColor = .white
    }

    required init?(coder: NSCoder) { fatalError("Use init(symbol:tip:)") }

    private static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    // MARK: Look

    override var contentTintColor: NSColor? {
        didSet { if contentTintColor != oldValue { showTint(animated: window != nil) } }
    }

    /// The active drawing tool: a faint accent plate stays behind it. Not `state`, which AppKit
    /// flips on every click of any button.
    var isSelected = false {
        didSet {
            guard isSelected != oldValue else { return }
            showPlate()
            light(hovering ? Self.lit : rest)
        }
    }

    /// The active tool rests fully lit; the others a little dimmed.
    private var rest: Float { isSelected ? Self.lit : Self.resting }

    override var isEnabled: Bool {
        didSet {
            if !isEnabled { hovering = false }
            light(hovering ? Self.lit : rest)
            showPlate()
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        plate.frame = bounds.insetBy(dx: 1, dy: 1)
        // The whole button, so the glyph is placed from whole points.
        icon.bounds = bounds
        icon.position = CGPoint(x: bounds.midX, y: bounds.midY)
        glyph.frame = icon.bounds
        let side = min(bounds.width, bounds.height)
        ring.frame = CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
        ring.path = CGPath(ellipseIn: ring.bounds.insetBy(dx: 2, dy: 2), transform: nil)
        CATransaction.commit()
        glyph.setNeedsDisplay()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        glyph.contentsScale = window?.backingScaleFactor ?? 2
        glyph.setNeedsDisplay()
    }

    /// The glyph is only a mask, so its color doesn't matter. Drawn through AppKit so it's upright
    /// whichever way the layer tree is flipped, and on the pixel grid so it's sharp at rest.
    nonisolated func draw(_ layer: CALayer, in context: CGContext) {
        MainActor.assumeIsolated {
            let size = symbol.size
            let centered = NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: layer.contentsAreFlipped())
            symbol.draw(in: backingAlignedRect(centered, options: .alignAllEdgesNearest), from: .zero, operation: .sourceOver,
                        fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    /// Blends the one icon from its color now to the new tint.
    private func showTint(animated: Bool) {
        let color = (contentTintColor ?? .white).cgColor
        if animated {
            let blend = CABasicAnimation(keyPath: "backgroundColor")
            blend.fromValue = icon.presentation()?.backgroundColor ?? icon.backgroundColor
            blend.toValue = color
            blend.duration = 0.22
            blend.timingFunction = CAMediaTimingFunction(name: .easeOut)
            icon.add(blend, forKey: "tint")
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        icon.backgroundColor = color
        ring.strokeColor = color
        CATransaction.commit()
    }

    /// Hover shows a plate; the selected tool keeps a faint accent one.
    private func showPlate(animated: Bool = true) {
        let color: NSColor = isSelected ? .controlAccentColor.withAlphaComponent(hovering ? 0.32 : 0.22)
            : .white.withAlphaComponent(0.14)
        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(0.15)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        } else {
            CATransaction.setDisableActions(true)
        }
        plate.backgroundColor = color.cgColor
        plate.opacity = isSelected || (hovering && isEnabled) ? 1 : 0
        CATransaction.commit()
    }

    // MARK: Light

    /// Fades the icon to `brightness` (a disabled icon stays faint whatever the pointer does).
    private func light(_ brightness: Float, duration: CFTimeInterval = 0.15, animated: Bool = true) {
        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(duration)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        } else {
            CATransaction.setDisableActions(true)
        }
        icon.opacity = isEnabled ? brightness : 0.35
        CATransaction.commit()
    }

    /// One ring rippling out in the tint, to say "this just became useful".
    func pop() {
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
        light(Self.lit)
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        showPlate()
        light(rest, duration: 0.25)
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return super.mouseDown(with: event) }
        light(Self.pressed, duration: 0.06)
        // Tracks the press until the button goes up, then acts.
        super.mouseDown(with: event)
        light(hovering ? Self.lit : rest, duration: 0.2)
    }

    // A hidden button gets no "mouse exited" (the toolbar hides while text is read, with the
    // pointer still on the button), so its look is set from where the pointer really is.
    override func viewDidHide() {
        super.viewDidHide()
        hovering = false
        settle()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        hovering = isEnabled && pointerIsInside
        settle()
    }

    private var pointerIsInside: Bool {
        guard let window else { return false }
        return bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    /// Straight to the resting look for the current state, nothing animating.
    private func settle() {
        light(hovering ? Self.lit : rest, animated: false)
        showPlate(animated: false)
    }
}
