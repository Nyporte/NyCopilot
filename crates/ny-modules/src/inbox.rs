//! Inbox: catch a thought in a second — typed, selected in any app, or a screenshot — and deal
//! with it later. Notes wait in `inbox.notes`; marking one done moves it to `inbox.done`, where it
//! stays 30 days (so nothing is lost by accident) and can be moved back. Snoozing one moves it to
//! `inbox.snoozed` until a time you choose; `wake` brings due notes back to the top of the inbox.
//!
//! Each note remembers where it came from — the app, its window's title, and the page or document
//! address when there is one — so it can be traced back later. Screenshots are image files the client
//! keeps beside the database; a note records only the file's name, which must be a UUID with `.png`
//! (or `.gif`, for a recording), so a note can never point anywhere else.

use ny_core::{now_millis, parse, CommandSpec, Core, ListQuery, Manifest, Module, NyError, Result, Scope, SettingSpec, DAY_MILLIS};
use serde::Deserialize;
use serde_json::{json, Value};

pub const NOTES: &str = "inbox.notes";
pub const DONE: &str = "inbox.done";
pub const SNOOZED: &str = "inbox.snoozed";
pub const MAX_TEXT_BYTES: usize = 64 * 1024;
pub const SOURCES: &[&str] = &["typed", "selection", "screenshot"];
/// How long a done note can still be brought back.
pub const DONE_DAYS: i64 = 30;

