import AppKit
import XCTest
@testable import NyCopilotKit

/// The README's moving pictures (see DemoDirector). They take over the screen for a few seconds
/// each, so they run only when asked, with the Mac left alone meanwhile:
///
///     NYCOPILOT_DEMOS=1 swift test --filter DemoTests
@MainActor
final class DemoTests: XCTestCase {
    let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../../../docs/images").standardizedFileURL

    override func setUp() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["NYCOPILOT_DEMOS"] != nil,
                          "set NYCOPILOT_DEMOS=1 to record the README's moving pictures")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    }

    // MARK: The opening picture

    /// The README's first picture, cut like a short ad (see DemoSpot): capture and pin, write in
    /// another language, jot a thought, ask AI, snap windows, then every key on one card.
    func testHeroDemo() throws {
        // The card's desktop first, with nothing on it yet.
        let backdrop = try DemoDirector(output: nil, content: NSView(), at: .zero)
        backdrop.showsPointer = false
        backdrop.wait(0.3)
        backdrop.roll()
        _ = backdrop.cut(hold: 0)
        let beats = [
            DemoSpot.Beat(scene: try heroPin(), keys: ["F1"], line: "Capture anything. Pin it on top."),
            DemoSpot.Beat(scene: try heroTranslate(), keys: ["F2"], line: "Type in your language. Send in theirs."),
            DemoSpot.Beat(scene: try heroJot(), keys: ["F3"], line: "Catch the thought before it’s gone."),
            DemoSpot.Beat(scene: try heroAsk(), keys: ["F4"], line: "Ask AI about anything you read."),
            DemoSpot.Beat(scene: try heroWindows(), keys: ["⌃", "⌥", "→"], line: "Snap every window into place.")
        ]
        let card = DemoSpot.Card(backdrop: backdrop, icon: NSImage(contentsOf: output.appendingPathComponent("icon.png")),
                                 title: "NyCopilot", line: "The copilot that lives in every app on your Mac.",
                                 keys: [("F1", "Capture & pin"), ("F2", "Translate"), ("F3", "Jot it down"), ("F4", "Ask AI"),
                                        ("⌃⌥→", "Window layouts")],
                                 footnote: "Free and open source  ·  macOS 14 and later", hold: 2.6)
        XCTAssertTrue(DemoSpot.make(beats, card: card, into: output.appendingPathComponent("demo-hero.gif")))
    }

    /// F1, drag out the chart, P pins it. Over in the slides being made, the pin stays on top and moves beside them.
    private func heroPin() throws -> DemoDirector {
        let notes = NotesWindow()
        let director = try DemoDirector(output: nil, content: notes, at: CGPoint(x: 140, y: 104))
        director.keysShownElsewhere = ["F1"]
        let region = notes.chartWithCaption
        director.move(to: director.onScreen(CGPoint(x: region.minX, y: region.minY), in: notes), duration: 0.01)
        director.roll()
        director.wait(0.2)

        let (session, overlay, _) = try beginCapture(director, over: [notes])
        var pinned: (image: NSImage, region: CGRect)?
        session.onFinish = { action, image, region, _ in if action == .pin { pinned = (image, region) } }
        director.send(.mouseMoved, to: overlay)
        director.send(.leftMouseDown, to: overlay)
        director.move(to: director.onScreen(CGPoint(x: region.maxX, y: region.maxY), in: notes), duration: 0.5, arc: 0.04) { _ in
            director.send(.leftMouseDragged, to: overlay)
        }
        director.send(.leftMouseUp, to: overlay)
        director.cursor = .arrow
        director.wait(0.3)

        director.press("P")
        director.type("p", keyCode: 35, to: overlay)
        let capture = try XCTUnwrap(pinned)
        let pin = PinWindow(image: capture.image, frame: CaptureSession.appKitRect(capture.region), shadow: true)
        pin.orderFrontRegardless()
        director.wait(0.45)

        // Over to the slides; the pin stays on top, and goes beside the slide it's for.
        director.press("⌘", "⇥")
        let slides = SlidesWindow()
        slides.alphaValue = 0
        director.place(slides, at: CGPoint(x: 36, y: 96))
        let began = director.now
        while director.now - began < 0.22 {
            let t = CGFloat(min((director.now - began) / 0.22, 1))
            slides.alphaValue = t
            notes.alphaValue = 1 - t
            director.wait(1.0 / 30)
        }
        slides.alphaValue = 1
        notes.isHidden = true
        director.wait(0.2)
        let grab = CGPoint(x: pin.frame.midX, y: pin.frame.midY)
        director.move(to: grab, duration: 0.35)
        director.click()
        let offset = CGPoint(x: pin.frame.minX - grab.x, y: pin.frame.minY - grab.y)
        let crop = director.crop
        let to = CGPoint(x: crop.minX + 410 - offset.x, y: crop.maxY - 360 - pin.frame.height - offset.y)
        director.move(to: to, duration: 0.55, arc: 0.08) { point in
            pin.setFrameOrigin(CGPoint(x: point.x + offset.x, y: point.y + offset.y))
        }
        XCTAssertTrue(director.cut(hold: 0.7))
        pin.orderOut(nil)
        return director
    }

    /// F2 in the reply field, type in English, Return: it goes out in Japanese.
    private func heroTranslate() throws -> DemoDirector {
        let chat = ChatWindow()
        let director = try DemoDirector(output: nil, content: chat, at: CGPoint(x: 180, y: 104))
        director.keysShownElsewhere = ["F2"]
        director.move(to: director.onScreen(CGPoint(x: 140, y: chat.field.bounds.midY), in: chat.field), duration: 0.01)
        director.cursor = .iBeam
        director.roll()
        director.wait(0.3)

        director.press("F2")
        director.wait(0.15)
        let composer = ComposerPanel()
        let field = director.onScreen(chat.field.bounds, in: chat.field)
        composer.present(over: ScreenGeometry.topLeft(field), mode: .paste, language: .init(code: "日", name: "Japanese"))
        director.look(at: (composer.window?.frame ?? field).union(field))
        director.wait(0.35)
        let editor = try XCTUnwrap(composer.window?.firstResponder as? NSTextView)
        for character in "Sure, 3 pm works. See you then!" {
            editor.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
            director.wait(character == " " ? 0.045 : 0.026)
        }
        director.wait(0.25)
        director.press("↩")
        composer.showLoading()
        director.wait(0.3)
        composer.close()
        chat.field.stringValue = "はい、15時で大丈夫です。ではその時に！"
        XCTAssertTrue(director.cut(hold: 0.9))
        return director
    }

    /// Reading a page, F3, jot a to-do, Return: it's in the inbox, with where it came from.
    private func heroJot() throws -> DemoDirector {
        let page = BrowserWindow(title: "Kyoto venues for the launch", size: NSSize(width: 680, height: 430))
        let director = try DemoDirector(output: nil, content: page, at: CGPoint(x: 140, y: 120))
        director.keysShownElsewhere = ["F3"]
        director.move(to: director.onScreen(CGPoint(x: 420, y: 250), in: page), duration: 0.01)
        director.roll()
        director.wait(0.3)

        director.press("F3")
        director.wait(0.12)
        let bar = InboxCaptureBar()
        var saved = ""
        bar.onSave = { text, _ in saved = text }
        bar.present(context: SourceContext(app: "Safari", title: "Kyoto venues for the launch", url: "https://kyoto-venues.example"),
                    returningTo: nil, waiting: 0)
        let panel = try XCTUnwrap(NSApp.windows.first { $0.isVisible && $0.firstResponder is JotView })
        let frame = panel.frame
        director.look(at: frame.insetBy(dx: 0, dy: -50))
        director.wait(0.35)
        let input = try XCTUnwrap(panel.firstResponder as? JotView)
        for character in "Book the Kyoto venue by Friday" {
            input.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
            director.wait(character == " " ? 0.045 : 0.026)
        }
        director.wait(0.25)
        director.press("↩")
        director.type("\r", keyCode: 36, to: panel)
        if bar.isVisible { bar.close(returningFocus: false) }
        Toast().show(L("Saved to Inbox"), detail: "Safari · Kyoto venues for the launch", style: .success, near: frame.offsetBy(dx: 0, dy: frame.height - 10))
        XCTAssertTrue(director.cut(hold: 1.1))
        XCTAssertEqual(saved, "Book the Kyoto venue by Friday")
        return director
    }

    /// Select a paragraph, F4, Summarize: the answer streams in beside it.
    private func heroAsk() throws -> DemoDirector {
        let notes = NotesWindow()
        let director = try DemoDirector(output: nil, content: notes, at: CGPoint(x: 140, y: 104))
        director.keysShownElsewhere = ["F4"]
        let text = notes.paragraph
        director.move(to: director.onScreen(text.firstGlyphPoint, in: text), duration: 0.01)
        director.cursor = .iBeam
        director.roll()
        director.wait(0.25)

        director.move(to: director.onScreen(text.lastGlyphPoint, in: text), duration: 0.5, arc: 0.02) { point in
            let local = text.convert(text.window!.convertPoint(fromScreen: point), from: nil)
            text.setSelectedRange(NSRange(location: 0, length: text.characterIndexForInsertion(at: local)))
        }
        text.setSelectedRange(NSRange(location: 0, length: text.string.utf16.count))
        director.cursor = .arrow
        director.wait(0.15)

        director.press("F4")
        director.wait(0.15)
        let ask = AskPanel()
        let answer = "**Launch moves to October 14.** Onboarding drops to two steps; the press kit is due a week early."
        ask.onAsk = { _, _, _ in
            // The bold opening arrives whole, so its asterisks never show half-way.
            let lead = "**Launch moves to October 14.**"
            var shown = ""
            for word in [lead] + answer.dropFirst(lead.count + 1).split(separator: " ", omittingEmptySubsequences: false).map(String.init) {
                shown += (shown.isEmpty ? "" : " ") + word
                await MainActor.run { ask.streamed(shown) }
                // A word every 45 ms of the recording's time, however slow the machine.
                let due = await MainActor.run { director.now } + 0.045
                while await MainActor.run(body: { director.now }) < due { try? await Task.sleep(nanoseconds: 5_000_000) }
            }
            return answer
        }
        var material = AskMaterial(text: text.string, source: SourceContext(app: "Notes", title: "Q3 launch notes", url: ""))
        material.anchor = director.onScreen(text.bounds, in: text)
        ask.prepare(material)
        if !ask.panel.isVisible { ask.panel.orderFrontRegardless() }
        director.wait(0.3)

        let summarize = try XCTUnwrap(buttons(in: ask.panel.contentView).first { $0.title == L("Summarize") })
        director.move(to: director.onScreen(CGPoint(x: summarize.bounds.midX, y: summarize.bounds.midY), in: summarize), duration: 0.4)
        director.click()
        summarize.performClick(nil)
        director.wait(0.1)
        director.look(at: ask.panel.frame)
        let asked = Date()
        while !ask.transcript.string.hasSuffix("early."), Date().timeIntervalSince(asked) < 10 { director.wait(0.05) }
        XCTAssertTrue(director.cut(hold: 1.0))
        ask.close()
        return director
    }

    /// Two windows in a heap. Drag one to the left edge: it fills the left half. ⌃⌥→ sends the other to the right.
    private func heroWindows() throws -> DemoDirector {
        let page = BrowserWindow(title: "Kyoto venues for the launch", size: NSSize(width: 540, height: 380))
        let director = try DemoDirector(output: nil, content: page, at: CGPoint(x: 110, y: 130))
        director.keysShownElsewhere = ["⌃", "⌥", "→"]
        let list = ChecklistWindow()
        director.place(list, at: CGPoint(x: 400, y: 190))
        let grab = director.onScreen(CGPoint(x: 150, y: 20), in: page)
        director.move(to: CGPoint(x: grab.x + 120, y: grab.y - 160), duration: 0.01)
        director.roll()
        director.wait(0.15)

        // Up to the page's title bar, and over to the left edge: its footprint shows where it'll land.
        director.move(to: grab, duration: 0.35)
        director.click()
        // To the front, as a click does.
        page.removeFromSuperview()
        director.stage.contentView?.addSubview(page)
        let footprint = Footprint()
        let crop = director.crop
        // Halves of the screen below the caption, which stands in for the menu bar.
        let screen = NSRect(x: crop.minX, y: crop.minY, width: crop.width, height: crop.height - DemoSpot.band)
        let left = NSRect(x: screen.minX, y: screen.minY, width: screen.width / 2, height: screen.height)
        let right = NSRect(x: screen.midX, y: screen.minY, width: screen.width / 2, height: screen.height)
        let offset = CGPoint(x: page.frame.minX - grab.x, y: page.frame.minY - grab.y)
        director.move(to: CGPoint(x: crop.minX + 3, y: grab.y - 40), duration: 0.55, arc: 0.06) { point in
            page.setFrameOrigin(CGPoint(x: point.x + offset.x, y: point.y + offset.y))
            if point.x < crop.minX + 24 { footprint.show(left) }
        }
        director.wait(0.2)
        footprint.hide()
        resize(page, to: left, director)
        director.wait(0.3)

        director.press("⌃", "⌥", "→")
        resize(list, to: right, director)
        XCTAssertTrue(director.cut(hold: 0.8))
        return director
    }

    /// Moves and sizes a window on the stage to `frame` (on screen), quickly, the way a layout lands.
    private func resize(_ window: NSView, to frame: NSRect, _ director: DemoDirector, duration: Double = 0.24) {
        let from = window.frame, began = director.now
        while true {
            let t = min((director.now - began) / duration, 1), eased = CGFloat(1 - pow(1 - t, 3))
            window.frame = NSRect(x: from.minX + (frame.minX - from.minX) * eased, y: from.minY + (frame.minY - from.minY) * eased,
                                  width: from.width + (frame.width - from.width) * eased, height: from.height + (frame.height - from.height) * eased)
            window.needsDisplay = true
            if t >= 1 { break }
            director.wait(1.0 / 30)
        }
    }

    /// F1: the screen as it is now, frozen under a capture, with `windows` to outline.
    func beginCapture(_ director: DemoDirector, over windows: [NSView]) throws -> (CaptureSession, NSWindow, CaptureView) {
        director.press("F1")
        director.wait(0.2)
        let screen = director.screen
        let whole = CGRect(x: 0, y: 0, width: screen.frame.width, height: screen.frame.height)
        let image = try XCTUnwrap(CGWindowListCreateImage(whole, .optionOnScreenOnly, kCGNullWindowID, [.bestResolution]))
        let frozen = FrozenScreen(screen: screen, image: image, windows: windows.map {
            .init(rect: ScreenGeometry.topLeft(director.onScreen($0.bounds, in: $0)), pid: getpid())
        })
        let session = CaptureSession(frozen: [frozen], recent: [], palette: [.systemRed, .systemOrange, .systemYellow, .systemGreen, .systemBlue],
                                     color: .systemRed, stroke: 4, style: CaptureStyle()) { _, _, _ in }
        session.show()
        let overlay = try XCTUnwrap(NSApp.windows.first { $0 is CaptureWindow && $0.isVisible })
        func find(_ view: NSView) -> CaptureView? { (view as? CaptureView) ?? view.subviews.lazy.compactMap(find).first }
        let view = try XCTUnwrap(overlay.contentView.flatMap(find))
        // Where the recording's pointer is, not the Mac's own.
        director.send(.mouseMoved, to: overlay)
        director.cursor = .crosshair
        director.wait(0.35)
        return (session, overlay, view)
    }

    /// Drags out a selection (or a shape) on the capture, from `start` to `end` on screen.
    func drag(_ director: DemoDirector, on window: NSWindow, from start: CGPoint, to end: CGPoint, duration: Double = 0.9, arc: CGFloat = 0.04) {
        director.move(to: start, duration: 0.65) { _ in director.send(.mouseMoved, to: window) }
        director.send(.leftMouseDown, to: window)
        director.move(to: end, duration: duration, arc: arc) { _ in director.send(.leftMouseDragged, to: window) }
        director.send(.leftMouseUp, to: window)
    }

    func toolbarButtons(in window: NSWindow) -> [ToolbarButton] {
        func find(_ view: NSView) -> [ToolbarButton] { view.subviews.flatMap { ($0 as? ToolbarButton).map { [$0] } ?? find($0) } }
        return window.contentView.map(find) ?? []
    }

    // MARK: Translate

    /// Read Japanese in English (select, F2), then write English that goes out in Japanese (F2, type, Return).
    func testTranslateDemo() throws {
        let chat = ChatWindow()
        let director = try DemoDirector(output: output.appendingPathComponent("demo-translate.gif"), content: chat, at: CGPoint(x: 180, y: 50))
        director.wait(0.4)
        director.roll()
        director.wait(0.6)

        // Select the message.
        let message = chat.received
        let start = director.onScreen(message.firstGlyphPoint, in: message)
        let end = director.onScreen(message.lastGlyphPoint, in: message)
        director.cursor = .iBeam
        director.move(to: start, duration: 0.8)
        director.move(to: end, duration: 0.8, arc: 0.03) { point in
            let local = message.convert(message.window!.convertPoint(fromScreen: point), from: nil)
            message.setSelectedRange(NSRange(location: 0, length: message.characterIndexForInsertion(at: local)))
        }
        message.setSelectedRange(NSRange(location: 0, length: message.string.utf16.count))
        director.wait(0.4)

        director.press("F2")
        director.wait(0.2)
        let card = TranslationCard()
        card.present(language: "English", beside: director.onScreen(message.bounds, in: message), on: director.screen)
        card.show("Could we move tomorrow’s meeting to 3 pm?")
        director.wait(2.0)

        // Reply.
        director.move(to: director.onScreen(CGPoint(x: 24, y: chat.field.bounds.midY), in: chat.field), duration: 0.8)
        director.click()
        card.close()
        message.setSelectedRange(NSRange(location: 0, length: 0))
        director.wait(0.5)
        director.press("F2")
        director.wait(0.2)
        let composer = ComposerPanel()
        composer.present(over: ScreenGeometry.topLeft(director.onScreen(chat.field.bounds, in: chat.field)), mode: .paste,
                         language: .init(code: "日", name: "Japanese"))
        director.wait(0.45)
        let editor = try XCTUnwrap(composer.window?.firstResponder as? NSTextView)
        for character in "Sure, 3 pm works. See you then!" {
            editor.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
            director.wait(character == " " ? 0.07 : 0.045)
        }
        director.wait(0.5)
        director.press("↩")
        composer.showLoading()
        director.wait(0.55)
        composer.close()
        chat.field.stringValue = "はい、15時で大丈夫です。ではその時に！"
        XCTAssertTrue(director.cut(hold: 2.0))
    }

    // MARK: Ask AI

    /// Select a paragraph, F4, Summarize, the answer streams in.
    func testAskDemo() throws {
        let notes = NotesWindow()
        let director = try DemoDirector(output: output.appendingPathComponent("demo-ask.gif"), content: notes, at: CGPoint(x: 70, y: 60))
        director.wait(0.4)
        director.roll()
        director.wait(0.5)

        let text = notes.paragraph
        director.cursor = .iBeam
        director.move(to: director.onScreen(text.firstGlyphPoint, in: text), duration: 0.8)
        director.move(to: director.onScreen(text.lastGlyphPoint, in: text), duration: 1.0, arc: 0.02) { point in
            let local = text.convert(text.window!.convertPoint(fromScreen: point), from: nil)
            text.setSelectedRange(NSRange(location: 0, length: text.characterIndexForInsertion(at: local)))
        }
        text.setSelectedRange(NSRange(location: 0, length: text.string.utf16.count))
        director.cursor = .arrow
        director.wait(0.4)

        director.press("F4")
        director.wait(0.2)
        let ask = AskPanel()
        let answer = "**Launch moves to October 14.** Beta feedback asked for faster onboarding, so the team trims setup to "
            + "two steps first. Pricing stays as planned; the press kit is due a week before launch."
        ask.onAsk = { _, _, _ in
            var shown = ""
            for word in answer.split(separator: " ", omittingEmptySubsequences: false) {
                shown += (shown.isEmpty ? "" : " ") + word
                await MainActor.run { ask.streamed(shown) }
                // A word every 55 ms of the recording's time, however slow the machine.
                let due = await MainActor.run { director.now } + 0.055
                while await MainActor.run(body: { director.now }) < due { try? await Task.sleep(nanoseconds: 5_000_000) }
            }
            return answer
        }
        var material = AskMaterial(text: text.string, source: SourceContext(app: "Notes", title: "Q3 launch notes", url: ""))
        material.anchor = director.onScreen(text.bounds, in: text)
        ask.prepare(material)
        if !ask.panel.isVisible { ask.panel.orderFrontRegardless() }
        director.wait(0.7)

        let summarize = try XCTUnwrap(buttons(in: ask.panel.contentView).first { $0.title == L("Summarize") })
        director.move(to: director.onScreen(CGPoint(x: summarize.bounds.midX, y: summarize.bounds.midY), in: summarize), duration: 0.8)
        director.wait(0.15)
        director.click()
        summarize.performClick(nil)
        // Until the answer has finished streaming, however fast the machine is, then a moment to read it.
        let asked = Date()
        while !ask.transcript.string.hasSuffix("launch."), Date().timeIntervalSince(asked) < 10 { director.wait(0.1) }
        director.wait(0.5)
        XCTAssertTrue(director.cut(hold: 2.0))
        ask.close()
    }

    func buttons(in view: NSView?) -> [NSButton] {
        guard let view else { return [] }
        return view.subviews.flatMap { ($0 as? NSButton).map { [$0] } ?? buttons(in: $0) }
    }
}

