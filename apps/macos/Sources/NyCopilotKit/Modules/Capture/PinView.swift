import AppKit
@preconcurrency import VisionKit

/// Shows the pin and turns gestures into pin actions. The pixels live in a layer that the GPU scales,
/// so zooming never redraws them.
final class PinView: NSView {
    weak var pin: PinWindow?
    let imageLayer = CALayer()
    let badge = Design.label("", size: 12, weight: .semibold, color: .white)
    var hideBadge: DispatchWorkItem?

    /// The accent border fades in faintly while the pointer is over the pin and turns solid once the
    /// pin is selected.
    let borderLayer = CALayer()
    var showsFocus = false { didSet { if showsFocus != oldValue { updateBorder() } } }
    var isHovered = false { didSet { if isHovered != oldValue { updateBorder() } } }

    func updateBorder() {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.18)
        borderLayer.opacity = showsFocus ? 0.85 : isHovered ? 0.3 : 0
        CATransaction.commit()
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        autoresizingMask = [.width, .height]
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        imageLayer.frame = bounds
        imageLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        imageLayer.contentsGravity = .resize
        imageLayer.minificationFilter = .trilinear
        imageLayer.magnificationFilter = .linear
        imageLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(imageLayer)
        borderLayer.frame = bounds
        borderLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        borderLayer.borderWidth = 1
        borderLayer.borderColor = NSColor.controlAccentColor.cgColor
        borderLayer.opacity = 0
        // Only opacity animates; the border follows zooming exactly.
        borderLayer.actions = ["bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(borderLayer)
        // Pins float over other apps, so track the pointer even while NyCopilot isn't active.
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
        badge.wantsLayer = true
        badge.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        badge.layer?.cornerRadius = 5
        badge.alphaValue = 0
        badge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(badge)
        NSLayoutConstraint.activate([
            badge.centerXAnchor.constraint(equalTo: centerXAnchor),
            badge.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8)
        ])
    }

    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

    func show(_ image: CGImage?) {
        imageLayer.contentsScale = window?.backingScaleFactor ?? 2
        imageLayer.contents = image
    }

    /// A short-lived label for zoom, opacity, and copy feedback; afterwards the hint, if any, returns.
    func flash(_ text: String) {
        badge.stringValue = "  \(text)  "
        hideBadge?.cancel()
        badge.alphaValue = 1
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if let hint { badge.stringValue = "  \(hint)  "; return }
            NSAnimationContext.runAnimationGroup { $0.duration = 0.3; self.badge.animator().alphaValue = 0 }
        }
        hideBadge = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: work)
    }

    /// Stays on the badge while set.
    var hint: String? {
        didSet {
            guard let hint else { badge.alphaValue = 0; return }
            hideBadge?.cancel()
            badge.stringValue = "  \(hint)  "
            badge.alphaValue = 1
        }
    }

    // MARK: Live Text

    var textOverlay: ImageAnalysisOverlayView?
    var copyWhenRead = false
    var isReadingText: Bool { textOverlay != nil }

    func toggleReadingText(_ image: CGImage?) {
        if isReadingText { endReadingText(); return }
        guard let image else { return }
        let overlay = LiveText.overlay(frame: bounds)
        overlay.autoresizingMask = [.width, .height]
        addSubview(overlay, positioned: .below, relativeTo: badge)
        textOverlay = overlay
        hint = L("Reading text…")
        Task { [weak self] in
            let analysis = try? await LiveText.analyze(image)
            guard let self, textOverlay === overlay else { return }
            LiveText.show(analysis, on: overlay)
            if analysis.map(LiveText.lineCount) ?? 0 > 0 {
                hint = L("Drag to select · ⌘C copy · T copy all · Esc done")
                if copyWhenRead { copyAllText() }
            } else {
                endReadingText()
                flash(L("No text found"))
            }
        }
    }

    func endReadingText() {
        guard let overlay = textOverlay else { return }
        overlay.removeFromSuperview()
        textOverlay = nil
        copyWhenRead = false
        hint = nil
        window?.makeFirstResponder(self)
    }

    /// T twice or Return: every line, then back to the plain pin. A double tap faster than
    /// recognition copies as soon as the text is read.
    func copyAllText() {
        guard let analysis = textOverlay?.analysis else { copyWhenRead = true; return }
        guard !analysis.transcript.isEmpty else { return }
        LiveText.copy(analysis.transcript)
        endReadingText()
        flash(L("Copied all text"))
    }

    /// Keys while reading text; the overlay passes along whatever it doesn't use itself.
    func readingTextKeyDown(_ event: NSEvent) -> Bool {
        guard let overlay = textOverlay else { return false }
        let command = event.modifierFlags.contains(.command)
        switch (event.keyCode, event.charactersIgnoringModifiers?.lowercased() ?? "", command) {
        case (53, _, _): endReadingText()
        case (_, "t", false), (36, _, _), (76, _, _): copyAllText()
        case (_, "c", true):
            let text = LiveText.textToCopy(from: overlay)
            guard !text.isEmpty else { break }
            LiveText.copy(text)
            flash(L("Copied"))
        default: return false
        }
        return true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    /// The pointer and the pin's origin when a drag began, in screen coordinates.
    var dragStart: (pointer: NSPoint, origin: NSPoint)?

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { pin?.close(); return }
        focus()
        // Dragged by hand rather than by the system, which won't take a window's top past the menu bar.
        guard let window else { return }
        dragStart = (window.convertPoint(toScreen: event.locationInWindow), window.frame.origin)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, let start = dragStart else { return }
        let pointer = window.convertPoint(toScreen: event.locationInWindow)
        window.setFrameOrigin(NSPoint(x: start.origin.x + pointer.x - start.pointer.x, y: start.origin.y + pointer.y - start.pointer.y))
    }

    override func mouseUp(with event: NSEvent) { dragStart = nil }

    override func rightMouseDown(with event: NSEvent) {
        guard let pin else { return }
        focus()
        NSMenu.popUpContextMenu(pin.menu(), with: event, for: self)
    }

    func focus() {
        guard let pin else { return }
        pin.makeKey()
        pin.isFocused = true
        pin.onFocus?(pin)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let pin else { return }
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 120 : event.scrollingDeltaY / 12
        if event.modifierFlags.contains(.option) { pin.setOpacity(pin.alphaValue + delta) }
        else { pin.setZoom(pin.zoom * (1 + delta), around: NSEvent.mouseLocation) }
    }

    override func keyDown(with event: NSEvent) {
        guard let pin else { return }
        if readingTextKeyDown(event) { return }
        if event.characters == "?" { KeySheet.shared.toggle(L("Pin keys"), groups: KeyGuide.pin, over: pin); return }
        let command = event.modifierFlags.contains(.command)
        switch (event.charactersIgnoringModifiers?.lowercased() ?? "", command) {
        case ("c", true): pin.copyImage()
        case ("s", true): pin.onSave?(pin.displayedImage)
        case ("w", true): pin.close()
        case ("t", false): pin.toggleReadingText()
        case ("r", false): pin.onVerb?(.translate, pin)
        case ("i", false): pin.onVerb?(.inbox, pin)
        case ("a", false): pin.onVerb?(.ask, pin)
        case ("0", _): pin.setZoom(1)
        case ("1", false): pin.rotate(clockwise: false)
        case ("2", false): pin.rotate(clockwise: true)
        case ("3", false): pin.flip(horizontally: true)
        case ("4", false): pin.flip(horizontally: false)
        case ("=", _), ("+", _): pin.setZoom(pin.zoom * 1.1)
        case ("-", _): pin.setZoom(pin.zoom / 1.1)
        default:
            if event.keyCode == 53 { pin.close() } else { super.keyDown(with: event) }
        }
    }
}
