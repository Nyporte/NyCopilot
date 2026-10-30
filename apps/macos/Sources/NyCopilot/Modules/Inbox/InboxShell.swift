import AppKit
import MacPlatform

/// macOS half of the Inbox module. F10 with text selected anywhere sends it to the inbox; F10
/// otherwise opens the panel to jot into. Screenshots arrive through `CopilotServices.sendToInbox`.
@MainActor
final class InboxShell: ModuleShell {
    let id = "inbox"
    let title = "Inbox"
    let symbolName = "tray"

    enum Action {
        static let open = "inbox.open"
    }

    private let services: CopilotServices
    /// Screenshots in notes, as `<uuid>.png` beside the database.
    static let imageFolder = Preferences.dataDirectory.appendingPathComponent("Inbox", isDirectory: true)
    private lazy var panel = InboxPanel(core: services.core, imageFolder: Self.imageFolder)

    init(services: CopilotServices) {
        self.services = services
        services.sendToInbox = { [weak self] text, image, app in self?.send(text: text, image: image, app: app) }
    }

    var hotKeyActions: [HotKeyCenter.Action] {
        [.init(id: Action.open, title: "Open the inbox, or send the selection to it",
               defaultCombination: .init(keyCode: 109, modifiers: 0), // F10
               handler: { [weak self] in self?.summon() })]
    }

    func menuItems() -> [NSMenuItem] {
        let count = (try? services.core.call("inbox.count") as? [String: Any])?["count"] as? Int ?? 0
        return [services.menuItem(count > 0 ? "Inbox (\(count))" : "Inbox", symbol: count > 0 ? "tray.full" : "tray",
                                  hotKey: Action.open, target: self, action: #selector(openFromMenu))]
    }

    func makeSettingsPane() -> SettingsPane? { InboxPane(services: services) }

    func shutdown() { panel.close(returningFocus: false) }

    @objc private func openFromMenu() { panel.present(returningTo: NSWorkspace.shared.frontmostApplication) }

    /// Selected text goes straight in; with nothing selected, the panel opens.
    private func summon() {
        if panel.isVisible { panel.close(); return }
        let app = NSWorkspace.shared.frontmostApplication
        guard let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier, Accessibility.isTrusted else {
            panel.present(returningTo: app)
            return
        }
        Task {
            if let text = await Self.selectedText(in: app.processIdentifier) {
                send(text: text, image: nil, app: app.localizedName ?? "", source: "selection")
            } else {
                panel.present(returningTo: app)
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

    /// A note from elsewhere — a selection, a screenshot — with a short confirmation by the pointer.
    private func send(text: String?, image: NSImage?, app: String, source: String? = nil) {
        var params: [String: Any] = ["text": text ?? "", "app": app, "source": source ?? (image == nil ? "selection" : "screenshot")]
        if let image {
            guard let name = Self.keep(image) else {
                services.toast.show("Couldn’t save the screenshot to the inbox", style: .warning)
                return
            }
            params["image"] = name
        }
        do {
            _ = try services.core.call("inbox.add", params)
            services.toast.show("Added to Inbox", detail: text.map { String($0.prefix(60)) }, style: .success)
        } catch {
            services.toast.show("Couldn’t add to the inbox", detail: error.localizedDescription, style: .warning)
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
}

/// Inbox settings: the shortcut, and clearing everything.
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
            shortcuts.section("Shortcuts", footer: "With text selected in any app, the shortcut sends it to the inbox; otherwise it opens the inbox to jot into. In a screenshot, I sends the capture.",
                              actions: [InboxShell.Action.open]),
            shortcuts.errorLabel,
            FormSection("Notes", footer: "Notes and their screenshots stay on this Mac.", rows: [
                FormRow("Remove every note", accessory: clearButton)
            ])
        ]
    }

    override func paneWillAppear() { shortcuts.refresh() }

    @objc private func clearAll() {
        let alert = NSAlert()
        alert.messageText = "Clear the inbox?"
        alert.informativeText = "Every note and its screenshot is removed."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard let window = view.window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            _ = try? self?.services.core.call("records.clear", ["collection": CoreCollection.inboxNotes.rawValue])
            try? FileManager.default.removeItem(at: InboxShell.imageFolder)
        }
    }
}
