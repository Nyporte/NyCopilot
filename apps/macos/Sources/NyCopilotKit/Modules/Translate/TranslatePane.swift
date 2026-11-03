import AppKit

/// Translate's Settings tab: favorite languages, model instructions, shortcuts, and history. The
/// engines themselves are set up in AI & Engines.
@MainActor
final class TranslatePane: SettingsPane, NSTextViewDelegate {
    private let services: CopilotServices
    private let openHistory: () -> Void
    /// Tokens hold language names (English); they display in each language's own script.
    private let favorites = LanguageListEditor()
    private let trimSwitch = NSSwitch()
    private let instructions = NSTextView()
    private let instructionsStatus = Design.label("", size: 11.5, color: .secondaryLabelColor)
    private let restoreButton = Design.button(L("Restore Default"), target: nil, action: nil)
    private let saveButton = Design.button(L("Save Instructions"), target: nil, action: nil)
    private var savedInstructions = ""
    private lazy var defaultInstructions = Self.defaultInstructions(services.core)
    private lazy var shortcuts = ShortcutEditor(services: services)

    init(services: CopilotServices, openHistory: @escaping () -> Void) {
        self.services = services
        self.openHistory = openHistory
        super.init(id: "translate", title: L("Translate"), symbol: "character.bubble")
    }

    required init?(coder: NSCoder) { fatalError("Use init(services:openHistory:)") }

    override func makeSections() -> [NSView] {
        favorites.onChange = { [weak self] names in
            guard let self else { return nil }
            do { try services.core.setSetting(.favoriteLanguages, names); return nil }
            catch { return error.localizedDescription }
        }
        trimSwitch.target = self
        trimSwitch.action = #selector(toggleTrim)

        let open = Design.button(L("Open History"), target: self, action: #selector(showHistory))
        let clear = Design.button(L("Clear…"), target: self, action: #selector(clearHistory))
        restoreButton.target = self
        restoreButton.action = #selector(restoreInstructions)
        saveButton.target = self
        saveButton.action = #selector(saveInstructions)
        let instructionsBar = Design.hstack([instructionsStatus, Design.spacer(), restoreButton, saveButton])
        return [
            FormSection(L("Favorite Languages"),
                        footer: L("In the translate box, Tab steps through these in this order and Shift+Tab goes back. Use ▲ ▼ to change the order."),
                        rows: [favorites]),
            FormSection(L("Result"), rows: [
                FormRow(L("Trim spaces and line breaks"), subtitle: L("Removes them from the start and end of each translation."),
                        accessory: trimSwitch)
            ]),
            FormSection(L("Instructions"),
                        footer: L("Sent to the model (Settings → AI & Engines) with each translation it makes; the other engines don’t take instructions. {language} becomes the target language. Your text is always sent separately, never inside these instructions."),
                        rows: [makeEditor()]),
            instructionsBar,
            shortcuts.section(L("Shortcuts"), footer: L("Click a shortcut and press a new combination. Press Delete to turn it off. Hold the translate shortcut to highlight all the text on screen, then point at a block to read its translation; Esc ends it."),
                              actions: [TranslateShell.Action.compose, TranslateShell.Action.history]),
            shortcuts.errorLabel,
            FormSection(L("History"),
                        footer: L("Every translation is saved on this Mac so you can copy it again. Your original text is never stored."),
                        rows: [FormRow(L("Saved translations"), accessory: Design.hstack([clear, open]))])
        ]
    }

    override func paneWillAppear() {
        let core = services.core
        favorites.load(core.setting(.favoriteLanguages, default: [String]()), suggestions: core.languages(), describe: core.language)
        trimSwitch.state = services.core.setting(.trimWhitespace, default: true) ? .on : .off
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
        instructions.setAccessibilityLabel(L("Translation instructions"))
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
        savedInstructions = services.core.setting(.instructions, default: "")
        instructions.string = savedInstructions
        instructionsStatus.stringValue = ""
        updateInstructionButtons()
    }

    private func updateInstructionButtons() {
        let edited = instructions.string != savedInstructions
        saveButton.isEnabled = edited
        restoreButton.isEnabled = edited || savedInstructions != defaultInstructions
        if edited {
            instructionsStatus.stringValue = L("Unsaved changes")
            instructionsStatus.textColor = .secondaryLabelColor
        }
    }

    func textDidChange(_ notification: Notification) {
        guard (notification.object as? NSTextView) === instructions else { return }
        updateInstructionButtons()
    }

    @objc private func saveInstructions() {
        do {
            try services.core.setSetting(.instructions, instructions.string)
            savedInstructions = services.core.setting(.instructions, default: "")
            instructionsStatus.stringValue = instructions.string.contains("{language}")
                ? L("Saved") : L("Saved — without {language}, the target language setting is ignored")
            instructionsStatus.textColor = instructions.string.contains("{language}") ? .secondaryLabelColor : .systemOrange
        } catch {
            instructionsStatus.stringValue = error.localizedDescription
            instructionsStatus.textColor = .systemRed
        }
        updateInstructionButtons()
    }

    @objc private func restoreInstructions() {
        try? services.core.resetSetting(.instructions)
        loadInstructions()
        instructionsStatus.stringValue = L("Default instructions restored")
    }

    /// The manifest default, so "Restore Default" can tell whether anything differs from it.
    private static func defaultInstructions(_ core: NyCore) -> String {
        guard let modules = try? core.call(.coreModules) as? [[String: Any]],
              let translate = modules.first(where: { $0["id"] as? String == "translate" }),
              let settings = translate["settings"] as? [[String: Any]],
              let spec = settings.first(where: { $0["key"] as? String == SettingKey.instructions.rawValue }) else { return "" }
        return spec["default"] as? String ?? ""
    }

    @objc private func toggleTrim() {
        do { try services.core.setSetting(.trimWhitespace, trimSwitch.state == .on) } catch {
            trimSwitch.state = trimSwitch.state == .on ? .off : .on
        }
    }

    @objc private func showHistory() { openHistory() }

    @objc private func clearHistory() {
        confirmDestructive(L("Clear translation history?"), detail: L("All saved translations will be permanently removed from this Mac."),
                           button: L("Clear History")) { [weak self] in
            _ = try? self?.services.core.clearRecords(.translateHistory)
        }
    }
}
