import AppKit
import MacPlatform
import XCTest
@testable import NyCopilotKit

/// The screenshot tool beyond a plain capture, for the README: three rows playing at once (Live
/// Text, scrolling capture, GIF recording), and a capture marked up and pinned. The panels are
/// NyCopilot's own; where the real thing would stream the screen (which GitHub's Macs can't), the
/// scene captures the frames itself and hands them to the same stitcher and GIF writer.
extension DemoTests {
    private static let row = NSSize(width: 960, height: 300)

    /// The three modes, stacked: one desktop, a row each.
    func testCaptureModesDemo() throws {
        let rows = [
            DemoReel.Row(scene: try textScene(), title: "Copy text from anything",
                         detail: "Select, then T: words in images, videos, and shared screens become text you can select."),
            DemoReel.Row(scene: try scrollingScene(), title: "Capture a whole page",
                         detail: "Select, then S, and scroll. The page is stitched together as you go."),
            DemoReel.Row(scene: try recordingScene(), title: "Record a GIF",
                         detail: "Select, then G, and Record. It plays back at once, ready to copy.")
        ]
        XCTAssertTrue(DemoReel.make(rows, into: output.appendingPathComponent("demo-capture-modes.gif")))
    }

    /// Row `index` of three: its own band of one desktop, keys in its bottom-left corner.
    private func rowDirector(_ index: Int, content: NSView, at origin: CGPoint) throws -> DemoDirector {
        let director = try DemoDirector(output: nil, size: Self.row, content: content, at: origin,
                                        backdrop: CGFloat(1 - index) * Self.row.height)
        director.keysCorner = .bottomLeft
        return director
    }

    private func waitUntil(_ director: DemoDirector, timeout: Double = 6, _ condition: () -> Bool) {
        let began = Date()
        while !condition(), Date().timeIntervalSince(began) < timeout { director.wait(0.05) }
    }

    // MARK: Live Text

    /// F1 over a shared screen, select the slide, T: the text glows; select a line, ⌘C.
    private func textScene() throws -> DemoDirector {
        let slide = SlideWindow()
        let director = try rowDirector(0, content: slide, at: CGPoint(x: 300, y: 12))
        director.wait(0.4)
        director.roll()
        director.wait(0.5)

        let (session, overlay, view) = try beginCapture(director, over: [slide])
        drag(director, on: overlay, from: director.onScreen(CGPoint(x: 30, y: 66), in: slide),
             to: director.onScreen(CGPoint(x: 620, y: 236), in: slide))
        director.cursor = .arrow
        // The text button turns blue once the words are read.
        waitUntil(director) { view.toolbar.recognizedLines != nil }
        director.wait(0.9)

        director.press("T")
        director.type("t", keyCode: 17, to: overlay)
        waitUntil(director) { view.textOverlay?.analysis != nil }
        director.wait(1.0)

        // One line, selected right where it is. Synthesized drags don't reach VisionKit's selection,
        // so it's set as the I-beam goes, the way a drag would grow it.
        let text = try XCTUnwrap(view.textOverlay)
        let transcript = text.analysis?.transcript ?? ""
        let line = slide.line(0)
        let start = director.onScreen(CGPoint(x: line.minX + 14, y: line.midY), in: slide)
        let end = director.onScreen(CGPoint(x: line.maxX + 2, y: line.midY), in: slide)
        director.cursor = .iBeam
        director.move(to: start, duration: 0.7)
        if let found = transcript.range(of: "Onboarding") {
            let lineEnd = transcript[found.lowerBound...].firstIndex(of: "\n") ?? transcript.endIndex
            let length = transcript.distance(from: found.lowerBound, to: lineEnd)
            director.move(to: end, duration: 0.9, arc: 0.01) { point in
                let fraction = min(max((point.x - start.x) / (end.x - start.x), 0), 1)
                let upTo = transcript.index(found.lowerBound, offsetBy: Int((Double(length) * fraction).rounded()))
                if #available(macOS 14, *) { text.selectedRanges = [found.lowerBound..<upTo] }
            }
        } else {
            director.move(to: end, duration: 0.9, arc: 0.01)
        }
        director.wait(0.4)
        director.press("⌘", "C")
        director.type("c", keyCode: 8, modifiers: .command, to: overlay)
        director.cursor = .arrow
        XCTAssertTrue(director.cut(hold: 2.0))
        session.close(returningFocus: false)
        return director
    }

