import Foundation

/// What Settings drives: the toggle, "Sync now" and the status it shows.
@MainActor
public protocol SyncControlling: AnyObject {
    var details: SyncStatusDetails { get }
    var isUserEnabled: Bool { get }
    /// Nobody chose yet (an existing install): ask before anything syncs.
    var needsDecision: Bool { get }
    /// Build 602 synced this Mac on by default before anyone chose.
    var syncedBeforeDecision: Bool { get }
    var onDetailsChange: ((SyncStatusDetails) -> Void)? { get set }
    func attach(host: SidebarSyncHost)
    func setUserEnabled(_ enabled: Bool)
    /// A new install's onboarding finished: on, unless someone already chose.
    func enableForNewInstall()
    func syncNow()
}

/// Runs `SidebarSyncCoordinator` cycles: soon after local edits (debounced),
/// on a poll interval, on demand, and again with backoff after transient
/// failures. One cycle at a time; a request during a cycle runs once after it.
public final class SidebarSyncScheduler: SyncEngine, SyncControlling, @unchecked Sendable {
    public static let editDebounce: TimeInterval = 3
    public static let pollInterval: TimeInterval = 300
    public static let maxBackoff: TimeInterval = 900

    public let coordinator: SidebarSyncCoordinator
    public private(set) var status: SyncEngineStatus
    public var onStatusChange: (@Sendable (SyncEngineStatus) -> Void)?
    public var onDetailsChange: ((SyncStatusDetails) -> Void)?

    private var running = false
    private var rerun = false
    private var started = false
    private var scheduled: Task<Void, Never>?
    private var poll: Task<Void, Never>?
    private var failures = 0
    /// Test hook: replaces sleeping (delays are recorded, cycles run at once).
    var sleeper: (TimeInterval) async -> Void = { seconds in
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    @MainActor
    public init(coordinator: SidebarSyncCoordinator) {
        self.coordinator = coordinator
        self.status = coordinator.details.engineStatus
        coordinator.onDetailsChange = { [weak self] details in
            self?.publish(details)
        }
    }

    @MainActor public var details: SyncStatusDetails { coordinator.details }
    @MainActor public var isUserEnabled: Bool { coordinator.isEnabled }
    @MainActor public var needsDecision: Bool { coordinator.needsDecision }
    @MainActor public var syncedBeforeDecision: Bool { coordinator.syncedBeforeDecision }

    @MainActor
    public func attach(host: SidebarSyncHost) {
        coordinator.host = host
    }

    @MainActor
    public func setUserEnabled(_ enabled: Bool) {
        coordinator.setEnabled(enabled)
        resumeOrPause()
    }

    @MainActor
    public func enableForNewInstall() {
        coordinator.enableForNewInstall()
        resumeOrPause()
    }

    @MainActor
    private func resumeOrPause() {
        if coordinator.isEnabled, started {
            startPolling()
            schedule(after: 0)
        } else {
            scheduled?.cancel()
            poll?.cancel()
        }
    }

    @MainActor
    public func syncNow() {
        coordinator.retrySchemaRejectedKinds() // An explicit retry after a schema deployment.
        schedule(after: 0)
    }

    // MARK: SyncEngine

    public func start() {
        MainActor.assumeIsolated {
            started = true
            publish(coordinator.details)
            guard coordinator.isEnabled else { return }
            startPolling()
            schedule(after: 1)
        }
    }

    public func stop() {
        MainActor.assumeIsolated {
            started = false
            scheduled?.cancel()
            poll?.cancel()
        }
    }

    /// Local edits: the coordinator diffs the whole sidebar, so entries only
    /// mean "something changed". Called on the coalescer's queue.
    public func push(_ entries: [SidebarJournalEntry]) {
        guard !entries.isEmpty else { return }
        Task { @MainActor [weak self] in
            guard let self, self.started, self.coordinator.isEnabled else { return }
            self.coordinator.captureLocalChanges()
            self.schedule(after: Self.editDebounce)
        }
    }

    public func pull(since sequence: UInt64) async throws -> SyncPullResult {
        await runCycle()
        return SyncPullResult()
    }

    // MARK: Scheduling

    @MainActor
    private func schedule(after delay: TimeInterval) {
        guard started, coordinator.isEnabled else { return }
        scheduled?.cancel()
        scheduled = Task { @MainActor [weak self] in
            guard let self else { return }
            if delay > 0 { await self.sleeper(delay) }
            guard !Task.isCancelled else { return }
            await self.runCycle()
        }
    }

    @MainActor
    private func startPolling() {
        poll?.cancel()
        poll = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.sleeper(Self.pollInterval)
                guard !Task.isCancelled else { return }
                await self.runCycle()
            }
        }
    }

    @MainActor
    func runCycle() async {
        guard started, coordinator.isEnabled else { return }
        if running {
            rerun = true
            return
        }
        running = true
        defer { running = false }
        repeat {
            rerun = false
            let outcome = await coordinator.sync()
            // A schema rejection holds back only its own record type (the
            // coordinator's cooldown), so the rest keeps its usual cadence.
            if let error = outcome.error, error.isTransient || error == .quotaExceeded {
                failures += 1
                let base = min(Self.maxBackoff, 5 * pow(2, Double(failures - 1)))
                let delay = max(error.retryAfter ?? 0, base * Double.random(in: 0.8 ... 1.2))
                schedule(after: error == .quotaExceeded ? Self.maxBackoff : delay)
            } else if outcome.error == nil || outcome.error?.isSchemaError == true {
                failures = 0
            }
        } while rerun
    }

    @MainActor
    private func publish(_ details: SyncStatusDetails) {
        status = details.engineStatus
        onStatusChange?(status)
        onDetailsChange?(details)
    }
}

