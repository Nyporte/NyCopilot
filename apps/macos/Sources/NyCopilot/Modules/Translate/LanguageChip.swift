import AppKit

/// A tiny rounded square showing the target language as a short code (EN, 简, 日…). Clicking it opens
/// it into a short list, anchored at its top-right corner; choosing a language closes it again.
@MainActor
final class LanguageChip: NSView {
    static let collapsedSize: CGFloat = 30
    private static let (expandedWidth, rowHeight, listInset): (CGFloat, CGFloat, CGFloat) = (176, 26, 5)

    var onChoose: ((String) -> Void)?
    var onOther: (() -> Void)?
    /// Asks the owner to resize its window around the chip's new size.
    var onResize: (() -> Void)?

    var languages: [String] = [] { didSet { rebuildList() } }
    var language = "" {
        didSet {
            code.stringValue = Self.code(for: language)
            code.font = .systemFont(ofSize: code.stringValue.unicodeScalars.first.map { $0.value > 0x2E80 } == true ? 13 : 11.5,
                                    weight: .semibold)
            toolTip = "Translating into \(language) — click to change"
            setAccessibilityLabel("Target language: \(language)")
            rebuildList()
        }
    }
    var isBusy = false {
        didSet {
            code.isHidden = isBusy || isExpanded
            spinner.isHidden = !isBusy
            isBusy ? spinner.startAnimation(nil) : spinner.stopAnimation(nil)
        }
    }
    private(set) var isExpanded = false
    private var target = NSSize(width: collapsedSize, height: collapsedSize)
    /// The room the chip needs now, including where an animation is heading.
    var currentSize: NSSize { NSSize(width: max(width.constant, target.width), height: max(height.constant, target.height)) }

