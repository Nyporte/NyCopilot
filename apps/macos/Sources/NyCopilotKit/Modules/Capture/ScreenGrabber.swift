import AppKit
@preconcurrency import ScreenCaptureKit

/// One display frozen at the moment a capture starts: its pixels and the windows on it, so the
/// selection UI works on a still image while the real screen keeps running underneath.
/// Immutable once frozen, so it can be handed between tasks.
struct FrozenScreen: @unchecked Sendable {
    let screen: NSScreen
    let image: CGImage
    /// On-screen windows, front to back, in this screen's flipped view coordinates (top-left origin).
    let windows: [Window]

    var scale: CGFloat { CGFloat(image.width) / screen.frame.width }

    /// A window's visible area and the app it belongs to, for finding the elements inside it.
    struct Window {
        let rect: CGRect
        let pid: pid_t
    }
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
    @MainActor
    static func freezeAll(hidingOwnWindows: Bool) async throws -> [FrozenScreen] {
        let started = Date()
        let windows = visibleWindows(includingOwn: !hidingOwnWindows)
        // The display list barely changes, so the lookup made at launch (or after the last capture)
        // serves; NyCopilot's windows are left out by app, which needs no fresh window list.
        var content = try await shareableContent(reusingRecent: true)
        let ids = NSScreen.screens.compactMap(displayID)
        if !ids.allSatisfy({ id in content.displays.contains { $0.displayID == id } }) {
            content = try await shareableContent(reusingRecent: false)
        }
        let looked = Date()
        // Every display at once rather than one after another.
        let screens = NSScreen.screens, lookup = content
        let images = await withTaskGroup(of: (Int, CGImage?).self) { group in
            for (index, screen) in screens.enumerated() {
                let target = (id: displayID(screen), size: CGSize(width: screen.frame.width * screen.backingScaleFactor,
                                                                   height: screen.frame.height * screen.backingScaleFactor))
                group.addTask { (index, try? await capture(target.id, pixels: target.size, hidingOwnWindows: hidingOwnWindows, content: lookup)) }
            }
            var images = [CGImage?](repeating: nil, count: screens.count)
            for await (index, image) in group { images[index] = image }
            return images
        }
        let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier
        let frozen = zip(screens, images).compactMap { (screen: NSScreen, image: CGImage?) -> FrozenScreen? in
            guard let image else { return nil }
            let scale = CGFloat(image.width) / screen.frame.width
            // The Dock reports its bar a few points off from where it draws it; the pixels say where.
            let onScreen = windows.compactMap { local($0, on: screen) }.map { (window: FrozenScreen.Window) -> FrozenScreen.Window in
                window.pid == dock ? FrozenScreen.Window(rect: snappedToEdges(window.rect, in: image, scale: scale), pid: window.pid) : window
            }
            return FrozenScreen(screen: screen, image: image, windows: onScreen)
        }
        guard !frozen.isEmpty else { throw Failure.captureFailed }
        Diagnostics.note("capture", "froze \(frozen.count) display\(frozen.count == 1 ? "" : "s") in \(Int(Date().timeIntervalSince(started) * 1000)) ms "
                         + "(lookup \(Int(looked.timeIntervalSince(started) * 1000)) ms)")
        // Ready for next time, off the critical path.
        Task { _ = try? await shareableContent(reusingRecent: false) }
        return frozen
    }

    /// Looks up the displays ahead of the first capture, so pressing the shortcut doesn't wait for it.
    @MainActor
    static func warmUp() {
        guard hasPermission else { return }
        Task { _ = try? await shareableContent(reusingRecent: false) }
    }