    // MARK: Scrolling capture

    /// F1 over an article, select, S: the outline stays while the page scrolls, and the panel
    /// beside it grows the whole page.
    private func scrollingScene() throws -> DemoDirector {
        let article = ArticleWindow()
        let director = try rowDirector(1, content: article, at: CGPoint(x: 330, y: -10))
        director.wait(0.4)
        director.roll()
        director.wait(1.1)

        let (session, overlay, _) = try beginCapture(director, over: [article])
        var picked: CGRect?
        session.onScroll = { region, _ in picked = region }
        drag(director, on: overlay, from: director.onScreen(CGPoint(x: 12, y: 48), in: article),
             to: director.onScreen(CGPoint(x: 368, y: 238), in: article))
        director.cursor = .arrow
        director.wait(0.7)
        director.press("S")
        director.type("s", keyCode: 1, to: overlay)
        let region = try XCTUnwrap(picked)

        let frame = ScreenGeometry.appKit(region)
        let border = RegionOutline(around: frame, look: .accent)
        border.orderFrontRegardless()
        let panel = ScrollCapturePanel(beside: frame, on: director.screen)
        panel.present()
        let scale = director.screen.backingScaleFactor
        let size = (width: Int((region.width * scale).rounded()), height: Int((region.height * scale).rounded()))
        let stitcher = ScrollStitcher(selection: 0..<size.height)
        func stitch() {
            guard let shot = CGWindowListCreateImage(region, .optionOnScreenOnly, kCGNullWindowID, [.bestResolution]),
                  let frame = Self.pixelFrame(shot, size: size) else { return }
            let outcome = stitcher.add(frame)
            switch outcome {
            case .started, .added: panel.show(outcome, height: stitcher.height, thumbnail: stitcher.makeThumbnail())
            default: break
            }
        }
        stitch()
        director.wait(0.5)

        // Down the page, under the outline.
        director.move(to: CGPoint(x: frame.midX + 40, y: frame.midY + 10), duration: 0.7)
        director.isScrolling = true
        let distance = article.scrollableHeight, length = 3.6, began = director.now
        while true {
            let t = min((director.now - began) / length, 1)
            let eased = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
            article.scroll(to: distance * eased)
            stitch()
            if t >= 1 { break }
            director.wait(1 / DemoDirector.fps)
        }
        director.isScrolling = false
        XCTAssertGreaterThan(stitcher.height, size.height * 3, "the whole page was stitched")
        director.wait(1.5)
        director.press("↩")
        director.wait(0.15)
        panel.orderOut(nil)
        border.orderOut(nil)
        XCTAssertTrue(director.cut(hold: 1.0))
        return director
    }

