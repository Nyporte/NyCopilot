import AppKit

/// The inbox as a window, for working through notes: the list on the left, grouped by day, and
/// the selected note on the right — its text (edited in place), its screenshot, where it came from.
/// Inbox, Later (snoozed), and Done switch at the top, with a search. Keys on the list: Space done
/// (or back), S send to Reminders, Notes, or Markdown, L snooze, R translate, A ask AI, P pin,
/// ↩ edit, ⌘C copy, ⌘O open the source, ⌫ delete, ⌘Z undo, ⌘F search.
@MainActor
final class InboxWindow: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSTextViewDelegate {
    struct Note: Decodable {
        let text: String
        let image: String?
        let app: String?
        let title: String?
        let url: String?
        let source: String?
        let created: Int64?
        let doneAt: Int64?
        let until: Int64?
    }
    typealias Item = CoreRecord<Note>
    enum Row { case day(String), note(Item) }
    enum Tab: Int { case inbox, later, done }

    let core: NyCore
    let images: ImageFolder
    let toast: Toast
    /// R, A, P on a note: translate it, ask about it, pin it to the screen.
    var onVerb: ((Verb, String, NSImage?) -> Void)?
    let tabs = NSSegmentedControl(labels: [L("Inbox"), L("Later"), L("Done")], trackingMode: .selectOne, target: nil, action: nil)
    let search = NSSearchField()
    let table = InboxTable()
    let empty = EmptyStateView()
    var rows: [Row] = []
    private let searching = RecordSearch()
    var tab: Tab { Tab(rawValue: tabs.selectedSegment) ?? .inbox }
    var showsDone: Bool { tab == .done }
    var collection: CoreCollection {
        switch tab {
        case .inbox: .inboxNotes
        case .later: .inboxSnoozed
        case .done: .inboxDone
        }
    }

    // The selected note.
    let detail = NSStackView()
    let preview = NSImageView()
    let editor = NSTextView()
    let editorScroll = NSScrollView()
    let sourceLabel = Design.label("", size: 12, color: .secondaryLabelColor)
    let timeLabel = Design.label("", size: 12, color: .secondaryLabelColor)
    let doneButton = Design.button(L("Done"), target: nil, action: nil)
    let sendButton = Design.button(L("Send To"), target: nil, action: nil)
    let laterButton = Design.button(L("Later"), target: nil, action: nil)
    let copyButton = Design.button(L("Copy"), target: nil, action: nil)
    let openButton = Design.button(L("Open Source"), target: nil, action: nil)
    let deleteButton = Design.button(L("Delete"), target: nil, action: nil)
    let nothingSelected = Design.label(L("Select a note"), size: 13, color: .tertiaryLabelColor)
    var shownID: String?
    var pendingSave: DispatchWorkItem?

