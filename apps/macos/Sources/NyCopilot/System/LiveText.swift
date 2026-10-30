import AppKit
import VisionKit

/// Live Text from macOS (VisionKit): the same on-device text recognition, highlight, and in-place
/// selection as Preview and Photos. Nothing leaves the Mac, and there are no models of our own.
@MainActor
enum LiveText {
    private static let analyzer = ImageAnalyzer()

    static func analyze(_ image: CGImage) async throws -> ImageAnalysis {
        try await analyzer.analyze(image, orientation: .up, configuration: ImageAnalyzer.Configuration(.text))
    }

    static func lineCount(_ analysis: ImageAnalysis) -> Int {
        analysis.hasResults(for: .text) ? analysis.transcript.split(whereSeparator: \.isNewline).count : 0
    }

    /// An overlay whose image fills its bounds exactly, so the text lines up with the pixels beneath.
    static func overlay(frame: CGRect) -> ImageAnalysisOverlayView {
        let overlay = ImageAnalysisOverlayView(frame: frame)
        overlay.delegate = FillsBounds.shared
        overlay.preferredInteractionTypes = .textSelection
        return overlay
    }

    /// Attach a finished analysis: the text glows where it is and can be selected.
    static func show(_ analysis: ImageAnalysis?, on overlay: ImageAnalysisOverlayView) {
        overlay.analysis = analysis
        overlay.selectableItemsHighlighted = true
        // VisionKit's own Live Text button would only repeat T; it appears with each new analysis.
        overlay.setSupplementaryInterfaceHidden(true, animated: false)
    }

    /// What ⌘C copies: the selection (macOS 14 and later can tell), otherwise everything.
    static func textToCopy(from overlay: ImageAnalysisOverlayView) -> String {
        if #available(macOS 14, *), overlay.hasActiveTextSelection, !overlay.selectedText.isEmpty { return overlay.selectedText }
        return overlay.analysis?.transcript ?? ""
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private final class FillsBounds: ImageAnalysisOverlayViewDelegate {
        static let shared = FillsBounds()
        func contentsRect(for overlayView: ImageAnalysisOverlayView) -> CGRect { CGRect(x: 0, y: 0, width: 1, height: 1) }
    }
}