    /// A window's pixels as BGRA rows of exactly `size`, as the stream would give them.
    private static func pixelFrame(_ image: CGImage, size: (width: Int, height: Int)) -> PixelFrame? {
        var pixels = [UInt8](repeating: 0, count: size.width * size.height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: size.width, height: size.height, bitsPerComponent: 8,
                                          bytesPerRow: size.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)
            else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
            return true
        }
        return drawn ? PixelFrame(width: size.width, height: size.height, pixels: pixels) : nil
    }

    // MARK: GIF recording

    /// F1 over something moving, select, G, Record; F1 stops it and the GIF plays back.
    private func recordingScene() throws -> DemoDirector {
        let motion = MotionWindow()
        let director = try rowDirector(2, content: motion, at: CGPoint(x: 330, y: 0))
        motion.clock = { [unowned director] in director.now }
        motion.play()
        defer { motion.stop() }
        director.wait(0.4)
        director.roll()
        director.wait(1.7)

        let (session, overlay, _) = try beginCapture(director, over: [motion])
        var picked: CGRect?
        session.onRecord = { region, _ in picked = region }
        drag(director, on: overlay, from: director.onScreen(CGPoint(x: 22, y: 48), in: motion),
             to: director.onScreen(CGPoint(x: 358, y: 240), in: motion))
        director.cursor = .arrow
        director.wait(0.7)
        director.press("G")
        director.type("g", keyCode: 5, to: overlay)
        let region = try XCTUnwrap(picked)

        let frame = ScreenGeometry.appKit(region)
        let border = RegionOutline(around: frame, look: .ready)
        border.orderFrontRegardless()
        let bar = RecordingBar(beside: frame, on: director.screen, shortcut: "F1")
        bar.orderFrontRegardless()
        director.wait(0.6)

        let record = try XCTUnwrap(buttons(in: bar.contentView).first { $0.toolTip == L("Start recording (%@)", "F1") })
        var recording = false
        bar.onRecord = { recording = true }
        director.move(to: director.onScreen(CGPoint(x: record.bounds.midX, y: record.bounds.midY), in: record), duration: 0.7)
        director.wait(0.15)
        director.click()
        record.performClick(nil)
        XCTAssertTrue(recording)
        border.look = .recording
        bar.showRecording()

        // The clip, from the screen, as the stream would record it.
        let clip = FileManager.default.temporaryDirectory.appendingPathComponent("demo-clip-\(UUID()).gif")
        defer { try? FileManager.default.removeItem(at: clip) }
        let scale = director.screen.backingScaleFactor
        let pixels = (width: Int((region.width * scale).rounded()), height: Int((region.height * scale).rounded()))
        let writer = try XCTUnwrap(GifWriter(url: clip, width: pixels.width, height: pixels.height))
        let started = director.now
        var sampled = -1.0, ticked = -1.0
        func sample() {
            let elapsed = director.now - started
            if elapsed - sampled >= 1.0 / 15,
               let shot = CGWindowListCreateImage(region, .optionOnScreenOnly, kCGNullWindowID, [.bestResolution]) {
                writer.add(shot, at: elapsed)
                sampled = elapsed
            }
            if elapsed - ticked >= 0.25 {
                bar.show(elapsed: elapsed, paused: false)
                ticked = elapsed
            }
        }
        director.move(to: CGPoint(x: frame.maxX + 70, y: frame.midY + 20), duration: 0.9) { _ in sample() }
        while director.now - started < 3.3 {
            sample()
            director.wait(1 / DemoDirector.fps)
        }
        director.press("F1")
        let length = director.now - started
        XCTAssertTrue(writer.finish(at: length))
        border.orderOut(nil)
        bar.showMaking()
        director.wait(0.7)
        bar.orderOut(nil)

        let bytes = (try? FileManager.default.attributesOfItem(atPath: clip.path)[.size] as? Int) ?? 0
        let preview = GifPreview(clip: GifClip(url: clip, size: region.size, pixels: pixels, duration: length, bytes: bytes),
                                 near: frame, on: director.screen)
        preview.show()
        director.wait(2.2)
        let copy = try XCTUnwrap(buttons(in: preview.panel.contentView).first { $0.title == L("Copy") })
        director.move(to: director.onScreen(CGPoint(x: copy.bounds.midX, y: copy.bounds.midY), in: copy), duration: 0.7)
        director.wait(0.2)
        director.click()
        director.wait(0.15)
        preview.close()
        XCTAssertTrue(director.cut(hold: 1.2))
        return director
    }

    // MARK: Edit and pin

    /// F1 over an invoice: box the total, point at the due date, label it, hide the contact
    /// details, P to pin. Switch to the expense sheet; the pin stays, smaller and see-through, beside it.
    func testCaptureEditDemo() throws {
        let invoice = InvoiceWindow()
        let director = try DemoDirector(output: output.appendingPathComponent("demo-capture-edit.gif"), content: invoice,
                                        at: CGPoint(x: 300, y: 46))
        director.wait(0.4)
        director.roll()
        director.wait(0.6)

        let (session, overlay, view) = try beginCapture(director, over: [invoice])
        var pinned: (image: NSImage, region: CGRect)?
        session.onFinish = { action, image, region, _ in if action == .pin { pinned = (image, region) } }
        func at(_ x: CGFloat, _ y: CGFloat) -> CGPoint { director.onScreen(CGPoint(x: x, y: y), in: invoice) }
        drag(director, on: overlay, from: at(18, 54), to: at(542, 442))
        director.cursor = .arrow
        director.wait(0.6)

        // A box around the total.
        try pick(.rectangle, on: overlay, director)
        let total = invoice.total
        director.cursor = .crosshair
        drag(director, on: overlay, from: at(total.minX - 10, total.minY - 7), to: at(total.maxX + 10, total.maxY + 7), duration: 0.7)
        director.wait(0.4)

        // An arrow to the due date, and a label at its tail.
        try pick(.arrow, on: overlay, director)
        let due = invoice.due
        let tail = CGPoint(x: due.maxX + 130, y: due.midY)
        director.cursor = .crosshair
        drag(director, on: overlay, from: at(tail.x, tail.y), to: at(due.maxX + 10, due.midY), duration: 0.6, arc: 0.12)
        director.wait(0.3)
        try pick(.text, on: overlay, director)
        director.cursor = .iBeam
        director.move(to: at(tail.x + 10, due.midY - 13), duration: 0.6) { _ in director.send(.mouseMoved, to: overlay) }
        director.click()
        director.send(.leftMouseDown, to: overlay)
        director.send(.leftMouseUp, to: overlay)
        let editor = try XCTUnwrap(view.subviews.lazy.compactMap { $0 as? TextAnnotationEditor }.first)
        director.wait(0.2)
        for character in "Pay by Friday" {
            editor.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
            director.wait(character == " " ? 0.08 : 0.055)
        }
        director.wait(0.3)
        director.press("↩")
        director.type("\r", keyCode: 36, to: overlay)
        director.wait(0.4)

        // The contact details, blurred into blocks.
        try pick(.mosaic, on: overlay, director)
        let contact = invoice.contact
        director.cursor = .crosshair
        drag(director, on: overlay, from: at(contact.minX - 4, contact.midY), to: at(contact.maxX + 6, contact.midY), duration: 0.9, arc: 0)
        director.cursor = .arrow
        director.wait(0.7)

        director.press("P")
        director.type("p", keyCode: 35, to: overlay)
        let capture = try XCTUnwrap(pinned)
        let pin = PinWindow(image: capture.image, frame: ScreenGeometry.appKit(capture.region), shadow: true)
        pin.orderFrontRegardless()
        director.wait(0.9)

        // Over to the expense sheet; the pin stays on top.
        director.press("⌘", "⇥")
        let sheet = SheetWindow()
        director.place(sheet, at: CGPoint(x: 40, y: 70))
        invoice.isHidden = true
        director.wait(0.8)

        // Scroll to zoom out, ⌥-scroll to see through it.
        director.move(to: CGPoint(x: pin.frame.maxX - 60, y: pin.frame.maxY - 60), duration: 0.8)
        director.isScrolling = true
        var began = director.now
        while director.now - began < 1.1 {
            let t = min((director.now - began) / 1.1, 1)
            pin.setZoom(1 - 0.42 * (1 - pow(1 - t, 2)), around: director.pointer)
            director.wait(1.0 / 30)
        }
        director.wait(0.5)
        director.press("⌥")
        began = director.now
        while director.now - began < 0.8 {
            let t = min((director.now - began) / 0.8, 1)
            pin.setOpacity(1 - 0.25 * t)
            director.wait(1.0 / 30)
        }
        director.isScrolling = false
        director.wait(0.6)

        // Beside the sheet, then fill in the amount from it.
        let offset = CGPoint(x: pin.frame.minX - director.pointer.x, y: pin.frame.minY - director.pointer.y)
        let target = director.onScreen(sheet.bounds, in: sheet)
        director.click()
        director.move(to: CGPoint(x: target.maxX + 30 - offset.x, y: target.maxY - 30 - pin.frame.height - offset.y), duration: 0.9) { point in
            pin.setFrameOrigin(CGPoint(x: point.x + offset.x, y: point.y + offset.y))
        }
        director.wait(0.4)
        director.cursor = .arrow
        director.move(to: director.onScreen(CGPoint(x: sheet.amountCell.midX, y: sheet.amountCell.midY), in: sheet), duration: 0.8)
        director.click()
        sheet.isEditing = true
        director.wait(0.3)
        for character in "7,400.00" {
            sheet.typed.append(character)
            director.wait(0.09)
        }
        director.press("↩")
        sheet.isEditing = false
        XCTAssertTrue(director.cut(hold: 2.2))
        pin.orderOut(nil)
    }

    /// Clicks a tool on the capture toolbar, the pointer taking `travel` seconds to get there.
    func pick(_ tool: AnnotationTool, on overlay: NSWindow, _ director: DemoDirector, travel: Double = 0.6) throws {
        let index = try XCTUnwrap(AnnotationTool.allCases.firstIndex(of: tool))
        let button = try XCTUnwrap(toolbarButtons(in: overlay).first { $0.toolTip == "\(tool.title) (\(index + 1))" })
        director.cursor = .arrow
        director.move(to: director.onScreen(CGPoint(x: button.bounds.midX, y: button.bounds.midY), in: button), duration: travel)
        button.mouseEntered(with: NSEvent())
        director.wait(travel / 3)
        director.click()
        button.performClick(nil)
        director.wait(0.25)
        button.mouseExited(with: NSEvent())
    }
}

