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

    /// Shift alone would swallow ordinary typing, so a global shortcut needs ⌘, ⌥, or ⌃.
    public var isValid: Bool { modifiers & (Self.command | Self.option | Self.control) != 0 }

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
