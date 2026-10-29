import AppKit
import Carbon
import MacPlatform

/// Turn physical key codes into the labels people see on their own keyboard layout.
enum KeyNames {
    private static let special: [UInt32: String] = [
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋", 76: "⌅", 117: "⌦",
        123: "←", 124: "→", 125: "↓", 126: "↑", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15"
    ]

    /// Full display such as "⌥⌘T", following the active input source.
    static func display(_ combination: HotKeyCombination) -> String {
        combination.modifierSymbols + key(combination.keyCode)
    }

    static func key(_ keyCode: UInt32) -> String {
        if let name = special[keyCode] { return name }
        return character(keyCode)?.uppercased() ?? "#\(keyCode)"
    }

    /// Menus render shortcuts natively when the key maps to a single typed character.
    static func menuEquivalent(_ combination: HotKeyCombination?) -> (String, NSEvent.ModifierFlags) {
        guard let combination, special[combination.keyCode] == nil,
              let character = character(combination.keyCode)?.lowercased(), character.count == 1 else { return ("", []) }
        var flags: NSEvent.ModifierFlags = []
        if combination.modifiers & HotKeyCombination.command != 0 { flags.insert(.command) }
        if combination.modifiers & HotKeyCombination.option != 0 { flags.insert(.option) }
        if combination.modifiers & HotKeyCombination.control != 0 { flags.insert(.control) }
        if combination.modifiers & HotKeyCombination.shift != 0 { flags.insert(.shift) }
        return (character, flags)
    }

    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= HotKeyCombination.command }
        if flags.contains(.option) { result |= HotKeyCombination.option }
        if flags.contains(.control) { result |= HotKeyCombination.control }
        if flags.contains(.shift) { result |= HotKeyCombination.shift }
        return result
    }

    /// UCKeyTranslate with no modifiers gives the base character printed on the key cap.
    private static func character(_ keyCode: UInt32) -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let status = data.withUnsafeBytes { buffer -> OSStatus in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return -1 }
            return UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, characters.count, &length, &characters)
        }
        guard status == noErr, length > 0 else { return nil }
        let text = String(utf16CodeUnits: characters, count: length)
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }
}
