use std::collections::HashMap;
use std::sync::{Arc, Mutex, MutexGuard};

use serde::de::DeserializeOwned;
use serde::Deserialize;
use serde_json::{json, Value};

use crate::{now_millis, ListQuery, Manifest, Module, NyError, Page, Record, Result, Scope, SettingSpec, Store, DAY_MILLIS};

/// Receives JSON events such as `{"type":"records.changed",...}`. Called on the calling thread;
/// clients hop to their UI thread themselves.
pub type EventSink = Box<dyn Fn(Value) + Send + Sync>;

/// Client-owned settings (shortcuts, window state, onboarding flags) need no manifest entry.
const CLIENT_PREFIX: &str = "client.";

/// The single entry point shared by every client and the future server.
///
/// `Core` is `Sync`: calls may arrive from any thread. The database lock is held only for the
/// duration of a store operation, never across network requests.
pub struct Core {
    store: Mutex<Store>,
    modules: Vec<Arc<dyn Module>>,
    manifests: Vec<Manifest>,
    settings: HashMap<String, (SettingSpec, usize)>,
    events: EventSink,
    platform: String,
    /// In-flight cancellable requests; `true` once the client asked to cancel.
    requests: Mutex<HashMap<String, bool>>,
}

/// Tracks one long-running call. Work that cannot be interrupted (a network request) checks
/// `is_cancelled()` before committing results, so a cancelled request never leaves data behind.
pub struct RequestGuard<'a> {
    core: &'a Core,
    id: Option<String>,
}

impl RequestGuard<'_> {
    pub fn is_cancelled(&self) -> bool {
        self.id.as_ref().is_some_and(|id| self.core.requests.lock().map(|r| r.get(id) == Some(&true)).unwrap_or(false))
    }

    pub fn check(&self) -> Result<()> {
        if self.is_cancelled() { Err(NyError::new("cancelled", "Cancelled.")) } else { Ok(()) }
    }
}

impl Drop for RequestGuard<'_> {
    fn drop(&mut self) {
        if let (Some(id), Ok(mut requests)) = (&self.id, self.core.requests.lock()) { requests.remove(id); }
    }
}

impl Core {
    pub fn new(store: Store, modules: Vec<Arc<dyn Module>>, platform: &str, events: EventSink) -> Result<Self> {
        let manifests: Vec<Manifest> = modules.iter().map(|m| m.manifest()).collect();
        let mut settings = HashMap::new();
        for (index, manifest) in manifests.iter().enumerate() {
            if manifests[..index].iter().any(|m| m.id == manifest.id) || ["core", "settings", "records", "client"].contains(&manifest.id.as_str()) {
                return Err(NyError::new("invalid_module", format!("Module id “{}” is reserved or duplicated.", manifest.id)));
            }
            for spec in &manifest.settings {
                debug_assert!(spec.key.starts_with(&format!("{}.", manifest.id)), "setting {} outside its module", spec.key);
                settings.insert(spec.key.clone(), (spec.clone(), index));
            }
        }
        Ok(Self { store: Mutex::new(store), modules, manifests, settings, events, platform: platform.into(), requests: Mutex::new(HashMap::new()) })
    }

    /// Dispatch one JSON method call. Built-in namespaces are `core`, `settings`, and `records`;
    /// everything else is routed to the module whose id prefixes the method.
    pub fn call(&self, method: &str, params: Value) -> Result<Value> {
        let params = if params.is_null() { json!({}) } else { params };
        let (namespace, command) = method.split_once('.').ok_or_else(|| NyError::unknown_method(method))?;
        match namespace {
            "core" => self.call_core(command, params),
            "settings" => self.call_settings(command, params),
            "records" => self.call_records(command, params),
            _ => {
                let index = self.manifests.iter().position(|m| m.id == namespace).ok_or_else(|| NyError::unknown_method(method))?;
                self.modules[index].call(self, command, params)
            }
        }
    }

