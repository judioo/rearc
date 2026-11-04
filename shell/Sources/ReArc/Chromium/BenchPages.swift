#if REARC_CHROMIUM
import AppKit
import Foundation
import SidebarModel

/// The bench's deterministic page set (docs/PERFORMANCE-PLAN.md §1.4,
/// "Loopback fixtures"), served by `LoopbackFixtureServer` on 127.0.0.1. The
/// same bytes every run: generated from a fixed seed, no external resources
/// (no fonts, scripts or images from other origins), so a page never needs
/// the network. Query strings are ignored, which gives each visit its own URL.
enum BenchPages {
    static let names = ["article", "images", "spa", "list"]
    static let imageCount = 48

    /// The `navigation` and `paint` entries the page itself saw (cross-check of the engine's events).
    static let navigationTimingScript = """
    (() => { const n = performance.getEntriesByType('navigation')[0];
      const p = performance.getEntriesByType('paint').find(e => e.name === 'first-contentful-paint');
      return { ttfb: n ? n.responseStart : -1, dcl: n ? n.domContentLoadedEventEnd : -1,
               load: n ? n.loadEventEnd : -1, fcp: p ? p.startTime : -1 }; })()
    """

    /// Writes the page set as files: DIR/bench/<name>.html, spa.js, img/<n>.png
    /// (`scripts/bench_chrome.py` serves them on loopback with the same paths).
    static func dump(to directory: URL) throws {
        let bench = directory.appendingPathComponent("bench", isDirectory: true)
        try FileManager.default.createDirectory(at: bench.appendingPathComponent("img"), withIntermediateDirectories: true)
        for (name, data) in [("article", article), ("images", imagesPage), ("spa", spa), ("list", list)] {
            try data.write(to: bench.appendingPathComponent(name + ".html"))
        }
        try spaScript.write(to: bench.appendingPathComponent("spa.js"))
        for (index, image) in images.enumerated() {
            try image.write(to: bench.appendingPathComponent("img/\(index).png"))
        }
    }

    /// Route lookup for the fixture server (any queue).
    static func route(_ path: String) -> (body: Data, type: String)? {
        if path.hasPrefix("/bench/tab/") {
            let n = path.dropFirst("/bench/tab/".count)
            return (Data(("<!doctype html><title>Bench tab \(n)</title><body style=\"font:16px -apple-system;margin:24px\">"
                + "<h1>Bench tab \(n)</h1><p>Loopback page for sidebar rows.</p>").utf8), html)
        }
        if path.hasPrefix("/bench/img/"), let n = Int(path.dropFirst("/bench/img/".count).replacingOccurrences(of: ".png", with: "")),
           n >= 0, n <= imageCount {
            return (images[n], "image/png")
        }
        switch path {
        case "/bench/article": return (article, html)
        case "/bench/images": return (imagesPage, html)
        case "/bench/spa": return (spa, html)
        case "/bench/spa.js": return (spaScript, "text/javascript; charset=utf-8")
        case "/bench/list": return (list, html)
        default: return nil
        }
    }

    private static let html = "text/html; charset=utf-8"

    private static func words(_ count: Int, seed: UInt64) -> [String] {
        var random = SplitMix64(seed: seed)
        let vocabulary = ["browser", "engine", "sidebar", "render", "frame", "network", "layout", "paint", "compositor", "space",
                          "profile", "tab", "command", "history", "memory", "process", "thread", "signal", "latency", "budget",
                          "the", "a", "of", "and", "to", "in", "is", "for", "with", "on"]
        return (0 ..< count).map { _ in vocabulary[Int(random.next() % UInt64(vocabulary.count))] }
    }

    private static func paragraphs(_ count: Int, wordsEach: Int, seed: UInt64) -> [String] {
        let all = words(count * wordsEach, seed: seed)
        return (0 ..< count).map { all[($0 * wordsEach) ..< (($0 + 1) * wordsEach)].joined(separator: " ").capitalizedFirst + "." }
    }

    /// A long text article (about 60 KB): headings and paragraphs, system font.
    static let article: Data = {
        let body = paragraphs(120, wordsEach: 70, seed: 11).enumerated().map { index, text in
            (index % 12 == 0 ? "<h2>Section \(index / 12 + 1)</h2>" : "") + "<p>\(text)</p>"
        }.joined()
        return Data(("<!doctype html><html><head><meta charset=utf-8><title>Bench article</title>"
            + "<style>body{font:17px/1.55 -apple-system;max-width:720px;margin:32px auto;color:#222}h1{font-size:40px}</style></head>"
            + "<body><h1>The bench article</h1>\(body)</body></html>").utf8)
    }()

