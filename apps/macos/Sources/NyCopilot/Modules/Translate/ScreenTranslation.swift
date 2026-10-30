import AppKit
import Carbon
import MacPlatform

/// Screen translation: hold the translate shortcut and every line of text on every display is
/// highlighted, like Live Text. Point at a block not in your language and a card with its translation
/// floats beside it. The page itself is left exactly as it is. The overlay lets every click and scroll
/// through, so the computer works as usual underneath, and it keeps up as the screen changes. Esc ends it.
///
/// Keeping up cheaply: each display is glanced at five times a second at an eighth of its resolution.
/// Where it changed, the highlights there are taken down at once — nothing stale stays up — and once
/// it has settled, only the changed band of the screen is read again, at full resolution. Everything
/// highlighted is translated in the background, so cards are usually ready before they're asked for;
/// a block pointed at before then is translated first.
@MainActor
final class ScreenTranslator {
    private let services: CopilotServices
    private var displays: [Display] = []
    private var watching: Task<Void, Never>?
    private var escape: GlobalHotKey?
    /// Pointer movement, watched (never caught), so cards follow the pointer while clicks go through.
    private var pointerMonitors: [Any] = []
    private let card = TranslationCard()
    /// The block under the pointer, and the card about to show for it.
    private var hovered: (display: Display, paragraph: Paragraph)?
    private var pendingCard: DispatchWorkItem?
    private var language = "", nativeLanguage = ""
    private var keys: [String: String] = [:]
    /// Blocks translated this session, by their text, in the language set when it started.
    private var translations: [String: String] = [:]
    /// Blocks out for translation right now, so none is asked for twice.
    private var requested: Set<String> = []

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
        nativeLanguage = (try? services.core.call("translate.native_name", ["language": language]) as? [String: Any])?["native"] as? String ?? language
        keys = ["api_key": (try? services.apiKey()) ?? "", "google_key": (try? services.googleKey()) ?? "",
                "volcengine_key": (try? services.volcengineKey()) ?? ""]
        displays = NSScreen.screens.map { Display(screen: $0, overlay: TranslationOverlay(screen: $0, language: nativeLanguage)) }
        displays.forEach { $0.overlay.orderFrontRegardless() }
        // Esc belongs to the overlay while it's up, whichever app is in front.
        escape = try? GlobalHotKey(identifier: 3000)
        escape?.onPress = { [weak self] in MainActor.assumeIsolated { self?.stop() } }
        try? escape?.register(HotKeyCombination(keyCode: UInt32(kVK_Escape), modifiers: 0))
        let moved: (NSEvent?) -> Void = { [weak self] _ in MainActor.assumeIsolated { self?.pointerMoved() } }
        let kinds: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .scrollWheel]
        pointerMonitors = [NSEvent.addGlobalMonitorForEvents(matching: kinds) { moved($0) } as Any,
                           NSEvent.addLocalMonitorForEvents(matching: kinds) { moved($0); return $0 } as Any]
        watching = Task { [weak self] in await self?.watch() }
    }

    func stop() {
        watching?.cancel()
        watching = nil
        escape = nil
        pointerMonitors.forEach(NSEvent.removeMonitor)
        pointerMonitors = []
        hover(nil)
        displays.forEach { $0.overlay.orderOut(nil) }
        displays = []
        requested = []
    }

    // MARK: Blocks of text

    private final class Display {
        let screen: NSScreen
        let overlay: TranslationOverlay
        /// The last glance: one grey byte per 8 × 8 points.
        var glance: (pixels: [UInt8], width: Int, height: Int)?
        /// Lines on screen, and the blocks they make up.
        var entries: [Entry] = []
        var paragraphs: [Paragraph] = []
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
        /// The original's font size, as best it can be told.
        let fontSize: CGFloat
    }

    /// Lines wrapped from one paragraph: pointed at and translated as one block.
    struct Paragraph {
        let entries: [Entry]
        let text: String
        let rect: CGRect
        /// Not already in the target language (nor just numbers or symbols): it gets a card.
        let needsTranslation: Bool
    }

    /// Lines into paragraphs: directly below one another at line spacing, in the same column, the
    /// same size, on the same background. Only a line long enough to have wrapped carries on to the
    /// next — short labels stacked in a sidebar or a menu stay apart, and a paragraph's short last line
    /// ends it — and a bullet or number starts a new one.
    static func paragraphs(_ entries: [Entry], language code: String?) -> [Paragraph] {
        var groups: [[Entry]] = []
        for entry in entries.sorted(by: { $0.line.rect.minY < $1.line.rect.minY }) {
            let candidates = groups.indices.filter { continues(groups[$0], with: entry) }
            // The paragraph whose last line sits closest above.
            if let index = candidates.max(by: { groups[$0].last!.line.rect.maxY < groups[$1].last!.line.rect.maxY }) {
                groups[index].append(entry)
            } else {
                groups.append([entry])
            }
        }
        return groups.map { group in
            let text = ScreenText.joined(group.map(\.line.text))
            return Paragraph(entries: group, text: text, rect: group.map(\.line.rect).reduce(group[0].line.rect) { $0.union($1) },
                             needsTranslation: ScreenText.needsTranslation(text, into: code))
        }
    }

    private static func continues(_ group: [Entry], with next: Entry) -> Bool {
        let last = group.last!, above = last.line.rect, below = next.line.rect, size = last.fontSize
        guard abs(next.fontSize - size) <= size * 0.2 else { return false }
        let gap = below.minY - above.maxY
        guard gap >= -size * 0.3, gap <= size * 0.75 else { return false }
        let overlap = min(above.maxX, below.maxX) - max(above.minX, below.minX)
        guard abs(above.minX - below.minX) <= max(size * 1.2, 8) || overlap >= min(above.width, below.width) * 0.8 else { return false }
        guard last.background.resembles(next.background) else { return false }
        let widest = max(group.map(\.line.rect.width).max()!, below.width)
        guard above.width >= widest * 0.75, above.width >= size * 12 else { return false }
        let start = next.line.text.trimmingCharacters(in: .whitespaces)
        if let first = start.first, "•·-–—*▪◦●".contains(first) || (first.isNumber && start.dropFirst().prefix(2).contains { ".)、".contains($0) }) {
            return false
        }
        return true
    }

    // MARK: Watching

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
                update(display)
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
            display.overlay.status = .ready
            return
        }
        let pixels = PixelSampler(crop, scale: scale, origin: band.origin)
        // Every line is highlighted, whatever its language — only blocks that need it get translated.
        let found = lines.map { ScreenText.Line(text: $0.text, rect: $0.rect.offsetBy(dx: band.minX, dy: band.minY)) }
            // Lines where the screen changed meanwhile wait for the next read.
            .filter { line in !display.changedDuringRead.contains { $0.intersects(line.rect) } }
            .map { Entry(line: $0, background: pixels.background(around: $0.rect), fontSize: ScreenText.fontSize(of: $0)) }
        display.entries.removeAll { band.intersects($0.line.rect) }
        display.entries += found
        update(display)
        display.overlay.status = .ready
        await translate(displays.flatMap(\.paragraphs).filter(\.needsTranslation).map(\.text))
    }

    /// Regroups a display's blocks and redraws its highlights; the card follows if its block went away.
    private func update(_ display: Display) {
        display.paragraphs = Self.paragraphs(display.entries, language: ScreenText.code(for: language))
        display.overlay.show(display.entries.map(\.line.rect))
        pointerMoved()
    }

    // MARK: Translating

    /// The texts without a translation yet, in one batch; the card updates if it was waiting on one.
    private func translate(_ texts: [String]) async {
        var missing: [String] = [], bytes = 0
        for text in texts where translations[text] == nil && !requested.contains(text) && !missing.contains(text) {
            guard missing.count < 400, bytes + text.utf8.count < 60_000 else { break }
            missing.append(text)
            bytes += text.utf8.count
        }
        guard !missing.isEmpty else { return }
        requested.formUnion(missing)
        if missing.count > 1 { displays.forEach { $0.overlay.status = .translating(missing.count) } }
        defer { requested.subtract(missing) }
        struct Batch: Decodable { let texts: [String] }
        let params: [String: Any] = ["texts": missing, "target_language": language]
        do {
            let result = try await services.core.perform("translate.batch", params.merging(keys) { _, key in key }, as: Batch.self)
            guard isActive, result.texts.count == missing.count else { return }
            if translations.count > 5000 { translations = [:] }
            for (source, text) in zip(missing, result.texts) { translations[source] = text }
            displays.forEach { $0.overlay.status = .ready }
            if let hovered, card.isVisible, let text = translations[hovered.paragraph.text] { card.show(text) }
        } catch {
            guard isActive else { return }
            displays.forEach { $0.overlay.status = .failed(error.localizedDescription) }
            if let hovered, card.isVisible, missing.contains(hovered.paragraph.text) { card.show(failure: error.localizedDescription) }
        }
    }

    // MARK: Pointing

    /// The block under the pointer, if any, becomes the hovered one.
    private func pointerMoved() {
        let location = NSEvent.mouseLocation
        guard let display = displays.first(where: { $0.screen.frame.contains(location) }) else { hover(nil); return }
        let point = CGPoint(x: location.x - display.screen.frame.minX, y: display.screen.frame.maxY - location.y)
        hover(display.paragraphs.last { $0.rect.insetBy(dx: -4, dy: -3).contains(point) }.map { (display, $0) })
    }

    /// Brightens the block's highlight at once; its card follows after a brief pause, so moving across
    /// the page doesn't flicker cards.
    private func hover(_ target: (display: Display, paragraph: Paragraph)?) {
        if target?.display === hovered?.display, target?.paragraph.text == hovered?.paragraph.text, target?.paragraph.rect == hovered?.paragraph.rect { return }
        hovered = target
        displays.forEach { $0.overlay.hovered = $0 === target?.display ? target?.paragraph.entries.map(\.line.rect) ?? [] : [] }
        pendingCard?.cancel()
        card.orderOut(nil)
        // Text already in your language is highlighted but has nothing to show.
        guard let target, target.paragraph.needsTranslation else { return }
        let work = DispatchWorkItem { [weak self] in self?.present(target) }
        pendingCard = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private func present(_ target: (display: Display, paragraph: Paragraph)) {
        let frame = target.display.screen.frame, rect = target.paragraph.rect
        let source = NSRect(x: frame.minX + rect.minX, y: frame.maxY - rect.maxY, width: rect.width, height: rect.height)
        card.present(language: nativeLanguage, beside: source, on: target.display.screen)
        if let text = translations[target.paragraph.text] {
            card.show(text)
        } else {
            // Pointed at before the background batch got to it: this one goes first, on its own.
            card.showWaiting()
            Task { await translate([target.paragraph.text]) }
        }
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

/// Reads the colour around a line out of a screenshot, by screen point, to tell blocks on different
/// backgrounds apart.
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
    /// Near enough to be the same background.
    func resembles(_ other: NSColor) -> Bool {
        guard let a = usingColorSpace(.sRGB), let b = other.usingColorSpace(.sRGB) else { return false }
        return abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent) + abs(a.blueComponent - b.blueComponent) < 0.25
    }
}

