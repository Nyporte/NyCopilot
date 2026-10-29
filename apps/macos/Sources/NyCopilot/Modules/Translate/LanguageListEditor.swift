import AppKit

/// Favorite languages as an ordered list: drag to reorder, − to remove, + to add from suggestions or
/// by name. The order is the order Tab steps through in the composer. Every change is saved at once.
@MainActor
final class LanguageListEditor: NSView, NSTableViewDataSource, NSTableViewDelegate {
    struct Language: Decodable { let name: String; let native: String; let code: String }

    /// Saves a new list; returns an error message to show (and keep the old list), or nil.
    var onChange: (([String]) -> String?)?
    /// Shown below the list for problems such as a rejected custom name.
    let message = Design.wrapping("", size: 11.5, color: .systemRed)

    private let table = NSTableView()
    private let addButton = NSButton()
    private var height: NSLayoutConstraint!
    private var names: [String] = []
    private var suggestions: [Language] = []
    /// Looks up the badge code and own name for languages that aren't suggestions.
    private var describe: (String) -> Language = { Language(name: $0, native: $0, code: String($0.prefix(2)).uppercased()) }
    private static let rowHeight: CGFloat = 36
    private static let maximum = 8
    private static let rowType = NSPasteboard.PasteboardType("dev.nycopilot.language-row")

    init() {
        super.init(frame: .zero)
        let column = NSTableColumn(identifier: .init("language"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.backgroundColor = .clear
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = .zero
        table.selectionHighlightStyle = .none
        table.gridStyleMask = []
        table.dataSource = self
        table.delegate = self
        table.registerForDraggedTypes([Self.rowType])
        table.draggingDestinationFeedbackStyle = .gap
        table.setAccessibilityLabel("Favorite languages, in Tab order")
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        column.resizingMask = .autoresizingMask
        // Tables load and recycle rows through their clip view, so the list lives in a scroll view
        // that is always exactly as tall as its rows and never scrolls.
        let list = NSScrollView()
        list.documentView = table
        list.drawsBackground = false
        list.hasVerticalScroller = false
        list.hasHorizontalScroller = false
        list.verticalScrollElasticity = .none
        list.horizontalScrollElasticity = .none
        list.borderType = .noBorder

        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add language")
        addButton.title = "Add Language"
        addButton.imagePosition = .imageLeading
        addButton.bezelStyle = .rounded
        addButton.target = self
        addButton.action = #selector(showAddMenu)
        message.isHidden = true

        let divider = AppearanceView()
        divider.fill = .separatorColor
        divider.radius = 0
        let footer = Design.hstack([addButton, message], spacing: 10)
        for view in [list, divider, footer] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        height = list.heightAnchor.constraint(equalToConstant: Self.rowHeight)
        NSLayoutConstraint.activate([
            list.leadingAnchor.constraint(equalTo: leadingAnchor),
            list.trailingAnchor.constraint(equalTo: trailingAnchor),
            list.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            height,
            divider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            divider.topAnchor.constraint(equalTo: list.bottomAnchor, constant: 4),
            divider.heightAnchor.constraint(equalToConstant: 1),
            footer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            footer.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            footer.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 10),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10)
        ])
    }

    required init?(coder: NSCoder) { fatalError("Use init()") }

    func load(_ names: [String], suggestions: [Language], describe: @escaping (String) -> Language) {
        self.names = names
        self.suggestions = suggestions
        self.describe = describe
        reload()
    }

    private func language(_ name: String) -> Language {
        suggestions.first { $0.name.caseInsensitiveCompare(name) == .orderedSame } ?? describe(name)
    }

    private func reload() {
        height.constant = CGFloat(max(names.count, 1)) * Self.rowHeight
        table.reloadData()
        addButton.isEnabled = names.count < Self.maximum
        addButton.toolTip = names.count < Self.maximum ? nil : "You can keep up to \(Self.maximum) languages."
    }

    /// Commit a new order or set; on rejection keep what was saved and say why.
    private func commit(_ updated: [String]) {
        if let problem = onChange?(updated) {
            message.stringValue = problem
            message.isHidden = false
        } else {
            names = updated
            message.isHidden = true
        }
        reload()
    }

    // MARK: Rows

    func numberOfRows(in tableView: NSTableView) -> Int { names.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let shown = language(names[row])
        let cell = LanguageRow(language: shown, canRemove: names.count > 1, isLast: row == names.count - 1)
        // Cells are rebuilt on every change, so the row index is always current.
        cell.onRemove = { [weak self] in
            guard let self, names.indices.contains(row) else { return }
            var updated = names
            updated.remove(at: row)
            commit(updated)
        }
        return cell
    }

