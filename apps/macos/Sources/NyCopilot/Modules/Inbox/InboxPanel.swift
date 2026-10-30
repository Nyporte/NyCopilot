import AppKit

/// The inbox as a small floating panel near the pointer: a box to jot into at the top (↩ adds,
/// ⇧↩ a new line), the notes waiting below, newest first. ↓ moves into the notes; there ↩ or a
/// double-click edits one, ⌘C copies it, ⌫ marks it handled, ↑ at the top goes back to the box.
/// Esc puts the panel away.
@MainActor
final class InboxPanel: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    struct Note: Decodable {
        let text: String
        let image: String?
        let app: String?
        let source: String?
    }
    typealias Item = CoreRecord<Note>

    private let core: NyCore
    /// Where screenshots in notes are kept.
    let imageFolder: URL
    private let panel = InboxWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 460),
                                    styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: true)
    private let input = JotView()
    private let inputScroll = NSScrollView()
    private var inputHeight: NSLayoutConstraint!
    private let table = NoteTable()
    private let hint = Design.label("", size: 10.5, color: .tertiaryLabelColor)
    private let empty = Design.label("Nothing waiting. Jot something above.", size: 12.5, color: .tertiaryLabelColor)
    private var items: [Item] = []
    /// The note being edited in the box, if any.
    private var editing: String?
    private var source: NSRunningApplication?
    private var observer: NSObjectProtocol?
    private var thumbnails: [String: NSImage] = [:]
    private let age: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.dateTimeStyle = .named
        return formatter
    }()

    init(core: NyCore, imageFolder: URL) {
        self.core = core
        self.imageFolder = imageFolder
        super.init()
        panel.float(at: .floating, shadow: true, behavior: .transient)
        panel.onResignKey = { [weak self] in self?.close(returningFocus: false) }

        let material = NSVisualEffectView.roundedMaterial(.popover, radius: 12)
        input.font = .systemFont(ofSize: 14)
        input.isRichText = false
        input.allowsUndo = true
        input.drawsBackground = false
        input.textContainerInset = NSSize(width: 2, height: 6)
        input.isVerticallyResizable = true
        input.textContainer?.widthTracksTextView = true
        input.onSubmit = { [weak self] in self?.submit() }
        input.onCancel = { [weak self] in self?.cancelEditingOrClose() }
        input.onDown = { [weak self] in self?.focusList() ?? false }
        input.onChange = { [weak self] in self?.fitInput() }
        inputScroll.documentView = input
        inputScroll.drawsBackground = false
        inputScroll.hasVerticalScroller = true
        inputScroll.autohidesScrollers = true
        let inputBox = NSBox()
        inputBox.boxType = .custom
        inputBox.cornerRadius = 8
        inputBox.borderWidth = 0
        inputBox.fillColor = NSColor.textBackgroundColor.withAlphaComponent(0.6)
        inputBox.contentView = inputScroll

        table.addTableColumn(NSTableColumn(identifier: .init("note")))
        table.headerView = nil
        table.style = .plain
        table.backgroundColor = .clear
        table.usesAutomaticRowHeights = true
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(editClicked)
        table.onUp = { [weak self] in self?.focusInput() }
        table.onEdit = { [weak self] in self?.beginEditing() }
        table.onCopy = { [weak self] in self?.copySelected() }
        table.onHandled = { [weak self] in self?.markHandled() }
        table.onCancel = { [weak self] in self?.close() }
        table.onFocus = { [weak self] focused in self?.showHint(listFocused: focused) }
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        for view in [inputBox, scroll, hint, empty] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            material.addSubview(view)
        }
        inputHeight = inputBox.heightAnchor.constraint(equalToConstant: 34)
        NSLayoutConstraint.activate([
            inputBox.topAnchor.constraint(equalTo: material.topAnchor, constant: 12),
            inputBox.leadingAnchor.constraint(equalTo: material.leadingAnchor, constant: 12),
            inputBox.trailingAnchor.constraint(equalTo: material.trailingAnchor, constant: -12),
            inputHeight,
            scroll.topAnchor.constraint(equalTo: inputBox.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: material.leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: material.trailingAnchor, constant: -6),
            scroll.bottomAnchor.constraint(equalTo: hint.topAnchor, constant: -6),
            hint.leadingAnchor.constraint(equalTo: material.leadingAnchor, constant: 14),
            hint.trailingAnchor.constraint(lessThanOrEqualTo: material.trailingAnchor, constant: -14),
            hint.bottomAnchor.constraint(equalTo: material.bottomAnchor, constant: -9),
            empty.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor)
        ])
        panel.contentView = material
        observer = NotificationCenter.default.addObserver(forName: NyCore.eventNotification, object: nil, queue: .main) { [weak self] note in
            guard let event = note.userInfo?["event"] as? [String: Any], event["type"] as? String == "records.changed",
                  event["collection"] as? String == CoreCollection.inboxNotes.rawValue else { return }
            MainActor.assumeIsolated { if self?.panel.isVisible == true { self?.reload() } }
        }
    }

    var isVisible: Bool { panel.isVisible }

    /// Opens near the pointer with the box ready for typing; `source` gets focus back afterwards.
    func present(returningTo source: NSRunningApplication?) {
        self.source = source
        editing = nil
        input.string = ""
        input.placeholder = "Jot something down"
        fitInput()
        reload()
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: min(max(pointer.x - size.width / 2, visible.minX), visible.maxX - size.width),
                                     y: min(max(pointer.y - size.height - 12, visible.minY), visible.maxY - size.height)))
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        focusInput()
    }

    /// Puts the panel away; unless something else takes focus right after, back to where you were.
    func close(returningFocus: Bool = true) {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        if returningFocus, let source, !source.isTerminated { source.activate(options: []) }
    }

    private func reload() {
        items = (try? core.call("records.list", ["collection": CoreCollection.inboxNotes.rawValue, "limit": 500], as: CorePage<Note>.self).records) ?? []
        let selected = table.selectedRow
        table.reloadData()
        if table.window?.firstResponder === table, !items.isEmpty {
            table.selectRowIndexes([min(max(selected, 0), items.count - 1)], byExtendingSelection: false)
        }
        empty.isHidden = !items.isEmpty
    }

    // MARK: The box

    private func submit() {
        let text = input.string
        do {
            if let editing {
                _ = try core.call("inbox.update", ["id": editing, "text": text])
            } else {
                _ = try core.call("inbox.add", ["text": text, "app": source?.localizedName ?? "", "source": "typed"])
            }
        } catch {
            NSSound.beep()
            return
        }
        editing = nil
        input.string = ""
        input.placeholder = "Jot something down"
        fitInput()
        reload()
    }

    private func cancelEditingOrClose() {
        guard editing != nil else { close(); return }
        editing = nil
        input.string = ""
        input.placeholder = "Jot something down"
        fitInput()
    }

    /// One line, growing to five as you type.
    private func fitInput() {
        guard let layout = input.layoutManager, let container = input.textContainer else { return }
        layout.ensureLayout(for: container)
        let lines = max(1, min(5, Int((layout.usedRect(for: container).height / 18).rounded(.up))))
        inputHeight.constant = CGFloat(lines) * 18 + 16
        showHint(listFocused: false)
    }

    private func focusInput() {
        panel.makeFirstResponder(input)
        table.deselectAll(nil)
        showHint(listFocused: false)
    }

    /// ↓ in the box: into the notes, unless the box has more lines below the cursor.
    private func focusList() -> Bool {
        guard !items.isEmpty, input.isOnLastLine else { return false }
        panel.makeFirstResponder(table)
        table.selectRowIndexes([0], byExtendingSelection: false)
        table.scrollRowToVisible(0)
        return true
    }

    private func showHint(listFocused: Bool) {
        if listFocused {
            hint.stringValue = "↩ edit   ⌘C copy   ⌫ handled   ↑ back to the box   esc close"
        } else if editing != nil {
            hint.stringValue = "↩ save   ⇧↩ new line   esc stop editing"
        } else {
            hint.stringValue = "↩ add   ⇧↩ new line   ↓ notes   esc close"
        }
    }

    // MARK: Notes

    private var selected: Item? { items.indices.contains(table.selectedRow) ? items[table.selectedRow] : nil }

    @objc private func editClicked() {
        guard items.indices.contains(table.clickedRow) else { return }
        table.selectRowIndexes([table.clickedRow], byExtendingSelection: false)
        beginEditing()
    }

    /// The note's text goes into the box; ↩ saves it in place.
    private func beginEditing() {
        guard let item = selected else { return }
        editing = item.id
        input.string = item.data.text
        input.placeholder = item.data.image == nil ? "" : "Add a caption"
        panel.makeFirstResponder(input)
        input.setSelectedRange(NSRange(location: (input.string as NSString).length, length: 0))
        fitInput()
    }

    private func copySelected() {
        guard let item = selected else { return }
        NSPasteboard.general.clearContents()
        if let image = item.data.image.flatMap(loadImage) {
            NSPasteboard.general.writeObjects([image])
            if !item.data.text.isEmpty { NSPasteboard.general.setString(item.data.text, forType: .string) }
        } else {
            NSPasteboard.general.setString(item.data.text, forType: .string)
        }
    }

    /// Handled: the note goes, and its screenshot with it.
    private func markHandled() {
        guard let item = selected else { return }
        let row = table.selectedRow
        _ = try? core.call("records.delete", ["id": item.id])
        if let image = item.data.image {
            try? FileManager.default.removeItem(at: imageFolder.appendingPathComponent(image))
            thumbnails[image] = nil
        }
        reload()
        if items.isEmpty { focusInput() } else { table.selectRowIndexes([min(row, items.count - 1)], byExtendingSelection: false) }
    }

    private func loadImage(_ name: String) -> NSImage? { NSImage(contentsOf: imageFolder.appendingPathComponent(name)) }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: .init("note"), owner: nil) as? NoteRow ?? NoteRow()
        cell.identifier = .init("note")
        let item = items[row]
        cell.text.stringValue = item.data.text.trimmingCharacters(in: .whitespacesAndNewlines)
        cell.text.isHidden = cell.text.stringValue.isEmpty
        if let name = item.data.image {
            if thumbnails[name] == nil { thumbnails[name] = loadImage(name) }
            cell.thumbnail.image = thumbnails[name]
            cell.thumbnail.isHidden = false
        } else {
            cell.thumbnail.isHidden = true
        }
        let now = Date()
        let when = age.localizedString(for: min(Date(timeIntervalSince1970: Double(item.createdAt) / 1000), now), relativeTo: now)
        let from: String? = switch item.data.source {
        case "selection": "selected"
        case "screenshot": "screenshot"
        default: nil
        }
        cell.metadata.stringValue = [from, item.data.app.flatMap { $0.isEmpty ? nil : $0 }, when].compactMap { $0 }.joined(separator: "  ·  ")
        return cell
    }
}

