import AppKit
import Carbon
import MacPlatform

/// Screen translation: hold the translate shortcut and every line of text on every display is shown
/// translated, right where it is. The overlay lets every click and scroll through, so the computer
/// works as usual underneath, and it keeps up as the screen changes. Esc ends it.
///
/// Keeping up cheaply: each display is glanced at five times a second at an eighth of its resolution.
/// Where it changed, the translations there are taken down at once — nothing stale stays up — and once
/// it has settled, only the changed band of the screen is read again, at full resolution, and only
/// text not seen before is sent for translation.
@MainActor
final class ScreenTranslator {
    private let services: CopilotServices
    private var displays: [Display] = []
    private var watching: Task<Void, Never>?
    private var escape: GlobalHotKey?
    private var language = ""
    private var keys: [String: String] = [:]
    /// Lines translated this session, by their text in the language set when it started.
    private var translations: [String: String] = [:]

    var isActive: Bool { watching != nil }

    init(services: CopilotServices) { self.services = services }

    func toggle() { isActive ? stop() : start() }

    func start() {
        guard !isActive else { return }
        guard ScreenGrabber.hasPermission else {
            ScreenGrabber.requestPermission()
            services.toast.show("Allow Screen Recording to translate the screen",
                                detail: "Turn on NyCopilot in System Settings → Privacy & Security → Screen Recording.", style: .warning)
            return
        }
        guard services.preferences.canTranslate else {
            services.toast.show("Set up a translation service first", detail: "Settings → Translate or Settings → Model.", style: .warning)
            services.openSettings("translate")
            return
        }
        let target: String = services.core.setting(.targetLanguage, default: "English")
        if target != language { translations = [:] }
        language = target
        keys = ["api_key": (try? services.apiKey()) ?? "", "google_key": (try? services.googleKey()) ?? "",
                "volcengine_key": (try? services.volcengineKey()) ?? ""]
        let native = (try? services.core.call("translate.native_name", ["language": language]) as? [String: Any])?["native"] as? String ?? language
        displays = NSScreen.screens.map { Display(screen: $0, overlay: TranslationOverlay(screen: $0, language: native)) }
        displays.forEach { $0.overlay.orderFrontRegardless() }
        // Esc belongs to the overlay while it's up, whichever app is in front.
        escape = try? GlobalHotKey(identifier: 3000)
        escape?.onPress = { [weak self] in MainActor.assumeIsolated { self?.stop() } }
        try? escape?.register(HotKeyCombination(keyCode: UInt32(kVK_Escape), modifiers: 0))
        watching = Task { [weak self] in await self?.watch() }
    }

    func stop() {
        watching?.cancel()
        watching = nil
        escape = nil
        displays.forEach { $0.overlay.orderOut(nil) }
        displays = []
    }

    // MARK: Watching

    private final class Display {
        let screen: NSScreen
        let overlay: TranslationOverlay
        /// The last glance: one grey byte per 8 × 8 points.
        var glance: (pixels: [UInt8], width: Int, height: Int)?
        /// Lines on screen, with the colours to draw their translations in.
        var entries: [Entry] = []
        /// What needs reading again (screen points, top-left), and when it last changed.
        var pending: CGRect?
        var changedAt = Date.distantPast
        var lastRead = Date.distantPast
        var reading = false
        /// Changes while a read was under way: the lines it found there may already be gone.
        var changedDuringRead: [CGRect] = []

        init(screen: NSScreen, overlay: TranslationOverlay) {
            self.screen = screen
            self.overlay = overlay
            pending = CGRect(origin: .zero, size: screen.frame.size)
        }
    }

    struct Entry {
        let line: ScreenText.Line
        let background: NSColor
        let foreground: NSColor
    }

    private static let glanceScale: CGFloat = 1.0 / 8
    private static let cell = 2 // glance pixels per side of a cell: 16 points

