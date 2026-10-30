import AppKit

/// Settings → Translate → Google Translate: the on/off switch, the Apps Script web app URL, its access
/// key (Keychain only), and a test that translates a short sample with the values on screen.
@MainActor
final class GoogleSection: NSObject, NSTextFieldDelegate {
    private let services: CopilotServices
    private let enabled = NSSwitch()
    private let url = NSTextField()
    private let key = NSSecureTextField()
    private let removeKey = NSButton()
    private let status = StatusLine()
    private let testButton = Design.button("Test", target: nil, action: nil)
    private let saveButton = Design.button("Save", target: nil, action: nil, primary: true)
    private var hasSavedKey = false
    private var removingKey = false
    private var test: Task<Void, Never>?

    init(services: CopilotServices) {
        self.services = services
        super.init()
    }

    func makeViews() -> [NSView] {
        enabled.target = self
        enabled.action = #selector(toggle)
        url.placeholderString = "https://script.google.com/macros/s/…/exec"
        url.lineBreakMode = .byTruncatingMiddle
        for field in [url, key] {
            field.delegate = self
            field.widthAnchor.constraint(equalToConstant: 300).isActive = true
        }
        removeKey.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "Remove saved key")
        removeKey.isBordered = false
        removeKey.contentTintColor = .secondaryLabelColor
        removeKey.toolTip = "Remove the saved access key"
        removeKey.target = self
        removeKey.action = #selector(removeSavedKey)
        testButton.target = self
        testButton.action = #selector(runTest)
        saveButton.target = self
        saveButton.action = #selector(save)
        let section = FormSection("Google Translate",
            footer: "Translates through your own Apps Script web app first, and falls back to the model when Google fails or a language needs the model (such as “formal Japanese”). Deploy the script with “Execute as: Me” and “Who has access: Anyone”. The key is stored only in your Keychain.",
            rows: [
                FormRow("Use Google Translate first", accessory: enabled),
                FormRow("Web app URL", accessory: url),
                FormRow("Access key", accessory: Design.hstack([removeKey, key], spacing: 6))
            ])
        return [section, Design.hstack([status, Design.spacer(), testButton, saveButton], spacing: 8)]
    }

    func refresh() {
        enabled.state = services.core.setting(.googleEnabled, default: true) ? .on : .off
        url.stringValue = savedURL
        key.stringValue = ""
        hasSavedKey = KeychainStore.hasKey(.google)
        removingKey = false
        refreshKeyField()
        status.show(nil, style: .info)
        updateButtons()
    }

    private var savedURL: String { services.core.setting(.googleURL, default: "") }
    private var draftURL: String { url.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }

    func controlTextDidChange(_ notification: Notification) { updateButtons() }

    private func updateButtons() {
        saveButton.isEnabled = draftURL != savedURL || !key.stringValue.isEmpty || removingKey
        testButton.isEnabled = !draftURL.isEmpty && test == nil
    }

    private func refreshKeyField() {
        key.placeholderString = hasSavedKey && !removingKey ? "Saved in Keychain — type to replace" : "The key your script checks"
        removeKey.isHidden = !hasSavedKey || removingKey
    }

    @objc private func toggle() {
        do { try services.core.setSetting(.googleEnabled, enabled.state == .on) } catch {
            enabled.state = enabled.state == .on ? .off : .on
        }
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
                throw NyCore.Failure(code: "invalid_key", message: "The key can’t contain line breaks or control characters.", status: nil)
            }
            try services.core.setSetting(.googleURL, draftURL)
            if !key.stringValue.isEmpty {
                try KeychainStore.write(key.stringValue, for: .google)
            } else if removingKey {
                try KeychainStore.write("", for: .google)
            }
        } catch {
            status.show(error.localizedDescription, style: .error)
            return
        }
        hasSavedKey = KeychainStore.hasKey(.google)
        removingKey = false
        key.stringValue = ""
        refreshKeyField()
        status.show(draftURL.isEmpty ? "Saved. Translations use the model only." : "Saved.", style: .success)
        updateButtons()
    }

    /// Translates "Hello, world." into Chinese with the values on screen, before or after saving.
    @objc private func runTest() {
        let target = draftURL
        let typedKey = key.stringValue
        let removing = removingKey
        status.showProgress("Asking Google…")
        let core = services.core
        struct Sample: Decodable { let text: String; let elapsedMs: Int }
        test = Task { [weak self] in
            let outcome: Result<Sample, Error>
            do {
                let accessKey = typedKey.isEmpty && !removing ? try KeychainStore.read(.google) : typedKey
                outcome = .success(try await core.perform("translate.test_google", ["url": target, "key": accessKey], as: Sample.self))
            } catch { outcome = .failure(error) }
            guard let self else { return }
            test = nil
            switch outcome {
            case .success(let sample):
                let seconds = String(format: "%.1f", Double(sample.elapsedMs) / 1000)
                status.show("Working — “Hello, world.” → “\(sample.text)” in \(seconds) s.", style: .success)
            case .failure(let error):
                status.show(error.localizedDescription, style: .error)
            }
            updateButtons()
        }
        updateButtons()
    }
}
