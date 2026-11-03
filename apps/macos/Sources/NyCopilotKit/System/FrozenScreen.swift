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

    /// A window's visible area and the app it belongs to, for finding the elements inside it.
    struct Window {
        let rect: CGRect
        let pid: pid_t
    }
}
