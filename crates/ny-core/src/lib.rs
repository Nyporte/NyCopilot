//! The NyCopilot foundation: everything a client needs that is not user interface.
//!
//! * [`Store`] keeps module data as **records** in one SQLite file. Every record has a time-ordered
//!   UUIDv7 id, an origin device, and a monotonically increasing revision, and deletions leave
//!   tombstones, so a future sync server only has to exchange "changes since revision N".
//! * **Settings** are typed JSON values declared by modules, with defaults and a scope: `synced`
//!   values follow the user across devices, `device` values stay on this machine.
//! * [`Module`]s plug in features (Translate today; Clipboard, Screenshot, Windows, Chat, Kanban
//!   later). Each declares a [`Manifest`] and answers `"<module>.<command>"` method calls.
//! * [`Core::call`] is the single entry point. The C ABI, every native client, and a future network
//!   server all speak the same JSON method protocol documented in `spec/`.

mod core;
mod error;
mod module;
mod store;

pub use crate::core::{parse, Core, EventSink, RequestGuard};
pub use error::{NyError, Result};
pub use module::{CommandSpec, Manifest, Module, Scope, SettingSpec};
pub use store::{now_millis, ListQuery, Page, Record, Store};
