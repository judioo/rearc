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

    /// Beside the sidebar file from a first run's onboarding start until it
    /// completes or is skipped. The sidebar is saved meanwhile (sync's state
    /// must match it), so the marker, not the file's absence, keeps a quit or
    /// crash mid-onboarding a first run. Installs from before the marker have
    /// a sidebar file and no marker: never a first run.
    public var onboardingMarkerURL: URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("onboarding-pending", isDirectory: false)
    }

    /// No sidebar yet, or one an unfinished onboarding left.
    public var isFirstRun: Bool { loadOutcome == .missingFile || onboardingPending }

    /// Written before the onboarding can change the store.
    public func beginOnboarding() {
        guard !FileManager.default.fileExists(atPath: onboardingMarkerURL.path) else { return }
        try? FileManager.default.createDirectory(at: onboardingMarkerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data().write(to: onboardingMarkerURL, options: [.atomic])
    }

    /// Completed or skipped: the next launch opens the browser.
    public func finishOnboarding() {
        try? FileManager.default.removeItem(at: onboardingMarkerURL)
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

        public var isFirstRun: Bool { outcome == .missingFile || onboardingPending }
    }

    public static func prepareLoad(from fileURL: URL) -> PreparedLoad {
        let persistence = SidebarFilePersistence(fileURL: fileURL)
        let snapshot = persistence.loadSnapshot()
        return PreparedLoad(snapshot: snapshot, outcome: persistence.loadOutcome, onboardingPending: persistence.onboardingPending)
    }

    public func restoreStore(from prepared: PreparedLoad) -> SidebarStore {
        loadOutcome = prepared.outcome
        onboardingPending = prepared.onboardingPending
        autosaveEnabled = prepared.outcome != .recoveredFromCorruptFile
        guard let snapshot = prepared.snapshot else { return SidebarStore.starter() }
        let store = SidebarStore()
        store.applySnapshot(snapshot)
        return store
    }

    public func loadSnapshot() -> SidebarSnapshot? {
        onboardingPending = FileManager.default.fileExists(atPath: onboardingMarkerURL.path)
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
            return snapshot
        } catch {
            quarantineCorruptPersistedFile()
            loadOutcome = .recoveredFromCorruptFile
            autosaveEnabled = false
            return nil
        }
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
