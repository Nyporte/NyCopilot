import AppKit
import Carbon
import MacPlatform
import os

nonisolated(unsafe) private let log = Logger(subsystem: "dev.nycopilot.NyCopilot", category: "composer")

/// macOS half of the Translate module: capture the focused field, show the composer, ask the core
/// to translate, then paste the result back (or copy it when the field can't take a paste).
@MainActor
final class TranslateShell: ModuleShell {
    let id = "translate"
    let title = L("Translate")
    let symbolName = "character.bubble"

    /// Global shortcut action ids; HotKeyCenter stores each one's shortcut under `client.hotkey.<id>`.
    enum Action {
        static let compose = "translate.compose"
        static let history = "translate.history"
    }

    private let services: CopilotServices
    private lazy var screen = ScreenTranslator(services: services)
    private lazy var selection = SelectionTranslator(services: services)
    private let composer = ComposerPanel()
    private var historyWindow: HistoryWindow?
    private var target: InputTarget?
    private var sourceApp: NSRunningApplication?
    private var operation: Task<Void, Never>?
    private var operationID = UUID()

    init(services: CopilotServices) {
        self.services = services
        composer.onSubmit = { [weak self] text in self?.translate(text) }
        composer.onCancel = { [weak self] in self?.returnToSource() }
        composer.onClose = { [weak self] in self?.cancelOperation() }
        composer.onCycleLanguage = { [weak self] step in self?.cycleLanguage(step) }
        services.translateText = { [weak self] text, near in self?.selection.show(text, near: near) }
        services.core.seedFavoriteLanguages()
    }

    var hotKeyActions: [HotKeyCenter.Action] {
        [.init(id: Action.compose, title: L("Translate as you type"),
               defaultCombination: Self.shortcuts(in: .functionKeys)[Action.compose],
               handler: { [weak self] in self?.beginComposition() },
               // Held: the whole screen, translated in place.
               longPress: { [weak self] in self?.screen.toggle() }),
         .init(id: Action.history, title: L("Open translation history"),
               defaultCombination: .init(keyCode: UInt32(kVK_ANSI_H), modifiers: HotKeyCombination.option | HotKeyCombination.command),
               handler: { [weak self] in self?.showHistory() })]
    }

    /// F2, between capture (F1) and the inbox (F3); or ⌥⌘T.
    nonisolated static func shortcuts(in scheme: KeyScheme) -> [String: HotKeyCombination] {
        switch scheme {
        case .functionKeys: [Action.compose: .init(keyCode: UInt32(kVK_F2), modifiers: 0)]
        case .letters: [Action.compose: .init(keyCode: UInt32(kVK_ANSI_T), modifiers: KeyScheme.letterModifiers)]
        }
    }

