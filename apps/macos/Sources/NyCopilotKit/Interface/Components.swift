import AppKit

/// Shared building blocks so every window uses the same spacing, type, and grouped-form style.
@MainActor
enum Design {
    static let paneWidth: CGFloat = 560
    static let panePadding: CGFloat = 24
    static let sectionSpacing: CGFloat = 22
    static let cornerRadius: CGFloat = 10

    static func label(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular,
                      color: NSColor = .labelColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        return label
    }

    static func wrapping(_ text: String, size: CGFloat = 12, color: NSColor = .secondaryLabelColor) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: size)
        label.textColor = color
        label.isSelectable = false
        return label
    }

    static func symbol(_ name: String, size: CGFloat = 13, weight: NSFont.Weight = .regular,
                       color: NSColor = .secondaryLabelColor) -> NSImageView {
        let view = NSImageView(image: NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage())
        view.symbolConfiguration = .init(pointSize: size, weight: weight)
        view.contentTintColor = color
        view.setContentHuggingPriority(.required, for: .horizontal)
        return view
    }

    static func button(_ title: String, target: AnyObject?, action: Selector?, primary: Bool = false) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .regular
        if primary { button.keyEquivalent = "\r" }
        return button
    }

    static func hstack(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = spacing
        return stack
    }

    static func vstack(_ views: [NSView], spacing: CGFloat = 8, alignment: NSLayoutConstraint.Attribute = .leading) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = alignment
        stack.spacing = spacing
        return stack
    }

    static func spacer() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.init(1), for: .horizontal)
        view.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        return view
    }
}

/// A view whose layer colors re-resolve with the light/dark appearance.
class AppearanceView: NSView {
    var fill: NSColor? { didSet { needsDisplay = true } }
    var border: NSColor? { didSet { needsDisplay = true } }
    var radius: CGFloat = Design.cornerRadius { didSet { needsDisplay = true } }
    /// Continuous (squircle) corners suit most views; outlines that trace a `roundedMaterial`
    /// mask use circular corners so the two shapes line up exactly.
    var continuousCorners = true { didSet { needsDisplay = true } }
    /// Zero draws a hairline.
    var borderWidth: CGFloat = 0 { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer.backgroundColor = fill?.cgColor
            layer.borderColor = border?.cgColor
        }
        layer.borderWidth = border == nil ? 0 : (borderWidth > 0 ? borderWidth : 1 / (window?.backingScaleFactor ?? 2))
        layer.cornerRadius = radius
        layer.cornerCurve = continuousCorners ? .continuous : .circular
    }
}

extension NSWindow {
    /// What every NyCopilot overlay shares: borderless and clear, floating over other apps' windows on
    /// every Space and over full-screen apps, and kept when ordered out so it can come back.
    func float(at level: NSWindow.Level, shadow: Bool, clickThrough: Bool = false, behavior: NSWindow.CollectionBehavior = []) {
        self.level = level
        isOpaque = false
        backgroundColor = .clear
        hasShadow = shadow
        ignoresMouseEvents = clickThrough
        isReleasedWhenClosed = false
        collectionBehavior = behavior.union([.canJoinAllSpaces, .fullScreenAuxiliary])
    }
}

extension NSWindow.Level {
    /// Screen translation's layers: the highlights just above the menu bar, its card and capsule above them.
    static let screenOverlay = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
    static let screenOverlayControls = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
}

extension NSVisualEffectView {
    /// A frosted background for borderless floating panels, rounded with a mask image.
    ///
    /// A layer `cornerRadius` only clips drawn content: the window server still blurs and shadows
    /// the full rectangle, which shows as a square edge around the card. A mask image shapes the
    /// blur and the window shadow itself.
    static func roundedMaterial(_ material: NSVisualEffectView.Material, radius: CGFloat) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        let edge = radius * 2 + 1
        let mask = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        mask.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        mask.resizingMode = .stretch
        view.maskImage = mask
        return view
    }
}

