import AppKit

/// What the menu bar divider should do, worked out from settings and geometry alone so it can be
/// tested without a menu bar. The divider hides the icons to its left by growing so wide that they
/// no longer fit on any screen; while they show, it's a thin line.
struct MenuBarState: Equatable {
    /// The divider is in the menu bar: the module and its own switch are both on.
    var isOn: Bool
    /// The icons left of the divider are hidden.
    var collapsed: Bool
    /// Seconds shown icons stay before they hide again; 0 leaves them shown.
    var collapseAfter: TimeInterval

    /// Wide enough to carry every icon left of the divider past the left edge of the widest display.
    static let hidingLength: CGFloat = 10_000
    /// A thin line with room either side to ⌘-drag an icon past it.
    static let lineLength: CGFloat = 12
    /// What Settings offers for hiding shown icons again; 0 is never.
    static let collapseAfterChoices: [TimeInterval] = [5, 10, 30, 60, 0]

    var dividerLength: CGFloat { Self.dividerLength(collapsed: collapsed) }

    static func dividerLength(collapsed: Bool) -> CGFloat { collapsed ? hidingLength : lineLength }

    /// How long until shown icons hide again, or nil when they stay as they are.
    var hideAgainIn: TimeInterval? { isOn && !collapsed && collapseAfter > 0 ? collapseAfter : nil }

    @MainActor
    static func read(_ core: NyCore, moduleOn: Bool) -> MenuBarState {
        MenuBarState(isOn: moduleOn && core.setting(.menuBarEnabled, default: false),
                     collapsed: core.setting(.menuBarCollapsed, default: false),
                     collapseAfter: core.setting(.menuBarCollapseAfter, default: 10.0))
    }

    /// Hiding is safe only while the divider ends left of where the chevron starts (in screen x).
    /// Otherwise the chevron would be pushed off the screen with the icons, and nothing in the menu
    /// bar could bring them back.
    static func canHide(divider: CGFloat, chevron: CGFloat) -> Bool { divider <= chevron + 1 }

    /// `point` is on the menu bar of a screen with `frame` and `visibleFrame` — then icons about to
    /// be clicked shouldn't vanish. The menu bar is as tall as the space above the visible frame
    /// (taller beside a notch), or the status bar's thickness while it's hidden.
    static func isOnMenuBar(_ point: CGPoint, frame: CGRect, visibleFrame: CGRect, thickness: CGFloat) -> Bool {
        let height = max(thickness, frame.maxY - visibleFrame.maxY)
        return (frame.minX...frame.maxX).contains(point.x) && (frame.maxY - height...frame.maxY).contains(point.y)
    }
}
