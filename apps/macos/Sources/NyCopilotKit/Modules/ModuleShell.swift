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

/// The things you can do with whatever you're looking at — a screenshot, a pin, a clipboard entry,
/// an inbox note, an answer — with the same key everywhere: R translate, I keep in the inbox, A ask
/// AI, P pin to the screen. Where you type (a search field), the same letters go with ⌘.
enum Verb: CaseIterable {
    case translate, inbox, ask, pin

    var key: String {
        switch self {
        case .translate: "R"
        case .inbox: "I"
        case .ask: "A"
        case .pin: "P"
        }
    }

    var title: String {
        switch self {
        case .translate: "Translate"
        case .inbox: "Keep in Inbox"
        case .ask: "Ask AI"
        case .pin: "Pin to Screen"
        }
    }
}

/// App-wide services handed to every module shell, so shells never reach into the app delegate.
@MainActor
final class CopilotServices {
    let core: NyCore
    let preferences: Preferences
    let hotKeys: HotKeyCenter
    let toast = Toast()
    var openSettings: (_ paneID: String?) -> Void = { _ in }
    /// Modules can be turned off (their shortcuts and menu items go) from the setup guide or General.
    var isModuleOn: (_ id: String) -> Bool = { _ in true }
    var setModule: (_ id: String, _ on: Bool) -> Void = { _, _ in }
    /// The loaded modules' ids and titles, in menu order.
    var moduleList: () -> [(id: String, title: String, symbol: String)] = { [] }
    var showWelcome: () -> Void = {}
    /// Shows a translation of `text` on a card beside `near` (AX coordinates), for modules that find
    /// text (screenshots); Translate provides it.
    var translateText: (_ text: String, _ near: CGRect?) -> Void = { _, _ in }
    /// Files a note — text, a screenshot, or both — in the inbox, noting the app (and its window) it
    /// came from; Inbox provides it.
    var sendToInbox: (_ text: String?, _ image: NSImage?, _ from: NSRunningApplication?) -> Void = { _, _, _ in }
    /// Files a file — a GIF recording — in the inbox; Inbox provides it.
    var sendFileToInbox: (_ url: URL, _ from: NSRunningApplication?) -> Void = { _, _ in }
    /// Opens Ask AI on a thing — a selection, a screenshot, a note; Ask AI provides it.
    var askAI: (_ material: AskMaterial) -> Void = { _ in }
    /// Pins text (as a card) or an image on top of everything; Screenshot & Pin provides it.
    var pinOnScreen: (_ text: String?, _ image: NSImage?) -> Void = { _, _ in }

    init(core: NyCore, preferences: Preferences, hotKeys: HotKeyCenter) {
        self.core = core
        self.preferences = preferences
        self.hotKeys = hotKeys
    }

    /// Does `verb` with a thing — text, an image, or both — that came from `app`, shown near `anchor`
    /// (AppKit coordinates) when it's on screen.
    func act(_ verb: Verb, text: String?, image: NSImage?, from app: NSRunningApplication? = nil, near anchor: NSRect? = nil) {
        let text = text.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        guard text != nil || image != nil else { NSSound.beep(); return }
        let near = anchor.map(ScreenGeometry.topLeft)
        switch verb {
        case .translate:
            if let text { translateText(text, near); return }
            guard let cgImage = image?.cgImage(forProposedRect: nil, context: nil, hints: nil), let image else { return }
            Task {
                let paragraphs = (try? await ScreenTranslator.paragraphs(in: cgImage, scale: CGFloat(cgImage.width) / max(image.size.width, 1))) ?? []
                if paragraphs.isEmpty { toast.show("No text to translate here", style: .info, near: anchor) }
                else { translateText(paragraphs.joined(separator: "\n\n"), near) }
            }
        case .inbox:
            sendToInbox(text, image, app)
        case .ask:
            Task { askAI(AskMaterial(text: text ?? "", image: image, source: await SourceContext.of(app), anchor: anchor, app: app)) }
        case .pin:
            pinOnScreen(text, image)
        }
    }

    /// Every translation engine's secret from the Keychain, as `translate.run` takes them; the core
    /// never stores secrets itself.
    func translationKeys() throws -> [String: String] {
        ["api_key": try KeychainStore.read(), "google_key": try KeychainStore.read(.google),
         "volcengine_key": try KeychainStore.read(.volcengine)]
    }

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
