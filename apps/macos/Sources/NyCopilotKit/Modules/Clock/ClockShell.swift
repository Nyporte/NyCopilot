import AppKit

/// macOS half of Clock: the date and time in a zone of your choosing, in the menu bar, with other
/// zones a click away. It follows the settings as they change, and the Mac as it wakes or its
/// clock, zone, or language changes.
@MainActor
final class ClockShell: ModuleShell {
    let id = "clock"
    let title = L("Clock")
    let symbolName = "clock"

    private let services: CopilotServices
    private var clock: ClockItem?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var settingChanges: CoreObservation?

    init(services: CopilotServices) {
        self.services = services
        services.clockItem = { [weak self] in self?.clock?.item }
        let center = NotificationCenter.default
        settingChanges = services.core.observe { [weak self] event in
            guard let key = event.changedSetting, key.hasPrefix("clock.") || key == SettingKey.modulesOff.rawValue else { return }
            self?.apply()
        }
        // A wall-clock timer fires on time after these too, but the face would show the old time
        // (or zone, or language) until then.
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification) { [weak self] _ in self?.reset("woke") }
        observe(center, .NSSystemClockDidChange) { [weak self] _ in self?.reset("the Mac's clock changed") }
        observe(center, .NSSystemTimeZoneDidChange) { [weak self] _ in
            NSTimeZone.resetSystemTimeZone()
            self?.reset("the Mac's time zone changed")
        }
        observe(center, NSLocale.currentLocaleDidChangeNotification) { [weak self] _ in self?.reset("the Mac's region changed") }
    }

    /// NyCopilot's own icon is in the menu bar now, so the clock can go beside it.
    func didLaunch() { apply() }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ handler: @escaping @MainActor @Sendable (Notification) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { note in
            MainActor.assumeIsolated { handler(note) }
        }
        observers.append((center, token))
    }

    private var settings: ClockSettings { ClockSettings.read(services.core, moduleOn: services.isModuleOn(id)) }

    var hotKeyActions: [HotKeyCenter.Action] { [] }

    func menuItems() -> [NSMenuItem] { [] }

    func makeSettingsPane() -> SettingsPane? { ClockPane(services: services) }

    func shutdown() {
        settingChanges?.cancel()
        for (center, token) in observers { center.removeObserver(token) }
        observers = []
    }

    /// The clock in the menu bar as the settings say, or out of it.
    private func apply() {
        let settings = settings
        guard settings.isOn else {
            if clock != nil { Diagnostics.note("clock", "off") }
            clock?.remove()
            clock = nil
            return
        }
        let face = ClockFace(settings, locale: Localization.locale)
        if let clock {
            clock.update(face)
            return
        }
        let made = ClockItem(face: face, appIcon: services.appIcon())
        made.onChoose = { [weak self] id in self?.show(id) }
        made.onSettings = { [weak self] in guard let self else { return }; services.openSettings(id) }
        clock = made
        Diagnostics.note("clock", "on, \(settings.zoneID.isEmpty ? "this Mac's zone" : settings.zoneID)\(settings.showSeconds ? ", seconds" : "")")
    }

    private func reset(_ why: String) {
        guard clock != nil else { return }
        Diagnostics.note("clock", "reading the time again: \(why)")
        // The zone, its name, and the language's patterns may all have changed.
        apply()
    }

    /// A zone from the menu takes the menu bar's place, and the one there joins the list.
    private func show(_ zoneID: String) {
        let chosen = settings.choosing(zoneID)
        try? services.core.setSetting(.clockOtherZones, chosen.otherZones)
        try? services.core.setSetting(.clockTimeZone, chosen.zoneID)
    }
}
