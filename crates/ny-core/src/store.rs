use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

use rusqlite::{params, Connection, OptionalExtension, Transaction};
use serde::Serialize;
use serde_json::Value;
use uuid::Uuid;

use crate::{NyError, Result, Scope};

/// One piece of module data. `data` is module-defined JSON; everything else is managed here.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Record {
    /// UUIDv7: unique across devices and sortable by creation time.
    pub id: String,
    /// `"<module>.<name>"`, e.g. `translate.history`.
    pub collection: String,
    pub data: Value,
    /// Unix milliseconds.
    pub created_at: i64,
    pub updated_at: i64,
    /// Deleted records remain as content-free tombstones so deletions can propagate.
    pub deleted: bool,
    /// The device that made the latest change.
    pub origin: String,
    /// Local change counter; `changes_since(rev)` is the sync primitive.
    pub rev: i64,
}

#[derive(Debug, Clone, Default)]
pub struct ListQuery {
    /// Exclusive cursor: return records older than this id.
    pub before: Option<String>,
    pub limit: usize,
    /// Case-insensitive substring over the module-supplied search text.
    pub search: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct Page {
    pub records: Vec<Record>,
    /// Pass back as `before` for the next page; absent on the last page.
    pub next: Option<String>,
}

pub fn now_millis() -> i64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as i64).unwrap_or(0)
}

/// The local database. One file per user profile holds every module's records and all settings.
pub struct Store {
    conn: Connection,
    device: String,
}

const MIGRATIONS: &[&str] = &[
    // 1: records, settings, and store metadata.
    "CREATE TABLE records (
        id TEXT PRIMARY KEY,
        collection TEXT NOT NULL,
        data TEXT NOT NULL,
        search TEXT NOT NULL DEFAULT '',
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        deleted INTEGER NOT NULL DEFAULT 0,
        origin TEXT NOT NULL,
        rev INTEGER NOT NULL
     );
     CREATE INDEX records_by_collection ON records (collection, deleted, id DESC);
     CREATE INDEX records_by_rev ON records (rev);
     CREATE TABLE settings (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL,
        scope TEXT NOT NULL,
        updated_at INTEGER NOT NULL,
        origin TEXT NOT NULL,
        rev INTEGER NOT NULL
     );
     CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);",
    // 2: a lookup key a module can set (a content hash) to find a record without scanning.
    "ALTER TABLE records ADD COLUMN lookup TEXT;
     CREATE INDEX records_by_lookup ON records (collection, lookup) WHERE lookup IS NOT NULL AND deleted = 0;",
];

