import AppKit

/// What the menu bar divider should do, worked out from settings and geometry alone so it can be
/// tested without a menu bar. The divider hides the icons to its left by growing so wide that they
/// no longer fit on any screen; while they show, it's the arrow, sized to fit.
struct MenuBarState: Equatable {
    /// The divider is in the menu bar: the module and its own switch are both on.
    var isOn: Bool
    /// The icons left of the divider are hidden.
    var collapsed: Bool
    /// Seconds shown icons stay before they hide again; 0 leaves them shown.
    var collapseAfter: TimeInterval
    /// Hidden icons show in a bar under the menu bar rather than in it.
    var showInBar = false

    /// Wide enough to carry every icon left of the divider past the left edge of the widest display.
    static let hidingLength: CGFloat = 10_000
    /// The arrow, as wide as its image. (No item is narrower than 16 pt: macOS pads every one.)
    static let shownLength = NSStatusItem.variableLength
    /// What Settings offers for hiding shown icons again; 0 is never.
    static let collapseAfterChoices: [TimeInterval] = [5, 10, 30, 60, 0]

    var dividerLength: CGFloat { Self.dividerLength(collapsed: collapsed) }

    /// A click on the arrow (or the shortcut) opens the bar instead of showing the icons in place.
    var opensBar: Bool { isOn && collapsed && showInBar }

    static func dividerLength(collapsed: Bool) -> CGFloat { collapsed ? hidingLength : shownLength }

    /// How long until shown icons hide again, or nil when they stay as they are.
    var hideAgainIn: TimeInterval? { isOn && !collapsed && collapseAfter > 0 ? collapseAfter : nil }

    @MainActor
    static func read(_ core: NyCore, moduleOn: Bool) -> MenuBarState {
        MenuBarState(isOn: moduleOn && core.setting(.menuBarEnabled, default: false),
                     collapsed: core.setting(.menuBarCollapsed, default: false),
                     collapseAfter: core.setting(.menuBarCollapseAfter, default: 10.0),
                     showInBar: core.setting(.menuBarShowInBar, default: false))
    }

    /// Where the chevron goes when it comes back: one point closer to the right edge than the
    /// divider, which puts it right beside it. The divider's place is the one macOS saved, or else
    /// where it is now (measured on macOS 14: a saved 331 was exactly 1920 − 1589, its right edge).
    static func chevronPosition(dividerSaved: Double?, dividerMaxX: CGFloat?, screenMaxX: CGFloat?) -> Double? {
        if let dividerSaved { return dividerSaved - 1 }
        guard let dividerMaxX, let screenMaxX, dividerMaxX > 0 else { return nil }
        return Double(screenMaxX - dividerMaxX) - 1
    }

    /// An item of NyCopilot's own that must stay in sight (the clock) would hide with the icons:
    /// it ends where the divider ends, or left of it.
    static func wouldHide(itemMaxX: CGFloat, dividerMaxX: CGFloat) -> Bool { itemMaxX <= dividerMaxX + 1 }

    /// Where such an item goes instead: right beside the chevron, so the arrow stays next to the
    /// icons it hides. Half a point, since saved places are whole numbers.
    static func inSightPosition(chevron: Double) -> Double { chevron - 0.5 }

    /// Hiding is safe only while the divider ends left of where the chevron starts (in screen x).
    /// Otherwise the chevron would be pushed off the screen with the icons, and nothing in the menu
    /// bar could bring them back.
    static func canHide(divider: CGFloat, chevron: CGFloat) -> Bool { divider <= chevron + 1 }

    /// The place to give the divider before it comes back into the bar, or nil to leave it where
    /// it is: macOS deletes an item's `saved` place while it's out of the bar, so the one NyCopilot
    /// `kept` before it left goes back, unless macOS has a place for it again.
    static func dividerPosition(saved: Double?, kept: Double?) -> Double? { saved == nil ? kept : nil }

    /// `point` is on the menu bar of a screen with `frame` and `visibleFrame` — then icons about to
    /// be clicked shouldn't vanish. The menu bar is as tall as the space above the visible frame
    /// (taller beside a notch), or the status bar's thickness while it's hidden.
    static func isOnMenuBar(_ point: CGPoint, frame: CGRect, visibleFrame: CGRect, thickness: CGFloat) -> Bool {
        let height = max(thickness, frame.maxY - visibleFrame.maxY)
        return (frame.minX...frame.maxX).contains(point.x) && (frame.maxY - height...frame.maxY).contains(point.y)
    }
}
