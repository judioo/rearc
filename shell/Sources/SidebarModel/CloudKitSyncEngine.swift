import Foundation
import Security

/// Decides whether this build may touch CloudKit. `CKContainer` traps when the
/// process lacks the iCloud entitlement, so nothing CloudKit is created
/// unless the running code signature carries it for the container the bundle
/// names (docs/ICLOUD-SETUP.md). SwiftPM, `swift test` and ad-hoc bundles never do.
public enum CloudKitSyncAvailability {
    public static let defaultContainerIdentifier = "iCloud.com.rearc.browser"
    /// Info.plist key the bundle scripts write when REARC_ICLOUD_CONTAINER is set.
    public static let infoPlistKey = "ReArcICloudContainer"
    public static let unavailableMessage = "iCloud sync unavailable in this build"
    /// Beside sync-state.json in a `REARC_DATA_DIR` launch: one line per iCloud call.
    public static let cloudKitCallLogName = "cloudkit-calls.log"

    public enum Availability: Equatable, Sendable {
        case available(containerIdentifier: String)
        case unavailable(reason: String)
    }

    /// Pure check: the bundle's configured container, then the entitlements
    /// that make CloudKit usable for it.
    public static func check(configuredContainer: String?, entitlement: (String) -> Any?) -> Availability {
        guard let container = configuredContainer, !container.isEmpty else {
            return .unavailable(reason: "\(unavailableMessage) (no iCloud container configured).")
        }
        let containers = entitlement("com.apple.developer.icloud-container-identifiers") as? [String] ?? []
        guard containers.contains(container) else {
            return .unavailable(reason: "\(unavailableMessage) (not signed with the \(container) entitlement).")
        }
        let services = entitlement("com.apple.developer.icloud-services") as? [String] ?? []
        guard services.contains("CloudKit") else {
            return .unavailable(reason: "\(unavailableMessage) (CloudKit service not entitled).")
        }
        return .available(containerIdentifier: container)
    }

    public static var current: Availability {
        let configured = Bundle.main.object(forInfoDictionaryKey: infoPlistKey) as? String
        return check(configuredContainer: configured, entitlement: signedEntitlement)
    }

    public static var hasCloudKitEntitlement: Bool {
        if case .available = current { return true }
        return false
    }

    public static func unavailableReasonIfNeeded() -> String? {
        if case .unavailable(let reason) = current { return reason }
        return nil
    }

    /// An entitlement of the running process's code signature.
    public static func signedEntitlement(_ key: String) -> Any? {
        guard let task = SecTaskCreateFromSelf(kCFAllocatorDefault) else { return nil }
        return SecTaskCopyValueForEntitlement(task, key as CFString, nil)
    }

    /// The app's sync engine: inert `UnavailableSyncEngine` unless entitled.
    @MainActor
    public static func makeEngine(stateFileURL: URL? = nil, deviceID: UUID = SyncDeviceIdentity.persistedDeviceID, initialState: SidebarSyncState? = nil) -> SyncEngine {
        switch current {
        case .unavailable(let reason):
            return UnavailableSyncEngine(reason: reason)
        case .available(let container):
            #if canImport(CloudKit)
            let fileURL = stateFileURL ?? SidebarFilePersistence.defaultFileURL
                .deletingLastPathComponent().appendingPathComponent(SidebarSyncStateFile.fileName)
            let transport = CloudKitSyncTransport(containerIdentifier: container)
            if ShellDataLocation.isOverridden {
                // A test run lists every iCloud call it made (docs/SYNC-RUNTIME.md).
                let log = fileURL.deletingLastPathComponent().appendingPathComponent(cloudKitCallLogName)
                transport.accessLog = { line in CloudKitCallLog.append(line, to: log) }
            }
            let coordinator = SidebarSyncCoordinator(
                transport: transport,
                stateStore: SidebarSyncStateFile(fileURL: fileURL),
                deviceID: deviceID.uuidString.lowercased(),
                initialState: initialState
            )
            return SidebarSyncScheduler(coordinator: coordinator)
            #else
            return UnavailableSyncEngine(reason: "\(unavailableMessage) (CloudKit missing).")
            #endif
        }
    }
}

/// Appends "<ISO time> <line>" to a file, from any thread.
enum CloudKitCallLog {
    private static let lock = NSLock()

    static func append(_ line: String, to url: URL) {
        lock.lock()
        defer { lock.unlock() }
        let text = ISO8601DateFormatter().string(from: Date()) + " " + line + "\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? Data(text.utf8).write(to: url, options: [.atomic])
        }
    }
}
