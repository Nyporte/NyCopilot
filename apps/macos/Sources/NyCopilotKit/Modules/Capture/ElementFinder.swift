import AppKit
import ApplicationServices

/// The element under the pointer during a capture — a button, a field, a sidebar — read from its
/// app through Accessibility: the innermost one big enough to be a real control, or else the
/// window. Lookups run off the main thread; while the pointer moves, only the newest is answered.
final class ElementFinder: @unchecked Sendable {
    static let shared = ElementFinder()

    private let queue = DispatchQueue(label: "dev.nycopilot.capture.elements", qos: .userInteractive)
    private let lock = NSLock()
    private var generation = 0

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
        let app = AX.application(window.pid, timeout: 0.15)
        _ = AX.exposeWebContent(app)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hit) == .success else { return window.rect }
        var current = hit
        for _ in 0..<30 {
            guard let element = current else { break }
            AX.setTimeout(element, 0.15)
            let role = AX.string(element, kAXRoleAttribute)
            if role == kAXApplicationRole || role == kAXWindowRole { break }
            if let frame = AX.frame(of: element)?.intersection(window.rect).integral,
               frame.width >= 20, frame.height >= 14, frame.contains(point) {
                return frame
            }
            current = AX.parent(of: element)
        }
        return window.rect
    }
}
