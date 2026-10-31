import Foundation

/// Typed calls for the modules the app calls most, so their replies aren't picked apart by hand.
extension NyCore {
    /// The id inside a `{record: {id}}` reply.
    private func recordID(_ reply: Any) -> String? { ((reply as? [String: Any])?["record"] as? [String: Any])?["id"] as? String }

    // MARK: Inbox

    /// Notes waiting.
    func inboxCount() -> Int { ((try? call(.inboxCount)) as? [String: Any])?["count"] as? Int ?? 0 }

    /// Adds a note; its id.
    @discardableResult
    func inboxAdd(_ note: [String: Any]) throws -> String? { recordID(try call(.inboxAdd, note)) }

    func inboxUpdate(_ id: String, text: String) throws { try call(.inboxUpdate, ["id": id, "text": text]) }

    /// Done or not done again (`.inboxDone`, `.inboxUndone`): the note's id in its new list.
    func inboxMove(_ method: CoreMethod, _ id: String) throws -> String? { recordID(try call(method, ["id": id])) }

    /// Puts a note away until `until`; its id in the snoozed list.
    func inboxSnooze(_ id: String, until: Int64) throws -> String? { recordID(try call(.inboxSnooze, ["id": id, "until": until])) }

    struct WokenNote { let id: String; let text: String? }

    /// Brings back one snoozed note now, or every one that's due.
    func inboxWake(_ id: String? = nil) throws -> [WokenNote] {
        let reply = try call(.inboxWake, id.map { ["id": $0] } ?? [:])
        return ((reply as? [String: Any])?["woken"] as? [[String: Any]] ?? []).compactMap { record in
            (record["id"] as? String).map { WokenNote(id: $0, text: (record["data"] as? [String: Any])?["text"] as? String) }
        }
    }

    // MARK: Clipboard

    /// Records a copy; the entry kept, or nil when the core left it out.
    func clipboardAdd(_ copy: [String: Any]) throws -> [String: Any]? {
        ((try call(.clipboardAdd, copy)) as? [String: Any])?["record"] as? [String: Any]
    }

    func clipboardPrune() { _ = try? call(.clipboardPrune) }

    // MARK: Translate

    struct Translation: Decodable, Sendable {
        let text: String
        let targetLanguage: String
        let engine: String
        let notice: String?
    }

    /// Translates with the first engine that succeeds; `keys` are the engines' secrets.
    @MainActor
    func translate(_ text: String, into language: String, keys: [String: String], extra: [String: Any] = [:]) async throws -> Translation {
        let params = extra.merging(["text": text, "target_language": language]) { _, new in new }.merging(keys) { _, key in key }
        return try await perform(.translateRun, params, as: Translation.self)
    }
}
