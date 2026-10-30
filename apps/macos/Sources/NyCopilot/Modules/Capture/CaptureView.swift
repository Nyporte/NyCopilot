import AppKit
import VisionKit

/// What the user chose to do with a capture.
enum CaptureAction { case copy, save, quickSave, pin, scroll, translate }

/// The interactive layer of one display during a capture: dims the frozen screen, highlights the
/// window under the pointer, lets you drag or adjust a selection, shows a magnifier, and draws
/// annotations. Coordinates are points with a top-left origin (the view is flipped).
@MainActor
final class CaptureView: NSView, NSTextViewDelegate {
    var onFinish: ((CaptureAction) -> Void)?
    var onCancel: (() -> Void)?
    /// Another display's view took the selection; this one just stays dimmed.
    var onSelectionStarted: (() -> Void)?
    /// Copy All in Live Text: the text is on the clipboard; the capture can close.
    var onTextCopied: ((Int) -> Void)?

    let frozen: FrozenScreen
    private(set) var selection: CGRect?
    private(set) var annotations: [Annotation] = []
    private var redoStack: [Annotation] = []
    /// What a click would take: the element under the pointer and each container up to its window,
    /// smallest first; scrolling picks a larger or smaller one.
    private var hoverCandidates: [CGRect] = []
    private var hoverLevel = 0
    private var hoverPID: pid_t = 0
    private var scrollCredit: CGFloat = 0
    private var hoverWindow: CGRect? {
        get { hoverCandidates.indices.contains(hoverLevel) ? hoverCandidates[hoverLevel] : nil }
        set { hoverCandidates = newValue.map { [$0] } ?? []; hoverLevel = 0 }
    }
    private var pointer: CGPoint?
    private var drag: Drag = .none
    private var current: Annotation?
    private var textEditor: TextAnnotationEditor?
    private var recentIndex = -1
    private var analysis: (rect: CGRect, task: Task<ImageAnalysis, Error>)?
    private var pendingAnalysis: DispatchWorkItem?
    private var textOverlay: ImageAnalysisOverlayView?
    private var copyWhenRead = false
    private let textBar = CaptureTextBar()
    /// Which format C copies; Shift switches between HEX and RGB.
    private var copiesHex = true
    /// "Copied …" shown briefly in the magnifier after C.
    private var copiedFlash: String?
    private var clearFlash: DispatchWorkItem?
    private var shiftWasDown = false
    private let recent: [CGRect]
    private lazy var pixelated = CaptureRenderer.pixelate(frozen.image, blockSize: 12 * frozen.scale)
    private let toolbar: CaptureToolbar
    /// Another display has the selection. Becoming the active one keeps what's outlined, so the
    /// click that started it can still take it.
    var isPassive = false {
        didSet {
            guard isPassive != oldValue else { return }
            if isPassive { hoverWindow = nil }
            needsDisplay = true
        }
    }

    var tool: AnnotationTool? {
        didSet {
            if tool != .text, textEditor != nil { commitText() }
            toolbar.selectedTool = tool
            // Each tool has its own options row, so the bar changes size.
            if !toolbar.isHidden { placeToolbar() }
            window?.invalidateCursorRects(for: self)
        }
    }
    var color: NSColor { didSet { toolbar.selectedColor = color; textEditor?.apply(style, color: color) } }
    var stroke: CGFloat { didSet { toolbar.selectedStroke = stroke } }
    var style: CaptureStyle { didSet { toolbar.style = style; textEditor?.apply(style, color: color); needsDisplay = true } }
    private let onStyleChange: (NSColor, CGFloat, CaptureStyle) -> Void

    private enum Drag {
        case none, creating(CGPoint), moving(CGPoint, CGRect), resizing(Handle, CGRect), drawing
    }
    private enum Handle: CaseIterable { case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left }

