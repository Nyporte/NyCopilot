import AppKit
import ImageIO
import MacPlatform
import XCTest
@testable import NyCopilotKit

/// The parts with no screen in them: timing curves, snooze times, key schemes, exports, the GIF
/// encoder, stuck capture streams, the core bridge's settings cache, reversing and gliding a wheel, and
/// the menu bar divider.
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
        // Each shell gives its own: capture's three, translate's one, the inbox's two, Ask's one.
        XCTAssertEqual(fkeys.count, 7)
        XCTAssertEqual(fkeys[CaptureShell.Action.capture], HotKeyCombination(keyCode: 122, modifiers: 0), "F1")
        XCTAssertEqual(fkeys[InboxShell.Action.open], HotKeyCombination(keyCode: 99, modifiers: HotKeyCombination.shift), "⇧F3")
        XCTAssertEqual(letters[TranslateShell.Action.compose], HotKeyCombination(keyCode: 17, modifiers: HotKeyCombination.option | HotKeyCombination.command), "⌥⌘T")
        XCTAssertEqual(letters[AskShell.Action.open], HotKeyCombination(keyCode: 0, modifiers: HotKeyCombination.option | HotKeyCombination.command), "⌥⌘A")
        for scheme in [fkeys, letters] {
            let pairs = scheme.values.map { "\($0.keyCode)-\($0.modifiers)" }
            XCTAssertEqual(Set(pairs).count, pairs.count, "no two actions share a key")
        }
    }

    /// Ask AI joined the key schemes as F4 (or ⌥⌘A): someone on ⌥⌘ letters keeps ⌥⌘A, someone on
    /// F-keys moves to F4, and a key someone chose stays theirs.
    @MainActor
    func testAskKeepsItsKeyOnLetters() throws {
        func fresh() throws -> (NyCore, Preferences) {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("core-\(UUID())", isDirectory: true)
            addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
            let core = try NyCore(dataDirectory: folder)
            return (core, Preferences(core: core))
        }
        let ask = AskShell.Action.open, capture = CaptureShell.Action.capture
        let letters = KeyScheme.letters.combinations, fkeys = KeyScheme.functionKeys.combinations
        func key(_ preferences: Preferences) -> HotKeyCombination? { preferences.hotKey(for: ask, default: fkeys[ask]) }

        let (chose, choseLetters) = try fresh()
        try chose.setSetting(.keyScheme, KeyScheme.letters.rawValue)
        AskShell.keepKeyOnLetters(choseLetters)
        XCTAssertEqual(key(choseLetters), letters[ask])

        let (_, before) = try fresh()
        before.setHotKey(letters[capture], for: capture)
        AskShell.keepKeyOnLetters(before)
        XCTAssertEqual(key(before), letters[ask], "letters from before the setup guide saved a scheme")

        let (onKeys, functionKeys) = try fresh()
        try onKeys.setSetting(.keyScheme, KeyScheme.functionKeys.rawValue)
        AskShell.keepKeyOnLetters(functionKeys)
        XCTAssertFalse(functionKeys.hasStoredHotKey(for: ask))
        XCTAssertEqual(key(functionKeys), HotKeyCombination(keyCode: 118, modifiers: 0))

        let (_, newcomer) = try fresh()
        AskShell.keepKeyOnLetters(newcomer)
        XCTAssertFalse(newcomer.hasStoredHotKey(for: ask), "a new Mac gets its keys from the setup guide")

        let (custom, customized) = try fresh()
        try custom.setSetting(.keyScheme, KeyScheme.letters.rawValue)
        let own = HotKeyCombination(keyCode: 40, modifiers: HotKeyCombination.control | HotKeyCombination.command)
        customized.setHotKey(own, for: ask)
        AskShell.keepKeyOnLetters(customized)
        XCTAssertEqual(key(customized), own)
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
        let core = try NyCore(dataDirectory: folder.appendingPathComponent("core", isDirectory: true))
        let file = try NoteExport.toMarkdown(content, in: folder, core: core)
        XCTAssertFalse(file.lastPathComponent.contains("/"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.deletingPathExtension().appendingPathExtension("gif").path), "named after the note")
        let text = try String(contentsOf: file)
        XCTAssertTrue(text.hasPrefix("---\ncreated: "))
        XCTAssertTrue(text.contains("url: https://example.com/q3"))
        XCTAssertTrue(text.contains("before Friday"))
        XCTAssertTrue(text.contains(".gif)"), "the screenshot keeps its own type")
        // A second export never overwrites the first.
        XCTAssertNotEqual(try NoteExport.toMarkdown(content, in: folder, core: core), file)
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

    /// A window's white stays exactly white beside near-whites: common colors get palette entries
    /// of their own, found before the nearest-color cache, which lumps 248–255 together.
    func testGifWriterKeepsCommonColorsExact() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("c-\(UUID()).gif")
        defer { try? FileManager.default.removeItem(at: url) }
        let size = (width: 320, height: 200)
        let writer = try XCTUnwrap(GifWriter(url: url, width: size.width, height: size.height))
        let context = try XCTUnwrap(CGContext(data: nil, width: size.width, height: size.height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        // Near-whites (a title bar, borders, antialiasing) read before the white beside them, then a
        // colorful picture that wants most of the palette.
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height))
        for x in Array(0..<40) + Array(240..<size.width) {
            for y in 0..<size.height {
                if x < 40 {
                    let gray = CGFloat(244 + (x * 7 + y * 13) % 11) / 255
                    context.setFillColor(CGColor(srgbRed: gray, green: gray, blue: gray, alpha: 1))
                } else {
                    context.setFillColor(CGColor(srgbRed: CGFloat(x - 240) / 80, green: CGFloat(y) / 200, blue: CGFloat((x * y) % 13) / 13, alpha: 1))
                }
                context.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        writer.add(try XCTUnwrap(context.makeImage()), at: 0)
        XCTAssertTrue(writer.finish(at: 0.1))
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let white = try sRGB(try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil)), x: 140, y: 100)
        XCTAssertEqual([white.red, white.green, white.blue], [255, 255, 255])
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

    /// Events arrive decoded, on the main thread, until the observation is cancelled.
    @MainActor
    func testCoreEventsReachObserversUntilCancelled() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("core-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let core = try NyCore(dataDirectory: folder)
        var seen: [CoreEvent] = []
        let observation = core.observe { seen.append($0) }
        try core.setSetting(.clipboardKeepDays, 7)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(seen, [.settingsChanged(key: SettingKey.clipboardKeepDays.rawValue)])
        observation.cancel()
        try core.setSetting(.clipboardKeepDays, 8)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(seen.count, 1, "nothing after cancelling")
        let delta = #"{"type": "ask.delta", "request_id": "r1", "text": "Two"}"#
        XCTAssertEqual(try JSONDecoder().decode(CoreEvent.self, from: Data(delta.utf8)), .askDelta(requestID: "r1", text: "Two"))
        XCTAssertEqual(try JSONDecoder().decode(CoreEvent.self, from: Data(#"{"type": "later.kind"}"#.utf8)), .unknown(type: "later.kind"))
    }

    /// A finished recording moves into the folder under a new name, keeping its type.
    func testImageFolderTakesOverAFile() throws {
        let images = ImageFolder("logic-images-\(UUID())")
        defer { images.removeAll() }
        let recording = FileManager.default.temporaryDirectory.appendingPathComponent("clip-\(UUID()).GIF")
        try Data("GIF89a".utf8).write(to: recording)
        let name = try images.keep(moving: recording)
        XCTAssertTrue(name.hasSuffix(".gif"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: recording.path), "moved, not copied")
        XCTAssertEqual(try Data(contentsOf: images.file(name)), Data("GIF89a".utf8))
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

    /// Bounds, engines, and language codes are the core's, read through the typed calls.
    func testRangesEnginesAndLocalesComeFromTheCore() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("core-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let core = try NyCore(dataDirectory: folder)
        XCTAssertEqual(core.settingRange(.windowGap), 0...60)
        XCTAssertEqual(core.settingRange(.favoriteLanguages)?.lowerBound, 1, "a list's length")
        XCTAssertNil(core.settingRange(.dragSnap))
        XCTAssertEqual(Set(core.translationEngines().map(\.id)), ["google", "volcengine", "model"])
        try core.setSetting(.engineOrder, ["model"])
        XCTAssertEqual(core.translationEngines().first?.id, "model", "in the order they're tried")
        XCTAssertEqual(core.language("Korean").locale, "ko")
        XCTAssertNil(core.language("Klingon").locale)
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
        let coreDefaults = favorites(german)
        german.seedFavoriteLanguages(device: "German", defaults: germanDefaults)
        XCTAssertEqual(favorites(german), ["English", "German"])
        try german.setSetting(.favoriteLanguages, coreDefaults)
        german.seedFavoriteLanguages(device: "German", defaults: germanDefaults)
        XCTAssertEqual(favorites(german), coreDefaults, "only once per Mac")

        for device in ["English", "Japanese"] {
            let (core, defaults) = try fresh()
            core.seedFavoriteLanguages(device: device, defaults: defaults)
            XCTAssertEqual(favorites(core), coreDefaults, device)
        }

        // A Mac that seeded before the mark moved to the core isn't seeded again.
        let (moved, movedDefaults) = try fresh()
        movedDefaults.set(true, forKey: "NyCopilotSeededFavorites")
        moved.seedFavoriteLanguages(device: "German", defaults: movedDefaults)
        XCTAssertEqual(favorites(moved), coreDefaults)
        XCTAssertFalse(movedDefaults.bool(forKey: "NyCopilotSeededFavorites"), "the old mark goes")

        let (changed, changedDefaults) = try fresh()
        try changed.setSetting(.favoriteLanguages, ["English", "Korean"])
        changed.seedFavoriteLanguages(device: "French", defaults: changedDefaults)
        XCTAssertEqual(favorites(changed), ["English", "Korean"])
    }
    /// A stop the capture service refuses because it lost the stream restarts the service; the
    /// warning shows only if that failed. Other stop failures leave the service alone.
    @MainActor
    func testStuckStreamRestartsCaptureService() async {
        let streams = CaptureStreams()
        let restarts = Counter(), warnings = Counter()
        streams.onStuck = { warnings.count += 1 }
        streams.restartService = { restarts.count += 1; return true }
        let lost = NSError(domain: "com.apple.ScreenCaptureKit.SCStreamErrorDomain", code: -3808)
        await streams.stopFailed("test", lost)
        XCTAssertEqual(restarts.count, 1)
        XCTAssertEqual(warnings.count, 0, "restarted, so nothing is left running")

        await streams.stopFailed("test", NSError(domain: "com.apple.ScreenCaptureKit.SCStreamErrorDomain", code: -3805))
        XCTAssertEqual(restarts.count, 1, "only a lost stream needs a restart")

        streams.restartService = { restarts.count += 1; return false }
        await streams.stopFailed("test", lost)
        XCTAssertEqual(restarts.count, 2)
        XCTAssertEqual(warnings.count, 1, "the restart failed, so say so")
    }

    func testReversingAWheelFlipsBothAxesInEveryUnit() throws {
        let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: 3, wheel2: -2, wheel3: 0))
        let before = (event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1), event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1),
                      event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2))
        MouseWheel.reverse(event)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventDeltaAxis1), -3)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventDeltaAxis2), 2)
        XCTAssertEqual(event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1), -before.0)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), -before.1)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2), -before.2)
        XCTAssertNotEqual(before.1, 0, "a line step carries points too")
    }

    /// Frames at `hz` for `seconds`: the points sent each frame, vertically.
    private func frames(_ glide: inout ScrollGlide, hz: Double, seconds: Double) -> [Int] {
        (0..<Int((seconds * hz).rounded())).map { _ in glide.frame(dt: 1 / hz).y }
    }

    func testAGlidingClickSendsItsWholeDistanceAndStopsOnTime() {
        var slow = ScrollGlide()
        slow.add(x: 0, y: 3, lines: 3, boost: 1, glide: 0.2, at: 0)
        let steps = frames(&slow, hz: 144, seconds: 0.2)
        XCTAssertEqual(steps.reduce(0, +), 101, "3 lines of 33.6 points, rounded once at the end")
        XCTAssertTrue(steps.allSatisfy { $0 >= 0 })
        XCTAssertGreaterThan(steps[1], steps[20], "from a standstill it starts at once, then eases off")
        XCTAssertTrue(slow.isIdle, "and it's done when the glide is")

        var quick = ScrollGlide()
        quick.add(x: 0, y: -80, lines: 3, boost: 1, glide: 0.2, at: 0)
        XCTAssertEqual(frames(&quick, hz: 144, seconds: 0.3).reduce(0, +), -240, "a quick spin goes as far as macOS sends it, times the lines")
        var boosted = ScrollGlide()
        boosted.add(x: 0, y: 1, lines: 1, boost: 5, glide: 0.2, at: 0)
        XCTAssertEqual(frames(&boosted, hz: 60, seconds: 0.3).reduce(0, +), 168)
    }

    func testASteadySpinScrollsAtASteadyPaceEvenWithAShortGlide() {
        // A click every 80 ms with a 50 ms glide: each used to finish (and the page stop) before the next.
        var spin = ScrollGlide()
        var steps: [Int] = []
        for click in 0..<10 {
            spin.add(x: 0, y: 1, lines: 3, boost: 1, glide: 0.05, at: Double(click) * 0.08)
            steps += frames(&spin, hz: 144, seconds: 0.08)
        }
        let middle = steps[Int(0.24 * 144)..<Int(0.72 * 144)]
        XCTAssertGreaterThanOrEqual(Double(middle.min() ?? 0), 0.4 * Double(middle.max() ?? 0), "no stalls between clicks: \(Array(middle))")
        steps += frames(&spin, hz: 144, seconds: 0.4)
        XCTAssertEqual(steps.reduce(0, +), 1008, "every click arrives")
        XCTAssertTrue(spin.isIdle)

        var single = ScrollGlide()
        single.add(x: 0, y: 1, lines: 3, boost: 1, glide: 0.05, at: 5)
        _ = frames(&single, hz: 144, seconds: 8 / 144)
        XCTAssertTrue(single.isIdle, "a lone click keeps the short glide: done in the 8 frames 50 ms spans")
    }

    func testAGlideFeelsTheSameAtAnyRefreshRate() {
        var at60 = ScrollGlide(), at144 = ScrollGlide()
        at60.add(x: 0, y: 1, lines: 3, boost: 1, glide: 0.2, at: 0)
        at144.add(x: 0, y: 1, lines: 3, boost: 1, glide: 0.2, at: 0)
        XCTAssertEqual(Double(frames(&at60, hz: 60, seconds: 0.1).reduce(0, +)), Double(frames(&at144, hz: 144, seconds: 0.1).reduce(0, +)), accuracy: 2)
    }

    func testClickingTheOtherWayTurnsAtOnceAndNoGlideSendsAllAtOnce() {
        var turning = ScrollGlide()
        turning.add(x: 0, y: 1, lines: 3, boost: 1, glide: 0.2, at: 0)
        _ = frames(&turning, hz: 144, seconds: 0.02)
        turning.add(x: 0, y: -1, lines: 3, boost: 1, glide: 0.2, at: 0.02)
        let after = frames(&turning, hz: 144, seconds: 0.4)
        XCTAssertTrue(after.allSatisfy { $0 <= 0 }, "nothing more goes the old way")
        XCTAssertEqual(after.reduce(0, +), -101)

        var instant = ScrollGlide()
        instant.add(x: 2, y: 0, lines: 2, boost: 1, glide: 0, at: 0)
        XCTAssertEqual(instant.frame(dt: 1 / 144).x, 67)
        XCTAssertTrue(instant.isIdle)
    }

    /// The lookup made at launch, before NyCopilot had a window up, can't leave NyCopilot out, so
    /// screen translation mustn't capture with it: its overlay would be in every glance.
    func testACaptureLookupWithoutNyCopilotIsMadeAgainBeforeLeavingNyCopilotOut() {
        let atLaunch = (displays: [CGDirectDisplayID(3)], applications: [pid_t(160), 464, 508])
        XCTAssertFalse(ScreenGrabber.serves(displays: atLaunch.displays, applications: atLaunch.applications, for: [3],
                                            hidingOwnWindows: true, own: 30817))
        XCTAssertTrue(ScreenGrabber.serves(displays: atLaunch.displays, applications: atLaunch.applications, for: [3],
                                           hidingOwnWindows: false, own: 30817), "nothing to leave out")
        XCTAssertTrue(ScreenGrabber.serves(displays: atLaunch.displays, applications: atLaunch.applications + [30817], for: [3],
                                           hidingOwnWindows: true, own: 30817))
        XCTAssertFalse(ScreenGrabber.serves(displays: atLaunch.displays, applications: atLaunch.applications + [30817], for: [3, 4],
                                            hidingOwnWindows: true, own: 30817), "a display plugged in since")
    }

    /// Hidden, the divider grows wide enough to carry the icons left of it off every screen; shown,
    /// it's the arrow itself, and shown icons hide again only when asked to.
    func testMenuBarDividerHidesByGrowingAndShowsAsTheArrow() {
        var state = MenuBarState(isOn: true, collapsed: true, collapseAfter: 10)
        XCTAssertEqual(state.dividerLength, 10_000)
        XCTAssertGreaterThan(state.dividerLength, 7680, "wider than an 8K display at 1×")
        XCTAssertNil(state.hideAgainIn, "already hidden")
        state.collapsed = false
        XCTAssertEqual(state.dividerLength, NSStatusItem.variableLength, "the arrow, as wide as its image")
        XCTAssertEqual(state.hideAgainIn, 10)
        state.collapseAfter = 0
        XCTAssertNil(state.hideAgainIn, "never")
        state.collapseAfter = 5
        state.isOn = false
        XCTAssertNil(state.hideAgainIn, "off: no divider to hide behind")
        XCTAssertTrue(MenuBarState.collapseAfterChoices.contains(0) && MenuBarState.collapseAfterChoices.contains(10))
    }

    /// Off until asked for and shown at first; whether icons are hidden survives a relaunch; the
    /// feature switched off in General takes the divider away whatever its own switch says.
    @MainActor
    func testMenuBarHidingIsKeptAcrossLaunches() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("menubar-\(UUID())", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        var core: NyCore? = try NyCore(dataDirectory: folder)
        XCTAssertEqual(MenuBarState.read(core!, moduleOn: true), MenuBarState(isOn: false, collapsed: false, collapseAfter: 10))

        try core!.setSetting(.menuBarEnabled, true)
        try core!.setSetting(.menuBarCollapsed, true)
        try core!.setSetting(.menuBarCollapseAfter, 30.0)
        XCTAssertThrowsError(try core!.setSetting(.menuBarCollapseAfter, 601.0))
        core = nil

        let relaunched = try NyCore(dataDirectory: folder)
        let state = MenuBarState.read(relaunched, moduleOn: true)
        XCTAssertEqual(state, MenuBarState(isOn: true, collapsed: true, collapseAfter: 30))
        XCTAssertEqual(state.dividerLength, MenuBarState.hidingLength)
        XCTAssertFalse(MenuBarState.read(relaunched, moduleOn: false).isOn)

        try relaunched.setSetting(.menuBarCollapsed, false)
        XCTAssertEqual(MenuBarState.read(relaunched, moduleOn: true).dividerLength, MenuBarState.shownLength)

        XCTAssertFalse(MenuBarState.read(relaunched, moduleOn: true).showInBar, "the bar is off until asked for")
        try relaunched.setSetting(.menuBarShowInBar, true)
        XCTAssertTrue(MenuBarState.read(relaunched, moduleOn: true).showInBar)
    }

    /// The arrow opens the bar only while icons are hidden and the bar is asked for; shown, it hides.
    func testMenuBarArrowOpensTheBarOnlyWhileHidden() {
        var state = MenuBarState(isOn: true, collapsed: true, collapseAfter: 10, showInBar: true)
        XCTAssertTrue(state.opensBar)
        state.collapsed = false
        XCTAssertFalse(state.opensBar, "shown: a click hides them")
        state.collapsed = true
        state.showInBar = false
        XCTAssertFalse(state.opensBar, "shows them in the menu bar, as before")
        state.showInBar = true
        state.isOn = false
        XCTAssertFalse(state.opensBar)
    }

    /// One status window as the window list gives it.
    private func statusWindow(_ number: Int, _ owner: String, pid: Int, x: CGFloat, y: CGFloat = 0, width: CGFloat,
                              height: CGFloat = 24, layer: Int = 25, onScreen: Bool = false) -> [String: Any] {
        [kCGWindowNumber as String: number, kCGWindowOwnerName as String: owner, kCGWindowOwnerPID as String: pid,
         kCGWindowLayer as String: layer, kCGWindowIsOnscreen as String: onScreen,
         kCGWindowBounds as String: ["X": x, "Y": y, "Width": width, "Height": height]]
    }

    /// The window list measured with icons hidden on a 1920-wide display (macOS 14): the divider
    /// cut to 5,016 pt ending at the arrow, hidden icons left of it, off screen.
    private var hiddenMenuBar: [[String: Any]] {
        [statusWindow(35, "Control Center", pid: 465, x: -3576, width: 38),
         statusWindow(75138, "WeChat", pid: 69596, x: -3504, width: 38),
         statusWindow(91246, "Lark Helper", pid: 56366, x: -3538, width: 34),
         statusWindow(45888, "Claude", pid: 44042, x: -3466, width: 40),
         statusWindow(53, "Tailscale", pid: 646, x: -3392, width: 38),
         statusWindow(91210, "NyCopilot", pid: 56239, x: -3354, width: 5016),
         statusWindow(90834, "AccessibilityVisualsAgent", pid: 54333, x: 88, y: 768, width: 224, height: 224),
         statusWindow(2104, "Control Center", pid: 465, x: 1435, width: 39),
         statusWindow(91209, "NyCopilot", pid: 56239, x: 1662, width: 26, onScreen: true),
         statusWindow(91207, "NyCopilot", pid: 56239, x: 1688, width: 34, onScreen: true),
         statusWindow(34, "Control Center", pid: 465, x: 1722, width: 76, onScreen: true),
         statusWindow(1, "Finder", pid: 400, x: 0, width: 1920, layer: 0, onScreen: true)]
    }

    /// Hidden icons are the status windows left of the divider on its menu bar, in order; the
    /// divider, the arrow, icons right of it, other screens' menu bars, and other windows aren't.
    func testMenuBarFindsTheIconsHiddenLeftOfTheDivider() {
        let items = hiddenMenuBar.compactMap(ItemFinder.Item.init)
        XCTAssertEqual(items.count, 11, "the Finder window isn't a status item")
        let hidden = ItemFinder.hidden(in: items, divider: 91210, own: 56239)
        XCTAssertEqual(hidden.map(\.owner), ["Control Center", "Lark Helper", "WeChat", "Claude", "Tailscale"])
        XCTAssertEqual(hidden.first?.frame, CGRect(x: -3576, y: 0, width: 38, height: 24))
        XCTAssertFalse(hidden.contains { $0.onScreen })

        XCTAssertEqual(ItemFinder.hidden(in: items, divider: 999, own: 56239), [], "no divider, nothing to tell apart")
        XCTAssertEqual(ItemFinder.hidden(in: items, divider: 91209, own: 56239).count, 6,
                       "measured from the arrow instead, the hidden Control Center window right of the divider counts too")

        // A second display above this one has its own menu bar, 1,080 pt higher.
        let above = items + [ItemFinder.Item(window: 7, pid: 900, owner: "Other", frame: CGRect(x: -100, y: -1080, width: 30, height: 24), onScreen: true)]
        XCTAssertFalse(ItemFinder.hidden(in: above, divider: 91210, own: 56239).contains { $0.owner == "Other" })
    }

    /// An icon's Accessibility item is the one whose frame sits inside its window (8 pt in, for
    /// the padding), whatever order the app lists them in; one icon and one item go together
    /// anyway; otherwise none is guessed.
    func testMenuBarMatchesIconsToTheirAccessibilityItems() {
        let controlCenter = ItemFinder.Item(window: 35, pid: 465, owner: "Control Center", frame: CGRect(x: -3576, y: 0, width: 38, height: 24), onScreen: false)
        // As measured: Clock, Control Center, Battery, Sound; five windows for four items.
        let axFrames: [CGRect?] = [CGRect(x: 1884, y: 1, width: 28, height: 22), CGRect(x: 1846, y: 1, width: 26, height: 22),
                                   CGRect(x: 1730, y: 1, width: 59, height: 22), CGRect(x: -3568, y: 1, width: 22, height: 22)]
        XCTAssertEqual(ItemFinder.match(controlCenter, appIcons: 5, axFrames: axFrames), 3)
        XCTAssertNil(ItemFinder.match(controlCenter, appIcons: 5, axFrames: Array(axFrames.prefix(3))), "not listed: no guessing by order")

        // Claude's item is as big as its window.
        let claude = ItemFinder.Item(window: 45888, pid: 44042, owner: "Claude", frame: CGRect(x: -3466, y: 0, width: 40, height: 24), onScreen: false)
        XCTAssertEqual(ItemFinder.match(claude, appIcons: 1, axFrames: [CGRect(x: -3466, y: 0, width: 40, height: 24)]), 0)
        XCTAssertEqual(ItemFinder.match(claude, appIcons: 1, axFrames: [nil]), 0, "one icon, one item")
        XCTAssertEqual(ItemFinder.match(claude, appIcons: 1, axFrames: [CGRect(x: 1550, y: 1, width: 40, height: 22)]), 0, "a stale frame")
        XCTAssertNil(ItemFinder.match(claude, appIcons: 2, axFrames: [CGRect(x: 1550, y: 1, width: 40, height: 22)]))
        XCTAssertNil(ItemFinder.match(claude, appIcons: 1, axFrames: []), "no AX items: the click is synthesized")
    }

    /// The bar hangs right-aligned under the arrow, below the menu bar, and stays on its screen.
    func testHiddenItemsBarSitsUnderTheArrow() {
        let arrow = NSRect(x: 1662, y: 1056, width: 26, height: 24)
        let screen = NSRect(x: 0, y: 0, width: 1920, height: 1080)
        XCTAssertEqual(HiddenItemsBar.frame(size: NSSize(width: 200, height: 32), under: arrow, on: screen),
                       NSRect(x: 1488, y: 1020, width: 200, height: 32))
        XCTAssertEqual(HiddenItemsBar.frame(size: NSSize(width: 200, height: 32), under: NSRect(x: 100, y: 1056, width: 26, height: 24), on: screen).minX, 4,
                       "kept on screen")
        XCTAssertEqual(HiddenItemsBar.frame(size: NSSize(width: 200, height: 32), under: NSRect(x: 1910, y: 1056, width: 26, height: 24), on: screen).maxX, 1916)
    }

    /// Menu Bar turned off and on puts the arrow back where it was: macOS forgets the place of an
    /// item out of the bar, so NyCopilot's kept copy is written back, but never over a place macOS has.
    func testMenuBarArrowComesBackWhereItWas() {
        // Measured on macOS 14: saved at 431 (x 1443), back at x 1365 with nothing written back.
        XCTAssertEqual(MenuBarState.dividerPosition(saved: nil, kept: 431), 431)
        XCTAssertNil(MenuBarState.dividerPosition(saved: 431, kept: 431), "macOS still has it")
        XCTAssertNil(MenuBarState.dividerPosition(saved: 290, kept: 431), "dragged since: where macOS has it")
        XCTAssertNil(MenuBarState.dividerPosition(saved: nil, kept: nil), "never placed: wherever macOS puts it")
    }

    /// The chevron comes back right beside the divider, and hiding with it anywhere left of the
    /// divider would hide it too; a pointer on the
    /// menu bar (taller beside a notch, or hidden in full screen) keeps shown icons shown.
    func testMenuBarHidesOnlyWithTheChevronInSightAndNotUnderThePointer() {
        // Measured on macOS 14: the chevron came back at 1563, where the divider (saved at 331) ended.
        XCTAssertEqual(MenuBarState.chevronPosition(dividerSaved: 331, dividerMaxX: 1589, screenMaxX: 1920), 330)
        XCTAssertEqual(MenuBarState.chevronPosition(dividerSaved: nil, dividerMaxX: 1589, screenMaxX: 1920), 330, "never dragged: where it is")
        XCTAssertEqual(MenuBarState.chevronPosition(dividerSaved: nil, dividerMaxX: 3029, screenMaxX: 3360), 330, "a second display to the right")
        XCTAssertNil(MenuBarState.chevronPosition(dividerSaved: nil, dividerMaxX: 0, screenMaxX: 1920), "not placed yet")
        XCTAssertNil(MenuBarState.chevronPosition(dividerSaved: nil, dividerMaxX: nil, screenMaxX: nil))

        XCTAssertTrue(MenuBarState.canHide(divider: 1563, chevron: 1563))
        XCTAssertFalse(MenuBarState.canHide(divider: 1563, chevron: 1349), "came back at the far left")
        XCTAssertTrue(MenuBarState.canHide(divider: 1370, chevron: 1370))
        XCTAssertTrue(MenuBarState.canHide(divider: 1342, chevron: 1370))
        XCTAssertFalse(MenuBarState.canHide(divider: 1396, chevron: 1342), "dragged right of the chevron")

        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let notched = CGRect(x: 0, y: 0, width: 1512, height: 945)
        XCTAssertTrue(MenuBarState.isOnMenuBar(CGPoint(x: 900, y: 950), frame: screen, visibleFrame: notched, thickness: 24))
        XCTAssertFalse(MenuBarState.isOnMenuBar(CGPoint(x: 900, y: 940), frame: screen, visibleFrame: notched, thickness: 24))
        XCTAssertTrue(MenuBarState.isOnMenuBar(CGPoint(x: 900, y: 970), frame: screen, visibleFrame: screen, thickness: 24), "menu bar hidden")
        XCTAssertFalse(MenuBarState.isOnMenuBar(CGPoint(x: 900, y: 950), frame: screen, visibleFrame: screen, thickness: 24))
        let left = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        XCTAssertFalse(MenuBarState.isOnMenuBar(CGPoint(x: 900, y: 1075), frame: left, visibleFrame: left.insetBy(dx: 0, dy: 12), thickness: 24),
                       "another display")
    }

    private final class Counter: @unchecked Sendable { var count = 0 }
}
