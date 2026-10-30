import AppKit
import VisionKit

/// An image floating above every window. Drag to move, scroll to zoom, ⌥-scroll to fade, 1–4 to rotate
/// and flip, T to select its text in place, ⌘C to copy, ⌘S to save, Esc or a double-click to close. Right-click for
/// everything else.
@MainActor
final class PinWindow: NSPanel {
    var onSave: ((NSImage) -> Void)?
    var onClose: ((PinWindow) -> Void)?
    var onCloseAll: (() -> Void)?
    /// Clicked: the board unfocuses every other pin.
    var onFocus: ((PinWindow) -> Void)?

    /// Shows the accent border. Pins never activate NyCopilot, so macOS doesn't tell them when a
    /// click lands in another app; the board clears this instead.
    var isFocused = false { didSet { if isFocused != oldValue { pinView.showsFocus = isFocused } } }

    let original: NSImage
    private let pinView: PinView
    private(set) var zoom: CGFloat = 1
    private var quarterTurns = 0
    private var flippedHorizontally = false
    private var flippedVertically = false
    private(set) var isClickThrough = false

    init(image: NSImage, frame: NSRect, shadow: Bool) {
        original = image
        pinView = PinView(frame: CGRect(origin: .zero, size: frame.size))
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = shadow
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        pinView.pin = self
        contentView = pinView
        redraw()
    }

    override var canBecomeKey: Bool { true }

    override func resignKey() {
        super.resignKey()
        isFocused = false
    }

    /// The pixels as currently shown — rotated and flipped — rendered once per change. Zooming only
    /// resizes the layer that shows them, so the GPU scales the bitmap and nothing is redrawn.
    private var rendered: CGImage?

    private var pointSize: NSSize {
        quarterTurns % 2 == 1 ? NSSize(width: original.size.height, height: original.size.width) : original.size
    }

    /// The image as currently shown, for copying and saving.
    var displayedImage: NSImage {
        rendered.map { NSImage(cgImage: $0, size: pointSize) } ?? original
    }

    private func redraw() {
        guard let source = original.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let turned = quarterTurns % 2 == 1
        let width = turned ? source.height : source.width, height = turned ? source.width : source.height
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.interpolationQuality = .high
        context.translateBy(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
        context.rotate(by: -CGFloat(quarterTurns) * .pi / 2)
        context.scaleBy(x: flippedHorizontally ? -1 : 1, y: flippedVertically ? -1 : 1)
        context.draw(source, in: CGRect(x: -CGFloat(source.width) / 2, y: -CGFloat(source.height) / 2,
                                        width: CGFloat(source.width), height: CGFloat(source.height)))
        rendered = context.makeImage()
        pinView.show(rendered)
    }

    /// Scale around a fixed point on screen (the pointer), within 10–800%.
    func setZoom(_ value: CGFloat, around anchor: NSPoint? = nil) {
        let clamped = min(max(value, 0.1), 8)
        let base = pointSize
        let size = NSSize(width: max(base.width * clamped, 16), height: max(base.height * clamped, 16))
        let pivot = anchor ?? NSPoint(x: frame.midX, y: frame.midY)
        let fx = (pivot.x - frame.minX) / frame.width, fy = (pivot.y - frame.minY) / frame.height
        // No implicit layer animation and no synchronous redraw: the layer simply rescales.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        setFrame(NSRect(x: pivot.x - fx * size.width, y: pivot.y - fy * size.height, width: size.width, height: size.height), display: false)
        CATransaction.commit()
        zoom = clamped
        pinView.flash("\(Int(round(clamped * 100)))%")
    }

    func setOpacity(_ value: CGFloat) {
        alphaValue = min(max(value, 0.1), 1)
        pinView.flash("Opacity \(Int(round(alphaValue * 100)))%")
    }

    /// T: the pin's text becomes selectable where it is (Live Text); T again copies all of it, Esc goes back.
    func toggleReadingText() { pinView.toggleReadingText(rendered) }

    func rotate(clockwise: Bool) {
        pinView.endReadingText()
        quarterTurns = (quarterTurns + (clockwise ? 1 : 3)) % 4
        redraw()
        setZoom(zoom)
    }

    func flip(horizontally: Bool) {
        pinView.endReadingText()
        if horizontally { flippedHorizontally.toggle() } else { flippedVertically.toggle() }
        redraw()
    }

    func copyImage() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([displayedImage])
        pinView.flash("Copied")
    }