    /// Undo for the last few done, back, and delete actions; a deleted note's screenshot is kept
    /// until its undo can no longer happen.
    var undoStack: [(String, () -> String?)] = []
    var keptImages: [String] = []
    var changes: CoreObservation?
    let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    init(core: NyCore, images: ImageFolder, toast: Toast) {
        self.core = core
        self.images = images
        self.toast = toast
        let window = ClosableWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 560),
                                    styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: true)
        window.title = L("Inbox")
        window.minSize = NSSize(width: 620, height: 380)
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.setFrameAutosaveName("NyCopilotInbox")
        super.init(window: window)
        window.delegate = self
        window.contentView = makeContent()
        window.contentView?.labelIconButtons()
        // A size saved while a screenshot stretched the window is put back to the default.
        let restored = window.setFrameUsingName("NyCopilotInbox")
        if !restored || window.frame.width > (window.screen ?? NSScreen.main).map({ $0.visibleFrame.width * 0.8 }) ?? 1200 {
            window.setContentSize(NSSize(width: 860, height: 560))
            window.center()
        }
        changes = core.observe { [weak self] event in
            guard event.changedCollection?.hasPrefix("inbox.") == true else { return }
            // Hidden, it reloads when it's shown again (`present`).
            if self?.window?.isVisible == true { self?.reload() }
        }
    }

    required init?(coder: NSCoder) { fatalError("Use init(core:images:toast:)") }

    func present() {
        reload()
        NSApp.bringForward()
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(table)
        if table.selectedRow < 0 { selectFirstNote() }
    }

    func windowWillClose(_ notification: Notification) {
        saveNow()
        forgetUndo()
    }

    /// Screenshots of deleted notes go once their undo is gone.
    func forgetUndo() {
        undoStack.removeAll()
        for name in keptImages { try? FileManager.default.removeItem(at: images.file(name)) }
        keptImages.removeAll()
    }

    // MARK: Layout

    func makeContent() -> NSView {
        let root = NSView()
        tabs.target = self
        tabs.action = #selector(switchTab)
        tabs.selectedSegment = 0
        search.placeholderString = L("Search notes")
        search.target = self
        search.action = #selector(searchChanged)
        search.sendsSearchStringImmediately = true
        let bar = Design.hstack([tabs, Design.spacer(), search], spacing: 12)
        search.widthAnchor.constraint(equalToConstant: 220).isActive = true

        table.addTableColumn(NSTableColumn(identifier: .init("note")))
        table.headerView = nil
        table.style = .sourceList
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(editSelected)
        table.onKey = { [weak self] key in self?.handleKey(key) ?? false }
        let list = NSScrollView()
        list.documentView = table
        list.hasVerticalScroller = true
        list.drawsBackground = false

        preview.imageScaling = .scaleProportionallyDown
        preview.imageAlignment = .alignTopLeft
        preview.heightAnchor.constraint(lessThanOrEqualToConstant: 260).isActive = true
        editor.font = .systemFont(ofSize: 15)
        editor.isRichText = false
        editor.allowsUndo = true
        editor.drawsBackground = false
        editor.textContainerInset = NSSize(width: 0, height: 4)
        editor.delegate = self
        editorScroll.documentView = editor
        editorScroll.hasVerticalScroller = true
        editorScroll.drawsBackground = false
        editor.autoresizingMask = [.width]
        editor.isVerticallyResizable = true
        editor.textContainer?.widthTracksTextView = true
        // Flush with the labels below it.
        editor.textContainer?.lineFragmentPadding = 0
        sourceLabel.lineBreakMode = .byTruncatingMiddle
        for (button, action) in [(doneButton, #selector(toggleDoneSelected)), (copyButton, #selector(copySelected)),
                                 (sendButton, #selector(showSendMenu)), (laterButton, #selector(showLaterMenu)),
                                 (openButton, #selector(openSelectedSource)), (deleteButton, #selector(deleteSelected))] {
            button.target = self
            button.action = action
        }
        sendButton.image = NSImage(systemSymbolName: "paperplane", accessibilityDescription: nil)
        laterButton.image = NSImage(systemSymbolName: "clock", accessibilityDescription: nil)
        for button in [sendButton, laterButton] { button.imagePosition = .imageLeading }
        // The rarer actions are icons, so the row fits a narrow pane.
        for (button, symbol, tip) in [(copyButton, "doc.on.doc", L("Copy (⌘C)")), (openButton, "arrow.up.forward.app", L("Open Source (⌘O)")),
                                      (deleteButton, "trash", L("Delete (⌫)"))] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
            button.imagePosition = .imageOnly
            button.toolTip = tip
        }
        let actions = Design.hstack([doneButton, sendButton, laterButton, copyButton, openButton, Design.spacer(), deleteButton], spacing: 8)
        let hint = Design.label(L("Space done   S send   L later   R translate   A ask   P pin   ? all keys"), size: 11, color: .tertiaryLabelColor)
        hint.lineBreakMode = .byTruncatingTail
        for view in [preview, editorScroll, sourceLabel, timeLabel, actions, hint] as [NSView] { detail.addArrangedSubview(view) }
        detail.orientation = .vertical
        detail.alignment = .leading
        detail.spacing = 10
        detail.setCustomSpacing(16, after: timeLabel)
        detail.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 14, right: 18)
        for view in [editorScroll, actions] as [NSView] { view.widthAnchor.constraint(equalTo: detail.widthAnchor, constant: -36).isActive = true }
        // A long address is cut in the middle (the whole of it shows on hover), never past the pane.
        // A screenshot is shown at most as wide as the pane: left to its natural size, a wide one
        // would push the window wider than the screen.
        for view in [sourceLabel, timeLabel, hint, preview] as [NSView] {
            view.widthAnchor.constraint(lessThanOrEqualTo: detail.widthAnchor, constant: -36).isActive = true
            view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        preview.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        // Below the fitting priority too, so even the window's natural size ignores a big picture.
        preview.setContentHuggingPriority(.init(1), for: .horizontal)
        preview.setContentHuggingPriority(.init(1), for: .vertical)
        preview.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        editorScroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        editorScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 80).isActive = true

        for view in [bar, list, detail, empty, nothingSelected] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(divider)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            list.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 10),
            list.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            list.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            list.widthAnchor.constraint(equalTo: root.widthAnchor, multiplier: 0.42),
            divider.topAnchor.constraint(equalTo: list.topAnchor),
            divider.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: list.trailingAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            detail.topAnchor.constraint(equalTo: list.topAnchor),
            detail.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            detail.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            detail.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            empty.centerXAnchor.constraint(equalTo: list.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: list.centerYAnchor),
            empty.widthAnchor.constraint(lessThanOrEqualTo: list.widthAnchor, constant: -40),
            nothingSelected.centerXAnchor.constraint(equalTo: detail.centerXAnchor),
            nothingSelected.centerYAnchor.constraint(equalTo: detail.centerYAnchor)
        ])
        return root
    }

    // MARK: Loading

    func reload() {
        let query = search.stringValue.trimmingCharacters(in: .whitespaces)
        show((try? core.records(collection, as: Note.self, search: query, limit: 500).records) ?? [], query: query)
    }

    /// As you type in the search field, notes are found off the main thread; the newest search wins.
    private func searchInBackground() {
        let query = search.stringValue.trimmingCharacters(in: .whitespaces), collection = collection
        searching.run({ [core] in
            (try? await core.searchRecords(collection, as: Note.self, search: query, limit: 500))?.records ?? []
        }, show: { [weak self] items in
            guard let self, collection == self.collection else { return }
            show(items, query: query)
        })
    }

    private func show(_ items: [Item], query: String) {
        let selectedID = selectedItem?.id
        rows = []
        var lastDay: String?
        // Snoozed notes are listed by when they come back, soonest first.
        let ordered = tab == .later ? items.sorted { ($0.data.until ?? 0) < ($1.data.until ?? 0) } : items
        for item in ordered {
            let day = Self.day(of: Date(timeIntervalSince1970: Double(tab == .later ? item.data.until ?? item.createdAt : item.createdAt) / 1000))
            if day != lastDay { rows.append(.day(day)); lastDay = day }
            rows.append(.note(item))
        }
        let waiting = core.inboxCount()
        tabs.setLabel(waiting > 0 ? L("Inbox (%ld)", waiting) : L("Inbox"), forSegment: 0)
        table.reloadData()
        if let selectedID, let row = rows.firstIndex(where: { if case .note(let item) = $0 { item.id == selectedID } else { false } }) {
            table.selectRowIndexes([row], byExtendingSelection: false)
        }
        let (symbol, title, message): (String, String, String) = switch tab {
        case .inbox: ("tray", L("All clear"), L("Press F3 to jot something down, or select text and press F3 to keep it."))
        case .later: ("clock", L("Nothing snoozed"), L("Press L on a note to put it away until later; it comes back to the top of the inbox."))
        case .done: ("checkmark.circle", L("Nothing done yet"), L("Notes you mark done stay here for 30 days, in case you need one back."))
        }
        empty.show(symbol: query.isEmpty ? symbol : "magnifyingglass", title: query.isEmpty ? title : L("No matches"),
                   message: query.isEmpty ? message : L("Nothing here mentions “%@”.", query))
        empty.isHidden = !items.isEmpty
        showSelected()
    }

    /// A list heading: "Today", "Yesterday", or the date, in the interface language.
    static func day(of date: Date) -> String { describe(date, time: false, context: .standalone) }

    /// A day and time inside a sentence: "today at 9:41 AM", "Thu, Oct 29, 9:41 AM".
    static func moment(_ date: Date) -> String { describe(date, time: true, context: .middleOfSentence) }

    private static func describe(_ date: Date, time: Bool, context: Formatter.Context) -> String {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.formattingContext = context
        if calendar.isDateInToday(date) || calendar.isDateInYesterday(date) || calendar.isDateInTomorrow(date) {
            formatter.dateStyle = .medium
            formatter.timeStyle = time ? .short : .none
            formatter.doesRelativeDateFormatting = true
        } else {
            let day = calendar.isDate(date, equalTo: Date(), toGranularity: .year) ? "EEEMMMd" : "yMMMd"
            formatter.setLocalizedDateFormatFromTemplate(day + (time ? "jmm" : ""))
        }
        return formatter.string(from: date)
    }

    @objc func switchTab() {
        saveNow()
        table.deselectAll(nil)
        reload()
        selectFirstNote()
    }

    @objc func searchChanged() { searchInBackground() }

    func selectFirstNote() {
        guard let row = rows.firstIndex(where: { if case .note = $0 { true } else { false } }) else { showSelected(); return }
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    // MARK: The selected note

    var selectedItem: Item? {
        guard rows.indices.contains(table.selectedRow), case .note(let item) = rows[table.selectedRow] else { return nil }
        return item
    }

    func showSelected() {
        guard let item = selectedItem else {
            detail.isHidden = true
            nothingSelected.isHidden = rows.isEmpty
            shownID = nil
            return
        }
        detail.isHidden = false
        nothingSelected.isHidden = true
        if shownID != item.id {
            saveNow()
            shownID = item.id
            editor.string = item.data.text
            editor.undoManager?.removeAllActions()
        }
        if let name = item.data.image, let image = images.image(name) {
            preview.image = image
            preview.isHidden = false
        } else {
            preview.image = nil
            preview.isHidden = true
        }
        let app = item.data.app ?? "", title = item.data.title ?? ""
        let place = [app, title == app ? "" : title].filter { !$0.isEmpty }.joined(separator: " — ")
        let address = item.data.url.flatMap { SourceContext.isMeaningful(address: $0) ? $0 : nil }
        sourceLabel.stringValue = [place.isEmpty ? nil : place, address].compactMap { $0 }.joined(separator: "  ·  ")
        sourceLabel.toolTip = sourceLabel.stringValue
        sourceLabel.isHidden = sourceLabel.stringValue.isEmpty
        let created = Date(timeIntervalSince1970: Double(item.data.created ?? item.createdAt) / 1000)
        var when = L("Added %@", Self.moment(created))
        if let until = item.data.until {
            let back = Date(timeIntervalSince1970: Double(until) / 1000)
            when += L(" · back %@", Self.moment(back))
        }
        if let doneAt = item.data.doneAt {
            let done = Date(timeIntervalSince1970: Double(doneAt) / 1000)
            when += L(" · done %@", Self.moment(done))
        }
        timeLabel.stringValue = when
        doneButton.title = switch tab { case .inbox: L("Done"); case .later: L("Back Now"); case .done: L("Not Done") }
        sendButton.isHidden = tab != .inbox
        laterButton.isHidden = tab != .inbox
        openButton.isEnabled = address != nil || runningApp(named: item.data.app) != nil
    }

    func tableViewSelectionDidChange(_ notification: Notification) { showSelected() }

    // MARK: Editing in place

    func textDidChange(_ notification: Notification) {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    /// The edited text, saved (an image note may have no text; a text note keeps at least some).
    func saveNow() {
        pendingSave?.cancel()
        pendingSave = nil
        guard let id = shownID, let item = rows.lazy.compactMap({ if case .note(let item) = $0, item.id == id { item } else { nil } }).first,
              editor.string != item.data.text else { return }
        try? core.inboxUpdate(id, text: editor.string)
    }

    @objc func editSelected() {
        guard selectedItem != nil else { return }
        window?.makeFirstResponder(editor)
    }

    // MARK: Actions

    func handleKey(_ key: InboxTable.Key) -> Bool {
        switch key {
        case .space: toggleDoneSelected()
        case .character("s") where tab == .inbox: showSendMenu()
        case .character("?"): KeySheet.shared.toggle(L("Inbox keys"), groups: KeyGuide.inbox, over: window)
        case .character("r"): verb(.translate)
        case .character("a"): verb(.ask)
        case .character("p"): verb(.pin)
        case .character("l") where tab == .inbox: showLaterMenu()
        case .returnKey: editSelected()
        case .delete: deleteSelected()
        case .command("c"): copySelected()
        case .command("o"): openSelectedSource()
        case .command("z"): undo()
        case .command("f"): window?.makeFirstResponder(search)
        default: return false
        }
        return true
    }

    /// Inbox: done. Later: back to the inbox now. Done: back to the inbox.
    @objc func toggleDoneSelected() {
        guard let item = selectedItem else { return }
        saveNow()
        let row = table.selectedRow
        let (command, back): (CoreMethod, CoreMethod?) = switch tab {
        case .inbox: (.inboxDone, .inboxUndone)
        case .later: (.inboxWake, nil)
        case .done: (.inboxUndone, .inboxDone)
        }
        let moved = command == .inboxWake ? (try? core.inboxWake(item.id))?.first?.id : (try? core.inboxMove(command, item.id)) ?? nil
        guard let movedID = moved else { return }
        let until = item.data.until
        remember(command.rawValue) { [core] in
            if let back { return try? core.inboxMove(back, movedID) ?? nil }
            return try? core.inboxSnooze(movedID, until: until ?? 0) ?? nil
        }
        reload()
        selectNear(row)
    }

    /// Marks a waiting note done that may no longer be selected, with the same undo as ⌘D.
    func markDone(_ item: Item) {
        guard let movedID = try? core.inboxMove(.inboxDone, item.id) ?? nil else { return }
        remember(CoreMethod.inboxDone.rawValue) { [core] in try? core.inboxMove(.inboxUndone, movedID) ?? nil }
        reload()
    }

    func verb(_ verb: Verb) {
        guard let item = selectedItem else { return }
        saveNow()
        onVerb?(verb, editor.string, item.data.image.flatMap(images.image))
    }

    // MARK: Undo

    func remember(_ name: String, undo: @escaping () -> String?) {
        undoStack.append((name, undo))
        if undoStack.count > 20 { undoStack.removeFirst() }
    }

    func undo() {
        guard let (_, action) = undoStack.popLast() else { NSSound.beep(); return }
        let restored = action()
        reload()
        if let restored, let row = rows.firstIndex(where: { if case .note(let item) = $0 { item.id == restored } else { false } }) {
            table.selectRowIndexes([row], byExtendingSelection: false)
            table.scrollRowToVisible(row)
        }
    }

    /// After a note leaves the list, the one that took its place (or the one above).
    func selectNear(_ row: Int) {
        let candidates = rows.indices.filter { if case .note = rows[$0] { true } else { false } }
        guard let next = candidates.first(where: { $0 >= row }) ?? candidates.last else { showSelected(); return }
        table.selectRowIndexes([next], byExtendingSelection: false)
        table.scrollRowToVisible(next)
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .day = rows[row] { true } else { false }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .note = rows[row] { true } else { false }
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .day = rows[row] { 24 } else { 46 }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .day(let day):
            let label = Design.label(day, size: 11, weight: .semibold, color: .secondaryLabelColor)
            let cell = NSTableCellView()
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                                         label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
            return cell
        case .note(let item):
            let cell = tableView.makeView(withIdentifier: .init("note"), owner: nil) as? InboxRow ?? InboxRow()
            cell.identifier = .init("note")
            let firstLine = item.data.text.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces)
            let picture = item.data.image?.hasSuffix(".gif") == true ? L("Recording") : L("Screenshot")
            cell.title.stringValue = firstLine.flatMap { $0.isEmpty ? nil : $0 } ?? (item.data.image == nil ? L("Empty note") : picture)
            cell.icon.image = NSImage(systemSymbolName: item.data.image != nil ? "photo" : item.data.source == "selection" ? "text.quote" : "pencil",
                                      accessibilityDescription: nil)
            let time = clock.string(from: Date(timeIntervalSince1970: Double(item.data.created ?? item.createdAt) / 1000))
            cell.metadata.stringValue = [item.data.app.flatMap { $0.isEmpty ? nil : $0 }, time].compactMap { $0 }.joined(separator: " · ")
            return cell
        }
    }
}
