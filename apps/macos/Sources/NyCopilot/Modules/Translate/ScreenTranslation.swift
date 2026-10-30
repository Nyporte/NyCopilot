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
    /// Pointer movement, watched (never caught) so translations can open on hover while clicks go through.
    private var pointerMonitors: [Any] = []
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
        let moved: (NSEvent?) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                let location = NSEvent.mouseLocation
                self?.displays.forEach { $0.overlay.pointer(at: location) }
            }
        }
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
        /// The original's font size, as best it can be told.
        let fontSize: CGFloat
        /// How much of the line is ink: bold lines have noticeably more than the screen's usual.
        let coverage: Double
    }

    /// Lines wrapped from one paragraph, translated together and laid out over the same area.
    struct Paragraph {
        let entries: [Entry]
        let text: String
        let rect: CGRect
        let fontSize: CGFloat
        /// Baseline to baseline, when there's more than one line.
        let pitch: CGFloat?
        let bold: Bool
    }

    /// Lines into paragraphs: directly below one another at line spacing, in the same column, the
    /// same size, on the same background. Only a line long enough to have wrapped carries on to the
    /// next — short labels stacked in a sidebar or a menu stay apart, and a paragraph's short last line
    /// ends it — and a bullet or number starts a new one.
    static func paragraphs(_ entries: [Entry]) -> [Paragraph] {
        // Bold against this screen's usual ink, since scripts differ (Chinese is denser than English).
        let coverages = entries.map(\.coverage).sorted()
        let usual = coverages.isEmpty ? 0 : coverages[coverages.count / 2]
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
            let sizes = group.map(\.fontSize).sorted(), tops = group.map(\.line.rect.minY)
            let steps = zip(tops.dropFirst(), tops).map { $0 - $1 }.sorted()
            let ink = group.map(\.coverage).reduce(0, +) / Double(group.count)
            return Paragraph(entries: group, text: ScreenText.joined(group.map(\.line.text)),
                             rect: group.map(\.line.rect).reduce(group[0].line.rect) { $0.union($1) },
                             fontSize: sizes[sizes.count / 2], pitch: steps.isEmpty ? nil : steps[steps.count / 2],
                             bold: entries.count >= 3 && ink >= max(0.3, usual * 1.45))
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
                let background = pixels.background(around: line.rect), ink = pixels.ink(in: line.rect, on: background)
                return Entry(line: line, background: background, foreground: ink.color, fontSize: ScreenText.fontSize(of: line), coverage: ink.coverage)
            }
        display.entries.removeAll { band.intersects($0.line.rect) }
        display.entries += found
        render(display)
        await translateMissing()
    }

    /// One batch for every paragraph on every display that has no translation yet.
    private func translateMissing() async {
        var missing: [String] = [], seen = Set<String>(), bytes = 0
        for display in displays {
            for paragraph in Self.paragraphs(display.entries) where translations[paragraph.text] == nil && !seen.contains(paragraph.text) {
                guard missing.count < 400, bytes + paragraph.text.utf8.count < 60_000 else { break }
                seen.insert(paragraph.text)
                missing.append(paragraph.text)
                bytes += paragraph.text.utf8.count
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
        display.overlay.show(Self.paragraphs(display.entries).compactMap { paragraph in
            guard let text = translations[paragraph.text], text.trimmingCharacters(in: .whitespaces) != paragraph.text else { return nil }
            let first = paragraph.entries[0]
            return TranslationOverlay.Box(rect: paragraph.rect, text: text, background: first.background, foreground: first.foreground,
                                          fontSize: paragraph.fontSize, pitch: paragraph.pitch, bold: paragraph.bold)
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

    /// The line's own text colour and how much of it there is: across a grid of points inside the
    /// line, the one furthest from the background, and the share of points that are ink (bold text
    /// covers more of its line than regular).
    func ink(in rect: CGRect, on background: NSColor) -> (color: NSColor, coverage: Double) {
        guard let base = background.usingColorSpace(.sRGB) else { return (.labelColor, 0) }
        let back = (Int(base.redComponent * 255), Int(base.greenComponent * 255), Int(base.blueComponent * 255))
        let columns = max(8, min(400, Int(rect.width * scale / 2))), rows = max(4, min(40, Int(rect.height * scale / 2)))
        var best: ((Int, Int, Int), Int)?, inked = 0, seen = 0
        for row in 0..<rows {
            for column in 0..<columns {
                let point = CGPoint(x: rect.minX + rect.width * (CGFloat(column) + 0.5) / CGFloat(columns),
                                    y: rect.minY + rect.height * (CGFloat(row) + 0.5) / CGFloat(rows))
                guard let pixel = sample(point) else { continue }
                let distance = abs(pixel.0 - back.0) + abs(pixel.1 - back.1) + abs(pixel.2 - back.2)
                seen += 1
                if distance > 200 { inked += 1 }
                if distance > (best?.1 ?? -1) { best = (pixel, distance) }
            }
        }
        guard let best, best.1 > 120 else { return (base.isLight ? NSColor(white: 0.08, alpha: 1) : NSColor(white: 0.96, alpha: 1), 0) }
        return (NSColor(srgbRed: CGFloat(best.0.0) / 255, green: CGFloat(best.0.1) / 255, blue: CGFloat(best.0.2) / 255, alpha: 1),
                seen > 0 ? Double(inked) / Double(seen) : 0)
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
        /// The original's size, line spacing (for a paragraph), and weight.
        let fontSize: CGFloat
        let pitch: CGFloat?
        let bold: Bool
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

    /// Where the pointer is (screen coordinates), so a cut-off translation under it can open.
    func pointer(at location: NSPoint) {
        let inside = frame.contains(location) ? CGPoint(x: location.x - frame.minX, y: frame.maxY - location.y) : nil
        canvas.pointer(at: inside)
    }

    private final class Canvas: NSView {
        var boxes: [Box] = [] {
            didSet {
                laid = boxes.map(layout)
                hovered = nil
                needsDisplay = true
            }
        }
        var status: Status = .reading { didSet { needsDisplay = true } }
        private let language: String
        /// The Dock's height at the bottom, if it's there.
        private let dock: CGFloat
        private var laid: [Laid] = []
        /// The cut-off translation the pointer rests on, shown in full.
        private var hovered: Int? { didSet { if hovered != oldValue { needsDisplay = true } } }

        init(language: String, dock: CGFloat) {
            self.language = language
            self.dock = dock
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("Use init(language:dock:)") }

        override var isFlipped: Bool { true }

        /// A translation placed: inside the original's area at the original's size — sizes that vary from
        /// box to box would read unevenly — cut off with "…" if it's longer, and the larger card it opens
        /// into on hover.
        private struct Laid {
            let box: Box
            let rect: CGRect
            let size: CGFloat
            let truncated: Bool
            let expanded: CGRect
        }

        private func attributes(_ box: Box, size: CGFloat, wrapping: Bool) -> [NSAttributedString.Key: Any] {
            let style = NSMutableParagraphStyle()
            if let pitch = box.pitch {
                let height = pitch * size / box.fontSize
                style.minimumLineHeight = height
                style.maximumLineHeight = height
            }
            style.lineBreakMode = wrapping ? .byWordWrapping : .byTruncatingTail
            return [.font: NSFont.systemFont(ofSize: size, weight: box.bold ? .semibold : .regular), .foregroundColor: box.foreground,
                    .paragraphStyle: style]
        }

        private func extent(_ box: Box, size: CGFloat, width: CGFloat) -> CGSize {
            let text = box.text as NSString
            return box.pitch == nil ? text.size(withAttributes: attributes(box, size: size, wrapping: false))
                : text.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin],
                                    attributes: attributes(box, size: size, wrapping: true)).size
        }

        private func layout(_ box: Box) -> Laid {
            let rect = box.rect.insetBy(dx: -3, dy: -2), room = rect.width - 6
            let size = box.fontSize, full = extent(box, size: size, width: room)
            guard box.pitch == nil ? full.width > room : full.height > rect.height - 2 else {
                return Laid(box: box, rect: rect, size: size, truncated: false, expanded: rect)
            }
            // In full: a line runs on to the right, a paragraph further down, moved back onto the screen
            // if it would leave it.
            var expanded = box.pitch == nil ? CGRect(x: rect.minX, y: rect.minY, width: min(full.width + 10, bounds.width - 16), height: rect.height)
                : CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: full.height + 8)
            expanded.origin.x = max(8, min(expanded.minX, bounds.maxX - 8 - expanded.width))
            expanded.origin.y = max(8, min(expanded.minY, bounds.maxY - 8 - expanded.height))
            return Laid(box: box, rect: rect, size: size, truncated: true, expanded: expanded)
        }

        /// The pointer moved (view coordinates): open the cut-off translation under it, and keep it open
        /// while the pointer is anywhere over the opened card.
        func pointer(at point: CGPoint?) {
            guard let point else { hovered = nil; return }
            if let index = hovered, laid.indices.contains(index), laid[index].expanded.union(laid[index].rect).contains(point) { return }
            hovered = laid.lastIndex { $0.truncated && $0.rect.contains(point) }
        }

        override func draw(_ dirtyRect: NSRect) {
            for (index, item) in laid.enumerated() where index != hovered { draw(item) }
            if let index = hovered, laid.indices.contains(index) { drawExpanded(laid[index]) }
            drawEdges()
            drawPill()
        }

        /// Inside the original's area and no further, so the page keeps its layout.
        private func draw(_ item: Laid) {
            // Opaque: the original must not show through beside a shorter translation.
            item.box.background.setFill()
            NSBezierPath(roundedRect: item.rect, xRadius: 3, yRadius: 3).fill()
            let text = item.box.text as NSString
            if item.box.pitch == nil {
                let height = text.size(withAttributes: attributes(item.box, size: item.size, wrapping: false)).height
                text.draw(in: CGRect(x: item.rect.minX + 3, y: item.rect.midY - height / 2, width: item.rect.width - 6, height: height),
                          withAttributes: attributes(item.box, size: item.size, wrapping: false))
            } else {
                text.draw(with: CGRect(x: item.rect.minX + 3, y: item.rect.minY + 2, width: item.rect.width - 6, height: item.rect.height - 2),
                          options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes(item.box, size: item.size, wrapping: true))
            }
        }

        /// The whole translation, on a card that floats over its neighbours.
        private func drawExpanded(_ item: Laid) {
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
            shadow.shadowBlurRadius = 10
            shadow.shadowOffset = NSSize(width: 0, height: -3)
            shadow.set()
            item.box.background.setFill()
            let card = NSBezierPath(roundedRect: item.expanded, xRadius: 5, yRadius: 5)
            card.fill()
            NSGraphicsContext.restoreGraphicsState()
            NSColor.controlAccentColor.withAlphaComponent(0.55).setStroke()
            card.lineWidth = 1
            card.stroke()
            let text = item.box.text as NSString
            if item.box.pitch == nil {
                let style = attributes(item.box, size: item.box.fontSize, wrapping: false)
                let height = text.size(withAttributes: style).height
                text.draw(in: CGRect(x: item.expanded.minX + 5, y: item.expanded.midY - height / 2, width: item.expanded.width - 10, height: height),
                          withAttributes: style)
            } else {
                text.draw(with: CGRect(x: item.expanded.minX + 3, y: item.expanded.minY + 4, width: item.expanded.width - 6, height: item.expanded.height - 4),
                          options: [.usesLineFragmentOrigin], attributes: attributes(item.box, size: item.box.fontSize, wrapping: true))
            }
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
