import AppKit
import MacPlatform

/// Two ways to lay out the one-press shortcuts: function keys (F1 capture, F2 translate, F3 inbox,
/// F4 ask — one press on keyboards whose F-keys send F1, F2…) or letters with ⌥⌘ (⌥⌘S, ⌥⌘T, ⌥⌘J,
/// ⌥⌘A — which work on any keyboard).
/// Everything else is the same in both.
enum KeyScheme: String, CaseIterable {
    case functionKeys, letters

    var title: String {
        switch self {
        case .functionKeys: "F1 – F4"
        case .letters: "⌥⌘ S · T · J · A"
        }
    }

    /// Apple keyboards' top row controls brightness and volume unless "Use F1, F2, etc. keys as
    /// standard function keys" is on; then function keys are one press.
    static var functionKeysAreStandard: Bool {
        UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["com.apple.keyboard.fnState"] as? Bool ?? false
    }

    static var recommended: KeyScheme { functionKeysAreStandard ? .functionKeys : .letters }

    /// The scheme chosen in the setup guide; before that, the one the screenshot shortcut is in.
    @MainActor
    static func current(_ preferences: Preferences) -> KeyScheme {
        if let chosen = preferences.chosenKeyScheme { return chosen }
        let capture = CaptureShell.Action.capture
        return preferences.hotKey(for: capture, default: nil) == letters.combinations[capture] ? .letters : .functionKeys
    }

    /// Moves the scheme's shortcuts (those of modules that are on) to this scheme; the failures, if
    /// another app holds one.
    @MainActor
    func apply(_ services: CopilotServices) -> [String: String] {
        try? services.core.setSetting(.keyScheme, rawValue)
        var changes: [String: HotKeyCombination?] = [:]
        for (id, combination) in combinations where services.hotKeys.combination(for: id) != nil { changes[id] = combination }
        return services.hotKeys.set(changes)
    }

    /// Every module's shortcuts in this scheme, as each shell gives them.
    var combinations: [String: HotKeyCombination] {
        ModuleShells.all.reduce(into: [:]) { all, shell in all.merge(shell.type.shortcuts(in: self)) { first, _ in first } }
    }

    /// The letters scheme's ⌥⌘; a second action on the same letter adds ⇧.
    static let letterModifiers = HotKeyCombination.option | HotKeyCombination.command
}
