import AppKit

/// Permissions and startup. Each module lists its own shortcuts in its own tab.
@MainActor
final class GeneralPane: SettingsPane {
    private let services: CopilotServices
    private let accessBadge = StatusBadge()
    private let accessButton = Design.button(L("Open System Settings…"), target: nil, action: nil)
    private let recordingBadge = StatusBadge()
    private let recordingButton = Design.button(L("Open System Settings…"), target: nil, action: nil)
    private let diagnosticsButton = Design.button(L("Copy Diagnostics"), target: nil, action: nil)
    private let captureServiceButton = Design.button(L("Restart"), target: nil, action: nil)
    private let loginSwitch = NSSwitch()
    private let languagePopup = NSPopUpButton()
    private let restartButton = Design.button(L("Restart Now"), target: nil, action: nil)
    private let loginNote = Design.wrapping("", size: 11.5)
    private var poll: Timer?
    private lazy var shortcuts = ShortcutEditor(services: services)
    private var moduleSwitches: [(id: String, toggle: NSSwitch)] = []

    init(services: CopilotServices) {
        self.services = services
        super.init(id: "general", title: L("General"), symbol: "gearshape")
    }

    required init?(coder: NSCoder) { fatalError("Use init(services:)") }

    override func makeSections() -> [NSView] {
        accessButton.target = self
        accessButton.action = #selector(requestAccess)
        let access = FormRow(L("Accessibility"), subtitle: L("Lets NyCopilot read and paste into text fields, and move other apps’ windows."),
                             accessory: Design.hstack([accessBadge, accessButton], spacing: 12))

        recordingButton.target = self
        recordingButton.action = #selector(requestRecording)
        let recording = FormRow(L("Screen Recording"), subtitle: L("Lets NyCopilot take screenshots and translate what’s on screen."),
                                accessory: Design.hstack([recordingBadge, recordingButton], spacing: 12))
        diagnosticsButton.target = self
        diagnosticsButton.action = #selector(copyDiagnostics)
        let diagnostics = FormRow(L("Diagnostics"), subtitle: L("What NyCopilot did lately — fields it found, pastes, errors — without any of your text. Paste it into a bug report."),
                                  accessory: diagnosticsButton)

        captureServiceButton.target = self
        captureServiceButton.action = #selector(restartCaptureService)
        let captureService = FormRow(L("Screen capture service"), subtitle: L("If the screen-recording indicator stays on after a capture, macOS kept it running; restarting its capture service ends it."),
                                     accessory: captureServiceButton)

        loginSwitch.target = self
        loginSwitch.action = #selector(toggleLogin)
        loginNote.isHidden = true
        let login = FormRow(L("Open at login"), subtitle: nil, accessory: loginSwitch)

        languagePopup.addItem(withTitle: L("System — %@", InterfaceLanguage.name(of: InterfaceLanguage.system)))
        languagePopup.menu?.addItem(.separator())
        for language in InterfaceLanguage.available {
            languagePopup.addItem(withTitle: language.name)
            languagePopup.lastItem?.representedObject = language.code
        }
        languagePopup.target = self
        languagePopup.action = #selector(changeLanguage)
        restartButton.target = self
        restartButton.action = #selector(restartApp)
        let language = FormRow(L("Language"), subtitle: L("NyCopilot’s menus, settings, and messages. A new language takes effect when NyCopilot restarts."),
                               accessory: Design.hstack([restartButton, languagePopup], spacing: 8))

        moduleSwitches = services.moduleList().map { module in
            let toggle = NSSwitch()
            toggle.target = self
            toggle.action = #selector(toggleModule(_:))
            toggle.identifier = NSUserInterfaceItemIdentifier(module.id)
            return (module.id, toggle)
        }
        let modules = FormSection(L("Features"), footer: L("A feature that’s off keeps its settings; its shortcuts and menu items come back when you turn it on."),
                                  rows: zip(services.moduleList(), moduleSwitches).map { module, entry in
                                      FormRow(module.title, accessory: entry.toggle)
                                  })
        let guide = Design.button(L("Show Setup Guide…"), target: self, action: #selector(showGuide))
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–"
        return [
            FormSection(L("Permissions"), rows: [access, recording]),
            modules,
            FormSection(L("Startup"), rows: [language, login]),
            // Under the login switch it's about.
            loginNote,
            shortcuts.section(L("Shortcuts"), footer: L("Shows every shortcut, and the keys that work on anything you capture or keep. On any surface, ? (or ⌘/ where you type) shows its own keys."),
                              actions: [AppDelegate.showShortcutsAction]),
            shortcuts.errorLabel,
            FormSection(L("Troubleshooting"), rows: [diagnostics, captureService]),
            Design.hstack([Design.label("NyCopilot \(version)", size: 12, color: .tertiaryLabelColor), Design.spacer(), guide])
        ]
    }

    override func paneWillAppear() {
        shortcuts.refresh()
        for entry in moduleSwitches { entry.toggle.state = services.isModuleOn(entry.id) ? .on : .off }
        refreshAccess()
        showLanguage()
        loginSwitch.state = LaunchAtLogin.isEnabled || LaunchAtLogin.needsApproval ? .on : .off
        showLoginNote()
        // Permission is granted in another app; re-check while this pane is on screen.
        poll?.invalidate()
        poll = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.view.window?.isVisible == true else { self?.poll?.invalidate(); return }
                self.refreshAccess()
            }
        }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        poll?.invalidate()
    }

    private func refreshAccess() {
        let trusted = Accessibility.isTrusted
        accessBadge.set(trusted ? L("Allowed") : L("Not allowed"), color: trusted ? .systemGreen : .systemOrange)
        accessButton.isHidden = trusted
        let recording = ScreenRecording.isGranted
        recordingBadge.set(recording ? L("Allowed") : L("Not allowed"), color: recording ? .systemGreen : .systemOrange)
        recordingButton.isHidden = recording
    }

    private func showLoginNote() {
        loginNote.isHidden = !LaunchAtLogin.needsApproval
        loginNote.stringValue = L("Approve NyCopilot in System Settings → General → Login Items to finish.")
    }

    private func showLanguage() {
        let chosen = InterfaceLanguage.chosen
        if let item = languagePopup.itemArray.first(where: { ($0.representedObject as? String) == chosen }) {
            languagePopup.select(item)
        } else {
            languagePopup.selectItem(at: 0)
        }
        restartButton.isHidden = (chosen ?? InterfaceLanguage.system) == InterfaceLanguage.running
    }

    @objc private func changeLanguage() {
        InterfaceLanguage.chosen = languagePopup.selectedItem?.representedObject as? String
        showLanguage()
    }

    @objc private func restartApp() { services.restart() }

    @objc private func requestAccess() { Accessibility.requestAccess() }
    @objc private func requestRecording() { ScreenRecording.requestAccess() }

    @objc private func toggleModule(_ sender: NSSwitch) {
        guard let id = sender.identifier?.rawValue else { return }
        services.setModule(id, sender.state == .on)
    }

    @objc private func restartCaptureService() {
        let done = CaptureStreams.restartCaptureService()
        services.toast.show(done ? L("Screen capture service restarted") : L("Couldn’t restart the screen capture service"), style: done ? .success : .warning)
    }

    @objc private func copyDiagnostics() {
        Diagnostics.copyReport()
        diagnosticsButton.title = L("Copied")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.diagnosticsButton.title = L("Copy Diagnostics") }
    }
    @objc private func showGuide() { services.showWelcome() }

    @objc private func toggleLogin() {
        do { try LaunchAtLogin.set(loginSwitch.state == .on) } catch {
            loginSwitch.state = LaunchAtLogin.isEnabled ? .on : .off
            loginNote.stringValue = L("Couldn’t change the login item: %@", error.localizedDescription)
            loginNote.isHidden = false
            return
        }
        showLoginNote()
    }
}
