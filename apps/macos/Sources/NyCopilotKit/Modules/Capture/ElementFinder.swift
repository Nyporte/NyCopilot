import AppKit
import ApplicationServices

/// An accessibility element's frame on screen, in global top-left coordinates.
enum AccessibilityFrame {
    static func of(_ element: AXUIElement) -> CGRect? {
        var position = CGPoint.zero, size = CGSize.zero
        guard let origin = value(element, kAXPositionAttribute), AXValueGetValue(origin, .cgPoint, &position),
              let extent = value(element, kAXSizeAttribute), AXValueGetValue(extent, .cgSize, &size),
              size.width > 0, size.height > 0 else { return nil }
        return CGRect(origin: position, size: size)
    }

    private static func value(_ element: AXUIElement, _ name: String) -> AXValue? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXValue.self)
    }
}

/// The element under the pointer during a capture — a button, a field, a sidebar — read from its
/// app through Accessibility: the innermost one big enough to be a real control, or else the
/// window. Lookups run off the main thread; while the pointer moves, only the newest is answered.
final class ElementFinder: @unchecked Sendable {
    static let shared = ElementFinder()

    private let queue = DispatchQueue(label: "dev.nycopilot.capture.elements", qos: .userInteractive)
    private let lock = NSLock()
    private var generation = 0
    /// Electron apps asked to expose their content; asked once per process.
    private var exposed: Set<pid_t> = []

    /// `point` and `window` are global top-left; `found` gets the element's frame on the main thread.
    func find(at point: CGPoint, in window: FrozenScreen.Window, found: @escaping @MainActor @Sendable (CGRect) -> Void) {
        guard AXIsProcessTrusted(), window.pid > 0 else { return }
        lock.lock()
        generation += 1
        let mine = generation
        lock.unlock()
        queue.async { [self] in
            guard isCurrent(mine) else { return }
            let element = element(at: point, in: window)
            guard isCurrent(mine) else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { found(element) } }
        }
    }

    private func isCurrent(_ request: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return request == generation
    }

    /// From the element hit outward, the first frame (clipped to the window) at least 20 × 14
    /// points that contains the point — so a label's text run gives way to its button — or the
    /// window when there's none.
    private func element(at point: CGPoint, in window: FrozenScreen.Window) -> CGRect {
        let app = AXUIElementCreateApplication(window.pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        lock.lock()
        let first = exposed.insert(window.pid).inserted
        lock.unlock()
        if first { _ = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue) }
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hit) == .success else { return window.rect }
        var current = hit
        for _ in 0..<30 {
            guard let element = current else { break }
            AXUIElementSetMessagingTimeout(element, 0.15)
            let role = Self.string(element, kAXRoleAttribute)
            if role == kAXApplicationRole || role == kAXWindowRole { break }
            if let frame = AccessibilityFrame.of(element)?.intersection(window.rect).integral,
               frame.width >= 20, frame.height >= 14, frame.contains(point) {
                return frame
            }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parent) == .success,
                  let parent, CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            current = unsafeBitCast(parent, to: AXUIElement.self)
        }
        return window.rect
    }

    private static func string(_ element: AXUIElement, _ name: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
