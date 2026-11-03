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
            guard let window = AX.element(AX.application(pid, timeout: 0.2), kAXFocusedWindowAttribute) else { return context }
            AX.setTimeout(window, 0.2)
            let title = AX.string(window, kAXTitleAttribute) ?? ""
            // A window titled with just the app's name says nothing more.
            context.title = title == name ? "" : title
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
            AX.setTimeout(element, 0.1)
            if AX.string(element, kAXRoleAttribute) == "AXWebArea" { return address(element, "AXURL") }
            if let list = AX.attribute(element, kAXChildrenAttribute) as? [AXUIElement] { queue += list.prefix(50) }
        }
        return nil
    }

    /// A URL attribute, whether the app gives it as a URL or as text; web and file addresses only.
    private static func address(_ element: AXUIElement, _ name: String) -> String? {
        guard let value = AX.attribute(element, name) else { return nil }
        let text = (value as? URL)?.absoluteString ?? (value as? String)
        guard let text, isMeaningful(address: text) else { return nil }
        return text
    }

    /// A web page, or a file of yours — not a file inside an app's own bundle (an Electron app
    /// reports its interface's index.html as its "document").
    static func isMeaningful(address: String) -> Bool {
        guard let url = URL(string: address), let scheme = url.scheme?.lowercased() else { return false }
        if scheme == "http" || scheme == "https" { return true }
        return scheme == "file" && !url.path.contains(".app/Contents/")
    }
}
