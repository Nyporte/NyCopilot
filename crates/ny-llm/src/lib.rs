//! Model access for every module: one provider (endpoint + model) per user, an OpenAI-compatible
//! Chat Completions client with strict bounds, and the `llm` module that exposes it.
//!
//! Requests are explicit and single-shot: no retries, no redirects, no cookies, no caching.
//! API keys are never stored by the core; the client passes them per call from the platform's
//! secure storage (Keychain on macOS, Credential Manager on Windows, Secret Service on Linux).

use std::io::Read;
use std::time::{Duration, Instant};

use ny_core::{parse, CommandSpec, Core, Manifest, Module, NyError, Result, Scope, SettingSpec};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

pub const MAX_INPUT_BYTES: usize = 64 * 1024;
pub const MAX_RESPONSE_BYTES: u64 = 1024 * 1024;

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProviderConfig {
    pub endpoint: String,
    pub model: String,
}

impl ProviderConfig {
    pub fn new(endpoint: &str, model: &str) -> Self {
        Self { endpoint: endpoint.trim().into(), model: model.trim().into() }
    }

    /// The provider stored in settings, shared by all modules.
    pub fn from_core(core: &Core) -> Result<Self> {
        Ok(Self::new(&core.setting::<String>("llm.endpoint")?, &core.setting::<String>("llm.model")?))
    }

    pub fn is_complete(&self) -> bool { !self.endpoint.is_empty() && !self.model.is_empty() }

    /// Incomplete settings are allowed so the rest of the app works before a provider is chosen.
    pub fn validate(&self) -> Result<()> {
        validate_model(&self.model)?;
        if !self.endpoint.is_empty() { endpoint_url(&self.endpoint)?; }
        Ok(())
    }
}

fn validate_model(model: &str) -> Result<()> {
    if model.chars().count() > 200 || model.contains(['\n', '\r']) {
        return Err(NyError::invalid_setting("Model ID must be a single line of at most 200 characters."));
    }
    Ok(())
}

/// HTTP or HTTPS, remote or local; no credentials, query, or fragment in the URL.
pub fn endpoint_url(endpoint: &str) -> Result<url::Url> {
    let invalid = || NyError::invalid_setting("Enter a complete API URL without a username, password, query, or fragment.");
    let url = url::Url::parse(endpoint.trim()).map_err(|_| invalid())?;
    if !matches!(url.scheme(), "http" | "https") {
        return Err(NyError::invalid_setting("The API endpoint must use HTTP or HTTPS."));
    }
    if url.host_str().is_none_or(str::is_empty) || !url.username().is_empty() || url.password().is_some()
        || url.query().is_some() || url.fragment().is_some() {
        return Err(invalid());
    }
    Ok(url)
}

/// One system instruction plus the user's text; every module reduces its request to this shape.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ChatPrompt {
    pub system: String,
    pub user: String,
}

/// Validate and serialize without touching the network.
pub fn request_body(prompt: &ChatPrompt, config: &ProviderConfig, api_key: &str) -> Result<Vec<u8>> {
    if prompt.user.trim().is_empty() { return Err(NyError::new("empty_input", "Type something first.")); }
    if prompt.user.len() > MAX_INPUT_BYTES {
        return Err(NyError::new("input_too_large", "That’s more than 64 KB of text. Shorten it and try again."));
    }
    messages_body(&[json!({ "role": "system", "content": prompt.system }), json!({ "role": "user", "content": prompt.user })], config, api_key, false)
}

/// A whole conversation — Chat Completions messages, whose content may mix text and images —
/// validated and serialized, asking for a streamed reply or not. Callers bound its size; this
/// checks the provider and the key.
pub fn messages_body(messages: &[Value], config: &ProviderConfig, api_key: &str, stream: bool) -> Result<Vec<u8>> {
    config.validate()?;
    if !config.is_complete() {
        return Err(NyError::new("provider_not_configured", "Connect a model provider in Settings first."));
    }
    if api_key.chars().any(char::is_control) {
        return Err(NyError::new("invalid_key", "The API key can’t contain line breaks or control characters."));
    }
    Ok(serde_json::to_vec(&json!({ "model": config.model, "messages": messages, "stream": stream }))?)
}

