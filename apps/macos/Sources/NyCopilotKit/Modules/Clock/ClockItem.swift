import AppKit
import os

/// The clock in the menu bar: its text, kept on the second or minute by a one-shot wall-clock
/// timer set again on each change, and its menu, which lists the other zones with their times.
@MainActor
final class ClockItem: NSObject, NSMenuDelegate {
    /// A zone in the menu was clicked: show it in the menu bar.
    var onChoose: (_ zoneID: String) -> Void = { _ in }
    var onSettings: () -> Void = {}

    let item: NSStatusItem
    private var face: ClockFace
    private let timer = DispatchSource.makeTimerSource(queue: .main)
    /// When the timer is set to fire, for what it shows if it fires a hair early.
    private var due: Date?
    private var menuRows: [(zone: TimeZone, row: NSMenuItem)] = []
    /// Every tick at debug level, for `log stream --level debug`, to check the clock keeps time.
    private static let ticks = Logger(subsystem: "dev.nycopilot.NyCopilot", category: "clock")

    static let autosaveName = "NyCopilot.Clock"

    /// `appIcon` is NyCopilot's own icon: the first time, the clock goes right beside it, on the side
    /// away from Menu Bar's arrow, so the clock never hides with the icons behind it.
    init(face: ClockFace, appIcon: NSStatusItem?) {
        self.face = face
        ClockPlacement.prepare(name: Self.autosaveName, beside: appIcon)
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = Self.autosaveName
        super.init()
        // macOS remembers an item taken out of the bar by its name; the clock is here to be seen.
        item.isVisible = true
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        timer.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.tick() } }
        timer.resume()
        refresh()
    }

    /// Reads the time afresh and sets the timer again: after a change of settings, waking, or the
    /// Mac's clock or zone changing (a wall-clock timer follows the new time, but the face shows
    /// the old one until it fires).
    func update(_ face: ClockFace) {
        self.face = face
        refresh()
    }

    func refresh() {
        due = nil
        tick()
    }

    /// Out of the menu bar, with its place kept for when it comes back.
    func remove() {
        timer.cancel()
        ClockPlacement.keep(name: Self.autosaveName)
        NSStatusBar.system.removeStatusItem(item)
    }

    private func tick() {
        let now = Date()
        let shown = ClockTick.shown(now: now, due: due)
        let text = face.text(at: shown)
        let lateness = due.map { "\(Int(now.timeIntervalSince($0) * 1000)) ms after its moment" } ?? "read afresh"
        Self.ticks.debug("\(text, privacy: .public), \(lateness, privacy: .public)")
        if item.button?.title != text {
            item.button?.attributedTitle = NSAttributedString(string: text, attributes: [.font: Self.font, .baselineOffset: 0.5])
        }
        updateMenu(at: shown)
        let next = ClockTick.next(after: shown, seconds: face.settings.showSeconds, in: face.settings.zone)
        due = next
        timer.schedule(wallDeadline: Self.wallTime(next), leeway: .milliseconds(face.settings.showSeconds ? 5 : 20))
    }

    /// The menu bar's font, with digits all one width so the clock doesn't shuffle as it ticks.
    private static var font: NSFont { .monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular) }

    private static func wallTime(_ date: Date) -> DispatchWallTime {
        let seconds = date.timeIntervalSince1970.rounded(.down)
        return DispatchWallTime(timespec: timespec(tv_sec: Int(seconds), tv_nsec: Int((date.timeIntervalSince1970 - seconds) * 1_000_000_000)))
    }

    // MARK: Menu

    /// Each zone with its weekday, time, and hours from this Mac; a click shows it in the menu bar.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menuRows = []
        for id in face.settings.menuZones {
            let row = NSMenuItem(title: "", action: #selector(choose(_:)), keyEquivalent: "")
            row.target = self
            row.representedObject = id
            row.state = id == face.settings.zoneID ? .on : .off
            menu.addItem(row)
            menuRows.append((ClockZones.zone(id), row))
        }
        updateMenu(at: Date())
        menu.addItem(.separator())
        let add = NSMenuItem(title: L("Add Time Zone…"), action: #selector(openSettings), keyEquivalent: "")
        add.target = self
        menu.addItem(add)
        let settings = NSMenuItem(title: L("Clock Settings…"), action: #selector(openSettings), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
    }

    func menuDidClose(_ menu: NSMenu) { menuRows = [] }

    /// The open menu's times move on with the clock.
    private func updateMenu(at now: Date) {
        guard !menuRows.isEmpty else { return }
        let here = TimeZone.autoupdatingCurrent
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .right, location: 230), NSTextTab(textAlignment: .right, location: 270)]
        let font = NSFont.menuFont(ofSize: 0)
        let digits = NSFont.monospacedDigitSystemFont(ofSize: font.pointSize, weight: .regular)
        for (zone, row) in menuRows {
            let title = NSMutableAttributedString(string: ClockZones.city(zone, locale: Localization.locale, at: now),
                                                  attributes: [.font: font, .paragraphStyle: style])
            title.append(NSAttributedString(string: "\t" + face.menuTime(at: now, in: zone), attributes: [.font: digits, .paragraphStyle: style]))
            title.append(NSAttributedString(string: "\t" + ClockZones.difference(zone, from: here, at: now),
                                            attributes: [.font: digits, .paragraphStyle: style, .foregroundColor: NSColor.secondaryLabelColor]))
            row.attributedTitle = title
        }
    }

    @objc private func choose(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        onChoose(id)
    }

    @objc private func openSettings() { onSettings() }
}