    func setClickThrough(_ on: Bool) {
        isClickThrough = on
        ignoresMouseEvents = on
    }

    override func close() {
        super.close()
        onClose?(self)
    }

    // MARK: Menu

    func menu() -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector, key: String = "", state: Bool = false) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self
            item.state = state ? .on : .off
            menu.addItem(item)
        }
        add("Copy", #selector(copyFromMenu), key: "c")
        add("Save…", #selector(saveFromMenu), key: "s")
        add("Select Text", #selector(selectTextFromMenu), key: "t", state: pinView.isReadingText)
        menu.addItem(.separator())
        add("Actual Size", #selector(actualSize), key: "0")
        let opacity = NSMenuItem(title: "Opacity", action: nil, keyEquivalent: "")
        let levels = NSMenu()
        for level in [100, 80, 60, 40, 20] {
            let item = NSMenuItem(title: "\(level)%", action: #selector(pickOpacity(_:)), keyEquivalent: "")
            item.target = self
            item.tag = level
            item.state = Int(round(alphaValue * 100)) == level ? .on : .off
            levels.addItem(item)
        }
        opacity.submenu = levels
        menu.addItem(opacity)
        add("Rotate Left", #selector(rotateLeft), key: "1")
        add("Rotate Right", #selector(rotateRight), key: "2")
        add("Flip Horizontal", #selector(flipH), key: "3")
        add("Flip Vertical", #selector(flipV), key: "4")
        add("Shadow", #selector(toggleShadow), state: hasShadow)
        add("Click Through", #selector(toggleClickThrough))
        menu.addItem(.separator())
        add("Close", #selector(closeFromMenu))
        add("Close All Pins", #selector(closeAllFromMenu))
        // Digits and T work on their own; copy and save take ⌘.
        for item in menu.items where !item.keyEquivalent.isEmpty {
            item.keyEquivalentModifierMask = item.keyEquivalent.first!.isNumber || item.keyEquivalent == "t" ? [] : [.command]
        }
        return menu
    }

    @objc private func copyFromMenu() { copyImage() }
    @objc private func saveFromMenu() { onSave?(displayedImage) }
    @objc private func selectTextFromMenu() { toggleReadingText() }
    @objc private func actualSize() { setZoom(1) }
    @objc private func pickOpacity(_ sender: NSMenuItem) { setOpacity(CGFloat(sender.tag) / 100) }
    @objc private func rotateLeft() { rotate(clockwise: false) }
    @objc private func rotateRight() { rotate(clockwise: true) }
    @objc private func flipH() { flip(horizontally: true) }
    @objc private func flipV() { flip(horizontally: false) }
    @objc private func toggleShadow() { hasShadow.toggle(); invalidateShadow() }
    @objc private func toggleClickThrough() { setClickThrough(true) }
    @objc private func closeFromMenu() { close() }
    @objc private func closeAllFromMenu() { onCloseAll?() }
}

/// Shows the pin and turns gestures into pin actions. The pixels live in a layer that the GPU scales,
/// so zooming never redraws them.
private final class PinView: NSView {
    weak var pin: PinWindow?
    private let imageLayer = CALayer()
    private let badge = Design.label("", size: 12, weight: .semibold, color: .white)
    private var hideBadge: DispatchWorkItem?

    /// The accent border fades in faintly while the pointer is over the pin and turns solid once the
    /// pin is selected.
    private let borderLayer = CALayer()
    var showsFocus = false { didSet { if showsFocus != oldValue { updateBorder() } } }
    private var isHovered = false { didSet { if isHovered != oldValue { updateBorder() } } }

    private func updateBorder() {
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
    private var hint: String? {
        didSet {
            guard let hint else { badge.alphaValue = 0; return }
            hideBadge?.cancel()
            badge.stringValue = "  \(hint)  "
            badge.alphaValue = 1
        }
    }

    // MARK: Live Text

    private var textOverlay: ImageAnalysisOverlayView?
    private var copyWhenRead = false
    var isReadingText: Bool { textOverlay != nil }

    func toggleReadingText(_ image: CGImage?) {
        if isReadingText { endReadingText(); return }
        guard let image else { return }
        let overlay = LiveText.overlay(frame: bounds)
        overlay.autoresizingMask = [.width, .height]
        addSubview(overlay, positioned: .below, relativeTo: badge)
        textOverlay = overlay
        hint = "Reading text…"
        Task { [weak self] in
            let analysis = try? await LiveText.analyze(image)
            guard let self, textOverlay === overlay else { return }
            LiveText.show(analysis, on: overlay)
            if analysis.map(LiveText.lineCount) ?? 0 > 0 {
                hint = "Drag to select · ⌘C copy · T copy all · Esc done"
                if copyWhenRead { copyAllText() }
            } else {
                endReadingText()
                flash("No text found")
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
    private func copyAllText() {
        guard let analysis = textOverlay?.analysis else { copyWhenRead = true; return }
        guard !analysis.transcript.isEmpty else { return }
        LiveText.copy(analysis.transcript)
        endReadingText()
        flash("Copied all text")
    }

    /// Keys while reading text; the overlay passes along whatever it doesn't use itself.
    private func readingTextKeyDown(_ event: NSEvent) -> Bool {
        guard let overlay = textOverlay else { return false }
        let command = event.modifierFlags.contains(.command)
        switch (event.keyCode, event.charactersIgnoringModifiers?.lowercased() ?? "", command) {
        case (53, _, _): endReadingText()
        case (_, "t", false), (36, _, _), (76, _, _): copyAllText()
        case (_, "c", true):
            let text = LiveText.textToCopy(from: overlay)
            guard !text.isEmpty else { break }
            LiveText.copy(text)
            flash("Copied")
        default: return false
        }
        return true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { pin?.close(); return }
        focus()
        window?.performDrag(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let pin else { return }
        focus()
        NSMenu.popUpContextMenu(pin.menu(), with: event, for: self)
    }

    private func focus() {
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
        let command = event.modifierFlags.contains(.command)
        switch (event.charactersIgnoringModifiers?.lowercased() ?? "", command) {
        case ("c", true): pin.copyImage()
        case ("s", true): pin.onSave?(pin.displayedImage)
        case ("w", true): pin.close()
        case ("t", false): pin.toggleReadingText()
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

/// Every open pin: create, hide and show together, close together, restore clicks.
@MainActor
final class PinBoard {
    var onSave: ((NSImage) -> Void)?
    private(set) var pins: [PinWindow] = []
    private(set) var areHidden = false
    /// Clicks in other apps, which unfocus every pin; installed only while pins exist.
    private var outsideClicks: Any?

    @discardableResult
    func pin(_ image: NSImage, at frame: NSRect, shadow: Bool) -> PinWindow {
        let pin = PinWindow(image: image, frame: frame, shadow: shadow)
        pin.onSave = { [weak self] image in self?.onSave?(image) }
        pin.onClose = { [weak self] closed in
            self?.pins.removeAll { $0 === closed }
            self?.updateMonitor()
        }
        pin.onCloseAll = { [weak self] in self?.closeAll() }
        pin.onFocus = { [weak self] focused in
            for other in self?.pins ?? [] where other !== focused { other.isFocused = false }
        }
        pins.append(pin)
        updateMonitor()
        if areHidden { showAll() }
        pin.orderFrontRegardless()
        return pin
    }

    func toggleVisibility() { areHidden ? showAll() : hideAll() }

    private func hideAll() {
        pins.forEach { $0.orderOut(nil) }
        areHidden = true
    }

    private func showAll() {
        pins.forEach { $0.orderFrontRegardless() }
        areHidden = false
    }

    func closeAll() { pins.forEach { $0.close() } }

    var hasClickThrough: Bool { pins.contains { $0.isClickThrough } }

    private func updateMonitor() {
        if pins.isEmpty, let monitor = outsideClicks {
            NSEvent.removeMonitor(monitor)
            outsideClicks = nil
        } else if !pins.isEmpty, outsideClicks == nil {
            outsideClicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated { self?.unfocusAll() }
            }
        }
    }

    func unfocusAll() { pins.forEach { $0.isFocused = false } }

    func makeAllClickable() { pins.forEach { $0.setClickThrough(false) } }
}
