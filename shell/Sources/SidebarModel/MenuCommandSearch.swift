import Foundation

/// A menu snapshot keeps matching independent of AppKit and menu targets.
public struct MenuCommand: Equatable, Identifiable {
    public var id: String
    public var title: String
    public var path: String
    public var keyEquivalent: String
    public var isEnabled: Bool
    public var hasAction: Bool
    public var requiresExactQuery: Bool

    public init(id: String, title: String, path: String, keyEquivalent: String = "",
                isEnabled: Bool = true, hasAction: Bool = true, requiresExactQuery: Bool = false) {
        self.id = id
        self.title = title
        self.path = path
        self.keyEquivalent = keyEquivalent
        self.isEnabled = isEnabled
        self.hasAction = hasAction
        self.requiresExactQuery = requiresExactQuery
    }
}

public enum MenuCommandSearch {
    public static func matches(_ commands: [MenuCommand], query: String, registered: [AppCommand]) -> [MenuCommand] {
        Index(commands, registered: registered).matches(query: query)
    }

    static func normalized(_ value: String) -> String {
        value.replacingOccurrences(of: "…", with: "").replacingOccurrences(of: "...", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
