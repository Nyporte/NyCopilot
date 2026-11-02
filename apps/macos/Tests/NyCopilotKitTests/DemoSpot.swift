import AppKit
@testable import NyCopilotKit

/// The README's opening picture, cut like a short ad: a few quick scenes, each under one line on
/// what it gets you and the key that does it, joined by a fast push, then a card with every key.
/// The card pushes back into the first scene, so the loop has no seam. Each scene is recorded on its
/// own by a DemoDirector (with no output file); a caption's key goes down and lights up when its
/// scene presses it.
@MainActor
enum DemoSpot {
    struct Beat {
        let scene: DemoDirector
        let keys: [String]
        let line: String
    }

    /// The closing card, over an empty scene's desktop so it joins the others'.
    struct Card {
        let backdrop: DemoDirector
        let icon: NSImage?
        let title: String
        let line: String
        let keys: [(keys: String, label: String)]
        let footnote: String
        let hold: Double
    }

    /// How long one shot takes to push the next in.
    static let push = 0.28

    private enum Shot { case beat(Int), card }

    static func make(_ beats: [Beat], card: Card, into url: URL, fps: Double = 30) -> Bool {
        guard let first = beats.first?.scene.frames.first?.image, let backdrop = card.backdrop.frames.first?.image else { return false }
        let width = first.width, height = first.height
        let scale = CGFloat(width) / beats[0].scene.crop.width
        let size = CGSize(width: width, height: height)
        guard let writer = GifWriter(url: url, width: width, height: height) else { return false }

        // A scene's clock starts when it began rolling.
        func start(_ beat: Beat) -> Double { beat.scene.frames.first?.time ?? 0 }
        let shots: [(shot: Shot, length: Double)] = beats.indices.map { (.beat($0), beats[$0].scene.duration - start(beats[$0])) }
            + [(.card, card.hold)]

        func draw(_ shot: Shot, at time: Double, offset: CGFloat, in context: CGContext) {
            let place = CGRect(x: offset, y: 0, width: size.width, height: size.height)
            switch shot {
            case .beat(let index):
                let beat = beats[index], time = start(beat) + time
                let frames = beat.scene.frames
                context.draw((frames.last { $0.time <= time + 1e-6 } ?? frames[0]).image, in: place)
                caption(beat, at: time, offset: offset, in: context, size: size, scale: scale)
            case .card:
                context.draw(backdrop, in: place)
                drawCard(card, at: time, offset: offset, in: context, size: size, scale: scale)
            }
        }

        var clock = 0.0
        for (index, entry) in shots.enumerated() {
            let next = shots[(index + 1) % shots.count].shot
            var local = 0.0
            while local < entry.length + push - 1e-6 {
                guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                if local < entry.length {
                    draw(entry.shot, at: local, offset: 0, in: context)
                } else {
                    // The shot slides out to the left as the next comes in, both on whole pixels.
                    let shift = (size.width * CGFloat(eased((local - entry.length) / push))).rounded()
                    draw(entry.shot, at: entry.length, offset: -shift, in: context)
                    draw(next, at: 0, offset: size.width - shift, in: context)
                }
                if let image = context.makeImage() { writer.add(image, at: clock + local) }
                local += 1 / fps
            }
            clock += entry.length + push
        }
        return writer.finish(at: clock)
    }

    private static func eased(_ t: Double) -> Double { t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2 }

    // MARK: Caption

    /// The key and the line, centered over the top of the scene.
    private static func caption(_ beat: Beat, at time: Double, offset: CGFloat, in context: CGContext, size: CGSize, scale: CGFloat) {
        let since = beat.scene.keys.last { $0.labels == beat.keys && $0.time <= time + 1e-6 }.map { time - $0.time } ?? .infinity
        let text = NSAttributedString(string: beat.line, attributes: [
            .font: NSFont.systemFont(ofSize: 27 * scale, weight: .bold), .foregroundColor: NSColor.white, .shadow: shadow(scale)])
        let label = beat.keys.joined()
        let capHeight = 40 * scale, gap = 16 * scale
        let capWidth = keycapWidth(label, height: capHeight)
        let textSize = text.size()
        let left = offset + (size.width - capWidth - gap - textSize.width) / 2
        let middle = size.height - 50 * scale
        appKit(context) {
            keycap(label, in: CGRect(x: left, y: middle - capHeight / 2, width: capWidth, height: capHeight), scale: scale,
                   lit: lit(since), dip: since >= 0 && since < 0.18 ? 0.92 : 1)
            text.draw(at: NSPoint(x: left + capWidth + gap, y: middle - textSize.height / 2))
        }
    }

    /// Fully lit as the key goes down, fading over the next moment.
    private static func lit(_ since: Double) -> CGFloat {
        guard since >= 0 else { return 0 }
        return CGFloat(max(0, min(1, 1 - (since - 0.45) / 0.35)))
    }

    // MARK: Card

