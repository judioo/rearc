import Foundation

/// One assistant the command bar can open (Max › Assistants in the Command
/// Bar, MAX.md §4). It is a shortcut to that company's own site: ReArc
/// opens the site with what was typed in its address, or, where the site
/// takes no prompt in its address, opens it and puts the text on the
/// clipboard. ReArc runs no AI and never fills the site's box by script.
public struct CommandBarAssistant: Identifiable, Hashable, Codable, Sendable {
    /// How the typed text reaches the site.
    public enum Delivery: String, Codable, Sendable {
        /// `template`'s `%s` takes the text.
        case url
        /// `template` is the site's home page; the text goes on the clipboard.
        case clipboard
    }

    public var id: String
    public var name: String
    /// Typed in the command bar, then Tab.
    public var keyword: String
    public var template: String
    public var delivery: Delivery
    public var placeholder: String
    public var tint: SpaceTheme
    /// Where the prompt address was checked (MAX.md lists them); empty for the person's own.
    public var source: String
    public var isCustom: Bool

    public init(id: String, name: String, keyword: String, template: String, delivery: Delivery = .url,
                placeholder: String = "Send a Message…", tint: SpaceTheme, source: String = "", isCustom: Bool = false) {
        self.id = id
        self.name = name
        self.keyword = keyword
        self.template = template
        self.delivery = delivery
        self.placeholder = placeholder
        self.tint = tint
        self.source = source
        self.isCustom = isCustom
    }

    /// The row's note: what happens when it opens.
    public var note: String {
        switch delivery {
        case .url: return "Opens \(name) with what you typed."
        case .clipboard: return "Opens \(name); what you typed is copied, ready to paste."
        }
    }

    /// What opening it with `text` does.
    public func action(for text: String) -> CommandBarAssistants.Action? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch delivery {
        case .url:
            guard let url = CommandBarAssistants.fill(template, with: trimmed) else { return nil }
            return .open(url)
        case .clipboard:
            guard let url = URL(string: template) else { return nil }
            return trimmed.isEmpty ? .open(url) : .openCopying(url, text: trimmed)
        }
    }
}

/// The assistants, which ones are on, and the person's own. The one place
/// their UserDefaults keys are read and written.
public enum CommandBarAssistants {
    public static let enabledKey = "rearc.assistants.enabled"
    public static let customKey = "rearc.assistants.custom"
    public static let maximumCustom = 20

    public enum Action: Equatable, Sendable {
        case open(URL)
        case openCopying(URL, text: String)
    }

