import AppKit

/// Settings → AI & Engines → Translation engines: the translation services in the order they're tried, each with a
/// switch and a one-line status. ▲ ▼ change the order; the next ready service takes over when one fails.
@MainActor
final class EngineList: NSStackView {
    struct Engine {
        let id: String
        let name: String
        let enabled: SettingKey
        /// "Ready", or what is missing.
        let status: () -> String
    }

    private let services: CopilotServices
    private let engines: [Engine]

    init(services: CopilotServices) {
        self.services = services
        let core = services.core
        engines = [
            Engine(id: "google", name: "Google Translate", enabled: .googleEnabled) {
                core.setting(.googleURL, default: "").isEmpty ? "Add a web app URL below" : "Ready"
            },
            Engine(id: "volcengine", name: "Volcengine", enabled: .volcengineEnabled) {
                KeychainStore.hasKey(.volcengine) ? "Ready" : "Add a key below"
            },
            Engine(id: "model", name: "Model", enabled: .modelEnabled) {
                services.preferences.provider.isComplete ? "Ready — \(services.preferences.provider.model)" : "Connect one above"
            }
        ]
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
    }

    required init?(coder: NSCoder) { fatalError("Use init(services:)") }

    /// Saved order first; any engine it doesn't mention follows, as in the core.
    private var order: [Engine] {
        let saved = services.core.setting(.engineOrder, default: [String]())
        let listed = saved.compactMap { id in engines.first { $0.id == id } }
        return listed + engines.filter { engine in !listed.contains { $0.id == engine.id } }
    }

    func refresh() {
        arrangedSubviews.forEach { $0.removeFromSuperview() }
        let order = order
        let rows = order.enumerated().map { index, engine -> NSView in
            let enabled = services.core.setting(engine.enabled, default: true)
            let toggle = NSSwitch()
            toggle.state = enabled ? .on : .off
            toggle.identifier = NSUserInterfaceItemIdentifier(engine.id)
            toggle.target = self
            toggle.action = #selector(toggle(_:))
            let up = arrow("chevron.up", "Try earlier", index: index, enabled: index > 0, action: #selector(tryEarlier(_:)))
            let down = arrow("chevron.down", "Try later", index: index, enabled: index < order.count - 1, action: #selector(tryLater(_:)))
            let status = enabled ? engine.status() : "Off"
            return FormRow("\(index + 1).  \(engine.name)", subtitle: status, accessory: Design.hstack([up, down, toggle], spacing: 4))
        }
        let fallback = SystemTranslation.isAvailable
            ? " With none ready, macOS’s own translation panel translates what you write or select, on this Mac." : ""
        let section = FormSection(L("Translation Engines"),
            footer: L("Each translation goes to the first ready engine. If it fails, or doesn’t offer the language, the next one takes over and a short note says so. Only the model follows Translate’s instructions.") + fallback,
            rows: rows)
        addArrangedSubview(section)
        section.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    }

    private func arrow(_ symbol: String, _ tip: String, index: Int, enabled: Bool, action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!, target: self, action: action)
        button.isBordered = false
        button.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = tip
        button.tag = index
        button.isEnabled = enabled
        button.widthAnchor.constraint(equalToConstant: 22).isActive = true
        return button
    }

    @objc private func tryEarlier(_ sender: NSButton) { move(sender.tag, by: -1) }
    @objc private func tryLater(_ sender: NSButton) { move(sender.tag, by: 1) }

    private func move(_ index: Int, by step: Int) {
        var ids = order.map(\.id)
        let target = index + step
        guard ids.indices.contains(target) else { return }
        ids.swapAt(index, target)
        try? services.core.setSetting(.engineOrder, ids)
        refresh()
    }

    @objc private func toggle(_ sender: NSSwitch) {
        guard let engine = engines.first(where: { $0.id == sender.identifier?.rawValue }) else { return }
        try? services.core.setSetting(engine.enabled, sender.state == .on)
        refresh()
    }
}