    init(frozen: FrozenScreen, recent: [CGRect], palette: [NSColor], color: NSColor, stroke: CGFloat, style: CaptureStyle,
         onStyleChange: @escaping (NSColor, CGFloat, CaptureStyle) -> Void) {
        self.frozen = frozen
        self.recent = recent
        self.color = color
        self.stroke = stroke
        self.style = style
        self.onStyleChange = onStyleChange
        toolbar = CaptureToolbar(palette: palette)
        super.init(frame: CGRect(origin: .zero, size: frozen.screen.frame.size))
        toolbar.isHidden = true
        toolbar.selectedColor = color
        toolbar.selectedStroke = stroke
        toolbar.style = style
        toolbar.onTool = { [weak self] tool in self?.tool = self?.tool == tool ? nil : tool }
        toolbar.onColor = { [weak self] color in
            self?.color = color
            self?.styleChanged()
        }
        toolbar.onStroke = { [weak self] stroke in
            self?.stroke = stroke
            self?.styleChanged()
        }
        toolbar.onStyle = { [weak self] style in
            self?.style = style
            self?.styleChanged()
            // Keep typing after picking a font or size.
            if let editor = self?.textEditor { self?.window?.makeFirstResponder(editor) }
        }
        toolbar.onUndo = { [weak self] in self?.undo() }
        toolbar.onRedo = { [weak self] in self?.redo() }
        toolbar.onAction = { [weak self] action in self?.finish(action) }
        toolbar.onCancel = { [weak self] in self?.onCancel?() }
        toolbar.onText = { [weak self] in self?.beginReadingText() }
        addSubview(toolbar)
        textBar.isHidden = true
        textBar.onCopyAll = { [weak self] in self?.copyAllText() }
        textBar.onDone = { [weak self] in self?.endReadingText() }
        addSubview(textBar)
    }

    required init?(coder: NSCoder) { fatalError("Use init(frozen:…)") }

