import AppKit

/// Clock settings: whether it's in the menu bar, the zone it shows, how it reads (with a preview),
/// and the other zones its menu lists.
@MainActor
final class ClockPane: SettingsPane {
    private let services: CopilotServices
    private let enabledSwitch = NSSwitch()
    private let zoneButton = Design.button("", target: nil, action: nil)
    private let preview = Design.label("", size: 13, weight: .medium)
    private let dateSwitch = NSSwitch()
    private let hourCycle = NSPopUpButton()
    private static let hourCycles: [(ClockSettings.HourCycle, String)] = [(.system, L("As on this Mac")), (.twelve, L("12-hour")),
                                                                          (.twentyFour, L("24-hour"))]
    private let secondsSwitch = NSSwitch()
    private let label = NSPopUpButton()
    private static let labels: [(ClockSettings.Label, String)] = [(.city, L("City")), (.abbreviation, L("Abbreviation")),
                                                                  (.offset, L("Offset from GMT")), (.custom, L("A name of your own")),
                                                                  (.none, L("Nothing"))]
    private let customField = NSTextField()
    private let addZoneButton = Design.button(L("Add…"), target: nil, action: nil)
    private let removeZoneMenu = NSPopUpButton(frame: .zero, pullsDown: true)
    private lazy var othersRow = FormRow(L("Other time zones"), subtitle: " ", accessory: Design.hstack([addZoneButton, removeZoneMenu]))
    private var picker: ZonePicker?

    init(services: CopilotServices) {
        self.services = services
        super.init(id: "clock", title: L("Clock"), symbol: "clock")
    }

    required init?(coder: NSCoder) { fatalError("Use init(services:)") }

    private var settings: ClockSettings { ClockSettings.read(services.core, moduleOn: true) }

