//! Ask AI: explain, summarize, or rewrite what you just selected or captured, or ask anything about
//! it, then follow up. It's the copilot's action layer over the other modules' things — a selection,
//! a screenshot, an inbox note — rather than a separate chat.
//!
//! The client sends the thing (text, and for a screenshot the PNG plus its recognized text), the
//! action, and the conversation so far; nothing is stored here. A screenshot goes to the model as an
//! image when `ask.send_images` is on (the model must accept images); otherwise only its text does.

use ny_core::{parse, CommandSpec, Core, Manifest, Module, NyError, Result, Scope, SettingSpec};
use ny_llm::ProviderConfig;
use serde::Deserialize;
use serde_json::{json, Value};

pub const ACTIONS: &[&str] = &["explain", "summarize", "rewrite", "ask"];
/// Base64 of a PNG; a full Retina screenshot fits.
pub const MAX_IMAGE_BYTES: usize = 12 * 1024 * 1024;
/// Turns kept from the conversation; older ones are dropped first.
pub const MAX_TURNS: usize = 20;

pub struct AskModule;

impl Module for AskModule {
    fn manifest(&self) -> Manifest {
        Manifest {
            id: "ask".into(),
            name: "Ask AI".into(),
            summary: "Explain, summarize, rewrite, or ask about anything you select or capture.".into(),
            capabilities: vec!["hotkey".into(), "text.capture".into(), "window.overlay".into(), "network".into()],
            collections: vec![],
            settings: vec![
                SettingSpec::new("ask.send_images", json!(true), Scope::Synced,
                                 "Send screenshots to the model as images (it must accept images); off sends only their text."),
            ],
            commands: vec![
                CommandSpec::new("run", "Answer about a thing: {action: explain|summarize|rewrite|ask, text?, image?: base64 PNG, question?, language?, turns?: [{role: user|assistant, content}], api_key?, request_id?, stream?} → {text}. turns are the follow-ups so far, oldest first; question is the new one. With stream and a request_id, `ask.delta` events {request_id, text} carry the answer so far."),
            ],
        }
    }

    fn call(&self, core: &Core, command: &str, params: Value) -> Result<Value> {
        #[derive(Deserialize)]
        struct Turn { role: String, content: String }
        #[derive(Deserialize)]
        struct Run {
            action: String,
            #[serde(default)] text: String,
            image: Option<String>,
            #[serde(default)] question: String,
            #[serde(default)] language: String,
            #[serde(default)] turns: Vec<Turn>,
            #[serde(default)] api_key: String,
            request_id: Option<String>,
            /// Stream the answer: `ask.delta` events carry it so far, for this `request_id`.
            #[serde(default)] stream: bool,
        }
        match command {
            "run" => {
                let p: Run = parse(params)?;
                let request_id = p.request_id.clone();
                let request = core.begin_request(p.request_id);
                if !ACTIONS.contains(&p.action.as_str()) {
                    return Err(NyError::invalid_params("Ask explains, summarizes, rewrites, or answers a question."));
                }
                if p.text.len() > ny_llm::MAX_INPUT_BYTES {
                    return Err(NyError::new("input_too_large", "That’s more than 64 KB of text. Select less and try again."));
                }
                let image = match p.image {
                    Some(image) if image.len() > MAX_IMAGE_BYTES => return Err(NyError::new("input_too_large", "That screenshot is too big to send.")),
                    Some(image) if image.is_empty() || !image.bytes().all(|b| b.is_ascii_alphanumeric() || b"+/=".contains(&b)) =>
                        return Err(NyError::invalid_params("A screenshot is sent as base64 PNG.")),
                    Some(image) if core.setting::<bool>("ask.send_images")? => Some(image),
                    _ => None,
                };
                if p.text.trim().is_empty() && image.is_none() && p.question.trim().is_empty() {
                    return Err(NyError::new("empty_input", "Select something or type a question first."));
                }
                if p.action == "ask" && p.question.trim().is_empty() && p.turns.is_empty() {
                    return Err(NyError::new("empty_input", "Type a question first."));
                }
                let mut messages = vec![json!({ "role": "system", "content": system(&p.language) })];
                messages.push(json!({ "role": "user", "content": first_message(&p.action, &p.text, image.as_deref(), &p.question, p.turns.is_empty()) }));
                let skip = p.turns.len().saturating_sub(MAX_TURNS);
                for turn in p.turns.iter().skip(skip) {
                    let role = if turn.role == "assistant" { "assistant" } else { "user" };
                    messages.push(json!({ "role": role, "content": turn.content.chars().take(16_000).collect::<String>() }));
                }
                if !p.turns.is_empty() {
                    if p.question.trim().is_empty() { return Err(NyError::new("empty_input", "Type a follow-up first.")); }
                    messages.push(json!({ "role": "user", "content": p.question }));
                }
                let config = ProviderConfig::from_core(core)?;
                let text = match (p.stream, request_id) {
                    (true, Some(id)) => {
                        // At most every 40 ms: enough to look live, few enough not to flood the client.
                        let mut last = std::time::Instant::now() - std::time::Duration::from_secs(1);
                        ny_llm::stream_messages(&messages, &config, &p.api_key, |so_far| {
                            // Cancelled: send nothing more, and stop reading now rather than when the answer is done.
                            if request.is_cancelled() { return false; }
                            if last.elapsed() >= std::time::Duration::from_millis(40) {
                                last = std::time::Instant::now();
                                core.emit(json!({ "type": "ask.delta", "request_id": id, "text": so_far }));
                            }
                            true
                        })?
                    }
                    _ => ny_llm::complete_messages(&messages, &config, &p.api_key)?,
                };
                // Cancelled while waiting: the answer is no longer wanted.
                request.check()?;
                Ok(json!({ "text": text.trim() }))
            }
            _ => Err(NyError::unknown_method(&format!("ask.{command}"))),
        }
    }
}

