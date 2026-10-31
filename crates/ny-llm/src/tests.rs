use super::*;
use std::io::{Read, Write};
use std::net::TcpListener;
use std::sync::{Arc, Mutex};
use std::thread;

fn prompt(text: &str) -> ChatPrompt {
    ChatPrompt { system: "Translate into English.".into(), user: text.into() }
}

fn configured() -> ProviderConfig { ProviderConfig::new("https://api.example.test/v1/chat/completions", "test-model") }

#[test]
fn unconfigured_provider_cannot_send() {
    let error = request_body(&prompt("Hello"), &ProviderConfig::default(), "").unwrap_err();
    assert_eq!(error.code, "provider_not_configured");
}

#[test]
fn endpoint_validation() {
    for ok in ["https://example.com/translate", "http://192.0.2.1:8081/v1/chat/completions",
               "http://[2001:db8::1]:8081/v1/chat/completions", "http://localhost:1234/v1/chat/completions"] {
        assert!(endpoint_url(ok).is_ok(), "{ok}");
    }
    for bad in ["ftp://localhost/api", "file:///tmp/api", "https://key:secret@example.com/api",
                "https://example.com/api?key=secret", "https://example.com/api#fragment", "/v1/chat/completions", ""] {
        assert!(endpoint_url(bad).is_err(), "{bad}");
    }
}

#[test]
fn request_contract_preserves_text_exactly() {
    let source = "  Hello 👋\nSecond line\n";
    let body: Value = serde_json::from_slice(&request_body(&prompt(source), &configured(), "k").unwrap()).unwrap();
    assert_eq!(body.as_object().unwrap().keys().cloned().collect::<Vec<_>>(), vec!["messages", "model", "stream"]);
    assert_eq!(body["model"], "test-model");
    assert_eq!(body["stream"], false);
    assert_eq!(body["messages"][0]["role"], "system");
    assert_eq!(body["messages"][1], json!({ "role": "user", "content": source }));
}

#[test]
fn input_and_key_limits() {
    assert_eq!(request_body(&prompt(" \n\t"), &configured(), "").unwrap_err().code, "empty_input");
    assert!(request_body(&prompt(&"a".repeat(65_536)), &configured(), "").is_ok());
    // Each euro sign is three UTF-8 bytes, so fewer characters exceed the byte limit.
    assert_eq!(request_body(&prompt(&"€".repeat(22_000)), &configured(), "").unwrap_err().code, "input_too_large");
    assert_eq!(request_body(&prompt("Hi"), &configured(), "key\r\nX-Test: bad").unwrap_err().code, "invalid_key");
    assert!(ProviderConfig::new("", "model\nother").validate().is_err());
    assert!(ProviderConfig::new("", &"a".repeat(201)).validate().is_err());
}

#[test]
fn response_decoding() {
    let ok = br#"{"choices":[{"message":{"content":"Hello\n\nWorld\n"},"finish_reason":"stop"}],"usage":{"total_tokens":10}}"#;
    assert_eq!(decode_response(ok).unwrap(), "Hello\n\nWorld\n");
    let truncated = br#"{"choices":[{"message":{"content":"partial"},"finish_reason":"length"}]}"#;
    assert_eq!(decode_response(truncated).unwrap_err().code, "truncated_response");
    for empty in [r#"{"choices":[{"message":{"content":null}}]}"#, r#"{"choices":[{"message":{"content":"  \n"}}]}"#] {
        assert_eq!(decode_response(empty.as_bytes()).unwrap_err().code, "empty_response");
    }
    for bad in ["not json", "{}", r#"{"choices":[]}"#, r#"{"choices":[{"message":{"content":[{"text":"hi"}]}}]}"#] {
        assert_eq!(decode_response(bad.as_bytes()).unwrap_err().code, "invalid_response");
    }
    assert_eq!(decode_response(&vec![b' '; 1_048_577]).unwrap_err().code, "response_too_large");
}

/// A one-connection-per-request loopback server; no test contacts a real provider.
struct Server { config: ProviderConfig, requests: Arc<Mutex<Vec<String>>> }

fn serve(status: &str, body: String, headers: &str, include_length: bool) -> Server {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let requests = Arc::new(Mutex::new(Vec::new()));
    let log = requests.clone();
    let length = if include_length { format!("Content-Length: {}\r\n", body.len()) } else { String::new() };
    let kind = if headers.contains("Content-Type:") { "" } else { "Content-Type: application/json\r\n" };
    let response = format!("HTTP/1.1 {status}\r\n{kind}{length}{headers}Connection: close\r\n\r\n{body}");
    thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(mut stream) = stream else { break };
            let mut buffer = Vec::new();
            let mut chunk = [0u8; 65536];
            while let Ok(count) = stream.read(&mut chunk) {
                if count == 0 { break; }
                buffer.extend_from_slice(&chunk[..count]);
                let text = String::from_utf8_lossy(&buffer).to_string();
                if let Some(split) = text.find("\r\n\r\n") {
                    let needed = text[..split].lines().find_map(|l| l.to_lowercase().strip_prefix("content-length:").map(|v| v.trim().parse::<usize>().unwrap_or(0))).unwrap_or(0);
                    if buffer.len() >= split + 4 + needed { break; }
                }
            }
            log.lock().unwrap().push(String::from_utf8_lossy(&buffer).to_string());
            let _ = stream.write_all(response.as_bytes());
        }
    });
    Server { config: ProviderConfig::new(&format!("http://127.0.0.1:{port}/v1/chat/completions"), "test-model"), requests }
}

