import Foundation
import SidebarModel

/// `--rearc-icloud-look`: one look at iCloud's sidebar through the code
/// Settings uses, timed and printed, then exit. Read-only: no state file,
/// no CloudKit write, no window. Where the self-test runs only (a
/// development build, or a verification bundle with
/// `REARC_RELEASE_VERIFICATION=1`). Prints counts and timings, never a
/// title or an address.
///
/// `--rearc-icloud-look-qos=utility|default|userInitiated`,
/// `--rearc-icloud-look-limit=N` (0: the server's default) and `--rearc-icloud-look-keys=payload`
/// try other read settings.
enum CloudLookProbe {
    static let flag = "--rearc-icloud-look"

    @MainActor
    static func runIfAsked(arguments: [String] = CommandLine.arguments, environment: [String: String] = ProcessInfo.processInfo.environment,
                           infoDictionary: [String: Any]? = Bundle.main.infoDictionary) {
        guard arguments.contains(flag) else { return }
        guard EngineLaunchOptions.allowsVerification(infoDictionary: infoDictionary, environment: environment) else {
            FileHandle.standardError.write(Data("ReArc: \(flag) runs only in a development build or a verification bundle\n".utf8))
            exit(64)
        }
        #if canImport(CloudKit)
        guard case .available(let container) = CloudKitSyncAvailability.current else {
            print("iCloud look: \(CloudKitSyncAvailability.unavailableReasonIfNeeded() ?? "unavailable")")
            exit(2)
        }
        let transport = CloudKitSyncTransport(containerIdentifier: container)
        func value(_ name: String) -> String? {
            arguments.first { $0.hasPrefix("\(flag)-\(name)=") }.map { String($0.dropFirst(flag.count + name.count + 2)) }
        }
        switch value("qos") {
        case "utility": transport.readTuning.qualityOfService = .utility
        case "default": transport.readTuning.qualityOfService = .default
        default: break
        }
        if let limit = value("limit").flatMap(Int.init) { transport.readTuning.resultsLimit = limit > 0 ? limit : nil }
        transport.readTuning.desiredKeys = value("keys").map { $0.split(separator: ",").map(String.init) }
        let started = Date()
        func stamp() -> String { String(format: "%6.2f s", Date().timeIntervalSince(started)) }
        transport.accessLog = { line in print("\(stamp())  \(line)") }
        let coordinator = SidebarSyncCoordinator(transport: transport, stateStore: InMemorySyncStateStore(), deviceID: "icloud-look-probe")
        print("iCloud look: container \(container), quality \(transport.readTuning.qualityOfService.rawValue), limit \(transport.readTuning.resultsLimit.map(String.init) ?? "default"), keys \(transport.readTuning.desiredKeys?.joined(separator: ",") ?? "all")")
        Task { @MainActor in
            var lastBatch = started
            let detection = await coordinator.detectCloudSidebar { step in
                if case .records = step { lastBatch = Date() }
                if case .stalled = step { print("\(stamp())  stalled") }
            }
            let summarized = Date().timeIntervalSince(lastBatch)
            switch detection {
            case .found(let found):
                let s = found.summary
                print("\(stamp())  found: \(found.records.count) records kept; \(s.spaces) spaces (\(s.arcCopies) Arc copies), \(s.pinnedTabs) pinned tabs, \(s.favorites) favorites")
            default:
                print("\(stamp())  \(detection)")
            }
            print(String(format: "total %.2f s; after the last batch (cleaning and counting, on the main thread) %.2f s", Date().timeIntervalSince(started), summarized))
            exit(0)
        }
        dispatchMain()
        #else
        exit(2)
        #endif
    }
}
