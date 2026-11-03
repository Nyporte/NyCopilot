import AppKit

/// Menu Bar settings: whether the divider is in the menu bar, when shown icons hide again, and the
/// shortcut that shows or hides them.
@MainActor
final class MenuBarPane: SettingsPane {
    private let services: CopilotServices
    private let enabledSwitch = NSSwitch()
    private let collapseAfter = NSPopUpButton()
    private lazy var shortcuts = ShortcutEditor(services: services)

    init(services: CopilotServices) {
        self.services = services
        super.init(id: "menubar", title: L("Menu Bar"), symbol: "menubar.rectangle")
    }

    required init?(coder: NSCoder) { fatalError("Use init(services:)") }

    override func makeSections() -> [NSView] {
        enabledSwitch.target = self
        enabledSwitch.action = #selector(toggleEnabled)
        for seconds in MenuBarState.collapseAfterChoices {
            collapseAfter.addItem(withTitle: Self.title(seconds))
            collapseAfter.lastItem?.representedObject = seconds
        }
        collapseAfter.target = self
        collapseAfter.action = #selector(changeCollapseAfter)
        return [
            FormSection(L("Menu bar icons"), footer: L("⌘-drag icons left of the divider to hide them, and right of it to keep them in sight. Click the chevron to show or hide them; right-click it for Settings. On a Mac with a notch, icons that don’t fit beside it stay out of sight even when shown."), rows: [
                FormRow(L("Hide icons behind a divider"), subtitle: L("Puts a divider and a chevron in the menu bar."), accessory: enabledSwitch),
                FormRow(L("Hide again"), subtitle: L("After showing hidden icons. Not while the pointer is on the menu bar."), accessory: collapseAfter)
            ]),
            shortcuts.section(L("Shortcut"), actions: [MenuBarShell.Action.toggle]),
            shortcuts.errorLabel
        ]
    }

    override func paneWillAppear() {
        let on: Bool = services.core.setting(.menuBarEnabled, default: false)
        enabledSwitch.state = on ? .on : .off
        let seconds: Double = services.core.setting(.menuBarCollapseAfter, default: 10)
        if let item = collapseAfter.itemArray.first(where: { $0.representedObject as? Double == seconds }) {
            collapseAfter.select(item)
        } else {
            // A value set elsewhere that isn't one of the choices still shows as itself.
            collapseAfter.addItem(withTitle: Self.title(seconds))
            collapseAfter.lastItem?.representedObject = seconds
            collapseAfter.select(collapseAfter.lastItem)
        }
        collapseAfter.isEnabled = on
        shortcuts.refresh()
    }

    private static func title(_ seconds: TimeInterval) -> String {
        switch seconds {
        case 0: L("Never")
        case 60: L("After 1 minute")
        default: L("After %ld seconds", Int(seconds))
        }
    }

    @objc private func toggleEnabled() {
        // The divider shows first, so there's somewhere to drag icons before anything hides.
        if enabledSwitch.state == .on { try? services.core.setSetting(.menuBarCollapsed, false) }
        try? services.core.setSetting(.menuBarEnabled, enabledSwitch.state == .on)
        if enabledSwitch.state == .on, !services.isModuleOn("menubar") { services.setModule("menubar", true) }
        paneWillAppear()
    }

    @objc private func changeCollapseAfter() {
        guard let seconds = collapseAfter.selectedItem?.representedObject as? Double else { return }
        try? services.core.setSetting(.menuBarCollapseAfter, seconds)
    }
}
