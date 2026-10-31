import AppKit

/// The capture overlay takes keys without making NyCopilot the active app, so the app you were in
/// keeps its focus — its window doesn't turn inactive and redraw under the frozen screen. macOS
/// ignores cursor changes from an app that isn't active unless its window-server connection says
/// otherwise; this sets that, once, so the crosshair still shows.
enum BackgroundCursor {
    private typealias ConnectionID = Int32
    @_silgen_name("_CGSDefaultConnection") private static func defaultConnection() -> ConnectionID
    @_silgen_name("CGSSetConnectionProperty")
    private static func setConnectionProperty(_ connection: ConnectionID, _ target: ConnectionID, _ key: CFString, _ value: CFTypeRef) -> Int32

    private static var allowed = false

    @MainActor
    static func allow() {
        guard !allowed else { return }
        allowed = true
        let connection = defaultConnection()
        let status = setConnectionProperty(connection, connection, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
        if status != 0 { Diagnostics.note("capture", "couldn’t set the cursor from the background (\(status))") }
    }
}