// MARK: - The apps being worked in

/// A plain app window: white, rounded, a title bar with the three buttons.
class MockWindow: NSView {
    let title: String
    init(title: String, size: NSSize) {
        self.title = title
        super.init(frame: NSRect(origin: .zero, size: size))
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.backgroundColor = NSColor.white.cgColor
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.32
        layer?.shadowRadius = 24
        layer?.shadowOffset = CGSize(width: 0, height: -10)
        appearance = NSAppearance(named: .aqua)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.965, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: bounds.width, height: 40), xRadius: 12, yRadius: 12).fill()
        NSRect(x: 0, y: 20, width: bounds.width, height: 20).fill()
        NSColor(white: 0.88, alpha: 1).setFill()
        NSRect(x: 0, y: 40, width: bounds.width, height: 1).fill()
        for (index, color) in [NSColor(srgbRed: 1, green: 0.37, blue: 0.34, alpha: 1), NSColor(srgbRed: 1, green: 0.74, blue: 0.18, alpha: 1),
                               NSColor(srgbRed: 0.16, green: 0.79, blue: 0.25, alpha: 1)].enumerated() {
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: 16 + CGFloat(index) * 20, y: 14, width: 12, height: 12)).fill()
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor(white: 0.3, alpha: 1)]
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: 20 - size.height / 2), withAttributes: attributes)
    }
}

