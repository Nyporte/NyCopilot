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

    private var panel: NSPanel?
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
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.float(at: window.map { NSWindow.Level(rawValue: $0.level.rawValue + 1) } ?? .floating, shadow: true, clickThrough: false,
                    behavior: .transient)
        let material = NSVisualEffectView.roundedMaterial(.hudWindow, radius: 14)
        material.appearance = NSAppearance(named: .darkAqua)
        let heading = Design.label(title, size: 15, weight: .semibold)
        let columns = Self.columns(groups)
        let footer = Design.label("Any key closes this", size: 11, color: .tertiaryLabelColor)
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
        let screen = window?.screen ?? NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let area = window.map { $0.frame.intersection(screen.visibleFrame) } ?? screen.visibleFrame
        let center = NSPoint(x: area.midX, y: area.midY)
        panel.setFrame(NSRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height), display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; panel.animator().alphaValue = 1 }
        self.panel = panel
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
            Design.vstack(column.map(groupView), spacing: 14)
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
        return Design.vstack([title, grid], spacing: 7)
    }
}

/// The keys of each surface, for its `?` sheet.
enum KeyGuide {
    static let verbs = KeySheet.Group(title: "On anything", keys: Verb.allCases.map { ($0.key, $0.title) })

    static let capture: [KeySheet.Group] = [
        .init(title: "Select", keys: [("Tab", "Windows ⇄ elements"), ("drag", "Draw a region"), ("⌘A", "Whole screen"),
                                      ("← → ↑ ↓", "Nudge · ⇧ resize"), (", .", "Earlier regions"), ("C", "Copy the color")]),
        .init(title: "Finish", keys: [("↩ / ⌘C", "Copy"), ("⌘T", "Pin"), ("⌘S", "Save… · ⇧⌘S quick save"), ("Esc", "Cancel")]),
        .init(title: "Do more", keys: [("T", "Select text in place"), ("S", "Scrolling capture"), ("R", "Translate its text"),
                                       ("I", "Keep in Inbox"), ("A", "Ask AI about it"), ("P", "Pin to the screen")]),
        .init(title: "Draw", keys: [("1–8", "Rectangle … text"), ("⌘Z", "Undo · ⇧⌘Z redo")])
    ]

    static let pin: [KeySheet.Group] = [
        .init(title: "Pin", keys: [("drag", "Move"), ("scroll", "Zoom · ⌥ opacity"), ("0", "Actual size"), ("1–4", "Rotate, flip"),
                                   ("⌘C", "Copy"), ("⌘S", "Save"), ("Esc", "Close")]),
        .init(title: "Do more", keys: [("T", "Select text in place"), ("R", "Translate its text"), ("I", "Keep in Inbox"), ("A", "Ask AI about it")])
    ]

    static let clipboard: [KeySheet.Group] = [
        .init(title: "Clipboard", keys: [("type", "Search"), ("↩", "Paste"), ("⌘1–9", "Paste one of the first nine"), ("⌘C", "Copy, don’t paste"),
                                         ("⌘P", "Pin or unpin"), ("⌘⌫", "Forget"), ("Esc", "Close")]),
        .init(title: "Do more", keys: [("⌘R", "Translate"), ("⌘I", "Keep in Inbox"), ("⌘A", "Ask AI (search empty)")])
    ]

    static let inbox: [KeySheet.Group] = [
        .init(title: "Work through", keys: [("Space", "Done · back"), ("S", "Send to Reminders, Notes, Markdown"), ("L", "Later (snooze)"),
                                            ("↩", "Edit"), ("⌫", "Delete"), ("⌘Z", "Undo"), ("⌘F", "Search")]),
        .init(title: "Do more", keys: [("R", "Translate"), ("A", "Ask AI"), ("P", "Pin to the screen"), ("⌘C", "Copy"), ("⌘O", "Open the source")])
    ]

    static let ask: [KeySheet.Group] = [
        .init(title: "Ask AI", keys: [("↩", "Ask · empty: explain"), ("⌘1–3", "Explain, summarize, rewrite"), ("⌘C", "Copy the answer"),
                                      ("⌘I", "Keep it in Inbox"), ("⌘P", "Pin it"), ("⌘↩", "Replace the selection"), ("Esc", "Close")])
    ]
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
