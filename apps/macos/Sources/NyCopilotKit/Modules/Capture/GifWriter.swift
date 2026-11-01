import CoreGraphics
import Foundation

/// Writes an animated GIF one frame at a time, straight to disk, so a long recording never holds
/// more than two frames in memory (ImageIO's GIF writer keeps every frame until the end, gigabytes
/// for a minute of screen). Each frame stores only the rectangle that changed since the one before,
/// with its own palette, and inside it the pixels that stayed the same are transparent: two small
/// changes far apart (a pointer and a clock) make a large rectangle, but long transparent runs cost
/// almost nothing. A pixel that stayed the same is drawn again anyway when what's shown is off by
/// more than a little, so a color a frame's palette had to approximate doesn't stay wrong for good.
/// Screens change in small places, so files stay small and frames are quick to encode. A frame's
/// delay is known once the next one arrives, so each is written then.
final class GifWriter {
    let width: Int
    let height: Int
    private let handle: FileHandle
    /// Frames are drawn here; it owns the pixel memory (RGBA, red in the low byte).
    private let context: CGContext
    private let pixels: UnsafeMutableBufferPointer<UInt32>
    /// The last frame, to find what changed.
    private var previous: [UInt32]
    /// What a viewer sees: each pixel as its palette last drew it.
    private var shown: [UInt32]
    private var hasPrevious = false
    /// The latest frame, encoded but not yet written: its graphic control block needs its delay.
    private var pending: (image: Data, time: Double, transparent: Bool)?
    private var lzw = LZW()
    private(set) var frameCount = 0

    init?(url: URL, width: Int, height: Int) {
        guard width > 0, height > 0, width < 65536, height < 65536,
              FileManager.default.createFile(atPath: url.path, contents: nil), let handle = try? FileHandle(forWritingTo: url),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let data = context.data else { return nil }
        self.width = width
        self.height = height
        self.handle = handle
        self.context = context
        pixels = UnsafeMutableBufferPointer(start: data.bindMemory(to: UInt32.self, capacity: width * height), count: width * height)
        previous = [UInt32](repeating: 0, count: width * height)
        shown = previous
        var header = Data("GIF89a".utf8)
        header.append(le16(width))
        header.append(le16(height))
        header.append(contentsOf: [0x70, 0, 0]) // no global color table, 8-bit color resolution
        // Loop forever (NETSCAPE2.0 extension).
        header.append(contentsOf: [0x21, 0xFF, 0x0B] + Array("NETSCAPE2.0".utf8) + [0x03, 0x01, 0x00, 0x00, 0x00])
        handle.write(header)
    }

    /// Adds a frame shown from `time` (seconds); a frame with nothing changed only extends the last.
    func add(_ image: CGImage, at time: Double) {
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let changed = changedRect() else { return }
        let block = encode(changed, overPrevious: hasPrevious)
        flushPending(until: time)
        pending = (block, time, hasPrevious)
        _ = previous.withUnsafeMutableBufferPointer { $0.update(fromContentsOf: pixels) }
        hasPrevious = true
        frameCount += 1
    }

    /// Writes the last frame, shown until `time`, and the trailer.
    @discardableResult
    func finish(at time: Double) -> Bool {
        flushPending(until: time)
        handle.write(Data([0x3B]))
        try? handle.close()
        return frameCount > 0
    }

    // MARK: Frames

    /// The bounding box of pixels that differ from the last frame; the whole frame at first.
    private func changedRect() -> (x: Int, y: Int, width: Int, height: Int)? {
        guard hasPrevious else { return (0, 0, width, height) }
        var minX = width, minY = height, maxX = -1, maxY = -1
        previous.withUnsafeBufferPointer { before in
            for y in 0..<height {
                let row = y * width
                var x = 0
                while x < width, pixels[row + x] == before[row + x] { x += 1 }
                guard x < width else { continue }
                var last = width - 1
                while last > x, pixels[row + last] == before[row + last] { last -= 1 }
                minX = min(minX, x); maxX = max(maxX, last)
                minY = min(minY, y); maxY = y
            }
        }
        guard maxX >= 0 else { return nil }
        return (minX, minY, maxX - minX + 1, maxY - minY + 1)
    }

    /// Writes the waiting frame with its delay now that it's known.
    private func flushPending(until time: Double) {
        guard let pending else { return }
        // Hundredths of a second; viewers stretch anything under 0.02 s.
        let delay = max(2, min(65535, Int(((time - pending.time) * 100).rounded())))
        // Disposal: leave in place, so the next frame draws over it; then whether it has a transparent index.
        var control = Data([0x21, 0xF9, 0x04, pending.transparent ? 0x05 : 0x04])
        control.append(le16(delay))
        control.append(contentsOf: [pending.transparent ? Palette.transparent : 0, 0])
        handle.write(control)
        handle.write(pending.image)
        self.pending = nil
    }

