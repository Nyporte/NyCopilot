import AppKit

/// The bar under a selection: drawing tools, undo and redo, then pin, save, cancel, and copy. While a
/// tool is active, a second row offers colors and line widths.
@MainActor
final class CaptureToolbar: NSView {
    var onTool: ((AnnotationTool) -> Void)?
    var onColor: ((NSColor) -> Void)?
    var onStroke: ((CGFloat) -> Void)?
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    var onAction: ((CaptureAction) -> Void)?
    var onCancel: (() -> Void)?

    var selectedTool: AnnotationTool? { didSet { refresh() } }
    var selectedColor: NSColor = .systemRed { didSet { refresh() } }
    var selectedStroke: CGFloat = 3 { didSet { refresh() } }
    var canUndo = false { didSet { undoButton.isEnabled = canUndo } }
    var canRedo = false { didSet { redoButton.isEnabled = canRedo } }

    static let strokes: [CGFloat] = [2, 4, 8]
    private var toolButtons: [AnnotationTool: NSButton] = [:]
    private var swatches: [(NSColor, Swatch)] = []
    private var strokeButtons: [(CGFloat, NSButton)] = []
    private let undoButton: NSButton
    private let redoButton: NSButton
    private let options: NSStackView
    private let palette: [NSColor]

    init(palette: [NSColor]) {
        self.palette = palette
        undoButton = Self.icon("arrow.uturn.backward", "Undo (⌘Z)")
        redoButton = Self.icon("arrow.uturn.forward", "Redo (⇧⌘Z)")
        options = Design.hstack([], spacing: 6)
        super.init(frame: .zero)

        let material = NSVisualEffectView.roundedMaterial(.hudWindow, radius: 10)
        material.translatesAutoresizingMaskIntoConstraints = false
        addSubview(material)

        var tools: [NSView] = []
        for (index, tool) in AnnotationTool.allCases.enumerated() {
            let button = Self.icon(tool.symbol, "\(tool.title) (\(index + 1))")
            button.target = self
            button.action = #selector(pickTool(_:))
            button.tag = index
            toolButtons[tool] = button
            tools.append(button)
        }
        undoButton.target = self
        undoButton.action = #selector(undo)
        undoButton.isEnabled = false
        redoButton.target = self
        redoButton.action = #selector(redo)
        redoButton.isEnabled = false
        let pin = Self.icon("pin", "Pin to screen (⌘T)")
        pin.target = self
        pin.action = #selector(pin(_:))
        let save = Self.icon("square.and.arrow.down", "Save… (⌘S) · Quick save (⇧⌘S)")
        save.target = self
        save.action = #selector(save(_:))
        let cancel = Self.icon("xmark", "Cancel (Esc)")
        cancel.target = self
        cancel.action = #selector(cancelTapped)
        let copy = Self.icon("checkmark", "Copy and close (Return)")
        copy.contentTintColor = .controlAccentColor
        copy.target = self
        copy.action = #selector(copy(_:))
        let mainRow = Design.hstack(tools + [Self.divider(), undoButton, redoButton, Self.divider(), pin, save, cancel, copy], spacing: 2)

        for color in palette {
            let swatch = Swatch(color: color)
            swatch.onPick = { [weak self] in self?.onColor?(color) }
            swatches.append((color, swatch))
            options.addArrangedSubview(swatch)
        }
        options.addArrangedSubview(Self.divider())
        for width in Self.strokes {
            let button = NSButton(image: Self.dot(width), target: self, action: #selector(pickStroke(_:)))
            button.isBordered = false
            button.toolTip = "Line width"
            button.tag = Int(width)
            button.widthAnchor.constraint(equalToConstant: 24).isActive = true
            strokeButtons.append((width, button))
            options.addArrangedSubview(button)
        }
        options.isHidden = true

        let column = Design.vstack([mainRow, options], spacing: 6, alignment: .leading)
        column.translatesAutoresizingMaskIntoConstraints = false
        material.addSubview(column)
        NSLayoutConstraint.activate([
            material.leadingAnchor.constraint(equalTo: leadingAnchor),
            material.trailingAnchor.constraint(equalTo: trailingAnchor),
            material.topAnchor.constraint(equalTo: topAnchor),
            material.bottomAnchor.constraint(equalTo: bottomAnchor),
            column.leadingAnchor.constraint(equalTo: material.leadingAnchor, constant: 6),
            column.trailingAnchor.constraint(equalTo: material.trailingAnchor, constant: -6),
            column.topAnchor.constraint(equalTo: material.topAnchor, constant: 5),
            column.bottomAnchor.constraint(equalTo: material.bottomAnchor, constant: -5)
        ])
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("Use init(palette:)") }

    override var isFlipped: Bool { true }

    private func refresh() {
        for (tool, button) in toolButtons {
            let active = tool == selectedTool
            button.contentTintColor = active ? .controlAccentColor : .white
            button.state = active ? .on : .off
        }
        for (color, swatch) in swatches { swatch.isSelected = color.isClose(to: selectedColor) }
        for (width, button) in strokeButtons { button.contentTintColor = width == selectedStroke ? .controlAccentColor : .white }
        let showOptions = selectedTool != nil && selectedTool != .mosaic
        if options.isHidden == showOptions {
            options.isHidden = !showOptions
            // Grow or shrink downward from the same top-right corner.
            let old = frame
            let size = fittingSize
            frame = CGRect(x: old.maxX - size.width, y: old.minY, width: size.width, height: size.height)
        }
    }

    @objc private func pickTool(_ sender: NSButton) { onTool?(AnnotationTool.allCases[sender.tag]) }
    @objc private func pickStroke(_ sender: NSButton) { onStroke?(CGFloat(sender.tag)) }
    @objc private func undo() { onUndo?() }
    @objc private func redo() { onRedo?() }
    @objc private func pin(_ sender: Any?) { onAction?(.pin) }
    @objc private func save(_ sender: Any?) {
        onAction?(NSEvent.modifierFlags.contains(.shift) ? .quickSave : .save)
    }
    @objc private func copy(_ sender: Any?) { onAction?(.copy) }
    @objc private func cancelTapped() { onCancel?() }

    private static func icon(_ symbol: String, _ tip: String) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!, target: nil, action: nil)
        button.isBordered = false
        button.symbolConfiguration = .init(pointSize: 14, weight: .medium)
        button.contentTintColor = .white
        button.toolTip = tip
        button.widthAnchor.constraint(equalToConstant: 28).isActive = true
        button.heightAnchor.constraint(equalToConstant: 26).isActive = true
        return button
    }

    private static func divider() -> NSView {
        let line = AppearanceView()
        line.fill = NSColor.white.withAlphaComponent(0.25)
        line.radius = 0
        line.translatesAutoresizingMaskIntoConstraints = false
        line.widthAnchor.constraint(equalToConstant: 1).isActive = true
        line.heightAnchor.constraint(equalToConstant: 16).isActive = true
        return line
    }

    /// A filled circle whose size shows the line width.
    private static func dot(_ width: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            NSColor.black.setFill()
            let size = min(4 + width * 1.2, 14)
            NSBezierPath(ovalIn: CGRect(x: rect.midX - size / 2, y: rect.midY - size / 2, width: size, height: size)).fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// A round color chip; the selected one wears a white ring.
private final class Swatch: NSView {
    var onPick: (() -> Void)?
    var isSelected = false { didSet { needsDisplay = true } }
    private let color: NSColor

    init(color: NSColor) {
        self.color = color
        super.init(frame: CGRect(x: 0, y: 0, width: 20, height: 20))
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 20).isActive = true
        heightAnchor.constraint(equalToConstant: 20).isActive = true
        setAccessibilityRole(.button)
        setAccessibilityLabel("Color")
    }

    required init?(coder: NSCoder) { fatalError("Use init(color:)") }

    override func draw(_ dirtyRect: NSRect) {
        let inner = bounds.insetBy(dx: 4, dy: 4)
        color.setFill()
        NSBezierPath(ovalIn: inner).fill()
        NSColor.white.withAlphaComponent(isSelected ? 1 : 0.35).setStroke()
        let ring = NSBezierPath(ovalIn: isSelected ? bounds.insetBy(dx: 1.5, dy: 1.5) : inner)
        ring.lineWidth = isSelected ? 2 : 0.5
        ring.stroke()
    }

    override func mouseDown(with event: NSEvent) { onPick?() }
    override func accessibilityPerformPress() -> Bool { onPick?(); return true }
}

extension NSColor {
    /// `#RRGGBB` → color; nil for anything else.
    convenience init?(hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                  blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    var hexString: String {
        let rgb = usingColorSpace(.sRGB) ?? self
        return String(format: "#%02X%02X%02X", Int(round(rgb.redComponent * 255)), Int(round(rgb.greenComponent * 255)),
                      Int(round(rgb.blueComponent * 255)))
    }

    func isClose(to other: NSColor) -> Bool { hexString == other.hexString }
}
