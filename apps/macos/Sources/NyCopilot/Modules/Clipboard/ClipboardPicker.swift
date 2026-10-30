import AppKit

/// The clipboard history as a small floating list near the pointer: type to search, ↑↓ to choose,
/// Return (or a double-click) to paste, ⌘1–⌘9 to paste one of the first nine, ⌘C to copy without
/// pasting, ⌘⌫ to forget an entry, Esc to close.
@MainActor
final class ClipboardPicker: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private struct Entry: Decodable { let text: String; let app: String? }
    private typealias Item = CoreRecord<Entry>

    /// The chosen text, and the field it should go back into.
    var onPick: ((String, InputTarget?) -> Void)?

    private let core: NyCore
    private let panel = PickerPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 380),
                                    styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: true)
    private let search = NSSearchField()
    private let table = NSTableView()
    private let empty = Design.label("", size: 12.5, color: .tertiaryLabelColor)
    private var items: [Item] = []
    private var target: InputTarget?
    private var source: NSRunningApplication?
    private let age: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.dateTimeStyle = .named
        return formatter
    }()

    init(core: NyCore) {
        self.core = core
        super.init()
        panel.float(at: .floating, shadow: true, behavior: .transient)
        panel.onCancel = { [weak self] in self?.close() }
        panel.onCommand = { [weak self] key in self?.command(key) ?? false }
        panel.onResignKey = { [weak self] in self?.close(returningFocus: false) }

        let material = NSVisualEffectView.roundedMaterial(.popover, radius: 12)
        search.placeholderString = "Search clipboard history"
        search.delegate = self
        search.focusRingType = .none
        search.font = .systemFont(ofSize: 14)

        let column = NSTableColumn(identifier: .init("item"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 46
        table.style = .plain
        table.backgroundColor = .clear
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(pickClicked)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        let hint = Design.label("↩ paste   ⌘1–9 pick   ⌘C copy   ⌘⌫ forget   esc close", size: 10.5, color: .tertiaryLabelColor)
        for view in [search, scroll, hint, empty] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            material.addSubview(view)
        }
        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: material.topAnchor, constant: 12),
            search.leadingAnchor.constraint(equalTo: material.leadingAnchor, constant: 12),
            search.trailingAnchor.constraint(equalTo: material.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: material.leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: material.trailingAnchor, constant: -6),
            scroll.bottomAnchor.constraint(equalTo: hint.topAnchor, constant: -6),
            hint.leadingAnchor.constraint(equalTo: material.leadingAnchor, constant: 14),
            hint.bottomAnchor.constraint(equalTo: material.bottomAnchor, constant: -9),
            empty.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor)
        ])
        panel.contentView = material
    }

    var isVisible: Bool { panel.isVisible }

    /// Opens near the pointer, newest copy selected, ready for typing.
    func present(target: InputTarget?, source: NSRunningApplication?) {
        self.target = target
        self.source = source
        search.stringValue = ""
        reload()
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        let size = panel.frame.size
        let origin = NSPoint(x: min(max(pointer.x - size.width / 2, visible.minX), visible.maxX - size.width),
                             y: min(max(pointer.y - size.height - 12, visible.minY), visible.maxY - size.height))
        panel.setFrameOrigin(origin)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(search)
    }

    /// Closes the list; unless a paste is about to return there anyway, focus goes back to the app
    /// you were in.
    func close(returningFocus: Bool = true) {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        if returningFocus, let source, !source.isTerminated { source.activate(options: []) }
        target = nil
    }

    private func reload() {
        var params: [String: Any] = ["collection": CoreCollection.clipboardItems.rawValue, "limit": 200]
        let query = search.stringValue.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty { params["search"] = query }
        items = (try? core.call("records.list", params, as: CorePage<Entry>.self).records) ?? []
        table.reloadData()
        if !items.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false); table.scrollRowToVisible(0) }
        empty.stringValue = query.isEmpty ? "Copy some text and it shows up here." : "Nothing matches “\(query)”."
        empty.isHidden = !items.isEmpty
    }

    private func pick(_ row: Int) {
        guard items.indices.contains(row) else { return }
        let text = items[row].data.text, target = target
        onPick?(text, target)
    }

    @objc private func pickClicked() { pick(table.clickedRow) }

    /// ⌘ shortcuts while the list is up; false lets the key through to the search field.
    private func command(_ key: String) -> Bool {
        if let digit = Int(key), (1...9).contains(digit) { pick(digit - 1); return true }
        switch key {
        case "c":
            guard items.indices.contains(table.selectedRow) else { return false }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(items[table.selectedRow].data.text, forType: .string)
            close()
            return true
        case "\u{8}", "\u{7F}":
            guard items.indices.contains(table.selectedRow) else { return true }
            let row = table.selectedRow
            _ = try? core.call("records.delete", ["id": items[row].id])
            reload()
            if !items.isEmpty { table.selectRowIndexes([min(row, items.count - 1)], byExtendingSelection: false) }
            return true
        default:
            return false
        }
    }

    // MARK: Search field

    func controlTextDidChange(_ notification: Notification) { reload() }

    /// ↑↓ move through the list and Return pastes, while typing stays in the search field.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)):
            guard !items.isEmpty else { return true }
            let step = selector == #selector(NSResponder.moveDown(_:)) ? 1 : -1
            let row = min(max(table.selectedRow + step, 0), items.count - 1)
            table.selectRowIndexes([row], byExtendingSelection: false)
            table.scrollRowToVisible(row)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            pick(table.selectedRow)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            close()
            return true
        default:
            return false
        }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: .init("clip"), owner: nil) as? ClipRow ?? ClipRow()
        cell.identifier = .init("clip")
        let item = items[row]
        cell.preview.stringValue = item.data.text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isNewline).prefix(2).joined(separator: " ⏎ ")
        // Never "in 0s": a copy made this instant is simply "now".
        let now = Date()
        let when = age.localizedString(for: min(Date(timeIntervalSince1970: Double(item.createdAt) / 1000), now), relativeTo: now)
        cell.metadata.stringValue = [row < 9 ? "⌘\(row + 1)" : nil, item.data.app.flatMap { $0.isEmpty ? nil : $0 }, when]
            .compactMap { $0 }.joined(separator: "  ·  ")
        return cell
    }
}

private final class ClipRow: NSTableCellView {
    let preview = Design.label("", size: 13)
    let metadata = Design.label("", size: 10.5, color: .secondaryLabelColor)

    init() {
        super.init(frame: .zero)
        preview.lineBreakMode = .byTruncatingTail
        let stack = Design.vstack([preview, metadata], spacing: 3)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            preview.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("Use init()") }
}

/// Borderless but able to take typing; Esc and ⌘ keys go to the picker, and it closes when you
/// click elsewhere.
private final class PickerPanel: NSPanel {
    var onCancel: (() -> Void)?
    var onCommand: ((String) -> Bool)?
    var onResignKey: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel?() }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if flags == [.command], let key = event.charactersIgnoringModifiers?.lowercased(), onCommand?(key) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }
}
