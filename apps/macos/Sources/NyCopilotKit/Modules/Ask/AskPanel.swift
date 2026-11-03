import AppKit

/// What Ask AI is asked about: a selection, a screenshot, a note, or nothing (just a question).
struct AskMaterial {
    var text = ""
    var image: NSImage?
    var source = SourceContext()
    /// Where it is on screen (AppKit coordinates); the panel opens beside it.
    var anchor: NSRect?
    /// The app it came from, for keeping an answer in the inbox.
    var app: NSRunningApplication?
    /// A selection in a field you can type in: a rewrite can replace it (⌘↩).
    var replaceable: InputTarget?

    var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && image == nil }
}

/// One earlier exchange in a conversation, as `ask.run` takes `turns`.
struct AskTurn: Codable, Sendable, Equatable {
    enum Role: String, Codable, Sendable { case user, assistant }
    let role: Role
    let content: String
}

/// The Ask AI panel: what it's about at the top, three actions (Explain, Summarize, Rewrite), the
/// answers, and a box for a question or a follow-up. ↩ asks (or, empty, explains), ⌘1–3 run an action
/// afresh, ⌘C copies the answer (or what's selected in it), ⌘I keeps it in the inbox, ⌘P pins it, ⌘↩ puts a
/// rewrite in place of the selection, Esc or a click elsewhere closes it.
@MainActor
final class AskPanel: NSObject, NSTextFieldDelegate {
    enum Action: String, CaseIterable {
        case explain, summarize, rewrite

        var title: String {
            switch self {
            case .explain: L("Explain")
            case .summarize: L("Summarize")
            case .rewrite: L("Rewrite")
            }
        }
    }

    /// Asks the core: the action, the question (empty for an action alone), and the turns so far.
    var onAsk: ((_ action: String, _ question: String, _ turns: [AskTurn]) async throws -> String)?
    var onCancel: (() -> Void)?
    var onKeep: ((String) -> Void)?
    var onPin: ((String) -> Void)?
    var onReplace: ((String) -> Void)?

    let panel = FloatingPanel(size: NSSize(width: 500, height: 200))
    private let subject = Design.label("", size: 12, color: .secondaryLabelColor)
    private let picture = NSImageView()
    private var pictureHeight: NSLayoutConstraint!
    private var chips: [NSButton] = []
    let transcript = NSTextView()
    private let transcriptScroll = NSScrollView()
    private var transcriptHeight: NSLayoutConstraint!
    private let spinner = NSProgressIndicator()
    private let input = NSTextField()
    private let hint = Design.label("", size: 10.5, color: .tertiaryLabelColor)
    private var turns: [AskTurn] = []
    /// What the conversation began with (an action, or "ask" for a question); follow-ups keep it, so
    /// the model still sees the material framed the same way.
    private var conversationAction = "ask"
    private var lastAnswer: String?
    private var material = AskMaterial()
    private var request: Task<Void, Never>?
    private static let width: CGFloat = 500, maxTranscript: CGFloat = 380

