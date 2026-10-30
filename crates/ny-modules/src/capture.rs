//! Screenshot & Pin: capture a region, annotate it, then copy, save, or pin it to the screen.
//!
//! Capturing pixels, drawing the selection and annotation UI, and floating pinned images are client
//! work. The core keeps what every platform shares: output settings, file names, and a history of
//! captured regions that the capture UI can step back through.

use ny_core::{now_millis, parse, CommandSpec, Core, Manifest, Module, NyError, Result, Scope, SettingSpec};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

pub const HISTORY: &str = "capture.history";
pub const FORMATS: &[&str] = &["png", "jpg"];
pub const DEFAULT_PATTERN: &str = "NyCopilot {date} at {time}";
/// Shape and text options, kept between captures. Missing keys fall back to these defaults.
pub fn default_style() -> Value {
    json!({ "corner_radius": 0, "filled": false, "font": "", "text_size": 20,
            "bold": false, "italic": false, "underline": false, "strikethrough": false })
}

/// Known keys only, each of the right type and range; `font` is a family name ("" = system font).
pub fn validate_style(value: &Value) -> Result<()> {
    let invalid = |why: &str| NyError::invalid_setting(format!("Annotation style: {why}."));
    let object = value.as_object().ok_or_else(|| invalid("expected an object"))?;
    for (key, item) in object {
        match key.as_str() {
            "corner_radius" if !item.as_f64().is_some_and(|r| (0.0..=64.0).contains(&r)) => return Err(invalid("corner radius is 0–64")),
            "text_size" if !item.as_f64().is_some_and(|s| (6.0..=144.0).contains(&s)) => return Err(invalid("text size is 6–144")),
            "font" if !item.as_str().is_some_and(|f| f.chars().count() <= 100 && !f.contains(['\n', '\r'])) =>
                return Err(invalid("font is a single-line family name")),
            "filled" | "bold" | "italic" | "underline" | "strikethrough" if !item.is_boolean() => return Err(invalid("switches are true or false")),
            "corner_radius" | "text_size" | "font" | "filled" | "bold" | "italic" | "underline" | "strikethrough" => {}
            other => return Err(invalid(&format!("unknown option “{other}”"))),
        }
    }
    Ok(())
}

/// Annotation colors offered in the toolbar, as `#RRGGBB`.
pub const PALETTE: &[&str] = &["#FF3B30", "#FF9500", "#FFCC00", "#34C759", "#0A84FF", "#AF52DE", "#FFFFFF", "#000000"];

/// A captured area in points, in the platform's screen coordinates (top-left origin on macOS AX).
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct Region {
    pub x: f64,
    pub y: f64,
    pub w: f64,
    pub h: f64,
}

/// `{date}` (YYYY-MM-DD), `{time}` (HH.MM.SS), and `{n}` (a counter) in `pattern`, plus the extension.
/// Characters that are unsafe in file names on any platform are replaced.
pub fn file_name(pattern: &str, format: &str, local: (i32, u32, u32, u32, u32, u32), counter: u64) -> String {
    let (year, month, day, hour, minute, second) = local;
    let name = pattern
        .replace("{date}", &format!("{year:04}-{month:02}-{day:02}"))
        .replace("{time}", &format!("{hour:02}.{minute:02}.{second:02}"))
        .replace("{n}", &counter.to_string());
    let safe: String = name.chars().map(|c| if "/\\:*?\"<>|".contains(c) || c.is_control() { '-' } else { c }).collect();
    let trimmed = safe.trim().trim_matches('.');
    format!("{}.{format}", if trimmed.is_empty() { "Capture" } else { trimmed })
}

pub fn validate_color(value: &str) -> Result<()> {
    let hex = value.strip_prefix('#').unwrap_or("");
    if hex.len() == 6 && hex.chars().all(|c| c.is_ascii_hexdigit()) { Ok(()) }
    else { Err(NyError::invalid_setting("Colors are written as #RRGGBB.")) }
}

pub struct CaptureModule;

