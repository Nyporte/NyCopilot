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
    }

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
            key.onPress = action.handler
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

    /// While a recorder listens, our own shortcuts must not fire or swallow the keystroke.
    func suspendAll() { keys.values.forEach { $0.suspend() } }

    func resumeAll() {
        for (id, key) in keys {
            do { try key.register(combination(for: id)) } catch { problems[id] = error.localizedDescription }
        }
    }
}
