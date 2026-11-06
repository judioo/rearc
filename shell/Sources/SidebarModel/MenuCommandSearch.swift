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
        let needle = normalized(query)
        let registeredTitles = Set(registered.map { normalized($0.title) })
        var seen: Set<String> = []
        return commands.compactMap { command -> (MenuCommand, Int)? in
            let title = normalized(command.title)
            guard command.isEnabled, command.hasAction, !title.isEmpty,
                  !registeredTitles.contains(title),
                  !command.requiresExactQuery || needle == title,
                  seen.insert(command.path + "\n" + command.keyEquivalent).inserted else { return nil }
            if needle.isEmpty { return (command, 0) }
            guard let match = TypeTravelFuzzyMatch.bestScore(query: needle, title: command.title, keywords: [command.path]) else { return nil }
            return (command, match.score)
        }.sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            if $0.0.title.count != $1.0.title.count { return $0.0.title.count < $1.0.title.count }
            return $0.0.path < $1.0.path
        }.map { $0.0 }
    }

    private static func normalized(_ value: String) -> String {
        value.replacingOccurrences(of: "…", with: "").replacingOccurrences(of: "...", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
