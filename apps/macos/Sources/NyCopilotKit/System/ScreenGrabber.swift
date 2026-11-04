import AppKit
@preconcurrency import ScreenCaptureKit

/// Whole-display capture through ScreenCaptureKit, for screenshots, scrolling capture, GIF
/// recording, and screen translation. Needs Screen Recording (see SystemAccess).
enum ScreenGrabber {
    /// Every display, captured as close to the same instant as possible. With `hidingOwnWindows`,
    /// NyCopilot's windows (pins included) are left out of both the pixels and window detection.
    @MainActor
    static func freezeAll(hidingOwnWindows: Bool) async throws -> [FrozenScreen] {
        let started = Date()
        let windows = visibleWindows(includingOwn: !hidingOwnWindows)
        // The display list barely changes, so the lookup made at launch (or after the last capture)
        // usually serves, and one lookup serves every display.
        let screens = NSScreen.screens
        _ = try await shareableContent(for: screens.compactMap(displayID), hidingOwnWindows: hidingOwnWindows)
        var filters: [SCContentFilter?] = []
        for screen in screens { filters.append(try? await filter(for: screen, excludingOwnWindows: hidingOwnWindows)) }
        let looked = Date()
        // Every display at once rather than one after another.
        let images = await withTaskGroup(of: (Int, CGImage?).self) { group in
            for (index, screen) in screens.enumerated() {
                let filter = filters[index], size = CGSize(width: screen.frame.width * screen.backingScaleFactor,
                                                           height: screen.frame.height * screen.backingScaleFactor)
                group.addTask { (index, try? await capture(filter, pixels: size)) }
            }
            var images = [CGImage?](repeating: nil, count: screens.count)
            for await (index, image) in group { images[index] = image }
            return images
        }
        let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier
        let frozen = zip(screens, images).compactMap { (screen: NSScreen, image: CGImage?) -> FrozenScreen? in
            guard let image else { return nil }
            let pixels = FrozenScreen(screen: screen, image: image, windows: [])
            // The Dock reports its bar a few points off from where it draws it; the pixels say where.
            let onScreen = windows.compactMap { local($0, on: screen) }.map { (window: FrozenScreen.Window) -> FrozenScreen.Window in
                window.pid == dock ? FrozenScreen.Window(rect: snappedToEdges(window.rect, in: pixels), pid: window.pid) : window
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
        guard ScreenRecording.isGranted else { return }
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

    /// A lookup for capturing these displays: the recent one if it will do, else a fresh one.
    @MainActor
    private static func shareableContent(for displays: [CGDirectDisplayID], hidingOwnWindows: Bool) async throws -> SCShareableContent {
        let recent = try await shareableContent(reusingRecent: true)
        return serves(displays: recent.displays.map(\.displayID), applications: recent.applications.map(\.processID),
                      for: displays, hidingOwnWindows: hidingOwnWindows)
            ? recent : try await shareableContent(reusingRecent: false)
    }

    /// Whether a lookup knows these displays and, to leave NyCopilot out, NyCopilot itself.
    /// ScreenCaptureKit lists an app only while it has a window on screen, so the lookup made at
    /// launch, before even the menu bar icon is up, has no NyCopilot in it: kept, it left the
    /// screen translation overlay in every glance, and every glance saw its own highlights change.
    nonisolated static func serves(displays known: [CGDirectDisplayID], applications: [pid_t], for displays: [CGDirectDisplayID],
                                   hidingOwnWindows: Bool, own: pid_t = ProcessInfo.processInfo.processIdentifier) -> Bool {
        displays.allSatisfy(known.contains) && (!hidingOwnWindows || applications.contains(own))
    }

    /// All of `screen`'s display, without NyCopilot's own windows (pins included) when
    /// `excludingOwnWindows`. They're left out by app rather than by window, so windows opened since
    /// the lookup are left out too. A lookup that doesn't know the display is made afresh.
    @MainActor
    static func filter(for screen: NSScreen, excludingOwnWindows: Bool) async throws -> SCContentFilter {
        guard let id = displayID(screen) else { throw Failure.captureFailed }
        let content = try await shareableContent(for: [id], hidingOwnWindows: excludingOwnWindows)
        guard let display = content.displays.first(where: { $0.displayID == id }) else { throw Failure.captureFailed }
        let own = excludingOwnWindows ? content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier } : []
        return SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
    }

    /// One display as it is now, without any NyCopilot window, `pixelsPerPoint` pixels per point:
    /// small for spotting changes, full for reading text. The cursor is left out.
    @MainActor
    static func snapshot(of screen: NSScreen, pixelsPerPoint: CGFloat) async throws -> CGImage {
        let configuration = SCStreamConfiguration()
        configuration.width = Int((screen.frame.width * pixelsPerPoint).rounded())
        configuration.height = Int((screen.frame.height * pixelsPerPoint).rounded())
        configuration.showsCursor = false
        let filter = try await filter(for: screen, excludingOwnWindows: true)
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    private static func capture(_ filter: SCContentFilter?, pixels: CGSize) async throws -> CGImage? {
        guard let filter else { return nil }
        let configuration = SCStreamConfiguration()
        configuration.width = Int(pixels.width)
        configuration.height = Int(pixels.height)
        configuration.showsCursor = false
        configuration.captureResolution = .best
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    /// Normal windows, menus, menu bar items, and the Dock, front to back, in global top-left
    /// coordinates. Raised layers that blanket a whole display are left out: they're invisible
    /// (the Dock keeps one over every screen) and would hide every window beneath them.
    private static func visibleWindows(includingOwn: Bool) -> [FrozenScreen.Window] {
        let own = ProcessInfo.processInfo.processIdentifier
        let displays = NSScreen.screens.map(ScreenGeometry.topLeftFrame)
        var windows: [FrozenScreen.Window] = []
        var dock: FrozenScreen.Window?
        for info in windowList() {
            let pid = info.pid, layer = info.layer, rect = info.bounds
            guard includingOwn || pid != own, info.alpha > 0.05, layer < Int(CGWindowLevelForKey(.screenSaverWindow)),
                  rect.width >= 8, rect.height >= 8 else { continue }
            if layer != 0, displays.contains(where: { $0.intersection(rect).width * $0.intersection(rect).height >= $0.width * $0.height * 0.9 }) {
                if info.owner == "Dock" { dock = dockBar(pid: pid).map { .init(rect: $0, pid: pid) } }
                continue
            }
            // The Dock's own bar sits above normal windows, wherever it fell in the list.
            if layer <= 0, let bar = dock { windows.append(bar); dock = nil }
            windows.append(.init(rect: rect, pid: pid))
        }
        if let dock { windows.append(dock) }
        return windows
    }

    /// One on-screen window as the window server lists it, in global top-left coordinates.
    struct ListedWindow {
        let bounds: CGRect
        let pid: pid_t
        let layer: Int
        let alpha: Double
        let owner: String?
    }

    /// Every on-screen window but the desktop's, front to back.
    static func windowList() -> [ListedWindow] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.compactMap { info in
            guard let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return nil }
            return ListedWindow(bounds: rect, pid: info[kCGWindowOwnerPID as String] as? pid_t ?? 0, layer: info[kCGWindowLayer as String] as? Int ?? 0,
                                alpha: info[kCGWindowAlpha as String] as? Double ?? 1, owner: info[kCGWindowOwnerName as String] as? String)
        }
    }

    /// `rect` (view points) moved by up to 12 points so its edges sit on the strongest edges in the
    /// image: rows where brightness jumps along the top and bottom, columns along the sides. Kept as
    /// it is unless an offset fits clearly better.
    static func snappedToEdges(_ rect: CGRect, in frozen: FrozenScreen) -> CGRect {
        let image = frozen.image, scale = frozen.scale
        let reach = 12 * scale
        let pixels = frozen.pixelRect(local: rect)
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
        guard AXIsProcessTrusted(), let bar = (AX.attribute(AX.application(pid, timeout: 0.2), kAXChildrenAttribute) as? [AXUIElement])?.first,
              let frame = AX.frame(of: bar), frame.width > 0, frame.height > 0 else { return nil }
        return frame
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
        var errorDescription: String? { L("macOS didn’t return an image of the screen.") }
    }
}