/// One display's overlay, in the manner of Live Text: the screen dimmed a little except for its lines
/// of text, which glow; the block under the pointer outlined; a glow along the screen's edges; and a
/// status pill. Every click and scroll goes through to what's underneath.
@MainActor
final class TranslationOverlay: NSWindow {
    enum Status: Equatable {
        case reading, translating(Int), ready, failed(String)
    }

    var status: Status = .reading { didSet { if status != oldValue { canvas.status = status } } }
    /// The lines of the block under the pointer, in this display's points (top-left).
    var hovered: [CGRect] = [] { didSet { if hovered != oldValue { canvas.hovered = hovered } } }
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

    /// The lines to highlight, in this display's points (top-left).
    func show(_ lines: [CGRect]) { canvas.lines = lines }

    private final class Canvas: NSView {
        var lines: [CGRect] = [] { didSet { needsDisplay = true } }
        var hovered: [CGRect] = [] { didSet { needsDisplay = true } }
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

        private func shape(_ line: CGRect) -> NSBezierPath {
            NSBezierPath(roundedRect: line.insetBy(dx: -3, dy: -2), xRadius: 4, yRadius: 4)
        }

        override func draw(_ dirtyRect: NSRect) {
            guard let context = NSGraphicsContext.current?.cgContext else { return }
            // Dim the screen, then cut every line back out, so the text stands out as with Live Text.
            NSColor.black.withAlphaComponent(0.2).setFill()
            bounds.fill()
            context.setBlendMode(.clear)
            for line in lines { shape(line).fill() }
            context.setBlendMode(.normal)
            // A soft white glow along each line's edge.
            NSGraphicsContext.saveGraphicsState()
            let glow = NSShadow()
            glow.shadowColor = NSColor.white.withAlphaComponent(0.9)
            glow.shadowBlurRadius = 5
            glow.set()
            NSColor.white.withAlphaComponent(0.75).setStroke()
            for line in lines {
                let path = shape(line)
                path.lineWidth = 1
                path.stroke()
            }
            NSGraphicsContext.restoreGraphicsState()
            // The block under the pointer, outlined line by line.
            NSColor.controlAccentColor.setStroke()
            for line in hovered {
                let path = shape(line)
                path.lineWidth = 2
                path.stroke()
            }
            drawEdges()
            drawPill()
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
            case .ready: "Point at text to read it in \(language) · Esc to exit"
            case .reading: "Reading the screen… · Esc to exit"
            case .translating(let count): "Translating \(count) block\(count == 1 ? "" : "s")… · Esc to exit"
            case .failed(let message): message
            }
            let text = NSMutableAttributedString(string: "Screen translation", attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.white])
            text.append(NSAttributedString(string: "   \(state)", attributes: [
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.white.withAlphaComponent(0.75)]))
            let size = text.size(), height = size.height + 10
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

/// The translation of the block under the pointer, on a frosted card just below it (above, near the
/// bottom of the screen). It never takes a click.
@MainActor
final class TranslationCard: NSPanel {
    private let caption = Design.label("", size: 11, weight: .medium, color: .secondaryLabelColor)
    private let text = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private let column: NSStackView
    private var source = NSRect.zero
    private var placedOn: NSScreen?
    private static let width: (min: CGFloat, max: CGFloat) = (220, 480)

