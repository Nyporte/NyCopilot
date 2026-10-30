import AppKit
import MacPlatform

/// The macOS half of a NyCopilot module.
///
/// Each feature is split in two: its platform-neutral logic, data, and settings live in a Rust
/// module in `crates/ny-modules` (shared by every client and the server), and a `ModuleShell`
/// supplies what only macOS can: overlays, menu items, global shortcuts, Accessibility, and
/// pasting. To add a module, implement both halves, then register the shell in
/// `AppDelegate.makeModules`. A shell whose core module is missing is not loaded.
@MainActor
protocol ModuleShell: AnyObject {
    /// Matches the core module's manifest id, e.g. `translate`.
    var id: String { get }
    var title: String { get }
    var symbolName: String { get }
    /// Global shortcuts; `HotKeyCenter` registers them and Settings lists them under Shortcuts.
    var hotKeyActions: [HotKeyCenter.Action] { get }
    /// Items for the menu bar menu, built fresh each time it opens.
    func menuItems() -> [NSMenuItem]
    /// A tab in Settings, or nil when the module has nothing to configure.
    func makeSettingsPane() -> SettingsPane?
    func shutdown()
}

/// App-wide services handed to every module shell, so shells never reach into the app delegate.
@MainActor
final class CopilotServices {
    let core: NyCore
    let preferences: Preferences
    let hotKeys: HotKeyCenter
    let toast = Toast()
    var openSettings: (_ paneID: String?) -> Void = { _ in }
    var showWelcome: () -> Void = {}

    init(core: NyCore, preferences: Preferences, hotKeys: HotKeyCenter) {
        self.core = core
        self.preferences = preferences
        self.hotKeys = hotKeys
    }

    /// The API key from the Keychain; the core never stores secrets itself.
    func apiKey() throws -> String { try KeychainStore.read() }
    func googleKey() throws -> String { try KeychainStore.read(.google) }
    func volcengineKey() throws -> String { try KeychainStore.read(.volcengine) }

    /// A menu item whose shortcut column mirrors the action's current global shortcut.
    func menuItem(_ title: String, symbol: String, hotKey actionID: String?, target: AnyObject, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = target
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        if let actionID {
            let (key, flags) = KeyNames.menuEquivalent(hotKeys.combination(for: actionID))
            item.keyEquivalent = key
            item.keyEquivalentModifierMask = flags
        }
        return item
    }
}