    private static func rgb(_ hex: UInt32) -> SpaceTheme {
        SpaceTheme(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }

    /// Checked 2026-11-12 (MAX.md §4 has the links). A site whose prompt
    /// parameter could not be confirmed, or is reported to have stopped
    /// filling the box, opens with the text copied instead.
    public static let builtIn: [CommandBarAssistant] = [
        CommandBarAssistant(id: "chatgpt", name: "ChatGPT", keyword: "chatgpt", template: "https://chatgpt.com/?q=%s",
                            tint: rgb(0x10A37F), source: "Tenable advisory TRA-2025-22 on chatgpt.com's ?q= (fills the box)"),
        CommandBarAssistant(id: "claude", name: "Claude", keyword: "claude", template: "https://claude.ai/new?q=%s",
                            tint: rgb(0xD97757), source: "Anthropic support 14729294: q prefills the prompt (claude://claude.ai/new?q=, the same path)"),
        CommandBarAssistant(id: "perplexity", name: "Perplexity", keyword: "perplexity", template: "https://www.perplexity.ai/search?q=%s",
                            placeholder: "Ask Anything…", tint: rgb(0x20808D), source: "Public default-search-engine guides (SSW rules)"),
        CommandBarAssistant(id: "grok", name: "Grok", keyword: "grok", template: "https://grok.com/?q=%s",
                            tint: rgb(0x1A1A1A), source: "Public reports of grok.com/?q= prefilling (r/grok)"),
        CommandBarAssistant(id: "lechat", name: "Le Chat", keyword: "lechat", template: "https://chat.mistral.ai/chat?q=%s",
                            tint: rgb(0xFA520F), source: "Public launcher docs (R searcher::ask_mistral)"),
        CommandBarAssistant(id: "huggingchat", name: "HuggingChat", keyword: "huggingchat", template: "https://huggingface.co/chat/?prompt=%s",
                            tint: rgb(0xFFB000), source: "huggingface/chat-ui source: the prompt parameter prefills the input"),
        CommandBarAssistant(id: "gemini", name: "Gemini", keyword: "gemini", template: "https://gemini.google.com/app", delivery: .clipboard,
                            tint: rgb(0x4285F4), source: "No documented prompt parameter; extensions fill ?q= by script"),
        CommandBarAssistant(id: "copilot", name: "Copilot", keyword: "copilot", template: "https://copilot.microsoft.com/", delivery: .clipboard,
                            tint: rgb(0x0078D4), source: "Microsoft Q&A 2025-11-07: ?q= no longer fills the box"),
        CommandBarAssistant(id: "deepseek", name: "DeepSeek", keyword: "deepseek", template: "https://chat.deepseek.com/", delivery: .clipboard,
                            tint: rgb(0x4D6BFE), source: "No prompt parameter documented or reported"),
        CommandBarAssistant(id: "kimi", name: "Kimi", keyword: "kimi", template: "https://www.kimi.com/", delivery: .clipboard,
                            tint: rgb(0x111111), source: "Kimi help centre documents none"),
    ]

    // MARK: Switches

    /// Ids switched on, built-in or custom. None until the person picks.
    public static func enabledIDs(in defaults: UserDefaults) -> Set<String> {
        Set(defaults.stringArray(forKey: enabledKey) ?? [])
    }

    public static func setEnabled(_ id: String, _ on: Bool, in defaults: UserDefaults) {
        var ids = enabledIDs(in: defaults)
        if on { ids.insert(id) } else { ids.remove(id) }
        defaults.set(ids.sorted(), forKey: enabledKey)
    }

    /// Turn On All: every built-in assistant (the person's own were switched on when added).
    public static func enableAllBuiltIn(in defaults: UserDefaults) {
        defaults.set(enabledIDs(in: defaults).union(builtIn.map(\.id)).sorted(), forKey: enabledKey)
    }

    /// Every assistant the tab lists: the built-in ones, then the person's own.
    public static func all(in defaults: UserDefaults) -> [CommandBarAssistant] {
        builtIn + custom(in: defaults)
    }

    /// The assistants switched on, in the tab's order.
    public static func enabled(in defaults: UserDefaults) -> [CommandBarAssistant] {
        let ids = enabledIDs(in: defaults)
        return all(in: defaults).filter { ids.contains($0.id) }
    }

    /// The command bar's side of the registry: one shortcut per assistant
    /// switched on. `template` has `%s` for the typed text; without one it
    /// is the site's home page, to open while the text goes on the
    /// clipboard (`CommandBarAssistant.action(for:)` does both).
    public static func shortcuts(in defaults: UserDefaults)
        -> [(keyword: String, name: String, template: String, placeholder: String, tint: SpaceTheme)] {
        enabled(in: defaults).map { ($0.keyword, $0.name, $0.template, $0.placeholder, $0.tint) }
    }

    /// The enabled assistant with this keyword (case-insensitive).
    public static func assistant(keyword: String, in defaults: UserDefaults) -> CommandBarAssistant? {
        let folded = keyword.lowercased()
        return enabled(in: defaults).first { $0.keyword == folded }
    }

    // MARK: The person's own

    public static func custom(in defaults: UserDefaults) -> [CommandBarAssistant] {
        guard let data = defaults.data(forKey: customKey),
              let saved = try? JSONDecoder().decode([CommandBarAssistant].self, from: data) else { return [] }
        // Saved data is checked again: a hand-edited plist gets no unchecked template.
        return saved.prefix(maximumCustom).filter { (try? validate(name: $0.name, keyword: $0.keyword, template: $0.template, existing: [])) != nil }
            .map { var copy = $0; copy.isCustom = true; copy.delivery = .url; return copy }
    }

    public enum ValidationError: Error, Equatable, Sendable {
        case name, keyword, keywordTaken, template, tooMany

        public var message: String {
            switch self {
            case .name: return "Give it a name of up to 32 characters."
            case .keyword: return "Use 2–24 lowercase letters, digits or hyphens for the keyword."
            case .keywordTaken: return "Another assistant uses that keyword."
            case .template: return "Use an https address with %s once, where your text goes."
            case .tooMany: return "You can add up to \(CommandBarAssistants.maximumCustom)."
            }
        }
    }

    /// Add Your Own…: a name, a keyword and an https template with one `%s`.
    public static func validate(name: String, keyword: String, template: String, existing: [CommandBarAssistant]) throws -> CommandBarAssistant {
        let name = TidyText.singleLine(name)
        guard !name.isEmpty, name.count <= 32 else { throw ValidationError.name }
        let keyword = keyword.trimmingCharacters(in: .whitespaces).lowercased()
        guard (2...24).contains(keyword.count), keyword.range(of: #"^[a-z0-9][a-z0-9-]*$"#, options: .regularExpression) != nil else {
            throw ValidationError.keyword
        }
        guard !(builtIn + existing).contains(where: { $0.keyword == keyword }) else { throw ValidationError.keywordTaken }
        let template = template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidTemplate(template) else { throw ValidationError.template }
        return CommandBarAssistant(id: "custom-\(keyword)", name: name, keyword: keyword, template: template,
                                   tint: SpaceTheme(red: 0.55, green: 0.45, blue: 0.85), isCustom: true)
    }

    /// https, a host, no user or password, exactly one `%s`, at most 2,048 characters.
    public static func isValidTemplate(_ template: String) -> Bool {
        guard template.count <= 2048, template.components(separatedBy: "%s").count == 2,
              let parts = URLComponents(string: template.replacingOccurrences(of: "%s", with: "q")),
              parts.scheme?.lowercased() == "https", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil else { return false }
        return true
    }

    public static func add(_ assistant: CommandBarAssistant, in defaults: UserDefaults) throws {
        var saved = custom(in: defaults)
        guard saved.count < maximumCustom else { throw ValidationError.tooMany }
        saved.append(assistant)
        defaults.set(try JSONEncoder().encode(saved), forKey: customKey)
        setEnabled(assistant.id, true, in: defaults)
    }

    public static func remove(id: String, in defaults: UserDefaults) {
        let saved = custom(in: defaults).filter { $0.id != id }
        defaults.set(try? JSONEncoder().encode(saved), forKey: customKey)
        setEnabled(id, false, in: defaults)
    }

    /// `%s` replaced by the percent-encoded text (at most 4,000 characters of it).
    static func fill(_ template: String, with text: String) -> URL? {
        guard isValidTemplate(template) else { return nil }
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#/;%")
        let bounded = String(TidyText.singleLine(text).prefix(4000))
        guard let encoded = bounded.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: template.replacingOccurrences(of: "%s", with: encoded))
    }
}
