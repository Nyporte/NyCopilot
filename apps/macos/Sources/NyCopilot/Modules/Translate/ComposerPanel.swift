import AppKit

/// The floating card you type into. It sits over the captured field, grows with the text,
/// and keeps failures inline so a retry is one keystroke away.
@MainActor
final class ComposerPanel: NSWindowController, NSWindowDelegate, NSTextViewDelegate {
    /// `paste` replaces text in the captured field; `copy` puts the result on the clipboard.
    enum Mode { case paste, copy }

    var onSubmit: ((String) -> Void)?
    var onCancel: (() -> Void)?
    var onClose: (() -> Void)?
    var onChooseLanguage: ((String) -> Void)?
    var onOtherLanguage: (() -> Void)?

    private let editor = ComposerTextView()
    private let scroll = NSScrollView()
    private let languageButton = PillButton()
    private let hint = Design.label("", size: 11.5, color: .tertiaryLabelColor)
    private let hintKey = KeyCap("⇧↵")
    private let progress = NSProgressIndicator()
    private let submitButton = NSButton()
    private let errorIcon = Design.symbol("exclamationmark.triangle.fill", size: 12, color: .systemOrange)
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let errorAction = NSButton()
    private var errorRow: NSStackView!
    private var errorHandler: (() -> Void)?
    private var editorHeight: NSLayoutConstraint!
    private var mode: Mode = .paste
    private var languages: [String] = []
    private static let padding: CGFloat = 14

