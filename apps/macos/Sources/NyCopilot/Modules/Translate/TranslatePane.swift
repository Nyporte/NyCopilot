import AppKit

/// Translate's Settings tab: favorite languages, model instructions, shortcuts, and history.
@MainActor
final class TranslatePane: SettingsPane, NSTokenFieldDelegate, NSTextViewDelegate {
    private let services: CopilotServices
    private let openHistory: () -> Void
    /// Tokens hold language names (English); they display in each language's own script.
    private let favorites = NSTokenField()
    private var suggestions: [(name: String, native: String)] = []
    private var savedFavorites: [String] = []
    private let message = Design.wrapping("", size: 11.5, color: .systemRed)
    private let instructions = NSTextView()
    private let instructionsStatus = Design.label("", size: 11.5, color: .secondaryLabelColor)
    private let restoreButton = Design.button("Restore Default", target: nil, action: nil)
    private let saveButton = Design.button("Save Instructions", target: nil, action: nil)
    private var savedInstructions = ""
    private lazy var defaultInstructions = Self.defaultInstructions(services.core)
    private lazy var shortcuts = ShortcutEditor(services: services)

    init(services: CopilotServices, openHistory: @escaping () -> Void) {
        self.services = services
        self.openHistory = openHistory
        super.init(id: "translate", title: "Translate", symbol: "character.bubble")
    }

    required init?(coder: NSCoder) { fatalError("Use init(services:openHistory:)") }

