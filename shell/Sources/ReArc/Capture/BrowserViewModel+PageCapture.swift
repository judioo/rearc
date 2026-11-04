import AppKit
import SwiftUI
import SidebarModel

/// Engines that can find the element under a point (click-to-capture).
protocol PageElementLocating: AnyObject {
    func captureElementBounds(atFractionX x: Double, y: Double) async -> PageElementRect?
}

/// An element's viewport rectangle in CSS pixels, with the viewport size.
struct PageElementRect: Equatable {
    var bounds: ElementBounds
    var viewportWidth: Double
    var viewportHeight: Double

    init(bounds: ElementBounds, viewportWidth: Double, viewportHeight: Double) {
        self.bounds = bounds
        self.viewportWidth = viewportWidth
        self.viewportHeight = viewportHeight
    }

    /// From the script's `{x, y, width, height, vw, vh}`.
    init?(_ value: Any?) {
        guard let object = value as? [String: Any] else { return nil }
        func number(_ key: String) -> Double? { (object[key] as? NSNumber)?.doubleValue }
        guard let x = number("x"), let y = number("y"), let width = number("width"), let height = number("height"),
              let vw = number("vw"), let vh = number("vh") else { return nil }
        self.init(bounds: ElementBounds(x: x, y: y, width: width, height: height), viewportWidth: vw, viewportHeight: vh)
    }

    var fraction: CaptureRect? {
        CaptureCropping.elementFraction(bounds, viewportWidth: viewportWidth, viewportHeight: viewportHeight)
    }
}

enum PageCaptureScripts {
    /// The element under a point, widened to the nearest ancestor that is a
    /// picture, media, a block of content or at least 48×24 CSS pixels (Arc's
    /// click-to-capture finds "the thing you clicked", not a stray span).
    static func elementRect(fractionX x: Double, y: Double) -> String {
        """
        (function(){
          var px = \(x) * innerWidth, py = \(y) * innerHeight;
          var e = document.elementFromPoint(px, py);
          var blocks = /^(IMG|VIDEO|CANVAS|SVG|PICTURE|FIGURE|ARTICLE|SECTION|ASIDE|NAV|HEADER|FOOTER|MAIN|TABLE|PRE|BLOCKQUOTE|P|LI|UL|OL|FORM|IFRAME|H[1-6])$/i;
          while (e && e.parentElement && e !== document.body) {
            var r = e.getBoundingClientRect();
            if (blocks.test(e.tagName) || (r.width >= 48 && r.height >= 24)) break;
            e = e.parentElement;
          }
          if (!e) return null;
          var b = e.getBoundingClientRect();
          return { x: b.x, y: b.y, width: b.width, height: b.height, vw: innerWidth, vh: innerHeight };
        })()
        """
    }
}

/// Arc's Capture (EASEL-CAPTURE §4.1): over the page, drag a region or
/// click an element; the result is a library capture with Copy and Add to
/// Easel. Capture in Portrait Mode frames the visible page on the space theme.
extension BrowserViewModel {

    /// The window showing the capture overlay, and its tab.
    struct PageCaptureSession: Equatable {
        var tabID: Tab.ID
        var window: SidebarWindowID?
    }

    /// ReArc > Portrait Capture Watermark (Arc `WindowScreenshotWatermarkToggle`; on by default).
    static let portraitWatermarkKey = "ReArcPortraitCaptureWatermark"

    var portraitCaptureWatermark: Bool {
        get { externalLinkDefaults.object(forKey: Self.portraitWatermarkKey) as? Bool ?? true }
        set { externalLinkDefaults.set(newValue, forKey: Self.portraitWatermarkKey) }
    }

    /// Capture: the overlay over the key window's page.
    @discardableResult
    func beginPageCapture(in window: SidebarWindowID? = nil) -> String? {
        let target = window ?? store.keyWindowID
        guard librarySection(in: target) == nil, selectedEaselRef(in: target) == nil,
              let tab = selectedTab(in: target) else { return "No page to capture" }
        guard boostEditorDraftByTab[tab.id] == nil else { return "Close the boost editor first" }
        dismissCommandBar()
        pageCaptureSession = PageCaptureSession(tabID: tab.id, window: target)
        return nil
    }

    func cancelPageCapture() {
        pageCaptureSession = nil
    }

