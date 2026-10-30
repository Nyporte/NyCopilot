//! Platform-neutral logic for NyCopilot's feature modules.
//!
//! A module here owns its data model, settings, and model prompts. Everything that touches the
//! operating system — overlays, global shortcuts, reading the focused field, pasting, screen
//! capture, window control — stays in each native client, which calls these modules through the
//! core's method protocol. Planned modules (Clipboard, Chat, Kanban) follow the same pattern; see
//! `spec/modules.md`.

use std::sync::Arc;

use ny_core::Module;

pub mod capture;
pub mod google;
pub mod translate;
pub mod volcengine;
pub mod windows;

/// Every module this build ships, in menu order. The `llm` module comes first because others use it.
pub fn all() -> Vec<Arc<dyn Module>> {
    vec![Arc::new(ny_llm::LlmModule), Arc::new(translate::TranslateModule), Arc::new(windows::WindowsModule), Arc::new(capture::CaptureModule)]
}
