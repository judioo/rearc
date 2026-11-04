import AppKit
import SidebarModel

extension NSAttributedString.Key {
    /// The paragraph's `NoteBlockStyle`, as `NoteTextFormatting.styleKey`.
    static let noteBlockStyle = NSAttributedString.Key("ReArcNoteBlockStyle")
    /// Set on the list marker ("• ", "1. ", "☐ ") before a block's text.
    static let noteMarker = NSAttributedString.Key("ReArcNoteMarker")
    static let noteBold = NSAttributedString.Key("ReArcNoteBold")
    static let noteItalic = NSAttributedString.Key("ReArcNoteItalic")
    static let noteCode = NSAttributedString.Key("ReArcNoteCode")
}

/// A note as an attributed string and back. Each block is one paragraph;
/// a list block starts with its marker. Inline bold, italic and code are
/// kept as their own attributes (heading fonts are bold already), and the
/// fonts are computed from them.
enum NoteTextFormatting {
    static let bodySize: CGFloat = 15

    static func styleKey(_ style: NoteBlockStyle) -> String {
        switch style {
        case .paragraph: return "paragraph"
        case .heading(let level): return "heading:\(level)"
        case .bullet: return "bullet"
        case .numbered: return "numbered"
        case .checklist(let checked): return checked ? "checklist:1" : "checklist:0"
        case .quote: return "quote"
        }
    }

    static func style(fromKey key: String?) -> NoteBlockStyle {
        switch key {
        case "heading:1"?: return .heading(1)
        case "heading:2"?: return .heading(2)
        case "heading:3"?: return .heading(3)
        case "bullet"?: return .bullet
        case "numbered"?: return .numbered
        case "checklist:0"?: return .checklist(checked: false)
        case "checklist:1"?: return .checklist(checked: true)
        case "quote"?: return .quote
        default: return .paragraph
        }
    }

    static func font(for style: NoteBlockStyle, bold: Bool, italic: Bool, code: Bool) -> NSFont {
        let size: CGFloat
        var weight: NSFont.Weight = .regular
        switch style {
        case .heading(1): size = 26; weight = .bold
        case .heading(2): size = 20; weight = .semibold
        case .heading: size = 17; weight = .semibold
        default: size = bodySize
        }
        if bold { weight = weight == .regular ? .bold : .heavy }
        var font = code ? NSFont.monospacedSystemFont(ofSize: size * 0.92, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
        if italic {
            font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        }
        return font
    }

    static func paragraphStyle(for style: NoteBlockStyle) -> NSParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = 4
        switch style {
        case .heading:
            paragraph.paragraphSpacingBefore = 10
            paragraph.paragraphSpacing = 4
        case .bullet, .numbered, .checklist:
            paragraph.headIndent = 26
            paragraph.firstLineHeadIndent = 6
            paragraph.tabStops = [NSTextTab(textAlignment: .left, location: 26)]
            paragraph.paragraphSpacing = 2
        case .quote:
            paragraph.headIndent = 18
            paragraph.firstLineHeadIndent = 18
        case .paragraph:
            break
        }
        return paragraph
    }

    static func marker(_ text: String) -> String { text + "\t" }

    static func attributedString(_ content: NoteContent) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let markers = content.markers()
        for (index, block) in content.blocks.enumerated() {
            let paragraph: [NSAttributedString.Key: Any] = [
                .noteBlockStyle: styleKey(block.style),
                .paragraphStyle: paragraphStyle(for: block.style),
            ]
            if let marker = markers[index] {
                var attributes = paragraph
                attributes[.noteMarker] = true
                attributes[.font] = NSFont.systemFont(ofSize: bodySize, weight: .medium)
                if case .checklist = block.style {
                    attributes[.foregroundColor] = NSColor.controlAccentColor
                    attributes[.cursor] = NSCursor.pointingHand
                } else {
                    attributes[.foregroundColor] = NSColor.secondaryLabelColor
                }
                out.append(NSAttributedString(string: Self.marker(marker), attributes: attributes))
            }
            let checkedDone: Bool = { if case .checklist(true) = block.style { return true }; return false }()
            for run in block.runs {
                var attributes = paragraph
                attributes[.font] = font(for: block.style, bold: run.bold, italic: run.italic, code: run.code)
                attributes[.foregroundColor] = block.style == .quote || checkedDone ? NSColor.secondaryLabelColor : NSColor.labelColor
                if run.bold { attributes[.noteBold] = true }
                if run.italic { attributes[.noteItalic] = true }
                if run.code {
                    attributes[.noteCode] = true
                    attributes[.backgroundColor] = NSColor.quaternaryLabelColor
                }
                if run.underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
                if run.strikethrough || checkedDone { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                if let link = run.link { attributes[.link] = link }
                out.append(NSAttributedString(string: run.text, attributes: attributes))
            }
            if index < content.blocks.count - 1 {
                out.append(NSAttributedString(string: "\n", attributes: [
                    .noteBlockStyle: styleKey(block.style),
                    .paragraphStyle: paragraphStyle(for: block.style),
                    .font: font(for: block.style, bold: false, italic: false, code: false),
                ]))
            }
        }
        return out
    }

