import AppKit

/// The borderless floating panel every quick surface is built on (the capture bar, the clipboard
/// list, Ask AI, the GIF preview). It takes keys without activating NyCopilot, so the app you were
/// in keeps its focus and NyCopilot's other windows stay where they are. ⌘ keys go to `onCommand`,
/// Esc to `onCancel`, and losing key status (a click elsewhere) to `onResignKey`. Its buttons never
/// take keyboard focus: the panel's keys are its own, so no button is ringed and Space does nothing.
class FloatingPanel: NSPanel {
    /// A ⌘ key (shift tells whether ⇧ was held too); true when handled.
    var onCommand: ((_ key: String, _ shift: Bool) -> Bool)?
    var onCancel: (() -> Void)?
    var onResignKey: (() -> Void)?
    /// False for panels that only show (a recording bar): clicks still work, keys stay with your app.
    var takesKeys = true

    init(size: NSSize, level: NSWindow.Level = .floating, shadow: Bool = true, behavior: NSWindow.CollectionBehavior = .transient) {
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: true)
        float(at: level, shadow: shadow, behavior: behavior)
    }

    override var canBecomeKey: Bool { takesKeys }

    override var contentView: NSView? {
        didSet {
            contentView.map(Self.refuseFocus)
            contentView?.labelIconButtons()
        }
    }

    /// Shows the panel and makes it key without activating NyCopilot; `focus` gets the typing.
    func present(focus: NSResponder? = nil) {
        orderFrontRegardless()
        guard takesKeys else { return }
        makeKey()
        makeFirstResponder(focus)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if flags.subtracting(.shift) == [.command], let key = event.charactersIgnoringModifiers?.lowercased(),
           onCommand?(key, flags.contains(.shift)) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        if let onCancel { onCancel() } else { super.cancelOperation(sender) }
    }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }

    /// Buttons anywhere in `view` stay out of the key loop; text fields still take focus.
    static func refuseFocus(in view: NSView) {
        if let button = view as? NSButton { button.refusesFirstResponder = true }
        view.subviews.forEach(refuseFocus)
    }
}
