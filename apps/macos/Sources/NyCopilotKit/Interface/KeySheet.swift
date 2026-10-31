import AppKit

/// Keys, as a sheet you call up: `?` on a surface (⌘/ where you type) shows that surface's keys,
/// and the "Keyboard Shortcuts" shortcut shows every global one plus the verbs that work on
/// anything. Any key or click puts it away.
@MainActor
final class KeySheet {
    struct Group {
        let title: String
        let keys: [(String, String)]
    }

    static let shared = KeySheet()

    private(set) var panel: NSPanel?
    private var monitors: [Any] = []

    var isVisible: Bool { panel?.isVisible ?? false }

    /// Over `window` when given (one level above it, so it shows over a capture), else centered on
    /// the screen with the pointer.
    func toggle(_ title: String, groups: [Group], over window: NSWindow? = nil) {
        if isVisible { dismiss(); return }
        show(title, groups: groups, over: window)
    }

    func show(_ title: String, groups: [Group], over window: NSWindow? = nil) {
        dismiss()
        let panel = Self.makePanel(title, groups: groups, over: window)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; panel.animator().alphaValue = 1 }
        self.panel = panel
        watchForDismissal()
    }

    /// The sheet as a panel, placed but not shown.
    static func makePanel(_ title: String, groups: [Group], over window: NSWindow? = nil) -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.float(at: window.map { NSWindow.Level(rawValue: $0.level.rawValue + 1) } ?? .floating, shadow: true, clickThrough: false,
                    behavior: .transient)
        let material = NSVisualEffectView.roundedMaterial(.hudWindow, radius: 14)
        material.appearance = NSAppearance(named: .darkAqua)
        let heading = Design.label(title, size: 15, weight: .semibold)
        let columns = Self.columns(groups)
        let footer = Design.label(L("Any key closes this"), size: 11, color: .tertiaryLabelColor)
        let stack = Design.vstack([heading, columns, footer], spacing: 14)
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 22, bottom: 14, right: 22)
        stack.translatesAutoresizingMaskIntoConstraints = false
        material.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: material.topAnchor), stack.bottomAnchor.constraint(equalTo: material.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: material.leadingAnchor), stack.trailingAnchor.constraint(equalTo: material.trailingAnchor)
        ])
        panel.contentView = material
        let size = material.fittingSize
        let screen = window?.screen ?? ScreenGeometry.screen()
        let area = window.map { $0.frame.intersection(screen.visibleFrame) } ?? screen.visibleFrame
        let center = NSPoint(x: area.midX, y: area.midY)
        panel.setFrame(NSRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height), display: false)
        return panel
    }

    private func watchForDismissal() {
        // Put away by the next key or click, wherever the focus is; the key itself still does its job.
        let events: NSEvent.EventTypeMask = [.keyDown, .leftMouseDown, .rightMouseDown]
        if let local = NSEvent.addLocalMonitorForEvents(matching: events, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.dismiss() }
            // Esc and the sheet's own keys (?, ⌘/) only close it, rather than act on the surface beneath.
            let own = event.keyCode == 53 || event.charactersIgnoringModifiers == "?" || event.charactersIgnoringModifiers == "/"
            return event.type == .keyDown && own ? nil : event
        }) { monitors.append(local) }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }) { monitors.append(global) }
    }

    func dismiss() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        panel?.orderOut(nil)
        panel = nil
    }

    /// Groups in two columns, balanced by length.
    private static func columns(_ groups: [Group]) -> NSView {
        var left: [Group] = [], right: [Group] = []
        var leftCount = 0, rightCount = 0
        for group in groups {
            if leftCount <= rightCount { left.append(group); leftCount += group.keys.count + 2 }
            else { right.append(group); rightCount += group.keys.count + 2 }
        }
        let views = [left, right].filter { !$0.isEmpty }.map { column -> NSView in
            // The shorter column ends with space, rather than stretching its rows.
            Design.vstack(column.map(groupView) + [Design.spacer()], spacing: 14)
        }
        let row = Design.hstack(views, spacing: 32)
        row.alignment = .top
        return row
    }

    private static func groupView(_ group: Group) -> NSView {
        let title = Design.label(group.title.uppercased(), size: 10.5, weight: .semibold, color: .secondaryLabelColor)
        let grid = NSGridView(views: group.keys.map { key, meaning in
            let keyLabel = Design.label(key, size: 12, weight: .semibold)
            keyLabel.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
            return [keyLabel, Design.label(meaning, size: 12, color: .labelColor)]
        })
        grid.rowSpacing = 5
        grid.columnSpacing = 14
        grid.column(at: 0).xPlacement = .trailing
        // Every group's keys line up in one column.
        grid.column(at: 0).width = 84
        grid.setContentHuggingPriority(.required, for: .vertical)
        return Design.vstack([title, grid], spacing: 7)
    }
}

