use serde::Serialize;

/// Every failure crosses the API boundary as a stable machine-readable `code` plus a short,
/// user-presentable `message`. Messages never contain user text, response bodies, or secrets.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, thiserror::Error)]
#[error("{message}")]
pub struct NyError {
    pub code: String,
    pub message: String,
    /// HTTP status for `http_status` errors, so clients can branch without parsing messages.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub status: Option<u16>,
}

pub type Result<T> = std::result::Result<T, NyError>;

impl NyError {
    pub fn new(code: &str, message: impl Into<String>) -> Self {
        Self { code: code.into(), message: message.into(), status: None }
    }

    pub fn invalid_params(message: impl Into<String>) -> Self { Self::new("invalid_params", message) }
    pub fn invalid_setting(message: impl Into<String>) -> Self { Self::new("invalid_setting", message) }
    pub fn not_found(message: impl Into<String>) -> Self { Self::new("not_found", message) }
    pub fn unknown_method(method: &str) -> Self { Self::new("unknown_method", format!("Unknown method “{method}”.")) }
}

impl From<rusqlite::Error> for NyError {
    fn from(_: rusqlite::Error) -> Self {
        Self::new("storage", "NyCopilot’s local database couldn’t be read or written.")
    }
}

impl From<std::io::Error> for NyError {
    fn from(_: std::io::Error) -> Self {
        Self::new("storage", "NyCopilot couldn’t access its data folder.")
    }
}

impl From<serde_json::Error> for NyError {
    fn from(error: serde_json::Error) -> Self { Self::invalid_params(format!("Malformed parameters: {error}")) }
}
