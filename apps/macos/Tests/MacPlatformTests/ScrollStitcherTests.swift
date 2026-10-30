import XCTest
@testable import MacPlatform

infix operator |>: AdditionPrecedence
private func |> <A, B>(value: A, transform: (A) -> B) -> B { transform(value) }

final class ScrollStitcherTests: XCTestCase {
    /// A long page of "text": rows of dark word-like blocks at random places on white.
    private struct Page {
        let width: Int, height: Int
        let pixels: [UInt8]

        init(width: Int, height: Int, seed: UInt64) {
            self.width = width
            self.height = height
            var random = seed
            func next() -> Int {
                random &+= 0x9E37_79B9_7F4A_7C15
                var z = random
                z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
                z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
                return Int(truncatingIfNeeded: (z ^ (z >> 31)) & 0x7FFF_FFFF)
            }
            var pixels = [UInt8](repeating: 255, count: width * height * 4)
            var y = 6
            while y < height - 14 {
                let lineHeight = 8 + next() % 6
                var x = 4 + next() % 10
                while x < width - 10 {
                    let word = 6 + next() % 24, shade = UInt8(20 + next() % 90)
                    for row in y..<min(y + lineHeight, height) {
                        for column in x..<min(x + word, width) {
                            let p = (row * width + column) * 4
                            pixels[p] = shade; pixels[p + 1] = shade; pixels[p + 2] = shade
                        }
                    }
                    x += word + 4 + next() % 8
                }
                y += lineHeight + 6 + next() % (next() % 5 == 0 ? 40 : 8)
            }
            self.pixels = pixels
        }

        func rows(_ range: Range<Int>) -> [UInt8] { Array(pixels[(range.lowerBound * width * 4)..<(range.upperBound * width * 4)]) }
    }

    /// The tracked area: a fixed 40-row header, 330 rows of page, a fixed 30-row footer.
    private let width = 240, area = 400, header = 40, footer = 30
    private var content: Int { area - header - footer }
    private lazy var page = Page(width: width, height: 6000, seed: 7)
    private lazy var chrome = Page(width: width, height: header + footer, seed: 99)
    /// The selection: 100 rows in the middle of the scrolling part.
    private let middle = 150..<250

    /// What the area shows with the page scrolled by `offset`.
    private func frame(at offset: Int) -> PixelFrame {
        PixelFrame(width: width, height: area,
                   pixels: chrome.rows(0..<header) + page.rows(offset..<(offset + content)) + chrome.rows(header..<(header + footer)))
    }

    /// Selected rows inside the scrolling part map to page rows `offset + row - header`.
    private func expected(_ selection: Range<Int>, from first: Int, to last: Int) -> [UInt8] {
        let moving = max(selection.lowerBound, header)..<min(selection.upperBound, area - footer)
        let top = selection.lowerBound < header ? chrome.rows(selection.lowerBound..<header) : []
        let bottom = selection.upperBound > area - footer ? chrome.rows(header..<(header + selection.upperBound - (area - footer))) : []
        return top + page.rows((first + moving.lowerBound - header)..<(last + moving.upperBound - header)) + bottom
    }

    private func pixels(_ image: CGImage?) -> [UInt8] {
        guard let image, let data = image.dataProvider?.data else { return [] }
        return Array(data as Data)
    }

    func testJumpsLargerThanTheSelectionStillConnect() {
        let stitcher = ScrollStitcher(selection: middle)
        XCTAssertEqual(stitcher.add(frame(at: 0)), .started)
        XCTAssertEqual(stitcher.add(frame(at: 0)), .unchanged)
        XCTAssertEqual(stitcher.add(frame(at: 37)), .added(37))
        // Twice the selection's height in one frame: the rows are read from above the selection.
        XCTAssertEqual(stitcher.add(frame(at: 238)), .added(201))
        XCTAssertEqual(stitcher.add(frame(at: 439)), .added(201))
        XCTAssertEqual(stitcher.add(frame(at: 450)), .added(11))
        XCTAssertTrue(pixels(stitcher.makeImage()) == expected(middle, from: 0, to: 450))
    }

    func testAGapHealsWhenScrollingBackALittle() {
        let stitcher = ScrollStitcher(selection: middle)
        stitcher.add(frame(at: 0))
        stitcher.add(frame(at: 200))
        // 250 rows at once: some never showed in the area, so nothing is added yet…
        XCTAssertEqual(stitcher.add(frame(at: 450)), .lost)
        // …until scrolling back brings them into view: rows 70–250 of this frame.
        XCTAssertEqual(stitcher.add(frame(at: 380)), .added(180))
        XCTAssertEqual(stitcher.add(frame(at: 580)), .added(200))
        XCTAssertTrue(pixels(stitcher.makeImage()) == expected(middle, from: 0, to: 580))
    }

