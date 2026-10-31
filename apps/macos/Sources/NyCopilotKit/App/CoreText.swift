import Foundation

/// The core speaks English; this shows what it says in the interface language. A fixed message is
/// its own key in `Localizable.strings`. A message with values in it, such as an HTTP status or a
/// service's own words, matches one of `templates` (the core's `format!` strings, with `%@` for
/// each value), and the values go back into the translated template, themselves translated when
/// they're messages too. Anything unrecognized shows as the core wrote it.
enum CoreText {
    static let templates = [
        "%@ failed, so %@ translated this. %@",
        "Access denied (HTTP %@). Check the API key and model permissions.",
        "Annotation style: %@.",
        "Choose between 1 and %@ different languages.",
        "Google Apps Script had a problem (HTTP %@). Try again shortly.",
        "Google Translate failed: %@",
        "Instructions must contain some text and be at most %@ characters.",
        "None of your translation services offers “%@”. Choose a standard language, or connect a model in Settings → AI & Engines.",
        "Request failed (HTTP %@). Check the endpoint and model.",
        "The API redirected the request (HTTP %@). Use the final endpoint URL.",
        "The model reported an error: %@",
        "The provider had a problem (HTTP %@). Try again shortly.",
        "Volcengine error %@: %@",
        "Volcengine had a problem (HTTP %@). Try again shortly.",
        "Volcengine refused the credentials (HTTP %@). Check the API key — or the App ID and access token — and that machine translation (volc.speech.mt) is enabled.",
        "Volcengine rejected the credentials (%@). Check the key — and the App ID, for old-console credentials — in Settings → AI & Engines.",
        "Volcengine rejected the request: %@",
        "Volcengine request failed (HTTP %@)."
    ]

    /// The names the core gives its translation engines inside its sentences.
    static let engineNames = ["Google Translate", "Volcengine", "the model", "The model"]

    static func localized(_ message: String) -> String {
        if let fixed = translation(of: message) { return fixed }
        if let names = engineList(message) { return names }
        if let reasons = engineReasons(message) { return reasons }
        for (template, pattern) in patterns {
            guard let match = pattern.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)) else { continue }
            let values: [CVarArg] = (1..<match.numberOfRanges).map { index in
                Range(match.range(at: index), in: message).map { localized(String(message[$0])) } ?? ""
            }
            return String(format: L(template), locale: Localization.locale, arguments: values)
        }
        return message
    }

    /// The translation of a key, or nil when the tables don't have it.
    private static func translation(of key: String) -> String? {
        let missing = "\u{1}"
        let found = Localization.bundle.localizedString(forKey: key, value: missing, table: nil)
        return found == missing ? nil : found
    }

    private static let patterns: [(String, NSRegularExpression)] = templates.compactMap { template in
        let escaped = NSRegularExpression.escapedPattern(for: template).replacingOccurrences(of: "%@", with: "(.+?)")
        return (try? NSRegularExpression(pattern: "^" + escaped + "$", options: [.dotMatchesLineSeparators])).map { (template, $0) }
    }

    /// "Google Translate and Volcengine": the engines that failed, as the core lists them.
    private static func engineList(_ text: String) -> String? {
        let names = text.components(separatedBy: " and ").flatMap { $0.components(separatedBy: ", ") }
        guard names.count > 1, names.allSatisfy(engineNames.contains) else { return nil }
        let formatter = ListFormatter()
        formatter.locale = Localization.locale
        return formatter.string(from: names.map { L($0) })
    }

    /// "Volcengine: … Google Translate: …": each engine's reason, when more than one failed.
    private static func engineReasons(_ text: String) -> String? {
        let labels = engineNames.map { NSRegularExpression.escapedPattern(for: $0 + ": ") }.joined(separator: "|")
        guard let pattern = try? NSRegularExpression(pattern: "(?:^|(?<= ))(?:" + labels + ")") else { return nil }
        let starts = pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text) }
        guard starts.count > 1, starts[0].lowerBound == text.startIndex else { return nil }
        return starts.indices.map { index in
            let name = String(text[starts[index]].dropLast(2))
            let end = index + 1 < starts.count ? starts[index + 1].lowerBound : text.endIndex
            let reason = text[starts[index].upperBound..<end].trimmingCharacters(in: .whitespaces)
            return L("%@: %@", L(name), localized(reason))
        }.joined(separator: " ")
    }
}
