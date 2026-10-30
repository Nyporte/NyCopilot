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

/// Builds one tall image of a selection from frames of a larger area around it while its content is
/// scrolled, either way.
///
/// The frames cover the whole scrollable area; the selection is a band of rows within them. Tracking
/// uses the whole frame: each frame is located against the last one by matching a band of rows, which
/// gives the scroll position to the pixel. The image is kept in document coordinates, so rows that
/// pass through the selection are added at whichever end they extend — even rows that went by too
/// fast to cross the selection in a frame, since they are still visible elsewhere in the area. Rows
/// that stay put at the top and bottom of the area (toolbars, sticky headers, status bars) are found
/// on the first scroll; where the selection includes them they appear once, above and below the
/// scrolled content. Matching works on per-row luminance signatures, a few milliseconds per frame.
public final class ScrollStitcher {
    public enum Outcome: Equatable {
        /// The first frame.
        case started
        /// The image grew by this many rows, at the top or the bottom.
        case added(Int)
        /// It scrolled over content already in the image.
        case covered
        /// Nothing scrolled.
        case unchanged
        /// Rows went by that no frame showed, or the frame couldn't be placed at all. Scrolling back a
        /// little fills the gap; nothing is lost.
        case lost
        /// The image reached `maxHeight`; later frames are ignored.
        case full
    }

    public let maxHeight: Int
    /// The rows of each frame the user selected; the rest of the frame only helps tracking.
    public let selection: Range<Int>
    public private(set) var width = 0
    /// Rows in the finished image so far.
    public var height: Int { rowBytes == 0 ? 0 : (header.count + above.count + below.count + footer.count) / rowBytes }

    private var rowBytes: Int { width * 4 }
    /// Selected rows inside the fixed bands, from the frames that last extended the top and the
    /// bottom: blank rows beside a real toolbar can pass for fixed ones, and this way they always
    /// join the content around them.
    private var header: [UInt8] = []
    private var footer: [UInt8] = []
    /// Scrolled content from the first frame down, and above it (nearest row first, so growing upward
    /// is an append too).
    private var below: [UInt8] = []
    private var above: [UInt8] = []
    /// The document rows the scrolled content covers, and where the latest frame's first row sits.
    private var top = 0, bottom = 0, position = 0
    private var previous: Signatures?
    private var frameHeight = 0
    private var fixed: (top: Int, bottom: Int)?
    private var isFull = false

    public init(selection: Range<Int>, maxHeight: Int = 30_000) {
        self.selection = selection
        self.maxHeight = maxHeight
    }

    @discardableResult
    public func add(_ frame: PixelFrame) -> Outcome {
        if isFull { return .full }
        let signatures = Signatures(frame)
        guard let old = previous else {
            precondition(selection.lowerBound >= 0 && selection.upperBound <= frame.height && !selection.isEmpty, "selection outside the frame")
            width = frame.width
            frameHeight = frame.height
            below = rows(frame, selection)
            (top, bottom) = (selection.lowerBound, selection.upperBound)
            previous = signatures
            return .started
        }
        guard frame.width == width, frame.height == frameHeight else { return .lost }
        let bands = fixed ?? Self.fixedBands(old, signatures)
        let band = bands.top..<(frame.height - bands.bottom)
        guard band.count >= 24 else { return .lost }

        // Most of the area unchanged in place: no scroll (a blinking caret or a hover doesn't count).
        if Self.meanDifference(old, signatures, offset: 0, rows: band) <= 3 { return .unchanged }
        let offset: Int
        if let down = Self.offset(from: old, to: signatures, band: band) {
            offset = down
        } else if let up = Self.offset(from: signatures, to: old, band: band) {
            offset = -up
        } else {
            return .lost
        }
        if fixed == nil { settle(bands) }
        position += offset
        previous = signatures

        let moving = max(selection.lowerBound, band.lowerBound)..<min(selection.upperBound, band.upperBound)
        guard !moving.isEmpty else { return .covered }

        var added = 0, gap = false
        // Scrolled down: rows past the bottom, read from wherever they are in this frame.
        if position + moving.upperBound > bottom {
            let from = bottom - position
            if from >= band.lowerBound {
                below += rows(frame, from..<moving.upperBound)
                added += moving.upperBound - from
                bottom = position + moving.upperBound
                footer = rows(frame, moving.upperBound..<selection.upperBound)
            } else {
                gap = true
            }
        }
        // Scrolled up: rows past the top, nearest first.
        if position + moving.lowerBound < top {
            let to = top - position
            if to <= band.upperBound {
                for row in stride(from: to - 1, through: moving.lowerBound, by: -1) { above += rows(frame, row..<(row + 1)) }
                added += to - moving.lowerBound
                top = position + moving.lowerBound
                header = rows(frame, selection.lowerBound..<moving.lowerBound)
            } else {
                gap = true
            }
        }
        if height >= maxHeight {
            isFull = true
            return .full
        }
        return added > 0 ? .added(added) : gap ? .lost : .covered
    }

