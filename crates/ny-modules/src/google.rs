//! Google Translate through the user's own Apps Script web app, which calls `LanguageApp.translate`.
//!
//! The script's contract: POST JSON `{key, text, source, target}` to the deployment's `/exec` URL;
//! it answers `{code, translated}` or `{code, error}`. Apps Script runs the script, then redirects
//! once to `script.googleusercontent.com` to serve the output. That hop is followed by hand with a
//! plain GET, so the key (which travels only in the POST body) is never sent anywhere else.

use ny_core::{NyError, Result};
use ny_llm::http;
use serde::Deserialize;
use serde_json::json;

/// Where Apps Script serves a web app's output after running it.
const OUTPUT_HOST: &str = "script.googleusercontent.com";

/// Language names NyCopilot uses, and codes typed directly, mapped to Google's codes.
const CODES: &[(&str, &str)] = &[
    ("English", "en"), ("Simplified Chinese", "zh-CN"), ("Chinese", "zh-CN"), ("Traditional Chinese", "zh-TW"),
    ("Japanese", "ja"), ("Korean", "ko"), ("Spanish", "es"), ("French", "fr"), ("German", "de"), ("Italian", "it"),
    ("Portuguese", "pt"), ("Brazilian Portuguese", "pt"), ("European Portuguese", "pt-PT"), ("Russian", "ru"),
    ("Arabic", "ar"), ("Dutch", "nl"), ("Polish", "pl"), ("Turkish", "tr"), ("Vietnamese", "vi"), ("Thai", "th"),
    ("Indonesian", "id"), ("Malay", "ms"), ("Hindi", "hi"), ("Bengali", "bn"), ("Ukrainian", "uk"), ("Swedish", "sv"),
    ("Norwegian", "no"), ("Danish", "da"), ("Finnish", "fi"), ("Greek", "el"), ("Hebrew", "iw"), ("Czech", "cs"),
    ("Hungarian", "hu"), ("Romanian", "ro"), ("Persian", "fa"), ("Filipino", "tl"), ("Tagalog", "tl"),
];

/// Google's code for a target language, or `None` when only a model can honor it — for example
/// "formal Japanese", whose qualifier Google would silently drop.
pub fn language_code(language: &str) -> Option<String> {
    let language = language.trim();
    if let Some((_, code)) = CODES.iter().find(|(name, _)| name.eq_ignore_ascii_case(language)) {
        return Some((*code).into());
    }
    // A code typed directly: "ja", "zh-TW", "pt-PT".
    let mut parts = language.split('-');
    let primary = parts.next().unwrap_or_default();
    let region = parts.next();
    let is_code = (2..=3).contains(&primary.len()) && primary.chars().all(|c| c.is_ascii_lowercase())
        && region.is_none_or(|r| (2..=4).contains(&r.len()) && r.chars().all(|c| c.is_ascii_alphanumeric()))
        && parts.next().is_none();
    is_code.then(|| language.to_string())
}

/// The deployment URL: HTTP(S), no credentials, query, or fragment.
pub fn validate_url(url: &str) -> Result<()> {
    ny_llm::endpoint_url(url).map(|_| ()).map_err(|_| NyError::invalid_setting(
        "Enter the web app URL from Deploy → Manage deployments; it ends in /exec."))
}

pub fn request_body(text: &str, target: &str, key: &str) -> Result<Vec<u8>> {
    Ok(serde_json::to_vec(&json!({ "key": key, "text": text, "source": "auto", "target": target }))?)
}

/// Run one translation through the web app.
pub fn translate(url: &str, key: &str, text: &str, target: &str) -> Result<String> {
    decode_response(&post(url, &request_body(text, target, key)?)?, text)
}

