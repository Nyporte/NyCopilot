import AppKit
import MacPlatform

/// Hosts the core and the module shells: menu bar item, app menu, Settings, and first-run guide.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var core: NyCore!
    private var services: CopilotServices!
    private var modules: [ModuleShell] = []
    private var statusItem: NSStatusItem?
    private var settingsWindow: SettingsWindow?
    private var welcomeWindow: WelcomeWindow?

    /// Every module this build ships, in menu order. Add new module shells here.
    private func makeModules() -> [ModuleShell] {
        [TranslateShell(services: services), WindowsShell(services: services), CaptureShell(services: services),
         ClipboardShell(services: services), InboxShell(services: services), AskShell(services: services)]
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let identifier = Bundle.main.bundleIdentifier,
           let existing = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            existing.activate(options: [.activateIgnoringOtherApps])
            NSApp.terminate(nil)
            return
        }
        do {
            core = try NyCore(dataDirectory: Preferences.dataDirectory)
        } catch {
            let alert = NSAlert()
            alert.messageText = "NyCopilot couldn’t start"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        let preferences = Preferences(core: core)
        preferences.migrateFromNyTranslate()
        services = CopilotServices(core: core, preferences: preferences, hotKeys: HotKeyCenter(preferences: preferences))
        services.openSettings = { [weak self] pane in self?.showSettings(pane: pane) }
        services.showWelcome = { [weak self] in self?.showWelcome() }
        services.isModuleOn = { [weak self] id in !(self?.modulesOff.contains(id) ?? false) }
        services.setModule = { [weak self] id, on in self?.setModule(id, on: on) }
        services.moduleList = { [weak self] in self?.modules.map { ($0.id, $0.title, $0.symbolName) } ?? [] }

        // Only load shells whose platform-neutral half exists in this core build.
        let available = Set((try? core.call(.coreInfo) as? [String: Any])?["modules"] as? [String] ?? [])
        // Old deletion markers go and the log is folded in, off the launch path.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [core] in _ = try? core?.call(.coreCompact) }
        modules = makeModules().filter { available.contains($0.id) }
        for module in modules { module.hotKeyActions.forEach(services.hotKeys.add) }
        services.hotKeys.add(.init(id: Self.showShortcutsAction, title: "Show all keyboard shortcuts",
                                   defaultCombination: .init(keyCode: 44, modifiers: HotKeyCombination.option | HotKeyCombination.command), // ⌥⌘/
                                   handler: { [weak self] in self?.showShortcuts() }))
        modules.compactMap { $0 as? WindowsShell }.first?.importRectangleOnce()

        installMenus()
        if !preferences.hasCompletedWelcome { showWelcome() }
    }

    /// Reopening the app (Finder, Spotlight) shows Settings, since there is no Dock icon.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showSettings(pane: nil) }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        modules.forEach { $0.shutdown() }
        _ = try? services.core.call(.coreCompact)
    }

    // MARK: Menus

    private func installMenus() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = BrandGlyph.menuBarImage()
        item.button?.toolTip = "NyCopilot"
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item

        // A standard main menu so text editing, ⌘W, and ⌘, work in NyCopilot's own windows.
        let main = NSMenu()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About NyCopilot", action: #selector(showAbout), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit NyCopilot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        main.addItem(appItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Find", action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "f").tag = 1
        let editItem = NSMenuItem()
        editItem.submenu = edit
        main.addItem(editItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        let windowItem = NSMenuItem()
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.mainMenu = main
    }

    /// The status menu is rebuilt on open so shortcuts and setup state are always current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        // Translation works without a service where macOS has its own panel.
        if !Accessibility.isTrusted || !(services.preferences.canTranslate || SystemTranslation.isAvailable) {
            let setup = NSMenuItem(title: "Finish Setting Up…", action: #selector(showWelcomeFromMenu), keyEquivalent: "")
            setup.target = self
            setup.image = NSImage(systemSymbolName: "exclamationmark.circle.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(paletteColors: [.white, .systemOrange]))
            menu.addItem(setup)
            menu.addItem(.separator())
        }
        for module in modules where services.isModuleOn(module.id) {
            module.menuItems().forEach(menu.addItem)
            menu.addItem(.separator())
        }
        menu.addItem(services.menuItem("Keyboard Shortcuts", symbol: "keyboard", hotKey: Self.showShortcutsAction,
                                       target: self, action: #selector(showShortcutsFromMenu)))
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let about = NSMenuItem(title: "About NyCopilot", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)
        menu.addItem(.separator())
        let restart = NSMenuItem(title: "Restart NyCopilot", action: #selector(restart), keyEquivalent: "")
        restart.target = self
        menu.addItem(restart)
        menu.addItem(NSMenuItem(title: "Quit NyCopilot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    // MARK: Windows

    @objc private func openSettings() { showSettings(pane: nil) }

    private func showSettings(pane: String?) {
        if settingsWindow == nil {
            let panes = [GeneralPane(services: services), ModelPane(services: services)] + modules.compactMap { $0.makeSettingsPane() }
            settingsWindow = SettingsWindow(panes: panes)
        }
        settingsWindow?.present(pane: pane)
    }

    @objc private func showWelcomeFromMenu() { showWelcome() }

    static let showShortcutsAction = "app.shortcuts"

    private var modulesOff: Set<String> { Set(services.core.setting(.modulesOff, default: [String]())) }

    /// Off: its shortcuts are cleared and its menu items hidden (Clipboard also stops keeping copies).
    /// On: its shortcuts come back as they were by default, in the current key scheme.
    private func setModule(_ id: String, on: Bool) {
        var off = modulesOff
        guard off.contains(id) == on, let module = modules.first(where: { $0.id == id }) else { return }
        if on { off.remove(id) } else { off.insert(id) }
        try? services.core.setSetting(.modulesOff, off.sorted())
        let scheme = KeyScheme.current(services).combinations
        var changes: [String: HotKeyCombination?] = [:]
        for action in module.hotKeyActions { changes[action.id] = on ? scheme[action.id] ?? action.defaultCombination : nil }
        _ = services.hotKeys.set(changes)
        if id == "clipboard" { try? services.core.setSetting(.clipboardEnabled, on) }
    }

    @objc private func showShortcutsFromMenu() { showShortcuts() }

    /// Every module's shortcuts as they're set now, then the verbs that work on anything.
    private func showShortcuts() {
        var groups: [KeySheet.Group] = modules.filter { services.isModuleOn($0.id) }.compactMap { module in
            var keys = module.hotKeyActions.compactMap { action in
                services.hotKeys.combination(for: action.id).map { (KeyNames.display($0), action.title) }
            }
            guard !keys.isEmpty else { return nil }
            if keys.count > 7 { keys = Array(keys.prefix(6)) + [("…", "\(keys.count - 6) more in Settings → \(module.title)")] }
            return KeySheet.Group(title: module.title, keys: keys)
        }
        groups.append(KeyGuide.verbs)
        if let combination = services.hotKeys.combination(for: Self.showShortcutsAction) {
            groups.append(.init(title: "Help", keys: [(KeyNames.display(combination), "This sheet"), ("?", "A surface’s own keys (⌘/ where you type)")]))
        }
        KeySheet.shared.toggle("Keyboard Shortcuts", groups: groups)
    }

    private func showWelcome() {
        if welcomeWindow == nil { welcomeWindow = WelcomeWindow(services: services) }
        welcomeWindow?.present()
    }

    /// Quits and opens again: a small shell waits for this process to exit (a second copy would
    /// otherwise see this one still running and quit), then opens the app.
    @objc private func restart() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.1; done; /usr/bin/open \"$2\"", "restart",
                             String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundlePath]
        do {
            try process.run()
        } catch {
            services.toast.show("Couldn’t restart", detail: error.localizedDescription, style: .warning)
            return
        }
        Diagnostics.note("app", "restarting")
        NSApp.terminate(nil)
    }

    @objc private func showAbout() {
        NSApp.bringForward()
        let credits = NSAttributedString(string: "Your AI copilot for every app.\nModules: " + modules.map(\.title).joined(separator: ", "),
                                         attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }
}
