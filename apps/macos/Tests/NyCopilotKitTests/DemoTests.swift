import AppKit
import XCTest
@testable import NyCopilotKit

/// The README's moving pictures (see DemoDirector). They take over the screen for a few seconds
/// each, so they run only when asked, with the Mac left alone meanwhile:
///
///     NYCOPILOT_DEMOS=1 swift test --filter DemoTests
@MainActor
final class DemoTests: XCTestCase {
    private let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../../../docs/images").standardizedFileURL

    override func setUp() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["NYCOPILOT_DEMOS"] != nil,
                          "set NYCOPILOT_DEMOS=1 to record the README's moving pictures")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    }

    // MARK: Screenshot

    /// F1, the outline finds the window, drag out a region, pick the arrow, draw, ⌘C.
    func testCaptureDemo() throws {
        let notes = NotesWindow()
        let director = try DemoDirector(output: output.appendingPathComponent("demo-capture.gif"), content: notes, at: CGPoint(x: 150, y: 60))
        director.wait(0.4)
        director.roll()
        director.wait(0.6)

        director.press("F1")
        director.wait(0.2)
        let screen = director.screen
        let whole = CGRect(x: 0, y: 0, width: screen.frame.width, height: screen.frame.height)
        let frozenImage = try XCTUnwrap(CGWindowListCreateImage(whole, .optionOnScreenOnly, kCGNullWindowID, [.bestResolution]))
        let windowRect = director.onScreen(notes.bounds, in: notes)
        let frozen = FrozenScreen(screen: screen, image: frozenImage,
                                  windows: [.init(rect: ScreenGeometry.topLeft(windowRect), pid: getpid())])
        let session = CaptureSession(frozen: [frozen], recent: [], palette: [.systemRed, .systemOrange, .systemYellow, .systemGreen, .systemBlue],
                                     color: .systemRed, stroke: 4, style: CaptureStyle()) { _, _, _ in }
        var copied = false
        session.onFinish = { action, _, _, _ in copied = action == .copy }
        session.show()
        let overlay = try XCTUnwrap(NSApp.windows.first { $0 is CaptureWindow && $0.isVisible })
        director.cursor = .crosshair
        director.wait(0.35)

        // The outline glides onto the window under the pointer.
        director.move(to: CGPoint(x: windowRect.midX - 40, y: windowRect.midY + 40), duration: 0.8) { _ in director.send(.mouseMoved, to: overlay) }
        director.wait(0.7)

        // Drag out the chart and its caption.
        let region = notes.chartWithCaption
        let chart = director.onScreen(region, in: notes)
        director.move(to: director.onScreen(CGPoint(x: region.minX, y: region.minY), in: notes), duration: 0.6) { _ in director.send(.mouseMoved, to: overlay) }
        director.send(.leftMouseDown, to: overlay)
        director.move(to: director.onScreen(CGPoint(x: region.maxX, y: region.maxY), in: notes), duration: 1.0, arc: 0.04) { _ in director.send(.leftMouseDragged, to: overlay) }
        director.send(.leftMouseUp, to: overlay)
        director.cursor = .arrow
        director.wait(0.6)

        // Pick the arrow tool.
        let arrow = try XCTUnwrap(toolbarButtons(in: overlay).dropFirst(2).first)
        director.move(to: director.onScreen(CGPoint(x: arrow.bounds.midX, y: arrow.bounds.midY), in: arrow), duration: 0.7)
        arrow.mouseEntered(with: NSEvent())
        director.wait(0.25)
        director.click()
        arrow.performClick(nil)
        director.wait(0.3)
        arrow.mouseExited(with: NSEvent())

        // From the caption to the tallest bar.
        let bar = notes.tallestBar
        director.cursor = .crosshair
        director.move(to: director.onScreen(notes.arrowStart, in: notes), duration: 0.7) { _ in director.send(.mouseMoved, to: overlay) }
        director.send(.leftMouseDown, to: overlay)
        director.move(to: director.onScreen(CGPoint(x: bar.maxX + 6, y: bar.minY + 10), in: notes), duration: 0.55, arc: 0.06) { _ in
            director.send(.leftMouseDragged, to: overlay)
        }
        director.send(.leftMouseUp, to: overlay)
        director.cursor = .arrow
        director.wait(0.7)

        director.press("⌘", "C")
        director.wait(0.15)
        director.type("c", keyCode: 8, modifiers: .command, to: overlay)
        director.wait(0.35)
        Toast().show(L("Copied"), style: .success, near: chart)
        XCTAssertTrue(director.cut(hold: 1.6))
        XCTAssertTrue(copied)
    }

    private func toolbarButtons(in window: NSWindow) -> [ToolbarButton] {
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

    /// Select a paragraph, ⌥⌘A, Summarize, the answer streams in.
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

        director.press("⌥", "⌘", "A")
        director.wait(0.2)
        let ask = AskPanel()
        let answer = "**Launch moves to October 14.** Beta feedback asked for faster onboarding, so the team trims setup to "
            + "two steps first. Pricing stays as planned; the press kit is due a week before launch."
        ask.onAsk = { _, _, _ in
            var shown = ""
            for word in answer.split(separator: " ", omittingEmptySubsequences: false) {
                shown += (shown.isEmpty ? "" : " ") + word
                await MainActor.run { ask.streamed(shown) }
                try? await Task.sleep(nanoseconds: 55_000_000)
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
        director.wait(3.2)
        XCTAssertTrue(director.cut(hold: 2.0))
        ask.close()
    }

    private func buttons(in view: NSView?) -> [NSButton] {
        guard let view else { return [] }
        return view.subviews.flatMap { ($0 as? NSButton).map { [$0] } ?? buttons(in: $0) }
    }
}

// MARK: - The apps being worked in

/// A plain app window: white, rounded, a title bar with the three buttons.
private class MockWindow: NSView {
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
private final class SelectableText: NSTextView {
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
