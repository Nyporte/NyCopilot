//! Volcengine (Doubao) machine translation: `POST …/machine_translation/matx_translate` with
//! `{target_language, text_list}`; the reply carries a business `code` (20000000 is success) and one
//! translation per text.
//!
//! Credentials come in two shapes: an API key from the new console (`X-Api-Key`), or an App ID plus
//! access token from the old one (`X-Api-App-Key` + `X-Api-Access-Key`). Either travels only in headers.

use ny_core::{NyError, Result};
use ny_llm::http;
use serde::Deserialize;
use serde_json::json;
use uuid::Uuid;

pub const ENDPOINT: &str = "https://openspeech.bytedance.com/api/v3/machine_translation/matx_translate";

/// The service URL; tests point it at a loopback stand-in.
pub fn endpoint() -> String {
    #[cfg(test)]
    if let Some(url) = tests::ENDPOINT_OVERRIDE.with(|url| url.borrow().clone()) { return url; }
    ENDPOINT.into()
}
const RESOURCE_ID: &str = "volc.speech.mt";
const SUCCESS: i64 = 20_000_000;
/// The API accepts at most this many texts per request.
const MAX_TEXTS: usize = 16;

/// The 32 languages the service translates between, by the names NyCopilot uses.
const CODES: &[(&str, &str)] = &[
    ("English", "en"), ("Simplified Chinese", "zh"), ("Chinese", "zh"), ("Traditional Chinese", "zh-Hant"),
    ("Japanese", "ja"), ("Korean", "ko"), ("French", "fr"), ("German", "de"), ("Spanish", "es"), ("Portuguese", "pt"),
    ("Brazilian Portuguese", "pt"), ("Russian", "ru"), ("Arabic", "ar"), ("Italian", "it"), ("Dutch", "nl"),
    ("Polish", "pl"), ("Romanian", "ro"), ("Swedish", "sv"), ("Danish", "da"), ("Norwegian", "nb"), ("Finnish", "fi"),
    ("Hungarian", "hu"), ("Czech", "cs"), ("Croatian", "hr"), ("Greek", "el"), ("Hebrew", "he"), ("Turkish", "tr"),
    ("Ukrainian", "uk"), ("Thai", "th"), ("Vietnamese", "vi"), ("Indonesian", "id"), ("Malay", "ms"),
    ("Filipino", "tl"), ("Tagalog", "tl"), ("Hindi", "hi"),
];
/// Codes typed directly, including the spellings other services use for the same languages.
const ALIASES: &[(&str, &str)] = &[("zh-CN", "zh"), ("zh-Hans", "zh"), ("zh-TW", "zh-Hant"), ("no", "nb"), ("iw", "he")];

/// The service's code for a target language, or `None` when it doesn't offer that language (or the
/// name carries a qualifier only a model can honor, such as "formal Japanese").
pub fn language_code(language: &str) -> Option<String> {
    let language = language.trim();
    CODES.iter().find(|(name, _)| name.eq_ignore_ascii_case(language)).map(|(_, code)| *code)
        .or_else(|| ALIASES.iter().find(|(alias, _)| alias.eq_ignore_ascii_case(language)).map(|(_, code)| *code))
        .or_else(|| CODES.iter().find(|(_, code)| code.eq_ignore_ascii_case(language)).map(|(_, code)| *code))
        .map(String::from)
}

/// The App ID is only needed with old-console credentials.
pub fn validate_app_id(app_id: &str) -> Result<()> {
    if app_id.chars().count() > 100 || app_id.chars().any(char::is_control) {
        return Err(NyError::invalid_setting("The App ID must be a single line of at most 100 characters."));
    }
    Ok(())
}

/// One line of the source: its own whitespace stays put, only the words in between are translated.
struct Line<'a> { lead: &'a str, body: &'a str, trail: &'a str }

fn lines(text: &str) -> Vec<Line<'_>> {
    text.split('\n').map(|line| {
        let start = line.len() - line.trim_start().len();
        let end = line.trim_end().len().max(start);
        Line { lead: &line[..start], body: &line[start..end], trail: &line[end..] }
    }).collect()
}

/// Each non-blank line becomes one text, so line breaks, blank lines, and indentation come back
/// exactly. Longer text than 16 lines goes as a single text.
pub fn texts(text: &str) -> Vec<String> {
    let bodies: Vec<String> = lines(text).iter().filter(|l| !l.body.is_empty()).map(|l| l.body.to_string()).collect();
    if bodies.len() <= MAX_TEXTS { bodies } else { vec![text.trim().to_string()] }
}

/// Put translations back where their lines were.
pub fn reassemble(text: &str, translations: Vec<String>) -> String {
    let lines = lines(text);
    if lines.iter().filter(|l| !l.body.is_empty()).count() > MAX_TEXTS {
        return translations.into_iter().next().unwrap_or_default();
    }
    let mut translated = translations.into_iter();
    lines.iter().map(|line| {
        if line.body.is_empty() { format!("{}{}", line.lead, line.trail) }
        else { format!("{}{}{}", line.lead, translated.next().unwrap_or_default(), line.trail) }
    }).collect::<Vec<_>>().join("\n")
}

