import AppKit

/// The two items Menu Bar puts in the menu bar: a divider, and right of it a chevron that hides or
/// shows the icons left of the divider. Hiding makes the divider `MenuBarState.hidingLength` wide,
/// which pushes those icons past the left edge of the screen; macOS keeps their apps running and
/// their places as they were. (The chevron can't do this alone: an item that doesn't fit on screen
/// isn't drawn at all.) Shown, the divider is a narrow empty gap whose line appears only while ⌘ is
/// held, which is when icons are ⌘-dragged past it; its width never changes, so nothing moves.
@MainActor
final class MenuBarDivider: NSObject {
    var onToggle: () -> Void = {}
    var onSettings: () -> Void = {}

    private let divider: NSStatusItem
    private let chevron: NSStatusItem
    private var collapsed = false
    private var commandHeld = false
    private var monitors: [Any] = []

    override init() {
        // Each new item goes left of the ones already there, so the first time, the divider lands
        // left of the chevron (and both left of NyCopilot's own icon). After that, macOS puts them
        // back where they were dragged, by name.
        chevron = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        chevron.autosaveName = "NyCopilot.MenuBar.Chevron"
        divider = NSStatusBar.system.statusItem(withLength: MenuBarState.lineLength)
        divider.autosaveName = "NyCopilot.MenuBar.Divider"
        super.init()
        for item in [chevron, divider] {
            item.button?.target = self
            item.button?.action = #selector(clicked)
            item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        divider.button?.toolTip = L("⌘-drag menu bar icons left of this line to hide them")
        // Seeing ⌘ in other apps needs Accessibility, which NyCopilot asks for anyway; without it
        // the line just stays.
        let watch: (NSEvent) -> Void = { [weak self] event in
            MainActor.assumeIsolated { self?.setCommandHeld(event.modifierFlags.contains(.command)) }
        }
        monitors = [NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: watch),
                    NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { watch($0); return $0 }].compactMap { $0 }
        show(collapsed: false)
    }

    var isVisible: Bool {
        get { chevron.isVisible }
        // macOS remembers a hidden item by its name; it's shown again here, never left out.
        set { chevron.isVisible = newValue; divider.isVisible = newValue }
    }

    /// Where the divider ends and the chevron starts, in screen x, once macOS has placed them. The
    /// divider grows to the left, so its right edge stays put whatever its length.
    var edges: (divider: CGFloat, chevron: CGFloat)? {
        guard let divider = divider.button?.window?.frame, let chevron = chevron.button?.window?.frame,
              divider.width > 0, chevron.width > 0 else { return nil }
        return (divider.maxX, chevron.minX)
    }

    func show(collapsed: Bool) {
        self.collapsed = collapsed
        divider.length = MenuBarState.dividerLength(collapsed: collapsed)
        showLine()
        let image = NSImage(systemSymbolName: collapsed ? "chevron.left" : "chevron.right",
                            accessibilityDescription: collapsed ? L("Show Hidden Icons") : L("Hide Menu Bar Icons"))?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
        image?.isTemplate = true
        chevron.button?.image = image
        chevron.button?.toolTip = collapsed ? L("Show Hidden Icons") : L("Hide Menu Bar Icons")
    }

    func remove() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        NSStatusBar.system.removeStatusItem(chevron)
        NSStatusBar.system.removeStatusItem(divider)
    }

    private func setCommandHeld(_ held: Bool) {
        guard held != commandHeld else { return }
        commandHeld = held
        showLine()
    }

    /// Off screen there's nothing to draw; on screen, the line shows while ⌘ is held, or always
    /// when NyCopilot can't see ⌘.
    private func showLine() {
        let visible = MenuBarState.showsLine(collapsed: collapsed, commandHeld: commandHeld, canSeeCommand: Accessibility.isTrusted)
        divider.button?.image = visible ? Self.line : nil
    }

    /// A click toggles; a right-click (or ⌃-click) offers the same and Settings.
    @objc private func clicked() {
        let event = NSApp.currentEvent
        guard event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true else { onToggle(); return }
        let menu = NSMenu()
        menu.addItem(withTitle: collapsed ? L("Show Hidden Icons") : L("Hide Menu Bar Icons"), action: #selector(toggleFromMenu), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: L("Menu Bar Settings…"), action: #selector(settingsFromMenu), keyEquivalent: "").target = self
        chevron.menu = menu
        chevron.button?.performClick(nil)
        chevron.menu = nil
    }

    @objc private func toggleFromMenu() { onToggle() }
    @objc private func settingsFromMenu() { onSettings() }

    /// A short rounded line, drawn in the menu bar's text color.
    private static let line: NSImage = {
        let image = NSImage(size: NSSize(width: 2, height: 16), flipped: false) { rect in
            NSColor.black.withAlphaComponent(0.55).set()
            NSBezierPath(roundedRect: rect.insetBy(dx: 0.25, dy: 0), xRadius: 0.75, yRadius: 0.75).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = L("Menu bar divider")
        return image
    }()
}
