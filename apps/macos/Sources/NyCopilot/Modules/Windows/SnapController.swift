import AppKit

/// Drag a window to a screen edge or corner, see where it will land, release to snap.
///
/// Uses global mouse monitors (event-driven, no polling). A drag only counts once the window under
/// the pointer actually moves, so selecting text or dragging files never shows a preview.
@MainActor
final class SnapController {
    var onSnap: ((AXUIElement, WindowRect, Display) -> Void)?
    var isEnabled = false {
        didSet {
            guard isEnabled != oldValue else { return }
            isEnabled ? start() : stop()
        }
    }

    private struct Drag {
        let window: AXUIElement
        let start: WindowRect
        let origin: CGPoint
        var confirmed = false
    }
    private struct Area: Decodable { let action: String?; let frame: WindowRect? }

    private let core: NyCore
    private var monitors: [Any] = []
    private var drag: Drag?
    private var target: (frame: WindowRect, display: Display)?
    private let footprint = Footprint()

    init(core: NyCore) { self.core = core }

    private func start() {
        let handler: (NSEvent) -> Void = { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
        for mask: NSEvent.EventTypeMask in [.leftMouseDown, .leftMouseDragged, .leftMouseUp] {
            if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handler) { monitors.append(monitor) }
        }
    }

    private func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        reset()
    }

    private func handle(_ event: NSEvent) {
        let point = WindowControl.axPoint(NSEvent.mouseLocation)
        switch event.type {
        case .leftMouseDown:
            reset()
            guard Accessibility.isTrusted, let window = WindowControl.window(at: point),
                  let frame = WindowControl.frame(of: window) else { return }
            drag = Drag(window: window, start: frame, origin: point)
        case .leftMouseDragged:
            guard var current = drag else { return }
            if !current.confirmed {
                guard hypot(point.x - current.origin.x, point.y - current.origin.y) > 6 else { return }
                guard let frame = WindowControl.frame(of: current.window) else { drag = nil; return }
                let moved = abs(frame.x - current.start.x) > 1 || abs(frame.y - current.start.y) > 1
                let resized = abs(frame.w - current.start.w) > 1 || abs(frame.h - current.start.h) > 1
                // Moving the pointer far without the window following means this isn't a window drag.
                if resized || (!moved && hypot(point.x - current.origin.x, point.y - current.origin.y) > 40) { drag = nil; return }
                guard moved else { return }
                current.confirmed = true
                drag = current
            }
            updateTarget(at: point)
        case .leftMouseUp:
            if let drag, drag.confirmed, let target {
                footprint.hide()
                // Let the app finish its own drag before the window is moved.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    self?.onSnap?(drag.window, target.frame, target.display)
                }
            }
            reset()
        default:
            break
        }
    }

    private func updateTarget(at point: CGPoint) {
        let displays = WindowControl.displays()
        guard let display = displays.first(where: { $0.frame.contains(point) }),
              let area = try? core.call("windows.snap_area", ["point": ["x": point.x, "y": point.y], "screen": display.visible.json],
                                        as: Area.self),
              let frame = area.frame else {
            target = nil
            footprint.hide()
            return
        }
        target = (frame, display)
        footprint.show(WindowControl.appKitRect(frame))
    }

    private func reset() {
        drag = nil
        target = nil
        footprint.hide()
    }
}

/// The translucent preview of where a dragged window will land.
@MainActor
private final class Footprint {
    private lazy var panel: NSPanel = {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        let material = NSVisualEffectView.roundedMaterial(.hudWindow, radius: 12)
        let tint = AppearanceView()
        tint.radius = 12
        tint.continuousCorners = false
        tint.fill = NSColor.controlAccentColor.withAlphaComponent(0.18)
        tint.border = NSColor.controlAccentColor.withAlphaComponent(0.7)
        tint.borderWidth = 2
        tint.autoresizingMask = [.width, .height]
        material.addSubview(tint)
        panel.contentView = material
        return panel
    }()

    func show(_ frame: NSRect) {
        let inset = frame.insetBy(dx: 2, dy: 2)
        if panel.isVisible {
            guard panel.frame != inset else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                panel.animator().setFrame(inset, display: true)
            }
        } else {
            panel.setFrame(inset, display: true)
            panel.contentView?.subviews.first?.frame = panel.contentView?.bounds ?? .zero
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.1; panel.animator().alphaValue = 1 }
        }
    }

    func hide() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
    }
}
