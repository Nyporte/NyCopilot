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
/// uses the whole frame: each frame is placed against the last one to the pixel. The image is kept in
/// document coordinates, so rows that pass through the selection are added at whichever end they
/// extend — even rows that went by too fast to cross the selection in a frame, since they are still
/// visible elsewhere in the area.
///
/// A real area holds more than the scrolling content: toolbars and composers that stay put, a blinking
/// caret, a hover highlight under the pointer, animations, headers that slide in. So nothing is
/// decided by an average. A placement is the offset most textured rows agree on; rows are compared
/// ignoring their two most different column groups, so a narrow scrollbar or badge doesn't spoil a
/// row; and rows are judged fixed only on evidence gathered over many frames (textured, still, and
/// not following the scroll). Where the selection includes fixed rows they appear once, above and
/// below the scrolled content. Matching works on per-row luminance signatures, a few milliseconds per frame.
public final class ScrollStitcher {
    public enum Outcome: Equatable, Sendable {
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
    /// Per row: positive when it has stayed put while the content scrolled, negative when it moved with it.
    private var evidence: [Int] = []
    /// Fixed rows as the image is laid out: settled on the first scroll, so the selection's split into
    /// header, content, and footer never shifts.
    private var fixed: (top: Int, bottom: Int)?
    private var lastOffset = 0
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
            evidence = [Int](repeating: 0, count: frame.height)
            below = rows(frame, selection)
            (top, bottom) = (selection.lowerBound, selection.upperBound)
            previous = signatures
            return .started
        }
        guard frame.width == width, frame.height == frameHeight else { return .lost }
        let tracked = movingBand()
        guard tracked.count >= 24 else { return .lost }
        // Nearly every textured row where it was: nothing scrolled (a caret or an animation doesn't count).
        if Self.isStill(old, signatures, band: tracked) { return .unchanged }
        // "Nothing moved" competes with every scroll on equal terms: an animation, a caret, or a hover
        // wins only the rows it covers, a real scroll wins the content.
        let still = Self.share(old, signatures, offset: 0, band: tracked)
        guard let offset = Self.displacement(from: old, to: signatures, band: tracked, hint: lastOffset),
              Self.share(old, signatures, offset: offset, band: tracked) > still else {
            return still >= 0.5 ? .unchanged : .lost
        }
        learn(from: old, to: signatures, offset: offset)
        if fixed == nil {
            let band = movingBand()
            settle((band.lowerBound, frame.height - band.upperBound))
        }
        position += offset
        lastOffset = offset
        previous = signatures

        // Rows are read only where content scrolls; the selection splits where the image's layout says.
        let band = movingBand(), layout = fixed!
        let moving = max(selection.lowerBound, layout.top, band.lowerBound)..<min(selection.upperBound, frame.height - layout.bottom, band.upperBound)
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

    /// Rows match when they differ by at most this much per column group, on average.
    static let tolerance = 4

    /// The rows that scroll: between the runs at the top and bottom that hold rows seen staying put.
    /// A run takes in blank rows, which can never show whether they move — reading a fixed blank row as
    /// content would put it in the image, while keeping a blank content row out only narrows the band a
    /// little — and stops at a textured row seen moving or not yet seen either way.
    private func movingBand() -> Range<Int> {
        let limit = frameHeight * 9 / 20, textured = previous?.textured ?? []
        func run(_ rows: [Int]) -> Int {
            var length = 0, fixed = false
            for (index, y) in rows.enumerated() {
                if evidence[y] > 0 { fixed = true } else if evidence[y] < 0 || textured[y] { break }
                if fixed { length = index + 1 }
            }
            return length
        }
        let top = run(Array(0..<limit)), bottom = run((0..<limit).map { frameHeight - 1 - $0 })
        return top..<(frameHeight - bottom)
    }

    /// After a scroll by `offset`: textured rows still where they were but not where the scroll would
    /// put them stayed put; those that followed the scroll moved.
    private func learn(from old: Signatures, to new: Signatures, offset: Int) {
        for y in 0..<frameHeight where new.textured[y] {
            let still = new.matches(y, old, y)
            let followed = (0..<frameHeight).contains(y + offset) && new.matches(y, old, y + offset)
            if still != followed { evidence[y] = max(-4, min(4, evidence[y] + (still ? 1 : -1))) }
        }
    }

    /// How many textured rows agree with content having moved up by `offset`, out of those compared
    /// (every other row where both frames have it inside `band`).
    static func agreement(_ old: Signatures, _ new: Signatures, offset: Int, band: Range<Int>) -> (agreeing: Int, compared: Int) {
        let lower = max(band.lowerBound, band.lowerBound - offset), upper = min(band.upperBound, band.upperBound - offset)
        var agreeing = 0, compared = 0
        for y in stride(from: lower, to: upper, by: 2) where new.textured[y] || old.textured[y + offset] {
            compared += 1
            if new.matches(y, old, y + offset) { agreeing += 1 }
        }
        return (agreeing, compared)
    }

    /// The agreeing share, or 0 with too little to go on.
    static func share(_ old: Signatures, _ new: Signatures, offset: Int, band: Range<Int>) -> Double {
        let (agreeing, compared) = agreement(old, new, offset: offset, band: band)
        return agreeing >= 6 ? Double(agreeing) / Double(compared) : 0
    }

