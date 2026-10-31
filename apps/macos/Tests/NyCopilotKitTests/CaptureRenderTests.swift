import AppKit
import XCTest
@testable import NyCopilotKit

@MainActor
final class CaptureRenderTests: XCTestCase {
    /// The bar starts at its own size and grows its options row without conflicts.
    func testToolbarLaysOutWithAndWithoutOptions() {
        let toolbar = CaptureToolbar(palette: [.systemRed, .systemBlue])
        XCTAssertGreaterThan(toolbar.frame.height, 20)
        Render.check(toolbar, "toolbar")
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 200))
        host.addSubview(toolbar)
        var resized = 0
        toolbar.onResize = { resized += 1; toolbar.setFrameSize(toolbar.fittingSize) }
        let log = Render.stderr {
            toolbar.selectedTool = .rectangle
            host.layoutSubtreeIfNeeded()
            toolbar.selectedTool = nil
            host.layoutSubtreeIfNeeded()
        }
        XCTAssertEqual(resized, 2)
        XCTAssertFalse(log.contains("Unable to simultaneously satisfy constraints"), String(log.prefix(600)))
        XCTAssertLessThan(toolbar.fittingSize.width, 720, "the bar should fit beside most selections")
    }

    /// The view answers AppKit's cursor requests itself. Without a cursor-update area, AppKit put
    /// the arrow back after every redraw, so the crosshair showed only while the mouse moved.
    func testCaptureViewKeepsTheCrosshairUntilThereIsASelection() throws {
        let screen = NSScreen.screens[0]
        let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let frozen = FrozenScreen(screen: screen, image: try XCTUnwrap(context.makeImage()), windows: [])
        let view = CaptureView(frozen: frozen, recent: [], palette: [.systemRed], color: .systemRed, stroke: 3, style: CaptureStyle()) { _, _, _ in }
        view.updateTrackingAreas()
        XCTAssertTrue(view.trackingAreas.contains { $0.options.contains(.cursorUpdate) && $0.owner === view })
        view.updateCursor(at: CGPoint(x: 300, y: 300))
        XCTAssertEqual(NSCursor.current, .crosshair)
        view.selection = CGRect(x: 100, y: 100, width: 100, height: 100)
        view.updateCursor(at: CGPoint(x: 300, y: 300))
        XCTAssertEqual(NSCursor.current, .arrow, "outside a finished selection, the pointer")
    }

    /// A pointer move redraws around the pointer and the outline, not the whole screen.
    func testPointerMovesRedrawOnlyNearby() throws {
        let screen = NSScreen.screens[0]
        let context = CGContext(data: nil, width: Int(screen.frame.width), height: Int(screen.frame.height), bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let frozen = FrozenScreen(screen: screen, image: try XCTUnwrap(context.makeImage()),
                                  windows: [.init(rect: CGRect(x: 100, y: 100, width: 300, height: 200), pid: 1)])
        let view = CaptureView(frozen: frozen, recent: [], palette: [.systemRed], color: .systemRed, stroke: 3, style: CaptureStyle()) { _, _, _ in }
        view.pointer = CGPoint(x: 200, y: 200)
        view.hoverWindow = frozen.windows[0].rect
        Render.check(view, "capture-view")
        // Invalid regions are tracked by a window; this one is never shown.
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        // As CaptureSession builds it: a plain container holding the frozen pixels, the view inside.
        let container = NSView(frame: view.frame)
        container.wantsLayer = true
        view.frame = container.bounds
        container.addSubview(view)
        window.contentView = container
        window.displayIfNeeded()
        XCTAssertFalse(view.needsDisplay)
        view.lastDirtyRect = .zero
        view.pointer = CGPoint(x: 220, y: 210)
        view.refreshDynamic()
        window.displayIfNeeded()
        XCTAssertEqual(view.lastDirtyRect, .zero, "a pointer move doesn't redraw the full-screen view")
        XCTAssertTrue(view.magnifierView.frame.insetBy(dx: -30, dy: -30).contains(CGPoint(x: 220, y: 210)), "the magnifier follows the pointer")
        XCTAssertFalse(view.sizeLabelView.isHidden, "the outline's size shows")
        let magnifier = try XCTUnwrap(Render.check(view.magnifierView, "magnifier"))
        let drawn = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(magnifier.tiffRepresentation)))
        XCTAssertGreaterThan(try XCTUnwrap(drawn.colorAt(x: 20, y: 20)).alphaComponent, 0.5, "the zoom is drawn inside its own view")

        // The hole in the dimming is where the outline is (top-left coordinates), not mirrored.
        let size = view.bounds.size
        let canvas = try XCTUnwrap(CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        // The whole window's layers, composited as the window server would (a plain, y-up context).
        try XCTUnwrap(container.layer).render(in: canvas)
        let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(canvas.makeImage()))
        let inHole = try XCTUnwrap(bitmap.colorAt(x: 250, y: 200)), outside = try XCTUnwrap(bitmap.colorAt(x: 250, y: Int(size.height) - 150))
        XCTAssertLessThan(inHole.alphaComponent, 0.05, "the outlined window is clear")
        XCTAssertGreaterThan(outside.alphaComponent, 0.2, "the rest is dimmed")
    }
}