/// POST to the web app and follow its one redirect to the output, returning the body.
fn post(url: &str, body: &[u8]) -> Result<Vec<u8>> {
    let start = ny_llm::endpoint_url(url)?;
    let agent = http::agent();
    let mut response = agent.post(start.as_str())
        .header("Content-Type", "application/json")
        .header("Accept", "application/json")
        .send(body).map_err(http::transport_error)?;
    let mut status = response.status().as_u16();
    if matches!(status, 301..=303) {
        let location = response.headers().get("location").and_then(|value| value.to_str().ok()).unwrap_or_default();
        let next = start.join(location).map_err(|_| unexpected())?;
        let same_origin = next.scheme() == start.scheme() && next.host_str() == start.host_str() && next.port() == start.port();
        if next.host_str().is_some_and(|host| host.ends_with("accounts.google.com")) { return Err(access_denied()); }
        if !(same_origin || (next.scheme() == "https" && next.host_str() == Some(OUTPUT_HOST))) { return Err(unexpected()); }
        response = agent.get(next.as_str()).header("Accept", "application/json").call().map_err(http::transport_error)?;
        status = response.status().as_u16();
    }
    match status {
        200..=299 => http::read_body(&mut response),
        401 | 403 => Err(access_denied()),
        404 => Err(NyError { code: "http_status".into(), status: Some(404),
                             message: "Web app not found (HTTP 404). Check the URL — it ends in /exec.".into() }),
        _ => Err(NyError { code: "http_status".into(), status: Some(status),
                           message: format!("Google Apps Script had a problem (HTTP {status}). Try again shortly.") }),
    }
}

/// The script reports its own errors inside a 200 response, with an HTTP-like `code`.
pub fn decode_response(data: &[u8], source: &str) -> Result<String> {
    #[derive(Deserialize)]
    struct Reply { code: u16, translated: Option<String>, error: Option<String> }
    let reply: Reply = serde_json::from_slice(data).map_err(|_| unexpected())?;
    let detail = reply.error.unwrap_or_default().chars().take(200).collect::<String>();
    match (reply.code, reply.translated) {
        (200, Some(text)) if !text.trim().is_empty() => Ok(unescape(text, source)),
        (200, _) => Err(NyError::new("empty_response", "Google Translate returned an empty translation.")),
        (401, _) => Err(NyError::new("invalid_key", "The web app rejected the access key. Check it in Settings → AI & Engines.")),
        (_, _) => Err(NyError::new("google_error", format!("Google Translate failed: {detail}"))),
    }
}

/// `LanguageApp` sometimes returns HTML entities (`&#39;`, `&quot;`). Decode them, unless the source
/// itself contained an ampersand that the translation may legitimately carry through.
fn unescape(text: String, source: &str) -> String {
    if source.contains('&') || !text.contains('&') { return text; }
    let mut out = String::with_capacity(text.len());
    let mut rest = text.as_str();
    while let Some(at) = rest.find('&') {
        out.push_str(&rest[..at]);
        rest = &rest[at..];
        let decoded = rest.find(';').filter(|&end| end <= 10).and_then(|end| {
            let character = match &rest[1..end] {
                "amp" => Some('&'), "lt" => Some('<'), "gt" => Some('>'), "quot" => Some('"'), "apos" => Some('\''),
                entity => entity.strip_prefix("#x").or_else(|| entity.strip_prefix("#X"))
                    .map(|hex| u32::from_str_radix(hex, 16).ok())
                    .unwrap_or_else(|| entity.strip_prefix('#').and_then(|dec| dec.parse().ok()))
                    .and_then(char::from_u32),
            };
            character.map(|c| (c, end))
        });
        match decoded {
            Some((character, end)) => { out.push(character); rest = &rest[end + 1..]; }
            None => { out.push('&'); rest = &rest[1..]; }
        }
    }
    out.push_str(rest);
    out
}

fn access_denied() -> NyError {
    NyError::new("google_access",
        "Google asked for a sign-in, so the script never ran. Redeploy the web app with “Who has access: Anyone”.")
}

