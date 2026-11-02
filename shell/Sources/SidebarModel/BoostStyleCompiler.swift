import Foundation

/// One validated CSS rule block (selector + declarations) applied under a stable style element id.
public struct BoostCSSRule: Equatable, Sendable, Codable, Hashable {
    public var id: String
    public var css: String

    public init(id: String, css: String) {
        self.id = id
        self.css = css
    }
}

public enum BoostStyleCompiler {
    /// Parses a stylesheet into validated rule blocks; returns nil when validation or tab budget fails.
    public static func compileStylesheet(_ css: String, allowInStyle: Bool = true) -> [BoostCSSRule]? {
        let trimmed = css.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let blocks = parseRuleBlocks(trimmed)
        guard !blocks.isEmpty else { return nil }
        var rules: [BoostCSSRule] = []
        for (index, block) in blocks.enumerated() {
            if !BoostSecurity.validateCSS(block, allowInStyle: allowInStyle).isEmpty {
                return nil
            }
            rules.append(BoostCSSRule(id: String(index), css: block))
        }
        let combined = rules.map(\.css)
        if !BoostSecurity.tabCSSBudgetOK(combined) {
            return nil
        }
        return rules
    }

    public static func parseRuleBlocks(_ css: String) -> [String] {
        var rules: [String] = []
        var depth = 0
        var start = css.startIndex
        var index = css.startIndex
        while index < css.endIndex {
            let ch = css[index]
            if ch == "{" {
                depth += 1
            } else if ch == "}" {
                depth -= 1
                if depth == 0 {
                    let end = css.index(after: index)
                    let block = String(css[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !block.isEmpty {
                        rules.append(block)
                    }
                    start = end
                }
            }
            index = css.index(after: index)
        }
        let tail = String(css[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty, rules.isEmpty {
            rules.append(tail)
        }
        return rules
    }
}
