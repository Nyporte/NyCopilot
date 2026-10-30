import Foundation
import MacPlatform

/// The shell's view of settings. Everything is stored by the core: shared settings (provider,
/// target language) are declared by core modules and sync-ready; Mac-only state such as shortcuts
/// lives under the core's device-scoped `client.` namespace.
@MainActor
final class Preferences {
    private let core: NyCore

    init(core: NyCore) { self.core = core }

    struct Provider: Equatable {
        var endpoint: String
        var model: String
        var isComplete: Bool { !endpoint.trimmingCharacters(in: .whitespaces).isEmpty && !model.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    var provider: Provider {
        Provider(endpoint: core.setting(.llmEndpoint, default: ""), model: core.setting(.llmModel, default: ""))
    }

    /// Something can translate: a model, or Google Translate through a web app.
    var canTranslate: Bool {
        provider.isComplete || (core.setting(.googleEnabled, default: true) && !core.setting(.googleURL, default: "").isEmpty)
    }

    /// Validated by the core. The model is checked first so an invalid pair never half-saves.
    func setProvider(_ provider: Provider) throws {
        let endpoint = provider.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = provider.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let previous = self.provider
        try core.setSetting(.llmModel, model)
        do { try core.setSetting(.llmEndpoint, endpoint) } catch {
            try? core.setSetting(.llmModel, previous.model)
            throw error
        }
    }

    var hasCompletedWelcome: Bool {
        get { core.setting(.welcomeCompleted, default: false) }
        set { try? core.setSetting(.welcomeCompleted, newValue) }
    }

    /// Absent means "use the action's default"; an empty string means the user turned it off.
    func hotKey(for action: String, default fallback: HotKeyCombination?) -> HotKeyCombination? {
        guard let stored = core.setting("client.hotkey.\(action)", default: Optional<String>.none) else { return fallback }
        return HotKeyCombination(storageValue: stored)
    }

    func hasStoredHotKey(for action: String) -> Bool {
        core.setting("client.hotkey.\(action)", default: Optional<String>.none) != nil
    }

    func setHotKey(_ combination: HotKeyCombination?, for action: String) {
        try? core.setSetting("client.hotkey.\(action)", combination?.storageValue ?? "")
    }

    /// Carry settings, shortcuts, and history over from the app's previous identity, exactly once.
    func migrateFromNyTranslate() {
        guard !core.setting(.migratedNyTranslate, default: false) else { return }
        try? core.setSetting(.migratedNyTranslate, true)
        if let legacy = UserDefaults(suiteName: "dev.nycopilot.NyTranslate") {
            let endpoint = legacy.string(forKey: "endpoint") ?? ""
            let model = legacy.string(forKey: "model") ?? ""
            if !endpoint.isEmpty || !model.isEmpty {
                try? core.setSetting(.llmEndpoint, endpoint)
                try? core.setSetting(.llmModel, model)
                hasCompletedWelcome = true
            }
            if let language = legacy.string(forKey: "targetLanguage") {
                try? core.setSetting(.targetLanguage, language)
            }
            for (old, action, keyCode) in [("shortcut", TranslateShell.Action.compose, UInt32(17)), ("historyShortcut", TranslateShell.Action.history, 4)] {
                switch HotKeyCombination.legacy(legacy.string(forKey: old) ?? "", keyCode: keyCode) {
                case .combination(let combination): setHotKey(combination, for: action)
                case .disabled: setHotKey(nil, for: action)
                case .unrecognized: break
                }
            }
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let oldHistory = support.appendingPathComponent("NyTranslate/history.sqlite3")
        if FileManager.default.fileExists(atPath: oldHistory.path),
           (try? core.call("translate.import_legacy", ["path": oldHistory.path])) != nil {
            try? FileManager.default.moveItem(at: oldHistory, to: oldHistory.appendingPathExtension("imported"))
        }
    }

    /// Private per-user storage for the core database.
    static var dataDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NyCopilot", isDirectory: true)
    }
}
