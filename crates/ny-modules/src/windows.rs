//! Window Layouts: snap windows into halves, corners, thirds, and more, by shortcut or by dragging.
//!
//! This module owns only geometry. Clients find the focused window and the screen it is on, ask
//! for a target frame, and move the window themselves. All rectangles use a top-left origin with
//! y growing downward (the convention of macOS Accessibility and Windows alike); screens are their
//! usable area, without menu bars, docks, or taskbars.

use ny_core::{parse, CommandSpec, Core, Manifest, Module, NyError, Result, Scope, SettingSpec};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub w: f64,
    pub h: f64,
}

impl Rect {
    pub fn new(x: f64, y: f64, w: f64, h: f64) -> Self { Self { x, y, w, h } }
    fn max_x(&self) -> f64 { self.x + self.w }
    fn max_y(&self) -> f64 { self.y + self.h }
    fn center(&self) -> (f64, f64) { (self.x + self.w / 2.0, self.y + self.h / 2.0) }

    /// Keep the rectangle on `bounds`, shrinking it only if it is larger.
    fn clamped(self, bounds: Rect) -> Rect {
        let w = self.w.min(bounds.w);
        let h = self.h.min(bounds.h);
        Rect::new(self.x.clamp(bounds.x, bounds.max_x() - w), self.y.clamp(bounds.y, bounds.max_y() - h), w, h)
    }
}

/// `(id, title, group)` for every action, in menu order. Clients localize titles later if needed.
pub const ACTIONS: &[(&str, &str, &str)] = &[
    ("left_half", "Left Half", "Halves"),
    ("right_half", "Right Half", "Halves"),
    ("top_half", "Top Half", "Halves"),
    ("bottom_half", "Bottom Half", "Halves"),
    ("top_left", "Top Left", "Corners"),
    ("top_right", "Top Right", "Corners"),
    ("bottom_left", "Bottom Left", "Corners"),
    ("bottom_right", "Bottom Right", "Corners"),
    ("first_third", "First Third", "Thirds"),
    ("center_third", "Center Third", "Thirds"),
    ("last_third", "Last Third", "Thirds"),
    ("first_two_thirds", "First Two Thirds", "Thirds"),
    ("last_two_thirds", "Last Two Thirds", "Thirds"),
    ("maximize", "Maximize", "Size and Position"),
    ("almost_maximize", "Almost Maximize", "Size and Position"),
    ("maximize_height", "Maximize Height", "Size and Position"),
    ("center", "Center", "Size and Position"),
    ("larger", "Make Larger", "Size and Position"),
    ("smaller", "Make Smaller", "Size and Position"),
    ("restore", "Restore", "Size and Position"),
    ("next_display", "Next Display", "Displays"),
    ("previous_display", "Previous Display", "Displays"),
];

/// Halves cycle through these widths when their shortcut is repeated.
const CYCLE: [f64; 3] = [1.0 / 2.0, 2.0 / 3.0, 1.0 / 3.0];

/// What pressing the same layout shortcut again does.
pub const REPEAT_MODES: &[&str] = &["cycle_sizes", "move_across_displays", "nothing"];

/// With `move_across_displays`, repeating a side layout carries the window to the neighbouring
/// display in that direction, landing on the mirrored layout so it keeps travelling the same way:
/// a second Left Half puts it in the right half of the display to the left.
pub fn travel(action: &str) -> Option<(&'static str, &'static str)> {
    Some(match action {
        "left_half" => ("left", "right_half"),
        "right_half" => ("right", "left_half"),
        "top_left" => ("left", "top_right"),
        "bottom_left" => ("left", "bottom_right"),
        "top_right" => ("right", "top_left"),
        "bottom_right" => ("right", "bottom_left"),
        "first_third" => ("left", "last_third"),
        "last_third" => ("right", "first_third"),
        "first_two_thirds" => ("left", "last_two_thirds"),
        "last_two_thirds" => ("right", "first_two_thirds"),
        _ => return None,
    })
}
const RESIZE_STEP: f64 = 30.0;

