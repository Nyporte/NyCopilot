import AppKit

/// Every time zone this Mac knows, in a popover with a search field: type a city, a zone's name,
/// or an offset ("gmt+9"), move with ↑ ↓, and press Return or click to pick one.
@MainActor
final class ZonePicker: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let all: [ClockZones.Choice]
    private var shown: [ClockZones.Choice]
    /// The first row, "This Mac's time zone", when it can be picked; its id is empty.
    private let thisMac: ClockZones.Choice?
    private let onPick: (_ id: String) -> Void
    private let search = NSSearchField()
    private let table = NSTableView()
    private weak var popover: NSPopover?

    init(includeThisMac: Bool, onPick: @escaping (_ id: String) -> Void) {
        all = ClockZones.choices(locale: Localization.locale)
        let here = TimeZone.current
        thisMac = includeThisMac ? ClockZones.Choice(id: "", city: L("This Mac’s time zone"),
                                                       name: ClockZones.city(here, locale: Localization.locale), offset: "", seconds: 0) : nil
        shown = (thisMac.map { [$0] } ?? []) + all
        self.onPick = onPick
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("Use init(includeThisMac:onPick:)") }

    /// Shows the picker under `view`.
    func present(below view: NSView) {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = self
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
        self.popover = popover
        view.window?.makeFirstResponder(search)
        popover.contentViewController?.view.window?.makeFirstResponder(search)
    }

    override func loadView() {
        search.placeholderString = L("City, zone, or GMT offset")
        search.delegate = self
        search.sendsSearchStringImmediately = true
        search.target = self
        search.action = #selector(searched)
        let column = NSTableColumn(identifier: .init("zone"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 34
        table.style = .plain
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let stack = Design.vstack([search, scroll], spacing: 8)
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        NSLayoutConstraint.activate([
            stack.widthAnchor.constraint(equalToConstant: 380),
            scroll.heightAnchor.constraint(equalToConstant: 320),
            search.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20)
        ])
        view = stack
        table.selectRowIndexes([0], byExtendingSelection: false)
    }

    @objc private func searched() {
        let query = search.stringValue
        shown = (query.isEmpty ? thisMac.map { [$0] } ?? [] : []) + ClockZones.filter(all, query)
        table.reloadData()
        if !shown.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
        table.scrollRowToVisible(0)
    }

    @objc private func clicked() { pick(table.clickedRow) }

    private func pick(_ row: Int) {
        guard shown.indices.contains(row) else { return }
        popover?.close()
        onPick(shown[row].id)
    }

    /// ↑ ↓ move through the list while typing; Return picks; Escape closes.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)), #selector(NSResponder.moveDown(_:)):
            guard !shown.isEmpty else { return true }
            let step = selector == #selector(NSResponder.moveUp(_:)) ? -1 : 1
            let row = min(max(table.selectedRow + step, 0), shown.count - 1)
            table.selectRowIndexes([row], byExtendingSelection: false)
            table.scrollRowToVisible(row)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            pick(table.selectedRow)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            popover?.close()
            return true
        default:
            return false
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let choice = shown[row]
        let city = Design.label(choice.city, size: 13, weight: .medium)
        let name = Design.label(choice.name, size: 11, color: .secondaryLabelColor)
        for label in [city, name] { label.lineBreakMode = .byTruncatingTail }
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let offset = Design.label(choice.offset, size: 12, color: .secondaryLabelColor)
        offset.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        offset.setContentCompressionResistancePriority(.required, for: .horizontal)
        let row = Design.hstack([Design.vstack([city, name], spacing: 1), Design.spacer(), offset])
        row.alignment = .centerY
        row.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 6)
        return row
    }
}
