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

    /// Every display, captured as close to the same instant as possible. With `hidingOwnWindows`,
    /// NyCopilot's windows (pins included) are left out of both the pixels and window detection.
    static func freezeAll(hidingOwnWindows: Bool) async throws -> [FrozenScreen] {
        let windows = visibleWindows(includingOwn: !hidingOwnWindows)
        // One lookup serves every display.
        var content: SCShareableContent?
        if #available(macOS 14.0, *) { content = try await shareableContent(reusingRecent: false) }
        var frozen: [FrozenScreen] = []
        for screen in NSScreen.screens {
            guard let image = try await capture(screen, hidingOwnWindows: hidingOwnWindows, content: content) else { continue }
            frozen.append(FrozenScreen(screen: screen, image: image, windows: windows.compactMap { local($0, on: screen) }))
        }
        guard !frozen.isEmpty else { throw Failure.captureFailed }
        return frozen
    }

    /// The displays, apps, and windows ScreenCaptureKit can see. The lookup takes a noticeable moment,
    /// so a scrolling capture started from F1 reuses the one F1 just made.
    @MainActor private static var recentContent: SCShareableContent?

    @MainActor
    static func shareableContent(reusingRecent: Bool) async throws -> SCShareableContent {
        if reusingRecent, let recentContent { return recentContent }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        recentContent = content
        return content
    }

    private static func capture(_ screen: NSScreen, hidingOwnWindows: Bool, content: SCShareableContent?) async throws -> CGImage? {
        guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return nil }
        if #available(macOS 14.0, *), let content {
            guard let display = content.displays.first(where: { $0.displayID == id }) else { return nil }
            let own = hidingOwnWindows
                ? content.windows.filter { $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier } : []
            let configuration = SCStreamConfiguration()
            configuration.width = Int(screen.frame.width * screen.backingScaleFactor)
            configuration.height = Int(screen.frame.height * screen.backingScaleFactor)
            configuration.showsCursor = false
            configuration.captureResolution = .best
            return try await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(display: display, excludingWindows: own), configuration: configuration)
        }
        guard hidingOwnWindows else { return CGDisplayCreateImage(id) }
        // macOS 13: compose the display from every on-screen window except NyCopilot's.
        let own = ProcessInfo.processInfo.processIdentifier
        let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        let ids = list.compactMap { info -> CGWindowID? in
            (info[kCGWindowOwnerPID as String] as? pid_t) == own ? nil : info[kCGWindowNumber as String] as? CGWindowID
        }
        // CGWindowListCreateImageFromArray takes a CFArray of raw window numbers, not objects.
        var pointers = ids.map { UnsafeRawPointer(bitPattern: UInt($0)) }
        guard let array = pointers.withUnsafeMutableBufferPointer({ CFArrayCreate(nil, $0.baseAddress, $0.count, nil) }) else { return nil }
        return CGImage(windowListFromArrayScreenBounds: CGDisplayBounds(id), windowArray: array, imageOption: .bestResolution)
    }

    /// Normal windows, menus, and the Dock, front to back, in global top-left coordinates.
    private static func visibleWindows(includingOwn: Bool) -> [CGRect] {
        let own = ProcessInfo.processInfo.processIdentifier
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.compactMap { info in
            guard includingOwn || (info[kCGWindowOwnerPID as String] as? pid_t) != own,
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