/// A tile spanning fractions `[x0, x1] × [y0, y1]` of `screen`, with `gap` around and between tiles.
fn tile(screen: Rect, gap: f64, (x0, x1): (f64, f64), (y0, y1): (f64, f64)) -> Rect {
    let usable_w = screen.w - gap;
    let usable_h = screen.h - gap;
    Rect::new(screen.x + gap + x0 * usable_w, screen.y + gap + y0 * usable_h,
              (x1 - x0) * usable_w - gap, (y1 - y0) * usable_h - gap)
}

/// The frame `action` gives `window` on `screen`. `repeat` counts how many times in a row the
/// same action was already applied to this window (0 for the first press).
pub fn compute(action: &str, window: Rect, screen: Rect, gap: f64, repeat: u32, cycle: bool) -> Result<Rect> {
    let full = (0.0, 1.0);
    let step = if cycle { CYCLE[repeat as usize % CYCLE.len()] } else { 0.5 };
    // Thirds follow the screen's long side, so they stack vertically on a portrait display.
    let portrait = screen.h > screen.w;
    let along = |range: (f64, f64)| if portrait { tile(screen, gap, full, range) } else { tile(screen, gap, range, full) };
    let frame = match action {
        "left_half" => tile(screen, gap, (0.0, step), full),
        "right_half" => tile(screen, gap, (1.0 - step, 1.0), full),
        "top_half" => tile(screen, gap, full, (0.0, step)),
        "bottom_half" => tile(screen, gap, full, (1.0 - step, 1.0)),
        "top_left" => tile(screen, gap, (0.0, 0.5), (0.0, 0.5)),
        "top_right" => tile(screen, gap, (0.5, 1.0), (0.0, 0.5)),
        "bottom_left" => tile(screen, gap, (0.0, 0.5), (0.5, 1.0)),
        "bottom_right" => tile(screen, gap, (0.5, 1.0), (0.5, 1.0)),
        "first_third" => along((0.0, 1.0 / 3.0)),
        "center_third" => along((1.0 / 3.0, 2.0 / 3.0)),
        "last_third" => along((2.0 / 3.0, 1.0)),
        "first_two_thirds" => along((0.0, 2.0 / 3.0)),
        "last_two_thirds" => along((1.0 / 3.0, 1.0)),
        "maximize" => tile(screen, gap, full, full),
        "almost_maximize" => {
            let (w, h) = (screen.w * 0.9, screen.h * 0.9);
            Rect::new(screen.x + (screen.w - w) / 2.0, screen.y + (screen.h - h) / 2.0, w, h)
        }
        "maximize_height" => Rect::new(window.x, screen.y + gap, window.w, screen.h - 2.0 * gap).clamped(screen),
        "center" => {
            let fitted = Rect::new(0.0, 0.0, window.w.min(screen.w), window.h.min(screen.h));
            Rect::new(screen.x + (screen.w - fitted.w) / 2.0, screen.y + (screen.h - fitted.h) / 2.0, fitted.w, fitted.h)
        }
        "larger" => Rect::new(window.x - RESIZE_STEP, window.y - RESIZE_STEP,
                              window.w + 2.0 * RESIZE_STEP, window.h + 2.0 * RESIZE_STEP).clamped(screen),
        "smaller" => {
            let w = (window.w - 2.0 * RESIZE_STEP).max((screen.w / 4.0).min(window.w));
            let h = (window.h - 2.0 * RESIZE_STEP).max((screen.h / 4.0).min(window.h));
            let (cx, cy) = window.center();
            Rect::new(cx - w / 2.0, cy - h / 2.0, w, h).clamped(screen)
        }
        _ => return Err(NyError::invalid_params(format!("Unknown window action “{action}”."))),
    };
    Ok(round(frame))
}

/// Keep the window's position and size relative to its screen when moving it to another one.
pub fn move_to_screen(window: Rect, from: Rect, to: Rect) -> Rect {
    let sx = to.w / from.w.max(1.0);
    let sy = to.h / from.h.max(1.0);
    let w = (window.w * sx).min(to.w);
    let h = (window.h * sy).min(to.h);
    round(Rect::new(to.x + (window.x - from.x) * sx, to.y + (window.y - from.y) * sy, w, h).clamped(to))
}

