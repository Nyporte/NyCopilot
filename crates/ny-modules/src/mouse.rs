//! Mouse: pointer speed and acceleration beyond what the system's own settings offer.
//!
//! This module owns the settings and how they become a device's pointer parameters. Clients find
//! the connected mice, read the system's acceleration, ask for the parameters, and write them to
//! the device themselves. The model is the one macOS's HID event system uses, and maps onto other
//! systems' speed and "enhance precision" switches:
//!
//! - **Acceleration** picks how much faster movements carry the pointer further. 0 turns it off:
//!   the pointer moves in proportion to the hand at any speed.
//! - **Speed** multiplies how far the pointer goes for the same hand movement. With acceleration,
//!   it sets the resolution (counts per inch) the system treats the mouse as having: 400 at 1×,
//!   half that at 2×. Like Windows, it ignores the resolution a mouse claims, which is often
//!   arbitrary: one mouse can claim 400 on its cable and 1600 through its receiver, for the same
//!   sensor. Without acceleration, it is the points the pointer moves for each count the mouse
//!   reports, as on Windows (one pixel per count at its default speed).
//!
//! The wheel's settings — reversing it, and smooth scrolling that glides each click a set number of
//! lines, as Mos does — are settings only: clients reshape wheel events (never a trackpad's)
//! themselves, since that happens many times a second.

use ny_core::{parse, CommandSpec, Core, Manifest, Module, NyError, Result, Scope, SettingSpec};
use serde::Deserialize;
use serde_json::{json, Value};

/// The speed multiplier's range. Without acceleration, a tenth of a point per count lets a mouse
/// set to a high resolution still move one pixel at a time on a Retina display.
pub const SPEED_RANGE: (f64, f64) = (0.1, 8.0);
/// The acceleration values the system accepts; System Settings offers 0–3.
pub const ACCELERATION_RANGE: (f64, f64) = (0.0, 40.0);
/// `mouse.acceleration` at this value follows the system's own setting.
pub const FOLLOW_SYSTEM: f64 = -1.0;
/// What macOS uses when nothing is set, and the resolution it assumes for a mouse: speed 1×.
const SYSTEM_ACCELERATION: f64 = 0.6875;
const BASE_RESOLUTION: f64 = 400.0;
/// The resolutions the system accepts, in counts per inch.
const RESOLUTION_RANGE: (f64, f64) = (10.0, 1995.0);
/// Lines a smooth wheel click scrolls (Windows scrolls 3), and milliseconds it glides for.
pub const SCROLL_LINES_RANGE: (f64, f64) = (1.0, 10.0);
pub const SCROLL_GLIDE_RANGE: (f64, f64) = (0.0, 600.0);
/// Apps whose wheel scrolls as usual, by bundle identifier.
const MAX_EXCEPTIONS: usize = 100;

/// A device's pointer parameters.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Pointer {
    /// Counts per inch the device is treated as having.
    pub resolution: f64,
    /// The acceleration curve; with `linear`, the points moved per count instead.
    pub acceleration: f64,
    /// Acceleration off: the pointer moves in proportion to the hand.
    pub linear: bool,
}

/// The parameters for a mouse at `speed` and `acceleration` (or the system's, `system`, when
/// following it).
pub fn pointer(speed: f64, acceleration: f64, system: f64) -> Pointer {
    let followed = if acceleration == FOLLOW_SYSTEM { system } else { acceleration };
    // Measured on macOS 14: with linear scaling, each count moves the pointer exactly the
    // acceleration value in points (0.25, 0.5, 1, 2, 3 alike), while a resolution above 400 only
    // drops counts and never makes a step smaller. So speed goes into the value, at 400.
    if followed == 0.0 {
        return Pointer { resolution: BASE_RESOLUTION, acceleration: speed, linear: true };
    }
    let resolution = (BASE_RESOLUTION / speed).clamp(RESOLUTION_RANGE.0, RESOLUTION_RANGE.1);
    Pointer { resolution, acceleration: followed, linear: false }
}

pub struct MouseModule;