impl Module for CaptureModule {
    fn manifest(&self) -> Manifest {
        Manifest {
            id: "capture".into(),
            name: "Screenshot & Pin".into(),
            summary: "Capture a region, annotate it, then copy, save, or pin it on top of everything.".into(),
            capabilities: vec!["screen.capture".into(), "window.overlay".into(), "hotkey".into(), "clipboard.read".into()],
            collections: vec![HISTORY.into()],
            settings: vec![
                // Folders differ per machine, so the save location stays on this device.
                SettingSpec::new("capture.save_folder", json!(""), Scope::Device, "Folder for saved captures; empty means Pictures/NyCopilot."),
                SettingSpec::new("capture.format", json!("png"), Scope::Synced, "File format for saved captures: png or jpg."),
                SettingSpec::new("capture.file_name", json!(DEFAULT_PATTERN), Scope::Synced, "File name pattern: {date}, {time}, {n}."),
                SettingSpec::new("capture.color", json!(PALETTE[0]), Scope::Synced, "Annotation color last used."),
                SettingSpec::new("capture.stroke", json!(3), Scope::Synced, "Annotation line width last used, in points."),
                SettingSpec::new("capture.style", default_style(), Scope::Synced,
                                 "Corner radius, fill, and text font, size, and emphasis last used for annotations."),
                SettingSpec::new("capture.pin_shadow", json!(true), Scope::Synced, "Draw a shadow around pinned images."),
                SettingSpec::new("capture.hide_own_windows", json!(false), Scope::Synced,
                                 "Leave NyCopilot's own windows, pins included, out of captures."),
            ],
            commands: vec![
                CommandSpec::new("palette", "Annotation colors: [\"#RRGGBB\"]."),
                CommandSpec::new("file_name", "{date: [y, m, d, H, M, S]} → {name} from the pattern and format."),
                CommandSpec::new("record", "Remember a capture: {region, display?, width, height, path?} → {record}."),
                CommandSpec::new("recent_regions", "Distinct recent regions, newest first: {limit?} → [Region]."),
            ],
        }
    }