// MARK: - The apps being worked in

private let ink = NSColor(white: 0.16, alpha: 1)
private let muted = NSColor(white: 0.5, alpha: 1)

private func paint(_ text: String, at point: CGPoint, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = ink) {
    (text as NSString).draw(at: point, withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color])
}

private func textSize(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular) -> NSSize {
    (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight)])
}

/// A video call showing someone's slide: text you can read but not select.
private final class SlideWindow: MockWindow {
    private let lines = ["Onboarding in two steps — Oct 3", "Press kit to partners — Oct 7", "Launch event in Kyoto — Oct 14"]

    init() { super.init(title: "Design review · Maya is sharing", size: NSSize(width: 640, height: 330)) }
    required init?(coder: NSCoder) { fatalError() }

    /// Where line `index` of the list is drawn.
    func line(_ index: Int) -> NSRect {
        let text = "•  " + lines[index], size = textSize(text, size: 18, weight: .medium)
        return NSRect(x: 48, y: 136 + CGFloat(index) * 34, width: size.width, height: size.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor(srgbRed: 0.12, green: 0.13, blue: 0.25, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 14, y: 54, width: 612, height: 262), xRadius: 8, yRadius: 8).fill()
        paint("Launch checklist", at: CGPoint(x: 46, y: 82), size: 28, weight: .bold, color: .white)
        for index in lines.indices {
            paint("•  " + lines[index], at: line(index).origin, size: 18, weight: .medium, color: NSColor.white.withAlphaComponent(0.9))
        }
        NSColor(srgbRed: 0.98, green: 0.62, blue: 0.27, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 48, y: 122, width: 44, height: 4), xRadius: 2, yRadius: 2).fill()
    }
}

