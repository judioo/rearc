import Foundation

/// Loads and saves easel documents outside the sidebar snapshot (local-first; sync attaches later).
public protocol EaselPersisting: AnyObject {
    func loadDocument(id: UUID) -> EaselDocument?
    func saveDocument(_ document: EaselDocument)
    func deleteDocument(id: UUID)
    func documentExists(id: UUID) -> Bool
}

/// One JSON file per document: `~/Library/Application Support/ReArc/easels/{uuid}.json`
/// (`ShellDataLocation`).
public final class EaselFilePersistence: EaselPersisting {
    public static let defaultDirectoryURL: URL = ShellDataLocation.root
        .appendingPathComponent("easels", isDirectory: true)

    private let directoryURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let queue: DispatchQueue
    private var pendingWrites: [UUID: DispatchWorkItem] = [:]
    private var writeGeneration: [UUID: Int] = [:]
    private let debounceInterval: TimeInterval

    public init(
        directoryURL: URL = EaselFilePersistence.defaultDirectoryURL,
        debounceInterval: TimeInterval = 0.35,
        queue: DispatchQueue = DispatchQueue(label: "net.rearc.easel.persistence")
    ) {
        self.directoryURL = directoryURL
        self.debounceInterval = debounceInterval
        self.queue = queue
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    public func loadDocument(id: UUID) -> EaselDocument? {
        let url = fileURL(for: id)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(EaselDocument.self, from: data)
    }

    public func saveDocument(_ document: EaselDocument) {
        scheduleWrite(document)
    }

    public func flushDocument(_ document: EaselDocument) {
        pendingWrites[document.id]?.cancel()
        pendingWrites[document.id] = nil
        writeNow(document)
    }

    public func deleteDocument(id: UUID) {
        pendingWrites[id]?.cancel()
        pendingWrites.removeValue(forKey: id)
        writeGeneration[id, default: 0] += 1
        try? FileManager.default.removeItem(at: fileURL(for: id))
    }

    public func flushAllPending() {
        let ids = Array(pendingWrites.keys)
        for id in ids {
            pendingWrites[id]?.cancel()
            pendingWrites[id] = nil
        }
    }

    public func documentExists(id: UUID) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(for: id).path)
    }

    private func scheduleWrite(_ document: EaselDocument) {
        pendingWrites[document.id]?.cancel()
        writeGeneration[document.id, default: 0] += 1
        let generation = writeGeneration[document.id]!
        let captured = document
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.writeGeneration[captured.id] == generation else { return }
            self.writeNow(captured)
        }
        pendingWrites[document.id] = work
        queue.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }

    private func writeNow(_ document: EaselDocument) {
        guard let data = try? encoder.encode(document) else { return }
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try? data.write(to: fileURL(for: document.id), options: [.atomic])
    }

    private func fileURL(for id: UUID) -> URL {
        directoryURL.appendingPathComponent("\(id.uuidString).json", isDirectory: false)
    }
}

/// Test/local harness without touching disk.
public final class InMemoryEaselPersistence: EaselPersisting {
    public var documents: [UUID: EaselDocument] = [:]

    public init() {}

    public func loadDocument(id: UUID) -> EaselDocument? {
        documents[id]
    }

    public func saveDocument(_ document: EaselDocument) {
        documents[document.id] = document
    }

    public func deleteDocument(id: UUID) {
        documents.removeValue(forKey: id)
    }

    public func documentExists(id: UUID) -> Bool {
        documents[id] != nil
    }
}
