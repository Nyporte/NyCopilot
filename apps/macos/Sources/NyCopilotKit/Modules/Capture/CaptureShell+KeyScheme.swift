import Carbon
import MacPlatform

extension CaptureShell {
    /// F1, ⇧F1 to pin the clipboard, ⌥F1 to hide or show pins; or ⌥⌘S, ⌥⌘P, and ⌥⌘⇧P.
    nonisolated static func shortcuts(in scheme: KeyScheme) -> [String: HotKeyCombination] {
        switch scheme {
        case .functionKeys:
            let f1 = UInt32(kVK_F1)
            return [Action.capture: .init(keyCode: f1, modifiers: 0),
                    Action.pinClipboard: .init(keyCode: f1, modifiers: HotKeyCombination.shift),
                    Action.togglePins: .init(keyCode: f1, modifiers: HotKeyCombination.option)]
        case .letters:
            let letters = KeyScheme.letterModifiers
            return [Action.capture: .init(keyCode: UInt32(kVK_ANSI_S), modifiers: letters),
                    Action.pinClipboard: .init(keyCode: UInt32(kVK_ANSI_P), modifiers: letters),
                    Action.togglePins: .init(keyCode: UInt32(kVK_ANSI_P), modifiers: letters | HotKeyCombination.shift)]
        }
    }
}
