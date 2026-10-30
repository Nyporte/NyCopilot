/// Every setting the macOS client reads or writes, by its key in the core. Module settings are
/// declared — with defaults, scope, and validation — by the Rust modules; `client.` keys are this
/// device's own state. Keeping them here means a typo is a compile error, not a silent default.
enum SettingKey: String {
    case llmEndpoint = "llm.endpoint"
    case llmModel = "llm.model"
    case targetLanguage = "translate.target_language"
    case favoriteLanguages = "translate.favorite_languages"
    case instructions = "translate.instructions"
    case trimWhitespace = "translate.trim_whitespace"
    case engineOrder = "translate.engine_order"
    case googleEnabled = "translate.google_enabled"
    case googleURL = "translate.google_url"
    case volcengineEnabled = "translate.volcengine_enabled"
    case volcengineAppID = "translate.volcengine_app_id"
    case modelEnabled = "translate.model_enabled"
    case windowGap = "windows.gap"
    case windowRepeat = "windows.repeat"
    case dragSnap = "windows.drag_snap"
    case captureSaveFolder = "capture.save_folder"
    case captureFormat = "capture.format"
    case captureFileName = "capture.file_name"
    case captureColor = "capture.color"
    case captureStroke = "capture.stroke"
    case captureStyle = "capture.style"
    case pinShadow = "capture.pin_shadow"
    case hideOwnWindows = "capture.hide_own_windows"
    case welcomeCompleted = "client.welcome_completed"
    case migratedNyTranslate = "client.migrated_nytranslate"
    case rectangleImportChecked = "client.windows.rectangle_import_checked"
    case rectangleRepeatChecked = "client.windows.rectangle_repeat_checked"
}

/// Record collections the macOS client lists or clears.
enum CoreCollection: String {
    case translateHistory = "translate.history"
}

extension NyCore {
    func setting<T>(_ key: SettingKey, default fallback: T) -> T { setting(key.rawValue, default: fallback) }
    func setSetting(_ key: SettingKey, _ value: Any) throws { try setSetting(key.rawValue, value) }
    /// Back to the module's declared default.
    func resetSetting(_ key: SettingKey) throws { try call("settings.reset", ["key": key.rawValue]) }
}
