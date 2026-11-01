import AppKit
import XCTest
@testable import NyCopilotKit

/// The README's pictures: NyCopilot's real panels, filled with sample content, captured on screen
/// and set on a backdrop. Runs only when asked, since it puts windows on screen for a moment:
///
///     NYCOPILOT_SHOWCASE=1 swift test --filter ShowcaseTests
@MainActor
final class ShowcaseTests: XCTestCase {
    private var folder: URL!
    private var core: NyCore!
    private let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../../../docs/images").standardizedFileURL

    override func setUp() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["NYCOPILOT_SHOWCASE"] != nil, "set NYCOPILOT_SHOWCASE=1 to make the README's pictures")
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("showcase-\(UUID())", isDirectory: true)
        core = try NyCore(dataDirectory: folder)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        core = nil
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    func testMakeTheReadmePictures() throws {
        let screen = NSScreen.screens[0]
        let images = ImageFolder("showcase-images-\(UUID())")
        defer { images.removeAll() }

        // Screenshot toolbar: arrow picked, text found in the selection.
        let toolbar = CaptureToolbar(palette: [.systemRed, .systemOrange, .systemYellow, .systemGreen, .systemBlue, .systemPurple])
        toolbar.selectedTool = .arrow
        toolbar.recognizedLines = 4
        let bar = NSWindow(contentRect: NSRect(origin: .zero, size: toolbar.frame.size), styleMask: .borderless, backing: .buffered, defer: false)
        bar.isOpaque = false
        bar.backgroundColor = .clear
        bar.contentView = toolbar
        bar.setContentSize(toolbar.fittingSize)
        try save(bar, "toolbar")

        // Ask AI, mid-conversation.
        let ask = AskPanel()
        ask.prepare(AskMaterial(text: "量子纠缠是一种量子力学现象：两个粒子即使相隔很远，测量其中一个也会立即影响另一个的状态。",
                                source: SourceContext(app: "Safari", title: "Quantum entanglement", url: "")))
        ask.append("Explain", style: .question)
        ask.append("**Quantum entanglement** links two particles so that measuring one instantly tells you about the other, "
                   + "however far apart they are.\n\nIt can't carry messages faster than light, since each result on its own looks random, "
                   + "but it's what quantum computers and quantum cryptography are built on.", style: .answer)
        try save(ask.panel, "ask")

        // Clipboard history: text, a link, a color, an image, one pinned.
        let picture = NSImage(size: NSSize(width: 160, height: 100), flipped: false) { rect in
            NSGradient(colors: [.systemTeal, .systemIndigo])!.draw(in: rect, angle: 35)
            return true
        }
        let name = try XCTUnwrap(images.keep(picture))
        _ = try core.call(.clipboardAdd, ["image": name, "digest": "showcase", "width": 1600, "height": 1000])
        for text in ["#5E5CE6", "https://developer.apple.com/design/human-interface-guidelines", "Meeting moved to Thursday 3 pm, room 4B",
                     "Thanks for the quick turnaround — the new layout reads much better."] {
            _ = try core.call(.clipboardAdd, ["text": text])
        }
        let first = ((try core.call(.recordsList, ["collection": "clipboard.items"]) as? [String: Any])?["records"] as? [[String: Any]])?.first?["id"]
        _ = try core.call(.clipboardPin, ["id": try XCTUnwrap(first)])
        let picker = ClipboardPicker(core: core, images: images)
        picker.prepare(target: nil, source: nil)
        try save(picker.panel, "clipboard")

        // Inbox: a few notes from different apps.
        _ = try core.call(.inboxAdd, ["text": "Ask Lin about the Q3 plan before Friday", "app": "Slack", "title": "#planning"])
        _ = try core.call(.inboxAdd, ["text": "Try the new onboarding copy on five people", "app": "Notes", "title": ""])
        _ = try core.call(.inboxAdd, ["text": "“The best interface is the one you don’t notice.”", "app": "Safari", "title": "Design notes",
                                        "url": "https://example.com/design-notes"])
        let inbox = InboxWindow(core: core, images: images, toast: Toast())
        inbox.reload()
        let inboxWindow = try XCTUnwrap(inbox.window)
        // The newest note open on the right, as you'd see it working through the inbox.
        let table = try XCTUnwrap(inboxWindow.contentView?.subviews.compactMap { ($0 as? NSScrollView)?.documentView as? NSTableView }.first)
        table.selectRowIndexes([1], byExtendingSelection: false)
        try save(inboxWindow, "inbox")

        // A translation beside what it translates.
        let card = TranslationCard()
        card.present(language: "English", beside: NSRect(x: screen.frame.midX - 160, y: screen.frame.midY, width: 320, height: 40), on: screen)
        card.show("Entanglement doesn't let you send messages faster than light.")
        try save(card, "translate")

        // Every key, one press away.
        try save(KeySheet.makePanel("Screenshot keys", groups: KeyGuide.capture), "keys")
    }

    /// Shows `window` for a moment, captures it as the screen shows it, and writes it on a
    /// backdrop, at the screen's full resolution.
    private func save(_ window: NSWindow, _ name: String) throws {
        window.appearance = NSAppearance(named: .darkAqua)
        let screen = NSScreen.screens[0].visibleFrame
        window.setFrameOrigin(NSPoint(x: screen.midX - window.frame.width / 2, y: screen.midY - window.frame.height / 2))
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        let shot = try XCTUnwrap(CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber),
                                                         [.boundsIgnoreFraming, .bestResolution]), name)
        window.orderOut(nil)

        let scale = CGFloat(shot.width) / window.frame.width
        let margin = 56 * scale
        let size = CGSize(width: CGFloat(shot.width) + margin * 2, height: CGFloat(shot.height) + margin * 2)
        let context = try XCTUnwrap(CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let backdrop = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [
            NSColor(srgbRed: 0.29, green: 0.22, blue: 0.62, alpha: 1).cgColor,
            NSColor(srgbRed: 0.12, green: 0.36, blue: 0.62, alpha: 1).cgColor
        ] as CFArray, locations: [0, 1])!
        context.drawLinearGradient(backdrop, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
        context.setShadow(offset: CGSize(width: 0, height: -10 * scale), blur: 36 * scale, color: NSColor.black.withAlphaComponent(0.45).cgColor)
        context.draw(shot, in: CGRect(x: margin, y: margin, width: CGFloat(shot.width), height: CGFloat(shot.height)))
        let picture = try XCTUnwrap(context.makeImage())
        try XCTUnwrap(NSBitmapImageRep(cgImage: picture).representation(using: .png, properties: [:]))
            .write(to: output.appendingPathComponent("\(name).png"))
    }
}
