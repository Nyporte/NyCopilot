import AppKit
import MacPlatform

/// macOS half of the Inbox module, one surface per job:
/// - F3 with text selected anywhere keeps the selection — no window, just a confirmation.
/// - F3 otherwise opens the capture bar to jot a thought and get back to work.
/// - ⇧F3 (or the menu, or ⌘O in the bar) opens the inbox window to work through notes.
/// Screenshots arrive through `CopilotServices.sendToInbox`. Every note keeps where it came from.
@MainActor
final class InboxShell: ModuleShell {
    let id = "inbox"
    let title = "Inbox"
    let symbolName = "tray"

    enum Action {
        static let capture = "inbox.capture"
        static let open = "inbox.open"
    }

    private let services: CopilotServices
    /// Screenshots in notes, as `<uuid>.png` beside the database.
    static let images = ImageFolder("Inbox")
    private let bar = InboxCaptureBar()
    private var window: InboxWindow?
    private var alarm: Timer?

    init(services: CopilotServices) {
        self.services = services
        services.sendToInbox = { [weak self] text, image, app in
            Task { await self?.send(text: text, image: image, context: SourceContext.of(app)) }
        }
        services.sendFileToInbox = { [weak self] url, app in
            Task { await self?.send(file: url, context: SourceContext.of(app)) }
        }
        bar.onSave = { [weak self] text, context in
            guard let self, add(["text": text, "source": "typed"], context: context) else { return }
            if Tips.due("inbox.selection", after: 3, times: 2) {
                let key = services.hotKeys.combination(for: Action.capture).map(KeyNames.display) ?? "the shortcut"
                services.toast.show("Saved to Inbox", detail: "Tip: select text in any app and press \(key) to keep it without typing.", style: .success)
            }
        }
        bar.onOpenInbox = { [weak self] in self?.openInbox() }
        Self.images.removeUnused(core: services.core, collections: [.inboxNotes, .inboxDone, .inboxSnoozed])
        // Snoozed notes come back on time, or at launch (or wake) when they fell due meanwhile.
        wakeDueNotes()
        snoozeObservers = [
            NotificationCenter.default.addObserver(forName: NyCore.eventNotification, object: nil, queue: .main) { [weak self] note in
                guard let event = note.userInfo?["event"] as? [String: Any],
                      event["collection"] as? String == CoreCollection.inboxSnoozed.rawValue else { return }
                MainActor.assumeIsolated { self?.scheduleAlarm() }
            },
            NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.wakeDueNotes() }
            }
        ]
    }

    private var snoozeObservers: [NSObjectProtocol] = []

    /// One timer, for the next snoozed note that's due — none while nothing is snoozed.
    private func scheduleAlarm() {
        alarm?.invalidate()
        snoozeObservers.forEach { NotificationCenter.default.removeObserver($0); NSWorkspace.shared.notificationCenter.removeObserver($0) }
        alarm = nil
        struct Snoozed: Decodable { let until: Int64? }
        let page = try? services.core.call(.recordsList, ["collection": CoreCollection.inboxSnoozed.rawValue, "limit": 500],
                                           as: CorePage<Snoozed>.self)
        guard let next = page?.records.compactMap(\.data.until).min() else { return }
        let due = Date(timeIntervalSince1970: Double(next) / 1000)
        let timer = Timer(fire: max(due, Date().addingTimeInterval(1)), interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.wakeDueNotes() }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        alarm = timer
    }

    var hotKeyActions: [HotKeyCenter.Action] {
        [.init(id: Action.capture, title: "Jot something down, or keep the selection",
               defaultCombination: .init(keyCode: 99, modifiers: 0), // F3
               handler: { [weak self] in self?.capture() }),
         .init(id: Action.open, title: "Open the inbox",
               defaultCombination: .init(keyCode: 99, modifiers: HotKeyCombination.shift),
               handler: { [weak self] in self?.openInbox() })]
    }

    func menuItems() -> [NSMenuItem] {
        [services.menuItem("Jot Down…", symbol: "square.and.pencil", hotKey: Action.capture, target: self, action: #selector(captureFromMenu)),
         services.menuItem(waiting > 0 ? "Inbox (\(waiting))" : "Inbox", symbol: waiting > 0 ? "tray.full" : "tray",
                           hotKey: Action.open, target: self, action: #selector(openFromMenu))]
    }

    func makeSettingsPane() -> SettingsPane? { InboxPane(services: services) }

    func shutdown() {
        alarm?.invalidate()
        bar.close(returningFocus: false)
        window?.forgetUndo()
    }

    private var waiting: Int { (try? services.core.call(.inboxCount) as? [String: Any])?["count"] as? Int ?? 0 }

    private func wakeDueNotes() {
        defer { scheduleAlarm() }
        guard let woken = (try? services.core.call(.inboxWake) as? [String: Any])?["woken"] as? [[String: Any]], !woken.isEmpty else { return }
        let first = ((woken[0]["data"] as? [String: Any])?["text"] as? String)?
            .split(whereSeparator: \.isNewline).first.map { "“\($0.prefix(50))”" } ?? "A snoozed note"
        services.toast.show(woken.count == 1 ? "Back in your inbox" : "\(woken.count) notes are back in your inbox",
                            detail: woken.count == 1 ? first : "\(first) and more · ⇧F3 to open", style: .info)
    }

    @objc private func captureFromMenu() { capture() }
    @objc private func openFromMenu() { openInbox() }

    private func openInbox() {
        bar.close(returningFocus: false)
        if window == nil {
            window = InboxWindow(core: services.core, images: Self.images, toast: services.toast)
            window?.onVerb = { [weak services] verb, text, image in services?.act(verb, text: text, image: image) }
        }
        window?.present()
    }

    /// The selection, kept as it is; with nothing selected, the capture bar.
    private func capture() {
        if bar.isVisible { bar.close(); return }
        let app = NSWorkspace.shared.frontmostApplication
        let foreign = app.flatMap { $0.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : $0 }
        Task {
            let context = await SourceContext.of(foreign)
            if let foreign, Accessibility.isTrusted, let text = await InputTarget.selectedText(pid: foreign.processIdentifier)?.text {
                send(text: text, image: nil, context: context)
            } else {
                bar.present(context: context, returningTo: foreign, waiting: waiting)
            }
        }
    }

    /// A selection or a screenshot, filed with a short confirmation by the pointer.
    private func send(text: String?, image: NSImage?, context: SourceContext) {
        var params: [String: Any] = ["text": text ?? "", "source": image == nil ? "selection" : "screenshot"]
        if let image {
            guard let name = Self.images.keep(image) else {
                services.toast.show("Couldn’t save the screenshot to the inbox", style: .warning)
                return
            }
            params["image"] = name
        }
        guard add(params, context: context) else { return }
        let snippet = text.map { "“\($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))…”" } ?? "Screenshot"
        services.toast.show("Added to Inbox", detail: [snippet, context.app].filter { !$0.isEmpty }.joined(separator: " · "), style: .success)
    }

    /// A GIF recording, copied in beside the screenshots.
    private func send(file url: URL, context: SourceContext) {
        let name = "\(UUID().uuidString).\(url.pathExtension.lowercased())"
        do {
            try FileManager.default.createDirectory(at: Self.images.url, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: Self.images.file(name))
        } catch {
            services.toast.show("Couldn’t add the recording to the inbox", detail: error.localizedDescription, style: .warning)
            return
        }
        guard add(["text": "", "image": name, "source": "screenshot"], context: context) else { return }
        services.toast.show("Added to Inbox", detail: ["Recording", context.app].filter { !$0.isEmpty }.joined(separator: " · "), style: .success)
    }

    @discardableResult
    private func add(_ params: [String: Any], context: SourceContext) -> Bool {
        let source: [String: Any] = ["app": context.app, "title": context.title, "url": context.url]
        do {
            _ = try services.core.call(.inboxAdd, params.merging(source) { mine, _ in mine })
            return true
        } catch {
            services.toast.show("Couldn’t add to the inbox", detail: error.localizedDescription, style: .warning)
            return false
        }
    }
}

/// Inbox settings: the shortcuts, and clearing everything.
@MainActor
final class InboxPane: SettingsPane {
    private let services: CopilotServices
    private lazy var shortcuts = ShortcutEditor(services: services)
    private let clearButton = Design.button("Clear Inbox…", target: nil, action: nil)
    private let folderButton = Design.button("Choose…", target: nil, action: nil)
    private let folderLabel = Design.label("", size: 12, color: .secondaryLabelColor)

    init(services: CopilotServices) {
        self.services = services
        super.init(id: "inbox", title: "Inbox", symbol: "tray")
    }

    required init?(coder: NSCoder) { fatalError("Use init(services:)") }

    override func makeSections() -> [NSView] {
        clearButton.target = self
        clearButton.action = #selector(clearAll)
        folderButton.target = self
        folderButton.action = #selector(chooseFolder)
        folderLabel.lineBreakMode = .byTruncatingMiddle
        folderLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        showFolder()
        return [
            shortcuts.section("Shortcuts", footer: "With text selected in any app, the first shortcut keeps it in the inbox; otherwise it opens a bar to jot into. In a screenshot, I sends the capture.",
                              actions: [InboxShell.Action.capture, InboxShell.Action.open]),
            shortcuts.errorLabel,
            FormSection("Send To", footer: "S on a note in the inbox sends it to Reminders, Notes, or this folder as a Markdown file (an Obsidian vault works well), then marks it done. L snoozes it until later.", rows: [
                FormRow("Markdown folder", accessory: Design.hstack([folderLabel, folderButton], spacing: 8))
            ]),
            FormSection("Notes", footer: "Notes and their screenshots stay on this Mac. Done notes are kept for 30 days.", rows: [
                FormRow("Remove every note, waiting and done", accessory: clearButton)
            ])
        ]
    }

    override func paneWillAppear() {
        shortcuts.refresh()
        showFolder()
    }

    private func showFolder() {
        let folder = NoteExport.markdownFolder(core: services.core, choosingIfNeeded: false)
        folderLabel.stringValue = folder.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? "Not chosen"
        folderLabel.toolTip = folder?.path
    }

    @objc private func chooseFolder() {
        NoteExport.chooseMarkdownFolder(core: services.core)
        showFolder()
    }

    @objc private func clearAll() {
        let alert = NSAlert()
        alert.messageText = "Clear the inbox?"
        alert.informativeText = "Every note, waiting and done, and its screenshot is removed."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard let window = view.window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            _ = try? self?.services.core.clearRecords(.inboxNotes)
            _ = try? self?.services.core.clearRecords(.inboxDone)
            _ = try? self?.services.core.clearRecords(.inboxSnoozed)
            InboxShell.images.removeAll()
        }
    }
}