/// `<uuid>.png` or `<uuid>.gif`, nothing else.
pub fn validate_image_name(name: &str) -> Result<()> {
    if crate::is_image_file_name(name) { Ok(()) } else { Err(NyError::invalid_params("An inbox image is named <uuid>.png or <uuid>.gif.")) }
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
            collections: vec![NOTES.into(), DONE.into(), SNOOZED.into()],
            settings: vec![
                // A folder on this Mac (an Obsidian vault, say) that notes are sent to as Markdown files.
                SettingSpec::new("inbox.markdown_folder", json!(""), Scope::Device, "Folder that notes are sent to as Markdown files."),
            ],
            commands: vec![
                CommandSpec::new("add", "Add a note: {text?, image?, app?, title?, url?, source?: typed|selection|screenshot, created? (ms)} → {record}; it needs text or an image. created keeps an earlier date, as when a deleted note is put back."),
                CommandSpec::new("update", "Change a note's text, waiting or done: {id, text} → {record}; everything else stays."),
                CommandSpec::new("done", "Mark a note done: {id} → {record} in inbox.done, kept 30 days."),
                CommandSpec::new("undone", "Bring a done note back: {id} → {record} in inbox.notes."),
                CommandSpec::new("snooze", "Put a waiting note away until a time: {id, until (ms)} → {record} in inbox.snoozed."),
                CommandSpec::new("wake", "Bring snoozed notes back to the top of the inbox: {id?} → {woken: [record]}; without an id, every one that's due."),
                CommandSpec::new("count", "Notes waiting → {count}."),
                CommandSpec::new("markdown", "A note as a Markdown file: {title, text, source?, url?, created (ms), stamp (local time, as the file name starts), image?: file name} → {stem, markdown}. The client makes the stem unique, names any image after it, and writes the files."),
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
            created: Option<i64>,
        }
        fn typed() -> String { "typed".into() }
        #[derive(Deserialize)]
        struct Update { id: String, text: String }
        #[derive(Deserialize)]
        struct Id { id: String }
        #[derive(Deserialize)]
        struct Snooze { id: String, until: i64 }
        #[derive(Deserialize)]
        struct Wake { id: Option<String> }
        match command {
            "add" => {
                let p: Add = parse(params)?;
                if let Some(image) = &p.image { validate_image_name(image)?; }
                validate_text(&p.text, p.image.is_some())?;
                if !SOURCES.contains(&p.source.as_str()) {
                    return Err(NyError::invalid_params("A note comes from typed, selection, or screenshot."));
                }
                if p.created.is_some_and(|created| created <= 0 || created > now_millis()) {
                    return Err(NyError::invalid_params("A note's date must be a time that has passed."));
                }
                let data = json!({ "text": p.text, "image": p.image, "app": line(&p.app, 100), "title": line(&p.title, 300),
                                   "url": line(&p.url, 2048), "source": p.source });
                // Like a note brought back from done: its own date, listed where it lands now.
                let record = core.insert_record(NOTES, data.clone(), &search_text(&data), p.created, None)?;
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
                if collection != NOTES { return Err(NyError::invalid_params("That note isn't waiting.")); }
                // Done notes are listed (and expire) by when they were done; the note keeps its own date.
                data["created"] = json!(data["created"].as_i64().unwrap_or(created));
                data["done_at"] = json!(now_millis());
                let record = core.move_record(&p.id, NOTES, DONE, data.clone(), &search_text(&data), None, None)?;
                prune(core)?;
                Ok(json!({ "record": record }))
            }
            "undone" => {
                let p: Id = parse(params)?;
                let (collection, mut data, _) = note(core, &p.id)?;
                if collection != DONE { return Err(NyError::invalid_params("That note is still waiting.")); }
                let created = data["created"].as_i64();
                if let Some(object) = data.as_object_mut() { object.remove("created"); object.remove("done_at"); }
                let record = core.move_record(&p.id, DONE, NOTES, data.clone(), &search_text(&data), created, None)?;
                Ok(json!({ "record": record }))
            }
            "snooze" => {
                let p: Snooze = parse(params)?;
                let (collection, mut data, created) = note(core, &p.id)?;
                if collection != NOTES { return Err(NyError::invalid_params("Only a waiting note can be snoozed.")); }
                if p.until <= now_millis() { return Err(NyError::invalid_params("Snooze until a time that's still to come.")); }
                data["created"] = json!(data["created"].as_i64().unwrap_or(created));
                data["until"] = json!(p.until);
                let record = core.move_record(&p.id, NOTES, SNOOZED, data.clone(), &search_text(&data), None, None)?;
                Ok(json!({ "record": record }))
            }
            "wake" => {
                let p: Wake = parse(params)?;
                let due: Vec<(String, Value)> = match p.id {
                    Some(id) => {
                        let (collection, data, _) = note(core, &id)?;
                        if collection != SNOOZED { return Err(NyError::invalid_params("That note isn't snoozed.")); }
                        vec![(id, data)]
                    }
                    None => {
                        let now = now_millis();
                        let mut due = Vec::new();
                        let mut query = ListQuery { limit: 500, ..Default::default() };
                        loop {
                            let page = core.list_records(SNOOZED, &query)?;
                            due.extend(page.records.into_iter().filter(|record| record.data["until"].as_i64().is_some_and(|until| until <= now))
                                .map(|record| (record.id, record.data)));
                            if page.next.is_none() { break; }
                            query.before = page.next;
                        }
                        due
                    }
                };
                let mut woken = Vec::new();
                for (id, mut data) in due {
                    if let Some(object) = data.as_object_mut() { object.remove("until"); }
                    // Back on top as if it had just arrived; `created` still says when it was first kept.
                    woken.push(core.move_record(&id, SNOOZED, NOTES, data.clone(), &search_text(&data), None, None)?);
                }
                Ok(json!({ "woken": woken }))
            }
            "count" => Ok(json!({ "count": core.count_records(NOTES)? })),
            "markdown" => {
                #[derive(Deserialize)]
                struct Markdown {
                    title: String,
                    text: String,
                    #[serde(default)] source: String,
                    #[serde(default)] url: String,
                    created: i64,
                    stamp: String,
                    image: Option<String>,
                }
                let p: Markdown = parse(params)?;
                Ok(json!({ "stem": markdown_stem(&p.stamp, &p.title),
                           "markdown": markdown(&p.text, &p.source, &p.url, p.created, p.image.as_deref()) }))
            }
            _ => Err(NyError::unknown_method(&format!("inbox.{command}"))),
        }
    }

    fn validate_setting(&self, key: &str, value: &Value) -> Result<()> {
        match key {
            "inbox.markdown_folder" if !value.as_str().is_some_and(|path| path.is_empty() || (path.starts_with('/') && path.len() <= 1024)) =>
                Err(NyError::invalid_setting("Choose a folder on this Mac.")),
            _ => Ok(()),
        }
    }
}