    init() {
        let panel = ComposerWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 96),
                                   styleMask: [.borderless], backing: .buffered, defer: false)
        panel.title = "NyCopilot"
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        super.init(window: panel)
        panel.delegate = self

        // The native material supplies blur; a thin adaptive tint and hairline keep edges crisp.
        let material = NSVisualEffectView()
        material.material = .popover
        material.blendingMode = .behindWindow
        material.state = .active
        material.wantsLayer = true
        material.layer?.cornerRadius = 14
        material.layer?.cornerCurve = .continuous
        material.layer?.masksToBounds = true
        panel.contentView = material
        let outline = AppearanceView()
        outline.radius = 14
        outline.border = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor.white.withAlphaComponent(0.14) : NSColor.black.withAlphaComponent(0.1) }
        outline.translatesAutoresizingMaskIntoConstraints = false
        material.addSubview(outline)

        editor.font = .systemFont(ofSize: 15)
        editor.textColor = .labelColor
        editor.insertionPointColor = .controlAccentColor
        editor.drawsBackground = false
        editor.isRichText = false
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.textContainerInset = NSSize(width: 0, height: 2)
        editor.textContainer?.lineFragmentPadding = 0
        editor.autoresizingMask = [.width]
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.textContainer?.widthTracksTextView = true
        editor.frame = NSRect(x: 0, y: 0, width: 392, height: 24)
        editor.delegate = self
        editor.setAccessibilityLabel("Text to translate")
        editor.onSubmit = { [weak self] in self?.submit() }
        editor.onCancel = { [weak self] in self?.cancel() }
        scroll.documentView = editor
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.borderType = .noBorder

        errorLabel.font = .systemFont(ofSize: 12)
        errorLabel.textColor = .secondaryLabelColor
        errorLabel.maximumNumberOfLines = 3
        errorLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        errorAction.bezelStyle = .inline
        errorAction.controlSize = .small
        errorAction.target = self
        errorAction.action = #selector(performErrorAction)
        errorRow = Design.hstack([errorIcon, errorLabel, errorAction], spacing: 6)
        errorRow.alignment = .firstBaseline
        errorRow.isHidden = true

        languageButton.symbolName = "globe"
        languageButton.toolTip = "Choose the target language"
        languageButton.onPress = { [weak self] in self?.showLanguageMenu() }
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        submitButton.image = NSImage(systemSymbolName: "arrow.up.circle.fill", accessibilityDescription: "Translate")
        submitButton.symbolConfiguration = .init(pointSize: 22, weight: .regular)
        submitButton.isBordered = false
        submitButton.contentTintColor = .controlAccentColor
        submitButton.target = self
        submitButton.action = #selector(submit)
        let footer = Design.hstack([languageButton, Design.spacer(), progress, hintKey, hint, submitButton], spacing: 6)
        footer.setCustomSpacing(10, after: hint)

        let root = Design.vstack([scroll, errorRow, footer], spacing: 10)
        root.translatesAutoresizingMaskIntoConstraints = false
        material.addSubview(root)
        editorHeight = scroll.heightAnchor.constraint(equalToConstant: 24)
        NSLayoutConstraint.activate([
            outline.leadingAnchor.constraint(equalTo: material.leadingAnchor),
            outline.trailingAnchor.constraint(equalTo: material.trailingAnchor),
            outline.topAnchor.constraint(equalTo: material.topAnchor),
            outline.bottomAnchor.constraint(equalTo: material.bottomAnchor),
            root.leadingAnchor.constraint(equalTo: material.leadingAnchor, constant: Self.padding),
            root.trailingAnchor.constraint(equalTo: material.trailingAnchor, constant: -Self.padding),
            root.topAnchor.constraint(equalTo: material.topAnchor, constant: Self.padding),
            root.bottomAnchor.constraint(equalTo: material.bottomAnchor, constant: -10),
            scroll.widthAnchor.constraint(equalTo: root.widthAnchor),
            errorRow.widthAnchor.constraint(equalTo: root.widthAnchor),
            footer.widthAnchor.constraint(equalTo: root.widthAnchor),
            footer.heightAnchor.constraint(equalToConstant: 26),
            submitButton.widthAnchor.constraint(equalToConstant: 26),
            editorHeight
        ])
    }

    required init?(coder: NSCoder) { fatalError("Use init()") }

    var isVisible: Bool { window?.isVisible == true }

    /// Open a fresh card over the field (AX coordinates), or near the pointer when there is none.
    func present(over axFrame: CGRect?, mode: Mode, language: String, languages: [String]) {
        guard let window else { return }
        self.mode = mode
        self.languages = languages
        editor.string = ""
        editor.undoManager?.removeAllActions()
        editor.placeholder = mode == .paste ? "Type to translate…" : "Type to translate and copy…"
        setLanguage(language)
        setIdle()
        hideError()
        // Convert AX's top-left desktop origin into AppKit's bottom-left coordinates.
        let desktopTop = NSScreen.screens.first?.frame.maxY ?? 0
        let anchor = axFrame.map { NSRect(x: $0.minX, y: desktopTop - $0.maxY, width: $0.width, height: $0.height) }
        let point = anchor.map { NSPoint(x: $0.midX, y: $0.midY) } ?? NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) ?? NSScreen.main {
            let visible = screen.visibleFrame.insetBy(dx: 12, dy: 12)
            let width = min(max(anchor?.width ?? 420, 380), min(520, visible.width))
            let x = max(visible.minX, min(anchor?.minX ?? point.x - width / 2, visible.maxX - width))
            let top = anchor.map { $0.maxY + 6 } ?? point.y + 12
            let y = max(visible.minY, min(top - 96, visible.maxY - 96))
            window.setFrame(NSRect(x: x, y: y, width: width, height: 96), display: false)
        }
        resizeToContent()
        NSApp.activate(ignoringOtherApps: true)
        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(editor)
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; window.animator().alphaValue = 1 }
    }

    func bringToFront() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func setLanguage(_ language: String) {
        languageButton.title = language
        languageButton.setAccessibilityLabel("Target language: \(language)")
    }

    /// Pause editing while the model works; the card stays where the user is looking.
    func showLoading(language: String) {
        editor.isEditable = false
        submitButton.isHidden = true
        languageButton.isEnabled = false
        hideError()
        hintKey.isHidden = true
        hint.stringValue = "Translating into \(language)…"
        progress.startAnimation(nil)
        resizeToContent()
    }

    /// Keep the source for a retry; an optional action fixes the cause (e.g. open Settings).
    func showError(_ message: String, action: (title: String, handler: () -> Void)? = nil) {
        setIdle()
        hintKey.keys = "↵"
        hint.stringValue = "Try again"
        errorLabel.stringValue = message
        errorLabel.toolTip = message
        errorAction.title = action?.title ?? ""
        errorAction.isHidden = action == nil
        errorHandler = action?.handler
        errorRow.isHidden = false
        resizeToContent()
        window?.makeFirstResponder(editor)
    }

    /// Hide without closing or cancelling while the original application regains keyboard focus.
    func hideForInsertion() { window?.orderOut(nil) }

    private func setIdle() {
        editor.isEditable = true
        submitButton.isHidden = false
        languageButton.isEnabled = true
        progress.stopAnimation(nil)
        hintKey.isHidden = false
        hintKey.keys = "⇧↵"
        hint.stringValue = "New line"
        submitButton.toolTip = mode == .paste ? "Translate and replace (↵)" : "Translate and copy (↵)"
    }

    private func hideError() {
        errorRow.isHidden = true
        errorHandler = nil
    }

    func textDidChange(_ notification: Notification) {
        editor.needsDisplay = true
        if !errorRow.isHidden { hideError() }
        resizeToContent()
    }

    /// Keep the top edge fixed while the card grows with wrapped text, up to a scrolling limit.
    private func resizeToContent() {
        guard let window, let container = editor.textContainer, let layout = editor.layoutManager else { return }
        let width = window.frame.width - Self.padding * 2
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        editor.setFrameSize(NSSize(width: width, height: editor.frame.height))
        layout.ensureLayout(for: container)
        // Include the empty line after a trailing newline so the caret remains visible immediately.
        let textHeight = ceil(max(layout.usedRect(for: container).maxY, layout.extraLineFragmentUsedRect.maxY))
            + editor.textContainerInset.height * 2
        let visibleTextHeight = min(max(textHeight, 24), 200)
        editorHeight.constant = visibleTextHeight
        editor.setFrameSize(NSSize(width: width, height: max(textHeight, visibleTextHeight)))
        window.contentView?.layoutSubtreeIfNeeded()
        let height = (window.contentView?.fittingSize.height ?? 96)
        var frame = window.frame
        frame.origin.y = frame.maxY - height
        frame.size.height = height
        if let screen = window.screen {
            frame.origin.y = max(screen.visibleFrame.minY + 10, min(frame.minY, screen.visibleFrame.maxY - height - 10))
        }
        window.setFrame(frame, display: true)
    }

    private func showLanguageMenu() {
        let menu = NSMenu()
        let current = languageButton.title
        var list = languages
        if !list.contains(current) { list.insert(current, at: 0) }
        for language in list {
            let item = NSMenuItem(title: language, action: #selector(chooseLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.state = language == current ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let other = NSMenuItem(title: "Other Language…", action: #selector(otherLanguage), keyEquivalent: "")
        other.target = self
        menu.addItem(other)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: languageButton.bounds.maxY + 4), in: languageButton)
    }

    @objc private func chooseLanguage(_ sender: NSMenuItem) {
        setLanguage(sender.title)
        onChooseLanguage?(sender.title)
        window?.makeFirstResponder(editor)
    }

    @objc private func otherLanguage() { onOtherLanguage?() }
    @objc private func performErrorAction() { errorHandler?() }

    @objc private func submit() {
        guard editor.isEditable, !submitButton.isHidden else { return }
        onSubmit?(editor.string)
    }

    /// Esc or the close command: dismiss and give focus back to the app the user came from.
    func cancel() {
        guard isVisible else { return }
        close()
        onCancel?()
    }

    func windowWillClose(_ notification: Notification) {
        progress.stopAnimation(nil)
        editor.string = ""
        editor.undoManager?.removeAllActions()
        onClose?()
    }
}