    /// A hero image plus a grid of 48 PNGs (seeded colour blocks, 480 × 320).
    static let imagesPage: Data = {
        let grid = (1 ... imageCount).map { "<img src=\"/bench/img/\($0).png\" width=240 height=160 alt=\"\">" }.joined()
        return Data(("<!doctype html><html><head><meta charset=utf-8><title>Bench images</title>"
            + "<style>body{margin:0;font:15px -apple-system}img{display:inline-block;margin:4px}</style></head><body>"
            + "<img src=\"/bench/img/0.png\" width=960 height=640 alt=\"hero\"><div>\(grid)</div></body></html>").utf8)
    }()

    /// Image 0 is the 960 × 640 hero; 1…48 are 480 × 320.
    static let images: [Data] = (0 ... imageCount).map { index in
        png(width: index == 0 ? 960 : 480, height: index == 0 ? 640 : 320, seed: UInt64(100 + index))
    }

    private static func png(width: Int, height: Int, seed: UInt64) -> Data {
        var random = SplitMix64(seed: seed)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: width * 4, bitsPerPixel: 32),
              let pixels = rep.bitmapData else { return Data() }
        let block = 8
        for by in stride(from: 0, to: height, by: block) {
            for bx in stride(from: 0, to: width, by: block) {
                let value = random.next()
                let r = UInt8(truncatingIfNeeded: value), g = UInt8(truncatingIfNeeded: value >> 8), b = UInt8(truncatingIfNeeded: value >> 16)
                for y in by ..< min(by + block, height) {
                    for x in bx ..< min(bx + block, width) {
                        let offset = (y * width + x) * 4
                        pixels[offset] = r; pixels[offset + 1] = g; pixels[offset + 2] = b; pixels[offset + 3] = 255
                    }
                }
            }
        }
        return rep.representation(using: .png, properties: [:]) ?? Data()
    }

    /// An SPA-like page: an empty shell, then a 200 KB script that builds and
    /// sorts a data set, renders 1500 cards through the DOM and starts a
    /// router-like re-render after load.
    static let spa = Data(("<!doctype html><html><head><meta charset=utf-8><title>Bench app</title>"
        + "<style>body{margin:0;font:14px -apple-system}.card{display:inline-block;width:180px;margin:6px;padding:8px;"
        + "border-radius:8px;background:#eef}</style></head><body><div id=app>Loading…</div>"
        + "<script src=\"/bench/spa.js\"></script></body></html>").utf8)

    static let spaScript: Data = {
        // A static data table inflates the script to about 200 KB, as framework bundles do.
        let table = words(24_000, seed: 23).map { "\"\($0)\"" }.joined(separator: ",")
        return Data(("""
        const WORDS = [\(table)];
        function seeded(n) { let x = n; return () => (x = (x * 1103515245 + 12345) % 2147483648) / 2147483648; }
        const rand = seeded(7);
        const items = [];
        for (let i = 0; i < 20000; i++) items.push({ id: i, score: rand(), title: WORDS[i % WORDS.length] + ' ' + WORDS[(i * 7) % WORDS.length] });
        items.sort((a, b) => a.score - b.score);
        function render(list) {
          const root = document.getElementById('app');
          const frag = document.createDocumentFragment();
          for (const item of list) {
            const card = document.createElement('div');
            card.className = 'card';
            card.innerHTML = '<b>' + item.title + '</b><br>#' + item.id + ' · ' + item.score.toFixed(4);
            frag.appendChild(card);
          }
          root.replaceChildren(frag);
        }
        render(items.slice(0, 1500));
        addEventListener('load', () => requestAnimationFrame(() => render(items.slice(500, 2000))));
        """).utf8)
    }()

    /// A long server-rendered list: 5000 rows.
    static let list: Data = {
        let all = words(5000 * 6, seed: 31)
        let rows = (0 ..< 5000).map { "<li><b>Row \($0 + 1)</b> \(all[($0 * 6) ..< ($0 * 6 + 6)].joined(separator: " "))</li>" }.joined()
        return Data(("<!doctype html><html><head><meta charset=utf-8><title>Bench list</title>"
            + "<style>body{font:15px -apple-system;margin:24px}li{padding:4px 0;border-bottom:1px solid #ddd}</style></head>"
            + "<body><h1>Bench list</h1><ol>\(rows)</ol></body></html>").utf8)
    }()
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
#endif
