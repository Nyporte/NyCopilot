import AppKit

/// The two ways macOS measures the screen, in one place. Accessibility, ScreenCaptureKit, and window
/// lists use global coordinates with the origin at the top-left of the primary display and y growing
/// down; AppKit puts the origin at its bottom-left with y growing up. Converting by hand in each
/// module is how a rectangle ends up on the wrong display, so everything converts through here.
enum ScreenGeometry {
    /// The primary display's height: the line both systems mirror around.
    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.maxY ?? 0 }

    /// Top-left global → AppKit. (The conversion is its own inverse.)
    static func appKit(_ rect: CGRect) -> NSRect {
        NSRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// AppKit → top-left global.
    static func topLeft(_ rect: NSRect) -> CGRect { appKit(rect) }

    static func topLeft(_ point: NSPoint) -> CGPoint { CGPoint(x: point.x, y: primaryHeight - point.y) }

    /// A display's top-left corner in top-left global coordinates.
    static func topLeftOrigin(of screen: NSScreen) -> CGPoint {
        CGPoint(x: screen.frame.minX, y: primaryHeight - screen.frame.maxY)
    }

    /// A display's frame in top-left global coordinates.
    static func topLeftFrame(of screen: NSScreen) -> CGRect { topLeft(screen.frame) }

    /// The display with the pointer (or with `point`, in AppKit coordinates).
    static func screen(at point: NSPoint = NSEvent.mouseLocation) -> NSScreen {
        NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
    }
}
