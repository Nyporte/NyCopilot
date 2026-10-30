import CoreGraphics
import Vision

/// Text in an image, read by Apple's on-device Vision framework: no models of our own, and nothing
/// leaves the Mac.
enum TextRecognizer {
    /// One recognized line, with its box normalized to the image and a top-left origin.
    struct Line: Equatable {
        let text: String
        let box: CGRect
    }

    /// Recognizes every line, then lays them out in reading order.
    static func text(in image: CGImage) async throws -> String {
        layout(try await lines(in: image))
    }

    static func lines(in image: CGImage) async throws -> [Line] {
        try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            // Vision picks the language per image; a fixed list makes it misread other scripts.
            request.automaticallyDetectsLanguage = true
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            return (request.results ?? []).compactMap { observation in
                guard let text = observation.topCandidates(1).first?.string, !text.isEmpty else { return nil }
                let box = observation.boundingBox
                return Line(text: text, box: CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height))
            }
        }.value
    }

    /// Lines that share a row are joined left to right; a gap taller than a line starts a new paragraph.
    static func layout(_ lines: [Line]) -> String {
        var rows: [[Line]] = []
        for line in lines.sorted(by: { $0.box.midY < $1.box.midY }) {
            if let last = rows.last?.last, abs(line.box.midY - last.box.midY) < min(line.box.height, last.box.height) / 2 {
                rows[rows.count - 1].append(line)
            } else {
                rows.append([line])
            }
        }
        var output = ""
        var previous: CGRect?
        for row in rows {
            let sorted = row.sorted { $0.box.minX < $1.box.minX }
            let text = sorted.dropFirst().reduce(sorted[0].text) { joined, line in
                joined + (isCJK(joined.last) && isCJK(line.text.first) ? "" : " ") + line.text
            }
            let box = sorted.map(\.box).reduce(sorted[0].box) { $0.union($1) }
            if let previous {
                output += box.minY - previous.maxY > min(box.height, previous.height) * 1.2 ? "\n\n" : "\n"
            }
            output += text
            previous = box
        }
        return output
    }

    /// Chinese, Japanese, and Korean don't put spaces between words.
    private static func isCJK(_ character: Character?) -> Bool {
        guard let scalar = character?.unicodeScalars.first?.value else { return false }
        return (0x3000...0x9FFF).contains(scalar) || (0xAC00...0xD7AF).contains(scalar) || (0xF900...0xFAFF).contains(scalar)
            || (0xFF00...0xFFEF).contains(scalar)
    }
}