/// Text that can be selected like any app's, with the points of its first and last glyph.
final class SelectableText: NSTextView {
    convenience init(_ text: String, font: NSFont, width: CGFloat, color: NSColor = NSColor(white: 0.18, alpha: 1)) {
        let storage = NSTextStorage(string: text, attributes: [.font: font, .foregroundColor: color,
                                                               .paragraphStyle: { let p = NSMutableParagraphStyle(); p.lineSpacing = 4; return p }()])
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        layout.ensureLayout(for: container)
        let height = ceil(layout.usedRect(for: container).height)
        self.init(frame: NSRect(x: 0, y: 0, width: width, height: height), textContainer: container)
        isEditable = false
        isSelectable = true
        drawsBackground = false
        selectedTextAttributes = [.backgroundColor: NSColor.selectedTextBackgroundColor]
    }

    var firstGlyphPoint: CGPoint { CGPoint(x: 1, y: 10) }
    var lastGlyphPoint: CGPoint {
        guard let layout = layoutManager, let container = textContainer else { return CGPoint(x: bounds.maxX, y: bounds.maxY) }
        let last = layout.boundingRect(forGlyphRange: NSRange(location: max(layout.numberOfGlyphs - 1, 0), length: 1), in: container)
        return CGPoint(x: last.maxX, y: last.midY)
    }
}