    override init() {
        super.init()
        panel.onResignKey = { [weak self] in self?.close() }
        panel.onCancel = { [weak self] in self?.close() }
        panel.onCommand = { [weak self] key, shift in self?.command(key, shift: shift) ?? false }
        let material = NSVisualEffectView.roundedMaterial(.popover, radius: 14)

        let sparkle = Design.symbol("sparkles", size: 13, weight: .semibold, color: .controlAccentColor)
        let title = Design.label(L("Ask AI"), size: 13, weight: .semibold)
        subject.lineBreakMode = .byTruncatingTail
        subject.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for (index, action) in Action.allCases.enumerated() {
            let chip = NSButton(title: action.title, target: self, action: #selector(chipClicked(_:)))
            chip.bezelStyle = .recessed
            chip.controlSize = .small
            chip.tag = index
            chip.toolTip = "⌘\(index + 1)"
            chips.append(chip)
        }
        let header = Design.hstack([sparkle, title, subject, Design.spacer()] + chips, spacing: 6)

        picture.imageScaling = .scaleProportionallyDown
        picture.imageAlignment = .alignLeft
        picture.wantsLayer = true
        picture.layer?.cornerRadius = 6
        picture.layer?.masksToBounds = true

        transcript.isEditable = false
        transcript.isSelectable = true
        transcript.drawsBackground = false
        transcript.textContainerInset = NSSize(width: 0, height: 2)
        transcript.textContainer?.lineFragmentPadding = 0
        transcript.minSize = .zero
        transcript.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        transcript.isVerticallyResizable = true
        transcript.autoresizingMask = [.width]
        transcript.textContainer?.widthTracksTextView = true
        transcript.frame = NSRect(x: 0, y: 0, width: Self.width - 32, height: 10)
        transcriptScroll.documentView = transcript
        transcriptScroll.drawsBackground = false
        transcriptScroll.hasVerticalScroller = true
        transcriptScroll.autohidesScrollers = true

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        input.placeholderString = L("Ask anything about this…")
        input.font = .systemFont(ofSize: 14)
        input.isBordered = false
        input.drawsBackground = false
        input.focusRingType = .none
        input.delegate = self
        input.cell?.isScrollable = true
        input.cell?.wraps = false
        let field = NSBox()
        field.boxType = .custom
        field.cornerRadius = 8
        field.borderWidth = 0
        field.fillColor = NSColor.labelColor.withAlphaComponent(0.06)
        let fieldRow = Design.hstack([input, spinner], spacing: 6)
        fieldRow.translatesAutoresizingMaskIntoConstraints = false
        field.contentView?.addSubview(fieldRow)
        hint.lineBreakMode = .byTruncatingTail
        hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stack = Design.vstack([header, picture, transcriptScroll, field, hint], spacing: 10)
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 10, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        material.addSubview(stack)
        pictureHeight = picture.heightAnchor.constraint(equalToConstant: 0)
        transcriptHeight = transcriptScroll.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: material.topAnchor),
            stack.leadingAnchor.constraint(equalTo: material.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: material.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: material.bottomAnchor),
            material.widthAnchor.constraint(equalToConstant: Self.width),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            transcriptScroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            field.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            hint.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor, constant: -32),
            pictureHeight, transcriptHeight,
            picture.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor, constant: -32),
            fieldRow.leadingAnchor.constraint(equalTo: field.leadingAnchor, constant: 10),
            fieldRow.trailingAnchor.constraint(equalTo: field.trailingAnchor, constant: -8),
            fieldRow.topAnchor.constraint(equalTo: field.topAnchor, constant: 7),
            fieldRow.bottomAnchor.constraint(equalTo: field.bottomAnchor, constant: -7)
        ])
        panel.contentView = material
    }

    var isVisible: Bool { panel.isVisible }

    /// Opens beside the material (or a fifth of the way down the screen with the pointer), ready for
    /// a question; with something to ask about, ↩ alone explains it.
    func present(_ material: AskMaterial) {
        prepare(material)
        panel.present(focus: input)
    }

    /// Everything `present` does but show the panel.
    func prepare(_ material: AskMaterial) {
        request?.cancel()
        stopStreaming()
        self.material = material
        turns = []
        lastAnswer = nil
        transcript.string = ""
        input.stringValue = ""
        let snippet = material.text.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let what = material.image != nil ? L("Screenshot") : snippet.isEmpty ? "" : "“\(snippet)”"
        subject.stringValue = [what, material.source.app].filter { !$0.isEmpty }.joined(separator: " · ")
        for chip in chips { chip.isHidden = material.isEmpty }
        input.placeholderString = material.isEmpty ? L("Ask anything…") : L("Ask anything about this, or ↩ to explain")
        if let image = material.image {
            picture.image = image
            pictureHeight.constant = min(120, image.size.height * min(1, (Self.width - 32) / max(image.size.width, 1)))
            picture.isHidden = false
        } else {
            picture.image = nil
            picture.isHidden = true
        }
        updateHint()
        fit()
        place(near: material.anchor)
    }

    func close() {
        guard panel.isVisible else { return }
        request?.cancel()
        stopStreaming()
        onCancel?()
        panel.orderOut(nil)
    }

    // MARK: Asking

    @objc private func chipClicked(_ sender: NSButton) { run(Action.allCases[sender.tag]) }

    /// An action starts afresh on the material.
    private func run(_ action: Action) {
        guard !material.isEmpty else { return }
        turns = []
        transcript.string = ""
        conversationAction = action.rawValue
        ask(action: action.rawValue, question: "", shown: action.title)
    }

    private func submit() {
        let question = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if question.isEmpty {
            guard turns.isEmpty, !material.isEmpty else { return }
            run(.explain)
            return
        }
        input.stringValue = ""
        if turns.isEmpty { conversationAction = "ask" }
        ask(action: conversationAction, question: question, shown: question)
    }

    func ask(action: String, question: String, shown: String) {
        request?.cancel()
        onCancel?()
        let previous = turns
        append(shown, style: .question)
        // Room for the answer, filled in as it streams.
        streaming = append("", style: .answer)
        spinner.startAnimation(nil)
        request = Task { [weak self] in
            guard let self else { return }
            do {
                let answer = try await onAsk?(action, question, previous) ?? ""
                guard !Task.isCancelled else { return }
                // An action alone asks nothing: its user turn is empty, and the action frames the material.
                turns = previous + [AskTurn(role: .user, content: question), AskTurn(role: .assistant, content: answer)]
                lastAnswer = answer
                finishStreaming(answer, style: .answer)
            } catch {
                guard !Task.isCancelled else { return }
                finishStreaming(error.localizedDescription, style: .failure)
            }
            spinner.stopAnimation(nil)
            updateHint()
        }
    }

    enum Style { case question, answer, failure }

    /// Where the answer being streamed sits in the transcript.
    private var streaming: NSRange?

    /// More of the answer arrived: it replaces what was shown so far.
    func streamed(_ text: String) {
        guard let range = streaming else { return }
        streaming = replace(range, with: formatted(text, style: .answer))
    }

    /// A cancelled answer's slot is left as it is and nothing more streams into it.
    private func stopStreaming() {
        streaming = nil
        spinner.stopAnimation(nil)
    }

    private func finishStreaming(_ text: String, style: Style) {
        if let range = streaming { _ = replace(range, with: formatted(text, style: style)) } else { append(text, style: style) }
        streaming = nil
    }

    private func replace(_ range: NSRange, with piece: NSAttributedString) -> NSRange {
        transcript.textStorage?.replaceCharacters(in: range, with: piece)
        fit()
        transcript.scrollToEndOfDocument(nil)
        return NSRange(location: range.location, length: piece.length)
    }

    /// Adds a piece to the transcript; its range, for an answer still arriving.
    @discardableResult
    func append(_ text: String, style: Style) -> NSRange {
        let storage = transcript.textStorage!
        if storage.length > 0 { storage.append(NSAttributedString(string: style == .question ? "\n\n" : "\n")) }
        let piece = formatted(text, style: style)
        let range = NSRange(location: storage.length, length: piece.length)
        storage.append(piece)
        fit()
        transcript.scrollToEndOfDocument(nil)
        return range
    }

    private func formatted(_ text: String, style: Style) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = 4
        paragraph.lineSpacing = 2
        var piece: NSMutableAttributedString
        switch style {
        case .question:
            piece = NSMutableAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                                                                        .foregroundColor: NSColor.secondaryLabelColor])
        case .answer:
            let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            let parsed = (try? AttributedString(markdown: text, options: options)).map { NSAttributedString($0) } ?? NSAttributedString(string: text)
            piece = NSMutableAttributedString(attributedString: parsed)
            let whole = NSRange(location: 0, length: piece.length)
            piece.addAttribute(.foregroundColor, value: NSColor.labelColor, range: whole)
            // Keep bold and italic from the Markdown; set the size.
            piece.enumerateAttribute(.font, in: whole) { value, range, _ in
                let traits = (value as? NSFont)?.fontDescriptor.symbolicTraits ?? []
                let base = NSFont.systemFont(ofSize: 13.5)
                let font = NSFont(descriptor: base.fontDescriptor.withSymbolicTraits(traits), size: 13.5) ?? base
                piece.addAttribute(.font, value: font, range: range)
            }
        case .failure:
            piece = NSMutableAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: NSColor.systemOrange])
        }
        piece.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: piece.length))
        return piece
    }

    private func updateHint() {
        var parts = [material.isEmpty ? L("↩ ask") : turns.isEmpty ? L("↩ ask or explain") : L("↩ follow up")]
        if !material.isEmpty { parts.append(L("⌘1–3 actions")) }
        if lastAnswer != nil {
            parts += [L("⌘C copy"), L("⌘I inbox"), L("⌘P pin")]
            if material.replaceable != nil { parts.append(L("⌘↩ replace selection")) }
        }
        parts.append(L("⌘/ keys"))
        hint.stringValue = parts.joined(separator: "   ")
    }

    // MARK: Keys

    /// ⌘ keys while the panel is up; false lets them through to the text field.
    private func command(_ key: String, shift: Bool) -> Bool {
        if let digit = Int(key), (1...Action.allCases.count).contains(digit), !material.isEmpty {
            run(Action.allCases[digit - 1])
            return true
        }
        switch key {
        case "c":
            if let editor = input.currentEditor(), editor.selectedRange.length > 0 { return false }
            let selected = transcript.selectedRange()
            let text = selected.length > 0 ? (transcript.string as NSString).substring(with: selected) : lastAnswer
            guard let text else { return false }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            return true
        case "/":
            KeySheet.shared.toggle(L("Ask AI keys"), groups: KeyGuide.ask, over: panel)
            return true
        case "i":
            guard let lastAnswer else { return true }
            onKeep?(lastAnswer)
            return true
        case "p":
            guard let lastAnswer else { return true }
            onPin?(lastAnswer)
            return true
        case "\r":
            guard let lastAnswer, material.replaceable != nil else { return false }
            onReplace?(lastAnswer)
            return true
        default:
            return false
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            submit()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            close()
            return true
        default:
            return false
        }
    }

    // MARK: Layout

    /// The answers grow the panel downward from where it opened, then scroll.
    private func fit() {
        guard let layout = transcript.layoutManager, let container = transcript.textContainer, let content = panel.contentView else { return }
        // The text wraps at the scroll view's width, which is only known once the panel is laid out.
        content.layoutSubtreeIfNeeded()
        transcript.setFrameSize(NSSize(width: Self.width - 32, height: transcript.frame.height))
        layout.ensureLayout(for: container)
        let used = transcript.string.isEmpty ? 0 : layout.usedRect(for: container).height + 6
        transcriptHeight.constant = min(Self.maxTranscript, ceil(used))
        transcriptScroll.isHidden = used == 0
        content.layoutSubtreeIfNeeded()
        let height = content.fittingSize.height
        let top = panel.frame.maxY
        panel.setFrame(NSRect(x: panel.frame.minX, y: top - height, width: Self.width, height: height), display: true)
    }

    private func place(near anchor: NSRect?) {
        let pointer = NSEvent.mouseLocation
        let reference = anchor ?? NSRect(origin: pointer, size: .zero)
        let screen = ScreenGeometry.screen(at: NSPoint(x: reference.midX, y: reference.midY))
        let visible = screen.visibleFrame.insetBy(dx: 12, dy: 12)
        let height = panel.frame.height
        var x = (anchor?.minX ?? visible.midX - Self.width / 2)
        // Below what it's about, else above it; with nothing to point at, a fifth of the way down.
        var top = anchor.map { $0.minY - 8 } ?? (visible.maxY - visible.height * 0.2)
        if let anchor, top - height < visible.minY { top = min(visible.maxY, anchor.maxY + 8 + height) }
        x = min(max(x, visible.minX), visible.maxX - Self.width)
        top = min(max(top, visible.minY + height), visible.maxY)
        panel.setFrame(NSRect(x: x, y: top - height, width: Self.width, height: height), display: false)
    }
}
