import AppKit

/// Translate's Settings tab: target language and history.
@MainActor
final class TranslatePane: SettingsPane, NSComboBoxDelegate {
    private let services: CopilotServices
    private let openHistory: () -> Void
    private let language = NSComboBox()
    private let message = Design.wrapping("", size: 11.5, color: .systemRed)

    init(services: CopilotServices, openHistory: @escaping () -> Void) {
        self.services = services
        self.openHistory = openHistory
        super.init(id: "translate", title: "Translate", symbol: "character.bubble")
    }

    required init?(coder: NSCoder) { fatalError("Use init(services:openHistory:)") }

    override func makeSections() -> [NSView] {
        language.addItems(withObjectValues: (try? services.core.call("translate.languages") as? [String]) ?? [])
        language.completes = true
        language.numberOfVisibleItems = 12
        language.delegate = self
        language.target = self
        language.action = #selector(commitLanguage)
        language.widthAnchor.constraint(equalToConstant: 220).isActive = true
        message.isHidden = true

        let open = Design.button("Open History", target: self, action: #selector(showHistory))
        let clear = Design.button("Clear…", target: self, action: #selector(clearHistory))
        return [
            FormSection("Translation", footer: "Pick a language or type any other, such as “Brazilian Portuguese” or “formal Japanese”.",
                        rows: [FormRow("Translate into", accessory: language)]),
            message,
            FormSection("History",
                        footer: "Every translation is saved on this Mac so you can copy it again. Your original text is never stored.",
                        rows: [FormRow("Saved translations", accessory: Design.hstack([clear, open]))])
        ]
    }

    override func paneWillAppear() {
        language.stringValue = services.core.setting("translate.target_language", default: "English")
        message.isHidden = true
    }

    func comboBoxSelectionDidChange(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in self?.commitLanguage() }
    }

    func controlTextDidEndEditing(_ obj: Notification) { commitLanguage() }

    @objc private func commitLanguage() {
        let value = language.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try services.core.setSetting("translate.target_language", value)
            message.isHidden = true
        } catch {
            message.stringValue = error.localizedDescription
            message.isHidden = false
        }
    }

    @objc private func showHistory() { openHistory() }

    @objc private func clearHistory() {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "Clear translation history?"
        alert.informativeText = "All saved translations will be permanently removed from this Mac."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear History").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            _ = try? self?.services.core.call("records.clear", ["collection": "translate.history"])
        }
    }
}