/// The box you jot into: ↩ submits, ⇧↩ (or ⌥↩) a new line, Esc cancels, ↓ on the last line moves on.
private final class JotView: NSTextView {
    var onSubmit: (() -> Void)?
    var onCancel: (() -> Void)?
    var onDown: (() -> Bool)?
    var onChange: (() -> Void)?
    var placeholder = "" { didSet { needsDisplay = true } }

    var isOnLastLine: Bool {
        let text = string as NSString
        return text.rangeOfCharacter(from: .newlines, range: NSRange(location: selectedRange().location,
                                                                     length: text.length - selectedRange().location)).location == NSNotFound
    }

    override func doCommand(by selector: Selector) {
        let flags = NSApp.currentEvent?.modifierFlags.intersection([.shift, .option]) ?? []
        switch selector {
        case #selector(insertNewline(_:)) where flags.isEmpty && !hasMarkedText(): onSubmit?()
        case #selector(insertNewline(_:)): insertNewlineIgnoringFieldEditor(nil)
        case #selector(cancelOperation(_:)): onCancel?()
        case #selector(moveDown(_:)) where onDown?() == true: break
        default: super.doCommand(by: selector)
        }
    }

    override func didChangeText() {
        super.didChangeText()
        onChange?()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        (placeholder as NSString).draw(at: NSPoint(x: textContainerInset.width + 5, y: textContainerInset.height),
                                       withAttributes: [.font: font ?? .systemFont(ofSize: 14), .foregroundColor: NSColor.placeholderTextColor])
    }
}