/// Settings > iCloud Sync text, kept out of the view so tests can read it.
public struct SyncSettingsPresentation: Equatable, Sendable {
    public var statusText: String
    public var accountText: String
    public var lastSyncedText: String
    public var pendingText: String?
    public var errorText: String?
    public var technicalError: String?
    public var canSyncNow: Bool

    public init(details: SyncStatusDetails, enabled: Bool, now: Date = Date()) {
        switch details.phase {
        case .off: statusText = "Off"
        case .unavailable(let reason): statusText = reason
        case .signedOut: statusText = "Not signed in to iCloud"
        case .syncing: statusText = "Syncing…"
        case .upToDate: statusText = "Up to date"
        case .waiting: statusText = "Waiting to sync"
        case .failed: statusText = "Sync failed"
        }
        accountText = details.accountDescription
        if let last = details.lastSyncedAt {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            lastSyncedText = formatter.localizedString(for: last, relativeTo: now)
        } else {
            lastSyncedText = "Never"
        }
        pendingText = details.pendingCount > 0 ? "\(details.pendingCount) change\(details.pendingCount == 1 ? "" : "s") waiting to upload" : nil
        switch details.phase {
        case .waiting(let message), .failed(let message), .signedOut(let message): errorText = message
        default: errorText = nil
        }
        technicalError = details.technicalError
        canSyncNow = enabled && details.phase != .syncing
    }
}

/// The one question an existing install gets before its sidebar syncs
/// (RC-0.1.0-602 T-01), kept out of the view so tests can read it.
public struct SyncDecisionPrompt: Equatable, Sendable {
    public static let title = "Sync your sidebar with iCloud?"
    public static let turnOn = "Turn On"
    public static let notNow = "Not Now"

    public var message: String

    /// `syncedBefore`: build 602 already synced this Mac without asking.
    public init(syncedBefore: Bool) {
        var text = "ReArc can keep your Spaces, Favorites, pinned tabs, folders, splits and Boosts the same on every Mac signed in to your Apple Account. "
        if syncedBefore {
            text += "The last update started syncing this sidebar without asking. Turn On keeps it in step with your other Macs. "
                + "Not Now stops it on this Mac; what was already uploaded stays in your iCloud account."
        } else {
            text += "Turning it on merges this Mac's sidebar with the one in iCloud: what each Mac has appears on both, and where an item "
                + "is already in iCloud, iCloud's version is kept, including a deletion."
        }
        text += " Today tabs, history, passwords and settings stay on this Mac.\n\nYou can change this later in Settings › Account."
        message = text
    }
}
