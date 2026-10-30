//! Inbox: catch a thought in a second — typed, selected in any app, or a screenshot — and deal
//! with it later. Notes wait in `inbox.notes`; marking one done moves it to `inbox.done`, where it
//! stays 30 days (so nothing is lost by accident) and can be moved back.
//!
//! Each note remembers where it came from — the app, its window's title, and the page or document
//! address when there is one — so it can be traced back later. Screenshots are image files the client
//! keeps beside the database; a note records only the file's name, which must be a UUID with `.png`,
//! so a note can never point anywhere else.

use ny_core::{now_millis, parse, CommandSpec, Core, Manifest, Module, NyError, Result};
use serde::Deserialize;
use serde_json::{json, Value};

pub const NOTES: &str = "inbox.notes";
pub const DONE: &str = "inbox.done";
pub const MAX_TEXT_BYTES: usize = 64 * 1024;
pub const SOURCES: &[&str] = &["typed", "selection", "screenshot"];
/// How long a done note can still be brought back.
pub const DONE_DAYS: i64 = 30;
const DAY_MILLIS: i64 = 24 * 60 * 60 * 1000;

/// `<uuid>.png`, nothing else.
pub fn validate_image_name(name: &str) -> Result<()> {
    if crate::is_image_file_name(name) { Ok(()) } else { Err(NyError::invalid_params("An inbox image is named <uuid>.png.")) }
}

/// One line, at most `limit` characters: window titles and addresses are context, not content.
fn line(text: &str, limit: usize) -> String {
    text.chars().filter(|c| !c.is_control()).take(limit).collect::<String>().trim().to_string()
}

pub struct InboxModule;

