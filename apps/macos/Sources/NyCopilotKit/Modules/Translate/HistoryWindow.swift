import AppKit

/// Saved translations: a searchable list on the left, the full text on the right.
@MainActor
final class HistoryWindow: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate,
                           NSToolbarDelegate, NSSearchFieldDelegate, NSMenuDelegate {
    private struct Entry: Decodable, Sendable { let text: String; let targetLanguage: String }
    private typealias Item = CoreRecord<Entry>

    private let core: NyCore
    private let table = HistoryTable()
    private let detail = NSTextView()
    private let detailMeta = Design.label("", size: 12, color: .secondaryLabelColor)
    private let copyButton = Design.button(L("Copy"), target: nil, action: nil)
    private let deleteButton = NSButton()
    private let emptyState = EmptyStateView()
    private var detailContainer: NSView!
    private var search = ""
    private var items: [Item] = []
    private var next: String?
    private var changes: CoreObservation?
    private let searching = RecordSearch()
    private let searchItem = NSToolbarItem.Identifier("search")
    private lazy var searchField = NSSearchField()

    init(core: NyCore) {
        self.core = core
        let window = ClosableWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 500),
                                    styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                                    backing: .buffered, defer: true)
        window.title = L("Translation History")
        window.minSize = NSSize(width: 560, height: 360)
        window.isReleasedWhenClosed = false
        window.titlebarSeparatorStyle = .automatic
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.setFrameAutosaveName("NyCopilotHistory")
        super.init(window: window)
        window.delegate = self

        let split = NSSplitViewController()
        let sidebar = NSSplitViewItem(sidebarWithViewController: makeList())
        sidebar.minimumThickness = 240
        sidebar.maximumThickness = 380
        sidebar.canCollapse = false
        split.addSplitViewItem(sidebar)
        let content = NSSplitViewItem(viewController: makeDetail())
        content.minimumThickness = 300
        split.addSplitViewItem(content)
        window.contentViewController = split
        window.setContentSize(NSSize(width: 760, height: 500))

        let toolbar = NSToolbar(identifier: "NyCopilotHistory")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        if !window.setFrameUsingName("NyCopilotHistory") { window.center() }

        changes = core.observe { [weak self] event in
            guard event.changedCollection == CoreCollection.translateHistory.rawValue else { return }
            if self?.window?.isVisible == true { self?.reload() }
        }
    }

    required init?(coder: NSCoder) { fatalError("Use init(core:)") }

    private func makeList() -> NSViewController {
        let column = NSTableColumn(identifier: .init("item"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .sourceList
        table.rowHeight = 58
        table.usesAutomaticRowHeights = false
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(copySelected)
        table.onCopy = { [weak self] in self?.copySelected() }
        table.onDelete = { [weak self] in self?.deleteSelected() }
        table.setAccessibilityLabel(L("Translations, newest first"))
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let controller = NSViewController()
        controller.view = scroll
        return controller
    }

    private func makeDetail() -> NSViewController {
        detail.isEditable = false
        detail.isSelectable = true
        detail.isRichText = false
        detail.drawsBackground = false
        detail.font = .systemFont(ofSize: 15)
        detail.textColor = .labelColor
        detail.textContainerInset = NSSize(width: 0, height: 4)
        detail.textContainer?.lineFragmentPadding = 0
        detail.autoresizingMask = [.width]
        detail.isVerticallyResizable = true
        detail.textContainer?.widthTracksTextView = true
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        detail.defaultParagraphStyle = paragraph
        detail.setAccessibilityLabel(L("Full translation"))
        let textScroll = NSScrollView()
        textScroll.documentView = detail
        textScroll.hasVerticalScroller = true
        textScroll.autohidesScrollers = true
        textScroll.drawsBackground = false

        copyButton.target = self
        copyButton.action = #selector(copySelected)
        copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
        copyButton.imagePosition = .imageLeading
        copyButton.keyEquivalent = "\r"
        deleteButton.image = NSImage(systemSymbolName: "trash", accessibilityDescription: L("Delete"))
        deleteButton.bezelStyle = .rounded
        deleteButton.toolTip = L("Delete this translation (⌫)")
        deleteButton.target = self
        deleteButton.action = #selector(deleteSelected)
        let bar = Design.hstack([detailMeta, Design.spacer(), deleteButton, copyButton])
        let stack = Design.vstack([textScroll, bar], spacing: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(stack)
        emptyState.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(emptyState)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
            textScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            bar.widthAnchor.constraint(equalTo: stack.widthAnchor),
            emptyState.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            emptyState.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            emptyState.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, constant: -48)
        ])
        detailContainer = stack
        let controller = NSViewController()
        controller.view = container
        return controller
    }

    func present() {
        reload()
        NSApp.bringForward()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(table)
    }

    // MARK: Data

    func reload() { load(reset: true) }

    private func load(reset: Bool) {
        if !reset && next == nil { return }
        let before = reset ? nil : next
        show(Result { try core.records(.translateHistory, as: Entry.self, search: search, limit: 100, before: before) }, reset: reset)
    }

    /// A page of translations: a first page replaces the list, a later one extends it; the selected
    /// translation stays selected.
    private func show(_ page: Result<CorePage<Entry>, Error>, reset: Bool) {
        let selectedID = selectedItem?.id
        switch page {
        case .success(let page):
            items = reset ? page.records : items + page.records
            next = page.next
            table.reloadData()
            if !items.isEmpty {
                let row = items.firstIndex(where: { $0.id == selectedID }) ?? (reset ? 0 : table.selectedRow)
                table.selectRowIndexes(IndexSet(integer: max(row, 0)), byExtendingSelection: false)
            }
            emptyState.configure(searching: !search.isEmpty, query: search)
        case .failure(let error):
            items = []
            table.reloadData()
            emptyState.configure(error: error.localizedDescription)
        }
        updateDetail()
    }

    private var selectedItem: Item? { items.indices.contains(table.selectedRow) ? items[table.selectedRow] : nil }

    private func updateDetail() {
        let item = selectedItem
        detailContainer.isHidden = item == nil
        emptyState.isHidden = item != nil
        guard let item else { return }
        detail.string = item.data.text
        detail.scrollToBeginningOfDocument(nil)
        detailMeta.stringValue = "\(L(item.data.targetLanguage)) · \(Self.longDate.string(from: date(item)))"
        copyButton.title = L("Copy")
    }

    private func date(_ item: Item) -> Date { Date(timeIntervalSince1970: Double(item.createdAt) / 1000) }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("historyRow")
        let cell = table.makeView(withIdentifier: identifier, owner: self) as? HistoryRow ?? HistoryRow()
        cell.identifier = identifier
        let item = items[row]
        cell.preview.stringValue = item.data.text.replacingOccurrences(of: "\n", with: " ")
        cell.metadata.stringValue = "\(Self.shortDate(date(item))) · \(L(item.data.targetLanguage))"
        // Page in older entries as the user scrolls near the end.
        if row >= items.count - 10 { DispatchQueue.main.async { [weak self] in self?.load(reset: false) } }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateDetail() }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard table.clickedRow >= 0 else { return }
        table.selectRowIndexes(IndexSet(integer: table.clickedRow), byExtendingSelection: false)
        menu.addItem(withTitle: L("Copy"), action: #selector(copySelected), keyEquivalent: "").target = self
        menu.addItem(withTitle: L("Delete"), action: #selector(deleteSelected), keyEquivalent: "").target = self
    }

    // MARK: Actions

    @objc private func copySelected() {
        guard let item = selectedItem else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.data.text, forType: .string)
        copyButton.title = L("Copied")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in self?.copyButton.title = L("Copy") }
    }

    @objc private func deleteSelected() {
        guard let item = selectedItem else { return }
        let row = table.selectedRow
        _ = try? core.deleteRecord(item.id)
        items.removeAll { $0.id == item.id }
        table.reloadData()
        if !items.isEmpty { table.selectRowIndexes(IndexSet(integer: min(row, items.count - 1)), byExtendingSelection: false) }
        emptyState.configure(searching: !search.isEmpty, query: search)
        updateDetail()
    }

    /// Searches as you type, off the main thread.
    func controlTextDidChange(_ obj: Notification) {
        search = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let query = search
        searching.run({ [core] () async -> Result<CorePage<Entry>, Error> in
            do { return .success(try await core.searchRecords(.translateHistory, as: Entry.self, search: query, limit: 100)) }
            catch { return .failure(error) }
        }, show: { [weak self] page in self?.show(page, reset: true) })
    }

    // MARK: Toolbar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.flexibleSpace, searchItem] }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.flexibleSpace, searchItem] }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard identifier == searchItem else { return nil }
        let item = NSSearchToolbarItem(itemIdentifier: identifier)
        item.searchField.placeholderString = L("Search translations")
        item.searchField.delegate = self
        searchField = item.searchField
        return item
    }

    @objc func performFindPanelAction(_ sender: Any?) { window?.makeFirstResponder(searchField) }

    func windowWillClose(_ notification: Notification) {
        searching.cancel()
        searchField.stringValue = ""
        search = ""
    }

    private static let longDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    private static func shortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.doesRelativeDateFormatting = true
        if Calendar.current.isDateInToday(date) || Calendar.current.isDateInYesterday(date) {
            formatter.dateStyle = .short
            formatter.timeStyle = .short
        } else {
            formatter.setLocalizedDateFormatFromTemplate("MMMd")
        }
        return formatter.string(from: date)
    }
}