const SUCCESS: &str = r#"{"choices":[{"message":{"content":"Hello, world!"},"finish_reason":"stop"}]}"#;

#[test]
fn loopback_round_trip() {
    let server = serve("200 OK", SUCCESS.into(), "", true);
    assert_eq!(complete(&prompt("Hello, world! 👋"), &server.config, "test-key").unwrap(), "Hello, world!");
    let request = server.requests.lock().unwrap()[0].clone();
    assert!(request.starts_with("POST /v1/chat/completions HTTP/1.1"));
    assert!(request.to_lowercase().contains("authorization: bearer test-key"));
    assert!(request.contains("Hello, world! 👋"));
}

#[test]
fn http_errors_are_not_retried_or_exposed() {
    let server = serve("429 Too Many Requests", "private-provider-detail".into(), "", true);
    let error = complete(&prompt("Hello"), &server.config, "").unwrap_err();
    assert_eq!((error.code.as_str(), error.status), ("http_status", Some(429)));
    assert!(!error.message.contains("private-provider-detail"));
    assert_eq!(server.requests.lock().unwrap().len(), 1);
}

#[test]
fn redirects_are_rejected() {
    let destination = serve("200 OK", SUCCESS.into(), "", true);
    let server = serve("307 Temporary Redirect", String::new(), &format!("Location: {}\r\n", destination.config.endpoint), true);
    let error = complete(&prompt("Hello"), &server.config, "k").unwrap_err();
    assert_eq!(error.status, Some(307));
    assert!(destination.requests.lock().unwrap().is_empty());
}

#[test]
fn oversized_responses_are_rejected_with_or_without_length() {
    for include_length in [true, false] {
        let server = serve("200 OK", "x".repeat(1_048_577), "", include_length);
        assert_eq!(complete(&prompt("Hello"), &server.config, "").unwrap_err().code, "response_too_large");
    }
}

#[test]
fn settings_are_validated_through_the_module() {
    let module = LlmModule;
    assert!(module.validate_setting("llm.endpoint", &json!("ftp://x")).is_err());
    assert!(module.validate_setting("llm.endpoint", &json!("")).is_ok());
    assert!(module.validate_setting("llm.model", &json!("a\nb")).is_err());
}

fn sse(chunks: &[&str]) -> String {
    let mut body: String = chunks.iter().map(|chunk| format!("data: {}\n\n",
        serde_json::json!({ "choices": [{ "delta": { "content": chunk }, "finish_reason": null }] }))).collect();
    body.push_str("data: [DONE]\n\n");
    body
}

#[test]
fn streamed_replies_arrive_piece_by_piece_and_can_be_stopped() {
    let server = serve("200 OK", sse(&["Hel", "lo", ", world"]), "Content-Type: text/event-stream\r\n", true);
    let mut seen = Vec::new();
    let text = stream_messages(&[serde_json::json!({ "role": "user", "content": "hi" })], &server.config, "", |so_far| {
        seen.push(so_far.to_string());
        true
    }).unwrap();
    assert_eq!(text, "Hello, world");
    assert_eq!(seen, ["Hel", "Hello", "Hello, world"]);
    assert!(server.requests.lock().unwrap()[0].contains("\"stream\":true"));

    let server = serve("200 OK", sse(&["one", " two", " three"]), "Content-Type: text/event-stream\r\n", true);
    let mut calls = 0;
    let error = stream_messages(&[serde_json::json!({ "role": "user", "content": "hi" })], &server.config, "", |_| {
        calls += 1;
        calls < 2
    }).unwrap_err();
    assert_eq!((error.code.as_str(), calls), ("cancelled", 2));
}

#[test]
fn servers_that_do_not_stream_answer_in_one_piece() {
    let server = serve("200 OK", SUCCESS.to_string(), "", true);
    let mut seen = Vec::new();
    let text = stream_messages(&[serde_json::json!({ "role": "user", "content": "hi" })], &server.config, "", |so_far| {
        seen.push(so_far.to_string());
        true
    }).unwrap();
    assert_eq!((text.as_str(), seen.len()), ("Hello, world!", 1));
}