/// Notes on a launch: a heading, a paragraph worth asking about, and a chart worth capturing.
private final class NotesWindow: MockWindow {
    let paragraph = SelectableText("We're moving the launch to October 14. Beta testers loved the new layout but asked for a faster first run, so "
                                   + "onboarding drops to two steps before we ship. Pricing stays the same, and the press kit needs "
                                   + "to be ready a week ahead.", font: .systemFont(ofSize: 15), width: 600)
    let chartFrame = NSRect(x: 40, y: 228, width: 300, height: 150)
    var tallestBar: NSRect { bar(3) }
    /// What the demo captures: the chart and the caption beside it, with a little room around.
    var chartWithCaption: NSRect { NSRect(x: chartFrame.minX - 14, y: chartFrame.minY - 14, width: 534, height: chartFrame.height + 28) }
    /// Where the arrow starts: under the caption, pointing back at the bar it's about.
    var arrowStart: CGPoint { CGPoint(x: chartFrame.maxX + 34, y: chartFrame.minY + 76) }

    init() {
        super.init(title: "Q3 launch notes", size: NSSize(width: 680, height: 420))
        let heading = NSTextField(labelWithString: "Q3 launch")
        heading.font = .systemFont(ofSize: 26, weight: .bold)
        heading.textColor = NSColor(white: 0.12, alpha: 1)
        heading.frame.origin = CGPoint(x: 40, y: 62)
        heading.sizeToFit()
        addSubview(heading)
        paragraph.frame.origin = CGPoint(x: 40, y: 110)
        addSubview(paragraph)
    }
    required init?(coder: NSCoder) { fatalError() }

