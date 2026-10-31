import AppKit

/// A brief, non-activating HUD that confirms an outcome without taking focus from the user's app.
@MainActor
final class Toast {
    enum Style {
        case success, warning, info
        var symbol: String {
            switch self {
            case .success: return "checkmark.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .info: return "info.circle.fill"
            }
        }
        var tint: NSColor {
            switch self {
            case .success: return .systemGreen
            case .warning: return .systemOrange
            case .info: return .controlAccentColor
            }
        }
    }

    private var panel: NSPanel?
    private var dismissal: DispatchWorkItem?

    /// `near` is in AppKit screen coordinates; without it the toast appears under the pointer.
    func show(_ title: String, detail: String? = nil, style: Style = .info, near anchor: NSRect? = nil) {
        // Every warning the user sees is kept for the diagnostics report.
        if style == .warning { Diagnostics.note("notice", [title, detail].compactMap { $0 }.joined(separator: " — ")) }
        dismiss(animated: false)
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.float(at: .statusBar, shadow: true, clickThrough: true, behavior: .transient)

        let material = NSVisualEffectView.roundedMaterial(.hudWindow, radius: 12)
        let titleLabel = Design.label(title, size: 13, weight: .semibold)
        var lines: [NSView] = [titleLabel]
        if let detail {
            let detailLabel = Design.wrapping(detail, size: 12)
            detailLabel.preferredMaxLayoutWidth = 300
            lines.append(detailLabel)
        }
        let row = Design.hstack([Design.symbol(style.symbol, size: 17, weight: .medium, color: style.tint),
                                 Design.vstack(lines, spacing: 2)], spacing: 10)
        row.alignment = detail == nil ? .centerY : .top
        row.translatesAutoresizingMaskIntoConstraints = false
        material.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: material.leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: material.trailingAnchor, constant: -16),
            row.topAnchor.constraint(equalTo: material.topAnchor, constant: 11),
            row.bottomAnchor.constraint(equalTo: material.bottomAnchor, constant: -11),
            material.widthAnchor.constraint(lessThanOrEqualToConstant: 360)
        ])
        panel.contentView = material
        let size = material.fittingSize
        let point = anchor.map { NSPoint(x: $0.midX, y: $0.minY - 8) } ?? NSPoint(x: NSEvent.mouseLocation.x, y: NSEvent.mouseLocation.y - 24)
        let screen: NSScreen? = ScreenGeometry.screen(at: point)
        var frame = NSRect(x: point.x - size.width / 2, y: point.y - size.height, width: size.width, height: size.height)
        if let visible = screen?.visibleFrame.insetBy(dx: 12, dy: 12) {
            frame.origin.x = max(visible.minX, min(frame.minX, visible.maxX - frame.width))
            frame.origin.y = max(visible.minY, min(frame.minY, visible.maxY - frame.height))
        }
        panel.setFrame(frame, display: true)
        panel.invalidateShadow()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 1 }
        self.panel = panel
        let work = DispatchWorkItem { [weak self] in self?.dismiss(animated: true) }
        dismissal = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (detail == nil ? 2.2 : 4), execute: work)
    }

    func dismiss(animated: Bool) {
        dismissal?.cancel()
        guard let panel else { return }
        self.panel = nil
        guard animated else { panel.orderOut(nil); return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; panel.animator().alphaValue = 0 },
                                             completionHandler: { panel.orderOut(nil) })
    }
}
