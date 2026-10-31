import AppKit
import MacPlatform

/// Brings shortcuts over from Rectangle, so switching window managers keeps your muscle memory.
///
/// Rectangle stores only the shortcuts you changed, as `{keyCode, modifierFlags}` with Cocoa
/// modifier flags; untouched actions use its defaults, which match NyCopilot's ⌃⌥ set.
enum RectangleImport {
    static let suite = "com.knollsoft.Rectangle"

    /// Rectangle action names and the Window Layouts action each one becomes.
    private static let actions: [String: String] = [
        "leftHalf": "left_half", "rightHalf": "right_half", "topHalf": "top_half", "bottomHalf": "bottom_half",
        "topLeft": "top_left", "topRight": "top_right", "bottomLeft": "bottom_left", "bottomRight": "bottom_right",
        "firstThird": "first_third", "centerThird": "center_third", "lastThird": "last_third",
        "firstTwoThirds": "first_two_thirds", "lastTwoThirds": "last_two_thirds",
        "maximize": "maximize", "almostMaximize": "almost_maximize", "maximizeHeight": "maximize_height",
        "center": "center", "larger": "larger", "smaller": "smaller", "restore": "restore",
        "nextDisplay": "next_display", "previousDisplay": "previous_display"
    ]

    struct Result {
        /// Window Layouts action id (without the `windows.` prefix) → shortcut, nil meaning turned off.
        var shortcuts: [String: HotKeyCombination?] = [:]
        /// Rectangle actions with no Window Layouts equivalent, such as Todo mode.
        var skipped: [String] = []
        /// What repeating a shortcut does, as a `windows.repeat` value.
        var repeatMode: String?
    }

    /// Rectangle's `subsequentExecutionMode`: 0 resize, 1 across displays, 2 none,
    /// 3 across displays and resize, 4 cycle displays. The display modes all map to travelling.
    private static let repeatModes = [0: "cycle_sizes", 1: "move_across_displays", 2: "nothing",
                                      3: "move_across_displays", 4: "move_across_displays"]

    /// Only Rectangle's own settings, never the global domain a suite lookup would merge in.
    private static var domain: [String: Any]? { UserDefaults.standard.persistentDomain(forName: suite) }

    static var isAvailable: Bool { domain?["lastVersion"] != nil }

    static func read() -> Result {
        var result = Result()
        result.repeatMode = (domain?["subsequentExecutionMode"] as? NSNumber).flatMap { repeatModes[$0.intValue] }
        for (key, value) in domain ?? [:] {
            guard let entry = value as? [String: Any], entry.isEmpty || entry["keyCode"] != nil else { continue }
            guard let action = actions[key] else { result.skipped.append(key); continue }
            guard let keyCode = (entry["keyCode"] as? NSNumber)?.intValue, keyCode >= 0,
                  let flags = (entry["modifierFlags"] as? NSNumber)?.uintValue else {
                result.shortcuts[action] = .some(nil)
                continue
            }
            let combination = HotKeyCombination(keyCode: UInt32(keyCode),
                                                 modifiers: KeyNames.carbonModifiers(NSEvent.ModifierFlags(rawValue: flags)))
            result.shortcuts[action] = combination.isValid ? combination : .some(nil)
        }
        result.skipped.sort()
        return result
    }

    /// Apply shortcuts (and the repeat behaviour, if found); returns a one-line summary for the UI.
    @MainActor
    static func apply(_ result: Result, to services: CopilotServices) -> (summary: String, failed: Int) {
        let failures = services.hotKeys.set(Dictionary(uniqueKeysWithValues: result.shortcuts.map { ("windows.\($0.key)", $0.value) }))
        var summary = result.shortcuts.isEmpty
            ? L("Rectangle uses its default shortcuts, which NyCopilot already matches.")
            : L("Imported %ld shortcuts from Rectangle.", result.shortcuts.count)
        if let mode = result.repeatMode, (try? services.core.setSetting(.windowRepeat, mode)) != nil {
            summary += mode == "move_across_displays" ? L(" Repeating a shortcut now moves the window to the next display.")
                : mode == "nothing" ? L(" Repeating a shortcut now does nothing.") : ""
        }
        if !result.skipped.isEmpty {
            summary += L(" Skipped %ld Rectangle-only actions (%@).", result.skipped.count, ListFormatter.localizedString(byJoining: result.skipped))
        }
        if !failures.isEmpty { summary += L(" %ld couldn’t be registered; quit Rectangle and import again.", failures.count) }
        return (summary, failures.count)
    }
}