impl Store {
    /// Open or create the database with private permissions (directory 0700, file 0600 on Unix).
    pub fn open(path: &Path) -> Result<Self> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
            restrict(parent, 0o700);
        }
        let conn = Connection::open(path)?;
        restrict(path, 0o600);
        Self::prepare(conn)
    }

    /// For tests and ephemeral servers.
    pub fn open_in_memory() -> Result<Self> { Self::prepare(Connection::open_in_memory()?) }

    fn prepare(mut conn: Connection) -> Result<Self> {
        conn.busy_timeout(std::time::Duration::from_millis(500))?;
        conn.pragma_update(None, "journal_mode", "WAL")?;
        conn.pragma_update(None, "foreign_keys", true)?;
        let version: usize = conn.pragma_query_value(None, "user_version", |row| row.get(0))?;
        if version > MIGRATIONS.len() {
            return Err(NyError::new("storage", "This database was created by a newer version of NyCopilot."));
        }
        for (index, sql) in MIGRATIONS.iter().enumerate().skip(version) {
            let tx = conn.transaction()?;
            tx.execute_batch(sql)?;
            tx.pragma_update(None, "user_version", index + 1)?;
            tx.commit()?;
        }
        let device = match conn.query_row("SELECT value FROM meta WHERE key = 'device_id'", [], |r| r.get(0)).optional()? {
            Some(id) => id,
            None => {
                let id = Uuid::new_v4().to_string();
                conn.execute("INSERT INTO meta (key, value) VALUES ('device_id', ?1)", [&id])?;
                id
            }
        };
        Ok(Self { conn, device })
    }

    pub fn device_id(&self) -> &str { &self.device }

    /// Highest revision written so far; a sync client stores this as its cursor.
    pub fn revision(&self) -> Result<i64> {
        Ok(self.conn.query_row("SELECT COALESCE(CAST(value AS INTEGER), 0) FROM meta WHERE key = 'rev'", [], |r| r.get(0))
            .optional()?.unwrap_or(0))
    }

    fn next_rev(tx: &Transaction) -> Result<i64> {
        let current: i64 = tx.query_row("SELECT COALESCE((SELECT CAST(value AS INTEGER) FROM meta WHERE key = 'rev'), 0)", [], |r| r.get(0))?;
        tx.execute("INSERT INTO meta (key, value) VALUES ('rev', ?1) ON CONFLICT(key) DO UPDATE SET value = ?1", [current + 1])?;
        Ok(current + 1)
    }

    /// `created_at` may be supplied when importing older data; ids still sort by import time.
    pub fn insert(&mut self, collection: &str, data: Value, search: &str, created_at: Option<i64>) -> Result<Record> {
        self.insert_keyed(collection, data, search, created_at, None)
    }

    /// `insert`, with a lookup key (see `find`).
    pub fn insert_keyed(&mut self, collection: &str, data: Value, search: &str, created_at: Option<i64>, lookup: Option<&str>) -> Result<Record> {
        let now = now_millis();
        let tx = self.conn.transaction()?;
        let rev = Self::next_rev(&tx)?;
        let record = Record {
            id: Uuid::now_v7().to_string(),
            collection: collection.into(),
            data,
            created_at: created_at.unwrap_or(now),
            updated_at: now,
            deleted: false,
            origin: self.device.clone(),
            rev,
        };
        tx.execute(
            "INSERT INTO records (id, collection, data, search, created_at, updated_at, deleted, origin, rev, lookup)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, 0, ?7, ?8, ?9)",
            params![record.id, record.collection, record.data.to_string(), search, record.created_at, record.updated_at, record.origin, rev, lookup],
        )?;
        tx.commit()?;
        Ok(record)
    }

    /// Live records in `collection` with this lookup key, through its index.
    pub fn find(&self, collection: &str, lookup: &str) -> Result<Vec<Record>> {
        let mut statement = self.conn.prepare(&format!(
            "SELECT {COLUMNS} FROM records WHERE collection = ?1 AND lookup = ?2 AND deleted = 0"))?;
        let rows = statement.query_map(params![collection, lookup], row_to_record)?;
        Ok(rows.collect::<std::result::Result<Vec<_>, _>>()?)
    }

    /// Removes deletion markers last changed before `before` — kept only for a sync that doesn't
    /// exist yet — and folds the write-ahead log back into the database. → markers removed.
    pub fn compact(&mut self, before: i64) -> Result<usize> {
        let removed = self.conn.execute("DELETE FROM records WHERE deleted = 1 AND updated_at < ?1", [before])?;
        self.conn.query_row("PRAGMA wal_checkpoint(TRUNCATE)", [], |_| Ok(()))?;
        Ok(removed)
    }

    pub fn get(&self, id: &str) -> Result<Option<Record>> {
        Ok(self.conn.query_row(&format!("SELECT {COLUMNS} FROM records WHERE id = ?1 AND deleted = 0"), [id], row_to_record).optional()?)
    }

    /// Newest first. Search is a literal substring match (LIKE wildcards are escaped).
    pub fn list(&self, collection: &str, query: &ListQuery) -> Result<Page> {
        let limit = query.limit.clamp(1, 500);
        let search = query.search.as_deref().map(str::trim).filter(|s| !s.is_empty())
            .map(|s| format!("%{}%", s.replace('\\', "\\\\").replace('%', "\\%").replace('_', "\\_")));
        let mut statement = self.conn.prepare(&format!(
            "SELECT {COLUMNS} FROM records
             WHERE collection = ?1 AND deleted = 0 AND (?2 IS NULL OR id < ?2) AND (?3 IS NULL OR search LIKE ?3 ESCAPE '\\')
             ORDER BY id DESC LIMIT ?4"))?;
        let mut records = statement
            .query_map(params![collection, query.before, search, (limit + 1) as i64], row_to_record)?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        let next = if records.len() > limit { records.truncate(limit); records.last().map(|r| r.id.clone()) } else { None };
        Ok(Page { records, next })
    }

    /// Replace content with a tombstone: the text is gone immediately, the deletion can still sync.
    /// Returns the collection the record belonged to, or `None` if there was nothing to delete.
    pub fn delete(&mut self, id: &str) -> Result<Option<String>> {
        let tx = self.conn.transaction()?;
        let rev = Self::next_rev(&tx)?;
        let collection: Option<String> = tx.query_row(
            "UPDATE records SET deleted = 1, data = 'null', search = '', lookup = NULL, updated_at = ?2, origin = ?3, rev = ?4
             WHERE id = ?1 AND deleted = 0 RETURNING collection",
            params![id, now_millis(), self.device, rev], |r| r.get(0)).optional()?;
        // A delete that changed nothing must not advance the revision a sync client reads.
        if collection.is_some() { tx.commit()?; }
        Ok(collection)
    }

    pub fn clear(&mut self, collection: &str) -> Result<usize> {
        let tx = self.conn.transaction()?;
        let rev = Self::next_rev(&tx)?;
        let changed = tx.execute(
            "UPDATE records SET deleted = 1, data = 'null', search = '', updated_at = ?2, origin = ?3, rev = ?4
             WHERE collection = ?1 AND deleted = 0",
            params![collection, now_millis(), self.device, rev],
        )?;
        if changed > 0 { tx.commit()?; }
        Ok(changed)
    }

    /// Replace a live record's data and search text; its id and creation time stay. Returns the
    /// updated record, or `None` if there is none (or it was deleted).
    pub fn update(&mut self, id: &str, data: Value, search: &str) -> Result<Option<Record>> {
        let tx = self.conn.transaction()?;
        let rev = Self::next_rev(&tx)?;
        let changed = tx.execute(
            "UPDATE records SET data = ?2, search = ?3, updated_at = ?4, origin = ?5, rev = ?6 WHERE id = ?1 AND deleted = 0",
            params![id, data.to_string(), search, now_millis(), self.device, rev],
        )?;
        if changed == 0 { return Ok(None); }
        tx.commit()?;
        self.get(id)
    }

    /// How many live records `collection` holds.
    pub fn count(&self, collection: &str) -> Result<usize> {
        let count: i64 = self.conn.query_row("SELECT COUNT(*) FROM records WHERE collection = ?1 AND deleted = 0", [collection], |r| r.get(0))?;
        Ok(count as usize)
    }

    /// Tombstone every record in `collection` beyond the newest `keep`, and any created before
    /// `before` (milliseconds); for collections with a retention policy. Returns how many went.
    pub fn prune(&mut self, collection: &str, keep: usize, before: i64) -> Result<usize> {
        let tx = self.conn.transaction()?;
        let rev = Self::next_rev(&tx)?;
        let changed = tx.execute(
            "UPDATE records SET deleted = 1, data = 'null', search = '', updated_at = ?3, origin = ?4, rev = ?5
             WHERE collection = ?1 AND deleted = 0 AND (created_at < ?2 OR id NOT IN (
                 SELECT id FROM records WHERE collection = ?1 AND deleted = 0 ORDER BY id DESC LIMIT ?6))",
            params![collection, before, now_millis(), self.device, rev, keep as i64],
        )?;
        if changed > 0 { tx.commit()?; }
        Ok(changed)
    }

    /// Every record (including tombstones) changed after `rev`, oldest change first.
    pub fn changes_since(&self, rev: i64, limit: usize) -> Result<Vec<Record>> {
        let mut statement = self.conn.prepare(&format!("SELECT {COLUMNS} FROM records WHERE rev > ?1 ORDER BY rev LIMIT ?2"))?;
        let records = statement.query_map(params![rev, limit.clamp(1, 1000) as i64], row_to_record)?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        Ok(records)
    }

    pub fn setting(&self, key: &str) -> Result<Option<Value>> {
        let raw: Option<String> = self.conn.query_row("SELECT value FROM settings WHERE key = ?1", [key], |r| r.get(0)).optional()?;
        Ok(raw.and_then(|text| serde_json::from_str(&text).ok()))
    }

    pub fn set_setting(&mut self, key: &str, value: &Value, scope: Scope) -> Result<()> {
        let tx = self.conn.transaction()?;
        let rev = Self::next_rev(&tx)?;
        tx.execute(
            "INSERT INTO settings (key, value, scope, updated_at, origin, rev) VALUES (?1, ?2, ?3, ?4, ?5, ?6)
             ON CONFLICT(key) DO UPDATE SET value = ?2, scope = ?3, updated_at = ?4, origin = ?5, rev = ?6",
            params![key, value.to_string(), scope.as_str(), now_millis(), self.device, rev],
        )?;
        tx.commit()?;
        Ok(())
    }

    pub fn remove_setting(&mut self, key: &str) -> Result<()> {
        self.conn.execute("DELETE FROM settings WHERE key = ?1", [key])?;
        Ok(())
    }

    /// Stored values whose key starts with `prefix`.
    pub fn settings_with_prefix(&self, prefix: &str) -> Result<Vec<(String, Value)>> {
        let mut statement = self.conn.prepare("SELECT key, value FROM settings WHERE substr(key, 1, length(?1)) = ?1 ORDER BY key")?;
        let rows = statement.query_map([prefix], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))?;
        let mut result = Vec::new();
        for row in rows {
            let (key, raw) = row?;
            if let Ok(value) = serde_json::from_str(&raw) { result.push((key, value)); }
        }
        Ok(result)
    }
}