    private static func drawCard(_ card: Card, at time: Double, offset: CGFloat, in context: CGContext, size: CGSize, scale: CGFloat) {
        // Laid out in points from the top, like the scenes.
        let center = offset + size.width / 2
        func y(_ top: CGFloat, _ height: CGFloat) -> CGFloat { size.height - (top + height) * scale }
        appKit(context) {
            if let icon = card.icon {
                let side = 96 * scale
                icon.draw(in: NSRect(x: center - side / 2, y: y(96, 96), width: side, height: side))
            }
            let title = NSAttributedString(string: card.title, attributes: [
                .font: NSFont.systemFont(ofSize: 46 * scale, weight: .heavy), .foregroundColor: NSColor.white, .shadow: shadow(scale)])
            title.draw(at: NSPoint(x: center - title.size().width / 2, y: y(198, title.size().height / scale)))
            let line = NSAttributedString(string: card.line, attributes: [
                .font: NSFont.systemFont(ofSize: 19 * scale, weight: .medium), .foregroundColor: NSColor.white.withAlphaComponent(0.88),
                .shadow: shadow(scale)])
            line.draw(at: NSPoint(x: center - line.size().width / 2, y: y(262, line.size().height / scale)))

            // The keys, one after another.
            let column = 176 * scale, capHeight = 50 * scale
            for (index, key) in card.keys.enumerated() {
                let shown = time - (0.2 + 0.16 * Double(index))
                let appear = CGFloat(max(0, min(1, shown / 0.2)))
                guard appear > 0 else { continue }
                let middle = center + (CGFloat(index) - CGFloat(card.keys.count - 1) / 2) * column
                let grow = 0.85 + 0.15 * (1 - pow(1 - appear, 3))
                let width = keycapWidth(key.keys, height: capHeight)
                let cap = CGRect(x: middle - width / 2, y: y(328, 50), width: width, height: capHeight)
                NSGraphicsContext.current?.cgContext.setAlpha(appear)
                keycap(key.keys, in: cap.insetBy(dx: cap.width * (1 - grow) / 2, dy: cap.height * (1 - grow) / 2), scale: scale,
                       lit: lit(shown), dip: 1)
                let label = NSAttributedString(string: key.label, attributes: [
                    .font: NSFont.systemFont(ofSize: 16 * scale, weight: .semibold), .foregroundColor: NSColor.white, .shadow: shadow(scale)])
                label.draw(at: NSPoint(x: middle - label.size().width / 2, y: y(392, label.size().height / scale)))
                NSGraphicsContext.current?.cgContext.setAlpha(1)
            }
            let footnote = NSAttributedString(string: card.footnote, attributes: [
                .font: NSFont.systemFont(ofSize: 14 * scale, weight: .medium), .foregroundColor: NSColor.white.withAlphaComponent(0.7)])
            footnote.draw(at: NSPoint(x: center - footnote.size().width / 2, y: y(470, footnote.size().height / scale)))
        }
    }

    // MARK: Drawing

    private static func keycapWidth(_ label: String, height: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: height * 0.46, weight: .semibold)
        return max(height, (label as NSString).size(withAttributes: [.font: font]).width + height * 0.7)
    }

    /// A key like the ones the scenes show in the corner; lit, it turns the accent blue.
    private static func keycap(_ label: String, in rect: CGRect, scale: CGFloat, lit: CGFloat, dip: CGFloat) {
        let cap = rect.insetBy(dx: rect.width * (1 - dip) / 2, dy: rect.height * (1 - dip) / 2).offsetBy(dx: 0, dy: dip < 1 ? -2 * scale : 0)
        let radius = cap.height * 0.22
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 14 * scale
        shadow.shadowOffset = NSSize(width: 0, height: -5 * scale)
        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        NSColor(white: 0.74, alpha: 1).blended(withFraction: lit, of: NSColor(srgbRed: 0.16, green: 0.33, blue: 0.82, alpha: 1))!.setFill()
        NSBezierPath(roundedRect: cap, xRadius: radius, yRadius: radius).fill()
        NSGraphicsContext.restoreGraphicsState()
        let face = NSBezierPath(roundedRect: NSRect(x: cap.minX, y: cap.minY + 3 * scale, width: cap.width, height: cap.height - 3 * scale),
                                xRadius: radius, yRadius: radius)
        let accent = NSColor(srgbRed: 0.29, green: 0.5, blue: 1, alpha: 1)
        NSGradient(starting: NSColor(white: 0.93, alpha: 1).blended(withFraction: lit, of: accent)!,
                   ending: NSColor(white: 0.99, alpha: 1).blended(withFraction: lit, of: accent.blended(withFraction: 0.25, of: .white)!)!)!
            .draw(in: face, angle: 90)
        let ink = NSColor(white: 0.17, alpha: 1).blended(withFraction: lit, of: .white)!
        let text = NSAttributedString(string: label, attributes: [
            .font: NSFont.systemFont(ofSize: cap.height * 0.46, weight: .semibold), .foregroundColor: ink])
        let size = text.size()
        text.draw(at: NSPoint(x: cap.midX - size.width / 2, y: cap.minY + 3 * scale + (cap.height - 3 * scale - size.height) / 2))
    }

    private static func shadow(_ scale: CGFloat) -> NSShadow {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 8 * scale
        shadow.shadowOffset = NSSize(width: 0, height: -1.5 * scale)
        return shadow
    }

    private static func appKit(_ context: CGContext, _ body: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        body()
        NSGraphicsContext.restoreGraphicsState()
    }
}
