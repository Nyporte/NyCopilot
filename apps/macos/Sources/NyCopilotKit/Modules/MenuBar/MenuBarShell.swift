import AppKit

/// macOS half of Menu Bar: an arrow in the menu bar. Icons ⌘-dragged left of it hide when it's
/// clicked (or the shortcut pressed) and show on the next click; shown, they can hide again on
/// their own. Whether they're hidden is kept across launches. With **Show hidden icons in a bar**
/// on, the click opens `HiddenItemsBar` instead; picking an icon there shows the icons in the menu
/// bar just long enough to open that one's menu, which opens under it as usual.
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
    private var bar: HiddenItemsBar?
    private var openingBar = false
    /// When a click on the arrow closed the bar, so that click doesn't open it again.
    private var barClosedByArrow: Date?
    /// The menu of an icon opened from the bar; icons hide again when it closes.
    private var menuWatch: MenuWatch?

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
        bar?.close()
        menuWatch?.stop()
    }

    @objc private func toggleFromMenu() { toggle() }

    /// Hidden icons show (in the bar, if that's on), shown ones hide. Off, the shortcut opens
    /// Settings where it's turned on.
    func toggle() {
        let state = state
        guard state.isOn else { services.openSettings(id); return }
        if let bar { bar.close(); return }
        if let closed = barClosedByArrow, Date().timeIntervalSince(closed) < 1 { barClosedByArrow = nil; return }
        if state.opensBar { openBar(); return }
        setCollapsed(!state.collapsed)
    }

    /// The hidden icons in a bar under the arrow, once their pictures are taken (a tenth of a
    /// second or so), so it opens complete.
    private func openBar() {
        guard !openingBar, let divider, let dividerWindow = divider.dividerWindow, let anchor = divider.arrowFrame else { return }
        let items = ItemFinder.hidden(in: ItemFinder.statusItems(), divider: dividerWindow)
        guard !items.isEmpty else {
            services.toast.show(L("No icons are hidden"), detail: L("⌘-drag menu bar icons left of this arrow to hide them"), near: anchor)
            return
        }
        openingBar = true
        let scale = NSScreen.screens.first { $0.frame.intersects(anchor) }?.backingScaleFactor ?? 2
        Task {
            let images = await HiddenItemsBar.images(of: items, scale: scale)
            openingBar = false
            guard state.opensBar else { return }
            let bar = HiddenItemsBar(items: items, images: images, anchor: anchor, appearance: divider.menuBarAppearance) { [weak self] in
                self?.open($0)
            }
            bar.onClose = { [weak self] byArrow in
                self?.bar = nil
                self?.barClosedByArrow = byArrow ? Date() : nil
            }
            self.bar = bar
            bar.show()
            Diagnostics.note("menubar", "bar opened with \(items.count) icons, \(images.count) pictured")
        }
    }

    /// An icon picked in the bar: the icons show in the menu bar, then that one is pressed where
    /// it is, so its menu opens under it as usual (pressed off screen, it would open off screen).
    private func open(_ item: ItemFinder.Item) {
        guard let divider else { return }
        Diagnostics.note("menubar", "opening \(item.owner)'s icon from the bar")
        divider.show { [weak self] in self?.press(item) }
        try? services.core.setSetting(.menuBarCollapsed, false)
    }

    private func press(_ item: ItemFinder.Item) {
        let items = ItemFinder.statusItems()
        let centre = { (item: ItemFinder.Item) in CGPoint(x: item.frame.midX, y: item.frame.midY) }
        guard let shown = items.first(where: { $0.window == item.window }), shown.onScreen,
              NSScreen.screens.contains(where: { ScreenGeometry.topLeftFrame(of: $0).contains(centre(shown)) }) else {
            Diagnostics.note("menubar", "\(item.owner)'s icon didn't come into sight")
            services.toast.show(L("Couldn’t reach that icon"), detail: L("It didn’t fit in the menu bar."), style: .warning)
            return
        }
        menuWatch?.stop()
        menuWatch = MenuWatch(pid: shown.pid) { [weak self] event in self?.menuEvent(event, owner: shown.owner) }
        let appIcons = items.filter { $0.pid == shown.pid }.count
        Task {
            let how = await ItemFinder.press(shown, appIcons: appIcons)
            Diagnostics.note("menubar", "pressed \(shown.owner)'s icon by \(how)")
        }
    }

    /// The icons stay while the opened menu does and hide once it closes. An icon that opens a
    /// window instead leaves them to hide as after any other show.
    private func menuEvent(_ event: MenuWatch.Event, owner: String) {
        switch event {
        case .opened:
            Diagnostics.note("menubar", "\(owner)'s menu opened")
        case .closed:
            Diagnostics.note("menubar", "\(owner)'s menu closed")
            menuWatch = nil
            if state.isOn, !state.collapsed { setCollapsed(true) }
        case .noMenu:
            Diagnostics.note("menubar", "\(owner) opened no menu")
            menuWatch = nil
        }
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
        if !state.opensBar { bar?.close() }
        guard state.isOn else {
            hideAgain?.invalidate()
            divider?.isVisible = false
            return
        }
        if divider == nil {
            let made = MenuBarDivider()
            made.onToggle = { [weak self] in self?.toggle() }
            made.onSettings = { [weak self] in guard let self else { return }; services.openSettings(id) }
            made.keepInSight = { [weak self] in self?.services.clockItem().map { [$0] } ?? [] }
            divider = made
            // Hidden when NyCopilot last quit: hide again the usual way, chevron placed first.
            if state.collapsed { setCollapsed(true); return }
        }
        divider?.onShowInMenuBar = state.showInBar ? { [weak self] in self?.setCollapsed(false) } : nil
        divider?.isVisible = true
        divider?.show(collapsed: state.collapsed)
        scheduleHideAgain(state.hideAgainIn)
    }

    /// Shown icons hide again after a while, but not while the pointer is on the menu bar,
    /// perhaps on its way to one of them, or while a menu opened from the bar is open: then the
    /// wait starts over.
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
                if onMenuBar || self.menuWatch?.isMenuOpen == true { self.scheduleHideAgain(self.state.hideAgainIn) } else { self.setCollapsed(true) }
            }
        }
        hideAgain?.tolerance = 0.5
    }
}
