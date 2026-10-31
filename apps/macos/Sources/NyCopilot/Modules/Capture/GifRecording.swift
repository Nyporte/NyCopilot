import AppKit
import Carbon
import CoreMedia
import ImageIO
import MacPlatform
import ScreenCaptureKit
import UniformTypeIdentifiers
import VideoToolbox

/// A finished GIF recording: the file (in NyCopilot's caches until it's saved somewhere) and what to
/// say about it.
struct GifClip {
    let url: URL
    /// Points, for laying out a preview.
    let size: CGSize
    let pixels: (width: Int, height: Int)
    let duration: TimeInterval
    let bytes: Int
}

/// GIF recording, run like scrolling capture: the selection stays outlined (in red) while you use the
/// computer as usual, and a small bar beside it shows the time, with pause and stop. Return (or the
/// stop button, or the capture shortcut again) stops; Esc discards. Recording ends on its own after a
/// minute. Frames go to disk as they come — a minute of frames held in memory would be gigabytes —
/// and become one GIF when you stop.
@MainActor
final class GifRecording {
    var onFinish: ((GifClip) -> Void)?
    var onCancel: (() -> Void)?
    var onFailure: ((Error) -> Void)?

    static let maximumDuration: TimeInterval = 60

    private let region: CGRect
    private let screen: NSScreen
    private let fps: Int
    private let pixelsPerPoint: CGFloat
    private let showsCursor: Bool
    private let border: NSWindow
    private let bar: RecordingBar
    private let frames: FrameSink
    private var stream: SCStream?
    private var keys: [GlobalHotKey] = []
    private var ticker: Timer?
    private var isOver = false

    /// `region` is in global top-left coordinates, on `screen`.
    init(region: CGRect, screen: NSScreen, fps: Int, retina: Bool, showsCursor: Bool) {
        self.region = region
        self.screen = screen
        self.fps = fps
        pixelsPerPoint = retina ? screen.backingScaleFactor : 1
        self.showsCursor = showsCursor
        let frame = CaptureSession.appKitRect(region)
        border = Self.makeBorder(around: frame)
        bar = RecordingBar(beside: frame, on: screen)
        frames = FrameSink(folder: FileManager.default.temporaryDirectory.appendingPathComponent("NyCopilot-GIF-\(UUID().uuidString)"))
        bar.onStop = { [weak self] in self?.stop() }
        bar.onPause = { [weak self] in self?.togglePause() }
    }

    var isRecording: Bool { !isOver }

    func start() {
        border.orderFrontRegardless()
        bar.orderFrontRegardless()
        claimKeys()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        Task { [weak self] in
            guard let self else { return }
            do { try await startStream() } catch {
                guard !isOver else { return }
                tearDown()
                frames.discard()
                onFailure?(error)
            }
        }
    }

    private func startStream() async throws {
        guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            throw ScreenGrabber.Failure.captureFailed
        }
        let content = try await ScreenGrabber.shareableContent(reusingRecent: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else { throw ScreenGrabber.Failure.captureFailed }
        // The outline, the bar, and pins stay out of the recording.
        let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let origin = CaptureSession.globalOrigin(of: screen)
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = region.offsetBy(dx: -origin.x, dy: -origin.y)
        configuration.width = max(2, Int((region.width * pixelsPerPoint).rounded()))
        configuration.height = max(2, Int((region.height * pixelsPerPoint).rounded()))
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.showsCursor = showsCursor
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        configuration.queueDepth = 5
        let stream = SCStream(filter: SCContentFilter(display: display, excludingApplications: own, exceptingWindows: []),
                              configuration: configuration, delegate: nil)
        try stream.addStreamOutput(frames, type: .screen, sampleHandlerQueue: frames.queue)
        frames.begin()
        try await stream.startCapture()
        if isOver { try? await stream.stopCapture(); return }
        self.stream = stream
    }

    private func tick() {
        let elapsed = frames.elapsed
        bar.show(elapsed: elapsed, paused: frames.isPaused)
        if elapsed >= Self.maximumDuration { stop() }
    }

    private func togglePause() {
        frames.setPaused(!frames.isPaused)
        (border.contentView as? BorderView)?.isPaused = frames.isPaused
        tick()
    }

    /// Return and Esc work whichever app has the focus, since you're working in another app.
    private func claimKeys() {
        let bindings: [(Int, Bool)] = [(kVK_Escape, false), (kVK_Return, true), (kVK_ANSI_KeypadEnter, true)]
        keys = bindings.compactMap { key, stops in
            GlobalHotKey.claim(HotKeyCombination(keyCode: UInt32(key), modifiers: 0)) { [weak self] in
                MainActor.assumeIsolated { stops ? self?.stop() : self?.cancel() }
            }
        }
    }

    /// Stops and makes the GIF; the bar says so while it's written.
    func stop() {
        guard !isOver else { return }
        let stream = stream
        tearDown(keepingBar: true)
        bar.showMaking()
        let frames = frames, fps = fps, scale = pixelsPerPoint
        Task { [weak self] in
            if let stream { try? await stream.stopCapture() }
            let clip = await Task.detached(priority: .userInitiated) { frames.makeGIF(fps: fps, pointsPerPixel: 1 / scale) }.value
            guard let self else { return }
            bar.orderOut(nil)
            if let clip { onFinish?(clip) } else { onFailure?(ScreenGrabber.Failure.captureFailed) }
        }
    }