const COLUMNS: &str = "id, collection, data, created_at, updated_at, deleted, origin, rev";

fn row_to_record(row: &rusqlite::Row) -> rusqlite::Result<Record> {
    let raw: String = row.get(2)?;
    Ok(Record {
        id: row.get(0)?,
        collection: row.get(1)?,
        data: serde_json::from_str(&raw).unwrap_or(Value::Null),
        created_at: row.get(3)?,
        updated_at: row.get(4)?,
        deleted: row.get::<_, i64>(5)? != 0,
        origin: row.get(6)?,
        rev: row.get(7)?,
    })
}

#[cfg(unix)]
fn restrict(path: &Path, mode: u32) {
    use std::os::unix::fs::PermissionsExt;
    let _ = std::fs::set_permissions(path, std::fs::Permissions::from_mode(mode));
}

#[cfg(not(unix))]
fn restrict(_: &Path, _: u32) {}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn lookup_keys_find_records_and_compact_drops_old_tombstones() {
        let mut store = Store::open_in_memory().unwrap();
        let kept = store.insert_keyed("t.items", json!({ "n": 1 }), "", None, Some("h1")).unwrap();
        store.insert_keyed("t.items", json!({ "n": 2 }), "", None, Some("h2")).unwrap();
        store.insert_keyed("t.other", json!({ "n": 3 }), "", None, Some("h1")).unwrap();
        assert_eq!(store.find("t.items", "h1").unwrap().iter().map(|r| r.id.clone()).collect::<Vec<_>>(), vec![kept.id.clone()]);
        store.delete(&kept.id).unwrap();
        assert!(store.find("t.items", "h1").unwrap().is_empty());
        // A fresh tombstone stays; one older than the cutoff goes.
        assert_eq!(store.compact(now_millis() - 60_000).unwrap(), 0);
        assert_eq!(store.compact(now_millis() + 60_000).unwrap(), 1);
        assert!(store.get(&kept.id).unwrap().is_none());
    }

    #[test]
    fn records_round_trip_newest_first_with_cursor() {
        let mut store = Store::open_in_memory().unwrap();
        let ids: Vec<String> = (0..5).map(|i| store.insert("t.items", json!({ "n": i }), &format!("item {i}"), None).unwrap().id).collect();
        let first = store.list("t.items", &ListQuery { limit: 2, ..Default::default() }).unwrap();
        assert_eq!(first.records.iter().map(|r| r.id.clone()).collect::<Vec<_>>(), vec![ids[4].clone(), ids[3].clone()]);
        let rest = store.list("t.items", &ListQuery { limit: 10, before: first.next.clone(), ..Default::default() }).unwrap();
        assert_eq!(rest.records.len(), 3);
        assert!(rest.next.is_none());
        assert_eq!(store.get(&ids[0]).unwrap().unwrap().data, json!({ "n": 0 }));
    }

    #[test]
    fn search_is_literal_and_case_insensitive() {
        let mut store = Store::open_in_memory().unwrap();
        store.insert("t.items", json!(1), "The Meeting is at 10", None).unwrap();
        let percent = store.insert("t.items", json!(2), "Up 50% today", None).unwrap();
        let found = store.list("t.items", &ListQuery { limit: 10, search: Some("meeting".into()), ..Default::default() }).unwrap();
        assert_eq!(found.records.len(), 1);
        let literal = store.list("t.items", &ListQuery { limit: 10, search: Some("%".into()), ..Default::default() }).unwrap();
        assert_eq!(literal.records.iter().map(|r| &r.id).collect::<Vec<_>>(), vec![&percent.id]);
    }

    #[test]
    fn deletes_leave_content_free_tombstones_for_sync() {
        let mut store = Store::open_in_memory().unwrap();
        let a = store.insert("t.items", json!("secret"), "secret", None).unwrap();
        store.insert("t.items", json!("other"), "other", None).unwrap();
        let before = store.revision().unwrap();
        assert_eq!(store.delete(&a.id).unwrap().as_deref(), Some("t.items"));
        let after = store.revision().unwrap();
        // Deleting again (or clearing an empty collection) changes nothing, so the revision stays.
        assert_eq!(store.delete(&a.id).unwrap(), None);
        assert_eq!(store.clear("t.empty").unwrap(), 0);
        assert_eq!(store.revision().unwrap(), after);
        assert!(store.get(&a.id).unwrap().is_none());
        let changes = store.changes_since(before, 100).unwrap();
        assert_eq!(changes.len(), 1);
        assert!(changes[0].deleted);
        assert_eq!(changes[0].data, Value::Null);
        assert_eq!(store.clear("t.items").unwrap(), 1);
        assert!(store.list("t.items", &ListQuery { limit: 10, ..Default::default() }).unwrap().records.is_empty());
    }

    #[test]
    fn exact_text_and_permissions_survive_reopening() {
        let dir = std::env::temp_dir().join(format!("ny-store-{}", Uuid::new_v4()));
        let path = dir.join("nycopilot.db");
        let text = "  English café 👩🏽‍💻\n'quotes' \"SQL\"\0tail\n";
        let id = {
            let mut store = Store::open(&path).unwrap();
            store.set_setting("x.y", &json!("value"), Scope::Synced).unwrap();
            store.insert("t.items", json!({ "text": text }), text, Some(42)).unwrap().id
        };
        let store = Store::open(&path).unwrap();
        let record = store.get(&id).unwrap().unwrap();
        assert_eq!(record.data["text"], json!(text));
        assert_eq!(record.created_at, 42);
        assert_eq!(store.setting("x.y").unwrap(), Some(json!("value")));
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(std::fs::metadata(&path).unwrap().permissions().mode() & 0o777, 0o600);
        }
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn device_id_is_stable_and_revisions_increase() {
        let mut store = Store::open_in_memory().unwrap();
        let device = store.device_id().to_string();
        let a = store.insert("t.items", json!(1), "", None).unwrap();
        let b = store.insert("t.items", json!(2), "", None).unwrap();
        assert!(b.rev > a.rev);
        assert_eq!(a.origin, device);
    }
}
