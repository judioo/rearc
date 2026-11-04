import Foundation

public struct ElementBounds: Equatable, Codable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var areaRatio: Double {
        guard width > 0, height > 0 else { return 0 }
        return (width * height) / max(1, width * height)
    }
}

/// Page-reported pick payload (descriptor + geometry + style snapshot).
public struct PickedElementSnapshot: Equatable, Sendable {
    public var descriptor: ElementDescriptor
    public var bounds: ElementBounds
    public var viewportWidth: Double
    public var viewportHeight: Double
    public var computedStyles: [String: String]

    public init(
        descriptor: ElementDescriptor,
        bounds: ElementBounds,
        viewportWidth: Double,
        viewportHeight: Double,
        computedStyles: [String: String] = [:]
    ) {
        self.descriptor = descriptor
        self.bounds = bounds
        self.viewportWidth = viewportWidth
        self.viewportHeight = viewportHeight
        self.computedStyles = computedStyles
    }

    public var rectAreaRatio: Double {
        let vpArea = max(1, viewportWidth * viewportHeight)
        return (bounds.width * bounds.height) / vpArea
    }
}

public struct RankedSelectorChoice: Equatable, Sendable {
    public var candidate: SelectorCandidate
    public var score: Double
    public var displayLabel: String

    public init(candidate: SelectorCandidate, score: Double, displayLabel: String) {
        self.candidate = candidate
        self.score = score
        self.displayLabel = displayLabel
    }
}

public enum BoostEditorPipeline {
    public static func topCandidates(
        from snapshot: PickedElementSnapshot,
        limit: Int = 3
    ) -> [RankedSelectorChoice] {
        let generated = SelectorScoringEngine.generateCandidates(from: snapshot.descriptor)
        let ranked = SelectorScoringEngine.rank(generated, descriptor: snapshot.descriptor)
        return ranked.prefix(limit).map { pair in
            RankedSelectorChoice(
                candidate: pair.0,
                score: pair.1,
                displayLabel: humanReadableSelector(pair.0.css, score: pair.1)
            )
        }
    }

    public static func humanReadableSelector(_ css: String, score: Double) -> String {
        let pct = Int((score * 100).rounded())
        return "\(css)  ·  \(pct)% confidence"
    }
}

public struct BoostAncestorCue: Equatable, Sendable {
    public var tag: String
    public var token: String?
    public var role: String?

    public init(tag: String, token: String? = nil, role: String? = nil) {
        self.tag = tag
        self.token = token
        self.role = role
    }
}

public struct BoostSelectorFingerprint: Equatable, Sendable {
    public var tag: String
    public var role: String?
    public var accessibleName: String?
    public var text: String?
    public var hrefPath: String?
    public var classHints: [String]
    public var ancestorCues: [BoostAncestorCue]
    public var rectAreaRatio: Double

    public init(
        tag: String,
        role: String? = nil,
        accessibleName: String? = nil,
        text: String? = nil,
        hrefPath: String? = nil,
        classHints: [String] = [],
        ancestorCues: [BoostAncestorCue] = [],
        rectAreaRatio: Double = 0
    ) {
        self.tag = tag.lowercased()
        self.role = role
        self.accessibleName = accessibleName
        self.text = text
        self.hrefPath = hrefPath
        self.classHints = Array(classHints.prefix(3))
        self.ancestorCues = Array(ancestorCues.prefix(3))
        self.rectAreaRatio = rectAreaRatio
    }

    public static func from(snapshot: PickedElementSnapshot) -> BoostSelectorFingerprint {
        let d = snapshot.descriptor
        let hints = d.classes.filter { SelectorTokenHeuristics.isHumanToken($0) }.prefix(3)
        let cues = d.structuralPath.prefix(3).map { BoostAncestorCue(tag: $0) }
        return BoostSelectorFingerprint(
            tag: d.tag,
            role: d.role,
            accessibleName: d.accessibleName,
            text: nil,
            hrefPath: d.attrs["href"],
            classHints: Array(hints),
            ancestorCues: cues,
            rectAreaRatio: snapshot.rectAreaRatio
        )
    }
}

public struct BoostRepairScanNode: Equatable, Sendable {
    public var snapshot: PickedElementSnapshot
    public var similarity: Double

