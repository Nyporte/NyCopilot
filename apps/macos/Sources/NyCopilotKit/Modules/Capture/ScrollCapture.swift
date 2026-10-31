import AppKit
import Carbon
import MacPlatform
@preconcurrency import ScreenCaptureKit

/// Scrolling capture. The selection stays outlined while you scroll whatever is under it, up or down.
/// The whole scrollable area around it is streamed — not just the selection — so every frame can be
/// placed exactly even after a fast scroll, and rows that went past the selection too quickly are
/// read from elsewhere in the area. Only the selection ends up in the image. A panel beside it shows
/// the image growing and finishes it like any capture: copy, save, or pin. While it runs, scrolling
/// over the area is held to a pace the capture can follow, and its keys work whichever window has focus.
@MainActor
final class ScrollCapture {
    var onFinish: ((CaptureAction, NSImage) -> Void)?
    var onCancel: (() -> Void)?
    /// The stream couldn't start; the outline and panel are already gone.
    var onFailure: ((Error) -> Void)?

    private let region: CGRect
    private let frozen: FrozenScreen
    /// Whether the frozen pixels of a global rectangle can stand in for the live screen (no pin on it).
    private let canSeed: (CGRect) -> Bool
    private let border: NSWindow
    private let panel: ScrollCapturePanel
    private var frames: FrameStitcher?
    private var stream: SCStream?
    private var pace: ScrollPace?
    private var keys: [GlobalHotKey] = []
    /// The selection as the screen showed it: the image until the stream has added to it.
    private var still: CGImage?
    private var isOver = false
    private var screen: NSScreen { frozen.screen }

    /// `region` is in global top-left coordinates, on the frozen screen.
    init(region: CGRect, frozen: FrozenScreen, canSeed: @escaping (CGRect) -> Bool) {
        self.region = region
        self.frozen = frozen
        self.canSeed = canSeed
        let frame = CaptureSession.appKitRect(region)
        border = Self.makeBorder(around: frame)
        panel = ScrollCapturePanel(beside: frame, on: frozen.screen)
        panel.onAction = { [weak self] action in self?.finish(action) }
        panel.onCancel = { [weak self] in self?.cancel() }
    }

    /// The outline, panel, and selection appear at once; the scroll area is found and the live stream
    /// joins a moment later, carrying on from what was on screen.
    func start() {
        border.orderFrontRegardless()
        panel.present()
        claimKeys()
        still = crop(region)
        panel.show(.started, height: still?.height ?? 0, thumbnail: still)
        let selection = region
        Task { [weak self] in
            // Accessibility can take a moment in a busy app; keep it off the main thread.
            let area = await Task.detached(priority: .userInitiated) { ScrollArea.around(selection) }.value
            guard let self, !isOver else { return }
            do { try await watch(area) } catch {
                guard !isOver else { return }
                stop()
                onFailure?(error)
            }
        }
    }

    /// Streams the selection's columns from the top to the bottom of the scroll area.
    private func watch(_ area: CGRect) async throws {
        let display = CGRect(origin: CaptureSession.globalOrigin(of: screen), size: screen.frame.size)
        let top = max(min(region.minY, area.minY), display.minY), bottom = min(max(region.maxY, area.maxY), display.maxY)
        let watched = CGRect(x: region.minX, y: top, width: region.width, height: bottom - top)
        let size = pixelSize(of: watched)
        let first = Int(((region.minY - watched.minY) * frozen.scale).rounded())
        let frames = FrameStitcher(selection: first..<min(size.height, first + pixelSize(of: region).height))
        frames.onUpdate = { [weak self] outcome, height, thumbnail in self?.panel.show(outcome, height: height, thumbnail: thumbnail) }
        self.frames = frames
        if canSeed(watched), let seed = crop(watched) { frames.seed(seed, size: size) }
        // Scroll steps of up to a third of the room above or below the selection: at 60 frames a
        // second, every row that passes the selection is still in the area in the next frame.
        pace = ScrollPace(region: watched, maxStep: 0.3 * min(region.maxY - watched.minY, watched.maxY - region.minY))
        try await stream(watched, size: size, into: frames)
    }

    private func pixelSize(of rect: CGRect) -> (width: Int, height: Int) {
        (Int((rect.width * frozen.scale).rounded()), Int((rect.height * frozen.scale).rounded()))
    }

    /// Part of the frozen screen, by global rectangle.
    private func crop(_ rect: CGRect) -> CGImage? {
        let origin = CaptureSession.globalOrigin(of: screen), size = pixelSize(of: rect)
        return frozen.image.cropping(to: CGRect(x: ((rect.minX - origin.x) * frozen.scale).rounded(),
                                                y: ((rect.minY - origin.y) * frozen.scale).rounded(), width: CGFloat(size.width), height: CGFloat(size.height)))
    }