fn unexpected() -> NyError {
    NyError::new("invalid_response", "Unexpected response from the web app. Check that the URL is the deployment’s /exec URL.")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::stand_in::{http, serve};

    #[test]
    fn languages_map_to_google_codes_only_when_exact() {
        assert_eq!(language_code("Simplified Chinese").as_deref(), Some("zh-CN"));
        assert_eq!(language_code(" japanese ").as_deref(), Some("ja"));
        assert_eq!(language_code("Brazilian Portuguese").as_deref(), Some("pt"));
        assert_eq!(language_code("zh-TW").as_deref(), Some("zh-TW"));
        for model_only in ["formal Japanese", "Klingon", "Japanese, polite", "EN", "en-", "a-b-c", ""] {
            assert_eq!(language_code(model_only), None, "{model_only}");
        }
    }

    #[test]
    fn replies_and_script_errors() {
        assert_eq!(decode_response(r#"{"code":200,"is_batch":false,"translated":"你好\n世界"}"#.as_bytes(), "Hello\nworld").unwrap(), "你好\n世界");
        assert_eq!(decode_response(br#"{"code":200,"translated":"l&#39;heure &quot;x&quot; &amp; &#x4E16; &bogus; & fin"}"#, "x").unwrap(),
                   "l'heure \"x\" & 世 &bogus; & fin");
        // An ampersand in the source means entities in the reply may be intended.
        assert_eq!(decode_response(br#"{"code":200,"translated":"A &amp; B"}"#, "A &amp; B").unwrap(), "A &amp; B");
        assert_eq!(decode_response(br#"{"code":401,"error":"Unauthorized"}"#, "x").unwrap_err().code, "invalid_key");
        let failed = decode_response(br#"{"code":500,"error":"Exception: Invalid argument: target"}"#, "x").unwrap_err();
        assert_eq!(failed.code, "google_error");
        assert!(failed.message.contains("Invalid argument"));
        assert_eq!(decode_response(br#"{"code":200,"translated":"  "}"#, "x").unwrap_err().code, "empty_response");
        assert_eq!(decode_response(b"<!DOCTYPE html><html>", "x").unwrap_err().code, "invalid_response");
    }

    #[test]
    fn request_carries_key_only_in_the_body() {
        let body: serde_json::Value = serde_json::from_slice(&request_body("Hi\n", "ja", "k").unwrap()).unwrap();
        assert_eq!(body, json!({ "key": "k", "text": "Hi\n", "source": "auto", "target": "ja" }));
        assert!(validate_url("https://script.google.com/macros/s/abc/exec").is_ok());
        assert!(validate_url("https://script.google.com/macros/s/abc/exec?key=secret").is_err());
    }

    #[test]
    fn follows_the_output_redirect_without_resending_the_key() {
        let ok = r#"{"code":200,"translated":"こんにちは"}"#;
        let (base, requests) = serve(vec![http("302 Found", "Location: /macros/echo?user_content_key=abc\r\n", ""),
                                          http("200 OK", "Content-Type: application/json\r\n", ok)]);
        assert_eq!(translate(&format!("{base}/macros/s/x/exec"), "secret-key", "Hello", "ja").unwrap(), "こんにちは");
        let requests = requests.lock().unwrap();
        assert!(requests[0].starts_with("POST /macros/s/x/exec") && requests[0].contains("secret-key"));
        assert!(requests[1].starts_with("GET /macros/echo?user_content_key=abc") && !requests[1].contains("secret-key"));
    }

    #[test]
    fn sign_in_and_foreign_redirects_are_refused() {
        let (base, _) = serve(vec![http("302 Found", "Location: https://accounts.google.com/v3/signin\r\n", "")]);
        assert_eq!(translate(&format!("{base}/exec"), "k", "Hello", "ja").unwrap_err().code, "google_access");
        let (base, _) = serve(vec![http("401 Unauthorized", "", "<html>Sorry, unable to open the file</html>")]);
        assert_eq!(translate(&format!("{base}/exec"), "k", "Hello", "ja").unwrap_err().code, "google_access");
        let (base, requests) = serve(vec![http("302 Found", "Location: https://example.com/steal\r\n", "")]);
        assert_eq!(translate(&format!("{base}/exec"), "k", "Hello", "ja").unwrap_err().code, "invalid_response");
        assert_eq!(requests.lock().unwrap().len(), 1);
    }
}
