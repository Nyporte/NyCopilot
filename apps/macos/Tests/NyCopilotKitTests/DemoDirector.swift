import AppKit
@testable import NyCopilotKit

/// Records the README's moving pictures. A full-screen stage shows a calm desktop and the app being
/// worked in; NyCopilot's real panels open over it, driven by synthesized events, while the
/// director moves a pointer along eased paths and shows each key pressed as a keycap. Every frame
/// is captured (only NyCopilot's own windows, so nothing else on the Mac shows), the pointer,
/// clicks, and keycaps are drawn on, and the frame goes into a GIF at 30 frames a second. Encoding
/// happens on its own queue, so a slow frame never stretches the script's timing.
///
/// It takes over the screen while it records, so it runs on GitHub's Macs (.github/workflows/demos.yml).
@MainActor
final class DemoDirector {
    enum Cursor { case arrow, crosshair, iBeam }

    let screen = NSScreen.screens[0]
    let stage: NSWindow
    /// The part of the screen that's recorded, in AppKit coordinates.
    let crop: NSRect
    private(set) var pointer: CGPoint
    var cursor: Cursor = .arrow

    nonisolated(unsafe) private let writer: GifWriter
    private let encoder = DispatchQueue(label: "demo-encoder")
    private let scale: CGFloat
    /// The frame being drawn. A fresh one each frame: the encoder reads the last on its own queue,
    /// and a bitmap shared with it would be cleared and redrawn mid-read, mixing frames together.
    private var context: CGContext
    private let pixels: (width: Int, height: Int)
    private var timer: Timer?
    private let start = CACurrentMediaTime()
    private var keys: [(time: Double, labels: [String])] = []
    private var clicks: [(time: Double, point: CGPoint)] = []

    var now: Double { CACurrentMediaTime() - start }

