import AppKit
@preconcurrency import VisionKit

/// Live Text on a still image in a view — a capture's selection or a pin: an overlay that makes its
/// words selectable right where they are, ⌘C for the selected words, T (again) or Return for all of
/// them, and Esc to end. A double tap faster than recognition copies as soon as the text is read.
/// The view it's in says what happens around it.
@MainActor
final class LiveTextController {
    /// The text is read: how many lines (none when there's no text).
    var onRead: ((Int) -> Void)?
    /// Every line is on the clipboard: how many.
    var onCopiedAll: ((Int) -> Void)?
    /// A short note: the selection was copied, or there was nothing to copy.
    var onFlash: ((String) -> Void)?
    /// The overlay is gone.
    var onEnd: (() -> Void)?

    private(set) var overlay: ImageAnalysisOverlayView?
    private var copyWhenRead = false

    var isActive: Bool { overlay != nil }

    /// How T and C read modifiers. A capture takes T alone and ⌘C alone; a pin looks only at ⌘,
    /// so ⇧T copies all and ⌘⇧C copies the selection there too.
    enum KeyRule { case exact, commandOnly }
    let keyRule: KeyRule

    init(keyRule: KeyRule = .exact) { self.keyRule = keyRule }

    /// Covers `frame` in `host`, under `sibling`, and shows the text once `analysis` has read it.
    @discardableResult
    func begin(in host: NSView, frame: CGRect, below sibling: NSView, reading analysis: Task<ImageAnalysis, Error>) -> ImageAnalysisOverlayView {
        let overlay = LiveText.overlay(frame: frame)
        host.addSubview(overlay, positioned: .below, relativeTo: sibling)
        self.overlay = overlay
        Task { [weak self] in
            let analysis = try? await analysis.value
            guard let self, self.overlay === overlay else { return }
            LiveText.show(analysis, on: overlay)
            onRead?(analysis.map(LiveText.lineCount) ?? 0)
            if copyWhenRead, self.overlay === overlay { copyAll() }
        }
        return overlay
    }

    func end() {
        guard let overlay else { return }
        overlay.removeFromSuperview()
        self.overlay = nil
        copyWhenRead = false
        onEnd?()
    }

    /// Every line, as soon as the text is read.
    func copyAll() {
        guard let overlay else { return }
        guard let analysis = overlay.analysis else { copyWhenRead = true; return }
        let transcript = analysis.transcript
        guard !transcript.isEmpty else { onFlash?(L("No text to copy")); return }
        LiveText.copy(transcript)
        onCopiedAll?(transcript.split(whereSeparator: \.isNewline).count)
    }

    /// ⌘C: the selected words, staying in Live Text.
    func copySelection() {
        guard let overlay, overlay.analysis != nil else { return }
        let text = LiveText.textToCopy(from: overlay)
        guard !text.isEmpty else { return }
        LiveText.copy(text)
        onFlash?(L("Copied"))
    }

    /// Esc, T, Return, and ⌘C while reading text; false for any other key, which the overlay
    /// passes along.
    func keyDown(_ event: NSEvent) -> Bool {
        guard isActive else { return false }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let command = flags.contains(.command)
        let plain = keyRule == .exact ? flags.isEmpty : !command
        let withCommand = keyRule == .exact ? flags == [.command] : command
        switch (event.keyCode, key) {
        case (53, _): end()
        case (_, "t") where plain, (36, _), (76, _): copyAll()
        case (_, "c") where withCommand: copySelection()
        default: return false
        }
        return true
    }
}