pub fn request_body(text: &str, target: &str) -> Result<Vec<u8>> {
    if text.trim().is_empty() { return Err(NyError::new("empty_input", "Type something first.")); }
    if text.len() > ny_llm::MAX_INPUT_BYTES {
        return Err(NyError::new("input_too_large", "That’s more than 64 KB of text. Shorten it and try again."));
    }
    Ok(serde_json::to_vec(&json!({ "target_language": target, "text_list": texts(text) }))?)
}

/// Run one translation. `app_id` empty means new-console credentials (`key` is the API key);
/// otherwise `key` is the old console's access token.
pub fn translate(endpoint: &str, app_id: &str, key: &str, text: &str, target: &str) -> Result<String> {
    let body = request_body(text, target)?;
    if key.trim().is_empty() {
        return Err(NyError::new("invalid_key", "Add a Volcengine API key in Settings → Translate."));
    }
    if key.chars().any(char::is_control) || app_id.chars().any(char::is_control) {
        return Err(NyError::new("invalid_key", "The key can’t contain line breaks or control characters."));
    }
    let mut request = http::agent().post(endpoint)
        .header("Content-Type", "application/json")
        .header("X-Api-Resource-Id", RESOURCE_ID)
        .header("X-Api-Request-Id", &Uuid::new_v4().to_string());
    request = if app_id.trim().is_empty() { request.header("X-Api-Key", key.trim()) }
              else { request.header("X-Api-App-Key", app_id.trim()).header("X-Api-Access-Key", key.trim()) };
    let mut response = request.send(&body[..]).map_err(http::transport_error)?;
    let status = response.status().as_u16();
    // Failures usually still carry the JSON envelope, which says more than the status.
    let data = http::read_body(&mut response)?;
    match decode_response(&data, text) {
        Err(error) if error.code == "invalid_response" && !(200..300).contains(&status) => Err(http_status(status)),
        result => result,
    }
}

