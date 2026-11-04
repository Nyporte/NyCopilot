import AppKit

/// The capture's hover outline, which glides from element to element, and the selection's frame and
/// handles, the nearest of which grows under the pointer — both on Bézier curves.
extension CaptureView {
    // MARK: Gliding outline

    /// The hover outline as drawn: one outline that glides from element to element instead of
    /// jumping. It appears where it belongs the first time, then eases to each new target.
    static let glideDuration: CFTimeInterval = 0.16

    func glidingOutline() -> CGRect? {
        guard let target = hoverWindow else { glide = nil; return nil }
        let now = CACurrentMediaTime()
        if glide?.to != target {
            let current = glide.map { Self.position(of: $0, at: now) } ?? target
            glide = (current, target, now)
            if current != target { keepGliding() }
        }
        return glide.map { Self.position(of: $0, at: now) }
    }

    /// Ease-out: quick to leave, gentle to arrive.
    static func position(of glide: (from: CGRect, to: CGRect, start: CFTimeInterval), at now: CFTimeInterval) -> CGRect {
        let eased = BezierCurve.easeOut.value(at: (now - glide.start) / glideDuration)
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * eased }
        return CGRect(x: mix(glide.from.minX, glide.to.minX), y: mix(glide.from.minY, glide.to.minY),
                      width: mix(glide.from.width, glide.to.width), height: mix(glide.from.height, glide.to.height))
    }

    /// Redraws at display rate until the outline arrives, then stops.
    func keepGliding() {
        guard glideTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                self.updateChrome()
                let now = CACurrentMediaTime()
                let gliding = self.glide.map { now - $0.start < Self.glideDuration } ?? false
                let growing = self.handleGrowth.values.contains { now - $0.start < Self.growDuration }
                if !gliding && !growing {
                    timer.invalidate()
                    self.glideTimer = nil
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        glideTimer = timer
    }

    var showsMagnifier: Bool {
        guard !isPassive, textEditor == nil else { return false }
        switch drag {
        case .creating, .resizing: return true
        case .none: return selection == nil
        default: return false
        }
    }

    // MARK: Handle under the pointer

    /// The handle nearest the pointer (within reach) grows, and so does the area that grabs it; it
    /// stays grown while it's dragged. Growing overshoots a touch and settles; shrinking eases out.
    static let growDuration: CFTimeInterval = 0.18
    static let handleReach: CGFloat = 24

    func growth(of handle: Handle, at now: CFTimeInterval) -> CGFloat {
        guard let state = handleGrowth[handle] else { return 0 }
        let curve = state.to > state.from ? BezierCurve.overshoot : BezierCurve.easeOut
        return state.from + (state.to - state.from) * curve.value(at: (now - state.start) / Self.growDuration)
    }

    func focusHandle(near point: CGPoint?) {
        var target: Handle?
        if case .resizing(let handle, _) = drag {
            target = handle
        } else if let selection, let point, tool == nil, !isReadingText, !isPassive,
                  toolbar.isHidden || !toolbar.frame.insetBy(dx: -4, dy: -4).contains(point) {
            func distance(_ handle: Handle) -> CGFloat {
                let spot = self.point(of: handle, in: selection)
                return hypot(spot.x - point.x, spot.y - point.y)
            }
            if let nearest = Handle.allCases.min(by: { distance($0) < distance($1) }), distance(nearest) <= Self.handleReach {
                target = nearest
            }
        }
        guard target != focusedHandle else { return }
        let now = CACurrentMediaTime()
        for handle in [focusedHandle, target].compactMap({ $0 }) {
            handleGrowth[handle] = (growth(of: handle, at: now), handle == target ? 1 : 0, now)
        }
        focusedHandle = target
        keepGliding()
    }

    /// The pixel size of `measuring` (by default `rect` itself), and where its plate goes next to `rect`.
    func sizeLabel(for rect: CGRect, measuring measured: CGRect? = nil) -> (text: String, plate: CGRect) {
        let pixels = frozen.pixelRect(local: measured ?? rect)
        let text = "\(Int(pixels.width)) × \(Int(pixels.height))"
        let size = (text as NSString).size(withAttributes: CaptureLabel.attributes)
        var origin = CGPoint(x: rect.minX, y: rect.minY - size.height - 10)
        if origin.y < 4 { origin.y = rect.minY + 6; origin.x += 6 }
        return (text, CGRect(x: origin.x, y: origin.y, width: ceil(size.width) + 12, height: ceil(size.height) + 6))
    }
}
