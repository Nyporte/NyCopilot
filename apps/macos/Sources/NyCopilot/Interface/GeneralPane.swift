import AppKit

/// Permissions and startup. Each module lists its own shortcuts in its own tab.
@MainActor
final class GeneralPane: SettingsPane {
    private let services: CopilotServices
    private let accessBadge = StatusBadge()
    private let accessButton = Design.button("Open System Settings…", target: nil, action: nil)
    private let recordingBadge = StatusBadge()
    private let recordingButton = Design.button("Open System Settings…", target: nil, action: nil)
    private let diagnosticsButton = Design.button("Copy Diagnostics", target: nil, action: nil)
    private let loginSwitch = NSSwitch()
    private let loginNote = Design.wrapping("", size: 11.5)
    private var poll: Timer?

    init(services: CopilotServices) {
        self.services = services
        super.init(id: "general", title: "General", symbol: "gearshape")
    }

    required init?(coder: NSCoder) { fatalError("Use init(services:)") }

    override func makeSections() -> [NSView] {
        accessButton.target = self
        accessButton.action = #selector(requestAccess)
        let access = FormRow("Accessibility", subtitle: "Lets NyCopilot read and paste into text fields, and move other apps’ windows.",
                             accessory: Design.hstack([accessBadge, accessButton], spacing: 12))

        recordingButton.target = self
        recordingButton.action = #selector(requestRecording)
        let recording = FormRow("Screen Recording", subtitle: "Lets NyCopilot take screenshots and translate what’s on screen.",
                                accessory: Design.hstack([recordingBadge, recordingButton], spacing: 12))
        diagnosticsButton.target = self
        diagnosticsButton.action = #selector(copyDiagnostics)
        let diagnostics = FormRow("Diagnostics", subtitle: "What NyCopilot did lately — fields it found, pastes, errors — without any of your text. Paste it into a bug report.",
                                  accessory: diagnosticsButton)

        loginSwitch.target = self
        loginSwitch.action = #selector(toggleLogin)
        loginNote.isHidden = true
        let login = FormRow("Open at login", subtitle: nil, accessory: loginSwitch)

        var sections: [NSView] = [
            FormSection("Permissions", rows: [access, recording]),
            FormSection("Startup", rows: [login]),
            FormSection("Troubleshooting", rows: [diagnostics]),
        ]
        let guide = Design.button("Show Setup Guide…", target: self, action: #selector(showGuide))
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–"
        sections.append(Design.hstack([Design.label("NyCopilot \(version)", size: 12, color: .tertiaryLabelColor),
                                       Design.spacer(), guide]))
        sections.insert(loginNote, at: 2)
        return sections
    }

    override func paneWillAppear() {
        refreshAccess()
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
        accessBadge.set(trusted ? "Allowed" : "Not allowed", color: trusted ? .systemGreen : .systemOrange)
        accessButton.isHidden = trusted
        let recording = ScreenGrabber.hasPermission
        recordingBadge.set(recording ? "Allowed" : "Not allowed", color: recording ? .systemGreen : .systemOrange)
        recordingButton.isHidden = recording
    }

    private func showLoginNote() {
        loginNote.isHidden = !LaunchAtLogin.needsApproval
        loginNote.stringValue = "Approve NyCopilot in System Settings → General → Login Items to finish."
    }

    @objc private func requestAccess() { Accessibility.requestAccess() }
    @objc private func requestRecording() { ScreenGrabber.requestPermission() }

    @objc private func copyDiagnostics() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Diagnostics.report(), forType: .string)
        diagnosticsButton.title = "Copied"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.diagnosticsButton.title = "Copy Diagnostics" }
    }
    @objc private func showGuide() { services.showWelcome() }

    @objc private func toggleLogin() {
        do { try LaunchAtLogin.set(loginSwitch.state == .on) } catch {
            loginSwitch.state = LaunchAtLogin.isEnabled ? .on : .off
            loginNote.stringValue = "Couldn’t change the login item: \(error.localizedDescription)"
            loginNote.isHidden = false
            return
        }
        showLoginNote()
    }
}
