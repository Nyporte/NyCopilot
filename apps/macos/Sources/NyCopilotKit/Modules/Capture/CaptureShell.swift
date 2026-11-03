import AppKit
import MacPlatform

/// macOS half of Screenshot & Pin: freeze the screens, run the selection and annotation overlay,
/// then copy, save, or pin the result; pin the clipboard; manage open pins.
@MainActor
final class CaptureShell: ModuleShell {
    let id = "capture"
    let title = L("Screenshot & Pin")
    let symbolName = "camera.viewfinder"

    enum Action {
        static let capture = "capture.snip"
        static let pinClipboard = "capture.pin_clipboard"
        static let togglePins = "capture.toggle_pins"
    }

    private let services: CopilotServices
    private let board = PinBoard()
    private var session: CaptureSession?
    /// Between the shortcut and the overlay appearing, while the screens freeze.
    private var isStarting = false
    private var scrolling: ScrollCapture?
    /// The app in front when capture started, to return to afterwards.
    private var previousApp: NSRunningApplication?

    init(services: CopilotServices) {
        self.services = services
        // A pin is saved long after its capture: return to whichever app is in front now.
        board.onSave = { [weak self] image in self?.saveWithPanel(image, region: nil, returningTo: Self.otherFrontApp()) }
        board.onVerb = { [weak services] verb, pin in services?.act(verb, text: nil, image: pin.displayedImage, near: pin.frame) }
        services.pinOnScreen = { [weak self] text, image in self?.pin(text: text, image: image) }
        board.restore()
        GifRecording.removeLeftovers()
        CaptureStreams.shared.onStuck = { [weak services] in
            services?.toast.show(L("macOS kept a screen capture running"),
                                 detail: L("Its recording indicator stays on. Settings → General → Restart Screen Capture Service ends it."),
                                 style: .warning)
        }
        // The display lookup is the slowest part of starting a capture; have it ready.
        ScreenGrabber.warmUp()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ScreenGrabber.warmUp() }
        }
    }

    /// Everything on F1: F1 to capture, ⇧F1 to pin the clipboard, ⌥F1 to hide or show pins (F3 is the inbox's).
    var hotKeyActions: [HotKeyCenter.Action] {
        [.init(id: Action.capture, title: L("Capture screen"), defaultCombination: .init(keyCode: 122, modifiers: 0),
               handler: { [weak self] in self?.startCapture() }),
         .init(id: Action.pinClipboard, title: L("Pin clipboard"), defaultCombination: .init(keyCode: 122, modifiers: HotKeyCombination.shift),
               handler: { [weak self] in self?.pinClipboard() }),
         .init(id: Action.togglePins, title: L("Hide or show pins"), defaultCombination: .init(keyCode: 122, modifiers: HotKeyCombination.option),
               handler: { [weak self] in self?.board.toggleVisibility() })]
    }

    func menuItems() -> [NSMenuItem] {
        var items = [
            services.menuItem(L("Capture Screen"), symbol: "camera.viewfinder", hotKey: Action.capture, target: self, action: #selector(captureFromMenu)),
            services.menuItem(L("Pin Clipboard"), symbol: "pin", hotKey: Action.pinClipboard, target: self, action: #selector(pinFromMenu))
        ]
        if !board.pins.isEmpty {
            items.append(services.menuItem(board.areHidden ? L("Show Pins") : L("Hide Pins"), symbol: board.areHidden ? "eye" : "eye.slash",
                                           hotKey: Action.togglePins, target: self, action: #selector(togglePins)))
            if board.hasClickThrough {
                items.append(services.menuItem(L("Make Pins Clickable"), symbol: "cursorarrow.click", hotKey: nil, target: self,
                                               action: #selector(makeClickable)))
            }
            items.append(services.menuItem(L("Close All Pins"), symbol: "xmark.circle", hotKey: nil, target: self, action: #selector(closeAllPins)))
        }
        return items
    }

    func makeSettingsPane() -> SettingsPane? { CapturePane(services: services) }

    /// Pins stay open across launches: where they are now is written down, and they come back.
    func shutdown() {
        session?.close()
        scrolling?.cancel()
        recording?.cancel()
        preview?.close()
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
        // With a recording armed or running, the shortcut starts or stops it.
        if let recording, recording.isActive { recording.shortcutPressed(); return }
        // A scrolling capture owns its keys and stream until it's finished or cancelled.
        guard session == nil, scrolling == nil, !isStarting else { return }
        guard ScreenRecording.isGranted else {
            ScreenRecording.requestAccess()
            services.toast.show(L("Allow Screen Recording to capture"), detail: L("Turn on NyCopilot in System Settings → Privacy & Security → Screen Recording, then press the shortcut again."), style: .warning)
            return
        }
        previousApp = Self.otherFrontApp()
        CaptureView.showsKeysTip = Tips.due("capture.keys", after: 2, times: 3)
        let pressed = Date()
        CaptureView.pressedAt = pressed
        isStarting = true
        Task { [weak self] in
            guard let self else { return }
            defer { isStarting = false }
            do {
                let frozen = try await ScreenGrabber.freezeAll(hidingOwnWindows: services.core.setting(.hideOwnWindows, default: false))
                let froze = Date()
                let recent = ((try? services.core.call(.captureRecentRegions, ["limit": 20], as: [Region].self)) ?? [])
                    .map { CGRect(x: $0.x, y: $0.y, width: $0.w, height: $0.h) }
                let palette = ((try? services.core.call(.capturePalette) as? [String]) ?? []).compactMap(NSColor.init(hex:))
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
                session.onRecord = { [weak self] region, screen in
                    self?.end()
                    self?.startRecording(region, on: screen)
                }
                session.onTextCopied = { [weak self] lines, region, _ in
                    self?.end()
                    self?.services.toast.show(L("Copied %ld lines of text", lines), style: .success,
                                              near: ScreenGeometry.appKit(region))
                }
                session.onCancel = { [weak self] in self?.end() }
                session.returnsFocusTo = previousApp
                self.session = session
                let built = Date()
                session.show()
                Diagnostics.note("capture", "F1 → frozen \(Self.ms(pressed, froze)) ms, session \(Self.ms(froze, built)) ms, shown \(Self.ms(built, Date())) ms")
            } catch {
                services.toast.show(L("Couldn’t capture the screen"), detail: error.localizedDescription, style: .warning)
            }
        }
    }

    private static func ms(_ from: Date, _ to: Date) -> Int { Int(to.timeIntervalSince(from) * 1000) }

    /// The session hands the focus back as it closes (see CaptureSession.close).
    private func end() {
        session = nil
    }

    private func finish(_ action: CaptureAction, image: NSImage, region: CGRect, screen: NSScreen) {
        switch action {
        case .scroll, .record:
            break // Handled by the session's onScroll and onRecord.
        case .inbox:
            record(image, region: region, screen: screen, path: nil)
            end()
            services.sendToInbox(nil, image, previousApp)
        case .translate:
            end()
            services.act(.translate, text: nil, image: image, near: ScreenGeometry.appKit(region))
        case .ask:
            record(image, region: region, screen: screen, path: nil)
            end()
            services.act(.ask, text: nil, image: image, from: previousApp, near: ScreenGeometry.appKit(region))
        case .copy:
            copy(image)
            record(image, region: region, screen: screen, path: nil)
            end()
        case .save:
            end()
            saveWithPanel(image, region: (region, screen), returningTo: previousApp)
        case .quickSave:
            end()
            if let url = write(image, to: nextFileURL()) {
                record(image, region: region, screen: screen, path: url.path)
                services.toast.show(L("Saved “%@”", url.lastPathComponent), detail: url.deletingLastPathComponent().path, style: .success)
            }
        case .pin:
            // A scrolling capture is taller than its region: it starts there and fits the screen.
            let frame = ScreenGeometry.appKit(CGRect(origin: region.origin, size: image.size))
            let pin = board.pin(image, at: frame, shadow: services.core.setting(.pinShadow, default: true))
            let visible = screen.visibleFrame
            if frame.height > visible.height * 0.9 {
                pin.setZoom(visible.height * 0.9 / frame.height, around: NSPoint(x: frame.minX, y: frame.maxY))
                pin.setFrameOrigin(NSPoint(x: pin.frame.minX, y: max(visible.minY, min(pin.frame.minY, visible.maxY - pin.frame.height))))
            }
            record(image, region: region, screen: screen, path: nil)
            end()
            tipAboutPins(near: pin.frame)
        }
    }

    private func tipAboutPins(near frame: NSRect) {
        guard Tips.due("pin.keys", times: 2) else { return }
        services.toast.show(L("Pinned"), detail: L("Scroll to zoom, ⌥-scroll for opacity. Click it and press ? for all its keys."), style: .info,
                            near: frame)
    }

    // MARK: GIF recording

    private var recording: GifRecording?
    private var preview: GifPreview?
    /// The clip last copied: the clipboard points at its file, so it stays until the next copy.
    private var copiedClip: URL?

    private func startRecording(_ region: CGRect, on screen: NSScreen) {
        let core = services.core
        let recording = GifRecording(region: region, screen: screen, fps: core.setting(.gifFPS, default: 15),
                                     retina: core.setting(.gifRetina, default: false), showsCursor: core.setting(.gifCursor, default: true),
                                     shortcut: services.hotKeys.combination(for: Action.capture).map(KeyNames.display) ?? "F1")
        recording.onFinish = { [weak self] clip in
            self?.recording = nil
            self?.review(clip, region: ScreenGeometry.appKit(region), screen: screen)
        }
        recording.onCancel = { [weak self] in self?.recording = nil }
        recording.onFailure = { [weak self] error in
            self?.recording = nil
            self?.services.toast.show(L("Couldn’t record the GIF"), detail: error.localizedDescription, style: .warning)
        }
        self.recording = recording
        recording.start()
    }

    private func review(_ clip: GifClip, region: NSRect, screen: NSScreen) {
        // A preview left open from an earlier recording goes, with its clip.
        if let earlier = preview {
            earlier.close()
            try? FileManager.default.removeItem(at: earlier.clip.url)
        }
        let preview = GifPreview(clip: clip, near: region, on: screen)
        preview.onAction = { [weak self] action, clip in
            self?.preview = nil
            self?.finish(action, clip: clip, near: region)
        }
        preview.onDiscard = { [weak self] clip in
            self?.preview = nil
            try? FileManager.default.removeItem(at: clip.url)
        }
        self.preview = preview
        preview.show()
    }

    /// Copy puts the file on the clipboard (chat apps take it as an animated GIF) along with its data.
    /// Otherwise the clip's temporary file goes once it's saved or filed.
    private func finish(_ action: GifAction, clip: GifClip, near region: NSRect) {
        let discard = { try? FileManager.default.removeItem(at: clip.url) }
        switch action {
        case .copy:
            if let earlier = copiedClip, earlier != clip.url { try? FileManager.default.removeItem(at: earlier) }
            copiedClip = clip.url
            let item = NSPasteboardItem()
            if let data = try? Data(contentsOf: clip.url) { item.setData(data, forType: NSPasteboard.PasteboardType("com.compuserve.gif")) }
            item.setString(clip.url.absoluteString, forType: .fileURL)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([item])
            services.toast.show(L("GIF copied"), detail: L("Paste it into a chat or a document."), style: .success, near: region)
        case .save:
            NSApp.bringForward()
            let panel = NSSavePanel()
            panel.directoryURL = saveFolder
            panel.nameFieldStringValue = fileName(extension: "gif")
            panel.allowedContentTypes = [.gif]
            panel.canCreateDirectories = true
            panel.level = .modalPanel
            panel.begin { [weak self] response in
                // Saved or not, back to the app you were in.
                if let app = self?.previousApp, !app.isTerminated { app.activate(options: []) }
                defer { discard() }
                guard response == .OK, let url = panel.url else { return }
                self?.move(clip, to: url)
            }
        case .quickSave:
            let url = nextFileURL(extension: "gif")
            if move(clip, to: url) {
                services.toast.show(L("Saved “%@”", url.lastPathComponent), detail: url.deletingLastPathComponent().path, style: .success)
            }
            discard()
        case .inbox:
            services.sendFileToInbox(clip.url, previousApp)
        }
    }

    @discardableResult
    private func move(_ clip: GifClip, to url: URL) -> Bool {
        do {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            try FileManager.default.copyItem(at: clip.url, to: url)
            return true
        } catch {
            services.toast.show(L("Couldn’t save the GIF"), detail: error.localizedDescription, style: .warning)
            return false
        }
    }

    /// The region stays live; whatever is scrolled under it is stitched into one tall image, which
    /// then goes through the same copy, save, and pin as any capture.
    private func startScrolling(_ region: CGRect, frozen: FrozenScreen) {
        let screen = frozen.screen
        // The frozen pixels are exactly what was on screen, so they start the image at once — unless
        // a pin was on them, since the live stream leaves pins out.
        let hidesPins = services.core.setting(.hideOwnWindows, default: false)
        let capture = ScrollCapture(region: region, frozen: frozen) { [weak self] rect in
            hidesPins || !(self?.board.covers(ScreenGeometry.appKit(rect)) ?? false)
        }
        capture.onFinish = { [weak self] action, image in
            self?.scrolling = nil
            self?.finish(action, image: image, region: region, screen: screen)
        }
        capture.onCancel = { [weak self] in self?.scrolling = nil }
        capture.onFailure = { [weak self] error in
            self?.scrolling = nil
            self?.services.toast.show(L("Couldn’t start scrolling capture"), detail: error.localizedDescription, style: .warning)
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
        _ = try? services.core.call(.captureRecord, params)
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

    private func fileName(extension ext: String? = nil) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date())
        let date = [parts.year ?? 0, parts.month ?? 0, parts.day ?? 0, parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0]
        struct Name: Decodable { let name: String }
        let name = (try? services.core.call(.captureFileName, ["date": date], as: Name.self).name) ?? "Capture.\(format)"
        guard let ext else { return name }
        return ((name as NSString).deletingPathExtension as NSString).appendingPathExtension(ext) ?? name
    }

    /// A name in the save folder that doesn't overwrite an existing file ("name 2.png", "name 3.png"…).
    private func nextFileURL(extension ext: String? = nil) -> URL {
        let first = saveFolder.appendingPathComponent(fileName(extension: ext))
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
            services.toast.show(L("Couldn’t encode the image"), style: .warning)
            return nil
        }
        do { try data.write(to: url, options: .atomic); return url } catch {
            services.toast.show(L("Couldn’t save the image"), detail: error.localizedDescription, style: .warning)
            return nil
        }
    }

    /// The app in front, unless it's NyCopilot itself: then nothing needs the focus back.
    private static func otherFrontApp() -> NSRunningApplication? {
        let front = NSWorkspace.shared.frontmostApplication
        return front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
    }

    private func saveWithPanel(_ image: NSImage, region: (CGRect, NSScreen)?, returningTo app: NSRunningApplication?) {
        NSApp.bringForward()
        let panel = NSSavePanel()
        panel.directoryURL = saveFolder
        panel.nameFieldStringValue = fileName()
        panel.allowedContentTypes = format == "jpg" ? [.jpeg] : [.png]
        panel.canCreateDirectories = true
        panel.level = .modalPanel
        panel.begin { [weak self] response in
            guard let self else { return }
            // Saved or not, back to the app you were in.
            if let app, !app.isTerminated { app.activate(options: []) }
            guard response == .OK, let url = panel.url else { return }
            if write(image, to: url) != nil, let (rect, screen) = region { record(image, region: rect, screen: screen, path: url.path) }
        }
    }

    // MARK: Pin clipboard

    /// An image pins as is; a #RRGGBB color pins as a swatch; other text pins as a rendered card.
    func pinClipboard() {
        let board = NSPasteboard.general
        if let picture = NSImage(pasteboard: board), picture.isValid {
            pin(text: nil, image: picture)
        } else if let text = board.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            pin(text: text, image: nil)
        } else {
            services.toast.show(L("Nothing to pin"), detail: L("Copy an image, some text, or a color first."), style: .info)
        }
    }

    /// An image as it is, a `#RRGGBB` color as a swatch, other text as a card — centered on the pointer.
    private func pin(text: String?, image: NSImage?) {
        let picture: NSImage
        if let image {
            picture = image
        } else if let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            picture = NSColor(hex: text).map { Self.swatch($0, label: text.uppercased()) } ?? Self.card(text)
        } else {
            return
        }
        let mouse = NSEvent.mouseLocation
        let frame = NSRect(x: mouse.x - picture.size.width / 2, y: mouse.y - picture.size.height / 2,
                           width: picture.size.width, height: picture.size.height)
        self.board.pin(picture, at: frame, shadow: services.core.setting(.pinShadow, default: true))
        tipAboutPins(near: frame)
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