/// The keys of each surface, for its `?` sheet.
enum KeyGuide {
    static var verbs: KeySheet.Group { KeySheet.Group(title: L("On anything"), keys: Verb.allCases.map { ($0.key, $0.title) }) }

    static var capture: [KeySheet.Group] { [
        .init(title: L("Select"), keys: [("Tab", L("Windows ⇄ elements")), (L("drag"), L("Draw a region")), ("⌘A", L("Whole screen")),
                                      ("← → ↑ ↓", L("Nudge · ⇧ resize")), (", .", L("Earlier regions")), ("C", L("Copy the color"))]),
        .init(title: L("Finish"), keys: [("↩ / ⌘C", L("Copy")), ("⌘T", L("Pin")), ("⌘S", L("Save…  ·  ⇧⌘S quick")), ("Esc", L("Cancel"))]),
        .init(title: L("Do more"), keys: [("T", L("Select text in place")), ("S", L("Scrolling capture")), ("G", L("Record a GIF")), ("R", L("Translate its text")),
                                       ("I", L("Keep in Inbox")), ("A", L("Ask AI about it")), ("P", L("Pin to the screen"))]),
        .init(title: L("Draw"), keys: [("1–8", L("Rectangle … text")), ("⌘Z", L("Undo · ⇧⌘Z redo"))])
    ] }

    static var pin: [KeySheet.Group] { [
        .init(title: L("Pin"), keys: [(L("drag"), L("Move")), (L("scroll"), L("Zoom · ⌥ opacity")), ("0", L("Actual size")), ("1–4", L("Rotate, flip")),
                                   ("⌘C", L("Copy")), ("⌘S", L("Save")), ("Esc", L("Close"))]),
        .init(title: L("Do more"), keys: [("T", L("Select text in place")), ("R", L("Translate its text")), ("I", L("Keep in Inbox")), ("A", L("Ask AI about it"))])
    ] }

    static var clipboard: [KeySheet.Group] { [
        .init(title: L("Clipboard"), keys: [(L("type"), L("Search")), ("↩", L("Paste")), ("⌘1–9", L("Paste one of the first nine")), ("⌘C", L("Copy, don’t paste")),
                                         ("⌘P", L("Pin or unpin")), ("⌘⌫", L("Forget")), ("Esc", L("Close"))]),
        .init(title: L("Do more"), keys: [("⌘R", L("Translate")), ("⌘I", L("Keep in Inbox")), ("⌘A", L("Ask AI (search empty)"))])
    ] }

    static var inbox: [KeySheet.Group] { [
        .init(title: L("Work through"), keys: [(L("Space"), L("Done · back")), ("S", L("Send to Reminders, Notes, Markdown")), ("L", L("Later (snooze)")),
                                            ("↩", L("Edit")), ("⌫", L("Delete")), ("⌘Z", L("Undo")), ("⌘F", L("Search"))]),
        .init(title: L("Do more"), keys: [("R", L("Translate")), ("A", L("Ask AI")), ("P", L("Pin to the screen")), ("⌘C", L("Copy")), ("⌘O", L("Open the source"))])
    ] }

    static var ask: [KeySheet.Group] { [
        .init(title: L("Ask AI"), keys: [("↩", L("Ask · empty: explain")), ("⌘1–3", L("Explain, summarize, rewrite")), ("⌘C", L("Copy the answer")),
                                      ("⌘I", L("Keep it in Inbox")), ("⌘P", L("Pin it")), ("⌘↩", L("Replace the selection")), ("Esc", L("Close"))])
    ] }
}

/// A tip shown at the moment it's useful, a few times at most, then never again. Kept per Mac.
enum Tips {
    private static let key = "NyCopilotTips"

    /// Counts a use of `id`; true (and counts a showing) when the tip should show now — from the
    /// `after`th use on, at most `times` times in all.
    static func due(_ id: String, after uses: Int = 1, times: Int = 2) -> Bool {
        var state = UserDefaults.standard.dictionary(forKey: key) as? [String: [Int]] ?? [:]
        var counts = state[id] ?? [0, 0]
        counts[0] += 1
        let show = counts[0] >= uses && counts[1] < times
        if show { counts[1] += 1 }
        state[id] = counts
        UserDefaults.standard.set(state, forKey: key)
        return show
    }
}
