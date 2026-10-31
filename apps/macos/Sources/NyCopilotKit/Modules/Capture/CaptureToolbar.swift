import AppKit

/// The bar under a selection: drawing tools, undo and redo, then save, pin, cancel, and copy. While a
/// tool is active, a second row holds that tool's options: colors, line width, corner radius and fill
/// for shapes, and font, size, and emphasis for text.
@MainActor
final class CaptureToolbar: NSView {
    var onTool: ((AnnotationTool) -> Void)?
    var onColor: ((NSColor) -> Void)?
    var onStroke: ((CGFloat) -> Void)?
    var onStyle: ((CaptureStyle) -> Void)?
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    var onAction: ((CaptureAction) -> Void)?
    var onCancel: (() -> Void)?
    /// T: read the text in the selection, in place.
    var onText: (() -> Void)?
    /// The options row appeared or went: the bar's size changed and it needs placing again.
    var onResize: (() -> Void)?

    var selectedTool: AnnotationTool? { didSet { if selectedTool != oldValue { rebuildOptions() }; refreshTools() } }
    var selectedColor: NSColor = .systemRed { didSet { refreshSwatches() } }
    var selectedStroke: CGFloat = 3
    var style = CaptureStyle()
    var canUndo = false { didSet { undoButton.isEnabled = canUndo } }
    var canRedo = false { didSet { redoButton.isEnabled = canRedo } }
    /// Lines of text found in the selection; nil while still reading.
    var recognizedLines: Int? { didSet { refreshTextButton() } }

    private var toolButtons: [AnnotationTool: NSButton] = [:]
    private var swatches: [(NSColor, Swatch)] = []
    private let undoButton: NSButton
    private let redoButton: NSButton
    private let textButton = CaptureToolbar.icon("text.viewfinder", "Select text (T)")
    private let scrollButton = CaptureToolbar.icon("rectangle.expand.vertical", "Scrolling Capture (S)")
    private let options = Design.hstack([], spacing: 8)
    private let palette: [NSColor]
    private static let textSizes: [CGFloat] = [12, 14, 16, 20, 24, 32, 40, 48, 64, 96]

