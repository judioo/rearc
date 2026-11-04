import Foundation

/// Page size and orientation for a host-rendered print PDF (Chromium
/// `printing`, ABI 1.28): the PDF is laid out on the paper the print panel
/// starts with, so printing it at 100% matches the sheet.
public struct PrintPaperSetup: Equatable, Sendable {
    /// Portrait width and height in inches (Chromium wants portrait plus a landscape flag).
    public var widthInches: Double
    public var heightInches: Double
    public var landscape: Bool

    public static let letter = PrintPaperSetup(widthInches: 8.5, heightInches: 11, landscape: false)

    public init(widthInches: Double, heightInches: Double, landscape: Bool) {
        self.widthInches = widthInches
        self.heightInches = heightInches
        self.landscape = landscape
    }

    /// From `NSPrintInfo.paperSize` (points, already swapped for landscape) and
    /// its orientation. A missing or implausible size falls back to Letter.
    public init(paperWidthPoints width: Double, heightPoints height: Double, landscape: Bool) {
        guard width.isFinite, height.isFinite, width >= 72, height >= 72, width <= 72 * 200, height <= 72 * 200 else {
            self = Self.letter
            self.landscape = landscape
            return
        }
        widthInches = min(width, height) / 72
        heightInches = max(width, height) / 72
        self.landscape = landscape
    }
}

/// Chromium page-range syntax ("1-3,5"), checked before the engine sees it:
/// ASCII digits, commas, dashes and spaces, ≤4096 bytes. Empty means every page.
public enum PrintPageRanges {
    public static let maxBytes = 4096

    public static func isWellFormed(_ ranges: String) -> Bool {
        guard ranges.utf8.count <= maxBytes else { return false }
        let trimmed = ranges.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return true }
        for part in trimmed.split(separator: ",", omittingEmptySubsequences: false) {
            let bounds = part.split(separator: "-", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard (1 ... 2).contains(bounds.count) else { return false }
            // "3-" runs to the last page, "-3" from the first (Chromium accepts both).
            let numbers = bounds.filter { !$0.isEmpty }
            guard !numbers.isEmpty,
                  numbers.allSatisfy({ $0.allSatisfy(\.isASCII) && Int($0).map { $0 >= 1 } == true }) else { return false }
            if bounds.count == 2, let low = Int(bounds[0]), let high = Int(bounds[1]), low > high { return false }
        }
        return true
    }
}

public enum PDFExportNaming {
    /// "Title.pdf" for Export as PDF: the page title, else its host, else "Page",
    /// without path separators or a leading dot, at most 200 characters.
    public static func suggestedFileName(title: String?, url: URL?) -> String {
        let candidates = [title, url?.host(), "Page"]
        var base = "Page"
        for candidate in candidates {
            let cleaned = clean(candidate ?? "")
            if !cleaned.isEmpty {
                base = cleaned
                break
            }
        }
        if base.lowercased().hasSuffix(".pdf") { base.removeLast(4) }
        return String(base.prefix(200)) + ".pdf"
    }

    private static func clean(_ raw: String) -> String {
        var text = raw.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        text = String(text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasPrefix(".") { text.removeFirst() }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum PDFSignature {
    /// True when `data` starts like a PDF file ("%PDF-").
    public static func isPDF(_ data: Data) -> Bool {
        data.starts(with: Array("%PDF-".utf8))
    }
}

/// One print at a time per page. Chromium posts a request for every
/// `window.print()` (throttled in the renderer); a request while that page's
/// print panel is open, or its PDF is being made, is dropped.
public struct PrintRequestGate<Key: Hashable>: Sendable where Key: Sendable {
    private var inFlight: Set<Key> = []

    public init() {}

    public func isPrinting(_ key: Key) -> Bool { inFlight.contains(key) }

    /// False when that page already prints.
    public mutating func begin(_ key: Key) -> Bool {
        inFlight.insert(key).inserted
    }

    public mutating func end(_ key: Key) {
        inFlight.remove(key)
    }
}
