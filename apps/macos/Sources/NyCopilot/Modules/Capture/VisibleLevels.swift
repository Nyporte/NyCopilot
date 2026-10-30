import AppKit

/// A display's frozen pixels in grey, for telling which outlines match something you can see.
final class GreyPixels: @unchecked Sendable {
    let width: Int
    let height: Int
    /// Pixels per point.
    let scale: CGFloat
    /// The display's top-left corner, in global top-left points.
    let origin: CGPoint
    private let pixels: [UInt8]

    init?(_ image: CGImage, scale: CGFloat, origin: CGPoint) {
        width = image.width
        height = image.height
        self.scale = scale
        self.origin = origin
        var pixels = [UInt8](repeating: 0, count: image.width * image.height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                          bytesPerRow: image.width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard drawn else { return nil }
        self.pixels = pixels
    }

    /// Global points → this display's pixel grid (rows top-down).
    func pixel(x: CGFloat) -> Int { Int(((x - origin.x) * scale).rounded()) }
    func pixel(y: CGFloat) -> Int { Int(((y - origin.y) * scale).rounded()) }
    func point(x: Int) -> CGFloat { CGFloat(x) / scale + origin.x }
    func point(y: Int) -> CGFloat { CGFloat(y) / scale + origin.y }

    /// Average brightness jump between pixel rows `y - 1` and `y`, over columns `from..<to`.
    func rowJump(_ y: Int, from: Int, to: Int) -> Double {
        let from = max(from, 0), to = min(to, width)
        guard y >= 1, y < height, to > from else { return 0 }
        let step = max(1, (to - from) / 400)
        var sum = 0, count = 0
        for x in stride(from: from, to: to, by: step) {
            sum += abs(Int(pixels[y * width + x]) - Int(pixels[(y - 1) * width + x]))
            count += 1
        }
        return Double(sum) / Double(count)
    }

    /// Average brightness jump between pixel columns `x - 1` and `x`, over rows `from..<to`.
    func columnJump(_ x: Int, from: Int, to: Int) -> Double {
        let from = max(from, 0), to = min(to, height)
        guard x >= 1, x < width, to > from else { return 0 }
        let step = max(1, (to - from) / 400)
        var sum = 0, count = 0
        for y in stride(from: from, to: to, by: step) {
            sum += abs(Int(pixels[y * width + x]) - Int(pixels[y * width + x - 1]))
            count += 1
        }
        return Double(sum) / Double(count)
    }
}

/// What an app's accessibility layers look like to the eye. An app nests its interface in many
/// layers, most of them invisible groups a few points apart; people screenshot what they see. So
/// each layer is checked against the frozen pixels: its sides are snapped to the edges actually
/// drawn nearby, and it counts only if it's visibly a box (or the kind of thing people capture).
enum VisibleLevels {
    /// Kinds of element worth a level of their own even without visible edges.
    static let meaningfulRoles: Set<String> = [
        kAXImageRole, kAXListRole, kAXTableRole, kAXOutlineRole, kAXBrowserRole, kAXScrollAreaRole, kAXTextAreaRole,
        kAXSheetRole, kAXDrawerRole, kAXMenuRole, kAXToolbarRole, kAXTabGroupRole, "AXWebArea", "AXPopover"
    ]

    /// How far a side may move to meet a drawn edge, in points.
    static let reach: CGFloat = 6
    /// A brightness jump (0–255, averaged along a side) that counts as a drawn edge.
    static let visibleJump = 7.0

    /// The rectangle with each side moved (independently, up to `reach`) onto the strongest drawn edge
    /// near it, and how many of its sides are visible edges — a side along the window's own edge counts.
    static func snapped(_ rect: CGRect, in pixels: GreyPixels, window: CGRect) -> (CGRect, Int) {
        let reach = Int((Self.reach * pixels.scale).rounded())
        let left = pixels.pixel(x: rect.minX), right = pixels.pixel(x: rect.maxX)
        let top = pixels.pixel(y: rect.minY), bottom = pixels.pixel(y: rect.maxY)
        // Measured along the middle of each side, away from rounded corners.
        let insetX = (right - left) / 10, insetY = (bottom - top) / 10
        /// `outward` is the direction away from the inside (−1 for top and left, +1 for bottom and
        /// right). Offsets are tried from the outermost in, so of a border's two equal edges the
        /// outer one wins and the border is part of the capture.
        func best(_ start: Int, outward: Int, _ jump: (Int) -> Double) -> (Int, Double) {
            let here = jump(start)
            var found = (start, here)
            for offset in stride(from: reach * outward, through: -reach * outward, by: -outward) where offset != 0 {
                let value = jump(start + offset)
                if value > found.1 { found = (start + offset, value) }
            }
            // Moved only for a clearly stronger edge.
            return found.1 >= max(here * 1.2, Self.visibleJump) ? found : (start, here)
        }
        let (newTop, topJump) = best(top, outward: -1) { pixels.rowJump($0, from: left + insetX, to: right - insetX) }
        let (newBottom, bottomJump) = best(bottom, outward: 1) { pixels.rowJump($0, from: left + insetX, to: right - insetX) }
        let (newLeft, leftJump) = best(left, outward: -1) { pixels.columnJump($0, from: top + insetY, to: bottom - insetY) }
        let (newRight, rightJump) = best(right, outward: 1) { pixels.columnJump($0, from: top + insetY, to: bottom - insetY) }
        let snapped = CGRect(x: pixels.point(x: newLeft), y: pixels.point(y: newTop),
                             width: pixels.point(x: newRight) - pixels.point(x: newLeft),
                             height: pixels.point(y: newBottom) - pixels.point(y: newTop))
        guard snapped.width >= 8, snapped.height >= 8 else { return (rect, 0) }
        let along: [Bool] = [abs(snapped.minY - window.minY) <= 2, abs(snapped.maxY - window.maxY) <= 2,
                             abs(snapped.minX - window.minX) <= 2, abs(snapped.maxX - window.maxX) <= 2]
        let sides = zip([topJump, bottomJump, leftJump, rightJump], along).filter { $0 >= visibleJump || $1 }.count
        return (snapped, sides)
    }

    /// Within 8 points on every side, or nearly the same area mostly overlapping: one level to the eye.
    static func resembles(_ a: CGRect, _ b: CGRect) -> Bool {
        if abs(a.minX - b.minX) <= 8, abs(a.minY - b.minY) <= 8, abs(a.maxX - b.maxX) <= 8, abs(a.maxY - b.maxY) <= 8 { return true }
        let overlap = a.intersection(b)
        guard !overlap.isNull else { return false }
        let areaA = a.width * a.height, areaB = b.width * b.height, shared = overlap.width * overlap.height
        return max(areaA, areaB) / max(min(areaA, areaB), 1) < 1.2 && shared / max(areaA, areaB) > 0.85
    }
}