    override func makeSections() -> [NSView] {
        enabledSwitch.target = self
        enabledSwitch.action = #selector(toggleEnabled)
        zoneButton.target = self
        zoneButton.action = #selector(pickZone)
        zoneButton.image = NSImage(systemSymbolName: "chevron.up.chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        zoneButton.imagePosition = .imageTrailing
        dateSwitch.target = self
        dateSwitch.action = #selector(changeFormat)
        secondsSwitch.target = self
        secondsSwitch.action = #selector(changeFormat)
        hourCycle.addItems(withTitles: Self.hourCycles.map(\.1))
        hourCycle.target = self
        hourCycle.action = #selector(changeFormat)
        label.addItems(withTitles: Self.labels.map(\.1))
        label.target = self
        label.action = #selector(changeFormat)
        customField.placeholderString = L("Office")
        customField.cell?.sendsActionOnEndEditing = true
        customField.target = self
        customField.action = #selector(changeFormat)
        customField.widthAnchor.constraint(equalToConstant: 110).isActive = true
        preview.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        addZoneButton.target = self
        addZoneButton.action = #selector(addZone)
        removeZoneMenu.target = self
        removeZoneMenu.action = #selector(removeZone(_:))
        return [
            FormSection(L("Menu bar clock"), footer: L("The clock first goes right of NyCopilot’s icon, where icons don’t hide. ⌘-drag it to move it."), rows: [
                FormRow(L("Show a clock in the menu bar"), subtitle: L("The date and time in any time zone, on the minute or the second."), accessory: enabledSwitch),
                FormRow(L("Time zone"), accessory: zoneButton)
            ]),
            FormSection(L("Format"), rows: [
                FormRow(L("Preview"), accessory: preview),
                FormRow(L("Show the date"), accessory: dateSwitch),
                FormRow(L("Hours"), accessory: hourCycle),
                FormRow(L("Show seconds"), accessory: secondsSwitch),
                FormRow(L("After the time"), subtitle: L("How the time zone is named."), accessory: Design.hstack([customField, label]))
            ]),
            FormSection(L("More time zones"), footer: L("Click the clock to see these with their times and hours from this Mac. Click one there to show it in the menu bar instead."), rows: [
                othersRow
            ])
        ]
    }

    override func paneWillAppear() {
        let settings = settings
        let on: Bool = services.core.setting(.clockEnabled, default: false)
        enabledSwitch.state = on ? .on : .off
        zoneButton.title = settings.zoneID.isEmpty ? L("This Mac’s time zone") : zoneTitle(settings.zoneID)
        dateSwitch.state = settings.showDate ? .on : .off
        secondsSwitch.state = settings.showSeconds ? .on : .off
        hourCycle.selectItem(at: Self.hourCycles.firstIndex { $0.0 == settings.hourCycle } ?? 0)
        label.selectItem(at: Self.labels.firstIndex { $0.0 == settings.label } ?? 0)
        customField.stringValue = settings.customLabel
        customField.isHidden = settings.label != .custom
        preview.stringValue = ClockFace(settings, locale: Localization.locale).text(at: Date())
        let others = settings.otherZones
        othersRow.subtitleLabel?.stringValue = others.isEmpty ? L("None yet.") : ListFormatter.localizedString(byJoining: others.map(zoneTitle))
        removeZoneMenu.removeAllItems()
        removeZoneMenu.addItem(withTitle: L("Remove"))
        for id in others {
            removeZoneMenu.addItem(withTitle: zoneTitle(id))
            removeZoneMenu.lastItem?.representedObject = id
        }
        removeZoneMenu.isEnabled = !others.isEmpty
        addZoneButton.isEnabled = others.count < 20
    }

    /// "Tokyo (GMT+9)", or the identifier of a zone this Mac doesn't know.
    private func zoneTitle(_ id: String) -> String {
        guard ClockZones.isKnown(id) else { return id }
        let zone = ClockZones.zone(id)
        let formatter = DateFormatter()
        formatter.locale = Localization.locale
        formatter.timeZone = zone
        formatter.dateFormat = "O"
        let city = ClockZones.city(zone, locale: Localization.locale)
        let offset = formatter.string(from: Date())
        return city == offset ? city : "\(city) (\(offset))"
    }

    @objc private func toggleEnabled() {
        try? services.core.setSetting(.clockEnabled, enabledSwitch.state == .on)
        if enabledSwitch.state == .on, !services.isModuleOn("clock") { services.setModule("clock", true) }
        paneWillAppear()
    }

    @objc private func pickZone() {
        let picker = ZonePicker(includeThisMac: true) { [weak self] id in
            guard let self else { return }
            try? services.core.setSetting(.clockTimeZone, id)
            // Shown in the menu bar, it needn't be listed too.
            try? services.core.setSetting(.clockOtherZones, settings.otherZones.filter { $0 != id })
            paneWillAppear()
        }
        picker.present(below: zoneButton)
        self.picker = picker
    }

    @objc private func changeFormat() {
        let core = services.core
        try? core.setSetting(.clockShowDate, dateSwitch.state == .on)
        try? core.setSetting(.clockShowSeconds, secondsSwitch.state == .on)
        try? core.setSetting(.clockHourCycle, Self.hourCycles[max(hourCycle.indexOfSelectedItem, 0)].0.rawValue)
        try? core.setSetting(.clockLabel, Self.labels[max(label.indexOfSelectedItem, 0)].0.rawValue)
        // Too long a name is cut to fit, as the core takes at most 40 characters on one line.
        let name = String(customField.stringValue.replacingOccurrences(of: "\n", with: " ").prefix(40))
        try? core.setSetting(.clockCustomLabel, name)
        paneWillAppear()
        if label.indexOfSelectedItem == Self.labels.firstIndex(where: { $0.0 == .custom }), name.isEmpty {
            view.window?.makeFirstResponder(customField)
        }
    }

    @objc private func addZone() {
        let picker = ZonePicker(includeThisMac: false) { [weak self] id in
            guard let self else { return }
            let settings = settings
            guard id != settings.zoneID, !settings.otherZones.contains(id) else { return }
            try? services.core.setSetting(.clockOtherZones, settings.otherZones + [id])
            paneWillAppear()
        }
        picker.present(below: addZoneButton)
        self.picker = picker
    }

    @objc private func removeZone(_ sender: NSPopUpButton) {
        guard let id = sender.selectedItem?.representedObject as? String else { return }
        try? services.core.setSetting(.clockOtherZones, settings.otherZones.filter { $0 != id })
        paneWillAppear()
    }
}
