//! Clock: the date and time in a time zone of your choosing, in the system menu bar.
//!
//! This module owns the settings: whether the clock is there, the zone it shows, how it reads
//! (date or not, 12 or 24 hours, seconds, and how the zone is named), and other zones listed beside
//! it. Zones are IANA identifiers (`Asia/Tokyo`); clients know the zone database and their own
//! language's city names, keep the clock in step with the system's, and draw it.

use ny_core::{Core, Manifest, Module, NyError, Result, Scope, SettingSpec};
use serde_json::{json, Value};

/// How many other zones the clock's list can hold.
pub const MAX_OTHER_ZONES: usize = 20;
/// The longest name you can give the zone.
pub const MAX_CUSTOM_LABEL: usize = 40;
/// `clock.hour_cycle`: the system's choice, or always 12 or 24 hours.
pub const HOUR_CYCLES: [&str; 3] = ["system", "12", "24"];
/// `clock.label`: what follows the time — the zone's city, its abbreviation, its offset from GMT,
/// a name of your own, or nothing.
pub const LABELS: [&str; 5] = ["city", "abbreviation", "offset", "custom", "none"];

/// An IANA zone identifier as the databases spell them: `GMT`, `Asia/Tokyo`, `Etc/GMT-9`,
/// `America/Argentina/Buenos_Aires`. Whether the zone exists is the client's to say.
pub fn is_zone_id(id: &str) -> bool {
    !id.is_empty() && id.len() <= 64 && !id.starts_with('/') && !id.ends_with('/') && !id.contains("//")
        && id.chars().all(|c| c.is_ascii_alphanumeric() || "/_+-".contains(c))
}

pub struct ClockModule;

impl Module for ClockModule {
    fn manifest(&self) -> Manifest {
        Manifest {
            id: "clock".into(),
            name: "Clock".into(),
            summary: "The date and time in a time zone of your choosing, in the menu bar.".into(),
            capabilities: vec!["statusbar.item".into()],
            collections: vec![],
            // The clock belongs to one Mac's menu bar; the zones you follow and how they read go with you.
            settings: vec![
                SettingSpec::new("clock.enabled", json!(false), Scope::Device, "Show the clock in the menu bar."),
                SettingSpec::new("clock.time_zone", json!(""), Scope::Synced,
                                 "The zone the clock shows, as an IANA identifier; empty follows the device's own zone."),
                SettingSpec::new("clock.other_zones", json!([]), Scope::Synced,
                                 "Other zones listed under the clock with their times, at most 20 IANA identifiers."),
                SettingSpec::new("clock.show_date", json!(true), Scope::Synced, "Show the weekday and date before the time."),
                SettingSpec::new("clock.hour_cycle", json!("system"), Scope::Synced, "12 or 24 hours, or system to follow the device."),
                SettingSpec::new("clock.show_seconds", json!(false), Scope::Synced, "Show seconds; the clock then changes every second."),
                SettingSpec::new("clock.label", json!("city"), Scope::Synced,
                                 "What follows the time: city, abbreviation, offset (from GMT), custom, or none."),
                SettingSpec::new("clock.custom_label", json!(""), Scope::Synced, "The zone's name with clock.label set to custom, at most 40 characters."),
            ],
            commands: vec![],
        }
    }

    fn call(&self, _core: &Core, command: &str, _params: Value) -> Result<Value> {
        Err(NyError::unknown_method(&format!("clock.{command}")))
    }