/// ⌘C and ⌫ act on the selected row through the responder chain.
private final class HistoryTable: NSTableView {
    var onCopy: (() -> Void)?
    var onDelete: (() -> Void)?
    @objc func copy(_ sender: Any?) { onCopy?() }
    @objc func delete(_ sender: Any?) { onDelete?() }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117 { onDelete?() } else { super.keyDown(with: event) }
    }
}

private final class HistoryRow: NSTableCellView {
    let preview = Design.label("", size: 13)
    let metadata = Design.label("", size: 11, color: .secondaryLabelColor)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        preview.maximumNumberOfLines = 2
        preview.lineBreakMode = .byTruncatingTail
        preview.cell?.wraps = true
        preview.cell?.truncatesLastVisibleLine = true
        let stack = Design.vstack([preview, metadata], spacing: 3)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            preview.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }
}

/// A centered icon and two lines of guidance for empty lists, empty searches, and errors.
final class EmptyStateView: NSStackView {
    private let icon = Design.symbol("clock.arrow.circlepath", size: 34, weight: .light, color: .tertiaryLabelColor)
    private let title = Design.label("", size: 15, weight: .semibold, color: .secondaryLabelColor)
    private let message = Design.wrapping("", size: 12.5, color: .tertiaryLabelColor)

    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .centerX
        spacing = 6
        message.alignment = .center
        message.preferredMaxLayoutWidth = 280
        addArrangedSubview(icon)
        setCustomSpacing(12, after: icon)
        addArrangedSubview(title)
        addArrangedSubview(message)
    }

    required init?(coder: NSCoder) { fatalError("Use init()") }

    func show(symbol: String, title: String, message: String) {
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        self.title.stringValue = title
        self.message.stringValue = message
    }

    func configure(searching: Bool, query: String) {
        show(symbol: searching ? "magnifyingglass" : "clock.arrow.circlepath", title: searching ? L("No Results") : L("No Translations Yet"),
             message: searching ? L("Nothing matches “%@”.", query) : L("Translations you make in any app will appear here."))
    }

    func configure(error: String) {
        show(symbol: "exclamationmark.triangle", title: L("History Unavailable"), message: error)
    }
}
