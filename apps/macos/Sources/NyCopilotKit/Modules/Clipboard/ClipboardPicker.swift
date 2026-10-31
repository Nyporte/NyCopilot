import AppKit
import ImageIO

/// A kept copy: text, or an image file beside the database.
struct ClipboardEntry: Decodable {
    let text: String?
    let image: String?
    let digest: String?
    let width: Int?
    let height: Int?
    let app: String?
}

/// The clipboard history as a small floating list near the pointer, pinned entries first: type to
/// search, ↑↓ to choose, Return (or a double-click) to paste, ⌘1–⌘9 to paste one of the first nine,
/// ⌘C to copy without pasting, ⌘P to pin or unpin, ⌘R / ⌘I / ⌘A to translate it, keep it in the
/// inbox, or ask about it, ⌘⌫ to forget an entry, Esc to close.
@MainActor
final class ClipboardPicker: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private typealias Item = CoreRecord<ClipboardEntry>

    /// The chosen entry, and the field it should go back into.
    var onPick: ((ClipboardEntry, InputTarget?) -> Void)?
    /// The entry onto the clipboard without pasting.
    var onCopy: ((ClipboardEntry) -> Void)?
    /// ⌘R, ⌘I, ⌘A: translate it, keep it in the inbox, or ask about it; the app it was opened over.
    var onVerb: ((Verb, ClipboardEntry, NSRunningApplication?) -> Void)?

    private let core: NyCore
    private let images: ImageFolder
    private let thumbnails = NSCache<NSString, NSImage>()
    let panel = FloatingPanel(size: NSSize(width: 420, height: 380))
    private let search = NSSearchField()
    private let table = NSTableView()
    private let empty = Design.label("", size: 12.5, color: .tertiaryLabelColor)
    private let hint = Design.label("", size: 10.5, color: .tertiaryLabelColor)
    private static let keysHint = "↩ paste   ⌘P pin   ⌘R translate   ⌘I inbox   ⌘A ask   ⌘/ keys"
    private var items: [Item] = []
    /// The first `pinnedCount` items are pinned.
    private var pinnedCount = 0
    private var target: InputTarget?
    private var source: NSRunningApplication?
    private let age: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.dateTimeStyle = .named
        return formatter
    }()

    init(core: NyCore, images: ImageFolder) {
        self.core = core
        self.images = images
        super.init()
        panel.onCancel = { [weak self] in self?.close() }
        panel.onCommand = { [weak self] key, shift in shift ? false : self?.command(key) ?? false }
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

        hint.stringValue = Self.keysHint
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
        prepare(target: target, source: source)
        panel.present(focus: search)
    }

    /// Everything `present` does but show the list.
    func prepare(target: InputTarget?, source: NSRunningApplication?) {
        self.target = target
        self.source = source
        search.stringValue = ""
        hint.stringValue = Tips.due("clipboard.pin", after: 3, times: 2) ? "Tip: ⌘P keeps an entry at the top, for good" : Self.keysHint
        reload()
        let pointer = NSEvent.mouseLocation
        let screen = ScreenGeometry.screen(at: pointer)
        let visible = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        let size = panel.frame.size
        let origin = NSPoint(x: min(max(pointer.x - size.width / 2, visible.minX), visible.maxX - size.width),
                             y: min(max(pointer.y - size.height - 12, visible.minY), visible.maxY - size.height))
        panel.setFrameOrigin(origin)
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
        let query = search.stringValue.trimmingCharacters(in: .whitespaces)
        func list(_ collection: CoreCollection, limit: Int) -> [Item] {
            var params: [String: Any] = ["collection": collection.rawValue, "limit": limit]
            if !query.isEmpty { params["search"] = query }
            return (try? core.call("records.list", params, as: CorePage<ClipboardEntry>.self).records) ?? []
        }
        let pinned = list(.clipboardPinned, limit: 100)
        pinnedCount = pinned.count
        items = pinned + list(.clipboardItems, limit: 200)
        table.reloadData()
        if !items.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false); table.scrollRowToVisible(0) }
        empty.stringValue = query.isEmpty ? "Copy some text or an image and it shows up here." : "Nothing matches “\(query)”."
        empty.isHidden = !items.isEmpty
    }

    private func pick(_ row: Int) {
        guard items.indices.contains(row) else { return }
        let entry = items[row].data, target = target
        onPick?(entry, target)
    }

    @objc private func pickClicked() { pick(table.clickedRow) }

    /// ⌘ shortcuts while the list is up; false lets the key through to the search field.
    private func command(_ key: String) -> Bool {
        if let digit = Int(key), (1...9).contains(digit) { pick(digit - 1); return true }
        let row = table.selectedRow
        switch key {
        case "c":
            guard items.indices.contains(row) else { return false }
            onCopy?(items[row].data)
            close()
            return true
        case "p":
            guard items.indices.contains(row) else { return true }
            let pinned = row < pinnedCount
            do {
                let moved = try core.call(pinned ? "clipboard.unpin" : "clipboard.pin", ["id": items[row].id]) as? [String: Any]
                reload()
                // Keep the same entry selected in its new place.
                let id = (moved?["record"] as? [String: Any])?["id"] as? String
                if let index = items.firstIndex(where: { $0.id == id }) {
                    table.selectRowIndexes([index], byExtendingSelection: false)
                    table.scrollRowToVisible(index)
                }
            } catch {
                NSSound.beep()
                empty.stringValue = error.localizedDescription
            }
            return true
        case "/":
            KeySheet.shared.toggle("Clipboard keys", groups: KeyGuide.clipboard, over: panel)
            return true
        case "r", "i", "a":
            // ⌘A selects the search text while there is some.
            if key == "a", !search.stringValue.isEmpty { return false }
            guard items.indices.contains(row) else { return true }
            let entry = items[row].data, app = source
            close()
            onVerb?(key == "r" ? .translate : key == "i" ? .inbox : .ask, entry, app)
            return true
        case "\u{8}", "\u{7F}":
            guard items.indices.contains(row) else { return true }
            _ = try? core.call("records.delete", ["id": items[row].id])
            reload()
            if !items.isEmpty { table.selectRowIndexes([min(row, items.count - 1)], byExtendingSelection: false) }
            return true
        default:
            return false
        }
    }

    /// A small rendition, decoded once: a full screenshot is too big to redraw in a list.
    private func thumbnail(_ name: String) -> NSImage? {
        if let cached = thumbnails.object(forKey: name as NSString) { return cached }
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 120,
                       kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(images.file(name) as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        let thumbnail = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        thumbnails.setObject(thumbnail, forKey: name as NSString)
        return thumbnail
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
        let item = items[row], entry = item.data
        if let name = entry.image {
            cell.show(thumbnail: thumbnail(name))
            cell.preview.stringValue = "Image  \(entry.width ?? 0) × \(entry.height ?? 0)"
        } else {
            cell.show(thumbnail: nil)
            cell.preview.stringValue = (entry.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                .split(whereSeparator: \.isNewline).prefix(2).joined(separator: " ⏎ ")
        }
        // Never "in 0s": a copy made this instant is simply "now".
        let now = Date()
        let when = row < pinnedCount ? "Pinned"
            : age.localizedString(for: min(Date(timeIntervalSince1970: Double(item.createdAt) / 1000), now), relativeTo: now)
        cell.metadata.stringValue = [row < 9 ? "⌘\(row + 1)" : nil, entry.app.flatMap { $0.isEmpty ? nil : $0 }, when]
            .compactMap { $0 }.joined(separator: "  ·  ")
        cell.pin.isHidden = row >= pinnedCount
        return cell
    }
}

private final class ClipRow: NSTableCellView {
    let preview = Design.label("", size: 13)
    let metadata = Design.label("", size: 10.5, color: .secondaryLabelColor)
    let pin = Design.symbol("pin.fill", size: 10, color: .controlAccentColor)
    private let picture = NSImageView()
    private var textLeading: NSLayoutConstraint!

    init() {
        super.init(frame: .zero)
        preview.lineBreakMode = .byTruncatingTail
        picture.imageScaling = .scaleProportionallyUpOrDown
        picture.wantsLayer = true
        picture.layer?.cornerRadius = 4
        picture.layer?.masksToBounds = true
        let stack = Design.vstack([preview, Design.hstack([pin, metadata], spacing: 4)], spacing: 3)
        for view in [picture, stack] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        textLeading = stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8)
        NSLayoutConstraint.activate([
            picture.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            picture.centerYAnchor.constraint(equalTo: centerYAnchor),
            picture.widthAnchor.constraint(equalToConstant: 48),
            picture.heightAnchor.constraint(equalToConstant: 36),
            textLeading,
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            preview.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor)
        ])
    }

    /// An image entry shows its picture before the text.
    func show(thumbnail: NSImage?) {
        picture.image = thumbnail
        picture.isHidden = thumbnail == nil
        textLeading.constant = thumbnail == nil ? 8 : 8 + 48 + 10
    }

    required init?(coder: NSCoder) { fatalError("Use init()") }
}
