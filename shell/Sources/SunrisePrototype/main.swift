import AppKit
import Onboarding

// sunrise                      Act 0 over the whole screen (1/2/3 switch takes,
//                              R or Cmd+R watches it again, M mutes, Esc skips).
// sunrise --windowed           The same in a 1440 x 900 window.
// sunrise --variant ember      Start on a take: horizon, ember or path.
// sunrise --render DIR [--size 1440x900] [--fps 30] [--duration 13] [--reduced]
//                              Offscreen PNG frames and a WAV per take, for previews.
//   --act1 [--name Kai]       ...carrying on into Act 1 with a scripted person.
//   --act2 [--real]           ...and into Act 2 (demo browsers, or this Mac's with --real).
//   --act3 [--fresh]          ...and Act 3 (spaces from the import, or suggested with --fresh).
//   --act4                    ...and Act 4: the motto and the drop into the browser.
//   --audio-only              Just score.wav (the frames do not depend on the score).
//   --later STYLE [--later-at S]  "Onboard later" at S seconds: sunset, fade or nightfall.
// sunrise --scan               Counts what Act 2 would find on this Mac (no names).
// sunrise --demo-sources       Live, with the demo browsers instead of this Mac's.

let args = CommandLine.arguments
func value(_ flag: String) -> String? {
    args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
}
let variants = value("--variant").flatMap(SunriseVariant.init(rawValue:)).map { [$0] } ?? SunriseVariant.allCases

final class AppDelegate: NSObject, NSApplicationDelegate {
    var takeover: SunriseTakeover?

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            buildMenu()
            let takeover = SunriseTakeover(variant: variants[0], windowed: args.contains("--windowed"), showsVariantPicker: true)
            takeover.player.usesDemoSources = args.contains("--demo-sources")
            self.takeover = takeover
            takeover.present { NSApp.terminate(nil) }
        }
    }

    @MainActor func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let app = NSMenu()
        app.addItem(withTitle: "Watch the Sunrise Again", action: #selector(watchAgain), keyEquivalent: "r")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Sunrise", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = app
        NSApp.mainMenu = main
    }

    @objc func watchAgain() { MainActor.assumeIsolated { takeover?.player.play() } }
}

MainActor.assumeIsolated {
    if args.contains("--scan") {
        for s in BrowserScanner.scan() {
            let st = s.stats
            print("\(s.browser) profile: \(st.spaces) spaces, \(st.tabs) tabs, \(st.bookmarks) bookmarks, \(st.pages) pages, \(st.passwords) passwords, \(st.extensions) extensions")
        }
        exit(0)
    }
    if let dir = value("--render") {
        let parts = (value("--size") ?? "1440x900").split(separator: "x").compactMap { Double($0) }
        let size = CGSize(width: parts.first ?? 1440, height: parts.last ?? 900)
        let fps = value("--fps").flatMap(Double.init) ?? 30
        let durationArg = value("--duration").flatMap(Double.init)
        let reduced = args.contains("--reduced")
        let withAct4 = args.contains("--act4")
        let withAct3 = args.contains("--act3") || withAct4
        let withAct2 = args.contains("--act2") || withAct3
        let withAct1 = args.contains("--act1") || withAct2
        for v in variants {
            let start = (reduced ? SunriseCues.reduced : SunriseCues.of(v)).end + 0.8
            let act1 = withAct1 ? Act1Log.demo(start: start, name: value("--name") ?? "Kai") : nil
            var act2 = withAct2 ? act1?.handOff.map { Act2Log.demo(start: $0, sources: args.contains("--real") ? BrowserScanner.scan() : ImportSource.demo) } : nil
            var act3: Act3Log?
            if withAct3, var a2 = act2, let start = a2.handOff {
                if args.contains("--fresh"), let c = a2.choice { a2.choice = (c.time, false) }
                let colour = act1?.picked.map { ProfilePalette.colours[$0.index].rgba } ?? MarkPalette.sun
                let base = Act3Log.after(a2, start: a2.handOff ?? start, colour: colour)
                act3 = Act3Log.demo(start: base.start, seeds: base.seeds, imported: base.imported)
                if args.contains("--fresh") { act2 = a2 }
            }
            let act4 = withAct4 ? act3?.handOff.map { Act4Log.after(act1: act1, act2: act2, act3: act3, start: $0) } : nil
            let end = (act4?.handOff ?? act3?.handOff ?? act2?.handOff ?? act1?.handOff).map { $0 + SunrisePlayer.exitDuration + 0.6 }
            let later = value("--later").flatMap(SunriseClosing.init(rawValue:)).map { style in
                (style: style, at: value("--later-at").flatMap(Double.init) ?? act1.map { $0.start + 6 } ?? start)
            }
            let duration = durationArg ?? later.map { $0.at + $0.style.duration + 0.4 } ?? end ?? 13
            let out = URL(fileURLWithPath: dir).appendingPathComponent(v.rawValue)
            do {
                try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
                let n = args.contains("--audio-only") ? 0
                    : try SunrisePreview.renderFrames(v, size: size, fps: fps, duration: duration, reduced: reduced, act1: act1, act2: act2, act3: act3, act4: act4, later: later, to: out)
                try SunrisePreview.renderAudio(v, duration: duration, reduced: reduced, act1: act1, act2: act2, act3: act3, act4: act4, later: later, to: out.appendingPathComponent("score.wav"))
                print("\(v.rawValue): \(n) frames and score.wav in \(out.path)")
            } catch {
                print("\(v.rawValue): \(error)")
                exit(1)
            }
        }
        exit(0)
    }
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
