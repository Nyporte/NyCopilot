import Foundation

/// Typed calls for the modules the app calls most, so their replies aren't picked apart by hand.
extension NyCore {
    /// A `{record}` reply: the record a method kept or moved, or null when it kept nothing.
    private struct Recorded: Decodable {
        struct RecordRef: Decodable { let id: String }
        let record: RecordRef?
    }

    /// The modules this core build has, by id.
    var moduleIDs: Set<String> {
        struct Info: Decodable { let modules: [String] }
        return Set((try? call(.coreInfo, as: Info.self))?.modules ?? [])
    }

    /// A setting's bounds from its module's manifest — a number's, or a list's length — or nil for a
    /// setting that has none. Controls are sized from these rather than from copies.
    func settingRange(_ key: SettingKey) -> ClosedRange<Double>? {
        settingRanges.range(key.rawValue) { [self] in
            struct Setting: Decodable { let key: String; let min: Double?; let max: Double? }
            struct Manifest: Decodable { let settings: [Setting]? }
            guard let manifests = try? call(.coreModules, as: [Manifest].self) else { return nil }
            var ranges: [String: ClosedRange<Double>] = [:]
            for setting in manifests.flatMap({ $0.settings ?? [] }) {
                if let min = setting.min, let max = setting.max, min <= max { ranges[setting.key] = min...max }
            }
            return ranges
        }
    }

    /// Fire-and-forget: tells the core to discard a request's result if it is still running.
    func cancel(requestID: String) { _ = try? call(.coreCancel, ["request_id": requestID]) }

    // MARK: Inbox

    /// Notes waiting.
    func inboxCount() -> Int {
        struct Count: Decodable { let count: Int }
        return (try? call(.inboxCount, as: Count.self))?.count ?? 0
    }

    /// Adds a note; its id.
    @discardableResult
    func inboxAdd(_ note: [String: Any]) throws -> String? { try call(.inboxAdd, note, as: Recorded.self).record?.id }

    func inboxUpdate(_ id: String, text: String) throws { try call(.inboxUpdate, ["id": id, "text": text]) }

    /// Done or not done again (`.inboxDone`, `.inboxUndone`): the note's id in its new list.
    func inboxMove(_ method: CoreMethod, _ id: String) throws -> String? { try call(method, ["id": id], as: Recorded.self).record?.id }

    /// Puts a note away until `until`; its id in the snoozed list.
    func inboxSnooze(_ id: String, until: Int64) throws -> String? {
        try call(.inboxSnooze, ["id": id, "until": until], as: Recorded.self).record?.id
    }

    struct WokenNote { let id: String; let text: String? }

    /// Brings back one snoozed note now, or every one that's due.
    func inboxWake(_ id: String? = nil) throws -> [WokenNote] {
        struct Note: Decodable { let text: String? }
        struct Woken: Decodable { let woken: [CoreRecord<Note>] }
        let params: [String: Any] = id.map { ["id": $0] } ?? [:]
        return try call(.inboxWake, params, as: Woken.self).woken.map { WokenNote(id: $0.id, text: $0.data.text) }
    }

    // MARK: Clipboard

    /// Records a copy; the id of the entry kept, or nil when the core left it out.
    func clipboardAdd(_ copy: [String: Any]) throws -> String? { try call(.clipboardAdd, copy, as: Recorded.self).record?.id }

    /// Pins an entry, or unpins it: its id in its new list.
    func clipboardPin(_ id: String, unpin: Bool = false) throws -> String? {
        try call(unpin ? .clipboardUnpin : .clipboardPin, ["id": id], as: Recorded.self).record?.id
    }

    /// A note as a Markdown file: `stem` names it (`<stamp> <title>`, made safe for file systems and
    /// note apps) and `markdown` is its text, front matter first, with `image` linked at the end.
    struct MarkdownNote: Decodable { let stem: String; let markdown: String }

    func inboxMarkdown(title: String, text: String, source: String, url: URL?, created: Date, stamp: String,
                       image: String? = nil) throws -> MarkdownNote {
        struct Note: Encodable {
            let title: String, text: String, source: String, url: String?, created: Int64, stamp: String, image: String?
        }
        let note = Note(title: title, text: text, source: source, url: url?.absoluteString,
                        created: Int64((created.timeIntervalSince1970 * 1000).rounded()), stamp: stamp, image: image)
        return try call(.inboxMarkdown, encoding: note, as: MarkdownNote.self)
    }

