import AppKit

/// macOS half of Menu Bar: an arrow in the menu bar. Icons ⌘-dragged left of it hide when it's
/// clicked (or the shortcut pressed) and show on the next click; shown, they can hide again on
/// their own. Whether they're hidden is kept across launches.
@MainActor
final class MenuBarShell: ModuleShell {
    let id = "menubar"
    let title = L("Menu Bar")
    let symbolName = "menubar.rectangle"

    enum Action {
        static let toggle = "menubar.toggle"
    }

    private let services: CopilotServices
    private var divider: MenuBarDivider?
    private var hideAgain: Timer?
    private var observer: NSObjectProtocol?

    init(services: CopilotServices) {
        self.services = services
        observer = NotificationCenter.default.addObserver(forName: NyCore.eventNotification, object: nil, queue: .main) { [weak self] note in
            guard let key = (note.userInfo?["event"] as? [String: Any])?["key"] as? String,
                  key.hasPrefix("menubar.") || key == SettingKey.modulesOff.rawValue else { return }
            MainActor.assumeIsolated { self?.apply() }
        }
        // After NyCopilot's own icon is in the menu bar, so the first time, these land left of it.
        DispatchQueue.main.async { [weak self] in self?.apply() }
    }

    private var state: MenuBarState { MenuBarState.read(services.core, moduleOn: services.isModuleOn(id)) }

    // No default: any combination is taken somewhere, and the arrow is always a click away.
    var hotKeyActions: [HotKeyCenter.Action] {
        [.init(id: Action.toggle, title: L("Show or hide menu bar icons"), defaultCombination: nil,
               handler: { [weak self] in self?.toggle() })]
    }

    func menuItems() -> [NSMenuItem] {
        let state = state
        guard state.isOn else { return [] }
        return [services.menuItem(state.collapsed ? L("Show Hidden Icons") : L("Hide Menu Bar Icons"), symbol: "menubar.rectangle",
                                  hotKey: Action.toggle, target: self, action: #selector(toggleFromMenu))]
    }

    func makeSettingsPane() -> SettingsPane? { MenuBarPane(services: services) }

    func shutdown() {
        hideAgain?.invalidate()
    }

    @objc private func toggleFromMenu() { toggle() }

    /// Hidden icons show, shown ones hide. Off, the shortcut opens Settings where it's turned on.
    func toggle() {
        guard state.isOn else { services.openSettings(id); return }
        setCollapsed(!state.collapsed)
    }

    /// `apply` follows from the setting's change event. Hiding is undone unless the chevron comes
    /// back right of the divider, so there's always something to click to show again.
    private func setCollapsed(_ collapsed: Bool) {
        guard collapsed, let divider else {
            Diagnostics.note("menubar", "showing")
            try? services.core.setSetting(.menuBarCollapsed, collapsed)
            return
        }
        divider.hide { [weak self] edges in
            guard let self else { return }
            let placed = edges.map { ": the divider ends at x \(Int($0.divider)), the chevron starts at x \(Int($0.chevron))" } ?? ""
            guard let edges, MenuBarState.canHide(divider: edges.divider, chevron: edges.chevron) else {
                Diagnostics.note("menubar", "not hiding\(placed)")
                divider.show(collapsed: false)
                if state.collapsed { try? services.core.setSetting(.menuBarCollapsed, false) }
                services.toast.show(L("Couldn’t hide the icons"), detail: L("⌘-drag the arrow a little, then try again."), style: .warning)
                return
            }
            Diagnostics.note("menubar", "hidden\(placed)")
            try? services.core.setSetting(.menuBarCollapsed, true)
        }
    }

    /// The divider in the menu bar as the settings say, or out of it.
    private func apply() {
        let state = state
        guard state.isOn else {
            hideAgain?.invalidate()
            divider?.isVisible = false
            return
        }
        if divider == nil {
            let made = MenuBarDivider()
            made.onToggle = { [weak self] in self?.toggle() }
            made.onSettings = { [weak self] in guard let self else { return }; services.openSettings(id) }
            divider = made
            // Hidden when NyCopilot last quit: hide again the usual way, chevron placed first.
            if state.collapsed { setCollapsed(true); return }
        }
        divider?.isVisible = true
        divider?.show(collapsed: state.collapsed)
        scheduleHideAgain(state.hideAgainIn)
    }

    /// Shown icons hide again after a while, but not while the pointer is on the menu bar,
    /// perhaps on its way to one of them: then the wait starts over.
    private func scheduleHideAgain(_ delay: TimeInterval?) {
        hideAgain?.invalidate()
        hideAgain = nil
        guard let delay else { return }
        hideAgain = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let point = NSEvent.mouseLocation
                let onMenuBar = NSScreen.screens.contains {
                    MenuBarState.isOnMenuBar(point, frame: $0.frame, visibleFrame: $0.visibleFrame, thickness: NSStatusBar.system.thickness)
                }
                if onMenuBar { self.scheduleHideAgain(self.state.hideAgainIn) } else { self.setCollapsed(true) }
            }
        }
        hideAgain?.tolerance = 0.5
    }
}
