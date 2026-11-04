import AppKit

/// Mouse settings: whether NyCopilot sets the mice's pointer, its speed and acceleration (dragged
/// or typed), and the wheel: which way it scrolls, and whether (and how far, and where) it glides.
@MainActor
final class MousePane: SettingsPane {
    private let services: CopilotServices
    private let connected: () -> [String]
    private let enabledSwitch = NSSwitch()
    private lazy var enabledRow = FormRow(L("Set mouse speed and acceleration"), subtitle: " ", accessory: enabledSwitch)
    private let times = Design.label("×", size: 12, color: .secondaryLabelColor)
    private lazy var speedRow = FormRow(L("Speed"), subtitle: " ", accessory: Design.hstack([speedSlider, speedField, times], spacing: 6))
    /// Speed runs on a doubling scale, so ½× and 2× sit the same distance either side of 1×.
    private let speedSlider = NSSlider()
    private let speedField = MousePane.numberField()
    /// Stops at 8 (or the core's limit, if lower); a typed value can go further.
    private let accelerationSlider = NSSlider()
    private let accelerationField = MousePane.numberField()
    private let accelerationOff = Design.label(L("Off"), size: 12, color: .secondaryLabelColor)
    private let resetButton = Design.button(L("Reset"), target: nil, action: nil)
    private let reverseSwitch = NSSwitch()
    private let smoothSwitch = NSSwitch()
    private let linesSlider = NSSlider()
    private let linesField = MousePane.numberField()
    private let glideSlider = NSSlider()
    private let glideField = MousePane.numberField()
    private let addAppButton = Design.button(L("Add App…"), target: nil, action: nil)
    private let removeAppMenu = NSPopUpButton(frame: .zero, pullsDown: true)
    private lazy var appsRow = FormRow(L("Apps that scroll as usual"), subtitle: " ", accessory: Design.hstack([addAppButton, removeAppMenu]))
    private let notes = Design.wrapping("", size: 11.5)

    /// Other apps that set the pointer's speed or reshape scrolling; two at once undo each other.
    private static let otherApps = ["com.naotanhaocan.BetterMouse", "com.lujjjh.LinearMouse", "com.caldis.Mos"]
    /// `mouse.acceleration` at this value follows System Settings.
    private static let followSystem = -1.0
    /// What the core accepts, from its manifest.
    private lazy var speedRange = services.core.settingRange(.mouseSpeed)
    private lazy var accelerationRange = services.core.settingRange(.mouseAcceleration)
    private lazy var linesRange = services.core.settingRange(.mouseScrollLines)
    private lazy var glideRange = services.core.settingRange(.mouseScrollGlide)

    init(services: CopilotServices, connected: @escaping () -> [String]) {
        self.services = services
        self.connected = connected
        super.init(id: "mouse", title: L("Mouse"), symbol: "computermouse")
    }

    required init?(coder: NSCoder) { fatalError("Use init(services:connected:)") }

    private static func numberField() -> NSTextField {
        let field = NSTextField()
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 2
        formatter.isLenient = true
        field.formatter = formatter
        field.alignment = .right
        // Return and leaving the field both commit what was typed.
        field.cell?.sendsActionOnEndEditing = true
        field.widthAnchor.constraint(equalToConstant: 52).isActive = true
        return field
    }

    /// A value within the core's range for its setting, when it has one.
    private static func clamped(_ value: Double, to range: ClosedRange<Double>?) -> Double {
        range.map { min(max(value, $0.lowerBound), $0.upperBound) } ?? value
    }

