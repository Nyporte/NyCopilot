import AppKit

/// Sending a note to Reminders, Notes, or a Markdown folder, and snoozing it.
extension InboxWindow {
    // MARK: Sending and snoozing

    @objc func showSendMenu() {
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
        let share = NSMenuItem(title: L("Share…"), action: #selector(shareSelected), keyEquivalent: "")
        share.target = self
        share.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: nil)
        menu.addItem(share)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sendButton.bounds.height + 4), in: sendButton)
    }

    @objc func showLaterMenu() {
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

    @objc func snoozeSelected(_ sender: NSMenuItem) {
        guard let item = selectedItem, let date = sender.representedObject as? Date else { return }
        saveNow()
        let row = table.selectedRow
        do {
            if let snoozedID = try core.inboxSnooze(item.id, until: Int64(date.timeIntervalSince1970 * 1000)) {
                remember(L("Snooze")) { [core] in (try? core.inboxWake(snoozedID))?.first?.id }
            }
        } catch {
            NSSound.beep()
        }
        reload()
        selectNear(row)
    }

    /// What a destination gets from the selected note.
    func exportContent(_ item: Item) -> NoteExport.Content {
        let app = item.data.app ?? "", title = item.data.title ?? ""
        let place = [app, title == app ? "" : title].filter { !$0.isEmpty }.joined(separator: " — ")
        let address = item.data.url.flatMap { SourceContext.isMeaningful(address: $0) ? URL(string: $0) : nil }
        return NoteExport.Content(text: editor.string, image: item.data.image.map(images.file), source: place, address: address,
                                  created: Date(timeIntervalSince1970: Double(item.data.created ?? item.createdAt) / 1000))
    }

    /// Sent notes are handed off, so they're marked done (⌘Z brings one back).
    @objc func sendSelected(_ sender: NSMenuItem) {
        guard let item = selectedItem, let raw = sender.representedObject as? String,
              let destination = NoteExport.Destination(rawValue: raw) else { return }
        saveNow()
        let content = exportContent(item)
        Task {
            do {
                let done = try await NoteExport.send(content, to: destination, core: self.core)
                if selectedItem?.id == item.id { toggleDoneSelected() } else { markDone(item) }
                toast.show(done, detail: L("Marked done · ⌘Z in the inbox brings it back"), style: .success)
            } catch {
                let alert = NSAlert()
                alert.messageText = L("Couldn’t send the note to %@", destination.title)
                alert.informativeText = error.localizedDescription
                if let window { alert.beginSheetModal(for: window, completionHandler: nil) } else { alert.runModal() }
            }
        }
    }

    @objc func shareSelected() {
        guard let item = selectedItem else { return }
        let content = exportContent(item)
        var things: [Any] = []
        if !content.text.isEmpty { things.append(content.text) }
        if let image = content.image.flatMap({ NSImage(contentsOf: $0) }) { things.append(image) }
        if let address = content.address { things.append(address) }
        NSSharingServicePicker(items: things).show(relativeTo: sendButton.bounds, of: sendButton, preferredEdge: .minY)
    }

    @objc func deleteSelected() {
        guard let item = selectedItem else { return }
        let row = table.selectedRow
        _ = try? core.deleteRecord(item.id)
        if let image = item.data.image { keptImages.append(image) }
        let note = item.data, list = tab, created = item.data.created ?? item.createdAt
        // Undo puts the note back where it was — waiting, later, or done — with its own date.
        remember(L("Delete")) { [weak self, core] in
            var params: [String: Any] = ["text": note.text, "app": note.app ?? "", "title": note.title ?? "", "url": note.url ?? "",
                                         "source": note.source ?? "typed", "created": created]
            if let image = note.image { params["image"] = image }
            guard let id = try? core.inboxAdd(params) ?? nil else { return nil }
            if let image = note.image { self?.keptImages.removeAll { $0 == image } }
            switch list {
            case .inbox: return id
            case .done: return try? core.inboxMove(.inboxDone, id) ?? nil
            case .later: return (note.until.flatMap { try? core.inboxSnooze(id, until: $0) ?? nil }) ?? id
            }
        }
        reload()
        selectNear(row)
    }

    @objc func copySelected() {
        guard let item = selectedItem else { return }
        NSPasteboard.general.clearContents()
        if let image = item.data.image.flatMap(images.image) {
            NSPasteboard.general.writeObjects([image])
        }
        if !item.data.text.isEmpty { NSPasteboard.general.setString(item.data.text, forType: .string) }
    }

    /// The page or document it came from; else the app, if it's running.
    @objc func openSelectedSource() {
        guard let item = selectedItem else { return }
        if let address = item.data.url, SourceContext.isMeaningful(address: address), let url = URL(string: address) {
            NSWorkspace.shared.open(url)
        } else if let app = runningApp(named: item.data.app) {
            app.activate(options: [])
        } else {
            NSSound.beep()
        }
    }

    func runningApp(named name: String?) -> NSRunningApplication? {
        guard let name, !name.isEmpty else { return nil }
        return NSWorkspace.shared.runningApplications.first { $0.localizedName == name }
    }

}
