import AppKit

/// The floating composer: a bare input card, and beside it a tiny language chip that opens into a
/// short list when clicked. The card grows with the text and shows failures only when there is one.
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
    private let card = NSVisualEffectView.roundedMaterial(.popover, radius: 14)
    private let chip = LanguageChip()
    private let errorIcon = Design.symbol("exclamationmark.triangle.fill", size: 11, color: .systemOrange)
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let errorAction = NSButton()
    private var errorRow: NSStackView!
    private var errorHandler: (() -> Void)?
    private var editorHeight: NSLayoutConstraint!
    private var cardWidth: NSLayoutConstraint!
    private var mode: Mode = .paste
    private static let (horizontalPadding, verticalPadding, lineHeight): (CGFloat, CGFloat, CGFloat) = (16, 12, 24)
    /// Space between the card and the chip; the chip centres on the card's first line.
    private static let (chipGap, chipTop): (CGFloat, CGFloat) = (8, 9)

    init() {
        let panel = ComposerWindow(contentRect: NSRect(x: 0, y: 0, width: 478, height: 48),
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

        let container = TopAnchoredView()
        panel.contentView = container
        card.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(card)
        let outline = AppearanceView()
        outline.radius = 14
        outline.continuousCorners = false
        outline.border = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor.white.withAlphaComponent(0.14) : NSColor.black.withAlphaComponent(0.1) }
        outline.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(outline)

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
        editor.frame = NSRect(x: 0, y: 0, width: 408, height: Self.lineHeight)
        editor.delegate = self
        editor.setAccessibilityLabel("Text to translate")
        editor.onSubmit = { [weak self] in self?.submit() }
        editor.onCancel = { [weak self] in self?.cancel() }
        editor.onActivity = { [weak self] in self?.chip.collapse() }
        editor.onActivityConsumesEscape = { [weak self] in self?.chip.isExpanded == true }
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
        errorAction.isBordered = false
        errorAction.contentTintColor = .controlAccentColor
        errorAction.font = .systemFont(ofSize: 12, weight: .medium)
        errorAction.target = self
        errorAction.action = #selector(performErrorAction)
        errorRow = Design.hstack([errorIcon, errorLabel, errorAction], spacing: 6)
        errorRow.alignment = .firstBaseline
        errorRow.isHidden = true

        let root = Design.vstack([scroll, errorRow], spacing: 8)
        root.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(root)

        chip.translatesAutoresizingMaskIntoConstraints = false
        chip.onChoose = { [weak self] language in
            self?.onChooseLanguage?(language)
            self?.window?.makeFirstResponder(self?.editor)
        }
        chip.onOther = { [weak self] in self?.onOtherLanguage?() }
        chip.onResize = { [weak self] in self?.fitWindow() }
        container.addSubview(chip)

        editorHeight = scroll.heightAnchor.constraint(equalToConstant: Self.lineHeight)
        cardWidth = card.widthAnchor.constraint(equalToConstant: 440)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            card.topAnchor.constraint(equalTo: container.topAnchor),
            cardWidth,
            outline.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            outline.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            outline.topAnchor.constraint(equalTo: card.topAnchor),
            outline.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            root.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Self.horizontalPadding),
            root.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Self.horizontalPadding),
            root.topAnchor.constraint(equalTo: card.topAnchor, constant: Self.verticalPadding),
            root.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -Self.verticalPadding),
            scroll.widthAnchor.constraint(equalTo: root.widthAnchor),
            errorRow.widthAnchor.constraint(equalTo: root.widthAnchor),
            editorHeight,
            // The chip keeps its right edge and top fixed, so it opens down and to the left.
            chip.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            chip.topAnchor.constraint(equalTo: container.topAnchor, constant: Self.chipTop)
        ])
    }

    required init?(coder: NSCoder) { fatalError("Use init()") }

    var isVisible: Bool { window?.isVisible == true }

    /// Open a fresh card over the field (AX coordinates), or near the pointer when there is none.
    func present(over axFrame: CGRect?, mode: Mode, language: String, languages: [String]) {
        guard let window else { return }
        self.mode = mode
        chip.collapse(animated: false)
        chip.languages = languages
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
            let side = Self.chipGap + LanguageChip.collapsedSize
            let width = min(max(anchor?.width ?? 440, 360), min(500, visible.width - side))
            cardWidth.constant = width
            errorLabel.preferredMaxLayoutWidth = width - Self.horizontalPadding * 2 - 120
            let x = max(visible.minX, min(anchor?.minX ?? point.x - width / 2, visible.maxX - width - side))
            let top = anchor.map { $0.maxY + 6 } ?? point.y + 12
            let y = max(visible.minY, min(top - 48, visible.maxY - 48))
            window.setFrame(NSRect(x: x, y: y, width: width + side, height: 48), display: false)
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

    func setLanguage(_ language: String) { chip.language = language }

    /// Pause editing while the model works; the text dims and the chip shows a spinner.
    func showLoading(language: String) {
        chip.collapse()
        editor.isEditable = false
        editor.textColor = .secondaryLabelColor
        chip.isBusy = true
        hideError()
        resizeToContent()
    }

    /// Keep the source for a retry (Return); an optional action fixes the cause (e.g. open Settings).
    func showError(_ message: String, action: (title: String, handler: () -> Void)? = nil) {
        setIdle()
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
        editor.textColor = .labelColor
        chip.isBusy = false
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

    /// Grow the card with wrapped text, up to a scrolling limit, keeping its top edge fixed.
    private func resizeToContent() {
        guard let container = editor.textContainer, let layout = editor.layoutManager else { return }
        let width = cardWidth.constant - Self.horizontalPadding * 2
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        editor.setFrameSize(NSSize(width: width, height: editor.frame.height))
        layout.ensureLayout(for: container)
        // Include the empty line after a trailing newline so the caret remains visible immediately.
        let textHeight = ceil(max(layout.usedRect(for: container).maxY, layout.extraLineFragmentUsedRect.maxY))
            + editor.textContainerInset.height * 2
        let visibleTextHeight = min(max(textHeight, Self.lineHeight), 200)
        editorHeight.constant = visibleTextHeight
        editor.setFrameSize(NSSize(width: width, height: max(textHeight, visibleTextHeight)))
        fitWindow()
    }

    /// The window wraps the card and the chip (which may be open); its top edge never moves.
    private func fitWindow() {
        guard let window else { return }
        window.contentView?.layoutSubtreeIfNeeded()
        let height = max(card.fittingSize.height, Self.chipTop + chip.currentSize.height)
        var frame = window.frame
        frame.origin.y = frame.maxY - height
        frame.size.height = height
        frame.size.width = cardWidth.constant + Self.chipGap + LanguageChip.collapsedSize
        if let screen = window.screen {
            frame.origin.y = max(screen.visibleFrame.minY + 10, min(frame.minY, screen.visibleFrame.maxY - height - 10))
        }
        window.setFrame(frame, display: true)
        // The shadow follows the masks' shapes only once it is recomputed for the new size.
        window.invalidateShadow()
    }

    @objc private func performErrorAction() { errorHandler?() }

    @objc private func submit() {
        guard editor.isEditable else { return }
        chip.collapse()
        onSubmit?(editor.string)
    }

    /// Esc or the close command: dismiss and give focus back to the app the user came from.
    func cancel() {
        guard isVisible else { return }
        close()
        onCancel?()
    }

    func windowDidResignKey(_ notification: Notification) { chip.collapse() }

    func windowWillClose(_ notification: Notification) {
        chip.isBusy = false
        chip.collapse(animated: false)
        editor.string = ""
        editor.undoManager?.removeAllActions()
        onClose?()
    }
}

/// Lays out from the top-left, so growing the window downward never moves the card.
private final class TopAnchoredView: NSView {
    override var isFlipped: Bool { true }
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
    /// Typing or clicking in the text means the user is done with anything else, like the language list.
    var onActivity: (() -> Void)?
    /// When this returns true (the language list is open), Esc closes the list instead of the composer.
    var onActivityConsumesEscape: (() -> Bool)?
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
            if event.keyCode == 53, let onActivity, onActivityConsumesEscape?() == true { onActivity(); return }
            if event.keyCode == 53 { onCancel?(); return }
            if event.keyCode == 36 || event.keyCode == 76 {
                if event.modifierFlags.contains(.shift) { insertNewline(nil) } else { onSubmit?() }
                return
            }
        }
        onActivity?()
        super.keyDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        onActivity?()
        super.mouseDown(with: event)
    }
}