    fn call_core(&self, command: &str, params: Value) -> Result<Value> {
        #[derive(Deserialize)]
        struct Cancel { request_id: String }
        match command {
            "cancel" => {
                let p: Cancel = parse(params)?;
                let mut requests = self.requests.lock().unwrap_or_else(|e| e.into_inner());
                let known = requests.get_mut(&p.request_id).map(|flag| *flag = true).is_some();
                Ok(json!({ "cancelled": known }))
            }
            "info" => {
                let store = self.store()?;
                Ok(json!({
                    "version": env!("CARGO_PKG_VERSION"),
                    "platform": self.platform,
                    "device_id": store.device_id(),
                    "revision": store.revision()?,
                    "modules": self.manifests.iter().map(|m| &m.id).collect::<Vec<_>>(),
                }))
            }
            "modules" => Ok(serde_json::to_value(&self.manifests)?),
            // Deletion markers older than 30 days go, and the log is folded in; at launch and quit.
            "compact" => {
                let removed = self.store()?.compact(now_millis() - 30 * DAY_MILLIS)?;
                Ok(json!({ "removed": removed }))
            }
            _ => Err(NyError::unknown_method(&format!("core.{command}"))),
        }
    }

    fn call_settings(&self, command: &str, params: Value) -> Result<Value> {
        #[derive(Deserialize)]
        struct Key { key: String }
        #[derive(Deserialize)]
        struct Set { key: String, value: Value }
        #[derive(Deserialize)]
        struct Prefix { #[serde(default)] prefix: String }
        match command {
            "get" => { let p: Key = parse(params)?; self.setting_value(&p.key) }
            "set" => { let p: Set = parse(params)?; self.set_setting(&p.key, p.value)?; Ok(json!({})) }
            "reset" => {
                let p: Key = parse(params)?;
                self.spec_scope(&p.key)?;
                self.store()?.remove_setting(&p.key)?;
                self.emit(json!({ "type": "settings.changed", "key": p.key }));
                Ok(json!({}))
            }
            "list" => {
                let p: Prefix = parse(params)?;
                let mut values = serde_json::Map::new();
                for (key, (spec, _)) in &self.settings {
                    if key.starts_with(&p.prefix) { values.insert(key.clone(), spec.default.clone()); }
                }
                for (key, value) in self.store()?.settings_with_prefix(&p.prefix)? { values.insert(key, value); }
                Ok(Value::Object(values))
            }
            _ => Err(NyError::unknown_method(&format!("settings.{command}"))),
        }
    }

    fn call_records(&self, command: &str, params: Value) -> Result<Value> {
        #[derive(Deserialize)]
        struct List { collection: String, before: Option<String>, #[serde(default = "default_limit")] limit: usize, search: Option<String> }
        #[derive(Deserialize)]
        struct Id { id: String }
        #[derive(Deserialize)]
        struct Collection { collection: String }
        #[derive(Deserialize)]
        struct Changes { #[serde(default)] since: i64, #[serde(default = "default_limit")] limit: usize }
        fn default_limit() -> usize { 100 }
        match command {
            "list" => {
                let p: List = parse(params)?;
                Ok(serde_json::to_value(self.list_records(&p.collection, &ListQuery { before: p.before, limit: p.limit, search: p.search })?)?)
            }
            "get" => {
                let p: Id = parse(params)?;
                let record = self.store()?.get(&p.id)?.ok_or_else(|| NyError::not_found("That item no longer exists."))?;
                Ok(serde_json::to_value(record)?)
            }
            "delete" => {
                let p: Id = parse(params)?;
                let collection = self.store()?.delete(&p.id)?;
                if let Some(collection) = &collection {
                    self.emit(json!({ "type": "records.changed", "collection": collection, "id": p.id, "change": "deleted" }));
                }
                Ok(json!({ "deleted": collection.is_some() }))
            }
            "clear" => {
                let p: Collection = parse(params)?;
                self.declared_collection(&p.collection)?;
                let count = self.store()?.clear(&p.collection)?;
                if count > 0 { self.emit(json!({ "type": "records.changed", "collection": p.collection, "change": "cleared" })); }
                Ok(json!({ "deleted": count }))
            }
            "changes" => {
                let p: Changes = parse(params)?;
                let store = self.store()?;
                Ok(json!({ "records": store.changes_since(p.since, p.limit)?, "revision": store.revision()? }))
            }
            _ => Err(NyError::unknown_method(&format!("records.{command}"))),
        }
    }

    // MARK: Services for modules

    /// Register a cancellable request. Clients pass `request_id` with long calls and may later
    /// call `core.cancel`. Without an id the request simply cannot be cancelled.
    pub fn begin_request(&self, id: Option<String>) -> RequestGuard<'_> {
        if let Some(id) = &id { self.requests.lock().unwrap_or_else(|e| e.into_inner()).insert(id.clone(), false); }
        RequestGuard { core: self, id }
    }

    /// The stored value, or the manifest default.
    pub fn setting_value(&self, key: &str) -> Result<Value> {
        let default = match self.settings.get(key) {
            Some((spec, _)) => spec.default.clone(),
            None if key.starts_with(CLIENT_PREFIX) => Value::Null,
            None => return Err(NyError::invalid_setting(format!("Unknown setting “{key}”."))),
        };
        Ok(self.store()?.setting(key)?.unwrap_or(default))
    }

    pub fn setting<T: DeserializeOwned>(&self, key: &str) -> Result<T> {
        serde_json::from_value(self.setting_value(key)?)
            .map_err(|_| NyError::invalid_setting(format!("Setting “{key}” has an unexpected type.")))
    }

    pub fn set_setting(&self, key: &str, value: Value) -> Result<()> {
        let scope = self.spec_scope(key)?;
        if let Some((spec, index)) = self.settings.get(key) {
            if std::mem::discriminant(&spec.default) != std::mem::discriminant(&value) {
                return Err(NyError::invalid_setting(format!("Setting “{key}” has the wrong type.")));
            }
            self.modules[*index].validate_setting(key, &value)?;
        }
        self.store()?.set_setting(key, &value, scope)?;
        self.emit(json!({ "type": "settings.changed", "key": key }));
        Ok(())
    }

    fn spec_scope(&self, key: &str) -> Result<Scope> {
        match self.settings.get(key) {
            Some((spec, _)) => Ok(spec.scope),
            None if key.starts_with(CLIENT_PREFIX) && key.len() > CLIENT_PREFIX.len() => Ok(Scope::Device),
            None => Err(NyError::invalid_setting(format!("Unknown setting “{key}”."))),
        }
    }

    // Record services check only that some module declares the collection: the core doesn't know
    // which module is calling, so each module keeps to its own collections.

    /// Insert a record into a declared collection and notify listeners. `created_at` keeps an older
    /// date (an import, a note brought back); `lookup` files it under a key for `find_records`.
    pub fn insert_record(&self, collection: &str, data: Value, search: &str, created_at: Option<i64>, lookup: Option<&str>) -> Result<Record> {
        self.declared_collection(collection)?;
        let record = self.store()?.insert(collection, data, search, created_at, lookup)?;
        self.emit(json!({ "type": "records.changed", "collection": collection, "id": record.id, "change": "inserted" }));
        Ok(record)
    }

    /// A live record, if it is in one of `collections` (each declared).
    pub fn get_record(&self, collections: &[&str], id: &str) -> Result<Option<Record>> {
        for collection in collections { self.declared_collection(collection)?; }
        Ok(self.store()?.get(id)?.filter(|record| collections.contains(&record.collection.as_str())))
    }

    /// A page of a declared collection, newest first (see `Store::list`).
    pub fn list_records(&self, collection: &str, query: &ListQuery) -> Result<Page> {
        self.declared_collection(collection)?;
        self.store()?.list(collection, query)
    }

    /// Tombstone a record if it is in `collection` (declared) and notify listeners → whether it was.
    pub fn delete_record(&self, collection: &str, id: &str) -> Result<bool> {
        self.declared_collection(collection)?;
        let mut store = self.store()?;
        if store.get(id)?.is_none_or(|record| record.collection != collection) { return Ok(false); }
        let deleted = store.delete(id)?.is_some();
        drop(store);
        if deleted { self.emit(json!({ "type": "records.changed", "collection": collection, "id": id, "change": "deleted" })); }
        Ok(deleted)
    }

    /// Move a record from one declared collection to another as new data, in one transaction (see
    /// `Store::move_record`), and notify listeners as an insert and a delete. `not_found` if `id`
    /// isn't live in `from`.
    #[allow(clippy::too_many_arguments)]
    pub fn move_record(&self, id: &str, from: &str, to: &str, data: Value, search: &str, created_at: Option<i64>, lookup: Option<&str>) -> Result<Record> {
        self.declared_collection(from)?;
        self.declared_collection(to)?;
        let record = self.store()?.move_record(id, from, to, data, search, created_at, lookup)?
            .ok_or_else(|| NyError::not_found("That item no longer exists."))?;
        self.emit(json!({ "type": "records.changed", "collection": to, "id": record.id, "change": "inserted" }));
        self.emit(json!({ "type": "records.changed", "collection": from, "id": id, "change": "deleted" }));
        Ok(record)
    }

    /// Live records in a declared collection under a lookup key.
    pub fn find_records(&self, collection: &str, lookup: &str) -> Result<Vec<Record>> {
        self.declared_collection(collection)?;
        self.store()?.find(collection, lookup)
    }

    /// Replace the data of a record in `collection` (declared) and notify listeners.
    pub fn update_record(&self, collection: &str, id: &str, data: Value, search: &str) -> Result<Record> {
        self.declared_collection(collection)?;
        let mut store = self.store()?;
        match store.get(id)? {
            Some(existing) if existing.collection == collection => {}
            _ => return Err(NyError::not_found("That item no longer exists.")),
        }
        let record = store.update(id, data, search)?.ok_or_else(|| NyError::not_found("That item no longer exists."))?;
        drop(store);
        self.emit(json!({ "type": "records.changed", "collection": collection, "id": id, "change": "updated" }));
        Ok(record)
    }

    /// How many live records a declared collection holds.
    pub fn count_records(&self, collection: &str) -> Result<usize> {
        self.declared_collection(collection)?;
        self.store()?.count(collection)
    }

    /// Apply a collection's retention policy (see `Store::prune`) and notify listeners.
    pub fn prune_records(&self, collection: &str, keep: Option<usize>, before: i64) -> Result<usize> {
        self.declared_collection(collection)?;
        let count = self.store()?.prune(collection, keep, before)?;
        if count > 0 { self.emit(json!({ "type": "records.changed", "collection": collection, "change": "pruned" })); }
        Ok(count)
    }

    pub fn emit(&self, event: Value) { (self.events)(event); }

    /// Some module's manifest lists `collection`.
    fn declared_collection(&self, collection: &str) -> Result<()> {
        if self.manifests.iter().any(|m| m.collections.iter().any(|c| c == collection)) { Ok(()) }
        else { Err(NyError::invalid_params(format!("Unknown collection “{collection}”."))) }
    }

    fn store(&self) -> Result<MutexGuard<'_, Store>> {
        // A panic while holding the lock cannot leave SQLite inconsistent (transactions roll back).
        Ok(self.store.lock().unwrap_or_else(|poisoned| poisoned.into_inner()))
    }
}

/// Decode method parameters with a uniform error.
pub fn parse<T: DeserializeOwned>(params: Value) -> Result<T> { Ok(serde_json::from_value(params)?) }

#[cfg(test)]
mod tests {
    use super::*;
    use crate::CommandSpec;
    use std::sync::atomic::{AtomicUsize, Ordering};

