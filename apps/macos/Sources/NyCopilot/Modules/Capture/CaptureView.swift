import AppKit

/// What the user chose to do with a capture.
enum CaptureAction { case copy, save, quickSave, pin }

/// The interactive layer of one display during a capture: dims the frozen screen, highlights the
/// window under the pointer, lets you drag or adjust a selection, shows a magnifier, and draws
/// annotations. Coordinates are points with a top-left origin (the view is flipped).
@MainActor
final class CaptureView: NSView, NSTextFieldDelegate {
    var onFinish: ((CaptureAction) -> Void)?
    var onCancel: (() -> Void)?
    /// Another display's view took the selection; this one just stays dimmed.
    var onSelectionStarted: (() -> Void)?
    /// C over a pixel copies its color as #RRGGBB.
    var onColorCopied: ((String) -> Void)?

    let frozen: FrozenScreen
    private(set) var selection: CGRect?
    private(set) var annotations: [Annotation] = []
    private var redoStack: [Annotation] = []
    private var hoverWindow: CGRect?
    private var pointer: CGPoint?
    private var drag: Drag = .none
    private var current: Annotation?
    private var textField: NSTextField?
    private var recentIndex = -1
    private let recent: [CGRect]
    private lazy var pixelated = CaptureRenderer.pixelate(frozen.image, blockSize: 12 * frozen.scale)
    private let toolbar: CaptureToolbar
    var isPassive = false { didSet { hoverWindow = nil; needsDisplay = true } }

    var tool: AnnotationTool? { didSet { toolbar.selectedTool = tool; window?.invalidateCursorRects(for: self) } }
    var color: NSColor { didSet { toolbar.selectedColor = color } }
    var stroke: CGFloat { didSet { toolbar.selectedStroke = stroke } }

    private enum Drag {
        case none, creating(CGPoint), moving(CGPoint, CGRect), resizing(Handle, CGRect), drawing
    }
    private enum Handle: CaseIterable { case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left }

    init(frozen: FrozenScreen, recent: [CGRect], palette: [NSColor], color: NSColor, stroke: CGFloat,
         onStyleChange: @escaping (NSColor, CGFloat) -> Void) {
        self.frozen = frozen
        self.recent = recent
        self.color = color
        self.stroke = stroke
        toolbar = CaptureToolbar(palette: palette)
        super.init(frame: CGRect(origin: .zero, size: frozen.screen.frame.size))
        toolbar.isHidden = true
        toolbar.selectedColor = color
        toolbar.selectedStroke = stroke
        toolbar.onTool = { [weak self] tool in self?.tool = self?.tool == tool ? nil : tool }
        toolbar.onColor = { [weak self] color in
            guard let self else { return }
            self.color = color
            onStyleChange(color, stroke)
        }
        toolbar.onStroke = { [weak self] stroke in
            guard let self else { return }
            self.stroke = stroke
            onStyleChange(color, stroke)
        }
        toolbar.onUndo = { [weak self] in self?.undo() }
        toolbar.onRedo = { [weak self] in self?.redo() }
        toolbar.onAction = { [weak self] action in self?.finish(action) }
        toolbar.onCancel = { [weak self] in self?.onCancel?() }
        addSubview(toolbar)
    }

