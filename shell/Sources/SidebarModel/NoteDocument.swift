import Foundation

/// A note's paragraph kinds (Arc's rich text editor format menu:
/// `HeaderText`, `BodyText`, `OrderedList`, `UnorderedList`, plus
/// checklists and quotes; EASEL-CAPTURE §3).
public enum NoteBlockStyle: Equatable, Hashable, Codable, Sendable {
    case paragraph
    case heading(Int)
    case bullet
    case numbered
    case checklist(checked: Bool)
    case quote

    public var isListItem: Bool {
        switch self {
        case .bullet, .numbered, .checklist: return true
        default: return false
        }
    }

    /// The same kind with the check cleared (a new checklist row).
    public var continued: NoteBlockStyle {
        if case .checklist = self { return .checklist(checked: false) }
        if case .heading = self { return .paragraph }
        return self
    }

    public var headingLevel: Int? {
        if case .heading(let level) = self { return level }
        return nil
    }

    enum CodingKeys: String, CodingKey { case kind, level, checked }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "heading": self = .heading(min(max(try c.decodeIfPresent(Int.self, forKey: .level) ?? 1, 1), 3))
        case "bullet": self = .bullet
        case "numbered": self = .numbered
        case "checklist": self = .checklist(checked: try c.decodeIfPresent(Bool.self, forKey: .checked) ?? false)
        case "quote": self = .quote
        default: self = .paragraph
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .paragraph: try c.encode("paragraph", forKey: .kind)
        case .heading(let level):
            try c.encode("heading", forKey: .kind)
            try c.encode(level, forKey: .level)
        case .bullet: try c.encode("bullet", forKey: .kind)
        case .numbered: try c.encode("numbered", forKey: .kind)
        case .checklist(let checked):
            try c.encode("checklist", forKey: .kind)
            try c.encode(checked, forKey: .checked)
        case .quote: try c.encode("quote", forKey: .kind)
        }
    }
}

/// A span of text with one set of inline styles.
public struct NoteRun: Equatable, Codable, Sendable {
    public var text: String
    public var bold: Bool
    public var italic: Bool
    public var underline: Bool
    public var strikethrough: Bool
    public var code: Bool
    public var link: URL?

    public init(_ text: String, bold: Bool = false, italic: Bool = false, underline: Bool = false,
                strikethrough: Bool = false, code: Bool = false, link: URL? = nil) {
        self.text = text
        self.bold = bold
        self.italic = italic
        self.underline = underline
        self.strikethrough = strikethrough
        self.code = code
        self.link = link
    }

    enum CodingKeys: String, CodingKey { case text, bold, italic, underline, strikethrough, code, link }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decode(String.self, forKey: .text)
        bold = try c.decodeIfPresent(Bool.self, forKey: .bold) ?? false
        italic = try c.decodeIfPresent(Bool.self, forKey: .italic) ?? false
        underline = try c.decodeIfPresent(Bool.self, forKey: .underline) ?? false
        strikethrough = try c.decodeIfPresent(Bool.self, forKey: .strikethrough) ?? false
        code = try c.decodeIfPresent(Bool.self, forKey: .code) ?? false
        link = try c.decodeIfPresent(URL.self, forKey: .link)
    }

    /// Only the styles that are set, to keep notes small.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(text, forKey: .text)
        if bold { try c.encode(true, forKey: .bold) }
        if italic { try c.encode(true, forKey: .italic) }
        if underline { try c.encode(true, forKey: .underline) }
        if strikethrough { try c.encode(true, forKey: .strikethrough) }
        if code { try c.encode(true, forKey: .code) }
        try c.encodeIfPresent(link, forKey: .link)
    }

    func sameStyle(as other: NoteRun) -> Bool {
        bold == other.bold && italic == other.italic && underline == other.underline
            && strikethrough == other.strikethrough && code == other.code && link == other.link
    }
}

public struct NoteBlock: Equatable, Codable, Sendable {
    public var style: NoteBlockStyle
    public var runs: [NoteRun]

    public init(_ style: NoteBlockStyle = .paragraph, runs: [NoteRun] = []) {
        self.style = style
        self.runs = NoteBlock.merged(runs)
    }

    public init(_ style: NoteBlockStyle = .paragraph, text: String) {
        self.init(style, runs: text.isEmpty ? [] : [NoteRun(text)])
    }

    public var text: String { runs.map(\.text).joined() }

    /// Neighbouring runs with the same styles become one; empty runs go.
    static func merged(_ runs: [NoteRun]) -> [NoteRun] {
        var out: [NoteRun] = []
        for run in runs where !run.text.isEmpty {
            if let last = out.last, last.sameStyle(as: run) {
                out[out.count - 1].text += run.text
            } else {
                out.append(run)
            }
        }
        return out
    }
}

/// A note's body: paragraphs, headings, lists, checklists and quotes with
/// bold, italic, underline, strikethrough, code and links.
public struct NoteContent: Equatable, Codable, Sendable {
    public var blocks: [NoteBlock]

    public init(blocks: [NoteBlock] = [NoteBlock()]) {
        self.blocks = blocks.isEmpty ? [NoteBlock()] : blocks
    }

    public var plainText: String { blocks.map(\.text).joined(separator: "\n") }

    public var isEmpty: Bool { blocks.allSatisfy { $0.text.isEmpty } }

