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

    /// Whether a line is worth translating into the language with this code: it has letters, more than
    /// one, and isn't clearly in that language already.
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

    /// The language code NaturalLanguage uses for one of NyCopilot's language names, when known.
    static func code(for language: String) -> String? {
        let known = ["english": "en", "simplified chinese": "zh-Hans", "chinese": "zh-Hans", "traditional chinese": "zh-Hant",
                     "japanese": "ja", "korean": "ko", "spanish": "es", "french": "fr", "german": "de", "italian": "it",
                     "portuguese": "pt", "brazilian portuguese": "pt", "russian": "ru", "arabic": "ar", "dutch": "nl",
                     "swedish": "sv", "danish": "da", "norwegian": "nb", "finnish": "fi", "polish": "pl", "turkish": "tr",
                     "ukrainian": "uk", "vietnamese": "vi", "thai": "th", "indonesian": "id", "hindi": "hi", "greek": "el",
                     "hebrew": "he", "czech": "cs", "hungarian": "hu", "romanian": "ro"]
        return known[language.trimmingCharacters(in: .whitespaces).lowercased()]
    }
}
