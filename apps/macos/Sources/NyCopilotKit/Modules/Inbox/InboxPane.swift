import AppKit

/// Inbox settings: the shortcuts, the Markdown folder notes are sent to, and clearing everything.
@MainActor
final class InboxPane: SettingsPane {
    private let services: CopilotServices
    private lazy var shortcuts = ShortcutEditor(services: services)
    private let clearButton = Design.button(L("Clear Inbox…"), target: nil, action: nil)
    private let folderButton = Design.button(L("Choose…"), target: nil, action: nil)
    private let folderLabel = Design.label("", size: 12, color: .secondaryLabelColor)

    init(services: CopilotServices) {
        self.services = services
        super.init(id: "inbox", title: L("Inbox"), symbol: "tray")
    }

    required init?(coder: NSCoder) { fatalError("Use init(services:)") }

    override func makeSections() -> [NSView] {
        clearButton.target = self
        clearButton.action = #selector(clearAll)
        folderButton.target = self
        folderButton.action = #selector(chooseFolder)
        folderLabel.lineBreakMode = .byTruncatingMiddle
        folderLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        showFolder()
        return [
            shortcuts.section(L("Shortcuts"), footer: L("With text selected in any app, the first shortcut keeps it in the inbox; otherwise it opens a bar to jot into. In a screenshot, I sends the capture."),
                              actions: [InboxShell.Action.capture, InboxShell.Action.open]),
            shortcuts.errorLabel,
            FormSection(L("Send To"), footer: L("S on a note in the inbox sends it to Reminders, Notes, or this folder as a Markdown file (an Obsidian vault works well), then marks it done. L snoozes it until later."), rows: [
                FormRow(L("Markdown folder"), accessory: Design.hstack([folderLabel, folderButton], spacing: 8))
            ]),
            FormSection(L("Notes"), footer: L("Notes and their screenshots stay on this Mac. Done notes are kept for 30 days."), rows: [
                FormRow(L("Remove every note, waiting and done"), accessory: clearButton)
            ])
        ]
    }

    override func paneWillAppear() {
        shortcuts.refresh()
        showFolder()
    }

    private func showFolder() {
        let folder = NoteExport.markdownFolder(core: services.core, choosingIfNeeded: false)
        folderLabel.stringValue = folder.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? L("Not chosen")
        folderLabel.toolTip = folder?.path
    }

    @objc private func chooseFolder() {
        NoteExport.chooseMarkdownFolder(core: services.core)
        showFolder()
    }

    @objc private func clearAll() {
        confirmDestructive(L("Clear the inbox?"), detail: L("Every note, waiting and done, and its screenshot is removed."),
                           button: L("Clear")) { [weak self] in
            guard let core = self?.services.core else { return }
            for collection in [CoreCollection.inboxNotes, .inboxDone, .inboxSnoozed] { _ = try? core.clearRecords(collection) }
            InboxShell.images.removeAll()
        }
    }
}
