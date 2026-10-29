import AppKit

/// The floating composer: one input card with the target language as a faint label at its right
/// edge. Tab steps through your favorite languages; failures show underneath only when there is one.
@MainActor
final class ComposerPanel: NSWindowController, NSWindowDelegate, NSTextViewDelegate {
    /// `paste` replaces text in the captured field; `copy` puts the result on the clipboard.
    enum Mode { case paste, copy }

    var onSubmit: ((String) -> Void)?
    var onCancel: (() -> Void)?
    var onClose: (() -> Void)?
    /// Asks for the next (+1) or previous (-1) favorite language.
    var onCycleLanguage: ((Int) -> Void)?

    private let editor = ComposerTextView()
    private let scroll = NSScrollView()
    private let card = NSVisualEffectView.roundedMaterial(.popover, radius: 10)
    private let languageLabel = TargetLanguageLabel()
    private let errorIcon = Design.symbol("exclamationmark.triangle.fill", size: 11, color: .systemOrange)
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let errorAction = NSButton()
    private var errorRow: NSStackView!
    private var errorHandler: (() -> Void)?
    private var editorHeight: NSLayoutConstraint!
    private var cardWidth: NSLayoutConstraint!
    private var mode: Mode = .paste
    /// Fixed once the composer appears: its top-left corner, and how far down it may grow.
    private var origin = NSPoint.zero
    private var floor: CGFloat = 0
    private var wasOverflowing = false
    private static let (horizontalPadding, verticalPadding, lineHeight): (CGFloat, CGFloat, CGFloat) = (16, 12, 24)
    private static let maximumTextHeight: CGFloat = 200
    /// Gap kept clear before the label, and the width over which text fades out ahead of it.
    private static let (labelClearance, fadeWidth): (CGFloat, CGFloat) = (6, 28)
    private let fadeMask = CALayer()

    init() {
        let panel = ComposerWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 48),
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
        outline.radius = 10
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
        editor.frame = NSRect(x: 0, y: 0, width: 320, height: Self.lineHeight)
        editor.delegate = self
        editor.setAccessibilityLabel("Text to translate")
        editor.onSubmit = { [weak self] in self?.submit() }
        editor.onCancel = { [weak self] in self?.cancel() }
        editor.onTab = { [weak self] step in self?.cycle(step) }
        scroll.documentView = editor
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.borderType = .noBorder

        languageLabel.onClick = { [weak self] in self?.cycle(1) }
        // A new name has a new width: re-fit the text and the fade once it appears.
        languageLabel.onChange = { [weak self] in self?.resizeToContent() }

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