/// Which action a drag ends in when the pointer is at `point` on `screen`: corners first, then edges.
pub fn snap_area(point: (f64, f64), screen: Rect, margin: f64, corner: f64) -> Option<&'static str> {
    let (x, y) = point;
    let near_left = x <= screen.x + margin;
    let near_right = x >= screen.max_x() - margin;
    let near_top = y <= screen.y + margin;
    let near_bottom = y >= screen.max_y() - margin;
    let in_left = x <= screen.x + corner;
    let in_right = x >= screen.max_x() - corner;
    let in_top = y <= screen.y + corner;
    let in_bottom = y >= screen.max_y() - corner;
    Some(match () {
        _ if (near_left && in_top) || (near_top && in_left) => "top_left",
        _ if (near_right && in_top) || (near_top && in_right) => "top_right",
        _ if (near_left && in_bottom) || (near_bottom && in_left) => "bottom_left",
        _ if (near_right && in_bottom) || (near_bottom && in_right) => "bottom_right",
        _ if near_left => "left_half",
        _ if near_right => "right_half",
        _ if near_top => "maximize",
        _ if near_bottom => {
            let third = (x - screen.x) / screen.w * 3.0;
            if third < 1.0 { "first_third" } else if third < 2.0 { "center_third" } else { "last_third" }
        }
        _ => return None,
    })
}

/// Whole points avoid sub-pixel frames that some apps round inconsistently.
fn round(rect: Rect) -> Rect { Rect::new(rect.x.round(), rect.y.round(), rect.w.round(), rect.h.round()) }

pub struct WindowsModule;

impl WindowsModule {
    fn gap(core: &Core) -> Result<f64> { core.setting::<f64>("windows.gap") }
}

impl Module for WindowsModule {
    fn manifest(&self) -> Manifest {
        Manifest {
            id: "windows".into(),
            name: "Window Layouts".into(),
            summary: "Snap windows into halves, corners, and thirds with shortcuts or by dragging.".into(),
            capabilities: vec!["window.control".into(), "hotkey".into(), "pointer.watch".into()],
            collections: vec![],
            settings: vec![
                SettingSpec::new("windows.gap", json!(0), Scope::Synced, "Space in points around and between snapped windows."),
                SettingSpec::new("windows.repeat", json!("cycle_sizes"), Scope::Synced,
                                 "Repeating a layout shortcut: cycle_sizes (½ → ⅔ → ⅓), move_across_displays, or nothing."),
                SettingSpec::new("windows.drag_snap", json!(true), Scope::Synced, "Snap windows dragged to screen edges and corners."),
            ],
            commands: vec![
                CommandSpec::new("actions", "Every action: [{id, title, group}]."),
                CommandSpec::new("compute", "{action, window, screen, repeat?} → {frame}, or {move: {direction, action}} to continue on a neighbouring display."),
                CommandSpec::new("move_to_screen", "{window, from, to} → {frame}."),
                CommandSpec::new("snap_area", "{point: {x, y}, screen} → {action?, frame?} for drag snapping."),
            ],
        }
    }

