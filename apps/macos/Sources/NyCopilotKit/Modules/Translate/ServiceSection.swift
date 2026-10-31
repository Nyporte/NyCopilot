import AppKit

/// A translation service's settings: one plain field (a URL or an App ID), a secret kept only in the
/// Keychain, and a Test that translates a short sample with the values on screen.
@MainActor
final class ServiceSection: NSObject, NSTextFieldDelegate {
    struct Spec {
        let title: String
        let footer: String
        let fieldLabel: String
        let fieldPlaceholder: String
        let setting: SettingKey
        let keyLabel: String
        let keyPlaceholder: String
        let keychain: KeychainStore.Item
        /// Whether a test can run with this field value and whether a key is available.
        let isTestable: (_ field: String, _ hasKey: Bool) -> Bool
        /// The core method and parameters that translate the sample.
        let test: (_ field: String, _ key: String) -> (method: CoreMethod, params: [String: Any])
    }

    /// Saved values changed, so engine statuses may have too.
    var onSave: (() -> Void)?

    private let spec: Spec
    private let services: CopilotServices
    private let field = NSTextField()
    private let key = NSSecureTextField()
    private let removeKey = NSButton()
    private let status = StatusLine()
    private let testButton = Design.button("Test", target: nil, action: nil)
    private let saveButton = Design.button("Save", target: nil, action: nil, primary: true)
    private var hasSavedKey = false
    private var removingKey = false
    private var test: Task<Void, Never>?

    init(_ spec: Spec, services: CopilotServices) {
        self.spec = spec
        self.services = services
        super.init()
    }

    func makeViews() -> [NSView] {
        field.placeholderString = spec.fieldPlaceholder
        field.lineBreakMode = .byTruncatingMiddle
        for control in [field, key] {
            control.delegate = self
            control.widthAnchor.constraint(equalToConstant: 300).isActive = true
        }
        removeKey.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "Remove saved key")
        removeKey.isBordered = false
        removeKey.contentTintColor = .secondaryLabelColor
        removeKey.toolTip = "Remove the saved key"
        removeKey.target = self
        removeKey.action = #selector(removeSavedKey)
        testButton.target = self
        testButton.action = #selector(runTest)
        saveButton.target = self
        saveButton.action = #selector(save)
        let section = FormSection(spec.title, footer: spec.footer, rows: [
            FormRow(spec.fieldLabel, accessory: field),
            FormRow(spec.keyLabel, accessory: Design.hstack([removeKey, key], spacing: 6))
        ])
        return [section, Design.hstack([status, Design.spacer(), testButton, saveButton], spacing: 8)]
    }

    func refresh() {
        field.stringValue = savedField
        key.stringValue = ""
        hasSavedKey = KeychainStore.hasKey(spec.keychain)
        removingKey = false
        refreshKeyField()
        status.show(nil, style: .info)
        updateButtons()
    }

    private var savedField: String { services.core.setting(spec.setting, default: "") }
    private var draftField: String { field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var keyAvailable: Bool { !key.stringValue.isEmpty || (hasSavedKey && !removingKey) }

    func controlTextDidChange(_ notification: Notification) { updateButtons() }

    private func updateButtons() {
        saveButton.isEnabled = draftField != savedField || !key.stringValue.isEmpty || removingKey
        testButton.isEnabled = spec.isTestable(draftField, keyAvailable) && test == nil
    }

    private func refreshKeyField() {
        key.placeholderString = hasSavedKey && !removingKey ? "Saved in Keychain — type to replace" : spec.keyPlaceholder
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
                throw NyCore.Failure(code: "invalid_key", message: "The key can’t contain line breaks or control characters.", status: nil)
            }
            try services.core.setSetting(spec.setting, draftField)
            if !key.stringValue.isEmpty {
                try KeychainStore.write(key.stringValue, for: spec.keychain)
            } else if removingKey {
                try KeychainStore.write("", for: spec.keychain)
            }
        } catch {
            status.show(error.localizedDescription, style: .error)
            return
        }
        hasSavedKey = KeychainStore.hasKey(spec.keychain)
        removingKey = false
        key.stringValue = ""
        refreshKeyField()
        status.show("Saved.", style: .success)
        updateButtons()
        onSave?()
    }

    /// Translates "Hello, world." into Chinese with the values on screen, before or after saving.
    @objc private func runTest() {
        let fieldValue = draftField
        let typedKey = key.stringValue
        let removing = removingKey
        let spec = spec
        status.showProgress("Translating a sample…")
        let core = services.core
        struct Sample: Decodable { let text: String; let elapsedMs: Int }
        test = Task { [weak self] in
            let outcome: Result<Sample, Error>
            do {
                let secret = typedKey.isEmpty && !removing ? try KeychainStore.read(spec.keychain) : typedKey
                let call = spec.test(fieldValue, secret)
                outcome = .success(try await core.perform(call.method, call.params, as: Sample.self))
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

extension ServiceSection.Spec {
    static let google = ServiceSection.Spec(
        title: "Google Translate",
        footer: "Runs through your own Apps Script web app. Deploy it with “Execute as: Me” and “Who has access: Anyone”; with any other access setting, requests land on Google’s sign-in page. The key is stored only in your Keychain.",
        fieldLabel: "Web app URL", fieldPlaceholder: "https://script.google.com/macros/s/…/exec", setting: .googleURL,
        keyLabel: "Access key", keyPlaceholder: "The key your script checks", keychain: .google,
        isTestable: { url, _ in !url.isEmpty },
        test: { url, key in (.translateTestGoogle, ["url": url, "key": key]) })

    static let volcengine = ServiceSection.Spec(
        title: "Volcengine",
        footer: "Doubao machine translation (volc.speech.mt), 32 languages. Paste the API key from the new Volcengine console, or, for old-console credentials, the App ID and access token. The key is stored only in your Keychain.",
        fieldLabel: "App ID (old console only)", fieldPlaceholder: "Leave empty with an API key", setting: .volcengineAppID,
        keyLabel: "API key or access token", keyPlaceholder: "From the Volcengine console", keychain: .volcengine,
        isTestable: { _, hasKey in hasKey },
        test: { appID, key in (.translateTestVolcengine, ["app_id": appID, "key": key]) })
}
