import AppKit
import Carbon
import CoreMedia
import MacPlatform
@preconcurrency import ScreenCaptureKit
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

/// GIF recording, run like scrolling capture, in two steps. First the area is armed — a white dashed
/// outline and a bar with a Record button — so you can set up what you'll show; Esc cancels. Record
/// (or the capture shortcut) starts it: the outline turns red, the bar shows the time with pause and
/// stop, and the capture shortcut or stop ends it. While recording, no key is taken from your apps, so
/// Return and Esc can be part of what you show. It ends on its own after a minute. Frames are encoded
/// as they come (see GifWriter), so stopping only closes the file.
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
    private let border: RegionOutline
    private let bar: RecordingBar
    private let frames: FrameSink
    private var stream: SCStream?
    private var keys: [GlobalHotKey] = []
    private var ticker: Timer?
    private enum Phase { case ready, recording, over }
    private var phase = Phase.ready
    private var isOver: Bool { phase == .over }

    /// `region` is in global top-left coordinates, on `screen`; `shortcut` names the capture
    /// shortcut, which starts and stops the recording.
    init(region: CGRect, screen: NSScreen, fps: Int, retina: Bool, showsCursor: Bool, shortcut: String) {
        self.region = region
        self.screen = screen
        self.fps = fps
        pixelsPerPoint = retina ? screen.backingScaleFactor : 1
        self.showsCursor = showsCursor
        let frame = ScreenGeometry.appKit(region)
        border = RegionOutline(around: frame, look: .ready)
        bar = RecordingBar(beside: frame, on: screen, shortcut: shortcut)
        frames = FrameSink(output: FrameSink.newRecordingURL())
        bar.onRecord = { [weak self] in self?.record() }
        bar.onStop = { [weak self] in self?.stop() }
        bar.onPause = { [weak self] in self?.togglePause() }
    }

    var isActive: Bool { !isOver }

    /// The capture shortcut: starts a ready recording, stops a running one.
    func shortcutPressed() {
        switch phase {
        case .ready: record()
        case .recording: stop()
        case .over: break
        }
    }

    /// Arms the area: the outline and the bar, waiting for Record. Esc cancels.
    func start() {
        border.orderFrontRegardless()
        bar.orderFrontRegardless()
        keys = [GlobalHotKey.claim(HotKeyCombination(keyCode: UInt32(kVK_Escape), modifiers: 0)) { [weak self] in
            MainActor.assumeIsolated { self?.cancel() }
        }].compactMap { $0 }
    }

    /// Starts recording; from here on every key goes to your apps.
    private func record() {
        guard phase == .ready else { return }
        phase = .recording
        keys = []
        border.look = .recording
        bar.showRecording()
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
        // The outline, the bar, and pins stay out of the recording.
        let filter = try await ScreenGrabber.filter(for: screen, excludingOwnWindows: true)
        let origin = ScreenGeometry.topLeftOrigin(of: screen)
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = region.offsetBy(dx: -origin.x, dy: -origin.y)
        configuration.width = max(2, Int((region.width * pixelsPerPoint).rounded()))
        configuration.height = max(2, Int((region.height * pixelsPerPoint).rounded()))
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.showsCursor = showsCursor
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        configuration.queueDepth = 5
        frames.begin()
        // macOS ended the stream itself: keep what was recorded rather than wait on a dead stream.
        let stream = try await CaptureStreams.shared.start(
            "GIF recording", filter: filter, configuration: configuration, output: frames, queue: frames.queue) { [weak self] in self?.stop() }
        if isOver { await CaptureStreams.shared.stop(stream); return }
        self.stream = stream
    }

    private func tick() {
        let elapsed = frames.elapsed
        bar.show(elapsed: elapsed, paused: frames.isPaused)
        if elapsed >= Self.maximumDuration { stop() }
    }

    private func togglePause() {
        frames.setPaused(!frames.isPaused)
        border.look = frames.isPaused ? .paused : .recording
        tick()
    }

    /// Stops and makes the GIF; the bar says so while it's written.
    func stop() {
        guard phase == .recording else { return }
        let stream = stream
        tearDown(keepingBar: true)
        bar.showMaking()
        let frames = frames, scale = pixelsPerPoint
        Task { [weak self] in
            if let stream { await CaptureStreams.shared.stop(stream) }
            let clip = await Task.detached(priority: .utility) { frames.makeGIF(pointsPerPixel: 1 / scale) }.value
            guard let self else { return }
            bar.orderOut(nil)
            if let clip { onFinish?(clip) } else { onFailure?(ScreenGrabber.Failure.captureFailed) }
        }
    }

    func cancel() {
        guard !isOver else { return }
        let stream = stream
        tearDown()
        Task { if let stream { await CaptureStreams.shared.stop(stream) } }
        frames.discard()
        onCancel?()
    }

    private func tearDown(keepingBar: Bool = false) {
        phase = .over
        stream = nil
        keys = []
        ticker?.invalidate()
        ticker = nil
        border.orderOut(nil)
        if !keepingBar { bar.orderOut(nil) }
    }
}

