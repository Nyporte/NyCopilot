import AppKit

/// Clipboard settings: whether copies are kept, for how long, how many, and the shortcut.
@MainActor
final class ClipboardPane: SettingsPane {
    private let services: CopilotServices
    private let enabledSwitch = NSSwitch()
    private let keepFor = NSPopUpButton()
    private let atMost = NSPopUpButton()
    private let clearButton = Design.button(L("Clear History…"), target: nil, action: nil)
    private lazy var shortcuts = ShortcutEditor(services: services)
    private static let days = [(1, DateComponents(day: 1)), (7, DateComponents(weekOfMonth: 1)), (30, DateComponents(day: 30)),
                                (90, DateComponents(day: 90)), (365, DateComponents(year: 1))]
        .map { ($0.0, ClipboardPane.duration.string(from: $0.1) ?? "\($0.0)") }
    private static let duration: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()
    private static let counts = [100, 500, 1000, 5000]

    init(services: CopilotServices) {
        self.services = services
        super.init(id: "clipboard", title: L("Clipboard"), symbol: "doc.on.clipboard")
    }

    required init?(coder: NSCoder) { fatalError("Use init(services:)") }

    override func makeSections() -> [NSView] {
        enabledSwitch.target = self
        enabledSwitch.action = #selector(toggleEnabled)
        keepFor.addItems(withTitles: Self.days.map(\.1))
        keepFor.target = self
        keepFor.action = #selector(changeDays)
        atMost.addItems(withTitles: Self.counts.map { L("%ld entries", $0) })
        atMost.target = self
        atMost.action = #selector(changeCount)
        clearButton.target = self
        clearButton.action = #selector(clearHistory)
        return [
            FormSection(L("History"), footer: L("Copies — text and images — stay on this Mac. Pinned entries (⌘P in the list) are kept until you unpin them. Passwords and anything an app marks private are never kept, nor copies from password managers."), rows: [
                FormRow(L("Keep clipboard history"), subtitle: L("Text and images you copy, newest first; copying it again moves it to the top."), accessory: enabledSwitch),
                FormRow(L("Keep entries for"), accessory: keepFor),
                FormRow(L("Keep at most"), accessory: atMost),
                FormRow(L("Forget everything"), accessory: clearButton)
            ]),
            shortcuts.section(L("Shortcuts"), footer: L("Type to search, ↩ pastes into the app you were in, ⌘1–9 picks one of the first nine, ⌘P pins."),
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
        services.core.clipboardPrune()
        ClipboardShell.removeUnusedImages(core: services.core)
    }

    @objc private func changeCount() {
        try? services.core.setSetting(.clipboardMaxItems, Self.counts[atMost.indexOfSelectedItem])
        services.core.clipboardPrune()
        ClipboardShell.removeUnusedImages(core: services.core)
    }

    @objc private func clearHistory() {
        confirmDestructive(L("Clear clipboard history?"), detail: L("Every kept copy is removed; pinned entries and what’s on the clipboard now stay."),
                           button: L("Clear")) { [weak self] in
            guard let core = self?.services.core else { return }
            _ = try? core.clearRecords(.clipboardItems)
            // Cleared means gone, however recent.
            ClipboardShell.removeUnusedImages(core: core, graceSeconds: 0)
        }
    }
}
