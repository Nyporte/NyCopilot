import AppKit
import MacPlatform
import ScreenCaptureKit

/// Scrolling capture: the selected region is streamed live while you scroll whatever is under it,
/// and each frame is stitched onto the image as it arrives. A frame marks the region (scrolling
/// passes straight through it); a panel beside it shows the image growing and finishes it like any
/// capture — copy, save, or pin.
@MainActor
final class ScrollCapture {
    var onFinish: ((CaptureAction, NSImage) -> Void)?
    var onCancel: (() -> Void)?

    private let region: CGRect
    private let screen: NSScreen
    private let border: NSWindow
    private let panel: ScrollCapturePanel
    private let frames = FrameStitcher()
    private var stream: SCStream?

    /// `region` is in global top-left coordinates, on `screen`.
    init(region: CGRect, screen: NSScreen) {
        self.region = region
        self.screen = screen
        let frame = CaptureSession.appKitRect(region)
        border = Self.makeBorder(around: frame)
        panel = ScrollCapturePanel(beside: frame, on: screen)
        panel.onAction = { [weak self] action in self?.finish(action) }
        panel.onCancel = { [weak self] in self?.cancel() }
        frames.onUpdate = { [weak self] outcome, height, tail in self?.panel.show(outcome, height: height, tail: tail) }
    }

    func start() async throws {
        guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            throw ScreenGrabber.Failure.captureFailed
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else { throw ScreenGrabber.Failure.captureFailed }
        // NyCopilot's own windows — this frame, the panel, pins — never appear in the image.
        let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let origin = CaptureSession.globalOrigin(of: screen)
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = region.offsetBy(dx: -origin.x, dy: -origin.y)
        configuration.width = Int((region.width * screen.backingScaleFactor).rounded())
        configuration.height = Int((region.height * screen.backingScaleFactor).rounded())
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.showsCursor = false
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 4
        let stream = SCStream(filter: SCContentFilter(display: display, excludingApplications: own, exceptingWindows: []),
                              configuration: configuration, delegate: nil)
        try stream.addStreamOutput(frames, type: .screen, sampleHandlerQueue: frames.queue)
        border.orderFrontRegardless()
        panel.orderFrontRegardless()
        panel.makeKey()
        try await stream.startCapture()
        self.stream = stream
    }

    private func finish(_ action: CaptureAction) {
        stop()
        guard let image = frames.image() else { onCancel?(); return }
        onFinish?(action, NSImage(cgImage: image, size: NSSize(width: CGFloat(image.width) / screen.backingScaleFactor,
                                                               height: CGFloat(image.height) / screen.backingScaleFactor)))
    }

    private func cancel() {
        stop()
        onCancel?()
    }

    private func stop() {
        if let stream { Task { try? await stream.stopCapture() } }
        stream = nil
        border.orderOut(nil)
        panel.orderOut(nil)
    }

    /// A dashed accent outline just outside the region; clicks and scrolls go through it.
    private static func makeBorder(around frame: NSRect) -> NSWindow {
        let window = NSWindow(contentRect: frame.insetBy(dx: -3, dy: -3), styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
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

/// Receives stream frames on its own queue and stitches them there, so the main thread only ever
/// sees a small preview.
private final class FrameStitcher: NSObject, SCStreamOutput, @unchecked Sendable {
    let queue = DispatchQueue(label: "dev.nycopilot.scroll-capture", qos: .userInitiated)
    /// Called on the main thread with the latest outcome, total height in pixels, and the newest rows.
    var onUpdate: (@MainActor (ScrollStitcher.Outcome, Int, CGImage?) -> Void)?
    private let stitcher = ScrollStitcher()

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .screen { process(sampleBuffer) }
    }

    func process(_ sampleBuffer: CMSampleBuffer) {
        // Only frames with new content; idle frames repeat the last one.
        guard sampleBuffer.isValid,
              let info = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = info.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let buffer = sampleBuffer.imageBuffer, let frame = Self.frame(from: buffer) else { return }
        let outcome = stitcher.add(frame)
        let changed: Bool
        switch outcome {
        case .started, .appended: changed = true
        default: changed = false
        }
        let tail = changed ? stitcher.makeTail(rows: frame.height * 2) : nil
        let height = stitcher.height
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.onUpdate?(outcome, height, tail) }
        }
    }

    func image() -> CGImage? { queue.sync { stitcher.makeImage() } }

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

/// Beside the region: the image growing as you scroll, its height, a hint, and the actions.
/// It takes keys without activating NyCopilot, so the app being scrolled stays in front.
@MainActor
private final class ScrollCapturePanel: NSPanel {
    var onAction: ((CaptureAction) -> Void)?
    var onCancel: (() -> Void)?

    private let preview = TailPreview()
    private let size = Design.label("", size: 12, weight: .semibold, color: .white)
    private let hint = Design.wrapping("Scroll down in the outlined area. Go at a steady pace.", size: 11.5)
    private let copyButton = NSButton(title: "Copy  ↩", target: nil, action: nil)

    init(beside region: NSRect, on screen: NSScreen) {
        let width: CGFloat = 200
        let height = min(max(region.height, 260), 420)
        super.init(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        appearance = NSAppearance(named: .darkAqua)
        contentView = makeContent()
        setFrameOrigin(Self.origin(for: frame.size, beside: region, in: screen.visibleFrame))
        show(.started, height: 0, tail: nil)
    }

    override var canBecomeKey: Bool { true }

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
        let actions = Design.hstack([icon("xmark", "Cancel (Esc)", #selector(cancelTapped)),
                                     icon("square.and.arrow.down", "Save… (⌘S) · Quick save (⇧⌘S)", #selector(saveTapped)),
                                     icon("pin", "Pin to screen (⌘T)", #selector(pinTapped)), Design.spacer(), copyButton], spacing: 2)
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

    func show(_ outcome: ScrollStitcher.Outcome, height: Int, tail: CGImage?) {
        if let tail { preview.image = tail }
        size.stringValue = height > 0 ? "\(height.formatted()) px tall" : "Starting…"
        copyButton.isEnabled = height > 0
        switch outcome {
        case .lost: hint.stringValue = "Lost the place — scroll back up a little, then on."
        case .full: hint.stringValue = "That’s the maximum length. Copy, save, or pin it."
        case .appended: hint.stringValue = "Keep scrolling, or press Return to copy."
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

    override func cancelOperation(_ sender: Any?) { onCancel?() }

    @objc private func copyTapped() { if copyButton.isEnabled { onAction?(.copy) } }
    @objc private func saveTapped() { onAction?(NSEvent.modifierFlags.contains(.shift) ? .quickSave : .save) }
    @objc private func pinTapped() { onAction?(.pin) }
    @objc private func cancelTapped() { onCancel?() }
}

/// The newest rows, fitted to the width and anchored at the bottom, where new content arrives.
private final class TailPreview: NSView {
    var image: CGImage? { didSet { needsDisplay = true } }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 120) }

    override func draw(_ dirtyRect: NSRect) {
        let frame = NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6)
        NSColor.black.withAlphaComponent(0.3).setFill()
        frame.fill()
        guard let image, let context = NSGraphicsContext.current?.cgContext else { return }
        let scale = bounds.width / CGFloat(image.width)
        let height = CGFloat(image.height) * scale
        context.saveGState()
        frame.addClip()
        context.interpolationQuality = .high
        // Short images hug the top; taller ones keep their newest rows in view at the bottom.
        context.draw(image, in: CGRect(x: 0, y: max(0, bounds.height - height), width: bounds.width, height: height))
        context.restoreGState()
    }
}