    /// An image descriptor, local palette, and LZW data for one rectangle of the frame. Drawn over
    /// the previous frame, its unchanged pixels are left transparent and kept out of the palette.
    private func encode(_ rect: (x: Int, y: Int, width: Int, height: Int), overPrevious: Bool) -> Data {
        // Which of the rectangle's pixels are drawn, row by row: those that changed, and those shown
        // too far from what they are; all of them on the first frame.
        var drawn = [Bool](repeating: true, count: rect.width * rect.height)
        if overPrevious {
            previous.withUnsafeBufferPointer { before in
                for y in 0..<rect.height {
                    let source = (rect.y + y) * width + rect.x, target = y * rect.width
                    for x in 0..<rect.width {
                        let pixel = pixels[source + x]
                        drawn[target + x] = pixel != before[source + x] || Self.isFar(shown[source + x], from: pixel)
                    }
                }
            }
        }
        var palette = Palette(pixels: UnsafeBufferPointer(pixels), width: width, rect: rect, drawn: drawn, reservingTransparent: overPrevious)
        var indices = [UInt8](repeating: Palette.transparent, count: rect.width * rect.height)
        for y in 0..<rect.height {
            let source = (rect.y + y) * width + rect.x, target = y * rect.width
            for x in 0..<rect.width where drawn[target + x] {
                let index = palette.index(of: pixels[source + x])
                indices[target + x] = index
                shown[source + x] = palette.color(at: index)
            }
        }
        var block = Data([0x2C])
        block.append(le16(rect.x)); block.append(le16(rect.y))
        block.append(le16(rect.width)); block.append(le16(rect.height))
        block.append(0x87) // local color table, 256 entries
        block.append(palette.table)
        block.append(8) // LZW minimum code size
        block.append(lzw.encode(indices))
        return block
    }

    /// Whether a shown color is off by more than a palette's usual rounding, in any channel.
    private static func isFar(_ shown: UInt32, from pixel: UInt32) -> Bool {
        abs(Int(shown & 0xFF) - Int(pixel & 0xFF)) > 10 || abs(Int((shown >> 8) & 0xFF) - Int((pixel >> 8) & 0xFF)) > 10
            || abs(Int((shown >> 16) & 0xFF) - Int((pixel >> 16) & 0xFF)) > 10
    }
}

private func le16(_ value: Int) -> Data { Data([UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)]) }

/// Up to 256 colors for one rectangle, by median cut on a sample of its pixels; each pixel then maps
/// to the nearest, cached by 15-bit color so a frame costs a few thousand searches at most.
private struct Palette {
    /// The index left out of the colors when a frame has transparent pixels.
    static let transparent: UInt8 = 255
    private(set) var table = Data(count: 768)
    private var colors: [(r: Int, g: Int, b: Int)] = []
    private var cache: [Int16]

    /// Colors for the `drawn` pixels of the rectangle (row by row within it); with
    /// `reservingTransparent`, at most 255 of them, so the last index stays free.
    init(pixels: UnsafeBufferPointer<UInt32>, width: Int, rect: (x: Int, y: Int, width: Int, height: Int),
         drawn: [Bool], reservingTransparent: Bool) {
        cache = [Int16](repeating: -1, count: 32768)
        // At most ~40,000 samples, every so many of the drawn pixels: a few small changes in a large
        // rectangle are all sampled.
        let count = drawn.reduce(0) { $1 ? $0 + 1 : $0 }
        let step = max(1, count / 40_000)
        var samples: [(Int, Int, Int)] = []
        samples.reserveCapacity(count / step + 1)
        var seen = 0
        for y in 0..<rect.height {
            for x in 0..<rect.width where drawn[y * rect.width + x] {
                defer { seen += 1 }
                guard seen % step == 0 else { continue }
                let pixel = pixels[(rect.y + y) * width + rect.x + x]
                samples.append((Int(pixel & 0xFF), Int((pixel >> 8) & 0xFF), Int((pixel >> 16) & 0xFF)))
            }
        }
        colors = Self.medianCut(samples, into: reservingTransparent ? 255 : 256)
        for (index, color) in colors.enumerated() {
            table[index * 3] = UInt8(color.r); table[index * 3 + 1] = UInt8(color.g); table[index * 3 + 2] = UInt8(color.b)
        }
    }

    /// The color at `index`, packed like a pixel.
    func color(at index: UInt8) -> UInt32 {
        let color = colors[Int(index)]
        return UInt32(color.r) | UInt32(color.g) << 8 | UInt32(color.b) << 16 | 0xFF00_0000
    }

