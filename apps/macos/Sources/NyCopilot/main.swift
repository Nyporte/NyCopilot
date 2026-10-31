import AppKit

/// NyCopilot runs as a menu bar accessory: no Dock icon, one process, the Rust core linked in.
@main
struct AppMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