    private let outline = AppearanceView()
    private let highlight = AppearanceView()
    private let code = Design.label("", size: 11.5, weight: .semibold, color: .secondaryLabelColor)
    private let spinner = NSProgressIndicator()
    private let list = NSStackView()
    private var width: NSLayoutConstraint!
    private var height: NSLayoutConstraint!
    private var hovering = false { didSet { highlight.isHidden = !hovering || isExpanded } }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.collapsedSize, height: Self.collapsedSize))
        let material = NSVisualEffectView.roundedMaterial(.popover, radius: 9)
        highlight.radius = 9
        highlight.continuousCorners = false
        highlight.fill = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor.white.withAlphaComponent(0.1) : NSColor.black.withAlphaComponent(0.05) }
        highlight.isHidden = true
        outline.radius = 9
        outline.continuousCorners = false
        outline.border = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor.white.withAlphaComponent(0.14) : NSColor.black.withAlphaComponent(0.1) }
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isHidden = true
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 0
        list.alphaValue = 0
        list.isHidden = true
        for view in [material, highlight, outline] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: leadingAnchor), view.trailingAnchor.constraint(equalTo: trailingAnchor),
                view.topAnchor.constraint(equalTo: topAnchor), view.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
        }
        for view in [code, spinner, list] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        width = widthAnchor.constraint(equalToConstant: Self.collapsedSize)
        height = heightAnchor.constraint(equalToConstant: Self.collapsedSize)
        NSLayoutConstraint.activate([
            width, height,
            // The code sits in the top-right square, where the chip lives when it is closed.
            code.centerXAnchor.constraint(equalTo: trailingAnchor, constant: -Self.collapsedSize / 2),
            code.centerYAnchor.constraint(equalTo: topAnchor, constant: Self.collapsedSize / 2),
            spinner.centerXAnchor.constraint(equalTo: code.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: code.centerYAnchor),
            list.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.listInset),
            list.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.listInset),
            list.topAnchor.constraint(equalTo: topAnchor, constant: Self.listInset)
        ])
        setAccessibilityRole(.popUpButton)
    }

    required init?(coder: NSCoder) { fatalError("Use init()") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if !isExpanded { expand() }
    }

    override func accessibilityPerformPress() -> Bool {
        isExpanded ? collapse() : expand()
        return true
    }

    func expand() {
        guard !isExpanded, !isBusy else { return }
        isExpanded = true
        highlight.isHidden = true
        code.isHidden = true
        list.isHidden = false
        let rows = CGFloat(list.arrangedSubviews.filter { $0 is ChipRow }.count)
        let dividers = CGFloat(list.arrangedSubviews.count) - rows
        resize(to: NSSize(width: Self.expandedWidth, height: rows * Self.rowHeight + dividers * 9 + Self.listInset * 2), list: 1)
    }

    func collapse(animated: Bool = true) {
        guard isExpanded else { return }
        isExpanded = false
        code.isHidden = isBusy
        resize(to: NSSize(width: Self.collapsedSize, height: Self.collapsedSize), list: 0, animated: animated) { [weak self] in
            self?.list.isHidden = true
        }
    }

    /// The window grows to the target before opening and shrinks after closing, so the chip never
    /// draws outside it mid-animation.
    private func resize(to size: NSSize, list alpha: CGFloat, animated: Bool = true, completion: (() -> Void)? = nil) {
        let growing = size.height > height.constant
        target = size
        if growing { onResize?() }
        guard animated else {
            width.constant = size.width
            height.constant = size.height
            list.alphaValue = alpha
            completion?()
            onResize?()
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            width.animator().constant = size.width
            height.animator().constant = size.height
            list.animator().alphaValue = alpha
            superview?.layoutSubtreeIfNeeded()
        }, completionHandler: { [weak self] in
            completion?()
            if !growing { self?.onResize?() }
        })
    }

    private func rebuildList() {
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        var names = languages
        if !language.isEmpty, !names.contains(language) { names.insert(language, at: 0) }
        for name in names {
            let row = ChipRow(title: name, selected: name == language) { [weak self] in
                guard let self else { return }
                language = name
                collapse()
                onChoose?(name)
            }
            list.addArrangedSubview(row)
        }
        let divider = AppearanceView()
        divider.fill = .separatorColor
        divider.radius = 0
        divider.translatesAutoresizingMaskIntoConstraints = false
        list.addArrangedSubview(divider)
        list.setCustomSpacing(4, after: list.arrangedSubviews[max(list.arrangedSubviews.count - 2, 0)])
        list.setCustomSpacing(4, after: divider)
        NSLayoutConstraint.activate([
            divider.heightAnchor.constraint(equalToConstant: 1),
            divider.widthAnchor.constraint(equalTo: list.widthAnchor, constant: -16)
        ])
        list.addArrangedSubview(ChipRow(title: "Other…", selected: false) { [weak self] in
            self?.collapse()
            self?.onOther?()
        })
        for row in list.arrangedSubviews where row is ChipRow {
            row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }
    }

    /// Short labels: CJK languages by their own character, others by a two-letter code.
    static func code(for language: String) -> String {
        switch language.lowercased().trimmingCharacters(in: .whitespaces) {
        case "english": return "EN"
        case "simplified chinese", "chinese": return "简"
        case "traditional chinese": return "繁"
        case "japanese": return "日"
        case "korean": return "한"
        case "spanish": return "ES"
        case "french": return "FR"
        case "german": return "DE"
        case "italian": return "IT"
        case "portuguese", "brazilian portuguese": return "PT"
        case "russian": return "RU"
        case "arabic": return "AR"
        default:
            let word = language.split(separator: " ").last.map(String.init) ?? language
            return String(word.prefix(2)).uppercased()
        }
    }
}

/// One choice in the open list: hover highlight, a check for the current language.
private final class ChipRow: AppearanceView {
    private let action: () -> Void
    private var hovering = false { didSet { fill = hovering ? NSColor.controlAccentColor.withAlphaComponent(0.85) : nil; restyle() } }
    private let label: NSTextField
    private let check = Design.symbol("checkmark", size: 10, weight: .semibold)

    init(title: String, selected: Bool, action: @escaping () -> Void) {
        self.action = action
        label = Design.label(title, size: 12.5)
        super.init(frame: .zero)
        radius = 5
        check.isHidden = !selected
        let row = Design.hstack([label, Design.spacer(), check], spacing: 6)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 26),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            row.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        setAccessibilityRole(.menuItem)
        setAccessibilityLabel(title)
        setAccessibilitySelected(selected)
        restyle()
    }

    required init?(coder: NSCoder) { fatalError("Use init(title:selected:action:)") }

    private func restyle() {
        label.textColor = hovering ? .white : .labelColor
        check.contentTintColor = hovering ? .white : .controlAccentColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseUp(with event: NSEvent) {
        hovering = false
        action()
    }
    override func mouseDown(with event: NSEvent) {}
    override func accessibilityPerformPress() -> Bool { action(); return true }
}
