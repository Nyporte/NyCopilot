import AppKit
@testable import NyCopilotKit

/// The README's opening picture, cut like a short ad: a quick scene for each tool, each under one
/// line on what it gets you and the key that does it, then a card with every key. Each scene is
/// recorded on its own by a DemoDirector (with no output file), and the composer adds the motion:
/// the camera moves in on what matters (DemoDirector.look), the line comes in word by word with its
/// key popping up on a pill, the key lights when the scene presses it, and each next scene opens out
/// of the middle over the last. The card hands back to the first scene, so the loop has no seam.
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

    /// How long one shot takes to hand over to the next, and how smooth that is: much of the frame
    /// moves, so fewer frames keep the file small.
    static let turn = 0.4, turnFPS = 20.0
    /// How long the camera takes to move, how far in it may go, and how smooth it is while moving
    /// (the whole frame changes, so again fewer frames).
    static let glide = 0.45, deepest: CGFloat = 1.35, glideFPS = 15.0
    /// The caption's band along the top, in points: the camera keeps what it moves in on below it.
    static let band: CGFloat = 96

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

        /// One shot as it looks `time` seconds in, filling the frame.
        func render(_ shot: Shot, at time: Double) -> CGImage? {
            guard let context = bitmap(width, height) else { return nil }
            let full = CGRect(origin: .zero, size: size)
            switch shot {
            case .beat(let index):
                let beat = beats[index], clock = start(beat) + time
                let frames = beat.scene.frames
                let view = camera(beat.scene, at: clock, size: size, scale: scale)
                context.saveGState()
                context.interpolationQuality = .high
                context.scaleBy(x: size.width / view.width, y: size.width / view.width)
                context.translateBy(x: -view.minX, y: -view.minY)
                context.draw((frames.last { $0.time <= clock + 1e-6 } ?? frames[0]).image, in: full)
                context.restoreGState()
                caption(beat, at: time, clock: clock, in: context, size: size, scale: scale)
            case .card:
                context.draw(backdrop, in: full)
                drawCard(card, at: time, in: context, size: size, scale: scale)
            }
            return context.makeImage()
        }

        var clock = 0.0
        for (index, entry) in shots.enumerated() {
            let next = shots[(index + 1) % shots.count].shot
            var local = 0.0, shown = -Double.infinity, view = CGRect.null
            while local < entry.length - 1e-6 {
                defer { local += 1 / fps }
                if case .beat(let index) = entry.shot {
                    let now = camera(beats[index].scene, at: start(beats[index]) + local, size: size, scale: scale)
                    if now != view, view != .null, local - shown < 1 / glideFPS - 1e-6 { continue }
                    view = now
                }
                guard let image = render(entry.shot, at: local) else { return false }
                writer.add(image, at: clock + local)
                shown = local
            }
            clock += entry.length
            // The next shot opens out of the middle over this one.
            var turned = 0.0
            while turned < turn - 1e-6 {
                guard let context = bitmap(width, height), let leaving = render(entry.shot, at: entry.length),
                      let coming = render(next, at: 0) else { return false }
                handOver(from: leaving, to: coming, at: turned / turn, in: context, size: size, scale: scale)
                guard let image = context.makeImage() else { return false }
                writer.add(image, at: clock + turned)
                turned += 1 / turnFPS
            }
            clock += turn
        }
        return writer.finish(at: clock)
    }

    private static func bitmap(_ width: Int, _ height: Int) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    private static func eased(_ t: Double) -> Double { t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2 }
    private static func easedOut(_ t: Double) -> Double { 1 - pow(1 - max(0, min(1, t)), 3) }
    /// Past the mark and back, like a spring settling.
    private static func overshoot(_ t: Double) -> Double {
        let t = max(0, min(1, t)), c = 1.70158
        return 1 + (c + 1) * pow(t - 1, 3) + c * pow(t - 1, 2)
    }

    // MARK: Hand-over

    private static func handOver(from leaving: CGImage, to coming: CGImage, at progress: Double,
                                 in context: CGContext, size: CGSize, scale: CGFloat) {
        let full = CGRect(origin: .zero, size: size)
        context.draw(leaving, in: full)
        context.setFillColor(NSColor.black.withAlphaComponent(0.4).cgColor)
        context.fill(full)
        let open = CGFloat(easedOut(progress)), rest = 1 - open
        let grow = 0.45 + 0.55 * open
        let rect = CGRect(x: size.width * (1 - grow) / 2, y: size.height * (1 - grow) / 2 - 50 * scale * rest,
                          width: size.width * grow, height: size.height * grow).integral
        let radius = 22 * scale * rest
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        context.setAlpha(CGFloat(min(1, progress / 0.25)))
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -14 * scale * rest), blur: 40 * scale * rest,
                          color: NSColor.black.withAlphaComponent(0.55 * rest).cgColor)
        context.addPath(path)
        context.setFillColor(NSColor.black.cgColor)
        context.fillPath()
        context.restoreGState()
        context.addPath(path)
        context.clip()
        context.interpolationQuality = .high
        context.draw(coming, in: rect)
    }

    // MARK: Camera

    /// The part of the frame (in pixels from the bottom-left) the camera shows at `time` on the scene's clock.
    private static func camera(_ scene: DemoDirector, at time: Double, size: CGSize, scale: CGFloat) -> CGRect {
        let full = CGRect(origin: .zero, size: size)
        func target(_ focus: CGRect?) -> CGRect {
            guard let focus else { return full }
            // At least a little of what's around it, at the frame's shape, never closer than `deepest`, inside the frame.
            let pixels = CGRect(x: focus.minX * scale, y: size.height - focus.maxY * scale,
                                width: focus.width * scale, height: focus.height * scale).insetBy(dx: -40 * scale, dy: -40 * scale)
            var width = max(pixels.width, pixels.height * size.width / size.height, size.width / deepest)
            width = min(width, size.width)
            let height = width * size.height / size.width, zoom = size.width / width
            let x = max(0, min(pixels.midX - width / 2, size.width - width))
            // Centered, but low enough that its top clears the caption.
            let clear = pixels.maxY - (size.height - band * scale) / zoom
            let y = max(0, min(max(pixels.midY - height / 2, clear), size.height - height))
            return CGRect(x: x, y: y, width: width, height: height)
        }
        var view = full
        let moves = scene.camera
        for (index, move) in moves.enumerated() where move.time <= time {
            let end = index + 1 < moves.count ? min(time, moves[index + 1].time) : time
            let t = CGFloat(eased(min(1, (end - move.time) / glide)))
            let to = target(move.focus)
            view = CGRect(x: view.minX + (to.minX - view.minX) * t, y: view.minY + (to.minY - view.minY) * t,
                          width: view.width + (to.width - view.width) * t, height: view.height + (to.height - view.height) * t)
        }
        return view
    }

    // MARK: Caption

    /// The key and the line, centered over the top of the scene: the key pops up, the words rise in
    /// one after another, and the key lights when the scene presses it.
    private static func caption(_ beat: Beat, at time: Double, clock: Double, in context: CGContext, size: CGSize, scale: CGFloat) {
        let since = beat.scene.keys.last { $0.labels == beat.keys && $0.time <= clock + 1e-6 }.map { clock - $0.time } ?? .infinity
        let font = NSFont.systemFont(ofSize: 28 * scale, weight: .bold)
        func words(_ text: String) -> NSAttributedString {
            NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.white, .shadow: shadow(scale)])
        }
        let label = beat.keys.joined()
        let capHeight = 42 * scale, gap = 16 * scale
        let capWidth = keycapWidth(label, height: capHeight)
        let whole = words(beat.line).size()
        let left = (size.width - capWidth - gap - whole.width) / 2
        let middle = size.height - 52 * scale
        appKit(context) {
            // On a dark pill, so it reads over anything.
            let pill = NSRect(x: left - 10 * scale, y: middle - 31 * scale, width: capWidth + gap + whole.width + 32 * scale, height: 62 * scale)
            NSColor.black.withAlphaComponent(0.5 * CGFloat(easedOut(time / 0.25))).setFill()
            NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
            let pop = CGFloat(overshoot(time / 0.32))
            let cap = CGRect(x: left, y: middle - capHeight / 2, width: capWidth, height: capHeight)
            NSGraphicsContext.current?.cgContext.setAlpha(CGFloat(min(1, time / 0.12)))
            keycap(label, in: cap.insetBy(dx: cap.width * (1 - pop) / 2, dy: cap.height * (1 - pop) / 2), scale: scale,
                   lit: lit(since), dip: since >= 0 && since < 0.18 ? 0.92 : 1)
            let parts = beat.line.split(separator: " ")
            for (index, part) in parts.enumerated() {
                let rise = easedOut((time - 0.1 - 0.045 * Double(index)) / 0.3)
                guard rise > 0 else { continue }
                let before = words(parts[..<index].joined(separator: " ") + (index > 0 ? " " : "")).size().width
                let word = words(String(part))
                NSGraphicsContext.current?.cgContext.setAlpha(CGFloat(rise))
                word.draw(at: NSPoint(x: left + capWidth + gap + before,
                                      y: middle - whole.height / 2 - CGFloat(1 - rise) * 14 * scale))
            }
            NSGraphicsContext.current?.cgContext.setAlpha(1)
        }
    }

    /// Fully lit as the key goes down, fading over the next moment.
    private static func lit(_ since: Double) -> CGFloat {
        guard since >= 0 else { return 0 }
        return CGFloat(max(0, min(1, 1 - (since - 0.45) / 0.35)))
    }

    // MARK: Card

    private static func drawCard(_ card: Card, at time: Double, in context: CGContext, size: CGSize, scale: CGFloat) {
        // Laid out in points from the top, like the scenes; each part rises in after the one above.
        let center = size.width / 2
        func y(_ top: CGFloat, _ height: CGFloat) -> CGFloat { size.height - (top + height) * scale }
        func rise(_ delay: Double) -> (alpha: CGFloat, lift: CGFloat) {
            let t = easedOut((time - delay) / 0.35)
            return (CGFloat(t), CGFloat(1 - t) * 16 * scale)
        }
        func line(_ text: String, font: NSFont, color: NSColor, top: CGFloat, delay: Double) {
            let (alpha, lift) = rise(delay)
            let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .shadow: shadow(scale)])
            NSGraphicsContext.current?.cgContext.setAlpha(alpha)
            string.draw(at: NSPoint(x: center - string.size().width / 2, y: y(top, string.size().height / scale) - lift))
        }
        appKit(context) {
            let cg = NSGraphicsContext.current?.cgContext
            if let icon = card.icon {
                let pop = CGFloat(overshoot(time / 0.45)), side = 96 * scale * (0.6 + 0.4 * pop)
                cg?.setAlpha(CGFloat(min(1, time / 0.15)))
                icon.draw(in: NSRect(x: center - side / 2, y: y(144, 0) - side / 2, width: side, height: side))
            }
            line(card.title, font: .systemFont(ofSize: 46 * scale, weight: .heavy), color: .white, top: 198, delay: 0.15)
            line(card.line, font: .systemFont(ofSize: 19 * scale, weight: .medium), color: NSColor.white.withAlphaComponent(0.88),
                 top: 262, delay: 0.27)

            // The keys, one after another, each lighting as it lands.
            let column = min(176 * scale, (size.width - 40 * scale) / CGFloat(card.keys.count)), capHeight = 50 * scale
            for (index, key) in card.keys.enumerated() {
                let shown = time - (0.45 + 0.12 * Double(index))
                guard shown > 0 else { continue }
                let middle = center + (CGFloat(index) - CGFloat(card.keys.count - 1) / 2) * column
                let pop = CGFloat(overshoot(shown / 0.3))
                let width = keycapWidth(key.keys, height: capHeight)
                let cap = CGRect(x: middle - width / 2, y: y(328, 50), width: width, height: capHeight)
                cg?.setAlpha(CGFloat(min(1, shown / 0.12)))
                keycap(key.keys, in: cap.insetBy(dx: cap.width * (1 - pop) / 2, dy: cap.height * (1 - pop) / 2), scale: scale,
                       lit: lit(shown), dip: 1)
                let label = NSAttributedString(string: key.label, attributes: [
                    .font: NSFont.systemFont(ofSize: 16 * scale, weight: .semibold), .foregroundColor: NSColor.white, .shadow: shadow(scale)])
                label.draw(at: NSPoint(x: middle - label.size().width / 2, y: y(392, label.size().height / scale)))
            }
            line(card.footnote, font: .systemFont(ofSize: 14 * scale, weight: .medium), color: NSColor.white.withAlphaComponent(0.7),
                 top: 470, delay: 0.45 + 0.12 * Double(card.keys.count) + 0.1)
            cg?.setAlpha(1)
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
