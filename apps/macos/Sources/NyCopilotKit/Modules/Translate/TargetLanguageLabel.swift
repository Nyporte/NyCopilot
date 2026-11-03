import AppKit
import CoreText

/// How a language's short code is drawn wherever it shows as a badge: the composer and the list of
/// favorites.
@MainActor
enum LanguageBadge {
    static let size = NSSize(width: 24, height: 18)

    /// A faint plate that works in light and dark.
    static let fill = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor.white.withAlphaComponent(0.1) : NSColor.black.withAlphaComponent(0.06) }

    /// CJK glyphs read better a size larger than Latin letters in the same badge.
    static func font(for code: String) -> NSFont {
        let wide = code.unicodeScalars.first.map { $0.value > 0x2E80 } ?? false
        return .systemFont(ofSize: wide ? 12 : 10.5, weight: .semibold)
    }
}

/// The target language as a pair of small icons: a badge with its short code (EN, 中, 日) and the ⇥
/// key that steps to the next one. The badge has a fixed size, so switching never moves the text.
/// While translating, a small spinner replaces the arrow inside the key's box, so the column's width
/// (and with it every line of text) stays exactly the same.
final class TargetLanguageLabel: NSStackView {
    var onClick: (() -> Void)?
    var isBusy = false {
        didSet {
            arrow.isHidden = isBusy
            spinner.isHidden = !isBusy
            isBusy ? spinner.startAnimation(nil) : spinner.stopAnimation(nil)
            code.textColor = isBusy ? .tertiaryLabelColor : .secondaryLabelColor
        }
    }
    private let badge = AppearanceView()
    private let code = Design.label("", size: 10.5, weight: .semibold, color: .secondaryLabelColor)
    /// The Tab key as a symbol rather than the ⇥ character: a glyph sits on its font's baseline and
    /// line height, so it never looks centered; a symbol image centers on its actual shape.
    private let key = AppearanceView()
    private let arrow = Design.symbol("arrow.right.to.line", size: 8.5, weight: .bold)
    private var codeBaseline: NSLayoutConstraint!
    private let spinner = NSProgressIndicator()
    private static let badgeSize = LanguageBadge.size

    init() {
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = 4
        for (box, content) in [(badge, code), (key, arrow)] as [(AppearanceView, NSView)] {
            box.radius = 5
            box.fill = LanguageBadge.fill
            box.translatesAutoresizingMaskIntoConstraints = false
            content.translatesAutoresizingMaskIntoConstraints = false
            box.addSubview(content)
        }
        code.alignment = .center
        spinner.style = .spinning
        spinner.controlSize = .mini
        spinner.isHidden = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        key.addSubview(spinner)
        addArrangedSubview(badge)
        addArrangedSubview(key)
        // Letters are centered on their visible height (cap height), not the font's line box.
        codeBaseline = code.firstBaselineAnchor.constraint(equalTo: badge.centerYAnchor)
        NSLayoutConstraint.activate([
            badge.widthAnchor.constraint(equalToConstant: Self.badgeSize.width),
            badge.heightAnchor.constraint(equalToConstant: Self.badgeSize.height),
            key.widthAnchor.constraint(equalToConstant: Self.badgeSize.width - 2),
            key.heightAnchor.constraint(equalToConstant: Self.badgeSize.height),
            code.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
            codeBaseline,
            arrow.centerXAnchor.constraint(equalTo: key.centerXAnchor),
            arrow.centerYAnchor.constraint(equalTo: key.centerYAnchor),
            spinner.centerXAnchor.constraint(equalTo: key.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: key.centerYAnchor)
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError("Use init()") }

    func set(_ language: ComposerPanel.Language, animated: Bool) {
        toolTip = L("Translating into %@. Tab for the next language, Shift+Tab for the previous one.", L(language.name))
        setAccessibilityLabel(L("Target language: %@. Press Tab to change.", L(language.name)))
        let apply = { [weak self] in
            guard let self else { return }
            code.stringValue = language.code
            let font = LanguageBadge.font(for: language.code)
            code.font = font
            // Center the ink, not the line box: measure where the glyphs actually draw relative to
            // the baseline, and put the middle of that on the badge's middle. Works for any script.
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: language.code, attributes: [.font: font]))
            codeBaseline.constant = CTLineGetImageBounds(line, nil).midY
        }
        guard animated, code.stringValue != language.code else { apply(); return }
        // A quick crossfade makes each Tab press visible without moving anything.
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.08; code.animator().alphaValue = 0 }, completionHandler: { [weak self] in
            apply()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.12; self?.code.animator().alphaValue = 1 }
        })
    }

    override func mouseDown(with event: NSEvent) { if !isBusy { onClick?() } }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
}
