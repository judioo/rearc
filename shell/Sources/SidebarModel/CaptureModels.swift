import Foundation

public enum CaptureScope: String, Codable, CaseIterable {
    case visible
    case fullPage
}

/// How a visible-area capture was framed (Arc's drag-to-capture,
/// click-to-capture and Capture in Portrait Mode, EASEL-CAPTURE §4.1). A
/// separate optional field, so builds before wave 28, which know only
/// `visible` and `fullPage`, still read the capture index.
public enum CaptureDetail: String, Codable, CaseIterable, Sendable {
    case region
    case element
    case portrait
}

public extension CaptureRecord {
    /// "Region", "Element", "Portrait", "Visible" or "Full page".
    var kindTitle: String {
        switch detail {
        case .region?: return "Region"
        case .element?: return "Element"
        case .portrait?: return "Portrait"
        case nil: return scope == .fullPage ? "Full page" : "Visible"
        }
    }
}

public struct CaptureRecord: Identifiable, Equatable, Codable {
    public var id: UUID
    public var sourceURL: URL?
    public var sourceTitle: String
    public var createdAt: Date
    public var scope: CaptureScope
    public var detail: CaptureDetail?
    /// PNG filename under the captures directory (`{id}.png`).
    public var fileName: String

    public init(
        id: UUID = UUID(),
        sourceURL: URL?,
        sourceTitle: String,
        createdAt: Date = Date(),
        scope: CaptureScope,
        detail: CaptureDetail? = nil,
        fileName: String? = nil
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.sourceTitle = sourceTitle
        self.createdAt = createdAt
        self.scope = scope
        self.detail = detail
        self.fileName = Self.canonicalFileName(id: id, proposed: fileName)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        sourceURL = try c.decodeIfPresent(URL.self, forKey: .sourceURL)
        sourceTitle = try c.decode(String.self, forKey: .sourceTitle)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        scope = try c.decode(CaptureScope.self, forKey: .scope)
        detail = (try? c.decodeIfPresent(CaptureDetail.self, forKey: .detail)) ?? nil
        let decodedName = try c.decodeIfPresent(String.self, forKey: .fileName)
        fileName = CaptureRecord.canonicalFileName(id: id, proposed: decodedName)
    }

    private enum CodingKeys: String, CodingKey {
        case id, sourceURL, sourceTitle, createdAt, scope, detail, fileName
    }

    public static func canonicalFileName(id: UUID, proposed: String?) -> String {
        let expected = "\(id.uuidString).png"
        guard let proposed, proposed == expected else { return expected }
        return expected
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(sourceURL, forKey: .sourceURL)
        try c.encode(sourceTitle, forKey: .sourceTitle)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(scope, forKey: .scope)
        try c.encodeIfPresent(detail, forKey: .detail)
        try c.encode(fileName, forKey: .fileName)
    }
}

public enum CaptureStoreOps {
    public static func insert(_ record: CaptureRecord, into captures: inout [UUID: CaptureRecord]) {
        captures[record.id] = record
    }

    public static func remove(id: UUID, from captures: inout [UUID: CaptureRecord]) -> CaptureRecord? {
        captures.removeValue(forKey: id)
    }
}

/// A rectangle in the model layer (no CoreGraphics), in whatever unit the
/// caller uses: fractions of a view, CSS pixels or image pixels.
public struct CaptureRect: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public static let unit = CaptureRect(x: 0, y: 0, width: 1, height: 1)
}

/// Region and element capture crop a viewport snapshot: the region as a
/// fraction of the page view (top-left origin), turned into image pixels.
public enum CaptureCropping {
    /// Below this many points a drag is a click, not a region.
    public static let minimumDragPoints = 8.0

    /// The dragged rectangle as a fraction of the view, clipped to it; nil
    /// for a drag too small to be a region.
    public static func dragFraction(from start: (x: Double, y: Double), to end: (x: Double, y: Double),
                                    viewWidth: Double, viewHeight: Double) -> CaptureRect? {
        guard viewWidth > 0, viewHeight > 0 else { return nil }
        let x0 = min(max(min(start.x, end.x), 0), viewWidth), x1 = min(max(max(start.x, end.x), 0), viewWidth)
        let y0 = min(max(min(start.y, end.y), 0), viewHeight), y1 = min(max(max(start.y, end.y), 0), viewHeight)
        guard x1 - x0 >= minimumDragPoints, y1 - y0 >= minimumDragPoints else { return nil }
        return CaptureRect(x: x0 / viewWidth, y: y0 / viewHeight, width: (x1 - x0) / viewWidth, height: (y1 - y0) / viewHeight)
    }