/// A long article in a browser, scrolled from the scene.
private final class ArticleWindow: MockWindow {
    private let scroller = NSScrollView()
    private let page = ArticlePage()

    init() {
        super.init(title: "Field Notes — Kyoto in autumn", size: NSSize(width: 380, height: 420))
        scroller.frame = NSRect(x: 0, y: 41, width: bounds.width, height: bounds.height - 41)
        scroller.hasVerticalScroller = false
        scroller.drawsBackground = true
        scroller.backgroundColor = .white
        scroller.documentView = page
        addSubview(scroller)
    }
    required init?(coder: NSCoder) { fatalError() }

    var scrollableHeight: CGFloat { page.frame.height - scroller.contentSize.height }

    /// To a whole pixel, as a wheel scrolls: a fractional offset blends the edges of the strips the
    /// clip view redraws into faint lines.
    func scroll(to offset: CGFloat) {
        let scale = window?.backingScaleFactor ?? 1
        scroller.contentView.scroll(to: NSPoint(x: 0, y: (offset * scale).rounded() / scale))
        scroller.reflectScrolledClipView(scroller.contentView)
        window?.displayIfNeeded()
    }
}

private final class ArticlePage: NSView {
    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 380, height: 0))
        // Exactly as long as the article, so scrolling to the end ends on its last line.
        frame.size.height = layOut(drawing: false) + 20
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    private let paragraphs = [
        "The maples turn late here, in the last weeks of November, and the city fills with people who came to see "
            + "them. Go early: by eight the paths at Tōfuku-ji are already busy, but the light through the leaves is at its best.",
        "Walk north along the Philosopher’s Path to Ginkaku-ji. The canal is lined with cherry trees that are bare by "
            + "now, and the small cafés along it open at ten. Most take cash only.",
        "In the evening, the riverbanks of the Kamo fill up with students and families. Buy something warm from a "
            + "konbini and sit on the stepping stones near Demachiyanagi as the sky goes orange, then purple.",
        "Getting around: a one-day bus pass covers almost everything in this guide, and the buses run until "
            + "eleven. For Arashiyama, take the JR line from Kyoto Station instead; it’s faster and the pass covers it."
    ]

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        bounds.fill()
        layOut(drawing: true)
    }

    /// Where everything goes, drawn or only measured; returns where the article ends.
    @discardableResult
    private func layOut(drawing: Bool) -> CGFloat {
        if drawing {
            photo(NSRect(x: 20, y: 16, width: 340, height: 150), [NSColor(srgbRed: 0.96, green: 0.55, blue: 0.2, alpha: 1),
                                                                  NSColor(srgbRed: 0.78, green: 0.16, blue: 0.2, alpha: 1)], "Tōfuku-ji, 7:40 am")
            paint("Kyoto in autumn", at: CGPoint(x: 20, y: 182), size: 24, weight: .bold)
            paint("By Ren Ito · 6 min read", at: CGPoint(x: 20, y: 216), size: 12, color: muted)
        }
        var y: CGFloat = 248
        for (index, text) in paragraphs.enumerated() {
            y = paragraph(text, at: y, drawing: drawing) + 18
            if index == 0 {
                if drawing {
                    photo(NSRect(x: 20, y: y, width: 340, height: 170), [NSColor(srgbRed: 0.27, green: 0.55, blue: 0.33, alpha: 1),
                                                                         NSColor(srgbRed: 0.12, green: 0.33, blue: 0.27, alpha: 1)], "Moss garden, Ginkaku-ji")
                }
                y += 188
            } else if index == 2 {
                if drawing {
                    photo(NSRect(x: 20, y: y, width: 340, height: 150), [NSColor(srgbRed: 0.99, green: 0.6, blue: 0.4, alpha: 1),
                                                                         NSColor(srgbRed: 0.42, green: 0.27, blue: 0.55, alpha: 1)], "The Kamo at dusk")
                }
                y += 168
            }
        }
        return y
    }

    private func paragraph(_ text: String, at y: CGFloat, drawing: Bool) -> CGFloat {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 4
        let attributed = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: ink,
                                                                       .paragraphStyle: style])
        let height = ceil(attributed.boundingRect(with: NSSize(width: 340, height: 1000), options: [.usesLineFragmentOrigin]).height)
        if drawing { attributed.draw(in: NSRect(x: 20, y: y, width: 340, height: height)) }
        return y + height
    }

    private func photo(_ rect: NSRect, _ colors: [NSColor], _ caption: String) {
        NSGradient(colors: colors)!.draw(in: NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10), angle: 70)
        // A few soft shapes, so stitched rows have something to line up on.
        for index in 0..<5 {
            let x = rect.minX + 30 + CGFloat(index) * 64, y = rect.minY + rect.height * (index.isMultiple(of: 2) ? 0.3 : 0.55)
            NSColor.white.withAlphaComponent(0.14 + 0.04 * CGFloat(index)).setFill()
            NSBezierPath(ovalIn: NSRect(x: x, y: y, width: 46, height: 46)).fill()
        }
        paint(caption, at: CGPoint(x: rect.minX + 12, y: rect.maxY - 26), size: 12, weight: .semibold, color: NSColor.white.withAlphaComponent(0.92))
    }
}