    private func stream(_ watched: CGRect, size: (width: Int, height: Int), into frames: FrameStitcher) async throws {
        guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            throw ScreenGrabber.Failure.captureFailed
        }
        // F1 just looked this up; asking again would cost a noticeable moment.
        let content = try await ScreenGrabber.shareableContent(reusingRecent: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else { throw ScreenGrabber.Failure.captureFailed }
        // NyCopilot's own windows — the outline, the panel, pins — never appear in the image.
        let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let origin = CaptureSession.globalOrigin(of: screen)
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = watched.offsetBy(dx: -origin.x, dy: -origin.y)
        configuration.width = size.width
        configuration.height = size.height
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.showsCursor = false
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.queueDepth = 4
        let stream = try await CaptureStreams.shared.start(
            "scrolling capture", filter: SCContentFilter(display: display, excludingApplications: own, exceptingWindows: []),
            configuration: configuration, output: frames, queue: frames.queue) { [weak self] in
            // macOS ended it: keep what was stitched so far.
            self?.finish(.copy)
        }
        // Finished or cancelled while the stream was starting.
        if isOver { await CaptureStreams.shared.stop(stream); return }
        self.stream = stream
    }

    /// The capture's keys, claimed system-wide while it runs: clicking the page being scrolled
    /// moves the focus there, but Return, Esc, ⌘C, ⌘S, ⇧⌘S, and ⌘T still come here.
    private func claimKeys() {
        let command = HotKeyCombination.command, shift = HotKeyCombination.shift
        let bindings: [(key: Int, modifiers: UInt32, action: CaptureAction?)] = [
            (kVK_Escape, 0, nil), (kVK_Return, 0, .copy), (kVK_ANSI_KeypadEnter, 0, .copy), (kVK_ANSI_C, command, .copy),
            (kVK_ANSI_S, command, .save), (kVK_ANSI_S, command | shift, .quickSave), (kVK_ANSI_T, command, .pin)
        ]
        // Another app may own one of these; the panel still answers it when it has focus.
        keys = bindings.compactMap { binding in
            GlobalHotKey.claim(HotKeyCombination(keyCode: UInt32(binding.key), modifiers: binding.modifiers)) { [weak self] in
                MainActor.assumeIsolated {
                    if let action = binding.action { self?.finish(action) } else { self?.cancel() }
                }
            }
        }
    }

    private func finish(_ action: CaptureAction) {
        guard let image = frames?.image() ?? still else { return }
        stop()
        onFinish?(action, NSImage(cgImage: image, size: NSSize(width: CGFloat(image.width) / screen.backingScaleFactor,
                                                               height: CGFloat(image.height) / screen.backingScaleFactor)))
    }

    private func cancel() {
        stop()
        onCancel?()
    }

    private func stop() {
        isOver = true
        if let stream { Task { await CaptureStreams.shared.stop(stream) } }
        stream = nil
        pace?.stop()
        pace = nil
        keys = []
        border.orderOut(nil)
        panel.orderOut(nil)
    }

    /// A dashed accent outline just outside the region; clicks and scrolls go through it.
    private static func makeBorder(around frame: NSRect) -> NSWindow {
        let window = NSWindow(contentRect: frame.insetBy(dx: -3, dy: -3), styleMask: .borderless, backing: .buffered, defer: false)
        window.float(at: .statusBar, shadow: false, clickThrough: true, behavior: .ignoresCycle)
        let view = BorderView()
        window.contentView = view
        return window
    }

    private final class BorderView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            let path = NSBezierPath(rect: bounds.insetBy(dx: 1.5, dy: 1.5))
            path.lineWidth = 2
            path.setLineDash([6, 4], count: 2, phase: 0)
            NSColor.controlAccentColor.setStroke()
            path.stroke()
        }
    }
}

/// Holds scrolling that starts over the region to a pace the capture can follow — no step larger
/// than `maxStep` points — so nothing slips past between frames. Everywhere else, scrolling is left
/// alone. It needs Accessibility, which NyCopilot already has for Translate; without it, nothing changes.
private final class ScrollPace {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private let region: CGRect
    private let maxStep: Double

    /// `region` is in global top-left coordinates, the same as scroll events' locations.
    init(region: CGRect, maxStep: Double) {
        self.region = region
        self.maxStep = maxStep
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: CGEventMask(1 << CGEventType.scrollWheel.rawValue),
                                          callback: { _, type, event, info in
            if let info {
                let pace = Unmanaged<ScrollPace>.fromOpaque(info).takeUnretainedValue()
                switch type {
                case .tapDisabledByTimeout, .tapDisabledByUserInput:
                    if let tap = pace.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                case .scrollWheel where pace.region.contains(event.location):
                    ScrollPace.limit(event, to: pace.maxStep)
                default: break
                }
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    /// Scales every delta field together, so trackpads, mice, and momentum all slow the same way.
    static func limit(_ event: CGEvent, to maxStep: Double) {
        let points = Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1))
        guard abs(points) > maxStep else { return }
        let factor = maxStep / abs(points)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64((points * factor).rounded()))
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1,
                                  value: event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1) * factor)
        let lines = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        if lines != 0 {
            event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: lines.signum() * max(1, Int64((Double(abs(lines)) * factor).rounded())))
        }
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }
}