/// A note's collection, data, and creation time, from either list.
fn note(core: &Core, id: &str) -> Result<(String, Value, i64)> {
    let record = core.get_record(&[NOTES, DONE, SNOOZED], id)?.ok_or_else(|| NyError::not_found("That note no longer exists."))?;
    Ok((record.collection, record.data, record.created_at))
}

/// Searching finds a note by its text, app, title, or address.
fn search_text(data: &Value) -> String {
    ["text", "app", "title", "url"].iter().filter_map(|key| data[*key].as_str()).collect::<Vec<_>>().join("\n")
}

/// Done notes older than 30 days go for good.
fn prune(core: &Core) -> Result<usize> {
    core.prune_records(DONE, None, now_millis() - DONE_DAYS * DAY_MILLIS)
}

/// `<stamp> <title>`, with the characters file systems or note apps (Obsidian links: `#^[]`) treat
/// specially turned into spaces, and the title cut to 60 characters.
pub fn markdown_stem(stamp: &str, title: &str) -> String {
    let words = title.split(|c: char| crate::is_unsafe_in_file_name(c) || "#^[]".contains(c))
        .filter(|word| !word.trim().is_empty()).map(str::trim).collect::<Vec<_>>().join(" ");
    let words: String = words.chars().take(60).collect();
    format!("{} {}", line(stamp, 40), words.trim()).trim().to_string()
}

/// Front matter for where the note came from, then its text, then the image beside it if any.
pub fn markdown(text: &str, source: &str, url: &str, created: i64, image: Option<&str>) -> String {
    let mut lines = vec!["---".to_string(), format!("created: {}", iso8601(created))];
    if !source.trim().is_empty() { lines.push(format!("source: \"{}\"", line(source, 300).replace('"', "'"))); }
    if !url.trim().is_empty() { lines.push(format!("url: {}", line(url, 2048))); }
    lines.extend(["tags: [inbox]", "---", ""].map(String::from));
    lines.push(text.trim().to_string());
    if let Some(image) = image { lines.extend([String::new(), format!("![]({})", path_encoded(image))]); }
    lines.join("\n") + "\n"
}

/// Unix milliseconds as `2026-11-03T03:30:00Z`.
fn iso8601(millis: i64) -> String {
    let seconds = millis.div_euclid(1000);
    let (days, rest) = (seconds.div_euclid(86_400), seconds.rem_euclid(86_400));
    // Days to a civil date (Howard Hinnant's algorithm).
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = yoe + era * 400 + i64::from(month <= 2);
    format!("{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}Z", rest / 3600, rest / 60 % 60, rest % 60)
}

