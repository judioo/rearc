import Foundation

/// What Settings drives: the toggle, "Sync now" and the status it shows.
@MainActor
public protocol SyncControlling: AnyObject {
    var details: SyncStatusDetails { get }
    var isUserEnabled: Bool { get }
    var onDetailsChange: ((SyncStatusDetails) -> Void)? { get set }
    func attach(host: SidebarSyncHost)
    /// Off, or on when iCloud holds no sidebar (`detectCloudSidebar` said so).
    func setUserEnabled(_ enabled: Bool)
    /// Profiles the person put in iCloud: they go up at the next join
    /// (`SidebarSyncCoordinator.putInICloud`).
    func putInICloud(_ profiles: Set<Profile.ID>)
    func syncNow()
    /// A read-only look at iCloud (Settings, and before turning sync on).
    func detectCloudSidebar(progress: @escaping @MainActor (CloudLookProgress) -> Void) async -> CloudSidebarDetection
    /// Uses, replaces or merges with what `detectCloudSidebar` found; sync is on afterwards.
    func apply(_ choice: CloudSidebarChoice, from found: CloudSidebarFound)
    /// Deletes ReArc's sidebar from iCloud; sync is off afterwards.
    func deleteCloudSidebar() async throws
    /// Deletes one profile from iCloud (`SidebarSyncCoordinator.deleteCloudProfile`).
    func deleteCloudProfile(_ confirmed: CloudProfileDeletion, in found: CloudSidebarFound,
                            backup: ([SyncWireRecord]) throws -> URL, deleteLocally: (() -> Void)?) async -> CloudProfileDeletionResult
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
    public func putInICloud(_ profiles: Set<Profile.ID>) {
        coordinator.putInICloud(profiles)
    }

    @MainActor
    public func detectCloudSidebar(progress: @escaping @MainActor (CloudLookProgress) -> Void) async -> CloudSidebarDetection {
        await coordinator.detectCloudSidebar(progress: progress)
    }

    @MainActor
    public func apply(_ choice: CloudSidebarChoice, from found: CloudSidebarFound) {
        coordinator.apply(choice, from: found)
        resumeOrPause()
    }

    @MainActor
    public func deleteCloudSidebar() async throws {
        try await coordinator.deleteCloudSidebar()
        resumeOrPause()
    }

    /// With sync on its cycles run here, never beside another cycle.
    @MainActor
    public func deleteCloudProfile(_ confirmed: CloudProfileDeletion, in found: CloudSidebarFound,
                                   backup: ([SyncWireRecord]) throws -> URL, deleteLocally: (() -> Void)?) async -> CloudProfileDeletionResult {
        while running { try? await Task.sleep(nanoseconds: 50_000_000) }
        running = true
        defer {
            running = false
            if rerun { schedule(after: 0) }
        }
        return await coordinator.deleteCloudProfile(confirmed, in: found, backup: backup, deleteLocally: deleteLocally)
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

/// What Settings says when Sync Sidebar is switched on and iCloud already
/// holds a sidebar, and in its iCloud box; kept out of the views so tests
/// can read them.
public enum SyncCloudText {
    public static let sheetTitle = "iCloud already has a ReArc sidebar"

    /// "It has 14 spaces, 210 pinned tabs and 12 favorites, last updated 3 days ago."
    public static func holds(_ summary: CloudSidebarSummary, now: Date = Date()) -> String {
        "It has " + summary.counts + (summary.updatedText(now: now).map { ", " + $0 } ?? "") + "."
    }

    public static let sheetWarning = "Using it can replace or change what is on this Mac, including what you just imported. Sites may ask you to sign in again on this Mac."

    public static func title(_ choice: CloudSidebarChoice) -> String {
        switch choice {
        case .useCloud: return "Use the iCloud Sidebar on This Mac"
        case .replaceCloud: return "Replace What's in iCloud with This Mac's Sidebar"
        case .merge: return "Merge Both"
        }
    }

    /// One line: what the choice does.
    public static func consequence(_ choice: CloudSidebarChoice, backupFolder: String) -> String {
        switch choice {
        case .useCloud:
            return "This Mac's sidebar is replaced. A copy of it is saved first in \(backupFolder)."
        case .replaceCloud:
            return "iCloud's sidebar is replaced with this one, and your other Macs get this Mac's sidebar."
        case .merge:
            return "Both come together. Each Arc space appears once; where both have an item, iCloud's version is kept."
        }
    }

    public static let cancel = "Cancel"
    public static let cancelConsequence = "Nothing changes here or in iCloud, and Sync Sidebar stays off."

    /// The iCloud box in Settings › Account.
    public static func status(_ detection: CloudSidebarDetection?, now: Date = Date()) -> String {
        switch detection {
        case nil: return "Checking iCloud…"
        case .found(let found)?: return "iCloud has " + found.summary.counts + (found.summary.updatedText(now: now).map { ", " + $0 } ?? "") + "."
        case .empty?: return "iCloud has no ReArc sidebar."
        case .signedOut(let message)?, .unreachable(let message)?, .unavailable(let message)?: return message
        }
    }
}
