import XCTest
@testable import MacPlatform

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

    private let width = 240, viewport = 300, header = 40, footer = 24
    private lazy var page = Page(width: width, height: 4000, seed: 7)
    private lazy var chrome = Page(width: width, height: header + footer, seed: 99)

    /// What the region shows with the page scrolled by `offset`: a fixed header, the page, a fixed footer.
    private func frame(at offset: Int) -> PixelFrame {
        let content = viewport - header - footer
        return PixelFrame(width: width, height: viewport,
                          pixels: chrome.rows(0..<header) + page.rows(offset..<(offset + content)) + chrome.rows(header..<(header + footer)))
    }

    private func expected(through offset: Int) -> [UInt8] {
        chrome.rows(0..<header) + page.rows(0..<(offset + viewport - header - footer)) + chrome.rows(header..<(header + footer))
    }

    private func pixels(_ image: CGImage?) -> [UInt8] {
        guard let image, let data = image.dataProvider?.data else { return [] }
        return Array(data as Data)
    }

    func testStitchesScrollsAndKeepsFixedBarsOnce() {
        let stitcher = ScrollStitcher()
        XCTAssertEqual(stitcher.add(frame(at: 0)), .started)
        XCTAssertEqual(stitcher.add(frame(at: 0)), .unchanged)
        XCTAssertEqual(stitcher.add(frame(at: 37)), .appended(37))
        XCTAssertEqual(stitcher.add(frame(at: 38)), .appended(1))
        XCTAssertEqual(stitcher.add(frame(at: 150)), .appended(112))
        // Scrolling back up, or jumping past everything seen, can't be placed; scrolling on resumes.
        XCTAssertEqual(stitcher.add(frame(at: 90)), .lost)
        XCTAssertEqual(stitcher.add(frame(at: 900)), .lost)
        XCTAssertEqual(stitcher.add(frame(at: 260)), .appended(110))
        for offset in stride(from: 300, through: 2200, by: 95) { _ = stitcher.add(frame(at: offset)) }
        XCTAssertEqual(stitcher.add(frame(at: 2250)), .appended(50))

        let result = pixels(stitcher.makeImage())
        XCTAssertEqual(stitcher.height, 2250 + viewport)
        XCTAssertEqual(result.count, expected(through: 2250).count)
        XCTAssertTrue(result == expected(through: 2250), "stitched pixels differ from the page")
    }

    func testFirstFrameAloneIsTheWholeRegion() {
        let stitcher = ScrollStitcher()
        stitcher.add(frame(at: 120))
        XCTAssertEqual(stitcher.height, viewport)
        XCTAssertEqual(pixels(stitcher.makeImage()), frame(at: 120).pixels)
        XCTAssertEqual(stitcher.makeTail(rows: 50)?.height, 50)
    }

    func testStopsAtTheMaximumHeight() {
        let stitcher = ScrollStitcher(maxHeight: 700)
        stitcher.add(frame(at: 0))
        var outcome = ScrollStitcher.Outcome.started
        for offset in stride(from: 100, through: 1000, by: 100) where outcome != .full { outcome = stitcher.add(frame(at: offset)) }
        XCTAssertEqual(outcome, .full)
        XCTAssertEqual(stitcher.add(frame(at: 1100)), .full)
        XCTAssertGreaterThanOrEqual(stitcher.height, 700)
    }

    func testBlankRegionsAreNotGuessed() {
        let blank = PixelFrame(width: 100, height: 200, pixels: [UInt8](repeating: 255, count: 100 * 200 * 4))
        var shifted = blank.pixels
        for p in stride(from: 100 * 4 * 150, to: 100 * 4 * 151, by: 4) { shifted[p] = 0 }
        let stitcher = ScrollStitcher()
        stitcher.add(blank)
        XCTAssertNotEqual(stitcher.add(PixelFrame(width: 100, height: 200, pixels: shifted)), .appended(1))
    }

    func testMatchingIsFast() {
        let stitcher = ScrollStitcher()
        let big = Page(width: 1600, height: 6000, seed: 3)
        func bigFrame(_ offset: Int) -> PixelFrame { PixelFrame(width: 1600, height: 1400, pixels: big.rows(offset..<(offset + 1400))) }
        stitcher.add(bigFrame(0))
        let started = Date()
        XCTAssertEqual(stitcher.add(bigFrame(180)), .appended(180))
        let elapsed = Date().timeIntervalSince(started)
        print(String(format: "1600×1400 frame matched in %.1f ms", elapsed * 1000))
        XCTAssertLessThan(elapsed, 0.5)
    }
}
