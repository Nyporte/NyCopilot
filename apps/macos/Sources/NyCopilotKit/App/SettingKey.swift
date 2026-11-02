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
    case screenLanguage = "translate.screen_language"
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
    case gifFPS = "capture.gif_fps"
    case gifRetina = "capture.gif_retina"
    case gifCursor = "capture.gif_cursor"
    case hideOwnWindows = "capture.hide_own_windows"
    case clipboardEnabled = "clipboard.enabled"
    case clipboardKeepDays = "clipboard.keep_days"
    case clipboardMaxItems = "clipboard.max_items"
    case inboxMarkdownFolder = "inbox.markdown_folder"
    case askSendImages = "ask.send_images"
    case mouseEnabled = "mouse.enabled"
    case mouseSpeed = "mouse.speed"
    case mouseAcceleration = "mouse.acceleration"
    case mouseReverseScroll = "mouse.reverse_scroll"
    case mouseSmoothScroll = "mouse.smooth_scroll"
    case mouseScrollLines = "mouse.scroll_lines"
    case mouseScrollGlide = "mouse.scroll_glide"
    case mouseScrollExceptions = "mouse.scroll_exceptions"
    case welcomeCompleted = "client.welcome_completed"
    case modulesOff = "client.modules_off"
    case keyScheme = "client.key_scheme"
    case migratedNyTranslate = "client.migrated_nytranslate"
    case rectangleImportChecked = "client.windows.rectangle_import_checked"
    case rectangleRepeatChecked = "client.windows.rectangle_repeat_checked"
}

/// Record collections the macOS client lists or clears.
enum CoreCollection: String {
    case translateHistory = "translate.history"
    case clipboardItems = "clipboard.items"
    case clipboardPinned = "clipboard.pinned"
    case inboxNotes = "inbox.notes"
    case inboxDone = "inbox.done"
    case inboxSnoozed = "inbox.snoozed"
}

extension NyCore {
    func setting<T>(_ key: SettingKey, default fallback: T) -> T { setting(key.rawValue, default: fallback) }
    func setSetting(_ key: SettingKey, _ value: Any) throws { try setSetting(key.rawValue, value) }
    /// Back to the module's declared default.
    func resetSetting(_ key: SettingKey) throws {
        defer { forgetSetting(key.rawValue) }
        try call(.settingsReset, ["key": key.rawValue])
    }
}
