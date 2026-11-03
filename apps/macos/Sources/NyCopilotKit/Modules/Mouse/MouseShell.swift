import AppKit

/// macOS half of Mouse: sets each connected mouse's pointer speed and acceleration to what the
/// core's `mouse` module computes, whenever a setting changes or a mouse connects, and puts them
/// back when the feature is turned off or NyCopilot quits. It also reverses or smooths the scroll
/// wheel, if asked (`MouseWheel`).
@MainActor
final class MouseShell: ModuleShell {
    let id = "mouse"
    let title = L("Mouse")
    let symbolName = "computermouse"

    private struct Pointer: Decodable { let enabled: Bool; let resolution: Double; let acceleration: Double; let linear: Bool }

    private let services: CopilotServices
    private let devices = PointerDevices()
    private var wheel: MouseWheel?
    private var settingChanges: CoreObservation?
    private var wakeObserver: NSObjectProtocol?
    /// What was last applied, so Diagnostics notes a change of state, not every slider step.
    private var applied: String?

    init(services: CopilotServices) {
        self.services = services
        devices?.onChange = { [weak self] in self?.apply() }
        settingChanges = services.core.observe { [weak self] event in
            guard let key = event.changedSetting, key.hasPrefix("mouse.") || key == SettingKey.modulesOff.rawValue else { return }
            self?.apply()
        }
        // A mouse that sleeps with the Mac can come back with the system's settings.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.apply() }
        }
        apply()
    }

    var hotKeyActions: [HotKeyCenter.Action] { [] }

    func menuItems() -> [NSMenuItem] { [] }

    func makeSettingsPane() -> SettingsPane? {
        MousePane(services: services, connected: { [weak self] in self?.devices?.mice.map(\.name) ?? [] })
    }

    func shutdown() {
        devices?.mice.forEach { devices?.restore($0) }
        wheel?.stop()
    }

    /// Every connected mouse to the settings, or back to its own when the feature is off.
    private func apply() {
        let on = services.isModuleOn(id)
        let core = services.core
        let options = MouseWheel.Options(reverse: core.setting(.mouseReverseScroll, default: false),
                                         smooth: core.setting(.mouseSmoothScroll, default: false),
                                         lines: core.setting(.mouseScrollLines, default: 3.0),
                                         glide: core.setting(.mouseScrollGlide, default: 200.0),
                                         exceptions: Set(core.setting(.mouseScrollExceptions, default: [String]())))
        if !on || !(options.reverse || options.smooth) { wheel?.stop(); wheel = nil }
        else if let wheel { wheel.options = options }
        // Tried again on every change, so it starts once Accessibility is allowed.
        else { wheel = MouseWheel(options: options) }
        guard let devices else { return }
        var params: [String: Any] = [:]
        params["system_acceleration"] = devices.systemAcceleration
        let pointer = try? services.core.call(.mousePointer, params, as: Pointer.self)
        var set = 0
        for mouse in devices.mice {
            guard let pointer, on, pointer.enabled else {
                devices.restore(mouse)
                continue
            }
            devices.set(mouse, resolution: pointer.resolution, acceleration: pointer.acceleration, linear: pointer.linear)
            set += 1
        }
        let note = "\(devices.mice.count) mice, \(set) set by NyCopilot, wheel \(wheel == nil ? "as the system" : "\(options.reverse ? "reversed" : "as the system")\(options.smooth ? ", smooth" : "")")"
        if note != applied { Diagnostics.note("mouse", note) }
        applied = note
    }
}