    func testScrollsUpAndDownFromTheMiddle() {
        let stitcher = ScrollStitcher(selection: middle)
        stitcher.add(frame(at: 1500))
        for offset in stride(from: 1350, through: 0, by: -150) { XCTAssertEqual(stitcher.add(frame(at: offset)), .added(150)) }
        // Back down over what's already there, then on past the starting point.
        for offset in stride(from: 180, through: 1440, by: 180) { XCTAssertEqual(stitcher.add(frame(at: offset)), .covered) }
        for offset in stride(from: 1620, through: 1980, by: 180) { XCTAssertEqual(stitcher.add(frame(at: offset)), .added(offset == 1620 ? 120 : 180)) }
        XCTAssertEqual(stitcher.add(frame(at: 1980)), .unchanged)
        XCTAssertEqual(stitcher.height, 1980 + 100)
        XCTAssertTrue(pixels(stitcher.makeImage()) == expected(middle, from: 0, to: 1980))
    }

    func testFixedBarsInsideTheSelectionAppearOnce() {
        let selection = 20..<390
        let stitcher = ScrollStitcher(selection: selection)
        for offset in stride(from: 0, through: 960, by: 120) { stitcher.add(frame(at: offset)) }
        XCTAssertEqual(stitcher.height, 960 + selection.count)
        XCTAssertTrue(pixels(stitcher.makeImage()) == expected(selection, from: 0, to: 960))
    }

    func testFirstFrameAloneIsTheSelection() {
        let stitcher = ScrollStitcher(selection: middle)
        stitcher.add(frame(at: 120))
        XCTAssertEqual(stitcher.height, middle.count)
        XCTAssertEqual(pixels(stitcher.makeImage()), Array(frame(at: 120).pixels[(middle.lowerBound * width * 4)..<(middle.upperBound * width * 4)]))
    }

    func testStopsAtTheMaximumHeight() {
        let stitcher = ScrollStitcher(selection: middle, maxHeight: 700)
        stitcher.add(frame(at: 0))
        var outcome = ScrollStitcher.Outcome.started
        for offset in stride(from: 150, through: 1500, by: 150) where outcome != .full { outcome = stitcher.add(frame(at: offset)) }
        XCTAssertEqual(outcome, .full)
        XCTAssertEqual(stitcher.add(frame(at: 1650)), .full)
        XCTAssertGreaterThanOrEqual(stitcher.height, 700)
    }

    func testBlankAreasAreNotGuessed() {
        let blank = PixelFrame(width: 100, height: 200, pixels: [UInt8](repeating: 255, count: 100 * 200 * 4))
        var shifted = blank.pixels
        for p in stride(from: 100 * 4 * 150, to: 100 * 4 * 151, by: 4) { shifted[p] = 0 }
        let stitcher = ScrollStitcher(selection: 50..<150)
        stitcher.add(blank)
        XCTAssertFalse([.added(1), .covered].contains(stitcher.add(PixelFrame(width: 100, height: 200, pixels: shifted))))
    }

    func testThumbnailStaysSmallHoweverLongTheImage() {
        let big = Page(width: 720, height: 9000, seed: 5)
        func bigFrame(_ offset: Int) -> PixelFrame { PixelFrame(width: 720, height: 800, pixels: big.rows(offset..<(offset + 800))) }
        let stitcher = ScrollStitcher(selection: 0..<800)
        stitcher.add(bigFrame(0))
        XCTAssertEqual(stitcher.makeThumbnail().map { [$0.width, $0.height] }, [360, 400])
        for offset in stride(from: 540, through: 8100, by: 540) {
            stitcher.add(bigFrame(offset))
            _ = stitcher.makeThumbnail()
        }
        let thumbnail = stitcher.makeThumbnail()!
        // 8,900 rows at a half or a quarter would be past the limit, so an eighth.
        XCTAssertEqual(stitcher.height, 8900)
        XCTAssertEqual(thumbnail.width, 90)
        XCTAssertEqual(thumbnail.height, 8900 / 8, accuracy: 3)
    }

    /// Closer to a real window: a toolbar, a sparse web page (words with glyph-like strokes, wide blank
    /// gaps between paragraphs, the odd image), and a chat composer whose caret blinks.
    private struct Window {
        let width: Int, toolbar = 70, composer = 90, area: Int
        let page: [UInt8], chrome: Page

        init(width: Int, area: Int, pageHeight: Int) {
            self.width = width
            self.area = area
            chrome = Page(width: width, height: 70 + 90, seed: 11)
            var pixels = [UInt8](repeating: 255, count: width * pageHeight * 4)
            var random: UInt64 = 21
            func next() -> Int { random = random &* 6364136223846793005 &+ 1442695040888963407; return Int(random >> 33) }
            func box(_ y: Int, _ height: Int, _ x: Int, _ w: Int, _ shade: UInt8, glyphs: Bool = false) {
                let seed = next()
                for row in y..<min(y + height, pageHeight) { for column in x..<min(x + w, width) {
                    // Glyphs: strokes that differ from row to row, like the inside of letters.
                    let ink = !glyphs || ((column * 7 + (row - y) * 13 + seed) % 11 < 5)
                    let value = ink ? shade : 235
                    let p = (row * width + column) * 4; pixels[p] = value; pixels[p + 1] = value; pixels[p + 2] = value } }
            }
            var y = 120
            while y < pageHeight - 200 {
                if next() % 7 == 0 { box(y, 140 + next() % 120, 20, width - 40, UInt8(60 + next() % 120)); y += 300; continue }
                for _ in 0..<(2 + next() % 5) {
                    var x = 20
                    let lineWidth = width - 40 - (next() % 3 == 0 ? next() % (width / 2) : 0)
                    while x < lineWidth { let word = 10 + next() % 40; box(y, 16, x, min(word, lineWidth - x), UInt8(30 + next() % 50), glyphs: true); x += word + 9 }
                    y += 30
                }
                y += 40 + next() % 90
            }
            page = pixels
        }

