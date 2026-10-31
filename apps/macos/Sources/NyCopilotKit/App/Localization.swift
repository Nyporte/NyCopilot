import Foundation

/// A user-facing string in the interface language. The English text is the key, so a string
/// without a translation (and every string while one is being written) shows in English.
/// Translations live in the app's `<language>.lproj/Localizable.strings`.
func L(_ english: String) -> String {
    Localization.bundle.localizedString(forKey: english, value: english, table: nil)
}

/// A string with values in it: `english` is the key and a format, `%@` for text and `%ld` for a
/// count. A count's wording follows the language's plural rules through `Localizable.stringsdict`
/// ("1 line", "2 lines"; Russian's three forms), and a translation may reorder values as `%1$@`.
func L(_ english: String, _ values: CVarArg...) -> String {
    String(format: L(english), locale: Localization.locale, arguments: values)
}

enum Localization {
    /// Where the tables come from: the app, or one language's `.lproj` when a test lays out
    /// the interface in that language. Set before any window is built.
    nonisolated(unsafe) static var bundle = Bundle.main
    /// The locale values are formatted in, which also picks a count's plural form.
    nonisolated(unsafe) static var locale = Locale.current
}

/// The language NyCopilot's interface is in: the Mac's, or one chosen in Settings → General. A
/// choice is the app's own `AppleLanguages`, which macOS reads at launch, so it applies on restart.
enum InterfaceLanguage {
    /// Every language the interface is translated into, each by its own name.
    static let available: [(code: String, name: String)] = [
        ("en", "English"), ("zh-Hans", "简体中文"), ("zh-Hant", "繁體中文"), ("ja", "日本語"), ("ko", "한국어"),
        ("es", "Español"), ("fr", "Français"), ("de", "Deutsch"), ("pt-BR", "Português (Brasil)"), ("ru", "Русский")
    ]

    private static let key = "AppleLanguages"
    private static let localeKey = "AppleLocale"

    /// The chosen language's code, or nil to follow the Mac. The locale changes with it, keeping
    /// the Mac's region, so dates, lists, and plurals read in the same language as the words.
    static var chosen: String? {
        get {
            guard let id = Bundle.main.bundleIdentifier else { return nil }
            return (UserDefaults.standard.persistentDomain(forName: id)?[key] as? [String])?.first
        }
        set {
            guard let newValue else {
                UserDefaults.standard.removeObject(forKey: key)
                UserDefaults.standard.removeObject(forKey: localeKey)
                return
            }
            let global = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)
            let region = (global?[localeKey] as? String).flatMap { Locale(identifier: $0).region?.identifier }
            // The language and any script ("zh-Hans"), without its own region ("pt-BR" → "pt").
            let parts = newValue.split(separator: "-")
            let base = ([parts[0]] + parts.dropFirst().filter { $0.count == 4 }).joined(separator: "-")
            UserDefaults.standard.set([newValue], forKey: key)
            UserDefaults.standard.set(base + "_" + (region ?? Locale(identifier: newValue).region?.identifier ?? "US"), forKey: localeKey)
        }
    }

    /// The language in use now.
    static var running: String { Bundle.main.preferredLocalizations.first ?? "en" }

    /// The language the Mac's own preferences pick from the available ones.
    static var system: String {
        let preferred = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?[key] as? [String] ?? ["en"]
        return Bundle.preferredLocalizations(from: available.map(\.code), forPreferences: preferred).first ?? "en"
    }

    static func name(of code: String) -> String { available.first { $0.code == code }?.name ?? code }
}
