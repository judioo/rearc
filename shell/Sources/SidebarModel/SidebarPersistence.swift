import Foundation

public enum SidebarLoadOutcome: Equatable, Sendable {
    case missingFile
    case loaded
    /// Corrupt file was quarantined; caller should use fallback data and keep autosave off until user edit.
    case recoveredFromCorruptFile
}

/// Loads and saves sidebar snapshots to disk with debounced writes.
public protocol SidebarPersisting: AnyObject {
    var loadOutcome: SidebarLoadOutcome { get }
    var autosaveEnabled: Bool { get }
    func loadSnapshot() -> SidebarSnapshot?
    func start(autoSave store: SidebarStore, onMutate: (() -> Void)?)
    func noteUserEditUnlockedAutosave()
    func stop()
    func flush()
}

/// Local JSON file persistence at `~/Library/Application Support/ReArc/sidebar.json`
/// (`ShellDataLocation`).
public final class SidebarFilePersistence: SidebarPersisting {
    public static let defaultFileURL: URL = ShellDataLocation.root
        .appendingPathComponent("sidebar.json", isDirectory: false)

    public let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let debounceInterval: TimeInterval
    private let queue: DispatchQueue
    private var store: SidebarStore?
    private var pendingWrite: DispatchWorkItem?

    public init(
        fileURL: URL = SidebarFilePersistence.defaultFileURL,
        debounceInterval: TimeInterval = 0.35,
        queue: DispatchQueue = DispatchQueue(label: "net.rearc.sidebar.persistence")
    ) {
        self.fileURL = fileURL
        self.debounceInterval = debounceInterval
        self.queue = queue
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    public private(set) var loadOutcome: SidebarLoadOutcome = .missingFile
    public private(set) var autosaveEnabled = true
    /// A first run's onboarding has begun and not finished (the marker file
    /// was there at load).
    public private(set) var onboardingPending = false
    public private(set) var onboardingSetupState: OnboardingSetupState = .notDeferred

    /// Beside the sidebar file from a first run's onboarding start until it
    /// completes or is explicitly skipped by a launch flag. The sidebar is
    /// saved meanwhile (sync's state must match it), so the marker keeps a quit or
    /// crash mid-onboarding a first run. Installs from before the marker have
    /// a sidebar file and no marker: never a first run.
    public var onboardingMarkerURL: URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("onboarding-pending", isDirectory: false)
    }