/// Takes the stream's frames on its own queue and adds each to the GIF as it comes (see GifWriter),
/// so stopping only has to close the file. Pausing drops frames and takes the pause out of the
/// timeline; a frame that arrives while the last is still being encoded is dropped.
final class FrameSink: NSObject, SCStreamOutput, @unchecked Sendable {
    let queue = DispatchQueue(label: "dev.nycopilot.capture.gif", qos: .utility)
    private let output: URL
    private let lock = NSLock()
    /// Only touched on `queue`.
    private var writer: GifWriter?
    private var started: Double?
    private var pausedAt: Double?
    private var pausedTotal: Double = 0
    private var stoppedAt: Double?
    private var isEncoding = false

    init(output: URL) {
        self.output = output
        super.init()
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

    /// A frame shown at `hostTime` (seconds on the host clock), unless paused or stopped; `image`
    /// is only made for a frame that's kept. Call on `queue`.
    func accept(at hostTime: Double, image: () -> CGImage?) {
        let time: Double? = locked {
            guard let started, pausedAt == nil, stoppedAt == nil, !isEncoding else { return nil }
            isEncoding = true
            return max(0, hostTime - started - pausedTotal)
        }
        guard let time else { return }
        defer { locked { isEncoding = false } }
        guard let image = image() else { return }
        if writer == nil {
            try? FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            writer = GifWriter(url: output, width: image.width, height: image.height)
        }
        writer?.add(image, at: time)
    }

    /// Only frames whose content changed carry an image; idle frames say so in their attachments.
    private static func isComplete(_ buffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, let status = SCFrameStatus(rawValue: raw) else { return false }
        return status == .complete
    }

    /// Closes the GIF, the last frame shown until the recording stopped; nil without frames.
    func makeGIF(pointsPerPixel: CGFloat) -> GifClip? {
        let end: Double = locked {
            let stop = stoppedAt ?? Self.now
            stoppedAt = stop
            // Stopped while paused: the recording ended when the pause began.
            return max(0, (pausedAt ?? stop) - (started ?? stop) - pausedTotal)
        }
        // After any frame still being encoded.
        return queue.sync {
            guard let writer, writer.finish(at: end) else { discardNow(); return nil }
            let bytes = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int) ?? 0
            Diagnostics.note("capture", "GIF: \(writer.frameCount) frames, \(writer.width)×\(writer.height), \(bytes / 1024) KB")
            return GifClip(url: output, size: CGSize(width: CGFloat(writer.width) * pointsPerPixel, height: CGFloat(writer.height) * pointsPerPixel),
                           pixels: (writer.width, writer.height), duration: end, bytes: bytes)
        }
    }

    func discard() {
        locked { stoppedAt = stoppedAt ?? Self.now }
        queue.async { [self] in discardNow() }
    }

    private func discardNow() {
        writer?.finish(at: 0)
        writer = nil
        try? FileManager.default.removeItem(at: output)
    }

    /// Finished GIFs wait here until saved or copied; the folder is emptied at launch.
    static var recordingsFolder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("NyCopilot/Recordings", isDirectory: true)
    }

    static func newRecordingURL() -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return recordingsFolder.appendingPathComponent("Recording \(formatter.string(from: Date())).gif")
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