/// Where the clock goes in the menu bar. macOS keeps each item's place in the app's defaults, by
/// name, as its distance from the screen's right edge (smaller is further right), and deletes it
/// while the item is out of the bar; NyCopilot keeps its own copy for when the clock comes back.
enum ClockPlacement {
    private static func key(_ name: String) -> String { "NSStatusItem Preferred Position \(name)" }
    private static func kept(_ name: String) -> String { "NyCopilot.KeptPosition.\(name)" }

    /// The place to give an item before it's made, or nil to leave it where it is: where it was
    /// last (`saved` by macOS, or `kept` by NyCopilot), else one point right of NyCopilot's own
    /// icon, by its saved place or else where it is now. With nothing to go on, macOS puts a new
    /// item left of the ones already there.
    static func position(saved: Double?, kept: Double?, appIconSaved: Double?, appIconMaxX: CGFloat?, screenMaxX: CGFloat?) -> Double? {
        if saved != nil { return nil }
        if let kept { return kept }
        if let appIconSaved { return appIconSaved - 1 }
        guard let appIconMaxX, let screenMaxX, appIconMaxX > 0 else { return nil }
        return Double(screenMaxX - appIconMaxX) - 1
    }

    @MainActor
    static func prepare(name: String, beside appIcon: NSStatusItem?) {
        let defaults = UserDefaults.standard
        let window = appIcon?.button?.window
        // Until macOS places an item, its window sits just below the screen (measured: y −24).
        let placed = window.map { $0.frame.maxY > 0 } ?? false
        guard let position = position(saved: defaults.object(forKey: key(name)) as? Double, kept: defaults.object(forKey: kept(name)) as? Double,
                                      appIconSaved: appIcon.flatMap { defaults.object(forKey: key($0.autosaveName)) as? Double },
                                      appIconMaxX: placed ? window?.frame.maxX : nil, screenMaxX: window?.screen?.frame.maxX) else { return }
        defaults.set(position, forKey: key(name))
        Diagnostics.note("clock", "placed at \(Int(position)) from the right")
    }

    /// Before the item leaves the bar, where it is: macOS forgets it then.
    static func keep(name: String) {
        guard let position = UserDefaults.standard.object(forKey: key(name)) as? Double else { return }
        UserDefaults.standard.set(position, forKey: kept(name))
    }
}
