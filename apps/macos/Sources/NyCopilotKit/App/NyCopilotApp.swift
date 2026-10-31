import AppKit

/// NyCopilot runs as a menu bar accessory: no Dock icon, one process, the Rust core linked in.
/// The executable only calls `run()`; everything else lives in this library, where tests can reach it.
public enum NyCopilotApp {
    @MainActor
    public static func run() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
