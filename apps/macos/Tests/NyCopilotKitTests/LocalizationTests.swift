import Foundation
import XCTest
@testable import NyCopilotKit

/// Every language has every string the interface and the core can show, with the same values in it.
final class LocalizationTests: XCTestCase {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../..").standardizedFileURL

    static func table(_ language: String) throws -> [String: String] {
        let url = root.appendingPathComponent("Resources/\(language).lproj/Localizable.strings")
        return try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String], language)
    }

    static func bundle(_ language: String) throws -> Bundle {
        try XCTUnwrap(Bundle(path: root.appendingPathComponent("Resources/\(language).lproj").path), language)
    }

    /// Every L("…") key in the app's sources.
    static func wrapped() throws -> Set<String> {
        let sources = root.appendingPathComponent("Sources/NyCopilotKit")
        var keys = Set<String>()
        let pattern = try NSRegularExpression(pattern: #"\bL\("((?:[^"\\]|\\.)*)"[,)]"#)
        for case let file as URL in FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)! where file.pathExtension == "swift" {
            let text = try String(contentsOf: file)
            for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                let literal = String(text[Range(match.range(at: 1), in: text)!])
                keys.insert(literal.replacingOccurrences(of: #"\""#, with: "\"").replacingOccurrences(of: #"\\"#, with: "\\"))
            }
        }
        return keys
    }

    /// The messages the core sends: every sentence in an error constructor or an error-message
    /// match arm, outside tests, with `{name}` placeholders as `%@`. Developer-only errors (bad
    /// parameters, unknown methods) and the prompts sent to models are left out.
    static func coreMessages() throws -> Set<String> {
        let crates = root.appendingPathComponent("../../crates").standardizedFileURL
        let developerOnly = try NSRegularExpression(pattern: #"invalid_params|unknown_method|invalid_module|Malformed|"(explain|summarize|rewrite|question)" *=>|Unknown setting|Setting “"#)
        let context = try NSRegularExpression(pattern: #"NyError|=> *"|=> *format!|message: *"|\.then\(\|\| format!"#)
        let literal = try NSRegularExpression(pattern: #""((?:[^"\\]|\\.)*)""#)
        let placeholder = try NSRegularExpression(pattern: #"\{[a-zA-Z_]*\}"#)
        func has(_ pattern: NSRegularExpression, _ text: String) -> Bool { pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil }
        var messages = Set<String>()
        for case let file as URL in FileManager.default.enumerator(at: crates, includingPropertiesForKeys: nil)! where file.pathExtension == "rs" && file.path.contains("/src/") {
            var text = try String(contentsOf: file)
            if let tests = text.range(of: #"#\[cfg\(test\)\]\s*mod "#, options: .regularExpression) { text = String(text[..<tests.lowerBound]) }
            let lines = text.components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                let window = (index > 0 ? lines[index - 1] + " " : "") + line
                guard has(context, window), !has(developerOnly, window) else { continue }
                for match in literal.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
                    let value = String(line[Range(match.range(at: 1), in: line)!])
                    guard value.contains(" "), let first = value.first, first.isUppercase || first == "{" else { continue }
                    let message = placeholder.stringByReplacingMatches(in: value, range: NSRange(value.startIndex..., in: value), withTemplate: "%@")
                    messages.insert(message.replacingOccurrences(of: #"\""#, with: "\""))
                }
            }
        }
        return messages
    }

    /// Names the core sends that the app shows through L(): window layouts and their groups (the
    /// title and group of each `(id, title, group)`), and languages (the English name of each
    /// `(name, native, code)`).
    static func coreNames() throws -> Set<String> {
        let crates = root.appendingPathComponent("../../crates/ny-modules/src").standardizedFileURL
        let tuple = try NSRegularExpression(pattern: #"\("([^"]+)", "([^"]+)", "([^"]+)"\)"#)
        var names = Set<String>()
        for (file, list, columns) in [("windows.rs", "pub const ACTIONS", [2, 3]), ("translate.rs", "SUGGESTED_LANGUAGES", [1])] {
            let text = try String(contentsOf: crates.appendingPathComponent(file))
            let body = try XCTUnwrap(text.components(separatedBy: list).dropFirst().first?.components(separatedBy: "];").first)
            for match in tuple.matches(in: body, range: NSRange(body.startIndex..., in: body)) {
                for column in columns { names.insert(String(body[Range(match.range(at: column), in: body)!])) }
            }
        }
        return names
    }

    static func specifiers(_ text: String) -> [String] {
        let pattern = try! NSRegularExpression(pattern: #"%(?:\d\$)?(@|ld)"#)
        return pattern.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .map { String(text[Range($0.range(at: 1), in: text)!]) }.sorted()
    }

    func testEveryLanguageHasEveryString() throws {
        let wrapped = try Self.wrapped()
        XCTAssertGreaterThan(wrapped.count, 550)
        let core = try Self.coreMessages()
        XCTAssertGreaterThan(core.count, 60)
        let english = try Self.table("en")
        // "%@ and %@" lists the engines that failed; CoreText joins them with the language's own list format.
        for message in core where !english.keys.contains(message) && message != "%@ and %@" {
            XCTAssertTrue(CoreText.templates.contains(message), "the core can say “\(message)”, which has no translation or template")
        }
        let names = try Self.coreNames()
        XCTAssertTrue(names.isSuperset(of: ["Left Half", "Halves", "Japanese", "Arabic"]), "\(names.sorted())")
        let needed = wrapped.union(CoreText.templates).union(CoreText.engineNames).union(names).union(core.filter { !$0.contains("%@") })
        XCTAssertEqual(Set(InterfaceLanguage.available.map(\.code)).count, 10)
        for language in InterfaceLanguage.available.map(\.code) {
            let table = try Self.table(language)
            let missing = needed.subtracting(table.keys)
            XCTAssertTrue(missing.isEmpty, "\(language) is missing: \(missing.sorted().prefix(5))")
            for (key, value) in table {
                XCTAssertEqual(Self.specifiers(value), Self.specifiers(key), "\(language): “\(value)” has different values than “\(key)”")
                for token in ["{date}", "{time}", "{n}", "{language}"] where key.contains(token) {
                    XCTAssertTrue(value.contains(token), "\(language): “\(value)” lost \(token)")
                }
            }
        }
    }

    /// A count reads right in each language: "1 line" and "3 lines"; Russian's one, few, and many.
    func testCountsFollowEachLanguagesPluralRules() throws {
        func format(_ key: String, _ language: String, _ count: Int) throws -> String {
            String(format: try Self.bundle(language).localizedString(forKey: key, value: key, table: nil), locale: Locale(identifier: language), count)
        }
        XCTAssertEqual(try format("Copied %ld lines of text", "en", 1), "Copied 1 line of text")
        XCTAssertEqual(try format("Copied %ld lines of text", "en", 3), "Copied 3 lines of text")
        XCTAssertEqual(try format("Copied %ld lines of text", "ru", 1), "Скопирована 1 строка текста")
        XCTAssertEqual(try format("Copied %ld lines of text", "ru", 3), "Скопированы 3 строки текста")
        XCTAssertEqual(try format("Copied %ld lines of text", "ru", 5), "Скопировано 5 строк текста")
        XCTAssertEqual(try format("Copied %ld lines of text", "ru", 21), "Скопирована 21 строка текста")
        XCTAssertEqual(try format("Copied %ld lines of text", "zh-Hans", 3), "已拷贝 3 行文字")
        // A count with a name after it keeps both in place.
        let more = String(format: try Self.bundle("de").localizedString(forKey: "%ld more in Settings → %@", value: nil, table: nil),
                          locale: Locale(identifier: "de"), 1, "Fenster")
        XCTAssertEqual(more, "1 weiterer unter Einstellungen → Fenster")
    }

    /// What the core says shows in the interface language, values and all.
    func testCoreMessagesAreTranslatedWithTheirValues() throws {
        let saved = (Localization.bundle, Localization.locale)
        defer { (Localization.bundle, Localization.locale) = saved }
        Localization.bundle = try Self.bundle("zh-Hans")
        Localization.locale = Locale(identifier: "zh-Hans")
        XCTAssertEqual(CoreText.localized("Type something first."), "请先输入一些内容。")
        XCTAssertEqual(CoreText.localized("Request failed (HTTP 502). Check the endpoint and model."), "请求失败（HTTP 502）。请检查端点和模型。")
        XCTAssertEqual(CoreText.localized("Google Translate failed, so the model translated this. Volcengine had an internal problem. Try again shortly."),
                       "Google 翻译失败，已改由模型翻译。火山引擎内部出了问题。请稍后重试。")
        XCTAssertEqual(CoreText.localized("Google Translate and Volcengine failed, so the model translated this. "
                                          + "Google Translate: The request timed out. Check the service, then try again. Volcengine: Volcengine rejected the request: bad text"),
                       "Google 翻译和火山引擎失败，已改由模型翻译。Google 翻译：请求超时。请检查服务后重试。 火山引擎：火山引擎拒绝了请求：bad text")
        XCTAssertEqual(CoreText.localized("Something new the core says."), "Something new the core says.")
        XCTAssertEqual(NyCore.Failure(code: "empty_input", message: "Type a question first.", status: nil).localizedDescription, "请先输入问题。")
    }
}