/// Send one request and return the first choice's text.
pub fn complete(prompt: &ChatPrompt, config: &ProviderConfig, api_key: &str) -> Result<String> {
    send(request_body(prompt, config, api_key)?, config, api_key)
}

/// Send a whole conversation and return the reply's text.
pub fn complete_messages(messages: &[Value], config: &ProviderConfig, api_key: &str) -> Result<String> {
    send(messages_body(messages, config, api_key, false)?, config, api_key)
}

/// A conversation, streamed: `on_text` gets the reply so far each time more arrives and returns
/// false to stop reading (the request was cancelled), which ends the request at once rather than
/// when the reply is done. A server that doesn't stream answers in one piece, and `on_text` gets it
/// once. Bounded like `complete`, but with time for a long answer.
pub fn stream_messages(messages: &[Value], config: &ProviderConfig, api_key: &str, mut on_text: impl FnMut(&str) -> bool) -> Result<String> {
    let body = messages_body(messages, config, api_key, true)?;
    let mut response = post(http::streaming_agent(), config, api_key, "text/event-stream, application/json", &body)?;
    let streams = response.headers().get("content-type").and_then(|value| value.to_str().ok())
        .is_some_and(|kind| kind.contains("text/event-stream"));
    if !streams {
        let text = decode_response(&http::read_body(&mut response)?)?;
        if !on_text(&text) { return Err(cancelled()); }
        return Ok(text);
    }
    let invalid = || NyError::new("invalid_response", "Unexpected response. The endpoint must stream Chat Completions events.");
    let reader = std::io::BufReader::new(response.body_mut().as_reader().take(MAX_RESPONSE_BYTES + 1));
    let mut text = String::new();
    let mut finish: Option<String> = None;
    for line in std::io::BufRead::lines(reader) {
        let line = line.map_err(|_| NyError::new("network", "The connection dropped while reading the reply. Try again."))?;
        let Some(data) = line.strip_prefix("data:").map(str::trim) else { continue };
        if data == "[DONE]" { break; }
        let event: Value = serde_json::from_str(data).map_err(|_| invalid())?;
        if let Some(message) = event["error"]["message"].as_str() {
            return Err(NyError::new("model_error", format!("The model reported an error: {message}")));
        }
        let choice = &event["choices"][0];
        if let Some(reason) = choice["finish_reason"].as_str() { finish = Some(reason.to_string()); }
        if let Some(delta) = choice["delta"]["content"].as_str().filter(|delta| !delta.is_empty()) {
            text.push_str(delta);
            if text.len() as u64 > MAX_RESPONSE_BYTES { return Err(too_large()); }
            if !on_text(&text) { return Err(cancelled()); }
        }
    }
    if finish.as_deref() == Some("length") {
        return Err(NyError::new("truncated_response", "The model hit its output limit, so the reply was incomplete."));
    }
    if text.trim().is_empty() { return Err(NyError::new("empty_response", "The model returned an empty reply.")); }
    Ok(text)
}

fn cancelled() -> NyError { NyError::new("cancelled", "Cancelled.") }

fn send(body: Vec<u8>, config: &ProviderConfig, api_key: &str) -> Result<String> {
    let mut response = post(http::agent(), config, api_key, "application/json", &body)?;
    decode_response(&http::read_body(&mut response)?)
}

/// POST a body to the provider, with the key when there is one → the response, if it succeeded.
fn post(agent: ureq::Agent, config: &ProviderConfig, api_key: &str, accept: &str, body: &[u8]) -> Result<ureq::http::Response<ureq::Body>> {
    let mut request = agent.post(endpoint_url(&config.endpoint)?.as_str())
        .header("Content-Type", "application/json")
        .header("Accept", accept);
    if !api_key.is_empty() { request = request.header("Authorization", &format!("Bearer {api_key}")); }
    let response = request.send(body).map_err(http::transport_error)?;
    let status = response.status().as_u16();
    if !(200..300).contains(&status) { return Err(http_status(status)); }
    Ok(response)
}

