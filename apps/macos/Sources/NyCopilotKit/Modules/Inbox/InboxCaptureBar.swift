import AppKit

/// The quick capture bar: one box, always in the same place (the upper part of the screen you're
/// on), so jotting is muscle memory. A tag below shows where you are — saved with the note.
/// ↩ saves and puts the bar away, ⇧↩ adds a line, Esc puts it away keeping what you typed for next
/// time, ⌘O opens the inbox. No list here: the bar is for getting a thought out of your head.
@MainActor
final class InboxCaptureBar {
    var onSave: ((String, SourceContext) -> Void)?
    var onOpenInbox: (() -> Void)?

    private let panel = FloatingPanel(size: NSSize(width: 560, height: 92))
    private let input = JotView()
    private var inputHeight: NSLayoutConstraint!
    private let source = Design.label("", size: 11.5, color: .secondaryLabelColor)
    private let sourceIcon = Design.symbol("macwindow", size: 11, color: .secondaryLabelColor)
    private let hint = Design.label("", size: 11, color: .tertiaryLabelColor)
    private var context = SourceContext()
    private var returnTo: NSRunningApplication?
    private static let width: CGFloat = 560, lineHeight: CGFloat = 20

    init() {
        panel.onResignKey = { [weak self] in self?.close(returningFocus: false) }
        panel.onCommand = { [weak self] key, shift in
            guard key == "o", !shift else { return false }
            self?.close(returningFocus: false)
            self?.onOpenInbox?()
            return true
        }
        let material = NSVisualEffectView.roundedMaterial(.popover, radius: 12)
        let icon = Design.symbol("tray.and.arrow.down", size: 16, color: .secondaryLabelColor)
        input.font = .systemFont(ofSize: 16)
        input.isRichText = false
        input.allowsUndo = true
        input.drawsBackground = false
        input.textContainerInset = NSSize(width: 0, height: 2)
        // A text view in a scroll view has to be told to fill its width and grow downward; left at
        // its zero-size frame, it never lays out what's typed.
        input.minSize = .zero
        input.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        input.isVerticallyResizable = true
        input.isHorizontallyResizable = false
        input.autoresizingMask = [.width]
        input.textContainer?.widthTracksTextView = true
        input.textContainer?.lineFragmentPadding = 0
        input.placeholder = "Jot something down"
        input.onSubmit = { [weak self] in self?.save() }
        input.onCancel = { [weak self] in self?.close() }
        input.onChange = { [weak self] in self?.fit() }
        let scroll = NSScrollView()
        scroll.documentView = input
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let chip = Design.hstack([sourceIcon, source], spacing: 5)
        source.lineBreakMode = .byTruncatingMiddle
        source.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for view in [icon, scroll, chip, hint] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            material.addSubview(view)
        }
        input.frame = NSRect(x: 0, y: 0, width: Self.width - 16 - 16 - 10 - 14, height: Self.lineHeight + 6)
        inputHeight = scroll.heightAnchor.constraint(equalToConstant: Self.lineHeight + 6)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: material.leadingAnchor, constant: 16),
            icon.topAnchor.constraint(equalTo: material.topAnchor, constant: 17),
            scroll.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            scroll.trailingAnchor.constraint(equalTo: material.trailingAnchor, constant: -14),
            scroll.topAnchor.constraint(equalTo: material.topAnchor, constant: 13),
            inputHeight,
            chip.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            chip.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 10),
            chip.trailingAnchor.constraint(lessThanOrEqualTo: hint.leadingAnchor, constant: -12),
            hint.trailingAnchor.constraint(equalTo: material.trailingAnchor, constant: -16),
            hint.centerYAnchor.constraint(equalTo: chip.centerYAnchor),
            chip.bottomAnchor.constraint(equalTo: material.bottomAnchor, constant: -12)
        ])
        panel.contentView = material
    }

    var isVisible: Bool { panel.isVisible }

    /// Opens on the screen with the pointer, a fifth of the way down, with whatever was left last time.
    func present(context: SourceContext, returningTo app: NSRunningApplication?, waiting: Int) {
        self.context = context
        returnTo = app
        let place = [context.app, context.title].filter { !$0.isEmpty }.joined(separator: " — ")
        source.stringValue = place.isEmpty ? "No source" : place
        sourceIcon.image = NSImage(systemSymbolName: context.url.hasPrefix("http") ? "globe" : "macwindow", accessibilityDescription: nil)
        hint.stringValue = "↩ save   ⇧↩ new line   ⌘O inbox" + (waiting > 0 ? " (\(waiting))" : "")
        fit()
        let pointer = NSEvent.mouseLocation
        let screen = ScreenGeometry.screen(at: pointer)
        let visible = screen.visibleFrame
        let top = visible.maxY - visible.height * 0.2
        panel.setFrameTopLeftPoint(NSPoint(x: visible.midX - Self.width / 2, y: top))
        // The panel takes typing without activating the app: activating would bring the app's
        // other windows (an open inbox) forward along with it.
        panel.present(focus: input)
        input.selectAll(nil)
    }

    /// Puts the bar away, keeping what's typed; back to the app you were in unless you clicked elsewhere.
    func close(returningFocus: Bool = true) {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        if returningFocus, let returnTo, !returnTo.isTerminated { returnTo.activate(options: []) }
    }

    private func save() {
        let text = input.string
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { close(); return }
        onSave?(text, context)
        input.string = ""
        close()
    }

    /// One line, growing to six as you type; the bar grows downward from where it sits.
    private func fit() {
        guard let layout = input.layoutManager, let container = input.textContainer else { return }
        layout.ensureLayout(for: container)
        let lines = max(1, min(6, Int((layout.usedRect(for: container).height / Self.lineHeight).rounded(.up))))
        inputHeight.constant = CGFloat(lines) * Self.lineHeight + 6
        let height = inputHeight.constant + 13 + 10 + 16 + 12
        let top = panel.frame.maxY
        panel.setFrame(NSRect(x: panel.frame.minX, y: top - height, width: Self.width, height: height), display: true)
    }
}

/// A box to jot into: ↩ submits, ⇧↩ (or ⌥↩) a new line, Esc cancels.
final class JotView: NSTextView {
    var onSubmit: (() -> Void)?
    var onCancel: (() -> Void)?
    var onChange: (() -> Void)?
    var placeholder = "" { didSet { needsDisplay = true } }

    override func doCommand(by selector: Selector) {
        let flags = NSApp.currentEvent?.modifierFlags.intersection([.shift, .option]) ?? []
        switch selector {
        case #selector(insertNewline(_:)) where flags.isEmpty && !hasMarkedText(): onSubmit?()
        case #selector(insertNewline(_:)): insertNewlineIgnoringFieldEditor(nil)
        case #selector(cancelOperation(_:)): onCancel?()
        default: super.doCommand(by: selector)
        }
    }

    override func didChangeText() {
        super.didChangeText()
        onChange?()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        (placeholder as NSString).draw(at: NSPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0), y: textContainerInset.height),
                                       withAttributes: [.font: font ?? .systemFont(ofSize: 16), .foregroundColor: NSColor.placeholderTextColor])
    }
}
