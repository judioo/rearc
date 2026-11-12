import Foundation

/// Text from pages (titles, file names) on its way into a title or a file
/// name: what Tidy Tab Titles, Tidy Downloads and Tidy Tabs share.
public enum TidyText {
    /// Bidirectional overrides and isolates, zero-width and other invisible
    /// format characters, on top of every control character.
    static let invisible: CharacterSet = {
        var set = CharacterSet.controlCharacters
        set.insert(charactersIn: "\u{00AD}\u{061C}\u{180E}\u{FEFF}\u{2028}\u{2029}")
        set.insert(charactersIn: "\u{200B}"..."\u{200F}")
        set.insert(charactersIn: "\u{202A}"..."\u{202E}")
        set.insert(charactersIn: "\u{2060}"..."\u{2069}")
        set.insert(charactersIn: "\u{E0000}"..."\u{E007F}")
        return set
    }()

    /// Removes control, bidirectional and invisible characters.
    public static func stripInvisible(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { !invisible.contains($0) }))
    }

    /// Invisible characters gone and runs of whitespace (newlines too) as one space.
    public static func singleLine(_ text: String) -> String {
        stripInvisible(text.replacingOccurrences(of: "\n", with: " ")).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// At most `limit` characters, cut at the last space when one is in the back half.
    public static func truncated(_ text: String, to limit: Int) -> String {
        guard limit > 0 else { return "" }
        guard text.count > limit else { return text }
        let cut = String(text.prefix(limit))
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) >= limit / 2 {
            return String(cut[..<space]).trimmingCharacters(in: .whitespaces)
        }
        return cut.trimmingCharacters(in: .whitespaces)
    }
}
