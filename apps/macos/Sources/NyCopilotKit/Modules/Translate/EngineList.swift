import AppKit

/// Settings → AI & Engines → Translation engines: the translation services in the order they're tried, each with a
/// switch and a one-line status. ▲ ▼ change the order; the next ready service takes over when one fails. The core
/// says which there are, in which order, and whether each is on and set up.
@MainActor
final class EngineList: NSStackView {
    private let services: CopilotServices
    /// As shown, in the order they're tried.
    private var engines: [NyCore.TranslationEngine] = []

    init(services: CopilotServices) {
        self.services = services
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
    }

    required init?(coder: NSCoder) { fatalError("Use init(services:)") }

    func refresh() {
        arrangedSubviews.forEach { $0.removeFromSuperview() }
        engines = services.core.translationEngines()
        let rows = engines.enumerated().map { index, engine -> NSView in
            let toggle = NSSwitch()
            toggle.state = engine.enabled ? .on : .off
            toggle.identifier = NSUserInterfaceItemIdentifier(engine.id)
            toggle.target = self
            toggle.action = #selector(toggle(_:))
            let up = arrow("chevron.up", L("Try earlier"), index: index, enabled: index > 0, action: #selector(tryEarlier(_:)))
            let down = arrow("chevron.down", L("Try later"), index: index, enabled: index < engines.count - 1, action: #selector(tryLater(_:)))
            return FormRow("\(index + 1).  \(L(engine.title))", subtitle: status(of: engine), accessory: Design.hstack([up, down, toggle], spacing: 4))
        }
        let fallback = SystemTranslation.isAvailable
            ? L(" With none ready, macOS’s own translation panel translates what you write or select, on this Mac.") : ""
        let section = FormSection(L("Translation Engines"),
            footer: L("Each translation goes to the first ready engine. If it fails, or doesn’t offer the language, the next one takes over and a short note says so. Only the model follows Translate’s instructions.") + fallback,
            rows: rows)
        addArrangedSubview(section)
        section.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    }

    /// "Ready", what is missing, or "Off".
    private func status(of engine: NyCore.TranslationEngine) -> String {
        guard engine.enabled else { return L("Off") }
        let model = services.preferences.provider.model
        switch (engine.id, engine.configured) {
        case ("model", true): return L("Ready — %@", model)
        case (_, true): return L("Ready")
        case ("google", false): return L("Add a web app URL below")
        case ("volcengine", false): return L("Add a key below")
        default: return L("Connect one above")
        }
    }

    private func arrow(_ symbol: String, _ tip: String, index: Int, enabled: Bool, action: Selector) -> NSButton {
        let button = Design.iconButton(symbol, label: tip, pointSize: 11, weight: .semibold, target: self, action: action)
        button.tag = index
        button.isEnabled = enabled
        return button
    }

    @objc private func tryEarlier(_ sender: NSButton) { move(sender.tag, by: -1) }
    @objc private func tryLater(_ sender: NSButton) { move(sender.tag, by: 1) }

    private func move(_ index: Int, by step: Int) {
        var ids = engines.map(\.id)
        let target = index + step
        guard ids.indices.contains(index), ids.indices.contains(target) else { return }
        ids.swapAt(index, target)
        try? services.core.setSetting(.engineOrder, ids)
        refresh()
    }

    @objc private func toggle(_ sender: NSSwitch) {
        guard let setting = engines.first(where: { $0.id == sender.identifier?.rawValue })?.enabledSetting else { return }
        try? services.core.setSetting(setting, sender.state == .on)
        refresh()
    }
}