    func clipboardPrune() { _ = try? call(.clipboardPrune) }

    // MARK: Translate

    struct Translation: Decodable, Sendable {
        let text: String
        let targetLanguage: String
        let engine: String
        let notice: String?
    }

    /// A language as the core knows it: its English name, its own name (日本語), the short code its
    /// badge shows (EN, 中, 日), and its BCP-47 code (`zh-Hans`) when the core knows one.
    struct LanguageInfo: Decodable, Sendable, Equatable {
        let name: String
        let native: String
        let code: String
        var locale: String? = nil
    }

    /// Any language name, described by the core; one it doesn't know keeps its name and gets the
    /// core's two-letter code.
    func language(_ name: String) -> LanguageInfo {
        struct Described: Decodable { let native: String; let code: String; let locale: String? }
        let described = try? call(.translateNativeName, ["language": name], as: Described.self)
        return LanguageInfo(name: name, native: described?.native ?? name, code: described?.code ?? "", locale: described?.locale)
    }

    /// The languages the core suggests, in its order.
    func languages() -> [LanguageInfo] { (try? call(.translateLanguages, as: [LanguageInfo].self)) ?? [] }

    /// Tab in the composer: the next favorite (-1 the previous one), kept as the target language.
    func cycleLanguage(_ step: Int) throws -> LanguageInfo {
        struct Cycled: Decodable { let targetLanguage: String; let native: String; let code: String }
        let next = try call(.translateCycle, ["step": step], as: Cycled.self)
        return LanguageInfo(name: next.targetLanguage, native: next.native, code: next.code)
    }

    /// The Mac's own language, as one of the core's language names (English for one it doesn't know).
    var deviceLanguage: String {
        struct Named: Decodable { let language: String }
        let locale = Locale.preferredLanguages.first ?? "en"
        return (try? call(.translateLanguageForLocale, ["locale": locale], as: Named.self))?.language ?? "English"
    }

    /// The language you read in: screen translation's choice, or else the Mac's own language.
    /// Screen translation, translated selections, and Ask AI's answers use it.
    var readingLanguage: String {
        let chosen: String = setting(.screenLanguage, default: "")
        return chosen.isEmpty ? deviceLanguage : chosen
    }

    /// A translation service, as the core tries them; `ready` is on and set up.
    struct TranslationEngine: Decodable, Sendable {
        let id: String
        /// A name ("Google Translate"), or "Model", which is shown in the interface language.
        let title: String
        let enabled: Bool
        let configured: Bool
        let ready: Bool

        /// The setting that turns it on and off.
        var enabledSetting: SettingKey? { SettingKey(rawValue: "translate.\(id)_enabled") }
    }

    /// The translation services in the order they're tried. The Volcengine key is in the Keychain,
    /// which the core never reads, so it's told whether there is one.
    func translationEngines() -> [TranslationEngine] {
        (try? call(.translateEngines, ["has_volcengine_key": KeychainStore.hasKey(.volcengine)], as: [TranslationEngine].self)) ?? []
    }

    /// Translates with the first engine that succeeds; `keys` are the engines' secrets.
    @MainActor
    func translate(_ text: String, into language: String, keys: [String: String], extra: [String: Any] = [:]) async throws -> Translation {
        let params = extra.merging(["text": text, "target_language": language]) { _, new in new }.merging(keys) { _, key in key }
        return try await perform(.translateRun, params, as: Translation.self)
    }
}

/// Settings' bounds from the manifests, kept once read; from any thread.
final class SettingRanges: @unchecked Sendable {
    private let lock = NSLock()
    /// Guarded by `lock`; nil until a read succeeds.
    private var ranges: [String: ClosedRange<Double>]?

    func range(_ key: String, reading: () -> [String: ClosedRange<Double>]?) -> ClosedRange<Double>? {
        lock.lock(); defer { lock.unlock() }
        if ranges == nil { ranges = reading() }
        return ranges?[key]
    }
}
