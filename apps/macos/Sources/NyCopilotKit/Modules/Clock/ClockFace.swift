import Foundation

/// What the clock shows and how, from its settings, worked out without a menu bar so it can be
/// tested.
struct ClockSettings: Equatable {
    enum HourCycle: String, CaseIterable { case system, twelve = "12", twentyFour = "24" }
    /// What follows the time: "Tokyo", "JST", "GMT+9", a name of your own, or nothing.
    enum Label: String, CaseIterable { case city, abbreviation, offset, custom, none }

    /// The clock is in the menu bar: the module and its own switch are both on.
    var isOn = false
    /// An IANA identifier, or empty for this Mac's own zone.
    var zoneID = ""
    /// Listed in the clock's menu with their times.
    var otherZones: [String] = []
    var showDate = true
    var hourCycle = HourCycle.system
    var showSeconds = false
    var label = Label.city
    var customLabel = ""

    @MainActor
    static func read(_ core: NyCore, moduleOn: Bool) -> ClockSettings {
        ClockSettings(isOn: moduleOn && core.setting(.clockEnabled, default: false),
                      zoneID: core.setting(.clockTimeZone, default: ""),
                      otherZones: core.setting(.clockOtherZones, default: [String]()),
                      showDate: core.setting(.clockShowDate, default: true),
                      hourCycle: HourCycle(rawValue: core.setting(.clockHourCycle, default: "system")) ?? .system,
                      showSeconds: core.setting(.clockShowSeconds, default: false),
                      label: Label(rawValue: core.setting(.clockLabel, default: "city")) ?? .city,
                      customLabel: core.setting(.clockCustomLabel, default: ""))
    }

    /// The zone shown: the chosen one, or this Mac's when none is chosen or this Mac doesn't know it
    /// (a zone chosen on another device, say).
    var zone: TimeZone { ClockZones.zone(zoneID) }

    /// The zones that make up the clock's menu: the one in the menu bar, then the others, each once.
    var menuZones: [String] {
        var seen = Set<String>()
        return ([zoneID] + otherZones).filter { seen.insert($0).inserted }
    }

    /// Shows `id` in the menu bar: it trades places with the zone there, which joins the others
    /// where `id` was. This Mac's zone joins them by its name, since the list holds names.
    func choosing(_ id: String, here: TimeZone = .current) -> (zoneID: String, otherZones: [String]) {
        guard id != zoneID else { return (zoneID, otherZones) }
        let current = zoneID.isEmpty ? here.identifier : zoneID
        var others = otherZones
        if let index = others.firstIndex(of: id) { others[index] = current } else { others.insert(current, at: 0) }
        var seen = Set<String>()
        return (id, others.filter { $0 != id && seen.insert($0).inserted })
    }
}

/// The text the clock shows: "Tue 4 Nov 14:05 · Tokyo", in the interface's language, built from
/// the locale's own patterns so each reads as it should ("11月4日 周二 14:05 · 东京").
final class ClockFace {
    let settings: ClockSettings
    private let date = DateFormatter()
    private let time = DateFormatter()
    private let menuTime = DateFormatter()
    private let naming = DateFormatter()

    init(_ settings: ClockSettings, locale: Locale) {
        self.settings = settings
        let zone = settings.zone
        let hours = Self.hourTemplate(settings.hourCycle)
        for (formatter, template) in [(date, "EEEdMMM"), (time, hours + (settings.showSeconds ? "ss" : "")), (menuTime, "EEE" + hours)] {
            formatter.locale = locale
            formatter.timeZone = zone
            formatter.dateFormat = DateFormatter.dateFormat(fromTemplate: template, options: 0, locale: locale)
        }
        naming.locale = locale
        naming.timeZone = zone
    }

    /// `j` is the locale's (and the Mac's) choice of 12 or 24 hours.
    static func hourTemplate(_ cycle: ClockSettings.HourCycle) -> String {
        switch cycle {
        case .system: "jmm"
        case .twelve: "hmma"
        case .twentyFour: "HHmm"
        }
    }

    /// The text in the menu bar at `now`.
    func text(at now: Date) -> String {
        // Without the commas some locales put after the weekday, as the menu bar's own clock does.
        let date = settings.showDate ? self.date.string(from: now).replacingOccurrences(of: ", ", with: " ") + " " : ""
        let label = label(at: now)
        return date + time.string(from: now) + (label.isEmpty ? "" : " · " + label)
    }

    /// The zone's name as the settings ask for it.
    func label(at now: Date) -> String {
        switch settings.label {
        case .city: ClockZones.city(settings.zone, locale: naming.locale)
        case .abbreviation: Self.pattern("zzz", naming, now)
        case .offset: Self.pattern("O", naming, now)
        case .custom: settings.customLabel.trimmingCharacters(in: .whitespaces)
        case .none: ""
        }
    }

