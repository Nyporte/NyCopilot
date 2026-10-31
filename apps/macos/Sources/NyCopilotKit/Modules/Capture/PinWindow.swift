import AppKit
@preconcurrency import VisionKit

/// An image floating above every window. Drag to move, scroll to zoom, ⌥-scroll to fade, 1–4 to rotate
/// and flip, T to select its text in place, ⌘C to copy, ⌘S to save, Esc or a double-click to close. Right-click for
/// everything else.
@MainActor
final class PinWindow: NSPanel {
    var onSave: ((NSImage) -> Void)?
    /// R, I, A, or P on the pin: translate its text, keep it in the inbox, ask about it, pin a copy.
    var onVerb: ((Verb, PinWindow) -> Void)?
    var onClose: ((PinWindow) -> Void)?
    var onCloseAll: (() -> Void)?
    /// Clicked: the board unfocuses every other pin.
    var onFocus: ((PinWindow) -> Void)?

    /// Shows the accent border. Pins never activate NyCopilot, so macOS doesn't tell them when a
    /// click lands in another app; the board clears this instead.
    var isFocused = false { didSet { if isFocused != oldValue { pinView.showsFocus = isFocused } } }

    let original: NSImage
    let pinView: PinView
    var zoom: CGFloat = 1
    var quarterTurns = 0
    var flippedHorizontally = false
    var flippedVertically = false
    var isClickThrough = false

    /// Names the pin's files while it's kept between launches.
    let id: UUID

    init(image: NSImage, frame: NSRect, shadow: Bool, id: UUID = UUID()) {
        self.id = id
        original = image
        pinView = PinView(frame: CGRect(origin: .zero, size: frame.size))
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        float(at: .floating, shadow: shadow)
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
    var rendered: CGImage?

    var pointSize: NSSize {
        quarterTurns % 2 == 1 ? NSSize(width: original.size.height, height: original.size.width) : original.size
    }

    /// The image as currently shown, for copying and saving.
    var displayedImage: NSImage {
        rendered.map { NSImage(cgImage: $0, size: pointSize) } ?? original
    }

    func redraw() {
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
    func setZoom(_ value: CGFloat, around anchor: NSPoint? = nil, announce: Bool = true) {
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
        if announce { pinView.flash("\(Int(round(clamped * 100)))%") }
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

    /// How the pin looks and where it is, kept between launches.
    struct State: Codable {
        var x, y, zoom, opacity: CGFloat
        var width, height: CGFloat
        var quarterTurns: Int
        var flippedHorizontally, flippedVertically, shadow: Bool
    }

    var state: State {
        State(x: frame.minX, y: frame.maxY, zoom: zoom, opacity: alphaValue, width: original.size.width, height: original.size.height,
              quarterTurns: quarterTurns, flippedHorizontally: flippedHorizontally, flippedVertically: flippedVertically, shadow: hasShadow)
    }

    /// Back as it was: turned, flipped, zoomed, and with its top-left corner where it was.
    func apply(_ state: State) {
        quarterTurns = state.quarterTurns % 4
        flippedHorizontally = state.flippedHorizontally
        flippedVertically = state.flippedVertically
        alphaValue = min(max(state.opacity, 0.1), 1)
        redraw()
        setZoom(state.zoom, announce: false)
        setFrameTopLeftPoint(NSPoint(x: state.x, y: state.y))
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

    @objc func copyFromMenu() { copyImage() }
    @objc func saveFromMenu() { onSave?(displayedImage) }
    @objc func selectTextFromMenu() { toggleReadingText() }
    @objc func actualSize() { setZoom(1) }
    @objc func pickOpacity(_ sender: NSMenuItem) { setOpacity(CGFloat(sender.tag) / 100) }
    @objc func rotateLeft() { rotate(clockwise: false) }
    @objc func rotateRight() { rotate(clockwise: true) }
    @objc func flipH() { flip(horizontally: true) }
    @objc func flipV() { flip(horizontally: false) }
    @objc func toggleShadow() { hasShadow.toggle(); invalidateShadow() }
    @objc func toggleClickThrough() { setClickThrough(true) }
    @objc func closeFromMenu() { close() }
    @objc func closeAllFromMenu() { onCloseAll?() }
}
