import Foundation

/// Process entry. The Chromium path must branch before any NSApplication or
/// SwiftUI `App.main` exists (engine/docs/C-ABI.md "Linking and startup");
/// everything else is the unchanged WebKit app.
@main
enum ReArcMain {
    @MainActor
    static func main() {
        let options = EngineLaunchOptions.parse(
            arguments: CommandLine.arguments,
            environment: ProcessInfo.processInfo.environment
        )
        // Links from other apps (ReArc as the default browser), both engines.
        if !options.selfTest { ExternalLinkRouter.shared.install() }
        if options.engine == .chromium {
            #if REARC_CHROMIUM
            ChromiumHost.launch(options)
            #else
            unavailableChromium(options, reason: "this binary was built without Chromium (see scripts/bundle-chromium.sh)")
            #endif
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