    override func makeSections() -> [NSView] {
        struct Suggestion: Decodable { let name: String; let native: String }
        suggestions = ((try? services.core.call("translate.languages", as: [Suggestion].self)) ?? []).map { ($0.name, $0.native) }
        favorites.delegate = self
        favorites.tokenStyle = .rounded
        favorites.completionDelay = 0
        favorites.placeholderString = "English, Japanese…"
        favorites.cell?.wraps = true
        favorites.widthAnchor.constraint(equalToConstant: 300).isActive = true
        message.isHidden = true

        let open = Design.button("Open History", target: self, action: #selector(showHistory))
        let clear = Design.button("Clear…", target: self, action: #selector(clearHistory))
        restoreButton.target = self
        restoreButton.action = #selector(restoreInstructions)
        saveButton.target = self
        saveButton.action = #selector(saveInstructions)
        let instructionsBar = Design.hstack([instructionsStatus, Design.spacer(), restoreButton, saveButton])
        return [
            FormSection("Languages",
                        footer: "In the translate box, Tab steps through these in order and Shift+Tab goes back. Type any language, such as “Brazilian Portuguese” or “formal Japanese”.",
                        rows: [FormRow("Favorite languages", accessory: favorites)]),
            message,
            FormSection("Instructions",
                        footer: "Sent to the model with every translation. {language} becomes the target language. Your text is always sent separately, never inside these instructions.",
                        rows: [makeEditor()]),
            instructionsBar,
            shortcuts.section("Shortcuts", footer: "Click a shortcut and press a new combination. Press Delete to turn it off.",
                              actions: ["translate.compose", "translate.history"]),
            shortcuts.errorLabel,
            FormSection("History",
                        footer: "Every translation is saved on this Mac so you can copy it again. Your original text is never stored.",
                        rows: [FormRow("Saved translations", accessory: Design.hstack([clear, open]))])
        ]
    }

    override func paneWillAppear() {
        savedFavorites = (try? services.core.call("settings.get", ["key": "translate.favorite_languages"]) as? [String]) ?? []
        favorites.objectValue = savedFavorites
        message.isHidden = true
        loadInstructions()
        shortcuts.refresh()
    }

    /// A plain-text editor sized for a short prompt; longer prompts scroll.
    private func makeEditor() -> NSView {
        instructions.isRichText = false
        instructions.allowsUndo = true
        instructions.font = .systemFont(ofSize: 12.5)
        instructions.textColor = .labelColor
        instructions.drawsBackground = false
        instructions.isAutomaticQuoteSubstitutionEnabled = false
        instructions.isAutomaticDashSubstitutionEnabled = false
        instructions.isAutomaticTextReplacementEnabled = false
        instructions.isAutomaticSpellingCorrectionEnabled = false
        instructions.textContainerInset = NSSize(width: 0, height: 4)
        instructions.textContainer?.lineFragmentPadding = 0
        instructions.autoresizingMask = [.width]
        instructions.isVerticallyResizable = true
        instructions.textContainer?.widthTracksTextView = true
        instructions.delegate = self
        instructions.setAccessibilityLabel("Translation instructions")
        let scroll = NSScrollView()
        scroll.documentView = instructions
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let row = NSView()
        row.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -8),
            scroll.topAnchor.constraint(equalTo: row.topAnchor, constant: 8),
            scroll.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -8),
            scroll.heightAnchor.constraint(equalToConstant: 132)
        ])
        return row
    }

    private func loadInstructions() {
        savedInstructions = services.core.setting("translate.instructions", default: "")
        instructions.string = savedInstructions
        instructionsStatus.stringValue = ""
        updateInstructionButtons()
    }

    private func updateInstructionButtons() {
        let edited = instructions.string != savedInstructions
        saveButton.isEnabled = edited
        restoreButton.isEnabled = edited || savedInstructions != defaultInstructions
        if edited {
            instructionsStatus.stringValue = "Unsaved changes"
            instructionsStatus.textColor = .secondaryLabelColor
        }
    }

    func textDidChange(_ notification: Notification) {
        guard (notification.object as? NSTextView) === instructions else { return }
        updateInstructionButtons()
    }

    @objc private func saveInstructions() {
        do {
            try services.core.setSetting("translate.instructions", instructions.string)
            savedInstructions = services.core.setting("translate.instructions", default: "")
            instructionsStatus.stringValue = instructions.string.contains("{language}")
                ? "Saved" : "Saved — without {language}, the target language setting is ignored"
            instructionsStatus.textColor = instructions.string.contains("{language}") ? .secondaryLabelColor : .systemOrange
        } catch {
            instructionsStatus.stringValue = error.localizedDescription
            instructionsStatus.textColor = .systemRed
        }
        updateInstructionButtons()
    }

    @objc private func restoreInstructions() {
        _ = try? services.core.call("settings.reset", ["key": "translate.instructions"])
        loadInstructions()
        instructionsStatus.stringValue = "Default instructions restored"
    }

    /// The manifest default, so "Restore Default" can tell whether anything differs from it.
    private static func defaultInstructions(_ core: NyCore) -> String {
        guard let modules = try? core.call("core.modules") as? [[String: Any]],
              let translate = modules.first(where: { $0["id"] as? String == "translate" }),
              let settings = translate["settings"] as? [[String: Any]],
              let spec = settings.first(where: { $0["key"] as? String == "translate.instructions" }) else { return "" }
        return spec["default"] as? String ?? ""
    }

    func tokenField(_ tokenField: NSTokenField, completionsForSubstring substring: String,
                    indexOfToken tokenIndex: Int, indexOfSelectedItem selectedIndex: UnsafeMutablePointer<Int>?) -> [Any]? {
        let query = substring.lowercased()
        return suggestions.filter { $0.name.lowercased().hasPrefix(query) || $0.native.lowercased().hasPrefix(query) }.map(\.name)
    }

    func tokenField(_ tokenField: NSTokenField, displayStringForRepresentedObject representedObject: Any) -> String? {
        guard let name = representedObject as? String else { return nil }
        return suggestions.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.native ?? name
    }

    func tokenField(_ tokenField: NSTokenField, representedObjectForEditing editingString: String) -> Any? {
        let trimmed = editingString.trimmingCharacters(in: .whitespacesAndNewlines)
        // Typing a language's own name (日本語) stores its English name, like picking a suggestion.
        return suggestions.first { $0.native == trimmed || $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }?.name ?? trimmed
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard (obj.object as? NSTokenField) === favorites else { return }
        let names = (favorites.objectValue as? [Any] ?? []).compactMap { $0 as? String }.filter { !$0.isEmpty }
        guard names != savedFavorites else { return }
        do {
            try services.core.setSetting("translate.favorite_languages", names)
            savedFavorites = names
            message.isHidden = true
        } catch {
            message.stringValue = error.localizedDescription
            message.isHidden = false
            favorites.objectValue = savedFavorites
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
