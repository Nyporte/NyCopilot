import AppKit
@testable import NyCopilotKit

/// Records the README's moving pictures. A full-screen stage shows a calm desktop and the app being
/// worked in; NyCopilot's real panels open over it, driven by synthesized events, while the
/// director moves a pointer along eased paths and shows each key pressed as a keycap. Every frame
/// is captured (only NyCopilot's own windows, so nothing else on the Mac shows), the pointer,
/// clicks, and keycaps are drawn on, and the frame goes into a GIF at 30 frames a second.
///
/// The script keeps its own time: each frame is a thirtieth of a second later than the one before,
/// however long the machine took to draw it, so motion stays even on a slow runner. Everything
/// gets at least that long to run between frames.
///
/// Without an output file it keeps the frames instead, for DemoReel or DemoSpot to put several scenes together.
///
/// It takes over the screen while it records, so it runs on GitHub's Macs (.github/workflows/demos.yml).
@MainActor
final class DemoDirector {
    enum Cursor { case arrow, crosshair, iBeam }
    enum Corner { case bottomLeft, bottomRight }

    let screen = NSScreen.screens[0]
    let stage: NSWindow
    /// The part of the screen that's recorded, in AppKit coordinates.
    let crop: NSRect
    private(set) var pointer = CGPoint.zero
    var cursor: Cursor = .arrow

    /// Where keycaps show.
    var keysCorner = Corner.bottomRight
    /// A key the recording shows some other way (DemoSpot's caption), so it isn't drawn in the corner too.
    var keysShownElsewhere: [String] = []
    /// A badge by the pointer while it scrolls, since a scroll has no key to show.
    var isScrolling = false
    /// Off for a scene that's only a backdrop.
    var showsPointer = true
    /// Where DemoSpot's camera looks from each moment on: a part of the recording, in points from
    /// its top-left, or nil for all of it.
    private(set) var camera: [(time: Double, focus: CGRect?)] = []
    /// The recording, when there's no output file: each frame and when it was shown.
    private(set) var frames: [(image: CGImage, time: Double)] = []
    private(set) var duration: Double = 0

    nonisolated(unsafe) private let writer: GifWriter?
    private let encoder = DispatchQueue(label: "demo-encoder")
    private let scale: CGFloat
    /// The frame being drawn. A fresh one each frame: the encoder reads the last on its own queue,
    /// and a bitmap shared with it would be cleared and redrawn mid-read, mixing frames together.
    private var context: CGContext
    private let pixels: (width: Int, height: Int)
    private var isRolling = false
    /// Each key pressed, and when.
    private(set) var keys: [(time: Double, labels: [String])] = []
    private var clicks: [(time: Double, point: CGPoint)] = []

    static let fps = 30.0
    /// The script's time, in seconds.
    private(set) var now = 0.0

