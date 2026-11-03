//! Platform-neutral logic for NyCopilot's feature modules.
//!
//! A module here owns its data model, settings, and model prompts. Everything that touches the
//! operating system — overlays, global shortcuts, reading the focused field, pasting, screen
//! capture, window control — stays in each native client, which calls these modules through the
//! core's method protocol. Planned modules (Clipboard, Chat, Kanban) follow the same pattern; see
//! `spec/modules.md`.

use std::sync::Arc;

use ny_core::Module;

pub mod ask;
pub mod capture;
pub mod clipboard;
pub mod clock;
pub mod google;
pub mod inbox;
pub mod menubar;
pub mod mouse;
pub mod translate;
pub mod volcengine;
pub mod windows;

/// An image file a client keeps beside the database is named `<uuid>.png` (or `.gif`, for a
/// recording), nothing else, so a record can never point anywhere else on disk.
pub fn is_image_file_name(name: &str) -> bool {
    let stem = name.strip_suffix(".png").or_else(|| name.strip_suffix(".gif")).unwrap_or_default();
    stem.len() == 36 && uuid::Uuid::parse_str(stem).is_ok()
}

/// Every module this build ships, in menu order. The `llm` module comes first because others use it.
pub fn all() -> Vec<Arc<dyn Module>> {
    vec![Arc::new(ny_llm::LlmModule), Arc::new(translate::TranslateModule), Arc::new(windows::WindowsModule), Arc::new(capture::CaptureModule),
         Arc::new(clipboard::ClipboardModule), Arc::new(inbox::InboxModule), Arc::new(ask::AskModule), Arc::new(mouse::MouseModule),
         Arc::new(clock::ClockModule), Arc::new(menubar::MenuBarModule)]
}

/// The loopback HTTP stand-in shared with `ny-llm`'s tests.
#[cfg(test)]
pub(crate) use ny_llm::stand_in;
