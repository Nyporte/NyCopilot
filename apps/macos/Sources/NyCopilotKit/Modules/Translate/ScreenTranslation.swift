import AppKit
import Carbon
import IOKit.ps
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
    let services: CopilotServices
    var displays: [Display] = []
    var watching: Task<Void, Never>?
    var escape: GlobalHotKey?
    /// Pointer movement, watched (never caught), so cards follow the pointer while clicks go through.
    var pointerMonitors: [Any] = []
    let card = TranslationCard()
    let bar = ScreenTranslationBar()
    /// The block under the pointer, and the card about to show for it.
    var hovered: (display: Display, paragraph: Paragraph)?
    var pendingCard: DispatchWorkItem?
    /// The last pointer movement or screen change: glances come quickly after it and ease off later.
    var lastActivity = Date()
    var language = "", nativeLanguage = ""
    /// Blocks translated this session, by language and text, so switching back costs nothing.
    var translations: [String: String] = [:]
    /// Blocks out for translation right now, so none is asked for twice.
    var requested: Set<String> = []
    func key(_ text: String) -> String { language + "\u{1}" + text }

    var isActive: Bool { watching != nil }

    init(services: CopilotServices) { self.services = services }

    func toggle() { isActive ? stop() : start() }

    func start() {
        guard !isActive else { return }
        guard ScreenGrabber.hasPermission else {
            ScreenGrabber.requestPermission()
            services.toast.show(L("Allow Screen Recording to translate the screen"),
                                detail: L("Turn on NyCopilot in System Settings → Privacy & Security → Screen Recording."), style: .warning)
            return
        }
        guard services.preferences.canTranslate else {
            services.toast.show(L("Set up a translation service first"), detail: L("Screen translation needs one: Settings → AI & Engines."), style: .warning)
            services.openSettings("model")
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
        let moved: (NSEvent?) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                self?.lastActivity = Date()
                self?.pointerMoved()
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
        hover(nil)
        bar.orderOut(nil)
        displays.forEach { $0.overlay.orderOut(nil) }
        displays = []
        requested = []
    }

    // MARK: Language

    /// Reads into `name` from now on: highlights recount what needs translating, and a card showing
    /// re-translates. `remember` keeps the choice for next time.
    func choose(_ name: String, remember: Bool) {
        language = name
        nativeLanguage = services.core.nativeName(of: name)
        if remember { try? services.core.setSetting(.screenLanguage, name) }
        hover(nil)
        displays.forEach(update)
    }

    /// The menu: favourites first, then every other language NyCopilot knows, in their own scripts.
    func languages() -> [[ScreenTranslationBar.Language]] {
        struct Known: Decodable { let name: String; let native: String }
        let known = (try? services.core.call(.translateLanguages, as: [Known].self)) ?? []
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

    // MARK: Watching

    static let glanceScale: CGFloat = 1.0 / 8
    static let cell = 2 // glance pixels per side of a cell: 16 points

    func watch() async {
        while !Task.isCancelled {
            for display in displays { await glance(at: display) }
            // Checked often, so moving the pointer after a still spell brings the next glance at once.
            let started = Date()
            while !Task.isCancelled, Date().timeIntervalSince(started) < glanceInterval {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }

    /// The wait between glances: a tenth of a second while the screen or pointer moves, easing to
    /// half a second once both have been still a while, and twice that on battery or in Low Power Mode.
    var glanceInterval: TimeInterval {
        let still = Date().timeIntervalSince(lastActivity)
        let base = still < 2 ? 0.1 : still < 10 ? 0.25 : 0.5
        let onBattery = IOPSGetProvidingPowerSourceType(nil)?.takeUnretainedValue() as String? == kIOPMBatteryPowerKey
        return onBattery || ProcessInfo.processInfo.isLowPowerModeEnabled ? base * 2 : base
    }

    func glance(at display: Display) async {
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
                lastActivity = display.changedAt
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
    func read(_ region: CGRect, on display: Display) async {
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
    func update(_ display: Display) {
        display.paragraphs = Self.paragraphs(display.entries, language: ScreenText.code(for: language))
        display.overlay.show(display.paragraphs.map { $0.entries.map(\.line.rect) })
        pointerMoved()
    }

    // MARK: Translating

    /// The block pointed at, unless it's already translated or on its way; the card updates if it's
    /// still showing that block when the translation arrives.
    func translate(_ text: String) async {
        let language = language, key = key(text)
        guard translations[key] == nil, !requested.contains(key) else { return }
        requested.insert(key)
        defer { requested.remove(key) }
        do {
            // Kept out of history: that's for what you translate on purpose, not what you glance at.
            let translation = try await services.core.translate(text, into: language, keys: try services.translationKeys(),
                                                                extra: ["save": false]).text
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
    func pointerMoved() {
        let location = NSEvent.mouseLocation
        guard let display = displays.first(where: { $0.screen.frame.contains(location) }) else { hover(nil); return }
        let point = CGPoint(x: location.x - display.screen.frame.minX, y: display.screen.frame.maxY - location.y)
        hover(display.paragraphs.last { $0.rect.insetBy(dx: -4, dy: -3).contains(point) }.map { (display, $0) })
    }

    /// Brightens the block's highlight at once; its card — and its translation, if it needs one —
    /// follows once the pointer has rested a moment, so sweeping across a page neither flickers cards
    /// nor sends a request for every block passed over.
    func hover(_ target: (display: Display, paragraph: Paragraph)?) {
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

    func present(_ target: (display: Display, paragraph: Paragraph)) {
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
struct PixelSampler {
    let pixels: [UInt8]
    let width: Int, height: Int
    let scale: CGFloat, origin: CGPoint

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

    func sample(_ point: CGPoint) -> (Int, Int, Int)? {
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

extension NSColor {
    /// Near enough to be the same background.
    func resembles(_ other: NSColor) -> Bool {
        guard let a = usingColorSpace(.sRGB), let b = other.usingColorSpace(.sRGB) else { return false }
        return abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent) + abs(a.blueComponent - b.blueComponent) < 0.25
    }
}