impl Module for InboxModule {
    fn manifest(&self) -> Manifest {
        Manifest {
            id: "inbox".into(),
            name: "Inbox".into(),
            summary: "Catch a thought in a second; deal with it later.".into(),
            capabilities: vec!["hotkey".into(), "text.capture".into(), "window.overlay".into()],
            collections: vec![NOTES.into(), DONE.into()],
            settings: vec![],
            commands: vec![
                CommandSpec::new("add", "Add a note: {text?, image?, app?, title?, url?, source?: typed|selection|screenshot} → {record}; it needs text or an image."),
                CommandSpec::new("update", "Change a note's text, waiting or done: {id, text} → {record}; everything else stays."),
                CommandSpec::new("done", "Mark a note done: {id} → {record} in inbox.done, kept 30 days."),
                CommandSpec::new("undone", "Bring a done note back: {id} → {record} in inbox.notes."),
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
            #[serde(default)] title: String,
            #[serde(default)] url: String,
            #[serde(default = "typed")] source: String,
        }
        fn typed() -> String { "typed".into() }
        #[derive(Deserialize)]
        struct Update { id: String, text: String }
        #[derive(Deserialize)]
        struct Id { id: String }
        match command {
            "add" => {
                let p: Add = parse(params)?;
                if let Some(image) = &p.image { validate_image_name(image)?; }
                validate_text(&p.text, p.image.is_some())?;
                if !SOURCES.contains(&p.source.as_str()) {
                    return Err(NyError::invalid_params("A note comes from typed, selection, or screenshot."));
                }
                let data = json!({ "text": p.text, "image": p.image, "app": line(&p.app, 100), "title": line(&p.title, 300),
                                   "url": line(&p.url, 2048), "source": p.source });
                let record = core.insert_record(NOTES, data.clone(), &search_text(&data), None)?;
                prune(core)?;
                Ok(json!({ "record": record }))
            }
            "update" => {
                let p: Update = parse(params)?;
                let (collection, mut data, _) = note(core, &p.id)?;
                validate_text(&p.text, data["image"].is_string())?;
                data["text"] = json!(p.text);
                Ok(json!({ "record": core.update_record(&collection, &p.id, data.clone(), &search_text(&data))? }))
            }
            "done" => {
                let p: Id = parse(params)?;
                let (collection, mut data, created) = note(core, &p.id)?;
                if collection != NOTES { return Err(NyError::invalid_params("That note is already done.")); }
                // Done notes are listed (and expire) by when they were done; the note keeps its own date.
                data["created"] = json!(created);
                data["done_at"] = json!(now_millis());
                let record = core.insert_record(DONE, data.clone(), &search_text(&data), None)?;
                core.call("records.delete", json!({ "id": p.id }))?;
                prune(core)?;
                Ok(json!({ "record": record }))
            }
            "undone" => {
                let p: Id = parse(params)?;
                let (collection, mut data, _) = note(core, &p.id)?;
                if collection != DONE { return Err(NyError::invalid_params("That note is still waiting.")); }
                let created = data["created"].as_i64();
                if let Some(object) = data.as_object_mut() { object.remove("created"); object.remove("done_at"); }
                let record = core.insert_record(NOTES, data.clone(), &search_text(&data), created)?;
                core.call("records.delete", json!({ "id": p.id }))?;
                Ok(json!({ "record": record }))
            }
            "count" => Ok(json!({ "count": core.count_records(NOTES)? })),
            _ => Err(NyError::unknown_method(&format!("inbox.{command}"))),
        }
    }

    fn validate_setting(&self, _key: &str, _value: &Value) -> Result<()> { Ok(()) }
}

/// A note's collection, data, and creation time, from either list.
fn note(core: &Core, id: &str) -> Result<(String, Value, i64)> {
    let record = core.call("records.get", json!({ "id": id }))?;
    let collection = record["collection"].as_str().unwrap_or_default().to_string();
    if collection != NOTES && collection != DONE { return Err(NyError::not_found("That note no longer exists.")); }
    Ok((collection, record["data"].clone(), record["created_at"].as_i64().unwrap_or_else(now_millis)))
}

/// Searching finds a note by its text, app, title, or address.
fn search_text(data: &Value) -> String {
    ["text", "app", "title", "url"].iter().filter_map(|key| data[*key].as_str()).collect::<Vec<_>>().join("\n")
}

/// Done notes older than 30 days go for good.
fn prune(core: &Core) -> Result<usize> {
    core.prune_records(DONE, usize::MAX >> 1, now_millis() - DONE_DAYS * DAY_MILLIS)
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

    fn list(core: &Core, collection: &str) -> Vec<Value> {
        core.call("records.list", json!({ "collection": collection })).unwrap()["records"].as_array().unwrap().clone()
    }

    #[test]
    fn notes_keep_their_source_and_can_be_edited_and_found() {
        let core = core();
        let note = core.call("inbox.add", json!({ "text": "ask Lin about Q3", "app": "Safari", "title": "Q3 planning\ndoc",
                                                  "url": "https://docs.example.com/q3" })).unwrap()["record"].clone();
        assert_eq!((note["data"]["title"].clone(), note["data"]["url"].clone()), (json!("Q3 planningdoc"), json!("https://docs.example.com/q3")));
        core.call("inbox.add", json!({ "image": format!("{}.png", uuid::Uuid::new_v4()), "source": "screenshot" })).unwrap();
        core.call("inbox.add", json!({ "text": "選取的文字", "source": "selection", "app": "WeChat" })).unwrap();
        assert_eq!(core.call("inbox.count", json!({})).unwrap()["count"], 3);

        let edited = core.call("inbox.update", json!({ "id": note["id"], "text": "ask Lin about Q3 at 3" })).unwrap()["record"].clone();
        assert_eq!((edited["id"].clone(), edited["created_at"].clone(), edited["data"]["app"].clone()),
                   (note["id"].clone(), note["created_at"].clone(), json!("Safari")));
        for query in ["Lin about", "docs.example.com", "planning"] {
            let found = core.call("records.list", json!({ "collection": NOTES, "search": query })).unwrap();
            assert_eq!(found["records"].as_array().unwrap().len(), 1, "{query}");
        }
    }

    #[test]
    fn done_notes_move_aside_and_can_come_back() {
        let core = core();
        let note = core.call("inbox.add", json!({ "text": "renew the domain" })).unwrap()["record"].clone();
        let done = core.call("inbox.done", json!({ "id": note["id"] })).unwrap()["record"].clone();
        assert_eq!((list(&core, NOTES).len(), list(&core, DONE).len()), (0, 1));
        assert_eq!(done["data"]["created"], note["created_at"]);
        assert!(done["data"]["done_at"].is_i64());
        assert_eq!(core.call("inbox.count", json!({})).unwrap()["count"], 0);
        assert_eq!(core.call("inbox.done", json!({ "id": done["id"] })).unwrap_err().code, "invalid_params");
        // Edited while done, then back with its original date.
        core.call("inbox.update", json!({ "id": done["id"], "text": "renew the domain (paid)" })).unwrap();
        let back = core.call("inbox.undone", json!({ "id": done["id"] })).unwrap()["record"].clone();
        assert_eq!((back["created_at"].clone(), back["data"]["text"].clone()), (note["created_at"].clone(), json!("renew the domain (paid)")));
        assert!(back["data"].get("done_at").is_none());
        assert_eq!((list(&core, NOTES).len(), list(&core, DONE).len()), (1, 0));
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
        // Another module's record can't be reached through the inbox.
        let other = core.call("clipboard.add", json!({ "text": "copied" })).unwrap()["record"]["id"].clone();
        assert_eq!(core.call("inbox.update", json!({ "id": other, "text": "x" })).unwrap_err().code, "not_found");
        assert_eq!(core.call("inbox.done", json!({ "id": other })).unwrap_err().code, "not_found");
    }
}
