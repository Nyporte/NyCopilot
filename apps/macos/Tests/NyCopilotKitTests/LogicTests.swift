import AppKit
import ImageIO
import XCTest
@testable import NyCopilotKit

/// The parts with no screen in them: timing curves, snooze times, key schemes, exports, the GIF
/// encoder, and the core bridge's settings cache.
final class LogicTests: XCTestCase {
    func testBezierCurvesEaseOutAndOvershootThenSettle() {
        XCTAssertEqual(BezierCurve.easeOut.value(at: 0), 0, accuracy: 0.001)
        XCTAssertEqual(BezierCurve.easeOut.value(at: 1), 1, accuracy: 0.001)
        XCTAssertGreaterThan(BezierCurve.easeOut.value(at: 0.3), 0.6, "quick to leave")
        let peak = stride(from: 0.0, through: 1.0, by: 0.05).map { BezierCurve.overshoot.value(at: $0) }.max() ?? 0
        XCTAssertGreaterThan(peak, 1.02)
        XCTAssertLessThan(peak, 1.12)
        XCTAssertEqual(BezierCurve.overshoot.value(at: 1), 1, accuracy: 0.001)
        XCTAssertEqual(BezierCurve.easeOut.value(at: -1), 0, accuracy: 0.001, "clamped")
    }

