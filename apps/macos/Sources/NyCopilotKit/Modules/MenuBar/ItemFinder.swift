import AppKit

/// Finds the icons Menu Bar hides and reaches the real item behind each one.
///
/// Every menu bar icon is a window at the status layer (25), owned by its app; its bounds need no
/// permission. Hidden ones end left of the divider's window, off screen. Measured on macOS 14: the
/// windows keep their numbers while hidden and shown, and each app's `AXExtrasMenuBar` children
/// report their frames even off screen, 8 pt inside the window (its padding), not in left-to-right
/// order. Pressed off screen, an item opens its menu off screen too, so it's pressed only once the
/// icons are back in the menu bar.
enum ItemFinder {
    /// One menu bar icon, as the window list describes it.
    struct Item: Equatable {
        let window: CGWindowID
        let pid: pid_t
        /// The app's name, for labels and the diagnostics report.
        let owner: String
        /// Global top-left coordinates, as the window list gives them.
        let frame: CGRect
        let onScreen: Bool

        /// A status item from one entry of `CGWindowListCopyWindowInfo`, or nil for any other window.
        init?(_ info: [String: Any]) {
            guard (info[kCGWindowLayer as String] as? NSNumber)?.intValue == Int(CGWindowLevelForKey(.statusWindow)),
                  let number = info[kCGWindowNumber as String] as? NSNumber, let pid = info[kCGWindowOwnerPID as String] as? NSNumber,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return nil }
            self.init(window: number.uint32Value, pid: pid.int32Value, owner: info[kCGWindowOwnerName as String] as? String ?? "",
                      frame: frame, onScreen: info[kCGWindowIsOnscreen as String] as? Bool ?? false)
        }

        init(window: CGWindowID, pid: pid_t, owner: String, frame: CGRect, onScreen: Bool) {
            self.window = window
            self.pid = pid
            self.owner = owner
            self.frame = frame
            self.onScreen = onScreen
        }
    }

    /// Every status item window, on screen or not.
    static func statusItems() -> [Item] {
        (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []).compactMap(Item.init)
    }

    /// The icons hidden behind the divider, left to right: on its menu bar (the same top edge) and
    /// ending where it starts or further left. NyCopilot's own items are never among them. Other
    /// windows at the status layer (an accessibility zoom lens, say) sit elsewhere and are left out.
    static func hidden(in items: [Item], divider: CGWindowID, own: pid_t = ProcessInfo.processInfo.processIdentifier) -> [Item] {
        guard let edge = items.first(where: { $0.window == divider })?.frame else { return [] }
        return items.filter { $0.pid != own && abs($0.frame.minY - edge.minY) < 1 && $0.frame.maxX <= edge.minX + 1 && $0.frame.width > 0 }
            .sorted { $0.frame.minX < $1.frame.minX }
    }

    /// Which of an app's Accessibility items is the one in `item`'s window: the one whose frame's
    /// centre lies inside it. An app with one icon and one item is matched even if the frame is off
    /// (or missing); otherwise there's no guessing, since the items' order isn't the icons' order.
    static func match(_ item: Item, appIcons: Int, axFrames: [CGRect?]) -> Int? {
        if let index = axFrames.firstIndex(where: { $0.map { item.frame.contains(CGPoint(x: $0.midX, y: $0.midY)) } ?? false }) {
            return index
        }
        return appIcons == 1 && axFrames.count == 1 ? 0 : nil
    }

    /// The Accessibility element behind `item`, if its app exposes its menu bar icons.
    static func element(for item: Item, appIcons: Int) -> AXUIElement? {
        let app = AXUIElementCreateApplication(item.pid)
        guard let bar = attribute(app, kAXExtrasMenuBarAttribute).map({ $0 as! AXUIElement }),
              let children = attribute(bar, kAXChildrenAttribute) as? [AXUIElement] else { return nil }
        return match(item, appIcons: appIcons, axFrames: children.map(frame)).map { children[$0] }
    }

    /// How a click reached an item, for the diagnostics report.
    enum Press: CustomStringConvertible {
        case accessibility, click(AXError?)

        var description: String {
            switch self {
            case .accessibility: "AX press"
            case .click(let error): "synthesized click" + (error.map { " (AX press failed: \($0.rawValue))" } ?? " (no AX element)")
            }
        }
    }

    /// Opens `item` as a click on it would: an Accessibility press, or a click at its centre for apps
    /// that don't take one. The item must be on screen. The press waits while the app tracks its
    /// menu, so it runs off the main thread with a short timeout; timing out then means the menu is
    /// open (measured: Tailscale, Clash Verge).
    static func press(_ item: Item, appIcons: Int) async -> Press {
        let element = element(for: item, appIcons: appIcons).map(Unchecked.init)
        let error: AXError? = if let element {
            await withCheckedContinuation { done in
                DispatchQueue.global(qos: .userInitiated).async {
                    AXUIElementSetMessagingTimeout(element.value, 0.25)
                    done.resume(returning: AXUIElementPerformAction(element.value, kAXPressAction as CFString))
                }
            }
        } else { nil }
        if error == .success || error == .cannotComplete { return .accessibility }
        await click(at: CGPoint(x: item.frame.midX, y: item.frame.midY))
        return .click(error)
    }

    /// A left click at `point` (global top-left). The pointer stays there, under the menu that opens.
    private static func click(at point: CGPoint) async {
        for type in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private static func frame(_ element: AXUIElement) -> CGRect? {
        guard let position = attribute(element, kAXPositionAttribute), let size = attribute(element, kAXSizeAttribute) else { return nil }
        var origin = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin), AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: origin, size: extent)
    }

    /// Accessibility elements are thread-safe to message but not marked `Sendable`.
    private struct Unchecked: @unchecked Sendable {
        let value: AXUIElement
    }
}

