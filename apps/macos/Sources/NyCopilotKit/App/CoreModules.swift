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

    func clipboardPrune() { _ = try? call(.clipboardPrune) }

    // MARK: Translate

    struct Translation: Decodable, Sendable {
        let text: String
        let targetLanguage: String
        let engine: String
        let notice: String?
    }

    /// The language you read in: screen translation's choice, or else the Mac's own language.
    /// Screen translation, translated selections, and Ask AI's answers use it.
    var readingLanguage: String {
        let chosen: String = setting(.screenLanguage, default: "")
        return chosen.isEmpty ? ScreenText.deviceLanguage : chosen
    }

    /// Translates with the first engine that succeeds; `keys` are the engines' secrets.
    @MainActor
    func translate(_ text: String, into language: String, keys: [String: String], extra: [String: Any] = [:]) async throws -> Translation {
        let params = extra.merging(["text": text, "target_language": language]) { _, new in new }.merging(keys) { _, key in key }
        return try await perform(.translateRun, params, as: Translation.self)
    }
}
