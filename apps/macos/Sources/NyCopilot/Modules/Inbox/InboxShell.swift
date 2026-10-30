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
    static let imageFolder = Preferences.dataDirectory.appendingPathComponent("Inbox", isDirectory: true)
    private let bar = InboxCaptureBar()
    private var window: InboxWindow?

    init(services: CopilotServices) {
        self.services = services
        services.sendToInbox = { [weak self] text, image, app in
            Task { await self?.send(text: text, image: image, context: SourceContext.of(app)) }
        }
        bar.onSave = { [weak self] text, context in self?.add(["text": text, "source": "typed"], context: context) }
        bar.onOpenInbox = { [weak self] in self?.openInbox() }
        removeUnusedImages()
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
        bar.close(returningFocus: false)
        window?.forgetUndo()
    }

    private var waiting: Int { (try? services.core.call("inbox.count") as? [String: Any])?["count"] as? Int ?? 0 }

    @objc private func captureFromMenu() { capture() }
    @objc private func openFromMenu() { openInbox() }

    private func openInbox() {
        bar.close(returningFocus: false)
        if window == nil { window = InboxWindow(core: services.core, imageFolder: Self.imageFolder) }
        window?.present()
    }

    /// The selection, kept as it is; with nothing selected, the capture bar.
    private func capture() {
        if bar.isVisible { bar.close(); return }
        let app = NSWorkspace.shared.frontmostApplication
        let foreign = app.flatMap { $0.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : $0 }
        Task {
            let context = await SourceContext.of(foreign)
            if let foreign, Accessibility.isTrusted, let text = await Self.selectedText(in: foreign.processIdentifier) {
                send(text: text, image: nil, context: context)
            } else {
                bar.present(context: context, returningTo: foreign, waiting: waiting)
            }
        }
    }

    /// The selection, through Accessibility when the app describes it, or else by asking it to copy.
    private static func selectedText(in pid: pid_t) async -> String? {
        switch await InputTarget.selection(pid: pid) {
        case .text(let text, _): return text
        case .nothing: return nil
        case .unknown: return await InputTarget.copiedSelection(pid: pid)
        }
    }

    /// A selection or a screenshot, filed with a short confirmation by the pointer.
    private func send(text: String?, image: NSImage?, context: SourceContext) {
        var params: [String: Any] = ["text": text ?? "", "source": image == nil ? "selection" : "screenshot"]
        if let image {
            guard let name = Self.keep(image) else {
                services.toast.show("Couldn’t save the screenshot to the inbox", style: .warning)
                return
            }
            params["image"] = name
        }
        guard add(params, context: context) else { return }
        let snippet = text.map { "“\($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))…”" } ?? "Screenshot"
        services.toast.show("Added to Inbox", detail: [snippet, context.app].filter { !$0.isEmpty }.joined(separator: " · "), style: .success)
    }

    @discardableResult
    private func add(_ params: [String: Any], context: SourceContext) -> Bool {
        let source: [String: Any] = ["app": context.app, "title": context.title, "url": context.url]
        do {
            _ = try services.core.call("inbox.add", params.merging(source) { mine, _ in mine })
            return true
        } catch {
            services.toast.show("Couldn’t add to the inbox", detail: error.localizedDescription, style: .warning)
            return false
        }
    }

    /// The screenshot as a PNG in the inbox folder; its file name, or nil if it couldn't be written.
    private static func keep(_ image: NSImage) -> String? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let data = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) else { return nil }
        let name = "\(UUID().uuidString).png"
        do {
            try FileManager.default.createDirectory(at: imageFolder, withIntermediateDirectories: true)
            try data.write(to: imageFolder.appendingPathComponent(name), options: .atomic)
            return name
        } catch {
            return nil
        }
    }

    /// Screenshots no note uses any more — done notes past 30 days, notes deleted before a quit.
    private func removeUnusedImages() {
        struct Note: Decodable { let image: String? }
        var used: Set<String> = []
        for collection in [CoreCollection.inboxNotes, .inboxDone] {
            var before: String?
            repeat {
                var params: [String: Any] = ["collection": collection.rawValue, "limit": 500]
                if let before { params["before"] = before }
                guard let page = try? services.core.call("records.list", params, as: CorePage<Note>.self) else { return }
                used.formUnion(page.records.compactMap(\.data.image))
                before = page.next
            } while before != nil
        }
        for file in (try? FileManager.default.contentsOfDirectory(atPath: Self.imageFolder.path)) ?? [] where !used.contains(file) {
            try? FileManager.default.removeItem(at: Self.imageFolder.appendingPathComponent(file))
        }
    }
}

/// Inbox settings: the shortcuts, and clearing everything.
@MainActor
final class InboxPane: SettingsPane {
    private let services: CopilotServices
    private lazy var shortcuts = ShortcutEditor(services: services)
    private let clearButton = Design.button("Clear Inbox…", target: nil, action: nil)

    init(services: CopilotServices) {
        self.services = services
        super.init(id: "inbox", title: "Inbox", symbol: "tray")
    }

    required init?(coder: NSCoder) { fatalError("Use init(services:)") }

    override func makeSections() -> [NSView] {
        clearButton.target = self
        clearButton.action = #selector(clearAll)
        return [
            shortcuts.section("Shortcuts", footer: "With text selected in any app, the first shortcut keeps it in the inbox; otherwise it opens a bar to jot into. In a screenshot, I sends the capture.",
                              actions: [InboxShell.Action.capture, InboxShell.Action.open]),
            shortcuts.errorLabel,
            FormSection("Notes", footer: "Notes and their screenshots stay on this Mac. Done notes are kept for 30 days.", rows: [
                FormRow("Remove every note, waiting and done", accessory: clearButton)
            ])
        ]
    }

    override func paneWillAppear() { shortcuts.refresh() }

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
            _ = try? self?.services.core.call("records.clear", ["collection": CoreCollection.inboxNotes.rawValue])
            _ = try? self?.services.core.call("records.clear", ["collection": CoreCollection.inboxDone.rawValue])
            try? FileManager.default.removeItem(at: InboxShell.imageFolder)
        }
    }
}
