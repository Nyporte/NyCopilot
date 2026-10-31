import AppKit

/// The capture's keys.
extension CaptureView {
    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        if isReadingText { readingTextKeyDown(event); return }
        if event.characters == "?" { KeySheet.shared.toggle("Screenshot keys", groups: KeyGuide.capture, over: window); return }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        switch (event.keyCode, flags) {
        case (53, _): onCancel?()
        case (48, []) where selection == nil: toggleDetection()
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
                case "g" where selection != nil: finish(.record)
                case "r" where selection != nil: finish(.translate)
                case "i" where selection != nil: finish(.inbox)
                case "a" where selection != nil: finish(.ask)
                case "p" where selection != nil: finish(.pin)
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
    func nudge(_ keyCode: UInt16, resize: Bool) {
        guard var rect = selection, tool == nil else {
            // Before selecting, arrows move the pointer for pixel-precise starts.
            if selection == nil, let pointer {
                let delta: CGPoint = keyCode == 123 ? CGPoint(x: -1, y: 0) : keyCode == 124 ? CGPoint(x: 1, y: 0)
                    : keyCode == 125 ? CGPoint(x: 0, y: 1) : CGPoint(x: 0, y: -1)
                let moved = clamp(CGPoint(x: pointer.x + delta.x, y: pointer.y + delta.y))
                if let window {
                    let screenPoint = window.convertPoint(toScreen: convert(moved, to: nil))
                    CGWarpMouseCursorPosition(ScreenGeometry.topLeft(screenPoint))
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

    func selectAll() {
        guard annotations.isEmpty else { return }
        onSelectionStarted?()
        selection = bounds
        hoverWindow = nil
        placeToolbar()
        selectionSettled()
        needsDisplay = true
    }

    /// `,` and `.` step back and forth through regions captured before.
    func stepRecent(by step: Int) {
        guard annotations.isEmpty, !recent.isEmpty else { return }
        recentIndex = min(max(recentIndex + step, 0), recent.count - 1)
        onSelectionStarted?()
        selection = recent[recentIndex]
        placeToolbar()
        selectionSettled()
        needsDisplay = true
    }

    /// C copies the color under the pointer in the highlighted format; capture carries on.
    func copyColor() {
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
