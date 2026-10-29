import XCTest
@testable import MacPlatform

/// UTF-16 insertion boundaries and shortcut storage, without permissions or a real keyboard.
final class TextAndShortcutTests: XCTestCase {
    /// UTF-16 cursor offsets correctly preserve surrounding text and replace emoji selections.
    func testUnicodeInsertionAndSelectionReplacement() {
        XCTAssertEqual(TextInsertion.replacing("Hi 👋 world", range: NSRange(location: 3, length: 2), with: "friends"), "Hi friends world")
        XCTAssertEqual(TextInsertion.replacing("AB", range: NSRange(location: 1, length: 0), with: "hello"), "AhelloB")
        XCTAssertEqual(TextInsertion.replacing("", range: NSRange(location: 0, length: 0), with: "Hello"), "Hello")
        XCTAssertEqual(TextInsertion.replacing("abc", range: NSRange(location: 0, length: 3), with: "xyz"), "xyz")
    }

    /// Invalid, stale, overflowing, and surrogate-splitting ranges cannot mutate a field.
    func testInvalidInsertionRanges() {
        for range in [NSRange(location: NSNotFound, length: 0), NSRange(location: 99, length: 0), NSRange(location: 1, length: Int.max), NSRange(location: 0, length: 99)] {
            XCTAssertNil(TextInsertion.replacing("abc", range: range, with: "x"))
        }
        XCTAssertNil(TextInsertion.replacing("👋", range: NSRange(location: 1, length: 0), with: "x"))
    }

    /// Shortcuts round-trip through defaults, and NyTranslate's fixed choices map onto real combinations.
    func testHotKeyStorageAndLegacyMigration() {
        let combo = HotKeyCombination(keyCode: 17, modifiers: HotKeyCombination.option | HotKeyCombination.command)
        XCTAssertEqual(combo.modifierSymbols, "⌥⌘")
        XCTAssertEqual(HotKeyCombination(storageValue: combo.storageValue), combo)
        XCTAssertNil(HotKeyCombination(storageValue: ""))
        XCTAssertNil(HotKeyCombination(storageValue: "17:\(HotKeyCombination.shift)"))
        XCTAssertEqual(HotKeyCombination.legacy("controlShift", keyCode: 4),
                       .combination(.init(keyCode: 4, modifiers: HotKeyCombination.control | HotKeyCombination.shift)))
        XCTAssertEqual(HotKeyCombination.legacy("disabled", keyCode: 4), .disabled)
        XCTAssertEqual(HotKeyCombination.legacy("", keyCode: 4), .unrecognized)
    }
}
