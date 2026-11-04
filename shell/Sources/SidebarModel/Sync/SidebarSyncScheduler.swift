import Foundation

/// What Settings drives: the toggle, "Sync now" and the status it shows.
@MainActor
public protocol SyncControlling: AnyObject {
    var details: SyncStatusDetails { get }
    var isUserEnabled: Bool { get }
    var onDetailsChange: ((SyncStatusDetails) -> Void)? { get set }
    func attach(host: SidebarSyncHost)
    func setUserEnabled(_ enabled: Bool)
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

    @MainActor
    public func attach(host: SidebarSyncHost) {
        coordinator.host = host
    }

    @MainActor
    public func setUserEnabled(_ enabled: Bool) {
        coordinator.setEnabled(enabled)
        if enabled {
            startPolling()
            schedule(after: 0)
        } else {
            scheduled?.cancel()
            poll?.cancel()
        }
    }

    @MainActor
    public func syncNow() {
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
            guard let self, self.coordinator.isEnabled else { return }
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
        guard coordinator.isEnabled else { return }
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
        if running {
            rerun = true
            return
        }
        running = true
        defer { running = false }
        repeat {
            rerun = false
            let outcome = await coordinator.sync()
            if let error = outcome.error, error.isTransient || error == .quotaExceeded {
                failures += 1
                let base = min(Self.maxBackoff, 5 * pow(2, Double(failures - 1)))
                let delay = max(error.retryAfter ?? 0, base * Double.random(in: 0.8 ... 1.2))
                schedule(after: error == .quotaExceeded ? Self.maxBackoff : delay)
            } else if outcome.error == nil {
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
        canSyncNow = enabled && details.phase != .syncing
    }
}
