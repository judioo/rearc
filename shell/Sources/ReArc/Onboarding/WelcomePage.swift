import Foundation
import Onboarding
import SidebarModel

/// The first tab after the onboarding: the page Act 4 draws, for real. A
/// local file in ReArc's data folder, so it is there on the next launch too.
enum WelcomePage {
    static func write(name: String, colour: RGBA, spaces: Int, imported: ImportStats?,
                      to directory: URL = ShellDataLocation.root.appendingPathComponent("Welcome", isDirectory: true)) -> URL {
        let url = directory.appendingPathComponent("welcome.html")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? html(name: name, colour: colour, spaces: spaces, imported: imported).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func hex(_ c: RGBA) -> String {
        String(format: "#%02X%02X%02X", Int((c.r * 255).rounded()), Int((c.g * 255).rounded()), Int((c.b * 255).rounded()))
    }

    static func html(name: String, colour: RGBA, spaces: Int, imported: ImportStats?) -> String {
        let greeting = name.isEmpty ? "Welcome to ReArc." : "Welcome to ReArc, <span class=\"you\">\(escape(name))</span>."
        let ready = "Your profile and \(spaces) space\(spaces == 1 ? " is" : "s are") ready."
        let brought = imported.flatMap { $0 == ImportStats() ? nil : "<p class=\"brought\">\(escape($0.summary)) came with you.</p>" } ?? ""
        let tips = [("⌘T", "New tab"), ("⌘L", "Command bar"), ("⌘S", "Hide the sidebar"), ("⌃1–9", "Switch spaces")]
            .map { "<li><kbd>\($0.0)</kbd>\($0.1)</li>" }.joined()
        return """
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Welcome to ReArc</title>
        <style>
        :root { --ink: #1D2160; --muted: rgba(29,33,96,.6); --faint: rgba(29,33,96,.4); --sun: #FF5B3A; --you: \(hex(colour)); --bg: #FFFDFB; --key: rgba(29,33,96,.05); --keyline: rgba(29,33,96,.12); }
        @media (prefers-color-scheme: dark) { :root { --ink: #EEF0FF; --muted: rgba(238,240,255,.65); --faint: rgba(238,240,255,.4); --bg: #12142B; --key: rgba(255,255,255,.06); --keyline: rgba(255,255,255,.14); } }
        * { box-sizing: border-box; }
        body { margin: 0; min-height: 100vh; background: var(--bg); color: var(--ink); font: 17px/1.5 -apple-system, BlinkMacSystemFont, system-ui, sans-serif; display: flex; align-items: center; }
        main { margin: 0 12%; max-width: 980px; }
        .motto { color: var(--sun); font-size: 12px; font-weight: 600; letter-spacing: .25em; margin: 0 0 18px; }
        h1 { font-weight: 300; font-size: clamp(32px, 4.4vw, 52px); line-height: 1.15; margin: 0 0 16px; letter-spacing: -.01em; }
        .you { color: var(--you); }
        .ready { font-size: 19px; color: var(--muted); margin: 0; }
        .brought { color: var(--faint); margin: 6px 0 0; }
        ul { list-style: none; padding: 0; margin: 48px 0 0; display: flex; flex-wrap: wrap; gap: 14px 28px; color: var(--muted); }
        kbd { font: 500 14px ui-rounded, -apple-system, system-ui; color: var(--ink); background: var(--key); border: 1px solid var(--keyline); border-radius: 7px; padding: 5px 9px; margin-right: 9px; }
        footer { position: fixed; bottom: 28px; left: 12%; color: var(--faint); font-size: 13px; }
        </style></head>
        <body><main>
        <p class="motto">REFOCUSED · RESTORED · REARC</p>
        <h1>\(greeting)</h1>
        <p class="ready">\(ready)</p>
        \(brought)
        <ul>\(tips)</ul>
        </main>
        <footer>Watch the sunrise again any time: Help ▸ Watch the Sunrise Again</footer>
        </body></html>
        """
    }
}
