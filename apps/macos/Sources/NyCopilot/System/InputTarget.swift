import AppKit
import ApplicationServices
import Carbon
import MacPlatform
import os

/// Geometry and roles only; captured text is never logged.
private let log = Logger(subsystem: "dev.nycopilot.NyCopilot", category: "capture")

/// The field a composition goes back to. A *verified* target is a text field macOS Accessibility can
/// read: NyCopilot restores its focus and selection and pastes through a temporary clipboard. Some
/// editors never expose their text (canvas editors, some web views); for those the target is just the
/// app and whatever it had focused, and the translation is pasted there and left on the clipboard,
/// so it is never lost if the app ignores the paste.
final class InputTarget: @unchecked Sendable {
    let processIdentifier: pid_t
    let frame: CGRect?
    /// The text cursor (or selection) on screen, in AX coordinates, when the app reports it.
    let caret: CGRect?
    /// The field's text and selection when the composer opened; nil when the field can't be read.
    private let original: (value: String, range: CFRange)?
    private let element: AXUIElement?
    private let sourceWindow: AXUIElement?

    var isVerified: Bool { original != nil }
    /// Text is selected in a field that can be read, so pasting replaces it.
    var hasSelection: Bool { (original?.range.length ?? 0) > 0 }

    /// Keep accessibility objects alive while the user composes without storing anything on disk.
    private init(pid: pid_t, element: AXUIElement?, window: AXUIElement?, original: (value: String, range: CFRange)?,
                 frame: CGRect?, caret: CGRect?) {
        processIdentifier = pid
        self.element = element
        sourceWindow = window
        self.original = original
        self.frame = frame
        self.caret = caret
    }

