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

/// The parts of a window under the pointer during a capture — a button, a text field, a sidebar, a
/// toolbar — read from the app through Accessibility, innermost first and ending with the window
/// itself, so a click can take any of them exactly. Lookups run off the main thread; while the
/// pointer moves, only the newest one is answered.
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

    /// `point` and `window` are global top-left; `found` gets the candidates on the main thread.
    func find(at point: CGPoint, in window: FrozenScreen.Window, found: @escaping @MainActor ([Candidate]) -> Void) {
        guard AXIsProcessTrusted(), window.pid > 0 else { return }
        lock.lock()
        generation += 1
        let mine = generation
        lock.unlock()
        queue.async { [self] in
            guard isCurrent(mine) else { return }
            let candidates = candidates(at: point, in: window)
            guard isCurrent(mine) else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { found(candidates) } }
        }
    }

    private func isCurrent(_ request: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return request == generation
    }

    /// The element under the point and each container up to the window: frames clipped to the
    /// window, at least 6 points a side, without near-repeats (the innermost of those is kept).
    private func candidates(at point: CGPoint, in window: FrozenScreen.Window) -> [Candidate] {
        let app = AXUIElementCreateApplication(window.pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        lock.lock()
        let first = exposed.insert(window.pid).inserted
        lock.unlock()
        if first { _ = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue) }
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hit) == .success else {
            return [Candidate(rect: window.rect, depth: 0)]
        }
        // Steps up from the element hit; depths are counted down from the window once it's reached.
        var found: [(rect: CGRect, step: Int)] = []
        var current = hit
        var steps = 0
        for step in 0..<30 {
            guard let element = current else { break }
            steps = step
            AXUIElementSetMessagingTimeout(element, 0.15)
            let role = Self.string(element, kAXRoleAttribute)
            if role == kAXApplicationRole { break }
            if let frame = AccessibilityFrame.of(element)?.intersection(window.rect).integral,
               frame.width >= 6, frame.height >= 6, frame.contains(point),
               !found.contains(where: { Self.resembles($0.rect, frame) }) {
                found.append((frame, step))
            }
            if role == kAXWindowRole { break }
            steps = step + 1
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parent) == .success,
                  let parent, CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            current = unsafeBitCast(parent, to: AXUIElement.self)
        }
        var candidates = found.map { Candidate(rect: $0.rect, depth: max(steps - $0.step, 1)) }
        // The window itself, always last, whether or not its own frame came back.
        candidates.removeAll { Self.resembles($0.rect, window.rect) }
        candidates.append(Candidate(rect: window.rect, depth: 0))
        return candidates
    }

    private static func resembles(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= 2 && abs(a.minY - b.minY) <= 2 && abs(a.maxX - b.maxX) <= 2 && abs(a.maxY - b.maxY) <= 2
    }

    private static func string(_ element: AXUIElement, _ name: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
