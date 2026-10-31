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
}
