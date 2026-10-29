import AppKit

/// Shared building blocks so every window uses the same spacing, type, and grouped-form style.
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
        layer.borderWidth = border == nil ? 0 : 1 / (window?.backingScaleFactor ?? 2)
        layer.cornerRadius = radius
        layer.cornerCurve = continuousCorners ? .continuous : .circular
    }
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
        let titleLabel = Design.label(title)
        subtitleLabel = subtitle.map { Design.wrapping($0, size: 11.5) }
        super.init(frame: .zero)
        let labels = Design.vstack([titleLabel] + (subtitleLabel.map { [$0] } ?? []), spacing: 2)
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)
        labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = Design.hstack([labels] + (accessory.map { [$0] } ?? []), spacing: 16)
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

/// A small rounded key cap, e.g. "⇧↵", for inline keyboard hints.
final class KeyCap: AppearanceView {
    private let text: NSTextField

    init(_ keys: String) {
        text = Design.label(keys, size: 10.5, weight: .medium, color: .secondaryLabelColor)
        super.init(frame: .zero)
        radius = 4
        fill = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor.white.withAlphaComponent(0.1) : NSColor.black.withAlphaComponent(0.06) }
        text.translatesAutoresizingMaskIntoConstraints = false
        addSubview(text)
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            text.topAnchor.constraint(equalTo: topAnchor, constant: 1.5),
            text.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1.5)
        ])
        setContentHuggingPriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("Use init(_:)") }

    var keys: String {
        get { text.stringValue }
        set { text.stringValue = newValue }
    }
}

/// The NyCopilot mark: a four-point sparkle with a smaller companion, drawn as vector paths.
enum BrandGlyph {
    static func sparkle(center: NSPoint, radius: CGFloat, pinch: CGFloat = 0.16) -> NSBezierPath {
        let path = NSBezierPath()
        let points = [NSPoint(x: 0, y: 1), NSPoint(x: 1, y: 0), NSPoint(x: 0, y: -1), NSPoint(x: -1, y: 0)]
        path.move(to: NSPoint(x: center.x, y: center.y + radius))
        for index in 0..<4 {
            let from = points[index], to = points[(index + 1) % 4]
            let control = NSPoint(x: center.x + (from.x + to.x) * radius * pinch, y: center.y + (from.y + to.y) * radius * pinch)
            path.curve(to: NSPoint(x: center.x + to.x * radius, y: center.y + to.y * radius), controlPoint1: control, controlPoint2: control)
        }
        path.close()
        return path
    }

    /// Both sparkles inside a square, matching the app icon's composition.
    static func mark(in rect: NSRect) -> NSBezierPath {
        let size = min(rect.width, rect.height)
        let path = sparkle(center: NSPoint(x: rect.minX + size * 0.43, y: rect.minY + size * 0.43), radius: size * 0.42)
        path.append(sparkle(center: NSPoint(x: rect.minX + size * 0.80, y: rect.minY + size * 0.80), radius: size * 0.18))
        return path
    }

    /// Template image for the menu bar, so macOS tints it for light, dark, and highlighted states.
    static func menuBarImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            NSColor.black.setFill()
            mark(in: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "NyCopilot"
        return image
    }
}
