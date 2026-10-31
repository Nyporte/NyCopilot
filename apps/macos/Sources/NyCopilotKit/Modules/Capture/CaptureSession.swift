import AppKit

/// One capture across every display: a frozen overlay per screen. Whichever display the selection
/// starts on owns it; the others stay dimmed until the capture ends.
@MainActor
final class CaptureSession {
    /// The chosen action with the rendered image and the selection in global top-left coordinates.
    var onFinish: ((CaptureAction, NSImage, CGRect, NSScreen) -> Void)?
    /// S: the selection (global top-left) and the frozen screen it's on, for a scrolling capture.
    var onScroll: ((CGRect, FrozenScreen) -> Void)?
    /// G: record the selection as a GIF, live.
    var onRecord: ((CGRect, NSScreen) -> Void)?
    /// Live Text's Copy All put this many lines on the clipboard.
    var onTextCopied: ((Int, CGRect, NSScreen) -> Void)?
    var onCancel: (() -> Void)?

    private var windows: [CaptureWindow] = []
    private var views: [CaptureView] = []

    init(frozen: [FrozenScreen], recent: [CGRect], palette: [NSColor], color: NSColor, stroke: CGFloat, style: CaptureStyle,
         onStyleChange: @escaping (NSColor, CGFloat, CaptureStyle) -> Void) {
        // Each capture starts by outlining windows; Tab switches to elements.
        CaptureView.detectsWindows = true
        for screen in frozen {
            let origin = Self.globalOrigin(of: screen.screen)
            let local = recent.map { $0.offsetBy(dx: -origin.x, dy: -origin.y) }
                .filter { CGRect(origin: .zero, size: screen.screen.frame.size).contains($0) }
            let view = CaptureView(frozen: screen, recent: local, palette: palette, color: color, stroke: stroke,
                                   style: style, onStyleChange: onStyleChange)
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
                guard let self, let view, let selection = view.selection else { return }
                let global = selection.offsetBy(dx: origin.x, dy: origin.y)
                // A scrolling capture starts from the screen as it was; annotations don't scroll with it.
                if action == .scroll {
                    close()
                    onScroll?(global, screen)
                    return
                }
                if action == .record {
                    close()
                    onRecord?(global, screen.screen)
                    return
                }
                guard let image = view.renderedImage() else { return }
                close()
                onFinish?(action, image, global, screen.screen)
            }
            view.onTextCopied = { [weak self, weak view] lines in
                guard let self, let selection = view?.selection else { return }
                close()
                onTextCopied?(lines, selection.offsetBy(dx: origin.x, dy: origin.y), screen.screen)
            }
            view.onCancel = { [weak self] in
                self?.close()
                self?.onCancel?()
            }
            view.onSelectionStarted = { [weak self, weak view] in
                for other in self?.views ?? [] where other !== view { other.isPassive = true }
                view?.isPassive = false
            }
            windows.append(window)
            views.append(view)
        }
    }

    /// The outline under the pointer is found before anything shows, so the first frame has both
    /// the dimming and the outline — not a gray screen that then brightens where the outline lands.
    func show() {
        let mouse = NSEvent.mouseLocation
        let pointed = zip(windows, views).first { window, _ in window.frame.contains(mouse) }
        pointed?.1.hoverAtPointer()
        for window in windows { window.orderFrontRegardless() }
        // Key without activating NyCopilot: the app you were in keeps its focus, so nothing under the
        // frozen screen changes (an inactive window's gray buttons, dimmed selections).
        if let (window, view) = pointed {
            window.makeKey()
            window.makeFirstResponder(view)
        }
        // Without the background cursor (a future macOS), activate so the crosshair still shows.
        if !BackgroundCursor.allow() { NSApp.bringForward() }
        NSCursor.crosshair.set()
    }

    func close() {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        views.removeAll()
        NSCursor.arrow.set()
    }

    /// A screen's top-left corner in global top-left coordinates (see ScreenGeometry).
    static func globalOrigin(of screen: NSScreen) -> CGPoint { ScreenGeometry.topLeftOrigin(of: screen) }

    /// Global top-left coordinates → AppKit screen coordinates (see ScreenGeometry).
    static func appKitRect(_ rect: CGRect) -> NSRect { ScreenGeometry.appKit(rect) }
}