    /// How well a move fits the rows that changed — rows that stayed put (toolbars, blank bands) say
    /// nothing about how far content went, and would only add noise between neighbouring offsets.
    /// The cost caps each row, so an animation weighs the same at every offset and exact content wins.
    static func fit(_ old: Signatures, _ new: Signatures, offset: Int, band: Range<Int>) -> (agreeing: Int, share: Double, cost: Double) {
        let lower = max(band.lowerBound, band.lowerBound - offset), upper = min(band.upperBound, band.upperBound - offset)
        let match = tolerance * new.kept, cap = match * 3
        var agreeing = 0, compared = 0, cost = 0
        for y in stride(from: lower, to: upper, by: 2) where (new.textured[y] || old.textured[y + offset]) && !new.matches(y, old, y) {
            let difference = new.runDifference(from: y, old, from: y + offset, rows: 1, giveUpAbove: cap)
            compared += 1
            cost += min(difference, cap)
            if difference <= match { agreeing += 1 }
        }
        guard agreeing >= 6 else { return (0, 0, .infinity) }
        return (agreeing, Double(agreeing) / Double(compared), Double(cost) / Double(compared))
    }

    static func isStill(_ old: Signatures, _ new: Signatures, band: Range<Int>) -> Bool {
        let (agreeing, compared) = agreement(old, new, offset: 0, band: band)
        return compared == 0 || agreeing * 20 >= compared * 17
    }

    /// How far content moved up (negative: down) from `old` to `new`. Every offset either way is tried
    /// against a sample of rows that changed (they carry the evidence of a move, even when fixed bars
    /// fill much of the area); the few that most samples agree with, plus the last offset (scrolling is
    /// smooth), are then judged on all textured rows, and the one most of them agree with wins.
    static func displacement(from old: Signatures, to new: Signatures, band: Range<Int>, hint: Int) -> Int? {
        let changed = band.filter { new.textured[$0] && !new.matches($0, old, $0) }
        guard changed.count >= 6 else { return nil }
        let samples = stride(from: 0, to: changed.count, by: max(1, changed.count / 32)).map { changed[$0] }
        var scored: [(offset: Int, hits: Int)] = []
        let reach = band.count - 12
        for offset in -reach...reach where offset != 0 {
            var hits = 0, seen = 0
            for y in samples where band.contains(y + offset) {
                seen += 1
                if new.matches(y, old, y + offset) { hits += 1 }
            }
            if hits >= 4, hits * 10 >= seen * 3 { scored.append((offset, hits)) }
        }
        var candidates = Set(scored.sorted { $0.hits > $1.hits }.prefix(6).map(\.offset))
        if hint != 0 { candidates.insert(hint) }
        // Each candidate's neighbours too: a sample can land a row or two off.
        for offset in Array(candidates) { for step in -2...2 where step != 0 { candidates.insert(offset + step) } }
        candidates.remove(0)
        // Most changed rows agreeing wins: one row off, every line's edges disagree. Then the closer fit;
        // exact repeats (fit equally well) go to the smoother scroll.
        var best: (offset: Int, agreeing: Int, cost: Double)?
        for offset in candidates where abs(offset) <= reach {
            let (agreeing, share, cost) = fit(old, new, offset: offset, band: band)
            // Headers sliding in, hovers, and animations can be a good part of what changed; the real
            // safeguard is beating "nothing moved" across all rows, which the caller checks.
            guard share >= 0.3 else { continue }
            if let current = best {
                if agreeing < current.agreeing { continue }
                if agreeing == current.agreeing {
                    if cost > current.cost + 0.5 { continue }
                    if cost >= current.cost - 0.5, abs(offset - hint) >= abs(current.offset - hint) { continue }
                }
            }
            best = (offset, agreeing, cost)
        }
        return best?.offset
    }

    struct Signatures {
        static let groupCount = 48
        let rows: Int
        let groups: Int
        let values: [UInt8]
        /// Rows with contrast across them; blank rows match anything and prove nothing.
        let textured: [Bool]
        /// Groups counted in a comparison: the two most different are left out.
        var kept: Int { groups > 4 ? groups - 2 : groups }

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
            textured = (0..<frame.height).map { y in
                let row = values[(y * groups)..<((y + 1) * groups)]
                return Int(row.max() ?? 0) - Int(row.min() ?? 0) >= 12
            }
        }

        /// Whether row `a` here and row `b` of `other` show the same thing.
        func matches(_ a: Int, _ other: Signatures, _ b: Int) -> Bool {
            runDifference(from: a, other, from: b, rows: 1, giveUpAbove: .max) <= ScrollStitcher.tolerance * kept
        }

        /// Summed per-group differences over `rows` consecutive rows, each row leaving out its two most
        /// different groups; stops early once past `limit`.
        func runDifference(from a: Int, _ other: Signatures, from b: Int, rows: Int, giveUpAbove limit: Int) -> Int {
            let trims = groups > 4
            return values.withUnsafeBufferPointer { mine in
                other.values.withUnsafeBufferPointer { theirs in
                    var total = 0
                    for row in 0..<rows {
                        let x = (a + row) * groups, y = (b + row) * groups
                        var sum = 0, largest = 0, second = 0
                        for index in 0..<groups {
                            let d = abs(Int(mine[x + index]) &- Int(theirs[y + index]))
                            sum &+= d
                            if d > largest { second = largest; largest = d } else if d > second { second = d }
                        }
                        total &+= trims ? sum - largest - second : sum
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