/// The notes list: keys for editing, copying, and marking handled.
private final class NoteTable: NSTableView {
    var onUp: (() -> Void)?
    var onEdit: (() -> Void)?
    var onCopy: (() -> Void)?
    var onHandled: (() -> Void)?
    var onCancel: (() -> Void)?
    var onFocus: ((Bool) -> Void)?

    @objc func copy(_ sender: Any?) { onCopy?() }

    override func becomeFirstResponder() -> Bool {
        defer { onFocus?(true) }
        return super.becomeFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 126 where selectedRow <= 0: onUp?()
        case 36, 76: onEdit?()
        case 51, 117: onHandled?()
        case 53: onCancel?()
        default: super.keyDown(with: event)
        }
    }
}

private final class NoteRow: NSTableCellView {
    let text = Design.label("", size: 13)
    let thumbnail = NSImageView()
    let metadata = Design.label("", size: 10.5, color: .secondaryLabelColor)

    init() {
        super.init(frame: .zero)
        text.maximumNumberOfLines = 3
        text.lineBreakMode = .byTruncatingTail
        text.cell?.wraps = true
        text.cell?.truncatesLastVisibleLine = true
        thumbnail.imageScaling = .scaleProportionallyUpOrDown
        thumbnail.imageAlignment = .alignLeft
        thumbnail.wantsLayer = true
        thumbnail.layer?.cornerRadius = 4
        thumbnail.heightAnchor.constraint(lessThanOrEqualToConstant: 90).isActive = true
        let stack = Design.vstack([thumbnail, text, metadata], spacing: 4)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            text.widthAnchor.constraint(equalTo: stack.widthAnchor),
            thumbnail.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("Use init()") }
}

/// Borderless but able to take typing; it goes away when you click elsewhere.
private final class InboxWindow: NSPanel {
    var onResignKey: (() -> Void)?
    override var canBecomeKey: Bool { true }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }
}