    /// Capture before opening our panel so the original application's focus is still available.
    static func capture(pid: pid_t) async throws -> InputTarget {
        guard AXIsProcessTrusted() else { throw Failure.permissionRequired }
        return try await Task.detached(priority: .userInitiated) {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.5)
            let appName = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)"
            var element = focusedElement(in: app)
            if readable(element) == nil, exposeWebContent(app, pid: pid) {
                // Chromium builds the tree on request, a moment later — only the first time it's
                // asked; after that, a focused element that isn't a text field simply isn't one.
                for _ in 0..<10 where readable(element) == nil {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    element = focusedElement(in: app)
                }
            }
            if let element { AXUIElementSetMessagingTimeout(element, 0.5) }
            let role = element.flatMap { attribute($0, kAXRoleAttribute) as? String }
            guard element.flatMap({ attribute($0, kAXSubroleAttribute) as? String }) != kAXSecureTextFieldSubrole else {
                Diagnostics.note("paste", "\(appName): password field, left alone")
                throw Failure.secureField
            }
            let window = element.flatMap { elementAttribute($0, kAXWindowAttribute) }
            if let window { AXUIElementSetMessagingTimeout(window, 0.5) }
            guard let element, let original = readable(element) else {
                Diagnostics.note("paste", "\(appName): field can’t be read (role \(role ?? "none")); will paste once the app is back")
                return InputTarget(pid: pid, element: element, window: window, original: nil, frame: nil, caret: nil)
            }
            // AX uses screen coordinates with a top-left origin; conversion happens in the UI.
            var position = CGPoint.zero
            var size = CGSize.zero
            let hasFrame = readAXValue(element, name: kAXPositionAttribute, type: .cgPoint, into: &position)
                && readAXValue(element, name: kAXSizeAttribute, type: .cgSize, into: &size)
            let frame = hasFrame ? CGRect(origin: position, size: size) : nil
            let caret = locateCaret(element, app: app, range: original.range, text: original.value as NSString, frame: frame, appName: appName)
            Diagnostics.note("paste", "\(appName): found \(role ?? "?")\(caret == nil ? ", no caret position" : "")"
                             + (frame == nil ? ", no frame" : ""))
            return InputTarget(pid: pid, element: element, window: window, original: original, frame: frame, caret: caret)
        }.value
    }

    /// What's selected in an app, as Accessibility reports it: some text (and where it is on screen,
    /// in AX coordinates, when the app says), nothing, or no answer at all.
    enum Selection {
        case text(String, bounds: CGRect?)
        case nothing
        case unknown
    }

    /// The selection in the app in front: in its focused element or one of that element's
    /// containers, through plain text ranges or (in web content) text markers.
    static func selection(pid: pid_t) async -> Selection {
        await Task.detached(priority: .userInitiated) {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.5)
            var current = focusedElement(in: app)
            var answered = false
            for _ in 0..<4 {
                guard let element = current else { break }
                AXUIElementSetMessagingTimeout(element, 0.5)
                if let text = attribute(element, kAXSelectedTextAttribute) as? String {
                    answered = true
                    if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        // Web content often answers only through text markers.
                        let bounds = selectedRange(element).flatMap { range -> CGRect? in
                            var range = range
                            return AXValueCreate(.cfRange, &range).flatMap { rect(element, kAXBoundsForRangeParameterizedAttribute, $0) }
                        } ?? attribute(element, "AXSelectedTextMarkerRange").flatMap { rect(element, "AXBoundsForTextMarkerRange", $0) }
                        return .text(text, bounds: bounds)
                    }
                }
                if let markers = attribute(element, "AXSelectedTextMarkerRange") {
                    answered = true
                    var result: CFTypeRef?
                    if AXUIElementCopyParameterizedAttributeValue(element, "AXStringForTextMarkerRange" as CFString, markers, &result) == .success,
                       let text = result as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        return .text(text, bounds: rect(element, "AXBoundsForTextMarkerRange", markers))
                    }
                }
                current = elementAttribute(element, kAXParentAttribute)
            }
            return answered ? .nothing : .unknown
        }.value
    }

    /// A parameterized attribute that answers with an on-screen rectangle.
    private static func rect(_ element: AXUIElement, _ name: String, _ parameter: CFTypeRef) -> CGRect? {
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, name as CFString, parameter, &result) == .success,
              let result, CFGetTypeID(result) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(unsafeBitCast(result, to: AXValue.self), .cgRect, &rect),
              rect.width > 0, rect.height > 0, rect.minX.isFinite, rect.minY.isFinite else { return nil }
        return rect
    }

    /// An enabled text field's text and selection, if the element is one.
    private static func readable(_ element: AXUIElement?) -> (value: String, range: CFRange)? {
        guard let element,
              [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(attribute(element, kAXRoleAttribute) as? String ?? ""),
              attribute(element, kAXEnabledAttribute) as? Bool != false,
              let value = attribute(element, kAXValueAttribute) as? String,
              value.utf8.count <= 1024 * 1024,
              let range = selectedRange(element),
              TextInsertion.replacing(value, range: NSRange(location: range.location, length: range.length), with: "") != nil else {
            return nil
        }
        return (value, range)
    }

    /// Electron apps (Claude, Slack, VS Code…) keep their web content out of Accessibility until a
    /// client asks for it. True when this request is what exposed it, so it's worth waiting for;
    /// a process asked before has had its tree all along.
    private static func exposeWebContent(_ app: AXUIElement, pid: pid_t) -> Bool {
        exposedLock.lock()
        let first = exposed.insert(pid).inserted
        exposedLock.unlock()
        guard first else { return false }
        let accepted = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue) == .success
        let electron = NSRunningApplication(processIdentifier: pid)?.bundleURL.map {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("Contents/Frameworks/Electron Framework.framework").path)
        } ?? false
        return accepted || electron
    }

    /// Processes already asked to expose their web content.
    nonisolated(unsafe) private static var exposed: Set<pid_t> = []
    private static let exposedLock = NSLock()

    /// The field is still there to paste into. Its text may have changed meanwhile — apps update
    /// drafts, and the paste goes wherever the cursor is — so only its disappearance stops a paste.
    func validate() async throws {
        try await Task.detached(priority: .userInitiated) { [self] in
            try validateSnapshot()
        }.value
    }

    private func validateSnapshot() throws {
        guard let element, original != nil else { return }
        guard Self.attribute(element, kAXValueAttribute) is String else { throw Failure.targetChanged }
    }

    /// Activate and verify the field; no keystroke is sent unless the app is back in front with the
    /// same field (when it has one) focused.
    @MainActor
    func insert(_ text: String, prepareForPaste: () async -> Void) async throws {
        try await returnToField(prepareForPaste: prepareForPaste)
        // Always use native paste so web editors receive their normal input and paste events.
        try await paste(text)
    }

    /// Back to the field, then ⌘V with whatever the clipboard holds — for content that isn't text,
    /// such as an image the caller has just put there.
    @MainActor
    func pasteClipboard(prepareForPaste: () async -> Void) async throws {
        try await returnToField(prepareForPaste: prepareForPaste)
        guard let (down, up) = Self.commandKey(kVK_ANSI_V) else { throw Failure.pasteUnavailable }
        down.postToPid(processIdentifier)
        up.postToPid(processIdentifier)
    }

    @MainActor
    private func returnToField(prepareForPaste: () async -> Void) async throws {
        try await InputFocusHandoff.restore(
            foreground: {
                switch NSWorkspace.shared.frontmostApplication?.processIdentifier {
                case self.processIdentifier: return .destination
                case ProcessInfo.processInfo.processIdentifier: return .overlay
                default: return .other
                }
            },
            dismissOverlay: prepareForPaste,
            validateTarget: validate,
            isTargetFocused: isFocused,
            activateTarget: {
                guard let app = NSRunningApplication(processIdentifier: self.processIdentifier), !app.isTerminated else {
                    throw Failure.targetChanged
                }
                guard app.isActive || app.activate(options: [.activateIgnoringOtherApps]) else {
                    throw InputFocusHandoff.Failure.restorationFailed
                }
            },
            focusTarget: restoreOriginalField
        )
        try await validate()
        try Task.checkCancellation()
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == processIdentifier else { throw Failure.focusChanged }
        await restoreSelection()
    }

    /// Restore the captured window and field, not whichever control happens to be focused.
    private func restoreOriginalField() async throws {
        try await Task.detached(priority: .userInitiated) { [self] in
            try validateSnapshot()
            if let sourceWindow { _ = AXUIElementPerformAction(sourceWindow, kAXRaiseAction as CFString) }
            guard let element else { return }
            let status = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            // A field that can't be read may not take focus by request either; its app restores it.
            guard status == .success || original == nil else { throw InputFocusHandoff.Failure.restorationFailed }
        }.value
    }

    /// Web editors often move the cursor when focus comes back; put the original selection back, so
    /// the translation replaces what was selected, or lands where the cursor was. Left alone if the
    /// text itself changed.
    private func restoreSelection() async {
        await Task.detached(priority: .userInitiated) { [self] in
            guard let element, let original, Self.attribute(element, kAXValueAttribute) as? String == original.value,
                  let range = Self.selectedRange(element),
                  range.location != original.range.location || range.length != original.range.length else { return }
            var wanted = original.range
            guard let value = AXValueCreate(.cfRange, &wanted) else { return }
            _ = AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value)
        }.value
    }

    /// An editor may focus its inner text node; accept only the captured field or its descendants.
    /// With no field captured, the app being in front is all that can be checked.
    private func isFocused() async -> Bool {
        guard let element else { return true }
        return await Task.detached(priority: .userInitiated) { [self] in
            let app = AXUIElementCreateApplication(processIdentifier)
            AXUIElementSetMessagingTimeout(app, 0.5)
            var focused = Self.focusedElement(in: app)
            for _ in 0..<8 {
                guard let current = focused else { return false }
                if CFEqual(current, element) { return true }
                focused = Self.elementAttribute(current, kAXParentAttribute)
                if let focused { AXUIElementSetMessagingTimeout(focused, 0.5) }
            }
            return false
        }.value
    }

    /// A verified field gets the text through a temporary clipboard that is then restored; an
    /// unverified one keeps the translation on the clipboard, in case the app ignored the paste.
    @MainActor
    private func paste(_ text: String) async throws {
        guard let (down, up) = Self.commandKey(kVK_ANSI_V) else { throw Failure.pasteUnavailable }
        guard isVerified else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            down.postToPid(processIdentifier)
            up.postToPid(processIdentifier)
            return
        }
        try await TemporaryPasteboard.withText(text, validate: {
            try await self.validate()
            guard await self.isFocused(),
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == self.processIdentifier else {
                throw Failure.focusChanged
            }
        }, perform: {
            // Allow the native paste event to consume the temporary text without verifying editor contents.
            down.postToPid(self.processIdentifier)
            up.postToPid(self.processIdentifier)
            // Once paste has been sent, cancellation must not shorten the clipboard's availability.
            await Task.detached {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }.value
        })
    }

    /// ⌘ plus `key`, down and up, from a private event source so the user's own modifiers don't mix in.
    private static func commandKey(_ key: Int) -> (CGEvent, CGEvent)? {
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key), keyDown: false) else { return nil }
        down.flags = .maskCommand
        up.flags = .maskCommand
        return (down, up)
    }

    /// The selection as the app would copy it — line breaks and list items intact (web content
    /// reports its selection to Accessibility run together) — with the clipboard put back, and where
    /// it is (AX coordinates) when the app says. Whether anything is selected is asked first, so
    /// with nothing selected this returns at once.
    @MainActor
    static func selectedText(pid: pid_t) async -> (text: String, bounds: CGRect?)? {
        switch await selection(pid: pid) {
        case .text(let text, let bounds): return (await copiedSelection(pid: pid) ?? text, bounds)
        case .nothing: return nil
        case .unknown: return await copiedSelection(pid: pid).map { ($0, nil) }
        }
    }

    /// The text selected in an app that doesn't describe its selection to Accessibility, read by
    /// asking it to copy (⌘C) with the clipboard put back afterwards.
    @MainActor
    static func copiedSelection(pid: pid_t) async -> String? {
        guard let (down, up) = commandKey(kVK_ANSI_C) else { return nil }
        let text = await TemporaryPasteboard.copying {
            down.postToPid(pid)
            up.postToPid(pid)
        }
        return text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? text : nil
    }

    /// Bound every attribute call through the timeout already set on the AX element.
    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    /// Check CF type identities before bridging values returned by another process.
    private static func focusedElement(in app: AXUIElement) -> AXUIElement? {
        elementAttribute(app, kAXFocusedUIElementAttribute)
    }

    /// Window, focus, and parent references are bridged only after validating the CF type.
    private static func elementAttribute(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    /// Where the cursor is drawn, trying in turn: the standard range bounds, WebKit/Chromium text
    /// markers, and — for Electron apps, which build their accessibility tree only on request — both
    /// again after asking for it. Results outside the field are rejected as bogus.
    private static func locateCaret(_ element: AXUIElement, app: AXUIElement, range: CFRange, text: NSString,
                                    frame: CGRect?, appName: String) -> CGRect? {
        func plausible(_ rect: CGRect?, _ source: String) -> CGRect? {
            guard let rect else { log.debug("\(appName, privacy: .public): \(source, privacy: .public) gave nothing"); return nil }
            if let frame, !frame.insetBy(dx: -40, dy: -40).intersects(rect) {
                log.notice("\(appName, privacy: .public): \(source, privacy: .public) rect \(String(describing: rect), privacy: .public) is outside the field")
                return nil
            }
            log.notice("\(appName, privacy: .public): caret from \(source, privacy: .public)")
            return rect
        }
        if let rect = plausible(caretBounds(element, range: range, text: text), "range bounds") { return rect }
        if let rect = plausible(markerBounds(element), "text markers") { return rect }
        guard AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue) == .success else { return nil }
        return plausible(caretBounds(element, range: range, text: text), "range bounds (Electron)")
            ?? plausible(markerBounds(element), "text markers (Electron)")
    }

    /// Chromium and WebKit describe the selection with opaque text markers rather than plain ranges.
    private static func markerBounds(_ element: AXUIElement) -> CGRect? {
        guard let markers = attribute(element, "AXSelectedTextMarkerRange") else { return nil }
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, "AXBoundsForTextMarkerRange" as CFString, markers, &result) == .success,
              let result, CFGetTypeID(result) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(unsafeBitCast(result, to: AXValue.self), .cgRect, &rect),
              rect.height > 0, rect.height < 200, rect.minX.isFinite, rect.minY.isFinite else { return nil }
        return rect
    }

    /// The standard range bounds. A selection reports its own bounds; an empty range often reports a
    /// zero-size rect, so the character before the cursor stands in for its position.
    private static func caretBounds(_ element: AXUIElement, range: CFRange, text: NSString) -> CGRect? {
        func isLineBreak(_ index: Int) -> Bool {
            index >= 0 && index < text.length && CharacterSet.newlines.contains(UnicodeScalar(text.character(at: index)) ?? " ")
        }
        var candidates: [(CFRange, atEnd: Bool)] = []
        if range.length > 0 { candidates.append((range, false)) }
        candidates.append((CFRange(location: range.location, length: 0), false))
        // A line break's bounds sit at the end of the previous line, so it can't stand in for the cursor.
        if range.location > 0, !isLineBreak(range.location - 1) {
            candidates.append((CFRange(location: range.location - 1, length: 1), true))
        }
        if range.location < text.length, !isLineBreak(range.location) {
            candidates.append((CFRange(location: range.location, length: 1), false))
        }
        for (candidate, atEnd) in candidates {
            var query = candidate
            guard let parameter = AXValueCreate(.cfRange, &query) else { continue }
            var result: CFTypeRef?
            guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                             parameter, &result) == .success,
                  let result, CFGetTypeID(result) == AXValueGetTypeID() else { continue }
            var rect = CGRect.zero
            guard AXValueGetValue(unsafeBitCast(result, to: AXValue.self), .cgRect, &rect),
                  rect.height > 0, rect.height < 200, rect.minX.isFinite, rect.minY.isFinite else { continue }
            return atEnd ? CGRect(x: rect.maxX, y: rect.minY, width: 1, height: rect.height) : rect
        }
        return nil
    }

    /// AX text ranges are UTF-16 offsets, matching NSString and NSRange semantics.
    private static func selectedRange(_ element: AXUIElement) -> CFRange? {
        var range = CFRange()
        return readAXValue(element, name: kAXSelectedTextRangeAttribute, type: .cfRange, into: &range) ? range : nil
    }

    /// Decode typed AX geometry and range values without unchecked pointer conversions.
    private static func readAXValue<T>(_ element: AXUIElement, name: String, type: AXValueType, into output: inout T) -> Bool {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXValueGetTypeID() else { return false }
        let axValue = unsafeBitCast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == type else { return false }
        return withUnsafeMutablePointer(to: &output) { AXValueGetValue(axValue, type, $0) }
    }

    /// On any uncertainty the result remains available for manual copy instead of another write.
    enum Failure: LocalizedError {
        case permissionRequired, secureField, targetChanged, focusChanged
        case pasteUnavailable
        var errorDescription: String? {
            switch self {
            case .permissionRequired: return "NyCopilot needs Accessibility access to work with text fields."
            case .secureField: return "NyCopilot never reads or writes password fields."
            case .targetChanged: return "The original field closed while you were typing, so NyCopilot didn’t paste."
            case .focusChanged: return "Focus moved to another field, so NyCopilot didn’t paste."
            case .pasteUnavailable: return "macOS couldn’t create a paste event."
            }
        }
    }
}
