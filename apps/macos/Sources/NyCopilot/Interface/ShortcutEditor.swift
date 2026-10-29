import AppKit

/// Shortcut rows for a module's Settings pane. Each pane shows its own module's shortcuts, so
/// adding a module never crowds the General tab.
@MainActor
final class ShortcutEditor {
    /// Shows conflicts and invalid combinations below the pane's shortcut sections.
    let errorLabel = Design.wrapping("", size: 11.5, color: .systemRed)
    private let services: CopilotServices
    private var recorders: [String: ShortcutRecorder] = [:]

    init(services: CopilotServices) {
        self.services = services
        errorLabel.isHidden = true
    }

    /// One grouped section with a recorder per action. Unknown action ids are skipped.
    func section(_ title: String, footer: String? = nil, actions ids: [String]) -> FormSection {
        let rows: [NSView] = ids.compactMap { id in
            guard let action = services.hotKeys.actions.first(where: { $0.id == id }) else { return nil }
            let recorder = ShortcutRecorder()
            recorder.onChange = { [weak self] value in
                guard let self else { return nil }
                do { try services.hotKeys.set(value, for: id); return nil } catch { return error.localizedDescription }
            }
            recorder.onRecordingChange = { [weak self] recording in
                if recording { self?.services.hotKeys.suspendAll() } else { self?.services.hotKeys.resumeAll() }
            }
            recorder.onError = { [weak self] message in self?.show(message) }
            recorders[id] = recorder
            return FormRow(action.title, accessory: recorder)
        }
        return FormSection(title, footer: footer, rows: rows)
    }

    /// Reload current shortcuts and any registration problems, e.g. when the pane appears.
    func refresh() {
        for (id, recorder) in recorders { recorder.combination = services.hotKeys.combination(for: id) }
        show(recorders.keys.sorted().compactMap { services.hotKeys.problems[$0] }.first)
    }

    private func show(_ message: String?) {
        errorLabel.stringValue = message ?? ""
        errorLabel.isHidden = message == nil
    }
}
