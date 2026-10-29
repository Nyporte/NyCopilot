import AppKit
import MacPlatform

/// macOS half of Window Layouts: global shortcuts, a menu, and drag snapping that move the focused
/// window to frames computed by the core's `windows` module.
@MainActor
final class WindowsShell: ModuleShell {
    let id = "windows"
    let title = "Window Layouts"
    let symbolName = "rectangle.split.2x1"

    struct ActionInfo: Decodable { let id: String; let title: String; let group: String }
    private struct FrameResult: Decodable { let frame: WindowRect }
    /// `compute` either returns a frame or asks to continue on the neighbouring display.
    private struct ComputeResult: Decodable {
        struct Move: Decodable { let direction: String; let action: String }
        let frame: WindowRect?
        let move: Move?
    }

    private let services: CopilotServices
    let actions: [ActionInfo]
    private let snapper: SnapController
    /// Frames from before NyCopilot first moved each window, for Restore. Newest last, bounded.
    private var originals: [(window: AXUIElement, frame: WindowRect)] = []
    /// The last action applied, so repeating a shortcut on an untouched window counts as a repeat.
    private var last: (window: AXUIElement, action: String, frame: WindowRect, repeat: UInt32)?
    private var observer: NSObjectProtocol?

    /// ⌃⌥ plus a key that suggests the layout; ⌃⌥⌘ moves between displays.
    private static let defaults: [String: (key: UInt32, modifiers: UInt32)] = {
        let base = HotKeyCombination.control | HotKeyCombination.option
        return [
            "left_half": (123, base), "right_half": (124, base), "top_half": (126, base), "bottom_half": (125, base),
            "top_left": (32, base), "top_right": (34, base), "bottom_left": (38, base), "bottom_right": (40, base),
            "first_third": (2, base), "center_third": (3, base), "last_third": (5, base),
            "first_two_thirds": (14, base), "last_two_thirds": (17, base),
            "maximize": (36, base), "maximize_height": (126, base | HotKeyCombination.shift), "center": (8, base),
            "larger": (24, base), "smaller": (27, base), "restore": (51, base),
            "next_display": (124, base | HotKeyCombination.command), "previous_display": (123, base | HotKeyCombination.command)
        ]
    }()

