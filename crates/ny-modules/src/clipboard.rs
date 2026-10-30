//! Clipboard history: what you copied, newest first, searchable, and kept for a while.
//!
//! The client watches the pasteboard and never passes on what must not be kept (content marked
//! concealed or transient by the app that copied it). This module keeps the history: one entry
//! per distinct text, moved back to the top when it's copied again, nothing from the apps you
//! exclude, and only as many entries, for as long, as the settings allow.

use ny_core::{now_millis, parse, CommandSpec, Core, Manifest, Module, NyError, Result, Scope, SettingSpec};
use serde::Deserialize;
use serde_json::{json, Value};

pub const ITEMS: &str = "clipboard.items";
/// Larger copies (a whole file's text) are left out of the history.
pub const MAX_TEXT_BYTES: usize = 256 * 1024;
const DAY_MILLIS: i64 = 24 * 60 * 60 * 1000;

/// Password managers, by bundle identifier: never recorded unless the user takes them off the list.
pub const DEFAULT_IGNORED_APPS: &[&str] = &[
    "com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop",
    "com.apple.keychainaccess", "com.apple.Passwords", "org.keepassxc.keepassxc",
];

pub struct ClipboardModule;

impl Module for ClipboardModule {
    fn manifest(&self) -> Manifest {
        Manifest {
            id: "clipboard".into(),
            name: "Clipboard".into(),
            summary: "Everything you copy, searchable, ready to paste again.".into(),
            capabilities: vec!["clipboard.watch".into(), "text.insert".into(), "hotkey".into()],
            collections: vec![ITEMS.into()],
            settings: vec![
                // What you copy stays on the machine you copied it on.
                SettingSpec::new("clipboard.enabled", json!(true), Scope::Device, "Keep a history of copied text."),
                SettingSpec::new("clipboard.keep_days", json!(30), Scope::Synced, "Days an entry is kept (1–365)."),
                SettingSpec::new("clipboard.max_items", json!(500), Scope::Synced, "Most entries kept (10–5000); the oldest go first."),
                SettingSpec::new("clipboard.ignored_apps", json!(DEFAULT_IGNORED_APPS), Scope::Synced,
                                 "Bundle identifiers of apps whose copies are never kept."),
            ],
            commands: vec![
                CommandSpec::new("add", "Record a copy: {text, app?, bundle_id?} → {record} (moved to the top if the same text is already kept), or {record: null, skipped} when it isn't kept."),
                CommandSpec::new("prune", "Apply the retention settings now → {deleted}."),
            ],
        }
    }