    fn call(&self, core: &Core, command: &str, params: Value) -> Result<Value> {
        #[derive(Deserialize)]
        struct Name { date: (i32, u32, u32, u32, u32, u32) }
        #[derive(Deserialize)]
        struct Record { region: Region, #[serde(default)] display: String, width: u32, height: u32, path: Option<String> }
        #[derive(Deserialize)]
        struct Recent { #[serde(default = "default_limit")] limit: usize }
        fn default_limit() -> usize { 20 }
        match command {
            "palette" => Ok(json!(PALETTE)),
            "file_name" => {
                let p: Name = parse(params)?;
                let pattern = core.setting::<String>("capture.file_name")?;
                let format = core.setting::<String>("capture.format")?;
                // A per-millisecond counter keeps names unique even for patterns without {time}.
                Ok(json!({ "name": file_name(&pattern, &format, p.date, (now_millis() % 100_000) as u64) }))
            }
            "record" => {
                let p: Record = parse(params)?;
                if p.region.w < 1.0 || p.region.h < 1.0 { return Err(NyError::invalid_params("A capture needs a non-empty region.")); }
                let data = json!({ "region": p.region, "display": p.display, "width": p.width, "height": p.height, "path": p.path });
                let record = core.insert_record(HISTORY, data, p.path.as_deref().unwrap_or(""), None)?;
                Ok(json!({ "record": record }))
            }
            "recent_regions" => {
                let p: Recent = parse(params)?;
                let page = core.call("records.list", json!({ "collection": HISTORY, "limit": 200 }))?;
                let mut regions: Vec<Region> = Vec::new();
                for record in page["records"].as_array().into_iter().flatten() {
                    let Ok(region) = serde_json::from_value::<Region>(record["data"]["region"].clone()) else { continue };
                    if !regions.contains(&region) { regions.push(region); }
                    if regions.len() >= p.limit { break; }
                }
                Ok(json!(regions))
            }
            _ => Err(NyError::unknown_method(&format!("capture.{command}"))),
        }
    }

    fn validate_setting(&self, key: &str, value: &Value) -> Result<()> {
        let text = value.as_str().unwrap_or_default();
        match key {
            "capture.format" if !FORMATS.contains(&text) => Err(NyError::invalid_setting("Choose png or jpg.")),
            "capture.file_name" if text.trim().is_empty() || text.chars().count() > 120 =>
                Err(NyError::invalid_setting("The file name pattern must be 1–120 characters.")),
            "capture.color" => validate_color(text),
            "capture.style" => validate_style(value),
            "capture.stroke" if !value.as_f64().is_some_and(|w| (1.0..=24.0).contains(&w)) =>
                Err(NyError::invalid_setting("Line width must be between 1 and 24 points.")),
            _ => Ok(()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ny_core::Store;

    fn core() -> Core { Core::new(Store::open_in_memory().unwrap(), crate::all(), "test", Box::new(|_| {})).unwrap() }
    const NOON: (i32, u32, u32, u32, u32, u32) = (2026, 10, 30, 12, 5, 9);

    #[test]
    fn file_names_follow_the_pattern_and_stay_safe() {
        assert_eq!(file_name(DEFAULT_PATTERN, "png", NOON, 1), "NyCopilot 2026-10-30 at 12.05.09.png");
        assert_eq!(file_name("shot {n}", "jpg", NOON, 42), "shot 42.jpg");
        assert_eq!(file_name("a/b:c?{date}", "png", NOON, 0), "a-b-c-2026-10-30.png");
        assert_eq!(file_name("  ..  ", "png", NOON, 0), "Capture.png");
    }

    #[test]
    fn settings_are_validated() {
        let core = core();
        for (key, bad) in [("capture.format", json!("gif")), ("capture.color", json!("red")), ("capture.color", json!("#12345")),
                           ("capture.stroke", json!(0)), ("capture.stroke", json!(99)), ("capture.file_name", json!("  "))] {
            assert!(core.call("settings.set", json!({ "key": key, "value": bad })).is_err(), "{key} {bad}");
        }
        core.call("settings.set", json!({ "key": "capture.format", "value": "jpg" })).unwrap();
        core.call("settings.set", json!({ "key": "capture.color", "value": "#0a84ff" })).unwrap();
        // NyCopilot's own windows appear in captures unless the user opts out.
        assert!(!core.setting::<bool>("capture.hide_own_windows").unwrap());
        assert!(core.call("settings.set", json!({ "key": "capture.hide_own_windows", "value": "no" })).is_err());
        core.call("settings.set", json!({ "key": "capture.hide_own_windows", "value": true })).unwrap();
        let name = core.call("capture.file_name", json!({ "date": [2026, 1, 2, 3, 4, 5] })).unwrap();
        assert_eq!(name["name"], "NyCopilot 2026-01-02 at 03.04.05.jpg");
    }

    #[test]
    fn style_is_validated_field_by_field() {
        let core = core();
        assert_eq!(core.setting::<Value>("capture.style").unwrap()["text_size"], 20);
        for bad in [json!({ "corner_radius": 99 }), json!({ "text_size": 2 }), json!({ "bold": "yes" }),
                    json!({ "font": "a\nb" }), json!({ "sparkle": true }), json!([1, 2])] {
            assert!(core.call("settings.set", json!({ "key": "capture.style", "value": bad })).is_err(), "{bad}");
        }
        let custom = json!({ "corner_radius": 12, "filled": true, "font": "Georgia", "text_size": 32, "bold": true,
                             "italic": true, "underline": true, "strikethrough": false });
        core.call("settings.set", json!({ "key": "capture.style", "value": custom.clone() })).unwrap();
        assert_eq!(core.setting::<Value>("capture.style").unwrap(), custom);
    }

    #[test]
    fn recent_regions_are_distinct_and_newest_first() {
        let core = core();
        let record = |x: f64| core.call("capture.record", json!({ "region": { "x": x, "y": 0, "w": 100, "h": 50 }, "width": 200, "height": 100 })).unwrap();
        record(1.0);
        record(2.0);
        record(1.0);
        let regions = core.call("capture.recent_regions", json!({})).unwrap();
        let xs: Vec<f64> = regions.as_array().unwrap().iter().map(|r| r["x"].as_f64().unwrap()).collect();
        assert_eq!(xs, vec![1.0, 2.0]);
        assert!(core.call("capture.record", json!({ "region": { "x": 0, "y": 0, "w": 0, "h": 5 }, "width": 0, "height": 0 })).is_err());
    }
}
