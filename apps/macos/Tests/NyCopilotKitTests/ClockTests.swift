import Foundation
import XCTest
@testable import NyCopilotKit

/// The menu bar clock without a menu bar: what it reads in each zone and format, when it changes
/// next, which zone a click in its menu shows, where it goes, and its settings across launches.
final class ClockTests: XCTestCase {
    /// Wednesday 4 November 2026, 14:05:07.250 in Tokyo (05:05:07.250 UTC).
    private let moment = Date(timeIntervalSince1970: 1_793_768_707.25)
    private let british = Locale(identifier: "en_GB")

    private func face(_ zone: String, locale: Locale? = nil, _ change: (inout ClockSettings) -> Void = { _ in }) -> String {
        var settings = ClockSettings(isOn: true, zoneID: zone)
        settings.hourCycle = .twentyFour
        change(&settings)
        return Self.plain(ClockFace(settings, locale: locale ?? british).text(at: moment))
    }

    /// The narrow no-break space ICU puts before "PM", as a plain one.
    private static func plain(_ text: String) -> String { text.replacingOccurrences(of: "\u{202F}", with: " ") }

    func testFaceReadsTheChosenZoneInEachFormat() {
        XCTAssertEqual(face("Asia/Tokyo"), "Wed 4 Nov 14:05 · Tokyo")
        XCTAssertEqual(face("Europe/London"), "Wed 4 Nov 05:05 · London")
        XCTAssertEqual(face("America/New_York"), "Wed 4 Nov 00:05 · New York")
        XCTAssertEqual(face("America/Los_Angeles"), "Tue 3 Nov 21:05 · Los Angeles", "the day before")
        XCTAssertEqual(face("Asia/Kolkata"), "Wed 4 Nov 10:35 · Kolkata", "a half-hour zone")

        XCTAssertEqual(face("Asia/Tokyo") { $0.showDate = false }, "14:05 · Tokyo")
        XCTAssertEqual(face("Asia/Tokyo") { $0.showSeconds = true }, "Wed 4 Nov 14:05:07 · Tokyo")
        XCTAssertEqual(face("Asia/Tokyo") { $0.hourCycle = .twelve }, "Wed 4 Nov 2:05 PM · Tokyo")
        XCTAssertEqual(face("Asia/Tokyo", locale: Locale(identifier: "en_US")) { $0.hourCycle = .twelve; $0.showDate = false }, "2:05 PM · Tokyo")
        XCTAssertEqual(face("Asia/Tokyo", locale: Locale(identifier: "en_US")) { $0.hourCycle = .twentyFour }, "Wed Nov 4 14:05 · Tokyo",
                       "no comma after the weekday")

        XCTAssertEqual(face("Asia/Tokyo") { $0.label = .offset }, "Wed 4 Nov 14:05 · GMT+9")
        XCTAssertEqual(face("America/New_York", locale: Locale(identifier: "en_US")) { $0.label = .abbreviation }, "Wed Nov 4 00:05 · EST")
        XCTAssertEqual(face("Asia/Tokyo") { $0.label = .custom; $0.customLabel = " Office " }, "Wed 4 Nov 14:05 · Office")
        XCTAssertEqual(face("Asia/Tokyo") { $0.label = .custom }, "Wed 4 Nov 14:05", "an empty name is no name")
        XCTAssertEqual(face("Asia/Tokyo") { $0.label = .none }, "Wed 4 Nov 14:05")
        XCTAssertEqual(face("Etc/GMT-9"), "Wed 4 Nov 14:05 · GMT+9", "a zone that is no place goes by its offset")
        XCTAssertEqual(face("UTC") { $0.showDate = false }, "05:05 · GMT")
    }

    func testFaceSpeaksTheInterfaceLanguage() {
        XCTAssertEqual(face("Asia/Tokyo", locale: Locale(identifier: "ja_JP")), "11月4日(水) 14:05 · 東京")
        XCTAssertEqual(face("Asia/Tokyo", locale: Locale(identifier: "zh_CN")), "11月4日 周三 14:05 · 东京")
        XCTAssertEqual(face("Asia/Tokyo", locale: Locale(identifier: "de_DE")), "Mi. 4. Nov. 14:05 · Tokio")
    }