impl Module for MouseModule {
    fn manifest(&self) -> Manifest {
        Manifest {
            id: "mouse".into(),
            name: "Mouse".into(),
            summary: "Set the mouse's pointer speed and acceleration beyond the system's own range.".into(),
            capabilities: vec!["pointer.control".into()],
            collections: vec![],
            // A speed suits one mouse on one screen, so these stay on this device.
            settings: vec![
                SettingSpec::new("mouse.enabled", json!(false), Scope::Device, "Set the connected mice's speed and acceleration."),
                SettingSpec::new("mouse.speed", json!(1.0), Scope::Device,
                                 "Pointer speed, 0.1–8: with acceleration, 1 treats the mouse as 400 counts per inch; without, points per count."),
                SettingSpec::new("mouse.acceleration", json!(FOLLOW_SYSTEM), Scope::Device,
                                 "Pointer acceleration, 0 (off) to 40; -1 follows the system's setting."),
                SettingSpec::new("mouse.reverse_scroll", json!(false), Scope::Device,
                                 "Scroll the other way with a mouse wheel; trackpads keep the system's direction."),
                SettingSpec::new("mouse.smooth_scroll", json!(false), Scope::Device, "A wheel click glides instead of jumping."),
                SettingSpec::new("mouse.scroll_lines", json!(3.0), Scope::Device, "Lines a smooth wheel click scrolls, 1–10; quick spins go further."),
                SettingSpec::new("mouse.scroll_glide", json!(200.0), Scope::Device, "Milliseconds a smooth wheel click glides for, 0–600."),
                SettingSpec::new("mouse.scroll_exceptions", json!([]), Scope::Device,
                                 "Bundle identifiers of apps whose wheel scrolls without gliding (games, remote desktops)."),
            ],
            commands: vec![
                CommandSpec::new("pointer", "{system_acceleration?} → {enabled, resolution, acceleration, linear} for every mouse."),
            ],
        }
    }

    fn call(&self, core: &Core, command: &str, params: Value) -> Result<Value> {
        #[derive(Deserialize)]
        struct System { system_acceleration: Option<f64> }
        match command {
            "pointer" => {
                let params: System = parse(params)?;
                // A system that reports nothing (or nonsense) gets macOS's default.
                let system = params.system_acceleration.filter(|a| *a >= 0.0).unwrap_or(SYSTEM_ACCELERATION);
                let p = pointer(core.setting("mouse.speed")?, core.setting("mouse.acceleration")?, system);
                Ok(json!({ "enabled": core.setting::<bool>("mouse.enabled")?, "resolution": p.resolution,
                           "acceleration": p.acceleration, "linear": p.linear }))
            }
            _ => Err(NyError::unknown_method(&format!("mouse.{command}"))),
        }
    }