        /// `header`: the site's header slid in at the top of the page (it shows when scrolling up).
        /// Always present: a hover highlight under the pointer and a video-like ad (new noise every
        /// frame), both outside the selection.
        func frame(at offset: Int, caret: Bool, header: Bool = false, tick: Int = 0) -> PixelFrame {
            let content = area - toolbar - composer
            var bottom = chrome.rows(toolbar..<(toolbar + composer))
            if caret { for row in 30..<56 { for column in 40..<43 { let p = (row * width + column) * 4; bottom[p] = 0; bottom[p + 1] = 0; bottom[p + 2] = 0 } } }
            var middle = Array(page[(offset * width * 4)..<((offset + content) * width * 4)])
            func paint(_ rows: Range<Int>, _ color: (Int, Int) -> (UInt8, UInt8, UInt8)) {
                for row in rows { for column in 0..<width {
                    let p = (row * width + column) * 4, c = color(row, column); middle[p] = c.0; middle[p + 1] = c.1; middle[p + 2] = c.2 } }
            }
            if header { paint(0..<60) { _, column in column % 40 < 30 ? (40, 40, 48) : (220, 220, 230) } }
            // Hover: a tint over whatever row sits under the pointer.
            paint(610..<640) { row, column in let p = (row * width + column) * 4; return (UInt8(min(255, Int(middle[p]) + 0)), middle[p + 1], UInt8(min(255, Int(middle[p + 2]) / 2 + 128))) }
            // An ad that animates every frame.
            paint(640..<700) { row, column in
                var z = UInt64(row * 1_000_003 + column * 7919 + tick * 104_729) &* 0x9E37_79B9_7F4A_7C15
                z ^= z >> 29
                return UInt8(truncatingIfNeeded: z) |> { ($0, $0 &+ 80, 255 &- $0) }
            }
            return PixelFrame(width: width, height: area, pixels: chrome.rows(0..<toolbar) + middle + bottom)
        }

        func expected(_ selection: Range<Int>, from first: Int, to last: Int) -> [UInt8] {
            Array(page[((first + selection.lowerBound - toolbar) * width * 4)..<((last + selection.upperBound - toolbar) * width * 4)])
        }
    }

    func testRealisticWindowWithFlicksBothWays() {
        let window = Window(width: 320, area: 900, pageHeight: 9000)
        let selection = 400..<520
        let stitcher = ScrollStitcher(selection: selection)
        // A trackpad: a two-pixel nudge, a flick that speeds up and coasts to a stop, then back up, then on.
        var offsets = [1500, 1500, 1502]
        for step in [4, 10, 24, 50, 90, 140, 190, 230, 230, 200, 160, 120, 80, 50, 30, 14, 6, 2] { offsets.append(offsets.last! + step) }
        for step in [-8, -40, -120, -220, -260, -200, -90, -20] { offsets.append(offsets.last! + step) }
        for step in [10, 60, 160, 240, 240, 240, 180, 90, 20] { offsets.append(offsets.last! + step) }
        var outcomes: [ScrollStitcher.Outcome] = []
        for (index, offset) in offsets.enumerated() {
            let scrollingUp = index > 0 && offset < offsets[index - 1]
            outcomes.append(stitcher.add(window.frame(at: offset, caret: index % 2 == 0, header: scrollingUp, tick: index)))
        }
        XCTAssertFalse(outcomes.contains(.lost), "\(outcomes)")
        let first = offsets.min()!, last = offsets.max()!
        XCTAssertEqual(stitcher.height, last - first + selection.count)
        XCTAssertTrue(pixels(stitcher.makeImage()) == window.expected(selection, from: first, to: last), "stitched pixels differ")
    }

    func testMatchingIsFast() {
        let big = Page(width: 1600, height: 6000, seed: 3)
        func bigFrame(_ offset: Int) -> PixelFrame { PixelFrame(width: 1600, height: 1400, pixels: big.rows(offset..<(offset + 1400))) }
        let stitcher = ScrollStitcher(selection: 400..<900)
        stitcher.add(bigFrame(0))
        let started = Date()
        XCTAssertEqual(stitcher.add(bigFrame(180)), .added(180))
        let elapsed = Date().timeIntervalSince(started)
        print(String(format: "1600×1400 frame matched in %.1f ms", elapsed * 1000))
        // Optimized, a frame at 60 fps has about 16 ms; unoptimized test builds run far slower.
        XCTAssertLessThan(elapsed, _isDebugAssertConfiguration() ? 5 : 0.012)
    }
}
