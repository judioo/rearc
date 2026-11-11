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

    /// CSS's own preprocessing: CR LF, CR and form feed become LF. Blink consumes CR LF as
    /// one unit after an escape where a naive tokenizer takes one scalar, so the two could
    /// disagree about where a string ends; normalised text is checked and is what the engine
    /// receives (RC-0.1.0-602 N-02).
    public static func normalizedCSS(_ css: String) -> String {
        var out = String.UnicodeScalarView()
        var previousCR = false
        for scalar in css.unicodeScalars {
            switch scalar {
            case "\r": out.append("\n"); previousCR = true; continue
            case "\n": if !previousCR { out.append("\n") }
            case "\u{0C}": out.append("\n")
            default: out.append(scalar)
            }
            previousCR = false
        }
        return String(out)
    }

    public static func validateCSS(_ css: String, allowInStyle: Bool) -> [BoostSecurityError] {
        let css = normalizedCSS(css)
        var errors: [BoostSecurityError] = []
        if css.count > maxCSSCharacters { errors.append(.cssTooLarge) }
        if css.lowercased().contains("</style>") { errors.append(.styleBreakoutInCSS) }
        // Style and script CSS alike: the page could otherwise send its data out one
        // attribute selector at a time (security RC-0.1.0-544 N-02).
        if BoostCSSResources.loadsResource(css) { errors.append(.remoteImportInCSS) }
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

/// Finds CSS that can make the page fetch something. Boost CSS may name `data:` URLs and
/// `#fragment` references only. The text is tokenized the way CSS reads it: comments
/// outside strings are dropped and escapes are decoded first, so `u\72l(`, `\2f\2f` and
/// comment tricks are seen as what they are. Refused:
/// - any `@import`;
/// - `url(…)` and `src(…)` naming anything other than `data:` or `#…` (or not a plain string);
/// - inside `image-set()`, `cross-fade()`, `image()` and their prefixed forms, any string
///   other than `data:` or `#…`, and any `var()`, `env()` or `attr()` (values the scanner cannot see);
/// - anywhere, a string that reads as an absolute or scheme-relative web URL, so a custom
///   property cannot carry one into `image-set(var(--x))`.
public enum BoostCSSResources {
    enum Token: Equatable {
        case atKeyword(String)
        case function(String)
        case url(String)
        case string(String)
        case open
        case close
        case other
    }

    public static func loadsResource(_ css: String) -> Bool {
        let tokens = tokenize(css)
        var imageDepth: [Int] = []
        var depth = 0
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            switch token {
            case .atKeyword(let name):
                if name == "import" { return true }
            case .url(let value):
                if !isLocal(value) { return true }
            case .function(let name):
                depth += 1
                if name == "url" || name == "src" {
                    guard index + 1 < tokens.count, case .string(let value) = tokens[index + 1], isLocal(value) else { return true }
                } else if imageFunctions.contains(name) {
                    imageDepth.append(depth)
                } else if !imageDepth.isEmpty, opaqueFunctions.contains(name) {
                    return true
                }
            case .open:
                depth += 1
            case .close:
                if imageDepth.last == depth { imageDepth.removeLast() }
                depth = max(0, depth - 1)
            case .string(let value):
                if !imageDepth.isEmpty, !isLocal(value) { return true }
                if looksLikeWebURL(value) { return true }
            case .other:
                break
            }
            index += 1
        }
        return false
    }

    private static let imageFunctions: Set<String> = [
        "image-set", "-webkit-image-set", "cross-fade", "-webkit-cross-fade", "image", "-webkit-image",
    ]
    private static let opaqueFunctions: Set<String> = ["var", "env", "attr"]

    /// What the URL parser keeps: no surrounding spaces or controls, no tabs or newlines.
    private static func normalizedURL(_ value: String) -> String {
        let trimmed = value.unicodeScalars.drop { $0.value <= 0x20 }.reversed().drop { $0.value <= 0x20 }.reversed()
        return String(String.UnicodeScalarView(trimmed.filter { $0 != "\t" && $0 != "\n" && $0 != "\r" })).lowercased()
    }

    static func isLocal(_ value: String) -> Bool {
        let url = normalizedURL(value)
        return url.isEmpty || url.hasPrefix("data:") || url.hasPrefix("#")
    }

    /// `//host`, `\\host` and the http-like schemes (which the URL parser accepts without
    /// slashes, as in `https:evil.example`).
    static func looksLikeWebURL(_ value: String) -> Bool {
        let url = normalizedURL(value)
        if ["//", "\\\\", "/\\", "\\/"].contains(where: url.hasPrefix) { return true }
        return ["http:", "https:", "ws:", "wss:", "ftp:", "file:"].contains(where: url.hasPrefix)
    }

    static func tokenize(_ css: String) -> [Token] {
        let scalars = Array(css.unicodeScalars)
        var tokens: [Token] = []
        var i = 0
        func peek(_ offset: Int = 0) -> Unicode.Scalar? { i + offset < scalars.count ? scalars[i + offset] : nil }
        func isHex(_ c: Unicode.Scalar) -> Bool { ("0"..."9").contains(c) || ("a"..."f").contains(c) || ("A"..."F").contains(c) }
        func isNewline(_ c: Unicode.Scalar) -> Bool { c == "\n" || c == "\r" || c == "\u{0C}" }
        func isWhitespace(_ c: Unicode.Scalar) -> Bool { c == " " || c == "\t" || isNewline(c) }
        func isNameScalar(_ c: Unicode.Scalar) -> Bool {
            c.properties.isAlphabetic || ("0"..."9").contains(c) || c == "-" || c == "_" || c.value >= 0x80
        }
        func startsEscape(_ offset: Int = 0) -> Bool {
            peek(offset) == "\\" && peek(offset + 1).map { !isNewline($0) } == true
        }
        /// After a backslash: the escaped scalar (hex escapes take up to six digits and one space).
        func consumeEscape() -> Unicode.Scalar {
            guard let c = peek() else { return "\u{FFFD}" }
            if isHex(c) {
                var hex = ""
                while hex.count < 6, let d = peek(), isHex(d) { hex.unicodeScalars.append(d); i += 1 }
                if let w = peek(), isWhitespace(w) { i += 1 }
                let value = UInt32(hex, radix: 16) ?? 0xFFFD
                return value == 0 ? "\u{FFFD}" : Unicode.Scalar(value) ?? "\u{FFFD}"
            }
            i += 1
            return c
        }
        func consumeName() -> String {
            var name = String.UnicodeScalarView()
            while let c = peek() {
                if startsEscape() { i += 1; name.append(consumeEscape()) }
                else if isNameScalar(c) { name.append(c); i += 1 }
                else { break }
            }
            return String(name).lowercased()
        }
        func consumeString(_ quote: Unicode.Scalar) -> String {
            var value = String.UnicodeScalarView()
            while let c = peek() {
                i += 1
                if c == quote { break }
                if isNewline(c) { break }
                if c == "\\" {
                    guard let next = peek() else { break }
                    if isNewline(next) { i += 1; continue }
                    value.append(consumeEscape())
                } else {
                    value.append(c)
                }
            }
            return String(value)
        }
        while i < scalars.count {
            let c = scalars[i]
            if c == "/", peek(1) == "*" {
                i += 2
                while i < scalars.count, !(scalars[i] == "*" && peek(1) == "/") { i += 1 }
                i = min(scalars.count, i + 2)
            } else if c == "\"" || c == "'" {
                i += 1
                tokens.append(.string(consumeString(c)))
            } else if c == "@" {
                i += 1
                tokens.append(.atKeyword(consumeName()))
            } else if isNameScalar(c) || startsEscape() {
                let name = consumeName()
                if name.isEmpty { i += 1; tokens.append(.other); continue }
                guard peek() == "(" else { tokens.append(.other); continue }
                i += 1
                if name == "url" {
                    var j = i
                    while j < scalars.count, isWhitespace(scalars[j]) { j += 1 }
                    if j < scalars.count, scalars[j] == "\"" || scalars[j] == "'" {
                        tokens.append(.function(name))
                        continue
                    }
                    var value = String.UnicodeScalarView()
                    while let u = peek(), u != ")" {
                        if startsEscape() { i += 1; value.append(consumeEscape()) } else { value.append(u); i += 1 }
                    }
                    i += 1
                    tokens.append(.url(String(value)))
                } else {
                    tokens.append(.function(name))
                }
            } else if c == "(" || c == "[" || c == "{" {
                i += 1
                tokens.append(.open)
            } else if c == ")" || c == "]" || c == "}" {
                i += 1
                tokens.append(.close)
            } else {
                i += 1
                tokens.append(.other)
            }
        }
        return tokens
    }
}