/// A file name as a Markdown link target: spaces and anything outside a URL path escaped.
fn path_encoded(name: &str) -> String {
    name.bytes().map(|byte| match byte {
        b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' | b'!' | b'$' | b'&' | b'\'' | b'(' | b')' | b'*'
        | b'+' | b',' | b';' | b'=' | b':' | b'@' | b'/' => (byte as char).to_string(),
        _ => format!("%{byte:02X}"),
    }).collect()
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
    fn notes_become_markdown_files() {
        assert_eq!(markdown_stem("2026-11-03 1130", "Read: the [design] doc #3 / v2\nand more"), "2026-11-03 1130 Read the design doc 3 v2 and more");
        let text = markdown("  Body\n", "Safari — \"Docs\"", "https://example.com/a", 1_793_712_600_000, Some("2026 note.png"));
        assert_eq!(text, "---\ncreated: 2026-11-03T13:30:00Z\nsource: \"Safari — 'Docs'\"\nurl: https://example.com/a\ntags: [inbox]\n---\n\nBody\n\n![](2026%20note.png)\n");
        assert_eq!(iso8601(0), "1970-01-01T00:00:00Z");
        assert_eq!(iso8601(951_782_400_000), "2000-02-29T00:00:00Z");
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
    fn snoozed_notes_come_back_on_top_when_due() {
        let core = core();
        let early = core.call("inbox.add", json!({ "text": "call the bank" })).unwrap()["record"].clone();
        core.call("inbox.add", json!({ "text": "later one" })).unwrap();
        let later = now_millis() + 60_000;
        let snoozed = core.call("inbox.snooze", json!({ "id": early["id"], "until": later })).unwrap()["record"].clone();
        assert_eq!((list(&core, NOTES).len(), list(&core, SNOOZED).len()), (1, 1));
        assert_eq!(snoozed["data"]["created"], early["created_at"]);
        assert_eq!(core.call("inbox.count", json!({})).unwrap()["count"], 1);
        // Not due yet: nothing comes back on its own.
        assert!(core.call("inbox.wake", json!({})).unwrap()["woken"].as_array().unwrap().is_empty());
        assert_eq!(core.call("inbox.snooze", json!({ "id": snoozed["id"], "until": later })).unwrap_err().code, "invalid_params");
        let woken = core.call("inbox.wake", json!({ "id": snoozed["id"] })).unwrap()["woken"][0].clone();
        assert_eq!(list(&core, NOTES)[0]["data"]["text"], "call the bank");
        assert_eq!((woken["data"]["created"].clone(), woken["data"].get("until")), (early["created_at"].clone(), None));
        // Done after waking keeps the date it was first kept.
        let done = core.call("inbox.done", json!({ "id": woken["id"] })).unwrap()["record"].clone();
        assert_eq!(done["data"]["created"], early["created_at"]);
        let past = core.call("inbox.add", json!({ "text": "x" })).unwrap()["record"]["id"].clone();
        assert_eq!(core.call("inbox.snooze", json!({ "id": past, "until": 1 })).unwrap_err().code, "invalid_params");
    }

    #[test]
    fn a_deleted_note_comes_back_with_its_date() {
        let core = core();
        let note = core.call("inbox.add", json!({ "text": "the original" })).unwrap()["record"].clone();
        core.call("records.delete", json!({ "id": note["id"] })).unwrap();
        let back = core.call("inbox.add", json!({ "text": "the original", "created": note["created_at"] })).unwrap()["record"].clone();
        assert_eq!((back["created_at"].clone(), list(&core, NOTES).len()), (note["created_at"].clone(), 1));
        // Done and undone again, it keeps that date.
        let done = core.call("inbox.done", json!({ "id": back["id"] })).unwrap()["record"].clone();
        assert_eq!(done["data"]["created"], note["created_at"]);
        for bad in [json!(0), json!(-5), json!(now_millis() + 60_000)] {
            assert_eq!(core.call("inbox.add", json!({ "text": "x", "created": bad })).unwrap_err().code, "invalid_params", "{bad}");
        }
    }

    #[test]
    fn every_due_note_wakes_however_many_there_are() {
        let core = core();
        for n in 0..520 { core.insert_record(SNOOZED, json!({ "text": format!("n{n}"), "until": 1 }), "", None, None).unwrap(); }
        core.insert_record(SNOOZED, json!({ "text": "later", "until": now_millis() + 60_000 }), "", None, None).unwrap();
        let woken = core.call("inbox.wake", json!({})).unwrap()["woken"].as_array().unwrap().len();
        assert_eq!((woken, core.count_records(NOTES).unwrap(), core.count_records(SNOOZED).unwrap()), (520, 520, 1));
    }

    #[test]
    fn bad_notes_are_refused() {
        let core = core();
        let add = |params: Value| core.call("inbox.add", params).unwrap_err().code;
        assert_eq!(add(json!({ "text": "  " })), "empty_input");
        assert_eq!(add(json!({ "image": "../../etc/passwd" })), "invalid_params");
        assert_eq!(add(json!({ "image": "photo.png" })), "invalid_params");
        assert_eq!(add(json!({ "image": format!("{}.jpg", uuid::Uuid::new_v4()) })), "invalid_params");
        core.call("inbox.add", json!({ "image": format!("{}.gif", uuid::Uuid::new_v4()), "source": "screenshot" })).unwrap();
        assert_eq!(add(json!({ "text": "x", "source": "email" })), "invalid_params");
        assert_eq!(add(json!({ "text": "x".repeat(MAX_TEXT_BYTES + 1) })), "input_too_large");
        // Another module's record can't be reached through the inbox.
        let other = core.call("clipboard.add", json!({ "text": "copied" })).unwrap()["record"]["id"].clone();
        assert_eq!(core.call("inbox.update", json!({ "id": other, "text": "x" })).unwrap_err().code, "not_found");
        assert_eq!(core.call("inbox.done", json!({ "id": other })).unwrap_err().code, "not_found");
    }
}