    override func makeSections() -> [NSView] {
        enabledSwitch.target = self
        enabledSwitch.action = #selector(toggleEnabled)
        if let speedRange {
            speedSlider.minValue = log2(speedRange.lowerBound)
            speedSlider.maxValue = log2(speedRange.upperBound)
        }
        if let accelerationRange {
            accelerationSlider.minValue = accelerationRange.lowerBound
            accelerationSlider.maxValue = min(8, accelerationRange.upperBound)
        }
        for (slider, range) in [(linesSlider, linesRange), (glideSlider, glideRange)] {
            guard let range else { continue }
            slider.minValue = range.lowerBound
            slider.maxValue = range.upperBound
        }
        for (slider, field, slid, typed) in [(speedSlider, speedField, #selector(changeSpeed), #selector(typeSpeed)),
                                             (accelerationSlider, accelerationField, #selector(changeAcceleration), #selector(typeAcceleration)),
                                             (linesSlider, linesField, #selector(changeLines), #selector(typeLines)),
                                             (glideSlider, glideField, #selector(changeGlide), #selector(typeGlide))] {
            slider.target = self
            slider.action = slid
            slider.isContinuous = true
            slider.numberOfTickMarks = slider === linesSlider ? 10 : 6
            slider.widthAnchor.constraint(equalToConstant: 160).isActive = true
            field.target = self
            field.action = typed
            (field.formatter as? NumberFormatter)?.locale = Localization.locale
        }
        resetButton.target = self
        resetButton.action = #selector(reset)
        reverseSwitch.target = self
        reverseSwitch.action = #selector(toggleReverse)
        smoothSwitch.target = self
        smoothSwitch.action = #selector(toggleSmooth)
        addAppButton.target = self
        addAppButton.action = #selector(addApp)
        removeAppMenu.target = self
        removeAppMenu.action = #selector(removeApp(_:))
        let unit = { (text: String) in Design.label(text, size: 12, color: .secondaryLabelColor) }
        return [
            FormSection(L("Pointer"), footer: L("Changes apply to every connected mouse as you make them; the trackpad keeps its own settings. When this is off, or NyCopilot quits, mice go back to System Settings → Mouse."), rows: [
                enabledRow,
                speedRow,
                FormRow(L("Acceleration"), subtitle: L("How much further quick movements carry the pointer. 0 turns it off: the pointer goes the same distance at any speed."),
                        accessory: Design.hstack([accelerationSlider, accelerationField, accelerationOff], spacing: 6)),
                FormRow(L("Start over"), subtitle: L("Speed back to 1×, acceleration back to System Settings."), accessory: resetButton)
            ]),
            FormSection(L("Scroll wheel"), rows: [
                FormRow(L("Reverse scrolling"), subtitle: L("A mouse wheel scrolls the other way from System Settings; the trackpad keeps its direction. With natural scrolling on, this is the Windows way."),
                        accessory: reverseSwitch),
                FormRow(L("Smooth scrolling"), subtitle: L("Each click glides instead of jumping, like Mos. Hold ⇧ to scroll sideways, ⌥ to go five times as far, ⌘ for a plain click."),
                        accessory: smoothSwitch),
                FormRow(L("Distance per click"), subtitle: L("Windows scrolls 3 lines a click. Quick spins go further."),
                        accessory: Design.hstack([linesSlider, linesField, unit(L("lines"))], spacing: 6)),
                FormRow(L("Glide"), subtitle: L("How long a click takes to arrive; 0 jumps at once, the same distance."),
                        accessory: Design.hstack([glideSlider, glideField, unit(L("ms"))], spacing: 6)),
                appsRow
            ]),
            notes
        ]
    }

    override func paneWillAppear() {
        let on: Bool = services.core.setting(.mouseEnabled, default: false)
        enabledSwitch.state = on ? .on : .off
        let mice = Array(NSOrderedSet(array: connected())) as? [String] ?? []
        enabledRow.subtitleLabel?.stringValue = mice.isEmpty ? L("No mouse is connected; these take effect when you connect one.")
            : L("Connected: %@", ListFormatter.localizedString(byJoining: mice))
        showSpeed(services.core.setting(.mouseSpeed, default: 1))
        showAcceleration(acceleration)
        for control: NSControl in [speedSlider, speedField, accelerationSlider, accelerationField, resetButton] { control.isEnabled = on }
        let reverse: Bool = services.core.setting(.mouseReverseScroll, default: false)
        reverseSwitch.state = reverse ? .on : .off
        let smooth: Bool = services.core.setting(.mouseSmoothScroll, default: false)
        smoothSwitch.state = smooth ? .on : .off
        showLines(services.core.setting(.mouseScrollLines, default: 3))
        showGlide(services.core.setting(.mouseScrollGlide, default: 200))
        showApps()
        for control: NSControl in [linesSlider, linesField, glideSlider, glideField, addAppButton, removeAppMenu] { control.isEnabled = smooth }
        removeAppMenu.isEnabled = smooth && !exceptions.isEmpty
        var lines: [String] = []
        if let running = NSWorkspace.shared.runningApplications.first(where: { Self.otherApps.contains($0.bundleIdentifier ?? "") }) {
            lines.append(L("%@ is running too. If it also changes the pointer or scrolling, turn that off there, so only one app does.", running.localizedName ?? ""))
        }
        if (reverse || smooth) && !Accessibility.isTrusted { lines.append(L("Reversing or smoothing the wheel needs Accessibility. Allow it in Settings → General.")) }
        notes.stringValue = lines.joined(separator: "\n")
        notes.textColor = .systemOrange
        notes.isHidden = lines.isEmpty
    }

    /// The acceleration in effect: the one set here, or, while following System Settings, the one the
    /// core applies (System Settings', or macOS's own when it has none). None, linear, shows as 0.
    private var acceleration: Double {
        let set: Double = services.core.setting(.mouseAcceleration, default: Self.followSystem)
        guard set == Self.followSystem else { return set }
        struct Pointer: Decodable { let acceleration: Double; let linear: Bool }
        var params: [String: Any] = [:]
        params["system_acceleration"] = PointerDevices.systemSetting
        guard let pointer = try? services.core.call(.mousePointer, params, as: Pointer.self) else { return 0 }
        return pointer.linear ? 0 : pointer.acceleration
    }

    private func showSpeed(_ speed: Double) {
        speedSlider.doubleValue = log2(speed)
        speedField.doubleValue = speed
    }

    private func showAcceleration(_ value: Double) {
        accelerationSlider.doubleValue = value
        accelerationField.doubleValue = value
        accelerationOff.isHidden = value != 0
        // Without acceleration, speed is points per count; Windows moves one pixel per count.
        let pixel = 1 / Double(NSScreen.main?.backingScaleFactor ?? 1)
        speedRow.subtitleLabel?.stringValue = value == 0
            ? L("Points the pointer moves for each step the mouse reports. Windows’ default is %@× on this display.",
                pixel.formatted(.number.precision(.fractionLength(0...2)).locale(Localization.locale)))
            : L("How far the pointer goes for the same movement; 1× is macOS’s standard for a mouse. Drag, or type a number.")
    }

    @objc private func toggleEnabled() {
        try? services.core.setSetting(.mouseEnabled, enabledSwitch.state == .on)
        paneWillAppear()
    }

    /// In steps of 0.05× while dragging, so a value can be found again.
    @objc private func changeSpeed() {
        setSpeed((pow(2, speedSlider.doubleValue) * 20).rounded() / 20)
    }

    @objc private func typeSpeed() {
        setSpeed((speedField.doubleValue * 100).rounded() / 100)
    }

    private func setSpeed(_ speed: Double) {
        let speed = Self.clamped(speed, to: speedRange)
        showSpeed(speed)
        try? services.core.setSetting(.mouseSpeed, speed)
    }

    /// In steps of 0.1 while dragging; the far left is off.
    @objc private func changeAcceleration() {
        setAcceleration((accelerationSlider.doubleValue * 10).rounded() / 10)
    }

    @objc private func typeAcceleration() {
        setAcceleration((accelerationField.doubleValue * 100).rounded() / 100)
    }

    private func setAcceleration(_ value: Double) {
        let value = Self.clamped(value, to: accelerationRange)
        showAcceleration(value)
        try? services.core.setSetting(.mouseAcceleration, value)
    }

    @objc private func toggleReverse() {
        try? services.core.setSetting(.mouseReverseScroll, reverseSwitch.state == .on)
        paneWillAppear()
    }

    @objc private func toggleSmooth() {
        try? services.core.setSetting(.mouseSmoothScroll, smoothSwitch.state == .on)
        paneWillAppear()
    }

    private func showLines(_ lines: Double) {
        linesSlider.doubleValue = lines
        linesField.doubleValue = lines
    }

    /// Half lines while dragging.
    @objc private func changeLines() { setLines((linesSlider.doubleValue * 2).rounded() / 2) }
    @objc private func typeLines() { setLines((linesField.doubleValue * 10).rounded() / 10) }

    private func setLines(_ lines: Double) {
        let lines = Self.clamped(lines, to: linesRange)
        showLines(lines)
        try? services.core.setSetting(.mouseScrollLines, lines)
    }

    private func showGlide(_ glide: Double) {
        glideSlider.doubleValue = glide
        glideField.doubleValue = glide
    }

    /// Steps of 10 ms while dragging.
    @objc private func changeGlide() { setGlide((glideSlider.doubleValue / 10).rounded() * 10) }
    @objc private func typeGlide() { setGlide(glideField.doubleValue.rounded()) }

    private func setGlide(_ glide: Double) {
        let glide = Self.clamped(glide, to: glideRange)
        showGlide(glide)
        try? services.core.setSetting(.mouseScrollGlide, glide)
    }

    private var exceptions: [String] { services.core.setting(.mouseScrollExceptions, default: [String]()) }

    /// An app's name from its bundle identifier, or the identifier when it isn't installed here.
    private static func name(of bundleID: String) -> String {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { FileManager.default.displayName(atPath: $0.path) }
            .map { $0.hasSuffix(".app") ? String($0.dropLast(4)) : $0 } ?? bundleID
    }

    private func showApps() {
        let apps = exceptions.map { (id: $0, name: Self.name(of: $0)) }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        appsRow.subtitleLabel?.stringValue = apps.isEmpty ? L("None. Games and remote desktops usually want to be here.")
            : ListFormatter.localizedString(byJoining: apps.map(\.name))
        removeAppMenu.removeAllItems()
        removeAppMenu.addItem(withTitle: L("Remove"))
        for app in apps {
            removeAppMenu.addItem(withTitle: app.name)
            removeAppMenu.lastItem?.representedObject = app.id
        }
    }

    @objc private func addApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self else { return }
            let added = panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }
            let all = self.exceptions + added.filter { !self.exceptions.contains($0) }
            try? self.services.core.setSetting(.mouseScrollExceptions, all)
            self.paneWillAppear()
        }
    }

    @objc private func removeApp(_ sender: NSPopUpButton) {
        guard let id = sender.selectedItem?.representedObject as? String else { return }
        try? services.core.setSetting(.mouseScrollExceptions, exceptions.filter { $0 != id })
        paneWillAppear()
    }

    @objc private func reset() {
        try? services.core.resetSetting(.mouseSpeed)
        try? services.core.resetSetting(.mouseAcceleration)
        paneWillAppear()
    }
}
