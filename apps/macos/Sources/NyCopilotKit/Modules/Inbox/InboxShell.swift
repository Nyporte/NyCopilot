import AppKit
import Carbon
import MacPlatform

/// macOS half of the Inbox module, one surface per job:
/// - F3 with text selected anywhere keeps the selection — no window, just a confirmation.
/// - F3 otherwise opens the capture bar to jot a thought and get back to work.
/// - ⇧F3 (or the menu, or ⌘O in the bar) opens the inbox window to work through notes.
/// Screenshots arrive through `CopilotServices.sendToInbox`. Every note keeps where it came from.
@MainActor
final class InboxShell: ModuleShell {
    let id = "inbox"
    let title = L("Inbox")
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
                let key = services.hotKeys.combination(for: Action.capture).map(KeyNames.display) ?? L("the shortcut")
                services.toast.show(L("Saved to Inbox"), detail: L("Tip: select text in any app and press %@ to keep it without typing.", key), style: .success)
            }
        }
        bar.onOpenInbox = { [weak self] in self?.openInbox() }
        // Finding unused screenshots reads every note: after launch, not during it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [core = services.core] in
            Self.images.removeUnused(core: core, collections: [.inboxNotes, .inboxDone, .inboxSnoozed])
        }
        // Snoozed notes come back on time, or at launch (or wake) when they fell due meanwhile.
        wakeDueNotes()
        snoozeChanges = services.core.observe { [weak self] event in
            if event.changedCollection == CoreCollection.inboxSnoozed.rawValue { self?.scheduleAlarm() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.wakeDueNotes() }
        }
    }

    /// Kept until shutdown: they set the alarm for the next snoozed note.
    private var snoozeChanges: CoreObservation?
    private var wakeObserver: NSObjectProtocol?

    /// One timer, for the next snoozed note that's due — none while nothing is snoozed.
    private func scheduleAlarm() {
        alarm?.invalidate()
        alarm = nil
        struct Snoozed: Decodable { let until: Int64? }
        let page = try? services.core.records(.inboxSnoozed, as: Snoozed.self, limit: 500)
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
        let defaults = Self.shortcuts(in: .functionKeys)
        return [.init(id: Action.capture, title: L("Jot something down, or keep the selection"),
                      defaultCombination: defaults[Action.capture], handler: { [weak self] in self?.capture() }),
                .init(id: Action.open, title: L("Open the inbox"),
                      defaultCombination: defaults[Action.open], handler: { [weak self] in self?.openInbox() })]
    }

    /// F3 and ⇧F3, or ⌥⌘J and ⌥⌘⇧J.
    nonisolated static func shortcuts(in scheme: KeyScheme) -> [String: HotKeyCombination] {
        let (key, modifiers) = scheme == .functionKeys ? (kVK_F3, UInt32(0)) : (kVK_ANSI_J, KeyScheme.letterModifiers)
        return [Action.capture: .init(keyCode: UInt32(key), modifiers: modifiers),
                Action.open: .init(keyCode: UInt32(key), modifiers: modifiers | HotKeyCombination.shift)]
    }

    func menuItems() -> [NSMenuItem] {
        [services.menuItem(L("Jot Down…"), symbol: "square.and.pencil", hotKey: Action.capture, target: self, action: #selector(captureFromMenu)),
         services.menuItem(waiting > 0 ? L("Inbox (%ld)", waiting) : L("Inbox"), symbol: waiting > 0 ? "tray.full" : "tray",
                           hotKey: Action.open, target: self, action: #selector(openFromMenu))]
    }

    func makeSettingsPane() -> SettingsPane? { InboxPane(services: services) }

    func shutdown() {
        alarm?.invalidate()
        snoozeChanges?.cancel()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        bar.close(returningFocus: false)
        window?.forgetUndo()
    }

    private var waiting: Int { services.core.inboxCount() }

    private func wakeDueNotes() {
        defer { scheduleAlarm() }
        guard let woken = try? services.core.inboxWake(), !woken.isEmpty else { return }
        let first = woken[0].text?
            .split(whereSeparator: \.isNewline).first.map { L("“%@”", String($0.prefix(50))) } ?? L("A snoozed note")
        services.toast.show(woken.count == 1 ? L("Back in your inbox") : L("%ld notes are back in your inbox", woken.count),
                            detail: woken.count == 1 ? first : L("%@ and more · ⇧F3 to open", first), style: .info)
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
                services.toast.show(L("Couldn’t save the screenshot to the inbox"), style: .warning)
                return
            }
            params["image"] = name
        }
        guard add(params, context: context) else { return }
        let snippet = text.map { "“\($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))…”" } ?? L("Screenshot")
        services.toast.show(L("Added to Inbox"), detail: [snippet, context.app].filter { !$0.isEmpty }.joined(separator: " · "), style: .success)
    }

    /// A GIF recording, beside the screenshots. The file moves into the inbox's folder: it's a
    /// temporary recording no one else keeps.
    private func send(file url: URL, context: SourceContext) {
        let name: String
        do {
            name = try Self.images.keep(moving: url)
        } catch {
            services.toast.show(L("Couldn’t add the recording to the inbox"), detail: error.localizedDescription, style: .warning)
            return
        }
        guard add(["text": "", "image": name, "source": "screenshot"], context: context) else { return }
        services.toast.show(L("Added to Inbox"), detail: [L("Recording"), context.app].filter { !$0.isEmpty }.joined(separator: " · "), style: .success)
    }

    @discardableResult
    private func add(_ params: [String: Any], context: SourceContext) -> Bool {
        let source: [String: Any] = ["app": context.app, "title": context.title, "url": context.url]
        do {
            try services.core.inboxAdd(params.merging(source) { mine, _ in mine })
            return true
        } catch {
            services.toast.show(L("Couldn’t add to the inbox"), detail: error.localizedDescription, style: .warning)
            return false
        }
    }
}
