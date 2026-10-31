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
    private enum Row { case day(String), note(Item) }
    private enum Tab: Int { case inbox, later, done }

    private let core: NyCore
    private let images: ImageFolder
    private let toast: Toast
    /// R, A, P on a note: translate it, ask about it, pin it to the screen.
    var onVerb: ((Verb, String, NSImage?) -> Void)?
    private let tabs = NSSegmentedControl(labels: ["Inbox", "Later", "Done"], trackingMode: .selectOne, target: nil, action: nil)
    private let search = NSSearchField()
    private let table = InboxTable()
    private let empty = EmptyStateView()
    private var rows: [Row] = []
    private var tab: Tab { Tab(rawValue: tabs.selectedSegment) ?? .inbox }
    private var showsDone: Bool { tab == .done }
    private var collection: CoreCollection {
        switch tab {
        case .inbox: .inboxNotes
        case .later: .inboxSnoozed
        case .done: .inboxDone
        }
    }

    // The selected note.
    private let detail = NSStackView()
    private let preview = NSImageView()
    private let editor = NSTextView()
    private let editorScroll = NSScrollView()
    private let sourceLabel = Design.label("", size: 12, color: .secondaryLabelColor)
    private let timeLabel = Design.label("", size: 12, color: .secondaryLabelColor)
    private let doneButton = Design.button("Done", target: nil, action: nil)
    private let sendButton = Design.button("Send To", target: nil, action: nil)
    private let laterButton = Design.button("Later", target: nil, action: nil)
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

    init(core: NyCore, images: ImageFolder, toast: Toast) {
        self.core = core
        self.images = images
        self.toast = toast
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
        // A size saved while a screenshot stretched the window is put back to the default.
        let restored = window.setFrameUsingName("NyCopilotInbox")
        if !restored || window.frame.width > (window.screen ?? NSScreen.main).map({ $0.visibleFrame.width * 0.8 }) ?? 1200 {
            window.setContentSize(NSSize(width: 860, height: 560))
            window.center()
        }
        observer = NotificationCenter.default.addObserver(forName: NyCore.eventNotification, object: nil, queue: .main) { [weak self] note in
            guard let event = note.userInfo?["event"] as? [String: Any], event["type"] as? String == "records.changed",
                  let collection = event["collection"] as? String, collection.hasPrefix("inbox.") else { return }
            MainActor.assumeIsolated { self?.reload() }
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
                                 (sendButton, #selector(showSendMenu)), (laterButton, #selector(showLaterMenu)),
                                 (openButton, #selector(openSelectedSource)), (deleteButton, #selector(deleteSelected))] {
            button.target = self
            button.action = action
        }
        sendButton.image = NSImage(systemSymbolName: "paperplane", accessibilityDescription: nil)
        laterButton.image = NSImage(systemSymbolName: "clock", accessibilityDescription: nil)
        for button in [sendButton, laterButton] { button.imagePosition = .imageLeading }
        // The rarer actions are icons, so the row fits a narrow pane.
        for (button, symbol, tip) in [(copyButton, "doc.on.doc", "Copy (⌘C)"), (openButton, "arrow.up.forward.app", "Open Source (⌘O)"),
                                      (deleteButton, "trash", "Delete (⌫)")] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
            button.imagePosition = .imageOnly
            button.toolTip = tip
        }
        let actions = Design.hstack([doneButton, sendButton, laterButton, copyButton, openButton, Design.spacer(), deleteButton], spacing: 8)
        let hint = Design.label("Space done   S send   L later   R translate   A ask   P pin   ? all keys", size: 11, color: .tertiaryLabelColor)
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
        let selectedID = selectedItem?.id
        var params: [String: Any] = ["collection": collection.rawValue, "limit": 500]
        let query = search.stringValue.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty { params["search"] = query }
        let items = (try? core.call(.recordsList, params, as: CorePage<Note>.self).records) ?? []
        rows = []
        var lastDay: String?
        // Snoozed notes are listed by when they come back, soonest first.
        let ordered = tab == .later ? items.sorted { ($0.data.until ?? 0) < ($1.data.until ?? 0) } : items
        for item in ordered {
            let day = Self.day(of: Date(timeIntervalSince1970: Double(tab == .later ? item.data.until ?? item.createdAt : item.createdAt) / 1000))
            if day != lastDay { rows.append(.day(day)); lastDay = day }
            rows.append(.note(item))
        }
        let waiting = (try? core.call(.inboxCount) as? [String: Any])?["count"] as? Int ?? 0
        tabs.setLabel(waiting > 0 ? "Inbox (\(waiting))" : "Inbox", forSegment: 0)
        table.reloadData()
        if let selectedID, let row = rows.firstIndex(where: { if case .note(let item) = $0 { item.id == selectedID } else { false } }) {
            table.selectRowIndexes([row], byExtendingSelection: false)
        }
        let (symbol, title, message): (String, String, String) = switch tab {
        case .inbox: ("tray", "All clear", "Press F3 to jot something down, or select text and press F3 to keep it.")
        case .later: ("clock", "Nothing snoozed", "Press L on a note to put it away until later; it comes back to the top of the inbox.")
        case .done: ("checkmark.circle", "Nothing done yet", "Notes you mark done stay here for 30 days, in case you need one back.")
        }
        empty.show(symbol: query.isEmpty ? symbol : "magnifyingglass", title: query.isEmpty ? title : "No matches",
                   message: query.isEmpty ? message : "Nothing here mentions “\(query)”.")
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
        var when = "Added \(Self.day(of: created).lowercasedIfRelative) at \(clock.string(from: created))"
        if let until = item.data.until {
            let back = Date(timeIntervalSince1970: Double(until) / 1000)
            when += " · back \(Self.day(of: back).lowercasedIfRelative) at \(clock.string(from: back))"
        }
        if let doneAt = item.data.doneAt {
            let done = Date(timeIntervalSince1970: Double(doneAt) / 1000)
            when += " · done \(Self.day(of: done).lowercasedIfRelative) at \(clock.string(from: done))"
        }
        timeLabel.stringValue = when
        doneButton.title = switch tab { case .inbox: "Done"; case .later: "Back Now"; case .done: "Not Done" }
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
    private func saveNow() {
        pendingSave?.cancel()
        pendingSave = nil
        guard let id = shownID, let item = rows.lazy.compactMap({ if case .note(let item) = $0, item.id == id { item } else { nil } }).first,
              editor.string != item.data.text else { return }
        _ = try? core.call(.inboxUpdate, ["id": id, "text": editor.string])
    }

    @objc private func editSelected() {
        guard selectedItem != nil else { return }
        window?.makeFirstResponder(editor)
    }

    // MARK: Actions

    private func handleKey(_ key: InboxTable.Key) -> Bool {
        switch key {
        case .space: toggleDoneSelected()
        case .character("s") where tab == .inbox: showSendMenu()
        case .character("?"): KeySheet.shared.toggle("Inbox keys", groups: KeyGuide.inbox, over: window)
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
    @objc private func toggleDoneSelected() {
        guard let item = selectedItem else { return }
        saveNow()
        let row = table.selectedRow
        let (command, params, back): (CoreMethod, [String: Any], CoreMethod?) = switch tab {
        case .inbox: (.inboxDone, ["id": item.id], .inboxUndone)
        case .later: (.inboxWake, ["id": item.id], nil)
        case .done: (.inboxUndone, ["id": item.id], .inboxDone)
        }
        guard let reply = try? core.call(command, params) as? [String: Any],
              let moved = (reply["record"] ?? (reply["woken"] as? [Any])?.first) as? [String: Any],
              let movedID = moved["id"] as? String else { return }
        let until = item.data.until
        remember(command.rawValue) { [core] in
            let reply: [String: Any]?
            if let back { reply = try? core.call(back, ["id": movedID]) as? [String: Any] }
            else { reply = try? core.call(.inboxSnooze, ["id": movedID, "until": until ?? 0]) as? [String: Any] }
            return (reply?["record"] as? [String: Any])?["id"] as? String
        }
        reload()
        selectNear(row)
    }

    private func verb(_ verb: Verb) {
        guard let item = selectedItem else { return }
        saveNow()
        onVerb?(verb, editor.string, item.data.image.flatMap(images.image))
    }

    // MARK: Sending and snoozing

    @objc private func showSendMenu() {
        guard selectedItem != nil, tab == .inbox else { return }
        let menu = NSMenu()
        for destination in NoteExport.Destination.allCases {
            let item = NSMenuItem(title: destination.title, action: #selector(sendSelected(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = destination.rawValue
            item.image = NSImage(systemSymbolName: destination.symbol, accessibilityDescription: nil)
            menu.addItem(item)
        }
        if let folder = NoteExport.markdownFolder(core: core, choosingIfNeeded: false) {
            menu.items.last?.toolTip = folder.path
        }
        menu.addItem(.separator())
        let share = NSMenuItem(title: "Share…", action: #selector(shareSelected), keyEquivalent: "")
        share.target = self
        share.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: nil)
        menu.addItem(share)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sendButton.bounds.height + 4), in: sendButton)
    }

    @objc private func showLaterMenu() {
        guard selectedItem != nil, tab == .inbox else { return }
        let menu = NSMenu()
        let format = DateFormatter()
        format.setLocalizedDateFormatFromTemplate("EEEjmm")
        for choice in SnoozeChoice.allCases {
            guard let date = choice.date() else { continue }
            let item = NSMenuItem(title: "\(choice.title)  —  \(format.string(from: date))", action: #selector(snoozeSelected(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = date
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: laterButton.bounds.height + 4), in: laterButton)
    }

    @objc private func snoozeSelected(_ sender: NSMenuItem) {
        guard let item = selectedItem, let date = sender.representedObject as? Date else { return }
        saveNow()
        let row = table.selectedRow
        do {
            let reply = try core.call(.inboxSnooze, ["id": item.id, "until": Int64(date.timeIntervalSince1970 * 1000)]) as? [String: Any]
            if let snoozedID = (reply?["record"] as? [String: Any])?["id"] as? String {
                remember("Snooze") { [core] in
                    ((try? core.call(.inboxWake, ["id": snoozedID]) as? [String: Any])?["woken"] as? [[String: Any]])?.first?["id"] as? String
                }
            }
        } catch {
            NSSound.beep()
        }
        reload()
        selectNear(row)
    }

    /// What a destination gets from the selected note.
    private func exportContent(_ item: Item) -> NoteExport.Content {
        let app = item.data.app ?? "", title = item.data.title ?? ""
        let place = [app, title == app ? "" : title].filter { !$0.isEmpty }.joined(separator: " — ")
        let address = item.data.url.flatMap { SourceContext.isMeaningful(address: $0) ? URL(string: $0) : nil }
        return NoteExport.Content(text: editor.string, image: item.data.image.map(images.file), source: place, address: address,
                                  created: Date(timeIntervalSince1970: Double(item.data.created ?? item.createdAt) / 1000))
    }

    /// Sent notes are handed off, so they're marked done (⌘Z brings one back).
    @objc private func sendSelected(_ sender: NSMenuItem) {
        guard let item = selectedItem, let raw = sender.representedObject as? String,
              let destination = NoteExport.Destination(rawValue: raw) else { return }
        saveNow()
        let content = exportContent(item)
        Task {
            do {
                let done = try await NoteExport.send(content, to: destination, core: core)
                if selectedItem?.id == item.id { toggleDoneSelected() }
                else if (try? core.call(.inboxDone, ["id": item.id])) != nil { reload() }
                toast.show(done, detail: "Marked done · ⌘Z in the inbox brings it back", style: .success)
            } catch {
                let alert = NSAlert()
                alert.messageText = "Couldn’t send the note to \(destination.title)"
                alert.informativeText = error.localizedDescription
                if let window { alert.beginSheetModal(for: window, completionHandler: nil) } else { alert.runModal() }
            }
        }
    }

    @objc private func shareSelected() {
        guard let item = selectedItem else { return }
        let content = exportContent(item)
        var things: [Any] = []
        if !content.text.isEmpty { things.append(content.text) }
        if let image = content.image.flatMap({ NSImage(contentsOf: $0) }) { things.append(image) }
        if let address = content.address { things.append(address) }
        NSSharingServicePicker(items: things).show(relativeTo: sendButton.bounds, of: sendButton, preferredEdge: .minY)
    }

    @objc private func deleteSelected() {
        guard let item = selectedItem else { return }
        let row = table.selectedRow
        _ = try? core.deleteRecord(item.id)
        if let image = item.data.image { keptImages.append(image) }
        let note = item.data, done = showsDone
        remember("Delete") { [core] in
            var params: [String: Any] = ["text": note.text, "app": note.app ?? "", "title": note.title ?? "", "url": note.url ?? "",
                                         "source": note.source ?? "typed"]
            if let image = note.image { params["image"] = image }
            guard let id = ((try? core.call(.inboxAdd, params) as? [String: Any])?["record"] as? [String: Any])?["id"] as? String else { return nil }
            return done ? ((try? core.call(.inboxDone, ["id": id]) as? [String: Any])?["record"] as? [String: Any])?["id"] as? String : id
        }
        reload()
        selectNear(row)
    }

    @objc private func copySelected() {
        guard let item = selectedItem else { return }
        NSPasteboard.general.clearContents()
        if let image = item.data.image.flatMap(images.image) {
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
            let picture = item.data.image?.hasSuffix(".gif") == true ? "Recording" : "Screenshot"
            cell.title.stringValue = firstLine.flatMap { $0.isEmpty ? nil : $0 } ?? (item.data.image == nil ? "Empty note" : picture)
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