    /// An explicit deferral opens the browser with a reminder instead of
    /// taking over the screen again. Keep the pending marker until completion.
    public var onboardingDeferredURL: URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("onboarding-deferred", isDirectory: false)
    }

    public var isFirstRun: Bool {
        !onboardingSetupState.showsMenuItem && (loadOutcome == .missingFile || onboardingPending)
    }

    /// The untouched starter an onboarding replaces, kept in the marker so
    /// a launch that resumes an interrupted onboarding still knows which
    /// space was the starter once the import has made the sidebar no longer
    /// look like one.
    public struct OnboardingStarter: Codable, Equatable, Sendable {
        public var spaceIDs: [UUID]
        public var favoriteIDs: [UUID]
        /// Every row the starter held: a starter space with any other row
        /// ("Onboard later", then browsing) is the person's now, and stays.
        public var itemIDs: [UUID]

        public init(spaceIDs: [UUID] = [], favoriteIDs: [UUID] = [], itemIDs: [UUID] = []) {
            self.spaceIDs = spaceIDs
            self.favoriteIDs = favoriteIDs
            self.itemIDs = itemIDs
        }

        enum CodingKeys: String, CodingKey { case spaceIDs, favoriteIDs, itemIDs }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            spaceIDs = try c.decodeIfPresent([UUID].self, forKey: .spaceIDs) ?? []
            favoriteIDs = try c.decodeIfPresent([UUID].self, forKey: .favoriteIDs) ?? []
            itemIDs = try c.decodeIfPresent([UUID].self, forKey: .itemIDs) ?? []
        }
    }

    /// Written before the onboarding can change the store; a marker already
    /// there (an interrupted onboarding) keeps the starter it recorded.
    public func beginOnboarding(starter: OnboardingStarter = OnboardingStarter()) {
        onboardingPending = true
        guard !FileManager.default.fileExists(atPath: onboardingMarkerURL.path) else { return }
        try? FileManager.default.createDirectory(at: onboardingMarkerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = (try? JSONEncoder().encode(starter)) ?? Data()
        try? data.write(to: onboardingMarkerURL, options: [.atomic])
    }

    /// The starter `beginOnboarding` recorded; nil without a marker, or for
    /// one written by builds that recorded none (empty).
    public var onboardingStarter: OnboardingStarter? {
        guard let data = try? Data(contentsOf: onboardingMarkerURL), !data.isEmpty else { return nil }
        return try? JSONDecoder().decode(OnboardingStarter.self, from: data)
    }

    /// Save the explicit deferral separately so old pending markers still
    /// resume the sunrise. Dismissing only the card keeps the menu available.
    public func deferOnboarding() {
        saveOnboardingSetupState(.deferred)
    }

    public func dismissOnboardingCard() {
        guard onboardingSetupState.showsCard else { return }
        saveOnboardingSetupState(.dismissed)
    }

    private func saveOnboardingSetupState(_ state: OnboardingSetupState) {
        try? FileManager.default.createDirectory(at: onboardingDeferredURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(state),
              (try? data.write(to: onboardingDeferredURL, options: .atomic)) != nil else { return }
        onboardingSetupState = state
    }

    /// Completed or explicitly skipped by a launch flag: no reminder remains.
    public func finishOnboarding() {
        try? FileManager.default.removeItem(at: onboardingMarkerURL)
        try? FileManager.default.removeItem(at: onboardingDeferredURL)
        onboardingPending = false
        onboardingSetupState = .notDeferred
    }

    /// Loads persisted state, or the empty starter when the file is missing or invalid.
    public static func loadStore(
        fileURL: URL = SidebarFilePersistence.defaultFileURL,
        fallback: () -> SidebarStore = { SidebarStore.starter() },
        persistence: SidebarFilePersistence? = nil
    ) -> SidebarStore {
        let persistence = persistence ?? SidebarFilePersistence(fileURL: fileURL)
        if let snapshot = persistence.loadSnapshot() {
            let store = SidebarStore()
            store.applySnapshot(snapshot)
            return store
        }
        return fallback()
    }

    /// Read/decode on a worker before constructing a main-thread-owned store.
    /// The result carries corruption recovery state as well as the snapshot;
    /// consuming it must not re-read or accidentally enable autosave.
    public struct PreparedLoad {
        public let snapshot: SidebarSnapshot?
        public let outcome: SidebarLoadOutcome
        public let onboardingPending: Bool
        public let onboardingSetupState: OnboardingSetupState

        public var isFirstRun: Bool {
            !onboardingSetupState.showsMenuItem && (outcome == .missingFile || onboardingPending)
        }
    }

    public static func prepareLoad(from fileURL: URL) -> PreparedLoad {
        let persistence = SidebarFilePersistence(fileURL: fileURL)
        let snapshot = persistence.loadSnapshot()
        return PreparedLoad(snapshot: snapshot, outcome: persistence.loadOutcome, onboardingPending: persistence.onboardingPending,
                            onboardingSetupState: persistence.onboardingSetupState)
    }

    public func restoreStore(from prepared: PreparedLoad) -> SidebarStore {
        loadOutcome = prepared.outcome
        onboardingPending = prepared.onboardingPending
        onboardingSetupState = prepared.onboardingSetupState
        autosaveEnabled = prepared.outcome != .recoveredFromCorruptFile
        guard let snapshot = prepared.snapshot else { return SidebarStore.starter() }
        let store = SidebarStore()
        store.applySnapshot(snapshot)
        return store
    }

    public func loadSnapshot() -> SidebarSnapshot? {
        onboardingPending = FileManager.default.fileExists(atPath: onboardingMarkerURL.path)
        if let data = try? Data(contentsOf: onboardingDeferredURL) {
            // Even an unreadable deferred choice should not replay the takeover.
            onboardingSetupState = (try? JSONDecoder().decode(OnboardingSetupState.self, from: data)) ?? .deferred
        } else {
            onboardingSetupState = .notDeferred
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            loadOutcome = .missingFile
            return nil
        }
        guard let data = try? Data(contentsOf: fileURL) else {
            quarantineCorruptPersistedFile()
            loadOutcome = .recoveredFromCorruptFile
            autosaveEnabled = false
            return nil
        }
        do {
            let snapshot = try decoder.decode(SidebarSnapshot.self, from: data)
            guard !snapshot.spaces.isEmpty else {
                quarantineCorruptPersistedFile()
                loadOutcome = .recoveredFromCorruptFile
                autosaveEnabled = false
                return nil
            }
            guard snapshot.spaces.contains(where: { $0.id == snapshot.activeSpaceID }) else {
                quarantineCorruptPersistedFile()
                loadOutcome = .recoveredFromCorruptFile
                autosaveEnabled = false
                return nil
            }
            loadOutcome = .loaded
            return repairingArcTwinsOnce(snapshot, original: data)
        } catch {
            quarantineCorruptPersistedFile()
            loadOutcome = .recoveredFromCorruptFile
            autosaveEnabled = false
            return nil
        }
    }

    /// Beside the sidebar once the duplicate-Arc-space repair ran (its report, as JSON).
    public var arcTwinRepairMarkerURL: URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("arc-twin-repair.json", isDirectory: false)
    }

    /// Once per sidebar file: merges copies of one Arc space (`ArcTwinSpaces.repair`).
    /// When it changes anything, the file as it was is kept beside it
    /// (`sidebar.before-arc-twin-repair-<time>.json`) and the repaired one
    /// is written at once; if the copy cannot be made, nothing changes and
    /// the next launch tries again.
    private func repairingArcTwinsOnce(_ snapshot: SidebarSnapshot, original data: Data) -> SidebarSnapshot {
        guard !FileManager.default.fileExists(atPath: arcTwinRepairMarkerURL.path) else { return snapshot }
        let (repaired, report) = ArcTwinSpaces.repair(snapshot)
        if report.changed {
            let stamp = SidebarBackup.stamp(Date())
            let backup = fileURL.deletingLastPathComponent()
                .appendingPathComponent("sidebar.before-arc-twin-repair-\(stamp).json", isDirectory: false)
            guard (try? data.write(to: backup, options: [.withoutOverwriting])) != nil,
                  let encoded = try? encoder.encode(repaired),
                  (try? encoded.write(to: fileURL, options: [.atomic])) != nil else { return snapshot }
        }
        try? JSONEncoder().encode(ArcTwinRepairRecord(report)).write(to: arcTwinRepairMarkerURL, options: [.atomic])
        return report.changed ? repaired : snapshot
    }

    public func noteUserEditUnlockedAutosave() {
        guard !autosaveEnabled else { return }
        autosaveEnabled = true
        scheduleWrite()
    }

    private func quarantineCorruptPersistedFile() {
        let stamp = Int(Date().timeIntervalSince1970)
        let backup = fileURL.deletingLastPathComponent()
            .appendingPathComponent("sidebar.corrupt-\(stamp).json", isDirectory: false)
        try? FileManager.default.moveItem(at: fileURL, to: backup)
    }

    public func start(autoSave store: SidebarStore, onMutate: (() -> Void)? = nil) {
        stop()
        self.store = store
        store.onDidMutate = { [weak self] in
            guard let self else { return }
            if !self.autosaveEnabled {
                self.noteUserEditUnlockedAutosave()
            } else {
                self.scheduleWrite()
            }
            onMutate?()
        }
    }

    public func stop() {
        pendingWrite?.cancel()
        pendingWrite = nil
        store?.onDidMutate = nil
        store = nil
    }

    public func flush() {
        pendingWrite?.cancel()
        pendingWrite = nil
        writeNow()
    }

    private func scheduleWrite() {
        pendingWrite?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.writeNow()
        }
        pendingWrite = work
        queue.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }

    private func writeNow() {
        guard autosaveEnabled, let store else { return }
        let snapshot = ModelSignposts.measure(ModelSignposts.persistence, "SidebarSnapshot") { captureSnapshot(from: store) }
        ModelSignposts.measure(ModelSignposts.persistence, "SidebarEncodeWrite") {
            guard let data = try? encoder.encode(snapshot) else { return }
            let directory = fileURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: fileURL, options: [.atomic])
        }
    }

    /// Snapshots must be taken on the main thread because `SidebarStore` is main-thread-owned.
    private func captureSnapshot(from store: SidebarStore) -> SidebarSnapshot {
        if Thread.isMainThread {
            return store.makeSnapshot()
        }
        return DispatchQueue.main.sync { store.makeSnapshot() }
    }
}