    /// Pixels are RGBA in memory: red in the low byte on little-endian Macs.
    mutating func index(of pixel: UInt32) -> UInt8 {
        let r = Int(pixel & 0xFF), g = Int((pixel >> 8) & 0xFF), b = Int((pixel >> 16) & 0xFF)
        let key = (r >> 3) << 10 | (g >> 3) << 5 | (b >> 3)
        if cache[key] >= 0 { return UInt8(cache[key]) }
        var best = 0, bestDistance = Int.max
        for (index, color) in colors.enumerated() {
            let dr = color.r - r, dg = color.g - g, db = color.b - b
            let distance = 2 * dr * dr + 4 * dg * dg + 3 * db * db
            if distance < bestDistance { bestDistance = distance; best = index; if distance == 0 { break } }
        }
        cache[key] = Int16(best)
        return UInt8(best)
    }

    /// Splits the box with the widest channel at its median until there are `target` boxes (or no
    /// box can split), each standing for its average color.
    private static func medianCut(_ samples: [(Int, Int, Int)], into target: Int) -> [(r: Int, g: Int, b: Int)] {
        guard !samples.isEmpty else { return [(0, 0, 0)] }
        var boxes: [[(Int, Int, Int)]] = [samples]
        func spread(_ box: [(Int, Int, Int)]) -> (channel: Int, range: Int) {
            var low = (255, 255, 255), high = (0, 0, 0)
            for (r, g, b) in box {
                low = (min(low.0, r), min(low.1, g), min(low.2, b))
                high = (max(high.0, r), max(high.1, g), max(high.2, b))
            }
            let ranges = [high.0 - low.0, high.1 - low.1, high.2 - low.2]
            let channel = ranges.indices.max { ranges[$0] < ranges[$1] } ?? 0
            return (channel, ranges[channel])
        }
        while boxes.count < target {
            // The box with the most color spread, weighted by how many pixels it holds.
            var pick = -1, score = 0
            var pickChannel = 0
            for (index, box) in boxes.enumerated() where box.count > 1 {
                let (channel, range) = spread(box)
                let value = range * Int(Double(box.count).squareRoot())
                if range > 0, value > score { score = value; pick = index; pickChannel = channel }
            }
            guard pick >= 0 else { break }
            let box = boxes[pick].sorted { a, b in
                switch pickChannel {
                case 0: a.0 < b.0
                case 1: a.1 < b.1
                default: a.2 < b.2
                }
            }
            let middle = box.count / 2
            boxes[pick] = Array(box[..<middle])
            boxes.append(Array(box[middle...]))
        }
        return boxes.map { box in
            var r = 0, g = 0, b = 0
            for sample in box { r += sample.0; g += sample.1; b += sample.2 }
            return (r / box.count, g / box.count, b / box.count)
        }
    }
}

/// GIF's variable-width LZW, 8-bit symbols, packed into 255-byte sub-blocks. Its tables are kept
/// between frames and reset by generation, rather than reallocated.
private struct LZW {
    /// Prefix code × 256 + byte → code, valid where `stamp` holds the current generation.
    private var table = [Int32](repeating: 0, count: 4096 * 256)
    private var stamp = [UInt16](repeating: 0, count: 4096 * 256)
    private var generation: UInt16 = 0

    mutating func encode(_ input: [UInt8]) -> Data {
        let clear = 256, end = 257
        var output = Data()
        var block = [UInt8]()
        block.reserveCapacity(255)
        var bitBuffer = 0, bitCount = 0
        var codeSize = 9, nextCode = 258
        func nextGeneration() {
            generation &+= 1
            if generation == 0 { stamp = [UInt16](repeating: 0, count: 4096 * 256); generation = 1 }
        }
        nextGeneration()

        func flushBlock() {
            guard !block.isEmpty else { return }
            output.append(UInt8(block.count))
            output.append(contentsOf: block)
            block.removeAll(keepingCapacity: true)
        }
        func emit(_ code: Int) {
            bitBuffer |= code << bitCount
            bitCount += codeSize
            while bitCount >= 8 {
                block.append(UInt8(bitBuffer & 0xFF))
                if block.count == 255 { flushBlock() }
                bitBuffer >>= 8
                bitCount -= 8
            }
        }

        emit(clear)
        guard var prefix = input.first.map(Int.init) else {
            emit(end)
            if bitCount > 0 { block.append(UInt8(bitBuffer & 0xFF)) }
            flushBlock()
            output.append(0)
            return output
        }
        for byte in input.dropFirst() {
            let key = prefix << 8 | Int(byte)
            if stamp[key] == generation {
                prefix = Int(table[key])
                continue
            }
            emit(prefix)
            if nextCode < 4096 {
                table[key] = Int32(nextCode)
                stamp[key] = generation
                nextCode += 1
                if nextCode > (1 << codeSize), codeSize < 12 { codeSize += 1 }
            } else {
                emit(clear)
                codeSize = 9
                nextCode = 258
                nextGeneration()
            }
            prefix = Int(byte)
        }
        emit(prefix)
        emit(end)
        if bitCount > 0 { block.append(UInt8(bitBuffer & 0xFF)) }
        flushBlock()
        output.append(0)
        return output
    }
}
