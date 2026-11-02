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

/// Local JSON file persistence at `~/Library/Application Support/ReArc/sidebar.json`.
public final class SidebarFilePersistence: SidebarPersisting {
    public static let defaultFileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("ReArc", isDirectory: true)
            .appendingPathComponent("sidebar.json", isDirectory: false)
    }()

    private let fileURL: URL
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

    /// Loads persisted state, or sample data when the file is missing or invalid.
    public static func loadStore(
        fileURL: URL = SidebarFilePersistence.defaultFileURL,
        fallback: () -> SidebarStore = { SidebarStore.sample() },
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

    public func loadSnapshot() -> SidebarSnapshot? {
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
        let snapshot = captureSnapshot(from: store)
        guard let data = try? encoder.encode(snapshot) else { return }
        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: [.atomic])
    }

    /// Snapshots must be taken on the main thread because `SidebarStore` is main-thread-owned.
    private func captureSnapshot(from store: SidebarStore) -> SidebarSnapshot {
        if Thread.isMainThread {
            return store.makeSnapshot()
        }
        return DispatchQueue.main.sync { store.makeSnapshot() }
    }
}