        // The text spans the whole card; the label floats over the first line's right end, and the
        // text there fades out beneath it instead of stopping at a hard edge.
        let root = Design.vstack([scroll, errorRow], spacing: 8)
        root.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(root)
        scroll.wantsLayer = true
        scroll.layer?.mask = fadeMask
        languageLabel.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(languageLabel)

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
            root.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Self.horizontalPadding + 4),
            root.topAnchor.constraint(equalTo: card.topAnchor, constant: Self.verticalPadding),
            root.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -Self.verticalPadding),
            scroll.widthAnchor.constraint(equalTo: root.widthAnchor),
            languageLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            languageLabel.topAnchor.constraint(equalTo: root.topAnchor),
            errorRow.widthAnchor.constraint(equalTo: root.widthAnchor),
            languageLabel.heightAnchor.constraint(equalToConstant: Self.lineHeight),
            editorHeight
        ])
    }

    required init?(coder: NSCoder) { fatalError("Use init()") }

    var isVisible: Bool { window?.isVisible == true }

    /// Open a fresh card at the text cursor (AX coordinates), or near the pointer when there is none.
    /// `language` is the display name, e.g. 日本語.
    func present(over axFrame: CGRect?, mode: Mode, language: String) {
        guard let window else { return }
        self.mode = mode
        editor.string = ""
        editor.undoManager?.removeAllActions()
        editor.placeholder = mode == .paste ? "Type to translate…" : "Type to translate and copy…"
        setLanguage(language, animated: false)
        setIdle()
        hideError()
        // Convert AX's top-left desktop origin into AppKit's bottom-left coordinates.
        let desktopTop = NSScreen.screens.first?.frame.maxY ?? 0
        let anchor = axFrame.map { NSRect(x: $0.minX, y: desktopTop - $0.maxY, width: $0.width, height: $0.height) }
        let point = anchor.map { NSPoint(x: $0.midX, y: $0.midY) } ?? NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) ?? NSScreen.main {
            // Three tenths of the screen wide (at least 300 pt), starting where the cursor is so typed text lines up with it.
            let visible = screen.visibleFrame.insetBy(dx: 12, dy: 12)
            let width = min(max(visible.width * 3 / 10, 300), visible.width)
            cardWidth.constant = width
            errorLabel.preferredMaxLayoutWidth = width - Self.horizontalPadding * 2 - 120
            let x = max(visible.minX, min((anchor?.minX ?? point.x) - Self.horizontalPadding, visible.maxX - width))
            // Just below the cursor's line, or just above it near the bottom of the screen. The top-left
            // is fixed from here on; the card only grows downward and then scrolls.
            let initial = Self.verticalPadding * 2 + Self.lineHeight
            let below = (anchor?.minY ?? point.y) - 6
            let top = below - initial * 2 >= visible.minY ? below : (anchor?.maxY ?? point.y) + 6 + initial
            origin = NSPoint(x: x, y: min(top, visible.maxY))
            floor = visible.minY
            window.setFrame(NSRect(x: origin.x, y: origin.y - initial, width: width, height: initial), display: false)
        }
        wasOverflowing = false
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

    func setLanguage(_ language: String, animated: Bool = true) {
        languageLabel.set(language, animated: animated && isVisible)
    }

    private func cycle(_ step: Int) {
        guard editor.isEditable else { return }
        onCycleLanguage?(step)
    }

    /// Pause editing while the model works; the text dims and the label shows a spinner.
    func showLoading(language: String) {
        editor.isEditable = false
        editor.textColor = .secondaryLabelColor
        languageLabel.isBusy = true
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
        languageLabel.isBusy = false
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

    /// Grow the card downward with wrapped text; past the room left on screen (or 200 points), scroll.
    private func resizeToContent() {
        guard let container = editor.textContainer, let layout = editor.layoutManager else { return }
        let width = cardWidth.constant - Self.horizontalPadding * 2 + 4
        // Only the first line makes room for the label; the lines below use the full width.
        let reserved = languageLabel.fittingSize.width + Self.labelClearance
        container.exclusionPaths = [NSBezierPath(rect: NSRect(x: width - reserved, y: 0, width: reserved,
                                                              height: Self.lineHeight - editor.textContainerInset.height * 2))]
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        editor.setFrameSize(NSSize(width: width, height: editor.frame.height))
        layout.ensureLayout(for: container)
        // Include the empty line after a trailing newline so the caret remains visible immediately.
        let textHeight = ceil(max(layout.usedRect(for: container).maxY, layout.extraLineFragmentUsedRect.maxY))
            + editor.textContainerInset.height * 2
        let errorHeight = errorRow.isHidden ? 0 : errorRow.fittingSize.height + 8
        let room = origin.y - floor - Self.verticalPadding * 2 - errorHeight
        let limit = max(Self.lineHeight, min(Self.maximumTextHeight, room))
        let visibleTextHeight = min(max(textHeight, Self.lineHeight), limit)
        editorHeight.constant = visibleTextHeight
        editor.setFrameSize(NSSize(width: width, height: max(textHeight, visibleTextHeight)))
        let overflowing = textHeight > visibleTextHeight
        fitWindow()
        updateFade(labelWidth: languageLabel.fittingSize.width)
        if overflowing {
            editor.scrollRangeToVisible(editor.selectedRange())
            // Show the scroller the moment text starts to scroll, not only while the wheel moves.
            if !wasOverflowing { scroll.flashScrollers() }
        }
        wasOverflowing = overflowing
    }

    /// The text view is masked opaque everywhere except a band beside the label: there it fades from
    /// opaque to clear over `fadeWidth`, and stays clear under the label. The band is fixed to the
    /// view, so text scrolling past the label melts away too.
    private func updateFade(labelWidth: CGFloat) {
        let size = scroll.bounds.size
        guard size.width > 0, size.height > 0 else { return }
        let clearFrom = size.width - labelWidth - Self.labelClearance
        let image = NSImage(size: size, flipped: true) { rect in
            NSColor.black.setFill()
            rect.fill()
            let band = NSRect(x: clearFrom - Self.fadeWidth, y: 0, width: size.width - clearFrom + Self.fadeWidth, height: Self.lineHeight)
            NSGraphicsContext.current?.compositingOperation = .copy
            NSColor.clear.setFill()
            band.fill()
            NSGradient(starting: .black, ending: NSColor.black.withAlphaComponent(0))?
                .draw(in: NSRect(x: band.minX, y: 0, width: Self.fadeWidth, height: Self.lineHeight), angle: 0)
            return true
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fadeMask.frame = CGRect(origin: .zero, size: size)
        fadeMask.contentsScale = window?.backingScaleFactor ?? 2
        fadeMask.contents = image.layerContents(forContentsScale: fadeMask.contentsScale)
        CATransaction.commit()
    }

    /// The window wraps the card and hangs from the locked top-left.
    private func fitWindow() {
        guard let window else { return }
        window.contentView?.layoutSubtreeIfNeeded()
        let height = card.fittingSize.height
        window.setFrame(NSRect(x: origin.x, y: origin.y - height, width: cardWidth.constant, height: height), display: true)
        // The shadow follows the mask's shape only once it is recomputed for the new size.
        window.invalidateShadow()
    }

    @objc private func performErrorAction() { errorHandler?() }

    @objc private func submit() {
        guard editor.isEditable else { return }
        onSubmit?(editor.string)
    }

    /// Esc or the close command: dismiss and give focus back to the app the user came from.
    func cancel() {
        guard isVisible else { return }
        close()
        onCancel?()
    }

    /// Dragging the composer by its background picks a new locked top-left.
    func windowDidMove(_ notification: Notification) {
        guard let frame = window?.frame else { return }
        origin = NSPoint(x: frame.minX, y: frame.maxY)
    }

    func windowWillClose(_ notification: Notification) {
        languageLabel.isBusy = false
        editor.string = ""
        editor.undoManager?.removeAllActions()
        onClose?()
    }
}

/// Lays out from the top-left, so growing the window downward never moves the card.
private final class TopAnchoredView: NSView {
    override var isFlipped: Bool { true }
}

/// The target language as a faint label with a ⇥ key cap: Tab (or a click) steps to the next one.
/// While translating, a small spinner takes the key cap's place.
private final class TargetLanguageLabel: NSStackView {
    var onClick: (() -> Void)?
    var onChange: (() -> Void)?
    var isBusy = false {
        didSet {
            key.isHidden = isBusy
            spinner.isHidden = !isBusy
            isBusy ? spinner.startAnimation(nil) : spinner.stopAnimation(nil)
            name.textColor = isBusy ? .quaternaryLabelColor : .tertiaryLabelColor
        }
    }
    private let name = Design.label("", size: 13, color: .tertiaryLabelColor)
    private let key = KeyCap("⇥")
    private let spinner = NSProgressIndicator()

    init() {
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = 6
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isHidden = true
        addArrangedSubview(name)
        addArrangedSubview(key)
        addArrangedSubview(spinner)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        toolTip = "Press Tab for the next language, Shift+Tab for the previous one"
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError("Use init()") }

    func set(_ language: String, animated: Bool) {
        setAccessibilityLabel("Target language: \(language). Press Tab to change.")
        guard animated, name.stringValue != language else {
            name.stringValue = language
            onChange?()
            return
        }
        // A quick crossfade makes each Tab press visible without moving anything.
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.08; name.animator().alphaValue = 0 }, completionHandler: { [weak self] in
            guard let self else { return }
            name.stringValue = language
            onChange?()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.12; self.name.animator().alphaValue = 1 }
        })
    }

    override func mouseDown(with event: NSEvent) { if !isBusy { onClick?() } }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
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
    /// Tab steps forward through the favorite languages, Shift+Tab back.
    var onTab: ((Int) -> Void)?
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
            if event.keyCode == 48 { onTab?(event.modifierFlags.contains(.shift) ? -1 : 1); return }
            if event.keyCode == 36 || event.keyCode == 76 {
                if event.modifierFlags.contains(.shift) { insertNewline(nil) } else { onSubmit?() }
                return
            }
        }
        super.keyDown(with: event)
    }
}
