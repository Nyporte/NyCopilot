import AppKit

/// The text found in a capture or pin, beside where it came from. It opens at once and fills in when
/// recognition finishes; the text can be selected, corrected, and copied. Esc closes it.
@MainActor
final class RecognizedTextWindow: NSPanel, NSTextViewDelegate {
    var onClose: ((RecognizedTextWindow) -> Void)?

    private let textView = NSTextView()
    private let status = StatusLine()
    private let copyButton = Design.button("Copy All", target: nil, action: nil, primary: true)
    private var reading: Task<Void, Never>?

    /// `anchor` is the source's frame in screen coordinates (bottom-left origin).
    init(near anchor: NSRect, text: Task<String, Error>) {
        let size = NSSize(width: 420, height: 280)
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable, .utilityWindow],
                   backing: .buffered, defer: false)
        title = "Recognized Text"
        level = .floating
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        minSize = NSSize(width: 280, height: 160)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = makeContent()
        setFrameOrigin(Self.origin(for: size, beside: anchor))

        status.showProgress("Recognizing text…")
        copyButton.isEnabled = false
        reading = Task { [weak self] in
            let result: Result<String, Error>
            do { result = .success(try await text.value) } catch { result = .failure(error) }
            self?.show(result)
        }
    }

    private func makeContent() -> NSView {
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: 13)
        textView.textColor = .labelColor
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = self
        textView.setAccessibilityLabel("Recognized text")
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        copyButton.target = self
        copyButton.action = #selector(copyAll)
        let bar = Design.hstack([status, Design.spacer(), copyButton], spacing: 8)

        let content = NSVisualEffectView()
        content.material = .windowBackground
        for view in [scroll, bar] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            bar.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 8),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            bar.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10)
        ])
        return content
    }

    private func show(_ result: Result<String, Error>) {
        switch result {
        case .success(let text) where text.isEmpty:
            status.show("No text found here.", style: .info)
        case .success(let text):
            textView.string = text
            copyButton.isEnabled = true
            let lines = text.split(separator: "\n").count
            status.show("\(lines) line\(lines == 1 ? "" : "s")", style: .info)
        case .failure(let error):
            status.show("Couldn’t read text: \(error.localizedDescription)", style: .error)
        }
    }

    /// Beside the source — right, then left, then below or above — and always on its screen.
    private static func origin(for size: NSSize, beside anchor: NSRect) -> NSPoint {
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? anchor.insetBy(dx: -size.width, dy: -size.height)
        let gap: CGFloat = 12
        let top = anchor.maxY - size.height
        let candidates = [
            NSPoint(x: anchor.maxX + gap, y: top),
            NSPoint(x: anchor.minX - gap - size.width, y: top),
            NSPoint(x: anchor.minX, y: anchor.minY - gap - size.height),
            NSPoint(x: anchor.minX, y: anchor.maxY + gap)
        ]
        let fits = candidates.first { visible.contains(NSRect(origin: $0, size: size)) } ?? candidates[0]
        return NSPoint(x: min(max(fits.x, visible.minX), visible.maxX - size.width),
                       y: min(max(fits.y, visible.minY), visible.maxY - size.height))
    }

    @objc private func copyAll() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(textView.string, forType: .string)
        status.show("Copied.", style: .success)
    }

    /// In a text view, Esc means "complete"; here it means close.
    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(cancelOperation(_:)) || selector == #selector(NSTextView.complete(_:)) else { return false }
        close()
        return true
    }

    override func cancelOperation(_ sender: Any?) { close() }

    override func close() {
        reading?.cancel()
        super.close()
        onClose?(self)
    }
}
