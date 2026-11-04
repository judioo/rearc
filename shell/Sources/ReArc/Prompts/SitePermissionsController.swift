import Foundation
import SidebarModel

/// The shell's record of permission answers (`SitePermissions.json` next to
/// the sidebar file, remembered answers of persistent profiles only). It
/// backs the URL field's site-permissions indicator on both engines and is
/// WebKit's permission store; Chromium keeps its own remembered settings
/// (chrome://settings/content), so there this is a mirror for the indicator.
@Observable
final class SitePermissionsController {
    private(set) var store: SitePermissionStore
    @ObservationIgnored private let fileURL: URL?

    init(fileURL: URL?) {
        self.fileURL = fileURL
        store = fileURL.map(SitePermissionStore.load(from:)) ?? SitePermissionStore()
    }

    func record(_ decision: PermissionDecision, remembered: Bool, request: PermissionPromptRequest, scope: String) {
        guard decision != .dismiss else { return }
        store.record(decision, remembered: remembered, types: request.types, origin: request.origin, scope: scope)
        if remembered { save() }
    }

    func entries(origin: String, scope: String) -> [(type: PermissionType, entry: SitePermissionStore.Entry)] {
        store.entries(origin: origin, scope: scope)
    }

    func rememberedDecision(for request: PermissionPromptRequest, scope: String) -> PermissionDecision? {
        store.rememberedDecision(for: request.types, origin: request.origin, scope: scope)
    }

    func reset(origin: String, scope: String, type: PermissionType? = nil) {
        store.reset(origin: origin, scope: scope, type: type)
        save()
    }

    /// A private session ended: its answers go with it.
    func dropScope(_ scope: String) {
        store.dropScope(scope)
    }

    private func save() {
        guard let fileURL else { return }
        do {
            try store.save(to: fileURL)
        } catch {
            FileHandle.standardError.write(Data("[ReArc] could not save \(fileURL.lastPathComponent): \(error.localizedDescription)\n".utf8))
        }
    }
}
