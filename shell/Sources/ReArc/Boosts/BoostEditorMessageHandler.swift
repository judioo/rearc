import Foundation
import SidebarModel
import WebKit

final class BoostEditorMessageHandler: NSObject, WKScriptMessageHandler {
    var onPick: ((PickedElementSnapshot) -> Void)?
    var onCancel: (() -> Void)?

    private static let maxMessageBytes = 65_536

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == BoostPickerScript.messageHandler else { return }
        guard message.frameInfo.isMainFrame else { return }
        guard let body = message.body as? [String: Any] else { return }
        if let json = try? JSONSerialization.data(withJSONObject: body),
           json.count > Self.maxMessageBytes {
            return
        }
        if let type = body["type"] as? String, type == "cancel" {
            onCancel?()
            return
        }
        guard let snapshot = Self.decodePick(body) else { return }
        onPick?(snapshot)
    }

    static func decodePick(_ body: [String: Any]) -> PickedElementSnapshot? {
        guard let descObj = body["descriptor"] as? [String: Any],
              let tag = descObj["tag"] as? String else { return nil }
        let boundsObj = body["bounds"] as? [String: Any] ?? [:]
        let bounds = ElementBounds(
            x: boundsObj["x"] as? Double ?? 0,
            y: boundsObj["y"] as? Double ?? 0,
            width: boundsObj["width"] as? Double ?? 0,
            height: boundsObj["height"] as? Double ?? 0
        )
        var classMatchCounts: [String: Int] = [:]
        if let raw = descObj["classMatchCounts"] as? [String: Any] {
            for (key, value) in raw {
                if let n = value as? Int { classMatchCounts[key] = n }
                else if let n = value as? Double { classMatchCounts[key] = Int(n) }
            }
        }
        let descriptor = ElementDescriptor(
            tag: tag,
            id: descObj["id"] as? String,
            classes: descObj["classes"] as? [String] ?? [],
            attrs: descObj["attrs"] as? [String: String] ?? [:],
            role: descObj["role"] as? String,
            accessibleName: descObj["accessibleName"] as? String,
            structuralPath: descObj["structuralPath"] as? [String] ?? [],
            indexAmongType: descObj["indexAmongType"] as? Int ?? 1,
            tagMatchCount: descObj["tagMatchCount"] as? Int ?? (descObj["tagMatchCount"] as? Double).map { Int($0) },
            idMatchCount: descObj["idMatchCount"] as? Int ?? (descObj["idMatchCount"] as? Double).map { Int($0) },
            classMatchCounts: classMatchCounts
        )
        return PickedElementSnapshot(
            descriptor: descriptor,
            bounds: bounds,
            viewportWidth: body["viewportWidth"] as? Double ?? 1,
            viewportHeight: body["viewportHeight"] as? Double ?? 1,
            computedStyles: body["computedStyles"] as? [String: String] ?? [:]
        )
    }
}
