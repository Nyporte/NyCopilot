import AppKit
import Carbon
import MacPlatform

/// Carbon registers one combination with the OS, without a keyboard hook or event polling.
final class GlobalHotKey {
    var onPress: (() -> Void)?
    /// The key came back up; for telling a tap from a hold.
    var onRelease: (() -> Void)?
    private(set) var current: HotKeyCombination?
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let identifier: UInt32
    private static let signature: OSType = 0x4E79436F // "NyCo" identifies our hotkey events.
    /// Only touched on the main thread, where hotkeys are registered.
    nonisolated(unsafe) private static var lastIdentifier: UInt32 = 0

    /// Each instance owns a distinct numeric ID so handlers never consume one another's events.
    init() throws {
        Self.lastIdentifier &+= 1
        identifier = Self.lastIdentifier
        var eventTypes = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                          EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var received = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &received)
            guard status == noErr, received.signature == GlobalHotKey.signature else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<GlobalHotKey>.fromOpaque(context).takeUnretainedValue()
            guard received.id == owner.identifier else { return OSStatus(eventNotHandledErr) }
            if GetEventKind(event) == UInt32(kEventHotKeyReleased) { owner.onRelease?() } else { owner.onPress?() }
            return noErr
        }, 2, &eventTypes, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr else { throw Failure(status: status) }
    }

    /// A combination held only while something is on screen — Esc for an overlay — so it works
    /// whichever app is in front. Released when the returned key goes; nil if another app holds it.
    static func claim(_ combination: HotKeyCombination, onPress: @escaping () -> Void) -> GlobalHotKey? {
        guard let key = try? GlobalHotKey() else { return nil }
        key.onPress = onPress
        return (try? key.register(combination)) == nil ? nil : key
    }

    /// Register a replacement before releasing the current combination, preserving it on error.
    /// Re-registering the current combination after `suspend()` restores it.
    func register(_ combination: HotKeyCombination?) throws {
        guard combination != current || (combination != nil && hotKey == nil) else { return }
        var replacement: EventHotKeyRef?
        if let combination {
            let status = RegisterEventHotKey(combination.keyCode, combination.modifiers,
                                             EventHotKeyID(signature: Self.signature, id: identifier),
                                             GetApplicationEventTarget(), 0, &replacement)
            guard status == noErr else { throw Failure(status: status) }
        }
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = replacement
        current = combination
    }

    /// Temporarily release the OS registration (while recording a new shortcut) without forgetting it.
    func suspend() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
    }

    /// Release OS registrations when the app exits.
    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }

    /// A conflict leaves Settings available so the user can choose another combination.
    struct Failure: LocalizedError {
        let status: OSStatus
        var errorDescription: String? {
            status == eventHotKeyExistsErr
                ? L("That shortcut is already used by another app. Choose a different one.")
                : L("macOS couldn’t register that shortcut (%@). Choose a different one.", String(status))
        }
    }
}
