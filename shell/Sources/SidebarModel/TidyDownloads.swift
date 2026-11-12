import Foundation

/// Max › Tidy Downloads (MAX.md §3): a finished download gets a clearer
/// name, by rules, from the page it came from, its host and its own name.
/// File names here come from web pages and servers, so they are treated as
/// hostile: no path separators, no leading dot, no reserved or invisible
/// characters, a bounded length, and the extension is the file's own and
/// never changes.
public enum TidyDownloads {
    /// Characters in the name before the extension.
    public static let maximumStemLength = 80
    /// Bytes in the whole name (APFS allows 255).
    static let maximumNameBytes = 240

    /// Files left as they are: bundles and anything that runs, installs or
    /// mounts. A renamed installer or disk image is a surprise, and some
    /// are open in the system (being mounted, verified) after they finish.
    public static let untouchedExtensions: Set<String> = [
        "app", "command", "tool", "sh", "zsh", "bash", "csh", "ksh", "fish", "pkg", "mpkg", "dmg", "iso",
        "sparseimage", "sparsebundle", "img", "toast", "cdr", "exe", "msi", "bat", "cmd", "com", "jar", "terminal",
        "workflow", "scpt", "scptd", "applescript", "action", "prefpane", "kext", "plugin", "bundle", "framework",
        "webloc", "inetloc", "fileloc", "url", "dylib", "so", "py", "pl", "rb", "php", "crdownload", "download",
        "part", "partial", "lnk", "desktop", "appimage", "deb", "rpm", "apk", "ipa", "xpi", "crx", "mobileconfig",
    ]

    /// Names that say nothing about the file.
    static let genericStems: Set<String> = [
        "download", "downloads", "file", "files", "document", "untitled", "export", "image", "img", "attachment",
        "output", "data", "content", "view", "get", "index", "blob", "temp", "tmp", "unknown", "noname", "default",
    ]

    /// Where a download came from, as the shell knew it when it finished.
    public struct Origin: Equatable, Sendable {
        public var pageTitle: String?
        public var pageHost: String?

        public init(pageTitle: String? = nil, pageHost: String? = nil) {
            self.pageTitle = pageTitle
            self.pageHost = pageHost
        }
    }

    /// The extension a rename keeps, lowercased; nil when the name has none.
    public static func fileExtension(of name: String) -> String? {
        let ext = (name as NSString).pathExtension
        return ext.isEmpty ? nil : ext.lowercased()
    }

    /// Never renamed: a hidden file, one without an extension, or one whose
    /// extension runs, installs or mounts.
    public static func isUntouched(_ name: String) -> Bool {
        guard !name.hasPrefix("."), let ext = fileExtension(of: name) else { return true }
        return untouchedExtensions.contains(ext)
    }

    /// The name says nothing: generic words, a hash, an id, or mostly digits.
    public static func isUninformative(_ stem: String) -> Bool {
        let words = readableWords(stem)
        let joined = words.joined(separator: " ").lowercased()
        if words.isEmpty || genericStems.contains(joined) { return true }
        let letters = joined.unicodeScalars.filter(CharacterSet.letters.contains).count
        let digits = joined.unicodeScalars.filter(CharacterSet.decimalDigits.contains).count
        if letters < 3 || digits > letters { return true }
        // A UUID or a hash: long hex runs.
        if stem.range(of: #"[0-9a-fA-F]{12,}"#, options: .regularExpression) != nil, words.count <= 2 { return true }
        // "IMG_2041", "DSC0034", "Screenshot 2026…" keep their words; "file-3" does not.
        if words.count <= 2, let first = words.first?.lowercased(), genericStems.contains(first) { return true }
        return false
    }

    /// The stem's words: separators (_ - + . %20) as spaces, case kept.
    static func readableWords(_ stem: String) -> [String] {
        var text = stem.removingPercentEncoding ?? stem
        text = TidyText.singleLine(text)
        text = text.replacingOccurrences(of: #"[_+]+"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?<=\D)-|-(?=\D)"#, with: " ", options: .regularExpression)
        // Copy counters and Chromium's "(1)".
        text = text.replacingOccurrences(of: #"\s*\(\d+\)\s*$"#, with: "", options: .regularExpression)
        return text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// A name's stem made safe to use: no separators, reserved or invisible
    /// characters, no dots except between digits ("v1.2"), no leading or
    /// trailing dot or space, bounded. Empty when nothing is left.
    public static func safeStem(_ text: String) -> String {
        var text = TidyText.singleLine(text)
        text = text.replacingOccurrences(of: #"[/\\:<>"|?*\u{0}]"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?<!\d)\.|\.(?!\d)"#, with: " ", options: .regularExpression)
        text = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: ". -").union(.whitespaces))
        text = TidyText.truncated(text, to: maximumStemLength)
        while text.utf8.count > maximumNameBytes - 16 { text.removeLast() }
        return text.trimmingCharacters(in: CharacterSet(charactersIn: ". -").union(.whitespaces))
    }

    /// The clearer name for `fileName`, with the same extension, or nil to
    /// leave it: the file is one never renamed, or no better name is found.
    /// An informative name is only made readable ("annual_report-2026.pdf"
    /// → "annual report 2026.pdf"); an uninformative one takes the page's
    /// tidy title, else its site's name, keeping any number it had.
    public static func tidyName(for fileName: String, origin: Origin) -> String? {
        guard !isUntouched(fileName), let ext = fileExtension(of: fileName) else { return nil }
        let originalStem = (fileName as NSString).deletingPathExtension
        var stem: String
        if !isUninformative(originalStem) {
            stem = readableWords(originalStem).joined(separator: " ")
        } else {
            let host = origin.pageHost?.lowercased() ?? ""
            let page = origin.pageTitle.flatMap { title in TidyTabTitles.tidyTitle(title, host: host) ?? TidyText.singleLine(title) }
            let site = TidyTabTitles.brand(for: host) ?? siteLabel(host)
            guard let base = page.flatMap({ $0.isEmpty ? nil : $0 }) ?? site else { return nil }
            stem = base
            // Keep what distinguished the file ("invoice-4471" → "Acme Billing 4471").
            if let number = originalStem.range(of: #"\d{2,}"#, options: .regularExpression).map({ String(originalStem[$0]) }),
               number.count <= 10, !stem.contains(number) {
                stem += " \(number)"
            }
        }
        stem = safeStem(stem)
        guard !stem.isEmpty else { return nil }
        let name = "\(stem).\(ext)"
        return name == fileName ? nil : name
    }

    /// "nytimes.com" → "Nytimes"; nil for no host or an address.
    static func siteLabel(_ host: String) -> String? {
        guard !host.isEmpty, host.range(of: #"^[\d.:\[\]]+$"#, options: .regularExpression) == nil else { return nil }
        let label = TidyTabTitles.label(for: host)
        return label.isEmpty ? nil : label.prefix(1).uppercased() + label.dropFirst()
    }

    /// `name` in `directory`, or the first of "stem 2.ext", "stem 3.ext", …
    /// that does not exist. Never one that does: the rename itself also
    /// refuses to replace (`RENAME_EXCL`), in case one appears meanwhile.
    public static func freeName(_ name: String, in directory: URL, exists: (URL) -> Bool) -> URL {
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = directory.appendingPathComponent(name)
        var counter = 2
        while exists(candidate), counter < 10_000 {
            candidate = directory.appendingPathComponent(ext.isEmpty ? "\(stem) \(counter)" : "\(stem) \(counter).\(ext)")
            counter += 1
        }
        return candidate
    }
}
