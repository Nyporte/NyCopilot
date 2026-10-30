import AppKit

/// A translation on a frosted card just below its source — the block under the pointer, or the
/// selection — or above it near the bottom of the screen. It never takes a click.
@MainActor
final class TranslationCard: NSPanel {
    private let caption = Design.label("", size: 11, weight: .medium, color: .secondaryLabelColor)
    private let text = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    /// The keys that work while the card is up, when there are any.
    private let hint = Design.label("", size: 10.5, color: .tertiaryLabelColor)
    private let column: NSStackView
    private var source = NSRect.zero
    private var placedOn: NSScreen?
    private static let width: (min: CGFloat, max: CGFloat) = (220, 480)

    init() {
        column = Design.vstack([], spacing: 5, alignment: .leading)
        super.init(contentRect: NSRect(x: 0, y: 0, width: 300, height: 60), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        float(at: .screenOverlayControls, shadow: true, clickThrough: true, behavior: [.stationary, .ignoresCycle])
        let material = NSVisualEffectView.roundedMaterial(.popover, radius: 10)
        text.font = .systemFont(ofSize: 14)
        text.textColor = .labelColor
        text.isSelectable = false
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
            column.leadingAnchor.constraint(equalTo: material.leadingAnchor, constant: 12),
            column.trailingAnchor.constraint(equalTo: material.trailingAnchor, constant: -12),
            column.topAnchor.constraint(equalTo: material.topAnchor, constant: 9),
            column.bottomAnchor.constraint(equalTo: material.bottomAnchor, constant: -11)
        ])
        contentView = material
    }

    /// Where the card belongs: `source` is the block, in AppKit screen coordinates.
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

    /// As wide as the block (within limits), sized to the text, below the block or else above it, and
    /// always on its screen.
    private func place() {
        guard let screen = placedOn else { return }
        let visible = screen.visibleFrame
        let width = min(max(source.width + 8, Self.width.min), Self.width.max, visible.width - 16)
        text.preferredMaxLayoutWidth = width - 24
        column.layoutSubtreeIfNeeded()
        let height = column.fittingSize.height + 20
        var origin = NSPoint(x: source.minX - 4, y: source.minY - 8 - height)
        if origin.y < visible.minY + 8 { origin.y = source.maxY + 8 }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - 8 - width)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - 8 - height)
        setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
        orderFrontRegardless()
    }
}
