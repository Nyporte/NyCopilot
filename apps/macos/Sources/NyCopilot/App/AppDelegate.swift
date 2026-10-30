import AppKit

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

        // Only load shells whose platform-neutral half exists in this core build.
        let available = Set((try? core.call("core.info") as? [String: Any])?["modules"] as? [String] ?? [])
        modules = makeModules().filter { available.contains($0.id) }
        for module in modules { module.hotKeyActions.forEach(services.hotKeys.add) }
        modules.compactMap { $0 as? WindowsShell }.first?.importRectangleOnce()

        installMenus()
        if !preferences.hasCompletedWelcome { showWelcome() }
    }

    /// Reopening the app (Finder, Spotlight) shows Settings, since there is no Dock icon.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showSettings(pane: nil) }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) { modules.forEach { $0.shutdown() } }

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
        if !Accessibility.isTrusted || !services.preferences.canTranslate {
            let setup = NSMenuItem(title: "Finish Setting Up…", action: #selector(showWelcomeFromMenu), keyEquivalent: "")
            setup.target = self
            setup.image = NSImage(systemSymbolName: "exclamationmark.circle.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(paletteColors: [.white, .systemOrange]))
            menu.addItem(setup)
            menu.addItem(.separator())
        }
        for module in modules {
            module.menuItems().forEach(menu.addItem)
            menu.addItem(.separator())
        }
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let about = NSMenuItem(title: "About NyCopilot", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)
        menu.addItem(.separator())
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

    private func showWelcome() {
        if welcomeWindow == nil { welcomeWindow = WelcomeWindow(services: services) }
        welcomeWindow?.present()
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        let credits = NSAttributedString(string: "Your AI copilot for every app.\nModules: " + modules.map(\.title).joined(separator: ", "),
                                         attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }
}
