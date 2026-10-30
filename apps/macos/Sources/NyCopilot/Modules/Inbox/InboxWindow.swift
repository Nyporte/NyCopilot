import AppKit

/// The inbox as a window, for working through notes: the list on the left, grouped by day, and
/// the selected note on the right — its text (edited in place), its screenshot, where it came from.
/// Inbox and Done switch at the top, with a search. Keys on the list: Space done (or back), ↩ edit,
/// ⌘C copy, ⌘O open the source, ⌫ delete, ⌘Z undo, ⌘F search.
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
    }
    typealias Item = CoreRecord<Note>
    private enum Row { case day(String), note(Item) }

    private let core: NyCore
    private let imageFolder: URL
    private let tabs = NSSegmentedControl(labels: ["Inbox", "Done"], trackingMode: .selectOne, target: nil, action: nil)
    private let search = NSSearchField()
    private let table = InboxTable()
    private let empty = EmptyStateView()
    private var rows: [Row] = []
    private var showsDone: Bool { tabs.selectedSegment == 1 }

    // The selected note.
    private let detail = NSStackView()
    private let preview = NSImageView()
    private let editor = NSTextView()
    private let editorScroll = NSScrollView()
    private let sourceLabel = Design.label("", size: 12, color: .secondaryLabelColor)
    private let timeLabel = Design.label("", size: 12, color: .secondaryLabelColor)
    private let doneButton = Design.button("Done", target: nil, action: nil)
    private let copyButton = Design.button("Copy", target: nil, action: nil)
    private let openButton = Design.button("Open Source", target: nil, action: nil)
    private let deleteButton = Design.button("Delete", target: nil, action: nil)
    private let nothingSelected = Design.label("Select a note", size: 13, color: .tertiaryLabelColor)
    private var shownID: String?
    private var pendingSave: DispatchWorkItem?

    /// Undo for the last few done, back, and delete actions; a deleted note's screenshot is kept
    /// until its undo can no longer happen.
    private var undoStack: [(String, () -> String?)] = []
    private var keptImages: [String] = []
    private var observer: NSObjectProtocol?
    private let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    init(core: NyCore, imageFolder: URL) {
        self.core = core
        self.imageFolder = imageFolder
        let window = InboxWindowPanel(contentRect: NSRect(x: 0, y: 0, width: 860, height: 560),
                                      styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: true)
        window.title = "Inbox"
        window.minSize = NSSize(width: 620, height: 380)
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.setFrameAutosaveName("NyCopilotInbox")
        super.init(window: window)
        window.delegate = self
        window.contentView = makeContent()
        if !window.setFrameUsingName("NyCopilotInbox") { window.center() }
        observer = NotificationCenter.default.addObserver(forName: NyCore.eventNotification, object: nil, queue: .main) { [weak self] note in
            guard let event = note.userInfo?["event"] as? [String: Any], event["type"] as? String == "records.changed",
                  let collection = event["collection"] as? String, collection.hasPrefix("inbox.") else { return }
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    required init?(coder: NSCoder) { fatalError("Use init(core:imageFolder:)") }

    func present() {
        reload()
        NSApp.activate(ignoringOtherApps: true)
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
        for name in keptImages { try? FileManager.default.removeItem(at: imageFolder.appendingPathComponent(name)) }
        keptImages.removeAll()
    }

    // MARK: Layout

    private func makeContent() -> NSView {
        let root = NSView()
        tabs.target = self
        tabs.action = #selector(switchTab)
        tabs.selectedSegment = 0
        search.placeholderString = "Search notes"
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
                                 (openButton, #selector(openSelectedSource)), (deleteButton, #selector(deleteSelected))] {
            button.target = self
            button.action = action
        }
        let actions = Design.hstack([doneButton, copyButton, openButton, Design.spacer(), deleteButton], spacing: 8)
        let hint = Design.label("Space done   ↩ edit   ⌘C copy   ⌘O open source   ⌫ delete   ⌘Z undo", size: 11, color: .tertiaryLabelColor)
        for view in [preview, editorScroll, sourceLabel, timeLabel, actions, hint] as [NSView] { detail.addArrangedSubview(view) }
        detail.orientation = .vertical
        detail.alignment = .leading
        detail.spacing = 10
        detail.setCustomSpacing(16, after: timeLabel)
        detail.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 14, right: 18)
        for view in [editorScroll, actions] as [NSView] { view.widthAnchor.constraint(equalTo: detail.widthAnchor, constant: -36).isActive = true }
        // A long address is cut in the middle (the whole of it shows on hover), never past the pane.
        for label in [sourceLabel, timeLabel] {
            label.widthAnchor.constraint(lessThanOrEqualTo: detail.widthAnchor, constant: -36).isActive = true
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
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

    private func reload() {
        let selectedID = selectedItem?.id
        var params: [String: Any] = ["collection": showsDone ? CoreCollection.inboxDone.rawValue : CoreCollection.inboxNotes.rawValue, "limit": 500]
        let query = search.stringValue.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty { params["search"] = query }
        let items = (try? core.call("records.list", params, as: CorePage<Note>.self).records) ?? []
        rows = []
        var lastDay: String?
        for item in items {
            let day = Self.day(of: Date(timeIntervalSince1970: Double(item.createdAt) / 1000))
            if day != lastDay { rows.append(.day(day)); lastDay = day }
            rows.append(.note(item))
        }
        let waiting = (try? core.call("inbox.count") as? [String: Any])?["count"] as? Int ?? 0
        tabs.setLabel(waiting > 0 ? "Inbox (\(waiting))" : "Inbox", forSegment: 0)
        table.reloadData()
        if let selectedID, let row = rows.firstIndex(where: { if case .note(let item) = $0 { item.id == selectedID } else { false } }) {
            table.selectRowIndexes([row], byExtendingSelection: false)
        }
        empty.show(symbol: showsDone ? "checkmark.circle" : "tray",
                   title: !query.isEmpty ? "No matches" : showsDone ? "Nothing done yet" : "All clear",
                   message: !query.isEmpty ? "Nothing here mentions “\(query)”."
                        : showsDone ? "Notes you mark done stay here for 30 days, in case you need one back."
                                    : "Press F3 to jot something down, or select text and press F3 to keep it.")
        empty.isHidden = !items.isEmpty
        showSelected()
    }

    private static func day(of date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate(calendar.isDate(date, equalTo: Date(), toGranularity: .year) ? "EEEMMMd" : "yMMMd")
        return formatter.string(from: date)
    }

    @objc private func switchTab() {
        saveNow()
        table.deselectAll(nil)
        reload()
        selectFirstNote()
    }

    @objc private func searchChanged() { reload() }

    private func selectFirstNote() {
        guard let row = rows.firstIndex(where: { if case .note = $0 { true } else { false } }) else { showSelected(); return }
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    // MARK: The selected note

    private var selectedItem: Item? {
        guard rows.indices.contains(table.selectedRow), case .note(let item) = rows[table.selectedRow] else { return nil }
        return item
    }

    private func showSelected() {
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
        if let name = item.data.image, let image = NSImage(contentsOf: imageFolder.appendingPathComponent(name)) {
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
        var when = "Added \(Self.day(of: created).lowercasedIfRelative) at \(clock.string(from: created))"
        if let doneAt = item.data.doneAt {
            let done = Date(timeIntervalSince1970: Double(doneAt) / 1000)
            when += " · done \(Self.day(of: done).lowercasedIfRelative) at \(clock.string(from: done))"
        }
        timeLabel.stringValue = when
        doneButton.title = showsDone ? "Not Done" : "Done"
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
    private func saveNow() {
        pendingSave?.cancel()
        pendingSave = nil
        guard let id = shownID, let item = rows.lazy.compactMap({ if case .note(let item) = $0, item.id == id { item } else { nil } }).first,
              editor.string != item.data.text else { return }
        _ = try? core.call("inbox.update", ["id": id, "text": editor.string])
    }

    @objc private func editSelected() {
        guard selectedItem != nil else { return }
        window?.makeFirstResponder(editor)
    }

    // MARK: Actions

    private func handleKey(_ key: InboxTable.Key) -> Bool {
        switch key {
        case .space: toggleDoneSelected()
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

    @objc private func toggleDoneSelected() {
        guard let item = selectedItem else { return }
        saveNow()
        let row = table.selectedRow
        let (command, back) = showsDone ? ("inbox.undone", "inbox.done") : ("inbox.done", "inbox.undone")
        guard let moved = (try? core.call(command, ["id": item.id]) as? [String: Any])?["record"] as? [String: Any],
              let movedID = moved["id"] as? String else { return }
        remember(showsDone ? "Not done" : "Done") { [core] in
            (try? core.call(back, ["id": movedID]) as? [String: Any]).flatMap { ($0["record"] as? [String: Any])?["id"] as? String }
        }
        reload()
        selectNear(row)
    }

    @objc private func deleteSelected() {
        guard let item = selectedItem else { return }
        let row = table.selectedRow
        _ = try? core.call("records.delete", ["id": item.id])
        if let image = item.data.image { keptImages.append(image) }
        let note = item.data, done = showsDone
        remember("Delete") { [core] in
            var params: [String: Any] = ["text": note.text, "app": note.app ?? "", "title": note.title ?? "", "url": note.url ?? "",
                                         "source": note.source ?? "typed"]
            if let image = note.image { params["image"] = image }
            guard let id = ((try? core.call("inbox.add", params) as? [String: Any])?["record"] as? [String: Any])?["id"] as? String else { return nil }
            return done ? ((try? core.call("inbox.done", ["id": id]) as? [String: Any])?["record"] as? [String: Any])?["id"] as? String : id
        }
        reload()
        selectNear(row)
    }

    @objc private func copySelected() {
        guard let item = selectedItem else { return }
        NSPasteboard.general.clearContents()
        if let image = item.data.image.flatMap({ NSImage(contentsOf: imageFolder.appendingPathComponent($0)) }) {
            NSPasteboard.general.writeObjects([image])
        }
        if !item.data.text.isEmpty { NSPasteboard.general.setString(item.data.text, forType: .string) }
    }

    /// The page or document it came from; else the app, if it's running.
    @objc private func openSelectedSource() {
        guard let item = selectedItem else { return }
        if let address = item.data.url, SourceContext.isMeaningful(address: address), let url = URL(string: address) {
            NSWorkspace.shared.open(url)
        } else if let app = runningApp(named: item.data.app) {
            app.activate(options: [])
        } else {
            NSSound.beep()
        }
    }

    private func runningApp(named name: String?) -> NSRunningApplication? {
        guard let name, !name.isEmpty else { return nil }
        return NSWorkspace.shared.runningApplications.first { $0.localizedName == name }
    }

    // MARK: Undo

    private func remember(_ name: String, undo: @escaping () -> String?) {
        undoStack.append((name, undo))
        if undoStack.count > 20 { undoStack.removeFirst() }
    }

    private func undo() {
        guard let (_, action) = undoStack.popLast() else { NSSound.beep(); return }
        let restored = action()
        reload()
        if let restored, let row = rows.firstIndex(where: { if case .note(let item) = $0 { item.id == restored } else { false } }) {
            table.selectRowIndexes([row], byExtendingSelection: false)
            table.scrollRowToVisible(row)
        }
    }

    /// After a note leaves the list, the one that took its place (or the one above).
    private func selectNear(_ row: Int) {
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
            cell.title.stringValue = firstLine.flatMap { $0.isEmpty ? nil : $0 } ?? (item.data.image == nil ? "Empty note" : "Screenshot")
            cell.icon.image = NSImage(systemSymbolName: item.data.image != nil ? "photo" : item.data.source == "selection" ? "text.quote" : "pencil",
                                      accessibilityDescription: nil)
            let time = clock.string(from: Date(timeIntervalSince1970: Double(item.data.created ?? item.createdAt) / 1000))
            cell.metadata.stringValue = [item.data.app.flatMap { $0.isEmpty ? nil : $0 }, time].compactMap { $0 }.joined(separator: " · ")
            return cell
        }
    }
}

private extension String {
    /// "Today" reads as "today" mid-sentence; a date stays as it is.
    var lowercasedIfRelative: String { self == "Today" || self == "Yesterday" ? lowercased() : "on \(self)" }
}

/// The list: its keys go to the window's actions first.
private final class InboxTable: NSTableView {
    enum Key: Equatable { case space, returnKey, delete, command(String) }
    var onKey: ((Key) -> Bool)?

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key: Key? = switch (event.keyCode, flags) {
        case (49, []): .space
        case (36, []), (76, []): .returnKey
        case (51, []), (117, []), (51, [.command]): .delete
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

private final class InboxRow: NSTableCellView {
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
private final class InboxWindowPanel: NSWindow {
    override func cancelOperation(_ sender: Any?) { performClose(sender) }
}
