import Foundation

public struct ElementDescriptor: Equatable, Sendable {
    public var tag: String
    public var id: String?
    public var classes: [String]
    public var attrs: [String: String]
    public var role: String?
    public var accessibleName: String?
    public var structuralPath: [String]
    public var indexAmongType: Int
    /// Document-wide match counts supplied by the picker runtime (when available).
    public var tagMatchCount: Int?
    public var idMatchCount: Int?
    public var classMatchCounts: [String: Int]

    public init(
        tag: String,
        id: String? = nil,
        classes: [String] = [],
        attrs: [String: String] = [:],
        role: String? = nil,
        accessibleName: String? = nil,
        structuralPath: [String] = [],
        indexAmongType: Int = 1,
        tagMatchCount: Int? = nil,
        idMatchCount: Int? = nil,
        classMatchCounts: [String: Int] = [:]
    ) {
        self.tag = tag.lowercased()
        self.id = id
        self.classes = classes
        self.attrs = attrs
        self.role = role
        self.accessibleName = accessibleName
        self.structuralPath = structuralPath
        self.indexAmongType = indexAmongType
        self.tagMatchCount = tagMatchCount
        self.idMatchCount = idMatchCount
        self.classMatchCounts = classMatchCounts
    }
}

public enum SelectorStep: Equatable, Sendable {
    case id(String)
    case classToken(String)
    case attribute(name: String, value: String)
    case tag(String)
    case nthOfType(Int)
}

public struct SelectorCandidate: Equatable, Sendable {
    public var steps: [SelectorStep]
    public var css: String
    public var matchCount: Int

    public init(steps: [SelectorStep], css: String, matchCount: Int) {
        self.steps = steps
        self.css = css
        self.matchCount = matchCount
    }
}

public enum SelectorTokenHeuristics {
    private static let componentWords: Set<String> = [
        "nav", "menu", "header", "footer", "main", "content", "sidebar", "button", "btn",
        "link", "item", "list", "card", "title", "heading", "search", "form", "input",
        "modal", "dialog", "tab", "panel", "toolbar", "icon", "avatar", "logo", "banner",
        "price", "article",
    ]