    init() {
        column = Design.vstack([], spacing: 5, alignment: .leading)
        super.init(contentRect: NSRect(x: 0, y: 0, width: 300, height: 60), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = true
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let material = NSVisualEffectView.roundedMaterial(.popover, radius: 10)
        text.font = .systemFont(ofSize: 14)
        text.textColor = .labelColor
        text.isSelectable = false
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        column.addArrangedSubview(Design.hstack([caption, spinner], spacing: 6))
        column.addArrangedSubview(text)
        column.translatesAutoresizingMaskIntoConstraints = false
        material.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: material.leadingAnchor, constant: 12),
            column.trailingAnchor.constraint(equalTo: material.trailingAnchor, constant: -12),
            column.topAnchor.constraint(equalTo: material.topAnchor, constant: 9),
            column.bottomAnchor.constraint(equalTo: material.bottomAnchor, constant: -11)
        ])
        contentView = material
    }

    /// Where the card belongs: `source` is the block, in AppKit screen coordinates.
    func present(language: String, beside source: NSRect, on screen: NSScreen) {
        self.source = source
        placedOn = screen
        caption.stringValue = language
    }

    func show(_ translation: String) {
        spinner.stopAnimation(nil)
        text.textColor = .labelColor
        text.stringValue = translation
        place()
    }

    func showWaiting() {
        spinner.startAnimation(nil)
        text.textColor = .secondaryLabelColor
        text.stringValue = "Translating…"
        place()
    }

    func show(failure message: String) {
        spinner.stopAnimation(nil)
        text.textColor = .systemOrange
        text.stringValue = message
        place()
    }

    /// As wide as the block (within limits), sized to the text, below the block or else above it, and
    /// always on its screen.
    private func place() {
        guard let screen = placedOn else { return }
        let visible = screen.visibleFrame
        let width = min(max(source.width + 8, Self.width.min), Self.width.max, visible.width - 16)
        text.preferredMaxLayoutWidth = width - 24
        column.layoutSubtreeIfNeeded()
        let height = column.fittingSize.height + 20
        var origin = NSPoint(x: source.minX - 4, y: source.minY - 8 - height)
        if origin.y < visible.minY + 8 { origin.y = source.maxY + 8 }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - 8 - width)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - 8 - height)
        setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
        orderFrontRegardless()
    }
}
