import AppKit

/// Screenshot & Pin settings: Screen Recording permission, what captures include, where and how they
/// are saved, pins, and shortcuts — with the capture keys listed for reference.
@MainActor
final class CapturePane: SettingsPane, NSTextFieldDelegate {
    private let services: CopilotServices
    private let permissionBadge = StatusBadge()
    private let permissionButton = Design.button(L("Open System Settings…"), target: nil, action: nil)
    private let folderLabel = Design.label("", size: 12, color: .secondaryLabelColor)
    private let format = NSPopUpButton()
    private let pattern = NSTextField()
    private let shadowSwitch = NSSwitch()
    private let hideSwitch = NSSwitch()
    private let gifRate = NSPopUpButton()
    private let gifRetinaSwitch = NSSwitch()
    private let gifCursorSwitch = NSSwitch()
    private static let rates = [10, 15, 20, 30]
    private let message = Design.wrapping("", size: 11.5, color: .systemRed)
    private lazy var shortcuts = ShortcutEditor(services: services)
    private static let formats = [("png", "PNG"), ("jpg", "JPEG")]
    /// Where saves go until a folder is chosen, with the Pictures folder named as Finder names it.
    private static var defaultFolderName: String {
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
        return (pictures.map { FileManager.default.displayName(atPath: $0.path) } ?? "Pictures") + " › NyCopilot"
    }

    init(services: CopilotServices) {
        self.services = services
        super.init(id: "capture", title: L("Screenshot"), symbol: "camera.viewfinder")
    }

    required init?(coder: NSCoder) { fatalError("Use init(services:)") }

    override func makeSections() -> [NSView] {
        permissionButton.target = self
        permissionButton.action = #selector(requestPermission)
        folderLabel.lineBreakMode = .byTruncatingMiddle
        folderLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 220).isActive = true
        let choose = Design.button(L("Choose…"), target: self, action: #selector(chooseFolder))
        format.addItems(withTitles: Self.formats.map(\.1))
        format.target = self
        format.action = #selector(changeFormat)
        pattern.placeholderString = "NyCopilot {date} at {time}"
        pattern.delegate = self
        pattern.widthAnchor.constraint(equalToConstant: 220).isActive = true
        shadowSwitch.target = self
        shadowSwitch.action = #selector(toggleShadow)
        hideSwitch.target = self
        hideSwitch.action = #selector(toggleHide)
        message.isHidden = true
        gifRate.addItems(withTitles: Self.rates.map { L("%ld frames a second", $0) })
        gifRate.target = self
        gifRate.action = #selector(changeRate)
        gifRetinaSwitch.target = self
        gifRetinaSwitch.action = #selector(toggleGifRetina)
        gifCursorSwitch.target = self
        gifCursorSwitch.action = #selector(toggleGifCursor)

        return [
            FormSection(L("Permissions"), rows: [
                FormRow(L("Screen Recording"), subtitle: L("Lets NyCopilot capture what’s on your screens."),
                        accessory: Design.hstack([permissionBadge, permissionButton], spacing: 12))
            ]),
            FormSection(L("Capturing"), rows: [
                FormRow(L("Hide NyCopilot windows"), subtitle: L("Leave pins and other NyCopilot windows out of captures."), accessory: hideSwitch)
            ]),
            FormSection(L("GIF Recording"), footer: L("G in a capture arms the selection; Record (or the capture shortcut) starts, the shortcut again stops. Up to a minute. GIFs save to the folder below."), rows: [
                FormRow(L("Frame rate"), subtitle: L("More frames move more smoothly and make bigger files."), accessory: gifRate),
                FormRow(L("Full Retina resolution"), subtitle: L("Off records one pixel per point: sharp enough, and a quarter of the size."), accessory: gifRetinaSwitch),
                FormRow(L("Show the pointer"), accessory: gifCursorSwitch)
            ]),
            FormSection(L("Saving"), footer: L("⌘S in a capture asks where to save; ⇧⌘S saves straight to this folder. The pattern understands {date}, {time}, and {n}."), rows: [
                FormRow(L("Folder"), accessory: Design.hstack([folderLabel, choose], spacing: 8)),
                FormRow(L("Format"), accessory: format),
                FormRow(L("File name"), accessory: pattern)
            ]),
            message,
            FormSection(L("Pins"), rows: [
                FormRow(L("Shadow"), subtitle: L("Draw a shadow around pinned images."), accessory: shadowSwitch)
            ]),
            shortcuts.section(L("Shortcuts"), footer: """
                In a capture: drag or click a window to select · arrows nudge, ⇧ arrows resize · 1–8 pick a tool · \
                ⌘Z undo · T select text in place, T again copies it all · S scrolling capture · Return copy · ⌘T pin · ⌘S save · C copy the color under the pointer · , and . recall recent regions · Esc cancel.
                On a pin: drag to move · scroll to zoom · ⌥ scroll for opacity · 1–4 rotate and flip · T select text · ⌘C copy · Esc or double-click to close.
                """, actions: [CaptureShell.Action.capture, CaptureShell.Action.pinClipboard, CaptureShell.Action.togglePins]),
            shortcuts.errorLabel
        ]
    }

    override func paneWillAppear() {
        let granted = ScreenRecording.isGranted
        permissionBadge.set(granted ? L("Allowed") : L("Not allowed"), color: granted ? .systemGreen : .systemOrange)
        permissionButton.isHidden = granted
        refreshFolder()
        let current: String = services.core.setting(.captureFormat, default: "png")
        format.selectItem(at: Self.formats.firstIndex { $0.0 == current } ?? 0)
        pattern.stringValue = services.core.setting(.captureFileName, default: "")
        shadowSwitch.state = services.core.setting(.pinShadow, default: true) ? .on : .off
        hideSwitch.state = services.core.setting(.hideOwnWindows, default: false) ? .on : .off
        let rate = services.core.setting(.gifFPS, default: 15)
        gifRate.selectItem(at: Self.rates.firstIndex { $0 >= rate } ?? 1)
        gifRetinaSwitch.state = services.core.setting(.gifRetina, default: false) ? .on : .off
        gifCursorSwitch.state = services.core.setting(.gifCursor, default: true) ? .on : .off
        message.isHidden = true
        shortcuts.refresh()
    }

    private func refreshFolder() {
        let chosen: String = services.core.setting(.captureSaveFolder, default: "")
        folderLabel.stringValue = chosen.isEmpty ? Self.defaultFolderName : (chosen as NSString).abbreviatingWithTildeInPath
        folderLabel.toolTip = chosen.isEmpty ? nil : chosen
    }

    @objc private func requestPermission() { ScreenRecording.requestAccess() }

    @objc private func chooseFolder() {
        guard let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = L("Use Folder")
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
    @objc private func toggleHide() { try? services.core.setSetting(.hideOwnWindows, hideSwitch.state == .on) }
    @objc private func changeRate() { try? services.core.setSetting(.gifFPS, Self.rates[max(0, gifRate.indexOfSelectedItem)]) }
    @objc private func toggleGifRetina() { try? services.core.setSetting(.gifRetina, gifRetinaSwitch.state == .on) }
    @objc private func toggleGifCursor() { try? services.core.setSetting(.gifCursor, gifCursorSwitch.state == .on) }
}