    init(palette: [NSColor]) {
        self.palette = palette
        undoButton = Self.icon("arrow.uturn.backward", "Undo (⌘Z)")
        redoButton = Self.icon("arrow.uturn.forward", "Redo (⇧⌘Z)")
        super.init(frame: .zero)
        // Always dark, like the overlay it sits on, so sliders and menus read well.
        appearance = NSAppearance(named: .darkAqua)

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
        let pin = Self.icon("pin", "Pin to the screen (P or ⌘T)")
        pin.target = self
        pin.action = #selector(pin(_:))
        textButton.target = self
        textButton.action = #selector(showText)
        scrollButton.target = self
        scrollButton.action = #selector(scrollCapture)
        let translate = Self.icon("character.bubble", "Translate its text (R)")
        translate.target = self
        translate.action = #selector(translateText)
        let inbox = Self.icon("tray.and.arrow.down", "Keep in Inbox (I)")
        inbox.target = self
        inbox.action = #selector(sendToInbox)
        let record = Self.icon("record.circle", "Record a GIF (G)")
        record.target = self
        record.action = #selector(recordGIF)
        let ask = Self.icon("sparkles", "Ask AI about it (A)")
        ask.target = self
        ask.action = #selector(askAI)
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
        // Grouped by purpose, left to right: draw, undo, read and file it, keep it, finish.
        let groups: [[NSView]] = [tools, [undoButton, redoButton], [textButton, translate, ask, inbox],
                                  [record, scrollButton, pin, save], [cancel, copy]]
        let mainRow = Design.hstack(groups.map { Design.hstack($0, spacing: 2) }.flatMap { [Self.divider(), $0] }.dropFirst().map { $0 }, spacing: 6)
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
            // Just below required: the bar is frame-sized by its owner, and for a moment while the
            // options row comes or goes, the frame is the old size. Required, that moment logged a
            // conflict for every view in the bar on every capture.
            {
                let bottom = column.bottomAnchor.constraint(equalTo: material.bottomAnchor, constant: -6)
                bottom.priority = .init(999)
                return bottom
            }()
        ])
        setFrameSize(fittingSize)
        refreshTools()
    }

    required init?(coder: NSCoder) { fatalError("Use init(palette:)") }

    override var isFlipped: Bool { true }

    // MARK: Options row

    /// Each tool shows only what applies to it.
    private func rebuildOptions() {
        options.arrangedSubviews.forEach { $0.removeFromSuperview() }
        swatches.removeAll()
        defer { onResize?() }
        guard let tool = selectedTool else { options.isHidden = true; return }
        options.isHidden = false
        if tool != .mosaic {
            for color in palette {
                let swatch = Swatch(color: color)
                swatch.onPick = { [weak self] in self?.onColor?(color) }
                swatches.append((color, swatch))
                options.addArrangedSubview(swatch)
            }
            refreshSwatches()
        }
        switch tool {
        case .text:
            options.addArrangedSubview(Self.divider())
            options.addArrangedSubview(fontMenu())
            options.addArrangedSubview(sizeMenu())
            options.addArrangedSubview(emphasis())
        default:
            if tool != .mosaic { options.addArrangedSubview(Self.divider()) }
            options.addArrangedSubview(slider(symbol: tool == .mosaic ? "circle.dotted" : "lineweight", tip: tool == .mosaic ? "Brush size" : "Line width",
                                              value: Double(selectedStroke), range: 1...24, action: #selector(strokeChanged(_:))))
            if tool == .rectangle {
                options.addArrangedSubview(slider(symbol: "square.dashed", tip: "Corner radius", value: Double(style.cornerRadius),
                                                  range: 0...40, action: #selector(radiusChanged(_:))))
            }
            if tool == .rectangle || tool == .ellipse { options.addArrangedSubview(fillControl(for: tool)) }
        }
    }

    /// A small slider with an icon and its live value, e.g. "⧉ ——●—— 4".
    private func slider(symbol: String, tip: String, value: Double, range: ClosedRange<Double>, action: Selector) -> NSView {
        let slider = NSSlider(value: value, minValue: range.lowerBound, maxValue: range.upperBound, target: self, action: action)
        slider.controlSize = .small
        slider.isContinuous = true
        slider.toolTip = tip
        slider.widthAnchor.constraint(equalToConstant: 84).isActive = true
        let label = Design.label("\(Int(value))", size: 11, weight: .medium, color: .white)
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        label.widthAnchor.constraint(equalToConstant: 18).isActive = true
        slider.identifier = NSUserInterfaceItemIdentifier(tip)
        valueLabels[tip] = label
        return Design.hstack([Design.symbol(symbol, size: 11, color: .white.withAlphaComponent(0.7)), slider, label], spacing: 4)
    }
    private var valueLabels: [String: NSTextField] = [:]

    private func fillControl(for tool: AnnotationTool) -> NSSegmentedControl {
        let outline = NSImage(systemSymbolName: tool == .ellipse ? "circle" : "square", accessibilityDescription: "Outline")!
        let filled = NSImage(systemSymbolName: tool == .ellipse ? "circle.fill" : "square.fill", accessibilityDescription: "Filled")!
        let control = NSSegmentedControl(images: [outline, filled], trackingMode: .selectOne, target: self, action: #selector(fillChanged(_:)))
        control.controlSize = .small
        control.selectedSegment = style.filled ? 1 : 0
        control.setToolTip("Outline", forSegment: 0)
        control.setToolTip("Filled", forSegment: 1)
        return control
    }

    /// Starts with just the current font; every family, each shown in its own face, is added when
    /// the menu first opens, since loading them all takes a noticeable moment.
    private func fontMenu() -> NSPopUpButton {
        let button = NSPopUpButton()
        button.controlSize = .small
        button.addItem(withTitle: style.font.isEmpty ? Self.systemFontTitle : style.font)
        button.menu?.delegate = self
        button.target = self
        button.action = #selector(fontChanged(_:))
        button.toolTip = "Font"
        button.widthAnchor.constraint(equalToConstant: 128).isActive = true
        fontButton = button
        return button
    }
    private weak var fontButton: NSPopUpButton?
    private static let systemFontTitle = "System Font"

    private func sizeMenu() -> NSPopUpButton {
        let menu = NSPopUpButton()
        menu.controlSize = .small
        let sizes = Self.textSizes.contains(style.textSize) ? Self.textSizes : (Self.textSizes + [style.textSize]).sorted()
        menu.addItems(withTitles: sizes.map { "\(Int($0)) pt" })
        menu.selectItem(withTitle: "\(Int(style.textSize)) pt")
        menu.target = self
        menu.action = #selector(sizeChanged(_:))
        menu.toolTip = "Text size"
        return menu
    }

    /// Bold, italic, underline, strikethrough — any combination.
    private func emphasis() -> NSSegmentedControl {
        let control = NSSegmentedControl(labels: ["B", "I", "U", "S"], trackingMode: .selectAny, target: self, action: #selector(emphasisChanged(_:)))
        control.controlSize = .small
        for (index, symbol) in ["bold", "italic", "underline", "strikethrough"].enumerated() {
            control.setImage(NSImage(systemSymbolName: symbol, accessibilityDescription: symbol.capitalized), forSegment: index)
            control.setLabel("", forSegment: index)
            control.setWidth(24, forSegment: index)
            control.setToolTip(symbol.capitalized, forSegment: index)
        }
        for (index, on) in [style.bold, style.italic, style.underline, style.strikethrough].enumerated() { control.setSelected(on, forSegment: index) }
        return control
    }

    // MARK: Option actions

    @objc private func strokeChanged(_ sender: NSSlider) {
        let width = CGFloat(sender.integerValue)
        selectedStroke = width
        valueLabels[sender.identifier?.rawValue ?? ""]?.stringValue = "\(Int(width))"
        onStroke?(width)
    }

    @objc private func radiusChanged(_ sender: NSSlider) {
        style.cornerRadius = CGFloat(sender.integerValue)
        valueLabels["Corner radius"]?.stringValue = "\(sender.integerValue)"
        onStyle?(style)
    }

    @objc private func fillChanged(_ sender: NSSegmentedControl) {
        style.filled = sender.selectedSegment == 1
        onStyle?(style)
    }

    @objc private func fontChanged(_ sender: NSPopUpButton) {
        let title = sender.titleOfSelectedItem ?? Self.systemFontTitle
        style.font = title == Self.systemFontTitle ? "" : title
        onStyle?(style)
    }

    @objc private func sizeChanged(_ sender: NSPopUpButton) {
        if let title = sender.titleOfSelectedItem, let size = Double(title.replacingOccurrences(of: " pt", with: "")) {
            style.textSize = CGFloat(size)
            onStyle?(style)
        }
    }

    @objc private func emphasisChanged(_ sender: NSSegmentedControl) {
        style.bold = sender.isSelected(forSegment: 0)
        style.italic = sender.isSelected(forSegment: 1)
        style.underline = sender.isSelected(forSegment: 2)
        style.strikethrough = sender.isSelected(forSegment: 3)
        onStyle?(style)
    }

    // MARK: Main row

    private func refreshTools() {
        for (tool, button) in toolButtons {
            let active = tool == selectedTool
            button.contentTintColor = active ? .controlAccentColor : .white
            button.state = active ? .on : .off
        }
    }

    private func refreshSwatches() {
        for (color, swatch) in swatches { swatch.isSelected = color.isClose(to: selectedColor) }
    }

    @objc private func pickTool(_ sender: NSButton) { onTool?(AnnotationTool.allCases[sender.tag]) }
    @objc private func undo() { onUndo?() }
    @objc private func redo() { onRedo?() }
    @objc private func pin(_ sender: Any?) { onAction?(.pin) }
    @objc private func translateText() { onAction?(.translate) }
    @objc private func sendToInbox() { onAction?(.inbox) }
    @objc private func askAI() { onAction?(.ask) }
    @objc private func recordGIF() { onAction?(.record) }
    @objc private func save(_ sender: Any?) {
        onAction?(NSEvent.modifierFlags.contains(.shift) ? .quickSave : .save)
    }
    @objc private func copy(_ sender: Any?) { onAction?(.copy) }
    @objc private func showText() { onText?() }
    @objc private func scrollCapture() { onAction?(.scroll) }

    /// Accent when the selection has text, dimmed when it has none.
    private func refreshTextButton() {
        switch recognizedLines {
        case nil:
            textButton.contentTintColor = .white
            textButton.toolTip = "Recognize Text (T)"
        case 0?:
            textButton.contentTintColor = .white.withAlphaComponent(0.4)
            textButton.toolTip = "No text found here (T)"
        case let lines?:
            textButton.contentTintColor = .controlAccentColor
            textButton.toolTip = "Select the \(lines) line\(lines == 1 ? "" : "s") of text in place (T)"
        }
    }
    @objc private func cancelTapped() { onCancel?() }

    private static func icon(_ symbol: String, _ tip: String) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!, target: nil, action: nil)
        button.isBordered = false
        button.symbolConfiguration = .init(pointSize: 14, weight: .medium)
        button.contentTintColor = .white
        button.toolTip = tip
        button.setAccessibilityLabel(tip)
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
}

extension CaptureToolbar: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu.items.count <= 1 else { return }
        let current = menu.items.first?.title ?? Self.systemFontTitle
        menu.removeAllItems()
        menu.addItem(withTitle: Self.systemFontTitle, action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        for family in NSFontManager.shared.availableFontFamilies where !family.hasPrefix(".") {
            let item = menu.addItem(withTitle: family, action: nil, keyEquivalent: "")
            item.attributedTitle = NSAttributedString(string: family, attributes: [.font: NSFont(name: family, size: 13) ?? NSFont.systemFont(ofSize: 13)])
        }
        if let button = fontButton, let item = menu.items.first(where: { $0.title == current }) { button.select(item) }
    }
}

/// Replaces the toolbar while the selection is Live Text: a hint, Copy All (T again), and Done (Esc).
@MainActor
final class CaptureTextBar: NSView {
    var onCopyAll: (() -> Void)?
    var onDone: (() -> Void)?

    private let spinner = NSProgressIndicator()
    private let hint = Design.label("", size: 12, weight: .medium, color: .white)
    private let copyAll = NSButton(title: "Copy All  T", target: nil, action: nil)
    private let done = NSButton(title: "Done  esc", target: nil, action: nil)
    private var restoreHint: DispatchWorkItem?
    private var lines = 0

    init() {
        super.init(frame: .zero)
        appearance = NSAppearance(named: .darkAqua)
        let material = NSVisualEffectView.roundedMaterial(.hudWindow, radius: 10)
        material.translatesAutoresizingMaskIntoConstraints = false
        addSubview(material)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        for (button, action) in [(copyAll, #selector(copyAllTapped)), (done, #selector(doneTapped))] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.target = self
            button.action = action
        }
        copyAll.keyEquivalent = ""
        copyAll.bezelColor = .controlAccentColor
        let icon = Design.symbol("text.viewfinder", size: 13, color: .controlAccentColor)
        let row = Design.hstack([icon, spinner, hint, Design.spacer(), done, copyAll], spacing: 8)
        row.translatesAutoresizingMaskIntoConstraints = false
        material.addSubview(row)
        NSLayoutConstraint.activate([
            material.leadingAnchor.constraint(equalTo: leadingAnchor),
            material.trailingAnchor.constraint(equalTo: trailingAnchor),
            material.topAnchor.constraint(equalTo: topAnchor),
            material.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: material.leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(equalTo: material.trailingAnchor, constant: -8),
            row.topAnchor.constraint(equalTo: material.topAnchor, constant: 6),
            row.bottomAnchor.constraint(equalTo: material.bottomAnchor, constant: -6)
        ])
    }

    required init?(coder: NSCoder) { fatalError("Use init()") }

    override var isFlipped: Bool { true }

    func showReading() {
        spinner.startAnimation(nil)
        hint.stringValue = "Reading text…"
        copyAll.isEnabled = false
    }

    func show(lines: Int) {
        self.lines = lines
        spinner.stopAnimation(nil)
        copyAll.isEnabled = lines > 0
        hint.stringValue = baseHint
    }

    /// A short confirmation in place of the hint.
    func flash(_ text: String) {
        hint.stringValue = text
        restoreHint?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            hint.stringValue = baseHint
        }
        restoreHint = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    private var baseHint: String {
        lines > 0 ? "Drag across the text to select it · ⌘C copies" : "No text found here"
    }

    @objc private func copyAllTapped() { onCopyAll?() }
    @objc private func doneTapped() { onDone?() }
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
        setAccessibilityLabel("Color \(color.hexString)")
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