/// A prototype with a sync animation that loops: worth recording.
private final class MotionWindow: MockWindow {
    private var timer: Timer?
    /// The scene's time, so the animation keeps pace with the recording.
    var clock: () -> Double = { CACurrentMediaTime() }

    init() { super.init(title: "Prototype — Photo sync", size: NSSize(width: 380, height: 330)) }
    required init?(coder: NSCoder) { fatalError() }

    func play() {
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.needsDisplay = true } }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() { timer?.invalidate() }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let phase = clock().truncatingRemainder(dividingBy: 2.6) / 2.6
        let progress = CGFloat(min(phase / 0.72, 1))
        let eased = 1 - pow(1 - progress, 2)
        let done = phase >= 0.72
        let center = CGPoint(x: 112, y: 150), radius: CGFloat = 50
        NSColor(white: 0.92, alpha: 1).setStroke()
        let track = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        track.lineWidth = 11
        track.stroke()
        let accent = done ? NSColor(srgbRed: 0.2, green: 0.72, blue: 0.4, alpha: 1) : NSColor(srgbRed: 0.35, green: 0.33, blue: 0.86, alpha: 1)
        accent.setStroke()
        let arc = NSBezierPath()
        // Flipped: clockwise from the top.
        arc.appendArc(withCenter: center, radius: radius, startAngle: -90, endAngle: -90 + 360 * eased, clockwise: false)
        arc.lineWidth = 11
        arc.lineCapStyle = .round
        arc.stroke()
        if done {
            // The check pops in, a little past full size, then settles.
            let t = CGFloat(min((phase - 0.72) / 0.12, 1))
            let pop = t < 0.7 ? t / 0.7 * 1.15 : 1.15 - 0.15 * (t - 0.7) / 0.3
            let check = NSBezierPath()
            check.move(to: CGPoint(x: center.x - 20 * pop, y: center.y + 2 * pop))
            check.line(to: CGPoint(x: center.x - 6 * pop, y: center.y + 16 * pop))
            check.line(to: CGPoint(x: center.x + 22 * pop, y: center.y - 14 * pop))
            check.lineWidth = 9
            check.lineCapStyle = .round
            check.lineJoinStyle = .round
            check.stroke()
        } else {
            let percent = "\(Int(eased * 100))%"
            let size = textSize(percent, size: 20, weight: .bold)
            paint(percent, at: CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2), size: 20, weight: .bold)
        }
        paint(done ? "All photos synced" : "Syncing photos…", at: CGPoint(x: 190, y: 118), size: 16, weight: .semibold)
        paint("\(done ? 248 : Int(eased * 248)) of 248", at: CGPoint(x: 190, y: 144), size: 13, color: muted)
        NSColor(white: 0.93, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 190, y: 170, width: 150, height: 6), xRadius: 3, yRadius: 3).fill()
        accent.setFill()
        NSBezierPath(roundedRect: NSRect(x: 190, y: 170, width: 150 * eased, height: 6), xRadius: 3, yRadius: 3).fill()
    }
}

