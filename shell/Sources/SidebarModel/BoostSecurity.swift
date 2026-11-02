import Foundation

public enum BoostSecurityError: Equatable, Sendable {
    case cssTooLarge
    case jsTooLarge
    case tabCssBudgetExceeded
    case remoteImportInCSS
    case remoteScriptSourceInJS
    case styleBreakoutInCSS
    case scriptInStylePackage
    case emptyScriptPayload
    case invalidHostRule
    case tooManyHostRules
    case invalidTitle
    case invalidInterchangeFormat
}

public enum BoostSecurity {
    public static let maxCSSCharacters = 256_000
    public static let maxJSCharacters = 256_000
    public static let maxTabCSSBytes = 1_048_576
    public static let maxHostRules = 20
    public static let maxTitleScalars = 80

    private static let remoteCSSImport = try? NSRegularExpression(
        pattern: #"@import\s+(?:url\s*\(\s*)?['"]?(?:https?://|//|/)"#,
        options: [.caseInsensitive]
    )
    private static let remoteURLInCSS = try? NSRegularExpression(
        pattern: #"url\s*\(\s*['"]?(?:https?://|//)"#,
        options: [.caseInsensitive]
    )
    private static let remoteScriptSrc = try? NSRegularExpression(
        pattern: #"(?:src|href)\s*=\s*['"]?(?:https?://|//)"#,
        options: [.caseInsensitive]
    )

    public static func validatePackage(_ package: BoostPackage) -> [BoostSecurityError] {
        var errors: [BoostSecurityError] = []
        if package.manifest.name.unicodeScalars.count < 1
            || package.manifest.name.unicodeScalars.count > maxTitleScalars {
            errors.append(.invalidTitle)
        }
        if package.manifest.hostScope.count > maxHostRules {
            errors.append(.tooManyHostRules)
        }
        for rule in package.manifest.hostScope where !BoostScopeMatcher.validateRule(rule) {
            errors.append(.invalidHostRule)
        }
        if let css = package.styleBoost?.css {
            errors.append(contentsOf: validateCSS(css, allowInStyle: true))
        }
        if let script = package.scriptBoost {
            if let css = script.css {
                errors.append(contentsOf: validateCSS(css, allowInStyle: false))
            }
            if let js = script.js {
                errors.append(contentsOf: validateJS(js))
            } else if script.css == nil {
                errors.append(.emptyScriptPayload)
            }
            if package.styleBoost != nil {
                errors.append(.scriptInStylePackage)
            }
        }
        return errors
    }

    public static func validateCSS(_ css: String, allowInStyle: Bool) -> [BoostSecurityError] {
        var errors: [BoostSecurityError] = []
        if css.count > maxCSSCharacters { errors.append(.cssTooLarge) }
        if css.lowercased().contains("</style>") { errors.append(.styleBreakoutInCSS) }
        if let re = remoteCSSImport,
           re.firstMatch(in: css, range: NSRange(css.startIndex..., in: css)) != nil {
            errors.append(.remoteImportInCSS)
        }
        if allowInStyle, let re = remoteURLInCSS,
           re.firstMatch(in: css, range: NSRange(css.startIndex..., in: css)) != nil {
            errors.append(.remoteImportInCSS)
        }
        return errors
    }

    public static func validateJS(_ js: String) -> [BoostSecurityError] {
        var errors: [BoostSecurityError] = []
        if js.count > maxJSCharacters { errors.append(.jsTooLarge) }
        if let re = remoteScriptSrc,
           re.firstMatch(in: js, range: NSRange(js.startIndex..., in: js)) != nil {
            errors.append(.remoteScriptSourceInJS)
        }
        return errors
    }

    public static func tabCSSBudgetOK(_ cssChunks: [String]) -> Bool {
        let total = cssChunks.reduce(0) { $0 + $1.utf8.count }
        return total <= maxTabCSSBytes
    }
}