    func testAnUnknownOrEmptyZoneIsThisMacs() {
        XCTAssertEqual(ClockZones.zone("").identifier, TimeZone.current.identifier)
        XCTAssertEqual(ClockZones.zone("Mars/Olympus_Mons").identifier, TimeZone.current.identifier)
        XCTAssertFalse(ClockZones.isKnown("Mars/Olympus_Mons"))
        XCTAssertTrue(ClockZones.isKnown("Asia/Tokyo"))
    }

    func testNextTickIsTheNextBoundaryNeverTheSameOne() {
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        let minute = ClockTick.next(after: moment, seconds: false, in: tokyo)
        XCTAssertEqual(minute.timeIntervalSince1970, 1_793_768_760, "14:06:00")
        XCTAssertEqual(ClockTick.next(after: minute, seconds: false, in: tokyo).timeIntervalSince1970, 1_793_768_820, "on the boundary: the next one")
        XCTAssertEqual(ClockTick.next(after: minute.addingTimeInterval(-0.0005), seconds: false, in: tokyo), minute)

        let second = ClockTick.next(after: moment, seconds: true, in: tokyo)
        XCTAssertEqual(second.timeIntervalSince1970, 1_793_768_708)
        XCTAssertEqual(ClockTick.next(after: second, seconds: true, in: tokyo).timeIntervalSince1970, 1_793_768_709)

        XCTAssertEqual(ClockTick.next(after: moment, seconds: false, in: TimeZone(identifier: "Asia/Kolkata")!), minute, "half-hour zones share minutes")
        // Liberia kept 44 minutes 30 seconds behind GMT until 1972: its minutes began at :30.
        let monrovia = TimeZone(identifier: "Africa/Monrovia")!
        let then = Date(timeIntervalSince1970: 31_536_000) // 1 January 1971, 00:00:00 UTC
        XCTAssertEqual(monrovia.secondsFromGMT(for: then), -2670)
        XCTAssertEqual(ClockTick.next(after: then, seconds: false, in: monrovia).timeIntervalSince1970, 31_536_030)
    }

    /// Times between the boundaries never pile up: each is worked out from the clock, not from the
    /// last one, so a late tick is followed by an on-time one.
    func testTicksStayOnTheMinuteAfterALateOne() {
        let london = TimeZone(identifier: "Europe/London")!
        var due = ClockTick.next(after: moment, seconds: false, in: london)
        for lateness in [0.003, 0.9, 12.5, 0.0] {
            let fired = due.addingTimeInterval(lateness)
            let shown = ClockTick.shown(now: fired, due: due)
            due = ClockTick.next(after: shown, seconds: false, in: london)
            XCTAssertEqual(due.timeIntervalSince1970.truncatingRemainder(dividingBy: 60), 0, "late by \(lateness) s")
            XCTAssertGreaterThan(due, fired)
        }
        // A hair early shows the moment it was due; well before (the clock was set back) shows now.
        XCTAssertEqual(ClockTick.shown(now: due.addingTimeInterval(-0.002), due: due), due)
        XCTAssertEqual(ClockTick.shown(now: due.addingTimeInterval(-30), due: due), due.addingTimeInterval(-30))
        XCTAssertEqual(ClockTick.shown(now: moment, due: nil), moment)
    }

    /// Crossing into summer time (London, 29 March 2026, 01:00 GMT → 02:00 BST) the next minute is
    /// still a minute away, and the face reads the new hour.
    func testTicksAcrossAClockChange() {
        let london = TimeZone(identifier: "Europe/London")!
        let before = Date(timeIntervalSince1970: 1_774_745_999) // 00:59:59 GMT
        let next = ClockTick.next(after: before, seconds: false, in: london)
        XCTAssertEqual(next.timeIntervalSince1970, 1_774_746_000)
        var settings = ClockSettings(isOn: true, zoneID: "Europe/London")
        settings.hourCycle = .twentyFour
        settings.showDate = false
        settings.label = .abbreviation
        XCTAssertEqual(ClockFace(settings, locale: british).text(at: next), "02:00 · BST")
    }

