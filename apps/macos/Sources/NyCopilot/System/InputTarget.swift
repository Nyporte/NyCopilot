import AppKit
import ApplicationServices
import Carbon
import MacPlatform
import os

/// Geometry and roles only; captured text is never logged.
private let log = Logger(subsystem: "dev.nycopilot.NyCopilot", category: "capture")

/// An immutable snapshot binds a composition to one field, its contents, and its original selection.
final class InputTarget: @unchecked Sendable {
    let processIdentifier: pid_t
    let frame: CGRect?
    /// The text cursor (or selection) on screen, in AX coordinates, when the app reports it.
    let caret: CGRect?
    private let element: AXUIElement
    private let sourceWindow: AXUIElement?
    private let originalValue: String
    private let originalRange: CFRange

    /// Keep accessibility objects alive while the user composes without storing anything on disk.
    private init(pid: pid_t, element: AXUIElement, window: AXUIElement?, value: String, range: CFRange, frame: CGRect?, caret: CGRect?) {
        processIdentifier = pid
        self.element = element
        sourceWindow = window
        originalValue = value
        originalRange = range
        self.frame = frame
        self.caret = caret
    }

    /// Capture before opening our panel so the original application's focus is still available.
    static func capture(pid: pid_t) async throws -> InputTarget {
        guard AXIsProcessTrusted() else { throw Failure.permissionRequired }
        return try await Task.detached(priority: .userInitiated) {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.5)
            guard let element = focusedElement(in: app) else { throw Failure.unsupportedField }
            AXUIElementSetMessagingTimeout(element, 0.5)
            let role = attribute(element, kAXRoleAttribute) as? String
            let subrole = attribute(element, kAXSubroleAttribute) as? String
            guard subrole != kAXSecureTextFieldSubrole else { throw Failure.secureField }
            guard [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role ?? ""),
                  attribute(element, kAXEnabledAttribute) as? Bool != false,
                  let value = attribute(element, kAXValueAttribute) as? String,
                  value.utf8.count <= 1024 * 1024,
                  let range = selectedRange(element),
                  TextInsertion.replacing(value, range: NSRange(location: range.location, length: range.length), with: "") != nil else {
                throw Failure.unsupportedField
            }
            // AX uses screen coordinates with a top-left origin; conversion happens in the UI.
            var position = CGPoint.zero
            var size = CGSize.zero
            let hasFrame = readAXValue(element, name: kAXPositionAttribute, type: .cgPoint, into: &position)
                && readAXValue(element, name: kAXSizeAttribute, type: .cgSize, into: &size)
            let window = elementAttribute(element, kAXWindowAttribute)
            if let window { AXUIElementSetMessagingTimeout(window, 0.5) }
            let frame = hasFrame ? CGRect(origin: position, size: size) : nil
            let appName = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)"
            let caret = locateCaret(element, app: app, range: range, text: value as NSString, frame: frame, appName: appName)
            log.notice("""
                captured \(appName, privacy: .public) role=\(role ?? "?", privacy: .public) \
                frame=\(String(describing: frame), privacy: .public) caret=\(String(describing: caret), privacy: .public)
                """)
            return InputTarget(pid: pid, element: element, window: window, value: value, range: range,
                               frame: frame, caret: caret)
        }.value
    }

    /// Detect edits and caret movement before any mutation, including a request completed much later.
    func validate() async throws {
        try await Task.detached(priority: .userInitiated) { [self] in
            try validateSnapshot()
        }.value
    }

    /// Recheck the immutable snapshot before restoring focus or sending a paste event.
    private func validateSnapshot() throws {
        guard let value = Self.attribute(element, kAXValueAttribute) as? String,
              value == originalValue,
              let range = Self.selectedRange(element),
              range.location == originalRange.location, range.length == originalRange.length else {
            throw Failure.targetChanged
        }
    }

    /// Activate and verify the exact field; no keystroke is sent to an unverified foreground target.
    @MainActor
    func insert(_ text: String, prepareForPaste: () async -> Void) async throws {
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

        // Always use native paste so web editors receive their normal input and paste events.
        try await paste(text)
    }

    /// Restore the captured window and exact AX field, not whichever control happens to be focused.
    private func restoreOriginalField() async throws {
        try await Task.detached(priority: .userInitiated) { [self] in
            try validateSnapshot()
            if let sourceWindow { _ = AXUIElementPerformAction(sourceWindow, kAXRaiseAction as CFString) }
            let status = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            guard status == .success else { throw InputFocusHandoff.Failure.restorationFailed }
        }.value
    }

    /// An editor may focus its inner text node; accept only the captured field or its descendants.
    private func isFocused() async -> Bool {
        await Task.detached(priority: .userInitiated) { [self] in
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

    /// Snapshot all clipboard types and restore them only if no other app changed the clipboard.
    @MainActor
    private func paste(_ text: String) async throws {
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false) else {
            throw Failure.pasteUnavailable
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
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

    /// Only an explicit permission-button click asks macOS to show its authorization prompt.
    static func requestPermission() {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
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
        case permissionRequired, unsupportedField, secureField, targetChanged, focusChanged
        case pasteUnavailable
        var errorDescription: String? {
            switch self {
            case .permissionRequired: return "NyCopilot needs Accessibility access to work with text fields."
            case .unsupportedField: return "This field doesn’t expose its text to macOS Accessibility."
            case .secureField: return "NyCopilot never reads or writes password fields."
            case .targetChanged: return "The original text changed while you were typing, so NyCopilot didn’t paste."
            case .focusChanged: return "Focus moved to another field, so NyCopilot didn’t paste."
            case .pasteUnavailable: return "macOS couldn’t create a paste event."
            }
        }
    }
}