    /// The note in an attributed string; a checked item's own strikethrough
    /// is drawn from its check, so it is not read back as a run style.
    /// An empty last line has no characters to carry its style, so the
    /// editor passes the style it had (`emptyLastStyle`).
    static func content(_ text: NSAttributedString, emptyLastStyle: NoteBlockStyle? = nil) -> NoteContent {
        let string = text.string as NSString
        let length = string.length
        var blocks: [NoteBlock] = []
        var start = 0
        while true {
            let newline = string.range(of: "\n", range: NSRange(location: start, length: length - start))
            let end = newline.location == NSNotFound ? length : newline.location
            let style: NoteBlockStyle
            if start < length {
                style = Self.style(fromKey: text.attribute(.noteBlockStyle, at: start, effectiveRange: nil) as? String)
            } else {
                style = emptyLastStyle ?? blocks.last?.style.continued ?? .paragraph
            }
            let checked: Bool = { if case .checklist(true) = style { return true }; return false }()
            var runs: [NoteRun] = []
            if end > start {
                text.enumerateAttributes(in: NSRange(location: start, length: end - start)) { attributes, runRange, _ in
                    guard attributes[.noteMarker] == nil else { return }
                    runs.append(NoteRun(
                        string.substring(with: runRange).replacingOccurrences(of: "\t", with: " "),
                        bold: attributes[.noteBold] != nil,
                        italic: attributes[.noteItalic] != nil,
                        underline: (attributes[.underlineStyle] as? Int ?? 0) != 0,
                        strikethrough: !checked && (attributes[.strikethroughStyle] as? Int ?? 0) != 0,
                        code: attributes[.noteCode] != nil,
                        link: (attributes[.link] as? URL) ?? (attributes[.link] as? String).flatMap(URL.init(string:))
                    ))
                }
            }
            blocks.append(NoteBlock(style, runs: runs))
            if newline.location == NSNotFound { break }
            start = end + 1
        }
        return NoteContent(blocks: blocks)
    }

    // MARK: Positions

    /// Where each block's paragraph starts and how long its marker is.
    static func layout(_ content: NoteContent) -> [(start: Int, markerLength: Int, textLength: Int)] {
        var result: [(Int, Int, Int)] = []
        var start = 0
        for (block, marker) in zip(content.blocks, content.markers()) {
            let markerLength = marker.map { (Self.marker($0) as NSString).length } ?? 0
            let textLength = (block.text as NSString).length
            result.append((start, markerLength, textLength))
            start += markerLength + textLength + 1
        }
        return result
    }

    /// A text position as (block, offset in the block's text).
    static func blockPosition(of location: Int, in content: NoteContent) -> (block: Int, offset: Int) {
        let lines = layout(content)
        for (index, line) in lines.enumerated().reversed() where location >= line.start {
            return (index, min(max(location - line.start - line.markerLength, 0), line.textLength))
        }
        return (0, 0)
    }

    static func location(of position: (block: Int, offset: Int), in content: NoteContent) -> Int {
        let lines = layout(content)
        guard !lines.isEmpty else { return 0 }
        let line = lines[min(max(position.block, 0), lines.count - 1)]
        return line.start + line.markerLength + min(max(position.offset, 0), line.textLength)
    }
}