/// Receives stream frames on its own queue and stitches them there, so the main thread only ever
/// sees a small preview.
private final class FrameStitcher: NSObject, SCStreamOutput, @unchecked Sendable {
    let queue = DispatchQueue(label: "dev.nycopilot.scroll-capture", qos: .userInitiated)
    /// Called on the main thread with the latest outcome, total height in pixels, and a thumbnail of
    /// the whole image when it changed.
    var onUpdate: (@MainActor (ScrollStitcher.Outcome, Int, CGImage?) -> Void)?
    private let stitcher: ScrollStitcher

    /// `selection`: the rows of each frame that make up the image.
    init(selection: Range<Int>) {
        stitcher = ScrollStitcher(selection: selection)
        super.init()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .screen { process(sampleBuffer) }
    }

    /// The region as it was on screen, so the image starts before the stream does.
    func seed(_ image: CGImage, size: (width: Int, height: Int)) {
        queue.async { [self] in if let frame = Self.frame(from: image, size: size) { accept(frame) } }
    }

    func process(_ sampleBuffer: CMSampleBuffer) {
        // Only frames with new content; idle frames repeat the last one.
        guard sampleBuffer.isValid,
              let info = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = info.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let buffer = sampleBuffer.imageBuffer, let frame = Self.frame(from: buffer) else { return }
        accept(frame)
    }

    private func accept(_ frame: PixelFrame) {
        let outcome = stitcher.add(frame)
        let changed: Bool
        switch outcome {
        case .started, .added: changed = true
        default: changed = false
        }
        let thumbnail = changed ? stitcher.makeThumbnail() : nil
        let height = stitcher.height
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.onUpdate?(outcome, height, thumbnail) }
        }
    }

    /// Nil until the first frame.
    func image() -> CGImage? { queue.sync { stitcher.height > 0 ? stitcher.makeImage() : nil } }

    /// An image redrawn as BGRA rows of exactly the stream's size.
    private static func frame(from image: CGImage, size: (width: Int, height: Int)) -> PixelFrame? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var pixels = [UInt8](repeating: 0, count: size.width * size.height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: size.width, height: size.height, bitsPerComponent: 8,
                                          bytesPerRow: size.width * 4, space: space,
                                          bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)
            else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
            return true
        }
        return drawn ? PixelFrame(width: size.width, height: size.height, pixels: pixels) : nil
    }

    /// The pixel buffer's rows, without its row padding.
    private static func frame(from buffer: CVPixelBuffer) -> PixelFrame? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
              let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer), rowBytes = width * 4
        var pixels = [UInt8](repeating: 0, count: rowBytes * height)
        pixels.withUnsafeMutableBytes { out in
            for y in 0..<height {
                (out.baseAddress! + y * rowBytes).copyMemory(from: base + y * stride, byteCount: rowBytes)
            }
        }
        return PixelFrame(width: width, height: height, pixels: pixels)
    }
}

/// Beside the region: the whole image so far, its height, a hint, and the actions. It never
/// activates NyCopilot, so the app being scrolled stays in front.
@MainActor
final class ScrollCapturePanel: FloatingPanel {
    var onAction: ((CaptureAction) -> Void)?

    private let preview = WholePreview()
    private let size = Design.label("", size: 12, weight: .semibold, color: .white)
    private let hint = Design.wrapping("Scroll up or down in the outlined area.", size: 11.5)
    private let copyButton = NSButton(title: "Copy  ↩", target: nil, action: nil)

    init(beside region: NSRect, on screen: NSScreen) {
        let width: CGFloat = 228
        let height = min(max(region.height, 260), 420)
        super.init(size: NSSize(width: width, height: height), level: .statusBar, behavior: [])
        appearance = NSAppearance(named: .darkAqua)
        contentView = makeContent()
        setFrameOrigin(Self.origin(for: frame.size, beside: region, in: screen.visibleFrame))
        show(.started, height: 0, thumbnail: nil)
    }


