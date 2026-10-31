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
    case recordsClear = "records.clear"
    case recordsDelete = "records.delete"
    case recordsGet = "records.get"
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
    /// Newest first; `search` matches the module's search text.
    func records<T: Decodable>(_ collection: CoreCollection, as type: T.Type, search: String? = nil, limit: Int = 50,
                               before: String? = nil) throws -> CorePage<T> {
        var params: [String: Any] = ["collection": collection.rawValue, "limit": limit]
        if let search, !search.isEmpty { params["search"] = search }
        if let before { params["before"] = before }
        return try call(.recordsList, params, as: CorePage<T>.self)
    }

    /// `records`, off the main thread: for searches run as you type.
    @MainActor
    func searchRecords<T: Decodable & Sendable>(_ collection: CoreCollection, as type: T.Type, search: String?, limit: Int) async throws -> CorePage<T> {
        var params: [String: Any] = ["collection": collection.rawValue, "limit": limit]
        if let search, !search.isEmpty { params["search"] = search }
        return try await perform(.recordsList, params, as: CorePage<T>.self)
    }

    func deleteRecord(_ id: String) throws { try call(.recordsDelete, ["id": id]) }

    func clearRecords(_ collection: CoreCollection) throws { try call(.recordsClear, ["collection": collection.rawValue]) }
}
