import AppKit

/// The key the demos draw: a slim pane of frosted glass with a hairline rim and white lettering.
/// It sits on a dark base, so it reads over a light window as well as over the desktop; lit, it
/// turns the accent blue.
enum DemoKeycap {
    static func width(_ label: String, height: CGFloat) -> CGFloat {
        max(height * 1.25, (label as NSString).size(withAttributes: attributes(height: height)).width + height * 0.8)
    }

    /// `dip` below 1 is the key held down: a touch smaller and brighter.
    static func draw(_ label: String, in rect: CGRect, scale: CGFloat, lit: CGFloat = 0, dip: CGFloat = 1) {
        let cap = rect.insetBy(dx: rect.width * (1 - dip) / 2, dy: rect.height * (1 - dip) / 2)
        let glow = max(lit, dip < 1 ? 0.25 : 0)
        let radius = cap.height * 0.3
        let path = NSBezierPath(roundedRect: cap, xRadius: radius, yRadius: radius)
        let accent = NSColor(srgbRed: 0.31, green: 0.52, blue: 1, alpha: 1)
        NSColor.black.withAlphaComponent(0.45).setFill()
        path.fill()
        NSGradient(starting: NSColor.white.withAlphaComponent(0.1).blended(withFraction: glow, of: accent.withAlphaComponent(0.85))!,
                   ending: NSColor.white.withAlphaComponent(0.22).blended(withFraction: glow, of: accent.blended(withFraction: 0.2, of: .white)!)!)!
            .draw(in: path, angle: 90)
        NSColor.white.withAlphaComponent(0.32 + 0.3 * glow).setStroke()
        let rim = NSBezierPath(roundedRect: cap.insetBy(dx: 0.5 * scale, dy: 0.5 * scale), xRadius: radius, yRadius: radius)
        rim.lineWidth = scale
        rim.stroke()
        let text = NSAttributedString(string: label, attributes: attributes(height: cap.height))
        let size = text.size()
        text.draw(at: NSPoint(x: cap.midX - size.width / 2, y: cap.midY - size.height / 2))
    }

    private static func attributes(height: CGFloat) -> [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: height * 0.5, weight: .medium), .foregroundColor: NSColor.white, .kern: height * 0.02]
    }
}