    // MARK: Reordering

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let item = NSPasteboardItem()
        item.setString(String(row), forType: Self.rowType)
        return item
    }

    /// Plain row views give the table no drag image, so it invents one pinned by its corner to the
    /// pointer — the row appears to jump. Instead, drag a snapshot of the row placed exactly where the
    /// row is, so the spot you pressed stays under the pointer.
    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint,
                   forRowIndexes rowIndexes: IndexSet) {
        guard let row = rowIndexes.first, let view = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) else { return }
        let frame = tableView.rect(ofRow: row)
        let image = Self.liftedSnapshot(of: view, size: frame.size)
        session.enumerateDraggingItems(options: [], for: tableView, classes: [NSPasteboardItem.self], searchOptions: [:]) { item, _, _ in
            item.setDraggingFrame(frame, contents: image)
        }
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    /// The row drawn on a rounded, slightly translucent card so it reads as picked up.
    private static func liftedSnapshot(of view: NSView, size: NSSize) -> NSImage {
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        if let rep { view.cacheDisplay(in: view.bounds, to: rep) }
        return NSImage(size: size, flipped: false) { rect in
            NSColor.controlBackgroundColor.withAlphaComponent(0.92).setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 4, dy: 1), xRadius: 6, yRadius: 6).fill()
            rep?.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            return true
        }
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
        guard info.draggingSource as? NSTableView === table else { return [] }
        tableView.setDropRow(row, dropOperation: .above)
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard let source = info.draggingPasteboard.string(forType: Self.rowType).flatMap(Int.init),
              names.indices.contains(source) else { return false }
        var updated = names
        let moved = updated.remove(at: source)
        updated.insert(moved, at: source < row ? row - 1 : row)
        guard updated != names else { return false }
        commit(updated)
        return true
    }

    // MARK: Adding

    @objc private func showAddMenu() {
        let menu = NSMenu()
        for suggestion in suggestions where !names.contains(where: { $0.caseInsensitiveCompare(suggestion.name) == .orderedSame }) {
            let title = suggestion.native == suggestion.name ? suggestion.name : "\(suggestion.native) — \(suggestion.name)"
            let item = NSMenuItem(title: title, action: #selector(addSuggestion(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = suggestion.name
            menu.addItem(item)
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        let other = NSMenuItem(title: "Other Language…", action: #selector(addOther), keyEquivalent: "")
        other.target = self
        menu.addItem(other)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: addButton.bounds.maxY + 4), in: addButton)
    }

    @objc private func addSuggestion(_ sender: NSMenuItem) {
        if let name = sender.representedObject as? String { commit(names + [name]) }
    }

    /// Any language name the model understands, such as "Brazilian Portuguese" or "formal Japanese".
    @objc private func addOther() {
        guard let window else { return }
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "Brazilian Portuguese"
        let alert = NSAlert()
        alert.messageText = "Add a language"
        alert.informativeText = "Type any language or style the model understands, such as “formal Japanese”."
        alert.accessoryView = field
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return }
            commit(names + [name])
        }
    }
}

/// One favorite: drag handle, badge, own name with the English name beside it, and a remove button.
private final class LanguageRow: NSView {
    var onRemove: (() -> Void)?

    init(language: LanguageListEditor.Language, canRemove: Bool, isLast: Bool) {
        super.init(frame: .zero)
        let grip = Design.symbol("line.3.horizontal", size: 11, color: .tertiaryLabelColor)
        grip.toolTip = "Drag to reorder"
        let badge = AppearanceView()
        badge.radius = 5
        badge.fill = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor.white.withAlphaComponent(0.1) : NSColor.black.withAlphaComponent(0.06) }
        let wide = language.code.unicodeScalars.first.map { $0.value > 0x2E80 } ?? false
        let code = Design.label(language.code, size: wide ? 12 : 10.5, weight: .semibold, color: .secondaryLabelColor)
        code.translatesAutoresizingMaskIntoConstraints = false
        badge.addSubview(code)
        badge.translatesAutoresizingMaskIntoConstraints = false
        let native = Design.label(language.native, size: 13)
        let english = Design.label(language.native == language.name ? "" : language.name, size: 12, color: .secondaryLabelColor)
        let remove = NSButton(image: NSImage(systemSymbolName: "minus.circle", accessibilityDescription: "Remove \(language.name)")!,
                              target: nil, action: nil)
        remove.isBordered = false
        remove.contentTintColor = .secondaryLabelColor
        remove.isEnabled = canRemove
        remove.toolTip = canRemove ? "Remove" : "Keep at least one language"
        remove.target = self
        remove.action = #selector(removeTapped)
        let row = Design.hstack([grip, badge, native, english, Design.spacer(), remove], spacing: 10)
        row.setCustomSpacing(8, after: native)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        var constraints = [
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.widthAnchor.constraint(equalToConstant: 24),
            badge.heightAnchor.constraint(equalToConstant: 18),
            code.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
            code.centerYAnchor.constraint(equalTo: badge.centerYAnchor)
        ]
        if !isLast {
            let divider = AppearanceView()
            divider.fill = .separatorColor
            divider.radius = 0
            divider.translatesAutoresizingMaskIntoConstraints = false
            addSubview(divider)
            constraints += [
                divider.leadingAnchor.constraint(equalTo: native.leadingAnchor),
                divider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
                divider.bottomAnchor.constraint(equalTo: bottomAnchor),
                divider.heightAnchor.constraint(equalToConstant: 1)
            ]
        }
        NSLayoutConstraint.activate(constraints)
        setAccessibilityElement(true)
        setAccessibilityLabel(language.native == language.name ? language.name : "\(language.native), \(language.name)")
    }

    required init?(coder: NSCoder) { fatalError("Use init(language:canRemove:isLast:)") }

    @objc private func removeTapped() { onRemove?() }
}