    /// The weekday and time in `zone`, for the clock's menu: "Thu 23:05".
    func menuTime(at now: Date, in zone: TimeZone) -> String {
        menuTime.timeZone = zone
        return menuTime.string(from: now)
    }

    private static func pattern(_ pattern: String, _ formatter: DateFormatter, _ now: Date) -> String {
        formatter.dateFormat = pattern
        return formatter.string(from: now)
    }
}

/// When the clock changes next. A one-shot timer set for exactly that moment, set again each time,
/// keeps the clock on the boundary, where a repeating one would drift off it.
enum ClockTick {
    /// The next moment after `date` that the clock's face changes: the next whole second, or the
    /// next whole minute in `zone` (a zone's offset was once not a whole number of minutes).
    static func next(after date: Date, seconds: Bool, in zone: TimeZone) -> Date {
        if seconds { return Date(timeIntervalSinceReferenceDate: date.timeIntervalSinceReferenceDate.rounded(.down) + 1) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.nextDate(after: date, matching: DateComponents(second: 0), matchingPolicy: .nextTime)
            ?? Date(timeIntervalSinceReferenceDate: (date.timeIntervalSinceReferenceDate / 60).rounded(.down) * 60 + 60)
    }

    /// What to show when the timer for `due` fires at `now`. A wall-clock timer can fire a hair
    /// early while the clock is being nudged into step; the face then shows the moment it was due.
    static func shown(now: Date, due: Date?) -> Date {
        guard let due, now < due, due.timeIntervalSince(now) < 0.5 else { return now }
        return due
    }
}

/// Every time zone this Mac knows, named in the interface's language, for picking one.
enum ClockZones {
    struct Choice: Equatable {
        let id: String
        /// "Tokyo"; a zone that is no place ("GMT", "Etc/GMT-9") is called by its offset.
        let city: String
        /// "Japan Standard Time".
        let name: String
        /// "GMT+9".
        let offset: String
        let seconds: Int
    }

    /// A zone by its identifier; empty, or unknown here, is this Mac's own (and follows it).
    static func zone(_ id: String) -> TimeZone {
        id.isEmpty ? .autoupdatingCurrent : TimeZone(identifier: id) ?? .autoupdatingCurrent
    }

    /// Whether `id` is a zone this Mac knows (and so one the clock can show).
    static func isKnown(_ id: String) -> Bool { TimeZone(identifier: id) != nil }

    /// The zone's city in `locale`'s language ("Tokyo", "東京"), or its offset from GMT for a zone
    /// that isn't a place, for which the formatter would say "Unknown City".
    static func city(_ zone: TimeZone, locale: Locale, at date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = zone
        let id = zone.identifier
        formatter.dateFormat = !id.contains("/") || id.hasPrefix("Etc/") ? "O" : "VVV"
        return formatter.string(from: date)
    }

    /// Hours from this Mac's zone, as the menu lists them: "+1", "−8", "+5:30"; empty when the same.
    static func difference(_ zone: TimeZone, from here: TimeZone, at date: Date) -> String {
        let seconds = zone.secondsFromGMT(for: date) - here.secondsFromGMT(for: date)
        guard seconds != 0 else { return "" }
        let minutes = abs(seconds) / 60
        let sign = seconds > 0 ? "+" : "−"
        return minutes % 60 == 0 ? "\(sign)\(minutes / 60)" : String(format: "%@%d:%02d", sign, minutes / 60, minutes % 60)
    }

    static func choices(locale: Locale, at date: Date = Date()) -> [Choice] {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateFormat = "O"
        return TimeZone.knownTimeZoneIdentifiers.compactMap { id -> Choice? in
            guard let zone = TimeZone(identifier: id) else { return nil }
            formatter.timeZone = zone
            return Choice(id: id, city: city(zone, locale: locale, at: date),
                          name: zone.localizedName(for: zone.isDaylightSavingTime(for: date) ? .daylightSaving : .standard, locale: locale) ?? "",
                          offset: formatter.string(from: date), seconds: zone.secondsFromGMT(for: date))
        }
        .sorted { ($0.seconds, $0.city) < ($1.seconds, $1.city) }
    }

    /// The choices whose city, zone name, offset, or identifier contain every word of `query`,
    /// ignoring case and accents ("sao" finds São Paulo, "gmt+9" Tokyo and Seoul).
    static func filter(_ choices: [Choice], _ query: String) -> [Choice] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return choices }
        return choices.filter { choice in
            let haystack = [choice.city, choice.name, choice.offset, choice.id.replacingOccurrences(of: "_", with: " ")].joined(separator: " ")
            return words.allSatisfy { haystack.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }
}
