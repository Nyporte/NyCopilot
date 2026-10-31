//! Clipboard history: what you copied, newest first, searchable, and kept for a while.
//!
//! The client watches the pasteboard and never passes on what must not be kept (content marked
//! concealed or transient by the app that copied it). This module keeps the history: one entry
//! per distinct text or image, moved back to the top when it's copied again, nothing from the apps
//! you exclude, and only as many entries, for as long, as the settings allow.
//!
//! An image is a PNG the client keeps beside the database; an entry records only the file's name
//! (`<uuid>.png`), its size, and a digest of its pixels so a repeat copy is recognized.
//!
//! Entries you pin move to `clipboard.pinned`: kept until you unpin them, never pruned, listed above
//! the history.

use ny_core::{now_millis, parse, CommandSpec, Core, Manifest, Module, NyError, Result, Scope, SettingSpec};
use serde::Deserialize;
use serde_json::{json, Value};

pub const ITEMS: &str = "clipboard.items";
pub const PINNED: &str = "clipboard.pinned";
/// Pinned entries are a short list of things you reuse, not a second history.
pub const MAX_PINNED: usize = 100;
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
            collections: vec![ITEMS.into(), PINNED.into()],
            settings: vec![
                // What you copy stays on the machine you copied it on.
                SettingSpec::new("clipboard.enabled", json!(true), Scope::Device, "Keep a history of copied text."),
                SettingSpec::new("clipboard.keep_days", json!(30), Scope::Synced, "Days an entry is kept (1–365)."),
                SettingSpec::new("clipboard.max_items", json!(500), Scope::Synced, "Most entries kept (10–5000); the oldest go first."),
                SettingSpec::new("clipboard.ignored_apps", json!(DEFAULT_IGNORED_APPS), Scope::Synced,
                                 "Bundle identifiers of apps whose copies are never kept."),
            ],
            commands: vec![
                CommandSpec::new("add", "Record a copy: {text, app?, bundle_id?} or {image: <uuid>.png, digest, width, height, app?, bundle_id?} → {record} (moved to the top if the same text or image is already kept), or {record: null, skipped} when it isn't kept."),
                CommandSpec::new("pin", "Keep an entry until it's unpinned: {id} → {record} in clipboard.pinned."),
                CommandSpec::new("unpin", "Put a pinned entry back at the top of the history: {id} → {record} in clipboard.items."),
                CommandSpec::new("prune", "Apply the retention settings now → {deleted}."),
            ],
        }
    }

    fn call(&self, core: &Core, command: &str, params: Value) -> Result<Value> {
        #[derive(Deserialize)]
        struct Add {
            #[serde(default)] text: String,
            image: Option<String>,
            #[serde(default)] digest: String,
            #[serde(default)] width: u32,
            #[serde(default)] height: u32,
            #[serde(default)] app: String,
            #[serde(default)] bundle_id: String,
        }
        #[derive(Deserialize)]
        struct Id { id: String }
        match command {
            "add" => {
                let p: Add = parse(params)?;
                let skipped = |why: &str| Ok(json!({ "record": null, "skipped": why }));
                if !core.setting::<bool>("clipboard.enabled")? { return skipped("off"); }
                if !p.bundle_id.is_empty() && core.setting::<Vec<String>>("clipboard.ignored_apps")?.contains(&p.bundle_id) {
                    return skipped("ignored_app");
                }
                let (data, search) = match &p.image {
                    Some(image) => {
                        if !crate::is_image_file_name(image) { return Err(NyError::invalid_params("A clipboard image is named <uuid>.png.")); }
                        if p.digest.is_empty() || p.digest.len() > 128 || p.width == 0 || p.height == 0 {
                            return Err(NyError::invalid_params("A clipboard image needs its digest and size."));
                        }
                        (json!({ "image": image, "digest": p.digest, "width": p.width, "height": p.height, "app": p.app }), String::new())
                    }
                    None => {
                        if p.text.trim().is_empty() { return skipped("empty"); }
                        if p.text.len() > MAX_TEXT_BYTES { return skipped("too_large"); }
                        (json!({ "text": p.text, "app": p.app }), p.text.clone())
                    }
                };
                // Something pinned is already at hand; the same thing copied again moves to the top
                // rather than appearing twice.
                if !same_as(core, PINNED, &data)?.is_empty() { return skipped("pinned"); }
                for id in same_as(core, ITEMS, &data)? { core.call("records.delete", json!({ "id": id }))?; }
                let key = lookup(&data);
                let record = core.insert_keyed_record(ITEMS, data, &search, &key)?;
                prune(core)?;
                Ok(json!({ "record": record }))
            }
            "pin" => {
                let p: Id = parse(params)?;
                let data = entry(core, &p.id, ITEMS)?;
                if core.count_records(PINNED)? >= MAX_PINNED {
                    return Err(NyError::invalid_params("Up to 100 entries can be pinned; unpin one first."));
                }
                let record = core.insert_keyed_record(PINNED, data.clone(), data["text"].as_str().unwrap_or_default(), &lookup(&data))?;
                core.call("records.delete", json!({ "id": p.id }))?;
                Ok(json!({ "record": record }))
            }
            "unpin" => {
                let p: Id = parse(params)?;
                let data = entry(core, &p.id, PINNED)?;
                let record = core.insert_keyed_record(ITEMS, data.clone(), data["text"].as_str().unwrap_or_default(), &lookup(&data))?;
                core.call("records.delete", json!({ "id": p.id }))?;
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

/// Ids in `collection` holding the same text, or an image with the same pixels — found through
/// an indexed content hash, then compared exactly.
fn same_as(core: &Core, collection: &str, data: &Value) -> Result<Vec<Value>> {
    let key = if data["text"].is_string() { "text" } else { "digest" };
    Ok(core.find_records(collection, &lookup(data))?.into_iter()
        .filter(|record| record.data[key] == data[key])
        .map(|record| json!(record.id)).collect())
}

/// The content hash an entry is filed under: FNV-1a of the text, or the image's own digest.
fn lookup(data: &Value) -> String {
    match data["text"].as_str() {
        Some(text) => {
            let hash = text.bytes().fold(0xcbf2_9ce4_8422_2325_u64, |hash, byte| (hash ^ u64::from(byte)).wrapping_mul(0x0100_0000_01b3));
            format!("t:{hash:016x}")
        }
        None => format!("i:{}", data["digest"].as_str().unwrap_or_default()),
    }
}

/// An entry's data, if `id` is in `collection`.
fn entry(core: &Core, id: &str, collection: &str) -> Result<Value> {
    let record = core.call("records.get", json!({ "id": id }))?;
    if record["collection"] != collection { return Err(NyError::not_found("That entry is no longer there.")); }
    Ok(record["data"].clone())
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

    fn texts_in(core: &Core, collection: &str) -> Vec<String> {
        let page = core.call("records.list", json!({ "collection": collection })).unwrap();
        page["records"].as_array().unwrap().iter()
            .map(|r| r["data"]["text"].as_str().or(r["data"]["digest"].as_str()).unwrap().to_string()).collect()
    }

    fn texts(core: &Core) -> Vec<String> { texts_in(core, ITEMS) }

    fn image(digest: &str) -> Value {
        json!({ "image": format!("{}.png", uuid::Uuid::new_v4()), "digest": digest, "width": 40, "height": 30, "app": "Preview" })
    }

    #[test]
    fn images_are_kept_and_recognized_when_copied_again() {
        let core = core();
        core.call("clipboard.add", image("aaa")).unwrap();
        core.call("clipboard.add", json!({ "text": "between" })).unwrap();
        let again = core.call("clipboard.add", image("aaa")).unwrap()["record"].clone();
        assert_eq!(texts(&core), ["aaa", "between"]);
        assert_eq!(again["data"]["width"], 40);
        let add = |params: Value| core.call("clipboard.add", params).unwrap_err().code;
        assert_eq!(add(json!({ "image": "../x.png", "digest": "d", "width": 1, "height": 1 })), "invalid_params");
        assert_eq!(add(json!({ "image": format!("{}.png", uuid::Uuid::new_v4()), "width": 1, "height": 1 })), "invalid_params");
    }

    #[test]
    fn pinned_entries_stay_out_of_the_history_and_its_pruning() {
        let core = core();
        let kept = core.call("clipboard.add", json!({ "text": "my address" })).unwrap()["record"].clone();
        let pinned = core.call("clipboard.pin", json!({ "id": kept["id"] })).unwrap()["record"].clone();
        assert_eq!((texts(&core).len(), texts_in(&core, PINNED)), (0, vec!["my address".to_string()]));
        // Copying it again doesn't add it to the history too.
        assert_eq!(core.call("clipboard.add", json!({ "text": "my address" })).unwrap()["skipped"], "pinned");
        core.call("settings.set", json!({ "key": "clipboard.max_items", "value": 10 })).unwrap();
        for n in 0..12 { core.call("clipboard.add", json!({ "text": format!("item {n}") })).unwrap(); }
        assert_eq!(texts_in(&core, PINNED).len(), 1);
        assert_eq!(core.call("clipboard.pin", json!({ "id": pinned["id"] })).unwrap_err().code, "not_found");
        core.call("clipboard.unpin", json!({ "id": pinned["id"] })).unwrap();
        assert_eq!((texts(&core)[0].as_str(), texts_in(&core, PINNED).len()), ("my address", 0));
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
