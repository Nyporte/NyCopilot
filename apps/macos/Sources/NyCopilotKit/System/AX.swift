import AppKit
@preconcurrency import ApplicationServices

/// Reading other apps through Accessibility, in one place. Every value another process returns is
/// checked for its CF type before it's bridged, and every call is bounded by the timeout set on the
/// element it goes to, so an app that doesn't answer can't hold anything up for long.
enum AX {
    /// An app's root element, with every call through it bounded by `timeout` seconds.
    static func application(_ pid: pid_t, timeout: Float) -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        setTimeout(app, timeout)
        return app
    }

    static func setTimeout(_ element: AXUIElement, _ seconds: Float) {
        AXUIElementSetMessagingTimeout(element, seconds)
    }

    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    static func string(_ element: AXUIElement, _ name: String) -> String? { attribute(element, name) as? String }

    /// Window, focus, and parent references, bridged only once they are elements.
    static func element(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    static func parent(of element: AXUIElement) -> AXUIElement? { self.element(element, kAXParentAttribute) }

    static func focusedElement(in app: AXUIElement) -> AXUIElement? { element(app, kAXFocusedUIElementAttribute) }

    /// A position, size, rectangle, or text range attribute, when the element has one of that type.
    static func value<T: AXGeometry>(_ element: AXUIElement, _ name: String) -> T? { decode(attribute(element, name)) }

    /// An element's frame on screen, in global top-left coordinates.
    static func frame(of element: AXUIElement) -> CGRect? {
        guard let origin: CGPoint = value(element, kAXPositionAttribute), let size: CGSize = value(element, kAXSizeAttribute) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    static func parameterized(_ element: AXUIElement, _ name: String, _ parameter: CFTypeRef) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, name as CFString, parameter, &result) == .success else { return nil }
        return result
    }

    /// A parameterized attribute that answers with a rectangle, such as the bounds of a text range.
    static func rect(_ element: AXUIElement, _ name: String, _ parameter: CFTypeRef) -> CGRect? {
        decode(parameterized(element, name, parameter))
    }

    /// The same, for a plain text range.
    static func rect(_ element: AXUIElement, _ name: String, range: CFRange) -> CGRect? {
        var range = range
        return AXValueCreate(.cfRange, &range).flatMap { rect(element, name, $0) }
    }

    private static func decode<T: AXGeometry>(_ value: CFTypeRef?) -> T? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeBitCast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == T.axType else { return nil }
        var result = T()
        return withUnsafeMutablePointer(to: &result) { AXValueGetValue(axValue, T.axType, $0) } ? result : nil
    }

    // MARK: Web content

    /// Asks an app to build the accessibility tree of its web content; true if it accepted.
    static func requestWebContent(_ app: AXUIElement) -> Bool {
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue) == .success
    }

    /// Electron apps (Claude, Slack, VS Code…) keep their web content out of Accessibility until a
    /// client asks for it; each process is asked once. True when this request is what exposed it,
    /// so it's worth waiting for; a process asked before has had its tree all along.
    static func exposeWebContent(_ app: AXUIElement) -> Bool {
        var pid: pid_t = 0
        guard AXUIElementGetPid(app, &pid) == .success else { return false }
        exposedLock.lock()
        let first = exposed.insert(pid).inserted
        exposedLock.unlock()
        guard first else { return false }
        let accepted = requestWebContent(app)
        let electron = NSRunningApplication(processIdentifier: pid)?.bundleURL.map {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("Contents/Frameworks/Electron Framework.framework").path)
        } ?? false
        return accepted || electron
    }

    /// Processes already asked to expose their web content.
    nonisolated(unsafe) private static var exposed: Set<pid_t> = []
    private static let exposedLock = NSLock()
}

/// The geometry types an `AXValue` carries, each with its tag.
protocol AXGeometry {
    static var axType: AXValueType { get }
    init()
}

extension CGPoint: AXGeometry { static var axType: AXValueType { .cgPoint } }
extension CGSize: AXGeometry { static var axType: AXValueType { .cgSize } }
extension CGRect: AXGeometry { static var axType: AXValueType { .cgRect } }
extension CFRange: AXGeometry { static var axType: AXValueType { .cfRange } }
