import AppKit

/// How lines of screen text become paragraphs: wrapped lines join, columns and headings stay apart.
extension ScreenTranslator {
    // MARK: Blocks of text

    final class Display {
        let screen: NSScreen
        let overlay: TranslationOverlay
        /// The last glance: one grey byte per 8 × 8 points.
        var glance: (pixels: [UInt8], width: Int, height: Int)?
        /// Lines on screen, and the blocks they make up.
        var entries: [Entry] = []
        var paragraphs: [Paragraph] = []
        /// What needs reading again (screen points, top-left), and when it last changed.
        var pending: CGRect?
        var changedAt = Date.distantPast
        var lastRead = Date.distantPast
        var reading = false
        /// Changes while a read was under way: the lines it found there may already be gone.
        var changedDuringRead: [CGRect] = []

        init(screen: NSScreen, overlay: TranslationOverlay) {
            self.screen = screen
            self.overlay = overlay
            pending = CGRect(origin: .zero, size: screen.frame.size)
        }
    }

    struct Entry {
        let line: ScreenText.Line
        let background: NSColor
        /// The original's font size, as best it can be told.
        let fontSize: CGFloat
    }

    /// Lines wrapped from one paragraph: pointed at and translated as one block.
    struct Paragraph {
        let entries: [Entry]
        let text: String
        let rect: CGRect
        /// Not already in the target language (nor just numbers or symbols): it gets a card.
        let needsTranslation: Bool
    }

    /// The text in an image, paragraph by paragraph, read the way the screen is: for translating a
    /// screenshot. `scale` is the image's pixels per point.
    static func paragraphs(in image: CGImage, scale: CGFloat) async throws -> [String] {
        let lines = try await ScreenText.lines(in: image, scale: scale)
        return paragraphs(entries(lines, from: PixelSampler(image, scale: scale, origin: .zero)), language: nil).map(\.text)
    }

    /// Lines with what grouping them takes: the background around each and its font size.
    static func entries(_ lines: [ScreenText.Line], from pixels: PixelSampler) -> [Entry] {
        lines.map { Entry(line: $0, background: pixels.background(around: $0.rect), fontSize: ScreenText.fontSize(of: $0)) }
    }

    /// Lines into paragraphs: directly below one another at line spacing, in the same column, the
    /// same size, on the same background. Only a line long enough to have wrapped carries on to the
    /// next — short labels stacked in a sidebar or a menu stay apart, and a paragraph's short last line
    /// ends it — and a bullet or number starts a new one. `code` is the language read into.
    static func paragraphs(_ entries: [Entry], language code: String?) -> [Paragraph] {
        var groups: [[Entry]] = []
        for entry in entries.sorted(by: { $0.line.rect.minY < $1.line.rect.minY }) {
            let candidates = groups.indices.filter { continues(groups[$0], with: entry) }
            // The paragraph whose last line sits closest above.
            if let index = candidates.max(by: { groups[$0].last!.line.rect.maxY < groups[$1].last!.line.rect.maxY }) {
                groups[index].append(entry)
            } else {
                groups.append([entry])
            }
        }
        return groups.map { group in
            let text = ScreenText.joined(group.map(\.line.text))
            return Paragraph(entries: group, text: text, rect: group.map(\.line.rect).reduce(group[0].line.rect) { $0.union($1) },
                             needsTranslation: ScreenText.needsTranslation(text, into: code))
        }
    }

    static func continues(_ group: [Entry], with next: Entry) -> Bool {
        let last = group.last!, above = last.line.rect, below = next.line.rect, size = last.fontSize
        guard abs(next.fontSize - size) <= size * 0.2 else { return false }
        let gap = below.minY - above.maxY
        guard gap >= -size * 0.3, gap <= size * 0.75 else { return false }
        let overlap = min(above.maxX, below.maxX) - max(above.minX, below.minX)
        guard abs(above.minX - below.minX) <= max(size * 1.2, 8) || overlap >= min(above.width, below.width) * 0.8 else { return false }
        guard last.background.resembles(next.background) else { return false }
        let widest = max(group.map(\.line.rect.width).max()!, below.width)
        guard above.width >= widest * 0.75, above.width >= size * 12 else { return false }
        let start = next.line.text.trimmingCharacters(in: .whitespaces)
        if let first = start.first, "•·-–—*▪◦●".contains(first) || (first.isNumber && start.dropFirst().prefix(2).contains { ".)、".contains($0) }) {
            return false
        }
        return true
    }

    /// The lines left once every block touching a change is taken down whole, and the areas of those
    /// blocks (to read again).
    static func removing(blocksTouching changed: [CGRect], from entries: [Entry], in blocks: [Paragraph]) -> (kept: [Entry], touched: [CGRect]) {
        let touched = blocks.filter { block in block.entries.contains { entry in changed.contains { $0.intersects(entry.line.rect) } } }
        let gone = touched.flatMap { $0.entries.map(\.line.rect) }
        let kept = entries.filter { entry in !gone.contains(entry.line.rect) && !changed.contains { $0.intersects(entry.line.rect) } }
        return (kept, touched.map(\.rect))
    }

}
