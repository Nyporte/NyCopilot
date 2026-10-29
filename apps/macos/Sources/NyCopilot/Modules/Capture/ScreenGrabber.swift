import AppKit
import ScreenCaptureKit

/// One display frozen at the moment a capture starts: its pixels and the windows on it, so the
/// selection UI works on a still image while the real screen keeps running underneath.
struct FrozenScreen {
    let screen: NSScreen
    let image: CGImage
    /// On-screen windows, front to back, in this screen's flipped view coordinates (top-left origin).
    let windows: [CGRect]

    var scale: CGFloat { CGFloat(image.width) / screen.frame.width }
}

/// Screen Recording permission and whole-display capture.
enum ScreenGrabber {
    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Shows the system prompt the first time; afterwards macOS only offers System Settings.
    static func requestPermission() {
        if !CGRequestScreenCaptureAccess() {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
    }

    /// Every display, captured as close to the same instant as possible.
    static func freezeAll() async throws -> [FrozenScreen] {
        let windows = visibleWindows()
        var frozen: [FrozenScreen] = []
        for screen in NSScreen.screens {
            guard let image = try await capture(screen) else { continue }
            frozen.append(FrozenScreen(screen: screen, image: image, windows: windows.compactMap { local($0, on: screen) }))
        }
        guard !frozen.isEmpty else { throw Failure.captureFailed }
        return frozen
    }

    private static func capture(_ screen: NSScreen) async throws -> CGImage? {
        guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return nil }
        if #available(macOS 14.0, *) {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == id }) else { return nil }
            // NyCopilot's own windows (pins included) are left out, so they never end up in a capture.
            let own = content.windows.filter { $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier }
            let configuration = SCStreamConfiguration()
            configuration.width = Int(screen.frame.width * screen.backingScaleFactor)
            configuration.height = Int(screen.frame.height * screen.backingScaleFactor)
            configuration.showsCursor = false
            configuration.captureResolution = .best
            return try await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(display: display, excludingWindows: own), configuration: configuration)
        }
        return CGDisplayCreateImage(id)
    }

    /// Normal windows, menus, and the Dock, front to back, in global top-left coordinates.
    private static func visibleWindows() -> [CGRect] {
        let own = ProcessInfo.processInfo.processIdentifier
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.compactMap { info in
            guard (info[kCGWindowOwnerPID as String] as? pid_t) != own,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0.05,
                  (info[kCGWindowLayer as String] as? Int ?? 0) < Int(CGWindowLevelForKey(.screenSaverWindow)),
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  rect.width >= 8, rect.height >= 8 else { return nil }
            return rect
        }
    }

    /// Global top-left coordinates → this screen's flipped view coordinates, clipped to the screen.
    private static func local(_ rect: CGRect, on screen: NSScreen) -> CGRect? {
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        let origin = CGPoint(x: screen.frame.minX, y: primaryHeight - screen.frame.maxY)
        let moved = rect.offsetBy(dx: -origin.x, dy: -origin.y)
        let clipped = moved.intersection(CGRect(origin: .zero, size: screen.frame.size))
        return clipped.isNull || clipped.width < 8 || clipped.height < 8 ? nil : clipped
    }

    enum Failure: LocalizedError {
        case captureFailed
        var errorDescription: String? { "macOS didn’t return an image of the screen." }
    }
}