fn system(language: &str) -> String {
    let language = if language.trim().is_empty() { "the language of the user's question, or else of the material" } else { language.trim() };
    format!("You are NyCopilot, a concise assistant on the user's Mac. The user shows you something they selected or captured \
             on screen and asks about it. Answer directly, without preamble or offers of further help. Use short paragraphs or \
             lists when they help; plain text, light Markdown at most. Reply in {language}, unless the user asks otherwise. \
             When rewriting, reply with only the rewritten text, in the material's own language.")
}

/// The thing itself, what to do with it, and — on a first turn — the question.
fn first_message(action: &str, text: &str, image: Option<&str>, question: &str, first: bool) -> Value {
    let task = match action {
        "explain" => "Explain this: what it means, any terms or references a reader might not know, and why it matters.",
        "summarize" => "Summarize this: the key points first, as briefly as the material allows.",
        "rewrite" => "Rewrite this to read clearly and naturally, keeping its meaning, tone, and language.",
        _ => "Answer my question about this.",
    };
    let mut prompt = String::from(task);
    if !text.trim().is_empty() {
        let label = if image.is_some() { "Text recognized in the screenshot" } else { "Material" };
        prompt.push_str(&format!("\n\n{label}:\n\"\"\"\n{text}\n\"\"\""));
    }
    if first && !question.trim().is_empty() { prompt.push_str(&format!("\n\nMy question: {question}")); }
    match image {
        Some(image) => json!([{ "type": "text", "text": prompt },
                              { "type": "image_url", "image_url": { "url": format!("data:image/png;base64,{image}") } }]),
        None => json!(prompt),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::stand_in;
    use ny_core::Store;

    fn core(model: &str) -> Core {
        let core = Core::new(Store::open_in_memory().unwrap(), crate::all(), "test", Box::new(|_| {})).unwrap();
        core.call("settings.set", json!({ "key": "llm.endpoint", "value": format!("{model}/v1/chat/completions") })).unwrap();
        core.call("settings.set", json!({ "key": "llm.model", "value": "m" })).unwrap();
        core
    }

    fn body(request: &str) -> Value { serde_json::from_str(&request[request.find("\r\n\r\n").unwrap() + 4..]).unwrap() }

    #[test]
    fn a_selection_is_explained_and_followed_up() {
        let (model, log) = stand_in::serve(vec![stand_in::model_reply(" It's a greeting. "), stand_in::model_reply("Hi.")]);
        let core = core(&model);
        let reply = core.call("ask.run", json!({ "action": "explain", "text": "你好", "language": "English" })).unwrap();
        assert_eq!(reply["text"], "It's a greeting.");
        core.call("ask.run", json!({ "action": "explain", "text": "你好", "question": "Shorter?",
                                    "turns": [{ "role": "user", "content": "" }, { "role": "assistant", "content": "It's a greeting." }] })).unwrap();
        let requests = log.lock().unwrap();
        let first = body(&requests[0]);
        assert!(first["messages"][0]["content"].as_str().unwrap().contains("Reply in English"));
        assert!(first["messages"][1]["content"].as_str().unwrap().contains("Explain this") && first["messages"][1]["content"].as_str().unwrap().contains("你好"));
        let second = body(&requests[1])["messages"].as_array().unwrap().clone();
        assert_eq!((second.len(), second[3]["role"].clone(), second[4]["content"].clone()), (5, json!("assistant"), json!("Shorter?")));
    }

    #[test]
    fn a_screenshot_goes_as_an_image_unless_turned_off() {
        let (model, log) = stand_in::serve(vec![stand_in::model_reply("A chart."), stand_in::model_reply("A chart.")]);
        let core = core(&model);
        let params = json!({ "action": "ask", "image": "iVBORw0KGgo=", "text": "Q3 revenue", "question": "What is this?" });
        core.call("ask.run", params.clone()).unwrap();
        core.call("settings.set", json!({ "key": "ask.send_images", "value": false })).unwrap();
        core.call("ask.run", params).unwrap();
        let requests = log.lock().unwrap();
        let with_image = &body(&requests[0])["messages"][1]["content"];
        assert_eq!(with_image[1]["image_url"]["url"], "data:image/png;base64,iVBORw0KGgo=");
        assert!(with_image[0]["text"].as_str().unwrap().contains("What is this?"));
        assert!(body(&requests[1])["messages"][1]["content"].as_str().unwrap().contains("Q3 revenue"));
    }

    #[test]
    fn streamed_answers_send_progress_events() {
        let body = ["Two", " particles"].iter().map(|chunk| format!("data: {}\n\n",
            json!({ "choices": [{ "delta": { "content": chunk } }] }))).collect::<String>() + "data: [DONE]\n\n";
        let (model, _) = stand_in::serve(vec![stand_in::http("200 OK", "Content-Type: text/event-stream\r\n", &body)]);
        let events = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
        let sink = events.clone();
        let core = Core::new(Store::open_in_memory().unwrap(), crate::all(), "test", Box::new(move |event| sink.lock().unwrap().push(event))).unwrap();
        core.call("settings.set", json!({ "key": "llm.endpoint", "value": format!("{model}/v1/chat/completions") })).unwrap();
        core.call("settings.set", json!({ "key": "llm.model", "value": "m" })).unwrap();
        let reply = core.call("ask.run", json!({ "action": "explain", "text": "x", "stream": true, "request_id": "r1" })).unwrap();
        assert_eq!(reply["text"], "Two particles");
        let deltas: Vec<Value> = events.lock().unwrap().iter().filter(|e| e["type"] == "ask.delta").cloned().collect();
        assert!(!deltas.is_empty());
        assert_eq!(deltas[0]["request_id"], "r1");
    }

    #[test]
    fn bad_requests_are_refused_before_sending() {
        let core = core("http://127.0.0.1:9");
        let run = |params: Value| core.call("ask.run", params).unwrap_err().code;
        assert_eq!(run(json!({ "action": "dance", "text": "x" })), "invalid_params");
        assert_eq!(run(json!({ "action": "explain" })), "empty_input");
        assert_eq!(run(json!({ "action": "ask", "text": "x" })), "empty_input");
        assert_eq!(run(json!({ "action": "explain", "image": "not base64!" })), "invalid_params");
        assert_eq!(run(json!({ "action": "explain", "text": "x".repeat(ny_llm::MAX_INPUT_BYTES + 1) })), "input_too_large");
    }
}
