import AppKit

/// Window Layouts settings: drag snapping, gaps, size cycling, and every layout shortcut.
@MainActor
final class WindowsPane: SettingsPane {
    private let services: CopilotServices
    private let actions: [WindowsShell.ActionInfo]
    private let dragSwitch = NSSwitch()
    private let repeatMode = NSPopUpButton()
    private static let repeatModes = [("cycle_sizes", L("Cycle sizes (½ → ⅔ → ⅓)")),
                                      ("move_across_displays", L("Move to the next display")),
                                      ("nothing", L("Do nothing"))]
    private let gapSlider = NSSlider(value: 0, minValue: 0, maxValue: 60, target: nil, action: nil)
    private let gapValue = Design.label("", size: 12, color: .secondaryLabelColor)
    private lazy var shortcuts = ShortcutEditor(services: services)
    private let importNote = Design.wrapping("", size: 11.5)

    init(services: CopilotServices, actions: [WindowsShell.ActionInfo]) {
        self.services = services
        self.actions = actions
        super.init(id: "windows", title: L("Windows"), symbol: "rectangle.split.2x1")
    }

    required init?(coder: NSCoder) { fatalError("Use init(services:actions:)") }

    override func makeSections() -> [NSView] {
        dragSwitch.target = self
        dragSwitch.action = #selector(toggleDrag)
        repeatMode.addItems(withTitles: Self.repeatModes.map(\.1))
        repeatMode.target = self
        repeatMode.action = #selector(changeRepeat)
        gapSlider.numberOfTickMarks = 11
        gapSlider.allowsTickMarkValuesOnly = true
        gapSlider.target = self
        gapSlider.action = #selector(changeGap)
        gapSlider.widthAnchor.constraint(equalToConstant: 180).isActive = true
        gapValue.alignment = .right
        gapValue.widthAnchor.constraint(equalToConstant: 36).isActive = true

        var sections: [NSView] = [
            FormSection(L("Arranging"), footer: L("Window Layouts moves the frontmost app’s focused window. It needs Accessibility, like Translate."), rows: [
                FormRow(L("Snap by dragging to edges"), subtitle: L("Drag a window to a side, corner, or the top of the screen."), accessory: dragSwitch),
                FormRow(L("When a shortcut is repeated"), subtitle: L("Pressing the same layout again on the same window."), accessory: repeatMode),
                FormRow(L("Gap between windows"), accessory: Design.hstack([gapSlider, gapValue]))
            ])
        ]
        var groups: [(String, [String])] = []
        for action in actions {
            if groups.last?.0 == action.group { groups[groups.count - 1].1.append("windows.\(action.id)") }
            else { groups.append((action.group, ["windows.\(action.id)"])) }
        }
        for (index, group) in groups.enumerated() {
            sections.append(shortcuts.section(group.0, footer: index == 0 ? L("Click a shortcut and press a new combination. Press Delete to turn it off.") : nil,
                                              actions: group.1))
        }
        sections.append(shortcuts.errorLabel)
        if RectangleImport.isAvailable {
            importNote.isHidden = true
            sections.append(FormSection(L("Switching from Rectangle"), rows: [
                FormRow(L("Rectangle settings"), subtitle: L("Use your Rectangle shortcuts and repeat behavior here."),
                        accessory: Design.button(L("Import"), target: self, action: #selector(importFromRectangle)))
            ]))
            sections.append(importNote)
        }
        return sections
    }

    override func paneWillAppear() {
        dragSwitch.state = services.core.setting(.dragSnap, default: true) ? .on : .off
        let mode: String = services.core.setting(.windowRepeat, default: "cycle_sizes")
        repeatMode.selectItem(at: Self.repeatModes.firstIndex { $0.0 == mode } ?? 0)
        let gap: Double = services.core.setting(.windowGap, default: 0)
        gapSlider.doubleValue = gap
        gapValue.stringValue = "\(Int(gap)) pt"
        shortcuts.refresh()
    }

    @objc private func importFromRectangle() {
        let outcome = RectangleImport.apply(RectangleImport.read(), to: services)
        importNote.stringValue = outcome.summary
        importNote.textColor = outcome.failed == 0 ? .secondaryLabelColor : .systemOrange
        importNote.isHidden = false
        paneWillAppear()
    }

    @objc private func toggleDrag() { try? services.core.setSetting(.dragSnap, dragSwitch.state == .on) }
    @objc private func changeRepeat() {
        try? services.core.setSetting(.windowRepeat, Self.repeatModes[max(repeatMode.indexOfSelectedItem, 0)].0)
    }

    @objc private func changeGap() {
        let gap = gapSlider.doubleValue.rounded()
        gapValue.stringValue = "\(Int(gap)) pt"
        try? services.core.setSetting(.windowGap, gap)
    }
}
