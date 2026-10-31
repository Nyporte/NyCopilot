import AppKit
import MacPlatform

/// Click, then press a key combination. Esc cancels; Delete turns the shortcut off.
final class ShortcutRecorder: AppearanceView {
    var combination: HotKeyCombination? { didSet { refresh() } }
    /// Return an error message to reject the new value and keep the old one.
    var onChange: ((HotKeyCombination?) -> String?)?
    var onRecordingChange: ((Bool) -> Void)?
    var onError: ((String?) -> Void)?

    private let text = Design.label("", size: 12.5, weight: .medium)
    private let clear = NSButton()
    private var recording = false { didSet { refresh(); onRecordingChange?(recording) } }
    private var monitor: Any?

    override init(frame: NSRect) {
        super.init(frame: frame)
        radius = 6
        text.alignment = .center
        text.translatesAutoresizingMaskIntoConstraints = false
        clear.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: L("Turn off shortcut"))
        clear.isBordered = false
        clear.contentTintColor = .tertiaryLabelColor
        clear.target = self
        clear.action = #selector(clearShortcut)
        clear.toolTip = L("Turn off this shortcut")
        clear.translatesAutoresizingMaskIntoConstraints = false
        addSubview(text)
        addSubview(clear)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 132),
            heightAnchor.constraint(equalToConstant: 26),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            text.trailingAnchor.constraint(equalTo: clear.leadingAnchor, constant: -2),
            clear.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            clear.centerYAnchor.constraint(equalTo: centerYAnchor),
            clear.widthAnchor.constraint(equalToConstant: 14)
        ])
        setAccessibilityRole(.button)
        setAccessibilityLabel(L("Keyboard shortcut"))
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        recording.toggle()
        if recording { startMonitoring() } else { stopMonitoring() }
    }

    override func resignFirstResponder() -> Bool {
        if recording { stopMonitoring(); recording = false }
        return super.resignFirstResponder()
    }

    /// A local monitor sees combinations such as ⌘Q before menus can act on them.
    private func startMonitoring() {
        onError?(nil)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self, recording else { return event }
            if event.type == .flagsChanged {
                let symbols = HotKeyCombination(keyCode: 0, modifiers: KeyNames.carbonModifiers(event.modifierFlags)).modifierSymbols
                text.stringValue = symbols.isEmpty ? L("Type shortcut…") : symbols
                return nil
            }
            handle(event)
            return nil
        }
    }

    private func stopMonitoring() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func handle(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.subtracting([.capsLock, .numericPad, .function]).isEmpty {
            switch event.keyCode {
            case 53: finish(); return
            case 51, 117: finish(); apply(nil); return
            default: break
            }
        }
        let candidate = HotKeyCombination(keyCode: UInt32(event.keyCode), modifiers: KeyNames.carbonModifiers(flags))
        guard candidate.isValid else {
            NSSound.beep()
            onError?(L("Include ⌘, ⌥, or ⌃, or use a function key, so the shortcut doesn’t interfere with typing."))
            return
        }
        finish()
        apply(candidate)
    }

    private func finish() {
        stopMonitoring()
        recording = false
    }

    private func apply(_ value: HotKeyCombination?) {
        if let error = onChange?(value) {
            onError?(error)
            NSSound.beep()
        } else {
            onError?(nil)
            combination = value
        }
    }

    @objc private func clearShortcut() {
        if recording { finish() }
        apply(nil)
    }

    private func refresh() {
        if recording {
            text.stringValue = L("Type shortcut…")
            text.textColor = .controlAccentColor
            fill = NSColor.controlAccentColor.withAlphaComponent(0.12)
            border = .controlAccentColor
        } else {
            text.stringValue = combination.map(KeyNames.display) ?? L("Record Shortcut")
            text.textColor = combination == nil ? .tertiaryLabelColor : .labelColor
            fill = .controlBackgroundColor
            border = .separatorColor
        }
        clear.isHidden = combination == nil || recording
        setAccessibilityValue(text.stringValue)
    }
}
