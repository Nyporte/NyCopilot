import AppKit

/// The shared model provider: endpoint, model, key, and a one-click connection test.
@MainActor
final class ModelPane: SettingsPane, NSTextFieldDelegate {
    private let services: CopilotServices
    private let endpoint = NSTextField()
    private let model = NSTextField()
    private let key = NSSecureTextField()
    private let removeKey = NSButton()
    private let status = StatusLine()
    private let testButton = Design.button("Test Connection", target: nil, action: nil)
    private let saveButton = Design.button("Save", target: nil, action: nil, primary: true)
    private var hasSavedKey = false
    private var removingKey = false
    private var test: Task<Void, Never>?

    init(services: CopilotServices) {
        self.services = services
        super.init(id: "model", title: "Model", symbol: "cpu")
    }

    required init?(coder: NSCoder) { fatalError("Use init(services:)") }

    override func makeSections() -> [NSView] {
        for (field, placeholder) in [(endpoint, "https://api.example.com/v1/chat/completions"),
                                     (model, "e.g. gpt-4o-mini, claude-sonnet-4-5, llama3.1")] as [(NSTextField, String)] {
            field.placeholderString = placeholder
            field.delegate = self
            field.lineBreakMode = .byTruncatingTail
            field.widthAnchor.constraint(equalToConstant: 300).isActive = true
        }
        key.delegate = self
        key.widthAnchor.constraint(equalToConstant: 300).isActive = true
        removeKey.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "Remove saved key")
        removeKey.isBordered = false
        removeKey.contentTintColor = .secondaryLabelColor
        removeKey.toolTip = "Remove the saved API key"
        removeKey.target = self
        removeKey.action = #selector(removeSavedKey)

        testButton.target = self
        testButton.action = #selector(testConnection)
        saveButton.target = self
        saveButton.action = #selector(save)

        let connection = FormSection("Connection",
            footer: "Works with any OpenAI-compatible Chat Completions endpoint — hosted providers or local servers such as Ollama and LM Studio. The API key is optional and stored only in your Keychain.",
            rows: [
                FormRow("Endpoint URL", accessory: endpoint),
                FormRow("Model ID", accessory: model),
                FormRow("API key", accessory: Design.hstack([removeKey, key], spacing: 6))
            ])
        let bar = Design.hstack([status, Design.spacer(), testButton, saveButton], spacing: 8)
        return [connection, bar]
    }

    override func paneWillAppear() {
        let provider = services.preferences.provider
        endpoint.stringValue = provider.endpoint
        model.stringValue = provider.model
        key.stringValue = ""
        hasSavedKey = KeychainStore.hasKey()
        removingKey = false
        refreshKeyField()
        status.show(provider.isComplete ? nil : services.preferences.canTranslate
                    ? "Optional while another translation engine is set up: the model takes over when it fails or a language needs the model."
                    : "Add an endpoint and model to start using NyCopilot.", style: .info)
        updateButtons()
    }

    func controlTextDidChange(_ notification: Notification) { updateButtons() }

    private var draft: Preferences.Provider {
        Preferences.Provider(endpoint: endpoint.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                             model: model.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    private var isDirty: Bool { draft != services.preferences.provider || !key.stringValue.isEmpty || removingKey }

    private func updateButtons() {
        saveButton.isEnabled = isDirty
        testButton.isEnabled = draft.isComplete && test == nil
    }

    private func refreshKeyField() {
        key.placeholderString = hasSavedKey && !removingKey ? "Saved in Keychain — type to replace" : "Optional for local servers"
        removeKey.isHidden = !hasSavedKey || removingKey
    }

    @objc private func removeSavedKey() {
        removingKey = true
        key.stringValue = ""
        refreshKeyField()
        status.show("The saved key will be removed when you click Save.", style: .info)
        updateButtons()
    }

    @objc private func save() {
        do {
            if key.stringValue.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
                throw NyCore.Failure(code: "invalid_key", message: "The API key can’t contain line breaks or control characters.", status: nil)
            }
            try services.preferences.setProvider(draft)
            if !key.stringValue.isEmpty {
                try KeychainStore.write(key.stringValue)
            } else if removingKey {
                try KeychainStore.write("")
            }
        } catch {
            status.show(error.localizedDescription, style: .error)
            return
        }
        hasSavedKey = KeychainStore.hasKey()
        removingKey = false
        key.stringValue = ""
        refreshKeyField()
        status.show("Saved.", style: .success)
        updateButtons()
    }

    /// Sends one tiny request with the values on screen, so a setup can be checked before saving.
    @objc private func testConnection() {
        let configuration = draft
        let typedKey = key.stringValue
        let removing = removingKey
        status.showProgress("Connecting…")
        let core = services.core
        struct Timing: Decodable { let elapsedMs: Int }
        test = Task { [weak self] in
            let outcome: Result<Timing, Error>
            do {
                let apiKey = typedKey.isEmpty && !removing ? try KeychainStore.read() : typedKey
                outcome = .success(try await core.perform("llm.test", ["endpoint": configuration.endpoint, "model": configuration.model,
                                                                       "api_key": apiKey], as: Timing.self))
            } catch { outcome = .failure(error) }
            guard let self else { return }
            test = nil
            switch outcome {
            case .success(let timing):
                let seconds = String(format: "%.1f", Double(timing.elapsedMs) / 1000)
                status.show("Connected — \(configuration.model) replied in \(seconds) s.", style: .success)
            case .failure(let error):
                status.show(error.localizedDescription, style: .error)
            }
            updateButtons()
        }
        updateButtons()
    }
}
