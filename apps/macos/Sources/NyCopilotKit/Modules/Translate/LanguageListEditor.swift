import AppKit

/// Favorite languages as an ordered list: ▲ ▼ to reorder, − to remove, + to add from suggestions or
/// by name. The order is the order Tab steps through in the composer. Every change is saved at once.
@MainActor
final class LanguageListEditor: NSView, NSTableViewDataSource, NSTableViewDelegate {
    typealias Language = NyCore.LanguageInfo

    /// Saves a new list; returns an error message to show (and keep the old list), or nil.
    var onChange: (([String]) -> String?)?
    /// Shown below the list for problems such as a rejected custom name.
    let message = Design.wrapping("", size: 11.5, color: .systemRed)

    private let table = NSTableView()
    private let addButton = NSButton()
    private var height: NSLayoutConstraint!
    private var names: [String] = []
    private var suggestions: [Language] = []
    /// Looks up the badge code and own name for languages that aren't suggestions (set by `load`).
    private var describe: (String) -> Language = { Language(name: $0, native: $0, code: "") }
    private static let rowHeight: CGFloat = 36
    private static let maximum = 8

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
        table.setAccessibilityLabel(L("Favorite languages, in Tab order"))
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

        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: L("Add language"))
        addButton.title = L("Add Language")
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
        addButton.toolTip = names.count < Self.maximum ? nil : L("You can keep up to %ld languages.", Self.maximum)
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
        let cell = LanguageRow(language: shown, isFirst: row == 0, isLast: row == names.count - 1, canRemove: names.count > 1)
        // Cells are rebuilt on every change, so the row index is always current.
        cell.onRemove = { [weak self] in
            guard let self, names.indices.contains(row) else { return }
            var updated = names
            updated.remove(at: row)
            commit(updated)
        }
        cell.onMove = { [weak self] step in self?.move(row, by: step) }
        return cell
    }

    /// Swap a language with its neighbour above (-1) or below (+1).
    func move(_ row: Int, by step: Int) {
        let target = row + step
        guard names.indices.contains(row), names.indices.contains(target) else { return }
        var updated = names
        updated.swapAt(row, target)
        commit(updated)
    }

    // MARK: Adding

    @objc private func showAddMenu() {
        let menu = NSMenu()
        for suggestion in suggestions where !names.contains(where: { $0.caseInsensitiveCompare(suggestion.name) == .orderedSame }) {
            let title = suggestion.native == suggestion.name ? L(suggestion.name) : "\(suggestion.native) — \(L(suggestion.name))"
            let item = NSMenuItem(title: title, action: #selector(addSuggestion(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = suggestion.name
            menu.addItem(item)
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        let other = NSMenuItem(title: L("Other Language…"), action: #selector(addOther), keyEquivalent: "")
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
        field.placeholderString = L("Brazilian Portuguese")
        let alert = NSAlert()
        alert.messageText = L("Add a language")
        alert.informativeText = L("Type any language or style the model understands, such as “formal Japanese”.")
        alert.accessoryView = field
        alert.addButton(withTitle: L("Add"))
        alert.addButton(withTitle: L("Cancel"))
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return }
            commit(names + [name])
        }
    }
}

/// One favorite: badge, own name with the English name beside it, then move up, move down, remove.
private final class LanguageRow: NSView {
    var onRemove: (() -> Void)?
    var onMove: ((Int) -> Void)?

    init(language: LanguageListEditor.Language, isFirst: Bool, isLast: Bool, canRemove: Bool) {
        super.init(frame: .zero)
        let badge = AppearanceView()
        badge.radius = 5
        badge.fill = LanguageBadge.fill
        let code = Design.label(language.code, color: .secondaryLabelColor)
        code.font = LanguageBadge.font(for: language.code)
        code.translatesAutoresizingMaskIntoConstraints = false
        badge.addSubview(code)
        badge.translatesAutoresizingMaskIntoConstraints = false
        let native = Design.label(language.native, size: 13)
        // The core's English name, in the interface language; a name typed by hand shows as typed.
        let english = Design.label(language.native == language.name ? "" : L(language.name), size: 12, color: .secondaryLabelColor)
        // A disabled button fades, so the first row has no ▲ to press.
        let up = Self.button("chevron.up", L("Move %@ up", L(language.name)), enabled: !isFirst, action: #selector(moveRowUp), target: self)
        let down = Self.button("chevron.down", L("Move %@ down", L(language.name)), enabled: !isLast, action: #selector(moveRowDown), target: self)
        let remove = Self.button("minus.circle", L("Remove %@", L(language.name)), enabled: canRemove, action: #selector(removeTapped), target: self)
        remove.toolTip = canRemove ? L("Remove") : L("Keep at least one language")
        let controls = Design.hstack([up, down], spacing: 2)
        let row = Design.hstack([badge, native, english, Design.spacer(), controls, remove], spacing: 10)
        row.setCustomSpacing(8, after: native)
        row.setCustomSpacing(14, after: controls)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        var constraints = [
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.widthAnchor.constraint(equalToConstant: LanguageBadge.size.width),
            badge.heightAnchor.constraint(equalToConstant: LanguageBadge.size.height),
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
    }

    required init?(coder: NSCoder) { fatalError("Use init(language:isFirst:isLast:canRemove:)") }

    private static func button(_ symbol: String, _ label: String, enabled: Bool, action: Selector, target: AnyObject) -> NSButton {
        let button = Design.iconButton(symbol, label: label, pointSize: 12, weight: .medium, target: target, action: action)
        button.isEnabled = enabled
        return button
    }

    @objc private func moveRowUp() { onMove?(-1) }
    @objc private func moveRowDown() { onMove?(1) }
    @objc private func removeTapped() { onRemove?() }
}