/// The bar beside a recording. Ready: a red Record button and how to start or cancel. Recording: a
/// red dot, the time out of a minute, pause, and stop.
final class RecordingBar: FloatingPanel {
    var onRecord: (() -> Void)?
    var onStop: (() -> Void)?
    var onPause: (() -> Void)?

    private let shortcut: String
    private let recordButton = NSButton()
    private let dot = Design.symbol("circle.fill", size: 10, color: .systemRed)
    private let time = Design.label(L("0:00"), size: 13, weight: .semibold, color: .white)
    private let hint = Design.label("", size: 11, color: NSColor.white.withAlphaComponent(0.6))
    private let pauseButton = NSButton()
    private let stopButton = NSButton()
    private let spinner = NSProgressIndicator()

    init(beside region: NSRect, on screen: NSScreen, shortcut: String) {
        self.shortcut = shortcut
        super.init(size: NSSize(width: 250, height: 40), level: .statusBar, behavior: [])
        // It only shows; your keys stay with the app you're recording.
        takesKeys = false
        appearance = NSAppearance(named: .darkAqua)
        let material = NSVisualEffectView.roundedMaterial(.hudWindow, radius: 10)
        time.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        // Drawn as its own red pill: a bezel's tint only shows in a key window, and this bar never is one.
        recordButton.isBordered = false
        recordButton.wantsLayer = true
        recordButton.layer?.backgroundColor = NSColor.systemRed.cgColor
        recordButton.layer?.cornerRadius = 12
        recordButton.attributedTitle = NSAttributedString(string: L("  ● Record  "), attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.white])
        recordButton.heightAnchor.constraint(equalToConstant: 24).isActive = true
        recordButton.toolTip = L("Start recording (%@)", shortcut)
        recordButton.target = self
        recordButton.action = #selector(recordTapped)
        for (button, symbol, tip, action) in [(pauseButton, "pause.fill", L("Pause"), #selector(pauseTapped)),
                                              (stopButton, "stop.fill", L("Stop (%@)", shortcut), #selector(stopTapped))] {
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
        let row = Design.hstack([recordButton, dot, time, hint, Design.spacer(), spinner, pauseButton, stopButton], spacing: 8)
        row.translatesAutoresizingMaskIntoConstraints = false
        material.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: material.leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: material.trailingAnchor, constant: -8),
            row.centerYAnchor.constraint(equalTo: material.centerYAnchor)
        ])
        contentView = material
        showReady()
        // Below the region, else above it, else inside its bottom edge.
        let visible = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        var origin = NSPoint(x: min(max(region.maxX - frame.width, visible.minX), visible.maxX - frame.width), y: region.minY - frame.height - 10)
        if origin.y < visible.minY { origin.y = region.maxY + 10 }
        if origin.y + frame.height > visible.maxY { origin.y = region.minY + 10 }
        setFrameOrigin(origin)
    }


    private func showReady() {
        hint.stringValue = L("%@ start   esc cancel", shortcut)
        for view in [dot, time, pauseButton, stopButton] as [NSView] { view.isHidden = true }
    }

    func showRecording() {
        recordButton.isHidden = true
        for view in [dot, time, pauseButton, stopButton] as [NSView] { view.isHidden = false }
        hint.stringValue = L("%@ stop", shortcut)
        show(elapsed: 0, paused: false)
    }

    func show(elapsed: TimeInterval, paused: Bool) {
        let seconds = Int(elapsed)
        time.stringValue = String(format: "%d:%02d", seconds / 60, seconds % 60) + (seconds >= Int(GifRecording.maximumDuration) - 10 ? " / 1:00" : "")
        dot.alphaValue = paused ? 0.35 : (dot.alphaValue < 1 ? 1 : 0.55)
        pauseButton.image = NSImage(systemSymbolName: paused ? "play.fill" : "pause.fill", accessibilityDescription: paused ? L("Resume") : L("Pause"))
        pauseButton.toolTip = paused ? L("Resume") : L("Pause")
    }

    func showMaking() {
        hint.stringValue = L("Making the GIF…")
        pauseButton.isHidden = true
        stopButton.isHidden = true
        spinner.startAnimation(nil)
    }

    @objc private func recordTapped() { onRecord?() }
    @objc private func pauseTapped() { onPause?() }
    @objc private func stopTapped() { onStop?() }
}