    /// A note made before wave 28: one easel text block whose runs carry
    /// bold, italic, underline and heading levels, lines split by newlines.
    public init(legacyRuns runs: [EaselRichTextRun]) {
        var blocks: [NoteBlock] = [NoteBlock()]
        for run in runs {
            let lines = run.text.components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                if index > 0 { blocks.append(NoteBlock()) }
                if let level = run.headingLevel, !line.isEmpty { blocks[blocks.count - 1].style = .heading(min(max(level, 1), 3)) }
                blocks[blocks.count - 1].runs = NoteBlock.merged(blocks[blocks.count - 1].runs + [
                    NoteRun(line, bold: run.isBold, italic: run.isItalic, underline: run.isUnderline),
                ])
            }
        }
        self.init(blocks: blocks)
    }

    /// The list marker shown before each block ("•", "1.", "☐"/"☑"), or nil.
    /// Numbering restarts after any block that is not a numbered item.
    public func markers() -> [String?] {
        var number = 0
        return blocks.map { block in
            switch block.style {
            case .numbered:
                number += 1
                return "\(number)."
            case .bullet:
                number = 0
                return "•"
            case .checklist(let checked):
                number = 0
                return checked ? "☑" : "☐"
            default:
                number = 0
                return nil
            }
        }
    }

    public mutating func toggleChecklist(at index: Int) {
        guard blocks.indices.contains(index), case .checklist(let checked) = blocks[index].style else { return }
        blocks[index].style = .checklist(checked: !checked)
    }

    /// The format menu: `style` on the blocks, or back to a paragraph when
    /// they all have it already.
    public mutating func setStyle(_ style: NoteBlockStyle, blocks indices: [Int]) {
        let valid = indices.filter { blocks.indices.contains($0) }
        guard !valid.isEmpty else { return }
        let sameKind: (NoteBlockStyle) -> Bool = { current in
            switch (current, style) {
            case (.checklist, .checklist): return true
            default: return current == style
            }
        }
        let allSet = valid.allSatisfy { sameKind(blocks[$0].style) }
        for index in valid { blocks[index].style = allSet ? .paragraph : style }
    }

    // MARK: Markdown

    /// Markdown for Copy as Markdown and export.
    public func markdown() -> String {
        let markers = markers()
        return zip(blocks, markers).map { block, marker -> String in
            let body = block.runs.map(Self.markdown(for:)).joined()
            switch block.style {
            case .paragraph: return body
            case .heading(let level): return String(repeating: "#", count: level) + " " + body
            case .bullet: return "- " + body
            case .numbered: return (marker ?? "1.") + " " + body
            case .checklist(let checked): return (checked ? "- [x] " : "- [ ] ") + body
            case .quote: return "> " + body
            }
        }.joined(separator: "\n")
    }

    static func markdown(for run: NoteRun) -> String {
        var text = run.text
        if run.code { text = "`\(text)`" }
        if run.bold { text = "**\(text)**" }
        if run.italic { text = "*\(text)*" }
        if run.strikethrough { text = "~~\(text)~~" }
        if let link = run.link { text = "[\(text)](\(link.absoluteString))" }
        return text
    }
}

/// Typing rules of the note editor, as pure decisions.
public enum NoteEditing {
    /// What Return does at the end of a block: an empty list item ends the
    /// list (Arc, Notes and every editor); otherwise the next block keeps
    /// the list kind (checklist rows start unchecked; after a heading comes body text).
    public static func styleAfterReturn(in style: NoteBlockStyle, blockIsEmpty: Bool) -> (current: NoteBlockStyle, next: NoteBlockStyle) {
        if blockIsEmpty, style.isListItem || style == .quote { return (.paragraph, .paragraph) }
        return (style, style.continued)
    }

    /// Delete at the very start of a styled block clears its style first.
    public static func styleAfterDeleteAtStart(_ style: NoteBlockStyle) -> NoteBlockStyle? {
        style == .paragraph ? nil : .paragraph
    }

    /// Markdown shortcuts typed at the start of a paragraph, then a space:
    /// "#", "##", "###", "-", "*", "1.", "[]", "[ ]", "[x]" and ">".
    public static func shortcutStyle(forPrefix prefix: String) -> NoteBlockStyle? {
        switch prefix {
        case "#": return .heading(1)
        case "##": return .heading(2)
        case "###": return .heading(3)
        case "-", "*": return .bullet
        case "1.", "1)": return .numbered
        case "[]", "[ ]": return .checklist(checked: false)
        case "[x]", "[X]": return .checklist(checked: true)
        case ">": return .quote
        default: return nil
        }
    }

    /// A typed link target as a URL: http(s) and mailto as given, a bare
    /// host gets https; anything else (javascript:, file:) is refused.
    public static func linkURL(from input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(" ") else { return nil }
        if let url = URL(string: text), let scheme = url.scheme?.lowercased() {
            return ["http", "https", "mailto"].contains(scheme) && (scheme == "mailto" || url.host() != nil) ? url : nil
        }
        guard text.contains("."), let url = URL(string: "https://" + text), url.host() != nil else { return nil }
        return url
    }
}

// MARK: - Easel documents

extension EaselDocument {
    /// A note's rich text. Notes from before wave 28 read their text block.
    public var noteContent: NoteContent {
        if let note { return note }
        for block in blocks {
            if case .text(let runs) = block.payload { return NoteContent(legacyRuns: runs) }
        }
        return NoteContent()
    }

    /// Saves a note. Its plain text also goes into the text block, so a
    /// ReArc from before wave 28 still shows what the note says.
    public mutating func setNoteContent(_ content: NoteContent, now: Date = Date()) {
        guard note != content else { return }
        note = content
        let mirror = EaselBlockPayload.text(runs: [EaselRichTextRun(text: content.plainText)])
        if let index = blocks.firstIndex(where: { if case .text = $0.payload { return true }; return false }) {
            blocks[index].payload = mirror
        } else {
            blocks.append(EaselBlock(frame: EaselFrame(x: 120, y: 120, width: 420, height: 200), payload: mirror))
        }
        updatedAt = now
    }
}
