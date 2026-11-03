import AppKit
import ApplicationServices

/// The scrollable area around a rectangle on screen: the scroll view under it, found through
/// Accessibility, or else the window under it. Scrolling capture watches this whole area, so content
/// that moves too far for the selection alone is still seen. Global top-left coordinates.
enum ScrollArea {
    /// Never nil: without a window or a scroll view, the rectangle itself.
    static func around(_ rect: CGRect) -> CGRect {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        guard let window = window(at: center) else { return rect }
        guard Accessibility.isTrusted, let view = scrollView(at: center, in: window.pid) else { return window.bounds }
        // Some apps report a scroll view taller than its window (the whole document); keep what's on screen.
        let visible = view.intersection(window.bounds)
        return visible.isEmpty ? window.bounds : visible
    }

    /// The frontmost normal window at `point` that isn't NyCopilot's.
    private static func window(at point: CGPoint) -> (bounds: CGRect, pid: pid_t)? {
        let own = ProcessInfo.processInfo.processIdentifier
        return ScreenGrabber.windowList().first { $0.pid != own && $0.layer == 0 && $0.bounds.contains(point) }
            .map { ($0.bounds, $0.pid) }
    }

    /// The nearest scroll area enclosing the element at `point` in that app.
    private static func scrollView(at point: CGPoint, in pid: pid_t) -> CGRect? {
        // An app that doesn't answer quickly shouldn't hold up a capture.
        let app = AX.application(pid, timeout: 0.25)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hit) == .success, var element = hit else { return nil }
        for _ in 0..<40 {
            // Each element answers with its own timeout, not the app's.
            AX.setTimeout(element, 0.25)
            if AX.string(element, kAXRoleAttribute) == kAXScrollAreaRole as String, let frame = AX.frame(of: element), frame.height >= 40 {
                return frame
            }
            guard let parent = AX.parent(of: element) else { return nil }
            element = parent
        }
        return nil
    }
}
