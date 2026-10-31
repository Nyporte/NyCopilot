import AppKit

// The inbox window's list, its rows, and the window itself.
extension String {
    /// "Today" reads as "today" mid-sentence; a date stays as it is.
    var lowercasedIfRelative: String { self == "Today" || self == "Yesterday" ? lowercased() : "on \(self)" }
}

/// The list: its keys go to the window's actions first.
final class InboxTable: NSTableView {
    enum Key: Equatable { case space, returnKey, delete, command(String), character(String) }
    var onKey: ((Key) -> Bool)?

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key: Key? = switch (event.keyCode, flags) {
        case (49, []): .space
        case (36, []), (76, []): .returnKey
        case (51, []), (117, []), (51, [.command]): .delete
        case (_, []), (_, [.shift]): event.charactersIgnoringModifiers.map { .character($0.lowercased()) }
        default: nil
        }
        if let key, onKey?(key) == true { return }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if window?.firstResponder === self, flags == [.command], let key = event.charactersIgnoringModifiers?.lowercased(),
           onKey?(.command(key)) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

final class InboxRow: NSTableCellView {
    let icon = NSImageView()
    let title = Design.label("", size: 13)
    let metadata = Design.label("", size: 11, color: .secondaryLabelColor)

    init() {
        super.init(frame: .zero)
        icon.contentTintColor = .secondaryLabelColor
        icon.symbolConfiguration = .init(pointSize: 12, weight: .regular)
        title.lineBreakMode = .byTruncatingTail
        let text = Design.vstack([title, metadata], spacing: 2)
        let stack = Design.hstack([icon, text], spacing: 8)
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16)
        ])
    }

    required init?(coder: NSCoder) { fatalError("Use init()") }
}

/// Escape closes the window, as in History.
final class InboxWindowPanel: NSWindow {
    override func cancelOperation(_ sender: Any?) { performClose(sender) }
}
