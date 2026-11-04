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
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for info in list {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != own,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = (info[kCGWindowBounds as String] as? [String: CGFloat]).flatMap({ CGRect(dictionaryRepresentation: $0 as CFDictionary) }),
                  bounds.contains(point) else { continue }
            return (bounds, pid)
        }
        return nil
    }

    /// The nearest scroll area enclosing the element at `point` in that app.
    private static func scrollView(at point: CGPoint, in pid: pid_t) -> CGRect? {
        let app = AXUIElementCreateApplication(pid)
        // An app that doesn't answer quickly shouldn't hold up a capture.
        AXUIElementSetMessagingTimeout(app, 0.25)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hit) == .success, var element = hit else { return nil }
        for _ in 0..<40 {
            // Each element answers with its own timeout, not the app's.
            AXUIElementSetMessagingTimeout(element, 0.25)
            if string(element, kAXRoleAttribute) == kAXScrollAreaRole as String, let frame = frame(of: element), frame.height >= 40 {
                return frame
            }
            guard let parent = value(element, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() else { return nil }
            element = parent as! AXUIElement
        }
        return nil
    }

    private static func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private static func string(_ element: AXUIElement, _ name: String) -> String? { value(element, name) as? String }

    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let position = value(element, kAXPositionAttribute), let size = value(element, kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin), AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: origin, size: extent)
    }
}