    struct Notes;
    impl Module for Notes {
        fn manifest(&self) -> Manifest {
            Manifest {
                id: "notes".into(), name: "Notes".into(), summary: "Test module".into(), capabilities: vec![],
                collections: vec!["notes.items".into(), "notes.archive".into()],
                settings: vec![SettingSpec::new("notes.font_size", json!(13), Scope::Synced, "Size").range((1.0, 72.0))],
                commands: vec![CommandSpec::new("add", "Add a note")],
            }
        }
        fn call(&self, core: &Core, command: &str, params: Value) -> Result<Value> {
            match command {
                "add" => Ok(serde_json::to_value(core.insert_record("notes.items", params.clone(), params["text"].as_str().unwrap_or(""), None, None)?)?),
                _ => Err(NyError::unknown_method(command)),
            }
        }
        fn validate_setting(&self, _: &str, value: &Value) -> Result<()> {
            if value.as_i64().unwrap_or(0) > 0 { Ok(()) } else { Err(NyError::invalid_setting("Must be positive.")) }
        }
    }

    fn core(counter: Arc<AtomicUsize>) -> Core {
        Core::new(Store::open_in_memory().unwrap(), vec![Arc::new(Notes)], "test",
                  Box::new(move |_| { counter.fetch_add(1, Ordering::SeqCst); })).unwrap()
    }