/// What the duplicate-Arc-space repair did, kept in its marker file.
struct ArcTwinRepairRecord: Codable {
    var duplicatedSources, mergedSameProfile, removedEmpty, movedRows, keptCopies, droppedRepeats: Int

    init(_ report: ArcTwinSpaces.Report) {
        duplicatedSources = report.duplicatedSources
        mergedSameProfile = report.mergedSameProfile
        removedEmpty = report.removedEmpty
        movedRows = report.movedRows
        keptCopies = report.keptCopies
        droppedRepeats = report.droppedRepeats
    }
}

/// Copies of the sidebar ReArc keeps before replacing it with iCloud's.
public enum SidebarBackup {
    public static func folder(besides fileURL: URL) -> URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("Backups", isDirectory: true)
    }

    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    /// `Backups/sidebar-<reason>-<time>.json`, in the sidebar file's own format
    /// (put it in place of sidebar.json, with ReArc quit, to go back to it).
    @discardableResult
    public static func write(_ snapshot: SidebarSnapshot, besides fileURL: URL, reason: String, now: Date = Date()) throws -> URL {
        try save(snapshot, named: "sidebar-\(reason)", besides: fileURL, now: now)
    }

    /// `Backups/icloud-profile-before-delete-<time>.json`: iCloud's records
    /// of a profile as read just before deleting them there, each with its
    /// stamped fields (`serverTag` is CloudKit's system fields). Saving
    /// them again by hand undoes the delete.
    @discardableResult
    public static func writeCloudRecords(_ records: [SyncWireRecord], besides fileURL: URL, now: Date = Date()) throws -> URL {
        try save(records, named: "icloud-profile-before-delete", besides: fileURL, now: now)
    }

    private static func save<T: Encodable>(_ value: T, named name: String, besides fileURL: URL, now: Date) throws -> URL {
        let directory = folder(besides: fileURL)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var url = directory.appendingPathComponent("\(name)-\(stamp(now)).json", isDirectory: false)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(name)-\(stamp(now))-\(n).json", isDirectory: false)
            n += 1
        }
        try encoder.encode(value).write(to: url, options: [.withoutOverwriting])
        return url
    }
}
