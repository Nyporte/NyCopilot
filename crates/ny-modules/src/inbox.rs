//! Inbox: catch a thought in a second — typed, selected in any app, or a screenshot — and deal
//! with it later. A note stays until it's handled (deleted).
//!
//! Screenshots are image files the client keeps beside the database; a note records only the
//! file's name, which must be a UUID with `.png`, so a note can never point anywhere else.

use ny_core::{parse, CommandSpec, Core, Manifest, Module, NyError, Result};
use serde::Deserialize;
use serde_json::{json, Value};

pub const NOTES: &str = "inbox.notes";
pub const MAX_TEXT_BYTES: usize = 64 * 1024;
pub const SOURCES: &[&str] = &["typed", "selection", "screenshot"];

/// `<uuid>.png`, nothing else.
pub fn validate_image_name(name: &str) -> Result<()> {
    let stem = name.strip_suffix(".png").unwrap_or_default();
    if uuid::Uuid::parse_str(stem).is_ok() && stem.len() == 36 { Ok(()) }
    else { Err(NyError::invalid_params("An inbox image is named <uuid>.png.")) }
}

pub struct InboxModule;

impl Module for InboxModule {
    fn manifest(&self) -> Manifest {
        Manifest {
            id: "inbox".into(),
            name: "Inbox".into(),
            summary: "Catch a thought in a second; deal with it later.".into(),
            capabilities: vec!["hotkey".into(), "text.capture".into(), "window.overlay".into()],
            collections: vec![NOTES.into()],
            settings: vec![],
            commands: vec![
                CommandSpec::new("add", "Add a note: {text?, image?, app?, source?: typed|selection|screenshot} → {record}; it needs text or an image."),
                CommandSpec::new("update", "Change a note's text: {id, text} → {record}; its image, app, and source stay."),
                CommandSpec::new("count", "Notes waiting → {count}."),
            ],
        }
    }

    fn call(&self, core: &Core, command: &str, params: Value) -> Result<Value> {
        #[derive(Deserialize)]
        struct Add {
            #[serde(default)] text: String,
            image: Option<String>,
            #[serde(default)] app: String,
            #[serde(default = "typed")] source: String,
        }
        fn typed() -> String { "typed".into() }
        #[derive(Deserialize)]
        struct Update { id: String, text: String }
        match command {
            "add" => {
                let p: Add = parse(params)?;
                if let Some(image) = &p.image { validate_image_name(image)?; }
                validate_text(&p.text, p.image.is_some())?;
                if !SOURCES.contains(&p.source.as_str()) {
                    return Err(NyError::invalid_params("A note comes from typed, selection, or screenshot."));
                }
                let data = json!({ "text": p.text, "image": p.image, "app": p.app, "source": p.source });
                let record = core.insert_record(NOTES, data, &format!("{}\n{}", p.text, p.app), None)?;
                Ok(json!({ "record": record }))
            }
            "update" => {
                let p: Update = parse(params)?;
                let existing = core.call("records.get", json!({ "id": p.id }))?;
                if existing["collection"] != NOTES { return Err(NyError::not_found("That note no longer exists.")); }
                let mut data = existing["data"].clone();
                validate_text(&p.text, data["image"].is_string())?;
                data["text"] = json!(p.text);
                let search = format!("{}\n{}", p.text, data["app"].as_str().unwrap_or_default());
                Ok(json!({ "record": core.update_record(NOTES, &p.id, data, &search)? }))
            }
            "count" => Ok(json!({ "count": core.count_records(NOTES)? })),
            _ => Err(NyError::unknown_method(&format!("inbox.{command}"))),
        }
    }

    fn validate_setting(&self, _key: &str, _value: &Value) -> Result<()> { Ok(()) }
}

/// Some text, unless there's an image; never more than 64 KB.
fn validate_text(text: &str, has_image: bool) -> Result<()> {
    if text.trim().is_empty() && !has_image { return Err(NyError::new("empty_input", "Type something first.")); }
    if text.len() > MAX_TEXT_BYTES { return Err(NyError::new("input_too_large", "A note can hold up to 64 KB of text.")); }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use ny_core::Store;

    fn core() -> Core { Core::new(Store::open_in_memory().unwrap(), crate::all(), "test", Box::new(|_| {})).unwrap() }

    #[test]
    fn notes_are_added_edited_counted_and_handled() {
        let core = core();
        let typed = core.call("inbox.add", json!({ "text": "call the bank", "app": "Notes" })).unwrap()["record"].clone();
        let image = format!("{}.png", uuid::Uuid::new_v4());
        core.call("inbox.add", json!({ "image": image, "source": "screenshot" })).unwrap();
        core.call("inbox.add", json!({ "text": "選取的文字", "source": "selection", "app": "Safari" })).unwrap();
        assert_eq!(core.call("inbox.count", json!({})).unwrap()["count"], 3);

        let edited = core.call("inbox.update", json!({ "id": typed["id"], "text": "call the bank at 3" })).unwrap()["record"].clone();
        assert_eq!((edited["id"].clone(), edited["data"]["text"].clone(), edited["data"]["app"].clone()),
                   (typed["id"].clone(), json!("call the bank at 3"), json!("Notes")));
        assert_eq!(edited["created_at"], typed["created_at"]);
        let found = core.call("records.list", json!({ "collection": NOTES, "search": "bank at" })).unwrap();
        assert_eq!(found["records"].as_array().unwrap().len(), 1);

        core.call("records.delete", json!({ "id": typed["id"] })).unwrap();
        assert_eq!(core.call("inbox.count", json!({})).unwrap()["count"], 2);
        assert_eq!(core.call("inbox.update", json!({ "id": typed["id"], "text": "x" })).unwrap_err().code, "not_found");
    }

    #[test]
    fn bad_notes_are_refused() {
        let core = core();
        let add = |params: Value| core.call("inbox.add", params).unwrap_err().code;
        assert_eq!(add(json!({ "text": "  " })), "empty_input");
        assert_eq!(add(json!({ "image": "../../etc/passwd" })), "invalid_params");
        assert_eq!(add(json!({ "image": "photo.png" })), "invalid_params");
        assert_eq!(add(json!({ "text": "x", "source": "email" })), "invalid_params");
        assert_eq!(add(json!({ "text": "x".repeat(MAX_TEXT_BYTES + 1) })), "input_too_large");
        // Another module's record can't be edited through the inbox.
        let other = core.call("clipboard.add", json!({ "text": "copied" })).unwrap()["record"]["id"].clone();
        assert_eq!(core.call("inbox.update", json!({ "id": other, "text": "x" })).unwrap_err().code, "not_found");
    }
}