    #[test]
    fn routes_methods_and_validates_settings() {
        let events = Arc::new(AtomicUsize::new(0));
        let core = core(events.clone());
        assert_eq!(core.call("settings.get", json!({ "key": "notes.font_size" })).unwrap(), json!(13));
        assert_eq!(core.call("settings.set", json!({ "key": "notes.font_size", "value": -1 })).unwrap_err().code, "invalid_setting");
        assert_eq!(core.call("settings.set", json!({ "key": "notes.font_size", "value": "big" })).unwrap_err().code, "invalid_setting");
        core.call("settings.set", json!({ "key": "notes.font_size", "value": 15 })).unwrap();
        assert_eq!(core.setting::<i64>("notes.font_size").unwrap(), 15);
        core.call("settings.set", json!({ "key": "client.hotkey.x", "value": "17:2304" })).unwrap();
        assert_eq!(core.call("settings.list", json!({ "prefix": "client." })).unwrap(), json!({ "client.hotkey.x": "17:2304" }));
        assert_eq!(core.call("settings.set", json!({ "key": "other.thing", "value": 1 })).unwrap_err().code, "invalid_setting");

        let note = core.call("notes.add", json!({ "text": "hello" })).unwrap();
        let page = core.call("records.list", json!({ "collection": "notes.items" })).unwrap();
        assert_eq!(page["records"][0]["id"], note["id"]);
        assert_eq!(core.call("records.list", json!({ "collection": "secrets.items" })).unwrap_err().code, "invalid_params");
        assert_eq!(core.call("nope.add", json!({})).unwrap_err().code, "unknown_method");
        assert_eq!(core.call("records.delete", json!({ "id": note["id"] })).unwrap(), json!({ "deleted": true }));
        assert_eq!(events.load(Ordering::SeqCst), 4);
        assert_eq!(core.call("core.modules", Value::Null).unwrap()[0]["id"], "notes");
        let setting = &core.call("core.modules", Value::Null).unwrap()[0]["settings"][0];
        assert_eq!((setting["min"].clone(), setting["max"].clone()), (json!(1.0), json!(72.0)));
    }

