import SwiftUI
import UniformTypeIdentifiers
import SidebarModel

extension SidebarDragPayload {
    static let contentType = UTType(exportedAs: SidebarDragType.identifier)

    static func hasItem(_ info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [contentType])
    }

    /// Window-local drag state is absent in another window. The UUID resolves
    /// its source container in the shared store; never interpret arbitrary text.
    static func load(_ info: DropInfo, move: @escaping (UUID) -> Void) -> Bool {
        load(info.itemProviders(for: [contentType]), move: move)
    }

    static func load(_ providers: [NSItemProvider], move: @escaping (UUID) -> Void) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(SidebarDragType.identifier) }) else { return false }
        provider.loadDataRepresentation(forTypeIdentifier: SidebarDragType.identifier) { data, _ in
            guard let data, let text = String(data: data, encoding: .utf8), let id = UUID(uuidString: text) else { return }
            DispatchQueue.main.async { move(id) }
        }
        return true
    }
}