    private func makeContent() -> NSView {
        let material = NSVisualEffectView.roundedMaterial(.hudWindow, radius: 12)
        hint.textColor = .white.withAlphaComponent(0.7)
        copyButton.bezelStyle = .rounded
        copyButton.bezelColor = .controlAccentColor
        copyButton.target = self
        copyButton.action = #selector(copyTapped)
        let icon = { (symbol: String, tip: String, action: Selector) -> NSButton in
            let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!, target: self, action: action)
            button.isBordered = false
            button.symbolConfiguration = .init(pointSize: 14, weight: .medium)
            button.contentTintColor = .white
            button.toolTip = tip
            button.widthAnchor.constraint(equalToConstant: 26).isActive = true
            return button
        }
        // As in the GIF preview: discard apart on the left, the likeliest on the right, Copy the default.
        let discard = icon("trash", "Discard (Esc)", #selector(cancelTapped))
        let buttons = [discard, icon("tray.and.arrow.down", "Keep in Inbox", #selector(inboxTapped)),
                       icon("square.and.arrow.down", "Save… (⌘S) · Quick save (⇧⌘S)", #selector(saveTapped)),
                       icon("pin", "Pin to screen (⌘T)", #selector(pinTapped))]
        let actions = Design.hstack([discard, Design.spacer()] + buttons.dropFirst().map { $0 as NSView } + [copyButton], spacing: 2)
        let column = Design.vstack([preview, size, hint, actions], spacing: 8, alignment: .leading)
        column.translatesAutoresizingMaskIntoConstraints = false
        material.addSubview(column)
        for view in [preview, hint, actions] { view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
        preview.setContentHuggingPriority(.init(1), for: .vertical)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: material.leadingAnchor, constant: 10),
            column.trailingAnchor.constraint(equalTo: material.trailingAnchor, constant: -10),
            column.topAnchor.constraint(equalTo: material.topAnchor, constant: 10),
            column.bottomAnchor.constraint(equalTo: material.bottomAnchor, constant: -10)
        ])
        return material
    }

    func show(_ outcome: ScrollStitcher.Outcome, height: Int, thumbnail: CGImage?) {
        if let thumbnail { preview.image = thumbnail }
        size.stringValue = height > 0 ? "\(height.formatted()) px tall" : "Starting…"
        copyButton.isEnabled = height > 0
        switch outcome {
        case .lost: hint.stringValue = "Too fast — scroll back a little to fill the gap."
        case .full: hint.stringValue = "That’s the maximum length. Copy, save, or pin it."
        case .added: hint.stringValue = "Keep scrolling either way, or press Return to copy."
        default: break
        }
    }

    /// Right of the region, else left, else inside its right edge.
    private static func origin(for size: NSSize, beside region: NSRect, in visible: NSRect) -> NSPoint {
        let top = min(region.maxY, visible.maxY) - size.height
        let y = max(visible.minY, top)
        if region.maxX + 12 + size.width <= visible.maxX { return NSPoint(x: region.maxX + 12, y: y) }
        if region.minX - 12 - size.width >= visible.minX { return NSPoint(x: region.minX - 12 - size.width, y: y) }
        return NSPoint(x: min(region.maxX, visible.maxX) - size.width - 12, y: y)
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        switch (event.keyCode, flags, key) {
        case (53, _, _): onCancel?()
        case (36, _, _), (76, _, _), (_, [.command], "c"): copyTapped()
        case (_, [.command], "s"): onAction?(.save)
        case (_, [.command, .shift], "s"): onAction?(.quickSave)
        case (_, [.command], "t"): onAction?(.pin)
        default: super.keyDown(with: event)
        }
    }


    @objc private func copyTapped() { if copyButton.isEnabled { onAction?(.copy) } }
    @objc private func saveTapped() { onAction?(NSEvent.modifierFlags.contains(.shift) ? .quickSave : .save) }
    @objc private func pinTapped() { onAction?(.pin) }
    @objc private func inboxTapped() { onAction?(.inbox) }
    @objc private func cancelTapped() { onCancel?() }
}

/// The whole image, fitted inside: as it grows taller it shrinks, so its full length is always in view.
private final class WholePreview: NSView {
    var image: CGImage? { didSet { needsDisplay = true } }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 120) }

    override func draw(_ dirtyRect: NSRect) {
        let frame = NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6)
        NSColor.black.withAlphaComponent(0.3).setFill()
        frame.fill()
        guard let image, let context = NSGraphicsContext.current?.cgContext else { return }
        let inner = bounds.insetBy(dx: 6, dy: 6)
        let scale = min(inner.width / CGFloat(image.width), inner.height / CGFloat(image.height))
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        // Centered across, top-aligned: the image grows downward, as the page does.
        let rect = CGRect(x: inner.midX - size.width / 2, y: inner.maxY - size.height, width: size.width, height: size.height)
        context.interpolationQuality = .high
        context.draw(image, in: rect)
        NSColor.white.withAlphaComponent(0.25).setStroke()
        NSBezierPath(rect: rect.insetBy(dx: -0.5, dy: -0.5)).stroke()
    }
}