/// The bounds every outgoing request shares, for model providers and other translation services.
pub mod http {
    use super::*;

    /// No automatic redirects (callers decide), no retries, platform-verified TLS, and time limits.
    pub fn agent() -> ureq::Agent { build(60, 30, 30) }

    /// For streamed replies: the same bounds, with minutes rather than seconds for the whole reply,
    /// since a long answer keeps arriving well past a minute.
    pub fn streaming_agent() -> ureq::Agent { build(300, 60, 300) }

    /// The shared bounds, with time limits in seconds for the whole request, the response's start, and its body.
    fn build(whole: u64, response: u64, body: u64) -> ureq::Agent {
        ureq::Agent::config_builder()
            .max_redirects(0)
            .http_status_as_error(false)
            .save_redirect_history(false)
            .timeout_global(Some(Duration::from_secs(whole)))
            .timeout_connect(Some(Duration::from_secs(15)))
            .timeout_recv_response(Some(Duration::from_secs(response)))
            .timeout_recv_body(Some(Duration::from_secs(body)))
            .tls_config(ureq::tls::TlsConfig::builder().root_certs(ureq::tls::RootCerts::PlatformVerifier).build())
            .build()
            .into()
    }

    /// The whole body, refusing anything over 1 MB.
    pub fn read_body(response: &mut ureq::http::Response<ureq::Body>) -> Result<Vec<u8>> {
        if response.body().content_length().is_some_and(|length| length > MAX_RESPONSE_BYTES) {
            return Err(too_large());
        }
        let mut data = Vec::new();
        response.body_mut().as_reader().take(MAX_RESPONSE_BYTES + 1).read_to_end(&mut data)
            .map_err(|_| NyError::new("network", "The connection dropped while reading the reply. Try again."))?;
        if data.len() as u64 > MAX_RESPONSE_BYTES { return Err(too_large()); }
        Ok(data)
    }

    pub fn transport_error(error: ureq::Error) -> NyError {
        use ureq::Error::*;
        let message = match &error {
            Timeout(_) => "The request timed out. Check the service, then try again.",
            HostNotFound => "Can’t find the host. Check the URL in Settings.",
            ConnectionFailed => "Can’t reach the server. Is it running?",
            Tls(_) | Rustls(_) => "Secure connection failed. Check the server’s TLS certificate.",
            _ => "The network request failed. Check your connection and the URL.",
        };
        NyError::new("network", message)
    }
}

/// Accept the first plain-text choice; reject truncated, empty, or non-Chat-Completions replies.
pub fn decode_response(data: &[u8]) -> Result<String> {
    #[derive(Deserialize)]
    struct Response { choices: Vec<Choice> }
    #[derive(Deserialize)]
    struct Choice { message: Message, finish_reason: Option<String> }
    #[derive(Deserialize)]
    struct Message { content: Option<String> }

    if data.len() as u64 > MAX_RESPONSE_BYTES { return Err(too_large()); }
    let invalid = || NyError::new("invalid_response", "Unexpected response. The endpoint must return Chat Completions JSON.");
    let response: Response = serde_json::from_slice(data).map_err(|_| invalid())?;
    let choice = response.choices.into_iter().next().ok_or_else(invalid)?;
    if choice.finish_reason.as_deref() == Some("length") {
        return Err(NyError::new("truncated_response", "The model hit its output limit, so the reply was incomplete. Try shorter text."));
    }
    match choice.message.content {
        Some(content) if !content.trim().is_empty() => Ok(content),
        _ => Err(NyError::new("empty_response", "The model returned an empty reply.")),
    }
}

fn too_large() -> NyError { NyError::new("response_too_large", "The reply exceeded 1 MB and was discarded.") }

