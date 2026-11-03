import AppKit

/// The two items Menu Bar puts in the menu bar, of which only one shows at a time. While icons
/// show, the divider is drawn as the ▸ arrow: the icons left of it are the ones that hide. Hiding
/// brings the chevron back right beside it, drawn as ◂, and makes the divider
/// `MenuBarState.hidingLength` wide, which pushes the icons left of it (and the divider itself)
/// past the left edge of the screen; macOS keeps their apps running and their places as they were.
/// One item can't do both: macOS doesn't draw an item that doesn't fit on screen, so it would
/// vanish with the icons. Items line up from the right, so the arrow stays in the same place.
@MainActor
final class MenuBarDivider: NSObject {
    var onToggle: () -> Void = {}
    var onSettings: () -> Void = {}
    /// Set while a click on the arrow opens the bar of hidden icons: its right-click menu then also
    /// offers showing them in the menu bar, where they can be ⌘-dragged.
    var onShowInMenuBar: (() -> Void)?

    private let divider: NSStatusItem
    private let chevron: NSStatusItem
    private var collapsed = false
    private var isOn = true
    private var whenPlaced: ((_ edges: (divider: CGFloat, chevron: CGFloat)?) -> Void)?
    private var whenShown: (() -> Void)?
    private var placement = 0
    private var placingSince = Date()
    private var moveObservers: [NSObjectProtocol] = []

    override init() {
        // Each new item goes left of the ones already there, so the first time, the divider lands
        // left of the chevron (and both left of NyCopilot's own icon). After that, macOS puts them
        // back where they were dragged, by name, including the chevron while it's out of the bar.
        chevron = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        chevron.autosaveName = "NyCopilot.MenuBar.Chevron"
        divider = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // Out of the bar when NyCopilot last quit (Menu Bar off), the divider comes back hidden
        // once it's named, and macOS deletes its place then: keep it first, and bring it back in.
        Self.keepPlace(of: Self.dividerName)
        divider.autosaveName = Self.dividerName
        super.init()
        if !divider.isVisible {
            Self.restorePlace(of: Self.dividerName)
            divider.isVisible = true
        }
        for item in [chevron, divider] {
            item.button?.target = self
            item.button?.action = #selector(clicked(_:))
            item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        chevron.button?.image = Self.arrow("chevron.left", L("Show Hidden Icons"))
        chevron.button?.toolTip = L("Show Hidden Icons")
        divider.button?.toolTip = L("Hide Menu Bar Icons") + "\n" + L("⌘-drag menu bar icons left of this arrow to hide them")
        show(collapsed: false)
    }

    var isVisible: Bool {
        get { isOn }
        // macOS remembers a hidden item by its name; it's shown again here, never left out.
        set {
            // Out of the bar, macOS forgets where both were; hidden icons need the chevron in sight.
            if newValue, !isOn {
                Self.restorePlace(of: Self.dividerName)
                if collapsed { placeChevronBesideDivider() }
            } else if !newValue, isOn {
                Self.keepPlace(of: Self.dividerName)
            }
            isOn = newValue
            divider.isVisible = newValue
            chevron.isVisible = newValue && collapsed
        }
    }

    /// Where the divider ends and the chevron starts, in screen x, once macOS has placed both. The
    /// divider grows to the left, so its right edge stays put whatever its length. Until an item is
    /// placed, its window sits just below the screen's bottom edge (measured: y −24).
    var edges: (divider: CGFloat, chevron: CGFloat)? {
        guard chevron.isVisible, let divider = divider.button?.window?.frame, let chevron = chevron.button?.window?.frame,
              divider.width > 0, chevron.width > 0, divider.maxY > 0, chevron.maxY > 0 else { return nil }
        return (divider.maxX, chevron.minX)
    }

    /// The divider's window, for telling hidden icons from the rest in the window list.
    var dividerWindow: CGWindowID? { (divider.button?.window?.windowNumber).map { CGWindowID($0) } }

    /// Where the arrow is while icons are hidden, in AppKit screen coordinates, once it's placed.
    var arrowFrame: NSRect? { edges != nil ? chevron.button?.window?.frame : nil }

    /// The menu bar's look, which other apps' icons are drawn for (light or dark, whatever the Mac's).
    var menuBarAppearance: NSAppearance? { chevron.button?.effectiveAppearance }

    /// Shows the icons and calls back once they're in the menu bar, to click one of them. The
    /// divider moves into place last (measured: 130–220 ms after showing, each time after every
    /// other app's icon was on screen; no event marks when theirs are).
    func show(then shown: @escaping () -> Void) {
        whenShown = shown
        placement += 1
        observeMoves()
        show(collapsed: false)
        let mine = placement
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            if self?.placement == mine { self?.shownMoved() }
        }
    }

    private func shownMoved() {
        guard let shown = whenShown, !collapsed else { return }
        whenShown = nil
        shown()
    }