/// An invoice in Mail: a total worth boxing, a date worth pointing at, and contact details to hide.
private final class InvoiceWindow: MockWindow {
    private let items = [("Brand workshop, 2 days", "$2,400.00"), ("Logo refresh", "$1,800.00"), ("Launch site design", "$3,200.00")]
    private let contactText = "jordan.lee@example.com  ·  +1 (415) 555-0142"

    init() { super.init(title: "Invoice 1042 — Northwind Studio", size: NSSize(width: 560, height: 470)) }
    required init?(coder: NSCoder) { fatalError() }

    var due: NSRect {
        let size = textSize("Due November 14", size: 15, weight: .semibold)
        return NSRect(x: 40, y: 104, width: size.width, height: size.height)
    }
    var contact: NSRect {
        let size = textSize(contactText, size: 13)
        return NSRect(x: 40, y: 160, width: size.width, height: size.height)
    }
    var total: NSRect {
        let size = textSize("$7,400.00", size: 18, weight: .bold)
        return NSRect(x: 520 - size.width, y: 352, width: size.width, height: size.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        paint("Northwind Studio", at: CGPoint(x: 40, y: 64), size: 24, weight: .bold)
        let number = "INVOICE #1042", width = textSize(number, size: 12, weight: .semibold).width
        paint(number, at: CGPoint(x: 520 - width, y: 72), size: 12, weight: .semibold, color: muted)
        paint("Due November 14", at: due.origin, size: 15, weight: .semibold, color: NSColor(srgbRed: 0.85, green: 0.33, blue: 0.2, alpha: 1))
        paint("Bill to Jordan Lee", at: CGPoint(x: 40, y: 138), size: 13, weight: .medium)
        paint(contactText, at: contact.origin, size: 13, color: muted)
        NSColor(white: 0.9, alpha: 1).setFill()
        NSRect(x: 40, y: 206, width: 480, height: 1).fill()
        for (index, item) in items.enumerated() {
            let y = 222 + CGFloat(index) * 36
            paint(item.0, at: CGPoint(x: 40, y: y), size: 14)
            paint(item.1, at: CGPoint(x: 520 - textSize(item.1, size: 14).width, y: y), size: 14)
        }
        NSRect(x: 40, y: 334, width: 480, height: 1).fill()
        paint("Total due", at: CGPoint(x: 40, y: 353), size: 16, weight: .semibold)
        paint("$7,400.00", at: total.origin, size: 18, weight: .bold)
        paint("Please pay by bank transfer within 30 days. Thank you!", at: CGPoint(x: 40, y: 410), size: 12, color: muted)
    }
}

/// Where the invoice's numbers go: a spreadsheet with an amount still to fill in.
private final class SheetWindow: MockWindow {
    var typed = "" { didSet { needsDisplay = true } }
    var isEditing = false { didSet { needsDisplay = true } }
    private let columns: [(title: String, x: CGFloat)] = [("Vendor", 16), ("Invoice", 196), ("Due", 286), ("Amount", 376)]
    private let rows = [["Figma", "8812", "Nov 3", "$45.00"], ["Fly.io", "2290", "Nov 8", "$112.40"],
                        ["Northwind Studio", "1042", "Nov 14", ""], ["", "", "", ""], ["", "", "", ""]]