fn http_status(status: u16) -> NyError {
    let message = match status {
        300..=399 => format!("The API redirected the request (HTTP {status}). Use the final endpoint URL."),
        401 | 403 => format!("Access denied (HTTP {status}). Check the API key and model permissions."),
        404 => "Endpoint or model not found (HTTP 404). Check both in Settings.".into(),
        429 => "Rate or quota limit reached (HTTP 429). Try again in a moment.".into(),
        500..=599 => format!("The provider had a problem (HTTP {status}). Try again shortly."),
        _ => format!("Request failed (HTTP {status}). Check the endpoint and model."),
    };
    NyError { code: "http_status".into(), message, status: Some(status) }
}

/// The `llm` module: provider settings plus raw completion for modules and clients.
pub struct LlmModule;

impl Module for LlmModule {
    fn manifest(&self) -> Manifest {
        Manifest {
            id: "llm".into(),
            name: "Model".into(),
            summary: "The model provider shared by every module.".into(),
            capabilities: vec!["network".into()],
            collections: vec![],
            settings: vec![
                SettingSpec::new("llm.endpoint", json!(""), Scope::Synced, "OpenAI-compatible Chat Completions URL."),
                SettingSpec::new("llm.model", json!(""), Scope::Synced, "Model ID sent with every request."),
            ],
            commands: vec![
                CommandSpec::new("complete", "Run one prompt: {system, user, api_key?} → {text}."),
                CommandSpec::new("test", "Check a provider: {endpoint, model, api_key?} → {elapsed_ms}."),
            ],
        }
    }

    fn call(&self, core: &Core, command: &str, params: Value) -> Result<Value> {
        #[derive(Deserialize)]
        struct Complete { system: String, user: String, #[serde(default)] api_key: String }
        #[derive(Deserialize)]
        struct Test { endpoint: String, model: String, #[serde(default)] api_key: String }
        match command {
            "complete" => {
                let p: Complete = parse(params)?;
                let text = complete(&ChatPrompt { system: p.system, user: p.user }, &ProviderConfig::from_core(core)?, &p.api_key)?;
                Ok(json!({ "text": text }))
            }
            "test" => {
                let p: Test = parse(params)?;
                let started = Instant::now();
                let prompt = ChatPrompt { system: "Reply with the single word OK.".into(), user: "Connection test".into() };
                complete(&prompt, &ProviderConfig::new(&p.endpoint, &p.model), &p.api_key)?;
                Ok(json!({ "elapsed_ms": started.elapsed().as_millis() as u64 }))
            }
            _ => Err(NyError::unknown_method(&format!("llm.{command}"))),
        }
    }

    fn validate_setting(&self, key: &str, value: &Value) -> Result<()> {
        let text = value.as_str().unwrap_or_default();
        match key {
            "llm.endpoint" if !text.trim().is_empty() => endpoint_url(text).map(|_| ()),
            "llm.model" => validate_model(text.trim()),
            _ => Ok(()),
        }
    }
}

/// A loopback stand-in for the HTTP services modules call: each connection gets the next canned
/// response, and every request is logged for the test to inspect. For tests here and, through the
/// `test-support` feature, in other crates.
#[cfg(any(test, feature = "test-support"))]
#[doc(hidden)]
pub mod stand_in {
    use std::io::{Read, Write};
    use std::net::TcpListener;
    use std::sync::{Arc, Mutex};
    use std::thread;

    pub fn serve(responses: Vec<String>) -> (String, Arc<Mutex<Vec<String>>>) {
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

    pub fn http(status: &str, headers: &str, body: &str) -> String {
        format!("HTTP/1.1 {status}\r\nContent-Length: {}\r\n{headers}Connection: close\r\n\r\n{body}", body.len())
    }

    /// A Chat Completions reply carrying `content`.
    pub fn model_reply(content: &str) -> String {
        http("200 OK", "", &serde_json::json!({ "choices": [{ "message": { "content": content }, "finish_reason": "stop" }] }).to_string())
    }
}

#[cfg(test)]
mod tests;