    fn call(&self, core: &Core, command: &str, params: Value) -> Result<Value> {
        #[derive(Deserialize)]
        struct Add { text: String, #[serde(default)] app: String, #[serde(default)] bundle_id: String }
        match command {
            "add" => {
                let p: Add = parse(params)?;
                let skipped = |why: &str| Ok(json!({ "record": null, "skipped": why }));
                if !core.setting::<bool>("clipboard.enabled")? { return skipped("off"); }
                if !p.bundle_id.is_empty() && core.setting::<Vec<String>>("clipboard.ignored_apps")?.contains(&p.bundle_id) {
                    return skipped("ignored_app");
                }
                if p.text.trim().is_empty() { return skipped("empty"); }
                if p.text.len() > MAX_TEXT_BYTES { return skipped("too_large"); }
                // The same text copied again moves to the top rather than appearing twice.
                let page = core.call("records.list", json!({ "collection": ITEMS, "search": p.text, "limit": 50 }))?;
                for record in page["records"].as_array().into_iter().flatten() {
                    if record["data"]["text"].as_str() == Some(p.text.as_str()) {
                        core.call("records.delete", json!({ "id": record["id"] }))?;
                    }
                }
                let record = core.insert_record(ITEMS, json!({ "text": p.text, "app": p.app }), &p.text, None)?;
                prune(core)?;
                Ok(json!({ "record": record }))
            }
            "prune" => Ok(json!({ "deleted": prune(core)? })),
            _ => Err(NyError::unknown_method(&format!("clipboard.{command}"))),
        }
    }

    fn validate_setting(&self, key: &str, value: &Value) -> Result<()> {
        match key {
            "clipboard.keep_days" if !value.as_i64().is_some_and(|days| (1..=365).contains(&days)) =>
                Err(NyError::invalid_setting("Keep entries for 1 to 365 days.")),
            "clipboard.max_items" if !value.as_i64().is_some_and(|count| (10..=5000).contains(&count)) =>
                Err(NyError::invalid_setting("Keep between 10 and 5000 entries.")),
            "clipboard.ignored_apps" if !value.as_array().is_some_and(|apps| apps.len() <= 200
                && apps.iter().all(|app| app.as_str().is_some_and(|id| !id.trim().is_empty() && id.len() <= 200 && !id.contains(char::is_whitespace)))) =>
                Err(NyError::invalid_setting("Excluded apps are listed by bundle identifier, such as com.example.app.")),
            _ => Ok(()),
        }
    }
}

/// Keep only the newest `max_items`, and nothing older than `keep_days`.
fn prune(core: &Core) -> Result<usize> {
    let keep = core.setting::<i64>("clipboard.max_items")?.clamp(10, 5000) as usize;
    let days = core.setting::<i64>("clipboard.keep_days")?.clamp(1, 365);
    core.prune_records(ITEMS, keep, now_millis() - days * DAY_MILLIS)
}

#[cfg(test)]
mod tests {
    use super::*;
    use ny_core::Store;

    fn core() -> Core { Core::new(Store::open_in_memory().unwrap(), crate::all(), "test", Box::new(|_| {})).unwrap() }

    fn texts(core: &Core) -> Vec<String> {
        let page = core.call("records.list", json!({ "collection": ITEMS })).unwrap();
        page["records"].as_array().unwrap().iter().map(|r| r["data"]["text"].as_str().unwrap().to_string()).collect()
    }

    #[test]
    fn copies_are_kept_newest_first_without_repeats() {
        let core = core();
        for text in ["one", "two", "one", "one more"] {
            core.call("clipboard.add", json!({ "text": text, "app": "Notes" })).unwrap();
        }
        assert_eq!(texts(&core), ["one more", "one", "two"]);
        let found = core.call("records.list", json!({ "collection": ITEMS, "search": "one" })).unwrap();
        assert_eq!(found["records"].as_array().unwrap().len(), 2);
    }

    #[test]
    fn some_copies_are_never_kept() {
        let core = core();
        let add = |params: Value| core.call("clipboard.add", params).unwrap()["skipped"].clone();
        assert_eq!(add(json!({ "text": "hunter2", "bundle_id": "com.1password.1password" })), "ignored_app");
        assert_eq!(add(json!({ "text": "  \n" })), "empty");
        assert_eq!(add(json!({ "text": "x".repeat(MAX_TEXT_BYTES + 1) })), "too_large");
        core.call("settings.set", json!({ "key": "clipboard.enabled", "value": false })).unwrap();
        assert_eq!(add(json!({ "text": "hello" })), "off");
        assert!(texts(&core).is_empty());
    }

    #[test]
    fn history_is_pruned_to_the_settings() {
        let core = core();
        core.call("settings.set", json!({ "key": "clipboard.max_items", "value": 10 })).unwrap();
        for n in 0..14 { core.call("clipboard.add", json!({ "text": format!("item {n}") })).unwrap(); }
        let kept = texts(&core);
        assert_eq!((kept.len(), kept[0].as_str(), kept[9].as_str()), (10, "item 13", "item 4"));
        for (key, bad) in [("clipboard.max_items", json!(5)), ("clipboard.keep_days", json!(0)),
                           ("clipboard.ignored_apps", json!(["has space"])), ("clipboard.ignored_apps", json!("com.a"))] {
            assert!(core.call("settings.set", json!({ "key": key, "value": bad })).is_err(), "{key} {bad}");
        }
    }
}