    private let values: [CGFloat] = [0.38, 0.52, 0.47, 0.86, 0.66]

    private func bar(_ index: Int) -> NSRect {
        let width: CGFloat = 38, gap = (chartFrame.width - width * CGFloat(values.count)) / CGFloat(values.count - 1)
        let height = (chartFrame.height - 24) * values[index]
        return NSRect(x: chartFrame.minX + CGFloat(index) * (width + gap), y: chartFrame.maxY - 22 - height, width: width, height: height)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor(white: 0.9, alpha: 1).setFill()
        NSRect(x: chartFrame.minX, y: chartFrame.maxY - 22, width: chartFrame.width, height: 1).fill()
        for index in values.indices {
            (index == 3 ? NSColor(srgbRed: 0.35, green: 0.33, blue: 0.86, alpha: 1) : NSColor(srgbRed: 0.62, green: 0.68, blue: 0.95, alpha: 1)).setFill()
            NSBezierPath(roundedRect: bar(index), xRadius: 5, yRadius: 5).fill()
            let label = ["Jun", "Jul", "Aug", "Sep", "Oct"][index] as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor(white: 0.5, alpha: 1)]
            label.draw(at: NSPoint(x: bar(index).midX - label.size(withAttributes: attributes).width / 2, y: chartFrame.maxY - 16), withAttributes: attributes)
        }
        let caption = "Sign-ups by month" as NSString
        caption.draw(at: NSPoint(x: chartFrame.maxX + 28, y: chartFrame.minY + 8),
                     withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor(white: 0.25, alpha: 1)])
        ("October is up 83% on June,\nthe best month since beta." as NSString)
            .draw(at: NSPoint(x: chartFrame.maxX + 28, y: chartFrame.minY + 30),
                  withAttributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor(white: 0.45, alpha: 1)])
    }
}