    init() { super.init(title: "Expenses — November", size: NSSize(width: 520, height: 330)) }
    required init?(coder: NSCoder) { fatalError() }

    var amountCell: NSRect { NSRect(x: 370, y: 41 + 36 + 2 * 34, width: 140, height: 34) }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor(white: 0.975, alpha: 1).setFill()
        NSRect(x: 0, y: 41, width: bounds.width, height: 36).fill()
        for column in columns { paint(column.title, at: CGPoint(x: column.x, y: 51), size: 12, weight: .semibold, color: muted) }
        NSColor(white: 0.9, alpha: 1).setFill()
        for index in 0...rows.count { NSRect(x: 0, y: 77 + CGFloat(index) * 34, width: bounds.width, height: 1).fill() }
        for column in columns.dropFirst() { NSRect(x: column.x - 6, y: 41, width: 1, height: 36 + CGFloat(rows.count) * 34).fill() }
        for (index, row) in rows.enumerated() {
            for (column, text) in zip(columns, row) { paint(text, at: CGPoint(x: column.x, y: 86 + CGFloat(index) * 34), size: 13) }
        }
        let cell = amountCell
        if !typed.isEmpty { paint("$" + typed, at: CGPoint(x: cell.minX + 6, y: cell.minY + 9), size: 13) }
        if isEditing || !typed.isEmpty {
            NSColor.controlAccentColor.setStroke()
            let outline = NSBezierPath(rect: cell.insetBy(dx: 1, dy: 1))
            outline.lineWidth = 2
            outline.stroke()
        }
    }
}
