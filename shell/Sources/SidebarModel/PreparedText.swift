import Foundation

/// Lowercased text prepared once for repeated substring and prefix tests on
/// every keystroke. Plain ASCII (no "\r", the one ASCII pair that is a single
/// Character) compares byte for byte, which is what `String.contains` and
/// `hasPrefix` do for such text. Anything else goes through those String
/// methods, so Unicode keeps their exact Character semantics.
public struct PreparedText: Sendable {
    public let text: String
    /// The UTF-8 bytes when the text is fast-path ASCII, else nil.
    private let ascii: ContiguousArray<UInt8>?

    /// `text` must already be lowercased when callers compare lowercased needles.
    public init(_ text: String) {
        self.text = text
        ascii = Self.isFastASCII(text) ? ContiguousArray(text.utf8) : nil
    }

    static func isFastASCII(_ text: String) -> Bool {
        text.utf8.allSatisfy { $0 < 0x80 && $0 != 0x0D }
    }

    public var isEmpty: Bool { text.isEmpty }

    public func contains(_ needle: Needle) -> Bool {
        guard let ascii, let bytes = needle.ascii, !bytes.isEmpty else { return text.contains(needle.text) }
        if bytes.count > ascii.count { return false }
        return ascii.withUnsafeBufferPointer { hay in
            bytes.withUnsafeBufferPointer { pin in
                memmem(hay.baseAddress, hay.count, pin.baseAddress, pin.count) != nil
            }
        }
    }

    public func hasPrefix(_ needle: Needle) -> Bool {
        guard let ascii, let bytes = needle.ascii else { return text.hasPrefix(needle.text) }
        return Self.bytes(ascii, at: 0, end: ascii.count, startWith: bytes)
    }

    /// Whether some word of the text starts with `needle`, a word being a run
    /// of letters and digits (`split(whereSeparator: { !$0.isLetter && !$0.isNumber })`).
    public func hasWord(withPrefix needle: Needle) -> Bool {
        guard let ascii, let bytes = needle.ascii else {
            return text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains { $0.hasPrefix(needle.text) }
        }
        var start: Int?
        for index in 0...ascii.count {
            let isWordByte = index < ascii.count && Self.isAlphanumeric(ascii[index])
            if isWordByte, start == nil { start = index }
            if !isWordByte, let wordStart = start {
                if Self.bytes(ascii, at: wordStart, end: index, startWith: bytes) { return true }
                start = nil
            }
        }
        return false
    }

    private static func isAlphanumeric(_ byte: UInt8) -> Bool {
        (byte >= 0x61 && byte <= 0x7A) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x30 && byte <= 0x39)
    }

    private static func bytes(_ hay: ContiguousArray<UInt8>, at start: Int, end: Int, startWith pin: ContiguousArray<UInt8>) -> Bool {
        guard pin.count <= end - start else { return false }
        for offset in pin.indices where hay[start + offset] != pin[offset] { return false }
        return true
    }

    /// A needle prepared once per keystroke.
    public struct Needle: Sendable {
        public let text: String
        fileprivate let ascii: ContiguousArray<UInt8>?

        public init(_ text: String) {
            self.text = text
            ascii = PreparedText.isFastASCII(text) ? ContiguousArray(text.utf8) : nil
        }
    }
}
