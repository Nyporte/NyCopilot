import AppKit
import XCTest
@testable import MacPlatform

/// Use isolated named pasteboards so regression checks never touch the user's general clipboard.
final class TemporaryPasteboardTests: XCTestCase {
    /// A paste must restore every original item and representation, including non-text binary data.
    @MainActor func testRestoresMultipleItemsAndRepresentations() async throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let binaryType = NSPasteboard.PasteboardType("dev.nycopilot.test.binary")
        let binary = Data([0, 1, 2, 255])
        let first = NSPasteboardItem()
        first.setString("Original text", forType: .string)
        first.setData(binary, forType: binaryType)
        let second = NSPasteboardItem()
        second.setString("Second item", forType: .string)
        XCTAssertTrue(board.writeObjects([first, second]))
        try await TemporaryPasteboard.withText("Translation", on: board, validate: {
            // A pasteboard-wide string joins multiple items; inspect the first representation directly.
            XCTAssertEqual(board.pasteboardItems?.first?.string(forType: .string), "Original text")
        }, perform: {
            XCTAssertEqual(board.string(forType: .string), "Translation")
            XCTAssertEqual(board.pasteboardItems?.count, 1)
        })
        let items = try XCTUnwrap(board.pasteboardItems)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items.first?.string(forType: .string), "Original text")
        XCTAssertEqual(items.first?.data(forType: binaryType), binary)
        XCTAssertEqual(items.last?.string(forType: .string), "Second item")
    }

    /// Cancellation after placing the temporary text still restores the previous clipboard.
    @MainActor func testCancellationRestoresOriginalClipboard() async {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("Original", forType: .string)
        do {
            try await TemporaryPasteboard.withText("Translation", on: board, validate: {}, perform: {
                throw CancellationError()
            })
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(board.string(forType: .string), "Original")
    }

    /// A copy made while the target consumes the translation takes priority over the old snapshot.
    @MainActor func testNewCopyDuringPasteIsPreserved() async throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("Original", forType: .string)
        try await TemporaryPasteboard.withText("Translation", on: board, validate: {}, perform: {
            board.clearContents()
            board.setString("New user copy", forType: .string)
        })
        XCTAssertEqual(board.string(forType: .string), "New user copy")
    }

    /// Changes during asynchronous target validation abort before the clipboard is replaced or pasted.
    @MainActor func testNewCopyBeforePastePreventsMutation() async {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("Original", forType: .string)
        var pasted = false
        do {
            try await TemporaryPasteboard.withText("Translation", on: board, validate: {
                board.clearContents()
                board.setString("New user copy", forType: .string)
            }, perform: { pasted = true })
            XCTFail("Expected a changed clipboard")
        } catch { XCTAssertEqual(error as? TemporaryPasteboard.Failure, .changed) }
        XCTAssertFalse(pasted)
        XCTAssertEqual(board.string(forType: .string), "New user copy")
    }

    /// An initially empty clipboard is restored to empty, rather than leaving the translation behind.
    @MainActor func testEmptyClipboardIsRestored() async throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.clearContents()
        try await TemporaryPasteboard.withText("Translation", on: board, validate: {}, perform: {})
        XCTAssertNil(board.string(forType: .string))
        XCTAssertTrue(board.pasteboardItems?.isEmpty ?? true)
    }

    /// Oversized snapshots fail before any pasteboard mutation, preserving the original payload.
    @MainActor func testOversizedClipboardRemainsUntouched() async {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let type = NSPasteboard.PasteboardType("dev.nycopilot.test.large")
        let payload = Data(repeating: 42, count: TemporaryPasteboard.maximumSnapshotBytes + 1)
        board.setData(payload, forType: type)
        do {
            try await TemporaryPasteboard.withText("Translation", on: board,
                validate: { XCTFail("An oversized snapshot must stop before validation") },
                perform: { XCTFail("An oversized snapshot must never be pasted") })
            XCTFail("Expected the snapshot limit")
        } catch { XCTAssertEqual(error as? TemporaryPasteboard.Failure, .snapshotUnavailable) }
        XCTAssertEqual(board.data(forType: type), payload)
    }
}
