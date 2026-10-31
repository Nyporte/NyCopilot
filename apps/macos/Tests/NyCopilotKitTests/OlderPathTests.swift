import AppKit
import XCTest
@testable import NyCopilotKit

/// The oldest paths' logic: how screen text becomes paragraphs, what the clipboard keeps, the two
/// coordinate systems, and how shortcuts are written.
@MainActor
final class OlderPathTests: XCTestCase {
    private func entry(_ text: String, x: CGFloat = 20, y: CGFloat, width: CGFloat = 400, height: CGFloat = 16) -> ScreenTranslator.Entry {
        ScreenTranslator.Entry(line: ScreenText.Line(text: text, rect: CGRect(x: x, y: y, width: width, height: height)),
                               background: .white, fontSize: height * 0.8)
    }

    func testWrappedLinesJoinIntoOneParagraphAndColumnsStayApart() {
        let entries = [
            entry("Screen translation reads every line on", y: 100),
            entry("the screen and groups the wrapped ones", y: 120),
            entry("into paragraphs.", y: 140, width: 120),
            // A second column, far to the right.
            entry("Sidebar item", x: 700, y: 100, width: 100),
            // A heading well below, after a gap.
            entry("Settings", y: 240, width: 90, height: 24)
        ]
        let paragraphs = ScreenTranslator.paragraphs(entries, language: "zh")
        let texts = paragraphs.map(\.text)
        XCTAssertTrue(texts.contains("Screen translation reads every line on the screen and groups the wrapped ones into paragraphs."), "\(texts)")
        XCTAssertTrue(texts.contains("Sidebar item"))
        XCTAssertTrue(texts.contains("Settings"))
        XCTAssertEqual(paragraphs.count, 3)
    }

    func testTextAlreadyInTheReadersLanguageNeedsNoCard() {
        let paragraphs = ScreenTranslator.paragraphs([entry("屏幕翻译会读取每一行文字", y: 100), entry("2026-10-31 12:00", y: 300)], language: "zh")
        XCTAssertTrue(paragraphs.allSatisfy { !$0.needsTranslation }, "Chinese for a Chinese reader, and bare numbers, get no card")
    }

    func testJoiningRespectsHyphensAndChineseWithoutSpaces() {
        XCTAssertEqual(ScreenText.joined(["A transla-", "tion here"]), "A translation here")
        XCTAssertEqual(ScreenText.joined(["屏幕翻译会读取", "每一行文字"]), "屏幕翻译会读取每一行文字")
        XCTAssertEqual(ScreenText.joined(["one", "two"]), "one two")
    }

    func testClipboardSkipsPrivateTransientAndFileCopies() {
        XCTAssertTrue(ClipboardShell.keeps(types: [.string]))
        XCTAssertTrue(ClipboardShell.keeps(types: [.png, .tiff]))
        XCTAssertFalse(ClipboardShell.keeps(types: [.string, .init("org.nspasteboard.ConcealedType")]), "passwords")
        XCTAssertFalse(ClipboardShell.keeps(types: [.string, .init("org.nspasteboard.TransientType")]))
        XCTAssertFalse(ClipboardShell.keeps(types: [.fileURL, .string]), "copied files")
    }

    func testCoordinateConversionsRoundTrip() {
        let rect = CGRect(x: 120, y: 80, width: 300, height: 200)
        XCTAssertEqual(ScreenGeometry.topLeft(ScreenGeometry.appKit(rect)), rect)
        XCTAssertEqual(ScreenGeometry.appKit(rect).maxY, ScreenGeometry.primaryHeight - rect.minY)
        let screen = NSScreen.screens[0]
        XCTAssertEqual(ScreenGeometry.topLeftOrigin(of: screen).y, ScreenGeometry.primaryHeight - screen.frame.maxY)
    }
}
