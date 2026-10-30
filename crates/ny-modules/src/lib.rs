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
pub mod clipboard;
pub mod google;
pub mod inbox;
pub mod translate;
pub mod volcengine;
pub mod windows;

/// An image file a client keeps beside the database is named `<uuid>.png`, nothing else, so a
/// record can never point anywhere else on disk.
pub fn is_image_file_name(name: &str) -> bool {
    let stem = name.strip_suffix(".png").unwrap_or_default();
    stem.len() == 36 && uuid::Uuid::parse_str(stem).is_ok()
}

/// Every module this build ships, in menu order. The `llm` module comes first because others use it.
pub fn all() -> Vec<Arc<dyn Module>> {
    vec![Arc::new(ny_llm::LlmModule), Arc::new(translate::TranslateModule), Arc::new(windows::WindowsModule), Arc::new(capture::CaptureModule),
         Arc::new(clipboard::ClipboardModule), Arc::new(inbox::InboxModule)]
}

/// A loopback stand-in for the HTTP services modules call: each connection gets the next canned
/// response, and every request is logged for the test to inspect.
#[cfg(test)]
pub(crate) mod stand_in {
    use std::io::{Read, Write};
    use std::net::TcpListener;
    use std::sync::{Arc, Mutex};
    use std::thread;

    pub(crate) fn serve(responses: Vec<String>) -> (String, Arc<Mutex<Vec<String>>>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let base = format!("http://127.0.0.1:{}", listener.local_addr().unwrap().port());
        let log = Arc::new(Mutex::new(Vec::new()));
        let requests = log.clone();
        thread::spawn(move || {
            for (stream, response) in listener.incoming().zip(responses) {
                let Ok(mut stream) = stream else { break };
                // Read the whole request (headers and declared body) before replying; answering
                // early can reset the connection while the client is still sending.
                let mut buffer = Vec::new();
                let mut chunk = [0u8; 65536];
                while let Ok(count) = stream.read(&mut chunk) {
                    if count == 0 { break; }
                    buffer.extend_from_slice(&chunk[..count]);
                    let text = String::from_utf8_lossy(&buffer).to_string();
                    if let Some(split) = text.find("\r\n\r\n") {
                        let needed = text[..split].lines().find_map(|l| l.to_lowercase().strip_prefix("content-length:")
                            .map(|v| v.trim().parse::<usize>().unwrap_or(0))).unwrap_or(0);
                        if buffer.len() >= split + 4 + needed { break; }
                    }
                }
                requests.lock().unwrap().push(String::from_utf8_lossy(&buffer).to_string());
                let _ = stream.write_all(response.as_bytes());
            }
        });
        (base, log)
    }

    pub(crate) fn http(status: &str, headers: &str, body: &str) -> String {
        format!("HTTP/1.1 {status}\r\nContent-Length: {}\r\n{headers}Connection: close\r\n\r\n{body}", body.len())
    }

    /// A Chat Completions reply carrying `content`.
    pub(crate) fn model_reply(content: &str) -> String {
        http("200 OK", "", &serde_json::json!({ "choices": [{ "message": { "content": content }, "finish_reason": "stop" }] }).to_string())
    }
}
