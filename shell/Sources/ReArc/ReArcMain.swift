import Foundation

/// Process entry. The Chromium path must branch before any NSApplication or
/// SwiftUI `App.main` exists (engine/docs/C-ABI.md "Linking and startup");
/// everything else is the unchanged WebKit app.
@main
enum ReArcMain {
    @MainActor
    static func main() {
        PerfSignposts.launchEvent("Main")
        let info = Bundle.main.infoDictionary
        let chromiumOwnsApplication = EngineLaunchOptions.applicationClassRequiresChromium(infoDictionary: info) {
            NSClassFromString($0) != nil
        }
        let parsed = EngineLaunchOptions.parse(
            arguments: CommandLine.arguments,
            environment: ProcessInfo.processInfo.environment,
            infoDictionary: info
        )
        let options = parsed.resolvingApplicationClass(requiresChromium: chromiumOwnsApplication)
        if let refusal = options.verificationRefusal {
            FileHandle.standardError.write(Data("ReArc: \(refusal)\nSELFTEST FAIL: verification refused\n".utf8))
            exit(64)
        }
        if options.source == .applicationClass {
            FileHandle.standardError.write(Data(("ReArc: this bundle's application class is Chromium's \(EngineLaunchOptions.chromiumApplicationClass); "
                + "using the Chromium engine (the WebKit path cannot start here).\n").utf8))
        }
        // Links from other apps (ReArc as the default browser), both engines.
        if !options.selfTest && options.bench == nil { ExternalLinkRouter.shared.install() }
        if options.engine == .chromium {
            #if REARC_CHROMIUM
            ChromiumHost.launch(options)
            #else
            unavailableChromium(options, reason: "this binary was built without Chromium (see scripts/bundle-chromium.sh)")
            #endif
        }
        if chromiumOwnsApplication {
            // NSApplicationMain would instantiate BrowserCrApplication and abort; exit cleanly instead.
            FileHandle.standardError.write(Data("ReArc: Chromium is unavailable in a Chromium bundle; cannot start the WebKit path here.\n".utf8))
            exit(70)
        }
        ReArcApp.main()
    }

    /// Falls back to WebKit, except for the self-test, which only proves Chromium.
    static func unavailableChromium(_ options: EngineLaunchOptions, reason: String) {
        FileHandle.standardError.write(Data("ReArc: Chromium engine requested but \(reason); using WebKit.\n".utf8))
        if options.selfTest {
            FileHandle.standardError.write(Data("SELFTEST FAIL: Chromium engine unavailable\n".utf8))
            exit(2)
        }
    }
}
