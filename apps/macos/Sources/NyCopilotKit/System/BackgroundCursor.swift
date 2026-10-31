import AppKit

/// The capture overlay takes keys without making NyCopilot the active app, so the app you were in
/// keeps its focus — its window doesn't turn inactive and redraw under the frozen screen. macOS
/// ignores cursor changes from an app that isn't active unless its window-server connection says
/// otherwise; this sets that, once, so the crosshair still shows.
///
/// The functions are private to macOS, so they're looked up when needed rather than linked: if a
/// future macOS drops them, NyCopilot still launches, and the capture activates the app instead.
enum BackgroundCursor {
    private typealias DefaultConnection = @convention(c) () -> Int32
    private typealias SetProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32

    @MainActor private static var result: Bool?

    /// Whether the cursor can be set from the background; false means the caller should activate.
    @MainActor
    @discardableResult
    static func allow() -> Bool {
        if let result { return result }
        let handle = dlopen(nil, RTLD_NOW)
        guard let connectionSymbol = dlsym(handle, "_CGSDefaultConnection"),
              let propertySymbol = dlsym(handle, "CGSSetConnectionProperty") else {
            Diagnostics.note("capture", "background cursor unavailable; activating instead")
            result = false
            return false
        }
        let connection = unsafeBitCast(connectionSymbol, to: DefaultConnection.self)()
        let status = unsafeBitCast(propertySymbol, to: SetProperty.self)(connection, connection, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
        if status != 0 { Diagnostics.note("capture", "couldn’t set the cursor from the background (\(status))") }
        result = status == 0
        return status == 0
    }
}