    func testSnoozeChoicesAreAheadAndOnlyWhenTheyMakeSense() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        // Wednesday 2026-10-28 10:00 UTC.
        let wednesday = calendar.date(from: DateComponents(year: 2026, month: 10, day: 28, hour: 10))!
        for choice in SnoozeChoice.allCases {
            if let date = choice.date(from: wednesday, calendar: calendar) { XCTAssertGreaterThan(date, wednesday, "\(choice)") }
        }
        XCTAssertEqual(calendar.component(.weekday, from: SnoozeChoice.weekend.date(from: wednesday, calendar: calendar)!), 7)
        XCTAssertEqual(calendar.component(.weekday, from: SnoozeChoice.nextWeek.date(from: wednesday, calendar: calendar)!), 2)
        let evening = calendar.date(from: DateComponents(year: 2026, month: 10, day: 28, hour: 20))!
        XCTAssertNil(SnoozeChoice.laterToday.date(from: evening, calendar: calendar))
        XCTAssertNil(SnoozeChoice.thisEvening.date(from: evening, calendar: calendar))
        let saturday = calendar.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 10))!
        XCTAssertNil(SnoozeChoice.weekend.date(from: saturday, calendar: calendar))
    }

    func testKeySchemesCoverTheSameActionsWithDistinctKeys() {
        let fkeys = KeyScheme.functionKeys.combinations, letters = KeyScheme.letters.combinations
        XCTAssertEqual(Set(fkeys.keys), Set(letters.keys))
        for scheme in [fkeys, letters] {
            let pairs = scheme.values.map { "\($0.keyCode)-\($0.modifiers)" }
            XCTAssertEqual(Set(pairs).count, pairs.count, "no two actions share a key")
        }
    }

    @MainActor
    func testMarkdownExportKeepsSourceAndScreenshot() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("md-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let image = folder.appendingPathComponent("shot.gif")
        try Data("GIF89a".utf8).write(to: image)
        let content = NoteExport.Content(text: "Ask Lin: Q3/plan?\nbefore Friday", image: image, source: "Safari — Q3",
                                         address: URL(string: "https://example.com/q3"), created: Date(timeIntervalSince1970: 0))
        let file = try NoteExport.toMarkdown(content, in: folder)
        XCTAssertFalse(file.lastPathComponent.contains("/"))
        let text = try String(contentsOf: file)
        XCTAssertTrue(text.hasPrefix("---\ncreated: "))
        XCTAssertTrue(text.contains("url: https://example.com/q3"))
        XCTAssertTrue(text.contains("before Friday"))
        XCTAssertTrue(text.contains(".gif)"), "the screenshot keeps its own type")
        // A second export never overwrites the first.
        XCTAssertNotEqual(try NoteExport.toMarkdown(content, in: folder), file)
    }

    func testGifWriterRoundTripsChangedRegionsAndDelays() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("w-\(UUID()).gif")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try XCTUnwrap(GifWriter(url: url, width: 64, height: 32))
        func frame(_ x: Int) -> CGImage {
            let context = CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
            context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1)); context.fill(CGRect(x: x, y: 8, width: 8, height: 8))
            return context.makeImage()!
        }
        writer.add(frame(0), at: 0)
        writer.add(frame(0), at: 0.05)  // unchanged: only extends the first frame
        writer.add(frame(16), at: 0.2)
        XCTAssertTrue(writer.finish(at: 0.5))
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 2)
        let delays = (0..<2).map { index -> Double in
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            return (properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any])?[kCGImagePropertyGIFDelayTime] as? Double ?? 0
        }
        XCTAssertEqual(delays[0], 0.2, accuracy: 0.011)
        XCTAssertEqual(delays[1], 0.3, accuracy: 0.011)
        // The second frame, composited, has the square where it moved and white where it was.
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 1, nil))
        // Bitmap rows count from the top: the square (drawn 8–16 up from the bottom) is at rows 16–24.
        let bitmap = NSBitmapImageRep(cgImage: image)
        XCTAssertLessThan(try XCTUnwrap(bitmap.colorAt(x: 20, y: 20)).redComponent, 0.2)
        XCTAssertGreaterThan(try XCTUnwrap(bitmap.colorAt(x: 4, y: 20)).redComponent, 0.9)
    }

    func testSettingsCacheFollowsWrites() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("core-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let core = try NyCore(dataDirectory: folder)
        XCTAssertEqual(core.setting(.clipboardKeepDays, default: 0), 30)
        try core.setSetting(.clipboardKeepDays, 7)
        XCTAssertEqual(core.setting(.clipboardKeepDays, default: 0), 7)
        try core.resetSetting(.clipboardKeepDays)
        XCTAssertEqual(core.setting(.clipboardKeepDays, default: 0), 30)
    }

    /// A German Mac starts with English and German to Tab between; Chinese and Japanese stay for
    /// Macs in those languages, and favorites someone changed are never touched.
    func testFavoritesStartInTheMacsLanguage() throws {
        func fresh() throws -> (NyCore, UserDefaults) {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("core-\(UUID())", isDirectory: true)
            addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
            let suite = "favorites-\(UUID())"
            addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
            return (try NyCore(dataDirectory: folder), try XCTUnwrap(UserDefaults(suiteName: suite)))
        }
        func favorites(_ core: NyCore) -> [String] { core.setting(.favoriteLanguages, default: []) }

        let (german, germanDefaults) = try fresh()
        XCTAssertEqual(favorites(german), NyCore.coreFavorites, "the copy must match the core's own default")
        german.seedFavoriteLanguages(device: "German", defaults: germanDefaults)
        XCTAssertEqual(favorites(german), ["English", "German"])
        try german.setSetting(.favoriteLanguages, NyCore.coreFavorites)
        german.seedFavoriteLanguages(device: "German", defaults: germanDefaults)
        XCTAssertEqual(favorites(german), NyCore.coreFavorites, "only once per Mac")

        for device in ["English", "Japanese"] {
            let (core, defaults) = try fresh()
            core.seedFavoriteLanguages(device: device, defaults: defaults)
            XCTAssertEqual(favorites(core), NyCore.coreFavorites, device)
        }

        let (changed, changedDefaults) = try fresh()
        try changed.setSetting(.favoriteLanguages, ["English", "Korean"])
        changed.seedFavoriteLanguages(device: "French", defaults: changedDefaults)
        XCTAssertEqual(favorites(changed), ["English", "Korean"])
    }
}