    func testMenuListsEachZoneOnceWithHoursFromThisMac() {
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        let shanghai = TimeZone(identifier: "Asia/Shanghai")!
        XCTAssertEqual(ClockZones.difference(tokyo, from: shanghai, at: moment), "+1")
        XCTAssertEqual(ClockZones.difference(TimeZone(identifier: "America/New_York")!, from: shanghai, at: moment), "−13")
        XCTAssertEqual(ClockZones.difference(TimeZone(identifier: "Asia/Kolkata")!, from: shanghai, at: moment), "−2:30")
        XCTAssertEqual(ClockZones.difference(TimeZone(identifier: "Asia/Kathmandu")!, from: TimeZone(identifier: "GMT")!, at: moment), "+5:45")
        XCTAssertEqual(ClockZones.difference(shanghai, from: shanghai, at: moment), "")

        var settings = ClockSettings(isOn: true, zoneID: "Asia/Tokyo", otherZones: ["Europe/London", "Asia/Tokyo", "Europe/London", "America/New_York"])
        XCTAssertEqual(settings.menuZones, ["Asia/Tokyo", "Europe/London", "America/New_York"])
        settings.zoneID = ""
        XCTAssertEqual(settings.menuZones.first, "", "this Mac's zone first")

        var settings24 = settings
        settings24.hourCycle = .twentyFour
        XCTAssertEqual(ClockFace(settings24, locale: british).menuTime(at: moment, in: tokyo), "Wed 14:05")
    }

    /// A zone clicked in the menu takes the menu bar's place; the one there takes its place in the list.
    func testChoosingAZoneFromTheMenuTradesPlaces() {
        let here = TimeZone(identifier: "Asia/Shanghai")!
        let settings = ClockSettings(isOn: true, zoneID: "Asia/Tokyo", otherZones: ["Europe/London", "America/New_York"])
        XCTAssertTrue(settings.choosing("Europe/London", here: here) == ("Europe/London", ["Asia/Tokyo", "America/New_York"]))
        XCTAssertTrue(settings.choosing("Asia/Tokyo", here: here) == ("Asia/Tokyo", ["Europe/London", "America/New_York"]), "already shown")
        XCTAssertTrue(settings.choosing("Asia/Seoul", here: here) == ("Asia/Seoul", ["Asia/Tokyo", "Europe/London", "America/New_York"]))
        let following = ClockSettings(isOn: true, zoneID: "", otherZones: ["Europe/London"])
        XCTAssertTrue(following.choosing("Europe/London", here: here) == ("Europe/London", ["Asia/Shanghai"]), "this Mac's zone by its name")
        let listed = ClockSettings(isOn: true, zoneID: "", otherZones: ["Asia/Shanghai", "Europe/London"])
        XCTAssertTrue(listed.choosing("Europe/London", here: here) == ("Europe/London", ["Asia/Shanghai"]), "listed once")
    }

    func testZonesCanBeFoundByCityNameOffsetOrIdentifier() {
        let choices = ClockZones.choices(locale: british, at: moment)
        XCTAssertGreaterThan(choices.count, 300)
        XCTAssertEqual(choices.map(\.seconds), choices.map(\.seconds).sorted(), "west to east")
        let tokyo = try? XCTUnwrap(choices.first { $0.id == "Asia/Tokyo" })
        XCTAssertEqual(tokyo?.city, "Tokyo")
        XCTAssertEqual(tokyo?.offset, "GMT+9")
        XCTAssertEqual(tokyo?.name, "Japan Standard Time")

        func found(_ query: String) -> [String] { ClockZones.filter(choices, query).map(\.id) }
        XCTAssertEqual(found("tokyo"), ["Asia/Tokyo"])
        XCTAssertTrue(found("sao").contains("America/Sao_Paulo"), "without accents")
        XCTAssertTrue(found("new york").contains("America/New_York"))
        XCTAssertTrue(found("japan").contains("Asia/Tokyo"), "by the zone's name")
        XCTAssertTrue(found("gmt+9").contains("Asia/Seoul") && found("gmt+9").contains("Asia/Tokyo"))
        XCTAssertTrue(found("argentina buenos").contains("America/Argentina/Buenos_Aires"), "every word")
        XCTAssertEqual(found("  ").count, choices.count)
        XCTAssertTrue(found("atlantis").isEmpty)

        let japanese = ClockZones.choices(locale: Locale(identifier: "ja_JP"), at: moment)
        XCTAssertEqual(ClockZones.filter(japanese, "東京").map(\.id), ["Asia/Tokyo"], "in the interface's language")
    }