/// A chat with a colleague in Japan: their message to read, and a field to answer in.
private final class ChatWindow: MockWindow {
    let received = SelectableText("明日の打ち合わせ、15時からに変更してもいいですか？", font: .systemFont(ofSize: 15), width: 330)
    let field = NSTextField(string: "")

    init() {
        super.init(title: "Aiko Tanaka", size: NSSize(width: 600, height: 460))
        received.frame.origin = CGPoint(x: 46, y: 162)
        addSubview(received)
        field.placeholderString = "Message"
        field.font = .systemFont(ofSize: 15)
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.focusRingType = .none
        field.frame = NSRect(x: 24, y: bounds.height - 58, width: bounds.width - 48, height: 32)
        addSubview(field)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // Their bubble behind the selectable text, and an earlier one of yours.
        NSColor(white: 0.92, alpha: 1).setFill()
        NSBezierPath(roundedRect: received.frame.insetBy(dx: -16, dy: -10), xRadius: 16, yRadius: 16).fill()
        let mine = NSRect(x: bounds.width - 24 - 250, y: 74, width: 250, height: 40)
        NSColor(srgbRed: 0.04, green: 0.52, blue: 1, alpha: 1).setFill()
        NSBezierPath(roundedRect: mine, xRadius: 16, yRadius: 16).fill()
        ("Are we still on for tomorrow?" as NSString).draw(at: NSPoint(x: mine.minX + 16, y: mine.minY + 10),
                                                         withAttributes: [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.white])
        ("Aiko · 9:41" as NSString).draw(at: NSPoint(x: 32, y: 136),
                                        withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor(white: 0.55, alpha: 1)])
    }
}

