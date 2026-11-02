import AppKit

/// Reshapes a mouse wheel's scrolling: the other way from System Settings, and gliding, as Mos
/// does. Trackpads (and Magic Mouse) are left alone: their scrolling is continuous, a wheel's comes
/// in clicks. It needs Accessibility, which NyCopilot already has for Translate; without it,
/// nothing changes.
///
/// A gliding click is swallowed and replaced, frame by frame, by small continuous scrolls that
/// add up to its distance. Hold ⇧ to scroll sideways, ⌥ to scroll five times as far, ⌘ or ⌃ for
/// the click as it was (zooming expects whole clicks).
@MainActor
final class MouseWheel: NSObject {
    struct Options: Equatable {
        var reverse = false
        var smooth = false
        var lines = 3.0
        /// Milliseconds a click glides for.
        var glide = 200.0
        /// Bundle identifiers of apps whose wheel scrolls as usual.
        var exceptions: Set<String> = []
    }

    var options = Options()

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var glide = ScrollGlide()
    private var link: CADisplayLink?
    private var lastFrame: CFTimeInterval?
    /// Marks the scrolls NyCopilot posts, so the tap lets them through untouched.
    private static let marker: Int64 = 0x4E79_5768 // "NyWh"

    /// Nil when the event tap can't be made (no Accessibility).
    init?(options: Options) {
        self.options = options
        super.init()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: CGEventMask(1 << CGEventType.scrollWheel.rawValue),
                                          callback: { _, type, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            let wheel = Unmanaged<MouseWheel>.fromOpaque(info).takeUnretainedValue()
            // The tap's run loop source is on the main run loop.
            return MainActor.assumeIsolated { wheel.handle(type, event) }
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return nil }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        link?.invalidate()
        link = nil
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        case .scrollWheel where event.getIntegerValueField(.scrollWheelEventIsContinuous) == 0
                             && event.getIntegerValueField(.eventSourceUserData) != Self.marker:
            if options.reverse { Self.reverse(event) }
            let flags = event.flags
            guard options.smooth, flags.isDisjoint(with: [.maskCommand, .maskControl]),
                  !options.exceptions.contains(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "") else {
                return Unmanaged.passUnretained(event)
            }
            var y = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
            var x = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)
            // A click too small to have points (rare) still has a line count.
            if y == 0 && x == 0 {
                y = Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis1))
                x = Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis2))
            }
            if flags.contains(.maskShift) && x == 0 { (x, y) = (y, 0) }
            glide.add(x: x, y: y, lines: options.lines, boost: flags.contains(.maskAlternate) ? 5 : 1,
                      glide: options.glide / 1000, at: CACurrentMediaTime())
            startFrames()
            return nil
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func startFrames() {
        if link == nil {
            link = NSScreen.main?.displayLink(target: self, selector: #selector(frame(_:)))
            link?.add(to: .main, forMode: .common)
        }
        link?.isPaused = false
    }

    @objc private func frame(_ link: CADisplayLink) {
        let now = link.timestamp
        // A long gap (the first frame, or after a pause) counts as one frame.
        let dt = lastFrame.map { min(now - $0, 0.05) } ?? link.duration
        lastFrame = now
        let step = glide.frame(dt: dt)
        if step.x != 0 || step.y != 0,
           let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(step.y), wheel2: Int32(step.x), wheel3: 0) {
            event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            event.setIntegerValueField(.eventSourceUserData, value: Self.marker)
            event.flags = []
            event.post(tap: .cgSessionEventTap)
        }
        if glide.isIdle {
            link.isPaused = true
            lastFrame = nil
        }
    }

    /// Lines first: setting them recomputes the point and fixed-point deltas, which then get their
    /// own (negated) values back.
    nonisolated static func reverse(_ event: CGEvent) {
        for (lines, fixed, points) in [(CGEventField.scrollWheelEventDeltaAxis1, CGEventField.scrollWheelEventFixedPtDeltaAxis1, CGEventField.scrollWheelEventPointDeltaAxis1),
                                       (.scrollWheelEventDeltaAxis2, .scrollWheelEventFixedPtDeltaAxis2, .scrollWheelEventPointDeltaAxis2)] {
            let (l, f, p) = (event.getIntegerValueField(lines), event.getDoubleValueField(fixed), event.getIntegerValueField(points))
            event.setIntegerValueField(lines, value: -l)
            event.setDoubleValueField(fixed, value: -f)
            event.setIntegerValueField(points, value: -p)
        }
    }
}