    private static func displayID(_ screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
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

    /// One display as it is now, without any NyCopilot window, `pixelsPerPoint` pixels per point:
    /// small for spotting changes, full for reading text. The cursor is left out.
    @MainActor
    static func snapshot(of screen: NSScreen, pixelsPerPoint: CGFloat) async throws -> CGImage? {
        guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return nil }
        let width = Int((screen.frame.width * pixelsPerPoint).rounded()), height = Int((screen.frame.height * pixelsPerPoint).rounded())
        var content = try await shareableContent(reusingRecent: true)
        if !content.displays.contains(where: { $0.displayID == id }) { content = try await shareableContent(reusingRecent: false) }
        guard let display = content.displays.first(where: { $0.displayID == id }) else { return nil }
        // By app rather than by window, so windows opened since the lookup are left out too.
        let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.showsCursor = false
        return try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(display: display, excludingApplications: own, exceptingWindows: []), configuration: configuration)
    }

    private static func capture(_ id: CGDirectDisplayID?, pixels: CGSize, hidingOwnWindows: Bool,
                                content: SCShareableContent) async throws -> CGImage? {
        guard let id else { return nil }
        do {
            guard let display = content.displays.first(where: { $0.displayID == id }) else { return nil }
            // By app rather than by window, so pins opened since the lookup are left out too.
            let own = hidingOwnWindows ? content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier } : []
            let configuration = SCStreamConfiguration()
            configuration.width = Int(pixels.width)
            configuration.height = Int(pixels.height)
            configuration.showsCursor = false
            configuration.captureResolution = .best
            return try await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(display: display, excludingApplications: own, exceptingWindows: []), configuration: configuration)
        }
    }

    /// Normal windows, menus, menu bar items, and the Dock, front to back, in global top-left
    /// coordinates. Raised layers that blanket a whole display are left out: they're invisible
    /// (the Dock keeps one over every screen) and would hide every window beneath them.
    private static func visibleWindows(includingOwn: Bool) -> [FrozenScreen.Window] {
        let own = ProcessInfo.processInfo.processIdentifier
        let displays = NSScreen.screens.map(ScreenGeometry.topLeftFrame)
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var windows: [FrozenScreen.Window] = []
        var dock: FrozenScreen.Window?
        for info in list {
            let pid = info[kCGWindowOwnerPID as String] as? pid_t ?? 0
            let layer = info[kCGWindowLayer as String] as? Int ?? 0
            guard includingOwn || pid != own,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0.05,
                  layer < Int(CGWindowLevelForKey(.screenSaverWindow)),
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  rect.width >= 8, rect.height >= 8 else { continue }
            if layer != 0, displays.contains(where: { $0.intersection(rect).width * $0.intersection(rect).height >= $0.width * $0.height * 0.9 }) {
                if info[kCGWindowOwnerName as String] as? String == "Dock" { dock = dockBar(pid: pid).map { .init(rect: $0, pid: pid) } }
                continue
            }
            // The Dock's own bar sits above normal windows, wherever it fell in the list.
            if layer <= 0, let bar = dock { windows.append(bar); dock = nil }
            windows.append(.init(rect: rect, pid: pid))
        }
        if let dock { windows.append(dock) }
        return windows
    }

    /// `rect` (view points) moved by up to 12 points so its edges sit on the strongest edges in the
    /// image: rows where brightness jumps along the top and bottom, columns along the sides. Kept as
    /// it is unless an offset fits clearly better.
    static func snappedToEdges(_ rect: CGRect, in image: CGImage, scale: CGFloat) -> CGRect {
        let reach = 12 * scale
        let pixels = CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
        let band = pixels.insetBy(dx: -reach - 1, dy: -reach - 1).integral
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard band.width > 4, band.height > 4, let crop = image.cropping(to: band) else { return rect }
        let width = crop.width, height = crop.height
        var grey = [UInt8](repeating: 0, count: width * height)
        let drawn = grey.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            // Bitmap rows run top-down already: row 0 is the band's top, as in the view.
            context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return rect }
        let inner = pixels.offsetBy(dx: -band.minX, dy: -band.minY)
        /// Average brightness jump across a row (between it and the one above) or a column, over the
        /// middle of the edge, away from rounded corners.
        func rowJump(_ y: Int) -> Double {
            guard y >= 1, y < height else { return 0 }
            let from = max(Int(inner.minX + inner.width * 0.2), 0), to = min(Int(inner.maxX - inner.width * 0.2), width)
            guard to > from else { return 0 }
            var sum = 0
            for x in from..<to { sum += abs(Int(grey[y * width + x]) - Int(grey[(y - 1) * width + x])) }
            return Double(sum) / Double(to - from)
        }
        func columnJump(_ x: Int) -> Double {
            guard x >= 1, x < width else { return 0 }
            let from = max(Int(inner.minY + inner.height * 0.2), 0), to = min(Int(inner.maxY - inner.height * 0.2), height)
            guard to > from else { return 0 }
            var sum = 0
            for y in from..<to { sum += abs(Int(grey[y * width + x]) - Int(grey[y * width + x - 1])) }
            return Double(sum) / Double(to - from)
        }
        func bestShift(_ low: CGFloat, _ high: CGFloat, _ jump: (Int) -> Double) -> CGFloat {
            func score(_ shift: Int) -> Double { jump(Int(low.rounded()) + shift) + jump(Int(high.rounded()) + shift) }
            let span = Int(reach)
            let best = (-span...span).max { score($0) < score($1) } ?? 0
            return score(best) > score(0) * 1.25 + 2 ? CGFloat(best) : 0
        }
        let dy = bestShift(inner.minY, inner.maxY, rowJump)
        let dx = bestShift(inner.minX, inner.maxX, columnJump)
        return rect.offsetBy(dx: dx / scale, dy: dy / scale)
    }

    /// The Dock's visible bar, from Accessibility (its window covers the whole screen).
    private static func dockBar(pid: pid_t) -> CGRect? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXChildrenAttribute as CFString, &children) == .success,
              let list = (children as? [AXUIElement])?.first else { return nil }
        return AccessibilityFrame.of(list)
    }

    /// Global top-left coordinates → this screen's flipped view coordinates, clipped to the screen.
    private static func local(_ window: FrozenScreen.Window, on screen: NSScreen) -> FrozenScreen.Window? {
        let origin = ScreenGeometry.topLeftOrigin(of: screen)
        let moved = window.rect.offsetBy(dx: -origin.x, dy: -origin.y)
        let clipped = moved.intersection(CGRect(origin: .zero, size: screen.frame.size))
        return clipped.isNull || clipped.width < 8 || clipped.height < 8 ? nil : .init(rect: clipped, pid: window.pid)
    }

    enum Failure: LocalizedError {
        case captureFailed
        var errorDescription: String? { "macOS didn’t return an image of the screen." }
    }
}