    init(services: CopilotServices) {
        self.services = services
        actions = (try? services.core.call("windows.actions", as: [ActionInfo].self)) ?? []
        snapper = SnapController(core: services.core)
        snapper.onSnap = { [weak self] window, frame, display in self?.apply(frame, to: window, on: display, action: nil) }
        snapper.isEnabled = services.core.setting("windows.drag_snap", default: true)
        observer = NotificationCenter.default.addObserver(forName: NyCore.eventNotification, object: nil, queue: .main) { [weak self] note in
            guard let event = note.userInfo?["event"] as? [String: Any], event["key"] as? String == "windows.drag_snap" else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                self.snapper.isEnabled = self.services.core.setting("windows.drag_snap", default: true)
            }
        }
    }

    /// Called once all shortcuts are registered: someone switching from Rectangle gets their
    /// shortcuts carried over automatically, once, unless they already customized NyCopilot's.
    func importRectangleOnce() {
        // The repeat behaviour arrived after the shortcut import, so it has its own one-time check.
        if !services.core.setting("client.windows.rectangle_repeat_checked", default: false) {
            try? services.core.setSetting("client.windows.rectangle_repeat_checked", true)
            if RectangleImport.isAvailable, let mode = RectangleImport.read().repeatMode {
                try? services.core.setSetting("windows.repeat", mode)
            }
        }
        guard !services.core.setting("client.windows.rectangle_import_checked", default: false) else { return }
        try? services.core.setSetting("client.windows.rectangle_import_checked", true)
        guard RectangleImport.isAvailable,
              !services.hotKeys.isCustomized(actions.map { "windows.\($0.id)" }) else { return }
        let result = RectangleImport.read()
        guard !result.shortcuts.isEmpty else { return }
        let outcome = RectangleImport.apply(result, to: services)
        services.toast.show("Window shortcuts imported from Rectangle", detail: outcome.summary,
                            style: outcome.failed == 0 ? .success : .warning)
    }

    var hotKeyActions: [HotKeyCenter.Action] {
        actions.map { action in
            let combination = Self.defaults[action.id].map { HotKeyCombination(keyCode: $0.key, modifiers: $0.modifiers) }
            return .init(id: "windows.\(action.id)", title: action.title, defaultCombination: combination,
                         handler: { [weak self] in self?.perform(action.id) })
        }
    }

    func menuItems() -> [NSMenuItem] {
        let menu = NSMenu()
        var group = actions.first?.group
        for action in actions {
            if action.group != group { menu.addItem(.separator()); group = action.group }
            let item = services.menuItem(action.title, symbol: Self.symbol(for: action.id), hotKey: "windows.\(action.id)",
                                         target: self, action: #selector(performFromMenu(_:)))
            item.representedObject = action.id
            menu.addItem(item)
        }
        let parent = NSMenuItem(title: "Window Layout", action: nil, keyEquivalent: "")
        parent.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        parent.submenu = menu
        return [parent]
    }

    func makeSettingsPane() -> SettingsPane? { WindowsPane(services: services, actions: actions) }

    func shutdown() { snapper.isEnabled = false }

    // MARK: Actions

    /// The status menu doesn't activate NyCopilot, so the frontmost app's window is still the target.
    @objc private func performFromMenu(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { perform(id) }
    }

    func perform(_ action: String) {
        guard Accessibility.isTrusted else {
            services.toast.show("Allow Accessibility to arrange windows", detail: "Open Settings → General to turn it on.", style: .warning)
            return
        }
        guard let window = WindowControl.focusedWindow(), let current = WindowControl.frame(of: window) else {
            NSSound.beep()
            return
        }
        let displays = WindowControl.displays()
        guard !displays.isEmpty else { return }
        let index = WindowControl.displayIndex(for: current, in: displays)
        let display = displays[index]
        do {
            switch action {
            case "restore":
                guard let saved = originals.lastIndex(where: { CFEqual($0.window, window) }) else { NSSound.beep(); return }
                let frame = originals.remove(at: saved).frame
                let target = displays[WindowControl.displayIndex(for: frame, in: displays)]
                WindowControl.setFrame(frame, of: window, within: target.visible)
                last = nil
            case "next_display", "previous_display":
                guard displays.count > 1 else { NSSound.beep(); return }
                let next = displays[(index + (action == "next_display" ? 1 : displays.count - 1)) % displays.count]
                let result = try services.core.call("windows.move_to_screen",
                    ["window": current.json, "from": display.visible.json, "to": next.visible.json], as: FrameResult.self)
                apply(result.frame, to: window, on: next, action: action)
            default:
                let repeated = last.map { CFEqual($0.window, window) && $0.action == action && $0.frame.isClose(to: current) } ?? false
                let count: UInt32 = repeated ? (last?.repeat ?? 0) + 1 : 0
                let result = try services.core.call("windows.compute",
                    ["action": action, "window": current.json, "screen": display.visible.json, "repeat": count], as: ComputeResult.self)
                if let frame = result.frame {
                    apply(frame, to: window, on: display, action: action, repeat: count)
                } else if let move = result.move {
                    // No display that way: leave the window where it is.
                    guard let neighbour = Self.neighbour(of: index, toward: move.direction, in: displays) else { NSSound.beep(); return }
                    let landing = try services.core.call("windows.compute",
                        ["action": move.action, "window": current.json, "screen": neighbour.visible.json], as: ComputeResult.self)
                    // Record the landing layout, so pressing the same key again keeps the window travelling.
                    if let frame = landing.frame { apply(frame, to: window, on: neighbour, action: move.action) }
                }
            }
        } catch {
            services.toast.show("Couldn’t arrange the window", detail: error.localizedDescription, style: .warning)
        }
    }

    /// Remember the pre-NyCopilot frame once per window, then move it.
    private func apply(_ frame: WindowRect, to window: AXUIElement, on display: Display, action: String?, repeat count: UInt32 = 0) {
        if !originals.contains(where: { CFEqual($0.window, window) }), let before = WindowControl.frame(of: window),
           !before.isClose(to: frame) {
            originals.append((window, before))
            if originals.count > 64 { originals.removeFirst() }
        }
        let applied = WindowControl.setFrame(frame, of: window, within: display.visible) ?? frame
        last = action.map { (window, $0, applied, count) }
    }

    /// The nearest display whose centre lies in `direction` from the current one.
    private static func neighbour(of index: Int, toward direction: String, in displays: [Display]) -> Display? {
        func center(_ rect: WindowRect) -> (Double, Double) { (rect.x + rect.w / 2, rect.y + rect.h / 2) }
        let (cx, cy) = center(displays[index].frame)
        return displays.enumerated()
            .filter { $0.offset != index && (direction == "left" ? center($0.element.frame).0 < cx : center($0.element.frame).0 > cx) }
            .min { hypot(center($0.element.frame).0 - cx, center($0.element.frame).1 - cy)
                 < hypot(center($1.element.frame).0 - cx, center($1.element.frame).1 - cy) }?.element
    }

    static func symbol(for action: String) -> String {
        switch action {
        case "left_half": return "rectangle.lefthalf.filled"
        case "right_half": return "rectangle.righthalf.filled"
        case "top_half": return "rectangle.tophalf.filled"
        case "bottom_half": return "rectangle.bottomhalf.filled"
        case "top_left": return "rectangle.inset.topleft.filled"
        case "top_right": return "rectangle.inset.topright.filled"
        case "bottom_left": return "rectangle.inset.bottomleft.filled"
        case "bottom_right": return "rectangle.inset.bottomright.filled"
        case "first_third", "first_two_thirds": return "rectangle.leadingthird.inset.filled"
        case "center_third": return "rectangle.center.inset.filled"
        case "last_third", "last_two_thirds": return "rectangle.trailingthird.inset.filled"
        case "maximize": return "rectangle.inset.filled"
        case "almost_maximize": return "rectangle.center.inset.filled"
        case "maximize_height": return "arrow.up.and.down.square"
        case "center": return "square.dashed.inset.filled"
        case "larger": return "plus.rectangle"
        case "smaller": return "minus.rectangle"
        case "restore": return "arrow.uturn.backward.square"
        case "next_display": return "arrow.right.to.line"
        case "previous_display": return "arrow.left.to.line"
        default: return "rectangle"
        }
    }
}
