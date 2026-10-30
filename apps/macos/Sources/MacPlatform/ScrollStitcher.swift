import CoreGraphics
import Foundation

/// One captured frame: tightly packed 8-bit BGRA rows, top row first.
public struct PixelFrame {
    public let width: Int
    public let height: Int
    public let pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(pixels.count == width * height * 4, "BGRA pixels must be width × height × 4 bytes")
        self.width = width
        self.height = height
        self.pixels = pixels
    }
}

/// Builds one tall image from frames of a region whose content is scrolled downward.
///
/// Each frame is compared with the last one it accepted: a band of rows from the new frame is found
/// in the old one, which gives how far the content moved, and only the rows that came into view are
/// appended. Rows that stay put at the top and bottom — a toolbar, a sticky header, a status bar —
/// are recognized from the first scroll, kept once, and left out of matching. Matching works on
/// per-row luminance signatures, so a frame costs a few milliseconds even on a large region.
public final class ScrollStitcher {
    public enum Outcome: Equatable {
        /// The first frame.
        case started
        /// New content came into view: this many rows.
        case appended(Int)
        /// Nothing scrolled.
        case unchanged
        /// No overlap with the last accepted frame: scrolled up, or too far at once.
        case lost
        /// The image reached `maxHeight`; later frames are ignored.
        case full
    }

    public let maxHeight: Int
    public private(set) var width = 0
    /// Rows in the finished image so far.
    public var height: Int { width == 0 ? 0 : (body.count + footer.count) / (width * 4) }

    private var body: [UInt8] = []
    /// The fixed rows at the bottom, taken from the latest frame.
    private var footer: [UInt8] = []
    private var previous: (frame: PixelFrame, signatures: Signatures)?
    /// Fixed rows at the top and bottom, settled by the first scroll.
    private var fixed: (top: Int, bottom: Int)?
    private var isFull = false

    public init(maxHeight: Int = 30_000) {
        self.maxHeight = maxHeight
    }

    @discardableResult
    public func add(_ frame: PixelFrame) -> Outcome {
        if isFull { return .full }
        let signatures = Signatures(frame)
        guard let previous else {
            width = frame.width
            body = frame.pixels
            self.previous = (frame, signatures)
            return .started
        }
        guard frame.width == previous.frame.width, frame.height == previous.frame.height else { return .lost }
        let old = previous.signatures, height = frame.height
        let bands = fixed ?? Self.fixedBands(old, signatures)
        let band = bands.top..<(height - bands.bottom)
        guard band.count >= 24 else { return .lost }

        // Most of the band unchanged in place: no scroll (a blinking caret or a hover doesn't count).
        if Self.meanDifference(old, signatures, offset: 0, rows: band) <= 3 { return .unchanged }
        guard let offset = Self.offset(from: old, to: signatures, band: band) else { return .lost }

        // Rows that scrolled into view sit just above the fixed footer.
        let rowBytes = frame.width * 4
        if fixed == nil {
            // The first frame's footer was part of the body until now.
            body.removeLast(bands.bottom * rowBytes)
            fixed = bands
        }
        body.append(contentsOf: frame.pixels[((band.upperBound - offset) * rowBytes)..<(band.upperBound * rowBytes)])
        footer = Array(frame.pixels[(band.upperBound * rowBytes)...])
        self.previous = (frame, signatures)
        if self.height >= maxHeight {
            isFull = true
            return .full
        }
        return .appended(offset)
    }

    /// The image so far.
    public func makeImage() -> CGImage? { Self.image(width: width, pixels: body + footer) }

    /// The last `rows` rows, for a live preview that stays cheap however long the image gets.
    public func makeTail(rows: Int) -> CGImage? {
        let all = body + footer, rowBytes = width * 4
        guard rowBytes > 0 else { return nil }
        let start = max(0, all.count - rows * rowBytes)
        return Self.image(width: width, pixels: Array(all[start...]))
    }

    // MARK: Matching

    /// Rows identical in place at the top and bottom of two frames, up to a third of the height each.
    static func fixedBands(_ old: Signatures, _ new: Signatures) -> (top: Int, bottom: Int) {
        let limit = old.rows / 3
        let same = { (y: Int) in old.difference(y, new, y) <= old.groups }
        let top = (0..<limit).first { !same($0) } ?? limit
        let bottom = (0..<limit).first { !same(old.rows - 1 - $0) } ?? limit
        return (top, bottom)
    }

