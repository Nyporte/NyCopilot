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

    /// A color the first frame's palette could only round (a small patch among thousands of others)
    /// stays the same in the next frame, which has few colors: it's drawn again, now exact, rather
    /// than left wrong for as long as it doesn't change.
    func testGifWriterRedrawsColorsItHadToRound() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("r-\(UUID()).gif")
        defer { try? FileManager.default.removeItem(at: url) }
        let size = (width: 320, height: 200)
        let writer = try XCTUnwrap(GifWriter(url: url, width: size.width, height: size.height))
        func frame(busy: Bool) -> CGImage {
            let context = CGContext(data: nil, width: size.width, height: size.height, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height))
            if busy {
                for x in stride(from: 0, to: size.width, by: 4) {
                    for y in stride(from: 0, to: size.height, by: 4) {
                        context.setFillColor(CGColor(red: CGFloat(x) / 320, green: CGFloat(y) / 200, blue: CGFloat((x * y) % 7) / 7, alpha: 1))
                        context.fill(CGRect(x: x, y: y, width: 4, height: 4))
                    }
                }
            }
            context.setFillColor(CGColor(red: 1, green: 0, blue: 0.8, alpha: 1))
            context.fill(CGRect(x: 20, y: 180, width: 4, height: 4))
            return context.makeImage()!
        }
        writer.add(frame(busy: true), at: 0)
        writer.add(frame(busy: false), at: 0.1)
        XCTAssertTrue(writer.finish(at: 0.2))
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let shown = try sRGB(try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 1, nil)), x: 22, y: 182)
        let patch = try sRGB(frame(busy: false), x: 22, y: 182)
        XCTAssertEqual(shown.red, patch.red, accuracy: 3)
        XCTAssertEqual(shown.green, patch.green, accuracy: 3)
        XCTAssertEqual(shown.blue, patch.blue, accuracy: 3)
    }

    /// A pixel's sRGB bytes, counted from the bottom-left like Core Graphics draws.
    private func sRGB(_ image: CGImage, x: Int, y: Int) throws -> (red: Int, green: Int, blue: Int) {
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        // Memory rows count from the top.
        let offset = ((image.height - 1 - y) * image.width + x) * 4
        return (Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2]))
    }

    /// Two small changes in opposite corners make a frame as large as the image; the pixels between
    /// them are left transparent, so they cost next to nothing and still show the frame before.
    func testGifWriterLeavesUnchangedPixelsTransparent() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("t-\(UUID()).gif")
        defer { try? FileManager.default.removeItem(at: url) }
        let size = (width: 320, height: 200)
        let writer = try XCTUnwrap(GifWriter(url: url, width: size.width, height: size.height))
        func frame(corners: Bool) -> CGImage {
            let context = CGContext(data: nil, width: size.width, height: size.height, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            // A detailed background, like a screen's, which would be expensive to store again.
            for x in stride(from: 0, to: size.width, by: 2) {
                for y in stride(from: 0, to: size.height, by: 2) {
                    let shade = CGFloat((x * 7 + y * 3) % 12) / 12
                    context.setFillColor(CGColor(red: shade, green: 1 - shade, blue: (x + y) % 4 == 0 ? 1 : 0.4, alpha: 1))
                    context.fill(CGRect(x: x, y: y, width: 2, height: 2))
                }
            }
            if corners {
                context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
                context.fill(CGRect(x: 0, y: 0, width: 6, height: 6))
                context.fill(CGRect(x: size.width - 6, y: size.height - 6, width: 6, height: 6))
            }
            return context.makeImage()!
        }
        writer.add(frame(corners: false), at: 0)
        writer.add(frame(corners: true), at: 0.1)
        let first = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        XCTAssertTrue(writer.finish(at: 0.2))
        let total = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        XCTAssertLessThan(total - first, 4_000, "the second frame stores its two corners, not the background between them")

        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let before = NSBitmapImageRep(cgImage: try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil)))
        let after = NSBitmapImageRep(cgImage: try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 1, nil)))
        // Between the corners, exactly what the first frame showed; the corners are black.
        for (x, y) in [(160, 100), (40, 150), (300, 20), (10, 10), (309, 189)] {
            XCTAssertEqual(after.colorAt(x: x, y: y), before.colorAt(x: x, y: y), "at \(x), \(y)")
        }
        // Bitmap rows count from the top: the corners drawn bottom-left and top-right.
        for (x, y) in [(2, 197), (317, 2)] {
            XCTAssertLessThan(try XCTUnwrap(after.colorAt(x: x, y: y)).brightnessComponent, 0.05, "at \(x), \(y)")
        }
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