/// A web page: a picture, a heading, and lines of text, laid out to whatever size the window is.
private final class BrowserWindow: MockWindow {
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let inner = bounds.width - 80
        NSGradient(colors: [NSColor(srgbRed: 0.93, green: 0.55, blue: 0.42, alpha: 1), NSColor(srgbRed: 0.55, green: 0.32, blue: 0.62, alpha: 1)])!
            .draw(in: NSBezierPath(roundedRect: NSRect(x: 40, y: 64, width: inner, height: min(130, bounds.height * 0.3)), xRadius: 10, yRadius: 10),
                  angle: -20)
        let top = 64 + min(130, bounds.height * 0.3) + 22
        ("Three venues for the Kyoto launch" as NSString).draw(
            in: NSRect(x: 40, y: top, width: inner, height: 60),
            withAttributes: [.font: NSFont.systemFont(ofSize: 21, weight: .bold), .foregroundColor: NSColor(white: 0.13, alpha: 1)])
        NSColor(white: 0.86, alpha: 1).setFill()
        var y = top + (inner < 360 ? 66 : 42)
        var index = 0
        while y < bounds.height - 30 {
            let length = [0.96, 0.9, 0.97, 0.62][index % 4]
            NSBezierPath(roundedRect: NSRect(x: 40, y: y, width: inner * length, height: 9), xRadius: 4.5, yRadius: 4.5).fill()
            y += index % 4 == 3 ? 34 : 21
            index += 1
        }
    }
}

