import AppKit
import XCTest
@testable import NyCopilotKit

/// Every panel laid out and drawn off screen, failing on layout conflicts and on sizes that don't
/// fit a 13-inch screen. Nothing is shown.
@MainActor
final class PanelRenderTests: XCTestCase {
    private var folder: URL!
    private var core: NyCore!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("panels-\(UUID())", isDirectory: true)
        core = try NyCore(dataDirectory: folder)
    }

    override func tearDown() async throws {
        core = nil
        try? FileManager.default.removeItem(at: folder)
    }

    func testInboxWindowWithTextAndAWideScreenshot() throws {
        let images = ImageFolder("panels-images-\(UUID())")
        defer { images.removeAll() }
        let wide = NSImage(size: NSSize(width: 2400, height: 500), flipped: false) { rect in NSColor.systemTeal.setFill(); rect.fill(); return true }
        let name = try XCTUnwrap(images.keep(wide))
        _ = try core.call(.inboxAdd, ["image": name, "source": "screenshot", "app": "Claude"])
        _ = try core.call(.inboxAdd, ["text": "Ask Lin about the Q3 plan\nbefore Friday", "app": "Safari", "title": "Q3 planning",
                                        "url": "https://docs.example.com/a/very/long/path/that/keeps/going/q3?tab=summary"])
        let window = InboxWindow(core: core, images: images, toast: Toast())
        window.reload()
        let content = try XCTUnwrap(window.window?.contentView)
        let table = try XCTUnwrap(content.subviews.compactMap { ($0 as? NSScrollView)?.documentView as? NSTableView }.first)
        for row in [1, 2] {
            table.selectRowIndexes([row], byExtendingSelection: false)
            Render.check(content, "inbox-\(row)")
            XCTAssertLessThanOrEqual(content.fittingSize.width, 1200, "a screenshot must not widen the window")
        }
    }

    func testAskPanelWithAConversation() {
        let panel = AskPanel()
        panel.prepare(AskMaterial(text: "量子纠缠是一种物理现象", source: SourceContext(app: "Safari", title: "", url: "")))
        panel.append("Explain", style: .question)
        panel.append("**Entanglement** links two particles so that measuring one tells you about the other, however far apart.", style: .answer)
        Render.check(panel.panel.contentView!, "ask")
        XCTAssertEqual(panel.panel.frame.width, 500)
    }

    func testAskPanelShowsAnAnswerAsItStreams() async {
        let panel = AskPanel()
        panel.prepare(AskMaterial(text: "x", source: SourceContext()))
        panel.onAsk = { _, _, _ in
            await MainActor.run { panel.streamed("Two") }
            await MainActor.run { XCTAssertTrue(panel.transcript.string.hasSuffix("Two")) }
            await MainActor.run { panel.streamed("Two particles") }
            return "Two particles, linked."
        }
        panel.ask(action: "explain", question: "", shown: "Explain")
        for _ in 0..<50 where !panel.transcript.string.hasSuffix("linked.") { try? await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(panel.transcript.string, "Explain\nTwo particles, linked.", "the final answer replaces what streamed")
    }

    func testClipboardPickerWithPinnedTextAndAnImage() throws {
        let images = ImageFolder("panels-clip-\(UUID())")
        defer { images.removeAll() }
        _ = try core.call(.clipboardAdd, ["text": "my address"])
        let pinned = ((try core.call(.recordsList, ["collection": "clipboard.items"]) as? [String: Any])?["records"] as? [[String: Any]])?.first?["id"]
        _ = try core.call(.clipboardPin, ["id": try XCTUnwrap(pinned)])
        let picture = NSImage(size: NSSize(width: 80, height: 60), flipped: false) { rect in NSColor.systemOrange.setFill(); rect.fill(); return true }
        let name = try XCTUnwrap(images.keep(picture))
        _ = try core.call(.clipboardAdd, ["image": name, "digest": "d1", "width": 80, "height": 60])
        let picker = ClipboardPicker(core: core, images: images)
        picker.prepare(target: nil, source: nil)
        Render.check(picker.panel.contentView!, "clipboard")
    }

    func testKeySheetsFitTheScreen() {
        for (name, groups) in [("capture", KeyGuide.capture), ("pin", KeyGuide.pin), ("inbox", KeyGuide.inbox),
                               ("clipboard", KeyGuide.clipboard), ("ask", KeyGuide.ask)] {
            let panel = KeySheet.makePanel("\(name) keys", groups: groups)
            Render.check(panel.contentView!, "keys-\(name)")
            XCTAssertLessThan(panel.frame.width, 1000, name)
        }
    }

    func testWelcomeFitsA13InchScreen() {
        let preferences = Preferences(core: core)
        let services = CopilotServices(core: core, preferences: preferences, hotKeys: HotKeyCenter(preferences: preferences))
        services.moduleList = { [("translate", "Translate", ""), ("capture", "Screenshot", ""), ("ask", "Ask AI", ""),
                                 ("inbox", "Inbox", ""), ("clipboard", "Clipboard", ""), ("windows", "Window Layouts", "")] }
        let welcome = WelcomeWindow(services: services)
        welcome.prepare()
        let content = welcome.window!.contentView!
        Render.check(content, "welcome")
        XCTAssertLessThanOrEqual(content.frame.height, 780)
    }

    func testRecordingBarAndPreviews() throws {
        let bar = RecordingBar(beside: NSRect(x: 200, y: 200, width: 400, height: 240), on: NSScreen.screens[0], shortcut: "F1")
        Render.check(bar.contentView!, "recording-ready")
        bar.showRecording()
        bar.show(elapsed: 7, paused: false)
        Render.check(bar.contentView!, "recording")

        let gif = FileManager.default.temporaryDirectory.appendingPathComponent("p-\(UUID()).gif")
        defer { try? FileManager.default.removeItem(at: gif) }
        let writer = try XCTUnwrap(GifWriter(url: gif, width: 120, height: 60))
        let frame = NSImage(size: NSSize(width: 120, height: 60), flipped: false) { rect in NSColor.white.setFill(); rect.fill(); return true }
        writer.add(try XCTUnwrap(frame.cgImage(forProposedRect: nil, context: nil, hints: nil)), at: 0)
        writer.finish(at: 1)
        let clip = GifClip(url: gif, size: CGSize(width: 120, height: 60), pixels: (120, 60), duration: 1, bytes: 100)
        let preview = GifPreview(clip: clip, near: NSRect(x: 200, y: 200, width: 120, height: 60), on: NSScreen.screens[0])
        Render.check(preview.panel.contentView!, "gif-preview")

        // Esc throws the recording away; it never saves.
        var discarded = false, acted = false
        preview.onDiscard = { _ in discarded = true }
        preview.onAction = { _, _ in acted = true }
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                                    context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                                    isARepeat: false, keyCode: 53))
        preview.panel.keyDown(with: escape)
        XCTAssertTrue(discarded)
        XCTAssertFalse(acted)

        // VoiceOver hears the trash button's purpose, not its symbol's name.
        let trash = preview.panel.contentView.flatMap { root -> NSButton? in
            func find(_ view: NSView) -> NSButton? {
                if let button = view as? NSButton, button.toolTip?.hasPrefix("Discard") == true { return button }
                return view.subviews.lazy.compactMap(find).first
            }
            return find(root)
        }
        XCTAssertTrue(trash?.accessibilityLabel()?.hasPrefix("Discard") == true)

        let scroll = ScrollCapturePanel(beside: NSRect(x: 200, y: 200, width: 400, height: 300), on: NSScreen.screens[0])
        Render.check(scroll.contentView!, "scroll-panel")
    }
}