    /// Hides at once and brings the chevron back beside the divider; once macOS has placed it,
    /// hands over where both are, so the hiding can be undone if the chevron didn't land right of
    /// the divider (where it would be hidden too). Growing first, rather than waiting for the
    /// chevron, keeps the icons from sliding left to make room for it before they go.
    func hide(_ placed: @escaping (_ edges: (divider: CGFloat, chevron: CGFloat)?) -> Void) {
        placeChevronBesideDivider()
        whenPlaced = placed
        whenShown = nil
        placement += 1
        placingSince = Date()
        show(collapsed: true)
        observeMoves()
        itemMoved(giveUp: false)
        // In case they never move.
        let mine = placement
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            if self?.placement == mine { self?.itemMoved(giveUp: true) }
        }
    }

    /// macOS places the chevron about 0.1 s after it comes back (measured), and says so by moving
    /// its window; just after launch, and whenever icons show, the divider is placed the same way.
    private func observeMoves() {
        guard moveObservers.isEmpty else { return }
        moveObservers = [chevron, divider].compactMap { $0.button?.window }.map { window in
            NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: window, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.itemMoved(giveUp: false)
                    if (note.object as? NSWindow) === self.divider.button?.window { self.shownMoved() }
                }
            }
        }
    }

    /// Hands over the edges once the chevron is right of the divider, or whatever there is when
    /// giving up. The chevron moves into place first and the divider makes room a moment later.
    private func itemMoved(giveUp: Bool) {
        let ready = edges.map { MenuBarState.canHide(divider: $0.divider, chevron: $0.chevron) } ?? false
        guard let placed = whenPlaced, giveUp || ready else { return }
        whenPlaced = nil
        Diagnostics.note("menubar", "chevron \(ready ? "placed" : "not placed") after \(Int(Date().timeIntervalSince(placingSince) * 1000)) ms")
        placed(edges)
    }

    /// Out of the menu bar, macOS forgets where an item was and would bring the chevron back at the
    /// far left. An item's place is kept in the app's defaults, by name, as its distance from the
    /// screen's right edge; the chevron gets one point less than the divider: right beside it.
    private func placeChevronBesideDivider() {
        let key = { (name: String) in "NSStatusItem Preferred Position \(name)" }
        let window = divider.button?.window
        guard let position = MenuBarState.chevronPosition(dividerSaved: UserDefaults.standard.object(forKey: key(divider.autosaveName)) as? Double,
                                                          dividerMaxX: window?.frame.maxX, screenMaxX: window?.screen?.frame.maxX) else { return }
        UserDefaults.standard.set(position, forKey: key(chevron.autosaveName))
    }

    func show(collapsed: Bool) {
        self.collapsed = collapsed
        chevron.isVisible = isOn && collapsed
        divider.length = MenuBarState.dividerLength(collapsed: collapsed)
        // Off screen there's nothing to draw.
        divider.button?.image = collapsed ? nil : Self.arrow("chevron.right", L("Hide Menu Bar Icons"))
    }

    func remove() {
        NSStatusBar.system.removeStatusItem(chevron)
        NSStatusBar.system.removeStatusItem(divider)
    }

    /// A click toggles; a right-click (or ⌃-click) offers the same and Settings.
    @objc private func clicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        guard event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true else { onToggle(); return }
        let item = sender === chevron.button ? chevron : divider
        let menu = NSMenu()
        menu.addItem(withTitle: collapsed ? L("Show Hidden Icons") : L("Hide Menu Bar Icons"), action: #selector(toggleFromMenu), keyEquivalent: "").target = self
        if collapsed, onShowInMenuBar != nil {
            menu.addItem(withTitle: L("Show Icons in the Menu Bar"), action: #selector(showInMenuBarFromMenu), keyEquivalent: "").target = self
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: L("Menu Bar Settings…"), action: #selector(settingsFromMenu), keyEquivalent: "").target = self
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    @objc private func toggleFromMenu() { onToggle() }
    @objc private func settingsFromMenu() { onSettings() }
    @objc private func showInMenuBarFromMenu() { onShowInMenuBar?() }

    private static let dividerName = "NyCopilot.MenuBar.Divider"
    private static func savedKey(_ name: String) -> String { "NSStatusItem Preferred Position \(name)" }
    private static func keptKey(_ name: String) -> String { "NyCopilot.KeptPosition.\(name)" }

    /// Before an item leaves the bar, where it is: macOS forgets it then.
    private static func keepPlace(of name: String) {
        guard let saved = UserDefaults.standard.object(forKey: savedKey(name)) as? Double else { return }
        UserDefaults.standard.set(saved, forKey: keptKey(name))
    }

    /// Before an item comes back, where it was kept, unless macOS has a place for it.
    private static func restorePlace(of name: String) {
        let defaults = UserDefaults.standard
        guard let position = MenuBarState.dividerPosition(saved: defaults.object(forKey: savedKey(name)) as? Double,
                                                          kept: defaults.object(forKey: keptKey(name)) as? Double) else { return }
        defaults.set(position, forKey: savedKey(name))
        Diagnostics.note("menubar", "arrow put back at \(Int(position)) from the right")
    }

    private static func arrow(_ symbol: String, _ description: String) -> NSImage? {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
        image?.isTemplate = true
        return image
    }
}
