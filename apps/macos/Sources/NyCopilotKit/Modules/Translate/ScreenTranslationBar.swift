import AppKit

/// The small capsule at the bottom while the screen is translated: what it reads into, as a menu, and
/// the way out. The translate icon turns into a spinner while the screen is being read. It never takes
/// the keyboard from the app in front.
@MainActor
final class ScreenTranslationBar: FloatingPanel {
    struct Language {
        let name: String
        let native: String
    }

    var onPick: ((String) -> Void)?
    var onExit: (() -> Void)?
    var reading = false {
        didSet {
            guard reading != oldValue else { return }
            icon.isHidden = reading
            spinner.isHidden = !reading
            reading ? spinner.startAnimation(nil) : spinner.stopAnimation(nil)
        }
    }
    let icon = Design.symbol("translate", size: 12, color: .white.withAlphaComponent(0.85))
    let spinner = NSProgressIndicator()
    let picker = FirstClickPopUp()
    /// Each language's own name, by its English one, for the capsule's title.
    var natives: [String: String] = [:]
    let content: NSStackView

    init() {
        content = Design.hstack([], spacing: 6)
        super.init(size: NSSize(width: 160, height: 30), level: .screenOverlayControls, behavior: [.stationary, .ignoresCycle])
        takesKeys = false
        becomesKeyOnlyIfNeeded = true
        appearance = NSAppearance(named: .darkAqua)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.isHidden = true
        for view in [icon, spinner] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalToConstant: 16).isActive = true
        }
        // A pull-down, so the capsule shows just the language's own name while the menu can say more.
        picker.pullsDown = true
        picker.isBordered = false
        picker.font = .systemFont(ofSize: 12, weight: .medium)
        picker.contentTintColor = .white
        picker.target = self
        picker.action = #selector(picked)
        let escape = Design.label(L("esc"), size: 10, weight: .medium, color: .white.withAlphaComponent(0.6))
        let key = ExitKey()
        key.toolTip = L("Esc ends screen translation")
        key.onClick = { [weak self] in self?.onExit?() }
        key.translatesAutoresizingMaskIntoConstraints = false
        escape.translatesAutoresizingMaskIntoConstraints = false
        key.addSubview(escape)
        NSLayoutConstraint.activate([
            escape.leadingAnchor.constraint(equalTo: key.leadingAnchor, constant: 4), escape.trailingAnchor.constraint(equalTo: key.trailingAnchor, constant: -4),
            escape.centerYAnchor.constraint(equalTo: key.centerYAnchor), key.heightAnchor.constraint(equalToConstant: 16)
        ])
        key.wantsLayer = true
        key.layer?.borderColor = NSColor.white.withAlphaComponent(0.3).cgColor
        key.layer?.borderWidth = 1
        key.layer?.cornerRadius = 4
        [icon, spinner, picker, key].forEach(content.addArrangedSubview)
        let material = NSVisualEffectView.roundedMaterial(.hudWindow, radius: 15)
        content.translatesAutoresizingMaskIntoConstraints = false
        material.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: material.leadingAnchor, constant: 12),
            content.trailingAnchor.constraint(equalTo: material.trailingAnchor, constant: -8),
            content.centerYAnchor.constraint(equalTo: material.centerYAnchor),
            material.heightAnchor.constraint(equalToConstant: 30)
        ])
        contentView = material
    }

    /// Fills the menu — groups of languages, a divider between groups — and shows the capsule at the
    /// bottom of `screen`, just above the Dock.
    func present(languages groups: [[Language]], selected: String, on screen: NSScreen) {
        picker.removeAllItems()
        picker.addItem(withTitle: "")
        for (index, group) in groups.enumerated() {
            if index > 0 { picker.menu?.addItem(.separator()) }
            for language in group {
                let item = NSMenuItem(title: language.native, action: nil, keyEquivalent: "")
                item.representedObject = language.name
                item.state = language.name == selected ? .on : .off
                natives[language.name] = language.native
                if language.native.caseInsensitiveCompare(language.name) != .orderedSame {
                    let title = NSMutableAttributedString(string: language.native, attributes: [.font: NSFont.menuFont(ofSize: 13)])
                    title.append(NSAttributedString(string: "  \(L(language.name))", attributes: [
                        .font: NSFont.menuFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
                    item.attributedTitle = title
                }
                picker.menu?.addItem(item)
            }
        }
        picker.itemArray.first?.title = natives[selected] ?? selected
        content.layoutSubtreeIfNeeded()
        let size = NSSize(width: content.fittingSize.width + 20, height: 30)
        let visible = screen.visibleFrame
        setFrame(NSRect(x: visible.midX - size.width / 2, y: visible.minY + 14, width: size.width, height: size.height), display: true)
        orderFrontRegardless()
    }

    @objc func picked() {
        guard let chosen = picker.selectedItem, let name = chosen.representedObject as? String else { return }
        picker.itemArray.forEach { $0.state = $0 === chosen ? .on : .off }
        picker.itemArray.first?.title = natives[name] ?? name
        onPick?(name)
        // The capsule follows the shorter or longer name.
        content.layoutSubtreeIfNeeded()
        let width = content.fittingSize.width + 20
        setFrame(NSRect(x: frame.midX - width / 2, y: frame.minY, width: width, height: frame.height), display: true)
    }

    /// Opens on the first click, though the capsule never becomes the key window.
    final class FirstClickPopUp: NSPopUpButton {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    /// The `esc` keycap, which also ends screen translation when clicked.
    final class ExitKey: NSView {
        var onClick: (() -> Void)?
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseUp(with event: NSEvent) { if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() } }
    }
}