    /// The clock goes where it was last, else one point right of NyCopilot's own icon (away from
    /// Menu Bar's arrow, which is left of it), measured from the screen's right edge.
    func testClockIsPlacedRightOfNyCopilotsIcon() {
        XCTAssertNil(ClockPlacement.position(saved: 150, kept: 120, appIconSaved: 198, appIconMaxX: 1700, screenMaxX: 1920), "macOS knows")
        XCTAssertEqual(ClockPlacement.position(saved: nil, kept: 120, appIconSaved: 198, appIconMaxX: 1700, screenMaxX: 1920), 120, "back where it was")
        XCTAssertEqual(ClockPlacement.position(saved: nil, kept: nil, appIconSaved: 198, appIconMaxX: 1700, screenMaxX: 1920), 197)
        XCTAssertEqual(ClockPlacement.position(saved: nil, kept: nil, appIconSaved: nil, appIconMaxX: 1700, screenMaxX: 1920), 219, "never dragged: where it is")
        XCTAssertEqual(ClockPlacement.position(saved: nil, kept: nil, appIconSaved: nil, appIconMaxX: 3540, screenMaxX: 3840), 299)
        XCTAssertNil(ClockPlacement.position(saved: nil, kept: nil, appIconSaved: nil, appIconMaxX: nil, screenMaxX: nil), "not placed yet")
        XCTAssertNil(ClockPlacement.position(saved: nil, kept: nil, appIconSaved: nil, appIconMaxX: 0, screenMaxX: 1920))
    }

    /// Off until asked for, following this Mac; every choice survives a relaunch, the core turns
    /// away what it can't use, and the feature switched off in General takes the clock away.
    @MainActor
    func testClockSettingsAreKeptAcrossLaunches() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("clock-\(UUID())", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        var core: NyCore? = try NyCore(dataDirectory: folder)
        XCTAssertEqual(ClockSettings.read(core!, moduleOn: true), ClockSettings())

        try core!.setSetting(.clockEnabled, true)
        try core!.setSetting(.clockTimeZone, "Asia/Tokyo")
        try core!.setSetting(.clockOtherZones, ["Europe/London", "America/New_York"])
        try core!.setSetting(.clockShowDate, false)
        try core!.setSetting(.clockHourCycle, "12")
        try core!.setSetting(.clockShowSeconds, true)
        try core!.setSetting(.clockLabel, "custom")
        try core!.setSetting(.clockCustomLabel, "Office")
        XCTAssertThrowsError(try core!.setSetting(.clockTimeZone, "Asia Tokyo"))
        XCTAssertThrowsError(try core!.setSetting(.clockHourCycle, "13"))
        XCTAssertThrowsError(try core!.setSetting(.clockCustomLabel, String(repeating: "x", count: 41)))
        core = nil

        let relaunched = try NyCore(dataDirectory: folder)
        let settings = ClockSettings.read(relaunched, moduleOn: true)
        XCTAssertEqual(settings, ClockSettings(isOn: true, zoneID: "Asia/Tokyo", otherZones: ["Europe/London", "America/New_York"],
                                               showDate: false, hourCycle: .twelve, showSeconds: true, label: .custom, customLabel: "Office"))
        XCTAssertEqual(Self.plain(ClockFace(settings, locale: british).text(at: moment)), "2:05:07 PM · Office")
        XCTAssertFalse(ClockSettings.read(relaunched, moduleOn: false).isOn)
    }
}
