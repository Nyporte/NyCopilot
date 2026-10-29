import Foundation

/// Calculate the expected insertion using the UTF-16 ranges supplied by macOS Accessibility.
public enum TextInsertion {
    public static func replacing(_ value: String, range: NSRange, with text: String) -> String? {
        let source = value as NSString
        guard range.location != NSNotFound, range.location >= 0, range.length >= 0,
              range.location <= source.length, range.length <= source.length - range.location else { return nil }
        // Foundation may bridge an index inside a surrogate pair; reject that explicitly.
        for offset in [range.location, range.location + range.length] where offset > 0 && offset < source.length {
            let previous = source.character(at: offset - 1)
            let current = source.character(at: offset)
            if (0xD800...0xDBFF).contains(previous) && (0xDC00...0xDFFF).contains(current) { return nil }
        }
        return source.replacingCharacters(in: range, with: text)
    }
}
