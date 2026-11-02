import Foundation

/// In-memory cache with debounced persistence for easel documents (sync seam).
public final class EaselDocumentStore {
    private let persistence: EaselPersisting
    private var cache: [UUID: EaselDocument] = [:]

    public init(persistence: EaselPersisting = EaselFilePersistence()) {
        self.persistence = persistence
    }

    public func document(id: UUID) -> EaselDocument? {
        if let cached = cache[id] { return cached }
        if let loaded = persistence.loadDocument(id: id) {
            cache[id] = loaded
            return loaded
        }
        return nil
    }

    @discardableResult
    public func create(_ document: EaselDocument) -> EaselDocument {
        cache[document.id] = document
        persistence.saveDocument(document)
        return document
    }

    public func save(_ document: EaselDocument) {
        cache[document.id] = document
        persistence.saveDocument(document)
    }

    public func flush(_ document: EaselDocument) {
        cache[document.id] = document
        if let filePersistence = persistence as? EaselFilePersistence {
            filePersistence.flushDocument(document)
        } else {
            persistence.saveDocument(document)
        }
    }

    public func flushAllCachedDocuments() {
        for document in cache.values {
            flush(document)
        }
    }

    public func deleteDocument(id: UUID, sidebar: SidebarStore) {
        cache.removeValue(forKey: id)
        persistence.deleteDocument(id: id)
        sidebar.purgeSidebarReferences(toDocument: id)
    }

    public func renameDocument(id: UUID, title: String) {
        guard var doc = document(id: id) else { return }
        doc.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        doc.updatedAt = Date()
        save(doc)
    }
}