    required init?(coder: NSCoder) { fatalError("Use init(frozen:…)") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let dim = NSColor.black.withAlphaComponent(selection == nil ? 0.28 : 0.45)
        let focus = selection ?? (isPassive ? nil : hoverWindow)
        let shade = NSBezierPath(rect: bounds)
        if let focus { shade.append(NSBezierPath(rect: focus)) }
        shade.windingRule = .evenOdd
        dim.setFill()
        shade.fill()

        if let selection {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: selection).addClip()
            for annotation in annotations { annotation.draw(pixelated: pixelated, imageFrame: bounds) }
            current?.draw(pixelated: pixelated, imageFrame: bounds)
            NSGraphicsContext.restoreGraphicsState()
            drawFrame(selection, handles: tool == nil)
            drawSizeLabel(for: selection)
        } else if let hoverWindow, !isPassive {
            drawFrame(hoverWindow, handles: false)
        }
        if showsMagnifier, let pointer { drawMagnifier(at: pointer) }
    }

    private var showsMagnifier: Bool {
        guard !isPassive, textField == nil else { return false }
        switch drag {
        case .creating, .resizing: return true
        case .none: return selection == nil
        default: return false
        }
    }

    private func drawFrame(_ rect: CGRect, handles: Bool) {
        NSColor.controlAccentColor.setStroke()
        let border = NSBezierPath(rect: rect.insetBy(dx: -0.5, dy: -0.5))
        border.lineWidth = 1.5
        border.stroke()
        guard handles else { return }
        for handle in Handle.allCases {
            let dot = NSBezierPath(ovalIn: CGRect(center: point(of: handle, in: rect), size: 7))
            NSColor.white.setFill()
            dot.fill()
            NSColor.controlAccentColor.setStroke()
            dot.lineWidth = 1.5
            dot.stroke()
        }
    }

    private func drawSizeLabel(for rect: CGRect) {
        let text = "\(Int(rect.width * frozen.scale)) × \(Int(rect.height * frozen.scale))" as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                                                          .foregroundColor: NSColor.white]
        let size = text.size(withAttributes: attributes)
        var origin = CGPoint(x: rect.minX, y: rect.minY - size.height - 10)
        if origin.y < 4 { origin.y = rect.minY + 6; origin.x += 6 }
        let plate = CGRect(x: origin.x, y: origin.y, width: size.width + 12, height: size.height + 6)
        NSColor.black.withAlphaComponent(0.65).setFill()
        NSBezierPath(roundedRect: plate, xRadius: 5, yRadius: 5).fill()
        text.draw(at: CGPoint(x: plate.minX + 6, y: plate.minY + 3), withAttributes: attributes)
    }

    /// A pixel-exact zoom of the area under the pointer, its position, and its color.
    private func drawMagnifier(at point: CGPoint) {
        let zoom: CGFloat = 8, span: CGFloat = 15
        let box = CGSize(width: span * zoom, height: span * zoom)
        var origin = CGPoint(x: point.x + 20, y: point.y + 20)
        if origin.x + box.width > bounds.maxX - 8 { origin.x = point.x - 20 - box.width }
        if origin.y + box.height + 44 > bounds.maxY - 8 { origin.y = point.y - 20 - box.height - 44 }
        let frame = CGRect(origin: origin, size: box)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let scale = frozen.scale
        let source = CGRect(x: (point.x - span / 2) * scale, y: (point.y - span / 2) * scale, width: span * scale, height: span * scale)
        context.saveGState()
        NSBezierPath(roundedRect: frame, xRadius: 8, yRadius: 8).addClip()
        NSColor.black.setFill()
        frame.fill()
        if let crop = frozen.image.cropping(to: source.integral) {
            context.interpolationQuality = .none
            context.translateBy(x: frame.minX, y: frame.maxY)
            context.scaleBy(x: 1, y: -1)
            context.draw(crop, in: CGRect(origin: .zero, size: box))
        }
        context.restoreGState()
        // Crosshair over the center pixel.
        NSColor.controlAccentColor.withAlphaComponent(0.8).setFill()
        CGRect(x: frame.midX - zoom / 2, y: frame.minY, width: zoom, height: frame.height).fill(using: .sourceOver)
        CGRect(x: frame.minX, y: frame.midY - zoom / 2, width: frame.width, height: zoom).fill(using: .sourceOver)
        NSColor.white.withAlphaComponent(0.9).setStroke()
        let ring = NSBezierPath(roundedRect: frame, xRadius: 8, yRadius: 8)
        ring.lineWidth = 2
        ring.stroke()

        let hex = colorHex(at: point) ?? "—"
        let info = "\(Int(point.x * scale)), \(Int(point.y * scale))   \(hex)\nC copies the color" as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                                                          .foregroundColor: NSColor.white]
        let plate = CGRect(x: frame.minX, y: frame.maxY + 4, width: frame.width, height: 38)
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: plate, xRadius: 6, yRadius: 6).fill()
        if let swatch = color(at: point) {
            swatch.setFill()
            NSBezierPath(roundedRect: CGRect(x: plate.minX + 8, y: plate.minY + 7, width: 10, height: 10), xRadius: 2, yRadius: 2).fill()
        }
        info.draw(in: plate.insetBy(dx: 8, dy: 4).offsetBy(dx: 16, dy: 0), withAttributes: attributes)
    }

    // MARK: Pixels

    func color(at point: CGPoint) -> NSColor? {
        let scale = frozen.scale
        let pixel = CGRect(x: floor(point.x * scale), y: floor(point.y * scale), width: 1, height: 1)
        guard let crop = frozen.image.cropping(to: pixel), let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var bytes = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return NSColor(srgbRed: CGFloat(bytes[0]) / 255, green: CGFloat(bytes[1]) / 255, blue: CGFloat(bytes[2]) / 255, alpha: 1)
    }

    private func colorHex(at point: CGPoint) -> String? {
        guard let color = color(at: point) else { return nil }
        return String(format: "#%02X%02X%02X", Int(round(color.redComponent * 255)), Int(round(color.greenComponent * 255)),
                      Int(round(color.blueComponent * 255)))
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        pointer = point
        if selection == nil, !isPassive { hoverWindow = frozen.windows.first { $0.contains(point) } }
        updateCursor(at: point)
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        pointer = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if textField != nil { commitText() }
        if isPassive { return }
        if event.clickCount == 2, let selection, selection.contains(point), tool == nil {
            finish(.copy)
            return
        }
        guard let selection else {
            drag = .creating(point)
            onSelectionStarted?()
            return
        }
        if let tool, selection.contains(point) {
            if tool == .text { beginText(at: point); return }
            current = Annotation(tool: tool, points: [point], color: color, width: stroke)
            drag = .drawing
        } else if tool == nil, let handle = handle(at: point, in: selection) {
            drag = .resizing(handle, selection)
        } else if tool == nil, selection.contains(point) {
            drag = .moving(point, selection)
        } else if annotations.isEmpty, tool == nil {
            // A fresh drag outside an untouched selection starts over.
            self.selection = nil
            toolbar.isHidden = true
            drag = .creating(point)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = clamp(convert(event.locationInWindow, from: nil))
        pointer = point
        switch drag {
        case .creating(let start):
            selection = CGRect(corners: start, point)
            toolbar.isHidden = true
        case .moving(let start, let original):
            var moved = original.offsetBy(dx: point.x - start.x, dy: point.y - start.y)
            moved.origin.x = min(max(moved.minX, 0), bounds.width - moved.width)
            moved.origin.y = min(max(moved.minY, 0), bounds.height - moved.height)
            selection = moved
            placeToolbar()
        case .resizing(let handle, let original):
            selection = resized(original, handle: handle, to: point)
            placeToolbar()
        case .drawing:
            guard var mark = current else { break }
            // Freehand tools collect every point; shapes keep their start and follow the pointer.
            if mark.tool.isFreehand { mark.points.append(point) } else { mark.points = [mark.points[0], point] }
            current = mark
        case .none:
            break
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        switch drag {
        case .creating:
            if let rect = selection, rect.width >= 4, rect.height >= 4 {
                selection = rect.integral
            } else {
                // A click without a drag takes the highlighted window (or nothing).
                selection = hoverWindow
            }
            hoverWindow = nil
            placeToolbar()
        case .drawing:
            if var finished = current, finished.points.count > 1 || finished.tool.isFreehand {
                if finished.points.count == 1 { finished.points.append(finished.points[0]) }
                annotations.append(finished)
                redoStack.removeAll()
                toolbar.canUndo = true
                toolbar.canRedo = false
            }
            current = nil
        default:
            break
        }
        drag = .none
        needsDisplay = true
    }

    override func rightMouseDown(with event: NSEvent) {
        if textField != nil { cancelText() }
        else if tool != nil { tool = nil }
        else if selection != nil, annotations.isEmpty { clearSelection() }
        else { onCancel?() }
    }

    private func clamp(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(point.x, 0), bounds.width), y: min(max(point.y, 0), bounds.height))
    }

    private func clearSelection() {
        selection = nil
        toolbar.isHidden = true
        tool = nil
        needsDisplay = true
    }

    // MARK: Handles

    private func point(of handle: Handle, in rect: CGRect) -> CGPoint {
        switch handle {
        case .topLeft: return CGPoint(x: rect.minX, y: rect.minY)
        case .top: return CGPoint(x: rect.midX, y: rect.minY)
        case .topRight: return CGPoint(x: rect.maxX, y: rect.minY)
        case .right: return CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomRight: return CGPoint(x: rect.maxX, y: rect.maxY)
        case .bottom: return CGPoint(x: rect.midX, y: rect.maxY)
        case .bottomLeft: return CGPoint(x: rect.minX, y: rect.maxY)
        case .left: return CGPoint(x: rect.minX, y: rect.midY)
        }
    }

    private func handle(at point: CGPoint, in rect: CGRect) -> Handle? {
        Handle.allCases.first { CGRect(center: self.point(of: $0, in: rect), size: 14).contains(point) }
    }

    private func resized(_ rect: CGRect, handle: Handle, to point: CGPoint) -> CGRect {
        var minX = rect.minX, minY = rect.minY, maxX = rect.maxX, maxY = rect.maxY
        switch handle {
        case .topLeft: minX = point.x; minY = point.y
        case .top: minY = point.y
        case .topRight: maxX = point.x; minY = point.y
        case .right: maxX = point.x
        case .bottomRight: maxX = point.x; maxY = point.y
        case .bottom: maxY = point.y
        case .bottomLeft: minX = point.x; maxY = point.y
        case .left: minX = point.x
        }
        return CGRect(corners: CGPoint(x: minX, y: minY), CGPoint(x: maxX, y: maxY)).integral
    }

    private func updateCursor(at point: CGPoint) {
        guard let selection else { NSCursor.crosshair.set(); return }
        if tool != nil { (selection.contains(point) ? (tool == .text ? NSCursor.iBeam : NSCursor.crosshair) : NSCursor.arrow).set() }
        else if let handle = handle(at: point, in: selection) {
            switch handle {
            case .left, .right: NSCursor.resizeLeftRight.set()
            case .top, .bottom: NSCursor.resizeUpDown.set()
            default: NSCursor.crosshair.set()
            }
        } else if selection.contains(point) { NSCursor.openHand.set() }
        else { NSCursor.arrow.set() }
    }

    // MARK: Toolbar

    /// Below the selection, right-aligned; above it when there is no room; inside as a last resort.
    private func placeToolbar() {
        guard let selection, selection.width >= 4, selection.height >= 4 else { toolbar.isHidden = true; return }
        toolbar.isHidden = false
        let size = toolbar.fittingSize
        var origin = CGPoint(x: selection.maxX - size.width, y: selection.maxY + 8)
        if origin.y + size.height > bounds.maxY - 8 { origin.y = selection.minY - size.height - 8 }
        if origin.y < 8 { origin.y = selection.maxY - size.height - 8 }
        origin.x = min(max(origin.x, 8), bounds.maxX - size.width - 8)
        toolbar.frame = CGRect(origin: origin, size: size)
    }

    // MARK: Text

    private func beginText(at point: CGPoint) {
        let font = NSFont.systemFont(ofSize: 12 + stroke * 2, weight: .medium)
        let field = NSTextField(frame: CGRect(x: point.x, y: point.y, width: 240, height: font.pointSize + 8))
        field.font = font
        field.textColor = color
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.placeholderString = "Text"
        field.delegate = self
        field.cell?.isScrollable = true
        addSubview(field)
        window?.makeFirstResponder(field)
        textField = field
    }

    func controlTextDidEndEditing(_ obj: Notification) { commitText() }

    private func commitText() {
        guard let field = textField else { return }
        textField = nil
        let text = field.stringValue
        field.removeFromSuperview()
        window?.makeFirstResponder(self)
        guard !text.isEmpty else { return }
        annotations.append(Annotation(tool: .text, points: [field.frame.origin], color: field.textColor ?? color,
                                      width: stroke, text: text, font: field.font ?? .systemFont(ofSize: 18)))
        redoStack.removeAll()
        toolbar.canUndo = true
        toolbar.canRedo = false
        needsDisplay = true
    }

    private func cancelText() {
        textField?.removeFromSuperview()
        textField = nil
        window?.makeFirstResponder(self)
    }

    // MARK: Editing

    func undo() {
        guard let last = annotations.popLast() else { return }
        redoStack.append(last)
        toolbar.canUndo = !annotations.isEmpty
        toolbar.canRedo = true
        needsDisplay = true
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        annotations.append(next)
        toolbar.canUndo = true
        toolbar.canRedo = !redoStack.isEmpty
        needsDisplay = true
    }

    private func finish(_ action: CaptureAction) {
        if textField != nil { commitText() }
        guard selection != nil else { return }
        onFinish?(action)
    }

    /// The finished image: selection plus annotations at full resolution.
    func renderedImage() -> NSImage? {
        guard let selection else { return nil }
        return CaptureRenderer.render(frozen, selection: selection, annotations: annotations, pixelated: pixelated)
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        switch (event.keyCode, flags) {
        case (53, _): onCancel?()
        case (36, _), (76, _): finish(.copy)
        case (123...126, _): nudge(event.keyCode, resize: flags.contains(.shift))
        default:
            if flags == [.command] {
                switch key {
                case "c": finish(.copy)
                case "s": finish(.save)
                case "t": finish(.pin)
                case "z": undo()
                case "a": selectAll()
                default: super.keyDown(with: event)
                }
            } else if flags == [.command, .shift] {
                switch key {
                case "s": finish(.quickSave)
                case "z": redo()
                default: super.keyDown(with: event)
                }
            } else if flags.isEmpty {
                switch key {
                case "c" where selection == nil: copyColor()
                case ",": stepRecent(by: 1)
                case ".": stepRecent(by: -1)
                case "1", "2", "3", "4", "5", "6", "7", "8":
                    guard selection != nil, let index = Int(key) else { break }
                    let picked = AnnotationTool.allCases[index - 1]
                    tool = tool == picked ? nil : picked
                default: super.keyDown(with: event)
                }
            } else {
                super.keyDown(with: event)
            }
        }
    }

    /// Arrow keys move the selection one point; with Shift they grow or shrink it.
    private func nudge(_ keyCode: UInt16, resize: Bool) {
        guard var rect = selection, tool == nil else {
            // Before selecting, arrows move the pointer for pixel-precise starts.
            if selection == nil, let pointer {
                let delta: CGPoint = keyCode == 123 ? CGPoint(x: -1, y: 0) : keyCode == 124 ? CGPoint(x: 1, y: 0)
                    : keyCode == 125 ? CGPoint(x: 0, y: 1) : CGPoint(x: 0, y: -1)
                let moved = clamp(CGPoint(x: pointer.x + delta.x, y: pointer.y + delta.y))
                if let window {
                    let screenPoint = window.convertPoint(toScreen: convert(moved, to: nil))
                    let top = NSScreen.screens.first?.frame.maxY ?? 0
                    CGWarpMouseCursorPosition(CGPoint(x: screenPoint.x, y: top - screenPoint.y))
                }
                self.pointer = moved
                needsDisplay = true
            }
            return
        }
        switch (keyCode, resize) {
        case (123, false): rect.origin.x -= 1
        case (124, false): rect.origin.x += 1
        case (125, false): rect.origin.y += 1
        case (126, false): rect.origin.y -= 1
        case (123, true): rect.size.width = max(4, rect.width - 1)
        case (124, true): rect.size.width += 1
        case (125, true): rect.size.height += 1
        case (126, true): rect.size.height = max(4, rect.height - 1)
        default: break
        }
        selection = rect.intersection(bounds)
        placeToolbar()
        needsDisplay = true
    }

    private func selectAll() {
        guard annotations.isEmpty else { return }
        onSelectionStarted?()
        selection = bounds
        hoverWindow = nil
        placeToolbar()
        needsDisplay = true
    }

    /// `,` and `.` step back and forth through regions captured before.
    private func stepRecent(by step: Int) {
        guard annotations.isEmpty, !recent.isEmpty else { return }
        recentIndex = min(max(recentIndex + step, 0), recent.count - 1)
        onSelectionStarted?()
        selection = recent[recentIndex]
        placeToolbar()
        needsDisplay = true
    }

    private func copyColor() {
        guard let pointer, let hex = colorHex(at: pointer) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(hex, forType: .string)
        onColorCopied?(hex)
    }
}

/// Borderless, above everything including the menu bar, and able to take keys.
final class CaptureWindow: NSPanel {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = true
        hasShadow = false
        backgroundColor = .black
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

extension CGRect {
    init(center: CGPoint, size: CGFloat) {
        self.init(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)
    }

    init(corners a: CGPoint, _ b: CGPoint) {
        self.init(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }
}
