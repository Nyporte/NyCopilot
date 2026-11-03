import AppKit
@preconcurrency import VisionKit

/// What the user chose to do with a capture.
enum CaptureAction { case copy, save, quickSave, pin, scroll, record, translate, inbox, ask }

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
    var selection: CGRect?
    var annotations: [Annotation] = []
    var redoStack: [Annotation] = []
    /// What a click would take: the element under the pointer, or — in window mode — its window.
    var hoverWindow: CGRect?
    /// Tab switches between outlining whole windows and elements, as in Snipaste. Shared by every
    /// display's overlay, and back to windows with each new capture.
    static var detectsWindows = true
    /// The first few captures show where the rest of the keys are.
    static var showsKeysTip = false
    /// When the shortcut was pressed, until the first frame is drawn (for timing).
    static var pressedAt: Date?
    var pointer: CGPoint?
    var drag: Drag = .none
    var current: Annotation?
    var textEditor: TextAnnotationEditor?
    var recentIndex = -1
    var analysis: (rect: CGRect, task: Task<ImageAnalysis, Error>)?
    var pendingAnalysis: DispatchWorkItem?
    var textOverlay: ImageAnalysisOverlayView?
    var copyWhenRead = false
    let textBar = CaptureTextBar()
    /// Which format C copies; Shift switches between HEX and RGB.
    var copiesHex = true
    /// "Copied …" shown briefly in the magnifier after C.
    var copiedFlash: String?
    var clearFlash: DispatchWorkItem?
    var shiftWasDown = false
    let recent: [CGRect]
    lazy var pixelatedScreen = CaptureRenderer.pixelate(frozen.image, blockSize: 12 * frozen.scale)
    /// The whole display pixelated, which takes a moment: made only once a mosaic mark needs it.
    var pixelated: CGImage? {
        annotations.contains { $0.tool == .mosaic } || current?.tool == .mosaic ? pixelatedScreen : nil
    }
    let toolbar: CaptureToolbar
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
    let onStyleChange: (NSColor, CGFloat, CaptureStyle) -> Void

    enum Drag {
        case none, creating(CGPoint), moving(CGPoint, CGRect), resizing(Handle, CGRect), drawing
    }
    enum Handle: CaseIterable { case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left }

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
        toolbar.onResize = { [weak self] in
            guard let self, !toolbar.isHidden else { return }
            place(toolbar)
        }
        // Under the toolbar and the text bars: the dimming and outline, the label, the magnifier.
        chrome.frame = bounds
        chrome.autoresizingMask = [.width, .height]
        magnifierView.owner = self
        for view in [chrome, sizeLabelView, magnifierView] as [NSView] { addSubview(view) }
        addSubview(toolbar)
        textBar.isHidden = true
        textBar.onCopyAll = { [weak self] in self?.copyAllText() }
        textBar.onDone = { [weak self] in self?.endReadingText() }
        addSubview(textBar)
    }

    required init?(coder: NSCoder) { fatalError("Use init(frozen:…)") }

    func styleChanged() { onStyleChange(color, stroke, style) }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The GPU-drawn dimming, outline, and handles; the size label; the magnifier (see CaptureChrome).
    let chrome = CaptureChrome(frame: .zero)
    let sizeLabelView = CaptureLabel()
    let magnifierView = MagnifierView()
    // Outline and handle animation state (see CaptureView+Outline).
    var glide: (from: CGRect, to: CGRect, start: CFTimeInterval)?
    var glideTimer: Timer?
    var focusedHandle: Handle?
    var handleGrowth: [Handle: (from: CGFloat, to: CGFloat, start: CFTimeInterval)] = [:]

    // MARK: Drawing

    /// The moving parts, refreshed: the outline's place, the handles, the label, the magnifier.
    func refreshDynamic() { updateChrome() }

    /// Any redraw also refreshes the layers above it.
    override var needsDisplay: Bool {
        get { super.needsDisplay }
        set {
            super.needsDisplay = newValue
            if newValue { updateChrome() }
        }
    }

    /// The area the last draw was asked to cover, or zero (for tests).
    var lastDirtyRect = NSRect.zero

    /// Only what changes with editing: annotations inside the selection and the text being typed.
    override func draw(_ dirtyRect: NSRect) {
        lastDirtyRect = dirtyRect
        if let pressed = Self.pressedAt {
            Self.pressedAt = nil
            Diagnostics.note("capture", "F1 → first frame \(Int(Date().timeIntervalSince(pressed) * 1000)) ms")
        }
        guard let selection else { return }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: selection).addClip()
        for annotation in annotations { annotation.draw(pixelated: pixelated, imageFrame: bounds) }
        current?.draw(pixelated: pixelated, imageFrame: bounds)
        NSGraphicsContext.restoreGraphicsState()
        if let textEditor { drawEditorFrame(textEditor.frame) }
    }

    /// The dimming, outline, handles, label, and magnifier, as the state says they are now.
    func updateChrome() {
        guard chrome.superview === self else { return }
        let hovering = selection == nil && !isPassive
        // After a selection, the next outline appears in place rather than gliding from the past.
        if !hovering { glide = nil }
        let outlined = hovering ? glidingOutline() : nil
        let framed = selection ?? (hoverWindow != nil ? outlined : nil)
        let now = CACurrentMediaTime()
        let spots: [(CGPoint, CGFloat)] = selection.map { selection in
            guard tool == nil, !isReadingText else { return [] }
            return Handle.allCases.map { (point(of: $0, in: selection), growth(of: $0, at: now)) }
        } ?? []
        chrome.show(dimming: selection == nil ? 0.28 : 0.45, focus: selection ?? outlined, frame: framed, handles: spots)

        if let framed {
            let (text, plate) = sizeLabel(for: framed, measuring: selection == nil ? hoverWindow : nil)
            sizeLabelView.text = text
            sizeLabelView.frame = plate
            sizeLabelView.isHidden = false
        } else {
            sizeLabelView.isHidden = true
        }
        if showsMagnifier, let pointer {
            magnifierView.pointer = pointer
            magnifierView.frame = magnifierFrame(at: pointer)
            magnifierView.needsDisplay = true
            magnifierView.isHidden = false
        } else {
            magnifierView.isHidden = true
        }
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        // .cursorUpdate: AppKit asks this view for the cursor whenever it re-decides it (after each
        // redraw, among other times); without it, AppKit falls back to the arrow.
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func cursorUpdate(with event: NSEvent) {
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        pointer = point
        if selection == nil, !isPassive { hover(at: point) }
        focusHandle(near: point)
        updateCursor(at: point)
        refreshDynamic()
    }

    /// Outlines what's under the pointer as soon as the capture opens, before it moves.
    func hoverAtPointer() {
        guard let window else { return }
        // From the screen position: the window may not be on screen yet.
        let point = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        guard bounds.contains(point) else { return }
        pointer = point
        if selection == nil, !isPassive { hover(at: point) }
        needsDisplay = true
    }

    /// In window mode, the window under the pointer. Otherwise the element under it, once its app
    /// answers; meanwhile the outline stays where it is rather than flashing the whole window.
    func hover(at point: CGPoint) {
        guard let window = frozen.windows.first(where: { $0.rect.contains(point) }) else { hoverWindow = nil; return }
        guard !Self.detectsWindows, AXIsProcessTrusted() else { hoverWindow = window.rect; return }
        if hoverWindow == nil { hoverWindow = window.rect }
        let origin = ScreenGeometry.topLeftOrigin(of: frozen.screen)
        let global = FrozenScreen.Window(rect: window.rect.offsetBy(dx: origin.x, dy: origin.y), pid: window.pid)
        ElementFinder.shared.find(at: CGPoint(x: point.x + origin.x, y: point.y + origin.y), in: global) { [weak self] element in
            guard let self, selection == nil, !isPassive, !Self.detectsWindows, let pointer, window.rect.contains(pointer) else { return }
            let local = element.offsetBy(dx: -origin.x, dy: -origin.y)
            hoverWindow = local.contains(pointer) ? local : window.rect
            refreshDynamic()
        }
    }

    /// Tab: elements ⇄ windows, on every display at once.
    func toggleDetection() {
        Self.detectsWindows.toggle()
        for view in NSApp.windows.compactMap({ $0.contentView?.subviews.first as? CaptureView }) {
            if let pointer = view.pointer, view.selection == nil, !view.isPassive { view.hover(at: pointer) }
            view.needsDisplay = true
        }
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
            focusHandle(near: point)
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
        focusHandle(near: pointer)
        needsDisplay = true
    }

    override func rightMouseDown(with event: NSEvent) {
        if isReadingText { endReadingText() }
        else if textEditor != nil { cancelText() }
        else if tool != nil { tool = nil }
        else if selection != nil, annotations.isEmpty { clearSelection() }
        else { onCancel?() }
    }

    func clamp(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(point.x, 0), bounds.width), y: min(max(point.y, 0), bounds.height))
    }

    func clearSelection() {
        selection = nil
        toolbar.isHidden = true
        tool = nil
        needsDisplay = true
    }

    // MARK: Handles

    func point(of handle: Handle, in rect: CGRect) -> CGPoint {
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

    func handle(at point: CGPoint, in rect: CGRect) -> Handle? {
        // The grown handle is easier to grab.
        if let focusedHandle, CGRect(center: self.point(of: focusedHandle, in: rect), size: 28).contains(point) { return focusedHandle }
        return Handle.allCases.first { CGRect(center: self.point(of: $0, in: rect), size: 14).contains(point) }
    }

    func resized(_ rect: CGRect, handle: Handle, to point: CGPoint) -> CGRect {
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
    func snapped(_ rect: CGRect) -> CGRect {
        let scale = frozen.scale
        func pixel(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
        return CGRect(corners: CGPoint(x: pixel(rect.minX), y: pixel(rect.minY)), CGPoint(x: pixel(rect.maxX), y: pixel(rect.maxY)))
    }

    func updateCursor(at point: CGPoint) {
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

    func placeToolbar() {
        guard let selection, selection.width >= 4, selection.height >= 4, !isReadingText else { toolbar.isHidden = true; return }
        toolbar.isHidden = false
        place(toolbar)
    }

    /// Below the selection, right-aligned; above it when there is no room; inside as a last resort.
    func place(_ bar: NSView) {
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
    func beginText(at point: CGPoint) {
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

    func drawEditorFrame(_ frame: CGRect) {
        let box = NSBezierPath(rect: frame.insetBy(dx: -4, dy: -3))
        box.lineWidth = 1
        box.setLineDash([4, 3], count: 2, phase: 0)
        NSColor.white.withAlphaComponent(0.8).setStroke()
        box.stroke()
    }

    func commitText() {
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

    func cancelText() {
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

    func finish(_ action: CaptureAction) {
        if textEditor != nil { commitText() }
        guard selection != nil else { return }
        onFinish?(action)
    }

    // MARK: Live Text

    /// Arrow keys and drags settle many times a second; read the text once things are still.
    func selectionSettled() {
        pendingAnalysis?.cancel()
        let work = DispatchWorkItem { [weak self] in _ = self?.textAnalysis() }
        pendingAnalysis = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    /// The text in the current selection, read from the screen as it was, so annotations don't get in
    /// the way. Started in the background as soon as the selection settles, so T is instant.
    func textAnalysis() -> Task<ImageAnalysis, Error>? {
        guard let selection else { return nil }
        if let analysis, analysis.rect == selection { return analysis.task }
        guard let image = frozen.crop(selection) else { return nil }
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

    func endReadingText() {
        copyWhenRead = false
        textOverlay?.removeFromSuperview()
        textOverlay = nil
        textBar.isHidden = true
        placeToolbar()
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    /// ⌘C: the selected words, staying in Live Text.
    func copySelectedText() {
        guard let overlay = textOverlay, overlay.analysis != nil else { return }
        let text = LiveText.textToCopy(from: overlay)
        guard !text.isEmpty else { return }
        LiveText.copy(text)
        textBar.flash(L("Copied"))
    }

    /// T twice — the left hand never moves — or Return, or Copy All: every line, then the capture
    /// closes. A double tap faster than recognition copies as soon as the text is read.
    func copyAllText() {
        guard let overlay = textOverlay else { return }
        guard let analysis = overlay.analysis else { copyWhenRead = true; return }
        let transcript = analysis.transcript
        guard !transcript.isEmpty else { textBar.flash(L("No text to copy")); return }
        LiveText.copy(transcript)
        onTextCopied?(transcript.split(whereSeparator: \.isNewline).count)
    }

    /// Keys while reading text; the overlay passes along whatever it doesn't use itself.
    func readingTextKeyDown(_ event: NSEvent) {
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


}
