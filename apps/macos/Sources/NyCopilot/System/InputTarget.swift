import AppKit
import ApplicationServices
import Carbon
import MacPlatform

/// An immutable snapshot binds a composition to one field, its contents, and its original selection.
final class InputTarget: @unchecked Sendable {
    let processIdentifier: pid_t
    let frame: CGRect?
    private let element: AXUIElement
    private let sourceWindow: AXUIElement?
    private let originalValue: String
    private let originalRange: CFRange

    /// Keep accessibility objects alive while the user composes without storing anything on disk.
    private init(pid: pid_t, element: AXUIElement, window: AXUIElement?, value: String, range: CFRange, frame: CGRect?) {
        processIdentifier = pid
        self.element = element
        sourceWindow = window
        originalValue = value
        originalRange = range
        self.frame = frame
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
            return InputTarget(pid: pid, element: element, window: window, value: value, range: range,
                               frame: hasFrame ? CGRect(origin: position, size: size) : nil)
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
