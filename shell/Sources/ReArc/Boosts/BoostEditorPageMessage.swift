import Foundation
import SidebarModel

/// Messages the boost picker posts from the editor isolated world. On
/// Chromium they arrive as JSON through the isolated page-message channel
/// (`rearcPostMessage`). They are untrusted page data: only these two kinds
/// are accepted, and a pick is decoded field by field like the WebKit bridge.
enum BoostEditorPageMessage {
    case pick(PickedElementSnapshot)
    case cancel

    /// The engine's own limit for one message.
    static let maxJSONBytes = 65_536

    static func decode(json: String) -> BoostEditorPageMessage? {
        guard json.utf8.count <= maxJSONBytes,
              let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let type = object["type"] as? String else { return nil }
        switch type {
        case "cancel":
            return .cancel
        case "pick":
            return BoostEditorMessageHandler.decodePick(object).map(BoostEditorPageMessage.pick)
        default:
            return nil
        }
    }
}