    /// `content` sits on the desktop, its frame given in points from the recorded area's top-left.
    init(output: URL, size: NSSize = NSSize(width: 960, height: 600), content: NSView, at origin: CGPoint) throws {
        let frame = screen.frame
        crop = NSRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2, width: size.width, height: size.height)
        scale = screen.backingScaleFactor
        let pixels = (Int(size.width * scale), Int(size.height * scale))
        guard let writer = GifWriter(url: output, width: pixels.0, height: pixels.1),
              let context = Self.bitmap(pixels)
        else { throw CocoaError(.fileWriteUnknown) }
        self.writer = writer
        self.context = context
        self.pixels = pixels
        stage = StageWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        let desktop = Desktop(frame: NSRect(origin: .zero, size: frame.size))
        stage.contentView = desktop
        content.frame.origin = CGPoint(x: crop.minX - frame.minX + origin.x,
                                       y: crop.maxY - frame.minY - origin.y - content.frame.height)
        desktop.addSubview(content)
        pointer = CGPoint(x: crop.midX + 220, y: crop.minY + 150)
        stage.orderFrontRegardless()
        stage.makeKey()
        print("demo: screen \(Int(frame.width))×\(Int(frame.height)) @\(scale)x, recording \(pixels.0)×\(pixels.1)")
    }

    // MARK: Recording

    func roll() {
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.frame() } }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        frame()
    }

    /// Stops recording, holding the last frame a moment so the loop doesn't jump, and closes every
    /// window the scene opened, so nothing carries into the next one.
    func cut(hold: Double = 1.2) -> Bool {
        wait(hold)
        timer?.invalidate()
        let end = now, writer = writer
        let done = encoder.sync { writer.finish(at: end) }
        NSApp.windows.filter(\.isVisible).forEach { $0.orderOut(nil) }
        return done
    }

    /// Lets everything run for `seconds`, recording.
    func wait(_ seconds: Double) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func frame() {
        let rect = CGRect(x: crop.minX, y: screen.frame.maxY - crop.maxY, width: crop.width, height: crop.height)
        // Opaque: the GIF writer draws each frame over the last, so any see-through pixel would let
        // earlier frames (a pointer, a keycap, a panel's old size) show through as a ghost.
        guard let shot = CGWindowListCreateImage(rect, .optionOnScreenOnly, kCGNullWindowID, [.bestResolution, .shouldBeOpaque]) else { return }
        if let raw = ProcessInfo.processInfo.environment["NYCOPILOT_DEMO_RAW"] { keepRaw(shot, in: raw) }
        guard let fresh = Self.bitmap(pixels) else { return }
        context = fresh
        let size = CGSize(width: context.width, height: context.height)
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(origin: .zero, size: size))
        context.draw(shot, in: CGRect(origin: .zero, size: size))
        let time = now
        drawClicks(at: time)
        drawPointer()
        drawKeys(at: time)
        guard let image = context.makeImage() else { return }
        let writer = writer
        encoder.async { writer.add(image, at: time) }
    }

    /// For checking the recorder: every tenth capture as it came from macOS, and how see-through it is.
    private var rawCount = 0
    private func keepRaw(_ shot: CGImage, in folder: String) {
        rawCount += 1
        guard rawCount % 10 == 1, let data = shot.dataProvider?.data as Data? else { return }
        var lowest: UInt8 = 255, seeThrough = 0
        let stride = shot.bytesPerRow, alphaFirst = [.first, .premultipliedFirst, .noneSkipFirst].contains(shot.alphaInfo)
        for y in Swift.stride(from: 0, to: shot.height, by: 4) {
            for x in Swift.stride(from: 0, to: shot.width, by: 4) {
                let alpha = data[y * stride + x * 4 + (alphaFirst ? 0 : 3)]
                lowest = min(lowest, alpha)
                if alpha < 250 { seeThrough += 1 }
            }
        }
        print("demo raw \(rawCount) t=\(String(format: "%.2f", now)) alphaInfo=\(shot.alphaInfo.rawValue) lowest alpha=\(lowest) see-through samples=\(seeThrough)")
        let url = URL(fileURLWithPath: folder).appendingPathComponent("raw-\(String(format: "%04d", rawCount)).png")
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? NSBitmapImageRep(cgImage: shot).representation(using: .png, properties: [:])?.write(to: url)
    }

    private static func bitmap(_ size: (width: Int, height: Int)) -> CGContext? {
        CGContext(data: nil, width: size.width, height: size.height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    // MARK: Pointer

    /// Glides the pointer to `target` along a gentle arc, easing in and out; `step` runs at every
    /// position (to send the matching mouse event).
    func move(to target: CGPoint, duration: Double = 0.7, arc: CGFloat = 0.12, step: ((CGPoint) -> Void)? = nil) {
        let from = pointer
        let distance = hypot(target.x - from.x, target.y - from.y)
        let normal = distance > 0 ? CGPoint(x: -(target.y - from.y) / distance, y: (target.x - from.x) / distance) : .zero
        let began = now
        while true {
            let t = min((now - began) / duration, 1)
            let eased = t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
            let bow = sin(.pi * eased) * distance * arc
            pointer = CGPoint(x: from.x + (target.x - from.x) * eased + normal.x * bow,
                              y: from.y + (target.y - from.y) * eased + normal.y * bow)
            step?(pointer)
            if t >= 1 { break }
            wait(1.0 / 60)
        }
    }

    /// A click where the pointer is: a soft ring in the recording.
    func click() { clicks.append((now, pointer)) }

    private func drawPointer() {
        let cursor: NSCursor = switch self.cursor {
        case .arrow: .arrow
        case .crosshair: .crosshair
        case .iBeam: .iBeam
        }
        let image = cursor.image, hot = cursor.hotSpot
        let point = local(pointer)
        let rect = CGRect(x: point.x - hot.x * scale, y: point.y - (image.size.height - hot.y) * scale,
                          width: image.size.width * scale, height: image.size.height * scale)
        drawInAppKit { image.draw(in: rect) }
    }

    private func drawClicks(at time: Double) {
        for click in clicks where time - click.time < 0.45 {
            let progress = CGFloat((time - click.time) / 0.45)
            let eased = 1 - pow(1 - progress, 3)
            let radius = (8 + 18 * eased) * scale
            let center = local(click.point)
            let ring = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            context.setFillColor(NSColor.white.withAlphaComponent(0.28 * (1 - progress)).cgColor)
            context.fillEllipse(in: ring)
            context.setStrokeColor(NSColor.controlAccentColor.withAlphaComponent(0.85 * (1 - progress)).cgColor)
            context.setLineWidth(2 * scale)
            context.strokeEllipse(in: ring)
        }
    }

    /// The pointer's place in the frame, in pixels from the bottom-left.
    private func local(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - crop.minX) * scale, y: (point.y - crop.minY) * scale)
    }

    // MARK: Keys

    /// Shows the keys as keycaps in the bottom-right corner, pressed then released.
    func press(_ labels: String...) { keys.append((now, labels)) }

    private func drawKeys(at time: Double) {
        guard let key = keys.last(where: { time - $0.time < 1.1 }) else { return }
        let age = time - key.time
        let alpha = CGFloat(min(age / 0.12, 1) * min((1.1 - age) / 0.3, 1))
        // Pressed for a moment, then up.
        let dip: CGFloat = age > 0.06 && age < 0.22 ? 0.94 : 1
        let font = NSFont.systemFont(ofSize: 21, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(white: 0.17, alpha: 1)]
        let height: CGFloat = 46, gap: CGFloat = 10
        let widths = key.labels.map { max(height, ($0 as NSString).size(withAttributes: attributes).width + 30) }
        let total = widths.reduce(0, +) + gap * CGFloat(widths.count - 1)
        // Bottom-right, out of the way of panels that open near the middle.
        var x = crop.width - total - 30
        let y: CGFloat = 30
        drawInAppKit {
            NSGraphicsContext.current?.cgContext.setAlpha(alpha)
            for (label, width) in zip(key.labels, widths) {
                let cap = NSRect(x: x * self.scale, y: y * self.scale, width: width * self.scale, height: height * self.scale)
                let pressed = cap.insetBy(dx: cap.width * (1 - dip) / 2, dy: cap.height * (1 - dip) / 2)
                    .offsetBy(dx: 0, dy: dip < 1 ? -2 * self.scale : 0)
                let shadow = NSShadow()
                shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
                shadow.shadowBlurRadius = 14 * self.scale
                shadow.shadowOffset = NSSize(width: 0, height: -5 * self.scale)
                NSGraphicsContext.saveGraphicsState()
                shadow.set()
                // The key's edge, then its face, a little lighter at the top.
                NSColor(white: 0.74, alpha: 1).setFill()
                NSBezierPath(roundedRect: pressed, xRadius: 10 * self.scale, yRadius: 10 * self.scale).fill()
                NSGraphicsContext.restoreGraphicsState()
                let face = NSRect(x: pressed.minX, y: pressed.minY + 3 * self.scale, width: pressed.width, height: pressed.height - 3 * self.scale)
                NSGradient(starting: NSColor(white: 0.93, alpha: 1), ending: NSColor(white: 0.99, alpha: 1))!
                    .draw(in: NSBezierPath(roundedRect: face, xRadius: 10 * self.scale, yRadius: 10 * self.scale), angle: 90)
                let big = NSFont.systemFont(ofSize: 21 * self.scale * dip, weight: .semibold)
                let text = NSAttributedString(string: label, attributes: [.font: big, .foregroundColor: NSColor(white: 0.17, alpha: 1)])
                let size = text.size()
                text.draw(at: NSPoint(x: face.midX - size.width / 2, y: face.midY - size.height / 2))
                x += width + gap
            }
        }
    }

    private func drawInAppKit(_ body: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        body()
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: Events

    /// A mouse event at the pointer, delivered to `window` as if it came from the hardware.
    func send(_ type: NSEvent.EventType, to window: NSWindow, modifiers: NSEvent.ModifierFlags = []) {
        let location = window.convertPoint(fromScreen: pointer)
        guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: modifiers,
                                             timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                             context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1) else { return }
        window.sendEvent(event)
    }

    /// A key press delivered to `window`.
    func type(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = [], to window: NSWindow) {
        for kind in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(with: kind, location: .zero, modifierFlags: modifiers,
                                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                               context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                               isARepeat: false, keyCode: keyCode) else { continue }
            window.sendEvent(event)
        }
    }

    /// Where a view's point is on screen (AppKit coordinates).
    func onScreen(_ point: CGPoint, in view: NSView) -> CGPoint {
        view.window?.convertPoint(toScreen: view.convert(point, to: nil)) ?? point
    }

    func onScreen(_ rect: CGRect, in view: NSView) -> CGRect {
        view.window?.convertToScreen(view.convert(rect, to: nil)) ?? rect
    }
}

private final class StageWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// A calm desktop: the README's indigo-to-blue, with a soft light in one corner.
private final class Desktop: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSGradient(colors: [NSColor(srgbRed: 0.31, green: 0.25, blue: 0.64, alpha: 1),
                            NSColor(srgbRed: 0.17, green: 0.38, blue: 0.66, alpha: 1)])!.draw(in: bounds, angle: -35)
        NSGradient(colors: [NSColor.white.withAlphaComponent(0.16), NSColor.white.withAlphaComponent(0)])!
            .draw(fromCenter: NSPoint(x: bounds.maxX * 0.72, y: bounds.maxY * 0.78), radius: 0,
                  toCenter: NSPoint(x: bounds.maxX * 0.72, y: bounds.maxY * 0.78), radius: bounds.width * 0.45, options: [])
    }
}
