import AppKit
import Carbon
import MacPlatform

/// Tap the translate shortcut with text selected outside a text field — on a web page, in a PDF, in
/// a message — and its translation appears on a card beside it, in the language you read in (or,
/// for text already in that language, the composer's language). Its text can be selected; ⌘C
/// copies the selection, or all of it. Esc, a click elsewhere, switching apps, or the shortcut
/// again closes it.
@MainActor
final class SelectionTranslator {
    private let services: CopilotServices
    private let card = TranslationCard(interactive: true)
    /// Esc and ⌘C, held only while the card is up.
    private var keys: [GlobalHotKey] = []
    /// Clicks in other apps (clicks on the card itself go to the card), and switching apps.
    private var clickMonitor: Any?
    private var appSwitch: NSObjectProtocol?
    private var request: Task<Void, Never>?
    private var translation: String?

    init(services: CopilotServices) { self.services = services }

    var isVisible: Bool { card.isVisible }

    /// `bounds` is the selection in AX coordinates; without it the card goes by the pointer.
    func show(_ text: String, near bounds: CGRect?) {
        dismiss()
        let pointer = NSEvent.mouseLocation
        let source = bounds.map(ScreenGeometry.appKit)
            ?? NSRect(x: pointer.x, y: pointer.y - 4, width: 1, height: 8)
        let screen = NSScreen.screens.first { $0.frame.intersects(source) } ?? NSScreen.main ?? NSScreen.screens[0]
        let language = Self.language(for: text, core: services.core)
        card.present(language: services.core.nativeName(of: language), beside: source, on: screen, hint: "⌘C copy   esc close")
        card.showWaiting()
        keys = [GlobalHotKey.claim(HotKeyCombination(keyCode: UInt32(kVK_Escape), modifiers: 0)) { [weak self] in
                    MainActor.assumeIsolated { self?.dismiss() }
                },
                GlobalHotKey.claim(HotKeyCombination(keyCode: UInt32(kVK_ANSI_C), modifiers: HotKeyCombination.command)) { [weak self] in
                    MainActor.assumeIsolated { self?.copy() }
                }].compactMap { $0 }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
        appSwitch = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                                     object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            MainActor.assumeIsolated { self?.dismiss() }
        }
        request = Task { [weak self] in await self?.translate(text, into: language) }
    }

    func dismiss() {
        request?.cancel()
        request = nil
        keys = []
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        if let appSwitch { NSWorkspace.shared.notificationCenter.removeObserver(appSwitch) }
        appSwitch = nil
        translation = nil
        card.orderOut(nil)
    }

    /// Into the language you read in, unless the text is already in it; then into the composer's.
    static func language(for text: String, core: NyCore) -> String {
        let reading = core.readingLanguage
        if ScreenText.needsTranslation(text, into: ScreenText.code(for: reading)) { return reading }
        return core.setting(.targetLanguage, default: "English")
    }

    private func translate(_ text: String, into language: String) async {
        struct Result: Decodable { let text: String }
        do {
            let params: [String: Any] = ["text": text, "target_language": language]
            let result = try await services.core.perform("translate.run", params.merging(try services.translationKeys()) { _, key in key },
                                                         as: Result.self)
            guard !Task.isCancelled, card.isVisible else { return }
            translation = result.text
            card.show(result.text)
        } catch {
            guard !Task.isCancelled, card.isVisible else { return }
            if (error as? NyCore.Failure)?.code == "provider_not_configured", SystemTranslation.isAvailable {
                let frame = card.frame
                dismiss()
                SystemTranslation.present(text, near: frame)
                return
            }
            Diagnostics.note("translate", "selection failed: \(error.localizedDescription)")
            card.show(failure: error.localizedDescription)
        }
    }

    /// ⌘C while the card is up: what's selected on it — or, with nothing selected, the whole
    /// translation — onto the clipboard. Copying a part keeps the card up for more.
    private func copy() {
        guard let translation else { return }
        let part = card.selectedText
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(part ?? translation, forType: .string)
        if part == nil { dismiss() }
    }
}
