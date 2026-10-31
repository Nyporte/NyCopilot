import Foundation

/// A user-facing string in the language macOS is set to. The English text is the key, so a string
/// without a translation (and every string while one is being written) shows in English.
/// Translations live in the app's `<language>.lproj/Localizable.strings`.
func L(_ english: String) -> String {
    Bundle.main.localizedString(forKey: english, value: english, table: nil)
}