/// System Settings–style group: an optional caption, rounded rows with hairline dividers, optional footnote.
final class FormSection: NSStackView {
    init(_ title: String? = nil, footer: String? = nil, rows: [NSView]) {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 6
        if let title {
            let caption = Design.label(title, size: 13, weight: .semibold)
            addArrangedSubview(caption)
            setCustomSpacing(8, after: caption)
        }
        let box = AppearanceView()
        box.fill = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor.white.withAlphaComponent(0.045) : NSColor.black.withAlphaComponent(0.028) }
        box.border = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor.white.withAlphaComponent(0.09) : NSColor.black.withAlphaComponent(0.07) }
        let column = NSStackView()
        column.orientation = .vertical
        column.spacing = 0
        column.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(column)
        for (index, row) in rows.enumerated() {
            if index > 0 {
                let divider = AppearanceView()
                divider.fill = .separatorColor
                divider.radius = 0
                divider.translatesAutoresizingMaskIntoConstraints = false
                column.addArrangedSubview(divider)
                NSLayoutConstraint.activate([
                    divider.heightAnchor.constraint(equalToConstant: 1),
                    divider.leadingAnchor.constraint(equalTo: column.leadingAnchor, constant: 12),
                    divider.trailingAnchor.constraint(equalTo: column.trailingAnchor, constant: -12)
                ])
            }
            column.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }
        addArrangedSubview(box)
        NSLayoutConstraint.activate([
            box.widthAnchor.constraint(equalTo: widthAnchor),
            column.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            column.topAnchor.constraint(equalTo: box.topAnchor),
            column.bottomAnchor.constraint(equalTo: box.bottomAnchor)
        ])
        if let footer {
            let note = Design.wrapping(footer, size: 11.5)
            addArrangedSubview(note)
            note.widthAnchor.constraint(equalTo: widthAnchor, constant: -8).isActive = true
            note.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4).isActive = true
        }
    }

    required init?(coder: NSCoder) { fatalError("Use init(_:footer:rows:)") }
}

/// One line of a form: a title (and optional explanation) on the left, a control on the right.
final class FormRow: NSView {
    let subtitleLabel: NSTextField?

    init(_ title: String, subtitle: String? = nil, accessory: NSView?) {
        // A long title (some languages run half again as long) wraps rather than pushing the
        // control or being cut off: the labels give way and the control keeps its full width.
        let titleLabel = Design.wrapping(title, size: 13, color: .labelColor)
        subtitleLabel = subtitle.map { Design.wrapping($0, size: 11.5) }
        for label in [titleLabel] + (subtitleLabel.map { [$0] } ?? []) {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        super.init(frame: .zero)
        let labels = Design.vstack([titleLabel] + (subtitleLabel.map { [$0] } ?? []), spacing: 2)
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)
        labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // The spacer takes the slack, so the control always sits at the right edge, however long
        // or short the title and subtitle are.
        let row = Design.hstack([labels, Design.spacer()] + (accessory.map { [$0] } ?? []), spacing: 16)
        row.translatesAutoresizingMaskIntoConstraints = false
        accessory?.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        accessory?.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        ])
    }

    required init?(coder: NSCoder) { fatalError("Use init(_:subtitle:accessory:)") }
}

/// A colored dot and short status word, used for permission and connection states.
final class StatusBadge: NSStackView {
    private let dot = AppearanceView()
    private let text = Design.label("", size: 12, color: .secondaryLabelColor)

    init() {
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 6
        alignment = .centerY
        dot.radius = 4
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([dot.widthAnchor.constraint(equalToConstant: 8), dot.heightAnchor.constraint(equalToConstant: 8)])
        addArrangedSubview(dot)
        addArrangedSubview(text)
    }

    required init?(coder: NSCoder) { fatalError("Use init()") }

    func set(_ title: String, color: NSColor) {
        text.stringValue = title
        dot.fill = color
    }
}

/// One line of feedback under a form: an icon and message, or a spinner while something runs.
@MainActor
final class StatusLine: NSStackView {
    enum Style { case info, success, error }

    private let icon = Design.symbol("circle", size: 13)
    private let spinner = NSProgressIndicator()
    private let label = NSTextField(wrappingLabelWithString: "")

    init() {
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 6
        alignment = .firstBaseline
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.maximumNumberOfLines = 3
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.isHidden = true
        icon.isHidden = true
        [icon, spinner, label].forEach(addArrangedSubview)
    }

    required init?(coder: NSCoder) { fatalError("Use init()") }

    func showProgress(_ text: String) {
        icon.isHidden = true
        spinner.isHidden = false
        spinner.startAnimation(nil)
        label.stringValue = text
        label.textColor = .secondaryLabelColor
    }

    /// nil clears the line.
    func show(_ text: String?, style: Style) {
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        label.stringValue = text ?? ""
        icon.isHidden = text == nil
        let (symbol, tint, color): (String, NSColor, NSColor) = switch style {
        case .info: ("info.circle", .secondaryLabelColor, .secondaryLabelColor)
        case .success: ("checkmark.circle.fill", .systemGreen, .labelColor)
        case .error: ("exclamationmark.triangle.fill", .systemOrange, .labelColor)
        }
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.contentTintColor = tint
        label.textColor = color
    }
}

extension NSView {
    /// Icon-only buttons in this view tree speak their tooltip to VoiceOver ("Copy (⌘C)", not
    /// "doc.on.doc"), unless they already have a label.
    func labelIconButtons() {
        if let button = self as? NSButton, button.title.isEmpty || button.imagePosition == .imageOnly,
           let tip = button.toolTip, !tip.isEmpty, (button.accessibilityLabel() ?? "").isEmpty {
            button.setAccessibilityLabel(tip)
        }
        subviews.forEach { $0.labelIconButtons() }
    }
}