    private func watch() async {
        while !Task.isCancelled {
            for display in displays { await glance(at: display) }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    private func glance(at display: Display) async {
        guard let image = try? await ScreenGrabber.snapshot(of: display.screen, pixelsPerPoint: Self.glanceScale),
              let grey = Self.grey(image), isActive else { return }
        if let last = display.glance, last.width == grey.width, last.height == grey.height {
            let changed = Self.changes(from: last, to: grey)
            if !changed.isEmpty {
                // Take down what's no longer true at once; read it again once it settles.
                display.entries.removeAll { entry in changed.contains { $0.intersects(entry.line.rect) } }
                render(display)
                display.pending = changed.reduce(display.pending ?? changed[0]) { $0.union($1) }
                display.changedAt = Date()
                if display.reading { display.changedDuringRead += changed }
            }
        }
        display.glance = grey
        let now = Date()
        if let pending = display.pending, !display.reading,
           now.timeIntervalSince(display.changedAt) >= 0.3, now.timeIntervalSince(display.lastRead) >= 0.6 {
            display.pending = nil
            display.reading = true
            display.changedDuringRead = []
            Task { await self.read(pending, on: display) }
        }
    }

    /// Reads a band of the screen again — the full width, so lines aren't cut — then translates what's new.
    private func read(_ region: CGRect, on display: Display) async {
        defer {
            display.reading = false
            display.lastRead = Date()
        }
        let size = display.screen.frame.size, scale = display.screen.backingScaleFactor
        // A small change re-reads its rows; a large one, the whole screen.
        var band = CGRect(x: 0, y: region.minY - 8, width: size.width, height: region.height + 16)
            .intersection(CGRect(origin: .zero, size: size))
        if band.height > size.height * 0.6 { band = CGRect(origin: .zero, size: size) }
        display.overlay.status = .reading
        guard let screenshot = try? await ScreenGrabber.snapshot(of: display.screen, pixelsPerPoint: scale),
              let crop = screenshot.cropping(to: CGRect(x: band.minX * scale, y: band.minY * scale,
                                                        width: band.width * scale, height: band.height * scale).integral),
              let lines = try? await ScreenText.lines(in: crop, scale: scale), isActive else {
            display.overlay.status = .idle
            return
        }
        let pixels = PixelSampler(crop, scale: scale, origin: band.origin)
        let code = ScreenText.code(for: language)
        let found = lines.map { ScreenText.Line(text: $0.text, rect: $0.rect.offsetBy(dx: band.minX, dy: band.minY)) }
            .filter { ScreenText.needsTranslation($0.text, into: code) }
            // Lines where the screen changed meanwhile wait for the next read.
            .filter { line in !display.changedDuringRead.contains { $0.intersects(line.rect) } }
            .map { line -> Entry in
                let background = pixels.background(around: line.rect)
                return Entry(line: line, background: background, foreground: background.isLight ? NSColor(white: 0.08, alpha: 1) : NSColor(white: 0.96, alpha: 1))
            }
        display.entries.removeAll { band.intersects($0.line.rect) }
        display.entries += found
        render(display)
        await translateMissing()
    }

    /// One batch for every line on every display that has no translation yet.
    private func translateMissing() async {
        var missing: [String] = [], seen = Set<String>(), bytes = 0
        for display in displays {
            for entry in display.entries where translations[entry.line.text] == nil && !seen.contains(entry.line.text) {
                guard missing.count < 400, bytes + entry.line.text.utf8.count < 60_000 else { break }
                seen.insert(entry.line.text)
                missing.append(entry.line.text)
                bytes += entry.line.text.utf8.count
            }
        }
        guard !missing.isEmpty else {
            displays.forEach { $0.overlay.status = .ready }
            return
        }
        displays.forEach { $0.overlay.status = .translating(missing.count) }
        struct Batch: Decodable { let texts: [String] }
        let params: [String: Any] = ["texts": missing, "target_language": language]
        do {
            let result = try await services.core.perform("translate.batch", params.merging(keys) { _, key in key }, as: Batch.self)
            guard isActive, result.texts.count == missing.count else { return }
            if translations.count > 5000 { translations = [:] }
            for (source, text) in zip(missing, result.texts) { translations[source] = text }
            displays.forEach { render($0); $0.overlay.status = .ready }
        } catch {
            displays.forEach { $0.overlay.status = .failed(error.localizedDescription) }
        }
    }

    private func render(_ display: Display) {
        display.overlay.show(display.entries.compactMap { entry in
            guard let text = translations[entry.line.text], text.trimmingCharacters(in: .whitespaces) != entry.line.text.trimmingCharacters(in: .whitespaces)
            else { return nil }
            return TranslationOverlay.Box(rect: entry.line.rect, text: text, background: entry.background, foreground: entry.foreground)
        })
    }

    // MARK: Glances

    /// One grey byte per pixel.
    static func grey(_ image: CGImage) -> (pixels: [UInt8], width: Int, height: Int)? {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? (pixels, width, height) : nil
    }

    /// Cells (in screen points, top-left) whose average grey moved noticeably between glances.
    static func changes(from old: (pixels: [UInt8], width: Int, height: Int), to new: (pixels: [UInt8], width: Int, height: Int)) -> [CGRect] {
        let points = 1 / glanceScale * CGFloat(cell)
        var changed: [CGRect] = []
        for cellY in stride(from: 0, to: new.height, by: cell) {
            for cellX in stride(from: 0, to: new.width, by: cell) {
                var difference = 0, count = 0
                for y in cellY..<min(cellY + cell, new.height) {
                    for x in cellX..<min(cellX + cell, new.width) {
                        difference += abs(Int(new.pixels[y * new.width + x]) - Int(old.pixels[y * new.width + x]))
                        count += 1
                    }
                }
                if difference > count * 6 {
                    changed.append(CGRect(x: CGFloat(cellX / cell) * points, y: CGFloat(cellY / cell) * points, width: points, height: points))
                }
            }
        }
        return changed
    }
}

/// Reads colours out of a screenshot, by screen point.
private struct PixelSampler {
    private let pixels: [UInt8]
    private let width: Int, height: Int
    private let scale: CGFloat, origin: CGPoint

    init(_ image: CGImage, scale: CGFloat, origin: CGPoint) {
        width = image.width
        height = image.height
        self.scale = scale
        self.origin = origin
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?
                .draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        self.pixels = pixels
    }

    private func sample(_ point: CGPoint) -> (Int, Int, Int)? {
        let x = Int((point.x - origin.x) * scale), y = Int((point.y - origin.y) * scale)
        guard (0..<width).contains(x), (0..<height).contains(y) else { return nil }
        let p = (y * width + x) * 4
        return (Int(pixels[p]), Int(pixels[p + 1]), Int(pixels[p + 2]))
    }

    /// The colour just around a line: the median of points along a ring a little outside it.
    func background(around rect: CGRect) -> NSColor {
        let ring = rect.insetBy(dx: -3, dy: -3)
        var samples: [(Int, Int, Int)] = []
        for step in 0...8 {
            let x = ring.minX + ring.width * CGFloat(step) / 8
            samples += [sample(CGPoint(x: x, y: ring.minY)), sample(CGPoint(x: x, y: ring.maxY))].compactMap { $0 }
        }
        samples += [sample(CGPoint(x: ring.minX, y: ring.midY)), sample(CGPoint(x: ring.maxX, y: ring.midY))].compactMap { $0 }
        guard !samples.isEmpty else { return .windowBackgroundColor }
        let middle = samples.count / 2
        func median(_ channel: (((Int, Int, Int)) -> Int)) -> CGFloat { CGFloat(samples.map(channel).sorted()[middle]) / 255 }
        return NSColor(srgbRed: median { $0.0 }, green: median { $0.1 }, blue: median { $0.2 }, alpha: 1)
    }
}

private extension NSColor {
    var isLight: Bool {
        guard let rgb = usingColorSpace(.sRGB) else { return true }
        return 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent > 0.55
    }
}

/// One display's overlay: the translations over their lines, a soft glow along the screen's edges,
/// and a small status pill at the top. Every click and scroll goes through to what's underneath.
@MainActor
final class TranslationOverlay: NSWindow {
    struct Box {
        let rect: CGRect
        let text: String
        let background: NSColor
        let foreground: NSColor
    }

    enum Status: Equatable {
        case idle, reading, translating(Int), ready, failed(String)
    }

    var status: Status = .reading { didSet { if status != oldValue { canvas.status = status } } }
    private let canvas: Canvas

    init(screen: NSScreen, language: String) {
        canvas = Canvas(language: language, dock: screen.visibleFrame.minY - screen.frame.minY)
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        contentView = canvas
        setFrame(screen.frame, display: false)
    }

    func show(_ boxes: [Box]) { canvas.boxes = boxes }

    private final class Canvas: NSView {
        var boxes: [Box] = [] { didSet { needsDisplay = true } }
        var status: Status = .reading { didSet { needsDisplay = true } }
        private let language: String
        /// The Dock's height at the bottom, if it's there.
        private let dock: CGFloat

        init(language: String, dock: CGFloat) {
            self.language = language
            self.dock = dock
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("Use init(language:dock:)") }

        override var isFlipped: Bool { true }

        override func draw(_ dirtyRect: NSRect) {
            for box in boxes { draw(box) }
            drawEdges()
            drawPill()
        }

        /// The translation over its line: the line's own background, the text fitted to the line's height
        /// and, if it can, its width; a longer translation widens the box rather than shrinking unreadably.
        private func draw(_ box: Box) {
            var rect = box.rect.insetBy(dx: -3, dy: -1.5)
            var size = max(9, box.rect.height * 0.78)
            var attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size), .foregroundColor: box.foreground]
            var width = (box.text as NSString).size(withAttributes: attributes).width
            if width > box.rect.width {
                size = max(9, size * box.rect.width / width)
                attributes[.font] = NSFont.systemFont(ofSize: size)
                width = (box.text as NSString).size(withAttributes: attributes).width
            }
            rect.size.width = min(max(rect.width, width + 6), bounds.maxX - rect.minX)
            // Opaque: the original must not show through beside a shorter translation.
            box.background.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
            let height = (box.text as NSString).size(withAttributes: attributes).height
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            attributes[.paragraphStyle] = paragraph
            (box.text as NSString).draw(in: CGRect(x: rect.minX + 3, y: rect.midY - height / 2, width: rect.width - 6, height: height),
                                        withAttributes: attributes)
        }

        /// A soft accent glow fading in from every edge: the screen is being translated.
        private func drawEdges() {
            let accent = NSColor.controlAccentColor
            for inset in 0..<6 {
                accent.withAlphaComponent(0.42 - CGFloat(inset) * 0.07).setStroke()
                let path = NSBezierPath(rect: bounds.insetBy(dx: CGFloat(inset) + 0.5, dy: CGFloat(inset) + 0.5))
                path.lineWidth = 1
                path.stroke()
            }
        }

        /// What's going on and how to leave, at the bottom just above the Dock, where there's usually
        /// the least text to cover.
        private func drawPill() {
            let state: String = switch status {
            case .idle, .ready: "Esc to exit"
            case .reading: "Reading the screen… · Esc to exit"
            case .translating(let count): "Translating \(count) line\(count == 1 ? "" : "s")… · Esc to exit"
            case .failed(let message): message
            }
            let text = NSMutableAttributedString(string: "Screen translation → \(language)", attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.white])
            text.append(NSAttributedString(string: "   \(state)", attributes: [
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.white.withAlphaComponent(0.75)]))
            let size = text.size()
            let height = size.height + 10
            let pill = CGRect(x: bounds.midX - size.width / 2 - 14, y: bounds.maxY - dock - height - 12, width: min(size.width + 28, bounds.width - 40), height: height)
            NSColor(white: 0.1, alpha: 0.82).setFill()
            NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
            NSColor.controlAccentColor.withAlphaComponent(0.8).setStroke()
            let outline = NSBezierPath(roundedRect: pill.insetBy(dx: 0.5, dy: 0.5), xRadius: pill.height / 2, yRadius: pill.height / 2)
            outline.lineWidth = 1
            outline.stroke()
            text.draw(with: pill.insetBy(dx: 14, dy: 5), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }
}