    public static func isHumanToken(_ s: String) -> Bool {
        let count = s.count
        if count < 2 || count > 32 { return false }
        for ch in s {
            guard let scalar = ch.unicodeScalars.first, scalar.isASCII else { return false }
            let c = Character(scalar)
            guard c.isLetter || c.isNumber || c == "-" || c == "_" else { return false }
        }
        let digits = s.filter(\.isNumber).count
        if Double(digits) / Double(count) > 0.25 { return false }
        if s.range(of: #"\d{4,}"#, options: .regularExpression) != nil { return false }
        if s.range(of: #"^[0-9a-f]{8,}$"#, options: .regularExpression) != nil { return false }
        let vowels = s.lowercased().filter { "aeiou".contains($0) }.count
        if count >= 8, vowels == 0, s.contains(where: \.isNumber) { return false }
        if shannonBitsPerChar(s) > 4.2, vowels * 3 < count { return false }
        return true
    }

    public static func tokenStability(_ s: String) -> Double {
        guard isHumanToken(s) else { return 0 }
        var score = 0.70
        if componentWords.contains(where: { s.lowercased().contains($0) }) { score += 0.20 }
        if s == s.lowercased() || s.contains("-") { score += 0.10 }
        return min(1, score)
    }

    public static func semanticAttributeScore(name: String, value: String) -> Double {
        guard !value.isEmpty, value.count <= 64 else { return 0 }
        switch name {
        case "data-testid", "data-test", "data-cy", "data-qa": return 1.00
        case "aria-label": return 0.90
        case "role":
            let bad = Set(["generic", "presentation", "none"])
            return bad.contains(value) ? 0 : 0.85
        case "name": return 0.80
        case "href": return 0.75
        case "placeholder", "alt", "title": return 0.45
        default: return 0
        }
    }

    private static func shannonBitsPerChar(_ s: String) -> Double {
        guard !s.isEmpty else { return 0 }
        var freq: [Character: Int] = [:]
        for ch in s { freq[ch, default: 0] += 1 }
        let n = Double(s.count)
        var entropy = 0.0
        for count in freq.values {
            let p = Double(count) / n
            entropy -= p * log2(p)
        }
        return entropy
    }
}

public enum SelectorScoringEngine {
    public static func generateCandidates(from descriptor: ElementDescriptor) -> [SelectorCandidate] {
        var pool: [SelectorCandidate] = []
        for step in atomicSteps(descriptor) {
            let css = css(for: [step])
            let count = estimatedMatchCount(for: step, descriptor: descriptor)
            pool.append(SelectorCandidate(steps: [step], css: css, matchCount: count))
        }
        if pool.isEmpty {
            let step = SelectorStep.nthOfType(descriptor.indexAmongType)
            let css = "\(descriptor.tag):nth-of-type(\(descriptor.indexAmongType))"
            pool.append(SelectorCandidate(steps: [step], css: css, matchCount: 1))
        }
        return rank(pool, descriptor: descriptor).prefix(8).map { $0.0 }
    }

    public static func score(_ candidate: SelectorCandidate, descriptor: ElementDescriptor) -> Double {
        let semantic = bestSemanticUsed(candidate)
        let idStab = idStabilityUsed(candidate)
        let classMean = meanClassStability(candidate)
        var unique = candidate.matchCount == 1 ? 1.0 : 0.0
        if candidate.matchCount == 1, hasLiveMatchEvidence(descriptor) {
            unique = min(1.0, unique + 0.15)
        }
        let tagBonus = ["button", "a", "input", "textarea", "select", "h1", "h2", "h3", "h4", "h5", "h6"]
            .contains(descriptor.tag) ? 1.0 : 0.0
        let depthPenalty = Double(max(0, candidate.steps.count - 1)) * 0.18
        let nthPenalty = candidate.steps.contains(where: {
            if case .nthOfType = $0 { return true }
            return false
        }) ? 0.50 : 0.0
        let raw = 1.00 * semantic + 0.55 * idStab + 0.40 * classMean + 0.35 * unique + 0.10 * tagBonus
            - depthPenalty - nthPenalty
        return min(1, max(0, raw))
    }

    public static func rank(_ candidates: [SelectorCandidate], descriptor: ElementDescriptor) -> [(SelectorCandidate, Double)] {
        candidates
            .map { ($0, score($0, descriptor: descriptor)) }
            .sorted { $0.1 > $1.1 }
    }

    private static func estimatedMatchCount(for step: SelectorStep, descriptor: ElementDescriptor) -> Int {
        switch step {
        case .id:
            return max(1, descriptor.idMatchCount ?? 1)
        case .classToken(let token):
            return max(1, descriptor.classMatchCounts[token] ?? 1)
        case .tag:
            return max(1, descriptor.tagMatchCount ?? 1)
        case .attribute, .nthOfType:
            return 1
        }
    }

    private static func atomicSteps(_ d: ElementDescriptor) -> [SelectorStep] {
        var steps: [SelectorStep] = []
        if let id = d.id, SelectorTokenHeuristics.isHumanToken(id) {
            steps.append(.id(id))
        }
        for token in d.classes where SelectorTokenHeuristics.isHumanToken(token) {
            steps.append(.classToken(token))
        }
        for (name, value) in d.attrs {
            if SelectorTokenHeuristics.semanticAttributeScore(name: name, value: value) > 0 {
                steps.append(.attribute(name: name, value: value))
            }
        }
        if steps.isEmpty {
            steps.append(.tag(d.tag))
        }
        return steps
    }

    private static func css(for steps: [SelectorStep]) -> String {
        steps.map { step in
            switch step {
            case .id(let id): return "#\(escapeIdent(id))"
            case .classToken(let t): return ".\(escapeIdent(t))"
            case .attribute(let name, let value):
                return "[\(name)=\"\(escapeString(value))\"]"
            case .tag(let tag): return tag
            case .nthOfType(let n): return ":nth-of-type(\(n))"
            }
        }.joined()
    }

    private static func escapeIdent(_ s: String) -> String {
        s.replacingOccurrences(of: ":", with: "\\:")
    }

    private static func escapeString(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func hasLiveMatchEvidence(_ descriptor: ElementDescriptor) -> Bool {
        if descriptor.tagMatchCount != nil || descriptor.idMatchCount != nil {
            return true
        }
        return !descriptor.classMatchCounts.isEmpty
    }

    private static func bestSemanticUsed(_ c: SelectorCandidate) -> Double {
        c.steps.compactMap { step -> Double? in
            if case .attribute(let name, let value) = step {
                let s = SelectorTokenHeuristics.semanticAttributeScore(name: name, value: value)
                return s > 0 ? s : nil
            }
            return nil
        }.max() ?? 0
    }

    private static func idStabilityUsed(_ c: SelectorCandidate) -> Double {
        for step in c.steps {
            if case .id(let id) = step {
                return SelectorTokenHeuristics.tokenStability(id)
            }
        }
        return 0
    }

    private static func meanClassStability(_ c: SelectorCandidate) -> Double {
        let values = c.steps.compactMap { step -> Double? in
            if case .classToken(let t) = step { return SelectorTokenHeuristics.tokenStability(t) }
            return nil
        }
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }
}