    #[test]
    fn cancellation_is_scoped_to_live_requests() {
        let core = core(Arc::new(AtomicUsize::new(0)));
        assert_eq!(core.call("core.cancel", json!({ "request_id": "a" })).unwrap(), json!({ "cancelled": false }));
        let guard = core.begin_request(Some("a".into()));
        assert!(guard.check().is_ok());
        assert_eq!(core.call("core.cancel", json!({ "request_id": "a" })).unwrap(), json!({ "cancelled": true }));
        assert_eq!(guard.check().unwrap_err().code, "cancelled");
        drop(guard);
        assert_eq!(core.call("core.cancel", json!({ "request_id": "a" })).unwrap(), json!({ "cancelled": false }));
    }

    #[test]
    fn moves_are_announced_as_an_insert_and_a_delete() {
        let events = Arc::new(Mutex::new(Vec::new()));
        let sink = events.clone();
        let core = Core::new(Store::open_in_memory().unwrap(), vec![Arc::new(Notes)], "test", Box::new(move |e| sink.lock().unwrap().push(e))).unwrap();
        let note = core.insert_record("notes.items", json!({ "text": "x" }), "x", None, None).unwrap();
        assert!(core.get_record(&["notes.archive"], &note.id).unwrap().is_none());
        assert_eq!(core.get_record(&["notes.items", "notes.archive"], &note.id).unwrap().unwrap().id, note.id);
        assert_eq!(core.get_record(&["secrets.items"], &note.id).unwrap_err().code, "invalid_params");
        assert!(!core.delete_record("notes.archive", &note.id).unwrap());
        events.lock().unwrap().clear();
        let moved = core.move_record(&note.id, "notes.items", "notes.archive", json!({ "text": "x" }), "x", Some(5), None).unwrap();
        assert_eq!((moved.collection.as_str(), moved.created_at), ("notes.archive", 5));
        let changes: Vec<(Value, Value, Value)> = events.lock().unwrap().iter().map(|e| (e["collection"].clone(), e["id"].clone(), e["change"].clone())).collect();
        assert_eq!(changes, vec![(json!("notes.archive"), json!(moved.id), json!("inserted")), (json!("notes.items"), json!(note.id), json!("deleted"))]);
        // The old record is gone, so moving it again finds nothing.
        assert_eq!(core.move_record(&note.id, "notes.items", "notes.archive", json!({}), "", None, None).unwrap_err().code, "not_found");
        assert_eq!(core.list_records("notes.archive", &ListQuery { limit: 10, ..Default::default() }).unwrap().records.len(), 1);
        assert!(core.delete_record("notes.archive", &moved.id).unwrap());
    }
}
