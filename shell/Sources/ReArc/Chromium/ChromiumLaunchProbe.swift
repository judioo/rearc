#if REARC_CHROMIUM
import AppKit
import Foundation
import ReArcEngine

/// `--rearc-launch-probe=PATH` (scripts/check-launch.sh): proves that a
/// LaunchServices launch (`open`, Finder, the Dock, a link from another app)
/// of the Chromium bundle reaches `ready` on the Chromium path. It runs on a
/// throwaway profile (the default user-data dir is a temp dir, as for the
/// self-test) and never builds the sidebar model, so the user's data is not
/// touched. At ready it waits briefly for Apple Events, writes one line of
/// `key=value` pairs to PATH, and shuts the engine down.
final class ChromiumLaunchProbe {
    private let runtime: ChromiumRuntime
    private let options: EngineLaunchOptions
    private let resultPath: String
    private var shutdownStatus: ReArcStatus?

    /// How long `ready` waits for a GetURL event (a launch with a link).
    static let linkGraceSeconds = 3.0

    init(runtime: ChromiumRuntime, options: EngineLaunchOptions, resultPath: String) {
        self.runtime = runtime
        self.options = options
        self.resultPath = resultPath
    }

    func start() {
        ChromiumLog.info("launch probe: ready (engine source \(options.source.rawValue))")
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.linkGraceSeconds) { [self] in
            MainActor.assumeIsolated { finish() }
        }
    }

    @MainActor
    private func finish() {
        let links = ExternalLinkRouter.shared.pendingURLs.map(\.absoluteString)
        let fields = [
            "ready=1",
            "engine=chromium",
            "source=\(options.source.rawValue)",
            "abi_minor=\(runtime.capabilities.abiMinorVersion.map(String.init) ?? "absent")",
            "principal_class=\(NSStringFromClass(type(of: NSApp!)))",
            "links=\(links.joined(separator: ","))",
        ]
        let line = fields.joined(separator: " ") + "\n"
        do {
            try line.write(toFile: resultPath, atomically: true, encoding: .utf8)
        } catch {
            ChromiumLog.info("launch probe: cannot write \(resultPath): \(error)")
        }
        ChromiumLog.info("launch probe: \(line.trimmingCharacters(in: .newlines))")
        let status = runtime.requestShutdown(force: true) { [self] status, cancelled in
            shutdownStatus = cancelled ? ReArcStatus(REARC_CANCELLED) : status
        }
        if status != .rearcOK {
            ChromiumLog.info("launch probe: shutdown rejected \(status.rearcName)")
            _exit(1)
        }
    }

    func exitCode(runResult: Int32) -> Int32 {
        let clean = runResult == 0 && shutdownStatus == .rearcOK
        ChromiumLog.info("launch probe: ReArcEngineRun returned \(runResult), shutdown \(shutdownStatus?.rearcName ?? "none")")
        return clean ? 0 : 1
    }
}
#endif
