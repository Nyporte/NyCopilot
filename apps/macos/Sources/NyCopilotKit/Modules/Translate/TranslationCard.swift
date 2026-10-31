import AppKit

/// A translation on a frosted card just below its source — the block under the pointer, or the
/// selection — or above it near the bottom of the screen. A hover card lets every click through; an
/// interactive one (for a selection) takes clicks, so its text can be selected and copied, without
/// taking focus from the app you're in.
@MainActor
final class TranslationCard: NSPanel {
    private let interactive: Bool
    private let caption = Design.label("", size: 12, weight: .medium, color: .secondaryLabelColor)
    private let text = SelectableLabel(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    /// The keys that work while the card is up, when there are any.
    private let hint = Design.label("", size: 11, color: .tertiaryLabelColor)
    private let column: NSStackView
    private var source = NSRect.zero
    private var placedOn: NSScreen?
    /// Translations usually run longer than their source, so the card gives them room.
    private static let width: (min: CGFloat, max: CGFloat) = (340, 640)
    private static let padding = (horizontal: CGFloat(16), top: CGFloat(12), bottom: CGFloat(14))

    init(interactive: Bool = false) {
        self.interactive = interactive
        column = Design.vstack([], spacing: 7, alignment: .leading)
        super.init(contentRect: NSRect(x: 0, y: 0, width: 300, height: 60), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        float(at: .screenOverlayControls, shadow: true, clickThrough: !interactive, behavior: [.stationary, .ignoresCycle])
        let material = NSVisualEffectView.roundedMaterial(.popover, radius: 12)
        text.font = .systemFont(ofSize: 15.5)
        text.textColor = .labelColor
        text.isSelectable = interactive
        // A long selection stays a card; ⌘C still copies all of it.
        text.maximumNumberOfLines = 20
        text.cell?.truncatesLastVisibleLine = true
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        column.addArrangedSubview(Design.hstack([caption, spinner], spacing: 6))
        column.addArrangedSubview(text)
        column.addArrangedSubview(hint)
        column.translatesAutoresizingMaskIntoConstraints = false
        material.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: material.leadingAnchor, constant: Self.padding.horizontal),
            column.trailingAnchor.constraint(equalTo: material.trailingAnchor, constant: -Self.padding.horizontal),
            column.topAnchor.constraint(equalTo: material.topAnchor, constant: Self.padding.top),
            column.bottomAnchor.constraint(equalTo: material.bottomAnchor, constant: -Self.padding.bottom)
        ])
        contentView = material
    }

    /// Where the card belongs: `source` is the block, in AppKit screen coordinates.
    /// Selecting text needs keystrokes and a field editor; only an interactive card takes them.
    override var canBecomeKey: Bool { interactive }

    /// The part of the translation selected on the card, if any.
    var selectedText: String? {
        guard let editor = text.currentEditor(), editor.selectedRange.length > 0 else { return nil }
        return (editor.string as NSString).substring(with: editor.selectedRange)
    }

    func present(language: String, beside source: NSRect, on screen: NSScreen, hint: String? = nil) {
        self.source = source
        placedOn = screen
        caption.stringValue = language
        self.hint.stringValue = hint ?? ""
        self.hint.isHidden = hint == nil
    }

    func show(_ translation: String) {
        spinner.stopAnimation(nil)
        text.textColor = .labelColor
        text.stringValue = translation
        place()
    }

    func showWaiting() {
        spinner.startAnimation(nil)
        text.textColor = .secondaryLabelColor
        text.stringValue = "Translating…"
        place()
    }

    func show(failure message: String) {
        spinner.stopAnimation(nil)
        text.textColor = .systemOrange
        text.stringValue = message
        place()
    }

    /// A bit wider than the block, and wider still for a long translation (within limits), sized to the text, below the block or else above it, and
    /// always on its screen.
    private func place() {
        guard let screen = placedOn else { return }
        let visible = screen.visibleFrame
        let widest = min(Self.width.max, visible.width - 16)
        var width = min(max(source.width * 1.15 + Self.padding.horizontal * 2, Self.width.min), widest)
        text.preferredMaxLayoutWidth = width - Self.padding.horizontal * 2
        // A long translation widens the card rather than standing as a tall, narrow column.
        let line = (text.font ?? .systemFont(ofSize: 15.5)).boundingRectForFont.height
        while width < widest, text.fittingSize.height > line * 3 {
            width = min(width + 80, widest)
            text.preferredMaxLayoutWidth = width - Self.padding.horizontal * 2
        }
        column.layoutSubtreeIfNeeded()
        let height = column.fittingSize.height + Self.padding.top + Self.padding.bottom
        var origin = NSPoint(x: source.minX - 4, y: source.minY - 8 - height)
        if origin.y < visible.minY + 8 { origin.y = source.maxY + 8 }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - 8 - width)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - 8 - height)
        setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
        orderFrontRegardless()
    }
}

/// Text that can be selected with the first click, even while another app is in front.
private final class SelectableLabel: NSTextField {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
