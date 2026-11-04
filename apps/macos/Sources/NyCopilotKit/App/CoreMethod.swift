import Foundation

/// Every method of the core protocol the app calls (see spec/protocol.md), so a misspelled method
/// is a compile error rather than an `unknown_method` at run time.
enum CoreMethod: String {
    case askRun = "ask.run"
    case captureFileName = "capture.file_name"
    case capturePalette = "capture.palette"
    case captureRecentRegions = "capture.recent_regions"
    case captureRecord = "capture.record"
    case clipboardAdd = "clipboard.add"
    case clipboardPin = "clipboard.pin"
    case clipboardPrune = "clipboard.prune"
    case clipboardUnpin = "clipboard.unpin"
    case coreCancel = "core.cancel"
    case coreCompact = "core.compact"
    case coreInfo = "core.info"
    case coreModules = "core.modules"
    case inboxAdd = "inbox.add"
    case inboxCount = "inbox.count"
    case inboxDone = "inbox.done"
    case inboxSnooze = "inbox.snooze"
    case inboxUndone = "inbox.undone"
    case inboxUpdate = "inbox.update"
    case inboxWake = "inbox.wake"
    case llmTest = "llm.test"
    case mousePointer = "mouse.pointer"
    case recordsClear = "records.clear"
    case recordsDelete = "records.delete"
    case recordsList = "records.list"
    case settingsGet = "settings.get"
    case settingsReset = "settings.reset"
    case settingsSet = "settings.set"
    case translateCycle = "translate.cycle"
    case translateImportLegacy = "translate.import_legacy"
    case translateLanguages = "translate.languages"
    case translateNativeName = "translate.native_name"
    case translateRun = "translate.run"
    case translateTestGoogle = "translate.test_google"
    case translateTestVolcengine = "translate.test_volcengine"
    case windowsActions = "windows.actions"
    case windowsCompute = "windows.compute"
    case windowsMoveToScreen = "windows.move_to_screen"
    case windowsSnapArea = "windows.snap_area"
}

/// Typed forms of the record calls every module makes.
extension NyCore {
    /// `records.list`'s parameters; an empty search matches everything.
    private struct RecordsQuery: Encodable {
        let collection: String
        let limit: Int
        let search: String?
        let before: String?

        init(_ collection: CoreCollection, search: String?, limit: Int, before: String?) {
            self.collection = collection.rawValue
            self.limit = limit
            self.search = search?.isEmpty == false ? search : nil
            self.before = before
        }
    }

    /// Newest first; `search` matches the module's search text.
    func records<T: Decodable>(_ collection: CoreCollection, as type: T.Type, search: String? = nil, limit: Int = 50,
                               before: String? = nil) throws -> CorePage<T> {
        try call(.recordsList, encoding: RecordsQuery(collection, search: search, limit: limit, before: before), as: CorePage<T>.self)
    }

    /// `records`, off the main thread: for searches run as you type.
    @MainActor
    func searchRecords<T: Decodable & Sendable>(_ collection: CoreCollection, as type: T.Type, search: String?, limit: Int) async throws -> CorePage<T> {
        try await perform(.recordsList, encoding: RecordsQuery(collection, search: search, limit: limit, before: nil), as: CorePage<T>.self)
    }

    func deleteRecord(_ id: String) throws { try call(.recordsDelete, ["id": id]) }

    func clearRecords(_ collection: CoreCollection) throws { try call(.recordsClear, ["collection": collection.rawValue]) }
}