    fn validate_setting(&self, key: &str, value: &Value) -> Result<()> {
        let number = value.as_f64().unwrap_or(f64::NAN);
        match key {
            "mouse.speed" if !(SPEED_RANGE.0..=SPEED_RANGE.1).contains(&number) =>
                Err(NyError::invalid_setting("The speed must be between 0.1 and 8.")),
            "mouse.acceleration" if number != FOLLOW_SYSTEM && !(ACCELERATION_RANGE.0..=ACCELERATION_RANGE.1).contains(&number) =>
                Err(NyError::invalid_setting("The acceleration must be between 0 and 40, or -1 to follow the system.")),
            "mouse.scroll_lines" if !(SCROLL_LINES_RANGE.0..=SCROLL_LINES_RANGE.1).contains(&number) =>
                Err(NyError::invalid_setting("A click must scroll between 1 and 10 lines.")),
            "mouse.scroll_glide" if !(SCROLL_GLIDE_RANGE.0..=SCROLL_GLIDE_RANGE.1).contains(&number) =>
                Err(NyError::invalid_setting("The glide must be between 0 and 600 milliseconds.")),
            "mouse.scroll_exceptions" => {
                let apps = value.as_array().map(Vec::as_slice).unwrap_or_default();
                if apps.len() > MAX_EXCEPTIONS || apps.iter().any(|app| app.as_str().is_none_or(|id| id.is_empty() || id.len() > 255)) {
                    return Err(NyError::invalid_setting("Apps must be listed by bundle identifier, at most 100."));
                }
                Ok(())
            }
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
    fn speed_divides_a_fixed_resolution_whatever_the_mouse_claims() {
        assert_eq!(pointer(1.0, 1.0, 3.0).resolution, 400.0);
        assert_eq!(pointer(2.0, 1.0, 3.0).resolution, 200.0);
        assert_eq!(pointer(0.25, 1.0, 3.0).resolution, 1600.0);
        assert_eq!(pointer(0.1, 1.0, 3.0).resolution, 1995.0);
        assert_eq!(pointer(8.0, 1.0, 3.0).resolution, 50.0);
    }

    #[test]
    fn acceleration_follows_the_system_until_set_and_zero_turns_it_off() {
        assert_eq!(pointer(1.0, FOLLOW_SYSTEM, 3.0), Pointer { resolution: 400.0, acceleration: 3.0, linear: false });
        assert_eq!(pointer(1.0, 1.5, 3.0), Pointer { resolution: 400.0, acceleration: 1.5, linear: false });
        // Off moves `speed` points per count, whatever the system's tracking speed.
        assert_eq!(pointer(1.0, 0.0, 3.0), Pointer { resolution: 400.0, acceleration: 1.0, linear: true });
        assert_eq!(pointer(0.5, 0.0, 3.0), Pointer { resolution: 400.0, acceleration: 0.5, linear: true });
        // The system's own setting can be off too.
        assert!(pointer(1.0, FOLLOW_SYSTEM, 0.0).linear);
    }

    #[test]
    fn module_reads_settings_and_rejects_bad_values() {
        let core = core();
        let defaults = core.call("mouse.pointer", json!({ "system_acceleration": 3 })).unwrap();
        assert_eq!(defaults, json!({ "enabled": false, "resolution": 400.0, "acceleration": 3.0, "linear": false }));

        core.call("settings.set", json!({ "key": "mouse.enabled", "value": true })).unwrap();
        core.call("settings.set", json!({ "key": "mouse.speed", "value": 2.5 })).unwrap();
        core.call("settings.set", json!({ "key": "mouse.acceleration", "value": 0.0 })).unwrap();
        let set = core.call("mouse.pointer", json!({ "system_acceleration": 0.6875 })).unwrap();
        assert_eq!(set, json!({ "enabled": true, "resolution": 400.0, "acceleration": 2.5, "linear": true }));

        // Following a system that reports nothing gets macOS's default acceleration.
        core.call("settings.set", json!({ "key": "mouse.acceleration", "value": FOLLOW_SYSTEM })).unwrap();
        let unknown = core.call("mouse.pointer", json!({})).unwrap();
        assert_eq!((unknown["resolution"].as_f64(), unknown["acceleration"].as_f64()), (Some(160.0), Some(SYSTEM_ACCELERATION)));

        for (key, value) in [("mouse.speed", json!(0.05)), ("mouse.speed", json!(9)), ("mouse.acceleration", json!(-0.5)),
                             ("mouse.acceleration", json!(41)), ("mouse.enabled", json!(1)),
                             ("mouse.reverse_scroll", json!("yes"))] {
            assert!(core.call("settings.set", json!({ "key": key, "value": value })).is_err(), "{key} = {value}");
        }
    }

    #[test]
    fn smooth_scrolling_settings_keep_to_their_ranges() {
        let core = core();
        for (key, value) in [("mouse.smooth_scroll", json!(true)), ("mouse.scroll_lines", json!(1.5)), ("mouse.scroll_glide", json!(0)),
                             ("mouse.scroll_exceptions", json!(["com.rustdesk.RustDesk", "com.parallels.desktop.console"]))] {
            assert!(core.call("settings.set", json!({ "key": key, "value": value })).is_ok(), "{key} = {value}");
        }
        for (key, value) in [("mouse.scroll_lines", json!(0.5)), ("mouse.scroll_lines", json!(11)), ("mouse.scroll_glide", json!(-1)),
                             ("mouse.scroll_glide", json!(601)), ("mouse.scroll_exceptions", json!([""])),
                             ("mouse.scroll_exceptions", json!([3])), ("mouse.scroll_exceptions", json!(vec!["a"; 101]))] {
            assert!(core.call("settings.set", json!({ "key": key, "value": value })).is_err(), "{key} = {value}");
        }
        assert!(core.call("settings.set", json!({ "key": "mouse.acceleration", "value": FOLLOW_SYSTEM })).is_ok());
    }
}
