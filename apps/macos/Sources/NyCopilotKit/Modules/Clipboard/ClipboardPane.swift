import AppKit

/// Clipboard settings: whether copies are kept, for how long, how many, and the shortcut.
@MainActor
final class ClipboardPane: SettingsPane {
    private let services: CopilotServices
    private let enabledSwitch = NSSwitch()
    private let keepFor = NSPopUpButton()
    private let atMost = NSPopUpButton()
    private let clearButton = Design.button("Clear History…", target: nil, action: nil)
    private lazy var shortcuts = ShortcutEditor(services: services)
    private static let days = [(1, "1 day"), (7, "1 week"), (30, "30 days"), (90, "90 days"), (365, "1 year")]
    private static let counts = [100, 500, 1000, 5000]

    init(services: CopilotServices) {
        self.services = services
        super.init(id: "clipboard", title: "Clipboard", symbol: "doc.on.clipboard")
    }

    required init?(coder: NSCoder) { fatalError("Use init(services:)") }

    override func makeSections() -> [NSView] {
        enabledSwitch.target = self
        enabledSwitch.action = #selector(toggleEnabled)
        keepFor.addItems(withTitles: Self.days.map(\.1))
        keepFor.target = self
        keepFor.action = #selector(changeDays)
        atMost.addItems(withTitles: Self.counts.map { "\($0) entries" })
        atMost.target = self
        atMost.action = #selector(changeCount)
        clearButton.target = self
        clearButton.action = #selector(clearHistory)
        return [
            FormSection("History", footer: "Copies — text and images — stay on this Mac. Pinned entries (⌘P in the list) are kept until you unpin them. Passwords and anything an app marks private are never kept, nor copies from password managers.", rows: [
                FormRow("Keep clipboard history", subtitle: "Text and images you copy, newest first; copying it again moves it to the top.", accessory: enabledSwitch),
                FormRow("Keep entries for", accessory: keepFor),
                FormRow("Keep at most", accessory: atMost),
                FormRow("Forget everything", accessory: clearButton)
            ]),
            shortcuts.section("Shortcuts", footer: "Type to search, ↩ pastes into the app you were in, ⌘1–9 picks one of the first nine, ⌘P pins.",
                              actions: [ClipboardShell.Action.open]),
            shortcuts.errorLabel
        ]
    }

    override func paneWillAppear() {
        enabledSwitch.state = services.core.setting(.clipboardEnabled, default: true) ? .on : .off
        let days = services.core.setting(.clipboardKeepDays, default: 30)
        keepFor.selectItem(at: Self.days.firstIndex { $0.0 >= days } ?? 2)
        let count = services.core.setting(.clipboardMaxItems, default: 500)
        atMost.selectItem(at: Self.counts.firstIndex { $0 >= count } ?? 1)
        shortcuts.refresh()
    }

    @objc private func toggleEnabled() { try? services.core.setSetting(.clipboardEnabled, enabledSwitch.state == .on) }

    @objc private func changeDays() {
        try? services.core.setSetting(.clipboardKeepDays, Self.days[keepFor.indexOfSelectedItem].0)
        _ = try? services.core.call(.clipboardPrune)
        ClipboardShell.images.removeUnused(core: services.core, collections: [.clipboardItems, .clipboardPinned])
    }

    @objc private func changeCount() {
        try? services.core.setSetting(.clipboardMaxItems, Self.counts[atMost.indexOfSelectedItem])
        _ = try? services.core.call(.clipboardPrune)
        ClipboardShell.images.removeUnused(core: services.core, collections: [.clipboardItems, .clipboardPinned])
    }

    @objc private func clearHistory() {
        let alert = NSAlert()
        alert.messageText = "Clear clipboard history?"
        alert.informativeText = "Every kept copy is removed; pinned entries and what’s on the clipboard now stay."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard let window = view.window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            guard let services = self?.services else { return }
            _ = try? services.core.clearRecords(.clipboardItems)
            ClipboardShell.images.removeUnused(core: services.core, collections: [.clipboardItems, .clipboardPinned])
        }
    }
}
