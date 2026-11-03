//! Menu Bar: an arrow in the system menu bar that hides the icons on one side of it.
//!
//! People drag the icons they don't need to see to one side of the arrow; a click on it hides
//! them, another shows them. This module owns the settings: whether the arrow is there, whether
//! the icons are hidden now (so they stay that way across launches), and how long shown icons stay
//! before they hide again. Clients own the menu bar itself.

use ny_core::{Core, Manifest, Module, NyError, Result, Scope, SettingSpec};
use serde_json::{json, Value};

/// Seconds shown icons stay before they hide again; 0 leaves them shown.
pub const COLLAPSE_AFTER_RANGE: (f64, f64) = (0.0, 600.0);

pub struct MenuBarModule;

impl Module for MenuBarModule {
    fn manifest(&self) -> Manifest {
        Manifest {
            id: "menubar".into(),
            name: "Menu Bar".into(),
            summary: "Hide menu bar icons behind an arrow, and show them with a click.".into(),
            capabilities: vec!["statusbar.control".into()],
            collections: vec![],
            // A menu bar belongs to one Mac, with that Mac's apps in it.
            settings: vec![
                SettingSpec::new("menubar.enabled", json!(false), Scope::Device, "Put the arrow in the menu bar and hide the icons on its far side."),
                SettingSpec::new("menubar.collapsed", json!(false), Scope::Device, "The icons beyond the arrow are hidden right now."),
                SettingSpec::new("menubar.collapse_after", json!(10.0), Scope::Device,
                                 "Seconds shown icons stay before they hide again, 0–600; 0 leaves them shown."),
            ],
            commands: vec![],
        }
    }

    fn call(&self, _core: &Core, command: &str, _params: Value) -> Result<Value> {
        Err(NyError::unknown_method(&format!("menubar.{command}")))
    }

    fn validate_setting(&self, key: &str, value: &Value) -> Result<()> {
        let number = value.as_f64().unwrap_or(f64::NAN);
        match key {
            "menubar.collapse_after" if !(COLLAPSE_AFTER_RANGE.0..=COLLAPSE_AFTER_RANGE.1).contains(&number) =>
                Err(NyError::invalid_setting("Icons must hide again after 0 to 600 seconds.")),
            _ => Ok(()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ny_core::Store;

    fn core() -> Core { Core::new(Store::open_in_memory().unwrap(), crate::all(), "test", Box::new(|_| {})).unwrap() }

    #[test]
    fn off_and_shown_until_asked_and_bad_values_rejected() {
        let core = core();
        assert!(!core.setting::<bool>("menubar.enabled").unwrap());
        assert!(!core.setting::<bool>("menubar.collapsed").unwrap());
        assert_eq!(core.setting::<f64>("menubar.collapse_after").unwrap(), 10.0);

        for (key, value) in [("menubar.enabled", json!(true)), ("menubar.collapsed", json!(true)),
                             ("menubar.collapse_after", json!(0)), ("menubar.collapse_after", json!(600))] {
            assert!(core.call("settings.set", json!({ "key": key, "value": value })).is_ok(), "{key} = {value}");
        }
        for (key, value) in [("menubar.enabled", json!(1)), ("menubar.collapsed", json!("yes")),
                             ("menubar.collapse_after", json!(-1)), ("menubar.collapse_after", json!(601)),
                             ("menubar.collapse_after", json!("10"))] {
            assert!(core.call("settings.set", json!({ "key": key, "value": value })).is_err(), "{key} = {value}");
        }
        assert!(core.call("menubar.anything", json!({})).is_err());
    }
}