    /// An element's viewport rectangle (CSS pixels, from the page) as a
    /// fraction of the viewport, clipped to what is on screen; nil when none of it is.
    public static func elementFraction(_ bounds: ElementBounds, viewportWidth: Double, viewportHeight: Double) -> CaptureRect? {
        guard viewportWidth > 0, viewportHeight > 0 else { return nil }
        let x0 = max(bounds.x, 0), y0 = max(bounds.y, 0)
        let x1 = min(bounds.x + bounds.width, viewportWidth), y1 = min(bounds.y + bounds.height, viewportHeight)
        guard x1 - x0 >= 1, y1 - y0 >= 1 else { return nil }
        return CaptureRect(x: x0 / viewportWidth, y: y0 / viewportHeight, width: (x1 - x0) / viewportWidth, height: (y1 - y0) / viewportHeight)
    }

    /// The fraction in whole image pixels, inside the image and at least one pixel.
    public static func pixelRect(_ fraction: CaptureRect, imageWidth: Int, imageHeight: Int) -> CaptureRect {
        let w = Double(imageWidth), h = Double(imageHeight)
        let x0 = (min(max(fraction.x, 0), 1) * w).rounded(.down)
        let y0 = (min(max(fraction.y, 0), 1) * h).rounded(.down)
        let x1 = (min(max(fraction.x + fraction.width, 0), 1) * w).rounded(.up)
        let y1 = (min(max(fraction.y + fraction.height, 0), 1) * h).rounded(.up)
        let width = max(min(x1, w) - x0, 1), height = max(min(y1, h) - y0, 1)
        return CaptureRect(x: min(x0, max(w - 1, 0)), y: min(y0, max(h - 1, 0)), width: width, height: height)
    }
}

/// Capture in Portrait Mode (Arc `capturePrettyScreenshot`, EASEL-CAPTURE
/// §4.2): the capture framed on the space's theme with rounded corners, a
/// shadow and, unless turned off, a small watermark
/// (`portraitCaptureHidesWatermark`). The proportions are ReArc's.
public struct PortraitCaptureLayout: Equatable, Sendable {
    public var canvasWidth: Double
    public var canvasHeight: Double
    /// Where the capture sits, top-left origin.
    public var image: CaptureRect
    public var cornerRadius: Double
    public var shadowRadius: Double
    /// The watermark's baseline origin, bottom-right inside the margin; nil when hidden.
    public var watermark: (x: Double, y: Double, fontSize: Double)?

    public static func == (a: PortraitCaptureLayout, b: PortraitCaptureLayout) -> Bool {
        a.canvasWidth == b.canvasWidth && a.canvasHeight == b.canvasHeight && a.image == b.image
            && a.cornerRadius == b.cornerRadius && a.shadowRadius == b.shadowRadius
            && a.watermark?.x == b.watermark?.x && a.watermark?.y == b.watermark?.y && a.watermark?.fontSize == b.watermark?.fontSize
    }

    public init(imageWidth: Double, imageHeight: Double, watermark: Bool) {
        let shorter = max(min(imageWidth, imageHeight), 1)
        let margin = (shorter * 0.08).rounded()
        canvasWidth = imageWidth + margin * 2
        canvasHeight = imageHeight + margin * 2
        image = CaptureRect(x: margin, y: margin, width: imageWidth, height: imageHeight)
        cornerRadius = (shorter * 0.025).rounded()
        shadowRadius = (margin * 0.4).rounded()
        if watermark {
            let fontSize = max((margin * 0.32).rounded(), 9)
            self.watermark = (x: canvasWidth - margin, y: canvasHeight - (margin - fontSize) / 2, fontSize: fontSize)
        } else {
            self.watermark = nil
        }
    }
}
