import AppKit
import MacPlatform

/// Every module's global shortcuts in one place, so Settings can list and edit them uniformly.
@MainActor
final class HotKeyCenter {
    struct Action {
        let id: String
        let title: String
        let defaultCombination: HotKeyCombination?
        let handler: () -> Void
        /// Holding the shortcut does something else. Then a tap acts when the key comes up, and a
        /// hold acts once it has been down for `holdDuration`.
        var longPress: (() -> Void)? = nil
    }

    static let holdDuration: TimeInterval = 0.35
    private var holds: [String: DispatchWorkItem] = [:]
    /// Shortcuts down right now: a press counts once until its release, even if the key repeats.
    private var down: Set<String> = []

    private(set) var actions: [Action] = []
    private var keys: [String: GlobalHotKey] = [:]
    /// Registration problems found at launch, keyed by action, for Settings to surface.
    private(set) var problems: [String: String] = [:]
    private let preferences: Preferences

    init(preferences: Preferences) { self.preferences = preferences }

    func add(_ action: Action) {
        actions.append(action)
        do {
            let key = try GlobalHotKey(identifier: UInt32(actions.count))
            if let longPress = action.longPress {
                key.onPress = { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.down.insert(action.id).inserted else { return }
                        let hold = DispatchWorkItem { [weak self] in
                            self?.holds[action.id] = nil
                            longPress()
                        }
                        self.holds[action.id] = hold
                        DispatchQueue.main.asyncAfter(deadline: .now() + Self.holdDuration, execute: hold)
                    }
                }
                key.onRelease = { [weak self] in
                    MainActor.assumeIsolated {
                        self?.down.remove(action.id)
                        // Still waiting: it was a tap. Already fired: the hold is over.
                        guard let hold = self?.holds.removeValue(forKey: action.id) else { return }
                        hold.cancel()
                        action.handler()
                    }
                }
            } else {
                key.onPress = action.handler
            }
            keys[action.id] = key
            try key.register(combination(for: action.id))
        } catch {
            problems[action.id] = error.localizedDescription
        }
    }

    func combination(for id: String) -> HotKeyCombination? {
        guard let action = actions.first(where: { $0.id == id }) else { return nil }
        return preferences.hotKey(for: id, default: action.defaultCombination)
    }

    /// Register first and persist only on success, so a conflict never leaves an action unbound.
    func set(_ combination: HotKeyCombination?, for id: String) throws {
        guard let key = keys[id] else { return }
        try key.register(combination)
        problems[id] = nil
        preferences.setHotKey(combination, for: id)
    }

    /// Apply many shortcuts at once. Every changing action is released first, so actions can swap
    /// keys without colliding with each other. Returns failures (for example, a key another app owns).
    @discardableResult
    func set(_ changes: [String: HotKeyCombination?]) -> [String: String] {
        let ids = changes.keys.filter { keys[$0] != nil }.sorted()
        for id in ids { try? keys[id]?.register(nil) }
        var failures: [String: String] = [:]
        for id in ids {
            let combination = changes[id] ?? nil
            preferences.setHotKey(combination, for: id)
            do {
                try keys[id]?.register(combination)
                problems[id] = nil
            } catch {
                failures[id] = error.localizedDescription
                problems[id] = error.localizedDescription
            }
        }
        return failures
    }

    /// Whether the user has changed any of these actions from their defaults.
    func isCustomized(_ ids: [String]) -> Bool { ids.contains { preferences.hasStoredHotKey(for: $0) } }

    /// While a recorder listens, our own shortcuts must not fire or swallow the keystroke.
    func suspendAll() { keys.values.forEach { $0.suspend() } }

    func resumeAll() {
        for (id, key) in keys {
            do { try key.register(combination(for: id)) } catch { problems[id] = error.localizedDescription }
        }
    }
}