    fn call(&self, core: &Core, command: &str, params: Value) -> Result<Value> {
        #[derive(Deserialize)]
        struct Compute { action: String, window: Rect, screen: Rect, #[serde(default)] repeat: u32 }
        #[derive(Deserialize)]
        struct Move { window: Rect, from: Rect, to: Rect }
        #[derive(Deserialize)]
        struct Point { x: f64, y: f64 }
        #[derive(Deserialize)]
        struct Snap { point: Point, screen: Rect }
        match command {
            "actions" => Ok(json!(ACTIONS.iter().map(|(id, title, group)| json!({ "id": id, "title": title, "group": group }))
                .collect::<Vec<_>>())),
            "compute" => {
                let p: Compute = parse(params)?;
                let mode = core.setting::<String>("windows.repeat")?;
                if p.repeat > 0 && mode == "move_across_displays" {
                    if let Some((direction, action)) = travel(&p.action) {
                        return Ok(json!({ "frame": null, "move": { "direction": direction, "action": action } }));
                    }
                }
                let frame = compute(&p.action, p.window, p.screen, Self::gap(core)?, p.repeat, mode == "cycle_sizes")?;
                Ok(json!({ "frame": frame }))
            }
            "move_to_screen" => {
                let p: Move = parse(params)?;
                Ok(json!({ "frame": move_to_screen(p.window, p.from, p.to) }))
            }
            "snap_area" => {
                let p: Snap = parse(params)?;
                match snap_area((p.point.x, p.point.y), p.screen, 6.0, 120.0) {
                    Some(action) => {
                        let frame = compute(action, p.screen, p.screen, Self::gap(core)?, 0, false)?;
                        Ok(json!({ "action": action, "frame": frame }))
                    }
                    None => Ok(json!({ "action": null, "frame": null })),
                }
            }
            _ => Err(NyError::unknown_method(&format!("windows.{command}"))),
        }
    }

    fn validate_setting(&self, key: &str, value: &Value) -> Result<()> {
        match key {
            "windows.gap" if !value.as_f64().is_some_and(|gap| (0.0..=60.0).contains(&gap)) =>
                Err(NyError::invalid_setting("The gap must be between 0 and 60 points.")),
            "windows.repeat" if !REPEAT_MODES.contains(&value.as_str().unwrap_or_default()) =>
                Err(NyError::invalid_setting("Choose cycle_sizes, move_across_displays, or nothing.")),
            _ => Ok(()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ny_core::Store;

    const SCREEN: Rect = Rect { x: 0.0, y: 25.0, w: 1440.0, h: 875.0 };
    const WINDOW: Rect = Rect { x: 100.0, y: 100.0, w: 800.0, h: 600.0 };

    fn frame(action: &str) -> Rect { compute(action, WINDOW, SCREEN, 0.0, 0, true).unwrap() }

    #[test]
    fn halves_corners_and_thirds_tile_the_screen() {
        assert_eq!(frame("left_half"), Rect::new(0.0, 25.0, 720.0, 875.0));
        assert_eq!(frame("right_half"), Rect::new(720.0, 25.0, 720.0, 875.0));
        assert_eq!(frame("bottom_half"), Rect::new(0.0, 463.0, 1440.0, 438.0));
        assert_eq!(frame("top_right"), Rect::new(720.0, 25.0, 720.0, 438.0));
        assert_eq!(frame("center_third"), Rect::new(480.0, 25.0, 480.0, 875.0));
        assert_eq!(frame("last_two_thirds"), Rect::new(480.0, 25.0, 960.0, 875.0));
        assert_eq!(frame("maximize"), SCREEN);
    }

    #[test]
    fn gaps_surround_and_separate_tiles() {
        let left = compute("left_half", WINDOW, SCREEN, 10.0, 0, true).unwrap();
        let right = compute("right_half", WINDOW, SCREEN, 10.0, 0, true).unwrap();
        assert_eq!(left.x, 10.0);
        assert_eq!(right.x - left.max_x(), 10.0);
        assert_eq!(SCREEN.max_x() - right.max_x(), 10.0);
        assert_eq!(left.y, 35.0);
        assert_eq!(left.max_y(), SCREEN.max_y() - 10.0);
    }

    #[test]
    fn repeating_a_half_cycles_its_width() {
        let widths: Vec<f64> = (0..4).map(|n| compute("left_half", WINDOW, SCREEN, 0.0, n, true).unwrap().w).collect();
        assert_eq!(widths, vec![720.0, 960.0, 480.0, 720.0]);
        assert_eq!(compute("right_half", WINDOW, SCREEN, 0.0, 1, false).unwrap().w, 720.0);
        assert_eq!(compute("right_half", WINDOW, SCREEN, 0.0, 1, true).unwrap().x, 480.0);
    }

    #[test]
    fn thirds_stack_vertically_on_portrait_screens() {
        let portrait = Rect::new(1440.0, 0.0, 1080.0, 1920.0);
        assert_eq!(compute("first_third", WINDOW, portrait, 0.0, 0, true).unwrap(), Rect::new(1440.0, 0.0, 1080.0, 640.0));
    }

    #[test]
    fn center_resize_and_display_moves_stay_on_screen() {
        assert_eq!(frame("center"), Rect::new(320.0, 163.0, 800.0, 600.0));
        let huge = Rect::new(0.0, 0.0, 3000.0, 2000.0);
        assert_eq!(compute("center", huge, SCREEN, 0.0, 0, true).unwrap(), SCREEN);
        let larger = frame("larger");
        assert_eq!((larger.w, larger.h), (860.0, 660.0));
        let smaller = compute("smaller", Rect::new(0.0, 25.0, 400.0, 260.0), SCREEN, 0.0, 0, true).unwrap();
        assert_eq!((smaller.w, smaller.h), (360.0, 219.0)); // stops at a quarter of the screen
        let external = Rect::new(1440.0, 0.0, 2560.0, 1415.0);
        let moved = move_to_screen(frame("right_half"), SCREEN, external);
        assert_eq!(moved, Rect::new(2720.0, 0.0, 1280.0, 1415.0));
    }

    #[test]
    fn snap_areas_prefer_corners_over_edges() {
        assert_eq!(snap_area((2.0, 30.0), SCREEN, 6.0, 120.0), Some("top_left"));
        assert_eq!(snap_area((2.0, 400.0), SCREEN, 6.0, 120.0), Some("left_half"));
        assert_eq!(snap_area((1439.0, 899.0), SCREEN, 6.0, 120.0), Some("bottom_right"));
        assert_eq!(snap_area((700.0, 26.0), SCREEN, 6.0, 120.0), Some("maximize"));
        assert_eq!(snap_area((700.0, 899.0), SCREEN, 6.0, 120.0), Some("center_third"));
        assert_eq!(snap_area((700.0, 400.0), SCREEN, 6.0, 120.0), None);
    }

    #[test]
    fn module_reads_settings_and_rejects_bad_input() {
        let core = Core::new(Store::open_in_memory().unwrap(), crate::all(), "test", Box::new(|_| {})).unwrap();
        core.call("settings.set", json!({ "key": "windows.gap", "value": 8 })).unwrap();
        assert!(core.call("settings.set", json!({ "key": "windows.gap", "value": 100 })).is_err());
        let result = core.call("windows.compute", json!({ "action": "maximize", "window": WINDOW, "screen": SCREEN })).unwrap();
        assert_eq!(result["frame"], json!({ "x": 8.0, "y": 33.0, "w": 1424.0, "h": 859.0 }));
        assert_eq!(core.call("windows.compute", json!({ "action": "fly", "window": WINDOW, "screen": SCREEN })).unwrap_err().code, "invalid_params");
        let snap = core.call("windows.snap_area", json!({ "point": { "x": 1, "y": 500 }, "screen": SCREEN })).unwrap();
        assert_eq!(snap["action"], "left_half");
        assert_eq!(core.call("windows.actions", Value::Null).unwrap().as_array().unwrap().len(), ACTIONS.len());
    }

    #[test]
    fn repeat_mode_decides_what_a_second_press_does() {
        let core = Core::new(Store::open_in_memory().unwrap(), crate::all(), "test", Box::new(|_| {})).unwrap();
        let press = |action: &str, repeat: u32| core.call("windows.compute",
            json!({ "action": action, "window": WINDOW, "screen": SCREEN, "repeat": repeat })).unwrap();
        assert_eq!(press("left_half", 1)["frame"]["w"], json!(960.0));
        assert!(core.call("settings.set", json!({ "key": "windows.repeat", "value": "sideways" })).is_err());

        core.call("settings.set", json!({ "key": "windows.repeat", "value": "move_across_displays" })).unwrap();
        assert_eq!(press("left_half", 1)["move"], json!({ "direction": "left", "action": "right_half" }));
        assert_eq!(press("bottom_right", 2)["move"], json!({ "direction": "right", "action": "bottom_left" }));
        // The first press, and layouts with no direction, still just arrange the window.
        assert_eq!(press("left_half", 0)["frame"]["w"], json!(720.0));
        assert_eq!(press("maximize", 1)["frame"]["w"], json!(1440.0));

        core.call("settings.set", json!({ "key": "windows.repeat", "value": "nothing" })).unwrap();
        assert_eq!(press("left_half", 1)["frame"]["w"], json!(720.0));
    }
}