    /// `content` sits on the desktop, its frame given in points from the recorded area's top-left.
    /// `backdrop` moves the desktop's light up (positive) or down, so scenes stacked by DemoReel
    /// join into one desktop.
    init(output: URL?, size: NSSize = NSSize(width: 960, height: 600), content: NSView, at origin: CGPoint, backdrop: CGFloat = 0) throws {
        let frame = screen.frame
        crop = NSRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2, width: size.width, height: size.height)
        scale = screen.backingScaleFactor
        let pixels = (Int(size.width * scale), Int(size.height * scale))
        guard let context = Self.bitmap(pixels) else { throw CocoaError(.fileWriteUnknown) }
        if let output {
            guard let writer = GifWriter(url: output, width: pixels.0, height: pixels.1) else { throw CocoaError(.fileWriteUnknown) }
            self.writer = writer
        } else {
            writer = nil
        }
        self.context = context
        self.pixels = pixels
        stage = StageWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        let desktop = Desktop(frame: NSRect(origin: .zero, size: frame.size))
        desktop.shift = backdrop
        stage.contentView = desktop
        place(content, at: origin)
        pointer = CGPoint(x: crop.midX + 220, y: crop.minY + 150)
        stage.orderFrontRegardless()
        stage.makeKey()
        print("demo: screen \(Int(frame.width))×\(Int(frame.height)) @\(scale)x, recording \(pixels.0)×\(pixels.1)")
    }

    /// Puts another window on the desktop, its frame given like `content`'s.
    func place(_ view: NSView, at origin: CGPoint) {
        let frame = screen.frame
        view.frame.origin = CGPoint(x: crop.minX - frame.minX + origin.x, y: crop.maxY - frame.minY - origin.y - view.frame.height)
        stage.contentView?.addSubview(view)
    }

    // MARK: Recording

    func roll() {
        isRolling = true
        frame()
    }

    /// Stops recording, holding the last frame a moment so the loop doesn't jump, and closes every
    /// window the scene opened, so nothing carries into the next one.
    func cut(hold: Double = 1.2) -> Bool {
        wait(hold)
        isRolling = false
        let end = now, writer = writer
        duration = end
        let done = encoder.sync { writer?.finish(at: end) ?? !frames.isEmpty }
        NSApp.windows.filter(\.isVisible).forEach { $0.orderOut(nil) }
        return done
    }

    /// Lets everything run for `seconds`, recording.
    func wait(_ seconds: Double) {
        let end = now + seconds
        while end - now > 1e-6 { step(min(1 / Self.fps, end - now)) }
    }

    /// The next frame, `seconds` later.
    private func step(_ seconds: Double) {
        now += seconds
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        if isRolling { frame() }
    }

    private func frame() {
        let rect = CGRect(x: crop.minX, y: screen.frame.maxY - crop.maxY, width: crop.width, height: crop.height)
        guard let shot = CGWindowListCreateImage(rect, .optionOnScreenOnly, kCGNullWindowID, [.bestResolution]) else { return }
        guard let fresh = Self.bitmap(pixels) else { return }
        context = fresh
        let size = CGSize(width: context.width, height: context.height)
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(origin: .zero, size: size))
        context.draw(shot, in: CGRect(origin: .zero, size: size))
        let time = now
        drawClicks(at: time)
        if showsPointer { drawPointer() }
        drawScrollHint()
        drawKeys(at: time)
        guard let image = context.makeImage() else { return }
        guard let writer else { frames.append((image, time)); return }
        encoder.async { writer.add(image, at: time) }
    }

    private static func bitmap(_ size: (width: Int, height: Int)) -> CGContext? {
        CGContext(data: nil, width: size.width, height: size.height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    /// Has DemoSpot's camera move in on `rect` (on screen, AppKit coordinates) from now, or back out for nil.
    func look(at rect: CGRect?) {
        camera.append((now, rect.map { CGRect(x: $0.minX - crop.minX, y: crop.maxY - $0.maxY, width: $0.width, height: $0.height) }))
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
            self.step(1 / Self.fps)
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

    private func drawScrollHint() {
        guard isScrolling,
              let symbol = NSImage(systemSymbolName: "arrow.up.and.down", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 12, weight: .bold).applying(.init(paletteColors: [.white]))) else { return }
        let point = local(pointer)
        let badge = CGRect(x: point.x + 14 * scale, y: point.y - 40 * scale, width: 26 * scale, height: 26 * scale)
        drawInAppKit {
            NSColor.black.withAlphaComponent(0.62).setFill()
            NSBezierPath(ovalIn: badge).fill()
            let size = NSSize(width: symbol.size.width * self.scale, height: symbol.size.height * self.scale)
            symbol.draw(in: NSRect(x: badge.midX - size.width / 2, y: badge.midY - size.height / 2, width: size.width, height: size.height))
        }
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

    /// Shows the keys as keycaps in the corner, pressed then released.
    func press(_ labels: String...) { keys.append((now, labels)) }

    private func drawKeys(at time: Double) {
        guard let key = keys.last(where: { time - $0.time < 1.1 && $0.labels != keysShownElsewhere }) else { return }
        let age = time - key.time
        let alpha = CGFloat(min(age / 0.12, 1) * min((1.1 - age) / 0.3, 1))
        // Pressed for a moment, then up.
        let dip: CGFloat = age > 0.06 && age < 0.22 ? 0.94 : 1
        let height: CGFloat = 34, gap: CGFloat = 8
        let widths = key.labels.map { DemoKeycap.width($0, height: height) }
        let total = widths.reduce(0, +) + gap * CGFloat(widths.count - 1)
        // In a corner, out of the way of panels that open near the middle.
        var x = keysCorner == .bottomRight ? crop.width - total - 30 : 30
        let y: CGFloat = keysCorner == .bottomRight ? 30 : 24
        drawInAppKit {
            NSGraphicsContext.current?.cgContext.setAlpha(alpha)
            for (label, width) in zip(key.labels, widths) {
                let cap = NSRect(x: x * self.scale, y: y * self.scale, width: width * self.scale, height: height * self.scale)
                DemoKeycap.draw(label, in: cap, scale: self.scale, dip: dip)
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
        // Drawn now, so the next frame captures the view as it is after this event, not before.
        window.displayIfNeeded()
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
    /// How far the whole desktop is drawn moved down, as if the screen showed a part of it higher up.
    var shift: CGFloat = 0

    override func draw(_ dirtyRect: NSRect) {
        let area = bounds.offsetBy(dx: 0, dy: -shift)
        NSColor(srgbRed: 0.24, green: 0.31, blue: 0.65, alpha: 1).setFill()
        bounds.fill()
        NSGradient(colors: [NSColor(srgbRed: 0.31, green: 0.25, blue: 0.64, alpha: 1),
                            NSColor(srgbRed: 0.17, green: 0.38, blue: 0.66, alpha: 1)])!.draw(in: area, angle: -35)
        NSGradient(colors: [NSColor.white.withAlphaComponent(0.16), NSColor.white.withAlphaComponent(0)])!
            .draw(fromCenter: NSPoint(x: area.minX + area.width * 0.72, y: area.minY + area.height * 0.78), radius: 0,
                  toCenter: NSPoint(x: area.minX + area.width * 0.72, y: area.minY + area.height * 0.78), radius: area.width * 0.45, options: [])
    }
}