/// A to-do list, half done.
private final class ChecklistWindow: MockWindow {
    private let items = [("Onboarding in two steps", true), ("Press kit to partners", true), ("Book the Kyoto venue", false),
                         ("Rehearse the keynote", false), ("Launch event · Oct 14", false)]

    init() { super.init(title: "Launch checklist", size: NSSize(width: 440, height: 320)) }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        ("This week" as NSString).draw(at: NSPoint(x: 32, y: 60), withAttributes: [
            .font: NSFont.systemFont(ofSize: 20, weight: .bold), .foregroundColor: NSColor(white: 0.13, alpha: 1)])
        for (index, item) in items.enumerated() {
            let y = 106 + CGFloat(index) * 38
            let box = NSRect(x: 32, y: y, width: 20, height: 20)
            if item.1 {
                NSColor(srgbRed: 0.2, green: 0.72, blue: 0.4, alpha: 1).setFill()
                NSBezierPath(ovalIn: box).fill()
                let tick = NSBezierPath()
                tick.move(to: NSPoint(x: box.minX + 5.5, y: box.midY))
                tick.line(to: NSPoint(x: box.minX + 9, y: box.maxY - 6))
                tick.line(to: NSPoint(x: box.maxX - 5, y: box.minY + 6))
                tick.lineWidth = 2.2
                NSColor.white.setStroke()
                tick.stroke()
            } else {
                NSColor(white: 0.7, alpha: 1).setStroke()
                let ring = NSBezierPath(ovalIn: box.insetBy(dx: 1, dy: 1))
                ring.lineWidth = 1.5
                ring.stroke()
            }
            (item.0 as NSString).draw(at: NSPoint(x: 64, y: y), withAttributes: [
                .font: NSFont.systemFont(ofSize: 15), .foregroundColor: item.1 ? NSColor(white: 0.55, alpha: 1) : NSColor(white: 0.18, alpha: 1)])
            NSColor(white: 0.92, alpha: 1).setFill()
            NSRect(x: 64, y: y + 29, width: bounds.width - 96, height: 1).fill()
        }
    }
}

/// A deck being made: slides down the side, and one waiting for its chart.
private final class SlidesWindow: MockWindow {
    init() { super.init(title: "Q3 review", size: NSSize(width: 520, height: 420)) }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor(white: 0.93, alpha: 1).setFill()
        NSRect(x: 0, y: 41, width: bounds.width, height: bounds.height - 53).fill()
        for index in 0..<4 {
            let thumb = NSRect(x: 18, y: 60 + CGFloat(index) * 64, width: 84, height: 50)
            NSColor.white.setFill()
            NSBezierPath(roundedRect: thumb, xRadius: 4, yRadius: 4).fill()
            if index == 1 {
                NSColor(srgbRed: 0.35, green: 0.33, blue: 0.86, alpha: 1).setStroke()
                let ring = NSBezierPath(roundedRect: thumb.insetBy(dx: -2, dy: -2), xRadius: 5, yRadius: 5)
                ring.lineWidth = 2.5
                ring.stroke()
            }
        }
        let slide = NSRect(x: 122, y: 60, width: bounds.width - 140, height: (bounds.width - 140) * 0.62)
        NSColor.white.setFill()
        NSBezierPath(roundedRect: slide, xRadius: 6, yRadius: 6).fill()
        ("Sign-ups are up 83%" as NSString).draw(at: NSPoint(x: slide.minX + 24, y: slide.minY + 22), withAttributes: [
            .font: NSFont.systemFont(ofSize: 22, weight: .bold), .foregroundColor: NSColor(white: 0.13, alpha: 1)])
        let empty = NSBezierPath(roundedRect: NSRect(x: slide.minX + 24, y: slide.minY + 66, width: slide.width - 48, height: slide.height - 90),
                                 xRadius: 6, yRadius: 6)
        empty.setLineDash([6, 5], count: 2, phase: 0)
        empty.lineWidth = 1.5
        NSColor(white: 0.75, alpha: 1).setStroke()
        empty.stroke()
    }
}
