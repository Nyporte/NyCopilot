import AppKit
import NaturalLanguage
import Vision

/// Lines of text on a screen and where they are, read by Apple's on-device Vision framework — for
/// translating in place.
enum ScreenText {
    struct Line {
        let text: String
        /// In the image's points, top-left origin.
        let rect: CGRect
    }

    /// Every line in `image`, whose pixels are `scale` times its points.
    static func lines(in image: CGImage, scale: CGFloat) async throws -> [Line] {
        try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            // Vision picks the language per line; a fixed list misreads other scripts.
            request.automaticallyDetectsLanguage = true
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            let width = CGFloat(image.width) / scale, height = CGFloat(image.height) / scale
            return (request.results ?? []).compactMap { observation in
                guard let text = observation.topCandidates(1).first?.string else { return nil }
                let box = observation.boundingBox
                return Line(text: text, rect: CGRect(x: box.minX * width, y: (1 - box.maxY) * height,
                                                     width: box.width * width, height: box.height * height))
            }
        }.value
    }

    /// The original's font size, judged by width — how wide the line's text is in the system font
    /// against how wide it is on screen (Vision's widths are within a few percent of the ink) — since
    /// the box's height swings from 0.8× to 1.4× the size with descenders and accents, and only keeps
    /// the guess sane. The system font spaces letters differently at each size, so the measurement is
    /// taken near the answer and refined once.
    static func fontSize(of line: Line) -> CGFloat {
        var size = line.rect.height
        for _ in 0..<2 {
            let width = (line.text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size)]).width
            guard width > 0 else { break }
            size = line.rect.width * size / width
        }
        return min(max(size, line.rect.height * 0.65), line.rect.height * 1.3)
    }

    /// Lines joined back into the text they were wrapped from: a hyphen that split a word goes, and
    /// Chinese, Japanese, and Korean lines meet without a space.
    static func joined(_ lines: [String]) -> String {
        lines.map { $0.trimmingCharacters(in: .whitespaces) }.reduce("") { text, line in
            guard let end = text.last, let start = line.first else { return text + line }
            if end == "-", start.isLowercase { return String(text.dropLast()) + line }
            if isCJK(end) || isCJK(start) { return text + line }
            return text + " " + line
        }
    }

    static func isCJK(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first?.value else { return false }
        return (0x3000...0x9FFF).contains(scalar) || (0xAC00...0xD7AF).contains(scalar) || (0xFF00...0xFFEF).contains(scalar)
    }

    /// Whether a line is worth translating into the language with this BCP-47 code (the core's
    /// `locale` for it): it has letters, more than one, and isn't clearly in that language already.
    static func needsTranslation(_ text: String, into code: String?) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.unicodeScalars.filter({ CharacterSet.letters.contains($0) }).count >= 2 else { return false }
        guard let code else { return true }
        // Short CJK labels are often too short for the recognizer; their script settles it.
        let scalars = trimmed.unicodeScalars
        let han = scalars.contains { (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value) }
        let kana = scalars.contains { (0x3040...0x30FF).contains($0.value) }
        let hangul = scalars.contains { (0xAC00...0xD7AF).contains($0.value) }
        let latin = scalars.contains { $0.isASCII && CharacterSet.letters.contains($0) }
        if !latin {
            if code.hasPrefix("zh"), han, !kana, !hangul { return false }
            if code == "ja", kana { return false }
            if code == "ko", hangul { return false }
        }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)
        guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first else { return true }
        return !(confidence >= 0.8 && language.rawValue == code)
    }
}