    /// The first scroll shows which rows stay put; any the selection included leave the scrolled
    /// content and become the header and footer.
    private func settle(_ bands: (top: Int, bottom: Int)) {
        fixed = bands
        let moving = max(selection.lowerBound, bands.top)..<max(max(selection.lowerBound, bands.top), min(selection.upperBound, frameHeight - bands.bottom))
        let start = (moving.lowerBound - selection.lowerBound) * rowBytes, end = start + moving.count * rowBytes
        header = Array(below[..<start])
        footer = Array(below[end...])
        below = Array(below[start..<end])
        (top, bottom) = (moving.lowerBound, moving.upperBound)
        resetThumbnail()
    }

    private func rows(_ frame: PixelFrame, _ range: Range<Int>) -> [UInt8] {
        Array(frame.pixels[(range.lowerBound * rowBytes)..<(range.upperBound * rowBytes)])
    }

    /// The image so far: header, scrolled content top to bottom, footer.
    public func makeImage() -> CGImage? {
        Self.image(width: width, pixels: header + Self.reversedRows(above, rowBytes: rowBytes) + below + footer)
    }

    // MARK: Thumbnail

    /// Previews fit the whole image in a narrow panel; this much is plenty.
    private static let thumbnailWidth = 360, thumbnailHeight = 1600
    private var thumbnailFactor = 0
    private var thumbnailBelow: [UInt8] = [], thumbnailAbove: [UInt8] = []
    /// Rows already scaled into the thumbnails, multiples of the factor.
    private var scaledBelow = 0, scaledAbove = 0

    private func resetThumbnail() {
        thumbnailBelow = []; thumbnailAbove = []
        scaledBelow = 0; scaledAbove = 0
    }

    /// The whole image, small. Each call scales down only rows that arrived since the last; when the
    /// image outgrows the thumbnail, the scale halves once and starts over, so a preview stays cheap
    /// however long the image gets.
    public func makeThumbnail() -> CGImage? {
        guard width > 0 else { return nil }
        var factor = max(1, thumbnailFactor, width / Self.thumbnailWidth)
        while height / factor > Self.thumbnailHeight { factor *= 2 }
        if factor != thumbnailFactor {
            thumbnailFactor = factor
            resetThumbnail()
        }
        let bytes = rowBytes
        func extend(_ thumbnail: inout [UInt8], _ scaled: inout Int, from source: [UInt8]) -> [UInt8] {
            let complete = source.count / bytes / factor * factor
            if complete > scaled {
                thumbnail += Self.scaledDown(Array(source[(scaled * bytes)..<(complete * bytes)]), width: width, by: factor)
                scaled = complete
            }
            return Self.scaledDown(Array(source[(complete * bytes)...]), width: width, by: factor)
        }
        let restBelow = extend(&thumbnailBelow, &scaledBelow, from: below)
        let restAbove = extend(&thumbnailAbove, &scaledAbove, from: above)
        let small = width / factor * 4
        let pixels = Self.scaledDown(header, width: width, by: factor) + Self.reversedRows(thumbnailAbove + restAbove, rowBytes: small)
            + thumbnailBelow + restBelow + Self.scaledDown(footer, width: width, by: factor)
        return Self.image(width: width / factor, pixels: pixels)
    }

    static func reversedRows(_ pixels: [UInt8], rowBytes: Int) -> [UInt8] {
        guard rowBytes > 0, pixels.count > rowBytes else { return pixels }
        var out = [UInt8](); out.reserveCapacity(pixels.count)
        for start in stride(from: pixels.count - rowBytes, through: 0, by: -rowBytes) { out += pixels[start..<(start + rowBytes)] }
        return out
    }

    /// Averages `factor` × `factor` blocks; a last, shorter run of rows averages what it has.
    static func scaledDown(_ pixels: [UInt8], width: Int, by factor: Int) -> [UInt8] {
        let rows = pixels.count / (width * 4), outWidth = width / factor
        guard factor > 1 else { return pixels }
        guard rows > 0, outWidth > 0 else { return [] }
        let outRows = (rows + factor - 1) / factor
        var out = [UInt8](repeating: 0, count: outRows * outWidth * 4)
        pixels.withUnsafeBufferPointer { source in
            out.withUnsafeMutableBufferPointer { target in
                for outY in 0..<outRows {
                    let firstRow = outY * factor, lastRow = min(firstRow + factor, rows)
                    for outX in 0..<outWidth {
                        var b = 0, g = 0, r = 0, a = 0
                        for y in firstRow..<lastRow {
                            var p = (y * width + outX * factor) * 4
                            for _ in 0..<factor {
                                b &+= Int(source[p]); g &+= Int(source[p + 1]); r &+= Int(source[p + 2]); a &+= Int(source[p + 3])
                                p += 4
                            }
                        }
                        let count = (lastRow - firstRow) * factor, q = (outY * outWidth + outX) * 4
                        target[q] = UInt8(b / count); target[q + 1] = UInt8(g / count)
                        target[q + 2] = UInt8(r / count); target[q + 3] = UInt8(a / count)
                    }
                }
            }
        }
        return out
    }

    // MARK: Matching

    /// Rows identical in place at the top and bottom of two frames. The area can include a window's
    /// toolbar and status bar, so each band may take up to nearly half of it.
    static func fixedBands(_ old: Signatures, _ new: Signatures) -> (top: Int, bottom: Int) {
        let limit = old.rows * 9 / 20
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