    /// The overlay's result: a dragged region, or a click at a point (both as
    /// fractions of the page view).
    func completePageCapture(region: CaptureRect?, clickAt point: (x: Double, y: Double)?) async {
        guard let session = pageCaptureSession, let tab = store.tab(withID: session.tabID) else { return }
        pageCaptureSession = nil
        let engine = engineHost.engine(for: tab, profileID: profileID(for: tab))
        var fraction = region
        var detail = CaptureDetail.region
        if fraction == nil, let point, let locator = engine as? PageElementLocating {
            fraction = await locator.captureElementBounds(atFractionX: point.x, y: point.y)?.fraction
            detail = .element
        }
        guard let fraction else {
            if point != nil { captureErrorMessage = "Nothing to capture there" }
            return
        }
        // Let the overlay leave the screen before the page is read.
        try? await Task.sleep(nanoseconds: 60_000_000)
        do {
            let png = try await engine.captureSnapshot(scope: .visible)
            guard let cropped = CaptureImaging.crop(png, to: fraction) else { throw PageCaptureError.imageFailed }
            saveCapture(cropped, from: tab, engine: engine, scope: .visible, detail: detail)
        } catch {
            captureErrorMessage = error.localizedDescription
        }
    }

    /// Capture in Portrait Mode: the visible page on the space's theme.
    func capturePortrait() async {
        guard let tab = store.selectedTab else { return }
        let engine = engineHost.engine(for: tab, profileID: profileID(for: tab))
        let theme = store.spaceContaining(tabID: tab.id).flatMap { store.space(withID: $0)?.theme } ?? store.activeSpace.theme
        let palette = SpaceThemePalette(theme: theme, darkAppearance: theme.appearance.isDark(systemDark: SystemAppearance.isSystemDark))
        do {
            let png = try await engine.captureSnapshot(scope: .visible)
            guard let framed = CaptureImaging.portrait(png, palette: palette, watermark: portraitCaptureWatermark) else {
                throw PageCaptureError.imageFailed
            }
            saveCapture(framed, from: tab, engine: engine, scope: .visible, detail: .portrait)
        } catch {
            captureErrorMessage = error.localizedDescription
        }
    }

    /// Stores a capture in the library and shows its Copy / Add to Easel card.
    func saveCapture(_ png: Data, from tab: Tab, engine: any WebEngine, scope: CaptureScope, detail: CaptureDetail?) {
        let record = CaptureRecord(
            sourceURL: engine.currentURL ?? tab.url,
            sourceTitle: engine.pageTitle ?? tab.title,
            scope: scope,
            detail: detail
        )
        do {
            try captureFileStore.savePNG(png, for: record)
            store.addCapture(record)
            lastCapturePreview = record
            isCapturePreviewPresented = true
        } catch {
            captureErrorMessage = error.localizedDescription
        }
    }
}

enum PageCaptureError: LocalizedError {
    case imageFailed
    var errorDescription: String? { "The capture could not be made." }
}

/// PNG cropping and the portrait frame, with CoreGraphics.
enum CaptureImaging {
    static func cgImage(_ png: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    static func png(_ image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    static func crop(_ data: Data, to fraction: CaptureRect) -> Data? {
        guard let image = cgImage(data) else { return nil }
        let rect = CaptureCropping.pixelRect(fraction, imageWidth: image.width, imageHeight: image.height)
        guard let cropped = image.cropping(to: CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)) else { return nil }
        return png(cropped)
    }

    static func portrait(_ data: Data, palette: SpaceThemePalette, watermark: Bool) -> Data? {
        guard let image = cgImage(data) else { return nil }
        let layout = PortraitCaptureLayout(imageWidth: Double(image.width), imageHeight: Double(image.height), watermark: watermark)
        let width = Int(layout.canvasWidth), height = Int(layout.canvasHeight)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Core Graphics has a bottom-left origin; the layout is top-left.
        func flipped(_ r: CaptureRect) -> CGRect {
            CGRect(x: r.x, y: layout.canvasHeight - r.y - r.height, width: r.width, height: r.height)
        }
        let colors = palette.colors.map { CGColor(srgbRed: $0.red, green: $0.green, blue: $0.blue, alpha: 1) } as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: nil) {
            context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: Double(height)), end: CGPoint(x: Double(width), y: 0), options: [])
        }
        let frame = flipped(layout.image)
        let path = CGPath(roundedRect: frame, cornerWidth: layout.cornerRadius, cornerHeight: layout.cornerRadius, transform: nil)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -layout.shadowRadius * 0.3), blur: layout.shadowRadius,
                          color: CGColor(gray: 0, alpha: 0.35))
        context.addPath(path)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fillPath()
        context.restoreGState()
        context.saveGState()
        context.addPath(path)
        context.clip()
        context.draw(image, in: frame)
        context.restoreGState()
        if let mark = layout.watermark {
            let text = NSAttributedString(string: "ReArc", attributes: [
                .font: NSFont.systemFont(ofSize: mark.fontSize, weight: .semibold),
                .foregroundColor: palette.prefersLightForeground ? NSColor.white.withAlphaComponent(0.75) : NSColor.black.withAlphaComponent(0.55),
            ])
            let size = text.size()
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            text.draw(at: NSPoint(x: mark.x - size.width, y: layout.canvasHeight - mark.y))
            NSGraphicsContext.restoreGraphicsState()
        }
        return context.makeImage().flatMap(png)
    }
}
