import AppKit

/// One capture across every display: a frozen overlay per screen. Whichever display the selection
/// starts on owns it; the others stay dimmed until the capture ends.
@MainActor
final class CaptureSession {
    /// The chosen action with the rendered image and the selection in global top-left coordinates.
    var onFinish: ((CaptureAction, NSImage, CGRect, NSScreen) -> Void)?
    var onCancel: (() -> Void)?
    var onColorCopied: ((String) -> Void)?

    private var windows: [CaptureWindow] = []
    private var views: [CaptureView] = []

    init(frozen: [FrozenScreen], recent: [CGRect], palette: [NSColor], color: NSColor, stroke: CGFloat,
         onStyleChange: @escaping (NSColor, CGFloat) -> Void) {
        for screen in frozen {
            let origin = Self.globalOrigin(of: screen.screen)
            let local = recent.map { $0.offsetBy(dx: -origin.x, dy: -origin.y) }
                .filter { CGRect(origin: .zero, size: screen.screen.frame.size).contains($0) }
            let view = CaptureView(frozen: screen, recent: local, palette: palette, color: color, stroke: stroke,
                                   onStyleChange: onStyleChange)
            let window = CaptureWindow(screen: screen.screen)
            let container = NSView(frame: CGRect(origin: .zero, size: screen.screen.frame.size))
            // The frozen pixels sit in a layer of their own; the capture view only draws what changes.
            container.wantsLayer = true
            container.layer?.contents = screen.image
            container.layer?.contentsGravity = .resize
            view.frame = container.bounds
            view.autoresizingMask = [.width, .height]
            container.addSubview(view)
            window.contentView = container
            view.onFinish = { [weak self, weak view] action in
                guard let self, let view, let image = view.renderedImage(), let selection = view.selection else { return }
                let global = selection.offsetBy(dx: origin.x, dy: origin.y)
                close()
                onFinish?(action, image, global, screen.screen)
            }
            view.onCancel = { [weak self] in
                self?.close()
                self?.onCancel?()
            }
            view.onColorCopied = { [weak self] hex in
                self?.close()
                self?.onColorCopied?(hex)
            }
            view.onSelectionStarted = { [weak self, weak view] in
                for other in self?.views ?? [] where other !== view { other.isPassive = true }
                view?.isPassive = false
            }
            windows.append(window)
            views.append(view)
        }
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        let mouse = NSEvent.mouseLocation
        for (window, view) in zip(windows, views) {
            window.orderFrontRegardless()
            if window.frame.contains(mouse) {
                window.makeKey()
                window.makeFirstResponder(view)
            }
        }
        NSCursor.crosshair.set()
    }

    func close() {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        views.removeAll()
        NSCursor.arrow.set()
    }

    /// A screen's top-left corner in global top-left coordinates (the primary display's top is 0).
    static func globalOrigin(of screen: NSScreen) -> CGPoint {
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        return CGPoint(x: screen.frame.minX, y: primaryHeight - screen.frame.maxY)
    }

    /// Global top-left coordinates → AppKit screen coordinates (bottom-left origin).
    static func appKitRect(_ rect: CGRect) -> NSRect {
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        return NSRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }
}
