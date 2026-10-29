import Foundation

/// A global shortcut as macOS registers it: a physical key code plus a Carbon modifier mask.
public struct HotKeyCombination: Equatable, Hashable, Sendable {
    public static let command: UInt32 = 0x0100
    public static let shift: UInt32 = 0x0200
    public static let option: UInt32 = 0x0800
    public static let control: UInt32 = 0x1000

    public var keyCode: UInt32
    public var modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers & (Self.command | Self.shift | Self.option | Self.control)
    }

    /// Key codes of F1–F20, which never type text and so may be used without modifiers.
    public static let functionKeys: Set<UInt32> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111,
                                                   105, 107, 113, 106, 64, 79, 80, 90]

    public var isFunctionKey: Bool { Self.functionKeys.contains(keyCode) }

    /// A letter or Shift+letter would swallow ordinary typing, so a global shortcut needs ⌘, ⌥, or ⌃,
    /// unless it is a function key.
    public var isValid: Bool { isFunctionKey || modifiers & (Self.command | Self.option | Self.control) != 0 }

    /// Symbols in Apple's canonical ⌃⌥⇧⌘ order, as shown in menus.
    public var modifierSymbols: String {
        [(Self.control, "⌃"), (Self.option, "⌥"), (Self.shift, "⇧"), (Self.command, "⌘")]
            .filter { modifiers & $0.0 != 0 }.map(\.1).joined()
    }

    /// A compact text form for UserDefaults; an empty string means the shortcut is turned off.
    public var storageValue: String { "\(keyCode):\(modifiers)" }

    public init?(storageValue: String) {
        let parts = storageValue.split(separator: ":")
        guard parts.count == 2, let key = UInt32(parts[0]), let mods = UInt32(parts[1]), key < 0x80 else { return nil }
        self.init(keyCode: key, modifiers: mods)
        guard isValid else { return nil }
    }

    /// NyTranslate stored one of three fixed modifier pairs; translate them onto its fixed key.
    public static func legacy(_ value: String, keyCode: UInt32) -> LegacyValue {
        switch value {
        case "optionCommand": return .combination(.init(keyCode: keyCode, modifiers: option | command))
        case "controlOption": return .combination(.init(keyCode: keyCode, modifiers: control | option))
        case "controlShift": return .combination(.init(keyCode: keyCode, modifiers: control | shift))
        case "disabled": return .disabled
        default: return .unrecognized
        }
    }

    public enum LegacyValue: Equatable { case combination(HotKeyCombination), disabled, unrecognized }
}
