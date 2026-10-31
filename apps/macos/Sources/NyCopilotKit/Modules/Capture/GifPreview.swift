import AppKit

/// What's done with a finished recording.
enum GifAction { case copy, save, quickSave, inbox }

/// The finished GIF, playing on a loop above the region it was recorded from, with what it is (length,
/// size, file size) and what to do with it, the likeliest on the right: ↩ copy (the default), ⌘S
/// save…, I keep in the inbox. Esc, the trash button, or ⌘⌫ discards it — Return copies, so Esc is
/// never the default — and a click elsewhere leaves it up.
@MainActor
final class GifPreview {
    var onAction: ((GifAction, GifClip) -> Void)?
    var onDiscard: ((GifClip) -> Void)?

    private let clip: GifClip
    let panel: PreviewPanel

    init(clip: GifClip, near region: NSRect, on screen: NSScreen) {
        self.clip = clip
        panel = PreviewPanel()
        panel.onKey = { [weak self] key in self?.key(key) ?? false }
        let visible = screen.visibleFrame.insetBy(dx: 12, dy: 12)
        // At most half the screen across, and the recording's own size at most.
        let fit = min(1, visible.width * 0.5 / max(clip.size.width, 1), visible.height * 0.5 / max(clip.size.height, 1))
        let picture = CGSize(width: max(220, (clip.size.width * fit).rounded()), height: max(80, (clip.size.height * fit).rounded()))
        let content = makeContent(picture: picture)
        panel.contentView = content
        let size = content.fittingSize
        let center = NSPoint(x: region.midX, y: region.midY)
        panel.setFrame(NSRect(x: min(max(center.x - size.width / 2, visible.minX), visible.maxX - size.width),
                              y: min(max(center.y - size.height / 2, visible.minY), visible.maxY - size.height),
                              width: size.width, height: size.height), display: false)
    }

    func show() {
        panel.present()
    }

    func close() { panel.orderOut(nil) }

    private func makeContent(picture size: CGSize) -> NSView {
        let material = NSVisualEffectView.roundedMaterial(.hudWindow, radius: 14)
        material.appearance = NSAppearance(named: .darkAqua)
        let image = NSImageView()
        image.image = NSImage(contentsOf: clip.url)
        image.animates = true
        image.imageScaling = .scaleProportionallyUpOrDown
        image.wantsLayer = true
        image.layer?.cornerRadius = 6
        image.layer?.masksToBounds = true
        image.widthAnchor.constraint(equalToConstant: size.width).isActive = true
        image.heightAnchor.constraint(equalToConstant: size.height).isActive = true
        let seconds = Int(clip.duration.rounded())
        let info = Design.label("\(String(format: "%d:%02d", seconds / 60, seconds % 60))  ·  \(clip.pixels.width) × \(clip.pixels.height)  ·  "
                                + ByteCountFormatter.string(fromByteCount: Int64(clip.bytes), countStyle: .file),
                                size: 12, color: NSColor.white.withAlphaComponent(0.75))
        let discard = NSButton(image: NSImage(systemSymbolName: "trash", accessibilityDescription: "Discard")!, target: self,
                               action: #selector(discardTapped))
        discard.bezelStyle = .rounded
        discard.toolTip = "Discard (Esc or ⌘⌫)"
        let inbox = button("Inbox", "I", #selector(inboxTapped))
        let save = button("Save…", "⌘S · ⇧⌘S quick save", #selector(saveTapped))
        let copy = button("Copy", "↩", #selector(copyTapped))
        // The default: Return, drawn in the accent color.
        copy.keyEquivalent = "\r"
        let actions = Design.hstack([discard, Design.spacer(), inbox, save, copy], spacing: 8)
        let column = Design.vstack([image, info, actions], spacing: 10, alignment: .centerX)
        column.translatesAutoresizingMaskIntoConstraints = false
        material.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: material.leadingAnchor, constant: 14),
            column.trailingAnchor.constraint(equalTo: material.trailingAnchor, constant: -14),
            column.topAnchor.constraint(equalTo: material.topAnchor, constant: 14),
            column.bottomAnchor.constraint(equalTo: material.bottomAnchor, constant: -12),
            actions.widthAnchor.constraint(equalTo: column.widthAnchor)
        ])
        return material
    }

    private func button(_ title: String, _ key: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.toolTip = "\(title.replacingOccurrences(of: "…", with: "")) (\(key))"
        return button
    }

    /// Keys while the preview is up; false lets the panel handle the rest.
    private func key(_ key: PreviewPanel.Key) -> Bool {
        switch key {
        case .returnKey: act(.copy)
        case .escape: discardTapped()
        case .character("i"): act(.inbox)
        case .command("c"): act(.copy)
        case .command("s"): act(.save)
        case .shiftCommand("s"): act(.quickSave)
        case .command("\u{8}"), .command("\u{7F}"): discardTapped()
        default: return false
        }
        return true
    }

    private func act(_ action: GifAction) {
        close()
        onAction?(action, clip)
    }

    @objc private func copyTapped() { act(.copy) }
    @objc private func saveTapped() { act(.save) }
    @objc private func inboxTapped() { act(.inbox) }
    @objc private func discardTapped() {
        close()
        onDiscard?(clip)
    }
}

/// Its keys are single letters as well as ⌘ keys, so it reads them itself.
final class PreviewPanel: FloatingPanel {
    enum Key: Equatable {
        case returnKey, escape, character(String), command(String), shiftCommand(String)

        var isCommand: Bool {
            switch self {
            case .command, .shiftCommand: true
            default: false
            }
        }
    }
    var onKey: ((Key) -> Bool)?

    init() {
        super.init(size: .zero, level: .statusBar, behavior: [])
    }

    override func keyDown(with event: NSEvent) {
        if let key = Self.key(event), onKey?(key) == true { return }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        switch Self.key(event) {
        case .some(let key) where key.isCommand: if onKey?(key) == true { return true }
        default: break
        }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) { _ = onKey?(.escape) }

    private static func key(_ event: NSEvent) -> Key? {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let character = event.charactersIgnoringModifiers?.lowercased() ?? ""
        switch (event.keyCode, flags) {
        case (36, []), (76, []): return .returnKey
        case (53, []): return .escape
        case (_, [.command]): return .command(character)
        case (_, [.command, .shift]): return .shiftCommand(character)
        case (_, []): return .character(character)
        default: return nil
        }
    }
}