pub fn decode_response(data: &[u8], source: &str) -> Result<String> {
    #[derive(Deserialize)]
    struct Reply { code: i64, #[serde(default)] message: String, data: Option<Data> }
    #[derive(Deserialize)]
    struct Data { translation_list: Vec<Item> }
    #[derive(Deserialize)]
    struct Item { translation: String }
    let reply: Reply = serde_json::from_slice(data)
        .map_err(|_| NyError::new("invalid_response", "Unexpected response from Volcengine."))?;
    let detail = reply.message.chars().take(200).collect::<String>();
    match reply.code {
        SUCCESS => {
            let list: Vec<String> = reply.data.map(|d| d.translation_list.into_iter().map(|i| i.translation).collect()).unwrap_or_default();
            if list.len() != texts(source).len() {
                return Err(NyError::new("invalid_response", "Volcengine returned a different number of lines than it was sent."));
            }
            let text = reassemble(source, list);
            if text.trim().is_empty() { return Err(NyError::new("empty_response", "Volcengine returned an empty translation.")); }
            Ok(text)
        }
        // A wrong key is reported as a generic 55000000 with the header named in the message.
        _ if ["api-key", "access-key", "app-key"].iter().any(|header| detail.to_lowercase().contains(header)) =>
            Err(NyError::new("invalid_key", format!("Volcengine rejected the credentials ({detail}). Check the key — and the App ID, for old-console credentials — in Settings → Translate."))),
        45_000_130 => Err(NyError::new("input_too_large", "Too long for Volcengine: each line can be at most about 1,024 tokens.")),
        45_000_001 => Err(NyError::new("volcengine_error", format!("Volcengine rejected the request: {detail}"))),
        55_000_001 => Err(NyError::new("volcengine_error", "Volcengine had an internal problem. Try again shortly.")),
        code => Err(NyError::new("volcengine_error", format!("Volcengine error {code}: {detail}"))),
    }
}

fn http_status(status: u16) -> NyError {
    let message = match status {
        401 | 403 => format!("Volcengine refused the credentials (HTTP {status}). Check the API key — or the App ID and access token — and that machine translation (volc.speech.mt) is enabled."),
        429 => "Volcengine’s rate or quota limit was reached (HTTP 429). Try again in a moment.".into(),
        500..=599 => format!("Volcengine had a problem (HTTP {status}). Try again shortly."),
        _ => format!("Volcengine request failed (HTTP {status})."),
    };
    NyError { code: "http_status".into(), message, status: Some(status) }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;

    thread_local! {
        pub(crate) static ENDPOINT_OVERRIDE: std::cell::RefCell<Option<String>> = const { std::cell::RefCell::new(None) };
    }

    #[test]
    fn languages() {
        assert_eq!(language_code("Simplified Chinese").as_deref(), Some("zh"));
        assert_eq!(language_code("traditional chinese").as_deref(), Some("zh-Hant"));
        assert_eq!(language_code("Norwegian").as_deref(), Some("nb"));
        assert_eq!(language_code("zh-TW").as_deref(), Some("zh-Hant"));
        assert_eq!(language_code("ja").as_deref(), Some("ja"));
        for unsupported in ["Bengali", "Persian", "formal Japanese", "xx", ""] {
            assert_eq!(language_code(unsupported), None, "{unsupported}");
        }
    }

    #[test]
    fn lines_go_out_separately_and_come_back_in_place() {
        let source = "  Hello there.\n\nSecond line \r\n\tThird";
        assert_eq!(texts(source), vec!["Hello there.", "Second line", "Third"]);
        let body: serde_json::Value = serde_json::from_slice(&request_body(source, "ja").unwrap()).unwrap();
        assert_eq!(body, json!({ "target_language": "ja", "text_list": ["Hello there.", "Second line", "Third"] }));
        assert_eq!(reassemble(source, vec!["一".into(), "二".into(), "三".into()]), "  一\n\n二 \r\n\t三");
        // More than 16 lines travel as one text.
        let long = (1..=20).map(|n| format!("line {n}")).collect::<Vec<_>>().join("\n");
        assert_eq!(texts(&long).len(), 1);
        assert_eq!(reassemble(&long, vec!["全部".into()]), "全部");
        assert_eq!(request_body(" \n ", "ja").unwrap_err().code, "empty_input");
    }

    #[test]
    fn replies_and_business_errors() {
        let ok = r#"{"code":20000000,"message":"ok","data":{"translation_list":[{"translation":"你好","usage":{"total_tokens":5}},{"translation":"世界"}]}}"#;
        assert_eq!(decode_response(ok.as_bytes(), "Hello\nworld").unwrap(), "你好\n世界");
        assert_eq!(decode_response(ok.as_bytes(), "Hello").unwrap_err().code, "invalid_response");
        assert_eq!(decode_response(br#"{"code":45000130,"message":"text_list[0] overflow tokens(1280>1024)"}"#, "x").unwrap_err().code, "input_too_large");
        let rejected = decode_response(br#"{"code":45000001,"message":"target_language is required"}"#, "x").unwrap_err();
        assert!(rejected.message.ends_with("target_language is required"));
        assert_eq!(decode_response(br#"{"code":45000010,"message":"invalid auth"}"#, "x").unwrap_err().message,
                   "Volcengine error 45000010: invalid auth");
        assert_eq!(decode_response(b"<html>", "x").unwrap_err().code, "invalid_response");
        // What the live service answers (with HTTP 500) for a wrong key.
        let wrong_key = decode_response(br#"{"code":55000000,"message":"Invalid X-Api-Key"}"#, "x").unwrap_err();
        assert_eq!(wrong_key.code, "invalid_key");
        assert!(wrong_key.message.starts_with("Volcengine rejected the credentials (Invalid X-Api-Key)."));
    }

    #[test]
    fn credentials_travel_only_in_headers() {
        let reply = r#"{"code":20000000,"message":"ok","data":{"translation_list":[{"translation":"こんにちは"}]}}"#;
        let (base, requests) = crate::google::tests::serve(vec![crate::google::tests::http("200 OK", "", reply); 2]);
        let endpoint = format!("{base}/api/v3/machine_translation/matx_translate");
        assert_eq!(translate(&endpoint, "", "new-key", "Hello", "ja").unwrap(), "こんにちは");
        assert_eq!(translate(&endpoint, "5584102956", "old-token", "Hello", "ja").unwrap(), "こんにちは");
        let requests = requests.lock().unwrap();
        let (new, old) = (requests[0].to_lowercase(), requests[1].to_lowercase());
        assert!(new.contains("x-api-key: new-key") && new.contains("x-api-resource-id: volc.speech.mt") && new.contains("x-api-request-id: "));
        assert!(old.contains("x-api-app-key: 5584102956") && old.contains("x-api-access-key: old-token") && !old.contains("x-api-key:"));
        let body = &requests[0][requests[0].find("\r\n\r\n").unwrap() + 4..];
        assert!(!body.contains("new-key"));
        assert_eq!(translate(&endpoint, "", " ", "Hello", "ja").unwrap_err().code, "invalid_key");
    }

    #[test]
    fn refused_credentials_without_an_envelope() {
        let (base, _) = crate::google::tests::serve(vec![crate::google::tests::http("401 Unauthorized", "", "denied")]);
        let error = translate(&format!("{base}/mt"), "", "k", "Hello", "ja").unwrap_err();
        assert_eq!((error.code.as_str(), error.status), ("http_status", Some(401)));
        assert!(!error.message.contains("denied"));
    }
}
