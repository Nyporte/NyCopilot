import AppKit

/// One display frozen at the moment a capture starts: its pixels and the windows on it, so the
/// selection UI works on a still image while the real screen keeps running underneath.
/// Immutable once frozen, so it can be handed between tasks.
struct FrozenScreen: @unchecked Sendable {
    let screen: NSScreen
    let image: CGImage
    /// On-screen windows, front to back, in this screen's flipped view coordinates (top-left origin).
    let windows: [Window]

    var scale: CGFloat { CGFloat(image.width) / screen.frame.width }

    /// The image pixels under a rectangle in this screen's view points, out to whole pixels: what a
    /// capture of it holds, and so the size it's labelled with.
    func pixelRect(local rect: CGRect) -> CGRect {
        CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale).integral
    }

    /// The same, for a rectangle in global top-left coordinates.
    func pixelRect(global rect: CGRect) -> CGRect {
        let origin = ScreenGeometry.topLeftOrigin(of: screen)
        return pixelRect(local: rect.offsetBy(dx: -origin.x, dy: -origin.y))
    }

    /// The one image pixel under a point in view points.
    func pixel(at point: CGPoint) -> CGRect { CGRect(x: floor(point.x * scale), y: floor(point.y * scale), width: 1, height: 1) }

    /// The frozen pixels under a rectangle in view points.
    func crop(_ rect: CGRect) -> CGImage? { image.cropping(to: pixelRect(local: rect)) }

    /// A window's visible area and the app it belongs to, for finding the elements inside it.
    struct Window {
        let rect: CGRect
        let pid: pid_t
    }
}