    fn validate_setting(&self, key: &str, value: &Value) -> Result<()> {
        let text = value.as_str().unwrap_or_default();
        match key {
            "clock.time_zone" if !text.is_empty() && !is_zone_id(text) =>
                Err(NyError::invalid_setting("A time zone must be an identifier such as Asia/Tokyo.")),
            "clock.other_zones" => {
                let zones = value.as_array().map(Vec::as_slice).unwrap_or_default();
                if zones.len() > MAX_OTHER_ZONES || zones.iter().any(|zone| zone.as_str().is_none_or(|id| !is_zone_id(id))) {
                    return Err(NyError::invalid_setting("Other time zones must be identifiers such as Asia/Tokyo, at most 20."));
                }
                Ok(())
            }
            "clock.hour_cycle" if !HOUR_CYCLES.contains(&text) =>
                Err(NyError::invalid_setting("Hours must be 12, 24, or system.")),
            "clock.label" if !LABELS.contains(&text) =>
                Err(NyError::invalid_setting("The label must be city, abbreviation, offset, custom, or none.")),
            "clock.custom_label" if text.chars().count() > MAX_CUSTOM_LABEL || text.contains('\n') =>
                Err(NyError::invalid_setting("The clock’s name must be one line of at most 40 characters.")),
            _ => Ok(()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ny_core::Store;

    fn core() -> Core { Core::new(Store::open_in_memory().unwrap(), crate::all(), "test", Box::new(|_| {})).unwrap() }

    #[test]
    fn zone_identifiers_are_spelled_as_the_databases_do() {
        for id in ["GMT", "UTC", "Asia/Tokyo", "Etc/GMT-9", "Etc/GMT+12", "America/Argentina/Buenos_Aires", "America/Port-au-Prince"] {
            assert!(is_zone_id(id), "{id}");
        }
        for id in ["", "/Asia", "Asia/", "Asia//Tokyo", "Asia/Tokyo ", "../etc/passwd", "Asia\\Tokyo", &"A".repeat(65)] {
            assert!(!is_zone_id(id), "{id}");
        }
    }

    #[test]
    fn off_following_the_device_until_asked_and_bad_values_rejected() {
        let core = core();
        assert!(!core.setting::<bool>("clock.enabled").unwrap());
        assert_eq!(core.setting::<String>("clock.time_zone").unwrap(), "");
        assert_eq!(core.setting::<Vec<String>>("clock.other_zones").unwrap(), Vec::<String>::new());
        assert!(core.setting::<bool>("clock.show_date").unwrap());
        assert_eq!(core.setting::<String>("clock.hour_cycle").unwrap(), "system");
        assert!(!core.setting::<bool>("clock.show_seconds").unwrap());
        assert_eq!(core.setting::<String>("clock.label").unwrap(), "city");

        for (key, value) in [("clock.enabled", json!(true)), ("clock.time_zone", json!("Asia/Tokyo")), ("clock.time_zone", json!("")),
                             ("clock.other_zones", json!(["Europe/London", "America/New_York"])), ("clock.other_zones", json!(vec!["GMT"; 20])),
                             ("clock.hour_cycle", json!("12")), ("clock.hour_cycle", json!("24")), ("clock.show_seconds", json!(true)),
                             ("clock.label", json!("offset")), ("clock.label", json!("none")), ("clock.custom_label", json!("東京オフィス")),
                             ("clock.custom_label", json!("x".repeat(40)))] {
            assert!(core.call("settings.set", json!({ "key": key, "value": value })).is_ok(), "{key} = {value}");
        }
        for (key, value) in [("clock.enabled", json!(1)), ("clock.time_zone", json!("Asia Tokyo")), ("clock.time_zone", json!(9)),
                             ("clock.other_zones", json!(["Europe/London", ""])), ("clock.other_zones", json!([3])),
                             ("clock.other_zones", json!(vec!["GMT"; 21])), ("clock.other_zones", json!("Europe/London")),
                             ("clock.hour_cycle", json!("13")), ("clock.hour_cycle", json!(24)), ("clock.label", json!("zone")),
                             ("clock.custom_label", json!("x".repeat(41))), ("clock.custom_label", json!("two\nlines")),
                             ("clock.show_date", json!("yes"))] {
            assert!(core.call("settings.set", json!({ "key": key, "value": value })).is_err(), "{key} = {value}");
        }
        assert!(core.call("clock.anything", json!({})).is_err());
    }
}
