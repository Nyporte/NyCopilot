import AppKit
import Carbon
import MacPlatform

/// Screen translation: hold the translate shortcut and every line of text on every display is
/// highlighted, like Live Text. Point at a block not in the chosen language and a card with its
/// translation floats beside it. The page itself is left exactly as it is. A small capsule at the
/// bottom picks the language — its own, apart from the composer's, since reading usually goes into
/// your language and writing out of it. The overlay lets every click and scroll
/// through, so the computer works as usual underneath, and it keeps up as the screen changes. Esc ends it.
///
/// Keeping up cheaply: each display is glanced at ten times a second at an eighth of its resolution.
/// Where it changed, every block touching the change is taken down at once — nothing stale stays up —
/// and once
/// it has settled, only the changed band of the screen is read again, at full resolution. Only a block
/// you point at is translated, once the pointer rests on it, and never twice in a session.
@MainActor
final class ScreenTranslator {
    private let services: CopilotServices
    private var displays: [Display] = []
    private var watching: Task<Void, Never>?
    private var escape: GlobalHotKey?
    /// Pointer movement, watched (never caught), so cards follow the pointer while clicks go through.
    private var pointerMonitors: [Any] = []
    private let card = TranslationCard()
    private let bar = ScreenTranslationBar()
    /// The block under the pointer, and the card about to show for it.
    private var hovered: (display: Display, paragraph: Paragraph)?
    private var pendingCard: DispatchWorkItem?
    private var language = "", nativeLanguage = ""
    /// Blocks translated this session, by language and text, so switching back costs nothing.
    private var translations: [String: String] = [:]
    /// Blocks out for translation right now, so none is asked for twice.
    private var requested: Set<String> = []
    private func key(_ text: String) -> String { language + "\u{1}" + text }

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
        choose(services.core.readingLanguage, remember: false)
        displays = NSScreen.screens.map { Display(screen: $0, overlay: TranslationOverlay(screen: $0)) }
        bar.onPick = { [weak self] language in self?.choose(language, remember: true) }
        bar.onExit = { [weak self] in self?.stop() }
        bar.present(languages: languages(), selected: language, on: NSScreen.main ?? NSScreen.screens[0])
        displays.forEach { overlay in
            // The dimming eases in rather than dropping over the screen.
            overlay.overlay.alphaValue = 0
            overlay.overlay.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.2; overlay.overlay.animator().alphaValue = 1 }
        }
        // Esc belongs to the overlay while it's up, whichever app is in front.
        escape = GlobalHotKey.claim(HotKeyCombination(keyCode: UInt32(kVK_Escape), modifiers: 0)) { [weak self] in
            MainActor.assumeIsolated { self?.stop() }
        }
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
        bar.orderOut(nil)
        displays.forEach { $0.overlay.orderOut(nil) }
        displays = []
        requested = []
    }

    // MARK: Language

    /// Reads into `name` from now on: highlights recount what needs translating, and a card showing
    /// re-translates. `remember` keeps the choice for next time.
    private func choose(_ name: String, remember: Bool) {
        language = name
        nativeLanguage = services.core.nativeName(of: name)
        if remember { try? services.core.setSetting(.screenLanguage, name) }
        hover(nil)
        displays.forEach(update)
    }

    /// The menu: favourites first, then every other language NyCopilot knows, in their own scripts.
    private func languages() -> [[ScreenTranslationBar.Language]] {
        struct Known: Decodable { let name: String; let native: String }
        let known = (try? services.core.call("translate.languages", as: [Known].self)) ?? []
        let favorites: [String] = services.core.setting(.favoriteLanguages, default: [String]())
        func entry(_ name: String) -> ScreenTranslationBar.Language {
            .init(name: name, native: known.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.native
                    ?? (name == language ? nativeLanguage : name))
        }
        var first = favorites.map(entry)
        if !first.contains(where: { $0.name == language }) { first.insert(entry(language), at: 0) }
        let rest = known.filter { item in !first.contains { $0.name.caseInsensitiveCompare(item.name) == .orderedSame } }.map { entry($0.name) }
        return [first, rest].filter { !$0.isEmpty }
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
    /// The text in an image, paragraph by paragraph, read the way the screen is: for translating a
    /// screenshot. `scale` is the image's pixels per point.
    static func paragraphs(in image: CGImage, scale: CGFloat) async throws -> [String] {
        let lines = try await ScreenText.lines(in: image, scale: scale)
        return paragraphs(entries(lines, from: PixelSampler(image, scale: scale, origin: .zero)), language: nil).map(\.text)
    }

    /// Lines with what grouping them takes: the background around each and its font size.
    private static func entries(_ lines: [ScreenText.Line], from pixels: PixelSampler) -> [Entry] {
        lines.map { Entry(line: $0, background: pixels.background(around: $0.rect), fontSize: ScreenText.fontSize(of: $0)) }
    }

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

    /// The lines left once every block touching a change is taken down whole, and the areas of those
    /// blocks (to read again).
    static func removing(blocksTouching changed: [CGRect], from entries: [Entry], in blocks: [Paragraph]) -> (kept: [Entry], touched: [CGRect]) {
        let touched = blocks.filter { block in block.entries.contains { entry in changed.contains { $0.intersects(entry.line.rect) } } }
        let gone = touched.flatMap { $0.entries.map(\.line.rect) }
        let kept = entries.filter { entry in !gone.contains(entry.line.rect) && !changed.contains { $0.intersects(entry.line.rect) } }
        return (kept, touched.map(\.rect))
    }

    // MARK: Watching

    private static let glanceScale: CGFloat = 1.0 / 8
    private static let cell = 2 // glance pixels per side of a cell: 16 points

    private func watch() async {
        while !Task.isCancelled {
            for display in displays { await glance(at: display) }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func glance(at display: Display) async {
        guard let image = try? await ScreenGrabber.snapshot(of: display.screen, pixelsPerPoint: Self.glanceScale),
              let grey = Self.grey(image), isActive else { return }
        if let last = display.glance, last.width == grey.width, last.height == grey.height {
            let changed = Self.changes(from: last, to: grey)
            if !changed.isEmpty {
                // Take down every block the change touches, whole, at once; read it all again once it settles.
                let (kept, touched) = Self.removing(blocksTouching: changed, from: display.entries, in: display.paragraphs)
                display.entries = kept
                update(display)
                display.pending = (changed + touched).reduce(display.pending ?? changed[0]) { $0.union($1) }
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
        bar.reading = true
        guard let screenshot = try? await ScreenGrabber.snapshot(of: display.screen, pixelsPerPoint: scale),
              let crop = screenshot.cropping(to: CGRect(x: band.minX * scale, y: band.minY * scale,
                                                        width: band.width * scale, height: band.height * scale).integral),
              let lines = try? await ScreenText.lines(in: crop, scale: scale), isActive else {
            bar.reading = displays.contains { $0 !== display && $0.reading }
            return
        }
        // Every line is highlighted, whatever its language — only blocks that need it get translated.
        let placed = lines.map { ScreenText.Line(text: $0.text, rect: $0.rect.offsetBy(dx: band.minX, dy: band.minY)) }
            // Lines where the screen changed meanwhile wait for the next read.
            .filter { line in !display.changedDuringRead.contains { $0.intersects(line.rect) } }
        let found = Self.entries(placed, from: PixelSampler(crop, scale: scale, origin: band.origin))
        display.entries.removeAll { band.intersects($0.line.rect) }
        display.entries += found
        update(display)
        bar.reading = displays.contains { $0 !== display && $0.reading }
    }

    /// Regroups a display's blocks and redraws its highlights; the card follows if its block went away.
    private func update(_ display: Display) {
        display.paragraphs = Self.paragraphs(display.entries, language: ScreenText.code(for: language))
        display.overlay.show(display.paragraphs.map { $0.entries.map(\.line.rect) })
        pointerMoved()
    }

    // MARK: Translating

    /// The block pointed at, unless it's already translated or on its way; the card updates if it's
    /// still showing that block when the translation arrives.
    private func translate(_ text: String) async {
        let language = language, key = key(text)
        guard translations[key] == nil, !requested.contains(key) else { return }
        requested.insert(key)
        defer { requested.remove(key) }
        struct Result: Decodable { let text: String }
        do {
            // Kept out of history: that's for what you translate on purpose, not what you glance at.
            let params: [String: Any] = ["text": text, "target_language": language, "save": false]
            let translation = try await services.core.perform("translate.run", params.merging(try services.translationKeys()) { _, key in key },
                                                              as: Result.self).text
            guard isActive else { return }
            if translations.count > 5000 { translations = [:] }
            translations[key] = translation
            if let hovered, hovered.paragraph.text == text, language == self.language, card.isVisible { card.show(translation) }
        } catch {
            guard isActive, let hovered, hovered.paragraph.text == text, language == self.language, card.isVisible else { return }
            card.show(failure: error.localizedDescription)
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

    /// Brightens the block's highlight at once; its card — and its translation, if it needs one —
    /// follows once the pointer has rested a moment, so sweeping across a page neither flickers cards
    /// nor sends a request for every block passed over.
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    private func present(_ target: (display: Display, paragraph: Paragraph)) {
        let frame = target.display.screen.frame, rect = target.paragraph.rect
        let source = NSRect(x: frame.minX + rect.minX, y: frame.maxY - rect.maxY, width: rect.width, height: rect.height)
        card.present(language: nativeLanguage, beside: source, on: target.display.screen)
        if let text = translations[key(target.paragraph.text)] {
            card.show(text)
        } else {
            card.showWaiting()
            Task { await translate(target.paragraph.text) }
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

/// One display's overlay, in the manner of Live Text: the screen dimmed a little except for its text,
/// each block (a paragraph's lines together) one glowing shape; the block under the pointer outlined;
/// and a glow along the screen's edges. Every click and scroll goes through to what's underneath.
@MainActor
final class TranslationOverlay: NSWindow {
    /// The lines of the block under the pointer, in this display's points (top-left).
    var hovered: [CGRect] = [] { didSet { if hovered != oldValue { canvas.hovered = hovered } } }
    private let canvas: Canvas

    init(screen: NSScreen) {
        canvas = Canvas()
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        float(at: .screenOverlay, shadow: false, clickThrough: true, behavior: [.stationary, .ignoresCycle])
        contentView = canvas
        setFrame(screen.frame, display: false)
    }

    /// The blocks to highlight, each as its lines, in this display's points (top-left).
    func show(_ blocks: [[CGRect]]) { canvas.show(blocks) }

    private final class Canvas: NSView {
        /// Each block's shape, keyed by where it is, and when it appeared — new blocks fade in.
        private var blocks: [(key: String, outline: NSBezierPath)] = []
        private var appeared: [String: CFTimeInterval] = [:]
        private var fading: Timer?
        private static let fadeIn: CFTimeInterval = 0.25
        var hovered: [CGRect] = [] { didSet { needsDisplay = true } }

        init() {
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("Use init()") }

        override var isFlipped: Bool { true }

        /// One shape around a block's lines: each line padded a little, neighbours meeting halfway between
        /// them, the left edge running down the lines' starts and the right edge back up their ends, every
        /// corner rounded (less on small steps). A single line is a rounded rectangle.
        static func outline(of lines: [CGRect]) -> NSBezierPath {
            let rows = smoothed(lines.map { $0.insetBy(dx: -3, dy: -2) }.sorted { $0.minY < $1.minY })
            guard let first = rows.first else { return NSBezierPath() }
            guard rows.count > 1 else { return NSBezierPath(roundedRect: first, xRadius: 4, yRadius: 4) }
            // Where each row starts and ends vertically, with no gaps between neighbours.
            var edges = [first.minY]
            for (upper, lower) in zip(rows, rows.dropFirst()) { edges.append((upper.maxY + lower.minY) / 2) }
            edges.append(rows.last!.maxY)
            // Around the shape clockwise (top-left origin): across the top, down the right, back along the
            // bottom, up the left.
            var corners = [CGPoint(x: first.minX, y: edges[0])]
            for (index, row) in rows.enumerated() {
                corners.append(CGPoint(x: row.maxX, y: edges[index]))
                corners.append(CGPoint(x: row.maxX, y: edges[index + 1]))
            }
            for (index, row) in rows.enumerated().reversed() {
                corners.append(CGPoint(x: row.minX, y: edges[index + 1]))
                corners.append(CGPoint(x: row.minX, y: edges[index]))
            }
            // Drop repeats and points in the middle of a straight run.
            var points: [CGPoint] = []
            for point in corners where points.last.map({ hypot($0.x - point.x, $0.y - point.y) > 0.5 }) ?? true { points.append(point) }
            if let last = points.last, hypot(last.x - points[0].x, last.y - points[0].y) <= 0.5 { points.removeLast() }
            points = points.indices.compactMap { index in
                let before = points[(index + points.count - 1) % points.count], point = points[index], after = points[(index + 1) % points.count]
                let straight = (abs(before.x - point.x) < 0.5 && abs(point.x - after.x) < 0.5) || (abs(before.y - point.y) < 0.5 && abs(point.y - after.y) < 0.5)
                return straight ? nil : point
            }
            guard points.count >= 3 else { return NSBezierPath(roundedRect: rows.reduce(first) { $0.union($1) }, xRadius: 4, yRadius: 4) }
            let path = NSBezierPath()
            let count = points.count
            func middle(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
            path.move(to: middle(points[count - 1], points[0]))
            for index in 0..<count {
                let point = points[index], before = points[(index + count - 1) % count], after = points[(index + 1) % count]
                let room = min(hypot(point.x - before.x, point.y - before.y), hypot(after.x - point.x, after.y - point.y)) / 2
                path.appendArc(from: point, to: middle(point, after), radius: min(4, room))
            }
            path.close()
            return path
        }

        /// Edges evened out: consecutive lines whose starts (or ends) lie within about two characters of
        /// each other share one edge, at the outermost of them so no text is cut — only real differences,
        /// like a short last line or an indent, make a step.
        static func smoothed(_ rows: [CGRect]) -> [CGRect] {
            guard rows.count > 1 else { return rows }
            let heights = rows.map(\.height).sorted()
            let tolerance = heights[heights.count / 2] * 1.4
            func even(_ values: [CGFloat], outermost: (CGFloat, CGFloat) -> CGFloat) -> [CGFloat] {
                var result = values, start = 0
                while start < values.count {
                    var end = start + 1, edge = values[start]
                    while end < values.count, abs(values[end] - edge) <= tolerance {
                        edge = outermost(edge, values[end])
                        end += 1
                    }
                    for index in start..<end { result[index] = edge }
                    start = end
                }
                return result
            }
            let starts = even(rows.map(\.minX), outermost: min), ends = even(rows.map(\.maxX), outermost: max)
            return rows.indices.map { CGRect(x: starts[$0], y: rows[$0].minY, width: ends[$0] - starts[$0], height: rows[$0].height) }
        }

        /// New blocks fade in; blocks still there keep their place in the fade; blocks gone are gone at once.
        func show(_ lines: [[CGRect]]) {
            let now = CACurrentMediaTime()
            blocks = lines.map { block in
                let box = block.reduce(block[0]) { $0.union($1) }
                return ("\(Int(box.minX)),\(Int(box.minY)),\(Int(box.width)),\(Int(box.height))", Self.outline(of: block))
            }
            appeared = Dictionary(blocks.map { ($0.key, appeared[$0.key] ?? now) }, uniquingKeysWith: { first, _ in first })
            needsDisplay = true
            guard fading == nil, appeared.values.contains(where: { now - $0 < Self.fadeIn }) else { return }
            fading = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
                MainActor.assumeIsolated {
                    guard let self else { return timer.invalidate() }
                    self.needsDisplay = true
                    if !self.appeared.values.contains(where: { CACurrentMediaTime() - $0 < Self.fadeIn }) {
                        timer.invalidate()
                        self.fading = nil
                    }
                }
            }
        }

        /// How far a block has faded in, eased.
        private func opacity(_ key: String, at now: CFTimeInterval) -> CGFloat {
            let progress = min(1, max(0, (now - (appeared[key] ?? 0)) / Self.fadeIn))
            return CGFloat(progress * progress * (3 - 2 * progress))
        }

        override func draw(_ dirtyRect: NSRect) {
            guard let context = NSGraphicsContext.current?.cgContext else { return }
            let now = CACurrentMediaTime()
            // Dim the screen, then cut every block back out, so the text stands out as with Live Text.
            NSColor.black.withAlphaComponent(0.2).setFill()
            bounds.fill()
            context.setBlendMode(.destinationOut)
            for block in blocks {
                NSColor.black.withAlphaComponent(opacity(block.key, at: now)).setFill()
                block.outline.fill()
            }
            context.setBlendMode(.normal)
            // A soft white glow along each block's edge.
            for block in blocks {
                let shown = opacity(block.key, at: now)
                NSGraphicsContext.saveGraphicsState()
                let glow = NSShadow()
                glow.shadowColor = NSColor.white.withAlphaComponent(0.9 * shown)
                glow.shadowBlurRadius = 5
                glow.set()
                NSColor.white.withAlphaComponent(0.75 * shown).setStroke()
                block.outline.lineWidth = 1
                block.outline.stroke()
                NSGraphicsContext.restoreGraphicsState()
            }
            // The block under the pointer, outlined.
            if !hovered.isEmpty {
                let outline = Self.outline(of: hovered)
                NSColor.controlAccentColor.setStroke()
                outline.lineWidth = 2
                outline.stroke()
            }
            drawEdges()
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
    }
}

/// The small capsule at the bottom while the screen is translated: what it reads into, as a menu, and
/// the way out. The translate icon turns into a spinner while the screen is being read. It never takes
/// the keyboard from the app in front.
@MainActor
final class ScreenTranslationBar: NSPanel {
    struct Language {
        let name: String
        let native: String
    }

    var onPick: ((String) -> Void)?
    var onExit: (() -> Void)?
    var reading = false {
        didSet {
            guard reading != oldValue else { return }
            icon.isHidden = reading
            spinner.isHidden = !reading
            reading ? spinner.startAnimation(nil) : spinner.stopAnimation(nil)
        }
    }
    private let icon = Design.symbol("translate", size: 12, color: .white.withAlphaComponent(0.85))
    private let spinner = NSProgressIndicator()
    private let picker = FirstClickPopUp()
    /// Each language's own name, by its English one, for the capsule's title.
    private var natives: [String: String] = [:]
    private let content: NSStackView

    init() {
        content = Design.hstack([], spacing: 6)
        super.init(contentRect: NSRect(x: 0, y: 0, width: 160, height: 30), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        float(at: .screenOverlayControls, shadow: true, behavior: [.stationary, .ignoresCycle])
        becomesKeyOnlyIfNeeded = true
        appearance = NSAppearance(named: .darkAqua)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.isHidden = true
        for view in [icon, spinner] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalToConstant: 16).isActive = true
        }
        // A pull-down, so the capsule shows just the language's own name while the menu can say more.
        picker.pullsDown = true
        picker.isBordered = false
        picker.font = .systemFont(ofSize: 12, weight: .medium)
        picker.contentTintColor = .white
        picker.target = self
        picker.action = #selector(picked)
        let escape = Design.label("esc", size: 10, weight: .medium, color: .white.withAlphaComponent(0.6))
        let key = ExitKey()
        key.toolTip = "Esc ends screen translation"
        key.onClick = { [weak self] in self?.onExit?() }
        key.translatesAutoresizingMaskIntoConstraints = false
        escape.translatesAutoresizingMaskIntoConstraints = false
        key.addSubview(escape)
        NSLayoutConstraint.activate([
            escape.leadingAnchor.constraint(equalTo: key.leadingAnchor, constant: 4), escape.trailingAnchor.constraint(equalTo: key.trailingAnchor, constant: -4),
            escape.centerYAnchor.constraint(equalTo: key.centerYAnchor), key.heightAnchor.constraint(equalToConstant: 16)
        ])
        key.wantsLayer = true
        key.layer?.borderColor = NSColor.white.withAlphaComponent(0.3).cgColor
        key.layer?.borderWidth = 1
        key.layer?.cornerRadius = 4
        [icon, spinner, picker, key].forEach(content.addArrangedSubview)
        let material = NSVisualEffectView.roundedMaterial(.hudWindow, radius: 15)
        content.translatesAutoresizingMaskIntoConstraints = false
        material.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: material.leadingAnchor, constant: 12),
            content.trailingAnchor.constraint(equalTo: material.trailingAnchor, constant: -8),
            content.centerYAnchor.constraint(equalTo: material.centerYAnchor),
            material.heightAnchor.constraint(equalToConstant: 30)
        ])
        contentView = material
    }

    /// Fills the menu — groups of languages, a divider between groups — and shows the capsule at the
    /// bottom of `screen`, just above the Dock.
    func present(languages groups: [[Language]], selected: String, on screen: NSScreen) {
        picker.removeAllItems()
        picker.addItem(withTitle: "")
        for (index, group) in groups.enumerated() {
            if index > 0 { picker.menu?.addItem(.separator()) }
            for language in group {
                let item = NSMenuItem(title: language.native, action: nil, keyEquivalent: "")
                item.representedObject = language.name
                item.state = language.name == selected ? .on : .off
                natives[language.name] = language.native
                if language.native.caseInsensitiveCompare(language.name) != .orderedSame {
                    let title = NSMutableAttributedString(string: language.native, attributes: [.font: NSFont.menuFont(ofSize: 13)])
                    title.append(NSAttributedString(string: "  \(language.name)", attributes: [
                        .font: NSFont.menuFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
                    item.attributedTitle = title
                }
                picker.menu?.addItem(item)
            }
        }
        picker.itemArray.first?.title = natives[selected] ?? selected
        content.layoutSubtreeIfNeeded()
        let size = NSSize(width: content.fittingSize.width + 20, height: 30)
        let visible = screen.visibleFrame
        setFrame(NSRect(x: visible.midX - size.width / 2, y: visible.minY + 14, width: size.width, height: size.height), display: true)
        orderFrontRegardless()
    }

    @objc private func picked() {
        guard let chosen = picker.selectedItem, let name = chosen.representedObject as? String else { return }
        picker.itemArray.forEach { $0.state = $0 === chosen ? .on : .off }
        picker.itemArray.first?.title = natives[name] ?? name
        onPick?(name)
        // The capsule follows the shorter or longer name.
        content.layoutSubtreeIfNeeded()
        let width = content.fittingSize.width + 20
        setFrame(NSRect(x: frame.midX - width / 2, y: frame.minY, width: width, height: frame.height), display: true)
    }

    /// Opens on the first click, though the capsule never becomes the key window.
    private final class FirstClickPopUp: NSPopUpButton {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    /// The `esc` keycap, which also ends screen translation when clicked.
    private final class ExitKey: NSView {
        var onClick: (() -> Void)?
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseUp(with event: NSEvent) { if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() } }
    }
}
