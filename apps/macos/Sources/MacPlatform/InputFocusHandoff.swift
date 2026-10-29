import Foundation

/// Restore the input destination across asynchronous application activation, before any text mutation.
@MainActor
public enum InputFocusHandoff {
    public enum Foreground { case overlay, destination, other }

    /// Accept an already-focused destination; otherwise restore it only from our own active overlay.
    public static func restore(
        foreground: () -> Foreground,
        dismissOverlay: () async -> Void,
        validateTarget: () async throws -> Void,
        isTargetFocused: () async -> Bool,
        activateTarget: () throws -> Void,
        focusTarget: () async throws -> Void,
        pause: () async throws -> Void = { try await Task.sleep(nanoseconds: 50_000_000) }
    ) async throws {
        // Hiding can itself return focus to the source; remember who owned it before dismissal.
        let initialForeground = foreground()
        try Task.checkCancellation()
        await dismissOverlay()
        try await validateTarget()
        try Task.checkCancellation()
        guard foreground() != .other else { throw Failure.applicationChanged }
        switch initialForeground {
        case .other: throw Failure.applicationChanged
        case .destination:
            // Accessory panels can leave the source app active; this is not a user focus change.
            guard foreground() == .destination else { throw Failure.applicationChanged }
            guard await isTargetFocused() else { throw Failure.fieldChanged }
            try await validateTarget()
            guard foreground() == .destination else { throw Failure.applicationChanged }
            return
        case .overlay: break
        }
        try activateTarget()
        var requestedFocus = false
        // Application activation and a web editor's responder restoration finish asynchronously.
        for _ in 0..<24 {
            try Task.checkCancellation()
            switch foreground() {
            case .other: throw Failure.applicationChanged
            case .overlay: break
            case .destination:
                if await isTargetFocused() {
                    try await validateTarget()
                    guard foreground() == .destination else { throw Failure.applicationChanged }
                    return
                }
                if !requestedFocus {
                    try await validateTarget()
                    try Task.checkCancellation()
                    guard foreground() == .destination else { throw Failure.applicationChanged }
                    try await focusTarget()
                    requestedFocus = true
                }
            }
            try await pause()
        }
        throw Failure.restorationFailed
    }

    /// Distinguish actual user navigation from an application that cannot restore its input responder.
    public enum Failure: LocalizedError, Equatable {
        case applicationChanged, fieldChanged, restorationFailed
        public var errorDescription: String? {
            switch self {
            case .applicationChanged: return "You switched apps, so NyCopilot didn’t paste. The result is saved in History."
            case .fieldChanged: return "Another field has focus, so NyCopilot didn’t paste. The result is saved in History."
            case .restorationFailed: return "Couldn’t return to the original field. The result is saved in History."
            }
        }
    }
}
