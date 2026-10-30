import AppKit

/// Own the complete save → temporary text → paste → restore lifecycle for a native pasteboard.
@MainActor
public enum TemporaryPasteboard {
    public static let maximumSnapshotBytes = 8 * 1024 * 1024

    /// Restore all original representations on success or failure, without overwriting a newer copy.
    public static func withText(
        _ text: String,
        on board: NSPasteboard = .general,
        validate: () async throws -> Void,
        perform: () async throws -> Void
    ) async throws {
        let initialChange = board.changeCount
        let saved = try snapshot(of: board)
        try await validate()
        try Task.checkCancellation()
        guard board.changeCount == initialChange else { throw Failure.changed }
        board.clearContents()
        let written = board.setString(text, forType: .string)
        let temporaryChange = board.changeCount

        // Only this operation's own clipboard generation may be replaced with the saved contents.
        func restore() throws {
            guard board.changeCount == temporaryChange else { return }
            board.clearContents()
            if !saved.isEmpty, !board.writeObjects(saved) { throw Failure.restoreFailed }
        }

        guard written else {
            try restore()
            throw Failure.writeFailed
        }
        do {
            try await perform()
        } catch {
            // Cancellation after a paste was sent still needs to finish clipboard cleanup.
            try restore()
            throw error
        }
        try restore()
    }

    /// The text the app in front puts on the clipboard when `copy` asks it to (⌘C), with the
    /// clipboard put back as it was. Nil when nothing new arrives within `timeout` — nothing was
    /// selected — or the clipboard is too large to back up.
    public static func copying(on board: NSPasteboard = .general, timeout: TimeInterval = 0.25,
                               copy: () -> Void) async -> String? {
        guard let saved = try? snapshot(of: board) else { return nil }
        let initialChange = board.changeCount
        copy()
        let deadline = Date().addingTimeInterval(timeout)
        while board.changeCount == initialChange, Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        guard board.changeCount != initialChange else { return nil }
        // Copied files (a Finder selection) carry their names as text; those aren't a text selection.
        let text = board.types?.contains(.fileURL) == true ? nil : board.string(forType: .string)
        board.clearContents()
        if !saved.isEmpty { board.writeObjects(saved) }
        return text
    }

    /// Every item and representation on the board, bounded so a huge clipboard isn't copied around.
    private static func snapshot(of board: NSPasteboard) throws -> [NSPasteboardItem] {
        var saved: [NSPasteboardItem] = []
        var size = 0
        for item in board.pasteboardItems ?? [] {
            let copy = NSPasteboardItem()
            for type in item.types {
                guard let data = item.data(forType: type) else { throw Failure.snapshotUnavailable }
                size += data.count
                guard size <= maximumSnapshotBytes else { throw Failure.snapshotUnavailable }
                copy.setData(data, forType: type)
            }
            saved.append(copy)
        }
        return saved
    }

    /// Report clipboard failures separately from focus failures so the recovery action is accurate.
    public enum Failure: LocalizedError, Equatable {
        case snapshotUnavailable, changed, writeFailed, restoreFailed
        public var errorDescription: String? {
            switch self {
            case .snapshotUnavailable: return "The clipboard is too large to back up safely (8 MB), so NyCopilot didn’t paste. The result is saved in History."
            case .changed: return "The clipboard changed while preparing to paste. The result is saved in History."
            case .writeFailed: return "Couldn’t use the clipboard to paste. The result is saved in History."
            case .restoreFailed: return "Pasted, but your previous clipboard couldn’t be restored."
            }
        }
    }
}