    /// Mean per-bucket difference between new rows and the old rows `offset` further down, sampling
    /// every other row.
    static func meanDifference(_ old: Signatures, _ new: Signatures, offset: Int, rows: Range<Int>) -> Double {
        let compared = rows.lowerBound..<(rows.upperBound - offset)
        guard !compared.isEmpty else { return .infinity }
        var total = 0, count = 0
        for y in stride(from: compared.lowerBound, to: compared.upperBound, by: 2) {
            total += old.difference(y + offset, new, y)
            count += 1
        }
        return Double(total) / Double(count * old.groups)
    }

    /// How many rows the content moved up: a textured run of rows near the top of the new band is
    /// looked up in the old band, then the whole overlap is checked.
    static func offset(from old: Signatures, to new: Signatures, band: Range<Int>) -> Int? {
        let length = min(64, max(12, band.count / 5))
        // The template must have texture; a run of blank rows would match anywhere.
        let starts = stride(from: band.lowerBound, through: band.lowerBound + band.count / 2, by: 4)
        guard let start = starts.first(where: { y in
            guard y + length < band.upperBound else { return false }
            let variation = (y..<(y + length - 1)).reduce(0) { $0 + new.difference($1, new, $1 + 1) }
            return variation > length * new.groups / 2
        }) else { return nil }

        var best: (position: Int, cost: Int)?
        for position in (start + 1)...(band.upperBound - length) {
            let cost = old.runDifference(from: position, new, from: start, rows: length, giveUpAbove: best?.cost ?? .max)
            if best == nil || cost < best!.cost { best = (position, cost) }
        }
        guard let best, Double(best.cost) / Double(length * new.groups) <= 4 else { return nil }
        let offset = best.position - start
        return meanDifference(old, new, offset: offset, rows: band) <= 6 ? offset : nil
    }

    /// Per row, the mean luminance of column groups: enough to tell lines of text apart, and cheap
    /// to compare. Stored flat, row after row.
    struct Signatures {
        static let groupCount = 48
        let rows: Int
        let groups: Int
        let values: [UInt8]

        init(_ frame: PixelFrame) {
            let groups = min(Self.groupCount, frame.width)
            var values = [UInt8](repeating: 0, count: frame.height * groups)
            frame.pixels.withUnsafeBufferPointer { pixels in
                values.withUnsafeMutableBufferPointer { out in
                    let rowBytes = frame.width * 4
                    for y in 0..<frame.height {
                        let row = y * rowBytes
                        for group in 0..<groups {
                            let start = group * frame.width / groups, end = (group + 1) * frame.width / groups
                            var sum = 0, count = 0
                            // Every other column is plenty for an average.
                            for x in stride(from: start, to: end, by: 2) {
                                let p = row + x * 4
                                // BGRA → luma (BT.601 weights out of 256).
                                sum += (Int(pixels[p + 2]) &* 77 &+ Int(pixels[p + 1]) &* 150 &+ Int(pixels[p]) &* 29) >> 8
                                count += 1
                            }
                            out[y * groups + group] = UInt8(sum / max(count, 1))
                        }
                    }
                }
            }
            self.rows = frame.height
            self.groups = groups
            self.values = values
        }

        /// Sum of per-group differences between row `a` here and row `b` of `other`.
        func difference(_ a: Int, _ other: Signatures, _ b: Int) -> Int {
            runDifference(from: a, other, from: b, rows: 1, giveUpAbove: .max)
        }

        /// The same over `rows` consecutive rows, stopping early once past `limit`.
        func runDifference(from a: Int, _ other: Signatures, from b: Int, rows: Int, giveUpAbove limit: Int) -> Int {
            values.withUnsafeBufferPointer { mine in
                other.values.withUnsafeBufferPointer { theirs in
                    var total = 0
                    for row in 0..<rows {
                        let x = (a + row) * groups, y = (b + row) * groups
                        for index in 0..<groups { total &+= abs(Int(mine[x + index]) &- Int(theirs[y + index])) }
                        if total >= limit { return total }
                    }
                    return total
                }
            }
        }
    }

    private static func image(width: Int, pixels: [UInt8]) -> CGImage? {
        guard width > 0, !pixels.isEmpty, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: pixels.count / (width * 4), bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue
                                                                | CGImageAlphaInfo.premultipliedFirst.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
