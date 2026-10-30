import AppKit
import ApplicationServices

/// Where something was captured: the app, its front window's title, and the page or document
/// address when the app reports one (a browser's page, an editor's file), read through
/// Accessibility so it can be traced back later.
struct SourceContext: Sendable {
    var app = ""
    var title = ""
    var url = ""

    /// What `app` shows right now; just its name without Accessibility.
    @MainActor
    static func of(_ app: NSRunningApplication?) async -> SourceContext {
        guard let app else { return SourceContext() }
        let name = app.localizedName ?? "", pid = app.processIdentifier
        guard AXIsProcessTrusted() else { return SourceContext(app: name) }
        return await Task.detached(priority: .userInitiated) {
            var context = SourceContext(app: name)
            let element = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(element, 0.2)
            guard let window = Self.element(element, kAXFocusedWindowAttribute) else { return context }
            AXUIElementSetMessagingTimeout(window, 0.2)
            context.title = Self.string(window, kAXTitleAttribute) ?? ""
            context.url = Self.address(window, kAXDocumentAttribute) ?? Self.webAddress(in: window) ?? ""
            return context
        }.value
    }

    /// A browser's page address: the `AXURL` of the first web area inside the window.
    private static func webAddress(in window: AXUIElement) -> String? {
        var queue = [window]
        var head = 0
        while head < queue.count, head < 300 {
            let element = queue[head]
            head += 1
            AXUIElementSetMessagingTimeout(element, 0.1)
            if string(element, kAXRoleAttribute) == "AXWebArea" { return address(element, "AXURL") }
            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
               let list = children as? [AXUIElement] { queue += list.prefix(50) }
        }
        return nil
    }

    /// A URL attribute, whether the app gives it as a URL or as text; web and file addresses only.
    private static func address(_ element: AXUIElement, _ name: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success, let value else { return nil }
        let text = (value as? URL)?.absoluteString ?? (value as? String)
        guard let text, let scheme = URL(string: text)?.scheme?.lowercased(), ["http", "https", "file"].contains(scheme) else { return nil }
        return text
    }

    private static func string(_ element: AXUIElement, _ name: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func element(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }
}
