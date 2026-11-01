import AppKit
@testable import NyCopilotKit

/// Several scenes in one moving picture, stacked and playing at once: each recorded on its own by a
/// DemoDirector (with no output file), then laid out row by row with a caption in its top-left
/// corner. Scenes recorded with matching backdrops join into one desktop, a fine line between them.
/// A scene that ends early holds its last frame until the longest is done.
@MainActor
enum DemoReel {
    struct Row {
        let scene: DemoDirector
        let title: String
        let detail: String
    }

    static func make(_ rows: [Row], into url: URL, fps: Double = 30) -> Bool {
        guard let first = rows.first?.scene.frames.first?.image else { return false }
        let width = first.width, rowHeight = first.height
        let height = rowHeight * rows.count
        let scale = CGFloat(width) / rows[0].scene.crop.width
        guard let writer = GifWriter(url: url, width: width, height: height) else { return false }
        let length = rows.map(\.scene.duration).max() ?? 0
        var shown = [Int](repeating: 0, count: rows.count)
        var time = 0.0
        while time < length {
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            for (index, row) in rows.enumerated() {
                // The latest frame of this scene at this moment.
                let frames = row.scene.frames
                while shown[index] + 1 < frames.count, frames[shown[index] + 1].time <= time { shown[index] += 1 }
                let top = height - rowHeight * (index + 1)
                context.draw(frames[shown[index]].image, in: CGRect(x: 0, y: top, width: width, height: rowHeight))
                caption(row, in: context, top: CGFloat(top + rowHeight), scale: scale)
                if index > 0 {
                    context.setFillColor(NSColor.white.withAlphaComponent(0.22).cgColor)
                    context.fill(CGRect(x: 0, y: CGFloat(top + rowHeight) - scale / 2, width: CGFloat(width), height: max(1, scale)))
                }
            }
            if let image = context.makeImage() { writer.add(image, at: time) }
            time += 1 / fps
        }
        return writer.finish(at: length)
    }

    /// The scene's name and one line on it, white on the desktop, in the row's top-left corner.
    private static func caption(_ row: Row, in context: CGContext, top: CGFloat, scale: CGFloat) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
        shadow.shadowBlurRadius = 6 * scale
        shadow.shadowOffset = NSSize(width: 0, height: -1 * scale)
        let title = NSAttributedString(string: row.title, attributes: [
            .font: NSFont.systemFont(ofSize: 21 * scale, weight: .bold), .foregroundColor: NSColor.white, .shadow: shadow])
        let detail = NSAttributedString(string: row.detail, attributes: [
            .font: NSFont.systemFont(ofSize: 13 * scale, weight: .medium), .foregroundColor: NSColor.white.withAlphaComponent(0.8),
            .shadow: shadow, .paragraphStyle: { let style = NSMutableParagraphStyle(); style.lineSpacing = 2 * scale; return style }()])
        let titleSize = title.size()
        title.draw(at: NSPoint(x: 28 * scale, y: top - 22 * scale - titleSize.height))
        let box = NSRect(x: 28 * scale, y: top - 112 * scale, width: 236 * scale, height: 62 * scale)
        detail.draw(in: box)
        NSGraphicsContext.restoreGraphicsState()
    }
}
