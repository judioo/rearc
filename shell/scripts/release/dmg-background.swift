// Draws the DMG window background for scripts/make-dmg.sh: brand canvas, a cobalt arrow
// from the app icon to the Applications link, and the link's label (the link itself is
// named " ", as Chromium's DMG layout in chrome/installer/mac/generate_dsstore.py expects).
// Geometry matches that script's defaults: 633 x 320 window, icons centered at (163, 148)
// and (470, 148), 128 pt icons. make-dmg.sh combines the 1x and @2x PNGs into one
// multi-resolution TIFF (tiffutil -cathidpicheck), the form Finder uses on Retina displays.
// Usage: swift dmg-background.swift OUT_DIR   (writes background.png and background@2x.png)
import AppKit

let width: CGFloat = 633, height: CGFloat = 320
let appCenter = CGPoint(x: 163, y: 148), linkCenter = CGPoint(x: 470, y: 148)
let canvas = NSColor(srgbRed: 0xF8 / 255, green: 0xFA / 255, blue: 0xFC / 255, alpha: 1)
let cobalt = NSColor(srgbRed: 0x25 / 255, green: 0x63 / 255, blue: 0xEB / 255, alpha: 1)
let muted = NSColor(srgbRed: 0x64 / 255, green: 0x74 / 255, blue: 0x8B / 255, alpha: 1)
let primary = NSColor(srgbRed: 0x0F / 255, green: 0x17 / 255, blue: 0x2A / 255, alpha: 1)

func render(scale: CGFloat, to url: URL) throws {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    canvas.setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()

    // Finder positions are top-left based; AppKit draws bottom-left.
    let y = height - appCenter.y
    let arrow = NSBezierPath()
    arrow.move(to: CGPoint(x: appCenter.x + 84, y: y))
    arrow.line(to: CGPoint(x: linkCenter.x - 96, y: y))
    arrow.lineWidth = 6
    arrow.lineCapStyle = .round
    cobalt.setStroke()
    arrow.stroke()
    let head = NSBezierPath()
    head.move(to: CGPoint(x: linkCenter.x - 84, y: y))
    head.line(to: CGPoint(x: linkCenter.x - 104, y: y + 14))
    head.line(to: CGPoint(x: linkCenter.x - 104, y: y - 14))
    head.close()
    cobalt.setFill()
    head.fill()

    func draw(_ text: String, size: CGFloat, color: NSColor, weight: NSFont.Weight, centerX: CGFloat, baseline: CGFloat) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        string.draw(at: CGPoint(x: centerX - string.size().width / 2, y: baseline))
    }
    // Under the link icon, where Finder would put a label (128 pt icon, 12 pt text).
    draw("Applications", size: 12, color: primary, weight: .regular, centerX: linkCenter.x, baseline: y - 64 - 18)
    draw("Drag ReArc to Applications to install", size: 13, color: muted, weight: .medium,
         centerX: width / 2, baseline: 28)
    NSGraphicsContext.restoreGraphicsState()
    guard let png = rep.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    try png.write(to: url)
}

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
try render(scale: 1, to: out.appendingPathComponent("background.png"))
try render(scale: 2, to: out.appendingPathComponent("background@2x.png"))