    func menuItems() -> [NSMenuItem] {
        [services.menuItem(L("Translate…"), symbol: "character.bubble", hotKey: Action.compose, target: self, action: #selector(beginFromMenu)),
         services.menuItem(L("Translate Screen"), symbol: "rectangle.and.text.magnifyingglass", hotKey: nil, target: self, action: #selector(toggleScreen)),
         services.menuItem(L("Translation History"), symbol: "clock.arrow.circlepath", hotKey: Action.history, target: self, action: #selector(showHistory))]
    }

    func makeSettingsPane() -> SettingsPane? {
        TranslatePane(services: services, openHistory: { [weak self] in self?.showHistory() })
    }

    func shutdown() {
        cancelOperation()
        screen.stop()
        selection.dismiss()
    }

    private var language: String { services.core.setting(.targetLanguage, default: "English") }

    /// The badge code and own name the composer shows for a language.
    private static func display(_ language: NyCore.LanguageInfo) -> ComposerPanel.Language {
        .init(code: language.code, name: language.native)
    }

    /// Tab in the composer: the core picks the next favorite and remembers it as the target.
    private func cycleLanguage(_ step: Int) {
        do {
            composer.setLanguage(Self.display(try services.core.cycleLanguage(step)))
        } catch {
            composer.showError(error.localizedDescription)
        }
    }

    // MARK: Lifecycle

    /// Opening from the menu bar happens while the source app is still frontmost, just like a shortcut.
    @objc private func beginFromMenu() { beginComposition() }
    @objc private func toggleScreen() { screen.toggle() }

    /// Capture the focused field before NyCopilot activates. Text selected outside a text field is
    /// translated on a card instead; otherwise the composer opens, so the shortcut always does
    /// something useful.
    private func beginComposition() {
        if selection.isVisible { Diagnostics.note("translate", "tap closed the card"); selection.dismiss(); return }
        if composer.isVisible { Diagnostics.note("translate", "tap raised the open composer"); composer.bringToFront(); return }
        guard let foreground = NSWorkspace.shared.frontmostApplication,
              foreground.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            Diagnostics.note("translate", "NyCopilot is in front; nothing to read")
            return
        }
        cancelOperation()
        sourceApp = foreground
        let id = operationID
        let started = Date()
        operation = Task { [weak self] in
            guard let self else { return }
            var captured: InputTarget?
            do {
                captured = try await InputTarget.capture(pid: foreground.processIdentifier)
            } catch InputTarget.Failure.secureField {
                services.toast.show(L("Password fields aren’t supported"), detail: L("NyCopilot never reads or types into secure fields."), style: .warning)
                return
            } catch {
                captured = nil
            }
            guard !Task.isCancelled, operationID == id else { return }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground.processIdentifier else {
                Diagnostics.note("translate", "\(foreground.localizedName ?? "?") left the front while its field was read; nothing shown")
                return
            }
            // A field you can type in gets the composer, even with text selected: it replaces the selection.
            if captured?.isVerified == false, let (text, bounds) = await Self.selectedText(in: foreground.processIdentifier, appName: foreground.localizedName) {
                guard !Task.isCancelled, operationID == id else { return }
                let elapsed = Int(Date().timeIntervalSince(started) * 1000)
                Diagnostics.note("translate", "selection in \(foreground.localizedName ?? "?"): card \(bounds == nil ? "at the pointer" : "beside it") after \(elapsed) ms")
                selection.show(text, near: bounds)
                return
            }
            target = captured
            composer.present(over: Self.anchor(for: captured), mode: captured == nil ? .copy : .paste,
                             language: Self.display(services.core.language(language)))
        }
    }

    /// The selection, through Accessibility when the app describes it, or else by asking it to copy.
    private static func selectedText(in pid: pid_t, appName: String?) async -> (String, CGRect?)? {
        switch await InputTarget.selection(pid: pid) {
        case .text(let text, let bounds): return (text, bounds)
        case .nothing:
            Diagnostics.note("translate", "\(appName ?? "?") says nothing is selected")
            return nil
        case .unknown:
            let copied = await InputTarget.copiedSelection(pid: pid)
            if copied == nil { Diagnostics.note("translate", "\(appName ?? "?") doesn’t describe its selection, and ⌘C copied nothing") }
            return copied.map { ($0, nil) }
        }
    }


    /// One request per submit. A newer submit or a cancel makes older results irrelevant, and the
    /// core discards a cancelled result before it reaches history.
    private func translate(_ text: String) {
        let keys: [String: String]
        do {
            keys = try services.translationKeys()
        } catch {
            composer.showError(error.localizedDescription)
            return
        }
        cancelRequest()
        operationID = UUID()
        let id = operationID
        let language = language
        composer.showLoading()
        let core = services.core
        operation = Task { [weak self] in
            let result: NyCore.Translation
            do {
                result = try await core.translate(text, into: language, keys: keys, extra: ["request_id": id.uuidString])
            } catch {
                guard let self, !Task.isCancelled, operationID == id else { return }
                // Nothing set up yet: macOS translates it, and its Replace hands the result back.
                if SystemTranslation.standsIn(for: error) {
                    composer.stopLoading()
                    SystemTranslation.present(text, near: composer.frame ?? .zero) { [weak self] translated in
                        Task { await self?.deliver(translated, id: id) }
                    }
                    return
                }
                showFailure(error)
                return
            }
            guard let self, !Task.isCancelled, operationID == id else { return }
            await deliver(result.text, id: id)
            if let notice = result.notice {
                let engine = ["google": "Google Translate", "volcengine": "Volcengine"][result.engine] ?? L("the model")
                services.toast.show(L("Translated by %@", engine), detail: CoreText.localized(notice), style: .warning)
            }
        }
    }

    private func showFailure(_ error: Error) {
        let code = (error as? NyCore.Failure)?.code
        Diagnostics.note("translate", "failed: \(code ?? "unknown") — \(error.localizedDescription)")
        switch code {
        case "google_access", "invalid_key", "unsupported_language", "provider_not_configured", "volcengine_error":
            composer.showError(error.localizedDescription, action: (L("Open Settings"), { [weak self] in
                self?.composer.cancel()
                self?.services.openSettings("model")
            }))
        case "invalid_setting":
            composer.showError(error.localizedDescription, action: (L("Open Settings"), { [weak self] in
                self?.composer.cancel()
                self?.services.openSettings("model")
            }))
        case "http_status" where (error as? NyCore.Failure)?.status.map({ [401, 403, 404].contains($0) }) == true:
            composer.showError(error.localizedDescription, action: (L("Open Settings"), { [weak self] in
                self?.composer.cancel()
                self?.services.openSettings("model")
            }))
        default:
            composer.showError(error.localizedDescription)
        }
    }

    /// The result is already in history. Paste once into the field the composer came from; if that
    /// can't be done safely, the translation goes on the clipboard with a short note.
    private func deliver(_ text: String, id: UUID) async {
        let anchor = Self.anchor(for: target).map(ScreenGeometry.appKit)
        guard let target else {
            Diagnostics.note("paste", "copied instead: Accessibility is off")
            composer.hideForInsertion()
            copy(text)
            returnToSource()
            let hint = Accessibility.isTrusted ? L("This field can’t be edited directly — press ⌘V to paste.")
                                               : L("Allow Accessibility in Settings to paste automatically.")
            services.toast.show(L("Translation copied"), detail: hint, style: .success, near: anchor)
            composer.close()
            return
        }
        do {
            try await target.insert(text, prepareForPaste: { self.composer.hideForInsertion() })
            Diagnostics.note("paste", target.isVerified ? "pasted" : "pasted unverified (also on the clipboard)")
            if Tips.due("translate.screen", after: 5, times: 2) {
                let key = services.hotKeys.combination(for: Action.compose).map(KeyNames.display) ?? L("the shortcut")
                services.toast.show(L("Tip: hold %@ to translate the whole screen", key), detail: L("Point at any text to read it in your language."),
                                    style: .info, near: anchor)
            }
        } catch is CancellationError {
        } catch TemporaryPasteboard.Failure.restoreFailed {
            services.toast.show(L("Pasted"), detail: L("Your previous clipboard couldn’t be restored."), style: .warning, near: anchor)
        } catch {
            Diagnostics.note("paste", "didn’t paste: \(error.localizedDescription)")
            copy(text)
            services.toast.show(L("Couldn’t paste into the field"), detail: L("The translation is on your clipboard and in History."),
                                style: .warning, near: anchor)
        }
        guard operationID == id else { return }
        composer.close()
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// An accessory app doesn't hand focus back on its own; return it to where the user was typing.
    private func returnToSource() {
        guard let app = sourceApp, !app.isTerminated,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier else { return }
        app.activate(options: [])
    }

    private func cancelRequest() {
        services.core.cancel(requestID: operationID.uuidString)
        operation?.cancel()
    }

    /// Invalidate callbacks before dropping the target; cancellation cannot undo an already sent paste.
    private func cancelOperation() {
        cancelRequest()
        operationID = UUID()
        operation = nil
        target = nil
    }

    @objc private func showHistory() {
        if historyWindow == nil { historyWindow = HistoryWindow(core: services.core) }
        historyWindow?.present()
    }

    /// Where to put the composer and notices: the text cursor when the app reports it, otherwise the
    /// field if it is a single line or so. Web apps often report their whole page as the field,
    /// which would put the composer far from where you're typing; the pointer is closer then.
    private static func anchor(for target: InputTarget?) -> CGRect? {
        let anchor: CGRect?
        let source: String
        if let caret = target?.caret { (anchor, source) = (caret, "caret") }
        else if let frame = target?.frame, frame.height <= 120 { (anchor, source) = (frame, "field") }
        else { (anchor, source) = (nil, "pointer") }
        log.notice("composer anchored to \(source, privacy: .public) \(String(describing: anchor), privacy: .public)")
        return anchor
    }
}

extension NyCore {
    /// The core's favorites, which Tab steps through in the composer, until someone changes them.
    static let coreFavorites = ["English", "Simplified Chinese", "Japanese"]

    /// On a Mac in another language, the favorites start as English and that language instead of
    /// the core's English, Chinese, and Japanese. Once per Mac, and only if they're still the core's.
    func seedFavoriteLanguages(device: String = ScreenText.deviceLanguage, defaults: UserDefaults = .standard) {
        let key = "NyCopilotSeededFavorites"
        guard !defaults.bool(forKey: key) else { return }
        defaults.set(true, forKey: key)
        let favorites: [String] = setting(.favoriteLanguages, default: [])
        guard favorites == Self.coreFavorites, !favorites.contains(device) else { return }
        try? setSetting(.favoriteLanguages, ["English", device])
    }
}