/// Borderless panels must explicitly accept keyboard focus for native editing and input methods.
private final class ComposerWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func performClose(_ sender: Any?) { (windowController as? ComposerPanel)?.cancel() }
    override func cancelOperation(_ sender: Any?) { (windowController as? ComposerPanel)?.cancel() }
}

/// Native text editing keeps IME composition; a placeholder avoids an empty-looking card.
private final class ComposerTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onCancel: (() -> Void)?
    var placeholder = "" { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !hasMarkedText() else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 15),
            .foregroundColor: NSColor.placeholderTextColor
        ]
        (placeholder as NSString).draw(at: NSPoint(x: textContainerInset.width, y: textContainerInset.height), withAttributes: attributes)
    }

    /// IME candidate confirmation wins over submission; Shift+Enter inserts a newline.
    override func keyDown(with event: NSEvent) {
        if !hasMarkedText() {
            if event.keyCode == 53 { onCancel?(); return }
            if event.keyCode == 36 || event.keyCode == 76 {
                if event.modifierFlags.contains(.shift) { insertNewline(nil) } else { onSubmit?() }
                return
            }
        }
        super.keyDown(with: event)
    }
}

/// A compact rounded button with an icon, a title, and a disclosure chevron.
final class PillButton: AppearanceView {
    var onPress: (() -> Void)?
    var symbolName = "" { didSet { icon.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) } }
    var title: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }
    var isEnabled = true { didSet { alphaValue = isEnabled ? 1 : 0.5 } }

    private let icon = Design.symbol("globe", size: 11, weight: .medium)
    private let label = Design.label("", size: 12, weight: .medium, color: .secondaryLabelColor)
    private let chevron = Design.symbol("chevron.up.chevron.down", size: 8, weight: .semibold, color: .tertiaryLabelColor)
    private var hovering = false { didSet { updateFill() } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        radius = 6
        let row = Design.hstack([icon, label, chevron], spacing: 5)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 24)
        ])
        updateFill()
        setAccessibilityRole(.popUpButton)
    }

    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { if isEnabled { onPress?() } }
    override func accessibilityPerformPress() -> Bool { onPress?(); return true }

    private func updateFill() {
        fill = NSColor(name: nil) { [hovering] appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return (dark ? NSColor.white : NSColor.black).withAlphaComponent(hovering ? (dark ? 0.12 : 0.08) : (dark ? 0.07 : 0.045))
        }
    }
}
