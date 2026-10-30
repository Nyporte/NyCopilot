import AppKit
import MacPlatform

/// macOS half of Screenshot & Pin: freeze the screens, run the selection and annotation overlay,
/// then copy, save, or pin the result; pin the clipboard; manage open pins.
@MainActor
final class CaptureShell: ModuleShell {
    let id = "capture"
    let title = "Screenshot & Pin"
    let symbolName = "camera.viewfinder"

    enum Action {
        static let capture = "capture.snip"
        static let pinClipboard = "capture.pin_clipboard"
        static let togglePins = "capture.toggle_pins"
    }

    private let services: CopilotServices
    private let board = PinBoard()
    private var session: CaptureSession?
    private var scrolling: ScrollCapture?
    /// The app in front when capture started, to return to afterwards.
    private var previousApp: NSRunningApplication?

    init(services: CopilotServices) {
        self.services = services
        board.onSave = { [weak self] image in self?.saveWithPanel(image, region: nil) }
        board.restore()
        // The display lookup is the slowest part of starting a capture; have it ready.
        ScreenGrabber.warmUp()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ScreenGrabber.warmUp() }
        }
    }

    /// Snipaste's keys: F1 to capture, F3 to pin the clipboard, ⇧F3 to hide or show pins.
    var hotKeyActions: [HotKeyCenter.Action] {
        [.init(id: Action.capture, title: "Capture screen", defaultCombination: .init(keyCode: 122, modifiers: 0),
               handler: { [weak self] in self?.startCapture() }),
         .init(id: Action.pinClipboard, title: "Pin clipboard", defaultCombination: .init(keyCode: 99, modifiers: 0),
               handler: { [weak self] in self?.pinClipboard() }),
         .init(id: Action.togglePins, title: "Hide or show pins", defaultCombination: .init(keyCode: 99, modifiers: HotKeyCombination.shift),
               handler: { [weak self] in self?.board.toggleVisibility() })]
    }

    func menuItems() -> [NSMenuItem] {
        var items = [
            services.menuItem("Capture Screen", symbol: "camera.viewfinder", hotKey: Action.capture, target: self, action: #selector(captureFromMenu)),
            services.menuItem("Pin Clipboard", symbol: "pin", hotKey: Action.pinClipboard, target: self, action: #selector(pinFromMenu))
        ]
        if !board.pins.isEmpty {
            items.append(services.menuItem(board.areHidden ? "Show Pins" : "Hide Pins", symbol: board.areHidden ? "eye" : "eye.slash",
                                           hotKey: Action.togglePins, target: self, action: #selector(togglePins)))
            if board.hasClickThrough {
                items.append(services.menuItem("Make Pins Clickable", symbol: "cursorarrow.click", hotKey: nil, target: self,
                                               action: #selector(makeClickable)))
            }
            items.append(services.menuItem("Close All Pins", symbol: "xmark.circle", hotKey: nil, target: self, action: #selector(closeAllPins)))
        }
        return items
    }

    func makeSettingsPane() -> SettingsPane? { CapturePane(services: services) }

    /// Pins stay open across launches: where they are now is written down, and they come back.
    func shutdown() {
        session?.close()
        board.persist()
    }

    @objc private func captureFromMenu() {
        // Let the menu finish closing so it isn't in the capture.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.startCapture() }
    }
    @objc private func pinFromMenu() { pinClipboard() }
    @objc private func togglePins() { board.toggleVisibility() }
    @objc private func makeClickable() { board.makeAllClickable() }
    @objc private func closeAllPins() { board.closeAll() }

    // MARK: Capture

    private struct Region: Codable { let x, y, w, h: Double }

    func startCapture() {
        guard session == nil else { return }
        guard ScreenGrabber.hasPermission else {
            ScreenGrabber.requestPermission()
            services.toast.show("Allow Screen Recording to capture", detail: "Turn on NyCopilot in System Settings → Privacy & Security → Screen Recording, then press the shortcut again.", style: .warning)
            return
        }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp = NSWorkspace.shared.frontmostApplication
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                let frozen = try await ScreenGrabber.freezeAll(hidingOwnWindows: services.core.setting(.hideOwnWindows, default: false))
                let recent = ((try? services.core.call("capture.recent_regions", ["limit": 20], as: [Region].self)) ?? [])
                    .map { CGRect(x: $0.x, y: $0.y, width: $0.w, height: $0.h) }
                let palette = ((try? services.core.call("capture.palette") as? [String]) ?? []).compactMap(NSColor.init(hex:))
                let color = NSColor(hex: services.core.setting(.captureColor, default: "#FF3B30")) ?? .systemRed
                let stroke = CGFloat(services.core.setting(.captureStroke, default: 3.0))
                let storedStyle = services.core.setting(.captureStyle, default: [String: Any]())
                let style = (try? JSONSerialization.data(withJSONObject: storedStyle))
                    .flatMap { try? JSONDecoder().decode(CaptureStyle.self, from: $0) } ?? CaptureStyle()
                let session = CaptureSession(frozen: frozen, recent: recent, palette: palette, color: color, stroke: stroke,
                                             style: style) { [weak self] color, stroke, style in
                    try? self?.services.core.setSetting(.captureColor, color.hexString)
                    try? self?.services.core.setSetting(.captureStroke, Double(stroke))
                    try? self?.services.core.setSetting(.captureStyle, style.json)
                }
                session.onFinish = { [weak self] action, image, region, screen in
                    self?.finish(action, image: image, region: region, screen: screen)
                }
                session.onScroll = { [weak self] region, frozen in
                    self?.end()
                    self?.startScrolling(region, frozen: frozen)
                }
                session.onTextCopied = { [weak self] lines, region, _ in
                    self?.end()
                    self?.services.toast.show("Copied \(lines) line\(lines == 1 ? "" : "s") of text", style: .success,
                                              near: CaptureSession.appKitRect(region))
                }
                session.onCancel = { [weak self] in self?.end() }
                self.session = session
                session.show()
            } catch {
                services.toast.show("Couldn’t capture the screen", detail: error.localizedDescription, style: .warning)
            }
        }
    }

    private func end(returnFocus: Bool = true) {
        session = nil
        if returnFocus, let app = previousApp, !app.isTerminated { app.activate(options: []) }
    }

    private func finish(_ action: CaptureAction, image: NSImage, region: CGRect, screen: NSScreen) {
        switch action {
        case .scroll:
            break // Handled by the session's onScroll.
        case .translate:
            end()
            Task { await translateText(in: image, region: region) }
        case .copy:
            copy(image)
            record(image, region: region, screen: screen, path: nil)
            end()
        case .save:
            end(returnFocus: false)
            saveWithPanel(image, region: (region, screen))
        case .quickSave:
            end()
            if let url = write(image, to: nextFileURL()) {
                record(image, region: region, screen: screen, path: url.path)
                services.toast.show("Saved “\(url.lastPathComponent)”", detail: url.deletingLastPathComponent().path, style: .success)
            }
        case .pin:
            // A scrolling capture is taller than its region: it starts there and fits the screen.
            let frame = CaptureSession.appKitRect(CGRect(origin: region.origin, size: image.size))
            let pin = board.pin(image, at: frame, shadow: services.core.setting(.pinShadow, default: true))
            let visible = screen.visibleFrame
            if frame.height > visible.height * 0.9 {
                pin.setZoom(visible.height * 0.9 / frame.height, around: NSPoint(x: frame.minX, y: frame.maxY))
                pin.setFrameOrigin(NSPoint(x: pin.frame.minX, y: max(visible.minY, min(pin.frame.minY, visible.maxY - pin.frame.height))))
            }
            record(image, region: region, screen: screen, path: nil)
            end()
        }
    }

    /// The capture's text, paragraph by paragraph, translated on a card beside the region — read from
    /// the finished image, so whatever a mosaic hides stays hidden.
    private func translateText(in image: NSImage, region: CGRect) async {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let paragraphs = try? await ScreenTranslator.paragraphs(in: cgImage, scale: CGFloat(cgImage.width) / image.size.width),
              !paragraphs.isEmpty else {
            services.toast.show("No text to translate here", style: .info, near: CaptureSession.appKitRect(region))
            return
        }
        services.translateText(paragraphs.joined(separator: "\n\n"), region)
    }

    /// The region stays live; whatever is scrolled under it is stitched into one tall image, which
    /// then goes through the same copy, save, and pin as any capture.
    private func startScrolling(_ region: CGRect, frozen: FrozenScreen) {
        let screen = frozen.screen
        // The frozen pixels are exactly what was on screen, so they start the image at once — unless
        // a pin was on them, since the live stream leaves pins out.
        let hidesPins = services.core.setting(.hideOwnWindows, default: false)
        let capture = ScrollCapture(region: region, frozen: frozen) { [weak self] rect in
            hidesPins || !(self?.board.covers(CaptureSession.appKitRect(rect)) ?? false)
        }
        capture.onFinish = { [weak self] action, image in
            self?.scrolling = nil
            self?.finish(action, image: image, region: region, screen: screen)
        }
        capture.onCancel = { [weak self] in self?.scrolling = nil }
        capture.onFailure = { [weak self] error in
            self?.scrolling = nil
            self?.services.toast.show("Couldn’t start scrolling capture", detail: error.localizedDescription, style: .warning)
        }
        scrolling = capture
        capture.start()
    }

    private func copy(_ image: NSImage) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }

    private func record(_ image: NSImage, region: CGRect, screen: NSScreen, path: String?) {
        let pixels = image.representations.first.map { ($0.pixelsWide, $0.pixelsHigh) } ?? (Int(image.size.width), Int(image.size.height))
        var params: [String: Any] = ["region": ["x": region.minX, "y": region.minY, "w": region.width, "h": region.height],
                                     "display": screen.localizedName, "width": pixels.0, "height": pixels.1]
        if let path { params["path"] = path }
        _ = try? services.core.call("capture.record", params)
    }

    // MARK: Files

    private var format: String { services.core.setting(.captureFormat, default: "png") }

    /// The chosen folder, or Pictures/NyCopilot, created on first use.
    private var saveFolder: URL {
        let chosen: String = services.core.setting(.captureSaveFolder, default: "")
        let folder = chosen.isEmpty
            ? FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0].appendingPathComponent("NyCopilot")
            : URL(fileURLWithPath: (chosen as NSString).expandingTildeInPath)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func fileName() -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date())
        let date = [parts.year ?? 0, parts.month ?? 0, parts.day ?? 0, parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0]
        struct Name: Decodable { let name: String }
        return (try? services.core.call("capture.file_name", ["date": date], as: Name.self).name) ?? "Capture.\(format)"
    }

    /// A name in the save folder that doesn't overwrite an existing file ("name 2.png", "name 3.png"…).
    private func nextFileURL() -> URL {
        let first = saveFolder.appendingPathComponent(fileName())
        let base = first.deletingPathExtension().lastPathComponent, ext = first.pathExtension
        var candidate = first, counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = saveFolder.appendingPathComponent("\(base) \(counter).\(ext)")
            counter += 1
        }
        return candidate
    }

    private func write(_ image: NSImage, to url: URL) -> URL? {
        guard let data = CaptureRenderer.encode(image, format: url.pathExtension.lowercased() == "jpg" ? "jpg" : "png") else {
            services.toast.show("Couldn’t encode the image", style: .warning)
            return nil
        }
        do { try data.write(to: url, options: .atomic); return url } catch {
            services.toast.show("Couldn’t save the image", detail: error.localizedDescription, style: .warning)
            return nil
        }
    }

    private func saveWithPanel(_ image: NSImage, region: (CGRect, NSScreen)?) {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.directoryURL = saveFolder
        panel.nameFieldStringValue = fileName()
        panel.allowedContentTypes = format == "jpg" ? [.jpeg] : [.png]
        panel.canCreateDirectories = true
        panel.level = .modalPanel
        panel.begin { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            if write(image, to: url) != nil, let (rect, screen) = region { record(image, region: rect, screen: screen, path: url.path) }
            if let app = previousApp, !app.isTerminated { app.activate(options: []) }
        }
    }

    // MARK: Pin clipboard

    /// An image pins as is; a #RRGGBB color pins as a swatch; other text pins as a rendered card.
    func pinClipboard() {
        let board = NSPasteboard.general
        let image: NSImage
        if let picture = NSImage(pasteboard: board), picture.isValid {
            image = picture
        } else if let text = board.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            image = NSColor(hex: text).map { Self.swatch($0, label: text.uppercased()) } ?? Self.card(text)
        } else {
            services.toast.show("Nothing to pin", detail: "Copy an image, some text, or a color first.", style: .info)
            return
        }
        let mouse = NSEvent.mouseLocation
        let frame = NSRect(x: mouse.x - image.size.width / 2, y: mouse.y - image.size.height / 2,
                           width: image.size.width, height: image.size.height)
        self.board.pin(image, at: frame, shadow: services.core.setting(.pinShadow, default: true))
    }

    private static func card(_ text: String) -> NSImage {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.labelColor]
        let bounds = (text as NSString).boundingRect(with: NSSize(width: 460, height: 2000),
                                                     options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes)
        let size = NSSize(width: ceil(bounds.width) + 28, height: min(ceil(bounds.height), 900) + 24)
        return NSImage(size: size, flipped: true) { rect in
            NSColor.windowBackgroundColor.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
            (text as NSString).draw(with: rect.insetBy(dx: 14, dy: 12), options: [.usesLineFragmentOrigin, .usesFontLeading],
                                    attributes: attributes)
            return true
        }
    }

    private static func swatch(_ color: NSColor, label: String) -> NSImage {
        NSImage(size: NSSize(width: 140, height: 96), flipped: true) { rect in
            color.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
            let luminance = 0.299 * color.redComponent + 0.587 * color.greenComponent + 0.114 * color.blueComponent
            (label as NSString).draw(at: CGPoint(x: 12, y: rect.maxY - 26), withAttributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: luminance > 0.6 ? NSColor.black : NSColor.white
            ])
            return true
        }
    }
}