    public init(snapshot: PickedElementSnapshot, similarity: Double) {
        self.snapshot = snapshot
        self.similarity = similarity
    }
}

public enum BoostSelectorRepairDecision: Equatable, Sendable {
    case sessionApply(SelectorCandidate, similarity: Double)
    case stale(reason: BoostSelectorRepairStaleReason)
}

public enum BoostSelectorRepairStaleReason: Equatable, Sendable {
    case belowSimilarityFloor
    case insufficientMargin
    case tagGuard
    case areaGuard
    case noCandidate
}

public enum BoostSelectorRepair {
    public static let similarityFloor = 0.82
    public static let marginFloor = 0.08

    public static func similarity(node: PickedElementSnapshot, fingerprint: BoostSelectorFingerprint) -> Double {
        var w = 0.0
        var s = 0.0
        func weigh(_ weight: Double, hit: Bool) {
            w += weight
            if hit { s += weight }
        }
        let d = node.descriptor
        if let a = fingerprint.accessibleName, !a.isEmpty,
           let b = d.accessibleName, !b.isEmpty {
            weigh(0.28, hit: a == b)
        }
        if let ft = fingerprint.text, !ft.isEmpty,
           let nt = d.accessibleName, !nt.isEmpty, ft == nt {
            weigh(0.18, hit: true)
        } else if let ft = fingerprint.text, !ft.isEmpty {
            weigh(0.18, hit: false)
        }
        weigh(0.14, hit: {
            guard let fr = fingerprint.role, !fr.isEmpty,
                  let nr = d.role, !nr.isEmpty else { return false }
            return fr == nr
        }())
        weigh(0.12, hit: {
            guard let fp = fingerprint.hrefPath, !fp.isEmpty,
                  let hp = d.attrs["href"], !hp.isEmpty else { return false }
            return fp == hp
        }())
        if !fingerprint.classHints.isEmpty {
            let nodeClasses = Set(d.classes)
            let hintSet = Set(fingerprint.classHints)
            let jaccard: Double = {
                let inter = hintSet.intersection(nodeClasses).count
                let union = hintSet.union(nodeClasses).count
                guard union > 0 else { return 0 }
                return Double(inter) / Double(union)
            }()
            weigh(0.16, hit: jaccard >= 0.50)
        }
        if !fingerprint.ancestorCues.isEmpty {
            let cueHit = fingerprint.ancestorCues.contains { d.structuralPath.contains($0.tag) }
            weigh(0.12, hit: cueHit)
        }
        guard w > 0 else { return 0 }
        return s / w
    }

    public static func considerRepair(
        fingerprint: BoostSelectorFingerprint,
        scan: [PickedElementSnapshot]
    ) -> BoostSelectorRepairDecision {
        let ranked = scan
            .map { BoostRepairScanNode(snapshot: $0, similarity: similarity(node: $0, fingerprint: fingerprint)) }
            .sorted { $0.similarity > $1.similarity }
        guard let best = ranked.first else {
            return .stale(reason: .noCandidate)
        }
        let second = ranked.dropFirst().first
        if best.similarity < similarityFloor {
            return .stale(reason: .belowSimilarityFloor)
        }
        if let second, best.similarity - second.similarity < marginFloor {
            return .stale(reason: .insufficientMargin)
        }
        let bestTag = best.snapshot.descriptor.tag
        let blockedTags = Set(["html", "body", "head", "main"])
        if blockedTags.contains(bestTag), fingerprint.tag != bestTag {
            return .stale(reason: .tagGuard)
        }
        if best.snapshot.rectAreaRatio > 0.60, fingerprint.rectAreaRatio < 0.25 {
            return .stale(reason: .areaGuard)
        }
        let candidates = SelectorScoringEngine.generateCandidates(from: best.snapshot.descriptor)
        guard let proposed = candidates.first else {
            return .stale(reason: .noCandidate)
        }
        return .sessionApply(proposed, similarity: best.similarity)
    }
}

public enum BoostQuickActions {
    public static func hideElementRule(selector: String) -> String {
        "\(selector) {\n  display: none !important;\n}\n"
    }

