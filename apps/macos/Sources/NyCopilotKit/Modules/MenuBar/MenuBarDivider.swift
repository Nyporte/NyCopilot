import AppKit

/// The two items Menu Bar puts in the menu bar: a thin divider, and right of it a chevron that
/// hides or shows the icons left of the divider. Hiding makes the divider `MenuBarState.hidingLength`
/// wide, which pushes those icons past the left edge of the screen; macOS keeps their apps running
/// and their places as they were.
@MainActor
final class MenuBarDivider: NSObject {
    var onToggle: () -> Void = {}
    var onSettings: () -> Void = {}

    private let divider: NSStatusItem
    private let chevron: NSStatusItem
    private var collapsed = false

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
        divider.button?.image = Self.line
        divider.button?.toolTip = L("⌘-drag menu bar icons left of this line to hide them")
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
        // Off screen there's nothing to draw.
        divider.button?.image = collapsed ? nil : Self.line
        let image = NSImage(systemSymbolName: collapsed ? "chevron.left" : "chevron.right",
                            accessibilityDescription: collapsed ? L("Show Hidden Icons") : L("Hide Menu Bar Icons"))?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
        image?.isTemplate = true
        chevron.button?.image = image
        chevron.button?.toolTip = collapsed ? L("Show Hidden Icons") : L("Hide Menu Bar Icons")
    }

    func remove() {
        NSStatusBar.system.removeStatusItem(chevron)
        NSStatusBar.system.removeStatusItem(divider)
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
