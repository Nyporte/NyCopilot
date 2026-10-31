import AppKit
import ApplicationServices

/// A rectangle in Accessibility coordinates: top-left origin of the primary display, y down.
/// This is the shape the core's `windows` module speaks.
struct WindowRect: Codable, Equatable {
    var x: Double
    var y: Double
    var w: Double
    var h: Double

    var json: [String: Double] { ["x": x, "y": y, "w": w, "h": h] }

    func isClose(to other: WindowRect, tolerance: Double = 2) -> Bool {
        abs(x - other.x) <= tolerance && abs(y - other.y) <= tolerance
            && abs(w - other.w) <= tolerance && abs(h - other.h) <= tolerance
    }

    func contains(_ point: CGPoint) -> Bool { point.x >= x && point.x < x + w && point.y >= y && point.y < y + h }
}

/// One display: its whole frame (for hit-testing the pointer) and its usable area (without the
/// menu bar and Dock), both in Accessibility coordinates.
struct Display {
    let frame: WindowRect
    let visible: WindowRect
}

/// Reads and moves other apps' windows through Accessibility. Never touches NyCopilot's own windows.
enum WindowControl {
    /// The focused window of the frontmost app, if it is a normal window that can be moved.
    static func focusedWindow() -> AXUIElement? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.3)
        guard let window = elementAttribute(element, kAXFocusedWindowAttribute) else { return nil }
        return isMovable(window) ? window : nil
    }

    /// The window under a point (Accessibility coordinates), for drag snapping.
    static func window(at point: CGPoint) -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.15)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &hit) == .success,
              let hit else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(hit, &pid) == .success, pid != ProcessInfo.processInfo.processIdentifier else { return nil }
        AXUIElementSetMessagingTimeout(hit, 0.15)
        let window = (attribute(hit, kAXRoleAttribute) as? String) == kAXWindowRole ? hit : elementAttribute(hit, kAXWindowAttribute)
        guard let window, isMovable(window) else { return nil }
        return window
    }

    static func frame(of window: AXUIElement) -> WindowRect? {
        var position = CGPoint.zero
        var size = CGSize.zero
        guard read(window, kAXPositionAttribute, .cgPoint, into: &position),
              read(window, kAXSizeAttribute, .cgSize, into: &size) else { return nil }
        return WindowRect(x: position.x, y: position.y, w: size.width, h: size.height)
    }

    /// Move and resize, then return where the window actually ended up. Apps with a minimum size
    /// can refuse a frame; the result is nudged back inside `bounds` so it never hangs off-screen.
    @discardableResult
    static func setFrame(_ target: WindowRect, of window: AXUIElement, within bounds: WindowRect) -> WindowRect? {
        var pid: pid_t = 0
        AXUIElementGetPid(window, &pid)
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        // Some apps animate every Accessibility move while this is on; switch it off for the move.
        let enhanced = attribute(app, "AXEnhancedUserInterface") as? Bool == true
        if enhanced { AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse) }
        defer { if enhanced { AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue) } }

        // Size first so the move isn't blocked by the old size, then again in case the move changed limits.
        write(window, kAXSizeAttribute, size: CGSize(width: target.w, height: target.h))
        write(window, kAXPositionAttribute, point: CGPoint(x: target.x, y: target.y))
        write(window, kAXSizeAttribute, size: CGSize(width: target.w, height: target.h))
        guard var actual = frame(of: window) else { return nil }
        if actual.x + actual.w > bounds.x + bounds.w || actual.y + actual.h > bounds.y + bounds.h {
            actual.x = max(bounds.x, min(actual.x, bounds.x + bounds.w - actual.w))
            actual.y = max(bounds.y, min(actual.y, bounds.y + bounds.h - actual.h))
            write(window, kAXPositionAttribute, point: CGPoint(x: actual.x, y: actual.y))
        }
        return frame(of: window)
    }

    /// Displays left to right (then top to bottom), in Accessibility coordinates.
    static func displays() -> [Display] {
        NSScreen.screens.map { Display(frame: axRect($0.frame), visible: axRect($0.visibleFrame)) }
            .sorted { ($0.frame.x, $0.frame.y) < ($1.frame.x, $1.frame.y) }
    }

    /// The display that holds most of `rect`, falling back to the one nearest its centre.
    static func displayIndex(for rect: WindowRect, in displays: [Display]) -> Int {
        func overlap(_ a: WindowRect, _ b: WindowRect) -> Double {
            max(0, min(a.x + a.w, b.x + b.w) - max(a.x, b.x)) * max(0, min(a.y + a.h, b.y + b.h) - max(a.y, b.y))
        }
        if let best = displays.indices.max(by: { overlap(rect, displays[$0].frame) < overlap(rect, displays[$1].frame) }),
           overlap(rect, displays[best].frame) > 0 { return best }
        let center = CGPoint(x: rect.x + rect.w / 2, y: rect.y + rect.h / 2)
        return displays.indices.min(by: { distance(center, displays[$0].frame) < distance(center, displays[$1].frame) }) ?? 0
    }

    // MARK: Coordinates

    private static var primaryHeight: Double { Double(NSScreen.screens.first?.frame.maxY ?? 0) }

    static func axRect(_ rect: NSRect) -> WindowRect {
        WindowRect(x: rect.minX, y: primaryHeight - rect.maxY, w: rect.width, h: rect.height)
    }

    static func appKitRect(_ rect: WindowRect) -> NSRect {
        NSRect(x: rect.x, y: primaryHeight - rect.y - rect.h, width: rect.w, height: rect.h)
    }

    static func axPoint(_ point: NSPoint) -> CGPoint { CGPoint(x: point.x, y: primaryHeight - point.y) }

    private static func distance(_ point: CGPoint, _ rect: WindowRect) -> Double {
        hypot(point.x - (rect.x + rect.w / 2), point.y - (rect.y + rect.h / 2))
    }

    // MARK: Accessibility plumbing

    /// Only ordinary windows: movable, resizable or not, and not full screen or minimized.
    private static func isMovable(_ window: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(window, kAXPositionAttribute as CFString, &settable) == .success,
              settable.boolValue else { return false }
        if attribute(window, "AXFullScreen") as? Bool == true { return false }
        if attribute(window, kAXMinimizedAttribute) as? Bool == true { return false }
        return true
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func elementAttribute(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private static func read<T>(_ element: AXUIElement, _ name: String, _ type: AXValueType, into output: inout T) -> Bool {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXValueGetTypeID() else { return false }
        let axValue = unsafeBitCast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == type else { return false }
        return withUnsafeMutablePointer(to: &output) { AXValueGetValue(axValue, type, $0) }
    }

    private static func write(_ element: AXUIElement, _ name: String, point: CGPoint) {
        var value = point
        if let axValue = AXValueCreate(.cgPoint, &value) { AXUIElementSetAttributeValue(element, name as CFString, axValue) }
    }

    private static func write(_ element: AXUIElement, _ name: String, size: CGSize) {
        var value = size
        if let axValue = AXValueCreate(.cgSize, &value) { AXUIElementSetAttributeValue(element, name as CFString, axValue) }
    }
}
