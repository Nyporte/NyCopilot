import Foundation
import XCTest

/// Every string the app wraps in L() has an entry in each language's table.
final class LocalizationTests: XCTestCase {
    func testEveryWrappedStringIsTranslated() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../..").standardizedFileURL
        let sources = root.appendingPathComponent("Sources/NyCopilotKit")
        var wrapped = Set<String>()
        let pattern = try NSRegularExpression(pattern: #"\bL\("((?:[^"\\]|\\.)*)"\)"#)
        for case let file as URL in FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)! where file.pathExtension == "swift" {
            let text = try String(contentsOf: file)
            for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                let literal = String(text[Range(match.range(at: 1), in: text)!])
                wrapped.insert(literal.replacingOccurrences(of: #"\""#, with: "\"").replacingOccurrences(of: #"\\"#, with: "\\"))
            }
        }
        XCTAssertGreaterThan(wrapped.count, 150)
        for language in ["en", "zh-Hans"] {
            let table = try XCTUnwrap(NSDictionary(contentsOf: root.appendingPathComponent("Resources/\(language).lproj/Localizable.strings")) as? [String: String])
            let missing = wrapped.subtracting(table.keys)
            XCTAssertTrue(missing.isEmpty, "\(language) is missing: \(missing.sorted().prefix(5))")
        }
    }
}
