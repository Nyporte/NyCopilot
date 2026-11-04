import AppKit
@preconcurrency import ScreenCaptureKit

/// A row of the hidden icons just under the menu bar, right-aligned under the arrow, for when they
/// shouldn't (or can't) take room in the menu bar itself. Clicking one hands it to `onPick`; Esc or
/// a click elsewhere closes the bar.
///
/// The pictures are the icons' own windows, captured where they are, off screen: ScreenCaptureKit
/// captures a window by itself wherever it is (measured on macOS 14: 4–85 ms each, drawn as in the
/// menu bar), so nothing in the menu bar moves. Without Screen Recording, each app's icon stands in.
@MainActor
final class HiddenItemsBar {
    private let panel = FloatingPanel(size: .zero, level: .statusBar, shadow: true)
    private let onPick: (ItemFinder.Item) -> Void
    private let anchor: NSRect
    private var closing = false
    /// `byArrow`: it closed because the arrow was clicked, which then mustn't open it again.
    var onClose: (_ byArrow: Bool) -> Void = { _ in }

    static let padding: CGFloat = 4

    /// `anchor` is the arrow's window, in AppKit screen coordinates; `appearance` the menu bar's,
    /// which the pictures were drawn for.
    init(items: [ItemFinder.Item], images: [CGWindowID: CGImage], anchor: NSRect, appearance: NSAppearance?,
         onPick: @escaping (ItemFinder.Item) -> Void) {
        self.onPick = onPick
        self.anchor = anchor
        let material = NSVisualEffectView.roundedMaterial(.menu, radius: 8)
        var x = Self.padding
        for item in items {
            let view = ItemView(item: item, image: images[item.window].map { NSImage(cgImage: $0, size: item.frame.size) }) { [weak self] in
                self?.pick(item)
            }
            view.frame = NSRect(origin: NSPoint(x: x, y: Self.padding), size: item.frame.size)
            material.addSubview(view)
            x += item.frame.width
        }
        let size = NSSize(width: x + Self.padding, height: (items.map(\.frame.height).max() ?? 24) + Self.padding * 2)
        material.frame = NSRect(origin: .zero, size: size)
        panel.appearance = appearance
        panel.contentView = material
        panel.setFrame(Self.frame(size: size, under: anchor, on: NSScreen.screens.first { $0.frame.intersects(anchor) }?.frame), display: false)
        panel.onCancel = { [weak self] in self?.close() }
        // A click on the arrow takes the key from the bar before the arrow acts on it (measured:
        // the bar closed and the same click opened it again).
        panel.onResignKey = { [weak self] in
            guard let self else { return }
            close(byArrow: anchor.contains(NSEvent.mouseLocation))
        }
        panel.setAccessibilityLabel(L("Hidden menu bar icons"))
    }

    /// Right-aligned under the arrow, just below the menu bar, kept on its screen.
    nonisolated static func frame(size: NSSize, under anchor: NSRect, on screen: NSRect?) -> NSRect {
        var frame = NSRect(x: anchor.maxX - size.width, y: anchor.minY - 4 - size.height, width: size.width, height: size.height)
        if let screen {
            frame.origin.x = max(screen.minX + 4, min(frame.minX, screen.maxX - 4 - size.width))
        }
        return frame
    }

    var isOpen: Bool { panel.isVisible }

    func show() { panel.present() }

    func close(byArrow: Bool = false) {
        // Ordering out a key panel resigns its key status, which comes back here.
        guard panel.isVisible, !closing else { return }
        closing = true
        panel.orderOut(nil)
        onClose(byArrow)
    }

    private func pick(_ item: ItemFinder.Item) {
        close()
        onPick(item)
    }

    /// Each item's window as it looks in the menu bar, at the screen's resolution, all at once;
    /// none without Screen Recording (never asked for here: the bar falls back to app icons).
    static func images(of items: [ItemFinder.Item], scale: CGFloat) async -> [CGWindowID: CGImage] {
        guard ScreenRecording.isGranted, !items.isEmpty else { return [:] }
        let started = Date()
        // Off-screen windows too: hidden icons are off screen.
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) else { return [:] }
        let windows = content.windows.filter { window in items.contains { $0.window == window.windowID } }
        let images = await withTaskGroup(of: (CGWindowID, CGImage?).self) { group in
            for window in windows {
                group.addTask {
                    let configuration = SCStreamConfiguration()
                    configuration.width = Int(window.frame.width * scale)
                    configuration.height = Int(window.frame.height * scale)
                    configuration.showsCursor = false
                    let image = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window),
                                                                            configuration: configuration)
                    return (window.windowID, image)
                }
            }
            var images: [CGWindowID: CGImage] = [:]
            for await (id, image) in group { images[id] = image }
            return images
        }
        Diagnostics.note("menubar", "captured \(images.count) of \(items.count) hidden icons in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
        return images
    }
}

/// One icon in the bar: its picture (or its app's icon), highlighted under the pointer as in the menu bar.
@MainActor
private final class ItemView: NSView {
    private let image: NSImage?
    private let fallback: NSImage?
    private let action: () -> Void
    private var hovered = false { didSet { needsDisplay = true } }

    init(item: ItemFinder.Item, image: NSImage?, action: @escaping () -> Void) {
        self.image = image
        fallback = image == nil ? NSRunningApplication(processIdentifier: item.pid)?.icon : nil
        self.action = action
        super.init(frame: .zero)
        toolTip = item.owner
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(item.owner)
    }

    required init?(coder: NSCoder) { fatalError("Use init(item:image:action:)") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action() }
    }
    override func rightMouseUp(with event: NSEvent) { action() }
    override func accessibilityPerformPress() -> Bool { action(); return true }

    override func draw(_ dirtyRect: NSRect) {
        if hovered {
            NSColor.labelColor.withAlphaComponent(0.15).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 1), xRadius: 4, yRadius: 4).fill()
        }
        if let image {
            image.draw(in: bounds)
        } else if let fallback {
            let side: CGFloat = 16
            fallback.draw(in: NSRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side))
        }
    }
}
