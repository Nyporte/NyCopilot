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
    static func current(_ services: CopilotServices) -> KeyScheme {
        if let chosen = KeyScheme(rawValue: services.core.setting(.keyScheme, default: "")) { return chosen }
        let capture = services.hotKeys.combination(for: CaptureShell.Action.capture)
        return capture != nil && capture == letters.combinations[CaptureShell.Action.capture] ? .letters : .functionKeys
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

    var combinations: [String: HotKeyCombination] {
        let option = HotKeyCombination.option, command = HotKeyCombination.command, shift = HotKeyCombination.shift
        switch self {
        case .functionKeys:
            return [CaptureShell.Action.capture: .init(keyCode: 122, modifiers: 0),
                    CaptureShell.Action.pinClipboard: .init(keyCode: 122, modifiers: shift),
                    CaptureShell.Action.togglePins: .init(keyCode: 122, modifiers: option),
                    TranslateShell.Action.compose: .init(keyCode: 120, modifiers: 0),
                    InboxShell.Action.capture: .init(keyCode: 99, modifiers: 0),
                    InboxShell.Action.open: .init(keyCode: 99, modifiers: shift),
                    AskShell.Action.open: .init(keyCode: 118, modifiers: 0)]
        case .letters:
            return [CaptureShell.Action.capture: .init(keyCode: 1, modifiers: option | command), // ⌥⌘S
                    CaptureShell.Action.pinClipboard: .init(keyCode: 35, modifiers: option | command), // ⌥⌘P
                    CaptureShell.Action.togglePins: .init(keyCode: 35, modifiers: option | command | shift),
                    TranslateShell.Action.compose: .init(keyCode: 17, modifiers: option | command), // ⌥⌘T
                    InboxShell.Action.capture: .init(keyCode: 38, modifiers: option | command), // ⌥⌘J
                    InboxShell.Action.open: .init(keyCode: 38, modifiers: option | command | shift),
                    AskShell.Action.open: .init(keyCode: 0, modifiers: option | command)] // ⌥⌘A
        }
    }
}