    func cancel() {
        guard !isOver else { return }
        let stream = stream
        tearDown()
        Task { if let stream { try? await stream.stopCapture() } }
        frames.discard()
        onCancel?()
    }

    private func tearDown(keepingBar: Bool = false) {
        isOver = true
        stream = nil
        keys = []
        ticker?.invalidate()
        ticker = nil
        border.orderOut(nil)
        if !keepingBar { bar.orderOut(nil) }
    }

    /// A red outline just outside the region (dashed while paused); clicks go through it.
    private static func makeBorder(around frame: NSRect) -> NSWindow {
        let window = NSWindow(contentRect: frame.insetBy(dx: -3, dy: -3), styleMask: .borderless, backing: .buffered, defer: false)
        window.float(at: .statusBar, shadow: false, clickThrough: true, behavior: .ignoresCycle)
        window.contentView = BorderView()
        return window
    }

    private final class BorderView: NSView {
        var isPaused = false { didSet { needsDisplay = true } }

        override func draw(_ dirtyRect: NSRect) {
            let path = NSBezierPath(rect: bounds.insetBy(dx: 1.5, dy: 1.5))
            path.lineWidth = 2
            if isPaused { path.setLineDash([6, 4], count: 2, phase: 0) }
            NSColor.systemRed.setStroke()
            path.stroke()
        }
    }
}

/// Takes the stream's frames on its own queue and writes each as a PNG with its time; pausing
/// drops frames and takes the pause out of the timeline. `makeGIF` turns the files into one GIF.
final class FrameSink: NSObject, SCStreamOutput, @unchecked Sendable {
    let queue = DispatchQueue(label: "dev.nycopilot.capture.gif", qos: .userInitiated)
    private let folder: URL
    private let lock = NSLock()
    /// Frame files and their times on the recording's own clock (pauses taken out), in seconds.
    private var written: [(url: URL, time: Double)] = []
    private var started: Double?
    private var pausedAt: Double?
    private var pausedTotal: Double = 0
    private var stoppedAt: Double?
    /// Frames still being written; more than a few behind and new ones are dropped.
    private var backlog = 0

    init(folder: URL) {
        self.folder = folder
        super.init()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    static var now: Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds }

    func begin() { locked { started = Self.now } }

    var isPaused: Bool { locked { pausedAt != nil } }

    func setPaused(_ paused: Bool) {
        locked {
            if paused, pausedAt == nil { pausedAt = Self.now }
            if !paused, let pausedAt { pausedTotal += Self.now - pausedAt; self.pausedAt = nil }
        }
    }

    /// Recorded time, without pauses.
    var elapsed: TimeInterval {
        locked {
            guard let started else { return 0 }
            return (stoppedAt ?? pausedAt ?? Self.now) - started - pausedTotal
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, buffer.isValid, Self.isComplete(buffer), let pixels = buffer.imageBuffer else { return }
        accept(at: buffer.presentationTimeStamp.seconds) {
            var image: CGImage?
            VTCreateCGImageFromCVPixelBuffer(pixels, options: nil, imageOut: &image)
            return image
        }
    }

    /// A frame shown at `hostTime` (seconds on the host clock), unless paused, stopped, or too far
    /// behind; `image` is only made for a frame that's kept.
    func accept(at hostTime: Double, image: () -> CGImage?) {
        let accepted: (index: Int, time: Double)? = locked {
            guard let started, pausedAt == nil, stoppedAt == nil, backlog < 4 else { return nil }
            backlog += 1
            return (written.count + backlog - 1, hostTime - started - pausedTotal)
        }
        guard let accepted else { return }
        defer { locked { backlog -= 1 } }
        let url = folder.appendingPathComponent(String(format: "%05d.png", accepted.index))
        guard let image = image(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        if CGImageDestinationFinalize(destination) { locked { written.append((url, max(0, accepted.time))) } }
    }

    /// Only frames whose content changed carry an image; idle frames say so in their attachments.
    private static func isComplete(_ buffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, let status = SCFrameStatus(rawValue: raw) else { return false }
        return status == .complete
    }

    /// One looping GIF from the frames, each shown until the next arrived; nil without frames.
    func makeGIF(fps: Int, pointsPerPixel: CGFloat) -> GifClip? {
        let (frames, end): ([(url: URL, time: Double)], Double) = locked {
            let stop = stoppedAt ?? Self.now
            stoppedAt = stop
            // Stopped while paused: the recording ended when the pause began.
            let end = (pausedAt ?? stop) - (started ?? stop) - pausedTotal
            return (written.sorted { $0.time < $1.time }, end)
        }
        defer { discard() }
        guard !frames.isEmpty else { return nil }
        let output = Self.recordingsFolder.appendingPathComponent("Recording \(Self.stamp()).gif")
        try? FileManager.default.createDirectory(at: Self.recordingsFolder, withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.gif.identifier as CFString, frames.count, nil) else { return nil }
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        var size: (width: Int, height: Int) = (0, 0)
        let shortest = 1 / Double(fps)
        for (index, frame) in frames.enumerated() {
            guard let source = CGImageSourceCreateWithURL(frame.url as CFURL, nil) else { continue }
            if index == 0, let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
                size = (properties[kCGImagePropertyPixelWidth] as? Int ?? 0, properties[kCGImagePropertyPixelHeight] as? Int ?? 0)
            }
            let next = index + 1 < frames.count ? frames[index + 1].time : max(end, frame.time + shortest)
            // GIF delays are in hundredths of a second; viewers stretch anything under 0.02 s.
            let delay = max(0.02, (next - frame.time).rounded(toPlaces: 2))
            CGImageDestinationAddImageFromSource(destination, source, 0,
                                                 [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay,
                                                                                  kCGImagePropertyGIFUnclampedDelayTime: delay]] as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { return nil }
        let bytes = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int) ?? 0
        Diagnostics.note("capture", "GIF: \(frames.count) frames, \(size.width)×\(size.height), \(bytes / 1024) KB")
        return GifClip(url: output, size: CGSize(width: CGFloat(size.width) * pointsPerPixel, height: CGFloat(size.height) * pointsPerPixel),
                       pixels: size, duration: max(end, 0), bytes: bytes)
    }

    func discard() { try? FileManager.default.removeItem(at: folder) }

    /// Finished GIFs wait here until saved or copied; the folder is emptied at launch.
    static var recordingsFolder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("NyCopilot/Recordings", isDirectory: true)
    }

    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return formatter.string(from: Date())
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

extension GifRecording {
    /// Recordings left from an earlier run (copied or discarded long since).
    static func removeLeftovers() {
        try? FileManager.default.removeItem(at: FrameSink.recordingsFolder)
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let factor = pow(10, Double(places))
        return (self * factor).rounded() / factor
    }
}

/// The bar beside a recording: a red dot, the time out of a minute, pause, and stop.
private final class RecordingBar: NSPanel {
    var onStop: (() -> Void)?
    var onPause: (() -> Void)?