    /// Generalize `:nth-of-type(n)` to `:nth-of-type(*)` style wildcard by dropping the index.
    public static func zapSimilarSelector(_ css: String) -> String {
        css.replacingOccurrences(
            of: #":nth-of-type\(\d+\)"#,
            with: "",
            options: .regularExpression
        )
    }

    public static func zapSimilarRule(selector: String) -> String {
        let generalized = zapSimilarSelector(selector)
        return hideElementRule(selector: generalized)
    }

    public static func commentedComputedStylesReference(
        selector: String,
        styles: [String: String]
    ) -> String {
        let interesting = ["color", "background-color", "font-size", "font-weight", "padding", "margin", "border", "display"]
        var lines = ["/* Reference computed styles for \(selector) */"]
        for key in interesting {
            if let val = styles[key], !val.isEmpty {
                lines.append("/*   \(key): \(val); */")
            }
        }
        lines.append("\(selector) {\n  \n}\n")
        return lines.joined(separator: "\n")
    }

    public static func appendRule(to css: String, rule: String) -> String {
        let trimmed = css.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return rule }
        return trimmed + "\n\n" + rule
    }
}

/// In-memory editor draft; persistence only on explicit save.
public struct BoostEditorDraft: Equatable, Sendable {
    public var packageID: UUID
    public var baselineCSS: String
    public var draftCSS: String
    public var selectedSelector: String?
    public var candidateChoices: [RankedSelectorChoice]
    public var pickerActive: Bool
    public var selectorDead: Bool
    /// The next pick zaps (hides) the element instead of selecting it.
    public var zapOnPick: Bool = false

    public init(
        packageID: UUID,
        baselineCSS: String,
        draftCSS: String? = nil,
        selectedSelector: String? = nil,
        candidateChoices: [RankedSelectorChoice] = [],
        pickerActive: Bool = false,
        selectorDead: Bool = false
    ) {
        self.packageID = packageID
        self.baselineCSS = baselineCSS
        self.draftCSS = draftCSS ?? baselineCSS
        self.selectedSelector = selectedSelector
        self.candidateChoices = candidateChoices
        self.pickerActive = pickerActive
        self.selectorDead = selectorDead
    }

    public var isDirty: Bool { draftCSS != baselineCSS }
}

/// Per-tab session overrides for dead selectors (cleared on navigation commit).
public struct BoostSessionApplyMap: Equatable, Sendable {
    public var overrides: [UUID: String]

    public init(overrides: [UUID: String] = [:]) {
        self.overrides = overrides
    }

    public mutating func clear() {
        overrides.removeAll()
    }

    public mutating func setSessionSelector(storedSelectorKey: UUID, css: String) {
        overrides[storedSelectorKey] = css
    }

    public var healedPackageIDs: Set<UUID> {
        Set(overrides.keys)
    }

    public func isHealed(packageID: UUID) -> Bool {
        overrides[packageID] != nil
    }
}

public enum BoostEditorLiveApply {
    /// CSS sent to the page during editing (draft), separate from saved package until save.
    public static func liveStylesheet(
        installedEntries: [BoostRuntimeEntry],
        editingPackageID: UUID,
        draftCSS: String,
        sessionMap: BoostSessionApplyMap
    ) -> String {
        var parts: [String] = []
        for entry in installedEntries where entry.packageID != editingPackageID {
            if let css = entry.css, !css.isEmpty {
                parts.append(css)
            }
        }
        parts.append(draftCSS)
        for (_, css) in sessionMap.overrides {
            parts.append("/* session-apply */\n\(css)")
        }
        return parts.joined(separator: "\n")
    }
}

public enum BoostEditorSave {
    public static func applySave(
        package: BoostPackage,
        draftCSS: String,
        now: Date = Date()
    ) -> BoostPackage? {
        var updated = package
        guard updated.styleBoost != nil else { return nil }
        let errors = BoostSecurity.validateCSS(draftCSS, allowInStyle: true)
        if !errors.isEmpty { return nil }
        let previous = updated.styleBoost?.css ?? ""
        guard draftCSS != previous else { return updated }
        updated.styleBoost?.css = draftCSS
        updated.manifest.updatedAt = now
        updated.manifest.version += 1
        return updated
    }
}