/// Whether an app has a menu open, from its Accessibility notifications, so icons shown to open
/// one of its items stay until that menu closes. Submenus open and close inside it, so menus are
/// counted. Ends on its own if no menu opens soon after the press: the item opened a window
/// instead, or nothing.
@MainActor
final class MenuWatch {
    enum Event { case opened, closed, noMenu }

    var isMenuOpen: Bool { openMenus > 0 }
    private var openMenus = 0
    private var observer: AXObserver?
    private let onEvent: (Event) -> Void
    private var waiting: DispatchWorkItem?
    /// What the observer's callback reaches the watch through. Retained for the observer until
    /// `stop` takes it off the run loop; a watch dropped without `stop` leaves a box that reaches nothing.
    private let box = Box()

    private final class Box {
        weak var watch: MenuWatch?
    }

    init?(pid: pid_t, onEvent: @escaping (Event) -> Void) {
        self.onEvent = onEvent
        var made: AXObserver?
        guard AXObserverCreate(pid, { _, _, name, context in
            guard let context else { return }
            let box = Unmanaged<Box>.fromOpaque(context).takeUnretainedValue()
            let opened = (name as String) == kAXMenuOpenedNotification
            MainActor.assumeIsolated { box.watch?.menu(opened: opened) }
        }, &made) == .success, let made else { return nil }
        observer = made
        let app = AXUIElementCreateApplication(pid)
        box.watch = self
        let context = Unmanaged.passRetained(box).toOpaque()
        for name in [kAXMenuOpenedNotification, kAXMenuClosedNotification] {
            AXObserverAddNotification(made, app, name as CFString, context)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(made), .defaultMode)
        // Measured: a menu opens about 30 ms after the press.
        let waiting = DispatchWorkItem { [weak self] in
            guard let self, !isMenuOpen else { return }
            stop()
            onEvent(.noMenu)
        }
        self.waiting = waiting
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: waiting)
    }

    private func menu(opened: Bool) {
        guard observer != nil, opened || openMenus > 0 else { return }
        waiting?.cancel()
        openMenus += opened ? 1 : -1
        if openMenus == 1, opened { onEvent(.opened) }
        if openMenus == 0 { stop(); onEvent(.closed) }
    }

    func stop() {
        waiting?.cancel()
        guard let observer else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        self.observer = nil
        Unmanaged.passUnretained(box).release()
    }
}