/// Where a gliding wheel is headed and how it gets there, in points. Each click starts a curve
/// to the new target that begins at the speed the page is already moving and comes to rest exactly
/// at the end, so a steady spin scrolls at a steady pace instead of in bursts. While clicks keep
/// coming, each curve lasts until about when the next click is due, so a short glide still bridges
/// the gaps; a single click keeps the short glide. Scroll events carry whole points only (macOS
/// drops fractions), so whole points go out and the fractions carry over.
struct ScrollGlide {
    /// Points in a line: Mos's step, and close to Windows' (3 lines = 100 pixels in a browser).
    static let line = 33.6
    /// Clicks closer together than this are one spin.
    static let spin = 0.3
    /// A curve lasts this many times the gap between clicks, so it overlaps the next one.
    static let bridge = 1.5
    /// The longest a spin can stretch a curve to, so stopping still stops promptly.
    static let longest = 0.4

    /// One axis: a cubic curve from where it was to its target, with the speed it started at.
    private struct Axis {
        var distance = 0.0
        var speed = 0.0
        var duration = 0.0
        var elapsed = 0.0
        var reached = 0.0
        var carry = 0.0
        var isMoving = false

        func position(at time: Double) -> Double {
            guard duration > 0, time < duration else { return distance }
            let s = time / duration
            return distance * (3 * s * s - 2 * s * s * s) + speed * duration * (s - 2 * s * s + s * s * s)
        }

        func velocity(at time: Double) -> Double {
            guard duration > 0, time < duration else { return 0 }
            let s = time / duration
            return (distance * (6 * s - 6 * s * s) + speed * duration * (1 - 4 * s + 3 * s * s)) / duration
        }

        /// Adds a click of `delta` points, arriving over `duration` seconds.
        mutating func add(_ delta: Double, over duration: Double) {
            guard delta != 0 else { return }
            let current = isMoving ? velocity(at: elapsed) : 0
            var target = isMoving ? distance - reached + delta : delta
            // The other way: stop what's left and turn at once.
            if target * delta < 0 || current * delta < 0 { (target, carry) = (delta, 0) }
            let turning = current * delta < 0
            (distance, self.duration, elapsed, reached, isMoving) = (target, duration, 0, 0, true)
            // Keep the speed the page has (so it doesn't jump), but no faster than ending at rest
            // allows without overshooting; from a standstill, start at that speed, like an ease-out.
            let fastest = duration > 0 ? 3 * target / duration : 0
            speed = !turning && current != 0 ? (abs(current) < abs(fastest) ? current : fastest) : fastest
        }

        mutating func advance(_ dt: Double) -> Int {
            guard isMoving else { return 0 }
            elapsed += dt
            let now = position(at: elapsed)
            carry += now - reached
            reached = now
            let done = elapsed >= duration
            // Whole points while moving; at the end, the fraction left rounds to the nearest.
            let whole = done ? carry.rounded() : carry.rounded(.towardZero)
            carry = done ? 0 : carry - whole
            if done { isMoving = false }
            return Int(whole)
        }
    }

    private var x = Axis(), y = Axis()
    private var lastClick: Double?

    var isIdle: Bool { !x.isMoving && !y.isMoving }

    /// One click, `dx` and `dy` as macOS would scroll it, at `time` (seconds). A slow click goes
    /// `lines` lines; a quick spin, which macOS already scrolls further, goes that much further again.
    mutating func add(x dx: Double, y dy: Double, lines: Double, boost: Double, glide: Double, at time: Double) {
        func distance(_ delta: Double) -> Double {
            delta == 0 ? 0 : (delta < 0 ? -1 : 1) * max(abs(delta), Self.line) * lines * boost
        }
        var duration = glide
        if glide > 0, let last = lastClick, time - last < Self.spin {
            duration = max(glide, min(Self.bridge * (time - last), Self.longest))
        }
        lastClick = time
        x.add(distance(dx), over: duration)
        y.add(distance(dy), over: duration)
    }

    /// The whole points to send for a frame `dt` seconds long.
    mutating func frame(dt: Double) -> (x: Int, y: Int) {
        (x.advance(dt), y.advance(dt))
    }
}