    private let dot = Design.symbol("circle.fill", size: 10, color: .systemRed)
    private let time = Design.label("0:00", size: 13, weight: .semibold, color: .white)
    private let hint = Design.label("↩ stop   esc discard", size: 11, color: NSColor.white.withAlphaComponent(0.6))
    private let pauseButton = NSButton()
    private let stopButton = NSButton()
    private let spinner = NSProgressIndicator()

    init(beside region: NSRect, on screen: NSScreen) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 250, height: 40), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        float(at: .statusBar, shadow: true)
        appearance = NSAppearance(named: .darkAqua)
        let material = NSVisualEffectView.roundedMaterial(.hudWindow, radius: 10)
        time.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        for (button, symbol, tip, action) in [(pauseButton, "pause.fill", "Pause", #selector(pauseTapped)),
                                              (stopButton, "stop.fill", "Stop (↩)", #selector(stopTapped))] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
            button.isBordered = false
            button.symbolConfiguration = .init(pointSize: 13, weight: .semibold)
            button.contentTintColor = .white
            button.toolTip = tip
            button.target = self
            button.action = action
            button.widthAnchor.constraint(equalToConstant: 26).isActive = true
        }
        stopButton.contentTintColor = .systemRed
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        let row = Design.hstack([dot, time, hint, Design.spacer(), spinner, pauseButton, stopButton], spacing: 8)
        row.translatesAutoresizingMaskIntoConstraints = false
        material.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: material.leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: material.trailingAnchor, constant: -8),
            row.centerYAnchor.constraint(equalTo: material.centerYAnchor)
        ])
        contentView = material
        // Below the region, else above it, else inside its bottom edge.
        let visible = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        var origin = NSPoint(x: min(max(region.maxX - frame.width, visible.minX), visible.maxX - frame.width), y: region.minY - frame.height - 10)
        if origin.y < visible.minY { origin.y = region.maxY + 10 }
        if origin.y + frame.height > visible.maxY { origin.y = region.minY + 10 }
        setFrameOrigin(origin)
    }

    override var canBecomeKey: Bool { false }

    func show(elapsed: TimeInterval, paused: Bool) {
        let seconds = Int(elapsed)
        time.stringValue = String(format: "%d:%02d", seconds / 60, seconds % 60) + (seconds >= Int(GifRecording.maximumDuration) - 10 ? " / 1:00" : "")
        dot.alphaValue = paused ? 0.35 : (dot.alphaValue < 1 ? 1 : 0.55)
        pauseButton.image = NSImage(systemSymbolName: paused ? "play.fill" : "pause.fill", accessibilityDescription: paused ? "Resume" : "Pause")
        pauseButton.toolTip = paused ? "Resume" : "Pause"
    }

    func showMaking() {
        hint.stringValue = "Making the GIF…"
        pauseButton.isHidden = true
        stopButton.isHidden = true
        spinner.startAnimation(nil)
    }

    @objc private func pauseTapped() { onPause?() }
    @objc private func stopTapped() { onStop?() }
}
