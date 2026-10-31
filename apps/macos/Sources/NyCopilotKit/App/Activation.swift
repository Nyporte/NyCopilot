import AppKit

extension NSApplication {
    /// Brings NyCopilot forward for a window that needs it (Settings, History, the inbox, a save
    /// panel). Quick panels never call this: they take keys without activating (see FloatingPanel).
    ///
    /// This is the one place activation is requested, and it asks the old way on purpose: macOS 14's
    /// cooperative `activate()` may decline a request that comes from a global shortcut pressed
    /// while another app is in front — exactly how NyCopilot is used.
    func bringForward() {
        activate(ignoringOtherApps: true)
    }
}
