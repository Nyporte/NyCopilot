import AppKit
import XCTest

/// Lays out and draws views off screen, as they would look in dark mode, and fails a test when
/// AppKit reports a layout conflict meanwhile — the kind of mistake that only shows in the log, or
/// as a window that never opens. Images go to the temporary folder for a look by eye.
enum Render {
    /// Runs `body`, returning what AppKit wrote to stderr meanwhile.
    static func stderr(during body: () throws -> Void) rethrows -> String {
        let pipe = Pipe()
        // Read as it's written: a full pipe would block the writer (AppKit) forever.
        var captured = Data()
        let lock = NSLock()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            lock.lock(); captured.append(chunk); lock.unlock()
        }
        let saved = dup(STDERR_FILENO)
        fflush(Darwin.stderr)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO)
        defer {
            fflush(Darwin.stderr)
            dup2(saved, STDERR_FILENO)
            close(saved)
            pipe.fileHandleForWriting.closeFile()
            // Let the reader drain what's left.
            Thread.sleep(forTimeInterval: 0.05)
            pipe.fileHandleForReading.readabilityHandler = nil
        }
        try body()
        fflush(Darwin.stderr)
        Thread.sleep(forTimeInterval: 0.05)
        lock.lock(); defer { lock.unlock() }
        return String(decoding: captured, as: UTF8.self)
    }

    /// Lays out and draws `view`, writing `name`.png; fails on any layout conflict.
    @MainActor
    @discardableResult
    static func check(_ view: NSView, _ name: String, file: StaticString = #filePath, line: UInt = #line) -> NSImage? {
        var image: NSImage?
        let log = stderr {
            view.appearance = NSAppearance(named: .darkAqua)
            view.layoutSubtreeIfNeeded()
            guard view.bounds.width > 0, view.bounds.height > 0,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: rep) }
            let picture = NSImage(size: view.bounds.size)
            picture.addRepresentation(rep)
            image = picture
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("NyCopilotRender-\(name).png")
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
        XCTAssertFalse(log.contains("Unable to simultaneously satisfy constraints"), "\(name): layout conflict\n\(log.prefix(600))",
                       file: file, line: line)
        XCTAssertNotNil(image, "\(name): nothing to draw", file: file, line: line)
        return image
    }
}

extension Render {
    /// The text of every single-line label, button, and segmented control that is narrower than
    /// its own text, so it shows cut off. Wrapping labels grow instead, so they never count.
    @MainActor
    static func clipped(_ view: NSView) -> [String] {
        view.layoutSubtreeIfNeeded()
        var found: [String] = []
        func visit(_ view: NSView) {
            guard !view.isHidden, view.alphaValue > 0 else { return }
            let room = view.bounds.width + 1
            if view.bounds.width > 0 {
                if let field = view as? NSTextField, !field.isEditable, !field.stringValue.isEmpty, let cell = field.cell, !cell.wraps,
                   cell.cellSize.width > room {
                    found.append(field.stringValue)
                } else if let button = view as? NSButton, !(view is NSPopUpButton), !button.title.isEmpty, button.imagePosition != .imageOnly,
                          button.intrinsicContentSize.width > room {
                    found.append(button.title)
                } else if let control = view as? NSSegmentedControl, control.intrinsicContentSize.width > room {
                    found.append((0..<control.segmentCount).compactMap { control.label(forSegment: $0) }.joined(separator: " | "))
                }
            }
            view.subviews.forEach(visit)
        }
        visit(view)
        return found
    }
}
