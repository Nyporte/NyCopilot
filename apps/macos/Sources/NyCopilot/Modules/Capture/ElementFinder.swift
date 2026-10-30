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

/// The parts of a window under the pointer during a capture — a button, a card, a sidebar, a
/// toolbar — read from the app through Accessibility and reduced to the levels you can see (see
/// `VisibleLevels`), innermost first and ending with the window itself, so a click can take any of
/// them exactly. Lookups run off the main thread; while the pointer moves, only the newest one is
/// answered.
final class ElementFinder: @unchecked Sendable {
    static let shared = ElementFinder()

    /// An element's frame (global top-left) and how deep it sits: the window is 0, its children 1…
    struct Candidate: Equatable {
        let rect: CGRect
        let depth: Int
    }

    private let queue = DispatchQueue(label: "dev.nycopilot.capture.elements", qos: .userInteractive)
    private let lock = NSLock()
    private var generation = 0
    /// Electron apps asked to expose their content; asked once per process.
    private var exposed: Set<pid_t> = []

    /// `point` and `window` are global top-left; `pixels` is the display as frozen, when ready;
    /// `found` gets the levels on the main thread.
    func find(at point: CGPoint, in window: FrozenScreen.Window, pixels: GreyPixels?,
              found: @escaping @MainActor ([Candidate]) -> Void) {
        guard AXIsProcessTrusted(), window.pid > 0 else { return }
        lock.lock()
        generation += 1
        let mine = generation
        lock.unlock()
        queue.async { [self] in
            guard isCurrent(mine) else { return }
            let candidates = VisibleLevels.levels(from: layers(at: point, in: window), window: window.rect, pixels: pixels)
            guard isCurrent(mine) else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { found(candidates) } }
        }
    }

    private func isCurrent(_ request: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return request == generation
    }

    /// The element under the point and each container below the window: frames clipped to the
    /// window, innermost first, with their roles.
    private func layers(at point: CGPoint, in window: FrozenScreen.Window) -> [VisibleLevels.Layer] {
        let app = AXUIElementCreateApplication(window.pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        lock.lock()
        let first = exposed.insert(window.pid).inserted
        lock.unlock()
        if first { _ = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue) }
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hit) == .success else { return [] }
        // Steps up from the element hit; depths are counted down from the window once it's reached.
        var found: [(rect: CGRect, step: Int, role: String?)] = []
        var current = hit
        var steps = 0
        for step in 0..<30 {
            guard let element = current else { break }
            steps = step
            AXUIElementSetMessagingTimeout(element, 0.15)
            let role = Self.string(element, kAXRoleAttribute)
            if role == kAXApplicationRole { break }
            if role != kAXWindowRole, let frame = AccessibilityFrame.of(element)?.intersection(window.rect).integral,
               frame.width >= 6, frame.height >= 6, frame.contains(point) {
                found.append((frame, step, role))
            }
            if role == kAXWindowRole { break }
            steps = step + 1
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parent) == .success,
                  let parent, CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            current = unsafeBitCast(parent, to: AXUIElement.self)
        }
        return found.map { VisibleLevels.Layer(rect: $0.rect, depth: max(steps - $0.step, 1), role: $0.role) }
    }

    private static func string(_ element: AXUIElement, _ name: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
