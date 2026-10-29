import AppKit

/// Screenshot & Pin settings: Screen Recording permission, where and how captures are saved, pins,
/// and shortcuts — with the capture keys listed for reference.
@MainActor
final class CapturePane: SettingsPane, NSTextFieldDelegate {
    private let services: CopilotServices
    private let permissionBadge = StatusBadge()
    private let permissionButton = Design.button("Open System Settings…", target: nil, action: nil)
    private let folderLabel = Design.label("", size: 12, color: .secondaryLabelColor)
    private let format = NSPopUpButton()
    private let pattern = NSTextField()
    private let shadowSwitch = NSSwitch()
    private let message = Design.wrapping("", size: 11.5, color: .systemRed)
    private lazy var shortcuts = ShortcutEditor(services: services)
    private static let formats = [("png", "PNG"), ("jpg", "JPEG")]

    init(services: CopilotServices) {
        self.services = services
        super.init(id: "capture", title: "Screenshot", symbol: "camera.viewfinder")
    }

    required init?(coder: NSCoder) { fatalError("Use init(services:)") }

    override func makeSections() -> [NSView] {
        permissionButton.target = self
        permissionButton.action = #selector(requestPermission)
        folderLabel.lineBreakMode = .byTruncatingMiddle
        folderLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 220).isActive = true
        let choose = Design.button("Choose…", target: self, action: #selector(chooseFolder))
        format.addItems(withTitles: Self.formats.map(\.1))
        format.target = self
        format.action = #selector(changeFormat)
        pattern.placeholderString = "NyCopilot {date} at {time}"
        pattern.delegate = self
        pattern.widthAnchor.constraint(equalToConstant: 220).isActive = true
        shadowSwitch.target = self
        shadowSwitch.action = #selector(toggleShadow)
        message.isHidden = true

        return [
            FormSection("Permissions", rows: [
                FormRow("Screen Recording", subtitle: "Lets NyCopilot capture what’s on your screens.",
                        accessory: Design.hstack([permissionBadge, permissionButton], spacing: 12))
            ]),
            FormSection("Saving", footer: "⌘S in a capture asks where to save; ⇧⌘S saves straight to this folder. The pattern understands {date}, {time}, and {n}.", rows: [
                FormRow("Folder", accessory: Design.hstack([folderLabel, choose], spacing: 8)),
                FormRow("Format", accessory: format),
                FormRow("File name", accessory: pattern)
            ]),
            message,
            FormSection("Pins", rows: [
                FormRow("Shadow", subtitle: "Draw a shadow around pinned images.", accessory: shadowSwitch)
            ]),
            shortcuts.section("Shortcuts", footer: """
                In a capture: drag or click a window to select · arrows nudge, ⇧ arrows resize · 1–8 pick a tool · \
                ⌘Z undo · Return copy · ⌘T pin · ⌘S save · C copy the color under the pointer · , and . recall recent regions · Esc cancel.
                On a pin: drag to move · scroll to zoom · ⌥ scroll for opacity · 1–4 rotate and flip · ⌘C copy · Esc or double-click to close.
                """, actions: [CaptureShell.Action.capture, CaptureShell.Action.pinClipboard, CaptureShell.Action.togglePins]),
            shortcuts.errorLabel
        ]
    }

    override func paneWillAppear() {
        let granted = ScreenGrabber.hasPermission
        permissionBadge.set(granted ? "Allowed" : "Not allowed", color: granted ? .systemGreen : .systemOrange)
        permissionButton.isHidden = granted
        refreshFolder()
        let current: String = services.core.setting(.captureFormat, default: "png")
        format.selectItem(at: Self.formats.firstIndex { $0.0 == current } ?? 0)
        pattern.stringValue = services.core.setting(.captureFileName, default: "")
        shadowSwitch.state = services.core.setting(.pinShadow, default: true) ? .on : .off
        message.isHidden = true
        shortcuts.refresh()
    }

    private func refreshFolder() {
        let chosen: String = services.core.setting(.captureSaveFolder, default: "")
        folderLabel.stringValue = chosen.isEmpty ? "Pictures › NyCopilot" : (chosen as NSString).abbreviatingWithTildeInPath
        folderLabel.toolTip = chosen.isEmpty ? nil : chosen
    }

    @objc private func requestPermission() { ScreenGrabber.requestPermission() }

    @objc private func chooseFolder() {
        guard let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            try? services.core.setSetting(.captureSaveFolder, url.path)
            refreshFolder()
        }
    }

    @objc private func changeFormat() {
        try? services.core.setSetting(.captureFormat, Self.formats[max(format.indexOfSelectedItem, 0)].0)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        do {
            try services.core.setSetting(.captureFileName, pattern.stringValue)
            message.isHidden = true
        } catch {
            message.stringValue = error.localizedDescription
            message.isHidden = false
            pattern.stringValue = services.core.setting(.captureFileName, default: "")
        }
    }

    @objc private func toggleShadow() { try? services.core.setSetting(.pinShadow, shadowSwitch.state == .on) }
}