    private func styleChanged() { onStyleChange(color, stroke, style) }

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
            drawFrame(selection, handles: tool == nil && !isReadingText)
            drawSizeLabel(for: selection)
            if let textEditor { drawEditorFrame(textEditor.frame) }
        } else if let hoverWindow, !isPassive {
            drawFrame(hoverWindow, handles: false)
            drawSizeLabel(for: hoverWindow, note: hoverCandidates.count > 1 ? "scroll ↕ to resize" : nil)
        }
        if showsMagnifier, let pointer { drawMagnifier(at: pointer) }
    }

    private var showsMagnifier: Bool {
        guard !isPassive, textEditor == nil else { return false }
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

    private func drawSizeLabel(for rect: CGRect, note: String? = nil) {
        let dimensions = "\(Int(rect.width * frozen.scale)) × \(Int(rect.height * frozen.scale))"
        let text = (note.map { "\(dimensions)  ·  \($0)" } ?? dimensions) as NSString
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

    /// A pixel-exact zoom of the area under the pointer with a pixel grid, then the pointer's position,
    /// the selection size while dragging, the color in HEX and RGB (the format C copies is
    /// highlighted), and the keys that act on it.
    private func drawMagnifier(at point: CGPoint) {
        let zoom: CGFloat = 8, span: CGFloat = 17
        let box = CGSize(width: span * zoom, height: span * zoom)
        let panelHeight: CGFloat = isSizing ? 98 : 82
        var origin = CGPoint(x: point.x + 20, y: point.y + 20)
        if origin.x + box.width > bounds.maxX - 8 { origin.x = point.x - 20 - box.width }
        if origin.y + box.height + panelHeight + 4 > bounds.maxY - 8 { origin.y = point.y - 20 - box.height - panelHeight - 4 }
        let frame = CGRect(origin: origin, size: box)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let scale = frozen.scale
        // Whole pixels around the pointer, so every cell in the grid is exactly one screen pixel.
        let center = CGPoint(x: floor(point.x * scale), y: floor(point.y * scale))
        let half = floor(span / 2)
        let source = CGRect(x: center.x - half, y: center.y - half, width: span, height: span)
        context.saveGState()
        NSBezierPath(roundedRect: frame, xRadius: 8, yRadius: 8).addClip()
        NSColor.black.setFill()
        frame.fill()
        if let crop = frozen.image.cropping(to: source) {
            context.interpolationQuality = .none
            context.translateBy(x: frame.minX, y: frame.maxY)
            context.scaleBy(x: 1, y: -1)
            context.draw(crop, in: CGRect(origin: .zero, size: box))
            context.scaleBy(x: 1, y: -1)
            context.translateBy(x: -frame.minX, y: -frame.maxY)
        }
        NSColor.white.withAlphaComponent(0.08).setFill()
        for index in 1..<Int(span) {
            let offset = CGFloat(index) * zoom
            CGRect(x: frame.minX + offset, y: frame.minY, width: 0.5, height: frame.height).fill(using: .sourceOver)
            CGRect(x: frame.minX, y: frame.minY + offset, width: frame.width, height: 0.5).fill(using: .sourceOver)
        }
        context.restoreGState()
        // The pixel the pointer is on, outlined.
        let cell = CGRect(x: frame.minX + half * zoom, y: frame.minY + half * zoom, width: zoom, height: zoom)
        NSColor.white.setStroke()
        NSBezierPath(rect: cell.insetBy(dx: -0.5, dy: -0.5)).stroke()
        NSColor.white.withAlphaComponent(0.9).setStroke()
        let ring = NSBezierPath(roundedRect: frame, xRadius: 8, yRadius: 8)
        ring.lineWidth = 2
        ring.stroke()

        let plate = CGRect(x: frame.minX, y: frame.maxY + 4, width: frame.width, height: panelHeight)
        NSColor.black.withAlphaComponent(0.78).setFill()
        NSBezierPath(roundedRect: plate, xRadius: 7, yRadius: 7).fill()
        let mono = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        let bold = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        let dim = NSColor.white.withAlphaComponent(0.55)
        var y = plate.minY + 6
        func line(_ text: String, font: NSFont = mono, color: NSColor = .white, indent: CGFloat = 0) {
            (text as NSString).draw(at: CGPoint(x: plate.minX + 9 + indent, y: y), withAttributes: [.font: font, .foregroundColor: color])
            y += 15
        }
        line("X \(Int(center.x))   Y \(Int(center.y))")
        if isSizing, let selection { line("\(Int((selection.width * scale).rounded())) × \(Int((selection.height * scale).rounded())) px") }
        if let swatch = color(at: point) {
            swatch.setFill()
            NSBezierPath(roundedRect: CGRect(x: plate.minX + 9, y: y + 2, width: 11, height: 11), xRadius: 2, yRadius: 2).fill()
            line(swatch.hexString, font: copiesHex ? bold : mono, color: copiesHex ? .white : dim, indent: 17)
            line(Self.rgb(swatch), font: copiesHex ? mono : bold, color: copiesHex ? dim : .white, indent: 17)
        }
        line(copiedFlash ?? "C copy  ·  ⇧ switch format", font: .systemFont(ofSize: 10.5, weight: copiedFlash == nil ? .regular : .semibold),
             color: copiedFlash == nil ? dim : .systemGreen)
    }

    /// Dragging out or resizing a selection: the magnifier also shows its size.
    private var isSizing: Bool {
        switch drag {
        case .creating, .resizing: return true
        default: return false
        }
    }

    private static func rgb(_ color: NSColor) -> String {
        "RGB \(Int(round(color.redComponent * 255))), \(Int(round(color.greenComponent * 255))), \(Int(round(color.blueComponent * 255)))"
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
        if selection == nil, !isPassive { hover(at: point) }
        updateCursor(at: point)
        needsDisplay = true
    }

    /// Outlines what's under the pointer as soon as the capture opens, before it moves.
    func hoverAtPointer() {
        guard let window else { return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard bounds.contains(point) else { return }
        pointer = point
        if selection == nil, !isPassive { hover(at: point) }
        needsDisplay = true
    }

    /// The window under the pointer at once, then the element within it once the app answers.
    private func hover(at point: CGPoint) {
        guard let window = frozen.windows.first(where: { $0.rect.contains(point) }) else { hoverWindow = nil; return }
        // Moving within what's outlined keeps it until the app says otherwise; a new window shows at once.
        if hoverPID != window.pid || !(hoverCandidates.last.map { $0 == window.rect } ?? false) || !(hoverWindow?.contains(point) ?? false) {
            hoverWindow = window.rect
        }
        hoverPID = window.pid
        let origin = CaptureSession.globalOrigin(of: frozen.screen)
        let global = FrozenScreen.Window(rect: window.rect.offsetBy(dx: origin.x, dy: origin.y), pid: window.pid)
        ElementFinder.shared.find(at: CGPoint(x: point.x + origin.x, y: point.y + origin.y), in: global) { [weak self] rects in
            guard let self, selection == nil, !isPassive, let pointer, window.rect.contains(pointer) else { return }
            let local = rects.map { $0.offsetBy(dx: -origin.x, dy: -origin.y) }.filter { $0.contains(pointer) || $0 == window.rect }
            guard !local.isEmpty else { return }
            // Keep the size chosen by scrolling when it's still on offer; else the smallest real control.
            let shown = hoverWindow
            hoverCandidates = local
            hoverLevel = shown.flatMap { previous in local.firstIndex { $0 == previous } }
                ?? local.firstIndex { $0.width >= 20 && $0.height >= 14 } ?? local.count - 1
            needsDisplay = true
        }
    }

    /// Scrolling while nothing is selected: up for the containing element, down for a smaller one.
    override func scrollWheel(with event: NSEvent) {
        guard selection == nil, !isPassive, hoverCandidates.count > 1 else { super.scrollWheel(with: event); return }
        let delta = event.scrollingDeltaY * (event.isDirectionInvertedFromDevice ? -1 : 1)
        scrollCredit += event.hasPreciseScrollingDeltas ? delta : delta * 10
        while abs(scrollCredit) >= 10 {
            let step = scrollCredit > 0 ? 1 : -1
            hoverLevel = min(max(hoverLevel + step, 0), hoverCandidates.count - 1)
            scrollCredit -= CGFloat(step) * 10
        }
        if event.phase == .ended || event.momentumPhase == .ended { scrollCredit = 0 }
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        pointer = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if textEditor != nil { commitText(); if tool == .text { return } }
        // Reading text: the overlay takes clicks on the selection; nothing else changes it.
        if isPassive || isReadingText { return }
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
            current = Annotation(tool: tool, points: [point], color: color, width: stroke, style: style)
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
            selection = snapped(CGRect(corners: start, point))
            toolbar.isHidden = true
        case .moving(let start, let original):
            var moved = original.offsetBy(dx: point.x - start.x, dy: point.y - start.y)
            moved.origin.x = min(max(moved.minX, 0), bounds.width - moved.width)
            moved.origin.y = min(max(moved.minY, 0), bounds.height - moved.height)
            selection = snapped(moved)
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
            // The selection is already on pixel boundaries; keeping it as is means the size shown
            // while dragging is exactly the size captured.
            if let rect = selection, rect.width >= 4, rect.height >= 4 {
                selection = rect
            } else {
                // A click without a drag takes the highlighted window (or nothing).
                selection = hoverWindow
            }
            hoverWindow = nil
            placeToolbar()
            selectionSettled()
        case .moving, .resizing:
            selectionSettled()
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
        if isReadingText { endReadingText() }
        else if textEditor != nil { cancelText() }
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
        return snapped(CGRect(corners: CGPoint(x: minX, y: minY), CGPoint(x: maxX, y: maxY)))
    }

    /// Each edge to its nearest pixel. Rounding outward (`integral`) grew selections by a point —
    /// two pixels on Retina — whenever the pointer sat between pixels.
    private func snapped(_ rect: CGRect) -> CGRect {
        let scale = frozen.scale
        func pixel(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
        return CGRect(corners: CGPoint(x: pixel(rect.minX), y: pixel(rect.minY)), CGPoint(x: pixel(rect.maxX), y: pixel(rect.maxY)))
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

    private func placeToolbar() {
        guard let selection, selection.width >= 4, selection.height >= 4, !isReadingText else { toolbar.isHidden = true; return }
        toolbar.isHidden = false
        place(toolbar)
    }

    /// Below the selection, right-aligned; above it when there is no room; inside as a last resort.
    private func place(_ bar: NSView) {
        guard let selection else { return }
        bar.isHidden = false
        let size = bar.fittingSize
        var origin = CGPoint(x: selection.maxX - size.width, y: selection.maxY + 8)
        if origin.y + size.height > bounds.maxY - 8 { origin.y = selection.minY - size.height - 8 }
        if origin.y < 8 { origin.y = selection.maxY - size.height - 8 }
        origin.x = min(max(origin.x, 8), bounds.maxX - size.width - 8)
        bar.frame = CGRect(origin: origin, size: size)
    }

    // MARK: Text

    /// A borderless, growing text view styled like the finished annotation, so what you type is
    /// exactly what gets drawn. Return commits, Shift+Return adds a line, Esc discards.
    private func beginText(at point: CGPoint) {
        let editor = TextAnnotationEditor(origin: point)
        editor.delegate = self
        editor.apply(style, color: color)
        addSubview(editor)
        window?.makeFirstResponder(editor)
        textEditor = editor
        needsDisplay = true
    }

    func textDidChange(_ notification: Notification) {
        textEditor?.fitToText()
        needsDisplay = true
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(insertNewline(_:)) where !(NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false):
            commitText()
            return true
        case #selector(insertNewline(_:)):
            textView.insertNewlineIgnoringFieldEditor(nil)
            return true
        case #selector(cancelOperation(_:)):
            cancelText()
            return true
        default:
            return false
        }
    }

    private func drawEditorFrame(_ frame: CGRect) {
        let box = NSBezierPath(rect: frame.insetBy(dx: -4, dy: -3))
        box.lineWidth = 1
        box.setLineDash([4, 3], count: 2, phase: 0)
        NSColor.white.withAlphaComponent(0.8).setStroke()
        box.stroke()
    }

    private func commitText() {
        guard let editor = textEditor else { return }
        textEditor = nil
        let text = editor.string
        editor.removeFromSuperview()
        window?.makeFirstResponder(self)
        needsDisplay = true
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        annotations.append(Annotation(tool: .text, points: [editor.frame.origin], color: color, width: stroke, style: style, text: text))
        redoStack.removeAll()
        toolbar.canUndo = true
        toolbar.canRedo = false
    }

    private func cancelText() {
        textEditor?.removeFromSuperview()
        textEditor = nil
        window?.makeFirstResponder(self)
        needsDisplay = true
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
        if textEditor != nil { commitText() }
        guard selection != nil else { return }
        onFinish?(action)
    }

    // MARK: Live Text

    /// Arrow keys and drags settle many times a second; read the text once things are still.
    private func selectionSettled() {
        pendingAnalysis?.cancel()
        let work = DispatchWorkItem { [weak self] in _ = self?.textAnalysis() }
        pendingAnalysis = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    /// The text in the current selection, read from the screen as it was, so annotations don't get in
    /// the way. Started in the background as soon as the selection settles, so T is instant.
    private func textAnalysis() -> Task<ImageAnalysis, Error>? {
        guard let selection else { return nil }
        if let analysis, analysis.rect == selection { return analysis.task }
        guard let image = CaptureRenderer.render(frozen, selection: selection, annotations: [], pixelated: nil)?
            .cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let task = Task { try await LiveText.analyze(image) }
        analysis = (selection, task)
        toolbar.recognizedLines = nil
        Task { [weak self] in
            let lines = (try? await task.value).map(LiveText.lineCount) ?? 0
            guard let self, analysis?.rect == selection else { return }
            toolbar.recognizedLines = lines
        }
        return task
    }

    var isReadingText: Bool { textOverlay != nil }

    /// T: the selection becomes Live Text — every word selectable right where it is on screen.
    /// T again copies all of it.
    func beginReadingText() {
        guard !isReadingText, let selection, let task = textAnalysis() else { return }
        if textEditor != nil { commitText() }
        tool = nil
        let overlay = LiveText.overlay(frame: selection)
        addSubview(overlay, positioned: .below, relativeTo: toolbar)
        textOverlay = overlay
        toolbar.isHidden = true
        textBar.showReading()
        place(textBar)
        Task { [weak self] in
            let analysis = try? await task.value
            guard let self, textOverlay === overlay else { return }
            LiveText.show(analysis, on: overlay)
            textBar.show(lines: analysis.map(LiveText.lineCount) ?? 0)
            place(textBar)
            if copyWhenRead { copyAllText() }
        }
        needsDisplay = true
    }

    private func endReadingText() {
        copyWhenRead = false
        textOverlay?.removeFromSuperview()
        textOverlay = nil
        textBar.isHidden = true
        placeToolbar()
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    /// ⌘C: the selected words, staying in Live Text.
    private func copySelectedText() {
        guard let overlay = textOverlay, overlay.analysis != nil else { return }
        let text = LiveText.textToCopy(from: overlay)
        guard !text.isEmpty else { return }
        LiveText.copy(text)
        textBar.flash("Copied")
    }

    /// T twice — the left hand never moves — or Return, or Copy All: every line, then the capture
    /// closes. A double tap faster than recognition copies as soon as the text is read.
    private func copyAllText() {
        guard let overlay = textOverlay else { return }
        guard let analysis = overlay.analysis else { copyWhenRead = true; return }
        let transcript = analysis.transcript
        guard !transcript.isEmpty else { textBar.flash("No text to copy"); return }
        LiveText.copy(transcript)
        onTextCopied?(transcript.split(whereSeparator: \.isNewline).count)
    }

    /// Keys while reading text; the overlay passes along whatever it doesn't use itself.
    private func readingTextKeyDown(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        switch (event.keyCode, flags, key) {
        case (53, _, _): endReadingText()
        case (_, [], "t"), (36, _, _), (76, _, _): copyAllText()
        case (_, [.command], "c"): copySelectedText()
        default: break
        }
    }

    /// The finished image: selection plus annotations at full resolution.
    func renderedImage() -> NSImage? {
        guard let selection else { return nil }
        return CaptureRenderer.render(frozen, selection: selection, annotations: annotations, pixelated: pixelated)
    }


    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        if isReadingText { readingTextKeyDown(event); return }
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
                case "c" where showsMagnifier: copyColor()
                case "t" where selection != nil: beginReadingText()
                case "s" where selection != nil: finish(.scroll)
                case "r" where selection != nil: finish(.translate)
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
        selectionSettled()
        needsDisplay = true
    }

    private func selectAll() {
        guard annotations.isEmpty else { return }
        onSelectionStarted?()
        selection = bounds
        hoverWindow = nil
        placeToolbar()
        selectionSettled()
        needsDisplay = true
    }

    /// `,` and `.` step back and forth through regions captured before.
    private func stepRecent(by step: Int) {
        guard annotations.isEmpty, !recent.isEmpty else { return }
        recentIndex = min(max(recentIndex + step, 0), recent.count - 1)
        onSelectionStarted?()
        selection = recent[recentIndex]
        placeToolbar()
        selectionSettled()
        needsDisplay = true
    }

    /// C copies the color under the pointer in the highlighted format; capture carries on.
    private func copyColor() {
        guard let pointer, let swatch = color(at: pointer) else { return }
        let value = copiesHex ? swatch.hexString : Self.rgb(swatch).replacingOccurrences(of: "RGB ", with: "")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        copiedFlash = "Copied \(value)"
        clearFlash?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.copiedFlash = nil
            self?.needsDisplay = true
        }
        clearFlash = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
        needsDisplay = true
    }

    /// Pressing Shift (on its own) switches the color format C copies.
    override func flagsChanged(with event: NSEvent) {
        let shiftDown = event.modifierFlags.contains(.shift)
        if shiftDown, !shiftWasDown, showsMagnifier {
            copiesHex.toggle()
            needsDisplay = true
        }
        shiftWasDown = shiftDown
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

/// The live text box of the text tool. No padding or insets, so its origin is where the committed
/// annotation draws its first line.
@MainActor
final class TextAnnotationEditor: NSTextView {
    init(origin: CGPoint) {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        layout.addTextContainer(container)
        super.init(frame: CGRect(origin: origin, size: CGSize(width: 2, height: 20)), textContainer: container)
        textContainerInset = .zero
        drawsBackground = false
        isRichText = false
        allowsUndo = true
        isHorizontallyResizable = true
        isVerticallyResizable = true
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        focusRingType = .none
    }

    override init(frame: NSRect, textContainer: NSTextContainer?) { super.init(frame: frame, textContainer: textContainer) }
    required init?(coder: NSCoder) { fatalError("Use init(origin:)") }

    /// Restyles everything typed so far and what comes next.
    func apply(_ style: CaptureStyle, color: NSColor) {
        let attributes = style.textAttributes(color: color)
        typingAttributes = attributes
        insertionPointColor = color
        if let storage = textStorage, storage.length > 0 {
            storage.setAttributes(attributes, range: NSRange(location: 0, length: storage.length))
        }
        fitToText()
    }

    /// Grows with the text; never narrower than the caret, never shorter than one line.
    func fitToText() {
        guard let layout = layoutManager, let container = textContainer else { return }
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        let font = typingAttributes[.font] as? NSFont ?? .systemFont(ofSize: 20)
        let lineHeight = layout.defaultLineHeight(for: font)
        setFrameSize(CGSize(width: ceil(max(used.width, 1)) + 2, height: ceil(max(used.height, lineHeight))))
        superview?.needsDisplay = true
    }
}
