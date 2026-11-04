use serde::Serialize;
use serde_json::Value;

use crate::{Core, Result};

/// Where a setting lives: `Synced` values follow the user to every device (once sync exists);
/// `Device` values describe this machine, such as keyboard shortcuts or window positions.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Scope { Synced, Device }

impl Scope {
    pub fn as_str(self) -> &'static str { match self { Scope::Synced => "synced", Scope::Device => "device" } }
}

#[derive(Debug, Clone, Serialize)]
pub struct SettingSpec {
    pub key: String,
    pub default: Value,
    pub scope: Scope,
    pub description: String,
    /// The bounds of a number, or of a list's length, so clients can size their controls. The
    /// module's `validate_setting` enforces them (with any exceptions it documents).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub min: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub max: Option<f64>,
}

impl SettingSpec {
    pub fn new(key: &str, default: Value, scope: Scope, description: &str) -> Self {
        Self { key: key.into(), default, scope, description: description.into(), min: None, max: None }
    }

    pub fn range(self, (min, max): (f64, f64)) -> Self { Self { min: Some(min), max: Some(max), ..self } }

    /// Whether `value` is within `range`.
    pub fn within(range: (f64, f64), value: f64) -> bool { (range.0..=range.1).contains(&value) }
}

#[derive(Debug, Clone, Serialize)]
pub struct CommandSpec {
    pub name: String,
    pub description: String,
}

impl CommandSpec {
    pub fn new(name: &str, description: &str) -> Self { Self { name: name.into(), description: description.into() } }
}

/// What a module is and needs. Clients read manifests to decide which modules they can host:
/// a module whose `capabilities` a platform cannot provide (for example `screen.capture` on a
/// server) is simply not offered there.
#[derive(Debug, Clone, Serialize)]
pub struct Manifest {
    pub id: String,
    pub name: String,
    pub summary: String,
    /// Platform services the client must supply, e.g. `text.capture`, `text.insert`, `hotkey`.
    pub capabilities: Vec<String>,
    /// Record collections the module owns, always prefixed with its id.
    pub collections: Vec<String>,
    pub settings: Vec<SettingSpec>,
    pub commands: Vec<CommandSpec>,
}

/// A feature of NyCopilot. Implementations hold no UI and no platform APIs; anything
/// platform-specific (capturing a field, drawing an overlay, registering a hotkey) is the client's job.
pub trait Module: Send + Sync {
    fn manifest(&self) -> Manifest;

    /// Handle `"<module id>.<command>"`; `command` excludes the module prefix.
    fn call(&self, core: &Core, command: &str, params: Value) -> Result<Value>;

    /// Reject invalid values before they are stored. Called only for this module's own keys.
    fn validate_setting(&self, _key: &str, _value: &Value) -> Result<()> { Ok(()) }
}
